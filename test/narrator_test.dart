import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/cue_clock.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/core/narrator.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/feed/node_video.dart';
import 'package:ramifica/features/feed/subtitle_line.dart';

void main() {
  test('opening a node decodes the narrator line', () async {
    final narrator = _Narrator();
    final bloc = _bloc(narrator, _Clock());
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);

    expect(narrator.prepared, ['https://example.com/voice.m4a']);
  });

  test('a muted pause shows the line for its duration', () async {
    final clock = _Clock();
    final bloc = _bloc(_Narrator(), clock);
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);

    expect(bloc.state.muted, isTrue);
    expect(clock.scheduled, const Duration(milliseconds: 4100));
    clock.fire();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);
    expect(bloc.state.phase, FeedPhase.window);
  });

  test('sound plays the line and skips the subtitle', () async {
    final narrator = _Narrator();
    final clock = _Clock();
    final bloc = _bloc(narrator, clock);
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
    bloc.add(const MuteToggled());
    await bloc.stream.first;
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
    await narrator.played;

    expect(narrator.plays, 1);
    expect(clock.scheduled, isNull);
    narrator.finish();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);
  });

  test(
    'muting during the line stops the voice and shows the subtitle',
    () async {
      final narrator = _Narrator();
      final clock = _Clock();
      final bloc = _bloc(narrator, clock);
      addTearDown(bloc.close);

      bloc.add(const StoryOpened(storyId: 'story_temple'));
      await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
      bloc.add(const MuteToggled());
      await bloc.stream.first;
      bloc.add(const PauseReached());
      await bloc.stream.firstWhere(
        (state) => state.phase == FeedPhase.speaking,
      );
      await narrator.played;
      bloc.add(const MuteToggled());
      await bloc.stream.first;

      expect(bloc.state.muted, isTrue);
      expect(narrator.stops, greaterThan(0));
      expect(clock.scheduled, const Duration(milliseconds: 4100));
    },
  );

  test('a node with no voice goes straight to the window', () async {
    final bloc = _bloc(_Narrator(), _Clock(), voice: false);
    addTearDown(bloc.close);

    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    expect(bloc.state.phase, FeedPhase.window);
  });

  testWidgets('the muted line is centered over the last frame', (tester) async {
    final narrator = _Narrator();
    final bloc = _bloc(narrator, _Clock());
    addTearDown(bloc.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider.value(
          value: bloc,
          child: FeedView(clipPlayer: _Clip()),
        ),
      ),
    );
    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await tester.pumpAndSettle();
    bloc.add(const PauseReached());
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(find.text('Enter or climb?'));
    expect(text.maxLines, 2);
    expect(text.textAlign, TextAlign.center);
    expect(find.byType(SubtitleLine), findsOneWidget);

    await tester.tap(find.byTooltip('Turn sound on'));
    await tester.pumpAndSettle();
    await narrator.played;

    expect(narrator.unlocks, 1);
    expect(find.text('Enter or climb?'), findsNothing);
  });
}

FeedBloc _bloc(_Narrator narrator, _Clock clock, {bool voice = true}) {
  return FeedBloc(
    repository: RunRepository(
      functions: FunctionsClient(
        call: (name, data) async {
          if (name == 'startRun') {
            return {
              'runId': 'run_1',
              'storyId': 'story_temple',
              'status': 'active',
            };
          }
          return _playback(voice: voice);
        },
      ),
    ),
    narrator: narrator,
    clock: clock,
  );
}

Map<String, dynamic> _playback({required bool voice}) {
  return {
    'runId': 'run_1',
    'status': 'active',
    'story': {
      'storyId': 'story_temple',
      'title': 'The temple secret',
      'authorName': 'Alex Vance',
    },
    'node': {
      'nodeId': 'node_001',
      'title': 'The temple door',
      'isEnding': false,
      'videoUrl': 'https://example.com/video.mp4',
      'durationSeconds': 10,
      'pauseAtSeconds': 9.967,
      'windowSeconds': 6,
      'ttsText': voice ? 'Enter or climb?' : null,
      'ttsAudioUrl': voice ? 'https://example.com/voice.m4a' : null,
      'ttsDurationSeconds': voice ? 4.1 : null,
      'videoFrameLastBlurData': 'data:image/webp;base64,abc',
    },
    'choices': <Object?>[],
  };
}

class _Clip implements ClipPlayer {
  @override
  bool ready = false;
  final _listeners = <VoidCallback>[];

  @override
  bool get ended => false;

  @override
  Future<void> open({
    required Uri url,
    required bool muted,
    required bool play,
  }) async {
    ready = true;
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  @override
  Widget buildView() => const SizedBox.expand();

  @override
  void dispose() {}
}

class _Clock implements CueClock {
  Duration? scheduled;
  void Function()? _fire;

  @override
  void schedule(Duration duration, void Function() fire) {
    scheduled = duration;
    _fire = fire;
  }

  @override
  void cancel() {
    scheduled = null;
    _fire = null;
  }

  void fire() {
    final next = _fire;
    _fire = null;
    next?.call();
  }
}

class _Narrator implements Narrator {
  final prepared = <String>[];
  var plays = 0;
  var stops = 0;
  var unlocks = 0;
  var fail = false;
  void Function()? _ended;
  final _played = Completer<void>();

  Future<void> get played => _played.future;

  @override
  Future<void> prepare(String url) async {
    prepared.add(url);
  }

  @override
  void unlock() => unlocks += 1;

  @override
  Future<bool> play({required void Function() onEnded}) async {
    plays += 1;
    if (!_played.isCompleted) _played.complete();
    if (fail) return false;
    _ended = onEnded;
    return true;
  }

  @override
  void stop() {
    stops += 1;
    _ended = null;
  }

  @override
  void dispose() {}

  void finish() {
    final ended = _ended;
    _ended = null;
    ended?.call();
  }
}
