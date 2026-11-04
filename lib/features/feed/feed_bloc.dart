import 'dart:async';
import 'dart:math';

import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:ramifica/core/cue_clock.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/web_audio.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/playback.dart';
import 'package:ramifica/data/repositories/catalog_repository.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:uuid/uuid.dart';

/// Resolves a preview hold target: the playback when its video is finished,
/// plus whether the target exists in the draft. An existing but unfinished
/// node shows a notice with an edit action; an unknown one shows the
/// notice alone.
typedef PreviewNodeResolver = ({Playback? playback, bool exists}) Function(
  String targetNodeId,
);

/// Display label for a draft node in preview notices, e.g. `1A`.
typedef PreviewNodeLabel = String Function(String targetNodeId);

class FeedBloc extends Bloc<FeedEvent, FeedState> {
  FeedBloc({
    required this.repository,
    this.catalog,
    Prefetcher? prefetcher,
    Narrator? narrator,
    CueClock? clock,
    String Function()? newRequestId,
    Random? random,
    Playback? previewPlayback,
    PreviewNodeResolver? resolvePreview,
    PreviewNodeLabel? previewNodeLabel,
  }) : prefetcher = prefetcher ?? Prefetcher(),
       narrator = narrator ?? openNarrator(),
       _clock = clock ?? TimerCueClock(),
       _newRequestId = newRequestId ?? _uuidRequestId,
       _random = random ?? Random(),
       _resolvePreview = resolvePreview,
       _previewNodeLabel = previewNodeLabel,
       _preview = previewPlayback != null,
       super(
         previewPlayback == null
             ? const FeedState()
             : FeedState(
                 phase: .playing,
                 storyId: previewPlayback.story.storyId,
                 runId: previewPlayback.runId,
                 playback: previewPlayback,
                 muted: false,
                 autoMuted: false,
               ),
       ) {
    on<StoryOpened>(_onOpened, transformer: restartable());
    on<PlaybackReloadRequested>(_onReload, transformer: restartable());
    on<StorySwiped>(_onSwiped, transformer: restartable());
    on<PauseReached>(_onPause);
    on<UserGestured>(_onUserGestured);
    on<AppHidden>(_onAppHidden);
    on<MuteToggled>(_onMute);
    on<VideoTapped>(_onVideoTapped);
    on<VoiceFinished>(_onVoice);
    on<PreviewCueStarted>(_onPreviewCueStarted);
    on<HoldStarted>(_onHold);
    on<HoldCancelled>(_onCancel);
    on<HoldCompleted>(_onHeld, transformer: droppable());
    on<BackgroundCommitAcked>(_onAcked);
    on<BackgroundCommitInvalid>(_onInvalidAck);
    on<OtherPathRequested>(_onOtherPath, transformer: restartable());
    on<MapRequested>(_onMap, transformer: droppable());
    final voice = previewPlayback?.node.ttsAudioUrl?.trim();
    if (voice != null && voice.isNotEmpty) {
      unawaited(this.narrator.prepare(voice));
    }
  }

  /// Plays a draft scene using the feed's normal phases without a server run.
  FeedBloc.preview({
    required Playback playback,
    Narrator? narrator,
    CueClock? clock,
    PreviewNodeResolver? resolvePreview,
    PreviewNodeLabel? previewNodeLabel,
  }) : this(
         repository: RunRepository(execute: _previewRunUnavailable),
         narrator: narrator,
         clock: clock,
         previewPlayback: playback,
         resolvePreview: resolvePreview,
         previewNodeLabel: previewNodeLabel,
       );

  final RunRepository repository;

  /// Published ids for the swipe draw. Null in tests that never swipe.
  final CatalogRepository? catalog;
  final Prefetcher prefetcher;
  final Narrator narrator;
  final CueClock _clock;
  final String Function() _newRequestId;
  final Random _random;
  final PreviewNodeResolver? _resolvePreview;
  final PreviewNodeLabel? _previewNodeLabel;
  final bool _preview;
  var _holdSealed = false;

