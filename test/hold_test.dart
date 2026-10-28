import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/cue_clock.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/warm_slot.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/feed/choice_zone.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/feed/node_video.dart';
import 'package:ramifica/features/feed/video_frame.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  test('the window waits windowSeconds, then holds the default', () async {
    final clock = _Clock();
    final bloc = _bloc(clock);
    addTearDown(bloc.close);

    await _open(bloc);
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
    expect(clock.scheduled, const Duration(milliseconds: 4100));
    clock.fire();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    expect(clock.scheduled, const Duration(seconds: 6));
    expect(bloc.prefetcher.urls, [
      'https://example.com/video.mp4',
      'https://example.com/next.mp4',
      'https://example.com/ridge.mp4',
    ]);
    clock.fire();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);

    expect(bloc.state.holdChoiceId, 'choice_temple');
    expect(bloc.prefetcher.urls.last, 'https://example.com/next.mp4');
  });

  test('a press holds that zone and promotes its clip', () async {
    final clock = _Clock();
    final bloc = _bloc(clock);
    addTearDown(bloc.close);
    await _window(bloc, clock);

    bloc.add(const HoldStarted('choice_ridge'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);

    expect(bloc.state.holdChoiceId, 'choice_ridge');
    expect(bloc.prefetcher.urls.last, 'https://example.com/ridge.mp4');
  });

  test('a press before the window does nothing', () async {
    final bloc = _bloc(_Clock());
    addTearDown(bloc.close);
    await _open(bloc);

    bloc.add(const HoldStarted('choice_ridge'));
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.phase, FeedPhase.playing);
    expect(bloc.state.holdChoiceId, isNull);
  });

  test('releasing early returns to the window', () async {
    final clock = _Clock();
    final bloc = _bloc(clock);
    addTearDown(bloc.close);
    await _window(bloc, clock);
    bloc.add(const HoldStarted('choice_ridge'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);

    bloc.add(const HoldCancelled());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    expect(bloc.state.holdChoiceId, isNull);
    expect(bloc.prefetcher.urls, contains('https://example.com/ridge.mp4'));
  });

  test('the window ending during a hold keeps that zone', () async {
    final clock = _Clock();
    final bloc = _bloc(clock);
    addTearDown(bloc.close);
    await _window(bloc, clock);
    bloc.add(const HoldStarted('choice_ridge'));
    await bloc.stream.firstWhere(
      (state) => state.holdChoiceId == 'choice_ridge',
    );

    clock.fire();
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.phase, FeedPhase.holding);
    expect(bloc.state.holdChoiceId, 'choice_ridge');

    bloc.add(const HoldCancelled());
    await bloc.stream.first;

    expect(bloc.state.phase, FeedPhase.holding);
    expect(bloc.state.holdChoiceId, 'choice_temple');
  });

  test('a finished hold ignores the release', () async {
    final clock = _Clock();
    final bloc = _bloc(clock);
    addTearDown(bloc.close);
    await _window(bloc, clock);
    bloc.add(const HoldStarted('choice_ridge'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);
    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
    final runId = bloc.state.runId;
    bloc.add(const HoldCancelled());
    await Future<void>.delayed(Duration.zero);

    // The release arrived after the commit went through: ignored, no
    // revert to the window, same run, hold cleared.
    expect(bloc.state.phase, FeedPhase.playing);
    expect(bloc.state.runId, runId);
    expect(bloc.state.holdChoiceId, isNull);
  });

  testWidgets('the window shows each label under its ring', (tester) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    expect(find.text('Enter the temple'), findsOneWidget);
    expect(find.text('Climb the ridge'), findsOneWidget);
    expect(find.byType(ChoiceZone), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('Enter the temple')).dy,
      greaterThan(
        tester
            .getBottomLeft(find.byKey(const ValueKey('ring-choice_temple')))
            .dy,
      ),
    );
  });

  testWidgets('a short press does not choose', (tester) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    final gesture = await tester.startGesture(_ring(tester, 'choice_ridge'));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(bloc.state.phase, FeedPhase.window);
    expect(bloc.state.holdChoiceId, isNull);
  });

  testWidgets('holding for one second keeps the portal open', (tester) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    final gesture = await tester.startGesture(_ring(tester, 'choice_ridge'));
    await tester.pump();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.holding);
    expect(find.byType(Image), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pump();

    expect(bloc.state.phase, FeedPhase.holding);
    expect(bloc.state.holdChoiceId, 'choice_ridge');
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('the timeout opens the default portal', (tester) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    clock.fire();
    await tester.pump();

    expect(bloc.state.phase, FeedPhase.holding);
    expect(bloc.state.holdChoiceId, 'choice_temple');
    await tester.pump(const Duration(seconds: 1));
    expect(bloc.state.holdChoiceId, 'choice_temple');
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('releasing outside the ring cancels the hold', (tester) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    final gesture = await tester.startGesture(_ring(tester, 'choice_ridge'));
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.holding);

    await gesture.moveTo(const Offset(10, 10));
    await gesture.up();
    await tester.pump();

    expect(bloc.state.phase, FeedPhase.window);
    expect(bloc.state.holdChoiceId, isNull);
  });

  testWidgets('another finger does not cancel the hold', (tester) async {
    final clock = _Clock();
    final bloc = _bloc(clock, voice: false);
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    final hold = await tester.startGesture(_ring(tester, 'choice_ridge'));
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.holding);

    final tap = await tester.startGesture(const Offset(10, 10));
    await tap.up();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.holding);
    expect(bloc.state.holdChoiceId, 'choice_ridge');

    await hold.up();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.window);
  });

  testWidgets('the ring follows the cover rect', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            key: const Key('frame'),
            width: 195,
            height: 422,
            child: Stack(
              children: [
                ChoiceZone(
                  choiceId: 'choice_ridge',
                  label: 'Climb the ridge',
                  x: 0.72,
                  y: 0.58,
                  radius: 0.12,
                  video: const VideoFrame(Size(195, 422)),
                  enabled: true,
                  onHoldStart: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Cover: scale = max(195/9, 422/16) = 26.375; video 237.375x422.
    final origin = tester.getTopLeft(find.byKey(const Key('frame')));
    expect(
      tester.getCenter(find.byKey(const ValueKey('ring-choice_ridge'))),
      offsetMoreOrLessEquals(origin + const Offset(149.7225, 244.76)),
    );
  });
}

Future<void> _open(FeedBloc bloc) async {
  bloc.add(const StoryOpened(storyId: 'story_temple'));
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
}

Future<void> _window(FeedBloc bloc, _Clock clock) async {
  await _open(bloc);
  bloc.add(const PauseReached());
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
  clock.fire();
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);
}

