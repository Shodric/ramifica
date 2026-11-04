import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/warm_slot.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/feed/node_video.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const _poster = 'data:image/png;base64,$_png';

void main() {
  testWidgets('a wide feed stages the whole clip centered', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bloc = _bloc();
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
    await _pumpUntil(tester, () => bloc.state.phase == FeedPhase.playing);

    // 9:16 fallback (the fake never reports a decoded size): a 450x800
    // stage centered on the 1200x800 screen, shown complete.
    final video = tester.widget<NodeVideo>(find.byType(NodeVideo));
    expect(video.fit, BoxFit.contain);
    expect(tester.getSize(find.byType(NodeVideo)), const Size(450, 800));
    expect(tester.getTopLeft(find.byType(NodeVideo)), const Offset(375, 0));

    // The rail fits in the right margin, beside the video.
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('action-rail'))).dx,
      375 + 450 + 12,
    );

    // Both rings land on the staged picture once the window opens.
    bloc.add(const PauseReached());
    await _pumpUntil(tester, () => bloc.state.phase == FeedPhase.window);
    const stage = Rect.fromLTWH(375, 0, 450, 800);
    for (final id in ['choice_temple', 'choice_ridge']) {
      final center = tester.getCenter(find.byKey(ValueKey('ring-$id')));
      expect(stage.contains(center), isTrue, reason: id);
    }
  });

  testWidgets('letterbox taps do nothing while stage taps pause', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bloc = _bloc();
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
    await _pumpUntil(tester, () => bloc.state.phase == FeedPhase.playing);

    // Left margin: outside the 375..825 stage, the pause stays off.
    await tester.tapAt(const Offset(100, 400));
    await tester.pump();
    expect(bloc.state.userPaused, isFalse);

    await tester.tapAt(const Offset(600, 400));
    await _pumpUntil(tester, () => bloc.state.userPaused);

    // Still paused after another margin tap; the stage tap resumes.
    await tester.tapAt(const Offset(1100, 400));
    await tester.pump();
    expect(bloc.state.userPaused, isTrue);

    await tester.tapAt(const Offset(600, 400));
    await _pumpUntil(tester, () => !bloc.state.userPaused);
  });

  testWidgets('a phone feed keeps the fullscreen cover frame', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bloc = _bloc();
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
    await _pumpUntil(tester, () => bloc.state.phase == FeedPhase.playing);

    final video = tester.widget<NodeVideo>(find.byType(NodeVideo));
    expect(video.fit, BoxFit.cover);
    expect(tester.getSize(find.byType(NodeVideo)), const Size(390, 844));
    expect(tester.getTopLeft(find.byType(NodeVideo)), Offset.zero);
  });
}

/// Pumps until [done] with a bounded loop instead of settling, so the
/// test never waits on unrelated timers or animations.
Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 50 && !done(); i++) {
    await tester.pump();
  }
  expect(done(), isTrue);
}

FeedBloc _bloc() {
  return FeedBloc(
    repository: RunRepository(
      execute: FunctionsClient(
        call: (name, data) async {
          if (name == 'startRun') {
            return {
              'runId': 'run_1',
              'storyId': 'story_temple',
              'status': 'active',
            };
          }
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
              'ttsText': null,
              'ttsAudioUrl': null,
              'ttsDurationSeconds': null,
              'videoFrameLastBlurData': _poster,
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
        },
      ).call,
    ),
    prefetcher: Prefetcher(open: _Slot.new),
  );
}

class _Slot implements WarmSlot {
  @override
  void mount(String url) {}

  @override
  void dispose() {}
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
