/// Default realtime transport for [AsrSocket], split per platform.
///
/// Web uses a browser `WebSocket`; every other platform throws (live
/// dictation is web-first — tests inject a fake [AsrChannel] and the
/// controller falls back to the WAV take).
library;

export 'asr_default_stub.dart'
    if (dart.library.js_interop) 'asr_default_web.dart';
