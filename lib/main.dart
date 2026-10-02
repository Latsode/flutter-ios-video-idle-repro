// Reproduction and fix verification for the Realize iOS "app gets laggy after
// browsing feed videos" report.
//
// The Realize feed card (lib/post/post_details/video/post_video.dart) creates and
// initializes a VideoPlayerController in initState, but renders only the
// thumbnail until the user taps play. On iOS, video_player_avfoundation starts a
// CADisplayLink when the texture is registered and stops it only after the
// engine has pulled one frame from the texture. A texture that is never painted
// is never pulled, so the display link fires every vsync and calls
// textureFrameAvailable, which makes the engine redraw the last frame. Before
// video_player_avfoundation 2.9.4 the display link also kept running after the
// controller was disposed.
//
// Each launch runs one card implementation (the scenario, read from a
// repro_scenario file the host writes into the app's tmp directory) in a feed
// that the app scrolls by itself, then taps play on the most visible card. The
// host script (tool/measure_ios_sim.py) samples CPU and native stacks of the
// simulator process during each MEASURE window.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

const videoUrl =
    'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4';
const measureDuration = Duration(seconds: 15);
const feedLength = 12;
const scrollStep = 300.0;

enum Scenario {
  // Current Realize PostVideo: initialize in initState, thumbnail only.
  eagerThumbnail,
  // Isolation check: initialize in initState, video painted under an opaque
  // thumbnail. The feed has no cache extent so every built card is painted.
  coveredWarm,
  // Proposed PostVideo: warm up as soon as any part is visible, video painted
  // under an opaque backdrop and the thumbnail, released when fully off screen.
  proposed,
  // Initialize only when play is tapped (cold start reference).
  lazy,
}

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

// Number of VideoPlayerControllers created and not yet disposed.
var _liveControllers = 0;

VideoPlayerController _createController() {
  _liveControllers++;
  return VideoPlayerController.networkUrl(Uri.parse(videoUrl));
}

void _disposeController(VideoPlayerController controller) {
  _liveControllers--;
  controller.pause();
  controller.dispose();
}

final _cards = <int, VideoCardState>{};

void main() {
  FlutterError.onError = (details) => _log('FLUTTER_ERROR ${details.exception}');
  PlatformDispatcher.instance.onError = (error, stack) {
    _log('UNCAUGHT_ERROR $error');
    return true;
  };
  final name = _scenarioFile.existsSync()
      ? _scenarioFile.readAsStringSync().trim()
      : null;
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
  final _scrollController = ScrollController();
  var _showFeed = false;

  Scenario get _scenario => widget.scenario;

  @override
  void initState() {
    super.initState();
    _run();
  }

  // The host measures each phase from its MEASURE line until the next line,
  // so start-up, video loading and scrolling are excluded.
  Future<void> _run() async {
    _log('SCENARIO ${_scenario.name}');
    _log('PHASE baseline');
    await _wait(3);
    await _measure('baseline');

    setState(() => _showFeed = true);
    _log('PHASE active');
    await _wait(2);
    await _browse(steps: 6);
    await _waitForTarget();
    await _measure('active');

    _log('PHASE play');
    final target = _targetCard();
    if (target == null) {
      _log('NO_TARGET');
    } else {
      _log('TAP card=${target.widget.index}');
      final latency = await target.tapAndMeasureStart();
      _log('START_LATENCY_MS ${latency ?? -1}');
      await _wait(4);
      await target.pause();
    }
    _log('PHASE paused');
    await _wait(3);
    await _measure('paused');

    _log('PHASE scrolledOn');
    await _browse(steps: 4);
    await _waitForTarget();
    await _measure('scrolledOn');

    setState(() => _showFeed = false);
    _log('PHASE afterDispose');
    // Dispose of a controller that is still initializing waits for creation.
    await _wait(6);
    await _measure('afterDispose');
    _log('DONE');
  }

  Future<void> _measure(String name) async {
    _log('LIVE_CONTROLLERS $name $_liveControllers');
    _log('MEASURE $name');
    await Future.delayed(measureDuration);
  }

  // Scroll like a user browsing: a step, a short look, the next step.
  Future<void> _browse({required int steps}) async {
    for (var i = 0; i < steps; i++) {
      await _scrollController.animateTo(
        _scrollController.offset + scrollStep,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
      await Future.delayed(const Duration(milliseconds: 1500));
    }
  }

  // Wait until the most visible card has finished preloading (if it preloads),
  // then let visibility callbacks and the first frame settle.
  Future<void> _waitForTarget() async {
    await _wait(1);
    final target = _targetCard();
    _log('TARGET card=${target?.widget.index}');
    await target?.preloaded.timeout(
      const Duration(seconds: 90),
      onTimeout: () => _log('READY_TIMEOUT'),
    );
    _log('READY');
    await _wait(3);
  }

  VideoCardState? _targetCard() {
    VideoCardState? best;
    for (final card in _cards.values) {
      if (best == null ||
          card.visibleFraction > best.visibleFraction ||
          (card.visibleFraction == best.visibleFraction &&
              card.widget.index < best.widget.index)) {
        best = card;
      }
    }
    return best;
  }

  Future<void> _wait(int seconds) => Future.delayed(Duration(seconds: seconds));

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: Text(_scenario.name)),
        body: _showFeed
            ? ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(8),
                cacheExtent: _scenario == Scenario.coveredWarm ? 0 : null,
                itemCount: feedLength,
                itemBuilder: (_, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: VideoCard(
                    key: ValueKey(index),
                    index: index,
                    scenario: _scenario,
                  ),
                ),
              )
            : const Center(child: Text('No feed')),
      ),
    );
  }
}

