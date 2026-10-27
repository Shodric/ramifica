import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';

/// Mutes the clip and the narrator together.
///
/// While [autoMuted], the control reads as the way to turn sound on.
class MuteButton extends StatelessWidget {
  const MuteButton({
    super.key,
    required this.muted,
    required this.autoMuted,
    required this.onPressed,
  });

  final bool muted;
  final bool autoMuted;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = autoMuted
        ? 'Turn sound on'
        : muted
        ? 'Unmute'
        : 'Mute';
    return Semantics(
      button: true,
      label: label,
      child: GlassPanel(
        padding: const .all(4),
        borderRadius: const .all(.circular(999)),
        child: Column(
          mainAxisSize: .min,
          children: [
            IconButton(
              tooltip: label,
              onPressed: onPressed,
              icon: Icon(
                muted ? Icons.volume_off_outlined : Icons.volume_up_outlined,
                color: RamificaColors.textPrimary,
              ),
            ),
            if (autoMuted)
              Padding(
                padding: const .only(bottom: 6),
                child: Text(
                  'Sound',
                  style: RamificaText.overVideo(RamificaText.meta),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
