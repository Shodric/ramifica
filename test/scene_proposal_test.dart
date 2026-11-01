import 'support/create_repository_harness.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';
import 'package:ramifica/features/create/create_node_screen.dart';
import 'package:ramifica/features/create/steps/step_frames.dart';

Map<String, dynamic> clone(Map<String, dynamic> data) => {
  ...data,
  'choices': [
    for (final c in data['choices'] as List) {...c as Map},
  ],
};

class Harness {
  Map<String, dynamic> root = const DraftNode(
    nodeId: 'root',
    title: 'Original',
  ).toJson();
  final children = <String, Map<String, dynamic>>{};
  final childByKey = <String, String>{};
  final calls = <String>[];
  int reads = 0;
  int writes = 0;
  final saveChoices = <List<Map<String, dynamic>>>[];
  Future<void> Function(int)? beforeRead;
  Future<void> Function(int)? beforeWrite;

  late final repository = testCreateRepository(
    createDraftDoc: ({required authorId, required title}) async => 'story',
    fetchStoryDoc: (_) async => {
      'authorId': 'author',
      'title': 'Story',
      'synopsis': 'Existing premise',
      'rootNodeId': 'root',
    },
    fetchNodeDocs: (_) async {
      reads++;
      await beforeRead?.call(reads);
      return [MapEntry('root', clone(root)), ...children.entries];
    },
    callFunction: (name, data) async {
      calls.add(name);
      if (name == 'generateNodeText') {
        return {
          'title': 'Gate',
          'ttsText': 'Enter or wait?',
          'startImagePrompt': 'Opening',
          'endImagePrompt': 'Closing',
          'videoPrompt': 'Slow move',
          'choices': [
            {'label': 'Enter', 'icon': 'key', 'iconColor': 'gold'},
            {'label': 'Wait', 'icon': 'clock', 'iconColor': 'blue'},
          ],
        };
      }
      if (name == 'generateNodeImage') {
        final which = data['which'] as String;
        root = {
          ...root,
          '${which}ImageSourceUrl': 'https://example.invalid/$which.png',
          '${which}ImageStatus': 'ready',
          '${which}ImageApproved': false,
          '${which}Hash': 'hash-$which',
        };
        return {};
      }
      if (name == 'approveNodeImage') {
        root['${data['which']}ImageApproved'] = data['approved'];
        return {};
      }
      if (name == 'generateNodeVoice') {
        expectSync(root['lineApproved'], isTrue);
        root = {
          ...root,
          'ttsStatus': 'ready',
          'ttsAudioUrl': 'https://example.invalid/voice.wav',
          'ttsDurationSeconds': 1,
          'ttsApproved': false,
        };
        return {};
      }
      if (name == 'generateNodeVideo') {
        expectSync(root['startImageApproved'], isTrue);
        expectSync(root['endImageApproved'], isTrue);
        root = {
          ...root,
          'videoStatus': 'ready',
          'videoUrl': 'https://example.invalid/clip.mp4',
        };
        return {'poll': false};
      }
      if (name != 'createNode') throw StateError('unexpected $name');
      final key = data['requestId'] as String;
      final id = childByKey.putIfAbsent(
        key,
        () => 'child_${childByKey.length}',
      );
      children.putIfAbsent(
        id,
        () => DraftNode(
          nodeId: id,
          startFromNodeId: data['parentNodeId'] as String,
        ).toJson(),
      );
      return {'nodeId': id};
    },
    saveNodeDoc: ({required storyId, required nodeId, required node}) async {
      writes++;
      await beforeWrite?.call(writes);
      final patch = nodeSavePatch(node, root['ttsText'] as String);
      root = {...root, ...patch};
      saveChoices.add([
        for (final c in root['choices'] as List)
          Map<String, dynamic>.from(c as Map),
      ]);
    },
  );

  Future<CreateBloc> open() async {
    final bloc = CreateBloc(repository: repository);
    final ready = bloc.stream.firstWhere(
      (s) => s.story != null && s.job == CreateJob.none,
    );
    bloc.add(const DraftOpened('story'));
    await ready;
    return bloc;
  }
}

