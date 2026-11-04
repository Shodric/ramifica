import 'dart:async';

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

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  test('a hold with a scene table arrives before the commit answers', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    final gate = Completer<Map<String, dynamic>>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(_commitResult(_playback()));
    });
    final bloc = _bloc(
      clock: clock,
      calls: calls,
      onCommit: (name, data) => gate.future,
    );
    addTearDown(bloc.close);
    await _open(bloc);
    await _toHolding(bloc, clock, 'choice_ridge');
    final phases = <FeedPhase>[];
    final sub = bloc.stream.listen((state) => phases.add(state.phase));
    addTearDown(sub.cancel);

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.nodeId == 'node_003',
    );

    // The clip switched while the commit is still in flight: no committing
    // phase, and the secret destination warmed through the scene table.
    expect(gate.isCompleted, isFalse);
    expect(phases, isNot(contains(FeedPhase.committing)));
    expect(bloc.state.holdChoiceId, isNull);
    expect(bloc.state.pendingRequestId, isNull);
    final commit = calls.where((call) => call.name == 'commitChoice').single;
    final requestId = commit.data!['requestId'] as String;
    expect(requestId, matches(_uuidV4));
    expect(commit.data, {
      'runId': 'run_1',
      'fromNodeId': 'node_001',
      'choiceId': 'choice_ridge',
      'requestId': requestId,
    });
    expect(bloc.prefetcher.urls, [
      'https://example.com/video.mp4',
      'https://example.com/next.mp4',
      'https://example.com/ridge.mp4',
    ]);

    gate.complete(_commitResult(_playback(nodeId: 'node_003')));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(bloc.state.phase, FeedPhase.playing);
    expect(bloc.state.playback!.node.nodeId, 'node_003');
    expect(bloc.state.sagaUnlocked, isNull);
  });

  test('back-to-back holds commit in chain order behind the clips', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    final gate = Completer<Map<String, dynamic>>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(_commitResult(_playback()));
    });
    var requests = 0;
    final bloc = _bloc(
      clock: clock,
      calls: calls,
      newRequestId: () => 'req_${++requests}',
      onCommit: (name, data) async {
        if (!gate.isCompleted) return gate.future;
        return {
          ..._commitResult(_playback(nodeId: 'node_001')),
          'sagaUnlocked': {
            'sagaId': 'saga_ab',
            'storyId': 'story_river',
            'title': 'Chain saga',
          },
        };
      },
    );
    addTearDown(bloc.close);
    await _open(bloc);
    await _toHolding(bloc, clock, 'choice_ridge');
    final phases = <FeedPhase>[];
    final sub = bloc.stream.listen((state) => phases.add(state.phase));
    addTearDown(sub.cancel);

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.nodeId == 'node_003',
    );
    await _toHolding(bloc, clock, 'choice_back_ridge');
    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.nodeId == 'node_001',
    );

    // Both clips switched; only the first commit left (the second queues
    // behind the gate).
    expect(phases, isNot(contains(FeedPhase.committing)));
    expect(
      calls.where((call) => call.name == 'commitChoice'),
      hasLength(1),
    );

    gate.complete(_commitResult(_playback(nodeId: 'node_003')));
    await bloc.stream.firstWhere(
      (state) => state.sagaUnlocked?.title == 'Chain saga',
    );

    final commits = [
      for (final call in calls)
        if (call.name == 'commitChoice') call.data!,
    ];
    expect(commits, hasLength(2));
    expect(commits[0]['fromNodeId'], 'node_001');
    expect(commits[0]['choiceId'], 'choice_ridge');
    expect(commits[0]['requestId'], 'req_1');
    expect(commits[1]['fromNodeId'], 'node_003');
    expect(commits[1]['choiceId'], 'choice_back_ridge');
    expect(commits[1]['requestId'], 'req_2');
    expect(bloc.state.playback!.node.nodeId, 'node_001');
  });

  test('a background ack threads saga and reward into state', () async {
    final clock = _Clock();
    final bloc = _bloc(
      clock: clock,
      onCommit: (name, data) async => {
        ..._commitResult(_playback(nodeId: 'node_003')),
        'sagaUnlocked': {
          'sagaId': 'saga_ab',
          'storyId': 'story_river',
          'title': 'The river saga',
        },
        'reward': {'rewardId': 'story_temple_node_003', 'code': 'RIDGE-1'},
      },
    );
    addTearDown(bloc.close);
    await _open(bloc);
    await _toHolding(bloc, clock, 'choice_ridge');

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) => state.sagaUnlocked?.title == 'The river saga',
    );

    expect(bloc.state.playback!.node.nodeId, 'node_003');
    expect(bloc.state.playback!.node.rewardCode, 'RIDGE-1');
  });

  test('an invalid background commit falls back to the real node', () async {
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
        return _playback(nodeId: 'node_002');
      },
    );
    addTearDown(bloc.close);
    await _open(bloc);
    await _toHolding(bloc, clock, 'choice_ridge');

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.nodeId == 'node_002',
    );

    expect(calls.where((call) => call.name == 'commitChoice'), hasLength(1));
    expect(calls.where((call) => call.name == 'loadPlayback'), hasLength(2));
    expect(bloc.state.pendingRequestId, isNull);
  });

  test('an offline commit parks without failing; a gesture resumes it', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    var attempts = 0;
    final bloc = _bloc(
      clock: clock,
      calls: calls,
      onCommit: (name, data) async {
        attempts += 1;
        if (attempts <= 2) throw const AppFailure(.offline);
        return {
          ..._commitResult(_playback(nodeId: 'node_003')),
          'reward': {'rewardId': 'story_temple_node_003', 'code': 'RIDGE-1'},
        };
      },
    );
    addTearDown(bloc.close);
    await _open(bloc);
    await _toHolding(bloc, clock, 'choice_ridge');
    final phases = <FeedPhase>[];
    final sub = bloc.stream.listen((state) => phases.add(state.phase));
    addTearDown(sub.cancel);

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.nodeId == 'node_003',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // The network retry ran (two sends), the clip kept playing, and no
    // failure surfaced: the head parked instead.
    expect(
      calls.where((call) => call.name == 'commitChoice'),
      hasLength(2),
    );
    expect(phases, isNot(contains(FeedPhase.failed)));

    bloc.add(const UserGestured());
    await bloc.stream.firstWhere(
      (state) => state.playback!.node.rewardCode == 'RIDGE-1',
    );

    expect(
      calls.where((call) => call.name == 'commitChoice'),
      hasLength(3),
    );
    expect(bloc.state.phase, FeedPhase.playing);
    expect(phases, isNot(contains(FeedPhase.failed)));
  });

  test('a re-hold from the same scene supersedes the parked commit', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    var online = false;
    final bloc = _bloc(
      clock: clock,
      calls: calls,
      onCommit: (name, data) async {
        if (!online) throw const AppFailure(.offline);
        return _commitResult(_playback());
      },
    );
    addTearDown(bloc.close);
    await _open(bloc);
    await _toHolding(bloc, clock, 'choice_ridge');

    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.nodeId == 'node_003',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      calls.where((call) => call.name == 'commitChoice'),
      hasLength(2),
    );

    // Still offline: reopening replays the parked ridge sends, then parks
    // again instead of stranding the queue.
    bloc.add(const StoryOpened(storyId: 'story_temple'));
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.nodeId == 'node_001',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      calls.where((call) => call.name == 'commitChoice'),
      hasLength(4),
    );

    // Back online the finger picks the other path: the parked ridge commit
    // is dropped, never retried.
    online = true;
    await _toHolding(bloc, clock, 'choice_temple');
    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.nodeId == 'node_002',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final sent = [
      for (final call in calls)
        if (call.name == 'commitChoice') call.data!['choiceId'],
    ];
    expect(sent, [
      'choice_ridge',
      'choice_ridge',
      'choice_ridge',
      'choice_ridge',
      'choice_temple',
    ]);
  });

  test('playback parses the scene table and defaults it empty', () {
    final playback = Playback.fromJson(_playback());
    expect(playback.nodes.keys, unorderedEquals(['node_001', 'node_002', 'node_003']));
    final ridge = playback.nodes['node_003']!;
    expect(ridge.node.title, 'The ridge path');
    expect(ridge.node.videoUrl, 'https://example.com/ridge.mp4');
    expect(ridge.choices.single.targetNodeId, 'node_001');
    expect(playback.choices[1].targetSecret, isTrue);
    expect(playback.choices[1].target, isNull);
    expect(Playback.fromJson(_playback()).nodes['node_003'], ridge);

    final legacy = Map<String, dynamic>.from(_playback())..remove('nodes');
    expect(Playback.fromJson(legacy).nodes, isEmpty);
    expect(
      () => Playback.fromJson({..._playback(), 'nodes': 'nope'}),
      throwsA(isA<AppFailure>()),
    );
  });
}

