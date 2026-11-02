import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:video_player/video_player.dart';

/// Opens the full-scene preview for the open node: the clip plays first,
/// then the narrator line speaks while the choice hotspots fade in —
/// exactly the feed order (video, audio, hotspots). Read-only: hotspots
/// do not navigate. Nothing is committed, no run is created.
Future<void> showCreatePreview(
  BuildContext context, {
  required DraftNode? node,
}) {
  return showDialog(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: RamificaColors.surface,
      child: CreatePreview(node: node),
    ),
  );
}

/// Read-only scene preview dialog. Dismisses on tap outside or the close
/// button. When the node has no clip, an empty-state box shows instead
/// of erroring.
class CreatePreview extends StatefulWidget {
  const CreatePreview({super.key, required this.node});

  final DraftNode? node;

  @override
  State<CreatePreview> createState() => _CreatePreviewState();
}

enum _Phase { loading, video, finale }

class _CreatePreviewState extends State<CreatePreview> {
  VideoPlayerController? _video;
  VideoPlayerController? _audio;
  var _phase = _Phase.loading;
  var _advanced = false;
  var _everPlayed = false;
  var _videoPlaying = false;
  String? _error;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final url = widget.node?.videoUrl;
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _error = 'No clip yet');
      return;
    }
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _video = controller;
    controller.addListener(_onVideoTick);
    try {
      await controller.initialize().timeout(const Duration(seconds: 20));
      if (_disposed) return;
      await controller.setVolume(1);
      await controller.play();
      if (_disposed) return;
      setState(() {
        _phase = _Phase.video;
        _everPlayed = true;
        _videoPlaying = true;
      });
    } catch (error) {
      if (_disposed) return;
      setState(() => _error = 'Clip could not be loaded');
    }
  }

  void _onVideoTick() {
    final controller = _video;
    if (controller == null || _advanced) return;
    final value = controller.value;
    if (!value.isInitialized || value.hasError) return;
    if (value.isPlaying != _videoPlaying) {
      setState(() => _videoPlaying = value.isPlaying);
    }
    if (value.duration > Duration.zero &&
        value.position >= value.duration &&
        !value.isPlaying) {
      _advanced = true;
      unawaited(_enterFinale());
    }
  }

  /// The clip ended: speak the narrator line (when the take exists) and
  /// reveal the choice hotspots over the last frame.
  Future<void> _enterFinale() async {
    if (_disposed) return;
    setState(() {
      _phase = _Phase.finale;
      _videoPlaying = false;
    });
    final url = widget.node?.ttsAudioUrl;
    if (url == null || url.isEmpty) return;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _audio = controller;
    try {
      await controller.initialize().timeout(const Duration(seconds: 20));
      if (_disposed) return;
      await controller.setVolume(1);
      await controller.play();
    } catch (_) {
      // Narration is a bonus: hotspots stay visible without it.
    }
  }

  Future<void> _toggle() async {
    if (_phase == _Phase.video) {
      final controller = _video;
      if (controller == null || !controller.value.isInitialized) return;
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        _everPlayed = true;
        await controller.play();
      }
      return;
    }
    final audio = _audio;
    if (audio == null || !audio.value.isInitialized) return;
    if (audio.value.isPlaying) {
      await audio.pause();
    } else {
      await audio.play();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _video?.removeListener(_onVideoTick);
    unawaited(_video?.dispose());
    unawaited(_audio?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final title = (node?.title.trim().isEmpty ?? true)
        ? '(untitled)'
        : node!.title.trim();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360, maxHeight: 640),
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Preview — $title',
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: RamificaText.labelSM,
                  ),
                ),
                IconButton(
                  key: const ValueKey('close-preview'),
                  tooltip: 'Close preview',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          Flexible(child: _media(node)),
        ],
      ),
    );
  }

  Widget _media(DraftNode? node) {
    if (_error != null) {
      return SizedBox(
        height: 160,
        child: Center(
          child: Text(
            _error!,
            style: RamificaText.bodySM.copyWith(
              color: RamificaColors.error,
            ),
          ),
        ),
      );
    }
    final video = _video;
    if (video == null || !video.value.isInitialized) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final choices = node?.choices ?? const <DraftChoice>[];
    final showChoices =
        _phase == _Phase.finale && !(node?.isEnding ?? true) && choices.isNotEmpty;
    final line = node?.ttsText.trim() ?? '';
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep the 9:16 frame inside the dialog.
        final width = constraints.maxWidth > 0 ? constraints.maxWidth : 320.0;
        final maxHeight = constraints.maxHeight > 0 ? constraints.maxHeight : 560.0;
        final height = (width * 16 / 9).clamp(0.0, maxHeight);
        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: GestureDetector(
              onTap: _toggle,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: .expand,
                  children: [
                    VideoPlayer(video),
                    if (!_everPlayed)
                      const Center(
                        child: CircleAvatar(
                          radius: 28,
                          backgroundColor: Colors.black54,
                          child: Icon(
                            Icons.play_arrow,
                            size: 36,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    if (_everPlayed && !_videoPlaying && _phase == _Phase.video)
                      const Center(
                        child: CircleAvatar(
                          radius: 28,
                          backgroundColor: Colors.black54,
                          child: Icon(
                            Icons.play_arrow,
                            size: 36,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    if (showChoices) ...[
                      // Bottom scrim + narrator line, feed style.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(12, 24, 12, 12),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                Color(0xE6141318),
                                Color(0x00141318),
                              ],
                            ),
                          ),
                          child: line.isEmpty
                              ? const SizedBox.shrink()
                              : Text(
                                  line,
                                  maxLines: 3,
                                  overflow: .ellipsis,
                                  style: RamificaText.bodySM.copyWith(
                                    color: Colors.white,
                                  ),
                                ),
                        ),
                      ),
                      for (final choice in choices)
                        _HotspotMarker(
                          label: choice.label.isEmpty ? 'Option' : choice.label,
                          x: choice.x,
                          y: choice.y,
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Read-only hotspot marker: a labeled pill centered on the choice
/// position. Unlike the feed hold zones, tapping does nothing — this is
/// a preview of how the scene will look, not a playable run.
class _HotspotMarker extends StatelessWidget {
  const _HotspotMarker({
    required this.label,
    required this.x,
    required this.y,
  });

  final String label;
  final double x;
  final double y;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment:
          Alignment(x.clamp(0.0, 1.0) * 2 - 1, y.clamp(0.0, 1.0) * 2 - 1),
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: RamificaColors.hotspot, width: 1.5),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: .ellipsis,
              textAlign: .center,
              style: RamificaText.labelSM.copyWith(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
