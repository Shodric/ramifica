import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/features/create/voice_preview.dart';

class _FakeVoicePlayback implements VoicePlayback {
  final _state = ValueNotifier(
    const VoicePlaybackState(
      ready: true,
      position: Duration(seconds: 10),
      duration: Duration(seconds: 60),
    ),
  );

  @override
  Future<void> pause() async {}

  @override
  Future<void> play(String url) async {}

  @override
  Future<void> prepare(String url) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}

  @override
  ValueListenable<VoicePlaybackState> get state => _state;

  @override
  void dispose() => _state.dispose();
}

void main() {
  testWidgets('voice seek shows the remaining path in white', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoicePreview(
            nodeId: 'n1',
            audioUrl: 'https://example.com/a.mp3',
            player: _FakeVoicePlayback(),
          ),
        ),
      ),
    );
    await tester.pump();

    final slider = find.byKey(const ValueKey('voice-seek-n1'));
    expect(slider, findsOneWidget);
    final theme = tester.widget<SliderTheme>(
      find.ancestor(of: slider, matching: find.byType(SliderTheme)),
    );
    expect(
      theme.data.inactiveTrackColor,
      RamificaColors.textPrimary.withValues(alpha: 0.25),
    );
  });
}
