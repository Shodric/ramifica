import 'package:ramifica/features/create/voice_recorder.dart';

/// Non-web mic capture is unsupported: `audio_waveforms` has no web
/// build and this app is web-first, so recording lives in
/// `voice_recorder_web.dart` and every other platform reports here.
VoiceRecorder createVoiceRecorder() =>
    throw UnsupportedError('Voice recording is only supported on web.');
