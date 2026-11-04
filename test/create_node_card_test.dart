import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/create_node_card.dart';

void main() {
  const badgeUrl = 'https://example.com/badge.png';

  Future<void> pumpCard(WidgetTester tester, DraftNode node) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CreateNodeCard(
              node: node,
              sceneIndex: 1,
              isRoot: false,
              isOpen: false,
              isOrphan: false,
              onTap: () {},
            ),
          ),
        ),
      );

  Finder badgeImage() => find.byWidgetPredicate(
    (w) =>
        w is Image &&
        w.image is NetworkImage &&
        (w.image as NetworkImage).url == badgeUrl,
  );

  testWidgets('shows a small badge thumbnail when the node has one', (
    tester,
  ) async {
    await pumpCard(
      tester,
      const DraftNode(nodeId: 'node_1', endingBadgeUrl: badgeUrl),
    );
    await tester.pump();

    expect(badgeImage(), findsOneWidget);
    final thumb = find.ancestor(
      of: badgeImage(),
      matching: find.byType(Container),
    );
    expect(thumb, findsWidgets);
    final size = tester.getSize(thumb.first);
    expect(size.width, 28);
    expect(size.height, 28);
  });

  testWidgets('shows no badge thumbnail without a badge url', (tester) async {
    await pumpCard(tester, const DraftNode(nodeId: 'node_1'));
    await tester.pumpAndSettle();

    expect(badgeImage(), findsNothing);
  });
}
