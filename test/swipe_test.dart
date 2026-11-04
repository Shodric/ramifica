import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/cue_clock.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/warm_slot.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/repositories/catalog_repository.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';

void main() {
  test('swipe draws another story and opens it with the resume rule', () async {
    final calls = <_Call>[];
    final bloc = _bloc(ids: ['story_a', 'story_b'], calls: calls);
    addTearDown(bloc.close);
    await _open(bloc, 'story_a');

    bloc.add(const StorySwiped());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.story.storyId == 'story_b',
    );

    final draws = [
      for (final call in calls)
        if (call.name == 'startRun') call.data?['storyId'],
    ];
    expect(draws, ['story_a', 'story_b']);
    expect(bloc.state.holdChoiceId, isNull);
    expect(bloc.state.endingSpeaking, isFalse);
  });

  test('swipe starts the other story from its root', () async {
    final calls = <_Call>[];
    final bloc = _bloc(ids: ['story_a', 'story_b'], calls: calls);
    addTearDown(bloc.close);
    await _open(bloc, 'story_a');

    bloc.add(const StorySwiped());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.story.storyId == 'story_b',
    );

    final restarts = [
      for (final call in calls)
        if (call.name == 'startRun') call.data?['restart'],
    ];
    expect(restarts, [true, true]);
  });

  test('swipe is ignored when it is the only story', () async {
    final calls = <_Call>[];
    final bloc = _bloc(ids: ['story_a'], calls: calls);
    addTearDown(bloc.close);
    await _open(bloc, 'story_a');

    bloc.add(const StorySwiped());
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.phase, FeedPhase.playing);
    expect(calls.where((call) => call.name == 'startRun'), hasLength(1));
  });

  test('swipe is ignored while speaking', () async {
    final calls = <_Call>[];
    final bloc = _bloc(ids: ['story_a', 'story_b'], calls: calls);
    addTearDown(bloc.close);
    await _open(bloc, 'story_a');

    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
    bloc.add(const StorySwiped());
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.phase, FeedPhase.speaking);
    // One open plus the background precache of story_b.
    expect(calls.where((call) => call.name == 'startRun'), hasLength(2));
  });

  test('swipe from the card opens another story', () async {
    final calls = <_Call>[];
    final bloc = _bloc(
      ids: ['story_a', 'story_b'],
      calls: calls,
      endings: {'story_a': true},
    );
    addTearDown(bloc.close);
    await _open(bloc, 'story_a');
    expect(bloc.state.phase, FeedPhase.ending);

    bloc.add(const StorySwiped());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.story.storyId == 'story_b',
    );

    expect(bloc.state.playback!.node.isEnding, isFalse);
  });

  test('swipe waits out the closing line', () async {
    final clock = _Clock();
    final calls = <_Call>[];
    final bloc = _bloc(
      ids: ['story_a', 'story_b'],
      calls: calls,
      clock: clock,
      commitsEndingWithLine: true,
    );
    addTearDown(bloc.close);
    await _open(bloc, 'story_a');

    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
    clock.fire();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);
    bloc.add(const HoldStarted('choice_a'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);
    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing && state.playback!.node.isEnding,
    );
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere(
      (state) => state.phase == FeedPhase.ending && state.endingSpeaking,
    );

    bloc.add(const StorySwiped());
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.phase, FeedPhase.ending);
    expect(bloc.state.endingSpeaking, isTrue);
    // One open plus the background precache of story_b.
    expect(calls.where((call) => call.name == 'startRun'), hasLength(2));

    clock.fire();
    await bloc.stream.firstWhere(
      (state) => state.phase == FeedPhase.ending && !state.endingSpeaking,
    );
    bloc.add(const StorySwiped());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.story.storyId == 'story_b',
    );
  });

  test('a catalog failure keeps the current clip', () async {
    final calls = <_Call>[];
    final bloc = _bloc(
      ids: const [],
      calls: calls,
      error: const AppFailure(.offline),
    );
    addTearDown(bloc.close);
    await _open(bloc, 'story_a');

    bloc.add(const StorySwiped());
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.phase, FeedPhase.playing);
    expect(bloc.state.playback!.story.storyId, 'story_a');
    expect(calls.where((call) => call.name == 'startRun'), hasLength(1));
  });

  test('swipe without a catalog does nothing', () async {
    final calls = <_Call>[];
    final bloc = FeedBloc(
      repository: _runs(calls, const {}),
      prefetcher: Prefetcher(open: _Slot.new),
      clock: _Clock(),
    );
    addTearDown(bloc.close);
    await _open(bloc, 'story_a');

    bloc.add(const StorySwiped());
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.phase, FeedPhase.playing);
    expect(calls.where((call) => call.name == 'startRun'), hasLength(1));
  });

  test('swipe mounts the precached story with no loading phase', () async {
    final calls = <_Call>[];
    final bloc = _bloc(ids: ['story_a', 'story_b'], calls: calls);
    addTearDown(bloc.close);
    await _open(bloc, 'story_a');
    // Let the background precache settle: open + precache startRuns.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final draws = [
      for (final call in calls)
        if (call.name == 'startRun') call.data?['storyId'],
    ];
    expect(draws, ['story_a', 'story_b']);

    final phases = <FeedPhase>[];
    final sub = bloc.stream.listen((state) => phases.add(state.phase));
    bloc.add(const StorySwiped());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.story.storyId == 'story_b',
    );
    await sub.cancel();

    // Two stories, no repeated ids: the draw must hit the precache, so
    // no new startRun fires for story_b on swipe (a later precache may
    // add a third call once the mounted story rebuilds the queue).
    final swipeDraws = [
      for (final call in calls)
        if (call.name == 'startRun') call.data?['storyId'],
    ];
    expect(swipeDraws.where((id) => id == 'story_b'), hasLength(1));
    expect(phases, isNot(contains(FeedPhase.loading)));
    expect(bloc.state.playback!.story.storyId, 'story_b');
  });

  test('a failed precache falls back to a normal load', () async {
    final calls = <_Call>[];
    var precache = true;
    final bloc = FeedBloc(
      repository: RunRepository(
        execute: FunctionsClient(
          call: (name, data) async {
            calls.add(_Call(name, data));
            if (name == 'startRun') {
              final story = (data?['storyId'] as String?) ?? 'story_a';
              // The first background startRun fails; the swipe retry works.
              if (precache && story == 'story_b') {
                precache = false;
                throw const AppFailure(.offline);
              }
              return {
                'runId': 'run_$story',
                'storyId': story,
                'status': 'active',
              };
            }
            if (name == 'loadPlayback') {
              final run = (data?['runId'] as String?) ?? 'run_story_a';
              final story = run.startsWith('run_') ? run.substring(4) : run;
              return _playback(runId: run, storyId: story);
            }
            throw StateError('unexpected $name');
          },
        ).call,
      ),
      catalog: CatalogRepository(
        fetchPublishedIds: () async => ['story_a', 'story_b'],
      ),
      prefetcher: Prefetcher(open: _Slot.new),
      clock: _Clock(),
    );
    addTearDown(bloc.close);
    await _open(bloc, 'story_a');

    bloc.add(const StorySwiped());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.story.storyId == 'story_b',
    );
    expect(bloc.state.playback!.story.storyId, 'story_b');
  });

  test('swiping back restarts that story at the root', () async {
    final calls = <_Call>[];
    final bloc = _bloc(ids: ['story_a', 'story_b', 'story_c'], calls: calls);
    addTearDown(bloc.close);
    await _open(bloc, 'story_a');
    final first = bloc.state.playback!;
    await bloc.stream.firstWhere((state) => state.nextPlayback != null);
    final next = bloc.state.nextPlayback!;

    bloc.add(StorySwiped(playback: next, queue: false));
    await bloc.stream.firstWhere(
      (state) => state.playback!.story.storyId == next.story.storyId,
    );
    final before = _runsFor(calls, 'story_a');

    bloc.add(ReelReplayed(first));
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.story.storyId == 'story_a' &&
          _runsFor(calls, 'story_a') > before,
    );

    expect(bloc.state.playback!.node.nodeId, first.node.nodeId);
    expect(_runsFor(calls, 'story_a'), before + 1);
    expect(
      calls
          .lastWhere(
            (call) =>
                call.name == 'startRun' && call.data?['storyId'] == 'story_a',
          )
          .data?['restart'],
      true,
    );
  });
}