void main() {
  testWidgets('ready frames remain visible and offer another take', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StepFrames(
              node: DraftNode(
                nodeId: 'root',
                startImageSourceUrl: 'https://example.invalid/s.png',
                endImageSourceUrl: 'https://example.invalid/e.png',
                startImageStatus: 'ready',
                endImageStatus: 'ready',
              ),
              isRoot: true,
              busy: false,
              showErrors: false,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('Another take'), findsNWidgets(2));
  });

  test(
    'Apply preserves edits made while the preliminary fetch is pending',
    () async {
      final h = Harness();
      final bloc = await h.open();
      addTearDown(bloc.close);
      final entered = Completer<void>();
      final release = Completer<void>();
      h.beforeRead = (read) async {
        if (read == 2) {
          entered.complete();
          await release.future;
        }
      };
      bloc.add(
        const SceneProposalApplied(
          nodeId: 'root',
          proposal: SceneProposal(endImagePrompt: 'New prompt'),
        ),
      );
      await entered.future;
      expect(
        bloc.state.job,
        CreateJob.saving,
        reason: 'Apply stays busy through its reload',
      );
      final edited = bloc.stream.firstWhere(
        (s) => s.openNode?.title == 'Typed during reload',
      );
      bloc.add(
        const NodeFieldChanged(nodeId: 'root', title: 'Typed during reload'),
      );
      await edited;
      final done = bloc.stream.firstWhere(
        (s) =>
            s.job == CreateJob.none &&
            s.openNode?.endImagePrompt == 'New prompt',
      );
      release.complete();
      await done;
      expect(bloc.state.openNode?.title, 'Typed during reload');
    },
  );

  test('Apply retry must preserve the choiceId already saved before a failed reload', () async {
    final h = Harness();
    final bloc = await h.open();
    addTearDown(bloc.close);
    h.beforeRead = (read) async {
      if (read >= 3) throw const AppFailure(.offline);
    };
    const apply = SceneProposalApplied(
      nodeId: 'root',
      proposal: SceneProposal(choices: [SceneProposalChoice(label: 'Go')]),
    );
    final failed = bloc.stream.firstWhere(
      (s) => s.failure != null && s.job == CreateJob.none,
    );
    bloc.add(apply);
    await failed;
    final firstId = (h.root['choices'] as List).single['choiceId'];
    expect(bloc.state.openNode?.choices.single.choiceId, firstId);
    h.beforeRead = null;
    final done = bloc.stream.firstWhere(
      (s) =>
          s.failure == null &&
          s.job == CreateJob.none &&
          s.openNode!.choices.isNotEmpty,
    );
    bloc.add(apply);
    await done;
    final lastId = (h.root['choices'] as List).single['choiceId'];
    expect(lastId, firstId);
  });
  test(
    'Apply preserves occupied B and only creates the missing A slot',
    () async {
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
        ttsText: 'New line',
        startImagePrompt: 'Start',
        endImagePrompt: 'End',
        videoPrompt: 'Move',
        choices: [
          SceneProposalChoice(label: 'A', icon: 'rocket', iconColor: 'mint'),
          SceneProposalChoice(
            label: 'Replace B',
            icon: 'key',
            iconColor: 'blue',
          ),
        ],
      );
      Future<void> apply() async {
        final done = bloc.stream.firstWhere(
          (s) => s.job == CreateJob.none && s.openNode!.choices.length == 2,
        );
        bloc.add(
          const SceneProposalApplied(nodeId: 'root', proposal: proposal),
        );
        await done;
      }

      await apply();
      final saved = bloc.state.openNode!;
      expect(saved.title, 'Manual');
      expect(saved.ttsText, 'New line');
      expect(saved.lineApproved, isFalse);
      expect(saved.startImagePrompt, 'Start');
      expect(saved.videoPrompt, 'Move');
      expect(saved.choices.singleWhere((c) => c.slot == 'B'), old);
      expect(h.childByKey.keys.single, 'v1:author:story:root:A');
      final ids = saved.choices.map((c) => c.choiceId).toList();
      await apply();
      expect(bloc.state.openNode!.choices.map((c) => c.choiceId), ids);
      expect(h.childByKey, hasLength(1));
    },
  );

  test(
    'a failed parent save is retried without changing the local choice ID',
    () async {
      final h = Harness();
      final bloc = await h.open();
      addTearDown(bloc.close);
      h.beforeWrite = (_) async => throw const AppFailure(.offline);
      const apply = SceneProposalApplied(
        nodeId: 'root',
        proposal: SceneProposal(choices: [SceneProposalChoice(label: 'Go')]),
      );
      final failed = bloc.stream.firstWhere(
        (s) => s.job == CreateJob.none && s.failure != null,
      );
      bloc.add(apply);
      await failed;
      final local = bloc.state.openNode!.choices.single;
      expect(h.childByKey, hasLength(1));
      expect(h.root['choices'], isEmpty);
      h.beforeWrite = null;
      final done = bloc.stream.firstWhere(
        (s) =>
            s.job == CreateJob.none &&
            s.failure == null &&
            s.openNode!.choices.isNotEmpty,
      );
      bloc.add(apply);
      await done;
      expect(bloc.state.openNode!.choices.single.choiceId, local.choiceId);
      expect((h.root['choices'] as List).single['choiceId'], local.choiceId);
      expect(h.childByKey, hasLength(1));
    },
  );

  test(
    'queued explicit saves cannot overwrite Apply with an older node',
    () async {
      final h = Harness();
      final bloc = await h.open();
      addTearDown(bloc.close);
      final entered = Completer<void>();
      final release = Completer<void>();
      h.beforeWrite = (write) async {
        if (write == 1) {
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
      expect(bloc.state.openNode!.choices, hasLength(1));
      expect(h.root['choices'], hasLength(1));
    },
  );

  test(
    'reload recovers an orphan by the same slot key after link failure',
    () async {
      final h = Harness();
      final first = await h.open();
      h.beforeWrite = (_) async => throw const AppFailure(.offline);
      final failed = first.stream.firstWhere(
        (s) => s.job == CreateJob.none && s.failure != null,
      );
      first.add(
        const SceneProposalApplied(
          nodeId: 'root',
          proposal: SceneProposal(
            choices: [SceneProposalChoice(label: 'Old A')],
          ),
        ),
      );
      await failed;
      expect(h.root['choices'], isEmpty);
      final childId = h.childByKey.values.single;
      h.children[childId]!['title'] = 'Authored orphan';
      await first.close();

      h.beforeWrite = null;
      final reloaded = await h.open();
      addTearDown(reloaded.close);
      final done = reloaded.stream.firstWhere(
        (s) => s.job == CreateJob.none && s.openNode!.choices.length == 2,
      );
      reloaded.add(
        const SceneProposalApplied(
          nodeId: 'root',
          proposal: SceneProposal(
            choices: [
              SceneProposalChoice(label: 'Revised A'),
              SceneProposalChoice(label: 'New B'),
            ],
          ),
        ),
      );
      await done;
      expect(h.childByKey, hasLength(2));
      expect(reloaded.state.openNode!.choices.first.targetNodeId, childId);
      expect(h.children[childId]!['title'], 'Authored orphan');
    },
  );

  test(
    'clearing prompts and endingName persists null; null events preserve them',
    () async {
      final h = Harness();
      h.root = const DraftNode(
        nodeId: 'root',
        startImagePrompt: 'S',
        endImagePrompt: 'E',
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
          endImagePrompt: '',
          videoPrompt: '',
          endingName: '',
        ),
      );
      await bloc.flushNode('root');
      for (final key in [
        'startImagePrompt',
        'endImagePrompt',
        'videoPrompt',
        'endingName',
      ]) {
        expect(h.root[key], isNull);
      }
    },
  );
  test('S4 narration generation only updates the decision text and invalidates voice', () async {
    final h = Harness();
    h.root = const DraftNode(
      nodeId: 'root',
      title: 'Authored scene',
      endImagePrompt: 'Keep the frame',
      ttsText: 'Old line',
      lineApproved: true,
      ttsApproved: true,
      ttsStatus: 'ready',
      ttsAudioUrl: 'old.wav',
      ttsDurationSeconds: 2,
    ).toJson();
    final bloc = await h.open();
    addTearDown(bloc.close);
    final done = bloc.stream.firstWhere(
      (s) => s.job == CreateJob.none && s.openNode?.ttsText == 'Enter or wait?',
    );
    bloc.add(const NarrationGenerateRequested('root'));
    await done;
    final node = bloc.state.openNode!;
    expect(node.title, 'Authored scene');
    expect(node.endImagePrompt, 'Keep the frame');
    expect(node.choices, isEmpty);
    expect(node.lineApproved, isFalse);
    expect(node.ttsApproved, isFalse);
    expect(node.ttsAudioUrl, isNull);
    expect(node.ttsStatus, 'idle');
    expect(h.root['ttsText'], 'Enter or wait?');
    expect(bloc.hasUnsavedNodeEdits('root'), isFalse);
  });

  testWidgets(
    'wizard completes S1 through S5 with reviewed prompts and explicit approvals',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = Harness();
      h.root = const DraftNode(nodeId: 'root').toJson();
      final bloc = await h.open();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        var done = false;
        final closed = bloc.close().then((_) => done = true);
        for (var i = 0; i < 30 && !done; i++) {
          await tester.pump();
          await tester.runAsync(() async {});
        }
        expect(done, isTrue);
        await closed;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CreateNodeScreen(
            bloc: bloc,
            nodeId: 'root',
            pickVideo: null,
            newTakeId: () => 'take',
          ),
        ),
      );
      Future<void> tap(String key) async {
        final finder = find.byKey(ValueKey(key));
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'after tapping $key');
      }

      await tap('wizard-continue');
      await tester.enterText(
        find.byKey(const ValueKey('script-direction-root')),
        'A gate in the rain',
      );
      await tester.pump();
      await tap('script-format-root');
      expect(bloc.state.openNode!.ttsText, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('script-prop-end-root')),
        'Reviewed closing frame',
      );
      await tap('script-apply-root');
      expect(bloc.state.openNode!.endImagePrompt, 'Reviewed closing frame');
      expect(bloc.state.openNode!.choices, hasLength(2));
      expect(bloc.state.openNode!.lineApproved, isFalse);
      expect(bloc.state.openNode!.ttsText, isEmpty);
      expect(find.byKey(const ValueKey('line-root')), findsNothing);
      await tap('wizard-continue');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('prompt-end-root')))
            .controller!
            .text,
        'Reviewed closing frame',
      );
      await tap('gen-image-start-root');
      await tap('approve-start-root');
      await tap('gen-image-end-root');
      await tap('approve-end-root');
      await tap('wizard-continue');
      await tap('wizard-continue');
      expect(find.byKey(const ValueKey('line-root')), findsOneWidget);
      await tap('gen-line-root');
      expect(bloc.state.openNode!.ttsText, 'Enter or wait?');
      expect(bloc.state.openNode!.lineApproved, isFalse);
      await tap('wizard-continue');
      expect(find.byKey(const ValueKey('line-root')), findsOneWidget);
      await tap('approve-line-root');
      await tap('gen-voice-root');
      await tap('approve-voice-root');
      await tap('wizard-continue');
      await tester.enterText(
        find.byKey(const ValueKey('video-prompt-root')),
        'Reviewed motion',
      );
      await tap('gen-video-root');
      expect(bloc.state.openNode!.videoStatus, 'ready');
      expect(h.root['videoPrompt'], 'Reviewed motion');
      expect(h.calls.where((c) => c == 'generateNodeText'), hasLength(2));
      expect(h.calls.where((c) => c == 'generateNodeVoice'), hasLength(1));
      expect(h.childByKey, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );
}
