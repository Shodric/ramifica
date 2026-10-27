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
  });
}
