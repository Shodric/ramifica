import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/cue_clock.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/warm_slot.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/playback.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/feed/node_video.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  test('a finished hold advances to the destination clip', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    final bloc = _bloc(clock: clock, calls: calls);
    addTearDown(bloc.close);
    await _holding(bloc, clock, 'choice_ridge');

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) => state.phase == FeedPhase.committing,
    );

    expect(bloc.state.holdChoiceId, 'choice_ridge');
    final requestId = bloc.state.pendingRequestId;
    expect(requestId, matches(_uuidV4));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);

    final commit = calls.where((call) => call.name == 'commitChoice').single;
    expect(commit.data, {
      'runId': 'run_1',
      'fromNodeId': 'node_001',
      'choiceId': 'choice_ridge',
      'requestId': requestId,
    });
    expect(bloc.state.playback!.node.nodeId, 'node_003');
    expect(bloc.state.pendingRequestId, isNull);
    expect(bloc.state.holdChoiceId, isNull);
    expect(bloc.prefetcher.urls, [
      'https://example.com/video.mp4',
      'https://example.com/next.mp4',
      'https://example.com/ridge.mp4',
    ]);
  });

  test('arriving keeps the sound the person chose', () async {
    final clock = _Clock();
    final bloc = _bloc(clock: clock);
    addTearDown(bloc.close);
    await _holding(bloc, clock, 'choice_ridge');
    bloc.add(const MuteToggled());
    await bloc.stream.first;

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);

    expect(bloc.state.muted, isFalse);
    expect(bloc.state.autoMuted, isFalse);
  });

  test('a lost network retries once with the same request id', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    var commits = 0;
    final bloc = _bloc(
      clock: clock,
      calls: calls,
      newRequestId: () => 'req_1',
      onCommit: (name, data) async {
        commits += 1;
        if (commits == 1) throw const AppFailure(.offline);
        return _commitResult(_destination());
      },
    );
    addTearDown(bloc.close);
    await _holding(bloc, clock, 'choice_ridge');

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);

    final sent = [
      for (final call in calls)
        if (call.name == 'commitChoice') call.data!['requestId'],
    ];
    expect(sent, ['req_1', 'req_1']);
    expect(bloc.state.playback!.node.nodeId, 'node_003');
  });

  test('a network that stays down fails the commit', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    final bloc = _bloc(
      clock: clock,
      calls: calls,
      onCommit: (name, data) async => throw const AppFailure(.offline),
    );
    addTearDown(bloc.close);
    await _holding(bloc, clock, 'choice_ridge');

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.failed);

    expect(bloc.state.failure, 'No connection');
    expect(
      calls.where((call) => call.name == 'commitChoice'),
      hasLength(2),
    );
  });

  test('an invalid hold falls back to the real node', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    var loads = 0;
    final bloc = _bloc(
      clock: clock,
      calls: calls,
      onCommit: (name, data) async => throw const AppFailure(.invalid),
      onLoad: (name, data) async {
        loads += 1;
        if (loads == 1) return _playback();
        return _playback(
          nodeId: 'node_002',
          title: 'The temple hall',
          videoUrl: 'https://example.com/next.mp4',
        );
      },
    );
    addTearDown(bloc.close);
    await _holding(bloc, clock, 'choice_ridge');

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);

    expect(calls.where((call) => call.name == 'commitChoice'), hasLength(1));
    expect(calls.where((call) => call.name == 'loadPlayback'), hasLength(2));
    expect(calls.last.data, {'runId': 'run_1'});
    expect(bloc.state.playback!.node.nodeId, 'node_002');
    expect(bloc.state.pendingRequestId, isNull);
  });

  test('an invalid hold with no way back fails', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    var loads = 0;
    final bloc = _bloc(
      clock: clock,
      calls: calls,
      onCommit: (name, data) async => throw const AppFailure(.invalid),
      onLoad: (name, data) async {
        loads += 1;
        if (loads == 1) return _playback();
        throw const AppFailure(.offline);
      },
    );
    addTearDown(bloc.close);
    await _holding(bloc, clock, 'choice_ridge');

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.failed);

    expect(bloc.state.failure, 'No connection');
    expect(calls.where((call) => call.name == 'commitChoice'), hasLength(1));
    expect(calls.where((call) => call.name == 'loadPlayback'), hasLength(2));
  });

  test('a second hold while committing is dropped', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    final gate = Completer<Map<String, dynamic>>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(_commitResult(_destination()));
    });
    final bloc = _bloc(
      clock: clock,
      calls: calls,
      onCommit: (name, data) => gate.future,
    );
    addTearDown(bloc.close);
    await _holding(bloc, clock, 'choice_ridge');

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) => state.phase == FeedPhase.committing,
    );
    bloc.add(const HoldCompleted());
    await Future<void>.delayed(Duration.zero);
    gate.complete(_commitResult(_destination()));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);

    expect(
      calls.where((call) => call.name == 'commitChoice'),
      hasLength(1),
    );
  });

  test('a hold that completes outside the portal does nothing', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    final bloc = _bloc(clock: clock, calls: calls);
    addTearDown(bloc.close);
    await _open(bloc);

    bloc.add(const HoldCompleted());
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.phase, FeedPhase.playing);
    expect(calls.where((call) => call.name == 'commitChoice'), isEmpty);
  });

  test('a commit to an ending plays the final clip, then parks with the card',
      () async {
    final clock = _Clock();
    final bloc = _bloc(
      clock: clock,
      onCommit: (name, data) async => _commitResult(_ending()),
    );
    addTearDown(bloc.close);
    await _holding(bloc, clock, 'choice_temple');

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.isEnding,
    );

    expect(bloc.state.playback!.node.endingName, 'The door');
    expect(bloc.state.holdChoiceId, isNull);
    expect(bloc.state.pendingRequestId, isNull);

    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.ending);

    // `_ending()` carries no closing line, so the card is already visible.
    expect(bloc.state.endingSpeaking, isFalse);
  });

  test('an ending with a closing line speaks over the last frame', () async {
    final clock = _Clock();
    final bloc = _bloc(
      clock: clock,
      onCommit: (name, data) async => _commitResult(_endingWithLine()),
    );
    addTearDown(bloc.close);
    await _holding(bloc, clock, 'choice_temple');

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.isEnding,
    );
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.ending && state.endingSpeaking,
    );

    clock.fire();
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.ending && !state.endingSpeaking,
    );
  });

  test('trying another path restarts at the root and keeps sound', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    final bloc = _bloc(
      clock: clock,
      calls: calls,
      onCommit: (name, data) async => _commitResult(_ending()),
    );
    addTearDown(bloc.close);
    await _holding(bloc, clock, 'choice_temple');
    bloc.add(const MuteToggled());
    await bloc.stream.first;

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.isEnding,
    );
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.ending);

    bloc.add(const OtherPathRequested());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          !state.playback!.node.isEnding,
    );

    expect(bloc.state.playback!.node.nodeId, 'node_001');
    expect(bloc.state.muted, isFalse);
    expect(bloc.state.autoMuted, isFalse);
    final restarts = [
      for (final call in calls)
        if (call.name == 'startRun' && call.data?['restart'] == true) call,
    ];
    expect(restarts, hasLength(1));
  });

  test('asking for the map from the card changes nothing', () async {
    final clock = _Clock();
    final bloc = _bloc(
      clock: clock,
      onCommit: (name, data) async => _commitResult(_ending()),
    );
    addTearDown(bloc.close);
    await _holding(bloc, clock, 'choice_temple');

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.isEnding,
    );
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.ending);

    bloc.add(const MapRequested());
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.phase, FeedPhase.ending);
    expect(bloc.state.endingSpeaking, isFalse);
  });

  test('commitChoice trims its ids and rejects a blank one', () async {
    final calls = <_Call>[];
    final repository = RunRepository(
      functions: FunctionsClient(
        call: (name, data) async {
          calls.add(_Call(name, data));
          return _commitResult(_destination());
        },
      ),
    );

    final result = await repository.commitChoice(
      runId: ' run_1 ',
      fromNodeId: 'node_001',
      choiceId: 'choice_ridge',
      requestId: 'req_1',
    );

    expect(result.playback.node.nodeId, 'node_003');
    expect(calls.single.data, {
      'runId': 'run_1',
      'fromNodeId': 'node_001',
      'choiceId': 'choice_ridge',
      'requestId': 'req_1',
    });
    expect(
      () => repository.commitChoice(
        runId: 'run_1',
        fromNodeId: 'node_001',
        choiceId: '   ',
        requestId: 'req_1',
      ),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.code,
          'code',
          AppFailureCode.invalid,
        ),
      ),
    );
    expect(calls, hasLength(1));
  });

  test('a commit without playback is invalid', () {
    expect(
      () => CommitResult.fromJson({}),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.code,
          'code',
          AppFailureCode.invalid,
        ),
      ),
    );
  });

  test('a commit ignores the fields a later slice reads', () {
    final result = CommitResult.fromJson({
      'playback': _playback(),
      'ending': null,
      'sagaUnlocked': null,
      'reward': null,
    });

    expect(result.playback.node.nodeId, 'node_001');
  });

  testWidgets('the portal stays full while committing', (tester) async {
    final gate = Completer<Map<String, dynamic>>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(_commitResult(_destination()));
    });
    final clock = _Clock();
    final bloc = _bloc(
      clock: clock,
      voice: false,
      onCommit: (name, data) => gate.future,
    );
    addTearDown(bloc.close);
    await _showWindow(tester, bloc);

    final gesture = await tester.startGesture(_ring(tester, 'choice_ridge'));
    await tester.pump();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.holding);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.committing);
    expect(find.byType(Image), findsOneWidget);

    await gesture.up();
    await tester.pump();
    expect(bloc.state.phase, FeedPhase.committing);

    gate.complete(_commitResult(_destination()));
    await tester.pumpAndSettle();
    expect(bloc.state.phase, FeedPhase.playing);
    expect(bloc.state.playback!.node.nodeId, 'node_003');
    expect(find.byType(Image), findsNothing);
  });
}

