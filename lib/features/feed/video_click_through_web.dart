import 'package:web/web.dart' as web;

/// Lets taps fall through the player's `<video>` elements to Flutter.
///
/// On web the player renders a native video element that swallows taps
/// landing on bare video areas, so the feed's tap-to-pause (and swipes)
/// never reach the framework. Only taps over Flutter-rendered overlays
/// (hotspots, rail, chips) arrive, because those target framework
/// elements first. Styling every video element click-through hands
/// bare-area taps to Flutter's hit test, where the feed's own
/// GestureDetector owns them. Re-run per video: each opened clip mounts
/// a new element.
void makeVideosClickThrough() {
  final videos = web.document.querySelectorAll('video');
  for (var i = 0; i < videos.length; i++) {
    // A 'video' selector only ever matches video elements, which are
    // always HTML elements; the static type just doesn't know it.
    (videos.item(i)! as web.HTMLElement).style.pointerEvents = 'none';
  }
}
