import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/feed/feed_state.dart';

class FeedBloc extends Bloc<FeedEvent, FeedState> {
  FeedBloc({required this.repository}) : super(const FeedState()) {
    on<StoryOpened>(_onOpened, transformer: restartable());
  }

  final RunRepository repository;

  Future<void> _onOpened(StoryOpened event, Emitter<FeedState> emit) async {
    final raw = event.storyId?.trim();
    final storyId = raw == null || raw.isEmpty ? null : raw;
    emit(FeedState(phase: .loading, storyId: storyId));
    try {
      final started = await repository.startRun(storyId: storyId);
      if (emit.isDone) return;
      final playback = await repository.loadPlayback(started.runId);
      if (emit.isDone) return;
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
}
