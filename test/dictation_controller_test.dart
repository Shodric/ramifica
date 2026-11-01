import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/features/create/dictation/dictation_controller.dart';
import 'package:ramifica/features/create/voice_recorder.dart';

void main() {
  test(
    'unavailable realtime socket falls back to one complete WAV take',
    () async {
      var transcriptions = 0;
      final finals = <String>[];
      final controller = DictationController(
        seedRecorder: FakeVoiceRecorder(bytes: [1, 2, 3]),
        socketFactory: () => throw UnsupportedError('No socket'),
        getIdToken: () async => 'token',
        transcribe: (bytes) async {
          expect(bytes, [1, 2, 3]);
          transcriptions++;
          return 'Una puerta bajo la lluvia';
        },
      )..onFinal = finals.add;
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.recording, isTrue);
      expect(controller.liveFailed, isTrue);
      await controller.stop(send: true);
      expect(transcriptions, 1);
      expect(finals, ['Una puerta bajo la lluvia']);
      expect(controller.busy, isFalse);
    },
  );

  test('disposing a pending transcription ignores its late response', () async {
    final entered = Completer<void>();
    final transcript = Completer<String>();
    final finals = <String>[];
    final controller = DictationController(
      seedRecorder: FakeVoiceRecorder(bytes: [1]),
      transcribe: (_) {
        entered.complete();
        return transcript.future;
      },
    )..onFinal = finals.add;
    await controller.start();
    final stopped = controller.stop(send: true);
    await entered.future;
    controller.dispose();
    transcript.complete('Too late');
    await stopped;
    expect(finals, isEmpty);
  });
}
