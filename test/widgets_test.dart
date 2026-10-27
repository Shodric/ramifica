import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/app.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';
import 'package:ramifica/core/widgets/status_pill.dart';

void main() {
  testWidgets('theme uses the bundled families', (tester) async {
    await tester.pumpWidget(const RamificaApp());
    final theme = Theme.of(tester.element(find.text('Continue with Google')));

    expect(theme.textTheme.bodyLarge?.fontFamily, RamificaText.sans);
    expect(theme.textTheme.headlineMedium?.fontFamily, RamificaText.display);
    expect(theme.textTheme.headlineMedium?.fontWeight, FontWeight.w700);
    expect(theme.scaffoldBackgroundColor, RamificaColors.surface);
  });

  testWidgets('GlassPanel blurs and keeps its child', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: GlassPanel(child: Text('Inside'))),
      ),
    );

    expect(find.text('Inside'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('EmptyState shows a button only when it can run', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmptyState(
            message: 'Nothing here',
            actionLabel: 'Start',
            onAction: () => taps++,
          ),
        ),
      ),
    );

    expect(find.text('Nothing here'), findsOneWidget);
    await tester.tap(find.text('Start'));
    expect(taps, 1);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: EmptyState(message: 'Nothing here')),
      ),
    );
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('StatusPill names each state', (tester) async {
    for (final status in StatusPillState.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: StatusPill(status: status)),
        ),
      );
      expect(find.text(status.label), findsOneWidget);
    }
  });

  testWidgets('FailureText retry sends the tap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FailureText(message: 'Offline', onRetry: () => taps++),
        ),
      ),
    );

    expect(find.text('Offline'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(taps, 1);
  });
}
