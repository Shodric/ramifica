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
        Text(label, style: RamificaText.labelSM),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 9 / 16,
          child: url == null
              ? Container(
                  decoration: const BoxDecoration(
                    color: RamificaColors.inputFill,
                    borderRadius: RamificaLayout.cardBorderRadius,
                    border: Border.fromBorderSide(RamificaColors.inputBorder),
                  ),
                  child: const Center(
                    child: Text('Missing', style: RamificaText.caption),
                  ),
                )
              : Container(
                  decoration: const BoxDecoration(
                    borderRadius: RamificaLayout.cardBorderRadius,
                    border: Border.fromBorderSide(RamificaColors.inputBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 16,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: RamificaLayout.cardBorderRadius,
                    child: Image.network(
                      url,
                      fit: .cover,
                      errorBuilder: (_, _, _) => Container(
                        color: RamificaColors.inputFill,
                        child: const Center(
                          child: Text('Missing', style: RamificaText.caption),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
