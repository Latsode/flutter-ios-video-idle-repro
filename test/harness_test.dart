// Runs the repro app's phase script against a fake video platform so harness
// logic can be checked without an iOS Simulator.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ios_video_idle_repro/main.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  var _nextId = 0;
  final _events = <int, StreamController<VideoEvent>>{};
  final _playing = <int, bool>{};
  final _position = <int, Duration>{};

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    final controller = StreamController<VideoEvent>();
    _events[id] = controller;
    Timer(const Duration(milliseconds: 200), () {
      controller.add(VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 10),
        size: const Size(1280, 720),
      ));
    });
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {
    _playing[playerId] = true;
    _position[playerId] = const Duration(milliseconds: 100);
  }

  @override
  Future<void> pause(int playerId) async => _playing[playerId] = false;

  @override
  Future<Duration> getPosition(int playerId) async =>
      _position[playerId] ?? Duration.zero;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.black);
}

void main() {
  final logFile = File('${Directory.systemTemp.path}/repro_phases.log');

  setUp(() {
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    if (logFile.existsSync()) logFile.deleteSync();
  });

  for (final scenario in Scenario.values) {
    testWidgets('${scenario.name} runs every phase', (tester) async {
      await tester.pumpWidget(ReproApp(scenario: scenario));
      for (var i = 0; i < 2400; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        if (logFile.readAsStringSync().contains(' DONE')) break;
      }
      final log = logFile.readAsStringSync();
      // ignore: avoid_print
      print(log.split('\n').map((l) => l.split(' ').skip(1).join(' ')).join('\n'));
      for (final phase in [
        'baseline',
        'active',
        'paused',
        'scrolledOn',
        'afterDispose',
      ]) {
        expect(log, contains('MEASURE $phase'));
      }
      expect(log, contains(' DONE'));
    });
  }
}
