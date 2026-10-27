import 'dart:math' as math;
import 'dart:ui';

/// Maps 0..1 video-frame coordinates to screen pixels.
///
/// Clips are always 9:16 and NodeVideo paints them cover-fit and centered,
/// so the frame rarely matches the screen. Zones and the portal must go
/// through this mapping, or they drift off the scene on tall screens.
///
/// Radius is relative to the frame's shorter side, so rings stay circular.
class VideoFrame {
  const VideoFrame(this.screen);

  /// Full screen size, from the feed LayoutBuilder.
  final Size screen;

  /// The clip aspect. processVideo re-encodes every clip to 480x854.
  static const aspectWidth = 9.0;
  static const aspectHeight = 16.0;

  double get _scale =>
      math.max(screen.width / aspectWidth, screen.height / aspectHeight);

  /// Displayed video width. Matches the screen, or overflows it.
  double get width => aspectWidth * _scale;

  /// Displayed video height. Matches the screen, or overflows it.
  double get height => aspectHeight * _scale;

  /// Left edge of the displayed video. Zero or negative (centered crop).
  double get left => (screen.width - width) / 2;

  /// Top edge of the displayed video. Zero or negative (centered crop).
  double get top => (screen.height - height) / 2;

  /// A video point (0..1 of the frame) in screen pixels.
  Offset point(double x, double y) =>
      Offset(left + x * width, top + y * height);

  /// A video radius (0..1 of the shorter side) in screen pixels.
  double radius(double value) => value * math.min(width, height);
}
