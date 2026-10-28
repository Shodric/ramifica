import 'package:ramifica/data/models/graph_stub.dart';

enum GraphPhase { loading, loaded, failed }

class GraphState {
  const GraphState({
    this.phase = GraphPhase.loading,
    this.storyId,
    this.runId,
    this.stubs = const [],
    this.currentNodeId,
    this.selectedId,
    this.failure,
    this.acting = false,
  });

  final GraphPhase phase;
  final String? storyId;
  final String? runId;
  final List<GraphStub> stubs;
  final String? currentNodeId;
  final String? selectedId;
  final String? failure;

  /// A rewind or approach is in flight. Stubs stay on screen meanwhile.
  final bool acting;

  /// False when the tab opened with no story; the view shows EmptyState.
  bool get hasStory => storyId != null && storyId!.isNotEmpty;

  GraphStub? get selected {
    final id = selectedId;
    if (id == null) return null;
    for (final stub in stubs) {
      if (stub.nodeId == id) return stub;
    }
    return null;
  }

  GraphStub? get current {
    final id = currentNodeId;
    if (id == null) return null;
    for (final stub in stubs) {
      if (stub.nodeId == id) return stub;
    }
    return null;
  }

  GraphState copy({
    GraphPhase? phase,
    String? Function()? storyId,
    String? Function()? runId,
    List<GraphStub>? stubs,
    String? Function()? currentNodeId,
    String? Function()? selectedId,
    String? Function()? failure,
    bool? acting,
  }) {
    return GraphState(
      phase: phase ?? this.phase,
      storyId: storyId == null ? this.storyId : storyId(),
      runId: runId == null ? this.runId : runId(),
      stubs: stubs ?? this.stubs,
      currentNodeId: currentNodeId == null
          ? this.currentNodeId
          : currentNodeId(),
      selectedId: selectedId == null ? this.selectedId : selectedId(),
      failure: failure == null ? this.failure : failure(),
      acting: acting ?? this.acting,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GraphState &&
        other.phase == phase &&
        other.storyId == storyId &&
        other.runId == runId &&
        _sameStubs(other.stubs, stubs) &&
        other.currentNodeId == currentNodeId &&
        other.selectedId == selectedId &&
        other.failure == failure &&
        other.acting == acting;
  }

  @override
  int get hashCode => Object.hash(
    phase,
    storyId,
    runId,
    Object.hashAll(stubs),
    currentNodeId,
    selectedId,
    failure,
    acting,
  );
}

bool _sameStubs(List<GraphStub> a, List<GraphStub> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
