import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/persistence/document_store.dart';
import 'package:ramifica/data/persistence/game_service.dart';
import 'package:ramifica/data/persistence/publication.dart';

import 'support/memory_document_store.dart';

const _badge = 'https://media/badge.png';

Json _readyNode({bool ending = false}) => {
  ...DraftNode(
    nodeId: 'n',
    title: ending ? 'End' : 'Gate',
    isEnding: ending,
    endingName: ending ? 'Freedom' : null,
    endingType: ending ? 'open' : null,
    visibility: ending ? 'secret' : 'visible',
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

void _seed(MemoryDocumentStore store) {
  store.documents['stories/s'] = {
    'authorId': 'author',
    'rootNodeId': 'root',
    'status': 'draft',
    'revision': 4,
  };
  store.documents['users/author'] = {'displayName': 'Author'};
  store.documents['stories/s/nodes/root'] = {
    ..._readyNode(),
    'choices': [
      {
        'choiceId': 'c',
        'targetNodeId': 'end',
        'label': 'Enter',
        'isDefault': true,
        'x': .3,
        'y': .4,
        'radius': .1,
        'icon': 'key',
        'iconColor': 'gold',
        'slot': 'A',
      },
    ],
  };
  store.documents['stories/s/nodes/end'] = {
    ..._readyNode(ending: true),
    'startFromNodeId': 'root',
    'startParentFrameHash': 'end',
  };
}

Future<String> _base(MemoryDocumentStore store) async {
  _seed(store);
  expect(await ClientPublisher(store, () => 'author').publish('s'), isEmpty);
  return 'stories/s/publications/${store.documents['stories/s']!['activePublicationId']}';
}

void main() {
  late MemoryDocumentStore store;
  setUp(() {
    store = MemoryDocumentStore();
  });
  tearDown(() {
    store.close();
  });

  test('ending outcome and reward doc carry the node badgeUrl', () async {
    final base = await _base(store);
    // The node-owning slice publishes `endingBadgeUrl` on ending nodes;
    // until that lands, the published body is seeded directly.
    store.documents['$base/nodes/end']!['endingBadgeUrl'] = _badge;
    final game = ClientGameService(store, () => 'player');
    final start = await game.execute('startRun', {'storyId': 's'});
    final result = await game.execute('commitChoice', {
      'runId': start['runId'],
      'fromNodeId': 'root',
      'choiceId': 'c',
      'requestId': 'decision',
    });

    expect(jsonMap(result['ending'])['badgeUrl'], _badge);
    expect(jsonMap(result['reward'])['badgeUrl'], _badge);
    expect(
      store.documents['users/player/rewards/s_end']!['badgeUrl'],
      _badge,
    );
  });

  test('ending outcome omits badgeUrl when the node has none', () async {
    await _base(store);
    final game = ClientGameService(store, () => 'player');
    final start = await game.execute('startRun', {'storyId': 's'});
    final result = await game.execute('commitChoice', {
      'runId': start['runId'],
      'fromNodeId': 'root',
      'choiceId': 'c',
      'requestId': 'decision',
    });

    expect(jsonMap(result['ending']).containsKey('badgeUrl'), false);
    expect(jsonMap(result['reward']).containsKey('badgeUrl'), false);
    expect(
      store.documents['users/player/rewards/s_end']!.containsKey('badgeUrl'),
      false,
    );
  });
}
