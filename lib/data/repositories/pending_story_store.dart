abstract class PendingStoryStore {
  String? read();

  void write(String storyId);

  void clear();
}

class MemoryPendingStoryStore implements PendingStoryStore {
  String? _storyId;

  @override
  String? read() => _storyId;

  @override
  void write(String storyId) => _storyId = storyId;

  @override
  void clear() => _storyId = null;
}
