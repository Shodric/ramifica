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

/// Resolves a preview tap target: the playback when its video is finished,
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
    this._resolvePreview,
    this._previewNodeLabel,
  }) : prefetcher = prefetcher ?? Prefetcher(),
       narrator = narrator ?? openNarrator(),
       _clock = clock ?? TimerCueClock(),
       _newRequestId = newRequestId ?? _uuidRequestId,
       _random = random ?? Random(),
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
    on<StorySwiped>(_onSwiped, transformer: restartable());
    on<PauseReached>(_onPause);
    on<UserGestured>(_onUserGestured);
    on<AppHidden>(_onAppHidden);
    on<MuteToggled>(_onMute);
    on<VideoTapped>(_onVideoTapped);
    on<VoiceFinished>(_onVoice);
    on<PreviewCueStarted>(_onPreviewCueStarted);
    on<PreviewChoiceTaken>(_onPreviewTaken);
    on<HoldStarted>(_onHold);
    on<HoldCancelled>(_onCancel);
    on<HoldCompleted>(_onHeld, transformer: droppable());
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

  Future<void> _onOpened(StoryOpened event, Emitter<FeedState> emit) async {
    if (_preview) return;
    final raw = event.storyId?.trim();
    await _loadStory(
      storyId: raw == null || raw.isEmpty ? null : raw,
      emit: emit,
    );
  }

  /// Draws another published story at random, excluding the current one,
  /// and opens it with the same resume rule. Only from `playing` or with
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

  /// Opens [storyId] (or lets the server pick when null) and parks on an
  /// ending or plays otherwise. Shared by [StoryOpened] and [StorySwiped].
  Future<void> _loadStory({
    required String? storyId,
    required Emitter<FeedState> emit,
  }) async {
    final muted = state.muted;
    final autoMuted = state.autoMuted;
    _holdSealed = false;
    _silence();
    emit(FeedState(phase: .loading, storyId: storyId));
    try {
      final started = await repository.startRun(storyId: storyId);
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
          muted: muted,
          autoMuted: autoMuted,
        ),
      );
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(FeedState(phase: .failed, storyId: storyId, failure: error.phrase));
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
    emit(state.copy(phase: .window, clearHold: true));
  }

  void _onPreviewCueStarted(PreviewCueStarted event, Emitter<FeedState> emit) {
    if (!_preview || state.phase != .speaking || state.hiddenPaused) return;
    emit(state.copy(previewCueStarted: true));
  }

  /// A preview tap on a hotspot. Jumps straight to the target draft scene
  /// and plays it like the feed would, with no hold, portal, or commit.
  /// A target with no finished video keeps the current scene and raises a
  /// transient notice instead, carrying the target when the editor can
  /// open it.
  void _onPreviewTaken(PreviewChoiceTaken event, Emitter<FeedState> emit) {
    if (!_preview) return;
    final zonesVisible =
        (state.phase == .speaking && state.previewCueStarted) ||
        state.phase == .window;
    if (!zonesVisible) return;
    final choice = _choice(event.choiceId);
    if (choice == null) return;
    final resolved = _resolvePreview?.call(choice.targetNodeId);
    final next = resolved?.playback;
    if (next == null) {
      final label =
          _previewNodeLabel?.call(choice.targetNodeId) ?? choice.targetNodeId;
      final editable = resolved?.exists ?? false;
      emit(
        state.copy(
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
    if (_preview) return;
    if (state.phase != .window) return;
    final choice = _choice(event.choiceId);
    if (choice == null) return;
    _startHold(choice, emit);
  }

  void _onCancel(HoldCancelled event, Emitter<FeedState> emit) {
    if (state.phase != .holding || _holdSealed) return;
    _holdSealed = false;
    emit(state.copy(phase: .window, clearHold: true));
  }

  Future<void> _onHeld(HoldCompleted event, Emitter<FeedState> emit) async {
    final playback = state.playback;
    final runId = state.runId;
    final holdChoiceId = state.holdChoiceId;
    if (state.phase != .holding) return;
    if (playback == null || runId == null || holdChoiceId == null) return;
    _holdSealed = true;
    final requestId = _newRequestId();
    emit(state.copy(phase: .committing, pendingRequestId: requestId));
    try {
      final result = await _commit(
        runId: runId,
        fromNodeId: playback.node.nodeId,
        choiceId: holdChoiceId,
        requestId: requestId,
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
        ),
      );
    }
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
    final muted = state.muted;
    final autoMuted = state.autoMuted;
    _holdSealed = false;
    _silence();
    emit(FeedState(phase: .loading, storyId: storyId));
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
          muted: muted,
          autoMuted: autoMuted,
        ),
      );
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(FeedState(phase: .failed, storyId: storyId, failure: error.phrase));
    }
  }

  void _onMap(MapRequested event, Emitter<FeedState> emit) {
    // Navigation belongs to the view: it reads the ShellBloc and opens the
    // map tab for this story. Kept here so the event has a handler.
  }

  void _startHold(PlaybackChoice choice, Emitter<FeedState> emit) {
    _holdSealed = false;
    final url = choice.target?.videoUrl.trim();
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
    return super.close();
  }
}

String _uuidRequestId() => const Uuid().v4();

Future<Map<String, dynamic>> _previewRunUnavailable(
  String operation,
  Map<String, dynamic> data,
) async => throw StateError('A preview cannot create or change a run.');
