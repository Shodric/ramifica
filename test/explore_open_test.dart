import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/campaign_summary.dart';
import 'package:ramifica/data/models/story_summary.dart';
import 'package:ramifica/data/repositories/catalog_repository.dart';
import 'package:ramifica/data/repositories/follow_repository.dart';
import 'package:ramifica/features/explore/explore_bloc.dart';
import 'package:ramifica/features/explore/explore_state.dart';
import 'package:ramifica/features/explore/explore_view.dart';

void main() {
  group('ExploreView search and open', () {
    testWidgets('typing filters the list; clearing restores it', (tester) async {
      final bloc = _bloc();
      addTearDown(bloc.close);
      await _pump(tester, bloc);

      // The temple story stays visible throughout: it is the unfiltered
      // featured pick, so only the ridge row is filter-sensitive.
      expect(find.text('The temple door'), findsWidgets);
      expect(find.text('Climb the ridge'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('exploreSearch')), 'temple');
      await tester.pump();

      expect(bloc.state.query, 'temple');
      expect(find.text('The temple door'), findsWidgets);
      expect(find.text('Climb the ridge'), findsNothing);

      await tester.enterText(find.byKey(const Key('exploreSearch')), '');
      await tester.pump();

      expect(find.text('The temple door'), findsWidgets);
      expect(find.text('Climb the ridge'), findsOneWidget);
    });

    testWidgets('synopsis matches keep the story', (tester) async {
      final bloc = _bloc();
      addTearDown(bloc.close);
      await _pump(tester, bloc);

      await tester.enterText(
        find.byKey(const Key('exploreSearch')),
        'mountain',
      );
      await tester.pump();

      expect(find.text('Climb the ridge'), findsOneWidget);
    });

    testWidgets('a search with no matches shows the no-results state', (
      tester,
    ) async {
      final bloc = _bloc(promos: false);
      addTearDown(bloc.close);
      await _pump(tester, bloc);

      await tester.enterText(find.byKey(const Key('exploreSearch')), 'zzz');
      await tester.pump();

      expect(
        find.text('No stories match your search. Try another search.'),
        findsOneWidget,
      );
      expect(find.text('Climb the ridge'), findsNothing);
    });

    testWidgets('story tap records pending and fires the callback, no run', (
      tester,
    ) async {
      final bloc = _bloc();
      addTearDown(bloc.close);
      final opened = <String>[];
      await _pump(tester, bloc, onStoryOpen: opened.add);

      await tester.tap(find.text('Climb the ridge'));
      await tester.pump();

      expect(opened, ['story_ridge']);
      expect(bloc.state.pendingStoryId, 'story_ridge');
    });

    testWidgets('following empty state offers browse back to For you', (
      tester,
    ) async {
      final bloc = _bloc();
      addTearDown(bloc.close);
      await _pump(tester, bloc);

      await tester.tap(find.text('Following'));
      await tester.pump();

      expect(
        find.text('Stories from people you follow show up here.'),
        findsOneWidget,
      );
      expect(find.text('Browse stories'), findsOneWidget);

      await tester.tap(find.text('Browse stories'));
      await tester.pump();

      expect(bloc.state.tab, ExploreTab.forYou);
      expect(find.text('Climb the ridge'), findsOneWidget);
    });

    testWidgets('following with a follow shows that author only', (
      tester,
    ) async {
      final bloc = _bloc(follows: {'u_author'});
      addTearDown(bloc.close);
      await _pump(tester, bloc);

      await tester.tap(find.text('Following'));
      await tester.pump();

      expect(find.text('Alex Vance'), findsOneWidget);
      expect(find.text('Sam Ruiz'), findsNothing);
    });

    testWidgets('following search with no matches shows no-results', (
      tester,
    ) async {
      final bloc = _bloc(follows: {'u_author'});
      addTearDown(bloc.close);
      await _pump(tester, bloc);

      await tester.tap(find.text('Following'));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('exploreSearch')), 'zzz');
      await tester.pump();

      expect(
        find.text('No stories match your search. Try another search.'),
        findsOneWidget,
      );
      expect(find.text('Browse stories'), findsNothing);
    });
  });
}

/// Pumps the view and lets the initial [CatalogRequested] load finish.
Future<void> _pump(
  WidgetTester tester,
  ExploreBloc bloc, {
  void Function(String storyId)? onStoryOpen,
  void Function(String authorId)? onAuthorOpen,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ExploreView(
        bloc: bloc,
        uid: 'u_me',
        onStoryOpen: onStoryOpen,
        onAuthorOpen: onAuthorOpen,
      ),
    ),
  );
  await bloc.stream.firstWhere((state) => state.phase == ExplorePhase.loaded);
  await tester.pump();
}

ExploreBloc _bloc({Set<String> follows = const {}, bool promos = true}) {
  final temple = StorySummary(
    storyId: 'story_temple',
    title: 'The temple door',
    authorId: 'u_author',
    authorName: 'Alex Vance',
    synopsis: 'A sealed gate beneath the dunes.',
    featured: promos,
  );
  const ridge = StorySummary(
    storyId: 'story_ridge',
    title: 'Climb the ridge',
    authorId: 'u_other',
    authorName: 'Sam Ruiz',
    synopsis: 'A mountain trek at dawn.',
  );
  return ExploreBloc(
    catalog: CatalogRepository(
      fetchPublishedIds: () async => const ['story_temple', 'story_ridge'],
      fetchPublishedStories: () async => [temple, ridge],
      fetchActiveCampaigns: () async => [
        if (promos)
          const CampaignSummary(
            campaignId: 'camp_acme',
            storyId: 'story_temple',
            brandLabel: 'Acme',
          ),
      ],
    ),
    follows: FollowRepository(fetchAuthorIds: (_) async => follows),
    uid: 'u_me',
  );
}
