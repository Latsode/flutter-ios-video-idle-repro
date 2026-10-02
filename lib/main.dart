// Minimal reproduction of the Realize iOS "app gets laggy after browsing feed
// videos" report.
//
// The Realize feed card (lib/post/post_details/video/post_video.dart) creates and
// initializes a VideoPlayerController in initState, but renders only the
// thumbnail until the user taps play. On iOS, video_player_avfoundation starts a
// CADisplayLink when the texture is registered and stops it only after the
// engine has pulled one frame from the texture. A texture that is never
// composited is never pulled, so the display link fires every vsync and calls
// textureFrameAvailable, which makes the engine redraw the last frame. Before
// video_player_avfoundation 2.9.4 the display link also kept running after the
// controller was disposed.
//
// Each launch runs one scenario, chosen by a repro_scenario file the host
// writes into the app's tmp directory, through three phases with no user
// input. The host script (tool/measure_ios_sim.py) samples CPU and native
// stacks of the simulator process during each phase.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

const videoUrl =
    'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4';
const measureDuration = Duration(seconds: 15);
const cardCount = 3;

enum Scenario {
  // Realize pattern: controllers initialized, only thumbnails shown.
  eagerThumbnail,
  // Realize pattern with another screen pushed on top of the feed.
  eagerThumbnailUnderRoute,
  // Controllers initialized and the video texture shown, paused.
  eagerShown,
  // Fix: controller created only when play is tapped (never tapped here).
  lazy,
}

enum Phase { baseline, active, afterDispose }

final _tmp = Directory.systemTemp.path;
final _logFile = File('$_tmp/repro_phases.log');
// Written into the app container by the host script before launch.
final _scenarioFile = File('$_tmp/repro_scenario');

void _log(String line) {
  final stamped = '${DateTime.now().millisecondsSinceEpoch} $line';
  // ignore: avoid_print
  print('REPRO $stamped');
  _logFile.writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
}

// Completes when every card of the active phase has finished initializing.
var _pendingCards = 0;
var _cardsReady = Completer<void>();

void _cardReady() {
  _pendingCards--;
  if (_pendingCards == 0 && !_cardsReady.isCompleted) _cardsReady.complete();
}

void main() {
  final name = _scenarioFile.existsSync()
      ? _scenarioFile.readAsStringSync().trim()
      : Platform.environment['REPRO_SCENARIO'];
  final scenario = Scenario.values.firstWhere(
    (s) => s.name == name,
    orElse: () => Scenario.eagerThumbnail,
  );
  runApp(ReproApp(scenario: scenario));
}

class ReproApp extends StatefulWidget {
  const ReproApp({super.key, required this.scenario});

  final Scenario scenario;

  @override
  State<ReproApp> createState() => _ReproAppState();
}

class _ReproAppState extends State<ReproApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  var _phase = Phase.baseline;

  @override
  void initState() {
    super.initState();
    _run();
  }

  // The host measures each phase from its MEASURE line until the next line,
  // so start-up, video loading and route transitions are excluded.
  Future<void> _run() async {
    _log('SCENARIO ${widget.scenario.name}');
    _log('PHASE baseline');
    await _wait(const Duration(seconds: 3));
    _log('MEASURE baseline');
    await _wait(measureDuration);

    _pendingCards = cardCount;
    _cardsReady = Completer<void>();
    setState(() => _phase = Phase.active);
    _log('PHASE active');
    await _cardsReady.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () => _log('READY_TIMEOUT'),
    );
    _log('READY');
    if (widget.scenario == Scenario.eagerThumbnailUnderRoute) {
      _navigatorKey.currentState!.push(
        MaterialPageRoute(builder: (_) => const OtherScreen()),
      );
    }
    await _wait(const Duration(seconds: 3));
    _log('MEASURE active');
    await _wait(measureDuration);

    if (widget.scenario == Scenario.eagerThumbnailUnderRoute) {
      _navigatorKey.currentState!.pop();
    }
    setState(() => _phase = Phase.afterDispose);
    _log('PHASE afterDispose');
    // Dispose of a controller that is still initializing waits for creation.
    await _wait(const Duration(seconds: 6));
    _log('MEASURE afterDispose');
    await _wait(measureDuration);
    _log('DONE');
  }

  Future<void> _wait(Duration duration) => Future.delayed(duration);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      home: FeedScreen(scenario: widget.scenario, phase: _phase),
    );
  }
}

class FeedScreen extends StatelessWidget {
  const FeedScreen({super.key, required this.scenario, required this.phase});

  final Scenario scenario;
  final Phase phase;

  @override
  Widget build(BuildContext context) {
    final showVideos = phase == Phase.active;
    return Scaffold(
      appBar: AppBar(title: Text('${scenario.name} / ${phase.name}')),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          for (var i = 0; i < cardCount; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: showVideos
                  ? VideoCard(key: ValueKey(i), scenario: scenario)
                  : const Thumbnail(),
            ),
        ],
      ),
    );
  }
}

class OtherScreen extends StatelessWidget {
  const OtherScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Other screen')),
      body: const Center(child: Text('Static screen pushed over the feed.')),
    );
  }
}

class VideoCard extends StatefulWidget {
  const VideoCard({super.key, required this.scenario});

  final Scenario scenario;

  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    // Same as PostVideo._initializeVideo in realize-app-flutter.
    if (widget.scenario == Scenario.lazy) {
      _cardReady();
    } else {
      _initializeVideo();
    }
  }

  Future<void> _initializeVideo() async {
    final controller = VideoPlayerController.networkUrl(Uri.parse(videoUrl));
    _controller = controller;
    try {
      await controller.initialize();
      _log('INITIALIZED');
    } catch (e) {
      _log('INIT_FAILED $e');
    }
    _cardReady();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (widget.scenario == Scenario.eagerShown &&
        controller != null &&
        controller.value.isInitialized) {
      return AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      );
    }
    return const Thumbnail();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _log('DISPOSED');
    super.dispose();
  }
}

class Thumbnail extends StatelessWidget {
  const Thumbnail({super.key});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: Colors.blueGrey.shade200,
        alignment: Alignment.center,
        child: const Icon(Icons.play_circle_outline, size: 60),
      ),
    );
  }
}
