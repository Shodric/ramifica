import 'package:ramifica/data/models/playback.dart';

/// `committing` waits for `commitChoice` to answer the destination clip.
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
    this.sagaUnlocked,
    this.failure,
    this.muted = true,
    this.autoMuted = true,
    this.holdChoiceId,
    this.holdSerial = 0,
    this.pendingRequestId,
    this.endingSpeaking = false,
    this.hiddenPaused = false,
  });
  final FeedPhase phase;
  final String? storyId;
  final String? runId;
  final Playback? playback;

  /// The saga story this ending newly unlocked, if any. Set only on the
  /// fresh commit that unlocked it; reopens and re-earns pass null, so the
  /// card announces `Unlocked {title}` exactly once.
  final SagaUnlocked? sagaUnlocked;

  final String? failure;

  /// Clip and narrator. Starts muted so the browser can autoplay.
  final bool muted;

  /// The browser muted the clip. The first manual toggle clears it.
  final bool autoMuted;

  /// The zone under the portal. Null while the window has no finger on it.
  final String? holdChoiceId;

  /// Bumps each time a hold starts, so the portal animation restarts.
  final int holdSerial;

  /// The `requestId` of the hold in flight. A retry sends this same id,
  /// so the server answers the stored result instead of advancing twice.
  final String? pendingRequestId;

  /// Inside `ending`: true while the closing line plays over the last frame.
  /// False once the card is visible. Always false outside `ending`.
  final bool endingSpeaking;

  /// The browser tab was hidden mid-clip. The video stays parked until the
  /// next tap; becoming visible again never resumes on its own.
  final bool hiddenPaused;

  FeedState copy({
    FeedPhase? phase,
    bool? muted,
    bool? autoMuted,
    String? holdChoiceId,
    int? holdSerial,
    bool clearHold = false,
    String? pendingRequestId,
    bool? endingSpeaking,
    bool? hiddenPaused,
  }) {
    return FeedState(
      phase: phase ?? this.phase,
      storyId: storyId,
      runId: runId,
      playback: playback,
      sagaUnlocked: sagaUnlocked,
      failure: failure,
      muted: muted ?? this.muted,
      autoMuted: autoMuted ?? this.autoMuted,
      holdChoiceId: clearHold ? null : holdChoiceId ?? this.holdChoiceId,
      holdSerial: clearHold ? 0 : holdSerial ?? this.holdSerial,
      pendingRequestId: pendingRequestId ?? this.pendingRequestId,
      endingSpeaking: endingSpeaking ?? this.endingSpeaking,
      hiddenPaused: hiddenPaused ?? this.hiddenPaused,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is FeedState &&
        other.phase == phase &&
        other.storyId == storyId &&
        other.runId == runId &&
        other.playback == playback &&
        other.sagaUnlocked == sagaUnlocked &&
        other.failure == failure &&
        other.muted == muted &&
        other.autoMuted == autoMuted &&
        other.holdChoiceId == holdChoiceId &&
        other.holdSerial == holdSerial &&
        other.pendingRequestId == pendingRequestId &&
        other.endingSpeaking == endingSpeaking &&
        other.hiddenPaused == hiddenPaused;
  }

  @override
  int get hashCode => Object.hash(
    phase,
    storyId,
    runId,
    playback,
    sagaUnlocked,
    failure,
    muted,
    autoMuted,
    holdChoiceId,
    holdSerial,
    pendingRequestId,
    endingSpeaking,
    hiddenPaused,
  );
}
