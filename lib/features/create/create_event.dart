import 'dart:async';

import 'package:ramifica/data/models/draft_node.dart';

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

/// Lists the author's own stories for the creations list. A null
/// [authorId] falls back to the signed-in identity; blank ids fail
/// without touching the network.
final class StoriesRequested extends CreateEvent {
  const StoriesRequested({this.authorId});

  final String? authorId;
}

/// Taps a node on the canvas. Unknown ids are ignored.
final class NodeSelected extends CreateEvent {
  const NodeSelected(this.nodeId);

  final String nodeId;
}

/// Adds a child node under [parentNodeId] (or the open node when null or
/// unknown) through `createNode` and opens it. Needs a draft with a
/// resolvable parent; otherwise ignored.
final class NodeAdded extends CreateEvent {
  const NodeAdded({this.parentNodeId, this.slot});

  /// Parent for the new child. Null or unknown falls back to the open node.
  final String? parentNodeId;

  /// Branch slot the tapped `+` mini stood for (`A` or `B`). The auto-link
  /// choice carries it so the child lands exactly on the tapped slot.
  /// Null (or taken) falls back to the first free slot.
  final String? slot;
}

/// Manual edit in the inspector. Writes bloc state only — nothing is
/// sent until [NodeSaved]. Only non-null fields change; choice labels
/// replace by choice id, leaving other choices alone. Prompt/ending
/// fields: null keeps, blank after trim clears to null on save.
final class NodeFieldChanged extends CreateEvent {
  const NodeFieldChanged({
    required this.nodeId,
    this.title,
    this.ttsText,
    this.choiceLabels,
    this.choiceIcons,
    this.choiceIconColors,
    this.visibility,
    this.startImagePrompt,
    this.videoPrompt,
    this.endingName,
    this.sceneDirection,
  });

  final String nodeId;

  /// New title, or null to leave it.
  final String? title;

  /// New narrator line, or null to leave it.
  final String? ttsText;

  /// New choice labels by choice id, or null to leave them.
  final Map<String, String>? choiceLabels;

  /// New choice hotspot icon names by choice id, or null to leave them.
  final Map<String, String>? choiceIcons;

  /// New choice hotspot icon color names by choice id, or null.
  final Map<String, String>? choiceIconColors;

  /// `visible` or `secret`, or null to leave it.
  final String? visibility;

  /// S-frame prompt override (root only), or null to leave it. Blank
  /// clears to null so generation falls back to `buildImagePrompt`.
  final String? startImagePrompt;

  /// Clip prompt override, or null to leave it. Blank clears to null so
  /// generation falls back to its default.
  final String? videoPrompt;

  /// Ending name (endings only), or null to leave it. Blank clears.
  final String? endingName;

  /// Scene direction (proposal input), or null to leave it. Blank clears.
  final String? sceneDirection;
}

/// Drops unsaved edits for [nodeId] and the story, restoring the stored
/// docs. No writes happen; used by the leave confirmation.
final class EditsDiscarded extends CreateEvent {
  const EditsDiscarded({required this.nodeId});

  final String nodeId;
}

/// Persists the selected node, or the open node when no id is supplied.
/// Saves share the bloc write queue; [completion] resolves after the
/// latest local revision is persisted, or with false on failure.
final class NodeSaved extends CreateEvent {
  const NodeSaved({this.nodeId, this.completion});

  final String? nodeId;
  final Completer<bool>? completion;
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

/// Generates only the decision narration in S3, then saves it.
final class NarrationGenerateRequested extends CreateEvent {
  const NarrationGenerateRequested(this.nodeId);

  final String nodeId;
}

/// Asks for the root S frame via `generateNodeImage`. [which] is `start`
/// (root only — the backend rejects it elsewhere). [prompt] is the
/// revised prompt override; null or blank falls back to `buildImagePrompt`.
/// `restartable`: a second tap cancels the first.
final class ImageGenerateRequested extends CreateEvent {
  const ImageGenerateRequested({
    required this.nodeId,
    required this.which,
    this.prompt,
  });