Future<void> _open(FeedBloc bloc) async {
  bloc.add(const StoryOpened(storyId: 'story_temple'));
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
}

Future<void> _holding(FeedBloc bloc, _Clock clock, String choiceId) async {
  await _open(bloc);
  bloc.add(const PauseReached());
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
  clock.fire();
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);
  bloc.add(HoldStarted(choiceId));
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);
}

Future<void> _showWindow(WidgetTester tester, FeedBloc bloc) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BlocProvider.value(value: bloc, child: FeedView(clipPlayer: _Clip())),
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

class _Call {
  const _Call(this.name, this.data);

  final String name;
  final Map<String, dynamic>? data;
}

FeedBloc _bloc({
  required _Clock clock,
  List<_Call>? calls,
  bool voice = true,
  String Function()? newRequestId,
  Future<dynamic> Function(String name, Map<String, dynamic>? data)? onCommit,
  Future<dynamic> Function(String name, Map<String, dynamic>? data)? onLoad,
}) {
  return FeedBloc(
    repository: RunRepository(
      functions: FunctionsClient(
        call: (name, data) async {
          calls?.add(_Call(name, data));
          if (name == 'startRun') {
            return {
              'runId': 'run_1',
              'storyId': 'story_temple',
              'status': 'active',
            };
          }
          if (name == 'commitChoice') {
            if (onCommit != null) return onCommit(name, data);
            return _commitResult(_destination());
          }
          if (onLoad != null) return onLoad(name, data);
          return _playback(voice: voice);
        },
      ),
    ),
    prefetcher: Prefetcher(open: _Slot.new),
    clock: clock,
    newRequestId: newRequestId,
  );
}

