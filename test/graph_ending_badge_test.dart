import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/graph_stub.dart';
import 'package:ramifica/data/persistence/document_store.dart';
import 'package:ramifica/data/persistence/game_service.dart';
import 'package:ramifica/data/persistence/publication.dart';
import 'package:ramifica/data/repositories/graph_repository.dart';
import 'package:ramifica/features/graph/graph_view.dart';
import 'package:ramifica/features/graph/stub_draft.dart';

import 'support/memory_document_store.dart';

void main() {
  group('Map ending badge', () {
    test('graphStubs reveals the badge only once the ending is seen', () async {
      final store = MemoryDocumentStore();
      addTearDown(store.close);
      _seed(store);
      expect(
        await ClientPublisher(store, () => 'author').publish('s'),
        isEmpty,
      );
      final game = ClientGameService(store, () => 'player');
      final start = await game.execute('startRun', {'storyId': 's'});
      final runId = start['runId'] as String;

      var stubs = await game.execute('graphStubs', {
        'storyId': 's',
        'runId': runId,
      });
      var nodes = stubs['nodes'] as List;
      expect(_node(nodes, 'end')['endingBadgeUrl'], isNull);

      await game.execute('commitChoice', {
        'runId': runId,
        'fromNodeId': 'root',
        'choiceId': 'c',
        'requestId': 'decision',
      });
      stubs = await game.execute('graphStubs', {
        'storyId': 's',
        'runId': runId,
      });
      nodes = stubs['nodes'] as List;
      expect(_node(nodes, 'end')['endingBadgeUrl'], _badgeUrl);
      expect(_node(nodes, 'root')['endingBadgeUrl'], isNull);
    });

    test(
      'graphStubs carries the HQ frame only once the node is seen',
      () async {
        final store = MemoryDocumentStore();
        addTearDown(store.close);
        _seed(store);
        expect(
          await ClientPublisher(store, () => 'author').publish('s'),
          isEmpty,
        );
        final game = ClientGameService(store, () => 'player');
        final start = await game.execute('startRun', {'storyId': 's'});
        final runId = start['runId'] as String;

        var stubs = await game.execute('graphStubs', {
          'storyId': 's',
          'runId': runId,
        });
        expect(_node(stubs['nodes'] as List, 'end')['thumbnailUrl'], isNull);

        await game.execute('commitChoice', {
          'runId': runId,
          'fromNodeId': 'root',
          'choiceId': 'c',
          'requestId': 'decision',
        });
        stubs = await game.execute('graphStubs', {
          'storyId': 's',
          'runId': runId,
        });
        expect(
          _node(stubs['nodes'] as List, 'end')['thumbnailUrl'],
          'https://media/frame.png',
        );
      },
    );

    test('stubs carry the earned badge onto draft nodes', () {
      final stub = GraphStub.fromJson({
        'nodeId': 'end',
        'isEnding': true,
        'visited': true,
        'secret': false,
        'endingBadgeUrl': _badgeUrl,
      });

      expect(stub.endingBadgeUrl, _badgeUrl);
      expect(draftNodesFromStubs([stub]).single.endingBadgeUrl, _badgeUrl);
    });

    testWidgets('the unlocked ending overlays its badge bottom-right', (
      tester,
    ) async {
      await _pumpGraph(tester, _stubs(badgeUrl: _badgeUrl));

      final badge = _badgeImage(_badgeUrl);
      expect(badge, findsOneWidget);
      final card = find.byKey(const ValueKey('canvas-node-end'));
      expect(card, findsOneWidget);
      final badgeRect = tester.getRect(badge);
      final badgeCenter = badgeRect.center;
      final cardCenter = tester.getCenter(card);
      final cardRect = tester.getRect(card);
      expect(badgeCenter.dx, greaterThan(cardCenter.dx));
      expect(cardRect.contains(badgeCenter), isTrue);
      // Straddles the thumbnail/footer seam: half over the image, half
      // over the gray footer below it.
      final footerTop = tester.getTopLeft(find.text('Scene 2')).dy;
      expect(badgeRect.top, lessThan(footerTop));
      expect(badgeRect.bottom, greaterThan(footerTop));
      // Full-bleed cover: the decoded frame spans the whole card
      // behind the footer glass.
      final cover = find.byWidgetPredicate(
        (w) => w is Image && w.image is MemoryImage,
      );
      expect(cover, findsOneWidget);
      expect(
        tester.getRect(cover).height,
        moreOrLessEquals(cardRect.height, epsilon: 4),
      );
    });

    testWidgets('a locked ending shows no badge overlay', (tester) async {
      await _pumpGraph(tester, _stubs());

      expect(_badgeImage(_badgeUrl), findsNothing);
    });

    testWidgets('only the footer text strip blurs', (tester) async {
      await _pumpGraph(tester, _stubs());

      final card = find.byKey(const ValueKey('canvas-node-end'));
      final filter = find.descendant(
        of: card,
        matching: find.byType(BackdropFilter),
      );
      expect(filter, findsOneWidget);
      final cardRect = tester.getRect(card);
      final filterRect = tester.getRect(filter);
      expect(filterRect.height, lessThan(cardRect.height / 2));
      expect(filterRect.bottom, moreOrLessEquals(cardRect.bottom, epsilon: 2));
    });

    testWidgets('an unlocked cover prefers its HQ frame over the blur', (
      tester,
    ) async {
      await _pumpGraph(tester, _stubs(coverUrl: _coverUrl));

      // The HQ url wins over the blur preview, which never renders.
      // (Network images never resolve in widget tests, so full-bleed
      // geometry is proven by the decoded-memory test above on the
      // same layout path.)
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Image &&
              w.image is NetworkImage &&
              (w.image as NetworkImage).url == _coverUrl,
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
        findsNothing,
      );
    });
  });
}

