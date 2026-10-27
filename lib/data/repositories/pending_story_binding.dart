import 'package:ramifica/data/repositories/pending_story_store.dart';
import 'package:ramifica/data/repositories/session_pending_story_store.dart'
    if (dart.library.io) 'package:ramifica/data/repositories/session_pending_story_store_stub.dart';

PendingStoryStore createPendingStoryStore() {
  return createPlatformPendingStoryStore();
}
