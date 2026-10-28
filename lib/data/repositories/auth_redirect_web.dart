import 'dart:js_interop';

import 'package:ramifica/data/repositories/auth_repository.dart';

@JS('navigator.userAgent')
external String get _navigatorUserAgent;

@JS('navigator.standalone')
external JSBoolean? get _navigatorStandalone;

@JS('window.matchMedia')
external _MediaQueryList _matchMedia(String query);

extension type _MediaQueryList._(JSObject _) implements JSObject {
  external bool get matches;
}

bool currentPagePrefersGoogleRedirect() {
  final displayMode = _matchMedia('(display-mode: standalone)').matches;
  final iosStandalone = _navigatorStandalone?.toDart ?? false;
  return googleRedirectOnIosPwa(
    userAgent: _navigatorUserAgent,
    standalone: displayMode || iosStandalone,
  );
}
