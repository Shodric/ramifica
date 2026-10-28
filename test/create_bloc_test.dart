import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/draft_story.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';
import 'package:ramifica/features/create/draft_canvas.dart';

void main() {
  group('CreateRepository', () {
    test('createDraft writes the story then the root node', () async {
      final calls = <_Call>[];
      final repository = _repo(calls);

      final (story, root) = await repository.createDraft(
        authorId: 'uid_1',
        title: 'Temple',
      );

      expect(calls.singleWhere((call) => call.name == 'createNode').data, {
        'storyId': 'story_1',
      });
      expect(story.storyId, 'story_1');
      expect(story.rootNodeId, 'node_1');
      expect(root.nodeId, 'node_1');
    });

    test('createDraft rejects a blank author without calling', () async {
      final calls = <_Call>[];
      final repository = _repo(calls);

      await expectLater(
        repository.createDraft(authorId: '  '),
        throwsA(const AppFailure(.invalid)),
      );
      expect(calls, isEmpty);
    });

    test('fetchNodes skips malformed docs', () async {
      final repository = _repo(
        null,
        nodes: [
          MapEntry('node_1', _nodeDoc()),
          const MapEntry('bad', {'title': 42}),
        ],
      );

      final nodes = await repository.fetchNodes('story_1');

      expect(nodes.map((node) => node.nodeId), ['node_1']);
    });

    test('saveNode sends the node doc under its id', () async {
      final calls = <_Call>[];
      final repository = _repo(calls);
      const node = DraftNode(nodeId: 'node_1', title: 'Door');

      await repository.saveNode(storyId: 'story_1', node: node);

      final save = calls.singleWhere((call) => call.name == 'saveNode');
      expect(save.data['storyId'], 'story_1');
      final sent = (save.data['node'] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
      expect(sent['nodeId'], 'node_1');
      expect(sent['title'], 'Door');
      expect(sent['choices'], isEmpty);
    });

    test('generateNodeText parses the backend shape', () async {
      final calls = <_Call>[];
      final repository = _repo(calls);

      final proposal = await repository.generateNodeText(
        storyId: 'story_1',
        nodeId: 'node_1',
      );

      expect(calls.single.name, 'generateNodeText');
      expect(calls.single.data, {
        'storyId': 'story_1',
        'nodeId': 'node_1',
      });
      expect(proposal.title, 'Spark title');
      expect(proposal.ttsText, startsWith('What should'));
      expect(proposal.choiceLabels, ['Enter', 'Climb']);
      expect(proposal.endingName, isNull);
    });

    test('generateNodeText accepts plain-string choices', () async {
      final repository = CreateRepository(
        createDraftDoc: ({required authorId, required title}) async =>
            throw const AppFailure(.failed),
        fetchStoryDoc: (_) async => throw const AppFailure(.failed),
        fetchNodeDocs: (_) async => const [],
        callFunction: (name, data) async => {
          'title': null,
          'ttsText': 'A line',
          'choices': ['Run', {'label': 'Hide'}],
          'endingName': null,
        },
      );

      final proposal = await repository.generateNodeText(
        storyId: 'story_1',
        nodeId: 'node_1',
      );

      expect(proposal.title, isNull);
      expect(proposal.choiceLabels, ['Run', 'Hide']);
    });

    test('an empty proposal is invalid', () async {
      final repository = CreateRepository(
        createDraftDoc: ({required authorId, required title}) async =>
            throw const AppFailure(.failed),
        fetchStoryDoc: (_) async => throw const AppFailure(.failed),
        fetchNodeDocs: (_) async => const [],
        callFunction: (name, data) async => {
          'title': null,
          'ttsText': '  ',
          'choices': [],
          'endingName': null,
        },
      );

      await expectLater(
        repository.generateNodeText(storyId: 'story_1', nodeId: 'node_1'),
        throwsA(const AppFailure(.invalid)),
      );
    });
  });

  group('CreateBloc', () {
    test('DraftRequested creates the draft and opens the root', () async {
      final bloc = CreateBloc(repository: _repo(null));
      addTearDown(bloc.close);

      bloc.add(const DraftRequested(authorId: 'uid_1', title: 'Temple'));
      await bloc.stream.firstWhere(
        (state) => state.hasDraft && state.job == CreateJob.none,
      );

      expect(bloc.state.story?.storyId, 'story_1');
      expect(bloc.state.openNodeId, 'node_1');
      expect(bloc.state.failure, isNull);
    });

    test('DraftRequested without an author fails quietly', () async {
      final calls = <_Call>[];
      final bloc = CreateBloc(repository: _repo(calls));
      addTearDown(bloc.close);

      bloc.add(const DraftRequested());
      await bloc.stream.firstWhere((state) => state.failure != null);

      expect(calls, isEmpty);
      expect(bloc.state.failure, 'That action is not valid');
    });

    test('DraftOpened loads the story and opens the root', () async {
      final bloc = CreateBloc(repository: _repo(null));
      addTearDown(bloc.close);

      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);

      expect(bloc.state.nodes, hasLength(2));
      expect(bloc.state.openNodeId, 'node_1');
    });

    test('unknown selections and edits are ignored', () async {
      final calls = <_Call>[];
      final bloc = CreateBloc(repository: _repo(calls));
      addTearDown(bloc.close);
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);
      calls.clear();

      bloc
        ..add(const NodeSelected('missing'))
        ..add(const NodeFieldChanged(nodeId: 'missing', title: 'x'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bloc.state.openNodeId, 'node_1');
      expect(calls, isEmpty);
    });

    test('field edits stay local until the explicit save', () async {
      final calls = <_Call>[];
      final bloc = CreateBloc(repository: _repo(calls));
      addTearDown(bloc.close);
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);
      calls.clear();

      bloc.add(const NodeFieldChanged(nodeId: 'node_1', title: 'Typed'));
      await bloc.stream.firstWhere(
        (state) => state.openNode?.title == 'Typed',
      );
      expect(calls, isEmpty);

      bloc.add(const NodeSaved());
      await bloc.stream.firstWhere(
        (state) =>
            state.job == CreateJob.none && state.openNode?.title == 'Typed',
      );
      final save = calls.singleWhere((call) => call.name == 'saveNode');
      final sent = (save.data['node'] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
      expect(sent['title'], 'Typed');
    });

    test('generation fills empty fields without clobbering edits', () async {
      final bloc = CreateBloc(repository: _repo(null));
      addTearDown(bloc.close);
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);

      bloc.add(const NodeFieldChanged(nodeId: 'node_1', title: 'Typed'));
      await bloc.stream.firstWhere(
        (state) => state.openNode?.title == 'Typed',
      );

      bloc.add(const TextGenerateRequested());
      final filled = await bloc.stream.firstWhere(
        (state) =>
            state.job == CreateJob.none &&
            (state.openNode?.ttsText.isNotEmpty ?? false),
      );

      expect(filled.openNode?.title, 'Typed');
      expect(filled.openNode?.ttsText, startsWith('What should'));
      expect(filled.openNode?.choices.first.label, 'Enter');
    });

    test('regenerate overwrites manual edits', () async {
      final bloc = CreateBloc(repository: _repo(null));
      addTearDown(bloc.close);
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);

      bloc.add(const NodeFieldChanged(nodeId: 'node_1', title: 'Typed'));
      await bloc.stream.firstWhere(
        (state) => state.openNode?.title == 'Typed',
      );

      bloc.add(const TextGenerateRequested(regenerate: true));
      final filled = await bloc.stream.firstWhere(
        (state) =>
            state.job == CreateJob.none &&
            state.openNode?.title == 'Spark title',
      );

      expect(filled.openNode?.title, 'Spark title');
    });

    test('a generation failure shows its phrase on the node', () async {
      final bloc = CreateBloc(
        repository: CreateRepository(
          createDraftDoc: ({required authorId, required title}) async =>
              throw const AppFailure(.failed),
          fetchStoryDoc: (_) async => _storyDoc(),
          fetchNodeDocs: (_) async => [MapEntry('node_1', _nodeDoc())],
          callFunction: (name, data) async =>
              throw const AppFailure(.offline),
        ),
      );
      addTearDown(bloc.close);
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);

      bloc.add(const TextGenerateRequested());
      await bloc.stream.firstWhere((state) => state.failure != null);

      expect(bloc.state.failure, 'No connection');
      expect(bloc.state.statusOf('node_1'), StatusPillState.failed);
    });
  });

  group('CreateState', () {
    test('missing lists the unmet publish conditions', () {
      const node = DraftNode(nodeId: 'node_1');

      final missing = missingForNode(node: node);

      expect(missing, contains('Node node_1 needs a title of 1-40 characters.'));
      expect(missing, contains('Node node_1 needs a ready video.'));
      expect(missing, contains('Node node_1 needs one or two choices.'));
      expect(
        missing,
        contains('Node node_1 needs windowSeconds between 3 and 15.'),
      );
      expect(missing, contains('Node node_1 needs an approved narrator line.'));
      expect(missing, contains('Node node_1 needs a ready narrator voice.'));
    });

    test('a complete node has nothing missing', () {
      final missing = missingForNode(node: _completeNode());

      expect(missing, isEmpty);
    });

    test('orphans are unreachable nodes shown distinctly', () {
      const state = CreateState(
        story: DraftStory(
          storyId: 'story_1',
          authorId: 'uid_1',
          title: 'Temple',
          rootNodeId: 'node_1',
        ),
        nodes: [
          DraftNode(
            nodeId: 'node_1',
            choices: [
              DraftChoice(
                choiceId: 'c1',
                label: 'Go',
                targetNodeId: 'node_2',
                isDefault: true,
              ),
            ],
          ),
          DraftNode(nodeId: 'node_2'),
          DraftNode(nodeId: 'node_9'),
        ],
        openNodeId: 'node_1',
      );

      expect(state.orphanNodeIds, {'node_9'});
      expect(state.statusOf('node_1'), StatusPillState.idle);
    });

    test('ready marks a complete open node', () {
      final state = CreateState(
        story: const DraftStory(
          storyId: 'story_1',
          authorId: 'uid_1',
          title: 'Temple',
          rootNodeId: 'node_1',
        ),
        nodes: [_completeNode().copy(title: 'Done')],
        openNodeId: 'node_1',
      );

      expect(state.statusOf('node_1'), StatusPillState.ready);
    });
  });

  group('layoutDraft', () {
    test('lays out every node and links choices', () {
      const nodes = [
        DraftNode(
          nodeId: 'node_1',
          title: 'Root',
          choices: [
            DraftChoice(
              choiceId: 'c1',
              label: 'Go',
              targetNodeId: 'node_2',
              isDefault: true,
            ),
          ],
        ),
        DraftNode(nodeId: 'node_2', title: 'Leaf'),
        DraftNode(nodeId: 'node_9', title: 'Orphan'),
      ];

      final layout = layoutDraft(nodes, rootNodeId: 'node_1');

      expect(layout.positions.keys, {'node_1', 'node_2', 'node_9'});
      expect(layout.edges.single.from, 'node_1');
      expect(layout.edges.single.to, 'node_2');
      expect(layout.edges.single.returns, isFalse);
      expect(
        layout.positions['node_2']!.dy,
        greaterThan(layout.positions['node_1']!.dy),
      );
    });

    test('a cycle draws as a return edge', () {
      const nodes = [
        DraftNode(
          nodeId: 'node_1',
          choices: [
            DraftChoice(
              choiceId: 'c1',
              label: 'Back',
              targetNodeId: 'node_1',
              isDefault: true,
            ),
          ],
        ),
      ];

      final layout = layoutDraft(nodes, rootNodeId: 'node_1');

      expect(layout.edges.single.returns, isTrue);
    });
  });
}

