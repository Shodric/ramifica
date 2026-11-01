import 'dart:async';
import 'dart:convert';

import 'package:ramifica/features/create/dictation/asr_default.dart';

/// Realtime ASR relay socket: the client side of the relay protocol.
///
/// The relay answers the auth text frame with `{type:'ready'}` once Meta
/// acks, then translates Meta `transcript` frames into `{type:'partial',
/// text}` and `speechComplete` into `{type:'final', text}`; errors arrive
/// as `{type:'error', message}`. Binary frames carry PCM16 LE mono 24 kHz.
/// The client ends the take with `{type:'end'}` and both sides close 1000.
///
/// Web-only transport resolution lives in `dictation/asr_default.dart`
/// (conditional import): this file never touches browser APIs, so unit
/// tests can construct (and subclass) [AsrSocket] freely; only a real
/// connect throws off-web, which callers treat as a WAV fallback.

/// Relay URL. The default is the live `asr-relay` service. Override with
/// `flutter build web --dart-define=ASR_RELAY_URL=wss://<relay>.run.app`.
const asrRelayUrl = String.fromEnvironment(
  'ASR_RELAY_URL',
  defaultValue: 'wss://asr-relay-209293545230.us-central1.run.app',
);

/// Cloud Run serves the socket on `GET /asr`. A bare host in
/// [asrRelayUrl] still lands there.
String asrSocketUrl(String base) {
  final uri = Uri.parse(base);
  if (uri.path == '/asr' || uri.path.endsWith('/asr')) return uri.toString();
  final prefix = uri.path.endsWith('/')
      ? uri.path.substring(0, uri.path.length - 1)
      : uri.path;
  return uri.replace(path: '$prefix/asr').toString();
}

/// Builds the realtime socket. The premise sheet takes one so tests can
/// inject a fake; production passes `AsrSocket.new`.
typedef AsrSocketFactory = AsrSocket Function();

/// Auth token for the relay auth frame. Null means signed-out (or no
/// provider): the sheet skips the socket and records for WAV fallback.
typedef AuthTokenProvider = Future<String?> Function();

/// Bare transport under [AsrSocket]: raw text/binary frames plus open and
/// close. Tests implement this to drive the socket without a network.
abstract class AsrChannel {
  void open({
    required String url,
    required void Function() onOpen,
    required void Function(String text) onText,
    required void Function(String message) onError,
    required void Function() onDone,
  });

  void sendText(String text);

  void sendBinary(List<int> bytes);

  void close();
}

/// Default transport is platform-conditional ([asr_default.dart]): a browser
/// `WebSocket` on web, unsupported elsewhere (tests inject a fake channel
/// and the controller falls back to the WAV take).
///
/// One realtime dictation take over an [AsrChannel].
class AsrSocket {
  AsrSocket({AsrChannel? channel})
    : _channel = channel ?? createDefaultAsrChannel();

  static const connectTimeout = Duration(seconds: 15);
  static const finishTimeout = Duration(seconds: 8);

  AsrChannel? _channel;
  void Function(String text)? _onPartial;
  void Function(String text)? _onFinal;
  void Function(String message)? _onError;
  Completer<void>? _readyCompleter;
  Completer<String>? _finishCompleter;
  var _ready = false;
  var _closed = false;
  var _lastText = '';

  /// Opens [url], sends the auth frame, and resolves once the relay
  /// answers `ready`. Throws (after reporting through [onError]) when the
  /// socket errors or `ready` takes longer than [connectTimeout] — the
  /// caller falls back to the single-shot WAV take.
  Future<void> connect({
    required String url,
    String? idToken,
    String? appCheckToken,
    void Function(String text)? onPartial,
    void Function(String text)? onFinal,
    void Function(String message)? onError,
  }) async {
    final channel = _channel;
    if (channel == null || _ready || _readyCompleter != null) {
      throw StateError('AsrSocket is already connected or closed.');
    }
    _onPartial = onPartial;
    _onFinal = onFinal;
    _onError = onError;
    final ready = Completer<void>();
    _readyCompleter = ready;
    // No-op error sink: late completions (e.g. after the connect timeout
    // already fired) must never surface as unhandled async errors. The
    // await below still observes every outcome through its own listener.
    ready.future.then<void>((_) {}, onError: (_) {});
    try {
      channel.open(
        url: asrSocketUrl(url),
        onOpen: () {
          try {
            channel.sendText(
              jsonEncode({
                'type': 'auth',
                'idToken': idToken,
                'appCheckToken': appCheckToken,
              }),
            );
          } catch (_) {}
        },
        onText: _handleText,
        onError: _handleError,
        onDone: _handleDone,
      );
    } catch (_) {
      _readyCompleter = null;
      await close();
      rethrow;
    }
    try {
      await ready.future.timeout(connectTimeout);
    } catch (error) {
      _fail(
        error is TimeoutException
            ? 'Live dictation did not respond in time.'
            : error is StateError
            ? error.message
            : 'Could not connect to live dictation.',
      );
      await close();
      rethrow;
    }
    _ready = true;
  }

