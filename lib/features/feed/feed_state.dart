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
    this.userPaused = false,
    this.previewCueStarted = false,
    this.previewNotice,
    this.previewNoticeSerial = 0,
    this.previewNoticeTarget,
    this.nextPlayback,
  });
  final FeedPhase phase;
  final String? storyId;
  final String? runId;
  final Playback? playback;

  /// The precached root playback of the swipe queue's head, painted on
  /// page 1 while page 0 holds the open story. Mounting it is instant;
  /// a swipe that draws another story falls back to a normal load.
  final Playback? nextPlayback;

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

  /// The viewer paused the clip with a tap. Cleared by the next tap or by
  /// any transition that replaces the playback; mute and narration cues
  /// are untouched.
  final bool userPaused;

  /// The preview's narration (or muted subtitle) has actually started.
  final bool previewCueStarted;

  /// A transient preview message, e.g. a held target with no finished
  /// video. The view shows it as a snackbar; it never changes the phase.
  final String? previewNotice;

  /// Bumps every time [previewNotice] is set, so the same message twice
  /// in a row still shows twice.
  final int previewNoticeSerial;

  /// The unfinished target behind [previewNotice], when it exists in the
  /// draft and the editor can open it. Null for unknown targets and
  /// outside the preview notice flow.
  final String? previewNoticeTarget;

  FeedState copy({
    FeedPhase? phase,
    Playback? playback,
    Playback? Function()? nextPlayback,
    SagaUnlocked? sagaUnlocked,
    bool? muted,
    bool? autoMuted,
    String? holdChoiceId,
    int? holdSerial,
    bool clearHold = false,
    String? pendingRequestId,
    bool? endingSpeaking,
    bool? hiddenPaused,
    bool? userPaused,
    bool? previewCueStarted,
    String? previewNotice,
    int? previewNoticeSerial,
    String? previewNoticeTarget,
    bool clearPreviewNoticeTarget = false,
  }) {
    return FeedState(
      phase: phase ?? this.phase,
      storyId: storyId,
      runId: runId,
      playback: playback ?? this.playback,
      nextPlayback: nextPlayback == null ? this.nextPlayback : nextPlayback(),
      sagaUnlocked: sagaUnlocked ?? this.sagaUnlocked,
      failure: failure,
      muted: muted ?? this.muted,
      autoMuted: autoMuted ?? this.autoMuted,
      holdChoiceId: clearHold ? null : holdChoiceId ?? this.holdChoiceId,
      holdSerial: clearHold ? 0 : holdSerial ?? this.holdSerial,
      pendingRequestId: pendingRequestId ?? this.pendingRequestId,
      endingSpeaking: endingSpeaking ?? this.endingSpeaking,
      hiddenPaused: hiddenPaused ?? this.hiddenPaused,
      userPaused: userPaused ?? this.userPaused,
      previewCueStarted: previewCueStarted ?? this.previewCueStarted,
      previewNotice: previewNotice ?? this.previewNotice,
      previewNoticeSerial: previewNoticeSerial ?? this.previewNoticeSerial,
      previewNoticeTarget: clearPreviewNoticeTarget
          ? null
          : previewNoticeTarget ?? this.previewNoticeTarget,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is FeedState &&
        other.phase == phase &&
        other.storyId == storyId &&
        other.runId == runId &&
        other.playback == playback &&
        other.nextPlayback == nextPlayback &&
        other.sagaUnlocked == sagaUnlocked &&
        other.failure == failure &&
        other.muted == muted &&
        other.autoMuted == autoMuted &&
        other.holdChoiceId == holdChoiceId &&
        other.holdSerial == holdSerial &&
        other.pendingRequestId == pendingRequestId &&
        other.endingSpeaking == endingSpeaking &&
        other.hiddenPaused == hiddenPaused &&
        other.userPaused == userPaused &&
        other.previewCueStarted == previewCueStarted &&
        other.previewNotice == previewNotice &&
        other.previewNoticeSerial == previewNoticeSerial &&
        other.previewNoticeTarget == previewNoticeTarget;
  }

  @override
  int get hashCode => Object.hash(
    phase,
    storyId,
    runId,
    playback,
    nextPlayback,
    sagaUnlocked,
    failure,
    muted,
    autoMuted,
    holdChoiceId,
    holdSerial,
    pendingRequestId,
    endingSpeaking,
    hiddenPaused,
    userPaused,
    previewCueStarted,
    previewNotice,
    previewNoticeSerial,
    previewNoticeTarget,
  );
}