Future<void> _open(FeedBloc bloc) async {
  bloc.add(const StoryOpened(storyId: 'story_temple'));
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
}

Future<void> _toHolding(FeedBloc bloc, _Clock clock, String choiceId) async {
  bloc.add(const PauseReached());
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
  clock.fire();
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);
  bloc.add(HoldStarted(choiceId));
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);
}

class _Call {
  const _Call(this.name, this.data);

  final String name;
  final Map<String, dynamic>? data;
}

FeedBloc _bloc({
  required _Clock clock,
  List<_Call>? calls,
  String Function()? newRequestId,
  Future<dynamic> Function(String name, Map<String, dynamic>? data)? onCommit,
  Future<dynamic> Function(String name, Map<String, dynamic>? data)? onLoad,
}) {
  return FeedBloc(
    repository: RunRepository(
      execute: FunctionsClient(
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
            return _commitResult(_playback(nodeId: 'node_003'));
          }
          if (onLoad != null) return onLoad(name, data);
          return _playback();
        },
      ).call,
    ),
    prefetcher: Prefetcher(open: _Slot.new),
    clock: clock,
    newRequestId: newRequestId,
  );
}

Map<String, dynamic> _commitResult(Map<String, dynamic> playback) {
  return {'playback': playback};
}

Map<String, dynamic> _playback({String nodeId = 'node_001'}) {
  final table = _table();
  final entry = Map<String, dynamic>.from(table[nodeId]! as Map);
  return {
    'runId': 'run_1',
    'status': 'active',
    'story': {
      'storyId': 'story_temple',
      'title': 'The temple secret',
      'authorName': 'Alex Vance',
    },
    'node': {'nodeId': nodeId, ...entry},
    'choices': entry['choices'],
    'nodes': table,
  };
}

