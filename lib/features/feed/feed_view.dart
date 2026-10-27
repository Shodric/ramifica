import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:ramifica/features/feed/mute_button.dart';
import 'package:ramifica/features/feed/node_video.dart';
import 'package:ramifica/features/feed/story_chip.dart';

class FeedView extends StatelessWidget {
  const FeedView({super.key, this.storyId, this.clipPlayer});

  final String? storyId;

  /// Test double for [NodeVideo]. Production leaves this null.
  final ClipPlayer? clipPlayer;

  @override
  Widget build(BuildContext context) {
    final bloc = _feedOf(context, listen: true);
    if (bloc == null) {
      return Scaffold(
        body: Semantics(
          label: storyId == null ? 'Feed' : 'Feed $storyId',
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
            (state.phase == .playing ||
                state.phase == .speaking ||
                state.phase == .ending);
        return Scaffold(
          body: Semantics(
            label: storyId == null ? 'Feed' : 'Feed $storyId',
            child: Stack(
              fit: .expand,
              children: [
                if (showClip)
                  NodeVideo(
                    key: ValueKey(playback.node.videoUrl),
                    url: playback.node.videoUrl,
                    muted: state.muted,
                    play: state.phase == .playing,
                    player: clipPlayer,
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
                        onPressed: () => bloc.add(const MuteToggled()),
                      ),
                    ),
                  ),
                if (state.phase == .failed && state.failure != null)
                  Center(
                    child: FailureText(
                      message: state.failure!,
                      onRetry: () =>
                          bloc.add(StoryOpened(storyId: state.storyId)),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
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
