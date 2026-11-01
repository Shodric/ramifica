import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart';

import 'package:ramifica/features/create/asr_socket.dart';

/// Production transport over the browser `WebSocket`. Binary frames go out
/// as `ArrayBuffer`s; only text frames are reported (the relay protocol
/// is text-only server-side).
class WebAsrChannel implements AsrChannel {
  WebSocket? _ws;

  @override
  void open({
    required String url,
    required void Function() onOpen,
    required void Function(String text) onText,
    required void Function(String message) onError,
    required void Function() onDone,
  }) {
    final ws = WebSocket(url);
    _ws = ws;
    ws.binaryType = 'arraybuffer';
    var opened = false;
    ws.onopen = ((Event _) {
      opened = true;
      onOpen();
    }).toJS;
    ws.onerror = ((Event _) {
      if (!opened) onError('Could not connect to live dictation.');
    }).toJS;
    ws.onclose = ((Event _) {
      onDone();
    }).toJS;
    ws.onmessage = ((Event event) {
      final data = (event as MessageEvent).data;
      if (data != null && data.isA<JSString>()) {
        onText((data as JSString).toDart);
      }
    }).toJS;
  }

  @override
  void sendText(String text) {
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.OPEN) return;
    ws.send(text.toJS);
  }

  @override
  void sendBinary(List<int> bytes) {
    if (bytes.isEmpty) return;
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.OPEN) return;
    ws.send(Uint8List.fromList(bytes).toJS);
  }

  @override
  void close() {
    final ws = _ws;
    _ws = null;
    if (ws == null) return;
    try {
      if (ws.readyState == WebSocket.OPEN) ws.close(1000);
    } catch (_) {}
  }
}

AsrChannel createDefaultAsrChannel() => WebAsrChannel();