  /// Background commits in send order. Holds enqueue; the pump sends
  /// serially so chained from-nodes validate. An offline head parks the
  /// pump until a gesture, a load, or a new hold resumes it.
  final List<_CommitItem> _commitQueue = [];
  var _commitPumpActive = false;
  var _commitParked = false;

  Future<void> _onOpened(StoryOpened event, Emitter<FeedState> emit) async {
    if (_preview) return;
    final raw = event.storyId?.trim();
    await _loadStory(
      storyId: raw == null || raw.isEmpty ? null : raw,
      emit: emit,
    );
  }

  /// Reloads the run current playback after the map moved it. Unlike
  /// [_loadStory] this restarts nothing: the run keeps its history and
  /// the feed opens wherever the pointer now sits. Run and playback
  /// stay put while loading, so the shell's reopen guard sees settled
  /// content and skips its StoryOpened instead of restarting.
  Future<void> _onReload(
    PlaybackReloadRequested event,
    Emitter<FeedState> emit,
  ) async {
    if (_preview) return;
    final runId = event.runId.trim();
    if (runId.isEmpty) return;
    // The map moved the pointer: parked from-nodes are stale, the rest of
    // the queue may resume.
    _dropRunCommits(runId);
    _pumpCommits(resume: true);
    _holdSealed = false;
    _silence();
    emit(
      FeedState(
        phase: .loading,
        storyId: state.storyId,
        runId: state.runId,
        playback: state.playback,
        muted: state.muted,
        autoMuted: state.autoMuted,
      ),
    );
    try {
      final playback = await repository.loadPlayback(runId);
      if (emit.isDone) return;
      prefetcher.warm(playback);
      final voice = playback.node.ttsAudioUrl?.trim();
      if (voice != null && voice.isNotEmpty) {
        unawaited(narrator.prepare(voice));
      }
      emit(
        FeedState(
          phase: playback.node.isEnding ? .ending : .playing,
          storyId: playback.story.storyId,
          runId: playback.runId,
          playback: playback,
          muted: state.muted,
          autoMuted: state.autoMuted,
        ),
      );
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(
        FeedState(
          phase: .failed,
          storyId: state.storyId,
          failure: error.phrase,
          muted: state.muted,
          autoMuted: state.autoMuted,
        ),
      );
    }
  }

  /// Draws another published story at random, excluding the current one,
  /// and opens it from its root. Only from `playing` or with
  /// the card visible; without another story, or without a catalog, it is
  /// ignored. Best-effort: a catalog failure keeps the current clip.
  Future<void> _onSwiped(StorySwiped event, Emitter<FeedState> emit) async {
    if (_preview) return;
    final current = state;
    final cardVisible = current.phase == .ending && !current.endingSpeaking;
    if (current.phase != .playing && !cardVisible) return;
    final catalog = this.catalog;
    final storyId = current.storyId;
    if (catalog == null || storyId == null || storyId.isEmpty) return;
    late final List<String> ids;
    try {
      ids = await catalog.publishedStoryIds();
    } on AppFailure {
      return;
    }
    final seen = <String>{};
    final others = <String>[
      for (final id in ids)
        if (id.trim().isNotEmpty && id != storyId && seen.add(id)) id,
    ];
    if (others.isEmpty || emit.isDone) return;
    await _loadStory(
      storyId: others[_random.nextInt(others.length)],
      emit: emit,
    );
  }

