// Minimal reproduction of the Realize iOS "app gets laggy after browsing feed
// videos" report.
//
// The Realize feed card (lib/post/post_details/video/post_video.dart) creates and
// initializes a VideoPlayerController in initState, but renders only the
// thumbnail until the user taps play. On iOS, video_player_avfoundation starts a
// CADisplayLink when the texture is registered and stops it only after the
// engine has pulled one frame from the texture. A texture that is never
// composited is never pulled, so the display link fires every vsync and calls
// textureFrameAvailable, which makes the engine redraw the last frame forever.
//
// The app runs a fixed sequence of phases with no user input. The host script
// (tool/measure_ios_sim.sh) samples CPU and native stacks of the simulator
// process during each phase.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

const videoUrl =
    'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4';
const phaseDuration = Duration(seconds: 20);
const cardCount = 3;

enum Phase {
  controlIdle('No video controllers. Baseline idle.'),
  bugFeed('Feed pattern: controllers initialized, only thumbnails shown.'),
  bugUnderOtherScreen('Feed pattern covered by another pushed screen.'),
  fixLazyInit('Fix: controller created only on play tap (never tapped).'),
  shownThenPaused('Controllers initialized and texture shown, paused.'),
  controlIdleEnd('All cards disposed again. Baseline idle.');

  const Phase(this.description);
  final String description;
}

final _logFile = File('${Directory.systemTemp.path}/repro_phases.log');

void _log(String line) {
  final stamped = '${DateTime.now().millisecondsSinceEpoch} $line';
  // ignore: avoid_print
  print('REPRO $stamped');
  _logFile.writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
}

void main() {
  if (_logFile.existsSync()) _logFile.deleteSync();
  runApp(const ReproApp());
}

class ReproApp extends StatefulWidget {
  const ReproApp({super.key});

  @override
  State<ReproApp> createState() => _ReproAppState();
}

class _ReproAppState extends State<ReproApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  var _phaseIndex = 0;
  Timer? _timer;

  Phase get _phase => Phase.values[_phaseIndex];

  @override
  void initState() {
    super.initState();
    _enterPhase();
    _timer = Timer.periodic(phaseDuration, (_) => _nextPhase());
  }

  void _nextPhase() {
    final navigator = _navigatorKey.currentState!;
    if (_phase == Phase.bugUnderOtherScreen) navigator.pop();

    if (_phaseIndex == Phase.values.length - 1) {
      _timer?.cancel();
      _log('DONE');
      return;
    }
    setState(() => _phaseIndex++);
    _enterPhase();

    if (_phase == Phase.bugUnderOtherScreen) {
      navigator.push(MaterialPageRoute(builder: (_) => const OtherScreen()));
    }
  }

  void _enterPhase() => _log('PHASE ${_phase.name}');

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      home: FeedScreen(phase: _phase),
    );
  }
}

class FeedScreen extends StatelessWidget {
  const FeedScreen({super.key, required this.phase});

  final Phase phase;

  @override
  Widget build(BuildContext context) {
    final cardMode = switch (phase) {
      Phase.controlIdle || Phase.controlIdleEnd => null,
      Phase.bugFeed || Phase.bugUnderOtherScreen => CardMode.eagerThumbnail,
      Phase.fixLazyInit => CardMode.lazy,
      Phase.shownThenPaused => CardMode.eagerShown,
    };

    return Scaffold(
      appBar: AppBar(title: Text(phase.name)),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          Text(phase.description),
          const SizedBox(height: 8),
          for (var i = 0; i < cardCount; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: cardMode == null
                  ? const Thumbnail()
                  // Keyed by mode so each phase disposes and recreates cards.
                  : VideoCard(key: ValueKey('$cardMode-$i'), mode: cardMode),
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

enum CardMode { eagerThumbnail, eagerShown, lazy }

class VideoCard extends StatefulWidget {
  const VideoCard({super.key, required this.mode});

  final CardMode mode;

  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    // Same as PostVideo._initializeVideo in realize-app-flutter.
    if (widget.mode != CardMode.lazy) _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    final controller = VideoPlayerController.networkUrl(Uri.parse(videoUrl));
    _controller = controller;
    try {
      await controller.initialize();
      _log('INITIALIZED ${widget.mode.name}');
    } catch (e) {
      _log('INIT_FAILED ${widget.mode.name} $e');
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (widget.mode == CardMode.eagerShown &&
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
