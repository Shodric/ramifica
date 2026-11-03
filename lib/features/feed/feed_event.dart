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

/// A finger pressed a zone during the window.
final class HoldStarted extends FeedEvent {
  const HoldStarted(this.choiceId);

  final String choiceId;
}

/// A preview tap on a hotspot. Unlike [HoldStarted], it navigates at once:
/// the preview has no run to commit, so there is no hold or portal.
final class PreviewChoiceTaken extends FeedEvent {
  const PreviewChoiceTaken(this.choiceId);

  final String choiceId;
}

/// The finger came up, or the pointer was cancelled, before one second.
final class HoldCancelled extends FeedEvent {
  const HoldCancelled();
}

/// The portal covered the screen. Commits the held choice.
final class HoldCompleted extends FeedEvent {
  const HoldCompleted();
}

/// A vertical swipe. Draws another published story at random and opens it
/// with the same resume rule. Ignored unless playing or the ending card
/// is visible, and when there is no other story.
final class StorySwiped extends FeedEvent {
  const StorySwiped();
}

/// From the ending card. Starts a new run at the root and keeps endings.
final class OtherPathRequested extends FeedEvent {
  const OtherPathRequested();
}

/// From the ending card. The view navigates to the map for this story.
final class MapRequested extends FeedEvent {
  const MapRequested();
}
