import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/features/create/crop_region.dart';

/// Crops [bytes] to [region] (source pixels) on a canvas and encodes the
/// result as JPEG, downscaling so the width never exceeds [maxWidth]
/// (9:16 keeps the height proportional). Fully client-side: decode,
/// crop, and encode all run in the browser.
///
/// Empty bytes, an undecodable image, or a region outside the decoded
/// size throw [AppFailure.invalid] before any canvas work the result
/// could poison.
Future<List<int>> cropImageToJpeg({
  required List<int> bytes,
  required CropRegion region,
  int maxWidth = 1080,
  double quality = 0.9,
}) async {
  if (bytes.isEmpty || maxWidth <= 0) throw const AppFailure(.invalid);
  final blob = web.Blob(
    [Uint8List.fromList(bytes).toJS].toJS,
    web.BlobPropertyBag(type: 'image/jpeg'),
  );
  final bitmap = await web.window.createImageBitmap(blob).toDart;
  try {
    checkCropRegion(region, bitmap.width, bitmap.height);
    final targetWidth = region.width < maxWidth ? region.width : maxWidth;
    final targetHeight = (targetWidth * region.height / region.width).round();
    if (targetWidth <= 0 || targetHeight <= 0) {
      throw const AppFailure(.invalid);
    }
    final canvas = web.HTMLCanvasElement()
      ..width = targetWidth
      ..height = targetHeight;
    final context = canvas.getContext('2d');
    if (context == null) {
      throw const AppFailure(.failed);
    }
    // A fresh canvas always answers '2d' with a 2D context; the cast
    // trusts the browser instead of an `is` check js_interop forbids.
    final ctx = context as web.CanvasRenderingContext2D;
    // JPEG has no alpha: transparent sources land on white, not black.
    ctx.fillStyle = 'white'.toJS;
    ctx.fillRect(0, 0, targetWidth, targetHeight);
    ctx.drawImage(
      bitmap,
      region.x,
      region.y,
      region.width,
      region.height,
      0,
      0,
      targetWidth,
      targetHeight,
    );
    final done = Completer<web.Blob?>();
    canvas.toBlob(
      ((web.Blob? out) {
        done.complete(out);
      }).toJS,
      'image/jpeg',
      quality.clamp(0, 1).toJS,
    );
    final out = await done.future;
    if (out == null) throw const AppFailure(.failed);
    return (await out.arrayBuffer().toDart).toDart.asUint8List();
  } finally {
    bitmap.close();
  }
}
