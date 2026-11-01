import 'support/create_repository_harness.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/user.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_view.dart';
import 'package:ramifica/features/create/create_node_screen.dart';
import 'package:ramifica/features/create/voice_preview.dart';
import 'package:ramifica/features/create/steps/step_clip.dart';

void main() {
  group('CreateView', () {
    testWidgets('an empty tab offers a draft', (tester) async {
      final bloc = CreateBloc(repository: _repo(null), auth: _auth('uid_1'));
      addTearDown(() => _disposeBloc(tester, bloc));
      await tester.pumpWidget(MaterialApp(home: CreateView(bloc: bloc)));

      expect(find.text('Your drafts live here.'), findsOneWidget);
      await tester.tap(find.text('Start a draft'));
      await tester.pumpAndSettle();

      expect(bloc.state.hasDraft, isTrue);
      expect(bloc.state.openNodeId, 'node_1');
    });

    testWidgets('start a draft enters the fullscreen canvas route', (
      tester,
    ) async {
      final bloc = CreateBloc(repository: _repo(null), auth: _auth('uid_1'));
      addTearDown(() => _disposeBloc(tester, bloc));
      final controller = AppRouteController(const CreateLocation());
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AppNavigation(
            controller: controller,
            child: CreateView(bloc: bloc),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Entry route: the draft pitch shows, but no canvas yet.
      expect(find.text('Your drafts live here.'), findsOneWidget);
      expect(find.byKey(const ValueKey('canvas-node-node_1')), findsNothing);

      await tester.tap(find.text('Start a draft'));
      await tester.pumpAndSettle();

      expect(pathOf(controller.location), AppRoutes.createNew);
      expect(bloc.state.hasDraft, isTrue);
      expect(find.byKey(const ValueKey('canvas-node-node_1')), findsOneWidget);
    });

    testWidgets('the canvas selects nodes and the inspector edits them', (
      tester,
    ) async {
      final bloc = await _pumpDraft(tester);

      // Empty slots render plus minis: the root has one unslotted child,
      // so a single `+ A` mini waits; endings take no children.
      expect(find.byKey(const ValueKey('canvas-add-node_1-A')), findsOneWidget);
      expect(find.byKey(const ValueKey('canvas-add-node_2-A')), findsNothing);
      // Tapping a card selects it and pushes its fullscreen editor.
      await tester.tap(find.byKey(const ValueKey('canvas-node-node_2')));
      await tester.pumpAndSettle();
      expect(bloc.state.openNodeId, 'node_2');
      expect(find.byType(CreateNodeScreen), findsOneWidget);

      // Manual edits write bloc state through the fields.
      await tester.enterText(
        find.byKey(const ValueKey('title-node_2')),
        'Typed leaf',
      );
      await tester.pump();
      expect(bloc.state.openNode?.title, 'Typed leaf');
    });

    testWidgets('a plus mini creates the child and enters it', (tester) async {
      final calls = <_Call>[];
      final bloc = await _pumpDraft(tester, calls);

      await tester.tap(find.byKey(const ValueKey('canvas-add-node_1-A')));
      await tester.pumpAndSettle();

      final add = calls.singleWhere((call) => call.name == 'createNode');
      expect(add.data['parentNodeId'], 'node_1');
      expect(bloc.state.openNodeId, isNotNull);
      expect(find.byType(CreateNodeScreen), findsOneWidget);
    });

    testWidgets('tapping slot B first creates the child on slot B', (
      tester,
    ) async {
      final calls = <_Call>[];
      final bloc = await _pumpMediaDraft(tester, calls, [
        MapEntry('node_1', {..._mediaDocs().first.value, 'choices': const []}),
      ]);

      // Both empty slots show, A left of B.
      expect(find.byKey(const ValueKey('canvas-add-node_1-A')), findsOneWidget);
      expect(find.byKey(const ValueKey('canvas-add-node_1-B')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('canvas-add-node_1-B')));
      await tester.pumpAndSettle();

      // The child lands linked on B and its editor opens.
      final save = calls.singleWhere((call) => call.name == 'saveNode');
      final sent = (save.data['node'] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final saved = (sent['choices'] as List).cast<Map>();
      expect(saved, hasLength(1));
      expect(saved.single['slot'], 'B');
      expect(bloc.state.openNodeId, isNotNull);
      expect(find.byType(CreateNodeScreen), findsOneWidget);
    });
    testWidgets('the premise stays separate from the decision narration', (
      tester,
    ) async {
      final calls = <_Call>[];
      final bloc = await _pumpDraft(tester, calls);
      await tester.tap(find.byKey(const ValueKey('canvas-node-node_1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('premise-transcript')),
        'A storm closes the temple gates.',
      );
      await tester.tap(find.byKey(const ValueKey('wizard-continue')));
      await tester.pumpAndSettle();
      expect(bloc.state.story!.synopsis, 'A storm closes the temple gates.');
      expect(bloc.state.openNode!.ttsText, isEmpty);
      expect(calls.where((call) => call.name == 'saveNode'), isEmpty);
    });

    testWidgets('Format proposes without mutating the node', (tester) async {
      final calls = <_Call>[];
      final bloc = await _pumpDraft(tester, calls);

      await _openNode(tester, 'node_1');

      await tester.enterText(
        find.byKey(const ValueKey('script-direction-node_1')),
        'A haunted terminal',
      );
      await tester.pump();
      final format = find.byKey(const ValueKey('script-format-node_1'));
      await tester.ensureVisible(format);
      await tester.pumpAndSettle();
      await tester.tap(format);
      await tester.pumpAndSettle();

      expect(
        calls.where((call) => call.name == 'generateNodeText').single.name,
        'generateNodeText',
      );
      expect(
        calls
            .singleWhere((call) => call.name == 'generateNodeText')
            .data['prompt'],
        'A haunted terminal',
      );
      expect(
        calls
            .singleWhere((call) => call.name == 'generateNodeText')
            .data['purpose'],
        'scene',
      );
      // Proposal-only: the node is untouched until Apply.
      expect(bloc.state.openNode?.title, 'Root');
      expect(bloc.state.openNode?.ttsText, isEmpty);
      // The accordion shows the editable proposal.
      expect(
        find.byKey(const ValueKey('script-prop-line-node_1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('script-prop-start-node_1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('script-prop-end-node_1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('script-prop-video-node_1')),
        findsOneWidget,
      );
    });

    testWidgets('Apply completes only empty fields', (tester) async {
      final calls = <_Call>[];
      final bloc = await _pumpDraft(tester, calls);

      await _openNode(tester, 'node_1');

      await tester.enterText(
        find.byKey(const ValueKey('script-direction-node_1')),
        'A haunted terminal',
      );
      await tester.pump();
      final format = find.byKey(const ValueKey('script-format-node_1'));
      await tester.ensureVisible(format);
      await tester.pumpAndSettle();
      await tester.tap(format);
      await tester.pumpAndSettle();

      // The title is already set, so only the other fields plus the two
      // branches count.
      expect(find.text('Apply (4 fields, 1 branch)'), findsOneWidget);

      final apply = find.byKey(const ValueKey('script-apply-node_1'));
      await tester.ensureVisible(apply);
      await tester.pumpAndSettle();
      await tester.tap(apply);
      await tester.pumpAndSettle();

      // Scene Apply fills prompts and options while leaving narration to S4.
      expect(bloc.state.openNode?.title, 'Root');
      final saves = calls.where((call) => call.name == 'saveNode');
      expect(saves, isNotEmpty);
      final sent = (saves.last.data['node'] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
      expect(sent['title'], 'Root');
      expect(sent['ttsText'], isEmpty);
      expect(sent['startImagePrompt'], 'misty gate');
      expect(sent['endImagePrompt'], 'ashen city');
      expect(sent['videoPrompt'], 'slow push in');
    });

    testWidgets('typing stays local until Save is pressed', (tester) async {
      final calls = <_Call>[];
      await _pumpDraft(tester, calls);

      expect(find.byKey(const ValueKey('ribbon-publish')), findsOneWidget);
      await _openNode(tester, 'node_1');
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is StatusPill && widget.status == StatusPillState.idle,
        ),
        findsWidgets,
      );

      await tester.enterText(
        find.byKey(const ValueKey('title-node_1')),
        'Typed root',
      );
      await tester.pump();
      calls.clear();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.name == 'saveNode'), isEmpty);
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('wizard-save')));
      await tester.pumpAndSettle();

      final save = calls.singleWhere((call) => call.name == 'saveNode');
      final sent = (save.data['node'] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
      expect(sent['title'], 'Typed root');
    });

    testWidgets('step changes and leaving keep node edits local', (
      tester,
    ) async {
      final calls = <_Call>[];
      final bloc = await _pumpMediaDraft(
        tester,
        calls,
        _mediaDocs(approved: true),
      );
      await _openNode(tester, 'node_1', step: 1);
      calls.clear();
      await tester.enterText(
        find.byKey(const ValueKey('prompt-end-node_1')),
        'Keep this local',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('wizard-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('wizard-step-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('wizard-continue')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      expect(calls.where((call) => call.name == 'saveNode'), isEmpty);
      expect(bloc.state.openNode!.endImagePrompt, 'Keep this local');
      await _openNode(tester, 'node_1');
      await tester.tap(find.byKey(const ValueKey('wizard-save')));
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.name == 'saveNode'), hasLength(1));
      expect(bloc.hasUnsavedNodeEdits('node_1'), isFalse);
    });

    testWidgets('frame approval does not save pending author edits', (
      tester,
    ) async {
      final calls = <_Call>[];
      final bloc = await _pumpMediaDraft(tester, calls);
      await _openNode(tester, 'node_1', step: 1);
      calls.clear();
      await tester.enterText(
        find.byKey(const ValueKey('prompt-end-node_1')),
        'Pending prompt',
      );
      final approve = find.byKey(const ValueKey('approve-end-node_1'));
      await tester.ensureVisible(approve);
      await tester.tap(approve);
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.name == 'saveNode'), isEmpty);
      expect(bloc.state.openNode!.endImagePrompt, 'Pending prompt');
      expect(bloc.hasUnsavedNodeEdits('node_1'), isTrue);
      expect(bloc.state.openNode!.endImageApproved, isTrue);
    });

    testWidgets('a failure shows its phrase', (tester) async {
      final bloc = CreateBloc(
        repository: testCreateRepository(
          createDraftDoc: ({required authorId, required title}) async =>
              throw const AppFailure(.offline),
          fetchStoryDoc: (_) async => throw const AppFailure(.offline),
          fetchNodeDocs: (_) async => const [],
          callFunction: (name, data) async => throw const AppFailure(.offline),
        ),
      );
      addTearDown(() => _disposeBloc(tester, bloc));
      await tester.pumpWidget(MaterialApp(home: CreateView(bloc: bloc)));

      await tester.tap(find.text('Start a draft'));
      await tester.pumpAndSettle();

      // No author id and no signed-in identity: fails before any network.
      expect(find.text('That action is not valid'), findsOneWidget);
    });

    testWidgets('root shows S controls, child hides them', (tester) async {
      final bloc = await _pumpMediaDraft(tester);

      await _openNode(tester, 'node_1', step: 1);

      // One panel per frame: the root owns both S and E prompts.
      expect(find.text('Start frame'), findsOneWidget);
      expect(find.text('End frame'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('approve-start-node_1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('approve-end-node_1')), findsOneWidget);

      // Back to the canvas, then tapping the leaf opens its own screen.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await _openNode(tester, 'node_2', step: 1);
      expect(bloc.state.openNodeId, 'node_2');

      // The child inherits S: no S controls, but its own E controls.
      expect(find.byKey(const ValueKey('approve-start-node_2')), findsNothing);
      expect(find.byKey(const ValueKey('approve-end-node_2')), findsOneWidget);
    });

    testWidgets('approve dispatches the end-frame approval', (tester) async {
      final calls = <_Call>[];
      await _pumpMediaDraft(tester, calls);

      await _openNode(tester, 'node_1', step: 1);

      final approve = find.byKey(const ValueKey('approve-end-node_1'));
      await tester.ensureVisible(approve);
      await tester.pumpAndSettle();
      await tester.tap(approve);
      await tester.pumpAndSettle();

      final sent = calls.singleWhere((call) => call.name == 'approveNodeImage');
      expect(sent.data['nodeId'], 'node_1');
      expect(sent.data['which'], 'end');
      expect(sent.data['approved'], isTrue);
    });

    testWidgets('reject flips an approved end frame off', (tester) async {
      final calls = <_Call>[];
      await _pumpMediaDraft(tester, calls, _mediaDocs(approved: true));

      await _openNode(tester, 'node_1', step: 1);

      // The approved pill marks the approved E frame.
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is StatusPill && widget.status == StatusPillState.approved,
        ),
        findsWidgets,
      );

      final reject = find.byKey(const ValueKey('reject-end-node_1'));
      await tester.ensureVisible(reject);
      await tester.pumpAndSettle();
      await tester.tap(reject);
      await tester.pumpAndSettle();

      final sent = calls.singleWhere((call) => call.name == 'approveNodeImage');
      expect(sent.data['which'], 'end');
      expect(sent.data['approved'], isFalse);
    });

    testWidgets('image generate sends the revised prompt', (tester) async {
      final calls = <_Call>[];
      await _pumpMediaDraft(tester, calls);

      await _openNode(tester, 'node_1', step: 1);

      final promptField = find.byKey(const ValueKey('prompt-end-node_1'));
      await tester.ensureVisible(promptField);
      await tester.pumpAndSettle();
      await tester.enterText(promptField, 'ashen city');
      await tester.pump();
      final generate = find.byKey(const ValueKey('gen-image-end-node_1'));
      await tester.ensureVisible(generate);
      await tester.pumpAndSettle();
      await tester.tap(generate);
      await tester.pumpAndSettle();

      final sent = calls.singleWhere(
        (call) => call.name == 'generateNodeImage',
      );
      expect(sent.data['nodeId'], 'node_1');
      expect(sent.data['which'], 'end');
      expect(sent.data['prompt'], 'ashen city');
    });

    testWidgets('child start prompt is inherited and readonly', (tester) async {
      await _pumpMediaDraft(tester, null, [
        MapEntry('node_1', {
          ..._mediaDocs().first.value,
          'endImagePrompt': 'parent glow',
        }),
        _mediaDocs()[1],
      ]);

      await _openNode(tester, 'node_2', step: 1);

      final prompt = find.byKey(const ValueKey('prompt-start-node_2'));
      await tester.ensureVisible(prompt);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(prompt).enabled, isFalse);
      expect(tester.widget<TextField>(prompt).controller?.text, 'parent glow');
      // The child still owns its E prompt editor.
      expect(find.byKey(const ValueKey('prompt-end-node_2')), findsOneWidget);
    });

    testWidgets('video generate sends the revised prompt', (tester) async {
      final calls = <_Call>[];
      await _pumpMediaDraft(tester, calls, _mediaDocs(approved: true));

      await _openNode(tester, 'node_1', step: 4);

      final promptField = find.byKey(const ValueKey('video-prompt-node_1'));
      await tester.ensureVisible(promptField);
      await tester.pumpAndSettle();
      await tester.enterText(promptField, 'slow push in');
      await tester.pump();
      calls.clear();
      await tester.pump(const Duration(seconds: 5));
      expect(calls.where((call) => call.name == 'saveNode'), isEmpty);
      final generate = find.byKey(const ValueKey('gen-video-node_1'));
      await tester.ensureVisible(generate);
      await tester.pumpAndSettle();
      await tester.tap(generate);
      await tester.pumpAndSettle();

      final sent = calls.singleWhere(
        (call) => call.name == 'generateNodeVideo',
      );
      expect(sent.data['nodeId'], 'node_1');
      expect(sent.data['prompt'], 'slow push in');
      // Generation saves the revised prompt before calling the provider.
      final saves = calls.where((call) => call.name == 'saveNode');
      expect(saves, isNotEmpty);
      final sentNode = (saves.last.data['node'] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
      expect(sentNode['videoPrompt'], 'slow push in');
    });

    testWidgets('gated video shows the message and disables generation', (
      tester,
    ) async {
      final bloc = await _pumpMediaDraft(tester);

      final child = bloc.state.nodes.singleWhere((n) => n.nodeId == 'node_2');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StepClip(
              node: child,
              busy: false,
              showErrors: false,
              videoGateMessage: bloc.state.videoGateMessage(child),
            ),
          ),
        ),
      );

      // The parent E is unapproved: the gate message shows and the video
      // button is disabled.
      expect(
        find.text('The parent end frame must be approved first.'),
        findsOneWidget,
      );
      final generate = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('gen-video-node_2')),
      );
      expect(generate.onPressed, isNull);
    });

    testWidgets('a stale child video shows the desync badge', (tester) async {
      final bloc = await _pumpMediaDraft(tester);

      final child = bloc.state.nodes.singleWhere((n) => n.nodeId == 'node_2');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StepClip(
              node: child,
              busy: false,
              showErrors: false,
              videoDesynced: bloc.state.videoDesynced(child),
            ),
          ),
        ),
      );

      // The parent regenerated E after this child inherited S.
      expect(find.textContaining('Out of sync'), findsOneWidget);
    });

    testWidgets('the upload button hides without a picker', (tester) async {
      await _pumpMediaDraft(tester);

      await _openNode(tester, 'node_1', step: 4);

      expect(find.byKey(const ValueKey('upload-video-node_1')), findsNothing);
    });

    testWidgets('retakes, video generate, and voice status show', (
      tester,
    ) async {
      await _pumpMediaDraft(tester);

      await _openNode(tester, 'node_1', step: 1);

      // Generated S and E frames offer another take (same generate call).
      expect(find.text('Another take'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('prompt-end-node_1')), findsOneWidget);
    });

    testWidgets('a node video offers another take', (tester) async {
      await _pumpUploadDraft(
        tester,
        docs: [
          MapEntry('node_1', {
            ..._mediaDocs().first.value,
            'videoUrl': 'https://cdn.example/v.mp4',
          }),
        ],
      );

      await _openNode(tester, 'node_1', step: 4);

      expect(find.text('Another take'), findsOneWidget);
      expect(find.text('Generate video'), findsNothing);
    });

    testWidgets('upload dispatches, shows progress, then clears', (
      tester,
    ) async {
      final calls = <_Call>[];
      final gate = Completer<void>();
      final bloc = await _pumpUploadDraft(
        tester,
        calls: calls,
        upload:
            ({
              required path,
              required contentType,
              required bytes,
              onProgress,
            }) async {
              calls.add(
                _Call('uploadNodeVideo', {
                  'path': path,
                  'contentType': contentType,
                  'byteLength': bytes.length,
                }),
              );
              onProgress?.call(0.5);
              await gate.future;
            },
      );

      await _openNode(tester, 'node_1', step: 4);

      final upload = find.byKey(const ValueKey('upload-video-node_1'));
      await tester.ensureVisible(upload);
      await tester.pumpAndSettle();
      await tester.tap(upload);
      await tester.pump();

      // In flight: the trigger path is hit and progress shows.
      final uploads = calls.where((call) => call.name == 'uploadNodeVideo');
      expect(uploads, hasLength(1));
      expect(
        uploads.single.data['path'],
        'uploads/uid_1/story_1_node_1_take1.mp4',
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(bloc.state.failure, isNull);
    });

    testWidgets('a bad pick is rejected without network', (tester) async {
      final calls = <_Call>[];
      await _pumpUploadDraft(
        tester,
        calls: calls,
        pick: () async =>
            const PickedVideoFile(contentType: 'video/avi', bytes: [1, 2, 3]),
      );

      await _openNode(tester, 'node_1', step: 4);

      final upload = find.byKey(const ValueKey('upload-video-node_1'));
      await tester.ensureVisible(upload);
      await tester.pumpAndSettle();
      await tester.tap(upload);
      await tester.pumpAndSettle();

      expect(
        find.text('Only mp4 or mov videos can be uploaded.'),
        findsOneWidget,
      );
      expect(calls.where((call) => call.name == 'uploadNodeVideo'), isEmpty);
    });

    testWidgets('a trigger failure surfaces its phrase', (tester) async {
      await _pumpUploadDraft(
        tester,
        docs: [
          MapEntry('node_1', {
            ..._mediaDocs().first.value,
            'uploadError': 'encode-failed',
          }),
        ],
      );

      await _openNode(tester, 'node_1', step: 4);

      final upload = find.byKey(const ValueKey('upload-video-node_1'));
      await tester.ensureVisible(upload);
      await tester.pumpAndSettle();
      await tester.tap(upload);
      await tester.pumpAndSettle();

      expect(find.text('Something failed'), findsOneWidget);
    });

    testWidgets('zones render over the last frame', (tester) async {
      final bloc = await _pumpDraft(tester);

      await _openNode(tester, 'node_1', step: 2);

      // The open root carries one choice with a center-frame zone.
      final zone = find.byKey(const ValueKey('zone-c1'));
      await tester.ensureVisible(zone);
      await tester.pumpAndSettle();
      expect(zone, findsOneWidget);
      expect(bloc.state.openNode?.choices.single.x, 0.25);
    });

    testWidgets('dragging a zone moves it with the finger, not to a corner', (
      tester,
    ) async {
      final bloc = await _pumpDraft(tester);

      await _openNode(tester, 'node_1', step: 2);

      final zone = find.byKey(const ValueKey('zone-c1'));
      await tester.ensureVisible(zone);
      await tester.pumpAndSettle();
      final before = tester.getCenter(zone);

      // Multi-step drag with a pump per step: each frame rebuilds the
      // zone at its in-flight position, like a real finger drag.
      final gesture = await tester.startGesture(before);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      for (var step = 0; step < 4; step++) {
        await gesture.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      // Past the touch slop the zone tracks the finger: 4 x 10px steps.
      final after = tester.getCenter(zone);
      expect(after.dx - before.dx, closeTo(20, 2));
      expect(after.dy - before.dy, closeTo(0, 2));
      expect(bloc.state.openNode?.choices.single.x, lessThan(0.5));
      expect(bloc.state.openNode?.choices.single.y, 0.65);
    });

    testWidgets('tapping a zone keeps it selected', (tester) async {
      await _pumpDraft(tester);

      await _openNode(tester, 'node_1', step: 2);

      final zone = find.byKey(const ValueKey('zone-c1'));
      await tester.ensureVisible(zone);
      await tester.pumpAndSettle();

      double ringWidth() {
        final ring = tester.widget<Container>(
          find.byKey(const ValueKey('zone-ring-node_1-c1')),
        );
        final border = (ring.decoration! as BoxDecoration).border! as Border;
        return border.top.width;
      }

      expect(ringWidth(), 1);
      await tester.tap(zone);
      await tester.pumpAndSettle();
      // onPanDown selects on pointer-down; the tap must not undo it.
      expect(ringWidth(), 2);
    });

    testWidgets('hotspot cards are always visible and pick icon and color', (
      tester,
    ) async {
      final bloc = await _pumpDraft(tester);

      await _openNode(tester, 'node_1', step: 2);

      // No tap or drag first: the editor card is already there.
      expect(find.byKey(const ValueKey('zone-label-c1')), findsOneWidget);

      // The current icon sits left of the name field; tapping it opens
      // the picker modal.
      final iconButton = find.byKey(const ValueKey('zone-icon-c1'));
      await tester.ensureVisible(iconButton);
      await tester.pumpAndSettle();
      await tester.tap(iconButton);
      await tester.pumpAndSettle();

      // Picking a color commits at once and keeps the modal open.
      final gold = find.byKey(const ValueKey('zone-icon-color-c1-gold'));
      await tester.tap(gold);
      await tester.pumpAndSettle();
      expect(bloc.state.openNode?.choices.single.iconColor, 'gold');

      final mountain = find.byKey(const ValueKey('zone-icon-c1-mountain'));
      await tester.ensureVisible(mountain);
      await tester.pumpAndSettle();
      await tester.tap(mountain);
      await tester.pumpAndSettle();

      expect(bloc.state.openNode?.choices.single.icon, 'mountain');
      final puck = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('zone-ring-node_1-c1')),
          matching: find.byType(Icon),
        ),
      );
      expect(puck.icon, Icons.terrain);
      expect(puck.color, RamificaColors.rewardGold);
    });
    testWidgets('zone labels cap at 24 characters with a counter', (
      tester,
    ) async {
      final bloc = await _pumpDraft(tester);

      await _openNode(tester, 'node_1', step: 2);

      final zone = find.byKey(const ValueKey('zone-c1'));
      await tester.ensureVisible(zone);
      await tester.pumpAndSettle();
      await tester.tap(zone);
      await tester.pumpAndSettle();

      final field = find.byKey(const ValueKey('zone-label-c1'));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123');
      await tester.pump();

      // The hard cap truncates the edit; the counter reports 24/24.
      expect(bloc.state.openNode?.choices.single.label.length, 24);
      expect(find.text('24/24'), findsOneWidget);
    });

    testWidgets('deleting a zone removes its choice', (tester) async {
      final bloc = await _pumpDraft(tester);

      await _openNode(tester, 'node_1', step: 2);

      final zone = find.byKey(const ValueKey('zone-c1'));
      await tester.ensureVisible(zone);
      await tester.pumpAndSettle();
      await tester.tap(zone);
      await tester.pumpAndSettle();

      final remove = find.byKey(const ValueKey('zone-delete-c1'));
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();

      expect(bloc.state.openNode?.choices, isEmpty);
      expect(find.byKey(const ValueKey('zone-c1')), findsNothing);
    });

    testWidgets('an empty Option slot creates its scene and zone', (
      tester,
    ) async {
      final bloc = await _pumpDraft(tester);

      await _openNode(tester, 'node_1', step: 2);

      final add = find.byKey(const ValueKey('add-option-node_1-B'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      final parent = bloc.state.nodes.singleWhere(
        (node) => node.nodeId == 'node_1',
      );
      expect(parent.choices, hasLength(2));
      expect(parent.choices.last.slot, 'B');
      expect(parent.choices.last.targetNodeId, 'node_3');
      expect(bloc.state.focusChoiceId, parent.choices.last.choiceId);
    });

    testWidgets('the ribbon publish CTA stays disabled until clean', (
      tester,
    ) async {
      await _pumpDraft(tester);

      expect(find.byKey(const ValueKey('ribbon-publish')), findsOneWidget);
      final cta = tester.widget<ElevatedButton>(
        find.byKey(const ValueKey('ribbon-publish')),
      );
      expect(cta.onPressed, isNull);
    });

    testWidgets('line approval opens the voice gate and generates', (
      tester,
    ) async {
      final calls = <_Call>[];
      final bloc = await _pumpDraft(tester, calls);

      await _openNode(tester, 'node_1');

      expect(bloc.state.openNode!.lineApproved, isFalse);
      expect(find.byKey(const ValueKey('line-node_1')), findsNothing);
      await _goToStep(tester, 3);
      expect(
        find.text('Approve the narrator line to generate voice.'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('line-node_1')),
        'Go left',
      );
      await tester.pump();
      final approve = find.byKey(const ValueKey('approve-line-node_1'));
      await tester.ensureVisible(approve);
      await tester.pumpAndSettle();
      await tester.tap(approve);
      await tester.pumpAndSettle();

      expect(bloc.state.openNode?.lineApproved, isTrue);
      final gate = find.byKey(const ValueKey('gen-voice-node_1'));
      await tester.ensureVisible(gate);
      expect(tester.widget<FilledButton>(gate).onPressed, isNotNull);
      await tester.tap(gate);
      await tester.pumpAndSettle();

      final sent = calls.singleWhere(
        (call) => call.name == 'generateNodeVoice',
      );
      expect(sent.data['nodeId'], 'node_1');
    });

    testWidgets('approving the take clears the approval missing', (
      tester,
    ) async {
      final bloc = await _pumpMediaDraft(tester, null, [
        MapEntry('node_1', {
          ..._mediaDocs().first.value,
          'ttsText': 'Go left',
          'lineApproved': true,
          'ttsAudioUrl': 'https://cdn.example/v.m4a',
          'ttsStatus': 'ready',
          'ttsDurationSeconds': 2.5,
          'ttsApproved': false,
        }),
        _mediaDocs()[1],
      ]);
      await _openNode(tester, 'node_1', step: 3);

      expect(bloc.state.openNode?.ttsApproved, isFalse);
      final approve = find.byKey(const ValueKey('approve-voice-node_1'));
      await tester.ensureVisible(approve);
      await tester.pumpAndSettle();
      await tester.tap(approve);
      await tester.pumpAndSettle();

      expect(bloc.state.openNode?.ttsApproved, isTrue);
    });

    testWidgets('a voice preview plays and stops through the player', (
      tester,
    ) async {
      final player = _FakePlayback();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoicePreview(
              nodeId: 'node_1',
              audioUrl: 'https://cdn.example/v.m4a',
              player: player,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final toggle = find.byTooltip('Play audio');
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(player.played, 'https://cdn.example/v.m4a');
      expect(find.byTooltip('Pause audio'), findsOneWidget);

      await tester.tap(find.byTooltip('Pause audio'));
      await tester.pumpAndSettle();
      expect(player.stops, 1);
      expect(find.byTooltip('Play audio'), findsOneWidget);
    });

    testWidgets(
      'zone edits stay local until the scene Save button is pressed',
      (tester) async {
        final calls = <_Call>[];
        await _pumpDraft(tester, calls);

        await _openNode(tester, 'node_1', step: 2);

        expect(find.byKey(const ValueKey('save-zones-node_1')), findsNothing);
        calls.clear();
        await tester.enterText(
          find.byKey(const ValueKey('zone-label-c1')),
          'Edited option',
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(calls.where((call) => call.name == 'saveNode'), isEmpty);
        await tester.tap(find.byKey(const ValueKey('wizard-save')));
        await tester.pumpAndSettle();
        expect(calls.where((call) => call.name == 'saveNode'), hasLength(1));
      },
    );

    testWidgets('the root shows no delete button', (tester) async {
      await _pumpDraft(tester);

      await _openNode(tester, 'node_1', step: 2);

      expect(find.byKey(const ValueKey('delete-node-node_1')), findsNothing);
      expect(find.text('The root node cannot be deleted.'), findsNothing);
    });

    testWidgets('a targeted node delete button names the blocker', (
      tester,
    ) async {
      final bloc = await _pumpDraft(tester);

      // The root choice targets the leaf.
      await _openNode(tester, 'node_2', step: 2);
      expect(bloc.state.openNodeId, 'node_2');

      final remove = find.byKey(const ValueKey('delete-node-node_2'));
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();

      expect(
        find.text('Node node_2 is a choice target — remove the choice first.'),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(remove).onPressed, isNull);
    });

    testWidgets('deleting an untargeted node removes it from the canvas', (
      tester,
    ) async {
      final docs = [
        MapEntry('node_1', {
          'title': 'Root',
          'visibility': 'visible',
          'isEnding': false,
          'videoStatus': 'idle',
          'ttsText': '',
          'lineApproved': false,
          'ttsStatus': 'idle',
          'choices': [
            {
              'choiceId': 'c1',
              'label': 'Enter',
              'targetNodeId': 'node_2',
              'isDefault': true,
              'x': 0.25,
              'y': 0.65,
              'radius': 0.15,
            },
          ],
        }),
        const MapEntry('node_2', {
          'title': 'Leaf',
          'visibility': 'secret',
          'isEnding': true,
          'endingName': 'Escape',
          'endingType': 'abierto',
        }),
        const MapEntry('node_3', {
          'title': 'Spare',
          'ttsText': 'Spare line',
          'lineApproved': true,
          'startImageApproved': true,
          'endImageApproved': true,
        }),
      ];
      final calls = <_Call>[];
      final bloc = CreateBloc(
        repository: testCreateRepository(
          createDraftDoc: ({required authorId, required title}) async =>
              'story_1',
          fetchStoryDoc: (_) async => {
            'authorId': 'uid_1',
            'title': 'Temple',
            'synopsis': '',
            'status': 'draft',
            'rootNodeId': 'node_1',
          },
          fetchNodeDocs: (_) async => List.of(docs),
          callFunction: (name, data) async {
            calls.add(_Call(name, data));
            if (name == 'deleteNode') {
              docs.removeWhere((doc) => doc.key == data['nodeId']);
              return {'nodeId': data['nodeId']};
            }
            return <String, dynamic>{};
          },
        ),
      );
      addTearDown(() => _disposeBloc(tester, bloc));
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);
      await tester.pumpWidget(MaterialApp(home: CreateView(bloc: bloc)));
      await tester.pumpAndSettle();
      await _openNode(tester, 'node_3', step: 2);

      final remove = find.byKey(const ValueKey('delete-node-node_3'));
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(remove).onPressed, isNotNull);

      await tester.tap(remove);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('confirm-delete-node_3')));
      await tester.pumpAndSettle();

      final deleted = calls.singleWhere((call) => call.name == 'deleteNode');
      expect(deleted.data, {'storyId': 'story_1', 'nodeId': 'node_3'});
      expect(
        bloc.state.nodes.map((node) => node.nodeId),
        containsAll(['node_1', 'node_2']),
      );
      expect(
        bloc.state.nodes.map((node) => node.nodeId),
        isNot(contains('node_3')),
      );
      expect(bloc.state.openNodeId, 'node_1');
    });

    testWidgets('a delete rejection surfaces its phrase', (tester) async {
      final bloc = CreateBloc(
        repository: testCreateRepository(
          createDraftDoc: ({required authorId, required title}) async =>
              'story_1',
          fetchStoryDoc: (_) async => {
            'authorId': 'uid_1',
            'title': 'Temple',
            'synopsis': '',
            'status': 'draft',
            'rootNodeId': 'node_1',
          },
          fetchNodeDocs: (_) async => [
            const MapEntry('node_1', {'title': 'Root'}),
            const MapEntry('node_3', {
              'title': 'Spare',
              'ttsText': 'Spare line',
              'lineApproved': true,
              'startImageApproved': true,
              'endImageApproved': true,
            }),
          ],
          callFunction: (name, data) async {
            if (name == 'deleteNode') throw const AppFailure(.invalid);
            return <String, dynamic>{};
          },
        ),
      );
      addTearDown(() => _disposeBloc(tester, bloc));
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);
      await tester.pumpWidget(MaterialApp(home: CreateView(bloc: bloc)));
      await tester.pumpAndSettle();
      await _openNode(tester, 'node_3', step: 2);

      final remove = find.byKey(const ValueKey('delete-node-node_3'));
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('confirm-delete-node_3')));
      await tester.pumpAndSettle();

      expect(find.text('That action is not valid'), findsOneWidget);
      expect(bloc.state.nodes.map((node) => node.nodeId), contains('node_3'));
    });

    testWidgets('publish success navigates through onPublished', (
      tester,
    ) async {
      String? published;
      final bloc = CreateBloc(
        repository: testCreateRepository(
          createDraftDoc: ({required authorId, required title}) async =>
              'story_1',
          fetchStoryDoc: (_) async => {
            'authorId': 'uid_1',
            'title': 'Temple',
            'synopsis': '',
            'status': 'draft',
            'rootNodeId': 'node_1',
          },
          fetchNodeDocs: (_) async => [
            const MapEntry('node_1', {'title': 'Root'}),
          ],
          callFunction: (name, data) async => {
            'storyId': 'story_1',
            'published': true,
            'problems': <String>[],
          },
        ),
      );
      addTearDown(() => _disposeBloc(tester, bloc));
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);
      await tester.pumpWidget(
        MaterialApp(
          home: CreateView(
            bloc: bloc,
            onPublished: (storyId) => published = storyId,
          ),
        ),
      );
      await tester.pumpAndSettle();

      bloc.add(const StoryPublished());
      await tester.pumpAndSettle();

      expect(published, 'story_1');
    });

    testWidgets('publish problems render as the checklist', (tester) async {
      final bloc = CreateBloc(
        repository: testCreateRepository(
          createDraftDoc: ({required authorId, required title}) async =>
              'story_1',
          fetchStoryDoc: (_) async => {
            'authorId': 'uid_1',
            'title': 'Temple',
            'synopsis': '',
            'status': 'draft',
            'rootNodeId': 'node_1',
          },
          fetchNodeDocs: (_) async => [
            const MapEntry('node_1', {'title': 'Root'}),
          ],
          callFunction: (name, data) async => {
            'storyId': 'story_1',
            'published': false,
            'problems': ['Node node_1 needs a ready video.'],
          },
        ),
      );
      addTearDown(() => _disposeBloc(tester, bloc));
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);
      await tester.pumpWidget(MaterialApp(home: CreateView(bloc: bloc)));
      await tester.pumpAndSettle();
      bloc.add(const StoryPublished());
      await tester.pumpAndSettle();
      expect(bloc.state.publishedStoryId, isNull);

      // The server checklist remains visible on the canvas.
      expect(find.text('Node node_1 needs a ready video.'), findsOneWidget);
    });

    testWidgets('a ready story publishes from the publish button', (
      tester,
    ) async {
      String? published;
      final calls = <_Call>[];
      final bloc = CreateBloc(
        repository: testCreateRepository(
          createDraftDoc: ({required authorId, required title}) async =>
              'story_1',
          fetchStoryDoc: (_) async => {
            'authorId': 'uid_1',
            'title': 'Temple',
            'synopsis': '',
            'status': 'draft',
            'rootNodeId': 'node_1',
          },
          fetchNodeDocs: (_) async => [
            MapEntry('node_1', {
              'title': 'Root',
              'visibility': 'visible',
              'isEnding': false,
              'videoStatus': 'ready',
              'videoUrl': 'https://cdn.example/root.mp4',
              'startImageSourceUrl': 'https://frames.invalid/s.webp',
              'startImageStatus': 'ready',
              'startImageApproved': true,
              'endImageSourceUrl': 'https://frames.invalid/e1.webp',
              'endImageStatus': 'ready',
              'endHash': 'hash-e1',
              'endImageApproved': true,
              'ttsText': 'Go left',
              'lineApproved': true,
              'ttsAudioUrl': 'https://cdn.example/root.m4a',
              'ttsStatus': 'ready',
              'ttsDurationSeconds': 2.5,
              'ttsApproved': true,
              'choices': [
                {
                  'choiceId': 'c1',
                  'label': 'Enter',
                  'targetNodeId': 'node_2',
                  'isDefault': true,
                  'x': 0.25,
                  'y': 0.65,
                  'radius': 0.15,
                },
              ],
            }),
            const MapEntry('node_2', {
              'title': 'Dawn',
              'visibility': 'visible',
              'isEnding': true,
              'endingName': 'Dawn',
              'endingType': 'abierto',
              'videoStatus': 'ready',
              'videoUrl': 'https://cdn.example/dawn.mp4',
              'endImageSourceUrl': 'https://frames.invalid/e2.webp',
              'endImageStatus': 'ready',
              'endHash': 'hash-e2',
              'endImageApproved': true,
              'ttsText': '',
            }),
          ],
          callFunction: (name, data) async {
            calls.add(_Call(name, data));
            return {
              'storyId': 'story_1',
              'published': true,
              'problems': <String>[],
            };
          },
        ),
      );
      addTearDown(() => _disposeBloc(tester, bloc));
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);
      await tester.pumpWidget(
        MaterialApp(
          home: CreateView(
            bloc: bloc,
            onPublished: (storyId) => published = storyId,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The whole checklist passes, so the CTA is armed.
      final cta = find.byKey(const ValueKey('ribbon-publish'));
      await tester.ensureVisible(cta);
      await tester.pumpAndSettle();
      await tester.tap(cta);
      await tester.pumpAndSettle();

      final publishedCall = calls.singleWhere(
        (call) => call.name == 'publishStory',
      );
      expect(publishedCall.data, {'storyId': 'story_1'});
      expect(published, 'story_1');
    });
  });
}

