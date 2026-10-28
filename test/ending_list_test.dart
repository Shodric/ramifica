import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/widgets/ending_badge.dart';
import 'package:ramifica/features/profile/ending_list.dart';

const _endings = [
  UnlockedEnding(
    storyId: 'story_temple',
    name: 'The open door',
    type: 'abierto',
  ),
  UnlockedEnding(
    storyId: 'story_river',
    name: 'The last crossing',
    type: 'tragico',
  ),
];

Future<void> _pump(
  WidgetTester tester,
  List<UnlockedEnding> endings,
  void Function(String storyId) onOpen,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: EndingList(endings: endings, onOpen: onOpen)),
    ),
  );
}

void main() {
  testWidgets('EndingList renders a row per ending with badge', (tester) async {
    await _pump(tester, _endings, (_) {});

    expect(find.text('The open door'), findsOneWidget);
    expect(find.text('The last crossing'), findsOneWidget);
    expect(find.byType(EndingBadge), findsNWidgets(2));
  });

  testWidgets('EndingList tap opens the tapped story id', (tester) async {
    final opened = <String>[];
    await _pump(tester, _endings, opened.add);

    await tester.tap(find.text('The last crossing'));
    expect(opened, ['story_river']);

    await tester.tap(find.text('The open door'));
    expect(opened, ['story_river', 'story_temple']);
  });

  testWidgets('EndingList empty shows text only, no action', (tester) async {
    await _pump(tester, const [], (_) {});

    expect(find.text('No endings unlocked yet.'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
  });
}
