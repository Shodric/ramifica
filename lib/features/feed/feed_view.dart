import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/shell_bloc.dart';
import 'package:ramifica/app/shell_event.dart';
import 'package:ramifica/core/browser_gesture.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/features/feed/choice_zone.dart';
import 'package:ramifica/features/feed/ending_card.dart';
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

class _FeedViewState extends State<FeedView> with WidgetsBindingObserver {
  /// Pointer id of the finger holding a zone. Written on down and read on
  /// release, both synchronously, so a quick tap is never missed between
  /// frames. Cleared on release. If a future slice leaves `holding` without
  /// a release (a swipe mid-hold), it must clear this too.
  int? _pointer;

  /// Accumulated vertical drag, reset on each new drag. A slow long drag
  /// past 64 px counts as a swipe, like a fast fling does.
  double _dragDy = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A login or link tap happened before this view existed. It counts as
    // the first gesture, so the first clip can start with sound.
    final bloc = _feedOf(context, listen: false);
    if (bloc != null && hadPriorGesture) {
      bloc.narrator.unlock();
      bloc.add(const UserGestured());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Hidden never resumes on its own: the next tap sends UserGestured,
    // which clears the park. TickerMode (switching tabs) is untouched.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _feedOf(context)?.add(const AppHidden());
    }
  }

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
    return BlocListener<FeedBloc, FeedState>(
      bloc: bloc,
      // A swipe changes the open story. Keep the URL deep-linkable; the
      // shell picks the new id up from the route (same-story guard skips
      // any reload). First load and same-story restarts stay silent.
      listenWhen: (previous, current) =>
          previous.playback != null &&
          current.playback != null &&
          previous.playback!.story.storyId !=
              current.playback!.story.storyId,
      listener: (context, state) {
        final id = state.playback!.story.storyId;
        try {
          AppNavigation.read(
            context,
          ).go(AppRoutes.storyPath(Uri.encodeComponent(id)));
        } on FlutterError {
          // Widget tests mount FeedView without the router.
        }
      },
      child: BlocBuilder<FeedBloc, FeedState>(
        bloc: bloc,
        builder: (context, state) {
        final playback = state.playback;
        final showClip =
            playback != null &&
            state.phase != .loading &&
            state.phase != .failed;
        final line = playback?.node.ttsText?.trim();
        final speakingCue =
            state.phase == .speaking ||
            (state.phase == .ending && state.endingSpeaking);
        final showLine =
            speakingCue && state.muted && line != null && line.isNotEmpty;
        final showCard =
            showClip &&
            state.phase == .ending &&
            !state.endingSpeaking &&
            playback.node.isEnding;
        return Listener(
          // The first pointerdown anywhere clears the browser auto-mute and
          // resumes the audio context. The bloc ignores repeats and never
          // overrides a manual mute. Also resumes a hidden-parked clip.
          onPointerDown: (_) {
            bloc.narrator.unlock();
            bloc.add(const UserGestured());
          },
          child: Scaffold(
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
                return GestureDetector(
                  // A hold never moves, so a vertical drag is never a hold.
                  // The bloc still gates: speaking, window, holding,
                  // committing, and the closing line ignore the swipe.
                  onVerticalDragStart: (_) => _dragDy = 0,
                  onVerticalDragUpdate: (details) =>
                      _dragDy += details.primaryDelta ?? 0,
                  onVerticalDragEnd: (details) {
                    _pointer = null;
                    final fling =
                        (details.primaryVelocity ?? 0).abs() >= 200;
                    final drag = _dragDy.abs() >= 64;
                    _dragDy = 0;
                    if (!fling && !drag) return;
                    bloc.add(const StorySwiped());
                  },
                  child: Stack(
                    fit: .expand,
                    children: [
                    if (showClip)
                      NodeVideo(
                        key: ValueKey(playback.node.videoUrl),
                        url: playback.node.videoUrl,
                        muted: state.muted,
                        play:
                            state.phase == .playing &&
                            !state.hiddenPaused,
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
                          child: Column(
                            mainAxisSize: .min,
                            children: [
                              MuteButton(
                                muted: state.muted,
                                autoMuted: state.autoMuted,
                                onPressed: () {
                                  if (state.muted) bloc.narrator.unlock();
                                  bloc.add(const MuteToggled());
                                },
                              ),
                              const SizedBox(height: 8),
                              IconButton(
                                tooltip: 'See map',
                                onPressed: () {
                                  bloc.add(const MapRequested());
                                  _openMap(context, state.storyId);
                                },
                                icon: const Icon(Icons.map_outlined),
                              ),
                            ],
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
                    if (showCard)
                      Positioned(
                        left: 24,
                        right: 24,
                        bottom:
                            MediaQuery.paddingOf(context).bottom + 96,
                        child: EndingCard(
                          key: const ValueKey('ending-card'),
                          name:
                              playback.node.endingName ??
                              playback.node.title,
                          type: playback.node.endingType,
                          rewardCode: playback.node.rewardCode,
                          unlockedTitle: state.sagaUnlocked?.title,
                          onSeeMap: () {
                            bloc.add(const MapRequested());
                            _openMap(context, state.storyId);
                          },
                          onTryAnotherPath: () =>
                              bloc.add(const OtherPathRequested()),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          ),
        );
      },
      ),
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

void _openMap(BuildContext context, String? storyId) {
  try {
    context.read<ShellBloc>().add(TabSelected(.graph, storyId: storyId));
  } on Exception {
    // Widget tests mount FeedView without the shell. ProviderNotFoundException
    // implements Exception, not FlutterError. The MapRequested event above
    // keeps the contract; navigation needs the real app.
  }
}