Map<String, dynamic> _table() {
  return {
    'node_001': _entry(
      title: 'The temple door',
      videoUrl: 'https://example.com/video.mp4',
      ttsText: 'Enter or climb?',
      ttsAudioUrl: 'https://example.com/voice.m4a',
      ttsDurationSeconds: 4.1,
      choices: [
        _choice(
          'choice_temple',
          'Enter the temple',
          'node_002',
          url: 'https://example.com/next.mp4',
          isDefault: true,
          x: 0.25,
          y: 0.55,
        ),
        _choice(
          'choice_ridge',
          'Climb the ridge',
          'node_003',
          secret: true,
          x: 0.72,
          y: 0.58,
        ),
      ],
    ),
    'node_002': _entry(
      title: 'The temple hall',
      videoUrl: 'https://example.com/next.mp4',
      ttsText: 'Look around?',
      ttsAudioUrl: 'https://example.com/hall.m4a',
      ttsDurationSeconds: 2.0,
      choices: [
        _choice(
          'choice_back_hall',
          'Go back',
          'node_001',
          url: 'https://example.com/video.mp4',
          isDefault: true,
        ),
      ],
    ),
    'node_003': _entry(
      title: 'The ridge path',
      videoUrl: 'https://example.com/ridge.mp4',
      ttsText: 'Ridge or river?',
      ttsAudioUrl: 'https://example.com/ridge.m4a',
      ttsDurationSeconds: 3.2,
      choices: [
        _choice(
          'choice_back_ridge',
          'Go back',
          'node_001',
          url: 'https://example.com/video.mp4',
          isDefault: true,
        ),
      ],
    ),
  };
}

Map<String, dynamic> _entry({
  required String title,
  required String videoUrl,
  String? ttsText,
  String? ttsAudioUrl,
  double? ttsDurationSeconds,
  required List<Map<String, dynamic>> choices,
}) {
  return {
    'title': title,
    'isEnding': false,
    'videoUrl': videoUrl,
    'durationSeconds': 10,
    'ttsText': ttsText,
    'ttsAudioUrl': ttsAudioUrl,
    'ttsDurationSeconds': ttsDurationSeconds,
    'videoFrameLastBlurData': 'data:image/png;base64,$_png',
    'choices': choices,
  };
}

Map<String, dynamic> _choice(
  String id,
  String label,
  String target, {
  String? url,
  bool secret = false,
  bool isDefault = false,
  double x = 0.3,
  double y = 0.4,
}) {
  return {
    'choiceId': id,
    'label': label,
    'targetNodeId': target,
    'isDefault': isDefault,
    'x': x,
    'y': y,
    'radius': 0.12,
    'targetSecret': secret,
    'target': secret ? null : {'nodeId': target, 'videoUrl': url},
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
