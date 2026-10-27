import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

class EmptyState extends StatelessWidget {
  final String message;

  final String? actionLabel;
  final VoidCallback? onAction;
  const EmptyState({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: .min,
      children: [
        Text(message, style: RamificaText.body, textAlign: .center),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 16),
          FilledButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ],
    );
  }
}
