import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/persistence/draft_persistence.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_node_screen.dart';

import 'support/create_repository_harness.dart';
import 'support/memory_document_store.dart';

void main() {
  testWidgets('Finish saves a moved hotspot and returns to the canvas', (
    tester,
  ) async {
    final (bloc, store) = await _openOptions(tester);
    await _moveHotspot(tester);
    final moved = bloc.state.nodes.single.choices.single;
    expect(moved.x, greaterThan(0.25));
    expect(bloc.hasUnsavedNodeEdits('root'), isTrue);

    final finish = find.byKey(const ValueKey('wizard-continue'));
    await tester.ensureVisible(finish);
    await tester.pumpAndSettle();
    expect(find.text('Finish'), findsOneWidget);
    await tester.tap(finish);
    await tester.pumpAndSettle();

    expect(find.byType(CreateNodeScreen), findsNothing);
    expect(find.text('Canvas'), findsOneWidget);
    expect(find.text('Unsaved changes'), findsNothing);
    expect(bloc.hasUnsavedNodeEdits('root'), isFalse);
    final choices =
        store.documents['stories/story/nodes/root']!['choices'] as List;
    final saved = Map<String, dynamic>.from(choices.single as Map);
    expect(saved['x'], closeTo(moved.x, 1e-9));
    expect(saved['y'], closeTo(moved.y, 1e-9));
    expect(store.documents['stories/story']!['revision'], 1);
    expect(store.commits, 1);
  });

  testWidgets('a failed save keeps the editor and unsaved hotspot', (
    tester,
  ) async {
    final (bloc, store) = await _openOptions(tester);
    await _moveHotspot(tester);
    final moved = bloc.state.nodes.single.choices.single;
    store.beforeCommit = () async => throw const AppFailure(.offline);

    final finish = find.byKey(const ValueKey('wizard-continue'));
    await tester.ensureVisible(finish);
    await tester.pumpAndSettle();
    await tester.tap(finish);
    await tester.pumpAndSettle();

    expect(find.byType(CreateNodeScreen), findsOneWidget);
    expect(find.text('No connection'), findsOneWidget);
    expect(bloc.hasUnsavedNodeEdits('root'), isTrue);
    expect(bloc.state.nodes.single.choices.single.x, moved.x);
    final choices =
        store.documents['stories/story/nodes/root']!['choices'] as List;
    expect((choices.single as Map)['x'], 0.25);
    expect(store.commits, 0);
  });

  testWidgets('Finish also saves story edits that arrive during the save', (
    tester,
  ) async {
    final (bloc, store) = await _openOptions(tester);
    await _moveHotspot(tester);
    final started = Completer<void>();
    final resume = Completer<void>();
    var firstCommit = true;
    store.beforeCommit = () async {
      if (!firstCommit) return;
      firstCommit = false;
      started.complete();
      await resume.future;
    };

    final finish = find.byKey(const ValueKey('wizard-continue'));
    await tester.ensureVisible(finish);
    await tester.pumpAndSettle();
    await tester.tap(finish);
    await tester.pump();
    expect(started.isCompleted, isTrue);
    bloc.add(const StoryFieldChanged(title: 'Edited while saving'));
    await tester.pump();
    expect(bloc.hasUnsavedStoryEdits, isTrue);
    resume.complete();
    await tester.pumpAndSettle();

    expect(find.byType(CreateNodeScreen), findsNothing);
    expect(store.documents['stories/story']!['title'], 'Edited while saving');
    expect(bloc.hasUnsavedStoryEdits, isFalse);
    expect(bloc.hasUnsavedNodeEdits('root'), isFalse);
  });
}

Future<(CreateBloc, MemoryDocumentStore)> _openOptions(
  WidgetTester tester,
) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final store = MemoryDocumentStore();
  store.documents['stories/story'] = {
    'authorId': 'author',
    'title': 'Story',
    'synopsis': '',
    'status': 'draft',
    'rootNodeId': 'root',
    'revision': 0,
  };
  store.documents['stories/story/nodes/root'] = const DraftNode(
    nodeId: 'root',
    title: 'Gate',
    ttsText: 'Choose a path',
    ttsStatus: 'ready',
    startImageStatus: 'ready',
    videoStatus: 'ready',
    choices: [
      DraftChoice(
        choiceId: 'door',
        label: 'Enter',
        targetNodeId: 'next',
        isDefault: true,
        x: 0.25,
        y: 0.65,
        radius: 0.12,
      ),
    ],
  ).toJson();
  final repository = testCreateRepository(
    createDraftDoc: ({required authorId, required title}) async => 'story',
    fetchStoryDoc: (id) => store.get('stories/$id'),
    fetchNodeDocs: (id) => store.list('stories/$id/nodes'),
    callFunction: (_, _) async => {},
  );
  final bloc = CreateBloc(
    repository: repository,
    drafts: ClientDraftPersistence(store, () => 'author'),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    var closed = false;
    final closing = bloc.close().then((_) => closed = true);
    for (var i = 0; i < 30 && !closed; i++) {
      await tester.pump();
      await tester.runAsync(() async {});
    }
    expect(closed, isTrue);
    await closing;
    store.close();
  });
  bloc.add(const DraftOpened('story'));
  await bloc.stream.firstWhere((state) => state.hasDraft);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CreateNodeScreen(
                  bloc: bloc,
                  nodeId: 'root',
                  pickVideo: null,
                  newTakeId: () => 'take',
                ),
              ),
            ),
            child: const Text('Canvas'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Canvas'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('wizard-step-4')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('zone-door')), findsOneWidget);
  return (bloc, store);
}

Future<void> _moveHotspot(WidgetTester tester) async {
  final zone = find.byKey(const ValueKey('zone-door'));
  await tester.ensureVisible(zone);
  await tester.pumpAndSettle();
  final gesture = await tester.startGesture(tester.getCenter(zone));
  await gesture.moveBy(const Offset(20, 0));
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await gesture.moveBy(const Offset(10, 0));
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}