Future<void> _showWindow(WidgetTester tester, FeedBloc bloc) async {
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
}

Offset _ring(WidgetTester tester, String choiceId) {
  return tester.getCenter(find.byKey(ValueKey('ring-$choiceId')));
}

FeedBloc _bloc(_Clock clock, {bool voice = true}) {
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
    prefetcher: Prefetcher(open: _Slot.new),
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
      'videoFrameLastBlurData': 'data:image/png;base64,$_png',
    },
    'choices': [
      {
        'choiceId': 'choice_temple',
        'label': 'Enter the temple',
        'targetNodeId': 'node_002',
        'isDefault': true,
        'x': 0.25,
        'y': 0.55,
        'radius': 0.12,
        'targetSecret': false,
        'target': {
          'nodeId': 'node_002',
          'videoUrl': 'https://example.com/next.mp4',
        },
      },
      {
        'choiceId': 'choice_ridge',
        'label': 'Climb the ridge',
        'targetNodeId': 'node_003',
        'isDefault': false,
        'x': 0.72,
        'y': 0.58,
        'radius': 0.12,
        'targetSecret': false,
        'target': {
          'nodeId': 'node_003',
          'videoUrl': 'https://example.com/ridge.mp4',
        },
      },
    ],
  };
}

class _Slot implements WarmSlot {
  @override
  void mount(String url) {}

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
