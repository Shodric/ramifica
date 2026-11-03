import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Full-width mic bar shared by S0 (premise) and S1 (script direction).
/// Idle shows a centered mic and label. Recording fills the same bar
/// with a stop mark, live waves, and the timer. A null [onTap] dims the
/// bar to its disabled look instead of only dropping taps.
///
/// Keys derive from [prefix]: `$prefix-voice-fab`, `$prefix-voice-stop`,
/// `$prefix-voice-waves`, `$prefix-voice-timer`. The premise passes
/// `premise` so its long-standing keys never change.
class DictationVoiceBar extends StatelessWidget {
  const DictationVoiceBar({
    super.key,
    required this.prefix,
    required this.label,
    required this.recording,
    required this.waves,
    required this.elapsed,
    required this.onTap,
  });

  final String prefix;
  final String label;
  final bool recording;
  final List<double> waves;
  final Duration elapsed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mm = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return AnimatedOpacity(
      opacity: onTap == null ? 0.38 : 1,
      duration: const Duration(milliseconds: 200),
      child: GestureDetector(
        key: ValueKey('$prefix-voice-fab'),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 56,
          width: double.infinity,
          clipBehavior: Clip.hardEdge,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: recording
                ? RamificaColors.error
                : RamificaColors.containerHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: RamificaColors.hotspot),
          ),
          child: recording
              ? Row(
                  children: [
                    const SizedBox(width: 16),
                    Container(
                      key: ValueKey('$prefix-voice-stop'),
                      width: 24,
                      height: 24,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.all(Radius.circular(4)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: CustomPaint(
                        key: ValueKey('$prefix-voice-waves'),
                        painter: DictationWavesPainter(waves),
                        child: const SizedBox(height: 32),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '$mm:$ss',
                      key: ValueKey('$prefix-voice-timer'),
                      style: RamificaText.labelSM.copyWith(color: Colors.white),
                    ),
                    const SizedBox(width: 16),
                  ],
                )
              : Row(
                  mainAxisAlignment: .center,
                  mainAxisSize: .min,
                  children: [
                    const Icon(Icons.mic, color: RamificaColors.textPrimary),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label,
                        style: RamificaText.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Live mic waves: one bar per recent level sample, suite cyan.
class DictationWavesPainter extends CustomPainter {
  const DictationWavesPainter(this.waves);

  final List<double> waves;

  @override
  void paint(Canvas canvas, Size size) {
    if (waves.isEmpty) return;
    final paint = Paint()..color = RamificaColors.hotspot;
    final barWidth = size.width / 40;
    for (var i = 0; i < waves.length; i++) {
      final height = (waves[i].clamp(0, 1) * size.height).clamp(
        2.0,
        size.height,
      );
      final x = size.width - (waves.length - i) * barWidth;
      canvas.drawRect(
        Rect.fromLTWH(x, (size.height - height) / 2, barWidth * 0.6, height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(DictationWavesPainter old) => old.waves != waves;
}
