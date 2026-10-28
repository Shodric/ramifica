import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/graph_stub.dart';
import 'package:ramifica/data/models/playback.dart';

/// Map reads. The view never calls these directly; [GraphBloc] does.
class GraphRepository {
  GraphRepository({required this.functions});

  final FunctionsClient functions;

  /// Every node of the story. Visited nodes carry title and counts;
  /// unvisited secret nodes carry only an id.
  Future<GraphStubsResult> fetchStubs({
    required String storyId,
    required String runId,
  }) async {
    final story = storyId.trim();
    final run = runId.trim();
    if (story.isEmpty || run.isEmpty) throw const AppFailure(.invalid);
    final payload = await functions.call('graphStubs', {
      'storyId': story,
      'runId': run,
    });
    return GraphStubsResult.fromJson(payload);
  }

  /// Playback of the visited parent approach that reaches [nodeId].
  /// History is untouched and the run stays active.
  Future<Playback> playApproach({
    required String runId,
    required String nodeId,
  }) async {
    final run = runId.trim();
    final node = nodeId.trim();
    if (run.isEmpty || node.isEmpty) throw const AppFailure(.invalid);
    final payload = await functions.call('playApproach', {
      'runId': run,
      'nodeId': node,
    });
    return Playback.fromJson(payload);
  }

  /// Moves the run back to the parent of its current node through the
  /// append-only history. A run at the root fails server-side.
  Future<Playback> rewind(String runId) async {
    final run = runId.trim();
    if (run.isEmpty) throw const AppFailure(.invalid);
    final payload = await functions.call('rewindRun', {'runId': run});
    return Playback.fromJson(payload);
  }
}

/// Production source: the `graphStubs`, `playApproach`, and `rewindRun`
/// callables in `us-central1`.
GraphRepository createFirebaseGraphRepository() {
  return GraphRepository(functions: FunctionsClient());
}
