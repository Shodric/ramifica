import 'dart:js_interop';

import 'package:ramifica/data/repositories/pending_story_store.dart';

@JS('sessionStorage')
extension type _SessionStorage._(JSObject _) implements JSObject {
  external String? getItem(String key);

  external void setItem(String key, String value);

  external void removeItem(String key);
}

@JS('sessionStorage')
external _SessionStorage get _sessionStorage;

class SessionPendingStoryStore implements PendingStoryStore {
  static const key = 'pendingStoryId';

  @override
  String? read() {
    final value = _sessionStorage.getItem(key);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  @override
  void write(String storyId) => _sessionStorage.setItem(key, storyId);

  @override
  void clear() => _sessionStorage.removeItem(key);
}

PendingStoryStore createPlatformPendingStoryStore() {
  return SessionPendingStoryStore();
}
