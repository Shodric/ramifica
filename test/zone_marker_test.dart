import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/zone_marker.dart';

void main() {
  testWidgets('zone label counter hides below the cap, shows 24/24 at it', (
    tester,
  ) async {
    String? lastLabel;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ZoneMarker(
              nodeId: 'node_1',
              choices: const [
                DraftChoice(
                  choiceId: 'c1',
                  label: '',
                  targetNodeId: 'node_2',
                  isDefault: true,
                ),
              ],
              targets: const [],
              onLabelChanged: (_, label) => lastLabel = label,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('zone-label-c1'));
    expect(field, findsOneWidget);
    expect(_hintOpacity(tester), 1.0);

    await tester.enterText(field, 'Short');
    await tester.pumpAndSettle();
    expect(lastLabel, 'Short');
    expect(_hintOpacity(tester), 0.0);
    expect(find.textContaining('/24'), findsNothing);

    await tester.enterText(field, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123');
    await tester.pump();
    expect(lastLabel, hasLength(24));
    expect(find.text('24/24'), findsOneWidget);

    await tester.enterText(field, '');
    await tester.pumpAndSettle();
    expect(_hintOpacity(tester), 1.0);
  });

  testWidgets('empty options show two styled slot buttons, no helper text', (
    tester,
  ) async {
    await _pumpMarker(tester, choices: const [], onAddOption: (_) {});

    expect(find.text('Add a zone below to edit its hotspot.'), findsNothing);
    final a = find.byKey(const ValueKey('add-option-node_1-A'));
    final b = find.byKey(const ValueKey('add-option-node_1-B'));
    expect(a, findsOneWidget);
    expect(b, findsOneWidget);
    expect(tester.widget<FilledButton>(a), isA<FilledButton>());
    expect(tester.widget<FilledButton>(b), isA<FilledButton>());
    expect(find.text('Option A'), findsOneWidget);
    expect(find.text('Option B'), findsOneWidget);
    expect(find.byIcon(Icons.add_circle), findsNWidgets(2));
    expect(find.byKey(const ValueKey('open-option-node_1-A')), findsNothing);
    expect(find.byKey(const ValueKey('open-option-node_1-B')), findsNothing);
  });

  testWidgets('a taken slot leaves the remaining button at full width', (
    tester,
  ) async {
    String? added;
    await _pumpMarker(
      tester,
      choices: const [
        DraftChoice(
          choiceId: 'c1',
          label: 'Left',
          targetNodeId: 'node_2',
          isDefault: true,
          slot: 'A',
        ),
      ],
      onAddOption: (slot) => added = slot,
    );

    expect(find.byKey(const ValueKey('add-option-node_1-A')), findsNothing);
    expect(find.byKey(const ValueKey('open-option-node_1-A')), findsNothing);
    final b = find.byKey(const ValueKey('add-option-node_1-B'));
    expect(b, findsOneWidget);
    expect(tester.widget<FilledButton>(b), isA<FilledButton>());
    expect(tester.getSize(b).width, closeTo(300, 0.5));

    await tester.ensureVisible(b);
    await tester.tap(b);
    await tester.pump();
    expect(added, 'B');
  });

  testWidgets('two taken slots hide the add row', (tester) async {
    await _pumpMarker(
      tester,
      choices: const [
        DraftChoice(
          choiceId: 'c1',
          label: 'Left',
          targetNodeId: 'node_2',
          isDefault: true,
          slot: 'A',
        ),
        DraftChoice(
          choiceId: 'c2',
          label: 'Right',
          targetNodeId: 'node_3',
          isDefault: false,
          slot: 'B',
        ),
      ],
      onAddOption: (_) {},
    );

    expect(find.byKey(const ValueKey('add-option-node_1-A')), findsNothing);
    expect(find.byKey(const ValueKey('add-option-node_1-B')), findsNothing);
  });
}

/// Pumps a 300px-wide [ZoneMarker] over no frame.
Future<void> _pumpMarker(
  WidgetTester tester, {
  required List<DraftChoice> choices,
  required void Function(String slot) onAddOption,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Center(
            child: SizedBox(
              width: 300,
              child: ZoneMarker(
                nodeId: 'node_1',
                choices: choices,
                targets: const [],
                onAddOption: onAddOption,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opacity of the `Zone label` placeholder: 1 when the field is empty,
/// fading to 0 once it holds text.
double _hintOpacity(WidgetTester tester) {
  final hint = find.text('Zone label');
  expect(hint, findsOneWidget);
  final fader = find.ancestor(of: hint, matching: find.byType(AnimatedOpacity));
  expect(fader, findsOneWidget);
  return tester.widget<AnimatedOpacity>(fader).opacity;
}