  /// Opens [storyId] (or lets the server pick when null) with a fresh run
  /// at the root, then parks on an ending or plays otherwise. Shared by
  /// [StoryOpened] and [StorySwiped]. Mute is read back from the current
  /// state on arrival, so a gesture that landed mid-load survives it.
  Future<void> _loadStory({
    required String? storyId,
    required Emitter<FeedState> emit,
  }) async {
    _holdSealed = false;
    _silence();
    _pumpCommits(resume: true);
    emit(
      FeedState(
        phase: .loading,
        storyId: storyId,
        muted: state.muted,
        autoMuted: state.autoMuted,
      ),
    );
    try {
      // Entering the feed always starts a fresh run at the root: a
      // finished story starts over instead of landing on its last
      // ending. A settled story never re-opens in session, so this
      // only resets on a real entry.
      final started = await repository.startRun(
        storyId: storyId,
        restart: true,
      );
      if (emit.isDone) return;
      final playback = await repository.loadPlayback(started.runId);
      if (emit.isDone) return;
      prefetcher.warm(playback);
      final voice = playback.node.ttsAudioUrl?.trim();
      if (voice != null && voice.isNotEmpty) {
        unawaited(narrator.prepare(voice));
      }
      emit(
        FeedState(
          phase: playback.node.isEnding ? .ending : .playing,
          storyId: playback.story.storyId,
          runId: playback.runId,
          playback: playback,
          muted: state.muted,
          autoMuted: state.autoMuted,
        ),
      );
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(
        FeedState(
          phase: .failed,
          storyId: storyId,
          failure: error.phrase,
          muted: state.muted,
          autoMuted: state.autoMuted,
        ),
      );
    }
  }

  void _onPause(PauseReached event, Emitter<FeedState> emit) {
    if (state.phase != .playing) return;
    final playback = state.playback;
    if (playback != null && playback.node.isEnding) {
      final speaking = _hasClosingLine;
      emit(state.copy(phase: .ending, endingSpeaking: speaking));
      if (speaking) _startCue();
      return;
    }
    emit(state.copy(phase: .speaking));
    _startCue();
  }

  void _onUserGestured(UserGestured event, Emitter<FeedState> emit) {
    // Any tap may restore the connection a parked commit waits for.
    _pumpCommits(resume: true);
    final hadAuto = state.autoMuted;
    final wasHidden = state.hiddenPaused;
    if (!hadAuto && !wasHidden) return;
    narrator.unlock();
    emit(
      state.copy(
        muted: hadAuto ? false : state.muted,
        autoMuted: false,
        hiddenPaused: false,
      ),
    );
    if (state.phase == .speaking ||
        (state.phase == .ending && state.endingSpeaking)) {
      _startCue();
    }
  }

  void _onAppHidden(AppHidden event, Emitter<FeedState> emit) {
    final speakingCue =
        state.phase == .speaking ||
        (state.phase == .ending && state.endingSpeaking);
    if (state.phase != .playing && !speakingCue) return;
    _silence();
    emit(state.copy(hiddenPaused: true));
  }

  void _onMute(MuteToggled event, Emitter<FeedState> emit) {
    emit(state.copy(muted: !state.muted, autoMuted: false));
    if (state.phase == .speaking ||
        (state.phase == .ending && state.endingSpeaking)) {
      _startCue();
    }
  }

  /// Toggles the tap pause. Only while the clip is playing: narration,
  /// decision, and ending phases ignore the tap, and so does a hidden
  /// clip (its wake tap belongs to [UserGestured]).
  void _onVideoTapped(VideoTapped event, Emitter<FeedState> emit) {
    if (state.phase != .playing || state.hiddenPaused) return;
    emit(state.copy(userPaused: !state.userPaused));
  }

  void _onVoice(VoiceFinished event, Emitter<FeedState> emit) {
    if (state.phase == .ending) {
      if (!state.endingSpeaking) return;
      _clock.cancel();
      narrator.stop();
      emit(state.copy(endingSpeaking: false));
      return;
    }
    if (state.phase != .speaking) return;
    _clock.cancel();
    narrator.stop();
    _holdSealed = false;
    _preloadChoiceTargets();
    emit(state.copy(phase: .window, clearHold: true));
  }

