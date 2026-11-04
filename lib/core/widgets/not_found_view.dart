import 'package:flutter/material.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/theme.dart';

/// Full-screen 404. The button opens the feed at `/`.
class NotFoundView extends StatelessWidget {
  const NotFoundView({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: RamificaColors.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: .symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: .min,
              children: [
                Text(
                  '404',
                  style: TextStyle(
                    fontFamily: RamificaText.display,
                    fontWeight: .w700,
                    fontSize: 40,
                    height: 44 / 40,
                    letterSpacing: -0.4,
                    color: RamificaColors.hotspot,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'This page does not exist.',
                  style: RamificaText.screenTitle,
                  textAlign: .center,
                ),
                SizedBox(height: 8),
                Text(
                  'That link does not open a story.',
                  style: TextStyle(
                    fontFamily: RamificaText.sans,
                    fontWeight: .w400,
                    fontSize: 16,
                    height: 24 / 16,
                    color: RamificaColors.textSecondary,
                  ),
                  textAlign: .center,
                ),
                SizedBox(height: 24),
                _FeedButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedButton extends StatelessWidget {
  const _FeedButton();

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: () {
        try {
          AppNavigation.read(context).go(AppRoutes.feed);
        } on FlutterError {
          // Widget tests mount the page without the router.
        }
      },
      child: const Text('Go to the feed'),
    );
  }
}
