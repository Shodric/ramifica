import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/features/create/crop_region.dart';
import 'package:ramifica/features/create/steps/reference_cropper.dart';

/// 1x1 transparent PNG: decodes under flutter_test without network.
Uint8List _pixel() => Uint8List.fromList([
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  10,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  0,
  1,
  0,
  0,
  5,
  0,
  1,
  13,
  10,
  45,
  180,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
]);

void main() {
  group('CropRegion', () {
    test('fits accepts boxes inside the source', () {
      expect(
        const CropRegion(x: 0, y: 0, width: 9, height: 16).fits(9, 16),
        isTrue,
      );
      expect(
        const CropRegion(x: 1, y: 1, width: 9, height: 16).fits(9, 16),
        isFalse,
      );
      expect(
        const CropRegion(x: 0, y: 0, width: 0, height: 16).fits(9, 16),
        isFalse,
      );
      expect(
        const CropRegion(x: -1, y: 0, width: 9, height: 16).fits(9, 16),
        isFalse,
      );
      expect(
        const CropRegion(x: 0, y: 0, width: 10, height: 16).fits(9, 16),
        isFalse,
      );
    });

    test('checkCropRegion throws outside the source', () {
      expect(
        () => checkCropRegion(
          const CropRegion(x: 0, y: 0, width: 9, height: 16),
          8,
          16,
        ),
        throwsA(const AppFailure(.invalid)),
      );
      expect(
        () => checkCropRegion(
          const CropRegion(x: 0, y: 0, width: 9, height: 16),
          9,
          16,
        ),
        returnsNormally,
      );
    });
  });

  group('cropper math', () {
    test('initial window is the largest centered 9:16 box', () {
      // Landscape: height-bound, centered horizontally.
      final wide = initialCropWindow(const Size(1600, 900));
      expect(wide.height, 900);
      expect(wide.width, closeTo(506.25, 0.001));
      expect(wide.left, closeTo((1600 - 506.25) / 2, 0.001));
      expect(wide.top, 0);

      // Exact 9:16 portrait: full-bleed.
      final tall = initialCropWindow(const Size(900, 1600));
      expect(tall, const Rect.fromLTWH(0, 0, 900, 1600));

      // Square: height-bound.
      final square = initialCropWindow(const Size(1000, 1000));
      expect(square.height, 1000);
      expect(square.width, closeTo(562.5, 0.001));
      expect(square.left, closeTo((1000 - 562.5) / 2, 0.001));
    });

    test('move clamps inside the image', () {
      const size = Size(1600, 900);
      final window = initialCropWindow(size);
      final moved = moveCropWindow(window, const Offset(10000, 10000), size);
      expect(moved.right, size.width);
      expect(moved.bottom, size.height);
      expect(moved.width, window.width);
      final back = moveCropWindow(moved, const Offset(-10000, -10000), size);
      expect(back.left, 0);
      expect(back.top, 0);
    });

    test('resize keeps 9:16 and clamps to bounds and minimum', () {
      const size = Size(1600, 900);
      final window = initialCropWindow(size);
      final shrunk = resizeCropWindow(window, -400, size);
      expect(shrunk.width, closeTo(window.width - 400, 0.001));
      expect(shrunk.height / shrunk.width, closeTo(16 / 9, 0.001));

      final tiny = resizeCropWindow(window, -10000, size);
      expect(tiny.width, minCropWindowWidthPx);

      final grown = resizeCropWindow(tiny, 10000, size);
      expect(grown.height, size.height);
      expect(grown.width / grown.height, closeTo(9 / 16, 0.001));
      expect(grown.right <= size.width, isTrue);
      expect(grown.bottom <= size.height, isTrue);
    });

    test('resize on tiny sources never traps the clamp', () {
      const size = Size(100, 100);
      final window = initialCropWindow(size);
      expect(window.width, lessThan(minCropWindowWidthPx));
      final resized = resizeCropWindow(window, -10, size);
      expect(resized.width, window.width);
      expect(resized.height, window.height);
    });

    test('center clamps inside the image', () {
      const size = Size(1600, 900);
      final window = initialCropWindow(size);
      final centered = centerCropWindow(window, const Offset(800, 450), size);
      expect(centered.center.dx, closeTo(800, 0.001));
      expect(centered.center.dy, closeTo(450, 0.001));
      final corner = centerCropWindow(window, Offset.zero, size);
      expect(corner.left, 0);
      expect(corner.top, 0);
    });

    test('finalize snaps to integer pixels inside the image', () {
      const size = Size(1600, 900);
      expect(
        finalizeCropWindow(const Rect.fromLTWH(10.4, 20.6, 100.2, 177.8), size),
        const CropRegion(x: 10, y: 21, width: 100, height: 178),
      );
      final edge = finalizeCropWindow(
        const Rect.fromLTWH(1550.7, 850.2, 100.4, 100.9),
        size,
      );
      expect(edge.x + edge.width <= 1600, isTrue);
      expect(edge.y + edge.height <= 900, isTrue);
    });

    test('contain rect centers the fitted image', () {
      final rect = cropImageRect(const Size(1600, 900), const Size(300, 400));
      expect(rect.width, 300);
      expect(rect.height, closeTo(168.75, 0.001));
      expect(rect.left, 0);
      expect(rect.top, closeTo((400 - 168.75) / 2, 0.001));
    });
  });

  group('ReferenceCropDialog', () {
    Future<void> open(
      WidgetTester tester, {
      required Size imageSize,
      required void Function(Future<CropRegion?>) onOpened,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => onOpened(
                  showReferenceCropper(
                    context: context,
                    image: MemoryImage(_pixel()),
                    imageSize: imageSize,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('confirm returns the initial framing', (tester) async {
      late final Future<CropRegion?> pending;
      await open(
        tester,
        imageSize: const Size(900, 1600),
        onOpened: (future) => pending = future,
      );

      await tester.tap(find.byKey(const ValueKey('reference-crop-confirm')));
      await tester.pumpAndSettle();

      expect(
        await pending,
        const CropRegion(x: 0, y: 0, width: 900, height: 1600),
      );
    });

    testWidgets('cancel returns null', (tester) async {
      late final Future<CropRegion?> pending;
      await open(
        tester,
        imageSize: const Size(900, 1600),
        onOpened: (future) => pending = future,
      );

      await tester.tap(find.byKey(const ValueKey('reference-crop-cancel')));
      await tester.pumpAndSettle();

      expect(await pending, isNull);
    });

    testWidgets('dragging the window moves the framing', (tester) async {
      const imageSize = Size(1600, 900);
      late final Future<CropRegion?> pending;
      await open(
        tester,
        imageSize: imageSize,
        onOpened: (future) => pending = future,
      );

      // Exact pixel math lives in the unit tests above; the pan
      // recognizer drops the pre-start slop travel, so the widget
      // asserts direction, bounds, and aspect instead of exact pixels.
      final area = find.byKey(const ValueKey('reference-crop-area'));
      final areaSize = tester.getSize(area);
      final scale = cropFitScale(imageSize, areaSize);
      final initial = initialCropWindow(imageSize);
      await tester.drag(area, const Offset(120, 0));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('reference-crop-confirm')));
      await tester.pumpAndSettle();

      final region = await pending;
      expect(region, isNotNull);
      expect(region!.x, greaterThan(initial.left.round()));
      expect(
        region.x,
        lessThanOrEqualTo((initial.left + 120 / scale).ceil() + 1),
      );
      expect(region.width / region.height, closeTo(9 / 16, 0.01));
    });

    testWidgets('dragging far clamps the framing to the edge', (tester) async {
      const imageSize = Size(1600, 900);
      late final Future<CropRegion?> pending;
      await open(
        tester,
        imageSize: imageSize,
        onOpened: (future) => pending = future,
      );

      await tester.drag(
        find.byKey(const ValueKey('reference-crop-area')),
        const Offset(1000, 500),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('reference-crop-confirm')));
      await tester.pumpAndSettle();

      // Clamping is exact no matter how much slop the drag lost.
      final region = await pending;
      expect(region, isNotNull);
      expect(region!.x + region.width, imageSize.width.toInt());
      expect(region.y + region.height, imageSize.height.toInt());
      expect(region.width / region.height, closeTo(9 / 16, 0.01));
    });

    testWidgets('pulling the handle resizes the framing', (tester) async {
      const imageSize = Size(1600, 900);
      late final Future<CropRegion?> pending;
      await open(
        tester,
        imageSize: imageSize,
        onOpened: (future) => pending = future,
      );

      final area = find.byKey(const ValueKey('reference-crop-area'));
      final areaSize = tester.getSize(area);
      final imageRect = cropImageRect(imageSize, areaSize);
      final scale = cropFitScale(imageSize, areaSize);
      final window = initialCropWindow(imageSize);
      final handle = Offset(
        imageRect.left + window.right * scale,
        imageRect.top + window.bottom * scale,
      );
      final areaTopLeft = tester.getTopLeft(area);
      await tester.dragFrom(areaTopLeft + handle, const Offset(-60, -60));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('reference-crop-confirm')));
      await tester.pumpAndSettle();

      final region = await pending;
      expect(region, isNotNull);
      expect(region!.width, lessThan(window.width.round()));
      expect(
        region.width,
        greaterThanOrEqualTo((window.width - 60 / scale).floor() - 1),
      );
      expect(region.width / region.height, closeTo(9 / 16, 0.01));
    });

    testWidgets('tapping outside recenters the framing', (tester) async {
      const imageSize = Size(1600, 900);
      late final Future<CropRegion?> pending;
      await open(
        tester,
        imageSize: imageSize,
        onOpened: (future) => pending = future,
      );

      final area = find.byKey(const ValueKey('reference-crop-area'));
      final areaSize = tester.getSize(area);
      final imageRect = cropImageRect(imageSize, areaSize);
      // Far right edge of the fitted image, vertically centered.
      final target = Offset(imageRect.right - 4, imageRect.center.dy);
      await tester.tapAt(tester.getTopLeft(area) + target);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('reference-crop-confirm')));
      await tester.pumpAndSettle();

      final region = await pending;
      expect(region, isNotNull);
      // The window slid right as far as the tap recentering allows.
      expect(region!.x, greaterThan(initialCropWindow(imageSize).left.round()));
      expect(region.width / region.height, closeTo(9 / 16, 0.01));
    });
  });
}