class VideoCard extends StatefulWidget {
  const VideoCard({super.key, required this.index, required this.scenario});

  final int index;
  final Scenario scenario;

  @override
  State<VideoCard> createState() => VideoCardState();
}

class VideoCardState extends State<VideoCard> {
  VideoPlayerController? _controller;
  Future<void>? _initializing;
  var _hasStarted = false;
  var visibleFraction = 0.0;

  Scenario get _scenario => widget.scenario;

  bool get _ready => _controller?.value.isInitialized == true;

  /// Completes when this card has nothing more to preload.
  Future<void> get preloaded => switch (_scenario) {
        Scenario.lazy => Future.value(),
        Scenario.proposed when visibleFraction == 0 => Future.value(),
        _ => _initializing ?? Future.value(),
      };

  @override
  void initState() {
    super.initState();
    _cards[widget.index] = this;
    // Same as PostVideo._initializeVideo in realize-app-flutter.
    if (_scenario == Scenario.eagerThumbnail ||
        _scenario == Scenario.coveredWarm) {
      _warmUp();
    }
  }

  Future<void> _warmUp() {
    final existing = _initializing;
    if (existing != null) return existing;
    final controller = _createController();
    _controller = controller;
    return _initializing = _initialize(controller);
  }

  Future<void> _initialize(VideoPlayerController controller) async {
    try {
      await controller.initialize();
      _log('INITIALIZED card=${widget.index}');
      if (mounted && _controller == controller) setState(() {});
    } catch (e) {
      _log('INIT_FAILED card=${widget.index} $e');
    }
  }

  void _release() {
    final controller = _controller;
    if (controller == null) return;
    _controller = null;
    _initializing = null;
    _disposeController(controller);
    _log('RELEASED card=${widget.index}');
    if (mounted) setState(() {});
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    visibleFraction = info.visibleFraction;
    if (!mounted || _scenario != Scenario.proposed) return;
    if (info.visibleFraction > 0) {
      _warmUp();
    } else if (info.visibleFraction == 0 && !_hasStarted) {
      _release();
    }
  }

  /// Simulates the user tapping play. Returns ms until playback position
  /// advances, or null on failure.
  Future<int?> tapAndMeasureStart() async {
    final stopwatch = Stopwatch()..start();
    setState(() => _hasStarted = true);
    await _warmUp();
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;
    await controller.play();
    if (mounted) setState(() {});
    while (stopwatch.elapsed < const Duration(seconds: 30)) {
      final position = await controller.position;
      if (position != null && position > Duration.zero) {
        return stopwatch.elapsedMilliseconds;
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
    return null;
  }

  Future<void> pause() async {
    await _controller?.pause();
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: ValueKey('video-card-${widget.index}'),
      onVisibilityChanged: _onVisibilityChanged,
      child: AspectRatio(aspectRatio: 16 / 9, child: _content()),
    );
  }

  Widget _content() {
    final controller = _controller;
    final paintUnderThumbnail =
        _scenario == Scenario.coveredWarm || _scenario == Scenario.proposed;

    if (_hasStarted && _ready) return VideoPlayer(controller!);
    if (paintUnderThumbnail && _ready) {
      // The video must be painted (not Offstage/Opacity 0) so the plugin
      // receives its first frame and stops its display link. The opaque
      // backdrop keeps the frame hidden while the thumbnail loads or fades in.
      return Stack(
        fit: StackFit.expand,
        children: [
          VideoPlayer(controller!),
          const ColoredBox(color: Colors.black),
          Thumbnail(index: widget.index),
        ],
      );
    }
    return Thumbnail(index: widget.index);
  }

  @override
  void dispose() {
    if (_cards[widget.index] == this) _cards.remove(widget.index);
    final controller = _controller;
    if (controller != null) _disposeController(controller);
    super.dispose();
  }
}

class Thumbnail extends StatelessWidget {
  const Thumbnail({super.key, required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.blueGrey.shade200,
      alignment: Alignment.center,
      child: Text('Video $index', style: const TextStyle(fontSize: 24)),
    );
  }
}
