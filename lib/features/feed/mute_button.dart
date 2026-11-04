import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Mutes the clip and the narrator together.
///
/// A right-rail action like the like, comment, and save buttons: the same
/// 44 px circle, the same label underneath, and a constant height. While
/// [autoMuted], the ring glows so the control reads as the way to turn
/// sound on.
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
    final tooltip = autoMuted
        ? 'Turn sound on'
        : muted
        ? 'Unmute'
        : 'Mute';
    final label = autoMuted
        ? 'Sound'
        : muted
        ? 'Unmute'
        : 'Mute';
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onPressed,
          child: Column(
            mainAxisSize: .min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xD82A292F),
                  border: Border.all(
                    color: autoMuted
                        ? const Color(0x4D00F2FE)
                        : const Color(0x1AFFFFFF),
                  ),
                  boxShadow: autoMuted
                      ? const [
                          BoxShadow(color: Color(0x6600F2FE), blurRadius: 14),
                        ]
                      : null,
                ),
                child: Icon(
                  muted ? Icons.volume_off_outlined : Icons.volume_up_outlined,
                  color: RamificaColors.textPrimary,
                  size: 24,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: RamificaText.overVideo(
                  RamificaText.caption.copyWith(
                    color: RamificaColors.textPrimary,
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
