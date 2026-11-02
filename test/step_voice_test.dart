import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/steps/step_voice.dart';

Future<void> _pumpStepVoice(
  WidgetTester tester, {
  DraftNode? node,
  bool generating = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StepVoice(
            node:
                node ??
                const DraftNode(nodeId: 'n1', ttsText: 'Pick your path.'),
            busy: false,
            active: false,
            generating: generating,
            showErrors: false,
            onVoiceGenerate: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('voice step without audio shows one Generate voice button', (
    tester,
  ) async {
    await _pumpStepVoice(tester);
    await tester.pump();

    expect(find.text('Generate voice'), findsOneWidget);
    expect(find.text('Another take'), findsNothing);
    expect(find.text('No narrator voice yet.'), findsOneWidget);
  });

  testWidgets('generating voice swaps the button label for a spinner', (
    tester,
  ) async {
    await _pumpStepVoice(
      tester,
      node: const DraftNode(
        nodeId: 'n1',
        ttsText: 'Pick your path.',
        ttsStatus: 'pending',
      ),
      generating: true,
    );
    await tester.pump();

    expect(find.text('Generating voice…'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('gen-voice-n1')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
  });

  testWidgets('voice step with audio regens from Generate voice', (
    tester,
  ) async {
    await _pumpStepVoice(
      tester,
      node: const DraftNode(
        nodeId: 'n1',
        ttsText: 'Pick your path.',
        ttsAudioUrl: 'https://example.com/voice.mp3',
        ttsStatus: 'ready',
      ),
    );
    await tester.pump();

    expect(find.text('Generate voice'), findsOneWidget);
    expect(find.text('Another take'), findsNothing);
    expect(find.text('Ready'), findsNothing);
  });
}
