import 'support/create_repository_harness.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';
import 'package:ramifica/features/create/draft_canvas.dart';

void main() {
  group('layoutDraft edge accents', () {
    test('forward edge carries the resolved choice tint', () {
      final nodes = [
        const DraftNode(
          nodeId: 'node_1',
          choices: [
            DraftChoice(
              choiceId: 'c1',
              label: '',
              targetNodeId: 'node_2',
              isDefault: true,
              slot: 'A',
              icon: 'compass',
              iconColor: 'cyan',
            ),
          ],
        ),
        const DraftNode(nodeId: 'node_2'),
      ];
      final layout = layoutDraft(nodes, rootNodeId: 'node_1');
      final edge = layout.edges.singleWhere(
        (candidate) => candidate.to == 'node_2',
      );
      expect(edge.returns, isFalse);
      expect(edge.iconName, 'compass');
      expect(edge.iconColorName, 'cyan');
      expect(edge.accent, RamificaColors.hotspot);
    });

    test('unset icon color falls back to the per-slot accent', () {
      final nodes = [
        const DraftNode(
          nodeId: 'node_1',
          choices: [
            DraftChoice(
              choiceId: 'c1',
              label: '',
              targetNodeId: 'node_2',
              isDefault: true,
              slot: 'B',
            ),
          ],
        ),
        const DraftNode(nodeId: 'node_2'),
      ];
      final layout = layoutDraft(nodes, rootNodeId: 'node_1');
      final edge = layout.edges.singleWhere(
        (candidate) => candidate.to == 'node_2',
      );
      expect(edge.accent, RamificaColors.nodeActive);
    });

    test('return edges stay neutral', () {
      final nodes = [
        const DraftNode(
          nodeId: 'node_1',
          choices: [
            DraftChoice(
              choiceId: 'c1',
              label: '',
              targetNodeId: 'node_2',
              isDefault: true,
              slot: 'A',
              icon: 'compass',
              iconColor: 'cyan',
            ),
          ],
        ),
        const DraftNode(
          nodeId: 'node_2',
          choices: [
            DraftChoice(
              choiceId: 'c2',
              label: '',
              targetNodeId: 'node_1',
              isDefault: true,
              slot: 'A',
            ),
          ],
        ),
      ];
      final layout = layoutDraft(nodes, rootNodeId: 'node_1');
      final back = layout.edges.singleWhere(
        (candidate) => candidate.from == 'node_2' && candidate.to == 'node_1',
      );
      expect(back.returns, isTrue);
      expect(back.accent, isNull);
    });
  });

  group('edgeBadgeCenter', () {
    test('matches the cubic midpoint at t=1/2', () {
      const from = Offset(0, 0);
      const to = Offset(0, 240);
      // C1=(0,60), C2=(0,180): P=(P0+3C1+3C2+P3)/8.
      expect(edgeBadgeCenter(from, to), const Offset(0, 120));
    });
  });

  group('HotspotAdded', () {
    test(
      'creates a child, links the slot, and focuses without navigating',
      () async {
        final store = <String, Map<String, dynamic>>{'node_1': _nodeDoc()};
        var nextId = 2;
        final bloc = CreateBloc(
          repository: testCreateRepository(
            createDraftDoc: ({required authorId, required title}) async =>
                'story_1',
            updateStoryDoc: ({required storyId, title, synopsis}) async {},
            fetchStoryDoc: (_) async => _storyDoc(),
            fetchNodeDocs: (_) async => [
              for (final entry in store.entries)
                MapEntry(entry.key, Map<String, dynamic>.of(entry.value)),
            ],
            callFunction: (name, data) async {
              if (name == 'createNode') {
                final id = 'node_${nextId++}';
                store[id] = _nodeDoc();
                return {'nodeId': id};
              }
              if (name == 'saveNode') {
                final node = Map<String, dynamic>.of(
                  data['node'] as Map<String, dynamic>,
                );
                store[node['nodeId'] as String] = node;
                return {};
              }
              throw const AppFailure(.invalid);
            },
          ),
        );
        addTearDown(bloc.close);

        bloc.add(const DraftOpened('story_1'));
        await bloc.stream.firstWhere((state) => state.hasDraft);
        expect(bloc.state.openNodeId, 'node_1');

        bloc.add(const HotspotAdded(nodeId: 'node_1', slot: 'A'));
        await bloc.stream.firstWhere(
          (state) => state.job == CreateJob.none && state.focusChoiceId != null,
        );

        final parent = bloc.state.nodes.singleWhere(
          (node) => node.nodeId == 'node_1',
        );
        expect(parent.choices, hasLength(1));
        final choice = parent.choices.single;
        expect(choice.slot, 'A');
        expect(choice.label, '');
        expect(choice.icon, 'compass');
        expect(choice.iconColor, 'cyan');
        expect(bloc.state.focusChoiceId, choice.choiceId);
        // No navigation: the parent stays open.
        expect(bloc.state.openNodeId, 'node_1');

        // A taken slot is ignored: no second child.
        bloc.add(const HotspotAdded(nodeId: 'node_1', slot: 'A'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          bloc.state.nodes
              .singleWhere((node) => node.nodeId == 'node_1')
              .choices,
          hasLength(1),
        );
      },
    );

    test('field edits clear the focus', () async {
      final bloc = CreateBloc(repository: _repository());
      addTearDown(bloc.close);
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);
      bloc.add(const HotspotAdded(nodeId: 'node_1', slot: 'A'));
      await bloc.stream.firstWhere((state) => state.focusChoiceId != null);
      bloc.add(
        NodeFieldChanged(
          nodeId: 'node_1',
          choiceLabels: {bloc.state.focusChoiceId!: 'Go'},
        ),
      );
      await bloc.stream.firstWhere((state) => state.focusChoiceId == null);
      expect(
        bloc.state.nodes
            .singleWhere((node) => node.nodeId == 'node_1')
            .choices
            .single
            .label,
        'Go',
      );
    });
  });

  group('OutlineApplied', () {
    test(
      'updates the story, sets the line, and links option children',
      () async {
        var storyTitle = 'Temple';
        var storySynopsis = '';
        final store = <String, Map<String, dynamic>>{'node_1': _nodeDoc()};
        var nextId = 2;
        final bloc = CreateBloc(
          repository: testCreateRepository(
            createDraftDoc: ({required authorId, required title}) async =>
                'story_1',
            updateStoryDoc: ({required storyId, title, synopsis}) async {
              if (title != null) storyTitle = title;
              if (synopsis != null) storySynopsis = synopsis;
            },
            fetchStoryDoc: (_) async => {
              'authorId': 'uid_1',
              'title': storyTitle,
              'synopsis': storySynopsis,
              'rootNodeId': 'node_1',
            },
            fetchNodeDocs: (_) async => [
              for (final entry in store.entries)
                MapEntry(entry.key, Map<String, dynamic>.of(entry.value)),
            ],
            callFunction: (name, data) async {
              if (name == 'createNode') {
                final id = 'node_${nextId++}';
                store[id] = _nodeDoc();
                return {'nodeId': id};
              }
              if (name == 'saveNode') {
                final node = Map<String, dynamic>.of(
                  data['node'] as Map<String, dynamic>,
                );
                store[node['nodeId'] as String] = node;
                return {};
              }
              throw const AppFailure(.invalid);
            },
          ),
        );
        addTearDown(bloc.close);

        bloc.add(const DraftOpened('story_1'));
        await bloc.stream.firstWhere((state) => state.hasDraft);
        bloc.add(
          const OutlineApplied(
            title: 'New title',
            synopsis: 'A premise.',
            narratorLine: 'What now?',
            options: [
              OutlineOption(label: 'Left', icon: 'compass', iconColor: 'cyan'),
              OutlineOption(label: 'Right'),
            ],
          ),
        );
        await bloc.stream.firstWhere(
          (state) =>
              state.job == CreateJob.none &&
              state.story?.synopsis == 'A premise.',
        );

        expect(bloc.state.story?.title, 'New title');
        final root = bloc.state.nodes.singleWhere(
          (node) => node.nodeId == 'node_1',
        );
        expect(root.ttsText, 'What now?');
        expect(root.choices, hasLength(2));
        expect(root.choices[0].slot, 'A');
        expect(root.choices[0].label, 'Left');
        expect(root.choices[0].icon, 'compass');
        expect(root.choices[0].iconColor, 'cyan');
        expect(root.choices[1].slot, 'B');
        expect(root.choices[1].label, 'Right');
      },
    );
  });
}

