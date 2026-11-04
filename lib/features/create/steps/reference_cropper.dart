import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/features/create/crop_region.dart';

/// Fixed crop aspect: every reference still ships 9:16.
const referenceCropAspect = 9 / 16;

/// Smallest window the handle allows, in source pixels.
const minCropWindowWidthPx = 90.0;

/// Display scale that contain-fits [imageSize] into [viewport].
double cropFitScale(Size imageSize, Size viewport) {
  if (imageSize.width <= 0 ||
      imageSize.height <= 0 ||
      viewport.width <= 0 ||
      viewport.height <= 0) {
    return 1;
  }
  final scale =
      viewport.width / imageSize.width < viewport.height / imageSize.height
      ? viewport.width / imageSize.width
      : viewport.height / imageSize.height;
  return scale;
}

/// Centered display rect of the contain-fitted image.
Rect cropImageRect(Size imageSize, Size viewport) {
  final scale = cropFitScale(imageSize, viewport);
  final width = imageSize.width * scale;
  final height = imageSize.height * scale;
  return Rect.fromLTWH(
    (viewport.width - width) / 2,
    (viewport.height - height) / 2,
    width,
    height,
  );
}

/// Largest centered 9:16 window inside the source image, in source pixels.
Rect initialCropWindow(Size imageSize) {
  var width = imageSize.width;
  var height = width / referenceCropAspect;
  if (height > imageSize.height) {
    height = imageSize.height;
    width = height * referenceCropAspect;
  }
  return Rect.fromLTWH(
    (imageSize.width - width) / 2,
    (imageSize.height - height) / 2,
    width,
    height,
  );
}

/// Moves [window] by [deltaPx] (source pixels), clamped inside the image.
Rect moveCropWindow(Rect window, Offset deltaPx, Size imageSize) {
  final left = (window.left + deltaPx.dx).clamp(
    0,
    imageSize.width - window.width,
  );
  final top = (window.top + deltaPx.dy).clamp(
    0,
    imageSize.height - window.height,
  );
  return Rect.fromLTWH(
    left.toDouble(),
    top.toDouble(),
    window.width,
    window.height,
  );
}

/// Resizes [window] by [widthDeltaPx] (source pixels) from its bottom-right
/// corner, keeping 9:16 and staying inside the image. The top-left anchors
/// unless the grown box would overflow, in which case it slides back in.
Rect resizeCropWindow(
  Rect window,
  double widthDeltaPx,
  Size imageSize, {
  double minWidthPx = minCropWindowWidthPx,
}) {
  final maxWidth = imageSize.width < imageSize.height * referenceCropAspect
      ? imageSize.width
      : imageSize.height * referenceCropAspect;
  // Tiny sources hold a smaller box than the minimum: the floor follows
  // the image down instead of trapping clamp with min > max.
  final floor = minWidthPx < maxWidth ? minWidthPx : maxWidth;
  final width = (window.width + widthDeltaPx).clamp(floor, maxWidth);
  final height = width / referenceCropAspect;
  final left = window.left.clamp(0, imageSize.width - width);
  final top = window.top.clamp(0, imageSize.height - height);
  return Rect.fromLTWH(
    left.toDouble(),
    top.toDouble(),
    width.toDouble(),
    height.toDouble(),
  );
}

/// Centers the [window] size on [centerPx], clamped inside the image.
Rect centerCropWindow(Rect window, Offset centerPx, Size imageSize) {
  final left = (centerPx.dx - window.width / 2).clamp(
    0,
    imageSize.width - window.width,
  );
  final top = (centerPx.dy - window.height / 2).clamp(
    0,
    imageSize.height - window.height,
  );
  return Rect.fromLTWH(
    left.toDouble(),
    top.toDouble(),
    window.width,
    window.height,
  );
}

/// Snaps [window] to integer source pixels, clamped inside the image.
CropRegion finalizeCropWindow(Rect window, Size imageSize) {
  var x = window.left.round().clamp(0, imageSize.width - 1).toInt();
  var y = window.top.round().clamp(0, imageSize.height - 1).toInt();
  var width = window.width.round().clamp(1, imageSize.width - x).toInt();
  var height = window.height.round().clamp(1, imageSize.height - y).toInt();
  if (x + width > imageSize.width) {
    width = (imageSize.width - x).toInt();
  }
  if (y + height > imageSize.height) {
    height = (imageSize.height - y).toInt();
  }
  return CropRegion(x: x, y: y, width: width, height: height);
}

/// Interactive 9:16 framing dialog for a picked reference image. The
/// author drags the window to frame, pulls the corner handle to resize,
/// or taps outside to recenter. Returns the framed source-pixel region,
/// or null when cancelled.
Future<CropRegion?> showReferenceCropper({
  required BuildContext context,
  required ImageProvider image,
  required Size imageSize,
}) {
  return showDialog<CropRegion>(
    context: context,
    builder: (dialogContext) =>
        ReferenceCropDialog(image: image, imageSize: imageSize),
  );
}

