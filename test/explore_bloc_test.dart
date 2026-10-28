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

    test('filter matches title case-insensitively without refetching',
        () async {
      var storyCalls = 0;
      var campaignCalls = 0;
      var followCalls = 0;
      final bloc = ExploreBloc(
        catalog: CatalogRepository(
          fetchPublishedIds: () async => const [
            'story_temple',
            'story_ridge',
          ],
          fetchPublishedStories: () async {
            storyCalls++;
            return _stories();
          },
          fetchActiveCampaigns: () async {
            campaignCalls++;
            return const [];
          },
        ),
        follows: FollowRepository(
          fetchAuthorIds: (_) async {
            followCalls++;
            return {'u_author'};
          },
        ),
        uid: 'u_me',
      );
      addTearDown(bloc.close);

      bloc.add(const CatalogRequested());
      await bloc.stream.firstWhere((state) => state.phase == .loaded);
      bloc.add(const QueryChanged('TEMPLE'));
      await bloc.stream.firstWhere((state) => state.query == 'TEMPLE');

      expect(bloc.state.isSearching, isTrue);
      expect(
        bloc.state.filteredStories.map((story) => story.storyId),
        ['story_temple'],
      );
      expect(bloc.state.stories, hasLength(2));
      expect(storyCalls, 1);
      expect(campaignCalls, 1);
      expect(followCalls, 1);
    });

    test('filter matches synopsis and tags', () async {
      final bloc = ExploreBloc(
        catalog: _catalog(),
        follows: _follows({}),
        uid: 'u_me',
      );
      addTearDown(bloc.close);

      bloc.add(const CatalogRequested());
      await bloc.stream.firstWhere((state) => state.phase == .loaded);

      bloc.add(const QueryChanged('jungle'));
      await bloc.stream.firstWhere((state) => state.query == 'jungle');
      expect(
        bloc.state.filteredStories.map((story) => story.storyId),
        ['story_temple'],
      );

      bloc.add(const QueryChanged('myst'));
      await bloc.stream.firstWhere((state) => state.query == 'myst');
      expect(
        bloc.state.filteredStories.map((story) => story.storyId),
        ['story_temple'],
      );

      bloc.add(const QueryChanged('climbing'));
      await bloc.stream.firstWhere((state) => state.query == 'climbing');
      expect(
        bloc.state.filteredStories.map((story) => story.storyId),
        ['story_ridge'],
      );
    });

    test('empty query returns the tab list unfiltered', () async {
      final bloc = ExploreBloc(
        catalog: _catalog(),
        follows: _follows({}),
        uid: 'u_me',
      );
      addTearDown(bloc.close);

      bloc.add(const CatalogRequested());
      await bloc.stream.firstWhere((state) => state.phase == .loaded);
      expect(bloc.state.isSearching, isFalse);
      expect(bloc.state.filteredStories, hasLength(2));

      bloc.add(const QueryChanged('   '));
      await bloc.stream.firstWhere((state) => state.query == '   ');
      expect(bloc.state.isSearching, isFalse);
      expect(bloc.state.filteredStories, hasLength(2));

      bloc.add(const QueryChanged('temple'));
      await bloc.stream.firstWhere((state) => state.query == 'temple');
      expect(bloc.state.filteredStories, hasLength(1));

      bloc.add(const QueryChanged(''));
      await bloc.stream.firstWhere(
        (state) => state.query.isEmpty && state.filteredStories.length == 2,
      );
      expect(bloc.state.filteredStories, hasLength(2));
    });

    test('tab and query combine', () async {
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

      bloc.add(const QueryChanged('temple'));
      await bloc.stream.firstWhere((state) => state.query == 'temple');
      expect(
        bloc.state.filteredStories.map((story) => story.storyId),
        ['story_temple'],
      );

      bloc.add(const QueryChanged('ridge'));
      await bloc.stream.firstWhere((state) => state.query == 'ridge');
      expect(bloc.state.tabStories, hasLength(1));
      expect(bloc.state.filteredStories, isEmpty);

      bloc.add(const CatalogTabSelected(.forYou));
      await bloc.stream.firstWhere((state) => state.tab == ExploreTab.forYou);
      expect(
        bloc.state.filteredStories.map((story) => story.storyId),
        ['story_ridge'],
      );
    });

    test('a story tap makes no repository call', () async {
      var catalogCalls = 0;
      var followCalls = 0;
      final bloc = ExploreBloc(
        catalog: CatalogRepository(
          fetchPublishedIds: () async {
            catalogCalls++;
            return const ['story_temple'];
          },
          fetchPublishedStories: () async {
            catalogCalls++;
            return _stories();
          },
          fetchActiveCampaigns: () async {
            catalogCalls++;
            return const [];
          },
        ),
        follows: FollowRepository(
          fetchAuthorIds: (_) async {
            followCalls++;
            return {'u_author'};
          },
        ),
        uid: 'u_me',
      );
      addTearDown(bloc.close);

      bloc.add(const StoryStartRequested('story_temple'));
      await bloc.stream.firstWhere(
        (state) => state.pendingStoryId == 'story_temple',
      );

      expect(bloc.state.pendingStoryId, 'story_temple');
      expect(catalogCalls, isZero);
      expect(followCalls, isZero);
    });

    test('per-tab empty conditions', () async {
      final bloc = ExploreBloc(catalog: _catalog(), follows: _follows({}));
      addTearDown(bloc.close);

      bloc.add(const CatalogRequested());
      await bloc.stream.firstWhere((state) => state.phase == .loaded);
      expect(bloc.state.filteredStories, hasLength(2));

      bloc.add(const CatalogTabSelected(.following));
      await bloc.stream.firstWhere(
        (state) => state.tab == ExploreTab.following,
      );
      expect(bloc.state.followingStories, isEmpty);
      expect(bloc.state.hasFollowedStories, isFalse);
      expect(bloc.state.tabStories, isEmpty);
      expect(bloc.state.filteredStories, isEmpty);
      expect(bloc.state.isSearching, isFalse);

      bloc.add(const QueryChanged('temple'));
      await bloc.stream.firstWhere((state) => state.query == 'temple');
      expect(bloc.state.filteredStories, isEmpty);
      expect(bloc.state.isSearching, isTrue);

      bloc.add(const CatalogTabSelected(.forYou));
      await bloc.stream.firstWhere((state) => state.tab == ExploreTab.forYou);
      expect(
        bloc.state.filteredStories.map((story) => story.storyId),
        ['story_temple'],
      );

      bloc.add(const QueryChanged('zzz-no-match'));
      await bloc.stream.firstWhere((state) => state.query == 'zzz-no-match');
      expect(bloc.state.tabStories, hasLength(2));
      expect(bloc.state.filteredStories, isEmpty);
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

  group('StorySummary tags', () {
    test('parses tags and trims entries', () {
      final story = StorySummary.fromDoc('s', {
        'title': 'T',
        'tags': [' mystery ', '', 42, 'ruins'],
      });

      expect(story.tags, ['mystery', 'ruins']);
    });

    test('missing or mistyped tags parse to empty', () {
      expect(StorySummary.fromDoc('s', {'title': 'T'}).tags, isEmpty);
      expect(
        StorySummary.fromDoc('s', {'title': 'T', 'tags': 'mystery'}).tags,
        isEmpty,
      );
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

    test('featuredStory prefers the injected single fetch', () async {
      var gridCalls = 0;
      final repository = CatalogRepository(
        fetchPublishedIds: () async => const ['story_grid'],
        fetchPublishedStories: () async {
          gridCalls++;
          return const [
            StorySummary(
              storyId: 'story_grid',
              title: 'Grid pick',
              featured: true,
            ),
          ];
        },
        fetchFeaturedStory: () async => const StorySummary(
          storyId: 'story_server',
          title: 'Server pick',
          featured: true,
        ),
      );

      expect((await repository.featuredStory())?.storyId, 'story_server');
      expect(gridCalls, isZero);
    });

    test('publishedStories keeps the server order', () async {
      final repository = CatalogRepository(
        fetchPublishedIds: () async => const ['story_old', 'story_new'],
        fetchPublishedStories: () async => const [
          StorySummary(storyId: 'story_old', title: 'Older'),
          StorySummary(storyId: 'story_new', title: 'Newer'),
        ],
      );

      final stories = await repository.publishedStories();

      expect(
        [for (final story in stories) story.storyId],
        ['story_old', 'story_new'],
      );
    });

    test('empty states never throw', () async {
      final repository = CatalogRepository(
        fetchPublishedIds: () async => const <String>[],
      );

      expect(await repository.publishedStories(), isEmpty);
      expect(await repository.featuredStory(), isNull);
      expect(await repository.activeCampaigns(), isEmpty);
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
      synopsis: 'A sealed gate in the jungle',
      featured: true,
      tags: ['mystery'],
    ),
    StorySummary(
      storyId: 'story_ridge',
      title: 'Climb the ridge',
      authorId: 'u_other',
      authorName: 'Sam Ruiz',
      synopsis: 'A high mountain path',
      tags: ['climbing'],
    ),
  ];
}

FollowRepository _follows(Set<String> ids) {
  return FollowRepository(fetchAuthorIds: (_) async => ids);
}
