import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/persistence/document_store.dart';
import 'package:ramifica/data/persistence/draft_persistence.dart';
import 'package:ramifica/data/persistence/game_service.dart';
import 'package:ramifica/data/persistence/publication.dart';

import 'support/memory_document_store.dart';

Json readyNode({bool ending = false, bool secret = false}) => {
  ...DraftNode(
    nodeId: 'n',
    title: ending ? 'End' : 'Gate',
    isEnding: ending,
    endingType: ending ? 'open' : null,
    visibility: secret ? 'secret' : 'visible',
  ).toJson(),
  'videoStatus': 'ready',
  'videoSource': 'generated',
  'videoUrl': 'https://media/video.mp4',
  'videoWidth': 480,
  'videoHeight': 854,
  'durationSeconds': 10,
  'videoFrameLastUrl': 'https://media/frame.png',
  'videoFrameLastHash': 'end',
  'startImageStatus': 'ready',
  'startHash': 'start',
  'videoFromHash': 'start',
  'startImageApproved': false,
  'startImageWidth': 480,
  'startImageHeight': 854,
  'startImagePrompt': 'PRIVATE START',
  'videoPrompt': 'PRIVATE VIDEO',
  'ttsText': 'Choose',
  'lineApproved': false,
  'ttsStatus': 'ready',
  'ttsApproved': false,
  'ttsAudioUrl': 'https://media/audio.m4a',
  'ttsDurationSeconds': 2.3,
};
Json choice(String target, {String id = 'c'}) => {
  'choiceId': id,
  'targetNodeId': target,
  'label': 'Enter',
  'isDefault': true,
  'x': .3,
  'y': .4,
  'radius': .1,
  'icon': 'key',
  'iconColor': 'gold',
  'slot': 'A',
};
void seedReady(MemoryDocumentStore store) {
  store.documents['stories/s'] = {
    'authorId': 'author',
    'rootNodeId': 'root',
    'status': 'draft',
    'revision': 4,
  };
  store.documents['users/author'] = {'displayName': 'Author'};
  store.documents['stories/s/nodes/root'] = {
    ...readyNode(),
    'choices': [choice('end')],
  };
  store.documents['stories/s/nodes/end'] = {
    ...readyNode(ending: true, secret: true),
    'startFromNodeId': 'root',
    'startParentFrameHash': 'end',
  };
}

