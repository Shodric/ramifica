import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Static "You are here" marker pinned above the current node card.
/// Shared by the story map and the create hub canvas.
class YouAreHerePill extends StatelessWidget {
  const YouAreHerePill({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [RamificaColors.hotspot, RamificaColors.nodeActive],
        ),
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [
          BoxShadow(color: RamificaColors.glowCyan, blurRadius: 16),
        ],
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Text(
          'You are here',
          style: TextStyle(
            fontFamily: RamificaText.sans,
            fontWeight: FontWeight.w700,
            fontSize: 10,
            height: 14 / 10,
            letterSpacing: 0.2,
            color: RamificaColors.onSecondary,
          ),
        ),
      ),
    );
  }
}
