import 'package:ramifica/data/models/playback.dart';

enum FeedPhase { loading, playing, ending, failed }

class FeedState {
  const FeedState({
    this.phase = FeedPhase.loading,
    this.storyId,
    this.runId,
    this.playback,
    this.failure,
  });

  final FeedPhase phase;
  final String? storyId;
  final String? runId;
  final Playback? playback;
  final String? failure;

  @override
  bool operator ==(Object other) {
    return other is FeedState &&
        other.phase == phase &&
        other.storyId == storyId &&
        other.runId == runId &&
        other.playback == playback &&
        other.failure == failure;
  }

  @override
  int get hashCode => Object.hash(phase, storyId, runId, playback, failure);
}
