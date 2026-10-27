import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:ramifica/core/cue_clock.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/web_audio.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/playback.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:uuid/uuid.dart';

class FeedBloc extends Bloc<FeedEvent, FeedState> {
  FeedBloc({
    required this.repository,
    Prefetcher? prefetcher,
    Narrator? narrator,
    CueClock? clock,
    String Function()? newRequestId,
  }) : prefetcher = prefetcher ?? Prefetcher(),
       narrator = narrator ?? openNarrator(),
       _clock = clock ?? TimerCueClock(),
       _newRequestId = newRequestId ?? _uuidRequestId,
       super(const FeedState()) {
    on<StoryOpened>(_onOpened, transformer: restartable());
    on<PauseReached>(_onPause);
    on<MuteToggled>(_onMute);
    on<VoiceFinished>(_onVoice);
    on<HoldStarted>(_onHold);
    on<HoldCancelled>(_onCancel);
    on<HoldCompleted>(_onHeld, transformer: droppable());
    on<WindowElapsed>(_onWindow);
  }

  final RunRepository repository;
  final Prefetcher prefetcher;
  final Narrator narrator;
  final CueClock _clock;
  final String Function() _newRequestId;
  var _windowSpent = false;
  var _holdSealed = false;

  Future<void> _onOpened(StoryOpened event, Emitter<FeedState> emit) async {
    _windowSpent = false;
    _holdSealed = false;
    _silence();
    final raw = event.storyId?.trim();
    final storyId = raw == null || raw.isEmpty ? null : raw;
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
          phase: playback.status == .ended ? .ending : .playing,
          storyId: playback.story.storyId,
          runId: playback.runId,
          playback: playback,
        ),
      );
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(FeedState(phase: .failed, storyId: storyId, failure: error.phrase));
    }
  }

  void _onPause(PauseReached event, Emitter<FeedState> emit) {
    if (state.phase != .playing) return;
    emit(state.copy(phase: .speaking));
    _startCue();
  }

  void _onMute(MuteToggled event, Emitter<FeedState> emit) {
    emit(state.copy(muted: !state.muted, autoMuted: false));
    if (state.phase == .speaking) _startCue();
  }

  void _onVoice(VoiceFinished event, Emitter<FeedState> emit) {
    if (state.phase != .speaking) return;
    _clock.cancel();
    narrator.stop();
    _windowSpent = false;
    _holdSealed = false;
    emit(state.copy(phase: .window, clearHold: true));
    _armWindow();
  }

  void _onHold(HoldStarted event, Emitter<FeedState> emit) {
    if (state.phase != .window) return;
    final choice = _choice(event.choiceId);
    if (choice == null) return;
    _startHold(choice, emit);
  }

  void _onCancel(HoldCancelled event, Emitter<FeedState> emit) {
    if (state.phase != .holding || _holdSealed) return;
    if (_windowSpent) {
      final fallback = _defaultChoice;
      if (fallback != null) {
        _startHold(fallback, emit);
        return;
      }
    }
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
      _arrive(result.playback, emit);
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
  /// continues from that node.
  Future<void> _recover(String runId, Emitter<FeedState> emit) async {
    try {
      final playback = await repository.loadPlayback(runId);
      if (emit.isDone) return;
      _arrive(playback, emit);
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

  void _arrive(Playback next, Emitter<FeedState> emit) {
    _windowSpent = false;
    _holdSealed = false;
    prefetcher.warm(next);
    final voice = next.node.ttsAudioUrl?.trim();
    if (voice != null && voice.isNotEmpty) {
      unawaited(narrator.prepare(voice));
    }
    emit(
      FeedState(
        phase: next.status == .ended ? .ending : .playing,
        storyId: next.story.storyId,
        runId: next.runId,
        playback: next,
        muted: state.muted,
        autoMuted: state.autoMuted,
      ),
    );
  }

  void _onWindow(WindowElapsed event, Emitter<FeedState> emit) {
    if (state.phase == .holding) {
      _windowSpent = true;
      return;
    }
    if (state.phase != .window) return;
    _windowSpent = true;
    final fallback = _defaultChoice;
    if (fallback == null) return;
    _startHold(fallback, emit);
  }

  void _armWindow() {
    final playback = state.playback;
    if (playback == null || playback.node.isEnding) return;
    if (playback.choices.isEmpty || playback.node.windowSeconds <= 0) return;
    _clock.schedule(
      Duration(milliseconds: playback.node.windowSeconds * 1000),
      _finishWindow,
    );
  }

  void _finishWindow() {
    if (isClosed) return;
    add(const WindowElapsed());
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

  PlaybackChoice? get _defaultChoice {
    final choices = state.playback?.choices;
    if (choices == null) return null;
    for (final choice in choices) {
      if (choice.isDefault) return choice;
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
      _clock.schedule(line, _finishCue);
      return;
    }
    unawaited(_playVoice());
  }

  Future<void> _playVoice() async {
    final played = await narrator.play(onEnded: _finishCue);
    if (isClosed || state.phase != .speaking) return;
    if (played && !state.muted) return;
    if (played) narrator.stop();
    final line = _lineDuration();
    if (line == null) {
      _finishCue();
      return;
    }
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
