import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/playback.dart';
import 'package:ramifica/features/feed/feed_pager.dart';

void main() {
  testWidgets('the next reel is built before the swipe', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StoryPager(
          reels: [_reel('a', 'Alpha'), _reel('b', 'Beta')],
          index: 0,
          paging: true,
          onSettled: (_) => true,
          pageBuilder: (playback, active, loop) => Text(playback.story.title),
        ),
      ),
    );

    expect(find.text('Alpha', skipOffstage: false), findsOneWidget);
    expect(find.text('Beta', skipOffstage: false), findsNWidgets(2));
  });

  testWidgets('swiping down settles on the previous reel', (tester) async {
    final landed = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: StoryPager(
          reels: [_reel('a', 'Alpha'), _reel('b', 'Beta')],
          index: 1,
          paging: true,
          onSettled: (index) {
            landed.add(index);
            return true;
          },
          pageBuilder: (playback, active, loop) => Text(playback.story.title),
        ),
      ),
    );

    await tester.drag(find.byType(PageView), const Offset(0, 500));
    await tester.pumpAndSettle();

    expect(landed, [0]);
  });

  testWidgets('swiping up from the last reel wraps to the first', (
    tester,
  ) async {
    final landed = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: StoryPager(
          reels: [_reel('a', 'Alpha'), _reel('b', 'Beta'), _reel('c', 'Gamma')],
          index: 2,
          paging: true,
          onSettled: (index) {
            landed.add(index);
            return true;
          },
          pageBuilder: (playback, active, loop) => Text(playback.story.title),
        ),
      ),
    );

    await tester.drag(find.byType(PageView), const Offset(0, -500));
    await tester.pumpAndSettle();

    expect(landed, [0]);
    expect(_page(tester), 1);
  });

  testWidgets('swiping down from the first reel wraps to the last', (
    tester,
  ) async {
    final landed = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: StoryPager(
          reels: [_reel('a', 'Alpha'), _reel('b', 'Beta'), _reel('c', 'Gamma')],
          index: 0,
          paging: true,
          onSettled: (index) {
            landed.add(index);
            return true;
          },
          pageBuilder: (playback, active, loop) => Text(playback.story.title),
        ),
      ),
    );

    await tester.drag(find.byType(PageView), const Offset(0, 500));
    await tester.pumpAndSettle();

    expect(landed, [2]);
    expect(_page(tester), 3);
  });

  testWidgets('the open reel stays put when the second story arrives', (
    tester,
  ) async {
    Future<void> pump(List<Playback> reels) {
      return tester.pumpWidget(
        MaterialApp(
          home: StoryPager(
            reels: reels,
            index: 0,
            paging: true,
            onSettled: (_) => true,
            pageBuilder: (playback, active, loop) => Text(playback.story.title),
          ),
        ),
      );
    }

    await pump([_reel('a', 'Alpha')]);
    expect(find.text('Alpha'), findsOneWidget);

    await pump([_reel('a', 'Alpha'), _reel('b', 'Beta')]);
    await tester.pump();

    expect(find.text('Alpha'), findsOneWidget);
    expect(_page(tester), 1);
  });
}

double _page(WidgetTester tester) {
  return tester.widget<PageView>(find.byType(PageView)).controller!.page!;
}

Playback _reel(String id, String title) {
  return Playback(
    runId: 'run_$id',
    status: .active,
    story: PlaybackStory(storyId: id, title: title, authorName: 'Ada'),
    node: PlaybackNode(
      nodeId: 'node_$id',
      title: title,
      isEnding: false,
      videoUrl: 'https://example.com/$id.mp4',
      durationSeconds: 4,
      videoFrameLastBlurData: 'data:image/webp;base64,abc',
    ),
    choices: const [],
  );
}
