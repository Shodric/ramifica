import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/create_hud.dart';

const _leaf = DraftNode(nodeId: 'leaf', title: 'Leaf');

const _fork = DraftNode(
  nodeId: 'fork',
  title: 'Fork',
  choices: [
    DraftChoice(
      choiceId: 'a',
      label: 'A',
      targetNodeId: 'leaf',
      isDefault: true,
    ),
    DraftChoice(
      choiceId: 'b',
      label: 'B',
      targetNodeId: 'leaf',
      isDefault: false,
    ),
  ],
);

void main() {
  group('hudBranchCount', () {
    test('empty draft has no branches', () {
      expect(hudBranchCount(const []), 0);
    });

    test('a lone root is not a branch', () {
      expect(
        hudBranchCount([const DraftNode(nodeId: 'root', title: 'Root')]),
        0,
      );
    });

    test('counts nodes with children only', () {
      expect(hudBranchCount([_fork, _leaf]), 1);
    });

    test('a chain counts every parent', () {
      const mid = DraftNode(
        nodeId: 'mid',
        title: 'Mid',
        choices: [
          DraftChoice(
            choiceId: 'c',
            label: 'Go',
            targetNodeId: 'leaf',
            isDefault: true,
          ),
        ],
      );
      const root = DraftNode(
        nodeId: 'root',
        title: 'Root',
        choices: [
          DraftChoice(
            choiceId: 'd',
            label: 'Go',
            targetNodeId: 'mid',
            isDefault: true,
          ),
        ],
      );
      expect(hudBranchCount([root, mid, _leaf]), 2);
    });
  });
}
