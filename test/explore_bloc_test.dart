import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/campaign_summary.dart';
import 'package:ramifica/data/models/story_summary.dart';
import 'package:ramifica/data/repositories/catalog_repository.dart';
import 'package:ramifica/data/repositories/follow_repository.dart';
import 'package:ramifica/features/explore/explore_bloc.dart';
import 'package:ramifica/features/explore/explore_event.dart';
import 'package:ramifica/features/explore/explore_state.dart';

void main() {
  group('ExploreBloc', () {
    test('loads stories, featured, campaigns, and follows', () async {
      final bloc = ExploreBloc(
        catalog: _catalog(),
        follows: _follows({'u_author'}),
        uid: 'u_me',
      );
      addTearDown(bloc.close);
      final phases = <ExplorePhase>[];
      final sub = bloc.stream.listen((state) => phases.add(state.phase));
      addTearDown(sub.cancel);

      bloc.add(const CatalogRequested());
      await bloc.stream.firstWhere((state) => state.phase == .loaded);
      await Future<void>.delayed(Duration.zero);

      expect(phases, [ExplorePhase.loading, ExplorePhase.loaded]);
      expect(bloc.state.stories, hasLength(2));
      expect(bloc.state.featuredStory?.storyId, 'story_temple');
      expect(bloc.state.campaigns, hasLength(1));
      expect(bloc.state.campaigns.single.brandLabel, 'Acme');
      expect(bloc.state.followingIds, {'u_author'});
      expect(bloc.state.failure, isNull);
    });

    test('signed out browses without touching follows', () async {
      var calls = 0;
      final bloc = ExploreBloc(
        catalog: _catalog(),
        follows: FollowRepository(
          fetchAuthorIds: (uid) async {
            calls++;
            return {'u_author'};
          },
        ),
      );
      addTearDown(bloc.close);

      bloc.add(const CatalogRequested());
      await bloc.stream.firstWhere((state) => state.phase == .loaded);

      expect(calls, isZero);
      expect(bloc.state.followingIds, isEmpty);
      expect(bloc.state.tabStories, hasLength(2));
    });

    test('a failure shows its phrase', () async {
      final bloc = ExploreBloc(
        catalog: CatalogRepository(
          fetchPublishedIds: () async => throw const AppFailure(.offline),
          fetchPublishedStories: () async =>
              throw const AppFailure(.offline),
        ),
        follows: _follows({}),
        uid: 'u_me',
      );
      addTearDown(bloc.close);

      bloc.add(const CatalogRequested());
      await bloc.stream.firstWhere((state) => state.phase == .failed);

      expect(bloc.state.failure, 'No connection');
      expect(bloc.state.stories, isEmpty);
    });

    test('the following tab keeps only followed authors', () async {
      final bloc = ExploreBloc(
        catalog: _catalog(),
        follows: _follows({'u_author'}),
        uid: 'u_me',
      );
      addTearDown(bloc.close);

      bloc.add(const CatalogRequested());
      await bloc.stream.firstWhere((state) => state.phase == .loaded);
      bloc.add(const CatalogTabSelected(.following));
      await bloc.stream.firstWhere(
        (state) => state.tab == ExploreTab.following,
      );

      expect(bloc.state.tabStories, hasLength(1));
      expect(bloc.state.tabStories.single.storyId, 'story_temple');
      expect(bloc.state.isFollowing('u_author'), isTrue);
      expect(bloc.state.isFollowing('u_other'), isFalse);
    });

    test('the query is held without touching the lists', () async {
      final bloc = ExploreBloc(
        catalog: _catalog(),
        follows: _follows({}),
        uid: 'u_me',
      );
      addTearDown(bloc.close);

      bloc.add(const CatalogRequested());
      await bloc.stream.firstWhere((state) => state.phase == .loaded);
      bloc.add(const QueryChanged('temple'));
      await bloc.stream.firstWhere((state) => state.query == 'temple');

      expect(bloc.state.query, 'temple');
      expect(bloc.state.stories, hasLength(2));
      expect(bloc.state.phase, ExplorePhase.loaded);
    });

    test('a story tap records the pending story', () async {
      final bloc = ExploreBloc(catalog: _catalog(), follows: _follows({}));
      addTearDown(bloc.close);

      bloc.add(const StoryStartRequested('story_temple'));
      await bloc.stream.firstWhere(
        (state) => state.pendingStoryId == 'story_temple',
      );

      expect(bloc.state.pendingStoryId, 'story_temple');
    });

    test('a second load restarts the first', () async {
      final gate = Completer<List<StorySummary>>();
      var calls = 0;
      final bloc = ExploreBloc(
        catalog: CatalogRepository(
          fetchPublishedIds: () async => const ['story_temple'],
          fetchPublishedStories: () async {
            calls++;
            if (calls == 1) return gate.future;
            return _stories();
          },
          fetchActiveCampaigns: () async => const [],
        ),
        follows: _follows({}),
      );
      addTearDown(bloc.close);

      bloc.add(const CatalogRequested());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      bloc.add(const CatalogRequested());
      await bloc.stream.firstWhere((state) => state.phase == .loaded);
      gate.complete(_stories());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bloc.state.stories, hasLength(2));
    });
  });

  group('CatalogRepository', () {
    test('featuredStory picks the flagged story', () async {
      final repository = _catalog();

      expect((await repository.featuredStory())?.storyId, 'story_temple');
    });

    test('featuredStory is null when none is flagged', () async {
      final repository = CatalogRepository(
        fetchPublishedIds: () async => const ['story_plain'],
        fetchPublishedStories: () async => const [
          StorySummary(storyId: 'story_plain', title: 'Plain'),
        ],
      );

      expect(await repository.featuredStory(), isNull);
    });

    test('publishedStories falls back to ids without an injected fetch', () async {
      final repository = CatalogRepository(
        fetchPublishedIds: () async => const ['story_a'],
      );

      expect(await repository.publishedStories(), hasLength(1));
      expect(await repository.activeCampaigns(), isEmpty);
    });

    test('malformed docs never surface raw maps', () {
      expect(
        () => StorySummary.fromDoc('s', {'title': '  '}),
        throwsA(const AppFailure(.invalid)),
      );
      expect(
        () => CampaignSummary.fromDoc('c', {'storyId': 's'}),
        throwsA(const AppFailure(.invalid)),
      );
    });
  });

  group('FollowRepository', () {
    test('blank ids never touch the network', () async {
      var calls = 0;
      final repository = FollowRepository(
        fetchAuthorIds: (uid) async {
          calls++;
          return {uid};
        },
      );

      expect(await repository.followingIds('  '), isEmpty);
      expect(
        await repository.isFollowing(uid: 'u_me', authorId: '  '),
        isFalse,
      );
      expect(calls, isZero);
    });

    test('isFollowing reads the id set', () async {
      final repository = _follows({'u_author'});

      expect(
        await repository.isFollowing(uid: 'u_me', authorId: 'u_author'),
        isTrue,
      );
      expect(
        await repository.isFollowing(uid: 'u_me', authorId: 'u_other'),
        isFalse,
      );
    });
  });
}

CatalogRepository _catalog() {
  return CatalogRepository(
    fetchPublishedIds: () async => const ['story_temple', 'story_ridge'],
    fetchPublishedStories: () async => _stories(),
    fetchActiveCampaigns: () async => const [
      CampaignSummary(
        campaignId: 'camp_acme',
        storyId: 'story_temple',
        brandLabel: 'Acme',
      ),
    ],
  );
}

List<StorySummary> _stories() {
  return const [
    StorySummary(
      storyId: 'story_temple',
      title: 'The temple door',
      authorId: 'u_author',
      authorName: 'Alex Vance',
      featured: true,
    ),
    StorySummary(
      storyId: 'story_ridge',
      title: 'Climb the ridge',
      authorId: 'u_other',
      authorName: 'Sam Ruiz',
    ),
  ];
}

FollowRepository _follows(Set<String> ids) {
  return FollowRepository(fetchAuthorIds: (_) async => ids);
}