Map<String, dynamic> _commitResult(Map<String, dynamic> playback) {
  return {'playback': playback};
}

Map<String, dynamic> _destination() {
  return _playback(
    nodeId: 'node_003',
    title: 'The ridge path',
    videoUrl: 'https://example.com/ridge.mp4',
    ttsText: 'Ridge or river?',
    ttsAudioUrl: 'https://example.com/ridge.m4a',
    ttsDurationSeconds: 3.2,
    choices: const [],
  );
}

Map<String, dynamic> _ending() {
  return {
    'runId': 'run_1',
    'status': 'ended',
    'story': {
      'storyId': 'story_temple',
      'title': 'The temple secret',
      'authorName': 'Alex Vance',
    },
    'node': {
      'nodeId': 'node_end',
      'title': 'The last door',
      'isEnding': true,
      'videoUrl': 'https://example.com/end.mp4',
      'durationSeconds': 10,
      'pauseAtSeconds': 9.967,
      'windowSeconds': 6,
      'ttsText': null,
      'ttsAudioUrl': null,
      'ttsDurationSeconds': null,
      'videoFrameLastBlurData': 'data:image/png;base64,$_png',
      'endingName': 'The door',
      'endingType': 'tragic',
    },
    'choices': const [],
  };
}

Map<String, dynamic> _endingWithLine() {
  final ending = _ending();
  final node = Map<String, dynamic>.from(ending['node'] as Map);
  node['ttsText'] = 'What should Jeff do now?';
  node['ttsAudioUrl'] = 'https://example.com/end-voice.m4a';
  node['ttsDurationSeconds'] = 2.5;
  return {...ending, 'node': node};
}

Map<String, dynamic> _playback({
  bool voice = true,
  String nodeId = 'node_001',
  String title = 'The temple door',
  String videoUrl = 'https://example.com/video.mp4',
  String? ttsText = 'Enter or climb?',
  String? ttsAudioUrl = 'https://example.com/voice.m4a',
  double? ttsDurationSeconds = 4.1,
  List<Map<String, Object?>>? choices,
}) {
  return {
    'runId': 'run_1',
    'status': 'active',
    'story': {
      'storyId': 'story_temple',
      'title': 'The temple secret',
      'authorName': 'Alex Vance',
    },
    'node': {
      'nodeId': nodeId,
      'title': title,
      'isEnding': false,
      'videoUrl': videoUrl,
      'durationSeconds': 10,
      'pauseAtSeconds': 9.967,
      'windowSeconds': 6,
      'ttsText': voice ? ttsText : null,
      'ttsAudioUrl': voice ? ttsAudioUrl : null,
      'ttsDurationSeconds': voice ? ttsDurationSeconds : null,
      'videoFrameLastBlurData': 'data:image/png;base64,$_png',
    },
    'choices':
        choices ??
        [
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
