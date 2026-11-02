import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/draft_node.dart';

/// Fixed card geometry. The canvas centers every card on its layout
/// position, so constant size keeps edges, minis, and the minimap exact.
const createCardWidth = 170.0;
const createCardHeight = 240.0;

/// Stitch-style node card on the draft canvas: thumbnail (or empty
/// placeholder), title, and status badges. Taps select.
/// Durations render as plain media facts only — never triggers or countdowns.
class CreateNodeCard extends StatelessWidget {
  const CreateNodeCard({
    super.key,
    required this.node,
    required this.sceneIndex,
    this.slotPath = '',
    required this.isRoot,
    required this.isOpen,
    required this.isOrphan,
    required this.onTap,
  });

  final DraftNode node;
  final int sceneIndex;

  /// Branch path from the root (`A`, `ABA`...). Appended to the scene
  /// label; empty shows the plain `Scene N`.
  final String slotPath;
  final bool isRoot;
  final bool isOpen;
  final bool isOrphan;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumbnail = node.videoFrameLastUrl ?? node.startImageSourceUrl;
    final title = node.title.trim().isEmpty ? '(untitled)' : node.title.trim();
    final dim = isOrphan ? 0.45 : 1.0;
    return Opacity(
      opacity: dim,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: createCardWidth,
          height: createCardHeight,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isOpen
                  ? RamificaColors.hotspot
                  : isOrphan
                  ? RamificaColors.textSecondary.withValues(alpha: 0.5)
                  : RamificaColors.outlineVariant,
              width: isOpen ? 2 : 1.5,
            ),
            boxShadow: isOpen
                ? const [
                    BoxShadow(color: RamificaColors.glowCyan, blurRadius: 16),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: .stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: .expand,
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(13),
                      ),
                      child: Container(
                        color: RamificaColors.containerHigh,
                        child: CreateNodeThumb(url: thumbnail),
                      ),
                    ),
                    if (isOpen)
                      const Positioned(
                        top: 6,
                        left: 6,
                        child: _Pill('Editing'),
                      ),
                    if (isRoot)
                      const Positioned(
                        top: 6,
                        right: 6,
                        child: _Pill('Root Node'),
                      ),
                  ],
                ),
              ),
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(13),
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: Container(
                    color: RamificaColors.containerHigh.withValues(alpha: 0.65),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Column(
                      mainAxisSize: .min,
                      crossAxisAlignment: .start,
                      children: [
                        Text(
                          slotPath.isEmpty
                              ? 'Scene $sceneIndex'
                              : 'Scene $sceneIndex - $slotPath',
                          style: RamificaText.caption.copyWith(
                            color: RamificaColors.textSecondary,
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: .ellipsis,
                                style: RamificaText.body.copyWith(
                                  color: RamificaColors.textPrimary,
                                ),
                              ),
                            ),
                            if (node.secret)
                              const Padding(
                                padding: EdgeInsets.only(left: 4),
                                child: Icon(
                                  Icons.lock_outline,
                                  size: 12,
                                  color: RamificaColors.textSecondary,
                                ),
                              ),
                          ],
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
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    // Blur only behind the pill text, leaving the thumbnail sharp.
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: RamificaColors.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: RamificaColors.hotspot),
          ),
          child: Text(
            label,
            style: RamificaText.caption.copyWith(
              color: RamificaColors.textPrimary,
              fontSize: 10,
            ),
          ),
        ),
      ),
    );
  }
}

/// Square-ish node thumbnail with the empty placeholder fallback. Shared
/// by the canvas card and the HUD active card so both stay identical.
class CreateNodeThumb extends StatelessWidget {
  const CreateNodeThumb({super.key, required this.url, this.iconSize = 20});

  final String? url;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return Container(
        color: RamificaColors.inputFill,
        child: Icon(
          Icons.image_outlined,
          size: iconSize,
          color: RamificaColors.textSecondary,
        ),
      );
    }
    return Image.network(
      url!,
      fit: .cover,
      errorBuilder: (_, _, _) => Container(
        color: RamificaColors.inputFill,
        child: Icon(
          Icons.image_outlined,
          size: iconSize,
          color: RamificaColors.textSecondary,
        ),
      ),
    );
  }
}
