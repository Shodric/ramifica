import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/ending_badge.dart';

Future<void> _pump(WidgetTester tester, String? type) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: EndingBadge(type: type)),
    ),
  );
}

Color _textColor(WidgetTester tester, String label) {
  final text = tester.widget<Text>(find.text(label));
  return text.style!.color!;
}

void main() {
  testWidgets('EndingBadge renders Spanish labels for the new ending types', (
    tester,
  ) async {
    const labels = {
      'heroic': 'Heroico',
      'mysterious': 'Misterioso',
      'bittersweet': 'Agridulce',
      'dark': 'Oscuro',
      'epic': 'Épico',
      'incomplete': 'Incompleto',
    };
    for (final entry in labels.entries) {
      await _pump(tester, entry.key);
      expect(find.text(entry.value), findsOneWidget, reason: entry.key);
    }
  });

  testWidgets('EndingBadge colors the new ending types distinctly', (
    tester,
  ) async {
    const colors = {
      'Heroico': RamificaColors.rewardGold,
      'Misterioso': RamificaColors.brandViolet,
      'Agridulce': RamificaColors.danger,
      'Oscuro': RamificaColors.textPrimary,
      'Épico': RamificaColors.hotspot,
      'Incompleto': RamificaColors.textSecondary,
    };
    const types = {
      'Heroico': 'heroic',
      'Misterioso': 'mysterious',
      'Agridulce': 'bittersweet',
      'Oscuro': 'dark',
      'Épico': 'epic',
      'Incompleto': 'incomplete',
    };
    for (final label in colors.keys) {
      await _pump(tester, types[label]);
      expect(_textColor(tester, label), colors[label], reason: label);
    }
  });

  testWidgets('EndingBadge keeps legacy labels and renders unknown as-is', (
    tester,
  ) async {
    await _pump(tester, 'tragic');
    expect(find.text('Tragic'), findsOneWidget);

    await _pump(tester, 'xyz');
    expect(find.text('xyz'), findsOneWidget);

    await _pump(tester, null);
    expect(find.text('Ending'), findsOneWidget);
  });
}
