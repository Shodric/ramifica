import 'support/fake_media_platform.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/clip_preview.dart';
import 'package:ramifica/features/create/voice_preview.dart';
import 'package:ramifica/features/create/steps/step_frames.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

Future<void> settlePlayer(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
}

void main() {
  late FakeMediaPlatform platform;
  setUp(() {
    platform = FakeMediaPlatform();
    VideoPlayerPlatform.instance = platform;
  });
  testWidgets(
    'audio uses real duration, moves its thumb, pauses, seeks, restarts after ending and stops leaving P3',
    (tester) async {
      final player = VideoVoicePlayback();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoicePreview(
              nodeId: 'n',
              audioUrl: 'https://fixture/voice.m4a',
              durationSeconds: 2,
              player: player,
            ),
          ),
        ),
      );
      await settlePlayer(tester);
      expect(
        find.text('0:10'),
        findsOneWidget,
      ); // actual metadata replaces the initial hint
      await tester.tap(find.byTooltip('Play audio'));
      await tester.pump();
      expect(platform.playing[1], true);
      platform.positions[1] = const Duration(seconds: 3);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<Slider>(find.byType(Slider)).value, 3000);
      await tester.tap(find.byTooltip('Pause audio'));
      await tester.pump();
      expect(platform.positions[1], const Duration(seconds: 3));
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(6000);
      slider.onChangeEnd!(6000);
      await tester.pump();
      expect(platform.positions[1], const Duration(seconds: 6));
      platform.events[1]!.add(VideoEvent(eventType: VideoEventType.completed));
      await settlePlayer(tester);
      await tester.tap(find.byTooltip('Play audio'));
      await tester.pump();
      expect(platform.positions[1], Duration.zero);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoicePreview(
              nodeId: 'n',
              audioUrl: 'https://fixture/voice.m4a',
              player: player,
              active: false,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(platform.playing[1], false);
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      await settlePlayer(tester);
      expect(platform.disposed, contains(1));
    },
  );
  testWidgets(
    'audio buffering/error/retry and take replacement are observable',
    (tester) async {
      final player = VideoVoicePlayback();
      Future<void> show(String url) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoicePreview(nodeId: 'n', audioUrl: url, player: player),
          ),
        ),
      );
      await show('https://fixture/one.m4a');
      await settlePlayer(tester);
      platform.events[1]!.add(
        VideoEvent(eventType: VideoEventType.bufferingStart),
      );
      await tester.pump();
      expect(find.text('Buffering audio…'), findsOneWidget);
      platform.events[1]!.addError(
        PlatformException(code: 'VideoError', message: 'bad audio'),
      );
      await tester.pump();
      expect(find.text('Retry audio'), findsOneWidget);
      await tester.tap(find.text('Retry audio'));
      await settlePlayer(tester);
      expect(platform.disposed, contains(1));
      await show('https://fixture/two.m4a');
      await settlePlayer(tester);
      expect(platform.urls.values.last, 'https://fixture/two.m4a');
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      await settlePlayer(tester);
    },
  );
  testWidgets(
    'video initializes only on P4, has seek/sound, replaces URL, and pauses on exit',
    (tester) async {
      Future<void> show({
        bool active = true,
        String url = 'https://fixture/one.mp4',
      }) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClipPreview(url: url, active: active),
          ),
        ),
      );
      await show(active: false);
      await tester.pump();
      expect(platform.sequence, 0);
      await show();
      await settlePlayer(tester);
      expect(platform.sequence, 1);
      expect(find.text('0:10'), findsOneWidget);
      await tester.tap(find.byTooltip('Play video'));
      await tester.pump();
      expect(platform.playing[1], true);
      await tester.tap(find.byTooltip('Pause video'));
      await tester.pump();
      expect(platform.playing[1], false);
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChangeEnd!(7000);
      await tester.pump();
      expect(platform.positions[1], const Duration(seconds: 7));
      await tester.tap(find.byTooltip('Mute'));
      await tester.pump();
      expect(platform.volumes[1], 0);
      await show(url: 'https://fixture/two.mp4');
      await settlePlayer(tester);
      expect(platform.disposed, contains(1));
      expect(platform.sequence, 2);
      await tester.tap(find.byTooltip('Play video'));
      await tester.pump();
      await show(active: false, url: 'https://fixture/two.mp4');
      await tester.pump();
      expect(platform.playing[2], false);
      await tester.pumpWidget(const SizedBox.shrink());
      await settlePlayer(tester);
      expect(platform.disposed, contains(2));
    },
  );
  testWidgets('video error ends buffering and provides retry', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ClipPreview(url: 'https://fixture/video.mp4')),
      ),
    );
    await settlePlayer(tester);
    platform.events[1]!.addError(
      PlatformException(code: 'VideoError', message: 'bad video'),
    );
    await tester.pump();
    expect(find.text('Retry video'), findsOneWidget);
    await tester.tap(find.text('Retry video'));
    await settlePlayer(tester);
    expect(platform.sequence, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await settlePlayer(tester);
  });
  testWidgets('local image request is visible immediately on the start frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StepFrames(
              node: DraftNode(nodeId: 'n'),
              busy: true,
              generatingWhich: 'start',
              phase: 'saving',
              showErrors: false,
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('generating-indicator')), findsOneWidget);
    expect(find.text('Saving changes…'), findsOneWidget);
    expect(find.byKey(const ValueKey('gen-image-start-n')), findsNothing);
    expect(find.byKey(const ValueKey('gen-image-end-n')), findsNothing);
  });
}
