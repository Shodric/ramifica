import 'package:ramifica/core/warm_slot.dart';

/// VM and tests. The browser build mounts a hidden video element.
WarmSlot createWarmSlot() => _IdleWarmSlot();

class _IdleWarmSlot implements WarmSlot {
  @override
  void mount(String url) {}

  @override
  void dispose() {}
}