Map<String, dynamic> _storyDoc() {
  return {
    'authorId': 'uid_1',
    'title': 'Temple',
    'synopsis': '',
    'rootNodeId': 'node_1',
  };
}

Map<String, dynamic> _nodeDoc() {
  return {
    'title': '',
    'visibility': 'visible',
    'isEnding': false,
    'videoStatus': 'idle',
    'ttsText': '',
    'lineApproved': false,
    'ttsStatus': 'idle',
    'choices': [],
  };
}

CreateRepository _repository() {
  final store = <String, Map<String, dynamic>>{'node_1': _nodeDoc()};
  var nextId = 2;
  return testCreateRepository(
    createDraftDoc: ({required authorId, required title}) async => 'story_1',
    updateStoryDoc: ({required storyId, title, synopsis}) async {},
    fetchStoryDoc: (_) async => _storyDoc(),
    fetchNodeDocs: (_) async => [
      for (final entry in store.entries)
        MapEntry(entry.key, Map<String, dynamic>.of(entry.value)),
    ],
    callFunction: (name, data) async {
      if (name == 'createNode') {
        final id = 'node_${nextId++}';
        store[id] = _nodeDoc();
        return {'nodeId': id};
      }
      if (name == 'saveNode') {
        final node = Map<String, dynamic>.of(
          data['node'] as Map<String, dynamic>,
        );
        store[node['nodeId'] as String] = node;
        return {};
      }
      throw const AppFailure(.invalid);
    },
  );
}
