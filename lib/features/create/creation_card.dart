import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/draft_story.dart';
import 'package:ramifica/features/create/create_node_card.dart';

/// One draft on the creations list: cover art, title, description, scene
/// and ending counts, and the draft status. Tapping opens it on the canvas.
/// Unknown (null) counts hide the counts line; the open draft shows its
/// live counts while the rest show the listed ones.
class CreationCard extends StatelessWidget {
  const CreationCard({
    super.key,
    required this.story,
    required this.nodeCount,
    required this.endingCount,
    required this.isOpen,
    required this.onTap,
  });

  final DraftStory story;
  final int? nodeCount;
  final int? endingCount;
  final bool isOpen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = story.title.trim().isEmpty
        ? 'Untitled story'
        : story.title.trim();
    final synopsis = story.synopsis.trim();
    return Container(
      decoration: BoxDecoration(
        color: RamificaColors.containerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isOpen
              ? RamificaColors.hotspot
              : RamificaColors.outlineVariant,
          width: isOpen ? 2 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: ValueKey('creation-${story.storyId}'),
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: .stretch,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(13),
                ),
                child: SizedBox(
                  height: 120,
                  width: double.infinity,
                  child: CreateNodeThumb(url: story.coverUrl, iconSize: 32),
                ),
              ),
              Padding(
                padding: const .all(12),
                child: Column(
                  crossAxisAlignment: .start,
                  mainAxisSize: .min,
                  children: [
                    Text(title, style: RamificaText.headlineSM),
                    if (synopsis.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        synopsis,
                        maxLines: 2,
                        overflow: .ellipsis,
                        style: RamificaText.meta,
                      ),
                    ],
                    if (nodeCount != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _countsLine(nodeCount!, endingCount ?? 0),
                        style: RamificaText.caption.copyWith(
                          color: RamificaColors.nodeActive,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          story.status == 'published' ? 'Published' : 'Draft',
                          style: RamificaText.meta,
                        ),
                        const Spacer(),
                        if (isOpen)
                          Text('Open', style: RamificaText.meta)
                        else
                          const Icon(Icons.chevron_right, size: 24),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _countsLine(int nodes, int endings) {
  if (nodes == 0) return 'No scenes yet';
  final scenes = '$nodes scene${nodes == 1 ? '' : 's'}';
  if (endings == 0) return scenes;
  return '$scenes · $endings ending${endings == 1 ? '' : 's'}';
}