class _Call {
  const _Call(this.name, this.data);

  final String name;
  final Map<String, dynamic> data;
}

class _FakePlayback implements VoicePlayback {
  final _state = ValueNotifier(
    const VoicePlaybackState(ready: true, duration: Duration(seconds: 2)),
  );
  @override
  ValueNotifier<VoicePlaybackState> get state => _state;
  @override
  Future<void> prepare(String url) async {}
  @override
  Future<void> pause() async {
    stops++;
    _state.value = const VoicePlaybackState(
      ready: true,
      duration: Duration(seconds: 2),
    );
  }

  @override
  Future<void> seek(Duration position) async {}
  String? played;
  var stops = 0;

  @override
  Future<void> play(String url) async {
    played = url;
    _state.value = const VoicePlaybackState(
      ready: true,
      playing: true,
      duration: Duration(seconds: 2),
    );
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  void dispose() {}
}

/// Opens the fullscreen editor for [nodeId] through its canvas card — the
/// production flow: tap selects the node and pushes its screen.
Future<void> _openNode(
  WidgetTester tester,
  String nodeId, {
  int step = 0,
}) async {
  await tester.tap(find.byKey(ValueKey('canvas-node-$nodeId')));
  await tester.pumpAndSettle();
  expect(find.byType(CreateNodeScreen), findsOneWidget);
  // The root opens on step 0 (Tell your idea). Script tests continue.
  if (find.byKey(const ValueKey('wizard-premise')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('wizard-continue')));
    await tester.pumpAndSettle();
  }
  if (step > 0) await _goToStep(tester, step);
}

