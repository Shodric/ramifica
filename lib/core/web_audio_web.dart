import 'dart:js_interop';

import 'package:ramifica/core/narrator.dart';
import 'package:web/web.dart';

/// Web Audio for the narrator line. One buffer per node, a new source per play.
Narrator createNarrator() => WebNarrator();

class WebNarrator implements Narrator {
  AudioContext? _context;
  AudioBuffer? _buffer;
  AudioBufferSourceNode? _source;
  Future<void>? _preparing;
  var _prepareToken = 0;
  var _playToken = 0;
  var _preparedUrl = '';

  AudioContext get _audio => _context ??= AudioContext();

  @override
  Future<void> prepare(String url) {
    if (url == _preparedUrl && (_buffer != null || _preparing != null)) {
      return _preparing ?? Future<void>.value();
    }
    _preparedUrl = url;
    _buffer = null;
    final token = ++_prepareToken;
    final loading = _load(url, token);
    _preparing = loading;
    return loading;
  }

  Future<void> _load(String url, int token) async {
    try {
      final response = await window.fetch(url.toJS).toDart;
      if (!response.ok || token != _prepareToken) return;
      final bytes = await response.arrayBuffer().toDart;
      if (token != _prepareToken) return;
      final buffer = await _audio.decodeAudioData(bytes).toDart;
      if (token != _prepareToken) return;
      _buffer = buffer;
    } catch (_) {
      if (token == _prepareToken) _buffer = null;
    } finally {
      if (token == _prepareToken) _preparing = null;
    }
  }

  @override
  void unlock() {
    _audio.resume().toDart.ignore();
  }

  @override
  Future<bool> play({required void Function() onEnded}) async {
    stop();
    final url = _preparedUrl;
    if (url.isEmpty) return false;
    final token = ++_playToken;
    await prepare(url);
    if (token != _playToken || _buffer == null) return false;
    final source = _audio.createBufferSource()
      ..buffer = _buffer
      ..onended = ((Event _) {
        if (token != _playToken) return;
        onEnded();
      }).toJS;
    source.connect(_audio.destination);
    source.start();
    _source = source;
    return true;
  }

  @override
  void stop() {
    _playToken += 1;
    final source = _source;
    _source = null;
    if (source == null) return;
    source.onended = null;
    try {
      source.stop();
    } catch (_) {
      // start() was never reached.
    }
    source.disconnect();
  }

  @override
  void dispose() {
    stop();
    _prepareToken += 1;
    _preparing = null;
    _buffer = null;
    _preparedUrl = '';
    _context?.close().toDart.ignore();
    _context = null;
  }
}