  void _onPreviewCueStarted(PreviewCueStarted event, Emitter<FeedState> emit) {
    if (!_preview || state.phase != .speaking || state.hiddenPaused) return;
    emit(state.copy(previewCueStarted: true));
  }

  /// A preview hold ran its full 1.5 seconds. Arrives like the feed would,
  /// locally: the preview has no run to commit, so the held choice jumps
  /// straight to the target draft scene. A target with no finished video
  /// keeps the current scene, falls back to the window, and raises a
  /// transient notice instead, carrying the target when the editor can
  /// open it.
  void _previewArrive(Emitter<FeedState> emit) {
    if (state.phase != .holding) return;
    final heldId = state.holdChoiceId;
    final choice = heldId == null ? null : _choice(heldId);
    if (choice == null) return;
    final resolved = _resolvePreview?.call(choice.targetNodeId);
    final next = resolved?.playback;
    if (next == null) {
      final label =
          _previewNodeLabel?.call(choice.targetNodeId) ?? choice.targetNodeId;
      final editable = resolved?.exists ?? false;
      _preloadChoiceTargets();
      emit(
        state.copy(
          phase: .window,
          clearHold: true,
          previewNotice: 'Node "$label" not finished yet',
          previewNoticeSerial: state.previewNoticeSerial + 1,
          previewNoticeTarget: editable ? choice.targetNodeId : null,
          clearPreviewNoticeTarget: !editable,
        ),
      );
      return;
    }
    _holdSealed = false;
    _silence();
    prefetcher.warm(next);
    final voice = next.node.ttsAudioUrl?.trim();
    if (voice != null && voice.isNotEmpty) {
      unawaited(narrator.prepare(voice));
    }
    emit(
      FeedState(
        phase: .playing,
        storyId: next.story.storyId,
        runId: next.runId,
        playback: next,
        muted: state.muted,
        autoMuted: state.autoMuted,
      ),
    );
  }

  void _onHold(HoldStarted event, Emitter<FeedState> emit) {
    if (_preview) {
      // The preview shows its zones early, once the cue starts, so a
      // hold may begin mid-narration too, like in the feed.
      final zonesUp =
          (state.phase == .speaking && state.previewCueStarted) ||
          state.phase == .window;
      if (!zonesUp) return;
    } else if (state.phase != .window && state.phase != .speaking) {
      return;
    }
    final choice = _choice(event.choiceId);
    if (choice == null) return;
    _startHold(choice, emit);
  }

  void _onCancel(HoldCancelled event, Emitter<FeedState> emit) {
    // A cancelled mid-narration hold lands in the window: the grab
    // already cut the cue, so there is nothing to resume.
    if (state.phase != .holding || _holdSealed) return;
    _holdSealed = false;
    _preloadChoiceTargets();
    emit(state.copy(phase: .window, clearHold: true));
  }

  Future<void> _onHeld(HoldCompleted event, Emitter<FeedState> emit) async {
    if (_preview) {
      _previewArrive(emit);
      return;
    }
    final playback = state.playback;
    final runId = state.runId;
    final holdChoiceId = state.holdChoiceId;
    if (state.phase != .holding) return;
    if (playback == null || runId == null || holdChoiceId == null) return;
    final choice = _choice(holdChoiceId);
    final scene = choice == null ? null : playback.nodes[choice.targetNodeId];
    if (choice != null && scene != null) {
      // The scene table knows the destination: arrive now, commit behind.
      _arriveLocal(scene, choice, runId, emit);
      return;
    }
    // Legacy publication without a scene table: await the commit, which
    // is also the only way to learn the destination clip.
    _holdSealed = true;
    final requestId = _newRequestId();
    emit(state.copy(phase: .committing, pendingRequestId: requestId));
    try {
      final result = await _enqueueCommit(
        runId: runId,
        fromNodeId: playback.node.nodeId,
        choiceId: holdChoiceId,
        toNodeId: choice?.targetNodeId ?? '',
        requestId: requestId,
        events: false,
      );
      if (emit.isDone) return;
      _arrive(result, emit);
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      if (error.code == .invalid) {
        await _recover(runId, emit);
        return;
      }
      emit(
        FeedState(
          phase: .failed,
          storyId: state.storyId,
          runId: runId,
          failure: error.phrase,
          muted: state.muted,
          autoMuted: state.autoMuted,
        ),
      );
    }
  }