int _runsFor(List<_Call> calls, String storyId) {
  return calls
      .where(
        (call) => call.name == 'startRun' && call.data?['storyId'] == storyId,
      )
      .length;
}

Future<void> _open(FeedBloc bloc, String storyId) async {
  bloc.add(StoryOpened(storyId: storyId));
  await bloc.stream.firstWhere(
    (state) =>
        state.phase == FeedPhase.playing || state.phase == FeedPhase.ending,
  );
}

class _Call {
  const _Call(this.name, this.data);

  final String name;
  final Map<String, dynamic>? data;
}

FeedBloc _bloc({
  required List<String> ids,
  List<_Call>? calls,
  Map<String, bool> endings = const {},
  _Clock? clock,
  Object? error,
  bool commitsEndingWithLine = false,
}) {
  final log = calls ?? <_Call>[];
  return FeedBloc(
    repository: _runs(
      log,
      endings,
      commitsEndingWithLine: commitsEndingWithLine,
    ),
    catalog: CatalogRepository(
      fetchPublishedIds: () async {
        if (error != null) throw error;
        return ids;
      },
    ),
    prefetcher: Prefetcher(open: _Slot.new),
    clock: clock ?? _Clock(),
  );
}

RunRepository _runs(
  List<_Call> calls,
  Map<String, bool> endings, {
  bool commitsEndingWithLine = false,
}) {
  return RunRepository(
    execute: FunctionsClient(
      call: (name, data) async {
        calls.add(_Call(name, data));
        if (name == 'startRun') {
          final story = (data?['storyId'] as String?) ?? 'story_a';
          return {'runId': 'run_$story', 'storyId': story, 'status': 'active'};
        }
        if (name == 'loadPlayback') {
          final run = (data?['runId'] as String?) ?? 'run_story_a';
          final story = run.startsWith('run_') ? run.substring(4) : run;
          return _playback(
            runId: run,
            storyId: story,
            ending: endings[story] ?? false,
          );
        }
        if (name == 'commitChoice' && commitsEndingWithLine) {
          return {
            'playback': _playback(
              runId: 'run_story_a',
              storyId: 'story_a',
              ending: true,
              line: true,
            ),
          };
        }
        throw StateError('unexpected $name');
      },
    ).call,
  );
}

