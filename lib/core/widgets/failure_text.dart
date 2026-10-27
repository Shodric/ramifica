import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

class FailureText extends StatelessWidget {
  const FailureText({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: .min,
      children: [
        Text(
          message,
          style: RamificaText.body.copyWith(color: RamificaColors.error),
          textAlign: .center,
        ),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}
