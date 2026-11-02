import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:video_player/video_player.dart';

import 'voice_preview.dart' show mediaTime;

/// Embedded player, also used by the general preview. Playback is explicit.
/// With [expand], the video box fills the leftover height instead of the
/// fixed 280px (the parent must bound the height and the column).
class ClipPreview extends StatefulWidget {
  const ClipPreview({
    super.key,
    required this.url,
    this.active = true,
    this.generating = false,
    this.phase,
    this.width,
    this.height,
    this.durationSeconds,
    this.expand = false,
  });
  final String url;
  final bool active, generating;
  final String? phase;
  final int? width, height;
  final double? durationSeconds;
  final bool expand;
  @override
  State<ClipPreview> createState() => _ClipPreviewState();
}

class _ClipPreviewState extends State<ClipPreview> {
  VideoPlayerController? _controller;
  String? _error;
  double? _drag;
  @override
  void initState() {
    super.initState();
    if (widget.active) unawaited(_load());
  }

  Future<void> _load() async {
    final old = _controller;
    old?.removeListener(_changed);
    final next = VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _controller = next;
    _error = null;
    _drag = null;
    next.addListener(_changed);
    if (mounted) setState(() {});
    await old?.dispose();
    try {
      await next.initialize().timeout(const Duration(seconds: 20));
    } catch (e) {
      if (mounted && next == _controller) {
        _error = 'Video could not be loaded: $e';
      }
    }
    if (mounted && next == _controller) {
      if (!widget.active) await next.pause();
      setState(() {});
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Pauses and releases the controller. The next activation reloads it
  /// from scratch, so nothing keeps playing behind the new step.
  void _release() {
    final c = _controller;
    _controller = null;
    _drag = null;
    if (c == null) return;
    c.removeListener(_changed);
    unawaited(c.dispose());
  }

  @override
  void didUpdateWidget(covariant ClipPreview old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      // New take on the same open node: swap the controller in place so
      // the screen never reloads.
      if (widget.active) {
        unawaited(_load());
      } else {
        _release();
      }
    } else if (!widget.active) {
      // Leaving the step (step change, preview, child node): pause and
      // release so video never plays behind the new screen.
      _release();
    } else if (widget.generating) {
      unawaited(_controller?.pause());
    } else if (!old.active && _controller == null) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    final c = _controller;
    final v = c?.value;
    final ready = v?.isInitialized == true;
    final error = _error ?? v?.errorDescription;
    final duration = ready
        ? v!.duration
        : Duration(
            milliseconds: ((widget.durationSeconds ?? 0) * 1000).round(),
          );
    final max = duration.inMilliseconds.toDouble();
    final enabled =
        ready && widget.active && !widget.generating && error == null;
    final videoBox = Stack(
      alignment: Alignment.center,
      children: [
        if (ready)
          AspectRatio(aspectRatio: v!.aspectRatio, child: VideoPlayer(c!))
        else
          const ColoredBox(color: Colors.black, child: SizedBox.expand()),
        if (error == null &&
            ((!ready && widget.active) || v?.isBuffering == true))
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [CircularProgressIndicator(), Text('Loading video…')],
          ),
        if (widget.generating)
          ColoredBox(
            color: Colors.black54,
            child: SizedBox.expand(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  Text(
                    widget.phase == 'processing'
                        ? 'Processing video…'
                        : widget.phase == 'saving'
                        ? 'Saving changes…'
                        : 'Generating video…',
                  ),
                ],
              ),
            ),
          ),
        if (error != null)
          ColoredBox(
            color: Colors.black87,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(error),
                      TextButton(
                        onPressed: widget.active ? _load : null,
                        child: const Text('Retry video'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    return Column(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.expand
            ? Expanded(child: videoBox)
            : SizedBox(height: 280, child: videoBox),
        Row(
          children: [
            IconButton(
              key: const ValueKey('video-play'),
              tooltip: v?.isPlaying == true ? 'Pause video' : 'Play video',
              onPressed: enabled
                  ? () async {
                      if (v!.isPlaying) {
                        await c!.pause();
                      } else {
                        if (v.position >= v.duration) {
                          await c!.seekTo(Duration.zero);
                        }
                        await c!.play();
                      }
                    }
                  : null,
              icon: Icon(v?.isPlaying == true ? Icons.pause : Icons.play_arrow),
            ),
            Text(mediaTime(v?.position ?? Duration.zero)),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  // Same as the audio bar: white at 25% keeps the
                  // remaining path visible on the dark surface.
                  inactiveTrackColor: RamificaColors.textPrimary.withValues(
                    alpha: 0.25,
                  ),
                ),
                child: Slider(
                  key: const ValueKey('video-seek'),
                  max: max > 0 ? max : 1,
                  value: (_drag ?? v?.position.inMilliseconds.toDouble() ?? 0)
                      .clamp(0, max > 0 ? max : 1),
                  onChanged: enabled && max > 0
                      ? (p) => setState(() => _drag = p)
                      : null,
                  onChangeEnd: enabled
                      ? (p) {
                          unawaited(
                            c!.seekTo(Duration(milliseconds: p.round())),
                          );
                          setState(() => _drag = null);
                        }
                      : null,
                ),
              ),
            ),
            Text(mediaTime(duration)),
            IconButton(
              key: const ValueKey('video-mute'),
              tooltip: v?.volume == 0 ? 'Unmute' : 'Mute',
              onPressed: enabled
                  ? () => c!.setVolume(v!.volume == 0 ? 1 : 0)
                  : null,
              icon: Icon(v?.volume == 0 ? Icons.volume_off : Icons.volume_up),
            ),
          ],
        ),
      ],
    );
  }
}
