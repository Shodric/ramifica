import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/cue_clock.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/warm_slot.dart';
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
const _poster = 'data:image/png;base64,$_png';

/// Same decoded bytes as [_png] under a different mediatype: the poster
/// decoder only reads past the comma, so this stays a valid image while
/// proving by string equality that First wins over Last.
const _first = 'data:image/jpeg;base64,$_png';

void main() {
  testWidgets('NodeVideo shows the poster before the first frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NodeVideo(
          url: 'https://example.com/video.mp4',
          muted: true,
          play: true,
          onFirstFrame: () {},
          onEnded: () {},
          player: _Clip(),
          poster: _poster,
        ),
      ),
    );
    await tester.pump();

    final image = find.descendant(
      of: find.byType(NodeVideo),
      matching: find.byType(Image),
    );
    expect(image, findsOneWidget);
    final provider = tester.widget<Image>(image).image as MemoryImage;
    expect(provider.bytes, orderedEquals(base64Decode(_png)));
  });

  testWidgets('NodeVideo without a poster keeps the black surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NodeVideo(
          url: 'https://example.com/video.mp4',
          muted: true,
          play: true,
          onFirstFrame: () {},
          onEnded: () {},
          player: _Clip(),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.descendant(of: find.byType(NodeVideo), matching: find.byType(Image)),
      findsNothing,
    );
    final box = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(NodeVideo),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(box.color, RamificaColors.surface);
  });

  testWidgets('FeedView falls back to the last frame blur as the poster', (
    tester,
  ) async {
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

    // The fake never reports ready, so the poster stays up like it does
    // during the real gap between a clip swap and its first frame.
    final video = tester.widget<NodeVideo>(find.byType(NodeVideo));
    expect(video.poster, _poster);
    final image = find.descendant(
      of: find.byType(NodeVideo),
      matching: find.byType(Image),
    );
    expect(image, findsOneWidget);
    final provider = tester.widget<Image>(image).image as MemoryImage;
    expect(provider.bytes, orderedEquals(base64Decode(_png)));
  });

  testWidgets('FeedView prefers the opening frame blur as the poster', (
    tester,
  ) async {
    final bloc = _bloc(first: _first);
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
    expect(video.poster, _first);
    final image = find.descendant(
      of: find.byType(NodeVideo),
      matching: find.byType(Image),
    );
    expect(image, findsOneWidget);
    final provider = tester.widget<Image>(image).image as MemoryImage;
    expect(provider.bytes, orderedEquals(base64Decode(_png)));
  });

  test('PlaybackNode parses the optional opening frame blur', () {
    final node = PlaybackNode.fromJson({
      'nodeId': 'node_001',
      'title': 'The temple door',
      'isEnding': false,
      'videoUrl': 'https://example.com/video.mp4',
      'durationSeconds': 10,
      'videoFrameLastBlurData': _poster,
      'videoFrameFirstBlurData': _first,
    });
    expect(node.videoFrameFirstBlurData, _first);

    final legacy = PlaybackNode.fromJson({
      'nodeId': 'node_001',
      'title': 'The temple door',
      'isEnding': false,
      'videoUrl': 'https://example.com/video.mp4',
      'durationSeconds': 10,
      'videoFrameLastBlurData': _poster,
    });
    expect(legacy.videoFrameFirstBlurData, isNull);
  });
}

/// A clip that never becomes ready, so the poster stays visible.
class _Clip implements ClipPlayer {
  @override
  bool get ready => false;

  @override
  bool get ended => false;

  @override
  Future<void> open({
    required Uri url,
    required bool muted,
    required bool play,
  }) async {}

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  Widget buildView() => const SizedBox.expand();

  @override
  void dispose() {}
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 50 && !done(); i++) {
    await tester.pump();
  }
  expect(done(), isTrue);
}

FeedBloc _bloc({String? first}) {
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
              'videoFrameLastBlurData': _poster,
              'videoFrameFirstBlurData': first,
            },
            'choices': <Map<String, dynamic>>[],
          };
        },
      ).call,
    ),
    prefetcher: Prefetcher(open: _Slot.new),
    clock: _Clock(),
  );
}

class _Slot implements WarmSlot {
  @override
  void mount(String url) {}

  @override
  void dispose() {}
}

class _Clock implements CueClock {
  @override
  void schedule(Duration duration, void Function() fire) {}

  @override
  void cancel() {}
}
