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
// Each launch runs one scenario, chosen by the REPRO_SCENARIO environment
// variable (set with SIMCTL_CHILD_REPRO_SCENARIO), through three phases with no
// user input. The host script (tool/measure_ios_sim.py) samples CPU and native
// stacks of the simulator process during each phase.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

const videoUrl =
    'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4';
const phaseDuration = Duration(seconds: 20);
const pushOtherScreenAfter = Duration(seconds: 5);
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

final _logFile = File('${Directory.systemTemp.path}/repro_phases.log');

void _log(String line) {
  final stamped = '${DateTime.now().millisecondsSinceEpoch} $line';
  // ignore: avoid_print
  print('REPRO $stamped');
  _logFile.writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
}

void main() {
  final name = Platform.environment['REPRO_SCENARIO'];
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
  var _routePushed = false;
  final _timers = <Timer>[];

  @override
  void initState() {
    super.initState();
    _log('SCENARIO ${widget.scenario.name}');
    _log('PHASE ${_phase.name}');
    _timers.add(Timer(phaseDuration, () => _enter(Phase.active)));
    _timers.add(Timer(phaseDuration * 2, () => _enter(Phase.afterDispose)));
    _timers.add(Timer(phaseDuration * 3, () => _log('DONE')));
  }

  void _enter(Phase phase) {
    if (_routePushed) {
      _navigatorKey.currentState!.pop();
      _routePushed = false;
    }
    setState(() => _phase = phase);
    _log('PHASE ${phase.name}');

    if (phase == Phase.active &&
        widget.scenario == Scenario.eagerThumbnailUnderRoute) {
      _timers.add(Timer(pushOtherScreenAfter, () {
        _routePushed = true;
        _navigatorKey.currentState!.push(
          MaterialPageRoute(builder: (_) => const OtherScreen()),
        );
      }));
    }
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    super.dispose();
  }

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
    if (widget.scenario != Scenario.lazy) _initializeVideo();
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
