import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/steps/fill_preview_dialog.dart';

const _full = SceneProposal(
  title: 'Spark title',
  ttsText: 'What should they do next?',
  startImagePrompt: 'misty gate',
  videoPrompt: 'slow push in',
  choices: [
    SceneProposalChoice(label: 'Enter', icon: 'door'),
    SceneProposalChoice(label: 'Climb'),
  ],
);

void main() {
  group('sliceProposalForStep', () {
    test('Info keeps title and line only', () {
      final sliced = sliceProposalForStep(_full, step: 0, isEnding: true)!;
      expect(sliced.title, 'Spark title');
      expect(sliced.ttsText, 'What should they do next?');
      expect(sliced.startImagePrompt, isNull);
      expect(sliced.videoPrompt, isNull);
      expect(sliced.choices, isEmpty);
    });

    test('Scenes keeps the start prompt only', () {
      final sliced = sliceProposalForStep(_full, step: 1, isEnding: false)!;
      expect(sliced.startImagePrompt, 'misty gate');
      expect(sliced.title, isNull);
      expect(sliced.ttsText, isNull);
      expect(sliced.videoPrompt, isNull);
      expect(sliced.choices, isEmpty);
    });

    test('Voice keeps the line only', () {
      final sliced = sliceProposalForStep(_full, step: 2, isEnding: false)!;
      expect(sliced.ttsText, 'What should they do next?');
      expect(sliced.title, isNull);
      expect(sliced.choices, isEmpty);
    });

    test('Clip keeps the video prompt only', () {
      final sliced = sliceProposalForStep(_full, step: 3, isEnding: false)!;
      expect(sliced.videoPrompt, 'slow push in');
      expect(sliced.ttsText, isNull);
      expect(sliced.choices, isEmpty);
    });

    test('Options keeps the choices only', () {
      final sliced = sliceProposalForStep(_full, step: 4, isEnding: false)!;
      expect(sliced.choices.map((c) => c.label).toList(), ['Enter', 'Climb']);
      expect(sliced.title, isNull);
      expect(sliced.ttsText, isNull);
      expect(sliced.videoPrompt, isNull);
    });

    test('endings take no options and empty sections slice to null', () {
      expect(sliceProposalForStep(_full, step: 4, isEnding: true), isNull);
      expect(
        sliceProposalForStep(const SceneProposal(), step: 0, isEnding: false),
        isNull,
      );
      expect(
        sliceProposalForStep(
          const SceneProposal(ttsText: 'Only a line'),
          step: 3,
          isEnding: false,
        ),
        isNull,
      );
    });
  });

  group('showFillPreview', () {
    Future<void> pumpOpener(
      WidgetTester tester,
      void Function(bool?) onResult,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  onResult(
                    await showFillPreview(
                      context: context,
                      step: 4,
                      proposal: sliceProposalForStep(
                        _full,
                        step: 4,
                        isEnding: false,
                      )!,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('lists the section values with Accept and Discard', (
      tester,
    ) async {
      bool? result;
      await pumpOpener(tester, (value) => result = value);

      expect(find.text('Proposed options'), findsOneWidget);
      expect(find.text('Option A'), findsOneWidget);
      expect(find.text('Enter · door'), findsOneWidget);
      expect(find.text('Option B'), findsOneWidget);
      expect(find.text('Climb'), findsOneWidget);
      expect(find.text('misty gate'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('fill-accept')));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(find.text('Proposed options'), findsNothing);
    });

    testWidgets('Discard closes without accepting', (tester) async {
      var called = false;
      bool? result;
      await pumpOpener(tester, (value) {
        called = true;
        result = value;
      });

      await tester.tap(find.byKey(const ValueKey('fill-discard')));
      await tester.pumpAndSettle();

      expect(called, isTrue);
      expect(result, isFalse);
      expect(find.text('Proposed options'), findsNothing);
    });
  });
}
