import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';
import 'package:ramifica/features/create/ending_setup_dialog.dart';
import 'package:ramifica/features/create/steps/step_hotspots.dart';

import 'support/create_repository_harness.dart';

void main() {
  group('DraftNode ending badge', () {
    test('round-trips endingBadgeUrl through map/json/copy', () {
      const node = DraftNode(
        nodeId: 'node_1',
        isEnding: true,
        endingType: 'epic',
        endingBadgeUrl: 'https://cdn.example/badge.png',
      );

      final revived = DraftNode.fromMap('node_1', node.toJson());
      expect(revived.endingBadgeUrl, 'https://cdn.example/badge.png');
      expect(revived, node);

      final cleared = node.copy(endingBadgeUrl: () => null);
      expect(cleared.endingBadgeUrl, isNull);
      expect(cleared.toJson(), contains('endingBadgeUrl'));

      final legacy = DraftNode.fromMap('node_1', {'title': 'Door'});
      expect(legacy.endingBadgeUrl, isNull);
    });

    test('nodeSavePatch carries endingBadgeUrl', () {
      const node = DraftNode(
        nodeId: 'node_1',
        endingBadgeUrl: 'https://cdn.example/badge.png',
      );
      final patch = nodeSavePatch(node, '');
      expect(patch['endingBadgeUrl'], 'https://cdn.example/badge.png');
    });
  });

  group('CreateRepository.generateEndingBadge', () {
    test('calls the callable and returns the badge URL', () async {
      final calls = <_Call>[];
      final repository = _repo(calls);

      final url = await repository.generateEndingBadge(
        storyId: 'story_1',
        nodeId: 'node_1',
        endingType: 'tragic',
      );

      expect(url, 'https://cdn.example/badge.png');
      expect(calls.single.name, 'generateEndingBadge');
      expect(calls.single.data, {
        'storyId': 'story_1',
        'nodeId': 'node_1',
        'endingType': 'tragic',
      });
    });

    test('blank ids fail without calling', () async {
      final calls = <_Call>[];
      final repository = _repo(calls);

      await expectLater(
        repository.generateEndingBadge(storyId: '  ', nodeId: 'node_1'),
        throwsA(const AppFailure(.invalid)),
      );
      expect(calls, isEmpty);
    });

    test('a payload without badgeUrl fails closed', () async {
      final repository = _repo(null, badgeAnswer: <String, dynamic>{});

      await expectLater(
        repository.generateEndingBadge(storyId: 'story_1', nodeId: 'node_1'),
        throwsA(isA<AppFailure>()),
      );
    });
  });

  group('CreateBloc ending events', () {
    test('NodeEndingTypeChanged updates the node and persists', () async {
      final calls = <_Call>[];
      final bloc = CreateBloc(repository: _repo(calls, ending: true));
      addTearDown(bloc.close);
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);
      calls.clear();

      bloc.add(
        const NodeEndingTypeChanged(nodeId: 'node_1', endingType: 'epic'),
      );
      await bloc.stream.firstWhere(
        (state) =>
            state.nodes
                .singleWhere((node) => node.nodeId == 'node_1')
                .endingType ==
            'epic',
      );

      expect(
        bloc.state.nodes
            .singleWhere((node) => node.nodeId == 'node_1')
            .endingType,
        'epic',
      );
      expect(bloc.state.failure, isNull);
      // The update rides the existing save path.
      await bloc.stream.firstWhere((state) => state.job == CreateJob.none);
      expect(
        calls.any(
          (call) =>
              call.name == 'saveNode' &&
              (call.data['node'] as Map)['endingType'] == 'epic',
        ),
        isTrue,
      );
    });

    test('NodeEndingTypeChanged ignores unknown nodes and types', () async {
      final calls = <_Call>[];
      final bloc = CreateBloc(repository: _repo(calls, ending: true));
      addTearDown(bloc.close);
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);
      calls.clear();

      bloc
        ..add(
          const NodeEndingTypeChanged(nodeId: 'missing', endingType: 'epic'),
        )
        ..add(
          const NodeEndingTypeChanged(nodeId: 'node_1', endingType: 'nope'),
        );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        bloc.state.nodes
            .singleWhere((node) => node.nodeId == 'node_1')
            .endingType,
        'open',
      );
      expect(calls, isEmpty);
    });

    test('NodeEndingBadgeRequested stores the generated URL', () async {
      final calls = <_Call>[];
      final bloc = CreateBloc(repository: _repo(calls, ending: true));
      addTearDown(bloc.close);
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);
      calls.clear();

      bloc.add(const NodeEndingBadgeRequested('node_1'));
      await bloc.stream.firstWhere(
        (state) =>
            state.nodes
                .singleWhere((node) => node.nodeId == 'node_1')
                .endingBadgeUrl ==
            'https://cdn.example/badge.png',
      );

      expect(calls.any((call) => call.name == 'generateEndingBadge'), isTrue);
      expect(bloc.state.failure, isNull);
      await bloc.stream.firstWhere((state) => state.job == CreateJob.none);
    });

    test('badge errors land on the snack failure, not inline', () async {
      final bloc = CreateBloc(
        repository: _repo(null, ending: true, failBadge: true),
      );
      addTearDown(bloc.close);
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);

      bloc.add(const NodeEndingBadgeRequested('node_1'));
      await bloc.stream.firstWhere((state) => state.failure != null);

      expect(bloc.state.job, CreateJob.none);
      expect(
        bloc.state.nodes
            .singleWhere((node) => node.nodeId == 'node_1')
            .endingBadgeUrl,
        isNull,
      );
    });
  });

  group('EndingSetupDialog', () {
    testWidgets('tapping Final scene opens the popup', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StepHotspots(
                node: const DraftNode(
                  nodeId: 'node_1',
                  isEnding: true,
                  endingType: 'open',
                ),
                busy: false,
                showErrors: false,
                onEndingTypeChanged: (_) {},
                onEndingBadgeRequested: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(const ValueKey('final-scene-node_1'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(find.byType(EndingSetupDialog), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ending-type-dropdown')),
        findsOneWidget,
      );
      expect(find.text('Generate'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('picking a type dispatches NodeEndingTypeChanged', (
      tester,
    ) async {
      final bloc = CreateBloc(repository: _repo(null, ending: true));
      addTearDown(bloc.close);
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);
      final node = bloc.state.nodes.singleWhere(
        (candidate) => candidate.nodeId == 'node_1',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StepHotspots(
                node: node,
                busy: false,
                showErrors: false,
                onEndingTypeChanged: (type) => bloc.add(
                  NodeEndingTypeChanged(nodeId: 'node_1', endingType: type),
                ),
                onEndingBadgeRequested: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(const ValueKey('final-scene-node_1'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();

      // Subscribe before tapping: the matching state lands while
      // pumpAndSettle flushes the bloc, so subscribing after would hang.
      final updated = bloc.stream.firstWhere(
        (state) =>
            state.nodes
                .singleWhere((candidate) => candidate.nodeId == 'node_1')
                .endingType ==
            'epic',
      );
      await tester.tap(find.byKey(const ValueKey('ending-type-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Epic').last);
      await tester.pumpAndSettle();

      await updated;
      expect(
        bloc.state.nodes
            .singleWhere((candidate) => candidate.nodeId == 'node_1')
            .endingType,
        'epic',
      );
    });

    testWidgets('Generate shows a loader while the request runs', (
      tester,
    ) async {
      final gate = Completer<void>();
      var requested = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EndingSetupDialog(
              nodeId: 'node_1',
              endingType: 'open',
              onBadgeRequested: () async {
                requested = true;
                await gate.future;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Generate'));
      await tester.pump();

      expect(requested, isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('badge preview shows the image or a placeholder', (
      tester,
    ) async {
      Future<void> pump(String? url) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EndingSetupDialog(nodeId: 'node_1', endingBadgeUrl: url),
          ),
        ),
      );

      await pump(null);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ending-badge-placeholder')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('ending-badge-image')), findsNothing);

      await pump('https://cdn.example/badge.png');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ending-badge-placeholder')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('ending-badge-image')), findsOneWidget);
    });

    testWidgets('badge preview swaps in live when generation lands', (
      tester,
    ) async {
      final bloc = CreateBloc(repository: _repo(null, ending: true));
      addTearDown(bloc.close);
      bloc.add(const DraftOpened('story_1'));
      await bloc.stream.firstWhere((state) => state.hasDraft);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EndingSetupDialog(
              nodeId: 'node_1',
              bloc: bloc,
              onBadgeRequested: () async {
                bloc.add(const NodeEndingBadgeRequested('node_1'));
                await bloc.stream.firstWhere(
                  (state) => state.job == CreateJob.none,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ending-badge-placeholder')),
        findsOneWidget,
      );

      await tester.tap(find.text('Generate'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('ending-badge-placeholder')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('ending-badge-image')), findsOneWidget);
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
  bool ending = false,
  Map<String, dynamic>? badgeAnswer,
  bool failBadge = false,
}) {
  Map<String, dynamic> nodeDoc() => {
    'title': 'Fall',
    'visibility': 'visible',
    'isEnding': ending,
    'endingType': ending ? 'open' : null,
    'videoStatus': 'idle',
    'ttsText': '',
    'ttsStatus': 'idle',
    'choices': [],
  };
  return testCreateRepository(
    createDraftDoc: ({required authorId, required title}) async => 'story_1',
    fetchStoryDoc: (_) async => {
      'authorId': 'uid_1',
      'title': 'Temple',
      'synopsis': '',
      'status': 'draft',
      'rootNodeId': 'node_1',
    },
    fetchNodeDocs: (_) async => [MapEntry('node_1', nodeDoc())],
    callFunction: (name, data) async {
      calls?.add(_Call(name, data));
      if (name == 'generateEndingBadge') {
        if (failBadge) throw const AppFailure(.failed);
        return badgeAnswer ?? {'badgeUrl': 'https://cdn.example/badge.png'};
      }
      return <String, dynamic>{};
    },
  );
}
