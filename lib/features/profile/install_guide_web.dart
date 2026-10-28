import 'dart:js_interop';

import 'install_guide.dart' show shouldShowInstallGuideFor;

@JS('navigator.userAgent')
external String get _userAgent;

@JS('navigator.standalone')
external JSBoolean? get _standalone;

@JS('window.matchMedia')
external _MediaQueryList _matchMedia(String query);

extension type _MediaQueryList._(JSObject _) implements JSObject {
  external bool get matches;
}

/// iOS Safari without an installed PWA. Installed means either the
/// standalone display-mode query or `navigator.standalone` agrees.
bool get shouldShowInstallGuide {
  try {
    final standalone =
        _matchMedia('(display-mode: standalone)').matches ||
        (_standalone?.toDart ?? false);
    return shouldShowInstallGuideFor(
      userAgent: _userAgent,
      installed: standalone,
    );
  } catch (_) {
    return false;
  }
}