  /// Arrives at a scene-table destination without waiting for the commit.
  /// Mirrors [_arrive]: fresh state on `playing`, warmed clip, prepared
  /// voice. The commit runs behind (see [_enqueueCommit]); its ending
  /// outcome reconciles through [BackgroundCommitAcked].
  void _arriveLocal(
    PlaybackScene scene,
    PlaybackChoice choice,
    String runId,
    Emitter<FeedState> emit,
  ) {
    final current = state.playback!;
    final requestId = _newRequestId();
    // The outcome arrives via ack events; a parked error stays silent.
    unawaited(
      _enqueueCommit(
        runId: runId,
        fromNodeId: current.node.nodeId,
        choiceId: choice.choiceId,
        toNodeId: choice.targetNodeId,
        requestId: requestId,
      ).then<void>((_) {}, onError: (_) {}),
    );
    final next = Playback(
      runId: current.runId,
      status: scene.node.isEnding ? RunStatus.ended : RunStatus.active,
      story: current.story,
      node: scene.node,
      choices: scene.choices,
      nodes: current.nodes,
    );
    _holdSealed = false;
    _silence();
    prefetcher.warm(next);
    final voice = next.node.ttsAudioUrl?.trim();
    if (voice != null && voice.isNotEmpty) {
      unawaited(narrator.prepare(voice));
    }
    emit(
      FeedState(
        phase: .playing,
        storyId: next.story.storyId,
        runId: next.runId,
        playback: next,
        muted: state.muted,
        autoMuted: state.autoMuted,
      ),
    );
  }

  /// Reconciles a background commit's ending outcome: the saga unlock and
  /// the reward code the scene table cannot know. Anything for another run
  /// or an older destination is dropped, and settled values never re-emit.
  void _onAcked(BackgroundCommitAcked event, Emitter<FeedState> emit) {
    if (_preview) return;
    if (state.runId != event.runId) return;
    final playback = state.playback;
    if (playback == null || playback.node.nodeId != event.toNodeId) return;
    final saga = event.sagaUnlocked;
    final code = event.rewardCode;
    final settled =
        (saga == null || saga == state.sagaUnlocked) &&
        (code == null || code == playback.node.rewardCode);
    if (settled) return;
    emit(
      state.copy(
        playback: code == null
            ? null
            : Playback(
                runId: playback.runId,
                status: playback.status,
                story: playback.story,
                node: playback.node.copy(rewardCode: code),
                choices: playback.choices,
                nodes: playback.nodes,
              ),
        sagaUnlocked: saga,
      ),
    );
  }

  /// A background commit was rejected as invalid: something else moved the
  /// run, so the locally shown destination may be wrong. Reloads the truth.
  Future<void> _onInvalidAck(
    BackgroundCommitInvalid event,
    Emitter<FeedState> emit,
  ) async {
    if (_preview) return;
    if (state.runId != event.runId) return;
    await _recover(event.runId, emit);
  }

  /// Sends the hold once. A lost network sends it again with the same
  /// `requestId`, and the server answers the stored result.
  Future<CommitResult> _commit({
    required String runId,
    required String fromNodeId,
    required String choiceId,
    required String requestId,
  }) async {
    try {
      return await repository.commitChoice(
        runId: runId,
        fromNodeId: fromNodeId,
        choiceId: choiceId,
        requestId: requestId,
      );
    } on AppFailure catch (error) {
      if (error.code != .offline) rethrow;
      return repository.commitChoice(
        runId: runId,
        fromNodeId: fromNodeId,
        choiceId: choiceId,
        requestId: requestId,
      );
    }
  }

