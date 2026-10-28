import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Audio preview of one narrator take.
///
/// The TTS backend renders audio-only bytes; this widget plays them
/// through the existing `video_player` dependency (which handles
/// audio-only streams) so no new plugin is needed. Playback is injected
/// via [VoicePlayback]: production builds a [VideoVoicePlayback]
/// internally, tests pass a fake. The widget disposes the player it
/// owns; a caller-passed player stays the caller's.
class VoicePreview extends StatefulWidget {
  const VoicePreview({
    super.key,
    required this.nodeId,
    required this.audioUrl,
    this.busy = false,
    this.player,
  });

  final String nodeId;
  final String audioUrl;
  final bool busy;

  /// Test seam. When null the widget owns a [VideoVoicePlayback].
  final VoicePlayback? player;

  @override
  State<VoicePreview> createState() => _VoicePreviewState();
}

/// One narrator-take playback session.
abstract class VoicePlayback {
  Future<void> play(String url);
  Future<void> stop();
  void dispose();
}

/// `video_player`-backed [VoicePlayback] for audio-only takes.
class VideoVoicePlayback implements VoicePlayback {
  VideoPlayerController? _controller;
  var _disposed = false;

  @override
  Future<void> play(String url) async {
    await stop();
    if (_disposed) return;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _controller = controller;
    await controller.initialize();
    if (_disposed || _controller != controller) return;
    await controller.play();
  }

  @override
  Future<void> stop() async {
    final controller = _controller;
    _controller = null;
    await controller?.pause();
    await controller?.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
  }
}

class _VoicePreviewState extends State<VoicePreview> {
  VoicePlayback? _owned;
  var _playing = false;

  VoicePlayback get _player => widget.player ?? (_owned ??= VideoVoicePlayback());

  @override
  void didUpdateWidget(covariant VoicePreview old) {
    super.didUpdateWidget(old);
    if (old.audioUrl != widget.audioUrl ||
        old.nodeId != widget.nodeId) {
      _stop();
    }
  }

  @override
  void dispose() {
    _owned?.dispose();
    _owned = null;
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _stop();
      return;
    }
    try {
      await _player.play(widget.audioUrl);
      if (!mounted) return;
      setState(() => _playing = true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Voice preview failed.')));
    }
  }

  Future<void> _stop() async {
    await _player.stop();
    if (!mounted) return;
    if (_playing) setState(() => _playing = false);
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      key: ValueKey('voice-preview-${widget.nodeId}'),
      onPressed: widget.busy ? null : _toggle,
      child: Text(_playing ? 'Stop preview' : 'Listen'),
    );
  }
}
