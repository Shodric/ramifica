import 'package:bloc/bloc.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/shell_event.dart';
import 'package:ramifica/app/shell_state.dart';

ShellState shellStateFor(AppLocation location) {
  return switch (location) {
    FeedLocation(:final storyId) => ShellState(
      storyId: storyId == null || storyId.isEmpty ? null : storyId,
    ),
    ExploreLocation() => const ShellState(tab: .explore),
    CreateLocation() => const ShellState(tab: .create),
    GraphLocation(:final storyId) => ShellState(tab: .graph, storyId: storyId),
    ProfileLocation() => const ShellState(tab: .profile),
    AccessLocation() || UnknownLocation() => const ShellState(),
  };
}

class ShellBloc extends Bloc<ShellEvent, ShellState> {
  ShellBloc({ShellState? initial}) : super(initial ?? const ShellState()) {
    on<TabSelected>(_onTab);
    on<StoryOpenRequested>(_onStory);
  }

  void _onTab(TabSelected event, Emitter<ShellState> emit) {
    final storyId = event.storyId?.trim();
    emit(
      state.copyWith(
        tab: event.tab,
        storyId: storyId == null || storyId.isEmpty ? null : storyId,
      ),
    );
  }

  void _onStory(StoryOpenRequested event, Emitter<ShellState> emit) {
    final storyId = event.storyId.trim();
    if (storyId.isEmpty) return;
    emit(state.copyWith(tab: .feed, storyId: storyId));
  }
}