  /// Enqueues a commit behind earlier holds and pumps the queue. Items send
  /// strictly in order, so back-to-back holds validate their chained
  /// from-nodes. A re-hold from the same scene drops parked (never sent)
  /// items for it: the finger changed its mind while offline. With [events]
  /// the worker also reports through [BackgroundCommitAcked] and
  /// [BackgroundCommitInvalid]; the legacy path awaits the future instead
  /// and passes false.
  Future<CommitResult> _enqueueCommit({
    required String runId,
    required String fromNodeId,
    required String choiceId,
    required String toNodeId,
    required String requestId,
    bool events = true,
  }) {
    for (final stale in _commitQueue
        .where(
          (item) =>
              !item.active &&
              item.runId == runId &&
              item.fromNodeId == fromNodeId,
        )
        .toList()) {
      _commitQueue.remove(stale);
      stale.fail(const AppFailure(.invalid));
    }
    final item = _CommitItem(
      runId: runId,
      fromNodeId: fromNodeId,
      choiceId: choiceId,
      toNodeId: toNodeId,
      requestId: requestId,
      events: events,
    );
    _commitQueue.add(item);
    _pumpCommits(resume: true);
    return item.future;
  }

  /// Drops parked commits for [runId] without reporting: the map moved the
  /// pointer, so their from-nodes are stale by definition.
  void _dropRunCommits(String runId) {
    for (final item in _commitQueue
        .where((item) => !item.active && item.runId == runId)
        .toList()) {
      _commitQueue.remove(item);
      item.fail(const AppFailure(.invalid));
    }
  }

  /// Starts the pump unless it runs already. A parked pump only resumes
  /// with [resume], so a failed head never spins on its own.
  void _pumpCommits({bool resume = false}) {
    if (_commitPumpActive || isClosed) return;
    if (_commitParked && !resume) return;
    _commitParked = false;
    _commitPumpActive = true;
    unawaited(
      _pump().whenComplete(() {
        _commitPumpActive = false;
        // An enqueue that landed between the last check and this reset
        // must not strand: repump drained queues, never parked ones.
        if (_commitQueue.isNotEmpty && !_commitParked && !isClosed) {
          _pumpCommits();
        }
      }),
    );
  }

  /// Sends queued commits head-first. An invalid head is terminal for that
  /// hold (something else moved the run); any other failure parks the pump
  /// with the head kept, so a later gesture or hold resumes it. Parked
  /// legacy waiters fail loudly; local holds already arrived and only
  /// listen for ack events.
  Future<void> _pump() async {
    while (_commitQueue.isNotEmpty && !isClosed) {
      final item = _commitQueue.first;
      item.active = true;
      try {
        final result = await _commit(
          runId: item.runId,
          fromNodeId: item.fromNodeId,
          choiceId: item.choiceId,
          requestId: item.requestId,
        );
        _commitQueue.remove(item);
        item.active = false;
        item.win(result);
        if (item.events && !isClosed) {
          add(
            BackgroundCommitAcked(
              runId: item.runId,
              toNodeId: item.toNodeId,
              sagaUnlocked: result.sagaUnlocked,
              rewardCode: result.reward?.code,
            ),
          );
        }
      } on AppFailure catch (error) {
        item.active = false;
        if (error.code == .invalid) {
          _commitQueue.remove(item);
          item.fail(error);
          if (item.events && !isClosed) {
            add(BackgroundCommitInvalid(item.runId));
          }
        } else {
          item.fail(error);
          _commitParked = true;
          return;
        }
      }
    }
  }