class ReferenceCropDialog extends StatefulWidget {
  const ReferenceCropDialog({
    super.key,
    required this.image,
    required this.imageSize,
  });

  final ImageProvider image;
  final Size imageSize;

  @override
  State<ReferenceCropDialog> createState() => ReferenceCropDialogState();
}

class ReferenceCropDialogState extends State<ReferenceCropDialog> {
  late Rect _window = initialCropWindow(widget.imageSize);

  /// Current window in display coords, for the painter and hit-testing.
  Rect _displayWindow(Rect imageRect) {
    final scale = cropFitScale(widget.imageSize, imageRect.size);
    return Rect.fromLTWH(
      imageRect.left + _window.left * scale,
      imageRect.top + _window.top * scale,
      _window.width * scale,
      _window.height * scale,
    );
  }

  Offset _toPixels(Offset display, Rect imageRect) {
    final scale = cropFitScale(widget.imageSize, imageRect.size);
    return Offset(
      (display.dx - imageRect.left) / scale,
      (display.dy - imageRect.top) / scale,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: RamificaColors.surface,
      title: const Text('Frame your reference'),
      content: SizedBox(
        width: 300,
        height: 430,
        child: Column(
          crossAxisAlignment: .stretch,
          children: [
            Text(
              '9:16 · drag to frame, pull the corner to resize',
              style: RamificaText.meta,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewport = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  final imageRect = cropImageRect(widget.imageSize, viewport);
                  final windowRect = _displayWindow(imageRect);
                  final scale = cropFitScale(widget.imageSize, imageRect.size);
                  bool onHandle(Offset position) =>
                      (position - windowRect.bottomRight).distance <= 24;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      if (windowRect.contains(details.localPosition) ||
                          onHandle(details.localPosition)) {
                        return;
                      }
                      setState(() {
                        _window = centerCropWindow(
                          _window,
                          _toPixels(details.localPosition, imageRect),
                          widget.imageSize,
                        );
                      });
                    },
                    // Decided on down, not on pan start: the start
                    // position sits a slop past the finger, which would
                    // misclassify a handle grab as a move.
                    onPanDown: (details) {
                      _panResize = onHandle(details.localPosition);
                      _panMove =
                          !_panResize &&
                          windowRect.contains(details.localPosition);
                    },
                    onPanUpdate: (details) {
                      if (_panResize) {
                        setState(() {
                          _window = resizeCropWindow(
                            _window,
                            details.delta.dx / scale,
                            widget.imageSize,
                          );
                        });
                      } else if (_panMove) {
                        setState(() {
                          _window = moveCropWindow(
                            _window,
                            details.delta / scale,
                            widget.imageSize,
                          );
                        });
                      }
                    },
                    onPanEnd: (_) {
                      _panResize = false;
                      _panMove = false;
                    },
                    child: Container(
                      key: const ValueKey('reference-crop-area'),
                      color: Colors.black,
                      child: Stack(
                        children: [
                          Positioned.fromRect(
                            rect: imageRect,
                            child: Image(
                              image: widget.image,
                              fit: BoxFit.fill,
                              errorBuilder: (_, _, _) => const ColoredBox(
                                color: RamificaColors.inputFill,
                                child: Center(child: Text('Missing')),
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _CropOverlayPainter(windowRect),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('reference-crop-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('reference-crop-confirm'),
          onPressed: () =>
              Navigator.of(context)
                  .pop(finalizeCropWindow(_window, widget.imageSize)),
          child: const Text('Use framing'),
        ),
      ],
    );
  }

  var _panResize = false;
  var _panMove = false;
}

/// Dims the fitted image outside the window, then draws the window
/// border, rule-of-thirds grid, and the resize handle.
class _CropOverlayPainter extends CustomPainter {
  const _CropOverlayPainter(this.window);

  final Rect window;

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(window);
    scrim.fillType = PathFillType.evenOdd;
    canvas.drawPath(scrim, Paint()..color = Colors.black54);
    canvas.drawRect(
      window,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white54;
    for (var i = 1; i < 3; i++) {
      final x = window.left + window.width * i / 3;
      canvas.drawLine(Offset(x, window.top), Offset(x, window.bottom), grid);
      final y = window.top + window.height * i / 3;
      canvas.drawLine(Offset(window.left, y), Offset(window.right, y), grid);
    }
    canvas.drawCircle(window.bottomRight, 12, Paint()..color = Colors.white);
    canvas.drawCircle(
      window.bottomRight,
      12,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black54,
    );
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter oldDelegate) =>
      oldDelegate.window != window;
}
