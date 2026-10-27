import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/app.dart';
import 'package:ramifica/features/create/create_view.dart';
import 'package:ramifica/features/explore/explore_view.dart';
import 'package:ramifica/features/graph/graph_view.dart';
import 'package:ramifica/features/profile/profile_view.dart';

void main() {
  testWidgets('opens Sign in at / when there is no session', (tester) async {
    await tester.pumpWidget(const RamificaApp());

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Feed'), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('opens Sign in at /access', (tester) async {
    await tester.pumpWidget(const RamificaApp(initialRoute: '/access'));

    expect(find.text('Sign in'), findsWidgets);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Continue with Google'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('opens Sign in at /story/{id} when there is no session', (
    tester,
  ) async {
    await tester.pumpWidget(
      const RamificaApp(initialRoute: '/story/story_temple'),
    );

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Feed'), findsNothing);
  });

  testWidgets('opens Map at /graph/{id}', (tester) async {
    await tester.pumpWidget(
      const RamificaApp(initialRoute: '/graph/story_temple'),
    );

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Map'), findsNWidgets(2));
    expect(
      tester.widget<GraphView>(find.byType(GraphView)).storyId,
      'story_temple',
    );
  });

  testWidgets('opens Explore at /explore', (tester) async {
    await tester.pumpWidget(const RamificaApp(initialRoute: '/explore'));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(ExploreView), findsOneWidget);
    expect(find.text('Explore'), findsNWidgets(2));
  });

  testWidgets('opens Create at /create', (tester) async {
    await tester.pumpWidget(const RamificaApp(initialRoute: '/create'));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(CreateView), findsOneWidget);
    expect(find.text('Create'), findsOneWidget);
  });

  testWidgets('opens Profile at /profile', (tester) async {
    await tester.pumpWidget(const RamificaApp(initialRoute: '/profile'));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(ProfileView), findsOneWidget);
    expect(find.text('Profile'), findsNWidgets(2));
  });

  testWidgets('unknown path says the page does not exist', (tester) async {
    await tester.pumpWidget(const RamificaApp(initialRoute: '/nope'));

    expect(find.text('This page does not exist.'), findsOneWidget);
  });
}
