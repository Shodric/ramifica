import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/app.dart';
import 'package:ramifica/core/widgets/failure_text.dart';

void main() {
  testWidgets('opens Feed at /', (tester) async {
    await tester.pumpWidget(const RamificaApp());

    expect(find.text('Feed'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
  });

  testWidgets('opens Sign in at /access', (tester) async {
    await tester.pumpWidget(const RamificaApp(initialRoute: '/access'));

    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('opens Feed at /story/{id}', (tester) async {
    await tester.pumpWidget(
      const RamificaApp(initialRoute: '/story/story_temple'),
    );

    expect(find.text('Feed'), findsOneWidget);
  });

  testWidgets('opens Map at /graph/{id}', (tester) async {
    await tester.pumpWidget(
      const RamificaApp(initialRoute: '/graph/story_temple'),
    );

    expect(find.text('Map'), findsOneWidget);
  });

  testWidgets('opens Explore at /explore', (tester) async {
    await tester.pumpWidget(const RamificaApp(initialRoute: '/explore'));

    expect(find.text('Explore'), findsOneWidget);
  });

  testWidgets('opens Create at /create', (tester) async {
    await tester.pumpWidget(const RamificaApp(initialRoute: '/create'));

    expect(find.text('Create'), findsOneWidget);
  });

  testWidgets('opens Profile at /profile', (tester) async {
    await tester.pumpWidget(const RamificaApp(initialRoute: '/profile'));

    expect(find.text('Profile'), findsOneWidget);
  });

  testWidgets('unknown path says the page does not exist', (tester) async {
    await tester.pumpWidget(const RamificaApp(initialRoute: '/nope'));

    expect(find.text('This page does not exist.'), findsOneWidget);
  });

  testWidgets('FailureText retry sends the tap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FailureText(message: 'Offline', onRetry: () => taps++),
        ),
      ),
    );

    expect(find.text('Offline'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(taps, 1);
  });
}