  /// Sends one raw PCM frame (int16 LE mono 24 kHz). Silently skipped
  /// unless the relay is live — the sheet pipes frames only while
  /// recording, and stray frames after a cut must never throw.
  void sendPcm(List<int> bytes) {
    if (_closed || !_ready) return;
    try {
      _channel?.sendBinary(bytes);
    } catch (_) {}
  }

  /// Ends the take: sends `{type:'end'}`, awaits the `final` (capped at
  /// [finishTimeout], falling back to the last accumulated text), then
  /// closes 1000. Late server events after close never fire callbacks.
  Future<String> finish() async {
    if (_closed) return _lastText;
    try {
      _channel?.sendText(jsonEncode({'type': 'end'}));
    } catch (_) {}
    final done = Completer<String>();
    _finishCompleter = done;
    String result;
    try {
      result = await done.future.timeout(finishTimeout);
    } on TimeoutException {
      result = _lastText;
    } finally {
      _finishCompleter = null;
    }
    await close();
    return result;
  }

  /// Closes the socket (code 1000) and silences every callback, including
  /// ones already in flight: after close, [_onPartial]/[_onFinal]/[_onError]
  /// never fire again.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _ready = false;
    final ready = _readyCompleter;
    _readyCompleter = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('AsrSocket closed.'));
    }
    final done = _finishCompleter;
    _finishCompleter = null;
    if (done != null && !done.isCompleted) done.complete(_lastText);
    _onPartial = null;
    _onFinal = null;
    _onError = null;
    try {
      _channel?.close();
    } catch (_) {}
    _channel = null;
  }

  void _handleText(String text) {
    if (_closed) return;
    final dynamic message;
    try {
      message = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (message is! Map) return;
    switch (message['type']) {
      case 'ready':
        final ready = _readyCompleter;
        _readyCompleter = null;
        if (ready != null && !ready.isCompleted) ready.complete();
      case 'partial':
        final partial = message['text'];
        if (partial is String) {
          _lastText = partial;
          _onPartial?.call(partial);
        }
      case 'final':
      // The relay sends `final`; also accept Meta's raw name in case a
      // frame ever arrives unwrapped.
      case 'speechComplete':
        final finalText = message['text'];
        if (finalText is String) {
          _lastText = finalText;
          _onFinal?.call(finalText);
          final done = _finishCompleter;
          _finishCompleter = null;
          if (done != null && !done.isCompleted) done.complete(finalText);
        }
      case 'error':
        final error = message['message'];
        _fail(error is String ? error : 'Live dictation failed.');
    }
  }

  void _handleError(String message) {
    if (_closed) return;
    if (_readyCompleter != null) {
      // Pre-ready: fail the pending connect; the caller reports.
      final ready = _readyCompleter;
      _readyCompleter = null;
      if (ready != null && !ready.isCompleted) {
        ready.completeError(StateError(message));
      }
      return;
    }
    if (_ready) _fail(message);
  }

  void _handleDone() {
    if (_closed) return;
    final wasReady = _ready;
    final finishing = _finishCompleter != null;
    _closed = true;
    _ready = false;
    final ready = _readyCompleter;
    _readyCompleter = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('ASR relay closed before ready.'));
    }
    final done = _finishCompleter;
    _finishCompleter = null;
    if (done != null && !done.isCompleted) done.complete(_lastText);
    _channel = null;
    // A close mid-take (not during finish, which tolerates it) drops to
    // the WAV fallback through the error callback.
    if (wasReady && !finishing) {
      final onError = _onError;
      _onPartial = null;
      _onFinal = null;
      _onError = null;
      onError?.call('The dictation connection closed.');
    }
  }

  void _fail(String message) {
    if (_closed) return;
    _ready = false;
    _onError?.call(message);
  }
}
