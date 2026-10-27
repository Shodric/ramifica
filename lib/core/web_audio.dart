import 'package:ramifica/core/narrator.dart';
import 'package:ramifica/core/web_audio_stub.dart'
    if (dart.library.js_interop) 'package:ramifica/core/web_audio_web.dart'
    as engine;

export 'package:ramifica/core/narrator.dart';

Narrator openNarrator() => engine.createNarrator();
