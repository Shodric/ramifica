import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/persistence/document_store.dart';
import 'package:ramifica/data/persistence/draft_persistence.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';

import 'support/memory_document_store.dart';

class Harness {
  Harness() {
    store.documents['stories/story'] = {
      'authorId': 'author',
      'title': 'Story',
      'status': 'draft',
      'synopsis': 'Existing premise',
      'rootNodeId': 'root',
      'revision': 0,
    };
    root = const DraftNode(nodeId: 'root', title: 'Original').toJson();
  }
  final store = MemoryDocumentStore();
  Json get root => store.documents['stories/story/nodes/root']!;
  set root(Json value) => store.documents['stories/story/nodes/root'] = value;
  Map<String, Json> get children => {
    for (final d in store.documents.entries)
      if (d.key.startsWith('stories/story/nodes/') && !d.key.endsWith('/root'))
        d.key.split('/').last: d.value,
  };
  Map<String, String> get childByKey => {
    for (final d in children.entries)
      if (d.value['requestId'] is String) d.value['requestId'] as String: d.key,
  };
  final calls = <String>[];
  late final writer = ClientDraftPersistence(store, () => 'author');
  late final repository = CreateRepository(
    drafts: writer,
    createDraftDoc: ({required authorId, required title}) async => 'story',
    fetchStoryDoc: (id) => store.get('stories/$id'),
    fetchNodeDocs: (id) async {
      final docs = await store.list('stories/$id/nodes');
      writer.remember(id, [
        for (final d in docs) DraftNode.fromMap(d.key, d.value),
      ]);
      return docs;
    },
    fetchNodeDoc: (id, nodeId) => store.get('stories/$id/nodes/$nodeId'),
    updateStoryDoc: ({required storyId, title, synopsis}) =>
        writer.updateStory(storyId, title: title, synopsis: synopsis),
    callFunction: (name, data) async {
      calls.add(name);
      if (name == 'generateNodeText') {
        return {
          'title': 'Gate',
          'ttsText': data['purpose'] == 'scene' ? null : 'Enter or wait?',
          'startImagePrompt': 'Opening',
          'videoPrompt': 'Slow move',
          'choices': [
            {'label': 'Enter', 'icon': 'key', 'iconColor': 'gold'},
            {'label': 'Wait', 'icon': 'clock', 'iconColor': 'blue'},
          ],
        };
      }
      if (name == 'generateNodeImage') {
        final which = data['which'] as String;
        await store.batch([
          DocumentWrite('stories/story/nodes/root', {
            '${which}ImageSourceUrl': 'https://example.invalid/$which.png',
            '${which}ImageStatus': 'ready',
            '${which}Hash': 'hash-$which',
            '${which}ImageWidth': 480,
            '${which}ImageHeight': 854,
          }, merge: true),
        ]);
        return {};
      }
      if (name == 'generateNodeVoice') {
        assert((root['ttsText'] as String? ?? '').trim().isNotEmpty);
        await store.batch([
          DocumentWrite('stories/story/nodes/root', {
            'ttsStatus': 'ready',
            'ttsAudioUrl': 'https://example.invalid/voice.m4a',
            'ttsDurationSeconds': 1,
          }, merge: true),
        ]);
        return {};
      }
      if (name == 'generateNodeVideo') {
        expectSync(root['startImageStatus'], 'ready');
        await store.batch([
          DocumentWrite('stories/story/nodes/root', {
            'videoStatus': 'ready',
            'videoUrl': 'https://example.invalid/clip.mp4',
            'videoWidth': 480,
            'videoHeight': 854,
            'durationSeconds': 10,
          }, merge: true),
        ]);
        return {'poll': false};
      }
      throw StateError('Business operation reached Functions: $name');
    },
  );
  Future<CreateBloc> open() async {
    final bloc = CreateBloc(repository: repository);
    final ready = bloc.stream.firstWhere(
      (s) => s.hasDraft && s.job == CreateJob.none,
    );
    bloc.add(const DraftOpened('story'));
    await ready;
    return bloc;
  }
}

