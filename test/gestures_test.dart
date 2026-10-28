import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/cue_clock.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/warm_slot.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';

void main() {
  test('the first gesture clears the browser mute', () async {
    final bloc = _bloc();
    addTearDown(bloc.close);
    await _open(bloc);

    expect(bloc.state.muted, isTrue);
    bloc.add(const UserGestured());
    await bloc.stream.first;

    expect(bloc.state.muted, isFalse);
    expect(bloc.state.autoMuted, isFalse);
    expect(bloc.state.phase, FeedPhase.playing);
  });

  test('a gesture never overrides a manual mute', () async {
    final bloc = _bloc();
    addTearDown(bloc.close);
    await _open(bloc);
    bloc.add(const MuteToggled());
    await bloc.stream.first;
    bloc.add(const MuteToggled());
    await bloc.stream.first;

    expect(bloc.state.muted, isTrue);
    bloc.add(const UserGestured());
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.muted, isTrue);
    expect(bloc.state.autoMuted, isFalse);
  });

  test('hiding parks the clip until the next tap', () async {
    final bloc = _bloc();
    addTearDown(bloc.close);
    await _open(bloc);

    bloc.add(const AppHidden());
    await bloc.stream.first;

    expect(bloc.state.phase, FeedPhase.playing);
    expect(bloc.state.hiddenPaused, isTrue);

    // Becoming visible again never resumes on its own.
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.hiddenPaused, isTrue);

    bloc.add(const UserGestured());
    await bloc.stream.first;

    expect(bloc.state.hiddenPaused, isFalse);
    expect(bloc.state.phase, FeedPhase.playing);
  });

  test('hiding mid-window does nothing', () async {
    final clock = _Clock();
    final bloc = _bloc(clock: clock);
    addTearDown(bloc.close);
    await _open(bloc);

    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
    clock.fire();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);

    bloc.add(const AppHidden());
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.phase, FeedPhase.window);
    expect(bloc.state.hiddenPaused, isFalse);
  });

  test('a hidden clip resumes the closing line on tap', () async {
    final clock = _Clock();
    final bloc = _bloc(clock: clock, commitsEndingWithLine: true);
    addTearDown(bloc.close);
    await _open(bloc);

    bloc.add(const PauseReached());
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.speaking);
    clock.fire();
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.window);
    bloc.add(const HoldStarted('choice_a'));
    await bloc.stream.firstWhere((state) => state.phase == FeedPhase.holding);
    bloc.add(const HoldCompleted());
    await bloc.stream.firstWhere(
      (state) =>
          state.phase == FeedPhase.playing &&
          state.playback!.node.isEnding,
    );
    bloc.add(const PauseReached());
    await bloc.stream.firstWhere(
      (state) => state.phase == FeedPhase.ending && state.endingSpeaking,
    );

    bloc.add(const AppHidden());
    await bloc.stream.first;
    expect(bloc.state.hiddenPaused, isTrue);

    // The tap resumes the line from the start; the card waits for the cue.
    bloc.add(const UserGestured());
    await bloc.stream.firstWhere(
      (state) => state.phase == FeedPhase.ending && !state.hiddenPaused,
    );
    expect(bloc.state.endingSpeaking, isTrue);
    expect(clock.scheduled, isNotNull);

    clock.fire();
    await bloc.stream.firstWhere(
      (state) => state.phase == FeedPhase.ending && !state.endingSpeaking,
    );
  });
}

Future<void> _open(FeedBloc bloc) async {
  bloc.add(const StoryOpened(storyId: 'story_a'));
  await bloc.stream.firstWhere((state) => state.phase == FeedPhase.playing);
}

FeedBloc _bloc({_Clock? clock, bool commitsEndingWithLine = false}) {
  return FeedBloc(
    repository: RunRepository(
      functions: FunctionsClient(
        call: (name, data) async {
          if (name == 'startRun') {
            return {'runId': 'run_story_a', 'storyId': 'story_a', 'status': 'active'};
          }
          if (name == 'loadPlayback') {
            return _playback();
          }
          if (name == 'commitChoice' && commitsEndingWithLine) {
            return {'playback': _endingWithLine()};
          }
          throw StateError('unexpected $name');
        },
      ),
    ),
    prefetcher: Prefetcher(open: _Slot.new),
    clock: clock ?? _Clock(),
  );
}

Map<String, dynamic> _playback() {
  return {
    'runId': 'run_story_a',
    'status': 'active',
    'story': {
      'storyId': 'story_a',
      'title': 'Story A',
      'authorName': 'Alex Vance',
    },
    'node': {
      'nodeId': 'node_001',
      'title': 'The first door',
      'isEnding': false,
      'videoUrl': 'https://example.com/a.mp4',
      'durationSeconds': 10,
      'pauseAtSeconds': 9.967,
      'windowSeconds': 6,
      'ttsText': 'Enter or climb?',
      'ttsAudioUrl': 'https://example.com/a.m4a',
      'ttsDurationSeconds': 4.1,
      'videoFrameLastBlurData': 'data:image/webp;base64,abc',
    },
    'choices': [
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
          'videoUrl': 'https://example.com/a-next.mp4',
        },
      },
    ],
  };
}

Map<String, dynamic> _endingWithLine() {
  return {
    'runId': 'run_story_a',
    'status': 'ended',
    'story': {
      'storyId': 'story_a',
      'title': 'Story A',
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
      'ttsText': 'What now?',
      'ttsAudioUrl': null,
      'ttsDurationSeconds': 2.5,
      'videoFrameLastBlurData': 'data:image/webp;base64,abc',
      'endingName': 'The door',
      'endingType': 'tragic',
    },
    'choices': const [],
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