const _badgeUrl = 'https://cdn.invalid/badge.png';
const _coverUrl = 'https://cdn.invalid/cover.png';

/// A real 1x1 PNG: network images never load in widget tests, but memory
/// images decode, so the cover below measures its true laid-out size.
const _coverBlur =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

Map<String, dynamic> _node(List nodes, String id) =>
    nodes.firstWhere((n) => n['nodeId'] == id) as Map<String, dynamic>;

Finder _badgeImage(String url) => find.byWidgetPredicate(
  (w) =>
      w is Image &&
      w.image is NetworkImage &&
      (w.image as NetworkImage).url == url,
);

Future<void> _pumpGraph(WidgetTester tester, Map<String, dynamic> stubs) async {
  final repository = GraphRepository(execute: (name, data) async => stubs);
  await tester.pumpWidget(
    MaterialApp(
      home: GraphView(
        storyId: 'story_temple',
        runId: 'run_1',
        repository: repository,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> _stubs({String? badgeUrl, String? coverUrl}) {
  return {
    'currentNodeId': 'node_001',
    'story': {'title': 'The temple secret'},
    'nodes': [
      {
        'nodeId': 'node_001',
        'title': 'The temple door',
        'isEnding': false,
        'visited': true,
        'secret': false,
        'childIds': ['end'],
        'choices': [
          {'choiceId': 'c_enter', 'label': 'Enter', 'count': 1},
        ],
      },
      {
        'nodeId': 'end',
        'title': 'The treasure',
        'isEnding': true,
        'visited': true,
        'secret': false,
        'imageBlurData': _coverBlur,
        'thumbnailUrl': ?coverUrl,
        'endingType': 'epic',
        'endingBadgeUrl': ?badgeUrl,
      },
    ],
  };
}

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
    'choices': [_choice('end')],
  };
  store.documents['stories/s/nodes/end'] = {
    ..._readyNode(ending: true),
    'endingBadgeUrl': _badgeUrl,
    'startFromNodeId': 'root',
    'startParentFrameHash': 'end',
  };
}

Json _readyNode({bool ending = false}) => {
  ...DraftNode(
    nodeId: 'n',
    title: ending ? 'End' : 'Gate',
    isEnding: ending,
    endingType: ending ? 'open' : null,
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
  'ttsText': 'Choose',
  'lineApproved': false,
  'ttsStatus': 'ready',
  'ttsApproved': false,
  'ttsAudioUrl': 'https://media/audio.m4a',
  'ttsDurationSeconds': 2.3,
};

Json _choice(String target) => {
  'choiceId': 'c',
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
