import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/playback.dart';

class RunRepository {
  RunRepository({required this.functions});

  final FunctionsClient functions;

  /// Opens the current run, or lets the server pick a story when [storyId]
  /// is null. Does not send `restart`.
  Future<RunStart> startRun({String? storyId}) async {
    final id = storyId?.trim();
    final data = <String, dynamic>{
      if (id != null && id.isNotEmpty) 'storyId': id,
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
}
