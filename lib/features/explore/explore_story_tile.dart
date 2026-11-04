import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// One tile in the Explore trending grid: cover, title, author. Pure:
/// data in via params, tap out via [onOpen]. No bloc, no router,
/// no repository. No counts, ratings, or durations — the catalog model
/// carries none, and they are never invented.
class ExploreStoryTile extends StatefulWidget {
  const ExploreStoryTile({
    super.key,
    required this.title,
    required this.authorName,
    this.coverUrl,
    this.onOpen,
  });

  final String title;
  final String authorName;
  final String? coverUrl;
  final VoidCallback? onOpen;

  @override
  State<ExploreStoryTile> createState() => _ExploreStoryTileState();
}

class _ExploreStoryTileState extends State<ExploreStoryTile> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Story ${widget.title}',
      button: widget.onOpen != null,
      child: GestureDetector(
        onTap: widget.onOpen,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: AnimatedScale(
          scale: _pressed ? 0.95 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 330,
                child: _TileCover(url: widget.coverUrl),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                widget.title,
                style: RamificaText.label.copyWith(fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                widget.authorName,
                style: RamificaText.meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }
}

class _TileCover extends StatelessWidget {
  const _TileCover({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final uri = url?.trim();
    if (uri == null || uri.isEmpty) {
      return const ColoredBox(color: RamificaColors.nodeLocked);
    }
    return Image.network(
      uri,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) =>
          const ColoredBox(color: RamificaColors.nodeLocked),
    );
  }
}
