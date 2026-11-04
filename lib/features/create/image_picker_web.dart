import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/repositories/create_repository.dart';

Future<PickedImageFile?> pickBrowserImage() async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/jpeg,image/png,image/webp,.jpg,.jpeg,.png,.webp';
  input.style.display = 'none';
  web.document.body?.appendChild(input);
  final result = Completer<PickedImageFile?>();
  Future<void> read() async {
    try {
      final file = input.files?.item(0);
      if (file == null) {
        result.complete(null);
        return;
      }
      var type = file.type;
      if (type.isEmpty) {
        final name = file.name.toLowerCase();
        type = name.endsWith('.png')
            ? 'image/png'
            : name.endsWith('.webp')
            ? 'image/webp'
            : 'image/jpeg';
      }
      final problem = validateReferenceUpload(
        contentType: type,
        byteLength: file.size,
      );
      if (problem != null) throw AppFailure(.invalid, detail: problem);
      final buffer = await file.arrayBuffer().toDart;
      // Decodability and pixel size in one step: an undecodable file
      // rejects here, before the cropper ever mounts.
      final bitmap = await web.window.createImageBitmap(file).toDart;
      final width = bitmap.width;
      final height = bitmap.height;
      bitmap.close();
      if (width <= 0 || height <= 0) {
        throw const AppFailure(.invalid);
      }
      result.complete(
        PickedImageFile(
          contentType: type,
          bytes: buffer.toDart.asUint8List(),
          width: width,
          height: height,
        ),
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
