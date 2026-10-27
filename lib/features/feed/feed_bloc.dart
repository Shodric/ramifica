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

class FeedBloc extends Bloc<FeedEvent, FeedState> {
  FeedBloc({
    required this.repository,
    Prefetcher? prefetcher,
    Narrator? narrator,
    CueClock? clock,
  }) : prefetcher = prefetcher ?? Prefetcher(),
       narrator = narrator ?? openNarrator(),
       _clock = clock ?? TimerCueClock(),
       super(const FeedState()) {
    on<StoryOpened>(_onOpened, transformer: restartable());
    on<PauseReached>(_onPause);
    on<MuteToggled>(_onMute);
    on<VoiceFinished>(_onVoice);
    on<HoldStarted>(_onHold);
    on<HoldCancelled>(_onCancel);
    on<HoldCompleted>(_onHeld);
    on<WindowElapsed>(_onWindow);
  }

  final RunRepository repository;
  final Prefetcher prefetcher;
  final Narrator narrator;
  final CueClock _clock;
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

  void _onHeld(HoldCompleted event, Emitter<FeedState> emit) {
    if (state.phase != .holding) return;
    _holdSealed = true;
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
