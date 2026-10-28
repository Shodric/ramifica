import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// A lock with no title. Map and saga locks share it: locked content
/// never leaks a title, thumbnail, or label, just the mark.
/// Pure: no bloc, no router, no repository.
class LockMark extends StatelessWidget {
  const LockMark({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        color: RamificaColors.nodeLocked,
        shape: .circle,
      ),
      child: Padding(
        padding: EdgeInsets.all(10),
        child: Icon(
          Icons.lock,
          size: 20,
          color: RamificaColors.textSecondary,
          semanticLabel: 'Locked',
        ),
      ),
    );
  }
}