  /// The server rejected the hold. Asks where the run really is and
  /// continues from that node. A parked `ended` run shows the card without
  /// replaying the clip.
  Future<void> _recover(String runId, Emitter<FeedState> emit) async {
    try {
      final playback = await repository.loadPlayback(runId);
      if (emit.isDone) return;
      _park(playback, emit);
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(
        FeedState(
          phase: .failed,
          storyId: state.storyId,
          runId: runId,
          failure: error.phrase,
          muted: state.muted,
          autoMuted: state.autoMuted,
        ),
      );
    }
  }

  /// A fresh destination. An ending still plays its clip once from the start;
  /// only a reopened `ended` run parks on the last frame (see `_park`).
  /// The saga unlock rides along so the card announces it exactly once:
  /// reopens come through `_park`, which leaves it null.
  void _arrive(CommitResult result, Emitter<FeedState> emit) {
    final next = result.playback;
    _holdSealed = false;
    prefetcher.warm(next);
    final voice = next.node.ttsAudioUrl?.trim();
    if (voice != null && voice.isNotEmpty) {
      unawaited(narrator.prepare(voice));
    }
    emit(
      FeedState(
        phase: .playing,
        storyId: next.story.storyId,
        runId: next.runId,
        playback: next,
        sagaUnlocked: result.sagaUnlocked,
        muted: state.muted,
        autoMuted: state.autoMuted,
      ),
    );
  }

  /// Parks on the current node without playing. Used for reopened `ended`
  /// runs and for `invalid` recoveries that land on an ending.
  void _park(Playback next, Emitter<FeedState> emit) {
    _holdSealed = false;
    prefetcher.warm(next);
    final voice = next.node.ttsAudioUrl?.trim();
    if (voice != null && voice.isNotEmpty) {
      unawaited(narrator.prepare(voice));
    }
    emit(
      FeedState(
        phase: next.node.isEnding ? .ending : .playing,
        storyId: next.story.storyId,
        runId: next.runId,
        playback: next,
        muted: state.muted,
        autoMuted: state.autoMuted,
      ),
    );
  }

  Future<void> _onOtherPath(
    OtherPathRequested event,
    Emitter<FeedState> emit,
  ) async {
    if (_preview) return;
    if (state.phase != .ending) return;
    final storyId = state.storyId;
    _holdSealed = false;
    _silence();
    _pumpCommits(resume: true);
    emit(
      FeedState(
        phase: .loading,
        storyId: storyId,
        muted: state.muted,
        autoMuted: state.autoMuted,
      ),
    );
    try {
      final started = await repository.startRun(
        storyId: storyId,
        restart: true,
      );
      if (emit.isDone) return;
      final playback = await repository.loadPlayback(started.runId);
      if (emit.isDone) return;
      prefetcher.warm(playback);
      final voice = playback.node.ttsAudioUrl?.trim();
      if (voice != null && voice.isNotEmpty) {
        unawaited(narrator.prepare(voice));
      }
      emit(
        FeedState(
          phase: .playing,
          storyId: playback.story.storyId,
          runId: playback.runId,
          playback: playback,
          muted: state.muted,
          autoMuted: state.autoMuted,
        ),
      );
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(
        FeedState(
          phase: .failed,
          storyId: storyId,
          failure: error.phrase,
          muted: state.muted,
          autoMuted: state.autoMuted,
        ),
      );
    }
  }

  void _onMap(MapRequested event, Emitter<FeedState> emit) {
    // Navigation belongs to the view: it reads the ShellBloc and opens the
    // map tab for this story. Kept here so the event has a handler.
  }

  /// Warms every choice target clip for the current scene. Runs each
  /// time the window opens so destinations load before the hold.
  /// Best-effort only: `warm` resolves through the scene table and skips
  /// targets without a URL, duplicate warms are harmless, and any failure
  /// is swallowed instead of reaching bloc state.
  void _preloadChoiceTargets() {
    final playback = state.playback;
    if (playback == null) return;
    try {
      prefetcher.warm(playback);
    } catch (_) {
      // A failed preload must never surface into bloc state.
    }
  }

