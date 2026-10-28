import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Cover, title, author, optional campaign label. Explore and Profile share
/// it. Pure: data in via params, actions out via [onOpen]. No bloc, no
/// router, no repository.
class StoryCard extends StatelessWidget {
  const StoryCard({
    super.key,
    required this.title,
    required this.authorName,
    this.coverUrl,
    this.campaignLabel,
    this.onOpen,
  });

  final String title;
  final String authorName;
  final String? coverUrl;
  final String? campaignLabel;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final label = campaignLabel?.trim();
    return Semantics(
      label: 'Story $title',
      button: onOpen != null,
      child: GestureDetector(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: .stretch,
          mainAxisSize: .min,
          children: [
            ClipRRect(
              borderRadius: .circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: _Cover(url: coverUrl, title: title),
              ),
            ),
            const SizedBox(height: 8),
            Text(title, style: _titleStyle, maxLines: 2, overflow: .ellipsis),
            const SizedBox(height: 2),
            Text(
              authorName,
              style: RamificaText.meta,
              maxLines: 1,
              overflow: .ellipsis,
            ),
            if (label != null && label.isNotEmpty) ...[
              const SizedBox(height: 6),
              Align(
                alignment: .centerLeft,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: RamificaColors.glass,
                    borderRadius: .circular(999),
                    border: .all(color: RamificaColors.glassBorder),
                  ),
                  child: Padding(
                    padding: const .symmetric(horizontal: 10, vertical: 4),
                    child: Text(
                      label,
                      style: RamificaText.meta.copyWith(
                        color: RamificaColors.hotspot,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Story titles use the display family (see theme: Montserrat 700 is only
/// for the story title, the ending name, and the screen title).
const _titleStyle = TextStyle(
  fontFamily: RamificaText.display,
  fontWeight: .w700,
  fontSize: 17,
  height: 22 / 17,
  color: RamificaColors.textPrimary,
);

class _Cover extends StatelessWidget {
  const _Cover({required this.url, required this.title});

  final String? url;
  final String title;

  @override
  Widget build(BuildContext context) {
    final uri = url?.trim();
    if (uri == null || uri.isEmpty) {
      return const ColoredBox(color: RamificaColors.nodeLocked);
    }
    return Image.network(
      uri,
      fit: .cover,
      semanticLabel: 'Cover of $title',
      errorBuilder: (_, _, _) =>
          const ColoredBox(color: RamificaColors.nodeLocked),
    );
  }
}
