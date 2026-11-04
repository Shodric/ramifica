import 'package:flutter/material.dart';
import 'package:ramifica/data/models/playback.dart';

/// Vertical reel pager. [reels] is every published story loaded so far.
/// Each child is a page the parent already built: blur, title, rail, and
/// a paused player. [allowImplicitScrolling] keeps the previous page and
/// the next one alive, so a drag uncovers a view instead of an empty
/// surface.
///
/// With two or more reels the list loops. A copy of the last reel sits
/// before the first, and a copy of the first sits after the last. Landing
/// on a copy jumps, without animation, to the real page of that same
/// story. One reel does not loop.
///
/// Finger up moves to the next page, finger down to the previous one.
/// [onSettled] runs when a page lands. It returns false when the bloc
/// rejects the move; the pager then snaps back to [index].
class StoryPager extends StatefulWidget {
  const StoryPager({
    super.key,
    required this.reels,
    required this.index,
    required this.paging,
    required this.onSettled,
    required this.pageBuilder,
  });

  final List<Playback> reels;
  final int index;
  final bool paging;
  final bool Function(int index) onSettled;

  /// [loop] is true for the copies parked outside the real list.
  final Widget Function(Playback playback, bool active, bool loop) pageBuilder;

  @override
  State<StoryPager> createState() => _StoryPagerState();
}

class _StoryPagerState extends State<StoryPager> {
  PageController? _controller;
  var _jumping = false;

  bool get _loops => widget.reels.length >= 2;

  int _slotCount(int length) => length < 2 ? length : length + 2;

  /// Real pages sit one slot in when the list loops, so slot 0 can hold
  /// the copy of the last reel.
  int _slotOf(int logical) => _loops ? logical + 1 : logical;

  bool _isLoopCopy(int page) {
    if (!_loops) return false;
    return page <= 0 || page >= widget.reels.length + 1;
  }

  int _logicalOf(int page) {
    final count = widget.reels.length;
    if (count < 2) return page;
    if (page <= 0) return count - 1;
    if (page >= count + 1) return 0;
    return page - 1;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _replaceController(int page) {
    final previous = _controller;
    _controller = PageController(initialPage: page);
    if (previous == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previous.dispose();
    });
  }

  void _jumpTo(int page) {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;
    if (controller.page?.round() == page) return;
    _jumping = true;
    controller.jumpToPage(page);
    _jumping = false;
  }

  @override
  void didUpdateWidget(StoryPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasLoop = oldWidget.reels.length >= 2;
    if (wasLoop != _loops) {
      _replaceController(_slotOf(widget.index));
      return;
    }
    if (oldWidget.index != widget.index) _jumpTo(_slotOf(widget.index));
  }

  /// Copies commit when the scroll stops. Committing at the halfway
  /// mark would teleport the page while the finger is still down.
  bool _onScrollEnd(ScrollNotification notification) {
    if (_jumping || notification.depth != 0) return false;
    if (notification is! ScrollEndNotification) return false;
    final metrics = notification.metrics;
    if (metrics is! PageMetrics || metrics.page == null) return false;
    final page = metrics.page!.round();
    if (!_isLoopCopy(page)) return false;
    final logical = _logicalOf(page);
    if (!widget.onSettled(logical)) {
      _jumpTo(_slotOf(widget.index));
      return false;
    }
    _jumpTo(_slotOf(logical));
    return false;
  }

  void _onPageChanged(int page) {
    if (_jumping || _isLoopCopy(page)) return;
    final logical = _logicalOf(page);
    if (widget.onSettled(logical)) return;
    _jumpTo(_slotOf(widget.index));
  }

  @override
  Widget build(BuildContext context) {
    final reels = widget.reels;
    _controller ??= PageController(initialPage: _slotOf(widget.index));
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollEnd,
      child: PageView.builder(
        // A new scroll position when the loop turns on, so the open reel
        // stays under the finger. Reusing the old offset would show the
        // copy that now sits at slot 0.
        key: ValueKey(_loops),
        scrollDirection: .vertical,
        allowImplicitScrolling: true,
        controller: _controller,
        physics: widget.paging
            ? const PageScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        itemCount: _slotCount(reels.length),
        onPageChanged: _onPageChanged,
        itemBuilder: (context, page) {
          final playback = reels[_logicalOf(page)];
          final loop = _isLoopCopy(page);
          final id = playback.story.storyId;
          return KeyedSubtree(
            key: ValueKey(loop ? '$id#loop$page' : id),
            child: widget.pageBuilder(
              playback,
              page == _slotOf(widget.index),
              loop,
            ),
          );
        },
      ),
    );
  }
}
