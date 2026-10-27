import 'package:ramifica/data/models/playback.dart';

enum FeedPhase { loading, playing, speaking, ending, failed }

class FeedState {
  const FeedState({
    this.phase = FeedPhase.loading,
    this.storyId,
    this.runId,
    this.playback,
    this.failure,
    this.muted = true,
    this.autoMuted = true,
  });

  final FeedPhase phase;
  final String? storyId;
  final String? runId;
  final Playback? playback;
  final String? failure;

  /// Clip and narrator. Starts muted so the browser can autoplay.
  final bool muted;

  /// The browser muted the clip. The first manual toggle clears it.
  final bool autoMuted;

  FeedState copy({FeedPhase? phase, bool? muted, bool? autoMuted}) {
    return FeedState(
      phase: phase ?? this.phase,
      storyId: storyId,
      runId: runId,
      playback: playback,
      failure: failure,
      muted: muted ?? this.muted,
      autoMuted: autoMuted ?? this.autoMuted,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is FeedState &&
        other.phase == phase &&
        other.storyId == storyId &&
        other.runId == runId &&
        other.playback == playback &&
        other.failure == failure &&
        other.muted == muted &&
        other.autoMuted == autoMuted;
  }

  @override
  int get hashCode =>
      Object.hash(phase, storyId, runId, playback, failure, muted, autoMuted);
}