/// Prepare only the prerequisites of the focused step through public events.
Future<void> _goToStep(WidgetTester tester, int step) async {
  final bloc = tester
      .widget<CreateNodeScreen>(find.byType(CreateNodeScreen))
      .bloc;
  var node = bloc.state.openNode!;
  if (step > 0) {
    bloc.add(
      NodeFieldChanged(
        nodeId: node.nodeId,
        title: node.title.isEmpty ? 'Scene' : null,
      ),
    );
    await tester.pumpAndSettle();
  }
  if (step > 1) {
    if (node.nodeId == bloc.state.story!.rootNodeId) {
      bloc.add(
        ImageApprovalChanged(
          nodeId: node.nodeId,
          which: 'start',
          approved: true,
        ),
      );
      await tester.pumpAndSettle();
    }
    bloc.add(
      ImageApprovalChanged(nodeId: node.nodeId, which: 'end', approved: true),
    );
    await tester.pumpAndSettle();
  }
  if (step > 2) {
    bloc.add(
      NodeFieldChanged(
        nodeId: node.nodeId,
        choiceLabels: {
          for (final choice in node.choices)
            if (choice.label.isEmpty) choice.choiceId: 'Enter',
        },
      ),
    );
    await tester.pumpAndSettle();
  }
  if (step > 3) {
    node = bloc.state.openNode!;
    bloc.add(
      NodeFieldChanged(
        nodeId: node.nodeId,
        ttsText: node.ttsText.isEmpty ? 'Choose a path' : null,
        lineApproved: true,
      ),
    );
    await tester.pumpAndSettle();
    node = bloc.state.openNode!;
    if (node.ttsStatus != 'ready') {
      bloc.add(VoiceGenerateRequested(node.nodeId));
      await tester.pumpAndSettle();
    }
    bloc.add(NodeFieldChanged(nodeId: node.nodeId, ttsApproved: true));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(ValueKey('wizard-step-$step')));
  await tester.pumpAndSettle();
}

