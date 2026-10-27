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

/// Flips mute for the clip and the narrator. Clears the browser auto-mute.
final class MuteToggled extends FeedEvent {
  const MuteToggled();
}

/// The narrator finished, or the muted subtitle ran for `ttsDurationSeconds`.
final class VoiceFinished extends FeedEvent {
  const VoiceFinished();
}

/// A finger pressed a zone during the window.
final class HoldStarted extends FeedEvent {
  const HoldStarted(this.choiceId);

  final String choiceId;
}

/// The finger came up, or the pointer was cancelled, before one second.
final class HoldCancelled extends FeedEvent {
  const HoldCancelled();
}

/// The portal covered the screen. `commitChoice` is the next slice.
final class HoldCompleted extends FeedEvent {
  const HoldCompleted();
}

/// `windowSeconds` ran out. Starts the default portal when nobody is holding.
final class WindowElapsed extends FeedEvent {
  const WindowElapsed();
}
