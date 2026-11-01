import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

@immutable
class VoicePlaybackState {
  const VoicePlaybackState({
    this.ready = false,
    this.loading = false,
    this.buffering = false,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.error,
  });
  final bool ready, loading, buffering, playing;
  final Duration position, duration;
  final String? error;
}

abstract class VoicePlayback {
  ValueListenable<VoicePlaybackState> get state;
  Future<void> prepare(String url);
  Future<void> play(String url);
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();
  void dispose();
}

/// Audio uses the existing video_player backend, including its real clock.
class VideoVoicePlayback implements VoicePlayback {
  final _state = ValueNotifier(const VoicePlaybackState());
  VideoPlayerController? _controller;
  String? _url;
  var _disposed = false;
  @override
  ValueListenable<VoicePlaybackState> get state => _state;
  void _sync() {
    if (_disposed) return;
    final v = _controller?.value;
    if (v == null) return;
    _state.value = VoicePlaybackState(
      ready: v.isInitialized,
      loading: !v.isInitialized && !v.hasError,
      buffering: v.isBuffering,
      playing: v.isPlaying,
      position: v.position,
      duration: v.duration,
      error: v.errorDescription,
    );
  }

  @override
  Future<void> prepare(String url) async {
    if (_disposed || (_url == url && _controller != null)) return;
    final previous = _controller;
    previous?.removeListener(_sync);
    _url = url;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _controller = controller;
    _state.value = const VoicePlaybackState(loading: true);
    controller.addListener(_sync);
    await previous?.dispose();
    try {
      await controller.initialize();
      if (_disposed || _controller != controller) return;
      _sync();
    } catch (error) {
      if (!_disposed && _controller == controller) {
        _state.value = VoicePlaybackState(
          error: 'Audio could not be loaded: $error',
        );
      }
    }
  }

  @override
  Future<void> play(String url) async {
    await prepare(url);
    final c = _controller;
    if (_disposed || c == null || !c.value.isInitialized) return;
    if (c.value.position >= c.value.duration) await c.seekTo(Duration.zero);
    await c.play();
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _controller?.seekTo(position);
  }

  @override
  Future<void> stop() async {
    final c = _controller;
    _controller = null;
    _url = null;
    c?.removeListener(_sync);
    await c?.dispose();
    if (!_disposed) _state.value = const VoicePlaybackState();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    _state.dispose();
  }
}

String mediaTime(Duration time) {
  final seconds = time.inSeconds.clamp(0, 359999);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class VoicePreview extends StatefulWidget {
  const VoicePreview({
    super.key,
    required this.nodeId,
    required this.audioUrl,
    this.busy = false,
    this.active = true,
    this.durationSeconds,
    this.player,
  });
  final String nodeId, audioUrl;
  final bool busy, active;
  final double? durationSeconds;
  final VoicePlayback? player;
  @override
  State<VoicePreview> createState() => _VoicePreviewState();
}

class _VoicePreviewState extends State<VoicePreview> {
  late VoicePlayback _player;
  double? _drag;
  @override
  void initState() {
    super.initState();
    _player = widget.player ?? VideoVoicePlayback();
    if (widget.active) unawaited(_player.prepare(widget.audioUrl));
  }

  @override
  void didUpdateWidget(covariant VoicePreview old) {
    super.didUpdateWidget(old);
    if (old.player != widget.player) {
      unawaited(_player.stop());
      if (old.player == null) _player.dispose();
      _player = widget.player ?? VideoVoicePlayback();
    }
    if (old.audioUrl != widget.audioUrl || old.nodeId != widget.nodeId) {
      _drag = null;
      unawaited(_replace());
    } else if (!widget.active || widget.busy) {
      unawaited(_player.pause());
    } else if (!old.active) {
      unawaited(_player.prepare(widget.audioUrl));
    }
  }

  Future<void> _replace() async {
    await _player.stop();
    if (mounted && widget.active) await _player.prepare(widget.audioUrl);
  }

  @override
  void dispose() {
    if (widget.player == null) {
      _player.dispose();
    } else {
      unawaited(_player.stop());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<VoicePlaybackState>(
        valueListenable: _player.state,
        builder: (context, value, _) {
          final duration = value.duration > Duration.zero
              ? value.duration
              : Duration(
                  milliseconds: ((widget.durationSeconds ?? 0) * 1000).round(),
                );
          final max = duration.inMilliseconds.toDouble();
          final enabled = widget.active && !widget.busy && value.ready;
          return Column(
            key: ValueKey('voice-preview-${widget.nodeId}'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (value.error != null)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        value.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(_replace()),
                      child: const Text('Retry audio'),
                    ),
                  ],
                ),
              Row(
                children: [
                  IconButton(
                    tooltip: value.playing ? 'Pause audio' : 'Play audio',
                    onPressed: enabled
                        ? () => unawaited(
                            value.playing
                                ? _player.pause()
                                : _player.play(widget.audioUrl),
                          )
                        : null,
                    icon: Icon(value.playing ? Icons.pause : Icons.play_arrow),
                  ),
                  Text(mediaTime(value.position)),
                  Expanded(
                    child: Slider(
                      key: ValueKey('voice-seek-${widget.nodeId}'),
                      value: (_drag ?? value.position.inMilliseconds.toDouble())
                          .clamp(0, max > 0 ? max : 1),
                      max: max > 0 ? max : 1,
                      onChanged: enabled && max > 0
                          ? (v) => setState(() => _drag = v)
                          : null,
                      onChangeEnd: enabled
                          ? (v) {
                              unawaited(
                                _player.seek(Duration(milliseconds: v.round())),
                              );
                              setState(() => _drag = null);
                            }
                          : null,
                    ),
                  ),
                  Text(mediaTime(duration)),
                ],
              ),
              if (value.loading || value.buffering) ...[
                const LinearProgressIndicator(),
                Text(value.loading ? 'Loading audio…' : 'Buffering audio…'),
              ],
            ],
          );
        },
      );
}