  void _startHold(PlaybackChoice choice, Emitter<FeedState> emit) {
    _holdSealed = false;
    // A hold may begin mid-narration; grabbing a choice cuts the cue.
    // At window nothing is playing, so this is a no-op there.
    _silence();
    final scene = state.playback?.nodes[choice.targetNodeId];
    final url = (scene?.node.videoUrl ?? choice.target?.videoUrl)?.trim();
    if (url != null && url.isNotEmpty) prefetcher.promote(url);
    emit(
      state.copy(
        phase: .holding,
        holdChoiceId: choice.choiceId,
        holdSerial: state.holdSerial + 1,
      ),
    );
  }

  PlaybackChoice? _choice(String id) {
    final choices = state.playback?.choices;
    if (choices == null) return null;
    for (final choice in choices) {
      if (choice.choiceId == id) return choice;
    }
    return null;
  }

  void _startCue() {
    _silence();
    final line = _lineDuration();
    if (!_hasVoice && line == null) {
      add(const VoiceFinished());
      return;
    }
    if (state.muted || !_hasVoice) {
      if (line == null) {
        add(const VoiceFinished());
        return;
      }
      if (_preview) add(const PreviewCueStarted());
      _clock.schedule(line, _finishCue);
      return;
    }
    unawaited(_playVoice());
  }

  Future<void> _playVoice() async {
    final played = await narrator.play(onEnded: _finishCue);
    if (isClosed) return;
    final speaking =
        state.phase == .speaking ||
        (state.phase == .ending && state.endingSpeaking);
    if (!speaking) return;
    if (played && !state.muted) {
      if (_preview) add(const PreviewCueStarted());
      return;
    }
    if (played) narrator.stop();
    final line = _lineDuration();
    if (line == null) {
      _finishCue();
      return;
    }
    if (_preview) add(const PreviewCueStarted());
    _clock.schedule(line, _finishCue);
  }

  void _finishCue() {
    if (isClosed) return;
    add(const VoiceFinished());
  }

  bool get _hasVoice {
    final url = state.playback?.node.ttsAudioUrl?.trim();
    return url != null && url.isNotEmpty;
  }

  bool get _hasClosingLine => _hasVoice || _lineDuration() != null;

  Duration? _lineDuration() {
    final node = state.playback?.node;
    final text = node?.ttsText?.trim();
    final seconds = node?.ttsDurationSeconds;
    if (text == null || text.isEmpty || seconds == null || seconds <= 0) {
      return null;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }

  void _silence() {
    _clock.cancel();
    narrator.stop();
  }

  @override
  Future<void> close() {
    _silence();
    narrator.dispose();
    prefetcher.dispose();
    // The pump checks isClosed; dropped futures settle nowhere.
    _commitQueue.clear();
    return super.close();
  }
}

String _uuidRequestId() => const Uuid().v4();

/// One queued hold. The future settles exactly once: the legacy path
/// awaits it, while local holds swallow it and listen for ack events.
class _CommitItem {
  _CommitItem({
    required this.runId,
    required this.fromNodeId,
    required this.choiceId,
    required this.toNodeId,
    required this.requestId,
    required this.events,
  });

  final String runId;
  final String fromNodeId;
  final String choiceId;
  final String toNodeId;
  final String requestId;
  final bool events;

  /// True while a send is in flight. Only idle items are superseded.
  var active = false;
  var _settled = false;
  final _done = Completer<CommitResult>();

  Future<CommitResult> get future => _done.future;

  void win(CommitResult result) {
    if (_settled) return;
    _settled = true;
    _done.complete(result);
  }

  void fail(Object error) {
    if (_settled) return;
    _settled = true;
    _done.completeError(error);
  }
}

Future<Map<String, dynamic>> _previewRunUnavailable(
  String operation,
  Map<String, dynamic> data,
) async => throw StateError('A preview cannot create or change a run.');
