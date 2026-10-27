enum ShellTab { feed, explore, create, graph, profile }

class ShellState {
  const ShellState({this.tab = .feed, this.storyId});

  final ShellTab tab;
  final String? storyId;

  ShellState copyWith({ShellTab? tab, String? storyId}) {
    return ShellState(tab: tab ?? this.tab, storyId: storyId ?? this.storyId);
  }

  @override
  bool operator ==(Object other) {
    return other is ShellState && other.tab == tab && other.storyId == storyId;
  }

  @override
  int get hashCode => Object.hash(tab, storyId);
}
