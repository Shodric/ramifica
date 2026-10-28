import 'package:ramifica/core/browser_gesture_stub.dart'
    if (dart.library.js_interop) 'package:ramifica/core/browser_gesture_web.dart'
    as engine;

/// True when a pointerdown already reached this document. A login or link
/// tap counts, so the first clip after login can start with sound.
/// Always false outside the browser, where there is no document.
bool get hadPriorGesture => engine.hadPriorGesture;
