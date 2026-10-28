import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/features/profile/install_guide.dart';

/// Add-to-Home-Screen steps for non-installed iOS Safari. Renders nothing
/// ([SizedBox.shrink]) everywhere else. Tests inject [shouldShow] instead
/// of sniffing a user agent; production defaults to
/// [shouldShowInstallGuide]. Dismissing is local view state, not bloc.
class InstallGuideBanner extends StatefulWidget {
  const InstallGuideBanner({super.key, this.shouldShow});

  final bool Function()? shouldShow;

  @override
  State<InstallGuideBanner> createState() => _InstallGuideBannerState();
}

class _InstallGuideBannerState extends State<InstallGuideBanner> {
  var _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final show =
        !_dismissed && (widget.shouldShow?.call() ?? shouldShowInstallGuide());
    if (!show) return const SizedBox.shrink();
    return Semantics(
      key: const Key('installGuideBanner'),
      label: 'Install Ramifica',
      child: Card(
        color: RamificaColors.glass,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: RamificaColors.glassBorder),
          borderRadius: .circular(12),
        ),
        child: Padding(
          padding: const .all(12),
          child: Row(
            crossAxisAlignment: .start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: .start,
                  mainAxisSize: .min,
                  children: [
                    Text('Install Ramifica', style: RamificaText.label),
                    SizedBox(height: 4),
                    Text(
                      '1. Tap Share in Safari.\n'
                      '2. Choose Add to Home Screen.\n'
                      '3. Open Ramifica from your Home Screen.',
                      style: RamificaText.meta,
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const Key('installGuideDismiss'),
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => setState(() => _dismissed = true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
