import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/features/feed/ending_card.dart';

Future<void> _pump(
  WidgetTester tester, {
  String? rewardCode,
  String? unlockedTitle,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: EndingCard(
          name: 'The door',
          type: 'tragic',
          rewardCode: rewardCode,
          unlockedTitle: unlockedTitle,
          onSeeMap: () {},
          onTryAnotherPath: () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('EndingCard shows the code and Unlocked title', (tester) async {
    await _pump(tester, rewardCode: 'DOOR-7Q2X', unlockedTitle: 'The door');

    expect(find.text('The door'), findsOneWidget);
    expect(find.text('Unlocked The door'), findsOneWidget);
    expect(find.text('DOOR-7Q2X'), findsOneWidget);
  });

  testWidgets('EndingCard hides the reward block without a code', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('The door'), findsOneWidget);
    expect(find.byKey(const ValueKey('reward-code')), findsNothing);
    expect(find.byKey(const ValueKey('unlocked-title')), findsNothing);
  });
}