Future<void> apply(CreateBloc bloc, SceneProposal proposal) async {
  final done = bloc.stream.firstWhere((s) => s.job == CreateJob.none);
  bloc.add(SceneProposalApplied(nodeId: 'root', proposal: proposal));
  await done;
}

void main() {
  test('Apply preserves edits arriving during the transaction and does not reload the collection', () async {
    final h = Harness();
    final bloc = await h.open();
    addTearDown(bloc.close);
    final entered = Completer<void>(), release = Completer<void>();
    var held = false;
    h.store.beforeRead = (path) async {
      if (!held && path.endsWith('/nodes/root')) {
        held = true;
        entered.complete();
        await release.future;
      }
    };
    final done = apply(bloc, const SceneProposal(videoPrompt: 'New move'));
    await entered.future;
    final edited = bloc.stream.firstWhere(
      (s) => s.openNode?.title == 'Typed during Apply',
    );
    bloc.add(
      const NodeFieldChanged(nodeId: 'root', title: 'Typed during Apply'),
    );
    await edited;
    release.complete();
    await done;
    expect(bloc.state.openNode?.title, 'Typed during Apply');
    expect(bloc.state.openNode?.videoPrompt, 'New move');
    expect(h.store.lists, hasLength(1));
  });
  test('atomic Apply rolls back completely on failure and a retry creates each branch once', () async {
    final h = Harness();
    final bloc = await h.open();
    addTearDown(bloc.close);
    h.store.beforeCommit = () async => throw const AppFailure(.offline);
    const proposal = SceneProposal(choices: [SceneProposalChoice(label: 'Go')]);
    await apply(bloc, proposal);
    expect(bloc.state.failure, isNotNull);
    expect(h.children, isEmpty);
    expect(h.root['choices'], isEmpty);
    h.store.beforeCommit = null;
    await apply(bloc, proposal);
    final choice = bloc.state.openNode!.choices.single;
    await apply(bloc, proposal);
    expect(bloc.state.openNode!.choices.single.choiceId, choice.choiceId);
    expect(h.childByKey, hasLength(1));
  });
  test('Apply overwrites occupied B label/style but preserves destination, ID, geometry and default', () async {
    final h = Harness();
    const old = DraftChoice(
      choiceId: 'fixed',
      label: 'Manual B',
      targetNodeId: 'existing',
      isDefault: true,
      slot: 'B',
      x: .2,
      y: .7,
      radius: .12,
      icon: 'heart',
      iconColor: 'red',
    );
    h.root = const DraftNode(
      nodeId: 'root',
      title: 'Manual',
      choices: [old],
    ).toJson();
    final bloc = await h.open();
    addTearDown(bloc.close);
    const proposal = SceneProposal(
      title: 'AI title',
      videoPrompt: 'Move',
      choices: [
        SceneProposalChoice(label: 'A'),
        SceneProposalChoice(label: 'Replace B'),
      ],
    );
    await apply(bloc, proposal);
    await apply(bloc, proposal);
    final b = bloc.state.openNode!.choices.singleWhere((c) => c.slot == 'B');
    expect(b.choiceId, 'fixed');
    expect(b.targetNodeId, 'existing');
    expect(b.x, .2);
    expect(b.y, .7);
    expect(b.radius, .12);
    expect(b.isDefault, true);
    expect(b.label, 'Replace B');
    // Reviewed style wins: the proposal carries no icon, so it clears.
    expect(b.icon, isNull);
    expect(b.iconColor, isNull);
    expect(bloc.state.openNode!.title, 'AI title');
    expect(bloc.state.openNode!.videoPrompt, 'Move');
    expect(h.childByKey.keys.single, 'v1:author:story:root:A');
  });
  test('queued saves cannot overwrite Apply with an older snapshot', () async {
    final h = Harness();
    final bloc = await h.open();
    addTearDown(bloc.close);
    final entered = Completer<void>(), release = Completer<void>();
    var held = false;
    h.store.beforeCommit = () async {
      if (!held) {
        held = true;
        entered.complete();
        await release.future;
      }
    };
    bloc.add(const NodeFieldChanged(nodeId: 'root', title: 'Typed'));
    await bloc.stream.firstWhere((s) => s.openNode?.title == 'Typed');
    final saving = bloc.flushNode('root');
    await entered.future;
    bloc.add(
      const SceneProposalApplied(
        nodeId: 'root',
        proposal: SceneProposal(choices: [SceneProposalChoice(label: 'Go')]),
      ),
    );
    final latest = bloc.flushNode('root');
    release.complete();
    await saving;
    await latest;
    expect(h.root['title'], 'Typed');
    expect(h.root['choices'], hasLength(1));
  });
  test('a legacy orphan is reused after reopening without journal or duplicate child', () async {
    final h = Harness();
    h.store.documents['stories/story/nodes/legacy'] = const DraftNode(
      nodeId: 'legacy',
      title: 'Authored orphan',
      requestId: 'v1:author:story:root:A',
      startFromNodeId: 'root',
    ).toJson();
    final bloc = await h.open();
    addTearDown(bloc.close);
    await apply(
      bloc,
      const SceneProposal(
        choices: [
          SceneProposalChoice(label: 'A'),
          SceneProposalChoice(label: 'B'),
        ],
      ),
    );
    expect(bloc.state.openNode!.choices.first.targetNodeId, 'legacy');
    expect(h.children['legacy']!['title'], 'Authored orphan');
    expect(h.children, hasLength(2));
  });
  test('null prompt events preserve values; empty strings clear all prompts and endingName', () async {
    final h = Harness();
    h.root = const DraftNode(
      nodeId: 'root',
      title: 'Scene',
      startImagePrompt: 'S',
      videoPrompt: 'V',
      endingName: 'Name',
    ).toJson();
    final bloc = await h.open();
    addTearDown(bloc.close);
    bloc.add(const NodeFieldChanged(nodeId: 'root'));
    await bloc.flushNode('root');
    expect(h.root['videoPrompt'], 'V');
    bloc.add(
      const NodeFieldChanged(
        nodeId: 'root',
        startImagePrompt: ' ',
        videoPrompt: '',
        endingName: '',
      ),
    );
    await bloc.flushNode('root');
    for (final field in ['startImagePrompt', 'videoPrompt', 'endingName']) {
      expect(h.root[field], isNull);
    }
  });
  test('P3 narration generation persists only the line and idles the previous voice', () async {
    final h = Harness();
    h.root = const DraftNode(
      nodeId: 'root',
      title: 'Authored',
      videoPrompt: 'Keep move',
      ttsText: 'Old line',
      ttsStatus: 'ready',
      ttsAudioUrl: 'old.m4a',
    ).toJson();
    final bloc = await h.open();
    addTearDown(bloc.close);
    final done = bloc.stream.firstWhere(
      (s) => s.job == CreateJob.none && s.openNode?.ttsText == 'Enter or wait?',
    );
    bloc.add(const NarrationGenerateRequested('root'));
    await done;
    expect(h.root['title'], 'Authored');
    expect(h.root['videoPrompt'], 'Keep move');
    expect(h.root['ttsStatus'], 'idle');
    expect(h.root['ttsAudioUrl'], isNull);
    expect(bloc.hasUnsavedNodeEdits('root'), false);
  });
  test('compact scoped answers parse with missing keys as null', () {
    final narration = GeneratedNodeText.fromJson({
      'ttsText': 'You choose.',
    });
    expect(narration.ttsText, 'You choose.');
    expect(narration.title, isNull);
    expect(narration.choices, isEmpty);
    expect(narration.isEmpty, isFalse);

    final options = GeneratedNodeText.fromJson({
      'choices': [
        {'label': 'Enter'},
        {'label': 'Climb'},
      ],
    });
    expect(options.choiceLabels, ['Enter', 'Climb']);
    expect(options.ttsText, isNull);

    expect(GeneratedNodeText.fromJson({}).isEmpty, isTrue);
  });
}
