import 'support/create_repository_harness.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';

MapEntry<String, Map<String, dynamic>> _storyDoc(
  String id, {
  String title = '',
  String status = 'draft',
  int? updatedMillis,
}) {
  return MapEntry(id, {
    'authorId': 'uid_1',
    'title': title,
    'status': status,
    if (updatedMillis case final ms) 'updatedAt': ms,
  });
}

void main() {
  group('fetchAuthorStories', () {
    test('lists newest first and skips malformed docs', () async {
      final repository = testCreateRepository(
        createDraftDoc: ({required authorId, required title}) async =>
            'story_1',
        fetchStoryDoc: (_) async => null,
        fetchNodeDocs: (_) async => const [],
        callFunction: (_, _) async => <String, dynamic>{},
        fetchAuthorStoryDocs: ({required authorId}) async => [
          _storyDoc(
            'old',
            title: 'Old',
            status: 'published',
            updatedMillis: 1000,
          ),
          _storyDoc('new', title: 'New', updatedMillis: 2000),
          _storyDoc('nodate', title: 'No date'),
          const MapEntry('bad', {'title': 42}),
        ],
      );

      final stories = await repository.fetchAuthorStories(authorId: 'uid_1');

      expect(stories.map((s) => s.storyId), ['new', 'old', 'nodate']);
      expect(stories[1].status, 'published');
      expect(stories.first.updatedAt?.millisecondsSinceEpoch, 2000);
    });

    test('blank author throws without calling', () async {
      var called = false;
      final repository = testCreateRepository(
        createDraftDoc: ({required authorId, required title}) async =>
            'story_1',
        fetchStoryDoc: (_) async => null,
        fetchNodeDocs: (_) async => const [],
        callFunction: (_, _) async => <String, dynamic>{},
        fetchAuthorStoryDocs: ({required authorId}) async {
          called = true;
          return const [];
        },
      );

      await expectLater(
        repository.fetchAuthorStories(authorId: '  '),
        throwsA(const AppFailure(.invalid)),
      );
      expect(called, isFalse);
    });

    test('no seam returns empty', () async {
      final repository = testCreateRepository(
        createDraftDoc: ({required authorId, required title}) async =>
            'story_1',
        fetchStoryDoc: (_) async => null,
        fetchNodeDocs: (_) async => const [],
        callFunction: (_, _) async => <String, dynamic>{},
      );

      expect(await repository.fetchAuthorStories(authorId: 'uid_1'), isEmpty);
    });

    test('attaches scene and ending counts', () async {
      final repository = testCreateRepository(
        createDraftDoc: ({required authorId, required title}) async =>
            'story_1',
        fetchStoryDoc: (_) async => null,
        fetchNodeDocs: (storyId) async => storyId == 'with-nodes'
            ? const [
                MapEntry('node_1', {'title': 'Root'}),
                MapEntry('node_2', {'title': 'Leaf', 'isEnding': true}),
              ]
            : const [],
        callFunction: (_, _) async => <String, dynamic>{},
        fetchAuthorStoryDocs: ({required authorId}) async => [
          _storyDoc('with-nodes', title: 'Full', updatedMillis: 2000),
          _storyDoc('empty', title: 'Empty', updatedMillis: 1000),
        ],
      );

      final stories = await repository.fetchAuthorStories(authorId: 'uid_1');

      expect(stories.map((s) => s.storyId), ['with-nodes', 'empty']);
      expect(stories[0].nodeCount, 2);
      expect(stories[0].endingCount, 1);
      expect(stories[1].nodeCount, 0);
      expect(stories[1].endingCount, 0);
    });

    test('unreadable nodes keep unknown counts', () async {
      final repository = testCreateRepository(
        createDraftDoc: ({required authorId, required title}) async =>
            'story_1',
        fetchStoryDoc: (_) async => null,
        fetchNodeDocs: (_) async => throw const AppFailure(.offline),
        callFunction: (_, _) async => <String, dynamic>{},
        fetchAuthorStoryDocs: ({required authorId}) async => [
          _storyDoc('a', title: 'A'),
        ],
      );

      final stories = await repository.fetchAuthorStories(authorId: 'uid_1');

      expect(stories, hasLength(1));
      expect(stories.single.nodeCount, isNull);
      expect(stories.single.endingCount, isNull);
    });
  });

  group('StoriesRequested', () {
    test('loads the creations list', () async {
      final repository = testCreateRepository(
        createDraftDoc: ({required authorId, required title}) async =>
            'story_1',
        fetchStoryDoc: (_) async => null,
        fetchNodeDocs: (_) async => const [],
        callFunction: (_, _) async => <String, dynamic>{},
        fetchAuthorStoryDocs: ({required authorId}) async => [
          _storyDoc('a', title: 'A', updatedMillis: 1000),
          _storyDoc('b', title: 'B', updatedMillis: 2000),
        ],
      );
      final bloc = CreateBloc(repository: repository);
      addTearDown(bloc.close);

      bloc.add(const StoriesRequested(authorId: 'uid_1'));
      final state = await bloc.stream.firstWhere((s) => s.stories.isNotEmpty);

      expect(state.stories.map((s) => s.storyId), ['b', 'a']);
      expect(state.failure, isNull);
    });

    test('creating a draft upserts it into the list', () async {
      final repository = testCreateRepository(
        createDraftDoc: ({required authorId, required title}) async =>
            'story_1',
        fetchStoryDoc: (_) async => null,
        fetchNodeDocs: (_) async => const [],
        callFunction: (name, _) async => switch (name) {
          'createNode' => {'nodeId': 'node_1'},
          _ => <String, dynamic>{},
        },
        fetchAuthorStoryDocs: ({required authorId}) async => [
          _storyDoc('other', title: 'Other', updatedMillis: 5000),
        ],
      );
      final bloc = CreateBloc(repository: repository);
      addTearDown(bloc.close);

      bloc.add(const StoriesRequested(authorId: 'uid_1'));
      await bloc.stream.firstWhere((s) => s.stories.isNotEmpty);
      bloc.add(const DraftRequested(authorId: 'uid_1', title: 'Fresh'));
      final state = await bloc.stream.firstWhere(
        (s) => s.hasDraft && s.stories.any((e) => e.storyId == 'story_1'),
      );

      expect(
        state.stories.firstWhere((e) => e.storyId == 'story_1').title,
        'Fresh',
      );
      expect(state.failure, isNull);
    });
  });
}