class _Call {
  const _Call(this.name, this.data);

  final String name;
  final Map<String, dynamic> data;
}

CreateRepository _repo(
  List<_Call>? calls, {
  List<MapEntry<String, Map<String, dynamic>>>? nodes,
}) {
  return CreateRepository(
    createDraftDoc: ({required authorId, required title}) async => 'story_1',
    fetchStoryDoc: (_) async => _storyDoc(),
    fetchNodeDocs: (_) async =>
        nodes ??
        [MapEntry('node_1', _nodeDoc()), MapEntry('node_2', _nodeDoc())],
    callFunction: (name, data) async {
      calls?.add(_Call(name, data));
      return switch (name) {
        'createNode' => {'nodeId': 'node_1'},
        'generateNodeText' => {
          'title': 'Spark title',
          'ttsText': 'What should they do next?',
          'choices': [
            {'label': 'Enter'},
            {'label': 'Climb'},
          ],
          'endingName': null,
        },
        _ => <String, dynamic>{},
      };
    },
  );
}

Map<String, dynamic> _storyDoc() {
  return {
    'authorId': 'uid_1',
    'title': 'Temple',
    'synopsis': '',
    'status': 'draft',
    'rootNodeId': 'node_1',
  };
}

Map<String, dynamic> _nodeDoc() {
  return {
    'title': '',
    'visibility': 'visible',
    'isEnding': false,
    'videoStatus': 'idle',
    'windowSeconds': 6,
    'ttsText': '',
    'lineApproved': false,
    'ttsStatus': 'idle',
    'choices': [
      {
        'choiceId': 'c1',
        'label': '',
        'targetNodeId': 'node_2',
        'isDefault': true,
        'x': 0.25,
        'y': 0.65,
        'radius': 0.15,
      },
    ],
  };
}

DraftNode _completeNode() {
  return const DraftNode(
    nodeId: 'node_1',
    title: 'Door',
    videoUrl: 'https://example.com/video.mp4',
    videoStatus: 'ready',
    windowSeconds: 6,
    ttsText: 'What should they do?',
    lineApproved: true,
    ttsAudioUrl: 'https://example.com/voice.m4a',
    ttsStatus: 'ready',
    ttsDurationSeconds: 4.1,
    choices: [
      DraftChoice(
        choiceId: 'c1',
        label: 'Enter',
        targetNodeId: 'node_2',
        isDefault: true,
        x: 0.25,
        y: 0.65,
        radius: 0.15,
      ),
    ],
  );
}
