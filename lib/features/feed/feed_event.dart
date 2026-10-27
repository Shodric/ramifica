sealed class FeedEvent {
  const FeedEvent();
}

final class StoryOpened extends FeedEvent {
  const StoryOpened({this.storyId});

  final String? storyId;
}
