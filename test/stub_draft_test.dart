import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/graph_stub.dart';
import 'package:ramifica/features/graph/stub_draft.dart';

const _blur = 'data:image/png;base64,AAA';

GraphStub _stub({
  required String id,
  String? title,
  bool ending = false,
  String? endingType,
  bool visited = true,
  bool secret = false,
  String? thumbnailUrl,
  String? imageBlurData,
  List<String> childIds = const [],
  List<GraphChoice> choices = const [],
}) {
  return GraphStub(
    nodeId: id,
    title: title,
    isEnding: ending,
    endingType: endingType,
    visited: visited,
    secret: secret,
    choiceCount: 0,
    thumbnailUrl: thumbnailUrl,
    imageBlurData: imageBlurData,
    childIds: childIds,
    choices: choices,
  );
}

void main() {
  group('draftNodesFromStubs', () {
    test('maps titles, endings, images, and choice icons', () {
      final nodes = draftNodesFromStubs([
        _stub(
          id: 'n1',
          title: 'Gate',
          thumbnailUrl: 'https://thumb/t.png',
          imageBlurData: _blur,
          childIds: ['n2'],
          choices: const [
            GraphChoice(
              choiceId: 'c',
              label: 'Enter',
              count: 3,
              icon: 'key',
              iconColor: 'gold',
            ),
          ],
        ),
        _stub(id: 'n2', title: 'End', ending: true, endingType: 'open'),
      ]);

      expect(nodes, hasLength(2));
      final gate = nodes.firstWhere((node) => node.nodeId == 'n1');
      expect(gate.title, 'Gate');
      expect(gate.videoFrameLastUrl, 'https://thumb/t.png');
      expect(gate.videoFrameLastBlurData, _blur);
      expect(gate.visibility, 'visible');
      expect(gate.choices, hasLength(1));
      expect(gate.choices.single.icon, 'key');
      expect(gate.choices.single.iconColor, 'gold');
      expect(gate.choices.single.targetNodeId, 'n2');
      expect(gate.cutSlots, {'A', 'B'});
      final end = nodes.firstWhere((node) => node.nodeId == 'n2');
      expect(end.isEnding, isTrue);
      expect(end.endingType, 'open');
    });

    test('locks unseen secrets and synthesizes choices from child ids', () {
      final nodes = draftNodesFromStubs([
        _stub(id: 'n1', title: 'Gate', childIds: ['n2']),
        _stub(id: 'n2', visited: false, secret: true),
      ]);

      final hidden = nodes.firstWhere((node) => node.nodeId == 'n2');
      expect(hidden.visibility, 'secret');
      expect(hidden.title, '');
      final gate = nodes.firstWhere((node) => node.nodeId == 'n1');
      expect(gate.choices.single.choiceId, 'choice-n2');
      expect(gate.choices.single.label, '');
      expect(gate.choices.single.icon, isNull);
      expect(gate.cutSlots, {'A', 'B'});
    });
  });

  group('draftRootIdFromStubs', () {
    test('picks the node nothing points to', () {
      expect(
        draftRootIdFromStubs([
          _stub(id: 'b'),
          _stub(id: 'a', childIds: ['b']),
        ]),
        'a',
      );
    });

    test('falls back to the first stub on cycles and empties', () {
      expect(
        draftRootIdFromStubs([
          _stub(id: 'a', childIds: ['b']),
          _stub(id: 'b', childIds: ['a']),
        ]),
        'a',
      );
      expect(draftRootIdFromStubs(const []), isNull);
    });
  });

  group('draftOrphansFromStubs', () {
    test('returns stubs unreachable from the root', () {
      expect(
        draftOrphansFromStubs([
          _stub(id: 'a', childIds: ['b']),
          _stub(id: 'b'),
          _stub(id: 'zzz'),
        ]),
        {'zzz'},
      );
    });

    test('returns empty when everything connects', () {
      expect(
        draftOrphansFromStubs([
          _stub(id: 'a', childIds: ['b']),
          _stub(id: 'b'),
        ]),
        isEmpty,
      );
      expect(draftOrphansFromStubs(const []), isEmpty);
    });
  });
}