Future<CreateBloc> _pumpDraft(WidgetTester tester, [List<_Call>? calls]) async {
  final bloc = CreateBloc(repository: _repo(calls));
  addTearDown(() => _disposeBloc(tester, bloc));
  bloc.add(const DraftOpened('story_1'));
  await bloc.stream.firstWhere((state) => state.hasDraft);
  await tester.pumpWidget(MaterialApp(home: CreateView(bloc: bloc)));
  await tester.pumpAndSettle();
  return bloc;
}

Future<CreateBloc> _pumpMediaDraft(
  WidgetTester tester, [
  List<_Call>? calls,
  List<MapEntry<String, Map<String, dynamic>>>? docs,
]) async {
  final bloc = CreateBloc(repository: _repo(calls, docs: docs ?? _mediaDocs()));
  addTearDown(() => _disposeBloc(tester, bloc));
  bloc.add(const DraftOpened('story_1'));
  await bloc.stream.firstWhere((state) => state.hasDraft);
  await tester.pumpWidget(MaterialApp(home: CreateView(bloc: bloc)));
  await tester.pumpAndSettle();
  return bloc;
}

/// Pumps the open root with an upload picker and an identified author, so
/// [VideoUploadRequested] resolves `uid_1` like production.
Future<CreateBloc> _pumpUploadDraft(
  WidgetTester tester, {
  List<_Call>? calls,
  List<MapEntry<String, Map<String, dynamic>>>? docs,
  UploadVideoFile? upload,
  PickVideoFile? pick,
  String takeId = 'take1',
}) async {
  final resolved = (docs ?? _mediaDocs()).map((doc) {
    if (doc.key == 'node_1' && !doc.value.containsKey('uploadTakeId')) {
      return MapEntry(doc.key, {...doc.value, 'uploadTakeId': takeId});
    }
    return doc;
  }).toList();
  final bloc = CreateBloc(
    repository: _repo(calls, docs: resolved, upload: upload),
    auth: _auth('uid_1'),
  );
  addTearDown(() => _disposeBloc(tester, bloc));
  bloc.add(const DraftOpened('story_1'));
  await bloc.stream.firstWhere((state) => state.hasDraft);
  await tester.pumpWidget(
    MaterialApp(
      home: CreateView(
        bloc: bloc,
        pickVideo:
            pick ??
            () async =>
                const PickedVideoFile(contentType: 'video/mp4', bytes: [1]),
        newTakeId: () => takeId,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return bloc;
}

AuthRepository _auth(String? uid) =>
    AuthRepository(auth: _Gateway(uid), users: _Users());

class _Gateway implements AuthGateway {
  _Gateway(this.uid);

  final String? uid;

  @override
  AuthIdentity? get currentIdentity =>
      uid == null ? null : AuthIdentity(uid: uid!);

  @override
  Stream<AuthIdentity?> authStateChanges() =>
      Stream<AuthIdentity?>.value(currentIdentity);

  @override
  Future<void> completeGoogleRedirect() async {}

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signInWithGooglePopup() async {}

  @override
  Future<void> signInWithGoogleRedirect() async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> signUpWithEmail({
    required String email,
    required String password,
  }) async {}
}

class _Users implements UserDirectory {
  @override
  Future<void> create(UserAccount user) async {}

  @override
  Future<bool> exists(String uid) async => true;

  @override
  Future<UserAccount?> read(String uid) async => null;

  @override
  Future<void> updateProfile({
    required String uid,
    String? displayName,
    String? handle,
    String? photoUrl,
    required String locale,
  }) async {}
}

/// Root with generated-but-unapproved S/E plus a stale child: the child
/// inherited `hash-old` while the parent E is now `hash-e1`, and its
/// video sits at `idle` waiting to re-inherit.
List<MapEntry<String, Map<String, dynamic>>> _mediaDocs({
  bool approved = false,
}) {
  return [
    MapEntry('node_1', {
      'title': 'Root',
      'visibility': 'visible',
      'isEnding': false,
      'videoStatus': 'idle',
      'ttsText': '',
      'lineApproved': false,
      'ttsStatus': 'idle',
      'startImageSourceUrl': 'https://frames.invalid/s.webp',
      'startImageStatus': 'ready',
      'startHash': 'hash-s',
      'startImageApproved': approved,
      'endImageSourceUrl': 'https://frames.invalid/e1.webp',
      'endImageStatus': 'ready',
      'endHash': 'hash-e1',
      'endImageApproved': approved,
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
    }),
    const MapEntry('node_2', {
      'title': 'Leaf',
      'visibility': 'visible',
      'isEnding': true,
      'endingName': 'Escape',
      'endingType': 'abierto',
      'videoStatus': 'idle',
      'startFromNodeId': 'node_1',
      'startParentEndHash': 'hash-old',
      'endImageSourceUrl': 'https://frames.invalid/e2.webp',
      'endImageStatus': 'ready',
      'endHash': 'hash-e2',
      'endImageApproved': false,
    }),
  ];
}

CreateRepository _repo(
  List<_Call>? calls, {
  List<MapEntry<String, Map<String, dynamic>>>? docs,
  UploadVideoFile? upload,
}) {
  final stored = {
    for (final doc
        in docs ??
            [
              MapEntry('node_1', {
                'title': 'Root',
                'visibility': 'visible',
                'isEnding': false,
                'videoStatus': 'idle',
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
              }),
              const MapEntry('node_2', {
                'title': 'Leaf',
                'visibility': 'secret',
                'isEnding': true,
                'endingName': 'Escape',
                'endingType': 'abierto',
              }),
            ])
      doc.key: <String, dynamic>{...doc.value},
  };
  final keyed = <String, String>{};
  return testCreateRepository(
    createDraftDoc: ({required authorId, required title}) async => 'story_1',
    updateStoryDoc: ({required storyId, title, synopsis}) async {
      calls?.add(_Call('updateStory', {'title': title, 'synopsis': synopsis}));
    },
    fetchStoryDoc: (_) async => {
      'authorId': 'uid_1',
      'title': 'Temple',
      'synopsis': '',
      'status': 'draft',
      'rootNodeId': 'node_1',
    },
    fetchNodeDocs: (_) async => [
      for (final entry in stored.entries) MapEntry(entry.key, {...entry.value}),
    ],
    callFunction: (name, data) async {
      calls?.add(_Call(name, data));
      if (name == 'saveNode') {
        final node = Map<String, dynamic>.from(data['node'] as Map);
        final id = node['nodeId'] as String;
        stored[id] = {...?stored[id], ...node};
        return {};
      }
      if (name == 'createNode') {
        if (data['parentNodeId'] == null) return {'nodeId': 'node_1'};
        final id = keyed.putIfAbsent(
          data['requestId'] as String? ?? 'manual-${stored.length}',
          () => 'node_${stored.length + 1}',
        );
        stored.putIfAbsent(
          id,
          () => {'title': '', 'startFromNodeId': data['parentNodeId']},
        );
        return {'nodeId': id};
      }
      final id = data['nodeId'] as String?;
      final node = stored[id];
      if (node != null) {
        if (name == 'approveNodeImage') {
          node['${data['which']}ImageApproved'] = data['approved'];
        }
        if (name == 'generateNodeVoice') {
          node.addAll({
            'ttsStatus': 'ready',
            'ttsAudioUrl': 'https://example.invalid/v.wav',
            'ttsDurationSeconds': 2,
          });
        }
        if (name == 'generateNodeVideo') node['videoStatus'] = 'ready';
      }
      return switch (name) {
        'createNode' => {'nodeId': 'node_1'},
        'generateNodeText' => {
          'title': 'Spark title',
          'ttsText': 'What should they do next?',
          'startImagePrompt': 'misty gate',
          'endImagePrompt': 'ashen city',
          'videoPrompt': 'slow push in',
          'choices': [
            {'label': 'Enter'},
            {'label': 'Climb'},
          ],
          'endingName': null,
        },
        _ => <String, dynamic>{},
      };
    },
    uploadVideoFile:
        upload ??
        ({
          required path,
          required contentType,
          required bytes,
          onProgress,
        }) async {
          calls?.add(
            _Call('uploadNodeVideo', {
              'path': path,
              'contentType': contentType,
              'byteLength': bytes.length,
            }),
          );
          onProgress?.call(1);
        },
  );
}

Future<void> _disposeBloc(WidgetTester tester, CreateBloc bloc) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var done = false;
  final closed = bloc.close().then((_) => done = true);
  for (var i = 0; i < 30 && !done; i++) {
    await tester.pump();
    await tester.runAsync(() async {});
  }
  expect(done, isTrue, reason: 'bloc disposes after unmount');
  await closed;
}
