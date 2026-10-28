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
    this.lineApproved,
    this.ttsApproved,
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

  /// Narrator line approval, or null to leave it. Persists through
  /// `saveNode`; the voice gate reads it before generating.
  final bool? lineApproved;

  /// Narrator take approval, or null to leave it. Fresh takes land
  /// unapproved; the author approves after listening. Persists through
  /// `saveNode`.
  final bool? ttsApproved;
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

/// Asks for a node frame via `generateNodeImage`. [which] is `start`
/// (root only — the backend rejects it elsewhere) or `end` (any node).
/// `restartable`: a second tap cancels the first.
final class ImageGenerateRequested extends CreateEvent {
  const ImageGenerateRequested({required this.nodeId, required this.which});

  final String nodeId;

  /// `start` or `end`.
  final String which;
}

/// Approves (`approved: true`) or rejects (`approved: false`) one node
/// frame via `approveNodeImage`. The backend records the approval; the
/// bloc then reloads the nodes so inheritance side effects show up.
final class ImageApprovalChanged extends CreateEvent {
  const ImageApprovalChanged({
    required this.nodeId,
    required this.which,
    required this.approved,
  });

  final String nodeId;

  /// `start` or `end`.
  final String which;

  final bool approved;
}

/// Asks for the node video via `generateNodeVideo`. GATED server-side:
/// the root needs its own S approved, any other node needs its parent E
/// approved; the call inherits the parent E as S. `restartable`.
final class VideoGenerateRequested extends CreateEvent {
  const VideoGenerateRequested(this.nodeId);

  final String nodeId;
}

/// Uploads a picked video for one node to `uploads/{uid}/`. The bloc
/// validates type (mp4/mov) and size (<=100MB) before any network call,
/// then streams [VideoUploadProgressed] ticks while the bytes go up.
/// `restartable`: picking again cancels the in-flight upload.
final class VideoUploadRequested extends CreateEvent {
  const VideoUploadRequested({
    required this.nodeId,
    required this.contentType,
    required this.bytes,
    this.takeId,
  });

  final String nodeId;

  /// The picker-reported content type (`video/mp4` or `video/quicktime`).
  final String contentType;

  /// The picked file bytes. Carried through the event so the bloc stays
  /// the only caller of the repository.
  final List<int> bytes;

  /// Client take nonce echoed by the trigger as `uploadTakeId`. Null lets
  /// the bloc mint one (production); tests pass a fixed id.
  final String? takeId;
}

/// Upload progress tick (0..1) for [nodeId]. Applied only while that
/// node's upload is in flight; stray ticks are ignored.
final class VideoUploadProgressed extends CreateEvent {
  const VideoUploadProgressed({required this.nodeId, required this.progress});

  final String nodeId;
  final double progress;
}

/// Moves a choice hold-zone inside the 0-1 frame. The bloc clamps [x]
/// and [y] to 0..1; unknown nodes and choices are ignored. Nothing is
/// sent until [NodeSaved] — the zone rides the `choices` whitelist.
final class ZoneMoved extends CreateEvent {
  const ZoneMoved({
    required this.nodeId,
    required this.choiceId,
    required this.x,
    required this.y,
  });

  final String nodeId;
  final String choiceId;
  final double x;
  final double y;
}

/// Adds a choice (and its center-frame zone) pointing at [targetNodeId].
/// The label starts empty for the author to type (24 chars max, like
/// every label field); it is the default only when it is the sole
/// choice. Ignored on endings, past two choices, blank targets, and
/// unknown nodes. Nothing is sent until [NodeSaved].
final class ChoiceAdded extends CreateEvent {
  const ChoiceAdded({required this.nodeId, required this.targetNodeId});

  final String nodeId;
  final String targetNodeId;
}

/// Removes a choice and its zone. When the default goes and choices
/// remain, the first survivor becomes the default so the
/// exactly-one-default checklist can still pass. Unknown nodes and
/// choices are ignored. Nothing is sent until [NodeSaved].
final class ChoiceRemoved extends CreateEvent {
  const ChoiceRemoved({required this.nodeId, required this.choiceId});

  final String nodeId;
  final String choiceId;
}

/// Asks for the node voice via `generateNodeVoice`. GATED server-side:
/// the line must be approved first (and non-blank); the call re-renders
/// the take, which lands unapproved for the author to preview. The bloc
/// reloads the nodes after so the take status shows up. `restartable`:
/// a second tap cancels the first.
final class VoiceGenerateRequested extends CreateEvent {
  const VoiceGenerateRequested(this.nodeId);

  final String nodeId;
}

/// Persists the open node's zones through `saveNode`. Thin wrapper over
/// the save path: zones ride the `choices` whitelist inside the full
/// node doc, exactly like [NodeSaved]. `droppable`: a second save while
/// one is in flight is dropped.
final class ZonesSaved extends CreateEvent {
  const ZonesSaved();
}

/// Persists the open node's window through `saveNode`. Thin wrapper over
/// the save path: the window rides `windowSeconds` inside the full node
/// doc, exactly like [NodeSaved]. `droppable`: a second save while one
/// is in flight is dropped.
final class WindowSaved extends CreateEvent {
  const WindowSaved();
}