  final String nodeId;

  /// `start` only.
  final String which;

  /// Revised prompt override, or null to use the backend fallback.
  final String? prompt;
}

/// Asks for the node video via `generateNodeVideo`. GATED server-side on
/// ready frames: the root needs its own S ready, any other node needs its
/// parent clip ready; the call inherits the parent clip's extracted last
/// frame as S. [prompt] is the revised clip prompt; null or blank keeps
/// the backend fallback.
/// `restartable`.
final class VideoGenerateRequested extends CreateEvent {
  const VideoGenerateRequested(this.nodeId, {this.prompt});

  final String nodeId;

  /// Revised clip prompt override, or null to use the fallback.
  final String? prompt;
}

/// Uploads a picked video for one node to `uploads/{uid}/`. The bloc
/// validates type (mp4/mov) and size (<=10MB) before any network call,
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

/// Toggles the cut mark on branch [slot] (`A` or `B`) — the long-press
/// on an empty Option button. A cut slot grows no child and shows no
/// add-mini on the canvas, so one cut leaves a single-child node. Only
/// a free slot can be cut, and the last open slot stays open; occupied
/// and last-open attempts land as [CreateState.failure]. Unknown nodes,
/// endings, and invalid slots are ignored. Nothing is sent until
/// [NodeSaved].
final class ChoiceCutToggled extends CreateEvent {
  const ChoiceCutToggled({required this.nodeId, required this.slot});

  final String nodeId;
  final String slot;
}

/// Flips the final-node switch at the bottom of Options. Turning final
/// on drops every Option (the UI confirms first when Options exist) and
/// clears cut marks, since a final scene has no branches; turning it
/// off reopens both slots. Unknown nodes are ignored. Nothing is sent
/// until [NodeSaved].
final class NodeEndingToggled extends CreateEvent {
  const NodeEndingToggled({required this.nodeId, required this.isEnding});

  final String nodeId;
  final bool isEnding;
}

/// Sets the ending type of [nodeId] to one of [kEndingTypeCodes] and
/// persists it through the node save path. Unknown nodes and codes
/// outside the list are ignored.
final class NodeEndingTypeChanged extends CreateEvent {
  const NodeEndingTypeChanged({required this.nodeId, required this.endingType});

  final String nodeId;
  final String endingType;
}

/// Asks for the ending badge via `generateEndingBadge` and stores the
/// returned URL on [nodeId] through the node save path. Failures land
/// as [CreateState.failure] (the shared snack), never inline. Unknown
/// nodes and missing drafts are ignored. `droppable`: a second tap
/// while one generation is in flight is dropped.
final class NodeEndingBadgeRequested extends CreateEvent {
  const NodeEndingBadgeRequested(this.nodeId);

  final String nodeId;
}

/// Asks for the node voice via `generateNodeVoice`. GATED server-side on
/// the non-blank narrator line; the call re-renders the take. The bloc
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

/// Deletes the open node through `deleteNode`. GUARDED server-side:
/// the root and any node targeted by another node's choices are rejected
/// (the delete button disables with the reason in those cases, computed
/// from the local graph). On success the bloc reloads the nodes and
/// reopens the root; a rejection lands as [CreateState.failure].
/// `droppable`: a second delete while one is in flight is dropped.
final class NodeDeleted extends CreateEvent {
  const NodeDeleted();
}

/// Publishes the draft through `publishStory`. The server re-runs the full
/// `validateStory` checklist and flips `draft` to `published` only when it
/// passes; a returned missing list lands as [CreateState.failure] with no
/// state change. On success the view leaves for Explore. `droppable`: a
/// second publish while one is in flight is dropped.
final class StoryPublished extends CreateEvent {
  const StoryPublished();
}

/// Adds a child node under [nodeId] on branch [slot] (`A` or `B`) and
/// links it as a choice — the hotspot path. Unlike [NodeAdded] there is no
/// navigation: the author stays on the parent while the new choice gets
/// focus (see `CreateState.focusChoiceId`). The link carries an empty
/// label with the slot's default icon and color. The 2-choice cap in
/// `_linkChoice` still applies; past it the event is ignored.
final class HotspotAdded extends CreateEvent {
  const HotspotAdded({required this.nodeId, required this.slot});

