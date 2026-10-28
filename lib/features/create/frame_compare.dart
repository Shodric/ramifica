import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Side-by-side S-vs-E comparison. STATIC: two images plus labels, no
/// animation or sliders, so tests can pumpAndSettle freely.
///
/// [startImageUrl] is the S frame (the root's own S, or the inherited
/// parent E on other nodes); [endImageUrl] is this node's E. Either may
/// be null while its frame is missing or still generating.
class FrameCompare extends StatelessWidget {
  const FrameCompare({super.key, this.startImageUrl, this.endImageUrl});

  final String? startImageUrl;
  final String? endImageUrl;

  @override
  Widget build(BuildContext context) {
    if (startImageUrl == null && endImageUrl == null) {
      return const Text('No frames yet.', style: RamificaText.meta);
    }
    return Row(
      crossAxisAlignment: .start,
      children: [
        Expanded(
          child: _Frame(label: 'Start', imageUrl: startImageUrl),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _Frame(label: 'End', imageUrl: endImageUrl),
        ),
      ],
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.label, this.imageUrl});

  final String label;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        Text(label, style: RamificaText.meta),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 9 / 16,
          child: url == null
              ? Container(
                  decoration: BoxDecoration(
                    color: RamificaColors.glass,
                    borderRadius: .circular(8),
                    border: .all(color: RamificaColors.glassBorder),
                  ),
                  child: const Center(
                    child: Text('Missing', style: RamificaText.meta),
                  ),
                )
              : ClipRRect(
                  borderRadius: .circular(8),
                  child: Image.network(
                    url,
                    fit: .cover,
                    errorBuilder: (_, _, _) => Container(
                      color: RamificaColors.glass,
                      child: const Center(
                        child: Text('Missing', style: RamificaText.meta),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
