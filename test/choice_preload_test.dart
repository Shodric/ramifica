import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/cue_clock.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/warm_slot.dart';
import 'package:ramifica/data/models/playback.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';

const _current = 'https://example.com/video.mp4';
const _temple = 'https://example.com/next.mp4';
const _ridge = 'https://example.com/ridge.mp4';

void main() {
  test('entering the window warms every choice target', () async {
    final mounted = <String>[];
    final clock = _Clock();
    final bloc = _bloc(clock, mounted);
    addTearDown(bloc.close);
    await _open(bloc);

    // Drop everything warmed at load so only the window preload remains.
    bloc.prefetcher.clear();
    mounted.clear();

    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
    clock.fire();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    expect(mounted, contains(_current));
    expect(mounted, contains(_temple));
    expect(mounted, contains(_ridge));
    expect(bloc.prefetcher.urls, contains(_temple));
    expect(bloc.prefetcher.urls, contains(_ridge));
  });

  test('secret targets are skipped by the window preload', () async {
    final mounted = <String>[];
    final bloc = _bloc(_Clock(), mounted, secretRidge: true, voice: false);
    addTearDown(bloc.close);
    await _open(bloc);

    bloc.prefetcher.clear();
    mounted.clear();

    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    expect(mounted, contains(_current));
    expect(mounted, contains(_temple));
    expect(mounted, isNot(contains(_ridge)));
    expect(bloc.prefetcher.urls, [_current, _temple]);
  });

  test('empty targets are skipped by the window preload', () async {
    final mounted = <String>[];
    final bloc = FeedBloc(
      repository: RunRepository(
        execute: (_, _) async => throw StateError('unused in preview'),
      ),
      prefetcher: Prefetcher(open: () => _Slot(mounted)),
      previewPlayback: _previewPlayback(),
    );
    addTearDown(bloc.close);
    expect(bloc.state.phase, FeedPhase.playing);

    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    expect(mounted, contains(_current));
    expect(mounted, contains(_temple));
    expect(mounted, isNot(contains('')));
    expect(mounted, isNot(contains('   ')));
    expect(bloc.prefetcher.urls, contains(_current));
    expect(bloc.prefetcher.urls, contains(_temple));
    expect(bloc.prefetcher.urls, hasLength(2));
  });

  test('hold-start still promotes the held clip', () async {
    final mounted = <String>[];
    final bloc = _bloc(_Clock(), mounted, voice: false);
    addTearDown(bloc.close);
    await _open(bloc);
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    bloc.add(const HoldStarted('choice_ridge'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);

    expect(bloc.state.holdChoiceId, 'choice_ridge');
    expect(bloc.prefetcher.urls.last, _ridge);
  });

  test('a failing preload never surfaces into bloc state', () async {
    var failOpen = false;
    final bloc = FeedBloc(
      repository: RunRepository(
        execute: (name, data) => _execute(name, data, voice: false),
      ),
      prefetcher: Prefetcher(
        open: () {
          if (failOpen) throw StateError('slots unavailable');
          return _Slot(<String>[]);
        },
      ),
      clock: _Clock(),
    );
    addTearDown(bloc.close);
    await _open(bloc);

    bloc.prefetcher.clear();
    failOpen = true;

    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    expect(bloc.state.phase, FeedPhase.window);
    expect(bloc.state.playback, isNotNull);
    expect(bloc.state.failure, isNull);
  });
}

Future<void> _open(FeedBloc bloc) async {
  bloc.add(const StoryOpened(storyId: 'story_temple'));
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
}

FeedBloc _bloc(
  _Clock clock,
  List<String> mounted, {
  bool secretRidge = false,
  bool voice = true,
}) {
  return FeedBloc(
    repository: RunRepository(
      execute: (name, data) =>
          _execute(name, data, secretRidge: secretRidge, voice: voice),
    ),
    prefetcher: Prefetcher(open: () => _Slot(mounted)),
    clock: clock,
  );
}

Future<Map<String, dynamic>> _execute(
  String name,
  Map<String, dynamic> data, {
  bool secretRidge = false,
  bool voice = true,
}) async {
  if (name == 'startRun') {
    return {'runId': 'run_1', 'storyId': 'story_temple', 'status': 'active'};
  }
  return _playback(secretRidge: secretRidge, voice: voice);
}

Map<String, dynamic> _playback({
  required bool secretRidge,
  required bool voice,
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
      'nodeId': 'node_001',
      'title': 'The temple door',
      'isEnding': false,
      'videoUrl': _current,
      'durationSeconds': 10,
      'ttsText': voice ? 'Enter or climb?' : null,
      'ttsAudioUrl': voice ? 'https://example.com/voice.m4a' : null,
      'ttsDurationSeconds': voice ? 4.1 : null,
      'videoFrameLastBlurData': 'data:image/png;base64,AAAA',
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
        'target': {'nodeId': 'node_002', 'videoUrl': _temple},
      },
      if (secretRidge)
        {
          'choiceId': 'choice_ridge',
          'label': 'Climb the ridge',
          'targetNodeId': 'node_003',
          'isDefault': false,
          'x': 0.72,
          'y': 0.58,
          'radius': 0.12,
          'targetSecret': true,
        }
      else
        {
          'choiceId': 'choice_ridge',
          'label': 'Climb the ridge',
          'targetNodeId': 'node_003',
          'isDefault': false,
          'x': 0.72,
          'y': 0.58,
          'radius': 0.12,
          'targetSecret': false,
          'target': {'nodeId': 'node_003', 'videoUrl': _ridge},
        },
    ],
  };
}

/// A preview scene with one empty and one whitespace target URL next to
/// a valid one. Built directly because JSON rejects empty URLs.
Playback _previewPlayback() {
  return const Playback(
    runId: 'run_preview',
    status: RunStatus.active,
    story: PlaybackStory(
      storyId: 'story_preview',
      title: 'Preview',
      authorName: 'Alex Vance',
    ),
    node: PlaybackNode(
      nodeId: 'node_001',
      title: 'The temple door',
      isEnding: false,
      videoUrl: _current,
      durationSeconds: 10,
      videoFrameLastBlurData: 'data:image/png;base64,AAAA',
    ),
    choices: [
      PlaybackChoice(
        choiceId: 'choice_temple',
        label: 'Enter the temple',
        targetNodeId: 'node_002',
        isDefault: true,
        x: 0.25,
        y: 0.55,
        radius: 0.12,
        targetSecret: false,
        target: PlaybackTarget(nodeId: 'node_002', videoUrl: _temple),
      ),
      PlaybackChoice(
        choiceId: 'choice_empty',
        label: 'Empty',
        targetNodeId: 'node_003',
        isDefault: false,
        x: 0.5,
        y: 0.5,
        radius: 0.1,
        targetSecret: false,
        target: PlaybackTarget(nodeId: 'node_003', videoUrl: ''),
      ),
      PlaybackChoice(
        choiceId: 'choice_blank',
        label: 'Blank',
        targetNodeId: 'node_004',
        isDefault: false,
        x: 0.7,
        y: 0.5,
        radius: 0.1,
        targetSecret: false,
        target: PlaybackTarget(nodeId: 'node_004', videoUrl: '   '),
      ),
    ],
  );
}

class _Slot implements WarmSlot {
  _Slot(this.mounted);

  final List<String> mounted;

  @override
  void mount(String url) => mounted.add(url);

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
