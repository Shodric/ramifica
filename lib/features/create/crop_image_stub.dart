import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/features/create/crop_region.dart';

/// Non-web crop: unsupported, fail closed. Production runs on web, where
/// [cropImageToJpeg] decodes and crops on a canvas.
Future<List<int>> cropImageToJpeg({
  required List<int> bytes,
  required CropRegion region,
  int maxWidth = 1080,
  double quality = 0.9,
}) async {
  throw const AppFailure(.failed);
}
