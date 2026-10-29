import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// A story in an active campaign: sponsored card with cover, exclusive
/// badge, brand eyebrow, title, and a Try button. The reward is never
/// shown, so there is no reward input. Pure: data in via params,
/// actions out via [onOpen]. No bloc, no router, no repository.
/// No animations.
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
      button: onOpen != null,
      child: GestureDetector(
        onTap: onOpen,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: RamificaColors.containerHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
                child: SizedBox(
                  height: 176,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _CampaignCover(url: coverUrl),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x00000000), Color(0x990B0B0F)],
                          ),
                        ),
                      ),
                      Positioned(
                        top: 12,
                        left: 12,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: RamificaColors.rewardGold,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.bolt,
                                  size: 13,
                                  color: Color(0xFF221B00),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'EXCLUSIVE CHALLENGE',
                                  style: RamificaText.labelSM.copyWith(
                                    fontSize: 10,
                                    color: const Color(0xFF221B00),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      brand,
                      style: RamificaText.caption.copyWith(letterSpacing: 0.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      title,
                      style: RamificaText.headlineSM.copyWith(fontSize: 18),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            authorName,
                            style: RamificaText.meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        GestureDetector(
                          onTap: onOpen,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: RamificaColors.containerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Try',
                                    style: RamificaText.labelSM.copyWith(
                                      color: RamificaColors.hotspot,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(
                                    Icons.arrow_forward,
                                    size: 14,
                                    color: RamificaColors.hotspot,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
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

class _CampaignCover extends StatelessWidget {
  const _CampaignCover({required this.url});

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
