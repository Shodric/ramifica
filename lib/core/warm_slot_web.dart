import 'package:ramifica/core/warm_slot.dart';
import 'package:web/web.dart';

/// Hidden `<video preload="auto" muted>`. The browser HTTP cache keeps the
/// bytes for [NodeVideo]. This element never plays.
WarmSlot createWarmSlot() => HtmlWarmSlot();

class HtmlWarmSlot implements WarmSlot {
  HTMLVideoElement? _video;

  @override
  void mount(String url) {
    final video = HTMLVideoElement()
      ..preload = 'auto'
      ..muted = true
      ..controls = false
      ..playsInline = true
      ..src = url;
    video.style.setProperty('display', 'none');
    document.body?.append(video);
    video.load();
    _video = video;
  }

  @override
  void dispose() {
    final video = _video;
    _video = null;
    if (video == null) return;
    video.pause();
    video.removeAttribute('src');
    video.load();
    video.remove();
  }
}
