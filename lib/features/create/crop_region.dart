import 'package:ramifica/data/models/app_failure.dart';

/// Pixel region of a source image to keep, in source pixels. The
/// interactive cropper produces this; [cropImageToJpeg] consumes it.
class CropRegion {
  const CropRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  /// True when the region is a non-empty box fully inside a
  /// [sourceWidth]×[sourceHeight] image.
  bool fits(int sourceWidth, int sourceHeight) =>
      width > 0 &&
      height > 0 &&
      x >= 0 &&
      y >= 0 &&
      x + width <= sourceWidth &&
      y + height <= sourceHeight;

  @override
  bool operator ==(Object other) =>
      other is CropRegion &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'CropRegion($x, $y, $width, $height)';
}

/// Throws [AppFailure.invalid] unless [region] fits the source size.
void checkCropRegion(CropRegion region, int sourceWidth, int sourceHeight) {
  if (!region.fits(sourceWidth, sourceHeight)) {
    throw const AppFailure(.invalid);
  }
}
