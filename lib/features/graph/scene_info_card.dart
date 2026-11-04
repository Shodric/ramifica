import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/choice_icon.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';
import 'package:ramifica/data/models/graph_stub.dart';

/// Selected scene card: the scene name over one line split by option
/// share. Each segment grows from its side's icon in the icon's color;
/// the labels read the complementary percents.
class SceneInfoCard extends StatelessWidget {
  const SceneInfoCard({super.key, required this.stub, this.onPlay});

  final GraphStub stub;

  /// Plays the scene. Null disables the button (locked scenes).
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final choices = stub.choices;
    final a = choices.isNotEmpty ? choices[0] : null;
    final b = choices.length > 1 ? choices[1] : null;
    final countA = a?.count ?? 0;
    final countB = b?.count ?? 0;
    final total = countA + countB;
    final pctA = total <= 0 ? 0 : (countA * 100 / total).round();
    final pctB = total <= 0 ? 0 : 100 - pctA;
    final colorA = a == null
        ? RamificaColors.containerHighest
        : choiceIconColor(a.iconColor, RamificaColors.hotspot);
    final colorB = b == null
        ? RamificaColors.containerHighest
        : choiceIconColor(b.iconColor, RamificaColors.nodeActive);
    final rawTitle = stub.title?.trim() ?? '';
    return GlassPanel(
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  rawTitle.isEmpty ? '(untitled)' : rawTitle,
                  maxLines: 2,
                  overflow: .ellipsis,
                  style: RamificaText.screenTitle.copyWith(
                    fontSize: 20,
                    height: 26 / 20,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _PlayButton(onPlay: onPlay),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('$pctA%', style: RamificaText.meta),
              const SizedBox(width: 6),
              _OptionBadge(
                iconName: a?.icon,
                color: colorA,
                index: 0,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _SplitLine(
                  countA: countA,
                  countB: countB,
                  colorA: colorA,
                  colorB: colorB,
                ),
              ),
              const SizedBox(width: 6),
              _OptionBadge(
                iconName: b?.icon,
                color: colorB,
                index: 1,
              ),
              const SizedBox(width: 6),
              Text('$pctB%', style: RamificaText.meta),
            ],
          ),
        ],
      ),
    );
  }
}

/// Play button on the far end of the scene title. Null [onPlay] shows
/// the disabled ghost so locked scenes stay visibly unplayable.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.onPlay});

  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPlay,
      tooltip: 'Play scene',
      style: IconButton.styleFrom(
        backgroundColor: RamificaColors.hotspot,
        disabledBackgroundColor: RamificaColors.containerHighest,
        foregroundColor: const Color(0xFF00373A),
        disabledForegroundColor: RamificaColors.textSecondary,
        shape: const CircleBorder(),
      ),
      icon: const Icon(Icons.play_arrow_rounded),
    );
  }
}

/// Choice glyph in its color, mirroring the canvas edge badges.
class _OptionBadge extends StatelessWidget {
  const _OptionBadge({
    required this.iconName,
    required this.color,
    required this.index,
  });

  final String? iconName;
  final Color color;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: RamificaColors.containerLowest.withValues(alpha: 0.9),
          width: 2,
        ),
      ),
      child: Icon(
        choiceIconData(iconName, index),
        size: 14,
        color: color.computeLuminance() > 0.6
            ? Colors.black87
            : Colors.white,
      ),
    );
  }
}

/// One line split by share. A side with no plays collapses so the
/// other fills the track; with no plays at all the track stays neutral.
class _SplitLine extends StatelessWidget {
  const _SplitLine({
    required this.countA,
    required this.countB,
    required this.colorA,
    required this.colorB,
  });

  final int countA;
  final int countB;
  final Color colorA;
  final Color colorB;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 6,
        child: countA + countB <= 0
            ? const ColoredBox(color: RamificaColors.containerHighest)
            : countA <= 0
            ? ColoredBox(color: colorB)
            : countB <= 0
            ? ColoredBox(color: colorA)
            : Row(
                // Stretch, not center: a childless ColoredBox collapses
                // to zero height on a loose cross axis, hiding the
                // split everywhere except the single-color cases.
                crossAxisAlignment: .stretch,
                children: [
                  Expanded(
                    flex: countA,
                    child: ColoredBox(color: colorA),
                  ),
                  Expanded(
                    flex: countB,
                    child: ColoredBox(color: colorB),
                  ),
                ],
              ),
      ),
    );
  }
}
