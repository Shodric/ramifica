import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// One tile in the Explore trending grid: cover, title, author. Pure:
/// data in via params, tap out via [onOpen]. No bloc, no router,
/// no repository. No counts, ratings, or durations — the catalog model
/// carries none, and they are never invented.
class ExploreStoryTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Story $title',
      button: onOpen != null,
      child: GestureDetector(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(height: 150, child: _TileCover(url: coverUrl)),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                title,
                style: RamificaText.label.copyWith(fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                authorName,
                style: RamificaText.meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
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
