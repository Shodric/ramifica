import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';

/// Future placeholders shown below the endings section.
///
/// One [GlassPanel] with two inert rows: the live room (Sala en vivo)
/// and the guild (Gremio). Rows are plain static widgets: no tap
/// handlers, no navigation, no repository or bloc calls, so they render
/// anywhere without extra providers.
class LaterBlock extends StatelessWidget {
  const LaterBlock({super.key});

  @override
  Widget build(BuildContext context) {
    return const GlassPanel(
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .stretch,
        children: [
          _LaterRow(
            key: Key('laterLiveRow'),
            icon: Icons.live_tv_outlined,
            title: 'Live room',
            soonLabel: 'Soon',
          ),
          SizedBox(height: 12),
          _LaterRow(
            key: Key('laterGuildRow'),
            icon: Icons.groups_outlined,
            title: 'Guild',
            soonLabel: 'Later',
          ),
        ],
      ),
    );
  }
}

class _LaterRow extends StatelessWidget {
  const _LaterRow({
    super.key,
    required this.icon,
    required this.title,
    required this.soonLabel,
  });

  final IconData icon;
  final String title;
  final String soonLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: RamificaColors.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(title, style: RamificaText.body),
        ),
        const SizedBox(width: 12),
        Text(
          soonLabel,
          style: RamificaText.meta.copyWith(
            color: RamificaColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
