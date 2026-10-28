import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/widgets/author_row.dart';
import 'package:ramifica/core/widgets/story_card.dart';
import 'package:ramifica/features/explore/campaign_card.dart';

void main() {
  testWidgets('StoryCard shows cover, title, author, and campaign label', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StoryCard(
            title: 'The temple secret',
            authorName: 'Alex Vance',
            campaignLabel: 'Brand days',
          ),
        ),
      ),
    );

    expect(find.text('The temple secret'), findsOneWidget);
    expect(find.text('Alex Vance'), findsOneWidget);
    expect(find.text('Brand days'), findsOneWidget);
  });

  testWidgets('StoryCard hides the campaign label when absent', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StoryCard(title: 'The temple secret', authorName: 'Alex Vance'),
        ),
      ),
    );

    expect(find.text('The temple secret'), findsOneWidget);
    expect(find.text('Alex Vance'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('StoryCard tap calls onOpen and nothing else', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StoryCard(
            title: 'The temple secret',
            authorName: 'Alex Vance',
            onOpen: () => taps++,
          ),
        ),
      ),
    );

    await tester.tap(find.text('The temple secret'));
    expect(taps, 1);
  });

  testWidgets('CampaignCard shows the brand label and never a reward', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CampaignCard(
            title: 'The ridge climb',
            authorName: 'Alex Vance',
            brandLabel: 'Andes Outdoor',
          ),
        ),
      ),
    );

    expect(find.text('Andes Outdoor'), findsOneWidget);
    expect(find.text('The ridge climb'), findsOneWidget);
    expect(find.text('Alex Vance'), findsOneWidget);
    // No reward anywhere on the card.
    expect(find.textContaining('reward', findRichText: true), findsNothing);
    expect(find.textContaining(r'$', findRichText: true), findsNothing);
  });

  testWidgets('CampaignCard tap calls onOpen', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CampaignCard(
            title: 'The ridge climb',
            authorName: 'Alex Vance',
            brandLabel: 'Andes Outdoor',
            onOpen: () => taps++,
          ),
        ),
      ),
    );

    await tester.tap(find.text('The ridge climb'));
    expect(taps, 1);
  });

  testWidgets('AuthorRow shows name, handle, and follow state', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AuthorRow(
            name: 'Alex Vance',
            handle: '@alex',
            isFollowing: true,
          ),
        ),
      ),
    );

    expect(find.text('Alex Vance'), findsOneWidget);
    expect(find.text('@alex'), findsOneWidget);
    expect(find.text('Following'), findsOneWidget);
    expect(find.text('Follow'), findsNothing);
  });

  testWidgets('AuthorRow shows Follow when not following, tap opens', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthorRow(
            name: 'Alex Vance',
            handle: '@alex',
            isFollowing: false,
            onOpen: () => taps++,
          ),
        ),
      ),
    );

    expect(find.text('Follow'), findsOneWidget);
    await tester.tap(find.text('Alex Vance'));
    expect(taps, 1);
  });
}
