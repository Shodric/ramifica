import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/features/create/asr_socket.dart';
import 'package:ramifica/features/create/voice_recorder.dart';

/// Shown in the direction field while the mic is open.
const listeningPlaceholder = 'Listening…';

/// Transcribes complete recording bytes to text. Wired to the
/// `transcribeVoice` callable; tests inject a fake. Null means
/// transcription is unwired — the transcript stays hand-editable.
typedef TranscribeAudio = Future<String> Function(List<int> bytes);

String dictationHintFor(Object error, String fallback) {
  if (error is AppFailure) return error.hint;
  return fallback;
}

/// Live-dictation controller shared by S0 (premise) and S1 (script).
///
/// Owns one mic take: the platform recorder, the realtime relay socket,
/// the 90s cap timer, and the single-shot WAV fallback on stop. Text
/// lives in the owner's field — this only reports it through [onBegin]
/// (take started), [onPartial] (interim captions, droppable while the
/// field is focused) and [onFinal] (final text, always wins).
///
/// Stale async work after [stop]/[dispose] (or a newer take) is ignored
/// through a generation counter; UI state ([recording], [sending],
/// [elapsed], [waves], [hint]) arrives through [ChangeNotifier] so the
/// mic bar rebuilds without touching the owner's field.
class DictationController extends ChangeNotifier {
  DictationController({
    this.seedRecorder,
    this.socketFactory,
    this.getIdToken,
    this.getAppCheckToken,
    this.transcribe,
  });

  /// Test seam. Null builds the platform recorder (web only) per take.
  final VoiceRecorder? seedRecorder;

  /// Builds the realtime socket. Null disables live dictation (legacy
  /// single-shot flow through [transcribe]).
  final AsrSocketFactory? socketFactory;

  /// Firebase ID token for the relay auth frame. Null provider (or a null
  /// token) means signed-out: no socket, record-only with WAV fallback.
  final AuthTokenProvider? getIdToken;

  /// App Check token for the relay auth frame. Null provider sends null.
  final AuthTokenProvider? getAppCheckToken;

  final TranscribeAudio? transcribe;

  /// Called synchronously when a take starts: the owner writes
  /// [listeningPlaceholder] (and clears any stale proposal state).
  VoidCallback? onBegin;

  /// Interim live captions. The owner may ignore these while its field
  /// is focused — a tap into the field claims it.
  ValueChanged<String>? onPartial;

  /// Final text for the take. Always applies, even over a focused field.
  /// Called with `''` when the take is discarded or produced no text.
  ValueChanged<String>? onFinal;

  /// Called when a take holds no audio (and nothing live arrived): the
  /// owner clears the placeholder only if its field still shows it.
  /// Defaults to [onFinal] with `''` when unset.
  VoidCallback? onEmptyTake;

  /// Called when the 90s cap stops the take, so the owner can notice.
  VoidCallback? onCap;

  VoiceRecorder? _recorder;
  StreamSubscription<double>? _levels;
  StreamSubscription<List<int>>? _pcm;
  AsrSocket? _socket;
  final _waves = <double>[];
  Timer? _clock;
  Timer? _cap;
  var _recording = false;
  var _stopping = false;
  var _sending = false;
  var _elapsed = Duration.zero;
  var _live = false;
  var _liveFailed = false;
  String? _hint;

  /// PCM that arrived before the relay answered `ready`. `pcmFrames` is a
  /// broadcast stream, and connect can take the whole 15s timeout, so the
  /// controller listens at mic start and holds frames until the socket is
  /// live.
  final _pcmBuffer = <List<int>>[];
  var _pcmHold = false;
  var _pcmLive = false;

  /// Generation counter: [stop]/[start]/[dispose] invalidate in-flight
  /// continuations so late socket/transcribe events never touch a newer
  /// take or a dead owner.
  var _gen = 0;
  var _disposed = false;

  bool get recording => _recording;
  bool get sending => _sending;

  /// True while the mic is open or the take is being transcribed.
  bool get busy => _recording || _sending;
  Duration get elapsed => _elapsed;
  List<double> get waves => List<double>.unmodifiable(_waves);
  String? get hint => _hint;
  bool get liveFailed => _liveFailed;

  void _releasePcmHold() {
    _pcmHold = false;
    _pcmLive = false;
    _pcmBuffer.clear();
  }

