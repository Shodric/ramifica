import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakeMediaPlatform extends VideoPlayerPlatform {
  int sequence = 0;
  bool initializeImmediately = true;
  final urls = <int, String>{};
  final events = <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  final playing = <int, bool>{};
  final volumes = <int, double>{};
  final disposed = <int>[];
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = ++sequence;
    urls[id] = options.dataSource.uri!;
    events[id] = StreamController<VideoEvent>.broadcast(
      sync: true,
      onListen: () {
        if (initializeImmediately) {
          scheduleMicrotask(() => events[id]!.add(initialized()));
        }
      },
    );
    positions[id] = Duration.zero;
    return id;
  }

  VideoEvent initialized() => VideoEvent(
    eventType: VideoEventType.initialized,
    duration: const Duration(seconds: 10),
    size: const Size(480, 854),
  );
  @override
  Stream<VideoEvent> videoEventsFor(int id) => events[id]!.stream;
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int id, double volume) async {
    volumes[id] = volume;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> play(int id) async {
    playing[id] = true;
  }

  @override
  Future<void> pause(int id) async {
    playing[id] = false;
  }

  @override
  Future<void> seekTo(int id, Duration position) async {
    positions[id] = position;
  }

  @override
  Future<Duration> getPosition(int id) async => positions[id] ?? Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.black);
  @override
  Future<void> dispose(int id) async {
    disposed.add(id);
    playing[id] = false;
    await events[id]?.close();
  }
}
