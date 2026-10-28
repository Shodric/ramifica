import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';
import 'package:ramifica/features/profile/later_block.dart';

void main() {
  Future<void> pumpBlock(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: LaterBlock())),
    );
    await tester.pump();
  }

  group('LaterBlock', () {
    testWidgets('renders both placeholder rows with soon labels', (
      tester,
    ) async {
      await pumpBlock(tester);

      expect(find.byType(GlassPanel), findsOneWidget);
      expect(find.text('Live room'), findsOneWidget);
      expect(find.text('Guild'), findsOneWidget);
      expect(find.text('Soon'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
    });

    testWidgets('rows are inert: no tap handlers, no navigation', (
      tester,
    ) async {
      await pumpBlock(tester);

      expect(find.byType(GestureDetector), findsNothing);
      expect(find.byType(InkWell), findsNothing);

      await tester.tap(find.text('Live room'));
      await tester.pump();
      expect(find.text('Live room'), findsOneWidget);

      await tester.tap(find.text('Guild'));
      await tester.pump();
      expect(find.text('Guild'), findsOneWidget);
    });

    testWidgets('renders with no bloc, providers, or async work', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: LaterBlock())),
      );
      // pumpAndSettle would hang on never-settling animations; a single
      // pump suffices because the block is fully static.
      await tester.pump();
      expect(find.byType(LaterBlock), findsOneWidget);
    });
  });
}
