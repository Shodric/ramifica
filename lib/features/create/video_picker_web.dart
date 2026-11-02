import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/repositories/create_repository.dart';

Future<PickedVideoFile?> pickBrowserVideo() async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'video/mp4,video/quicktime,.mp4,.mov';
  input.style.display = 'none';
  web.document.body?.appendChild(input);
  final result = Completer<PickedVideoFile?>();
  Future<void> read() async {
    try {
      final file = input.files?.item(0);
      if (file == null) {
        result.complete(null);
        return;
      }
      final type = file.type.isNotEmpty
          ? file.type
          : file.name.toLowerCase().endsWith('.mov')
          ? 'video/quicktime'
          : 'video/mp4';
      final problem = validateVideoUpload(
        contentType: type,
        byteLength: file.size,
      );
      if (problem != null) throw AppFailure(.invalid, detail: problem);
      final buffer = await file.arrayBuffer().toDart;
      result.complete(
        PickedVideoFile(contentType: type, bytes: buffer.toDart.asUint8List()),
      );
    } catch (error, stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    }
  }

  final change = ((web.Event _) {
    unawaited(read());
  }).toJS;
  final cancel = ((web.Event _) {
    if (!result.isCompleted) result.complete(null);
  }).toJS;
  input.addEventListener('change', change);
  input.addEventListener('cancel', cancel);
  input.click();
  try {
    return await result.future;
  } finally {
    input.removeEventListener('change', change);
    input.removeEventListener('cancel', cancel);
    input.remove();
  }
}
