import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Story-of-the-day hero card: cover, badges, creator, title, synopsis,
/// and a full-width gradient CTA. Pure: data in via params, tap out via
/// [onOpen]. No bloc, no router, no repository. No animations.
class ExploreHero extends StatelessWidget {
  const ExploreHero({
    super.key,
    required this.title,
    required this.creatorLabel,
    this.synopsis,
    this.coverUrl,
    this.onOpen,
  });

  final String title;
  final String creatorLabel;
  final String? synopsis;
  final String? coverUrl;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Story of the day $title',
      button: onOpen != null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: 400,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _HeroCover(url: coverUrl, title: title),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x66000000),
                      Color(0x00000000),
                      Color(0xFF131318),
                    ],
                    stops: [0.0, 0.45, 1.0],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Align(
                      alignment: Alignment.topLeft,
                      child: _StoryOfTheDayBadge(),
                    ),
                    const Spacer(),
                    Text(
                      creatorLabel,
                      style: RamificaText.meta.copyWith(
                        color: RamificaColors.textSecondary,
                        shadows: const [RamificaColors.videoShadow],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      style: RamificaText.headlineMD.copyWith(
                        shadows: const [RamificaColors.videoShadow],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    if ((synopsis ?? '').trim().isNotEmpty)
                      Text(
                        synopsis!.trim(),
                        style: RamificaText.bodySM.copyWith(
                          color: const Color(0xFFE4E1E9),
                          shadows: const [RamificaColors.videoShadow],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 12),
                    _CtaButton(onOpen: onOpen),
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

class _StoryOfTheDayBadge extends StatelessWidget {
  const _StoryOfTheDayBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCC0B0B0F),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: RamificaColors.hotspot,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'STORY OF THE DAY',
              style: RamificaText.labelSM.copyWith(
                color: RamificaColors.hotspot,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CtaButton extends StatelessWidget {
  const _CtaButton({required this.onOpen});

  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onOpen,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [RamificaColors.hotspot, RamificaColors.nodeActive],
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.play_arrow,
                color: RamificaColors.onSecondary,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                'Start Adventure',
                style: RamificaText.headlineSM.copyWith(
                  fontSize: 18,
                  color: RamificaColors.onSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroCover extends StatelessWidget {
  const _HeroCover({required this.url, required this.title});

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
      fit: BoxFit.cover,
      semanticLabel: 'Cover of $title',
      errorBuilder: (_, _, _) =>
          const ColoredBox(color: RamificaColors.nodeLocked),
    );
  }
}
