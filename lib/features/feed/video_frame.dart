import 'dart:math' as math;
import 'dart:ui';

/// Maps 0..1 video-frame coordinates to screen pixels.
///
/// The regular feed uses a centered cover frame. The creator preview can
/// instead fit the video to the screen width while keeping its source aspect.
/// Zones and the portal must use the same mapping as the displayed video.
///
/// Radius is relative to the frame's shorter side, so rings stay circular.
class VideoFrame {
  const VideoFrame(this.screen) : _fitWidth = false, sourceSize = null;

  /// Fits the source video to the viewport width. Draft zones were placed
  /// on a 9:16 editor frame that cover-crops the source, so points are mapped
  /// through that centered crop before they are placed on the video.
  const VideoFrame.fitWidth(this.screen, {this.sourceSize}) : _fitWidth = true;

  /// Full screen size, from the feed LayoutBuilder.
  final Size screen;
  final bool _fitWidth;
  final Size? sourceSize;

  /// The fixed aspect of the creator's zone editor.
  static const aspectWidth = 9.0;
  static const aspectHeight = 16.0;

  double get _sourceAspect {
    final size = sourceSize;
    if (size == null ||
        size.isEmpty ||
        !size.width.isFinite ||
        !size.height.isFinite) {
      return aspectWidth / aspectHeight;
    }
    return size.width / size.height;
  }

  double get _scale =>
      math.max(screen.width / aspectWidth, screen.height / aspectHeight);

  /// Displayed video width.
  double get width => _fitWidth ? screen.width : aspectWidth * _scale;

  /// Displayed video height.
  double get height =>
      _fitWidth ? width / _sourceAspect : aspectHeight * _scale;

  /// Left edge of the centered video.
  double get left => (screen.width - width) / 2;

  /// Top edge of the centered video, including any letterboxing.
  double get top => (screen.height - height) / 2;

  double get _referenceWidth =>
      _fitWidth ? math.min(width, height * aspectWidth / aspectHeight) : width;

  double get _referenceHeight =>
      _fitWidth ? math.min(height, width * aspectHeight / aspectWidth) : height;

  /// A point in the editor's 9:16 frame, mapped to screen pixels.
  Offset point(double x, double y) => Offset(
    left + (width - _referenceWidth) / 2 + x * _referenceWidth,
    top + (height - _referenceHeight) / 2 + y * _referenceHeight,
  );

  /// A video radius (0..1 of the shorter side) in screen pixels.
  double radius(double value) =>
      value * math.min(_referenceWidth, _referenceHeight);
}
