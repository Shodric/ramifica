import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/widgets/choice_icon.dart';
import 'package:ramifica/data/models/app_failure.dart';
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

/// The frame-slot image showing [url].
Finder frameImage(String url) => find.byWidgetPredicate(
  (widget) =>
      widget is Image &&
      widget.image is NetworkImage &&
      (widget.image as NetworkImage).url == url,
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

  test('Script requires only a title; voice gates the line, not approval', () {
    const untitled = DraftNode(nodeId: 'n');
    expect(
      firstMissingForStep(step: 0, node: untitled, isRoot: true),
      'a scene title (1-40 characters)',
    );
    const scene = DraftNode(nodeId: 'n', title: 'Title');
    expect(firstMissingForStep(step: 0, node: scene, isRoot: true), isNull);
    final written = scene.copy(ttsText: 'Will you enter or wait?');
    expect(firstMissingForStep(step: 0, node: written, isRoot: true), isNull);
    expect(
      firstMissingForStep(step: 1, node: written, isRoot: true),
      'a generated start frame',
    );
    final referenced = written.copy(
      startImageReferenceUrl: () => 'https://storage.invalid/r.jpg',
    );
    expect(
      firstMissingForStep(step: 1, node: referenced, isRoot: true),
      isNull,
    );
    expect(
      firstMissingForStep(step: 2, node: written, isRoot: true),
      'a generated voice',
    );
  });

  for (final width in [390.0, 1200.0]) {
    testWidgets('S3 edits narrator text and generates voice at width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? line;
      await mount(
        tester,
        StepVoice(
          node: const DraftNode(nodeId: 'n', ttsText: 'Choose a path'),
          busy: false,
          showErrors: false,
          onLineChanged: (value) => line = value,
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
      expect(find.text('Suggest line'), findsNothing);
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
            propose: (_, {purpose}) async {
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

  testWidgets('S1 proposes with no mid-flight indicator', (tester) async {
    final gate = Completer<void>();
    await mount(
      tester,
      StepScript(
        node: const DraftNode(nodeId: 'root'),
        isRoot: true,
        busy: false,
        showErrors: false,
        propose: (_, {purpose}) async {
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
    expect(find.byKey(const ValueKey('script-proposing-root')), findsNothing);
    expect(find.text('Proposing scene…'), findsNothing);
    gate.complete();
    final proposal = await pending;
    await tester.pump();
    expect(proposal?.title, 'AI title');
    expect(tester.takeException(), isNull);
  });

  testWidgets('proposeDirection forwards the requested purpose', (
    tester,
  ) async {
    String? seen;
    await mount(
      tester,
      StepScript(
        node: const DraftNode(nodeId: 'root'),
        isRoot: true,
        busy: false,
        showErrors: false,
        propose: (_, {purpose}) async {
          seen = purpose;
          return const GeneratedNodeText(ttsText: 'You choose.');
        },
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('script-direction-root')),
      'A rainy door',
    );
    await tester.pump();
    final state = tester.state<StepScriptState>(find.byType(StepScript));
    await state.proposeDirection(purpose: 'narration');
    expect(seen, 'narration');
    await state.proposeDirection();
    expect(seen, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('takeProposalError returns the reason once', (tester) async {
    await mount(
      tester,
      StepScript(
        node: const DraftNode(nodeId: 'root'),
        isRoot: true,
        busy: false,
        showErrors: false,
        propose: (_, {purpose}) async => throw const AppFailure(.failed),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('script-direction-root')),
      'A rainy door',
    );
    await tester.pump();
    final state = tester.state<StepScriptState>(find.byType(StepScript));
    expect(await state.proposeDirection(), isNull);
    final reason = state.takeProposalError();
    expect(reason, isNotNull);
    expect(state.takeProposalError(), isNull);
    await tester.pump();
    expect(find.text(reason!), findsNothing);
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
          propose: (_, {purpose}) async => const GeneratedNodeText(
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
    'ending auto-proposal drops options and child start, preserves the title',
    (tester) async {
      await mount(
        tester,
        StepScript(
          node: const DraftNode(nodeId: 'leaf', isEnding: true, title: 'Old'),
          isRoot: false,
          busy: false,
          showErrors: false,
          propose: (_, {purpose}) async => const GeneratedNodeText(
            ttsText: 'The end.',
            title: 'AI',
            choices: [GeneratedChoice(label: 'Bad')],
            startImagePrompt: 'Bad',
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('script-direction-leaf')),
        'The ending',
      );
      await tester.pump();
      final state = tester.state<StepScriptState>(find.byType(StepScript));
      final proposal = await state.proposeDirection();
      await tester.pump();
      expect(proposal?.ttsText, 'The end.');
      expect(proposal?.title, isNull);
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

  testWidgets('S2 reference upload button fires and hides without wiring', (
    tester,
  ) async {
    var tapped = false;
    await mount(
      tester,
      StepFrames(
        node: const DraftNode(nodeId: 'root'),
        busy: false,
        showErrors: false,
        onUploadReference: () => tapped = true,
      ),
    );
    final upload = find.byKey(const ValueKey('upload-reference-root'));
    await tester.ensureVisible(upload);
    await tester.tap(upload);
    expect(tapped, isTrue);

    await mount(
      tester,
      const StepFrames(
        node: DraftNode(nodeId: 'root'),
        busy: false,
        showErrors: false,
      ),
    );
    expect(find.byKey(const ValueKey('upload-reference-root')), findsNothing);
    expect(find.text('Reference'), findsNothing);
  });

  testWidgets('S2 reference row shows progress while the still goes up', (
    tester,
  ) async {
    await mount(
      tester,
      StepFrames(
        node: const DraftNode(nodeId: 'root'),
        busy: true,
        showErrors: false,
        uploadProgress: 0.5,
        onUploadReference: () {},
      ),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('reference-upload-progress-root')),
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('reference-upload-progress-root')),
          )
          .value,
      0.5,
    );
    expect(find.text('Uploading reference… 50%'), findsOneWidget);
  });

  testWidgets('S2 reference overwrites the generated frame slot', (
    tester,
  ) async {
    // No settle: the URLs never resolve in tests; the slot mounts the
    // reference (badged) instead of the generated still immediately.
    await mount(
      tester,
      StepFrames(
        node: const DraftNode(
          nodeId: 'root',
          startImageSourceUrl: 'https://cdn.invalid/generated.png',
          startImageStatus: 'ready',
          startImageReferenceUrl: 'https://storage.invalid/r.jpg',
        ),
        busy: false,
        showErrors: false,
        onUploadReference: () {},
        onReferenceRemoved: () {},
      ),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('reference-badge-root')),
    );
    expect(frameImage('https://storage.invalid/r.jpg'), findsOneWidget);
    expect(frameImage('https://cdn.invalid/generated.png'), findsNothing);
    // The generated frame is still one regen away.
    expect(find.text('Another take'), findsOneWidget);
  });

  testWidgets('S2 reference without a frame keeps Generate below', (
    tester,
  ) async {
    String? sent;
    await mount(
      tester,
      StepFrames(
        node: const DraftNode(
          nodeId: 'root',
          startImageReferenceUrl: 'https://storage.invalid/r.jpg',
        ),
        busy: false,
        showErrors: false,
        onImageGenerate: (which, prompt) => sent = '$which:$prompt',
        onUploadReference: () {},
        onReferenceRemoved: () {},
      ),
    );
    final generate = find.byKey(const ValueKey('gen-image-start-root'));
    await tester.ensureVisible(generate);
    // The slot shows the reference; the gate still needs its S.
    expect(frameImage('https://storage.invalid/r.jpg'), findsOneWidget);
    await tester.tap(generate);
    expect(sent, 'start:');
  });

  testWidgets('S2 reference row offers change and remove', (tester) async {
    var changed = false;
    var removed = false;
    await mount(
      tester,
      StepFrames(
        node: const DraftNode(
          nodeId: 'root',
          startImageReferenceUrl: 'https://storage.invalid/r.jpg',
        ),
        busy: false,
        showErrors: false,
        onUploadReference: () => changed = true,
        onReferenceRemoved: () => removed = true,
      ),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('reference-badge-root')),
    );
    expect(find.text('Change'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('upload-reference-root')));
    expect(changed, isTrue);
    await tester.tap(find.byKey(const ValueKey('remove-reference-root')));
    expect(removed, isTrue);
  });

  testWidgets('S2 busy blocks the reference controls', (tester) async {
    await mount(
      tester,
      StepFrames(
        node: const DraftNode(
          nodeId: 'root',
          startImageReferenceUrl: 'https://storage.invalid/r.jpg',
        ),
        busy: true,
        showErrors: false,
        onUploadReference: () {},
        onReferenceRemoved: () {},
      ),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('reference-badge-root')),
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('upload-reference-root')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('remove-reference-root')),
          )
          .onPressed,
      isNull,
    );
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
    // No status row: the button label already names the running job.
    expect(find.text('Generating video…'), findsNothing);
    expect(find.text('Processing video…'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('gen-video-root')));
    expect(sent, 'Submitted motion');
  });

  testWidgets('S4 hides the prompt card while generating', (tester) async {
    await mount(
      tester,
      StepClip(
        node: const DraftNode(
          nodeId: 'root',
          videoPrompt: 'Submitted motion',
          videoStatus: 'pending',
        ),
        busy: true,
        generating: true,
        showErrors: false,
        active: true,
        continueAction: const Text('Continue'),
      ),
    );
    expect(find.byKey(const ValueKey('video-prompt-root')), findsNothing);
    expect(find.byKey(const ValueKey('gen-video-root')), findsNothing);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('S4 hides the prompt card while uploading, keeps progress', (
    tester,
  ) async {
    await mount(
      tester,
      StepClip(
        node: const DraftNode(nodeId: 'root', videoPrompt: 'Clip idea'),
        busy: true,
        generating: true,
        showErrors: false,
        uploadProgress: 0.4,
        active: true,
        continueAction: const Text('Continue'),
      ),
    );
    expect(find.byKey(const ValueKey('video-prompt-root')), findsNothing);
    expect(find.byKey(const ValueKey('gen-video-root')), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('S4 shows the prompt card again when the clip fails', (
    tester,
  ) async {
    await mount(
      tester,
      StepClip(
        node: const DraftNode(
          nodeId: 'root',
          videoPrompt: 'Clip idea',
          videoStatus: 'failed',
        ),
        busy: false,
        generating: true,
        showErrors: false,
        onVideoGenerate: (_) {},
      ),
    );
    expect(find.byKey(const ValueKey('video-prompt-root')), findsOneWidget);
    expect(find.byKey(const ValueKey('gen-video-root')), findsOneWidget);
    expect(
      find.text('Video generation failed. Retry Generate.'),
      findsOneWidget,
    );
  });
}