  /// Parent node that gains the choice.
  final String nodeId;

  /// Branch slot for the new child (`A` or `B`).
  final String slot;
}

/// Applies a voice-proposed story outline: story title/synopsis plus the
/// root's narrator line and up to two option labels with icons. The bloc
/// updates the story doc, sets the root fields, creates one child per
/// option and links it on its slot — without navigating. Malformed option
/// entries are skipped; lengths are clamped (title 40, line 280, label
/// 24) and icons fall back to the catalog in `choice_icon.dart`.
final class OutlineApplied extends CreateEvent {
  const OutlineApplied({
    this.title,
    this.synopsis,
    this.narratorLine,
    this.options = const [],
  });

  final String? title;
  final String? synopsis;
  final String? narratorLine;
  final List<OutlineOption> options;
}

/// One proposed option for [OutlineApplied]: label plus optional icon
/// and color names from the shared catalog.
final class OutlineOption {
  const OutlineOption({required this.label, this.icon, this.iconColor});

  final String label;
  final String? icon;
  final String? iconColor;
}

/// One proposed branch for [SceneProposal]: label plus optional icon
/// and color names from the shared catalog (`choice_icon.dart`).
/// Unknown names normalize to null in the bloc via `_catalogIcon` /
/// `_catalogColor` and draw the index fallback.
final class SceneProposalChoice {
  const SceneProposalChoice({required this.label, this.icon, this.iconColor});

  final String label;
  final String? icon;
  final String? iconColor;
}

/// A Spark scene proposal: text plus visual prompts plus up to
/// two branches. Proposal-only: the wizard builds this from the direction
/// and [SceneProposalApplied] writes it. All fields nullable;
/// absent/blank/invalid normalize to null in the bloc. Children
/// proposals carry `startImagePrompt: null` (S is inherited); endings
/// carry `choices: []` with an optional [endingName].
/// Accepts legacy shapes via [SceneProposal.fromJson]: plain-string
/// choices and `choiceLabels` maps, missing prompts.
final class SceneProposal {
  const SceneProposal({
    this.title,
    this.ttsText,
    this.startImagePrompt,
    this.videoPrompt,
    this.endingName,
    this.choices = const [],
  });

  /// Compat reader for backend proposal payloads: `choices` may hold
  /// `{label, icon, iconColor}` maps or plain strings; `choiceLabels`
  /// (list of strings or `{label}` maps) is accepted as a fallback.
  /// Malformed entries are skipped; lengths are clamped by the bloc.
  factory SceneProposal.fromJson(Map<String, dynamic> json) {
    String? text(Object? value) {
      if (value is String && value.trim().isNotEmpty) return value;
      return null;
    }

    final choices = <SceneProposalChoice>[];
    final raw = json['choices'];
    if (raw is List) {
      for (final item in raw) {
        if (item is String && item.trim().isNotEmpty) {
          choices.add(SceneProposalChoice(label: item));
        } else if (item is Map) {
          final map = item.map((key, value) => MapEntry(key.toString(), value));
          final label = text(map['label']);
          if (label == null) continue;
          choices.add(
            SceneProposalChoice(
              label: label,
              icon: text(map['icon']),
              iconColor: text(map['iconColor'] ?? map['color']),
            ),
          );
        }
      }
    } else {
      final fallback = json['choiceLabels'];
      if (fallback is List) {
        for (final item in fallback) {
          if (item is String && item.trim().isNotEmpty) {
            choices.add(SceneProposalChoice(label: item));
          } else if (item is Map) {
            final label = text(
              (item.map(
                (key, value) => MapEntry(key.toString(), value),
              ))['label'],
            );
            if (label != null) choices.add(SceneProposalChoice(label: label));
          }
        }
      }
    }
    return SceneProposal(
      title: text(json['title']),
      ttsText: text(json['ttsText'] ?? json['narratorLine']),
      startImagePrompt: text(json['startImagePrompt']),
      videoPrompt: text(json['videoPrompt']),
      endingName: text(json['endingName']),
      choices: choices,
    );
  }

