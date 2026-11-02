import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Stitch-style canvas ribbon: close + story title with the Settings
/// and Publish actions. The Publish CTA disables while the draft has
/// missing items. Zoom and recenter float over the canvas instead.
/// All copy is final EN — no hold, timing, or tap-to-choose affordances.
class CreateRibbon extends StatelessWidget {
  const CreateRibbon({
    super.key,
    required this.title,
    required this.onSettings,
    required this.onPublish,
    required this.canPublish,
    required this.onClose,
  });

  final String title;
  final VoidCallback onSettings;
  final VoidCallback? onPublish;

  /// Publish CTA enabled exactly when the draft has no missing items and
  /// no job is running.
  final bool canPublish;

  /// Leaves the fullscreen canvas back to Explore.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          key: const ValueKey('ribbon-close'),
          tooltip: 'Back to Create',
          onPressed: onClose,
          icon: const Icon(Icons.close, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title.isEmpty ? 'Create' : title,
            maxLines: 1,
            overflow: .ellipsis,
            style: RamificaText.headlineSM.copyWith(fontSize: 18),
          ),
        ),
        IconButton(
          key: const ValueKey('ribbon-settings'),
          tooltip: 'Story settings',
          onPressed: onSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
        const SizedBox(width: 8),
        _PublishButton(onPressed: canPublish ? onPublish : null),
      ],
    );
  }
}

class _PublishButton extends StatelessWidget {
  const _PublishButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: onPressed == null
            ? null
            : const LinearGradient(
                colors: [RamificaColors.nodeActive, RamificaColors.brandViolet],
              ),
      ),
      child: ElevatedButton(
        key: const ValueKey('ribbon-publish'),
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          disabledBackgroundColor: RamificaColors.inputFill,
        ),
        child: const Text('Publish'),
      ),
    );
  }
}
