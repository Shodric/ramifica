import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// App-styled floating snackbars: one dark container, one accent icon,
/// no stacking (a new message replaces the current one).
void showErrorSnackBar(BuildContext context, String message) {
  _showAppSnackBar(
    context,
    message,
    icon: Icons.error_outline,
    iconColor: RamificaColors.error,
  );
}

/// Neutral variant for notices that are not failures (limits reached,
/// background work done).
void showNoticeSnackBar(BuildContext context, String message) {
  _showAppSnackBar(
    context,
    message,
    icon: Icons.info_outline,
    iconColor: RamificaColors.nodeActive,
  );
}

void _showAppSnackBar(
  BuildContext context,
  String message, {
  required IconData icon,
  required Color iconColor,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          crossAxisAlignment: .start,
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, style: RamificaText.bodySM),
            ),
          ],
        ),
        backgroundColor: RamificaColors.containerHigh,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: RamificaColors.outline),
        ),
        duration: const Duration(seconds: 4),
      ),
    );
}
