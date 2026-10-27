import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:video_player/video_player.dart';

/// Plays one node mp4 and reports the first frame and the last frame.
///
/// The player does not watch the clock. `onEnded` fires from the platform
/// `ended` event, which leaves the last frame on screen.
class NodeVideo extends StatefulWidget {
  const NodeVideo({
    super.key,
    required this.url,
    required this.muted,
    required this.play,
    required this.onFirstFrame,
    required this.onEnded,
    this.player,
  });

  final String url;
  final bool muted;

  /// When false, open the clip parked on its last frame and do not emit
  /// `onEnded`. Used for a run that is already `ended`.
  final bool play;
  final VoidCallback onFirstFrame;
  final VoidCallback onEnded;

  /// Test double. Production builds a [VideoClipPlayer].
  final ClipPlayer? player;

  @override
  State<NodeVideo> createState() => _NodeVideoState();
}

class _NodeVideoState extends State<NodeVideo> {
  ClipPlayer? _owned;
  var _generation = 0;
  var _started = false;
  var _tickerEnabled = true;
  var _sawReady = false;
  var _sawEnded = false;
  var _armEnded = false;

  ClipPlayer get _player => widget.player ?? _owned!;

  @override
  void initState() {
    super.initState();
    if (widget.player == null) _owned = VideoClipPlayer();
    _player.addListener(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    final tickerChanged = enabled != _tickerEnabled;
    _tickerEnabled = enabled;
    if (!_started) {
      _started = true;
      unawaited(_open());
      return;
    }
    if (tickerChanged) _syncPlayback();
  }

  @override
  void didUpdateWidget(NodeVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _sawReady = false;
      _sawEnded = false;
      unawaited(_open());
      return;
    }
    if (oldWidget.muted != widget.muted) {
      unawaited(_player.setMuted(widget.muted));
    }
    if (oldWidget.play != widget.play) _syncPlayback();
  }

  @override
  void dispose() {
    _generation += 1;
    _player.removeListener(_onTick);
    _owned?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final generation = ++_generation;
    _armEnded = widget.play;
    // Yield so this does not run inside didChangeDependencies.
    await Future<void>.value();
    if (!mounted || generation != _generation) return;
    try {
      await _player.open(
        url: Uri.parse(widget.url),
        muted: widget.muted,
        play: widget.play,
      );
    } catch (_) {
      return;
    }
    if (!mounted || generation != _generation) return;
    await _player.setMuted(widget.muted);
    if (!mounted || generation != _generation) return;
    _onTick();
    _syncPlayback();
  }

  void _syncPlayback() {
    if (!_tickerEnabled || !widget.play || _player.ended) {
      _player.pause();
      return;
    }
    _player.resume();
  }

  void _onTick() {
    if (!mounted) return;
    final becameReady = _player.ready && !_sawReady;
    if (becameReady) {
      _sawReady = true;
      widget.onFirstFrame();
    }
    if (_armEnded && _player.ended && !_sawEnded) {
      _sawEnded = true;
      widget.onEnded();
    }
    if (becameReady) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: RamificaColors.surface,
      child: SizedBox.expand(child: _player.buildView()),
    );
  }
}

/// One mp4 surface. [NodeVideo] owns the production player.
abstract class ClipPlayer {
  Future<void> open({
    required Uri url,
    required bool muted,
    required bool play,
  });

  Future<void> setMuted(bool muted);

  void pause();

  void resume();

  void addListener(VoidCallback listener);

  void removeListener(VoidCallback listener);

  bool get ready;

  bool get ended;

  Widget buildView();

  void dispose();
}

class VideoClipPlayer implements ClipPlayer {
  VideoPlayerController? _controller;
  final _listeners = <VoidCallback>[];
  var _ready = false;
  var _ended = false;
  var _reportEnded = false;
  var _disposed = false;

  @override
  bool get ready => _ready;

  @override
  bool get ended => _ended;

  @override
  Future<void> open({
    required Uri url,
    required bool muted,
    required bool play,
  }) async {
    final previous = _controller;
    _controller = null;
    _ready = false;
    _ended = false;
    _reportEnded = play;
    previous?.removeListener(_forward);
    await previous?.dispose();
    if (_disposed) return;
    final controller = VideoPlayerController.networkUrl(
      url,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _controller = controller;
    controller.addListener(_forward);
    await controller.initialize();
    if (_disposed || _controller != controller) return;
    await controller.setVolume(muted ? 0 : 1);
    if (!play && controller.value.duration > Duration.zero) {
      await controller.seekTo(controller.value.duration);
    }
    _forward();
  }

  @override
  Future<void> setMuted(bool muted) async {
    await _controller?.setVolume(muted ? 0 : 1);
  }

  @override
  void pause() {
    unawaited(_controller?.pause());
  }

  @override
  void resume() {
    final controller = _controller;
    if (controller == null || _ended || !_reportEnded) return;
    if (!controller.value.isInitialized) return;
    unawaited(controller.play());
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  @override
  Widget buildView() {
    final controller = _controller;
    final value = controller?.value;
    if (controller == null ||
        value == null ||
        !value.isInitialized ||
        value.size.isEmpty) {
      return const SizedBox.expand();
    }
    return FittedBox(
      fit: .cover,
      child: SizedBox(
        width: value.size.width,
        height: value.size.height,
        child: VideoPlayer(controller),
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _listeners.clear();
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_forward);
    unawaited(controller?.dispose());
  }

  void _forward() {
    final value = _controller?.value;
    if (value == null) return;
    if (value.isInitialized) _ready = true;
    if (_reportEnded && value.isCompleted) _ended = true;
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }
}
