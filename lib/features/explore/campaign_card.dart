import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/story_card.dart';

/// A story in an active campaign: [StoryCard] plus the brand label. The
/// reward is never shown, so there is no reward input. Pure: data in via
/// params, actions out via [onOpen]. No bloc, no router, no repository.
class CampaignCard extends StatelessWidget {
  const CampaignCard({
    super.key,
    required this.title,
    required this.authorName,
    required this.brandLabel,
    this.coverUrl,
    this.onOpen,
  });

  final String title;
  final String authorName;
  final String brandLabel;
  final String? coverUrl;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final brand = brandLabel.trim();
    return Semantics(
      label: 'Campaign $title',
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  brand,
                  style: RamificaText.meta.copyWith(
                    color: RamificaColors.hotspot,
                  ),
                  maxLines: 1,
                  overflow: .ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          StoryCard(
            title: title,
            authorName: authorName,
            coverUrl: coverUrl,
            onOpen: onOpen,
          ),
        ],
      ),
    );
  }
}
