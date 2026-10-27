import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';

/// Title and author while the clip plays. Not interactive.
class StoryChip extends StatelessWidget {
  const StoryChip({super.key, required this.title, required this.author});

  final String title;
  final String author;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: GlassPanel(
        padding: const .symmetric(horizontal: 12, vertical: 8),
        borderRadius: const .all(.circular(999)),
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: .ellipsis,
              style: RamificaText.overVideo(
                RamificaText.screenTitle.copyWith(
                  fontSize: 14,
                  height: 18 / 14,
                ),
              ),
            ),
            Text(
              'by $author',
              maxLines: 1,
              overflow: .ellipsis,
              style: RamificaText.overVideo(RamificaText.meta),
            ),
          ],
        ),
      ),
    );
  }
}
