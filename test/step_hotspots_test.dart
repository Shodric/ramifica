import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/steps/step_hotspots.dart';
import 'package:ramifica/features/create/zone_marker.dart';

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

  testWidgets('a lone slot button gets a top margin, a pair does not', (
    tester,
  ) async {
    // Top inset of the Padding hugging the slot button itself.
    double closestTop(String key) {
      final paddings = find.ancestor(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Padding),
      );
      final padding =
          (paddings.evaluate().last.widget as Padding).padding as EdgeInsets;
      return padding.top;
    }

    Future<void> pump(DraftNode node) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StepHotspots(
              node: node,
              busy: false,
              showErrors: false,
              onAddHotspot: (_) {},
              onAddBranch: () {},
            ),
          ),
        ),
      ),
    );

    await pump(const DraftNode(nodeId: 'node_1'));
    await tester.pumpAndSettle();
    expect(closestTop('add-option-node_1-A'), 0);

    // One slot taken: the lone remaining button spans full width with a
    // top margin. (A cut slot renders a chip instead, so the row still
    // holds two widgets and takes the pair branch.)
    const lone = DraftNode(
      nodeId: 'node_1',
      choices: [
        DraftChoice(
          choiceId: 'c1',
          label: 'Go',
          targetNodeId: 'node_2',
          isDefault: true,
          slot: 'A',
        ),
      ],
    );
    await pump(lone);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('add-option-node_1-B')),
      findsOneWidget,
    );
    expect(closestTop('add-option-node_1-B'), 8);
  });

  testWidgets('long-pressing a slot button reports a cut toggle', (
    tester,
  ) async {
    String? cutSlot;
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
              onCutToggled: (slot) => cutSlot = slot,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('add-option-node_1-A')),
    );
    await tester.longPress(
      find.byKey(const ValueKey('add-option-node_1-A')),
    );
    await tester.pumpAndSettle();

    expect(cutSlot, 'A');
  });

  testWidgets('a cut path shows a chip instead of its button', (tester) async {
    String? cutSlot;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StepHotspots(
              node: const DraftNode(nodeId: 'node_1', cutSlots: {'B'}),
              busy: false,
              showErrors: false,
              onAddHotspot: (_) {},
              onAddBranch: () {},
              onCutToggled: (slot) => cutSlot = slot,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('add-option-node_1-A')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-option-node_1-B')), findsNothing);
    expect(find.byKey(const ValueKey('cut-option-node_1-B')), findsOneWidget);
    expect(find.text('Path B cut'), findsOneWidget);

    // Long-pressing the chip restores the path.
    await tester.ensureVisible(
      find.byKey(const ValueKey('cut-option-node_1-B')),
    );
    await tester.longPress(
      find.byKey(const ValueKey('cut-option-node_1-B')),
    );
    await tester.pumpAndSettle();

    expect(cutSlot, 'B');
  });

  testWidgets('the ending toggle flips straight through with no options', (
    tester,
  ) async {
    bool? ending;
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
              onEndingToggled: (value) => ending = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('ending-toggle-node_1')),
    );
    await tester.tap(find.byKey(const ValueKey('ending-toggle-node_1')));
    await tester.pumpAndSettle();

    expect(find.text('Make this the final scene?'), findsNothing);
    expect(ending, isTrue);
  });

  testWidgets('the ending toggle warns before deleting options', (
    tester,
  ) async {
    const node = DraftNode(
      nodeId: 'node_1',
      choices: [
        DraftChoice(
          choiceId: 'c1',
          label: 'Go',
          targetNodeId: 'node_2',
          isDefault: true,
        ),
      ],
    );
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StepHotspots(
              node: node,
              busy: false,
              showErrors: false,
              onAddHotspot: (_) {},
              onAddBranch: () {},
              onEndingToggled: (_) => calls++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('ending-toggle-node_1')),
    );
    await tester.tap(find.byKey(const ValueKey('ending-toggle-node_1')));
    await tester.pumpAndSettle();

    expect(find.text('Make this the final scene?'), findsOneWidget);
    expect(
      find.text('This scene has 1 option. Making it final will delete them.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, 0);

    await tester.ensureVisible(
      find.byKey(const ValueKey('ending-toggle-node_1')),
    );
    await tester.tap(find.byKey(const ValueKey('ending-toggle-node_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make final'));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  group('final scene marker', () {
    Future<void> pumpMarker(
      WidgetTester tester, {
      required bool isEnding,
    }) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ZoneMarker(
                  nodeId: 'node_1',
                  choices: const [],
                  targets: const [],
                  isEnding: isEnding,
                  onAddOption: (_) {},
                ),
              ),
            ),
          ),
        );

    testWidgets('keeps the HUD and swaps option buttons for the container', (
      tester,
    ) async {
      await pumpMarker(tester, isEnding: true);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('final-scene-node_1')), findsOneWidget);
      expect(find.text('Final scene'), findsOneWidget);
      expect(find.byIcon(Icons.emoji_events), findsOneWidget);
      expect(find.byKey(const ValueKey('add-option-node_1-A')), findsNothing);
      expect(find.byKey(const ValueKey('add-option-node_1-B')), findsNothing);
      // HUD preview stays visible: frame grid toggle + placeholder text.
      expect(find.byKey(const ValueKey('zone-grid-toggle')), findsOneWidget);
      expect(find.text('Generate the clip to place zones.'), findsOneWidget);
    });

    testWidgets('container matches the Add Option button styling', (
      tester,
    ) async {
      await pumpMarker(tester, isEnding: false);
      await tester.pumpAndSettle();
      final addButton = tester.widget<FilledButton>(
        find.byKey(const ValueKey('add-option-node_1-A')),
      );
      final addShape =
          addButton.style?.shape?.resolve({}) as RoundedRectangleBorder;

      await pumpMarker(tester, isEnding: true);
      await tester.pumpAndSettle();
      final container = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('final-scene-node_1')),
      );
      final decoration = container.decoration as BoxDecoration;

      expect(decoration.color, RamificaColors.containerBase);
      expect(decoration.borderRadius, addShape.borderRadius);
      expect(
        addButton.style?.backgroundColor?.resolve({}),
        RamificaColors.containerBase,
      );
    });
  });
}
