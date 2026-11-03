import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/app.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/app_snackbar.dart';
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

  testWidgets('FailureText fits a one-pixel viewport', (tester) async {
    for (final retry in <VoidCallback?>[null, () {}]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox.square(
                dimension: 1,
                child: FailureText(
                  message: 'That action is not valid',
                  onRetry: retry,
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('FailureText can scroll to Retry in a short viewport', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 60,
              child: FailureText(
                message: 'A long error message. ' * 10,
                onRetry: () => taps++,
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    expect(taps, 1);
  });

  testWidgets('error and notice snackbars show one styled message', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () =>
                      showErrorSnackBar(context, 'Something failed.'),
                  child: const Text('fail'),
                ),
                TextButton(
                  onPressed: () =>
                      showNoticeSnackBar(context, 'Just so you know.'),
                  child: const Text('notify'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('fail'));
    await tester.pump();
    expect(find.text('Something failed.'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    final errorBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(errorBar.behavior, SnackBarBehavior.floating);

    // A new message replaces the current one instead of stacking.
    await tester.tap(find.text('notify'));
    await tester.pump();
    expect(find.text('Something failed.'), findsNothing);
    expect(find.text('Just so you know.'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