  void _onPcm(List<int> frame) {
    if (_pcmLive) {
      _socket?.sendPcm(frame);
      return;
    }
    if (_pcmHold) _pcmBuffer.add(List<int>.from(frame));
  }

  Future<void> toggle() {
    if (_recording) return stop(send: true);
    return start();
  }

  Future<void> start() async {
    if (_recording || _sending || _disposed) return;
    final gen = ++_gen;
    _recording = true;
    _stopping = false;
    _live = false;
    _liveFailed = false;
    _hint = null;
    _waves.clear();
    _elapsed = Duration.zero;
    onBegin?.call();
    notifyListeners();
    final recorder = seedRecorder ?? createVoiceRecorder();
    _recorder = recorder;
    try {
      await recorder.start();
    } catch (_) {
      if (_disposed || gen != _gen) return;
      _recording = false;
      onFinal?.call('');
      _hint = 'Microphone is unavailable.';
      notifyListeners();
      return;
    }
    if (_disposed || gen != _gen) {
      recorder.dispose();
      return;
    }
    // Before the next await. Canned frames and the first speech both
    // arrive on a later microtask; listening after connect drops them.
    if (socketFactory != null) {
      _pcmHold = true;
      _pcmLive = false;
      _pcmBuffer.clear();
      _pcm = recorder.pcmFrames.listen(_onPcm, onError: (_) {});
    }
    _levels = recorder.levels.listen((level) {
      if (_disposed || gen != _gen) return;
      _waves.add(level);
      if (_waves.length > 40) _waves.removeAt(0);
      notifyListeners();
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed || gen != _gen) return;
      _elapsed += const Duration(seconds: 1);
      notifyListeners();
    });
    // Sessions cap at 90s; the cap stops and sends with a notice.
    _cap = Timer(const Duration(seconds: 90), () async {
      if (_disposed || gen != _gen || !_recording) return;
      onCap?.call();
      await stop(send: true);
    });
    await _connectLive(gen);
  }

  /// Opens the realtime relay. PCM is already buffered by [_onPcm].
  /// Any failure (or a missing/signed-out token) leaves the take recording
  /// for the single-shot WAV fallback on stop.
  Future<void> _connectLive(int gen) async {
    bool stale() => _disposed || gen != _gen;
    final factory = socketFactory;
    if (factory == null || stale() || !_recording || _stopping) {
      _releasePcmHold();
      return;
    }
    final idToken = await getIdToken?.call();
    if (stale() || !_recording || _stopping) {
      _releasePcmHold();
      return;
    }
    if (idToken == null) {
      // No user: no socket. The take still records for WAV fallback.
      _releasePcmHold();
      if (stale()) return;
      _hint = 'Sign in to dictate live.';
      notifyListeners();
      return;
    }
    final appCheckToken = await getAppCheckToken?.call();
    if (stale() || !_recording || _stopping) {
      _releasePcmHold();
      return;
    }
    late final AsrSocket socket;
    try {
      socket = factory();
    } catch (error) {
      _releasePcmHold();
      if (stale()) return;
      _liveFailed = true;
      _hint = dictationHintFor(
        error,
        'Live dictation is unavailable. The full take will be transcribed when you stop.',
      );
      notifyListeners();
      return;
    }
    _socket = socket;
    try {
      await socket.connect(
        url: asrRelayUrl,
        idToken: idToken,
        appCheckToken: appCheckToken,
        onPartial: (text) {
          if (_disposed || gen != _gen || !_recording) return;
          onPartial?.call(text);
        },
        onFinal: (text) {
          if (_disposed || gen != _gen) return;
          // Finals always win, even over a focused field.
          onFinal?.call(text);
        },
        onError: (message) {
          if (_disposed || gen != _gen || !_recording) return;
          // Mid-take relay cut: close Meta's session, keep recording,
          // WAV on stop.
          final current = _socket;
          _socket = null;
          _releasePcmHold();
          unawaited(current?.close());
          _live = false;
          _liveFailed = true;
          notifyListeners();
        },
      );
    } catch (error) {
      // Relay unreachable: stay recording, single WAV fallback on stop.
      if (identical(_socket, socket)) _socket = null;
      _releasePcmHold();
      if (stale() || _stopping) return;
      _liveFailed = true;
      _hint = dictationHintFor(
        error,
        'Live dictation is unavailable. The full take will be '
        'transcribed when you stop.',
      );
      notifyListeners();
      return;
    }
    if (stale() || !_recording || _stopping || !identical(_socket, socket)) {
      _releasePcmHold();
      try {
        await socket.close();
      } catch (_) {}
      if (identical(_socket, socket)) _socket = null;
      return;
    }
    // No await between the clear and the live flag: this runs straight
    // through, so a frame cannot land in both the buffer and the socket.
    final buffered = List<List<int>>.of(_pcmBuffer);
    _pcmBuffer.clear();
    _pcmHold = false;
    _pcmLive = true;
    for (final frame in buffered) {
      socket.sendPcm(frame);
    }
    if (stale()) return;
    _live = true;
    notifyListeners();
  }

  Future<void> stop({required bool send}) async {
    // Reentrancy guard: the second tap (or the 90s cap, or backgrounding)
    // landing mid-finish must not start tearing down twice.
    if (_stopping) return;
    _stopping = true;
    final gen = _gen;
    bool stale() => _disposed || gen != _gen;
    final recorder = _recorder;
    _recorder = null;
    final socket = _socket;
    final live = _live && socket != null;
    if (live && send) {
      // Before any await. The tail is a [pcmFrames] event, and the
      // listener is dropped as soon as this method yields.
      try {
        recorder?.sendEnd();
      } catch (_) {}
    }
    _releasePcmHold();
    await _levels?.cancel();
    _levels = null;
    await _pcm?.cancel();
    _pcm = null;
    _clock?.cancel();
    _clock = null;
    _cap?.cancel();
    _cap = null;
    _socket = null;
    _live = false;
    String? liveText;
    if (socket != null && live) {
      if (send) {
        try {
          liveText = await socket.finish();
        } catch (_) {
          liveText = null;
        }
      } else {
        try {
          await socket.close();
        } catch (_) {}
      }
    } else if (socket != null) {
      // Connect still in flight, or the relay already cut the take.
      try {
        await socket.close();
      } catch (_) {}
      if (send) _liveFailed = true;
    }
    List<int> bytes = const <int>[];
    if (recorder != null) {
      try {
        bytes = await recorder.stop();
      } catch (_) {
        bytes = const <int>[];
      }
      recorder.dispose();
    }
    if (stale()) return;
    _recording = false;
    _elapsed = Duration.zero;
    _sending =
        send && (liveText != null || (bytes.isNotEmpty && transcribe != null));
    notifyListeners();
    if (!send) {
      onFinal?.call('');
      return;
    }
    if (liveText != null) {
      // Realtime take: the relay final replaces the interim captions.
      if (stale()) return;
      final text = liveText.trim();
      onFinal?.call(text);
      _sending = false;
      notifyListeners();
      return;
    }
    if (bytes.isEmpty || transcribe == null) {
      // No audio (or no transcription wired): the field stays
      // hand-editable instead of holding the listening placeholder.
      if (stale()) return;
      _sending = false;
      notifyListeners();
      if (onEmptyTake != null) {
        onEmptyTake!.call();
      } else {
        onFinal?.call('');
      }
      return;
    }
    try {
      // Single WAV fallback: the socket never connected (or cut
      // mid-take), so the complete take goes through `transcribeVoice`
      // with `format: 'wav'` and its text replaces the field.
      final text = await transcribe!(bytes);
      if (stale()) return;
      onFinal?.call(text.trim());
      if (_liveFailed) {
        _hint = 'Live dictation is unavailable. The full take was transcribed.';
        notifyListeners();
      }
    } catch (error) {
      if (stale()) return;
      onFinal?.call('');
      _hint = dictationHintFor(error, 'Could not transcribe. Try again.');
      notifyListeners();
    } finally {
      if (!stale()) {
        _sending = false;
        notifyListeners();
      }
    }
  }

  /// Discard the take and invalidate callbacks before changing scenes.
  void cancel() {
    _gen++;
    _levels?.cancel();
    _levels = null;
    _pcm?.cancel();
    _pcm = null;
    _clock?.cancel();
    _cap?.cancel();
    _recorder?.dispose();
    _recorder = null;
    final socket = _socket;
    _socket = null;
    unawaited(socket?.close());
    _releasePcmHold();
    _recording = false;
    _sending = false;
    _stopping = false;
    _live = false;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
