import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_view.dart';
import 'package:ramifica/features/create/draft_canvas.dart';

void main() {
  group('CreateView', () {
    testWidgets('an empty tab offers a draft', (tester) async {
      final bloc = CreateBloc(repository: _repo(null));
      addTearDown(bloc.close);
      await tester.pumpWidget(
        MaterialApp(home: CreateView(bloc: bloc)),
      );

      expect(find.text('Your drafts live here.'), findsOneWidget);
      await tester.tap(find.text('Start a draft'));
      await tester.pumpAndSettle();

      expect(bloc.state.hasDraft, isTrue);
      expect(bloc.state.openNodeId, 'node_1');
    });

    testWidgets('the canvas selects nodes and the inspector edits them', (
      tester,
    ) async {
      final bloc = await _pumpDraft(tester);

      // Titles, secrets, and orphans draw on the canvas painter, which
      // widget finders cannot see; selection through it is asserted below.

      // Tapping the leaf selects it in the inspector.
      final layout = layoutDraft(
        bloc.state.nodes,
        rootNodeId: 'node_1',
      );
      final origin = tester.getTopLeft(find.byType(DraftCanvas));
      await tester.tapAt(origin + layout.positions['node_2']!);
      await tester.pumpAndSettle();
      expect(bloc.state.openNodeId, 'node_2');

      // Manual edits write bloc state through the fields.
      await tester.enterText(
        find.byKey(const ValueKey('title-node_2')),
        'Typed leaf',
      );
      await tester.pump();
      expect(bloc.state.openNode?.title, 'Typed leaf');
    });

    testWidgets('Spark fills empties but keeps manual edits', (tester) async {
      final calls = <_Call>[];
      final bloc = await _pumpDraft(tester, calls);

      await tester.enterText(
        find.byKey(const ValueKey('title-node_1')),
        'Typed root',
      );
      await tester.pump();
      await tester.tap(find.text('Spark'));
      await tester.pumpAndSettle();

      expect(calls.single.name, 'generateNodeText');
      expect(bloc.state.openNode?.title, 'Typed root');
      expect(
        bloc.state.openNode?.ttsText,
        'What should they do next?',
      );
    });

    testWidgets('Regenerate overwrites manual edits', (tester) async {
      final bloc = await _pumpDraft(tester);

      await tester.enterText(
        find.byKey(const ValueKey('title-node_1')),
        'Typed root',
      );
      await tester.pump();
      await tester.tap(find.text('Regenerate'));
      await tester.pumpAndSettle();

      expect(bloc.state.openNode?.title, 'Spark title');
    });

    testWidgets('Save sends the edited node and missing is listed', (
      tester,
    ) async {
      final calls = <_Call>[];
      await _pumpDraft(tester, calls);

      expect(find.textContaining('needs a ready video'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is StatusPill && widget.status == StatusPillState.idle,
        ),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('title-node_1')),
        'Typed root',
      );
      await tester.pump();
      calls.clear();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final save = calls.singleWhere((call) => call.name == 'saveNode');
      final sent = (save.data['node'] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
      expect(sent['title'], 'Typed root');
    });

    testWidgets('a failure shows its phrase', (tester) async {
      final bloc = CreateBloc(
        repository: CreateRepository(
          createDraftDoc: ({required authorId, required title}) async =>
              throw const AppFailure(.offline),
          fetchStoryDoc: (_) async => throw const AppFailure(.offline),
          fetchNodeDocs: (_) async => const [],
          callFunction: (name, data) async =>
              throw const AppFailure(.offline),
        ),
      );
      addTearDown(bloc.close);
      await tester.pumpWidget(
        MaterialApp(home: CreateView(bloc: bloc)),
      );

      await tester.tap(find.text('Start a draft'));
      await tester.pumpAndSettle();

      // No author id and no signed-in identity: fails before any network.
      expect(find.text('That action is not valid'), findsOneWidget);
    });
  });
}

class _Call {
  const _Call(this.name, this.data);

  final String name;
  final Map<String, dynamic> data;
}

Future<CreateBloc> _pumpDraft(WidgetTester tester, [List<_Call>? calls]) async {
  final bloc = CreateBloc(repository: _repo(calls));
  addTearDown(bloc.close);
  bloc.add(const DraftOpened('story_1'));
  await bloc.stream.firstWhere((state) => state.hasDraft);
  await tester.pumpWidget(MaterialApp(home: CreateView(bloc: bloc)));
  await tester.pumpAndSettle();
  return bloc;
}

CreateRepository _repo(List<_Call>? calls) {
  return CreateRepository(
    createDraftDoc: ({required authorId, required title}) async => 'story_1',
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
      }),
      const MapEntry('node_2', {
        'title': 'Leaf',
        'visibility': 'secret',
        'isEnding': true,
        'endingName': 'Escape',
        'endingType': 'abierto',
      }),
    ],
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
