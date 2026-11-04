import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/shell_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/app/shell_event.dart';
import 'package:ramifica/core/browser_gesture.dart';
import 'package:ramifica/core/widgets/choice_icon.dart';
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
  const FeedView({
    super.key,
    this.storyId,
    this.clipPlayer,
    this.preview = false,
    this.previewAuthorName,
    this.previewVideoSize,
    this.previewOpenNode,
  });

  final String? storyId;

  /// A draft preview shows the feed without navigating or changing a run.
  final bool preview;

  /// The draft author's profile name, if it arrives after preview opens.
  final String? previewAuthorName;

  /// Draft metadata used until the video reports its decoded dimensions.
  final Size? previewVideoSize;

  /// Opens a draft node for editing from the unfinished-target notice.
  /// Set by the editor preview only; without it the notice has no action.
  final void Function(String nodeId)? previewOpenNode;

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

  /// Accumulated horizontal drag, same 64 px rule. A rightward swipe
  /// exits the feed to the open story's tree.
  double _dragDx = 0;
  Size? _previewVideoSize;

  /// Whether the clip was hidden when the current tap pressed down. Read
  /// synchronously on pointer down and consumed on tap up, so the tap
  /// that wakes a hidden clip never toggles the pause. Every tap
  /// refreshes it on its way down, so a stale value cannot survive.
  bool _hiddenAtDown = false;

  /// Whether the clip was still auto-muted when the current tap pressed
  /// down. The down already turned the sound on through `UserGestured`,
  /// so the mute press of that same tap skips its toggle instead of
  /// muting back. Refreshed on every down, like [_hiddenAtDown].
  bool _autoMutedAtDown = false;

  /// Shows the resume flash. Set on the paused-to-playing edge and
  /// cleared 600ms later; [_flashToken] drops stale timers when taps
  /// come faster than that.
  bool _playFlash = false;
  int _flashToken = 0;

  void _flashPlay() {
    final token = ++_flashToken;
    setState(() => _playFlash = true);
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted || token != _flashToken) return;
      setState(() => _playFlash = false);
    });
  }

  /// Local like/save toggles. No backend yet, so they never leave the
  /// device, in both feed and preview.
  var _liked = false;
  var _saved = false;

  void _onPreviewVideoSize(Size size) {
    if (size == _previewVideoSize) return;
    setState(() => _previewVideoSize = size);
  }

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
          previous.playback!.story.storyId != current.playback!.story.storyId,
      listener: (context, state) {
        final id = state.playback!.story.storyId;
        try {
          AppNavigation.read(context)
              .go(AppRoutes.storyPath(Uri.encodeComponent(id)));
        } on FlutterError {
          // Widget tests mount FeedView without the router.
        }
      },
      child: BlocListener<FeedBloc, FeedState>(
        bloc: bloc,
        // A preview hold on an unfinished target keeps the scene and raises
        // a transient notice. The serial replays repeats; the phase is
        // untouched, so this listener never fights the player.
        listenWhen: (previous, current) =>
            current.previewNoticeSerial != previous.previewNoticeSerial &&
            current.previewNotice != null,
        listener: (context, state) {
          final target = state.previewNoticeTarget;
          final open = widget.previewOpenNode;
          _showRailSnackbar(
            context,
            state.previewNotice!,
            onAction: target != null && open != null
                ? () {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    open(target);
                  }
                : null,
          );
        },
        child: BlocListener<FeedBloc, FeedState>(
          bloc: bloc,
          listenWhen: (previous, current) =>
              previous.userPaused && !current.userPaused,
          listener: (context, state) => _flashPlay(),
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
              // The choice zones are up. The engagement rail hides while
              // they show, in both feed and preview; mute and map stay. Zones rise
              // with the narration and stay through the window.
              final zonesVisible =
                  playback != null &&
                  !playback.node.isEnding &&
                  ((state.phase == .speaking &&
                          (!widget.preview || state.previewCueStarted)) ||
                      state.phase == .window ||
                      state.phase == .holding);
              return Listener(
                // The first pointerdown anywhere clears the browser auto-mute and
                // resumes the audio context. The bloc ignores repeats and never
                // overrides a manual mute. Also resumes a hidden-parked clip.
                onPointerDown: (_) {
                  _hiddenAtDown = bloc.state.hiddenPaused;
                  _autoMutedAtDown = bloc.state.autoMuted;
                  bloc.narrator.unlock();
                  bloc.add(const UserGestured());
                },
                child: Scaffold(
                  body: Semantics(
                    label: widget.storyId == null
                        ? 'Feed'
                        : 'Feed ${widget.storyId}',
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final video = widget.preview
                            ? VideoFrame.fitWidth(
                                constraints.biggest,
                                sourceSize:
                                    _previewVideoSize ??
                                    widget.previewVideoSize,
                              )
                            : VideoFrame(constraints.biggest);
                        final heldId = state.holdChoiceId;
                        var holdX = 0.0;
                        var holdY = 0.0;
                        var holdRadius = 0.0;
                        String? holdIconColor;
                        var holdIndex = 0;
                        var hasHold = false;
                        if (playback != null && heldId != null) {
                          for (final (i, choice) in playback.choices.indexed) {
                            if (choice.choiceId != heldId) continue;
                            holdX = choice.x;
                            holdY = choice.y;
                            holdRadius = choice.radius;
                            holdIconColor = choice.iconColor;
                            holdIndex = i;
                            hasHold = true;
                          }
                        }
                        // Same resolution as ChoiceZone: the held hotspot's
                        // icon color, so the circle grows in its color.
                        final holdColor = choiceIconColor(
                          holdIconColor,
                          holdIndex % 2 == 0
                              ? RamificaColors.hotspot
                              : RamificaColors.nodeActive,
                        );
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          // A tap on the video toggles the pause while the clip
                          // is playing; the bloc ignores it anywhere else, so
                          // hotspots, narration, and the ending card are safe.
                          // The tap that wakes a hidden clip is consumed here
                          // and never reaches the bloc as a toggle.
                          onTap: () {
                            final woke = _hiddenAtDown;
                            _hiddenAtDown = false;
                            if (!woke) bloc.add(const VideoTapped());
                          },
                          // A hold never moves, so a vertical drag is never a hold.
                          // The bloc still gates: speaking, window, holding,
                          // committing, and the closing line ignore the swipe.
                          // Cancelling here (not at drag end) matters: the
                          // drag-end handler clears `_pointer`, which would
                          // make the release catcher ignore the finger-up and
                          // leave the portal growing with no finger on it.
                          onVerticalDragStart: (_) {
                            _dragDy = 0;
                            if (_pointer != null) {
                              _pointer = null;
                              bloc.add(const HoldCancelled());
                            }
                          },
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
                          // Swipe right exits the fullscreen feed to the
                          // tree of the story on screen. Same path as the
                          // rail's "See map" pill, so previews stay put.
                          onHorizontalDragStart: (_) {
                            _dragDx = 0;
                            if (_pointer != null) {
                              _pointer = null;
                              bloc.add(const HoldCancelled());
                            }
                          },
                          onHorizontalDragUpdate: (details) {
                            _dragDx += details.primaryDelta ?? 0;
                          },
                          onHorizontalDragEnd: (details) {
                            _pointer = null;
                            final fling = (details.primaryVelocity ?? 0) >= 200;
                            final drag = _dragDx >= 64;
                            _dragDx = 0;
                            if (widget.preview) return;
                            if (!fling && !drag) return;
                            bloc.add(const MapRequested());
                            _openMap(context, state.storyId);
                          },
                          child: Stack(
                            fit: .expand,
                            children: [
                              if (showClip)
                                NodeVideo(
                                  key: ValueKey(playback.node.videoUrl),
                                  url: playback.node.videoUrl,
                                  poster:
                                      playback.node.videoFrameFirstBlurData ??
                                      playback.node.videoFrameLastBlurData,
                                  muted: state.muted,
                                  play:
                                      state.phase == .playing &&
                                      !state.hiddenPaused &&
                                      !state.userPaused,
                                  player: widget.clipPlayer,
                                  fit: widget.preview
                                      ? BoxFit.fitWidth
                                      : BoxFit.cover,
                                  onVideoSizeChanged: widget.preview
                                      ? _onPreviewVideoSize
                                      : null,
                                  onFirstFrame: () {},
                                  onEnded: () => bloc.add(const PauseReached()),
                                ),
                              // Stitch top scrim: static readability gradient. No tabs,
                              // no countdown, no timing UI live here.
                              if (showClip)
                                const Positioned(
                                  left: 0,
                                  top: 0,
                                  right: 0,
                                  height: 120,
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Color(0xB3141318),
                                            Color(0x00141318),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              // Stitch bottom scrim under the metadata column.
                              if (showClip)
                                const Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  height: 220,
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.bottomCenter,
                                          end: Alignment.topCenter,
                                          colors: [
                                            Color(0xE6141318),
                                            Color(0x00141318),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              // Stitch bottom-left metadata column: story title + author.
                              // No description or hashtags exist in playback state, so
                              // none render here. Visibility gate unchanged (playing).
                              if (playback != null)
                                Positioned(
                                  left: 16,
                                  right: 88,
                                  bottom:
                                      MediaQuery.paddingOf(context).bottom + 24,
                                  child: Align(
                                    alignment: .centerLeft,
                                    child: AnimatedOpacity(
                                      opacity:
                                          state.phase == .playing ||
                                              state.phase == .ending
                                          ? 1
                                          : 0,
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      child: IgnorePointer(
                                        ignoring:
                                            state.phase != .playing &&
                                            state.phase != .ending,
                                        child: StoryChip(
                                          title: playback.story.title,
                                          author:
                                              widget.previewAuthorName ??
                                              playback.story.authorName,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              // The hold circle grows behind the hotspots: the held
                              // one stays visible on top of it while the
                              // others fade out (see `dimmed` below).
                              if (showClip)
                                Positioned.fill(
                                  // Preserve the exit when a fast commit swaps
                                  // the video and removes zones in one build.
                                  key: const ValueKey('hold-portal'),
                                  child: RepaintBoundary(
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
                                      fillColor: holdColor,
                                      onCompleted: () =>
                                          bloc.add(const HoldCompleted()),
                                    ),
                                  ),
                                ),
                              if (zonesVisible)
                                for (final (i, choice)
                                    in playback.choices.indexed)
                                  ChoiceZone(
                                    key: ValueKey(choice.choiceId),
                                    choiceId: choice.choiceId,
                                    label: choice.label,
                                    x: choice.x,
                                    y: choice.y,
                                    radius: choice.radius,
                                    video: video,
                                    enabled: widget.preview
                                        ? ((state.phase == .speaking &&
                                                  state.previewCueStarted) ||
                                              state.phase == .window)
                                        : state.phase == .window ||
                                              state.phase == .speaking,
                                    icon: choice.icon,
                                    iconColor: choice.iconColor,
                                    index: i,
                                    compact: widget.preview,
                                    dimmed:
                                        heldId != null &&
                                        choice.choiceId != heldId,
                                    onHoldStart: (pointer) {
                                      _pointer = pointer;
                                      bloc.add(HoldStarted(choice.choiceId));
                                    },
                                  ),
                              // Tap-pause feedback, centered over the video. The
                              // pause mark stays while paused; the play mark
                              // flashes once on resume and fades. Display only:
                              // taps pass through to the toggle below.
                              if (showClip)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: Stack(
                                      alignment: .center,
                                      children: [
                                        AnimatedOpacity(
                                          key: const ValueKey('pause-mark'),
                                          opacity:
                                              state.userPaused &&
                                                  state.phase == .playing
                                              ? 1
                                              : 0,
                                          duration: const Duration(
                                            milliseconds: 200,
                                          ),
                                          child: const Icon(
                                            Icons.pause_circle,
                                            size: 72,
                                            color: Color(0x80FFFFFF),
                                          ),
                                        ),
                                        AnimatedOpacity(
                                          key: const ValueKey('play-flash'),
                                          opacity:
                                              _playFlash && !state.userPaused
                                              ? 1
                                              : 0,
                                          duration: const Duration(
                                            milliseconds: 250,
                                          ),
                                          child: const Icon(
                                            Icons.play_circle,
                                            size: 72,
                                            color: Color(0x80FFFFFF),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (showClip)
                                Positioned(
                                  right: 8,
                                  top: MediaQuery.paddingOf(context).top,
                                  bottom: 88,
                                  child: Align(
                                    alignment: .bottomRight,
                                    // The whole right rail fades out while the
                                    // choice zones are up: creator, map, like,
                                    // comment, save, and mute.
                                    child: AnimatedOpacity(
                                      key: const ValueKey('action-rail'),
                                      opacity: zonesVisible ? 0 : 1,
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      child: IgnorePointer(
                                        ignoring: zonesVisible,
                                        child: Column(
                                          mainAxisSize: .min,
                                          children: [
                                            // Creator avatar above the map entry. It
                                            // opens `/profile/<uid>` with the
                                            // creator's stories and endings.
                                            // Hidden while the uid is unknown.
                                            const SizedBox(height: 12),
                                            if ((state
                                                        .playback
                                                        ?.story
                                                        .authorId ??
                                                    '')
                                                .isNotEmpty) ...[
                                              _RailAction(
                                                key: const ValueKey(
                                                  'rail-creator',
                                                ),
                                                tooltip: _creatorName(
                                                  state
                                                      .playback
                                                      ?.story
                                                      .authorName,
                                                ),
                                                label: _creatorLabel(
                                                  state
                                                      .playback
                                                      ?.story
                                                      .authorName,
                                                ),
                                                icon: Icons.person,
                                                iconColor:
                                                    RamificaColors.textPrimary,
                                                imageUrl: state
                                                    .playback
                                                    ?.story
                                                    .authorPhotoUrl,
                                                onTap: () => _openCreator(
                                                  context,
                                                  state
                                                      .playback
                                                      ?.story
                                                      .authorId,
                                                  widget.preview,
                                                ),
                                              ),
                                              const SizedBox(height: 12),
                                            ],
                                            // Map entry, same shape and label
                                            // as the other rail actions.
                                            _RailAction(
                                              key: const ValueKey('rail-map'),
                                              tooltip: 'See map',
                                              label: 'Map',
                                              icon: Icons.map_outlined,
                                              iconColor: const Color(
                                                0xFFE0FDFF,
                                              ),
                                              iconSize: 22,
                                              glow: true,
                                              onTap: () {
                                                if (widget.preview) return;
                                                bloc.add(
                                                  const MapRequested(),
                                                );
                                                _openMap(
                                                  context,
                                                  state.storyId,
                                                );
                                              },
                                            ),
                                            // Engagement actions: like, comment,
                                            // save. They toggle locally until the
                                            // backend lands; comments stay off.
                                            const SizedBox(height: 12),
                                            _RailAction(
                                              key: const ValueKey('rail-like'),
                                              tooltip: 'Like',
                                              label: 'Like',
                                              icon: _liked
                                                  ? Icons.favorite
                                                  : Icons.favorite_border,
                                              iconColor: _liked
                                                  ? RamificaColors.hotspot
                                                  : RamificaColors.textPrimary,
                                              glow: _liked,
                                              onTap: () => setState(
                                                () => _liked = !_liked,
                                              ),
                                            ),
                                            const SizedBox(height: 12),
                                            _RailAction(
                                              key: const ValueKey(
                                                'rail-comment',
                                              ),
                                              tooltip: 'Comment',
                                              label: 'Comment',
                                              icon: Icons.chat_bubble,
                                              iconColor:
                                                  RamificaColors.textPrimary,
                                              onTap: () => _showRailSnackbar(
                                                context,
                                                widget.preview
                                                    ? 'Comments are not available in preview.'
                                                    : 'Comments are coming soon.',
                                              ),
                                            ),
                                            const SizedBox(height: 12),
                                            _RailAction(
                                              key: const ValueKey('rail-save'),
                                              tooltip: 'Save',
                                              label: 'Save',
                                              icon: _saved
                                                  ? Icons.bookmark
                                                  : Icons.bookmark_border,
                                              iconColor:
                                                  RamificaColors.textPrimary,
                                              iconSize: 22,
                                              onTap: () => setState(
                                                () => _saved = !_saved,
                                              ),
                                            ),
                                            const SizedBox(height: 12),
                                            MuteButton(
                                              muted: state.muted,
                                              autoMuted: state.autoMuted,
                                              onPressed: () {
                                                // This tap already turned the
                                                // sound on through UserGestured;
                                                // toggling would mute it back.
                                                if (_autoMutedAtDown) return;
                                                if (state.muted) {
                                                  bloc.narrator.unlock();
                                                }
                                                bloc.add(const MuteToggled());
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              if (showLine)
                                Positioned(
                                  left: 24,
                                  right: 24,
                                  bottom:
                                      MediaQuery.paddingOf(context).bottom + 96,
                                  child: SubtitleLine(text: line),
                                ),
                              if (state.phase == .failed &&
                                  state.failure != null)
                                Center(
                                  child: FailureText(
                                    message: state.failure!,
                                    onRetry: () => bloc.add(
                                      StoryOpened(storyId: state.storyId),
                                    ),
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
                                // Stops before the right rail (right: 8, 56
                                // wide at most) keeping the same 24 outer gap
                                // as the left edge, so the card flexes with
                                // the screen width instead of sliding under
                                // the rail buttons.
                                Positioned(
                                  left: 12,
                                  right: 8 + 56 + 12,
                                  bottom:
                                      MediaQuery.paddingOf(context).bottom +
                                      96 -
                                      12,
                                  child: EndingCard(
                                    key: const ValueKey('ending-card'),
                                    name: playback.node.title,
                                    type: playback.node.endingType,
                                    rewardCode: playback.node.rewardCode,
                                    unlockedTitle: state.sagaUnlocked?.title,
                                    badgeUrl: playback.node.endingBadgeUrl,
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
        ),
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

/// Right-rail action mirroring the Stitch feed rail: a 44 px glass circle
/// with an 11 px label under it.
class _RailAction extends StatelessWidget {
  const _RailAction({
    super.key,
    required this.tooltip,
    required this.label,
    required this.icon,
    required this.iconColor,
    this.iconSize = 24,
    this.glow = false,
    this.imageUrl,
    required this.onTap,
  });

  final String tooltip;
  final String label;
  final IconData icon;
  final Color iconColor;
  final double iconSize;
  final bool glow;

  /// A profile photo shown instead of [icon]. Null or blank keeps the icon.
  final String? imageUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: .min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xD82A292F),
                border: Border.all(
                  color: glow
                      ? const Color(0x4D00F2FE)
                      : const Color(0x1AFFFFFF),
                ),
                boxShadow: glow
                    ? const [
                        BoxShadow(color: Color(0x6600F2FE), blurRadius: 14),
                      ]
                    : null,
              ),
              child: _RailCircle(
                icon: icon,
                iconColor: iconColor,
                iconSize: iconSize,
                imageUrl: imageUrl,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: RamificaText.overVideo(
                RamificaText.caption.copyWith(
                  color: RamificaColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rail circle contents: a profile photo when [imageUrl] is set, the
/// icon otherwise. A broken photo falls back to the icon.
class _RailCircle extends StatelessWidget {
  const _RailCircle({
    required this.icon,
    required this.iconColor,
    required this.iconSize,
    this.imageUrl,
  });

  final IconData icon;
  final Color iconColor;
  final double iconSize;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim();
    if (url == null || url.isEmpty) {
      return Icon(icon, color: iconColor, size: iconSize);
    }
    return ClipOval(
      child: Image.network(
        url,
        width: 44,
        height: 44,
        fit: .cover,
        errorBuilder: (context, error, stack) =>
            Icon(icon, color: iconColor, size: iconSize),
      ),
    );
  }
}

void _showRailSnackbar(
  BuildContext context,
  String message, {
  VoidCallback? onAction,
}) {
  final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
  if (onAction == null) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
    return;
  }
  messenger.showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Expanded(child: Text(message)),
          IconButton(
            key: const ValueKey('notice-open-node'),
            tooltip: 'Open node',
            icon: const Icon(
              Icons.chevron_right,
              color: RamificaColors.hotspot,
            ),
            onPressed: onAction,
          ),
        ],
      ),
    ),
  );
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

/// Full author name for the creator button tooltip. Falls back to
/// 'Creator' while the name is unknown.
String _creatorName(String? authorName) {
  final clean = (authorName ?? '').trim();
  return clean.isEmpty ? 'Creator' : clean;
}

/// Rail label for the creator button: the author name cut to 10 letters.
String _creatorLabel(String? authorName) {
  final name = _creatorName(authorName);
  return name.length > 10 ? name.substring(0, 10) : name;
}

void _openCreator(BuildContext context, String? authorId, bool preview) {
  // Previews stay put, like the rail's "See map" entry.
  if (preview) return;
  final uid = authorId?.trim();
  if (uid == null || uid.isEmpty) return;
  try {
    AppNavigation.read(context).go(AppRoutes.profileOf(uid));
  } on FlutterError {
    // Widget tests mount FeedView without the router.
  }
}
