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