  final String? title;
  final String? ttsText;
  final String? startImagePrompt;
  final String? videoPrompt;
  final String? endingName;

  /// Proposed branches in slot order (index 0 → A, 1 → B, max two).
  final List<SceneProposalChoice> choices;
}

/// Applies a reviewed [proposal] to [nodeId]: flushes pending edits,
/// then overwrites non-empty fields (narrator line, start/video prompts)
/// plus per-slot option label/icon/color — staying on the same scene.
/// The manual title and ending name arrive null (preserved).
/// `droppable`: a second Apply while one is in flight is dropped.
/// Occupied slots keep ids/target/geometry/default and never delete; free
/// slots create via the reproducible `v1:author:story:parent:slot` key.
/// A narration change idles the voice. Never generates media.
final class SceneProposalApplied extends CreateEvent {
  const SceneProposalApplied({
    required this.nodeId,
    required this.proposal,
    this.completion,
  });

  /// Scene that gains the proposal.
  final String nodeId;

  /// Auto-built proposal from the S1 direction. Every non-empty value
  /// overwrites; the manual title and ending name are preserved.
  final SceneProposal proposal;

  /// Resolves after the proposal is persisted, or with false on failure —
  /// mirroring [NodeSaved].
  final Completer<bool>? completion;
}

/// A background icon decision landed for one choice. Fills the styling
/// only when the choice is still unstyled (null or the link placeholder
/// pair): a manual (or earlier) pick wins by check-at-merge, then the
/// node is saved.
final class ChoiceIconDecided extends CreateEvent {
  const ChoiceIconDecided({
    required this.nodeId,
    required this.choiceId,
    this.icon,
    this.iconColor,
  });

  final String nodeId;
  final String choiceId;
  final String? icon;
  final String? iconColor;
}

/// A live draft snapshot; stale-story events are ignored by the bloc.
final class DraftNodesObserved extends CreateEvent {
  const DraftNodesObserved(this.storyId, this.nodes, {this.error});
  final String storyId;
  final List<DraftNode> nodes;
  final Object? error;
}

/// Local story fields, persisted by Save or before an explicit AI operation.
final class StoryFieldChanged extends CreateEvent {
  const StoryFieldChanged({this.title, this.synopsis});
  final String? title, synopsis;
}

/// Persists the story fields (title/synopsis) without touching any node.
/// [completion] resolves after the latest local revision is persisted, or
/// with false on failure — mirroring [NodeSaved].
final class StorySaved extends CreateEvent {
  const StorySaved({this.completion});

  final Completer<bool>? completion;
}

/// Asks for the story key art via `generateStoryCover`. Flushes pending
/// story edits first so the cover prompt reads the latest title and
/// synopsis. [prompt] is an author override; null or blank falls back to
/// the story bible prompt. `droppable`: a second tap while one cover is
/// in flight is dropped.
final class CoverGenerateRequested extends CreateEvent {
  const CoverGenerateRequested({this.prompt});

  /// Revised cover prompt override, or null to use the fallback.
  final String? prompt;
}

/// Hides the open published story: an author-guarded client transaction
/// flips `status` back to `draft`, so every player read rule stops
/// matching and the story leaves the catalog. Publishing again creates
/// a fresh publication.
final class StoryUnpublished extends CreateEvent {
  const StoryUnpublished();
}

/// Deletes the open draft story doc. GUARDED by firestore.rules: only
/// the author of a draft may delete. Node and publication docs turn
/// into unreachable orphans, like the Storage bytes node deletes leave.
final class StoryDeleted extends CreateEvent {
  const StoryDeleted();
}
