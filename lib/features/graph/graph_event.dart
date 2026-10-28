sealed class GraphEvent {
  const GraphEvent();
}

/// Opens the map: fetches every stub of [storyId] for [runId].
final class GraphRequested extends GraphEvent {
  const GraphRequested({required this.storyId, required this.runId});

  final String storyId;
  final String runId;
}

/// Taps a node on the canvas. Unknown ids are ignored.
final class NodeSelected extends GraphEvent {
  const NodeSelected(this.nodeId);

  final String nodeId;
}

/// From the sheet. Returns the sheet to the you-are-here node; the view
/// also navigates back to Feed.
final class ContinueRequested extends GraphEvent {
  const ContinueRequested();
}

/// From a lock. Plays the visited parent approach without moving history.
final class ApproachRequested extends GraphEvent {
  const ApproachRequested(this.nodeId);

  final String nodeId;
}

/// From the sheet. Moves the run back to the parent of the current node.
final class RewindRequested extends GraphEvent {
  const RewindRequested();
}
