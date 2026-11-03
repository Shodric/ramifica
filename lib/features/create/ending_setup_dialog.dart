import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/draft_node.dart';

/// English label per ending-type code, in [kEndingTypeCodes] order.
const endingTypeLabels = <String, String>{
  'open': 'Open',
  'tragic': 'Tragic',
  'secret': 'Secret',
  'heroic': 'Heroic',
  'mysterious': 'Mysterious',
  'bittersweet': 'Bittersweet',
  'dark': 'Dark',
  'epic': 'Epic',
  'incomplete': 'Incomplete',
};

/// Final-scene setup popup, opened by tapping the ending row in
/// [ZoneMarker]. Shows the badge preview (or a placeholder), the
/// ending-type picker, and a Generate button that runs [onBadgeRequested]
/// with a loader while it is in flight. Failures surface through the
/// shared snack owned by the caller — nothing renders inline here.
class EndingSetupDialog extends StatefulWidget {
  const EndingSetupDialog({
    super.key,
    required this.nodeId,
    this.endingType,
    this.endingBadgeUrl,
    this.onEndingTypeChanged,
    this.onBadgeRequested,
  });

  final String nodeId;
  final String? endingType;
  final String? endingBadgeUrl;

  /// Fires when the author picks a type code from the dropdown.
  final ValueChanged<String>? onEndingTypeChanged;

  /// Runs the badge generation; the Generate button shows a loader until
  /// the returned future completes.
  final Future<void> Function()? onBadgeRequested;

  @override
  State<EndingSetupDialog> createState() => _EndingSetupDialogState();
}

class _EndingSetupDialogState extends State<EndingSetupDialog> {
  var _generating = false;

  Future<void> _generate() async {
    final request = widget.onBadgeRequested;
    if (request == null || _generating) return;
    setState(() => _generating = true);
    try {
      await request();
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.endingType;
    return AlertDialog(
      title: const Text('Final scene'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: .stretch,
          mainAxisSize: .min,
          children: [
            _badgePreview(),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: const ValueKey('ending-type-dropdown'),
              initialValue: current != null && kEndingTypeCodes.contains(current)
                  ? current
                  : null,
              hint: const Text('Ending type'),
              items: [
                for (final code in kEndingTypeCodes)
                  DropdownMenuItem(
                    value: code,
                    child: Text(endingTypeLabels[code] ?? code),
                  ),
              ],
              onChanged: widget.onEndingTypeChanged == null
                  ? null
                  : (code) {
                      if (code != null) widget.onEndingTypeChanged!(code);
                    },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('ending-setup-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          key: const ValueKey('ending-badge-generate'),
          onPressed: widget.onBadgeRequested == null || _generating
              ? null
              : _generate,
          child: _generating
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Generate'),
        ),
      ],
    );
  }

  /// Badge preview: always a square box on the placeholder background,
  /// so the generated image sits on the same surface instead of floating
  /// bare, and [BoxFit.contain] shows it whole without cropping.
  Widget _badgePreview() {
    final url = widget.endingBadgeUrl;
    final hasImage = url != null && url.isNotEmpty;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: AspectRatio(
          aspectRatio: 1,
          child: Container(
            decoration: BoxDecoration(
              color: RamificaColors.containerBase,
              borderRadius: BorderRadius.circular(12),
            ),
            child: hasImage
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      key: const ValueKey('ending-badge-image'),
                      url,
                      fit: .contain,
                      errorBuilder: (_, _, _) => const Center(
                        key: ValueKey('ending-badge-error'),
                        child: Text(
                          'Badge unavailable.',
                          style: RamificaText.meta,
                        ),
                      ),
                    ),
                  )
                : const Center(
                    key: ValueKey('ending-badge-placeholder'),
                    child: Column(
                      mainAxisSize: .min,
                      children: [
                        Icon(
                          Icons.emoji_events_outlined,
                          size: 32,
                          color: RamificaColors.textSecondary,
                        ),
                        SizedBox(height: 8),
                        Text('No badge yet', style: RamificaText.meta),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
