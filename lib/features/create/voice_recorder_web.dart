import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:ramifica/features/create/voice_recorder.dart';
import 'package:web/web.dart';

/// Web mic capture: `getUserMedia` feeds an `AnalyserNode` time-domain
/// meter (FAB live waves, unchanged) plus a PCM tap that resamples the
/// mic to mono 24 kHz int16 and emits ~80 ms frames on [pcmFrames].
///
/// The tap is an `AudioWorklet` (processor code rides a blob module URL,
/// so no extra asset is needed); when the worklet fails to load, the same
/// seam falls back to a `ScriptProcessorNode` with an identical
/// nearest-neighbor decimation — the sheet never sees which tap runs. No
/// chunked container format is produced anywhere in this flow: no WebM
/// chunk ever enters the realtime socket. [stop] accumulates every sample
/// and returns the take as WAV bytes for the single-shot fallback.
VoiceRecorder createVoiceRecorder() => WebVoiceRecorder();

class WebVoiceRecorder implements VoiceRecorder {
  /// Relay PCM contract: mono 24 kHz int16, ~80 ms frames.
  static const pcmRate = 24000;
  static const frameSamples = 1920;
  static const frameBytes = frameSamples * 2;

  final _levels = StreamController<double>.broadcast();

  /// Sync so [sendEnd] delivers the tail frame before it returns.
  /// The sheet drops the live listener as soon as [sendEnd] returns.
  final _pcm = StreamController<List<int>>.broadcast(sync: true);
  MediaStream? _stream;
  AudioContext? _context;
  MediaStreamAudioSourceNode? _source;
  AnalyserNode? _analyser;
  AudioWorkletNode? _worklet;
  ScriptProcessorNode? _script;
  GainNode? _silence;
  String? _workletUrl;
  Timer? _meter;
  final _pending = <int>[];
  final _take = <int>[];
  double _resamplePhase = 0;
  var _recording = false;

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Stream<List<int>> get pcmFrames => _pcm.stream;

  @override
  bool get isRecording => _recording;

