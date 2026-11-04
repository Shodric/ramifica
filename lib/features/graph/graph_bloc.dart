import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/repositories/graph_repository.dart';
import 'package:ramifica/features/graph/graph_event.dart';
import 'package:ramifica/features/graph/graph_state.dart';

class GraphBloc extends Bloc<GraphEvent, GraphState> {
  GraphBloc({required this.repository}) : super(const GraphState()) {
    on<GraphRequested>(_onRequested, transformer: restartable());
    on<NodeSelected>(_onSelected);
    on<PlayRequested>(_onPlay, transformer: droppable());
    on<ContinueRequested>(_onContinue, transformer: droppable());
    on<ApproachRequested>(_onApproach, transformer: droppable());
    on<RewindRequested>(_onRewind, transformer: droppable());
  }

  final GraphRepository repository;

  Future<void> _onRequested(
    GraphRequested event,
    Emitter<GraphState> emit,
  ) async {
    final story = event.storyId.trim();
    var run = event.runId.trim();
    if (story.isEmpty) {
      emit(const GraphState(phase: .loaded));
      return;
    }
    emit(
      GraphState(
        phase: .loading,
        storyId: story,
        runId: run.isEmpty ? null : run,
      ),
    );
    try {
      if (run.isEmpty) {
        run = await repository.resumeRun(story);
        if (emit.isDone) return;
      }
      final result = await repository.fetchStubs(storyId: story, runId: run);
      if (emit.isDone) return;
      emit(
        GraphState(
          phase: .loaded,
          storyId: story,
          runId: run,
          stubs: result.nodes,
          currentNodeId: result.currentNodeId,
          storyTitle: result.storyTitle,
          storyCoverUrl: result.storyCoverUrl,
          storyAuthorId: result.storyAuthorId,
          storyAuthorName: result.storyAuthorName,
          storyAuthorPhotoUrl: result.storyAuthorPhotoUrl,
          selectedId: result.currentNodeId,
          acting: false,
        ),
      );
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(
        GraphState(
          phase: .failed,
          storyId: story,
          runId: run.isEmpty ? null : run,
          failure: error.hint,
          missing: error.unavailable,
        ),
      );
    }
  }

  void _onSelected(NodeSelected event, Emitter<GraphState> emit) {
    if (state.phase != .loaded) return;
    final id = event.nodeId.trim();
    if (id.isEmpty) return;
    var known = false;
    for (final stub in state.stubs) {
      if (stub.nodeId == id) {
        known = true;
        break;
      }
    }
    if (!known) return;
    emit(state.copy(selectedId: () => id, failure: () => null));
  }

  Future<void> _onPlay(PlayRequested event, Emitter<GraphState> emit) async {
    if (state.phase != .loaded || state.acting) return;
    final run = state.runId;
    final story = state.storyId;
    final node = event.nodeId.trim();
    if (run == null ||
        run.isEmpty ||
        story == null ||
        story.isEmpty ||
        node.isEmpty) {
      emit(state.copy(failure: () => const AppFailure(.invalid).phrase));
      return;
    }
    emit(state.copy(acting: true, failure: () => null));
    try {
      final playback = await repository.jumpToNode(runId: run, nodeId: node);
      if (emit.isDone) return;
      final refreshed = await repository.fetchStubs(storyId: story, runId: run);
      if (emit.isDone) return;
      emit(
        state.copy(
          acting: false,
          stubs: refreshed.nodes,
          currentNodeId: () => playback.node.nodeId,
          selectedId: () => playback.node.nodeId,
        ),
      );
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(state.copy(acting: false, failure: () => error.phrase));
    }
  }

  void _onContinue(ContinueRequested event, Emitter<GraphState> emit) {
    if (state.phase != .loaded) return;
    final current = state.currentNodeId;
    if (current == null) return;
    emit(state.copy(selectedId: () => current, failure: () => null));
  }

  Future<void> _onApproach(
    ApproachRequested event,
    Emitter<GraphState> emit,
  ) async {
    if (state.phase != .loaded || state.acting) return;
    final run = state.runId;
    final node = event.nodeId.trim();
    if (run == null || run.isEmpty || node.isEmpty) {
      emit(state.copy(failure: () => const AppFailure(.invalid).phrase));
      return;
    }
    emit(state.copy(acting: true, failure: () => null));
    try {
      final playback = await repository.playApproach(runId: run, nodeId: node);
      if (emit.isDone) return;
      var select = playback.node.nodeId;
      var known = false;
      for (final stub in state.stubs) {
        if (stub.nodeId == select) {
          known = true;
          break;
        }
      }
      if (!known) select = node;
      emit(state.copy(acting: false, selectedId: () => select));
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(state.copy(acting: false, failure: () => error.phrase));
    }
  }

  Future<void> _onRewind(
    RewindRequested event,
    Emitter<GraphState> emit,
  ) async {
    if (state.phase != .loaded || state.acting) return;
    final run = state.runId;
    final story = state.storyId;
    if (run == null || run.isEmpty || story == null || story.isEmpty) {
      emit(state.copy(failure: () => const AppFailure(.invalid).phrase));
      return;
    }
    emit(state.copy(acting: true, failure: () => null));
    try {
      final playback = await repository.rewind(run);
      if (emit.isDone) return;
      final refreshed = await repository.fetchStubs(storyId: story, runId: run);
      if (emit.isDone) return;
      emit(
        state.copy(
          acting: false,
          stubs: refreshed.nodes,
          currentNodeId: () => playback.node.nodeId,
          selectedId: () => playback.node.nodeId,
        ),
      );
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(state.copy(acting: false, failure: () => error.phrase));
    }
  }
}
