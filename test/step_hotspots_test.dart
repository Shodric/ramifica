import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/steps/step_hotspots.dart';

void main() {
  testWidgets('the step shows only the styled slot buttons, no bottom add', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StepHotspots(
              node: const DraftNode(nodeId: 'node_1'),
              busy: false,
              showErrors: false,
              onAddHotspot: (_) {},
              onAddBranch: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Add Option (+)'), findsNothing);
    expect(find.text('Add a zone below to edit its hotspot.'), findsNothing);
    expect(find.byKey(const ValueKey('add-option-node_1-A')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-option-node_1-B')), findsOneWidget);
  });
}
