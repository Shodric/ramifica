import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/widgets/lock_mark.dart';
import 'package:ramifica/core/widgets/story_card.dart';
import 'package:ramifica/features/profile/saga_list.dart';

const _stories = [
  SagaStory(
    storyId: 'story_temple',
    title: 'The temple secret',
    authorName: 'Alex Vance',
    unlocked: true,
  ),
  SagaStory(storyId: 'story_ridge', unlocked: false),
  SagaStory(
    storyId: 'story_river',
    title: 'The last crossing',
    authorName: 'Alex Vance',
    unlocked: true,
  ),
];

Future<void> _pump(
  WidgetTester tester,
  List<SagaStory> stories,
  void Function(String storyId) onOpen,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SagaList(stories: stories, onOpen: onOpen)),
    ),
  );
}

void main() {
  testWidgets('SagaList preserves order with locks in place', (tester) async {
    await _pump(tester, _stories, (_) {});

    expect(find.text('The temple secret'), findsOneWidget);
    expect(find.text('The last crossing'), findsOneWidget);
    expect(find.byType(StoryCard), findsNWidgets(2));
    expect(find.byType(LockMark), findsOneWidget);

    final first = tester.getCenter(find.text('The temple secret')).dy;
    final lock = tester.getCenter(find.byType(LockMark)).dy;
    final last = tester.getCenter(find.text('The last crossing')).dy;
    expect(first, lessThan(lock));
    expect(lock, lessThan(last));
  });

  testWidgets('SagaList locked entry shows a lock without its title', (
    tester,
  ) async {
    await _pump(tester, const [
      SagaStory(storyId: 'story_ridge', title: 'Hidden ascent', unlocked: false),
    ], (_) {});

    expect(find.byType(LockMark), findsOneWidget);
    expect(find.text('Hidden ascent'), findsNothing);
    expect(find.byType(StoryCard), findsNothing);
  });

  testWidgets('SagaList tap opens unlocked only, locked tap is a no-op', (
    tester,
  ) async {
    final opened = <String>[];
    await _pump(tester, _stories, opened.add);

    await tester.tap(find.text('The last crossing'));
    expect(opened, ['story_river']);

    await tester.tap(find.byType(LockMark));
    expect(opened, ['story_river']);

    await tester.tap(find.text('The temple secret'));
    expect(opened, ['story_river', 'story_temple']);
  });

  testWidgets('SagaList empty shows text only, no action', (tester) async {
    await _pump(tester, const [], (_) {});

    expect(find.text('No saga stories yet.'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
  });
}
