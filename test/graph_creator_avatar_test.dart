import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/graph_stub.dart';
import 'package:ramifica/data/repositories/graph_repository.dart';
import 'package:ramifica/features/graph/graph_view.dart';

void main() {
  group('Map creator avatar', () {
    test('graphStubs carries the story author', () {
      final result = GraphStubsResult.fromJson(_stubs());

      expect(result.storyAuthorId, 'u_author');
      expect(result.storyAuthorName, 'Alex Vance');
      expect(result.storyAuthorPhotoUrl, 'https://cdn.invalid/alex.png');
    });

    testWidgets('a circular creator photo sits above the root card', (
      tester,
    ) async {
      await _pumpGraph(tester, _stubs());

      final avatar = find.byKey(const ValueKey('creator-avatar'));
      expect(avatar, findsOneWidget);
      final decoration =
          tester.widget<Container>(avatar).decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      final avatarCenter = tester.getCenter(avatar);
      final rootCenter = tester.getCenter(
        find.byKey(const ValueKey('canvas-node-node_001')),
      );
      expect(avatarCenter.dy, lessThan(rootCenter.dy));
      expect((avatarCenter.dx - rootCenter.dx).abs(), lessThan(1));
    });

    testWidgets('no author means no avatar', (tester) async {
      await _pumpGraph(tester, _stubs(withAuthor: false));

      expect(find.byKey(const ValueKey('creator-avatar')), findsNothing);
    });

    testWidgets('tapping the avatar opens the creator profile', (
      tester,
    ) async {
      final opened = <String>[];
      await _pumpGraph(
        tester,
        _stubs(),
        onCreatorOpen: opened.add,
      );
      await tester.tap(find.byKey(const ValueKey('creator-avatar')));
      await tester.pumpAndSettle();

      expect(opened, ['u_author']);
    });

    testWidgets('the connector carries the creator full name', (
      tester,
    ) async {
      await _pumpGraph(tester, _stubs());

      final badge = find.byKey(const ValueKey('creator-name'));
      expect(badge, findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text('Alex Vance')),
        findsOneWidget,
      );
      final badgeCenter = tester.getCenter(badge);
      final avatarCenter = tester.getCenter(
        find.byKey(const ValueKey('creator-avatar')),
      );
      final rootCenter = tester.getCenter(
        find.byKey(const ValueKey('canvas-node-node_001')),
      );
      expect(badgeCenter.dy, greaterThan(avatarCenter.dy));
      expect(badgeCenter.dy, lessThan(rootCenter.dy));
      expect((badgeCenter.dx - rootCenter.dx).abs(), lessThan(1));
    });

    testWidgets('photo without a name shows no name badge', (tester) async {
      await _pumpGraph(tester, _stubs(withName: false));

      expect(find.byKey(const ValueKey('creator-avatar')), findsOneWidget);
      expect(find.byKey(const ValueKey('creator-name')), findsNothing);
    });
  });
}

Future<void> _pumpGraph(
  WidgetTester tester,
  Map<String, dynamic> stubs, {
  void Function(String authorId)? onCreatorOpen,
}) async {
  final repository = GraphRepository(
    execute: (name, data) async => stubs,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: GraphView(
        storyId: 'story_temple',
        runId: 'run_1',
        repository: repository,
        onCreatorOpen: onCreatorOpen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> _stubs({bool withAuthor = true, bool withName = true}) {
  return {
    'currentNodeId': 'node_001',
    'story': {
      'title': 'The temple secret',
      'coverUrl': 'https://cover/c.png',
      if (withAuthor) ...{
        'authorId': 'u_author',
        if (withName) 'authorName': 'Alex Vance',
        'authorPhotoUrl': 'https://cdn.invalid/alex.png',
      },
    },
    'nodes': [
      {
        'nodeId': 'node_001',
        'title': 'The temple door',
        'isEnding': false,
        'visited': true,
        'secret': false,
        'choiceCount': 10,
        'childIds': ['node_002'],
        'choices': [
          {'choiceId': 'c_enter', 'label': 'Enter the room', 'count': 10},
        ],
      },
      {
        'nodeId': 'node_002',
        'title': 'The inner room',
        'isEnding': false,
        'visited': true,
        'secret': false,
        'choiceCount': 0,
        'childIds': <String>[],
      },
    ],
  };
}
