import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/features/feed/video_frame.dart';

void main() {
  group('VideoFrame', () {
    test('maps 1:1 on an exact 9:16 screen', () {
      const video = VideoFrame(Size(450, 800));
      expect(video.left, 0);
      expect(video.top, 0);
      expect(
        video.point(0.25, 0.65),
        offsetMoreOrLessEquals(const Offset(112.5, 520)),
      );
      expect(video.radius(0.12), closeTo(54, 1e-9));
    });

    test('crops the sides on a tall phone', () {
      const video = VideoFrame(Size(390, 844));
      // scale = max(390/9, 844/16) = 52.75; video is 474.75x844.
      expect(video.left, closeTo(-42.375, 1e-9));
      expect(video.top, 0);
      expect(
        video.point(0.25, 0.65),
        offsetMoreOrLessEquals(const Offset(76.3125, 548.6)),
      );
      expect(video.radius(0.12), closeTo(56.97, 1e-9));
    });

    test('crops top and bottom on a wide screen', () {
      const video = VideoFrame(Size(800, 600));
      expect(video.left, 0);
      expect(video.top, closeTo(-411.11, 0.01));
      expect(
        video.point(0.5, 0.5),
        offsetMoreOrLessEquals(const Offset(400, 300)),
      );
    });

    test('one side always matches the screen', () {
      const screens = [
        Size(390, 844),
        Size(800, 600),
        Size(450, 800),
        Size(768, 1024),
      ];
      for (final screen in screens) {
        final video = VideoFrame(screen);
        final matchesWidth = (video.width - screen.width).abs() < 1e-9;
        final matchesHeight = (video.height - screen.height).abs() < 1e-9;
        expect(matchesWidth || matchesHeight, isTrue);
        expect(video.left, lessThanOrEqualTo(0));
        expect(video.top, lessThanOrEqualTo(0));
      }
    });

    test('width-fit maps the editor crop onto a wider source', () {
      const video = VideoFrame.fitWidth(
        Size(390, 844),
        sourceSize: Size(480, 832),
      );
      expect(video.width, 390);
      expect(video.height, closeTo(676, 1e-9));
      expect(video.top, closeTo(84, 1e-9));
      expect(
        video.point(0.25, 0.65),
        offsetMoreOrLessEquals(const Offset(99.9375, 523.4)),
      );
      expect(video.radius(0.12), closeTo(45.63, 1e-9));
    });

    test('width-fit maps the editor crop onto a taller source', () {
      const video = VideoFrame.fitWidth(
        Size(390, 844),
        sourceSize: Size(480, 960),
      );
      expect(video.width, 390);
      expect(video.height, 780);
      expect(video.top, 32);
      expect(
        video.point(0.75, 0.65),
        offsetMoreOrLessEquals(const Offset(292.5, 526)),
      );
      expect(video.radius(0.12), closeTo(46.8, 1e-9));
    });

    test('useStage splits phones from wide screens', () {
      expect(VideoFrame.useStage(const Size(390, 844)), isFalse);
      expect(VideoFrame.useStage(const Size(600, 800)), isFalse);
      expect(VideoFrame.useStage(const Size(601, 800)), isTrue);
      expect(VideoFrame.useStage(const Size(800, 600)), isTrue);
      expect(VideoFrame.useStage(const Size(1920, 1080)), isTrue);
    });

    test('contain centers a 9:16 clip on a wide screen', () {
      const video = VideoFrame.contain(Size(1200, 800));
      expect(video.width, 450);
      expect(video.height, 800);
      expect(video.left, 375);
      expect(video.top, 0);
      expect(
        video.point(0.25, 0.55),
        offsetMoreOrLessEquals(const Offset(487.5, 440)),
      );
      expect(video.radius(0.12), closeTo(54, 1e-9));
    });

    test('contain letterboxes instead of cropping', () {
      const screens = [
        Size(390, 844),
        Size(800, 600),
        Size(1200, 800),
        Size(1920, 1080),
        Size(768, 1024),
      ];
      for (final screen in screens) {
        final video = VideoFrame.contain(screen);
        // The whole clip stays on screen: no negative edges, no overflow.
        expect(video.left, greaterThanOrEqualTo(0));
        expect(video.top, greaterThanOrEqualTo(0));
        expect(
          video.left + video.width,
          lessThanOrEqualTo(screen.width + 1e-9),
        );
        expect(
          video.top + video.height,
          lessThanOrEqualTo(screen.height + 1e-9),
        );
        // One side always fills the screen: as large as complete allows.
        final fillsWidth = (video.width - screen.width).abs() < 1e-9;
        final fillsHeight = (video.height - screen.height).abs() < 1e-9;
        expect(fillsWidth || fillsHeight, isTrue);
      }
    });

    test('contain maps the editor crop onto a landscape source', () {
      const video = VideoFrame.contain(
        Size(1200, 800),
        sourceSize: Size(1920, 1080),
      );
      expect(video.width, 1200);
      expect(video.height, closeTo(675, 1e-9));
      expect(video.left, 0);
      expect(video.top, closeTo(62.5, 1e-9));
      // The centered 9:16 crop keeps the frame center on screen center.
      expect(
        video.point(0.5, 0.5),
        offsetMoreOrLessEquals(const Offset(600, 400)),
      );
      expect(video.radius(0.12), closeTo(45.5625, 1e-9));
    });

    test('contain falls back to 9:16 without a decoded size', () {
      const invalid = VideoFrame.contain(
        Size(1200, 800),
        sourceSize: Size.zero,
      );
      const missing = VideoFrame.contain(Size(1200, 800));
      expect(invalid.width, missing.width);
      expect(invalid.height, missing.height);
      expect(invalid.left, missing.left);
      expect(
        invalid.point(0.25, 0.55),
        offsetMoreOrLessEquals(missing.point(0.25, 0.55)),
      );
    });
  });
}
