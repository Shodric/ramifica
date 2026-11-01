import 'package:ramifica/features/create/asr_socket.dart';

/// Non-web default: live dictation is unsupported, so constructing the
/// default transport throws and the controller records for WAV fallback.
AsrChannel createDefaultAsrChannel() =>
    throw UnsupportedError('Live dictation is only supported on web.');