Map<String, dynamic> _playback({
  required String runId,
  required String storyId,
  bool ending = false,
  bool line = false,
}) {
  return {
    'runId': runId,
    'status': ending ? 'ended' : 'active',
    'story': {
      'storyId': storyId,
      'title': 'Story $storyId',
      'authorName': 'Alex Vance',
    },
    'node': {
      'nodeId': ending ? 'node_end' : 'node_001',
      'title': ending ? 'The last door' : 'The first door',
      'isEnding': ending,
      'videoUrl': 'https://example.com/$storyId.mp4',
      'durationSeconds': 10,
      'ttsText': line ? 'What now?' : (ending ? null : 'Enter or climb?'),
      'ttsAudioUrl': line
          ? 'https://example.com/$storyId-end.m4a'
          : (ending ? null : 'https://example.com/$storyId.m4a'),
      'ttsDurationSeconds': line ? 2.5 : (ending ? null : 4.1),
      'videoFrameLastBlurData': 'data:image/webp;base64,abc',
      'endingType': ending ? 'tragic' : null,
    },
    'choices': ending
        ? <Object?>[]
        : [
            {
              'choiceId': 'choice_a',
              'label': 'Go on',
              'targetNodeId': 'node_002',
              'isDefault': true,
              'x': 0.5,
              'y': 0.65,
              'radius': 0.15,
              'targetSecret': false,
              'target': {
                'nodeId': 'node_002',
                'videoUrl': 'https://example.com/$storyId-next.mp4',
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
