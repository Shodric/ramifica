import 'package:ramifica/data/models/playback.dart';

sealed class FeedEvent {
  const FeedEvent();
}

final class StoryOpened extends FeedEvent {
  const StoryOpened({this.storyId});

  final String? storyId;
}

/// The clip reached its last frame. `NodeVideo` sends this from the
/// player `ended` event.
final class PauseReached extends FeedEvent {
  const PauseReached();
}

/// The first pointerdown anywhere in the page, or a tap after the browser
/// tab was hidden. Clears the browser auto-mute and resumes the audio
/// context; also resumes a clip parked by [AppHidden]. Never overrides a
/// manual mute.
final class UserGestured extends FeedEvent {
  const UserGestured();
}

/// The browser tab was hidden mid-clip. Parks the video until the next
/// tap; becoming visible again never resumes on its own.
final class AppHidden extends FeedEvent {
  const AppHidden();
}

/// Flips mute for the clip and the narrator. Clears the browser auto-mute.
final class MuteToggled extends FeedEvent {
  const MuteToggled();
}

/// A tap on the video surface. Toggles the user pause while the clip is
/// playing; anywhere else it is ignored. The view never sends the tap
/// that wakes a hidden clip, so waking never pauses.
final class VideoTapped extends FeedEvent {
  const VideoTapped();
}

/// The narrator finished, or the muted subtitle ran for `ttsDurationSeconds`.
final class VoiceFinished extends FeedEvent {
  const VoiceFinished();
}

/// A preview's narration or muted subtitle has begun.
final class PreviewCueStarted extends FeedEvent {
  const PreviewCueStarted();
}

/// A finger pressed a zone during the narration or the window that
/// follows it.
final class HoldStarted extends FeedEvent {
  const HoldStarted(this.choiceId);

  final String choiceId;
}

/// The finger came up, or the pointer was cancelled, before 1.5 seconds.
final class HoldCancelled extends FeedEvent {
  const HoldCancelled();
}

/// The portal covered the screen. Commits the held choice.
final class HoldCompleted extends FeedEvent {
  const HoldCompleted();
}

/// A vertical swipe onto the next reel. Mounts [playback] when the finger
/// landed on a page that is already built. With no playback, mounts the
/// prepared successor. Ignored unless playing or the ending card is
/// visible, and when there is no other story.
final class StorySwiped extends FeedEvent {
  const StorySwiped({this.playback, this.queue = true});

  /// The page the finger landed on. Null mounts the prepared next story,
  /// which is how tests advance without a pager.
  final Playback? playback;

  /// When true, mounting draws the story that follows this one. A landing
  /// in the middle of the session list leaves the pages that are already
  /// built.
  final bool queue;
}

/// The finger moved back to a reel that is already in the session. Starts
/// that story over at its root, so the whole story plays from the first
/// scene.
final class ReelReplayed extends FeedEvent {
  const ReelReplayed(this.playback);

  final Playback playback;
}

/// One published story finished loading for the reel list. The bloc has
/// already appended it to the visit list; the event wakes the view. [era]
/// is that visit: a completion from a replaced visit is ignored.
final class NextPrecached extends FeedEvent {
  const NextPrecached(this.playback, {this.era = 0});

  final Playback? playback;
  final int era;
}

/// From the ending card. Starts a new run at the root and keeps endings.
final class OtherPathRequested extends FeedEvent {
  const OtherPathRequested();
}

/// From the ending card. The view navigates to the map for this story.
final class MapRequested extends FeedEvent {
  const MapRequested();
}

/// The map jumped the run to another scene. Reloads that run current
/// playback without starting over.
final class PlaybackReloadRequested extends FeedEvent {
  const PlaybackReloadRequested(this.runId);

  final String runId;
}

/// A background commit landed. Reconciles the ending outcome when the run
/// is still on the committed destination; the clip itself arrived locally
/// long before, so node bodies never ride the ack.
final class BackgroundCommitAcked extends FeedEvent {
  const BackgroundCommitAcked({
    required this.runId,
    required this.toNodeId,
    this.sagaUnlocked,
    this.rewardCode,
  });

  final String runId;
  final String toNodeId;
  final SagaUnlocked? sagaUnlocked;
  final String? rewardCode;
}

/// A background commit was rejected as invalid: the run moved on elsewhere
/// (another device, the map). Reloads the run truth. Parked offline commits
/// stay silent instead: they keep waiting for a connection.
final class BackgroundCommitInvalid extends FeedEvent {
  const BackgroundCommitInvalid(this.runId);

  final String runId;
}
