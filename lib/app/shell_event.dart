import 'package:ramifica/app/shell_state.dart';

sealed class ShellEvent {
  const ShellEvent();
}

final class TabSelected extends ShellEvent {
  const TabSelected(this.tab, {this.storyId});

  final ShellTab tab;

  /// When set, this also becomes the open story. Null keeps the current one.
  final String? storyId;
}

final class StoryOpenRequested extends ShellEvent {
  const StoryOpenRequested(this.storyId);

  final String storyId;
}
