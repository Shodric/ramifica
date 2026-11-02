import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/widgets/choice_icon.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/steps/step_script.dart';
import 'package:ramifica/features/create/steps/step_frames.dart';
import 'package:ramifica/features/create/steps/step_clip.dart';
import 'package:ramifica/features/create/steps/step_voice.dart';
import 'package:ramifica/features/create/steps/wizard_gates.dart';
import 'package:ramifica/features/create/premise_sheet.dart';
import 'package:ramifica/features/create/voice_recorder.dart';

Future<void> mount(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

class DeniedRecorder extends FakeVoiceRecorder {
  @override
  Future<void> start() async => throw StateError('permission denied');
}

void main() {
  test('Flutter icon and color catalogs mirror catalog.json', () {
    final catalog = jsonDecode(File('catalog.json').readAsStringSync()) as Map;
    expect(choiceIconOptions.map((o) => o.name).toList(), catalog['icons']);
    expect(
      choiceColorOptions.map((o) => o.name).toList(),
      catalog['iconColors'],
    );
  });

  test('icon search matches names and labels, blank returns all', () {
    expect(filterChoiceIcons(''), hasLength(choiceIconOptions.length));
    expect(filterChoiceIcons('  '), hasLength(choiceIconOptions.length));

    expect(
      filterChoiceIcons('moon').map((o) => o.name),
      containsAll(['moon', 'moonshield']),
    );
    expect(filterChoiceIcons('Hoop').map((o) => o.name), contains('hoop'));
    expect(filterChoiceIcons('zzz-no-such-icon'), isEmpty);
  });

  test('icon search matches tags across related options', () {
    expect(
      filterChoiceIcons('money').map((o) => o.name),
      containsAll(['cash', 'coin', 'card', 'wallet', 'bank']),
    );
    expect(
      filterChoiceIcons('bill').map((o) => o.name),
      containsAll(['cash', 'ticket', 'receipt']),
    );
    expect(filterChoiceIcons('ghost').map((o) => o.name), contains('unseen'));
  });

  test('every icon maps to a labeled section in order', () {
    for (final option in choiceIconOptions) {
      expect(
        choiceIconSections[option.name],
        isNotNull,
        reason: '${option.name} has no section',
      );
      expect(kIconSectionOrder, contains(choiceIconSections[option.name]));
    }
    for (final section in kIconSectionOrder) {
      expect(kIconSectionLabels[section], isNotNull);
      expect(
        choiceIconOptions.any((o) => iconSectionOf(o.name) == section),
        isTrue,
        reason: '$section is empty',
      );
    }
  });

  test(
    'Script requires title and narrator line; voice needs a take, not approval',
    () {
      const untitled = DraftNode(nodeId: 'n');
      expect(
        firstMissingForStep(step: 0, node: untitled, isRoot: true),
        'a scene title (1-40 characters)',
      );
      const scene = DraftNode(nodeId: 'n', title: 'Title');
      expect(
        firstMissingForStep(step: 0, node: scene, isRoot: true),
        'the narrator line',
      );
      final written = scene.copy(ttsText: 'Will you enter or wait?');
      expect(firstMissingForStep(step: 0, node: written, isRoot: true), isNull);
      expect(
        firstMissingForStep(step: 1, node: written, isRoot: true),
        'a generated start frame',
      );
      expect(
        firstMissingForStep(step: 2, node: written, isRoot: true),
        'a generated voice',
      );
    },
  );

  for (final width in [390.0, 1200.0]) {
    testWidgets('S3 edits narrator text and generates voice at width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? line;
      var generated = false;
      await mount(
        tester,
        StepVoice(
          node: const DraftNode(nodeId: 'n', ttsText: 'Choose a path'),
          busy: false,
          showErrors: false,
          onLineChanged: (value) => line = value,
          onLineGenerate: () => generated = true,
        ),
      );
      expect(
        find.textContaining('just before the player chooses'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('line-n')),
        'Enter or wait?',
      );
      expect(line, 'Enter or wait?');
      await tester.tap(find.byKey(const ValueKey('gen-line-n')));
      expect(generated, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'S1 auto-proposal applies unreviewed fields and preserves the manual title at width $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var calls = 0;
        const node = DraftNode(nodeId: 'root', title: 'Manual title');
        await mount(
          tester,
          StepScript(
            node: node,
            isRoot: true,
            busy: false,
            showErrors: false,
            propose: (_) async {
              calls++;
              return const GeneratedNodeText(
                title: 'AI title',
                ttsText: 'Choose',
                startImagePrompt: 'Start',
                videoPrompt: 'Move',
                choices: [
                  GeneratedChoice(
                    label: 'Go',
                    icon: 'rocket',
                    iconColor: 'mint',
                  ),
                ],
              );
            },
          ),
        );
        await tester.enterText(
          find.byKey(const ValueKey('script-direction-root')),
          'A rainy door',
        );
        await tester.pump();
        // No review UI: no format bar, no accordion, no apply button.
        expect(
          find.byKey(const ValueKey('script-proposal-bar-root')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('script-format-root')), findsNothing);
        expect(find.byKey(const ValueKey('script-apply-root')), findsNothing);
        final state = tester.state<StepScriptState>(find.byType(StepScript));
        expect(state.directionReady, isTrue);
        final proposal = await state.proposeDirection();
        await tester.pump();
        expect(calls, 1);
        expect(proposal?.ttsText, 'Choose');
        expect(proposal?.videoPrompt, 'Move');
        expect(proposal?.startImagePrompt, 'Start');
        expect(proposal?.choices.single.label, 'Go');
        expect(proposal?.choices.single.icon, 'rocket');
        // The manual title is preserved, not overwritten.
        expect(proposal?.title, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('S1 shows a proposing indicator mid-flight', (tester) async {
    final gate = Completer<void>();
    await mount(
      tester,
      StepScript(
        node: const DraftNode(nodeId: 'root'),
        isRoot: true,
        busy: false,
        showErrors: false,
        propose: (_) async {
          await gate.future;
          return const GeneratedNodeText(title: 'AI title');
        },
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('script-direction-root')),
      'A rainy door',
    );
    await tester.pump();
    final state = tester.state<StepScriptState>(find.byType(StepScript));
    final pending = state.proposeDirection();
    await tester.pump();
    expect(find.byKey(const ValueKey('script-proposing-root')), findsOneWidget);
    gate.complete();
    final proposal = await pending;
    await tester.pump();
    expect(proposal?.title, 'AI title');
    expect(find.byKey(const ValueKey('script-proposing-root')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'auto-proposal overwrites options and prompts but preserves the title',
    (tester) async {
      const node = DraftNode(
        nodeId: 'root',
        title: 'Title',
        ttsText: 'Line',
        startImagePrompt: 'S',
        videoPrompt: 'V',
        choices: [
          DraftChoice(
            choiceId: 'a',
            label: 'A',
            targetNodeId: 'a',
            slot: 'A',
            isDefault: true,
            icon: 'key',
            iconColor: 'blue',
          ),
          DraftChoice(
            choiceId: 'b',
            label: 'B',
            targetNodeId: 'b',
            slot: 'B',
            isDefault: false,
            icon: 'heart',
            iconColor: 'red',
          ),
        ],
      );
      await mount(
        tester,
        StepScript(
          node: node,
          isRoot: true,
          busy: false,
          showErrors: false,
          propose: (_) async => const GeneratedNodeText(
            title: 'Other',
            choices: [
              GeneratedChoice(label: 'Other A', icon: 'rocket'),
              GeneratedChoice(label: 'Other B'),
            ],
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('script-direction-root')),
        'Direction',
      );
      await tester.pump();
      final state = tester.state<StepScriptState>(find.byType(StepScript));
      final proposal = await state.proposeDirection();
      await tester.pump();
      expect(proposal?.title, isNull);
      expect(proposal?.choices.map((c) => c.label).toList(), [
        'Other A',
        'Other B',
      ]);
      expect(proposal?.choices.first.icon, 'rocket');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ending auto-proposal drops options and child start, preserves the name',
    (tester) async {
      String? changed;
      await mount(
        tester,
        StepScript(
          node: const DraftNode(
            nodeId: 'leaf',
            isEnding: true,
            endingName: 'Old',
          ),
          isRoot: false,
          busy: false,
          showErrors: false,
          onEndingNameChanged: (s) => changed = s,
          propose: (_) async => const GeneratedNodeText(
            ttsText: 'The end.',
            endingName: 'AI',
            choices: [GeneratedChoice(label: 'Bad')],
            startImagePrompt: 'Bad',
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('ending-name-leaf')),
        'New',
      );
      expect(changed, 'New');
      await tester.enterText(
        find.byKey(const ValueKey('script-direction-leaf')),
        'The ending',
      );
      await tester.pump();
      final state = tester.state<StepScriptState>(find.byType(StepScript));
      final proposal = await state.proposeDirection();
      await tester.pump();
      expect(proposal?.ttsText, 'The end.');
      expect(proposal?.endingName, isNull);
      expect(proposal?.choices, isEmpty);
      expect(proposal?.startImagePrompt, isNull);
      expect(find.text('Options'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a denied microphone preserves typed S1 direction', (
    tester,
  ) async {
    await mount(
      tester,
      StepScript(
        node: const DraftNode(nodeId: 'root'),
        isRoot: true,
        busy: false,
        showErrors: false,
        recorder: DeniedRecorder(),
      ),
    );
    final field = find.byKey(const ValueKey('script-direction-root'));
    await tester.enterText(field, 'Keep this direction');
    await tester.tap(find.byKey(const ValueKey('script-direction-voice-fab')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field).controller!.text,
      'Keep this direction',
    );
    expect(find.text('Microphone is unavailable.'), findsOneWidget);
  });

  testWidgets('S0 microphone failure preserves the existing idea', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PremiseSheet(
            embedded: true,
            initialIdea: 'Keep my idea',
            recorder: DeniedRecorder(),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('premise-voice-fab')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('premise-transcript')))
          .controller!
          .text,
      'Keep my idea',
    );
  });

  testWidgets('S2 sends the current start prompt on the root', (tester) async {
    String? sent;
    await mount(
      tester,
      StepFrames(
        node: const DraftNode(nodeId: 'root'),
        isRoot: true,
        busy: false,
        showErrors: false,
        onImageGenerate: (which, prompt) => sent = '$which:$prompt',
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('prompt-start-root')),
      'Revised',
    );
    final generate = find.byKey(const ValueKey('gen-image-start-root'));
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    expect(sent, 'start:Revised');
  });

  testWidgets('S2 shows the inherited frame read-only for children', (
    tester,
  ) async {
    await mount(
      tester,
      StepFrames(
        node: const DraftNode(nodeId: 'child'),
        isRoot: false,
        inheritedImageUrl: 'https://example.com/f.png',
        inheritedCaption: 'Inherited from Scene 1',
        busy: false,
        showErrors: false,
        onImageGenerate: (_, _) => fail('children cannot generate'),
      ),
    );
    expect(find.text('Inherited'), findsOneWidget);
    expect(find.text('Inherited from Scene 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('gen-image-start-child')), findsNothing);
    expect(find.byKey(const ValueKey('gen-image-end-child')), findsNothing);
    expect(find.byKey(const ValueKey('prompt-start-child')), findsNothing);
    expect(find.byKey(const ValueKey('prompt-end-child')), findsNothing);
  });

  testWidgets(
    'S4 sends the edited prompt and disables it during an active job',
    (tester) async {
      String? sent;
      await mount(
        tester,
        StepClip(
          node: const DraftNode(nodeId: 'root', videoPrompt: 'Old'),
          busy: false,
          showErrors: false,
          onVideoGenerate: (p) => sent = p,
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('video-prompt-root')),
        'Revised motion',
      );
      await tester.tap(find.byKey(const ValueKey('gen-video-root')));
      expect(sent, 'Revised motion');
      await mount(
        tester,
        const StepClip(
          node: DraftNode(
            nodeId: 'root',
            videoPrompt: 'Submitted',
            videoStatus: 'pending',
          ),
          busy: true,
          showErrors: false,
        ),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('video-prompt-root')))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('gen-video-root')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('S4 resumes a pending job with its submitted prompt', (
    tester,
  ) async {
    String? sent;
    await mount(
      tester,
      StepClip(
        node: const DraftNode(
          nodeId: 'root',
          videoPrompt: 'Submitted motion',
          videoStatus: 'pending',
          videoJobId: 'or_existing-job',
        ),
        busy: false,
        showErrors: false,
        onVideoGenerate: (prompt) => sent = prompt,
      ),
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('video-prompt-root')))
          .enabled,
      isFalse,
    );
    expect(find.text('Continue generation'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gen-video-root')));
    expect(sent, 'Submitted motion');
  });
}
