import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/repositories/follow_repository.dart';

void main() {
  group('FollowRepository.followingStories', () {
    test('blank uid returns empty without touching the network', () async {
      var idCalls = 0;
      var docCalls = 0;
      final repository = FollowRepository(
        fetchAuthorIds: (uid) async {
          idCalls++;
          return {uid};
        },
        fetchStoryDocs: (authorIds) async {
          docCalls++;
          return [for (final id in authorIds) _doc(id, 1)];
        },
      );

      expect(await repository.followingStories('  '), isEmpty);
      expect(idCalls, isZero);
      expect(docCalls, isZero);
    });

    test('empty follows return empty without reading stories', () async {
      var docCalls = 0;
      final repository = FollowRepository(
        fetchAuthorIds: (_) async => const <String>{},
        fetchStoryDocs: (_) async {
          docCalls++;
          return const [];
        },
      );

      expect(await repository.followingStories('u_me'), isEmpty);
      expect(docCalls, isZero);
    });

    test('no story fetcher returns empty', () async {
      final repository = FollowRepository(
        fetchAuthorIds: (_) async => {'u_author'},
      );

      expect(await repository.followingStories('u_me'), isEmpty);
    });

    test('ten ids read in one batch', () async {
      final seen = <List<String>>[];
      final repository = FollowRepository(
        fetchAuthorIds: (_) async => {for (var i = 0; i < 10; i++) 'u_$i'},
        fetchStoryDocs: (authorIds) async {
          seen.add(authorIds);
          return const [];
        },
      );

      await repository.followingStories('u_me');
      expect(seen, hasLength(1));
      expect(seen.single, hasLength(10));
    });

    test('eleven ids read in batches of ten and one', () async {
      final seen = <List<String>>[];
      final repository = FollowRepository(
        fetchAuthorIds: (_) async => {for (var i = 0; i < 11; i++) 'u_$i'},
        fetchStoryDocs: (authorIds) async {
          seen.add(authorIds);
          return const [];
        },
      );

      await repository.followingStories('u_me');
      expect(seen, hasLength(2));
      expect(seen[0], hasLength(10));
      expect(seen[1], hasLength(1));
      expect(
        {...seen[0], ...seen[1]},
        {for (var i = 0; i < 11; i++) 'u_$i'},
      );
    });

    test('twenty-five ids read in batches of ten, ten, and five', () async {
      final seen = <List<String>>[];
      final repository = FollowRepository(
        fetchAuthorIds: (_) async => {for (var i = 0; i < 25; i++) 'u_$i'},
        fetchStoryDocs: (authorIds) async {
          seen.add(authorIds);
          return const [];
        },
      );

      await repository.followingStories('u_me');
      expect(seen.map((batch) => batch.length), [10, 10, 5]);
      expect(
        {for (final batch in seen) ...batch},
        {for (var i = 0; i < 25; i++) 'u_$i'},
      );
    });

    test('batches merge newest-first; untimestamped sort last', () async {
      final repository = FollowRepository(
        fetchAuthorIds: (_) async => {'u_a', 'u_b'},
        fetchStoryDocs: (authorIds) async {
          return [
            if (authorIds.contains('u_a')) ...[
              _doc('old', 1, author: 'u_a'),
              _doc('new', 3),
            ],
            if (authorIds.contains('u_b')) ...[
              _doc('mid', 2),
              _doc('undated', null),
              _badDoc('broken'),
            ],
          ];
        },
      );

      final stories = await repository.followingStories('u_me');
      expect(
        [for (final story in stories) story.storyId],
        ['new', 'mid', 'old', 'undated'],
      );
    });

    test('a failing batch does not kill the other batches', () async {
      final repository = FollowRepository(
        fetchAuthorIds: (_) async => {
          for (var i = 0; i < 21; i++) 'u_$i',
        },
        fetchStoryDocs: (authorIds) async {
          // 'u_9' sorts into the trailing single-id batch, so exactly one
          // story is lost when its batch fails.
          if (authorIds.contains('u_9')) throw Exception('boom');
          return [for (final id in authorIds) _doc('s_$id', 1)];
        },
      );

      final stories = await repository.followingStories('u_me');
      expect(stories, hasLength(20));
      expect(
        {for (final story in stories) story.storyId},
        {for (var i = 0; i < 21; i++) 's_u_$i'}..remove('s_u_9'),
      );
    });

    test('follow lists cap at ten batches of ten', () async {
      var calls = 0;
      final sent = <String>[];
      final repository = FollowRepository(
        fetchAuthorIds: (_) async => {for (var i = 0; i < 105; i++) 'u_$i'},
        fetchStoryDocs: (authorIds) async {
          calls++;
          sent.addAll(authorIds);
          return const [];
        },
      );

      await repository.followingStories('u_me');
      expect(calls, FollowRepository.maxAuthorBatches);
      expect(sent, hasLength(100));
    });
  });
}

FollowStoryDoc _doc(String id, int? publishedAtMs, {String author = 'u_a'}) {
  final data = <String, dynamic>{'title': 'title $id', 'authorId': author};
  final publishedAt = publishedAtMs;
  if (publishedAt != null) data['publishedAt'] = publishedAt;
  return FollowStoryDoc(id, data);
}

FollowStoryDoc _badDoc(String id) {
  return FollowStoryDoc(id, {'authorId': 'u_b'});
}
