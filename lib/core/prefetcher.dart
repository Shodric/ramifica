import 'package:ramifica/core/warm_slot.dart';
import 'package:ramifica/core/warm_slot_stub.dart'
    if (dart.library.js_interop) 'package:ramifica/core/warm_slot_web.dart';
import 'package:ramifica/data/models/playback.dart';

/// Warms mp4 URLs in the browser HTTP cache. Not a bloc.
///
/// The current clip and up to two non-secret destinations stay mounted.
/// A secret target is skipped. Changing story drops the previous queue.
class Prefetcher {
  Prefetcher({WarmSlot Function()? open}) : _open = open ?? createWarmSlot;

  static const cap = 3;

  final WarmSlot Function() _open;
  final List<_Slot> _slots = [];

  String? storyId;

  /// Oldest first. The current clip is never the one a full queue drops.
  List<String> get urls => [for (final slot in _slots) slot.url];

  void warm(Playback playback) {
    if (storyId != playback.story.storyId) _dropAll();
    storyId = playback.story.storyId;
    final current = playback.node.videoUrl.trim();
    if (current.isEmpty) return;
    final wanted = <String>[current];
    for (final choice in playback.choices) {
      if (choice.targetSecret) continue;
      final url = choice.target?.videoUrl.trim();
      if (url == null || url.isEmpty || wanted.contains(url)) continue;
      wanted.add(url);
    }
    for (final url in wanted) {
      _ensure(url);
    }
    _evict(keeping: current);
  }

  /// Moves one destination to the newest slot so the cap drops another.
  void promote(String url) {
    final index = _slots.indexWhere((slot) => slot.url == url);
    if (index < 0 || index == _slots.length - 1) return;
    _slots.add(_slots.removeAt(index));
  }

  void clear() {
    _dropAll();
    storyId = null;
  }

  void dispose() => clear();

  void _ensure(String url) {
    if (_slots.any((slot) => slot.url == url)) return;
    final slot = _open();
    try {
      slot.mount(url);
    } catch (_) {
      slot.dispose();
      return;
    }
    _slots.add(_Slot(url, slot));
  }

  void _evict({required String keeping}) {
    while (_slots.length > cap) {
      final index = _slots.indexWhere((slot) => slot.url != keeping);
      if (index < 0) return;
      _slots.removeAt(index).warm.dispose();
    }
  }

  void _dropAll() {
    for (final slot in _slots) {
      slot.warm.dispose();
    }
    _slots.clear();
  }
}

class _Slot {
  const _Slot(this.url, this.warm);

  final String url;
  final WarmSlot warm;
}
