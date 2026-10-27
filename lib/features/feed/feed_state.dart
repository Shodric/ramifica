import 'package:ramifica/data/models/playback.dart';

/// `committing` waits for `commitChoice`, in the next slice.
enum FeedPhase {
  loading,
  playing,
  speaking,
  window,
  holding,
  committing,
  ending,
  failed,
}

class FeedState {
  const FeedState({
    this.phase = FeedPhase.loading,
    this.storyId,
    this.runId,
    this.playback,
    this.failure,
    this.muted = true,
    this.autoMuted = true,
    this.holdChoiceId,
    this.holdSerial = 0,
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

  /// The zone under the portal. Null while the window has no finger on it.
  final String? holdChoiceId;

  /// Bumps each time a hold starts, so the portal animation restarts.
  final int holdSerial;

  FeedState copy({
    FeedPhase? phase,
    bool? muted,
    bool? autoMuted,
    String? holdChoiceId,
    int? holdSerial,
    bool clearHold = false,
  }) {
    return FeedState(
      phase: phase ?? this.phase,
      storyId: storyId,
      runId: runId,
      playback: playback,
      failure: failure,
      muted: muted ?? this.muted,
      autoMuted: autoMuted ?? this.autoMuted,
      holdChoiceId: clearHold ? null : holdChoiceId ?? this.holdChoiceId,
      holdSerial: clearHold ? 0 : holdSerial ?? this.holdSerial,
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
        other.autoMuted == autoMuted &&
        other.holdChoiceId == holdChoiceId &&
        other.holdSerial == holdSerial;
  }

  @override
  int get hashCode => Object.hash(
    phase,
    storyId,
    runId,
    playback,
    failure,
    muted,
    autoMuted,
    holdChoiceId,
    holdSerial,
  );
}