  @override
  Future<void> start() async {
    if (_recording) return;
    final stream = await window.navigator.mediaDevices
        .getUserMedia(
          MediaStreamConstraints(audio: true.toJS, video: false.toJS),
        )
        .toDart;
    _stream = stream;
    _pending.clear();
    _take.clear();
    _resamplePhase = 0;
    final context = AudioContext();
    _context = context;
    context.resume().toDart.ignore();
    final source = context.createMediaStreamSource(stream);
    _source = source;
    final analyser = context.createAnalyser();
    analyser.fftSize = 512;
    _analyser = analyser;
    source.connect(analyser);
    if (!await _startWorkletTap(context, source)) {
      _startScriptTap(context, source);
    }
    _recording = true;
    _meter = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _sample(),
    );
  }

  /// Primary tap: resampling lives in the worklet, the main thread only
  /// re-frames the posted int16 buffers. False when the blob module fails
  /// to load, so the caller falls back to the script processor.
  Future<bool> _startWorkletTap(
    AudioContext context,
    MediaStreamAudioSourceNode source,
  ) async {
    try {
      final blob = Blob(
        <JSAny>[_workletCode.toJS].toJS,
        BlobPropertyBag(type: 'application/javascript'),
      );
      final url = URL.createObjectURL(blob);
      await context.audioWorklet.addModule(url).toDart;
      final node = AudioWorkletNode(
        context,
        'pcm-capture',
        AudioWorkletNodeOptions(
          processorOptions:
              ({
                    'fromRate': context.sampleRate.toInt(),
                    'toRate': pcmRate,
                    'frame': frameSamples,
                  }.jsify()
                  as JSObject),
        ),
      );
      _worklet = node;
      node.port.onmessage = ((Event event) {
        final data = (event as MessageEvent).data;
        if (data != null && data.isA<JSArrayBuffer>()) {
          _emitPcm((data as JSArrayBuffer).toDart.asUint8List());
        }
      }).toJS;
      source.connect(node);
      // Silent pull: guarantees the worklet renders even though nobody
      // listens to its (empty) audio output.
      final silence = context.createGain();
      silence.gain.value = 0;
      _silence = silence;
      node.connect(silence);
      silence.connect(context.destination);
      return true;
    } catch (_) {
      _worklet = null;
      return false;
    }
  }

  /// Fallback tap: same mic, same decimation as the worklet, computed on
  /// the main thread. Deprecated upstream but universally available.
  void _startScriptTap(
    AudioContext context,
    MediaStreamAudioSourceNode source,
  ) {
    final fromRate = context.sampleRate.toInt();
    final proc = context.createScriptProcessor(4096, 1, 1);
    _script = proc;
    proc.onaudioprocess = ((Event event) {
      final input = (event as AudioProcessingEvent).inputBuffer;
      if (input.numberOfChannels < 1) return;
      _pushFloat(input.getChannelData(0).toDart, fromRate);
    }).toJS;
    // Script processors only fire while pulled by the destination; mute
    // the pull so nothing audible leaks out.
    final silence = context.createGain();
    silence.gain.value = 0;
    _silence = silence;
    source.connect(proc);
    proc.connect(silence);
    silence.connect(context.destination);
  }

  /// Nearest-neighbor decimation of one mono float chunk to 24 kHz int16
  /// LE — the same grid the worklet uses, so takes are identical either
  /// way. The fractional phase persists across chunks.
  void _pushFloat(List<double> channel, int fromRate) {
    final out = <int>[];
    final step = pcmRate / fromRate;
    for (var i = 0; i < channel.length; i++) {
      _resamplePhase += step;
      if (_resamplePhase < 1) continue;
      _resamplePhase -= 1;
      final s = channel[i].clamp(-1.0, 1.0);
      final v = s < 0 ? (s * 32768).round() : (s * 32767).round();
      out.add(v & 0xFF);
      out.add((v >> 8) & 0xFF);
    }
    _emitPcm(out);
  }

  /// Accumulates the take for [stop] and slices exact ~80 ms frames onto
  /// [pcmFrames]. Tap callbacks already deliver whole frames; re-framing
  /// keeps the script path (arbitrary chunk sizes) identical.
  void _emitPcm(List<int> bytes) {
    if (bytes.isEmpty) return;
    _take.addAll(bytes);
    _pending.addAll(bytes);
    while (_pending.length >= frameBytes) {
      final frame = _pending.sublist(0, frameBytes).toList();
      _pending.removeRange(0, frameBytes);
      if (!_pcm.isClosed) _pcm.add(frame);
    }
  }

  void _sample() {
    final analyser = _analyser;
    if (!_recording || analyser == null) return;
    final buffer = JSUint8Array.withLength(analyser.fftSize);
    analyser.getByteTimeDomainData(buffer);
    var peak = 0;
    for (final byte in buffer.toDart) {
      final deviation = (byte - 128).abs();
      if (deviation > peak) peak = deviation;
    }
    if (!_levels.isClosed) {
      _levels.add((peak / 128).clamp(0, 1).toDouble());
    }
  }

  @override
  void sendEnd() {
    if (!_recording || _pending.isEmpty || _pcm.isClosed) return;
    // Already counted in [_take]; just flush the short tail frame.
    final tail = _pending.toList();
    _pending.clear();
    _pcm.add(tail);
  }

  @override
  Future<List<int>> stop() async {
    if (!_recording && _take.isEmpty) return const <int>[];
    _recording = false;
    _meter?.cancel();
    _meter = null;
    try {
      _source?.disconnect();
    } catch (_) {}
    _source = null;
    _analyser = null;
    try {
      _worklet?.disconnect();
    } catch (_) {}
    _worklet = null;
    final script = _script;
    _script = null;
    if (script != null) {
      try {
        script.onaudioprocess = null;
      } catch (_) {}
      try {
        script.disconnect();
      } catch (_) {}
    }
    try {
      _silence?.disconnect();
    } catch (_) {}
    _silence = null;
    final context = _context;
    _context = null;
    if (context != null) context.close().toDart.ignore();
    final stream = _stream;
    _stream = null;
    if (stream != null) {
      for (final track in stream.getTracks().toDart) {
        track.stop();
      }
    }
    final workletUrl = _workletUrl;
    _workletUrl = null;
    if (workletUrl != null) {
      try {
        URL.revokeObjectURL(workletUrl);
      } catch (_) {}
    }
    final wav = _wavBytes(_take);
    _take.clear();
    _pending.clear();
    return wav;
  }

  @override
  void dispose() {
    _meter?.cancel();
    if (!_levels.isClosed) _levels.close();
    if (!_pcm.isClosed) _pcm.close();
  }

  /// 44-byte RIFF header (PCM, mono, 24 kHz, 16-bit) + the raw samples.
  /// Int16 samples are little-endian on every supported platform, matching
  /// the relay contract and the WAV container alike.
  static List<int> _wavBytes(List<int> pcm) {
    final header = ByteData(44)
      ..setUint32(0, 0x52494646, Endian.big) // 'RIFF'
      ..setUint32(4, 36 + pcm.length, Endian.little)
      ..setUint32(8, 0x57415645, Endian.big) // 'WAVE'
      ..setUint32(12, 0x666d7420, Endian.big) // 'fmt '
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little) // PCM
      ..setUint16(22, 1, Endian.little) // mono
      ..setUint32(24, pcmRate, Endian.little)
      ..setUint32(28, pcmRate * 2, Endian.little) // byte rate
      ..setUint16(32, 2, Endian.little) // block align
      ..setUint16(34, 16, Endian.little) // bits per sample
      ..setUint32(36, 0x64617461, Endian.big) // 'data'
      ..setUint32(40, pcm.length, Endian.little);
    return [...header.buffer.asUint8List(), ...pcm];
  }

  /// Worklet processor: nearest-neighbor decimation from the context rate
  /// to 24 kHz, int16 conversion, and ~80 ms posts to the main thread.
  /// Loaded from a blob URL so the app ships no extra worklet asset.
  static const _workletCode = r'''
class PcmCapture extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const o = (options && options.processorOptions) || {};
    this.fromRate = o.fromRate || 48000;
    this.toRate = o.toRate || 24000;
    this.frame = o.frame || 1920;
    this.phase = 0;
    this.buf = [];
  }
  process(inputs) {
    const channels = inputs && inputs[0];
    if (channels && channels.length > 0) {
      const input = channels[0];
      const step = this.toRate / this.fromRate;
      for (let i = 0; i < input.length; i++) {
        this.phase += step;
        if (this.phase < 1) continue;
        this.phase -= 1;
        let s = input[i];
        s = s < -1 ? -1 : s > 1 ? 1 : s;
        this.buf.push(s < 0 ? Math.round(s * 32768) : Math.round(s * 32767));
        if (this.buf.length >= this.frame) {
          const out = new Int16Array(this.buf);
          this.buf = [];
          this.port.postMessage(out.buffer);
        }
      }
    }
    return true;
  }
}
registerProcessor('pcm-capture', PcmCapture);
''';
}
