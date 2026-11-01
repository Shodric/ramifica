import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/widgets/choice_icon.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_event.dart';
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

  test(
    'Script does not require narration; Voice owns the line and approval gate',
    () {
      const scene = DraftNode(nodeId: 'n', title: 'Title');
      expect(firstMissingForStep(step: 0, node: scene, isRoot: true), isNull);
      expect(
        firstMissingForStep(step: 3, node: scene, isRoot: true),
        'the narrator line',
      );
      final written = scene.copy(ttsText: 'Will you enter or wait?');
      expect(
        firstMissingForStep(step: 3, node: written, isRoot: true),
        'approval of the narrator line',
      );
      final approved = written.copy(lineApproved: true);
      expect(
        firstMissingForStep(step: 3, node: approved, isRoot: true),
        'a generated voice',
      );
    },
  );

  for (final width in [390.0, 1200.0]) {
    testWidgets('S4 owns narrator text and approval at width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? line;
      bool? approved;
      var generated = false;
      await mount(
        tester,
        StepVoice(
          node: const DraftNode(nodeId: 'n', ttsText: 'Choose a path'),
          busy: false,
          showErrors: false,
          onLineChanged: (value) => line = value,
          onLineApprovalChanged: (value) => approved = value,
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
      await tester.tap(find.byKey(const ValueKey('approve-line-n')));
      expect(approved, isTrue);
      await tester.tap(find.byKey(const ValueKey('gen-line-n')));
      expect(generated, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'S1 review and Apply fit width $width without changing the node',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SceneProposal? applied;
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
                endImagePrompt: 'End',
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
            onApplyProposal: (p) => applied = p,
          ),
        );
        await tester.enterText(
          find.byKey(const ValueKey('script-direction-root')),
          'A rainy door',
        );
        await tester.pump();
        final format = find.byKey(const ValueKey('script-format-root'));
        await tester.ensureVisible(format);
        await tester.tap(format);
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(applied, isNull);
        expect(node.title, 'Manual title');
        expect(find.text('Kept. Edit in Script.'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('script-prop-end-root')),
          'Reviewed end',
        );
        final apply = find.byKey(const ValueKey('script-apply-root'));
        await tester.ensureVisible(apply);
        await tester.tap(apply);
        await tester.pump();
        expect(applied?.ttsText, isNull);
        expect(find.byKey(const ValueKey('line-root')), findsNothing);
        expect(
          find.byKey(const ValueKey('script-prop-line-root')),
          findsNothing,
        );
        expect(applied?.endImagePrompt, 'Reviewed end');
        expect(applied?.choices.single.icon, 'rocket');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Apply is disabled when the scene and both options are already filled',
    (tester) async {
      const node = DraftNode(
        nodeId: 'root',
        title: 'Title',
        ttsText: 'Line',
        startImagePrompt: 'S',
        endImagePrompt: 'E',
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
      await tester.ensureVisible(
        find.byKey(const ValueKey('script-format-root')),
      );
      await tester.tap(find.byKey(const ValueKey('script-format-root')));
      await tester.pumpAndSettle();
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('script-apply-root')),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets(
    'ending has a manual name editor and no proposed options or child start',
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
      await tester.tap(find.byKey(const ValueKey('script-format-leaf')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('script-prop-start-leaf')),
        findsNothing,
      );
      expect(find.text('Options'), findsNothing);
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

  testWidgets(
    'S2 sends current prompt and children cannot generate their start',
    (tester) async {
      String? sent;
      await mount(
        tester,
        StepFrames(
          node: const DraftNode(nodeId: 'child'),
          isRoot: false,
          inheritedPrompt: 'Parent end',
          busy: false,
          showErrors: false,
          onImageGenerate: (which, prompt) => sent = '$which:$prompt',
        ),
      );
      expect(find.byKey(const ValueKey('gen-image-start-child')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('prompt-end-child')),
        'Revised',
      );
      final generate = find.byKey(const ValueKey('gen-image-end-child'));
      await tester.ensureVisible(generate);
      await tester.tap(generate);
      expect(sent, 'end:Revised');
    },
  );

  testWidgets(
    'S5 sends the edited prompt and disables it during an active job',
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

  testWidgets('S5 resumes a pending job with its submitted prompt', (
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
