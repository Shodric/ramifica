import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/features/create/asr_socket.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/premise_sheet.dart';
import 'package:ramifica/features/create/voice_recorder.dart';

/// Relay stand-in. `ready` stays pending until the test says so, so PCM
/// that the recorder emits during connect has to be buffered.
class ScriptedChannel implements AsrChannel {
  void Function(String text)? _onText;
  final binary = <List<int>>[];
  var closed = false;
  var _pendingReady = false;

  @override
  void open({
    required String url,
    required void Function() onOpen,
    required void Function(String text) onText,
    required void Function(String message) onError,
    required void Function() onDone,
  }) {
    _onText = onText;
    onOpen();
    if (_pendingReady) {
      _pendingReady = false;
      onText('{"type":"ready"}');
    }
  }

  void ready() {
    final onText = _onText;
    if (onText == null) {
      _pendingReady = true;
      return;
    }
    onText('{"type":"ready"}');
  }

  void fail(String message) =>
      _onText?.call('{"type":"error","message":"$message"}');

  @override
  void sendText(String text) {
    if (!text.contains('"type":"end"')) return;
    // After [AsrSocket.finish] has stored its completer. A sync final
    // would arrive too early and the socket would wait out its timeout.
    scheduleMicrotask(() {
      _onText?.call('{"type":"final","text":"listo"}');
    });
  }

  @override
  void sendBinary(List<int> bytes) => binary.add(bytes);

  @override
  void close() => closed = true;
}

Future<void> _pump(
  WidgetTester tester, {
  required FakeVoiceRecorder recorder,
  required ScriptedChannel channel,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PremiseSheet(
          recorder: recorder,
          socketFactory: () => AsrSocket(channel: channel),
          getIdToken: () async => 'token',
        ),
      ),
    ),
  );
}

const _fab = ValueKey('premise-voice-fab');

Future<void> _stop(WidgetTester tester) async {
  await tester.tap(find.byKey(_fab));
  await tester.pump();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets('flushes PCM buffered while the relay connects', (tester) async {
    final channel = ScriptedChannel();
    await _pump(
      tester,
      recorder: FakeVoiceRecorder(
        frames: const [
          [1, 2],
          [3],
        ],
      ),
      channel: channel,
    );
    await tester.tap(find.byKey(_fab));
    await tester.pump();
    expect(channel.binary, isEmpty);

    channel.ready();
    await tester.pump();

    expect(channel.binary, [
      [1, 2],
      [3],
    ]);
    await _stop(tester);
  });

  testWidgets('sends the tail frame before dropping the PCM listener', (
    tester,
  ) async {
    final channel = ScriptedChannel();
    await _pump(
      tester,
      recorder: FakeVoiceRecorder(tail: const [9]),
      channel: channel,
    );
    await tester.tap(find.byKey(_fab));
    await tester.pump();
    channel.ready();
    await tester.pump();

    await tester.tap(find.byKey(_fab));
    expect(channel.binary, [
      [9],
    ]);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('closes the socket when the relay errors mid-take', (
    tester,
  ) async {
    final channel = ScriptedChannel();
    await _pump(tester, recorder: FakeVoiceRecorder(), channel: channel);
    await tester.tap(find.byKey(_fab));
    await tester.pump();
    channel.ready();
    await tester.pump();
    expect(channel.closed, isFalse);

    channel.fail('cut');
    await tester.pump();

    expect(channel.closed, isTrue);
    await _stop(tester);
  });

  testWidgets('one idea field fills the height under the title', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PremiseSheet(embedded: true))),
    );
    expect(find.byKey(const ValueKey('premise-synopsis')), findsNothing);
    expect(find.text('Narration'), findsNothing);
    final title = tester.getRect(find.byKey(const ValueKey('premise-title')));
    final idea = tester.getRect(
      find.byKey(const ValueKey('premise-transcript')),
    );
    expect(idea.top, greaterThan(title.bottom));
    expect(idea.height, greaterThan(400));
    final mic = tester.getSize(find.byKey(const ValueKey('premise-voice-fab')));
    expect(mic.width, tester.getSize(find.byType(PremiseSheet)).width);
    expect(mic.height, 56);
  });

  testWidgets('proposeIdea normalizes without writing, applyProposal fills', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? draftedTitle;
    String? draftedIdea;
    List<OutlineOption>? draftedOptions;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PremiseSheet(
            embedded: true,
            initialTitle: 'Typed title',
            initialIdea: 'a door in the rain',
            propose: (_) async => (
              title: 'Rain door',
              synopsis: 'The door opens.',
              narratorLine: 'You stand before the rain door.',
              options: const <OutlineOption>[
                OutlineOption(label: 'Enter'),
                OutlineOption(label: '  '),
                OutlineOption(label: 'Climb'),
              ],
            ),
            onDraft: ({required title, required idea, required options}) {
              draftedTitle = title;
              draftedIdea = idea;
              draftedOptions = options;
            },
          ),
        ),
      ),
    );

    // No inline review UI: the AppBar spark drives the proposal.
    expect(find.text('Format'), findsNothing);
    expect(find.text('Order text style'), findsNothing);

    final state = tester.state<PremiseSheetState>(find.byType(PremiseSheet));
    expect(state.ideaReady, isTrue);
    final proposal = await state.proposeIdea();
    await tester.pump();

    // The fields are untouched until the preview is accepted...
    expect(proposal?.title, 'Rain door');
    expect(proposal?.idea, 'You stand before the rain door.');
    expect(proposal?.options.map((o) => o.label).toList(), [
      'Enter',
      'Climb',
    ]);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('premise-title')))
          .controller!
          .text,
      'Typed title',
    );

    state.applyProposal(proposal!);
    await tester.pump();

    // ...then the reviewed values land in the fields and publish.
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('premise-title')))
          .controller!
          .text,
      'Rain door',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('premise-transcript')))
          .controller!
          .text,
      'You stand before the rain door.',
    );
    expect(draftedTitle, 'Rain door');
    expect(draftedIdea, 'You stand before the rain door.');
    expect(draftedOptions?.map((o) => o.label).toList(), ['Enter', 'Climb']);
  });

  testWidgets('proposeIdea on an empty idea reports back for the snackbar', (
    tester,
  ) async {
    var called = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PremiseSheet(
            embedded: true,
            propose: (_) async {
              called = true;
              return (
                title: null,
                synopsis: null,
                narratorLine: null,
                options: const <OutlineOption>[],
              );
            },
          ),
        ),
      ),
    );

    final state = tester.state<PremiseSheetState>(find.byType(PremiseSheet));
    expect(state.ideaReady, isFalse);
    expect(await state.proposeIdea(), isNull);
    await tester.pump();
    expect(called, isFalse);
    expect(state.takeProposalError(), 'Describe your idea to format it.');
    expect(state.takeProposalError(), isNull);
  });
}
