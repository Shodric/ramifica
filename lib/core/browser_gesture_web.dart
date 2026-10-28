import 'dart:js_interop';

import 'package:web/web.dart' as web;

extension type _GestureFlag(JSObject _) implements JSObject {
  @JS('__ramificaGestured')
  external JSAny? get gestured;
}

/// Reads the capture-phase `pointerdown` flag set by `web/index.html`.
bool get hadPriorGesture {
  try {
    final flag = (_GestureFlag(web.window as JSObject)).gestured;
    return (flag as JSBoolean?)?.toDart ?? false;
  } catch (_) {
    return false;
  }
}
