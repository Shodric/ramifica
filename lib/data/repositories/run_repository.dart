import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/playback.dart';

class RunRepository {
  RunRepository({required this.functions});

  final FunctionsClient functions;

  /// Opens the current run, or lets the server pick a story when [storyId]
  /// is null. With [restart] true, starts a new run at the root and marks
  /// it active. Endings and visited nodes are kept server-side.
  Future<RunStart> startRun({String? storyId, bool restart = false}) async {
    final id = storyId?.trim();
    final data = <String, dynamic>{
      if (id != null && id.isNotEmpty) 'storyId': id,
      if (restart) 'restart': true,
    };
    final payload = await functions.call('startRun', data);
    return RunStart.fromJson(payload);
  }

  Future<Playback> loadPlayback(String runId) async {
    final id = runId.trim();
    if (id.isEmpty) throw const AppFailure(.invalid);
    final payload = await functions.call('loadPlayback', {'runId': id});
    return Playback.fromJson(payload);
  }

  /// Commits one hold. The server answers the same result when the same
  /// [requestId] is sent again.
  Future<CommitResult> commitChoice({
    required String runId,
    required String fromNodeId,
    required String choiceId,
    required String requestId,
  }) async {
    final run = runId.trim();
    final from = fromNodeId.trim();
    final choice = choiceId.trim();
    final request = requestId.trim();
    if (run.isEmpty || from.isEmpty || choice.isEmpty || request.isEmpty) {
      throw const AppFailure(.invalid);
    }
    final payload = await functions.call('commitChoice', {
      'runId': run,
      'fromNodeId': from,
      'choiceId': choice,
      'requestId': request,
    });
    return CommitResult.fromJson(payload);
  }
}
