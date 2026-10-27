import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/features/feed/choice_zone.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:ramifica/features/feed/hold_portal.dart';
import 'package:ramifica/features/feed/mute_button.dart';
import 'package:ramifica/features/feed/node_video.dart';
import 'package:ramifica/features/feed/story_chip.dart';
import 'package:ramifica/features/feed/subtitle_line.dart';
import 'package:ramifica/features/feed/video_frame.dart';

class FeedView extends StatefulWidget {
  const FeedView({super.key, this.storyId, this.clipPlayer});

  final String? storyId;

  /// Test double for [NodeVideo]. Production leaves this null.
  final ClipPlayer? clipPlayer;

  @override
  State<FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends State<FeedView> {
  /// Pointer id of the finger holding a zone. Written on down and read on
  /// release, both synchronously, so a quick tap is never missed between
  /// frames. Cleared on release. If a future slice leaves `holding` without
  /// a release (a swipe mid-hold), it must clear this too.
  int? _pointer;

  @override
  Widget build(BuildContext context) {
    final bloc = _feedOf(context, listen: true);
    if (bloc == null) {
      return Scaffold(
        body: Semantics(
          label: widget.storyId == null ? 'Feed' : 'Feed ${widget.storyId}',
          child: const Center(child: Text('Feed')),
        ),
      );
    }
    return BlocBuilder<FeedBloc, FeedState>(
      bloc: bloc,
      builder: (context, state) {
        final playback = state.playback;
        final showClip =
            playback != null &&
            state.phase != .loading &&
            state.phase != .failed;
        final line = playback?.node.ttsText?.trim();
        final showLine =
            state.phase == .speaking &&
            state.muted &&
            line != null &&
            line.isNotEmpty;
        return Scaffold(
          body: Semantics(
            label: widget.storyId == null ? 'Feed' : 'Feed ${widget.storyId}',
            child: LayoutBuilder(
              builder: (context, constraints) {
                final video = VideoFrame(constraints.biggest);
                final heldId = state.holdChoiceId;
                var holdX = 0.0;
                var holdY = 0.0;
                var holdRadius = 0.0;
                var hasHold = false;
                if (playback != null && heldId != null) {
                  for (final choice in playback.choices) {
                    if (choice.choiceId != heldId) continue;
                    holdX = choice.x;
                    holdY = choice.y;
                    holdRadius = choice.radius;
                    hasHold = true;
                  }
                }
                return Stack(
                  fit: .expand,
                  children: [
                    if (showClip)
                      NodeVideo(
                        key: ValueKey(playback.node.videoUrl),
                        url: playback.node.videoUrl,
                        muted: state.muted,
                        play: state.phase == .playing,
                        player: widget.clipPlayer,
                        onFirstFrame: () {},
                        onEnded: () => bloc.add(const PauseReached()),
                      ),
                    if (playback != null)
                      Positioned(
                        left: 16,
                        top: MediaQuery.paddingOf(context).top + 16,
                        right: 88,
                        child: Align(
                          alignment: .centerLeft,
                          child: AnimatedOpacity(
                            opacity: state.phase == .playing ? 1 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: IgnorePointer(
                              ignoring: state.phase != .playing,
                              child: StoryChip(
                                title: playback.story.title,
                                author: playback.story.authorName,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (playback != null &&
                        !playback.node.isEnding &&
                        (state.phase == .window || state.phase == .holding))
                      for (final choice in playback.choices)
                        ChoiceZone(
                          key: ValueKey(choice.choiceId),
                          choiceId: choice.choiceId,
                          label: choice.label,
                          x: choice.x,
                          y: choice.y,
                          radius: choice.radius,
                          video: video,
                          enabled: state.phase == .window,
                          onHoldStart: (pointer) {
                            _pointer = pointer;
                            bloc.add(HoldStarted(choice.choiceId));
                          },
                        ),
                    if (showClip)
                      Positioned.fill(
                        child: HoldPortal(
                          open:
                              state.phase == .holding ||
                              state.phase == .committing,
                          serial: state.holdSerial,
                          center: hasHold
                              ? video.point(holdX, holdY)
                              : null,
                          startRadius: hasHold
                              ? video.radius(holdRadius)
                              : 0,
                          blurData: playback.node.videoFrameLastBlurData,
                          onCompleted: () => bloc.add(const HoldCompleted()),
                        ),
                      ),
                    if (showClip)
                      Positioned(
                        right: 8,
                        top: MediaQuery.paddingOf(context).top,
                        bottom: 88,
                        child: Align(
                          alignment: .centerRight,
                          child: MuteButton(
                            muted: state.muted,
                            autoMuted: state.autoMuted,
                            onPressed: () {
                              if (state.muted) bloc.narrator.unlock();
                              bloc.add(const MuteToggled());
                            },
                          ),
                        ),
                      ),
                    if (showLine)
                      Positioned(
                        left: 24,
                        right: 24,
                        bottom: MediaQuery.paddingOf(context).bottom + 96,
                        child: SubtitleLine(text: line),
                      ),
                    if (state.phase == .failed && state.failure != null)
                      Center(
                        child: FailureText(
                          message: state.failure!,
                          onRetry: () =>
                              bloc.add(StoryOpened(storyId: state.storyId)),
                        ),
                      ),
                    if (showClip)
                      Positioned.fill(
                        child: _ReleaseCatcher(
                          onRelease: (pointer) {
                            if (pointer != _pointer) return;
                            _pointer = null;
                            bloc.add(const HoldCancelled());
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Ends the tracked hold when its finger lifts anywhere on screen.
///
/// Sits on top of the stack and only watches: with `translucent` behavior it
/// never blocks the mute button or the zones. The view matches the pointer
/// id, so a second finger cannot cancel the hold.
class _ReleaseCatcher extends StatelessWidget {
  const _ReleaseCatcher({required this.onRelease});

  /// Called with the released pointer id. The view matches it.
  final ValueChanged<int> onRelease;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: .translucent,
      onPointerUp: (event) => onRelease(event.pointer),
      onPointerCancel: (event) => onRelease(event.pointer),
      child: const SizedBox.expand(),
    );
  }
}

FeedBloc? _feedOf(BuildContext context, {bool listen = false}) {
  try {
    return BlocProvider.of<FeedBloc>(context, listen: listen);
  } on FlutterError {
    return null;
  }
}
