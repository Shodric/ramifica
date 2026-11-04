import 'dart:math' as math;
import 'dart:ui';

/// Maps 0..1 video-frame coordinates to screen pixels.
///
/// Phones use a centered cover frame. Wide screens letterbox the whole
/// clip ([VideoFrame.contain]). The creator preview fits the video to the
/// screen width. Zones and the portal must use the same mapping as the
/// displayed video.
///
/// Radius is relative to the frame's shorter side, so rings stay circular.
enum _FrameFit { cover, width, contain }

class VideoFrame {
  const VideoFrame(this.screen) : _fit = .cover, sourceSize = null;

  /// Fits the source video to the viewport width. Draft zones were placed
  /// on a 9:16 editor frame that cover-crops the source, so points are mapped
  /// through that centered crop before they are placed on the video.
  const VideoFrame.fitWidth(this.screen, {this.sourceSize}) : _fit = .width;

  /// Letterboxes the clip so the whole picture stays on screen. A decoded
  /// [sourceSize] keeps zone points on the centered 9:16 editor crop.
  const VideoFrame.contain(this.screen, {this.sourceSize}) : _fit = .contain;

  /// Wide screens stage the clip. Phones (width <= 600) keep the cover frame.
  static bool useStage(Size screen) => screen.width > 600;

  /// Full screen size, from the feed LayoutBuilder.
  final Size screen;
  final _FrameFit _fit;
  final Size? sourceSize;

  /// The fixed aspect of the creator's zone editor.
  static const aspectWidth = 9.0;
  static const aspectHeight = 16.0;

  bool get _hasSource {
    final size = sourceSize;
    return size != null &&
        !size.isEmpty &&
        size.width.isFinite &&
        size.height.isFinite;
  }

  double get _sourceAspect {
    if (!_hasSource) return aspectWidth / aspectHeight;
    return sourceSize!.width / sourceSize!.height;
  }

  double get _coverScale =>
      math.max(screen.width / aspectWidth, screen.height / aspectHeight);

  /// Source aspect when it decoded, otherwise the 9:16 editor frame.
  Size get _contained {
    final aspect = _hasSource ? _sourceAspect : aspectWidth / aspectHeight;
    final fullHeight = screen.width / aspect;
    if (fullHeight <= screen.height) {
      return Size(screen.width, fullHeight);
    }
    return Size(screen.height * aspect, screen.height);
  }

  /// Displayed video width.
  double get width => switch (_fit) {
    .width => screen.width,
    .cover => aspectWidth * _coverScale,
    .contain => _contained.width,
  };

  /// Displayed video height.
  double get height => switch (_fit) {
    .width => screen.width / _sourceAspect,
    .cover => aspectHeight * _coverScale,
    .contain => _contained.height,
  };

  /// Left edge of the centered video.
  double get left => (screen.width - width) / 2;

  /// Top edge of the centered video, including any letterboxing.
  double get top => (screen.height - height) / 2;

  /// Fit-width and a decoded contain picture are wider or taller than the
  /// 9:16 editor. Points land on that centered crop, not the raw pixels.
  bool get _editorCrop => _fit == .width || (_fit == .contain && _hasSource);

  double get _referenceWidth => _editorCrop
      ? math.min(width, height * aspectWidth / aspectHeight)
      : width;

  double get _referenceHeight => _editorCrop
      ? math.min(height, width * aspectHeight / aspectWidth)
      : height;

  /// A point in the editor's 9:16 frame, mapped to screen pixels.
  Offset point(double x, double y) => Offset(
    left + (width - _referenceWidth) / 2 + x * _referenceWidth,
    top + (height - _referenceHeight) / 2 + y * _referenceHeight,
  );

  /// A video radius (0..1 of the shorter side) in screen pixels.
  double radius(double value) =>
      value * math.min(_referenceWidth, _referenceHeight);
}
