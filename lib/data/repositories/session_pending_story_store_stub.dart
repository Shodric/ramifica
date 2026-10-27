import 'package:ramifica/data/repositories/pending_story_store.dart';

PendingStoryStore createPlatformPendingStoryStore() {
  return MemoryPendingStoryStore();
}
