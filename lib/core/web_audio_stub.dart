import 'package:ramifica/core/narrator.dart';

/// VM and tests. The browser build uses Web Audio.
Narrator createNarrator() => _IdleNarrator();

class _IdleNarrator implements Narrator {
  @override
  Future<void> prepare(String url) async {}

  @override
  void unlock() {}

  @override
  Future<bool> play({required void Function() onEnded}) async => false;

  @override
  void stop() {}

  @override
  void dispose() {}
}
