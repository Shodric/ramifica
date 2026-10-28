sealed class CreateEvent {
  const CreateEvent();
}

/// Starts a new draft: creates the story doc plus its root node and opens
/// the root in the inspector. `restartable`: a second tap cancels the
/// first. A null [authorId] falls back to the signed-in identity; blank
/// ids fail without touching the network.
final class DraftRequested extends CreateEvent {
  const DraftRequested({this.authorId, this.title = 'Untitled story'});

  final String? authorId;
  final String title;
}

/// Opens an existing draft: fetches the story and every node, secrets
/// included. `restartable`.
final class DraftOpened extends CreateEvent {
  const DraftOpened(this.storyId);

  final String storyId;
}

/// Taps a node on the canvas. Unknown ids are ignored.
final class NodeSelected extends CreateEvent {
  const NodeSelected(this.nodeId);

  final String nodeId;
}

/// Adds a child node under the open node through `createNode` and opens
/// it. Needs an open node; otherwise ignored.
final class NodeAdded extends CreateEvent {
  const NodeAdded();
}

/// Manual edit in the inspector. Writes bloc state only — nothing is
/// sent until [NodeSaved]. Only non-null fields change; choice labels
/// replace by choice id, leaving other choices alone.
final class NodeFieldChanged extends CreateEvent {
  const NodeFieldChanged({
    required this.nodeId,
    this.title,
    this.ttsText,
    this.choiceLabels,
    this.visibility,
    this.windowSeconds,
  });

  final String nodeId;

  /// New title, or null to leave it.
  final String? title;

  /// New narrator line, or null to leave it.
  final String? ttsText;

  /// New choice labels by choice id, or null to leave them.
  final Map<String, String>? choiceLabels;

  /// `visible` or `secret`, or null to leave it.
  final String? visibility;

  /// New decision window, or null to leave it.
  final int? windowSeconds;
}

/// Persists the open node through `saveNode`. `droppable`: a second save
/// while one is in flight is dropped.
final class NodeSaved extends CreateEvent {
  const NodeSaved();
}

/// Asks Spark for proposed text via `generateNodeText`. `restartable`.
/// The proposal fills only empty fields, so manual edits are never
/// clobbered — unless [regenerate] is true, when every proposed field
/// overwrites.
final class TextGenerateRequested extends CreateEvent {
  const TextGenerateRequested({this.prompt, this.regenerate = false});

  final String? prompt;
  final bool regenerate;
}
