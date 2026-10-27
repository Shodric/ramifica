/// One hidden media element. [Prefetcher] owns it.
abstract class WarmSlot {
  void mount(String url);

  void dispose();
}
