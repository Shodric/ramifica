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