void main() {
  late MemoryDocumentStore store;
  late ClientDraftPersistence writer;
  setUp(() {
    store = MemoryDocumentStore();
    writer = ClientDraftPersistence(store, () => 'author');
  });
  tearDown(() {
    store.close();
  });
  test('story and root commit together with no reconstruction reads', () async {
    final (story, root) = await writer.createDraft('author', 'Story');
    expect(store.commits, 1);
    expect(store.reads, isEmpty);
    expect(store.lists, isEmpty);
    expect(
      store.documents['stories/${story.storyId}']!['rootNodeId'],
      root.nodeId,
    );
    expect(
      store.documents['stories/${story.storyId}/nodes/${root.nodeId}'],
      isNotNull,
    );
  });
  test(
    'child and link roll back together, then retry and occupied slots converge',
    () async {
      final (s, root) = await writer.createDraft('author', 'Story');
      store.beforeCommit = () async {
        throw const AppFailure(.offline);
      };
      await expectLater(
        writer.createAndLink(
          s.storyId,
          root.nodeId,
          slot: 'A',
          requestId: 'stable',
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(store.documents.length, 2);
      store.beforeCommit = null;
      final created = await writer.createAndLink(
        s.storyId,
        root.nodeId,
        slot: 'A',
        requestId: 'stable',
      );
      final retry = await writer.createAndLink(
        s.storyId,
        root.nodeId,
        slot: 'A',
        requestId: 'different',
      );
      expect(retry.selectedId, created.selectedId);
      expect(store.documents.length, 3);
      expect(store.lists, isEmpty);
    },
  );
  test('legacy orphan is recovered by requestId and re-linked without changing its contents', () async {
    final (s, root) = await writer.createDraft('author', 'Story');
    final legacy = DraftNode(
      nodeId: 'legacy',
      title: 'Existing content',
      startFromNodeId: root.nodeId,
      requestId: 'stable',
    );
    store.documents['stories/${s.storyId}/nodes/legacy'] = legacy.toJson();
    writer = ClientDraftPersistence(store, () => 'author');
    final linked = await writer.createAndLink(
      s.storyId,
      root.nodeId,
      slot: 'A',
      requestId: 'stable',
    );
    expect(linked.selectedId, 'legacy');
    expect(linked.nodes.last.title, 'Existing content');
    expect(store.documents.length, 3);
  });
  test('Apply overwrites reviewed fields, preserves geometry/destination/default, clamps and is reentrant', () async {
    seedReady(store);
    writer.remember('s', [
      for (final id in ['root', 'end'])
        DraftNode.fromMap(id, store.documents['stories/s/nodes/$id']!),
    ]);
    final original = store.documents['stories/s/nodes/root']!;
    original['title'] = 'Manual';
    original['ttsText'] = 'Old line';
    original['videoPrompt'] = 'Old move';
    original['choices'] = [
      choice('end')
        ..['label'] = 'Manual A'
        ..['icon'] = 'heart'
        ..['iconColor'] = 'red',
    ];
    final proposal = {
      'title': 'A' * 55,
      'ttsText': 'Choose again',
      'startImagePrompt': 'new prompt',
      'videoPrompt': 'Reviewed motion',
    };
    final options = [
      {'label': 'Enter', 'icon': 'unknown', 'iconColor': 'unknown'},
      {'label': 'Wait'},
    ];
    final applied = await writer.applyScene('s', 'root', proposal, options);
    final again = await writer.applyScene('s', 'root', proposal, options);
    // Reviewed non-empty fields win, clamped.
    expect(applied.nodes.first.title.length, 40);
    expect(applied.nodes.first.title, 'A' * 40);
    expect(applied.nodes.first.ttsText, 'Choose again');
    expect(applied.nodes.first.startImagePrompt, 'new prompt');
    expect(applied.nodes.first.videoPrompt, 'Reviewed motion');
    // Per-slot label/icon/color overwrite; ids/target/geometry/default stay.
    expect(again.nodes.first.choices.length, 2);
    final c = applied.nodes.first.choices.firstWhere((e) => e.choiceId == 'c');
    expect(c.targetNodeId, 'end');
    expect(c.x, .3);
    expect(c.y, .4);
    expect(c.radius, .1);
    expect(c.isDefault, true);
    expect(c.label, 'Enter');
    expect(c.icon, isNull);
    expect(c.iconColor, isNull);
    final b = applied.nodes.first.choices.firstWhere((e) => e.choiceId != 'c');
    expect(b.label, 'Wait');
    expect(b.isDefault, false);
    // A changed line idles the voice; approvals are ignored legacy.
    expect(applied.nodes.first.ttsStatus, 'idle');
    expect(store.documents.keys.where((p) => p.contains('/nodes/')).length, 3);
    expect(store.lists, isEmpty);
  });
  test(
    'Apply forces child start prompts null and creates no branches on endings',
    () async {
      seedReady(store);
      writer.remember('s', [
        for (final id in ['root', 'end'])
          DraftNode.fromMap(id, store.documents['stories/s/nodes/$id']!),
      ]);
      final child = await writer.createAndLink('s', 'root', slot: 'B');
      final childId = child.selectedId;
      final appliedChild = await writer.applyScene('s', childId, {
        'title': 'Child title',
        'startImagePrompt': 'should be dropped',
        'videoPrompt': 'Child move',
      }, []);
      expect(appliedChild.nodes.first.title, 'Child title');
      expect(appliedChild.nodes.first.startImagePrompt, isNull);
      // Endings ignore choices.
      final ending = await writer.applyScene(
        's',
        'end',
        {'title': 'End title'},
        [
          {'label': 'Should not branch'},
        ],
      );
      expect(ending.nodes.first.title, 'End title');
      expect(ending.nodes.first.choices, isEmpty);
    },
  );
  test('author writes advance revision', () async {
    seedReady(store);
    await writer.save(
      's',
      DraftNode.fromMap(
        'root',
        store.documents['stories/s/nodes/root']!,
      ).copy(title: 'Saved'),
    );
    expect(store.documents['stories/s']!['revision'], 5);
  });
  test(
    'delete rejects root and references and fences concurrent graph edits',
    () async {
      seedReady(store);
      await expectLater(writer.delete('s', 'root'), throwsA(isA<AppFailure>()));
      await expectLater(writer.delete('s', 'end'), throwsA(isA<AppFailure>()));
      store.documents['stories/s/nodes/orphan'] = const DraftNode(
        nodeId: 'orphan',
      ).toJson();
      var first = true;
      store.beforeList = (_) async {
        if (first) {
          first = false;
          store.documents['stories/s']!['revision'] = 5;
          store.documents['stories/s/nodes/root']!['choices'] = [
            choice('orphan'),
          ];
        }
      };
      await expectLater(
        writer.delete('s', 'orphan'),
        throwsA(isA<AppFailure>()),
      );
      expect(store.documents.containsKey('stories/s/nodes/orphan'), true);
    },
  );
  test('publication excludes private fields, hides secret map and only prefetches nonsecrets', () async {
    seedReady(store);
    expect(await ClientPublisher(store, () => 'author').publish('s'), isEmpty);
    final story = store.documents['stories/s']!;
    final base = 'stories/s/publications/${story['activePublicationId']}';
    final body = store.documents['$base/nodes/root']!;
    expect(body.containsKey('videoPrompt'), false);
    expect(body.containsKey('lineApproved'), false);
    expect(jsonMap((body['choices'] as List).first)['targetVideoUrl'], isNull);
    expect(store.documents['$base/map/end'], {'secret': true});
    expect(story['authorName'], 'Author');
    expect(story['revision'], 5);
  });
  test('publication stages the scene table and playback attaches it once', () async {
    seedReady(store);
    expect(await ClientPublisher(store, () => 'author').publish('s'), isEmpty);
    final story = store.documents['stories/s']!;
    final base = 'stories/s/publications/${story['activePublicationId']}';
    final table = jsonMap(store.documents[base]!['nodes']);
    expect(table.keys, unorderedEquals(['root', 'end']));
    expect(jsonMap(table['end'])['isEnding'], true);
    expect(
      jsonMap((jsonMap(table['root'])['choices'] as List).first)['targetNodeId'],
      'end',
    );
    final game = ClientGameService(store, () => 'player');
    final start = await game.execute('startRun', {'storyId': 's'});
    final runId = start['runId'] as String;
    final playback = await game.execute('loadPlayback', {'runId': runId});
    expect(jsonMap(playback['nodes']).keys, unorderedEquals(['root', 'end']));
    final reads = store.reads.where((p) => p == base).length;
    await game.execute('loadPlayback', {'runId': runId});
    expect(store.reads.where((p) => p == base), hasLength(reads));
  });
  test('interrupted staging never activates; changed revision refuses stale publication', () async {
    seedReady(store);
    store.beforeBatch = (_) async {
      throw const AppFailure(.offline);
    };
    await expectLater(
      ClientPublisher(store, () => 'author').publish('s'),
      throwsA(isA<AppFailure>()),
    );
    expect(store.documents['stories/s']!['activePublicationId'], isNull);
    store.beforeBatch = (_) async {
      store.documents['stories/s']!['revision'] = 9;
    };
    await expectLater(
      ClientPublisher(store, () => 'author').publish('s'),
      throwsA(isA<AppFailure>()),
    );
    expect(store.documents['stories/s']!['status'], 'draft');
    store.beforeBatch = null;
    expect(await ClientPublisher(store, () => 'author').publish('s'), isEmpty);
  });
  test('media ships as-is: any size and duration publish', () {
    seedReady(store);
    final story = store.documents['stories/s']!;
    final root = store.documents['stories/s/nodes/root']!;
    root['durationSeconds'] = 6;
    root['videoWidth'] = 768;
    root['startImageWidth'] = 100;
    var problems = validatePublication(story, {'root': root});
    expect(problems.any((p) => p.contains('10-second')), false);
    expect(problems.any((p) => p.contains('480')), false);
    root['durationSeconds'] = 0;
    problems = validatePublication(story, {'root': root});
    expect(problems.any((p) => p.contains('measured video duration')), true);
  });
  test('commit unlocks secret before read; interrupted ending finalizes once on resume and retries', () async {
    seedReady(store);
    await ClientPublisher(store, () => 'author').publish('s');
    final base =
        'stories/s/publications/${store.documents['stories/s']!['activePublicationId']}';
    final game = ClientGameService(store, () => 'player');
    final start = await game.execute('startRun', {'storyId': 's'});
    final runId = start['runId'] as String;
    var interrupt = true;
    store.beforeRead = (path) async {
      if (path == '$base/nodes/end') {
        expect(
          store.documents['users/player/storyState/s']!['visitedNodeIds'],
          contains('end'),
        );
        if (interrupt) throw const AppFailure(.offline);
      }
    };
    final data = {
      'runId': runId,
      'fromNodeId': 'root',
      'choiceId': 'c',
      'requestId': 'decision',
    };
    await expectLater(
      game.execute('commitChoice', data),
      throwsA(isA<AppFailure>()),
    );
    expect(
      store.documents['users/player/runs/$runId']!['currentNodeId'],
      'end',
    );
    expect(store.documents.keys.where((p) => p.contains('/rewards/')), isEmpty);
    interrupt = false;
    final resumed = await game.execute('loadPlayback', {'runId': runId});
    expect(jsonMap(resumed['node'])['isEnding'], true);
    final code = store.documents['users/player/rewards/s_end']!['code'];
    await game.execute('commitChoice', data);
    expect(store.documents['users/player/rewards/s_end']!['code'], code);
    expect(store.documents['$base/stats/root']!['choiceCounts'], {'c': 1});
    expect(
      store.documents['users/player/runs/$runId']!['choices'],
      hasLength(1),
    );
    expect(store.documents['users/player/storyState/s']!['endings'], ['end']);
    await game.execute('rewindRun', {'runId': runId});
    expect(
      store.documents['users/player/runs/$runId']!['currentNodeId'],
      'root',
    );
    expect(
      store.documents['users/player/runs/$runId']!['choices'],
      hasLength(1),
    );
  });
  test('jumpToNode moves the pointer between visited scenes only', () async {
    seedReady(store);
    await ClientPublisher(store, () => 'author').publish('s');
    final game = ClientGameService(store, () => 'player');
    final start = await game.execute('startRun', {'storyId': 's'});
    final runId = start['runId'] as String;
    await game.execute('commitChoice', {
      'runId': runId,
      'fromNodeId': 'root',
      'choiceId': 'c',
      'requestId': 'decision',
    });
    expect(store.documents['users/player/runs/$runId']!['currentNodeId'], 'end');

    final back = await game.execute('jumpToNode', {
      'runId': runId,
      'nodeId': 'root',
    });
    expect(jsonMap(back['node'])['nodeId'], 'root');
    expect(
      store.documents['users/player/runs/$runId']!['currentNodeId'],
      'root',
    );
    expect(
      store.documents['users/player/runs/$runId']!['choices'],
      hasLength(1),
    );

    final same = await game.execute('jumpToNode', {
      'runId': runId,
      'nodeId': 'root',
    });
    expect(jsonMap(same['node'])['nodeId'], 'root');

    await expectLater(
      game.execute('jumpToNode', {'runId': runId, 'nodeId': 'missing'}),
      throwsA(isA<AppFailure>()),
    );
    expect(
      store.documents['users/player/runs/$runId']!['currentNodeId'],
      'root',
    );
  });
  test('graphStubs carries card images and choice icon colors for seen nodes', () async {
    seedReady(store);
    store.documents['stories/s']!['title'] = 'The temple secret';
    store.documents['stories/s']!['coverUrl'] = 'https://cover/c.png';
    store.documents['stories/s/nodes/root']!['videoFrameLastBlurData'] =
        'data:image/png;base64,AAA';
    await ClientPublisher(store, () => 'author').publish('s');
    final game = ClientGameService(store, () => 'player');
    final start = await game.execute('startRun', {'storyId': 's'});
    final stubs = await game.execute(
      'graphStubs',
      {'storyId': 's', 'runId': start['runId']},
    );
    final nodes = stubs['nodes'] as List;
    final root = nodes.firstWhere((n) => n['nodeId'] == 'root');
    expect(root['imageBlurData'], 'data:image/png;base64,AAA');
    expect(stubs['story'], {
      'title': 'The temple secret',
      'coverUrl': 'https://cover/c.png',
    });
    expect(root['choices'].single['icon'], 'key');
    expect(root['choices'].single['iconColor'], 'gold');
    final end = nodes.firstWhere((n) => n['nodeId'] == 'end');
    expect(end['choices'], isNull);
    expect(end['imageBlurData'], isNull);
  });

  test('shared playback/map cache is cleared on account switch', () async {
    seedReady(store);
    await ClientPublisher(store, () => 'author').publish('s');
    var user = 'first';
    final game = ClientGameService(store, () => user);
    final first = await game.execute('startRun', {'storyId': 's'});
    await game.execute('loadPlayback', {'runId': first['runId']});
    store.reads.clear();
    user = 'second';
    final second = await game.execute('startRun', {'storyId': 's'});
    await game.execute('loadPlayback', {'runId': second['runId']});
    expect(store.reads.where((p) => p.endsWith('/nodes/root')), isNotEmpty);
    expect(store.documents['users/second/storyState/s']!['visitedNodeIds'], [
      'root',
    ]);
  });
  test('unpublishStory flips a published story back to draft', () async {
    seedReady(store);
    store.documents['stories/s']!['status'] = 'published';
    await writer.unpublishStory('s');
    final story = store.documents['stories/s']!;
    expect(story['status'], 'draft');
    expect(story['revision'], 5);
    expect(story['updatedAt'], isNotNull);
  });
  test('unpublishStory rejects a draft story', () async {
    seedReady(store);
    await expectLater(writer.unpublishStory('s'), throwsA(isA<AppFailure>()));
    expect(store.documents['stories/s']!['revision'], 4);
  });
  test('unpublishStory rejects another author', () async {
    seedReady(store);
    store.documents['stories/s']!['status'] = 'published';
    await expectLater(
      ClientDraftPersistence(store, () => 'other').unpublishStory('s'),
      throwsA(isA<AppFailure>()),
    );
    expect(store.documents['stories/s']!['status'], 'published');
  });
  test('deleteStory removes the draft story doc', () async {
    seedReady(store);
    await writer.deleteStory('s');
    expect(store.documents['stories/s'], isNull);
    // Nodes stay but nothing can read them without the story doc.
    expect(store.documents['stories/s/nodes/root'], isNotNull);
  });
  test('deleteStory rejects a published story', () async {
    seedReady(store);
    store.documents['stories/s']!['status'] = 'published';
    await expectLater(writer.deleteStory('s'), throwsA(isA<AppFailure>()));
    expect(store.documents['stories/s'], isNotNull);
  });
  test('deleteStory rejects another author', () async {
    seedReady(store);
    await expectLater(
      ClientDraftPersistence(store, () => 'other').deleteStory('s'),
      throwsA(isA<AppFailure>()),
    );
    expect(store.documents['stories/s'], isNotNull);
  });

  test('validatePublication accepts every ending type of the taxonomy', () {
    seedReady(store);
    final story = store.documents['stories/s']!;
    const types = [
      'open',
      'tragic',
      'secret',
      'heroic',
      'mysterious',
      'bittersweet',
      'dark',
      'epic',
      'incomplete',
    ];
    for (final type in types) {
      final end = Map.of(store.documents['stories/s/nodes/end']!);
      end['endingType'] = type;
      final problems = validatePublication(story, {
        'root': store.documents['stories/s/nodes/root']!,
        'end': end,
      });
      expect(
        problems.where((p) => p.contains('valid type')),
        isEmpty,
        reason: type,
      );
    }
  });
  test('validatePublication rejects an unknown ending type', () {
    seedReady(store);
    final story = store.documents['stories/s']!;
    final end = Map.of(store.documents['stories/s/nodes/end']!);
    end['endingType'] = 'xyz';
    final problems = validatePublication(story, {
      'root': store.documents['stories/s/nodes/root']!,
      'end': end,
    });
    expect(problems, contains('Ending end needs a valid type.'));
  });
}
