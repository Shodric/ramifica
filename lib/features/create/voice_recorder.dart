/// Mic capture seam for the premise voice FAB (Step 0).
///
/// Web-first: this app records through `package:web` (`getUserMedia` plus
/// an audio tap for PCM frames and an `AnalyserNode` for live levels) on
/// web and reports unsupported elsewhere. Tests inject a fake
/// [VoiceRecorder] into [PremiseSheet]; the stub below is never
/// constructed in tests.
library;

import 'dart:async';

export 'voice_recorder_stub.dart'
    if (dart.library.js_interop) 'voice_recorder_web.dart';

/// One mic recording session: live levels for the FAB waves, a stream of
/// raw PCM frames for the realtime relay, plus the complete audio bytes
/// on stop for the single-shot WAV fallback.
abstract class VoiceRecorder {
  /// Live mic level 0..1 while recording (broadcast).
  Stream<double> get levels;

  /// Raw mic audio: signed 16-bit little-endian PCM, mono, 24 kHz
  /// (broadcast). Each event is ~80 ms (1920 samples / 3840 bytes); the
  /// event flushed by [sendEnd] may be shorter. The premise sheet pipes
  /// these frames into the realtime ASR relay socket.
  Stream<List<int>> get pcmFrames;

  /// True between [start] and [stop].
  bool get isRecording;

  /// Requests the mic and starts capturing. Throws when the mic is
  /// denied or unsupported — the sheet renders the message as a hint.
  Future<void> start();

  /// Flushes buffered-but-unsent samples as a final (possibly short)
  /// [pcmFrames] event. No-op when idle or fully flushed.
  void sendEnd();

  /// Stops capture and returns the complete take as WAV bytes (44-byte
  /// RIFF PCM mono 24 kHz header + the accumulated samples) for the
  /// single-shot `transcribeVoice(format: 'wav')` fallback.
  Future<List<int>> stop();

  void dispose();
}

/// Test seam: synchronous fake levels, canned PCM frames on [start], and
/// canned WAV bytes on [stop].
class FakeVoiceRecorder implements VoiceRecorder {
  FakeVoiceRecorder({
    this.bytes = const <int>[],
    List<List<int>>? frames,
    this.tail,
  }) : frames = frames ?? const <List<int>>[];

  final List<int> bytes;

  /// PCM frames emitted on [start], in order (plus anything pushed
  /// through [emitPcm] while recording).
  final List<List<int>> frames;

  /// Frame emitted by [sendEnd], when set. The sheet must still be
  /// listening: cancelling the PCM subscription first drops it.
  final List<int>? tail;

  final _levels = StreamController<double>.broadcast();

  /// Sync so [sendEnd]'s frame reaches the listener before [sendEnd]
  /// returns. An async controller would deliver it after the sheet has
  /// already dropped the live flag.
  final _pcm = StreamController<List<int>>.broadcast(sync: true);
  var _recording = false;

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Stream<List<int>> get pcmFrames => _pcm.stream;

  @override
  bool get isRecording => _recording;

  /// Pushes a live level into [levels] (no-op while idle).
  void emit(double level) {
    if (_recording) _levels.add(level.clamp(0, 1).toDouble());
  }

  /// Pushes one raw PCM frame into [pcmFrames] (no-op while idle).
  void emitPcm(List<int> frame) {
    if (_recording && !_pcm.isClosed) _pcm.add(frame);
  }

  @override
  Future<void> start() async {
    _recording = true;
    if (frames.isEmpty) return;
    // Yield so `await start()` returns and the caller can listen, then
    // emit. A microtask queued before that yield runs first and the
    // frames never reach the listener.
    await Future<void>.value();
    scheduleMicrotask(() {
      for (final frame in frames) {
        emitPcm(frame);
      }
    });
  }

  @override
  void sendEnd() {
    final pending = tail;
    if (pending == null) return;
    emitPcm(pending);
  }

  @override
  Future<List<int>> stop() async {
    _recording = false;
    return bytes;
  }

  @override
  void dispose() {
    _levels.close();
    _pcm.close();
  }
}
