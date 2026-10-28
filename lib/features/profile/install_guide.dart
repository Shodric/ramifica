import 'install_guide_stub.dart'
    if (dart.library.js_interop) 'install_guide_web.dart'
    as engine;

/// True only on non-installed iOS Safari (web). Desktop, Android,
/// installed PWAs, and unit tests all read false.
bool shouldShowInstallGuide() => engine.shouldShowInstallGuide;

/// Pure decision behind [shouldShowInstallGuide]: an iOS Safari page that
/// is not installed. Browser-free so widget tests fake the banner outright
/// instead of sniffing a user agent.
bool shouldShowInstallGuideFor({
  required String userAgent,
  required bool installed,
}) {
  if (installed) return false;
  final ios =
      userAgent.contains('iPhone') ||
      userAgent.contains('iPad') ||
      userAgent.contains('iPod');
  if (!ios) return false;
  if (!userAgent.contains('Safari')) return false;
  // Chrome, Firefox, and Edge on iOS all carry their own token next to
  // Safari and already offer their own install affordance.
  if (userAgent.contains('CriOS') ||
      userAgent.contains('FxiOS') ||
      userAgent.contains('EdgiOS')) {
    return false;
  }
  return true;
}
