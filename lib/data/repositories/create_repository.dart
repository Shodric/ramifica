export 'package:ramifica/data/persistence/node_fields.dart';

import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ramifica/data/persistence/node_fields.dart';
import 'package:ramifica/data/persistence/document_store.dart';
import 'package:ramifica/data/persistence/draft_persistence.dart';
import 'package:ramifica/data/persistence/publication.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/draft_story.dart';

/// One proposed choice for a decision node: the label the player reads
/// plus optional hotspot styling. Unknown icon/color names arrive as-is;
/// the bloc maps them through the shared catalog (unknown to null) when
/// applying, so old drafts and old responses look unchanged.
class GeneratedChoice {
  const GeneratedChoice({required this.label, this.icon, this.iconColor});

  factory GeneratedChoice.fromJson(Map<String, dynamic> json) {
    return GeneratedChoice(
      label: _optionalString(json['label']) ?? '',
      icon: _optionalString(json['icon']),
      iconColor: _optionalString(json['iconColor']),
    );
  }

  /// Proposed choice label, 1-24 characters when non-blank.
  final String label;

  /// Proposed hotspot icon name, or null when unstyled/legacy.
  final String? icon;

  /// Proposed hotspot icon color name, or null when unstyled/legacy.
  final String? iconColor;

  /// True when the label is blank — the caller drops these.
  bool get isEmpty => label.isEmpty;
}

/// What `generateNodeText` proposes. Proposal-only: the server writes
/// nothing; the bloc merges the proposal into empty fields and the author
/// saves explicitly. Every value is nullable and `choices` may be empty —
/// a partial proposal still parses.
///
/// Backend contract (functions/src/create/generateNodeText.ts): every key
/// is always present; `choices` is always an array of
/// `{label, icon, iconColor}` maps (plain-string labels and missing
/// prompts parse too, for old responses); `endingName` is non-null only
/// for ending nodes.
class GeneratedNodeText {
  const GeneratedNodeText({
    this.title,
    this.ttsText,
    this.choices = const [],
    this.endingName,
    this.startImagePrompt,
    this.videoPrompt,
  });

  factory GeneratedNodeText.fromJson(Map<String, dynamic> json) {
    return GeneratedNodeText(
      title: _optionalString(json['title']),
      ttsText: _optionalString(json['ttsText']),
      choices: _optionalChoices(json['choices'] ?? json['choiceLabels']),
      endingName: _optionalString(json['endingName']),
      startImagePrompt: _optionalString(json['startImagePrompt']),
      videoPrompt: _optionalString(json['videoPrompt']),
    );
  }

  final String? title;
  final String? ttsText;

  /// Proposed choices, in order with optional hotspot styling. Applied to
  /// existing choices by index, never creating or deleting choices on
  /// their own.
  final List<GeneratedChoice> choices;

  /// Proposed choice labels, in order. Compat accessor over [choices].
  List<String> get choiceLabels => [for (final choice in choices) choice.label];

  /// Proposed ending name, for ending nodes only.
  final String? endingName;

  /// Proposed S-frame (root) image prompt, or null when absent/legacy.
  final String? startImagePrompt;

  /// Proposed video prompt, or null when absent/legacy.
  final String? videoPrompt;

  /// True when the proposal carries nothing usable.
  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (ttsText == null || ttsText!.isEmpty) &&
      choices.isEmpty &&
      (endingName == null || endingName!.isEmpty) &&
      (startImagePrompt == null || startImagePrompt!.isEmpty) &&
      (videoPrompt == null || videoPrompt!.isEmpty);
}

/// One opening option from a `proposeStoryOutline` proposal: label plus
/// optional hotspot styling. Unknown icon/color names arrive as null —
/// the client draws its index fallback for those.
class ProposedOutlineOption {
  const ProposedOutlineOption({required this.label, this.icon, this.iconColor});

  factory ProposedOutlineOption.fromJson(Map<String, dynamic> json) {
    return ProposedOutlineOption(
      label: _optionalString(json['label']) ?? '',
      icon: _optionalString(json['icon']),
      iconColor: _optionalString(json['iconColor']),
    );
  }

  final String label;
  final String? icon;
  final String? iconColor;

  /// True when the label is blank — the caller drops these.
  bool get isEmpty => label.isEmpty;
}

/// What `proposeStoryOutline` proposes. Proposal-only: the server writes
/// nothing; the premise sheet shows it editable and the bloc applies it
/// through [CreateRepository.updateStory] plus node writes on `Aplicar`.
/// Every value is nullable and `options` may be empty — a partial
/// proposal still parses.
///
/// Backend contract (functions/src/create/proposeOutline.ts): every key
/// is always present; `options` is an array of
/// `{label, icon, iconColor}` maps with at most two entries.
class ProposedOutline {
  const ProposedOutline({
    this.title,
    this.synopsis,
    this.narratorLine,
    this.options = const [],
  });

  factory ProposedOutline.fromJson(Map<String, dynamic> json) {
    final raw = json['options'];
    final options = <ProposedOutlineOption>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final option = ProposedOutlineOption.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          );
          if (!option.isEmpty) options.add(option);
        }
      }
    }
    return ProposedOutline(
      title: _optionalString(json['title']),
      synopsis: _optionalString(json['synopsis']),
      narratorLine: _optionalString(json['narratorLine']),
      options: options,
    );
  }

  final String? title;
  final String? synopsis;
  final String? narratorLine;

  /// Proposed opening options with hotspot styling, in order (max two).
  final List<ProposedOutlineOption> options;

  /// True when the proposal carries nothing usable.
  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (synopsis == null || synopsis!.isEmpty) &&
      (narratorLine == null || narratorLine!.isEmpty) &&
      options.isEmpty;
}

/// One `transcribeVoice` answer. `text` is the transcript of the bytes
/// sent with that call. `done` stays false; the client stops the take.
typedef TranscribedSlice = ({String text, bool done});

String? _optionalString(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value;
  return null;
}

/// Accepts `[{label, icon, iconColor}]` maps or plain strings; anything else
/// is skipped so one malformed entry cannot sink the proposal. Blank labels
/// are dropped; icon/color ride along as-is for the bloc to catalog-check.
List<GeneratedChoice> _optionalChoices(Object? value) {
  if (value is! List) return const [];
  final choices = <GeneratedChoice>[];
  for (final raw in value) {
    if (raw is String && raw.trim().isNotEmpty) {
      choices.add(GeneratedChoice(label: raw));
    } else if (raw is Map) {
      final choice = GeneratedChoice.fromJson(
        raw.map((key, value) => MapEntry(key.toString(), value)),
      );
      if (!choice.isEmpty) choices.add(choice);
    }
  }
  return choices;
}

/// Max creator upload: storage.rules allows under 100 MB.
const maxVideoUploadBytes = 100 * 1024 * 1024;

/// Content types the upload trigger accepts (storage.rules mirrors this).
const videoUploadContentTypes = {'video/mp4', 'video/quicktime'};

/// One picked video file: bytes plus the content type the picker reported.
/// Picking is view-side and injected; the repository never touches a picker
/// plugin — it only validates and uploads what it gets.
class PickedVideoFile {
  const PickedVideoFile({required this.contentType, required this.bytes});

  final String contentType;
  final List<int> bytes;
}

/// Picks a video file, or returns null when the author cancels. Wired by
/// the view; tests inject a fake. Production needs a picker plugin
/// (file_picker or image_picker — not a dependency yet); until Main wires
/// one, the upload button stays hidden.
typedef PickVideoFile = Future<PickedVideoFile?> Function();

/// Raw upload transport: bytes to an exact Storage path. Tests inject a
/// fake; production needs firebase_storage (putData/putFile with the given
/// content type — not a dependency yet, so the factory default throws
/// [AppFailure.failed] instead of pretending to upload).
typedef UploadVideoFile = Future<void> Function({
  required String path,
  required String contentType,
  required List<int> bytes,
  void Function(double progress)? onProgress,
});

/// Client-side upload pre-check. Returns the phrase to show, or null when
/// the file may be sent. Runs before any network call, so rejections never
/// touch Storage. Mirrors storage.rules (`video/(mp4|quicktime)`, <100MB).
String? validateVideoUpload({
  required String contentType,
  required int byteLength,
}) {
  if (!videoUploadContentTypes.contains(contentType.trim())) {
    return 'Only mp4 or mov videos can be uploaded.';
  }
  if (byteLength <= 0 || byteLength > maxVideoUploadBytes) {
    return 'Videos must be 100 MB or smaller.';
  }
  return null;
}

/// Trigger-written upload outcome for one node: the `uploadError` code (if
/// the take failed) and the `uploadTakeId` echo of the take that wrote it.
/// The bloc polls the marker until the echo matches its own take before
/// trusting the error — a pre-trigger read carries the previous take's
/// echo (or none) and never resolves the upload.
typedef UploadMarker = ({String? error, String? takeId});

/// Story-doc merge transport: `stories/{id}` patched client-direct.
/// Tests inject a fake; production uses the Firestore merge in
/// [createFirebaseCreateRepository].
typedef UpdateStoryDoc = Future<void> Function({
  required String storyId,
  String? title,
  String? synopsis,
});

/// Direct node merge: `stories/{storyId}/nodes/{nodeId}`. Production
/// reads the stored line and writes [nodeSavePatch]. Tests may inject it; otherwise the direct draft persistence is used.
typedef SaveNodeDoc = Future<void> Function({
  required String storyId,
  required String nodeId,
  required DraftNode node,
});

/// Author fields a save may merge. Pipeline media stays out.
///
/// When [storedText] differs from the line, the stored voice is idled:
/// it still speaks the old words. An explicit line approval in [node]
/// is kept; a voice approval is not.
/// Fail-closed story-doc default: used when no transport is wired.
/// Throws instead of pretending to write.
Future<void> _unwiredUpdateStory({
  required String storyId,
  String? title,
  String? synopsis,
}) async {
  throw const AppFailure(.failed);
}

/// Fail-closed upload default: used when no transport is wired (no
/// firebase_storage dependency yet). Throws instead of pretending to work.
Future<void> _unwiredUpload({
  required String path,
  required String contentType,
  required List<int> bytes,
  void Function(double progress)? onProgress,
}) async {
  throw const AppFailure(.failed);
}

/// Draft reads and writes for Create. The view never calls this directly;
/// [CreateBloc] does.
///
/// Split write path (firestore.rules):
/// * the story doc is client-direct — rules allow the author to create
///   and edit their own `draft` story;
/// * an open node's author fields merge client-direct (`saveNodeDoc`);
///   create and delete stay on `createNode` / `deleteNode`;
/// * `generateNodeText` proposes text without writing anything.
///
/// Tests inject the lambdas; production uses
/// [createFirebaseCreateRepository].
class CreateRepository {
  CreateRepository({
    required this.createDraftDoc,
    UpdateStoryDoc? updateStoryDoc,
    required this.fetchStoryDoc,
    required this.fetchNodeDocs,
    required this.callFunction,
    this.fetchAuthorStoryDocs,
    this.saveNodeDoc,
    this.drafts,
    this.publisher,
    this.fetchNodeDoc,
    UploadVideoFile? uploadVideoFile,
  }) : updateStoryDoc = updateStoryDoc ?? _unwiredUpdateStory,
       uploadVideoFile = uploadVideoFile ?? _unwiredUpload;

  /// Creates `stories/{id}` with `status: 'draft'` owned by [authorId].
  /// Returns the new story id.
  final Future<String> Function({
    required String authorId,
    required String title,
  })
  createDraftDoc;

  /// Merges fields into `stories/{id}` client-direct (firestore.rules
  /// opens drafts to their author). Used by the premise `Aplicar` path
  /// to persist the approved title/synopsis. Optional with a fail-closed
  /// default, like [uploadVideoFile].
  final UpdateStoryDoc updateStoryDoc;

  /// Reads one story doc. Returns null when it does not exist.
  final Future<Map<String, dynamic>?> Function(String storyId) fetchStoryDoc;

  /// Merges one node's author fields. Tests may inject this seam. Production uses direct draft persistence.
  final SaveNodeDoc? saveNodeDoc;
  final DraftPersistence? drafts;
  final ClientPublisher? publisher;
  final Future<Map<String, dynamic>?> Function(String storyId, String nodeId)?
  fetchNodeDoc;

  DraftPersistence get persistence =>
      drafts ??
      (throw const AppFailure(
        .failed,
        detail: 'Draft persistence is not configured.',
      ));

  Stream<List<DraftNode>> watchNodes(String storyId) =>
      drafts?.watchNodes(storyId) ?? const Stream.empty();

  Future<DraftNode?> fetchNode(String storyId, String nodeId) async {
    final read = fetchNodeDoc;
    if (read != null) {
      final data = await read(storyId, nodeId);
      return data == null ? null : DraftNode.fromMap(nodeId, data);
    }
    final nodes = await fetchNodes(storyId);
    for (final node in nodes) {
      if (node.nodeId == nodeId) return node;
    }
    return null;
  }

  Future<DraftChange> createAndLink({
    required String storyId,
    required String parentNodeId,
    String? slot,
    String? requestId,
    String label = '',
    String? icon,
    String? iconColor,
  }) => persistence.createAndLink(
    storyId,
    parentNodeId,
    slot: slot,
    requestId: requestId,
    label: label,
    icon: icon,
    iconColor: iconColor,
  );

  Future<DraftChange> applyScene({
    required String storyId,
    required String nodeId,
    required GeneratedNodeText proposal,
  }) => persistence.applyScene(
    storyId,
    nodeId,
    {
      'title': proposal.title,
      'ttsText': proposal.ttsText,
      'endingName': proposal.endingName,
      'startImagePrompt': proposal.startImagePrompt,
      'videoPrompt': proposal.videoPrompt,
    },
    [
      for (final c in proposal.choices)
        {'label': c.label, 'icon': c.icon, 'iconColor': c.iconColor},
    ],
  );

  /// Reads every node doc of [storyId]: `(nodeId, data)` entries.
  final Future<List<MapEntry<String, Map<String, dynamic>>>> Function(
    String storyId,
  )
  fetchNodeDocs;

  /// Lists the author's own story docs: `(storyId, data)` entries.
  /// Optional: tests may omit it, then [fetchAuthorStories] returns [].
  final Future<List<MapEntry<String, Map<String, dynamic>>>> Function({
    required String authorId,
  })?
  fetchAuthorStoryDocs;

  /// Calls a Create callable by name with the given payload.
  final Future<Map<String, dynamic>> Function(
    String name,
    Map<String, dynamic> data,
  )
  callFunction;

  /// Raw upload transport (see [UploadVideoFile]). The client never
  /// re-encodes: it puts the picked bytes at the exact trigger path and
  /// the backend does the rest.
  final UploadVideoFile uploadVideoFile;

  /// Creates a draft plus its root node and returns the parsed pair.
  ///
  /// The story doc lands client-direct; the root node comes from the
  /// `createNode` callable. A blank author id throws [AppFailure.invalid]
  /// without touching the network.
  Future<(DraftStory, DraftNode)> createDraft({
    required String authorId,
    String title = 'Untitled story',
  }) async {
    if (authorId.trim().isEmpty) throw const AppFailure(.invalid);
    return persistence.createDraft(authorId.trim(), title);
  }

  /// Merges the approved premise into the story doc client-direct: only
  /// non-blank [title]/[synopsis] are sent, and at least one is
  /// required. A blank id or two blank fields throws
  /// [AppFailure.invalid] without touching the network. Transport
  /// failures throw [AppFailure] via the injected [updateStoryDoc].
  Future<void> updateStory({
    required String storyId,
    String? title,
    String? synopsis,
  }) async {
    final story = storyId.trim();
    final cleanTitle = title?.trim();
    final cleanSynopsis = synopsis?.trim();
    if (story.isEmpty) throw const AppFailure(.invalid);
    if ((cleanTitle == null || cleanTitle.isEmpty) &&
        (cleanSynopsis == null || cleanSynopsis.isEmpty)) {
      throw const AppFailure(.invalid);
    }
    await updateStoryDoc(
      storyId: story,
      title: cleanTitle == null || cleanTitle.isEmpty ? null : cleanTitle,
      synopsis: cleanSynopsis == null || cleanSynopsis.isEmpty
          ? null
          : cleanSynopsis,
    );
  }

  /// The author's draft story, or null when it does not exist.
  /// Malformed docs throw [AppFailure.invalid].
  Future<DraftStory?> fetchDraft(String storyId) async {
    final id = storyId.trim();
    if (id.isEmpty) throw const AppFailure(.invalid);
    final data = await fetchStoryDoc(id);
    if (data == null) return null;
    return DraftStory.fromDoc(id, data);
  }

  /// Every node of the draft, secrets included. Malformed node docs are
  /// skipped so one bad doc cannot sink the canvas.
  Future<List<DraftNode>> fetchNodes(String storyId) async {
    final id = storyId.trim();
    if (id.isEmpty) throw const AppFailure(.invalid);
    final docs = await fetchNodeDocs(id);
    final nodes = <DraftNode>[];
    for (final doc in docs) {
      try {
        nodes.add(DraftNode.fromMap(doc.key, doc.value));
      } on AppFailure {
        continue;
      }
    }
    return nodes;
  }

  /// The author's own stories, newest first (missing dates sort last).
  /// Malformed docs are skipped like in [fetchNodes]. Without a
  /// [fetchAuthorStoryDocs] seam there is nothing to read: returns [].
  /// Each story carries its scene and ending counts for the creations
  /// list; a story whose nodes cannot be read keeps unknown (null)
  /// counts instead of sinking the list.
  Future<List<DraftStory>> fetchAuthorStories({
    required String authorId,
  }) async {
    final author = authorId.trim();
    if (author.isEmpty) throw const AppFailure(.invalid);
    final read = fetchAuthorStoryDocs;
    if (read == null) return const [];
    final docs = await read(authorId: author);
    final stories = <DraftStory>[];
    for (final doc in docs) {
      try {
        stories.add(await _withCounts(DraftStory.fromDoc(doc.key, doc.value)));
      } on AppFailure {
        continue;
      }
    }
    stories.sort((a, b) {
      final au = a.updatedAt;
      final bu = b.updatedAt;
      if (au == null && bu == null) return a.title.compareTo(b.title);
      if (au == null) return 1;
      if (bu == null) return -1;
      return bu.compareTo(au);
    });
    return stories;
  }

  /// Attaches scene and ending counts to [story] for the creations list.
  /// Node reads are best-effort: on any failure the story keeps unknown
  /// counts so one unreadable draft cannot sink the list.
  Future<DraftStory> _withCounts(DraftStory story) async {
    try {
      final nodes = await fetchNodes(story.storyId);
      return story.copy(
        nodeCount: () => nodes.length,
        endingCount: () => nodes.where((node) => node.isEnding).length,
      );
    } catch (_) {
      return story;
    }
  }

  /// Adds a child node under [parentNodeId] through the `createNode`
  /// callable. Returns the new node id. With [requestId], the backend
  /// resolves the same child on retry (idempotent by author/story/parent
  /// slot key `v1:…`); without it behavior is unchanged.
  Future<String> createNode({
    required String storyId,
    required String parentNodeId,
    String? requestId,
  }) async {
    final result = await createAndLink(
      storyId: storyId,
      parentNodeId: parentNodeId,
      requestId: requestId,
    );
    return result.selectedId;
  }

  /// Deletes one non-root, untargeted node through the `deleteNode`
  /// callable. GUARDED server-side: the root (`rootNodeId`) and any node
  /// targeted by another node's choices are rejected and surface as
  /// [AppFailure] phrases. Blank ids throw [AppFailure.invalid] without
  /// touching the network.
  Future<void> deleteNode({
    required String storyId,
    required String nodeId,
  }) async {
    if (storyId.trim().isEmpty || nodeId.trim().isEmpty) {
      throw const AppFailure(.invalid);
    }
    await persistence.delete(documentId(storyId), documentId(nodeId));
  }

  /// Publishes the draft through the `publishStory` callable. Returns the
  /// server's `problems` list: empty when the story flipped `draft` to
  /// `published`, one message per unmet `validateStory` condition
  /// otherwise (no state change server-side). Render a non-empty list as
  /// the checklist — never as a generic error. Transport failures throw
  /// [AppFailure]; a blank id throws [AppFailure.invalid] without
  /// touching the network.
  Future<List<String>> publishStory({required String storyId}) async {
    if (storyId.trim().isEmpty) throw const AppFailure(.invalid);
    final service = publisher;
    if (service == null) {
      throw const AppFailure(
        .failed,
        detail: 'Publication persistence is not configured.',
      );
    }
    return await service.publish(documentId(storyId));
  }

  /// Persists the author's edits. Production merges [nodeSavePatch] into
  /// the node doc. No callable fallback exists.
  Future<void> saveNode({
    required String storyId,
    required DraftNode node,
  }) async {
    final story = documentId(storyId);
    documentId(node.nodeId);
    final direct = saveNodeDoc;
    if (direct != null) {
      await direct(storyId: story, nodeId: node.nodeId, node: node);
    } else {
      await persistence.save(story, node);
    }
  }

  /// Asks Spark for proposed text. Proposal-only: nothing is written;
  /// the bloc merges the proposal into empty fields (or every field on
  /// an explicit regenerate) and the author saves by hand.
  ///
  /// The server also accepts an optional `context` key and a null
  /// `nodeId` for new-node proposals; the client always has an open node
  /// here, so it sends both ids and the optional author prompt.
  /// [purpose] is `scene` for S1 or `narration` for S3. Omission retains
  /// the legacy full proposal contract.
  Future<GeneratedNodeText> generateNodeText({
    required String storyId,
    required String nodeId,
    String? prompt,
    String? purpose,
  }) async {
    final story = storyId.trim();
    final node = nodeId.trim();
    if (story.isEmpty || node.isEmpty) throw const AppFailure(.invalid);
    final data = {'storyId': story, 'nodeId': node};
    if (purpose != null) data['purpose'] = purpose;
    final hint = prompt?.trim();
    if (hint != null && hint.isNotEmpty) data['prompt'] = hint;
    final payload = await callFunction('generateNodeText', data);
    final proposal = GeneratedNodeText.fromJson(payload);
    if (proposal.isEmpty) throw const AppFailure(.invalid);
    return proposal;
  }

  /// Asks for the root S frame via the `generateNodeImage` callable.
  /// [which] is `start` only; anything else throws [AppFailure.invalid]
  /// without touching the network. Generation is server-side: this
  /// records intent, then the caller reloads the nodes to read the
  /// resulting `pending`/`ready` status.
  Future<void> generateNodeImage({
    required String storyId,
    required String nodeId,
    required String which,
    String? prompt,
  }) async {
    final story = storyId.trim();
    final node = nodeId.trim();
    if (story.isEmpty || node.isEmpty) throw const AppFailure(.invalid);
    if (which != 'start') {
      throw const AppFailure(.invalid);
    }
    final data = {'storyId': story, 'nodeId': node, 'which': which};
    final hint = prompt?.trim();
    if (hint != null && hint.isNotEmpty) data['prompt'] = hint;
    await callFunction('generateNodeImage', data);
  }

  /// Asks for the story key art via the `generateStoryCover` callable.
  /// Returns the public cover URL the backend wrote to the story doc, or
  /// null when the payload carries none (the caller keeps the last good
  /// cover). [prompt] is an author override; null or blank falls back to
  /// the story bible prompt server-side.
  Future<String?> generateStoryCover({
    required String storyId,
    String? prompt,
  }) async {
    final story = storyId.trim();
    if (story.isEmpty) throw const AppFailure(.invalid);
    final data = {'storyId': story};
    final hint = prompt?.trim();
    if (hint != null && hint.isNotEmpty) data['prompt'] = hint;
    final payload = await callFunction('generateStoryCover', data);
    final url = payload['coverUrl'];
    return url is String && url.isNotEmpty ? url : null;
  }

  /// Asks for the node video via the `generateNodeVideo` callable. GATED
  /// server-side on ready frames: the root needs its own S ready, any other
  /// node needs its parent clip ready; the call inherits the parent clip's
  /// extracted last frame as this node's S. Returns whether the backend is
  /// still working the job: true means the caller re-asks until the backend
  /// reports done or the poll cap is hit. The caller reloads the nodes to
  /// read the resulting `pending`/`ready` status.
  Future<bool> generateNodeVideo({
    required String storyId,
    required String nodeId,
    String? prompt,
  }) async {
    final story = storyId.trim();
    final node = nodeId.trim();
    if (story.isEmpty || node.isEmpty) throw const AppFailure(.invalid);
    final data = {'storyId': story, 'nodeId': node};
    final hint = prompt?.trim();
    if (hint != null && hint.isNotEmpty) data['prompt'] = hint;
    final res = await callFunction('generateNodeVideo', data);
    return res['poll'] == true;
  }

  /// Transcribes one closed audio blob through `transcribeVoice`.
  /// Each call sends the WebM accumulated so far (header included) and
  /// the returned text replaces the on-screen transcript. `last` marks
  /// the full take on release. Blank ids, a negative [seq], or empty
  /// [audioBase64] throw [AppFailure.invalid] without touching the network.
  Future<TranscribedSlice> transcribeVoice({
    required String sessionId,
    required int seq,
    required String audioBase64,
    String format = 'webm',
    required bool last,
  }) async {
    final session = sessionId.trim();
    final audio = audioBase64.trim();
    final container = format.trim().isEmpty ? 'webm' : format.trim();
    if (session.isEmpty || audio.isEmpty || seq < 0) {
      throw const AppFailure(.invalid);
    }
    final payload = await callFunction('transcribeVoice', {
      'sessionId': session,
      'seq': seq,
      'audioBase64': audio,
      'format': container,
      'last': last,
    });
    final text = payload['text'];
    return (text: text is String ? text : '', done: payload['done'] == true);
  }

  /// Asks Spark for a story outline from a spoken transcript via the
  /// `proposeStoryOutline` callable. Proposal-only: nothing is written;
  /// the premise sheet shows the [ProposedOutline] editable and the bloc
  /// applies it through [updateStory] plus node writes on `Aplicar`.
  /// A blank id or transcript throws [AppFailure.invalid] without
  /// touching the network; an empty proposal throws
  /// [AppFailure.invalid].
  Future<ProposedOutline> proposeStoryOutline({
    required String storyId,
    required String transcript,
  }) async {
    final story = storyId.trim();
    if (story.isEmpty || transcript.trim().isEmpty) {
      throw const AppFailure(.invalid);
    }
    final payload = await callFunction('proposeStoryOutline', {
      'storyId': story,
      'transcript': transcript.trim(),
    });
    final proposal = ProposedOutline.fromJson(payload);
    if (proposal.isEmpty) throw const AppFailure(.invalid);
    return proposal;
  }

  /// Renders the node voice via the `generateNodeVoice` callable. GATED
  /// server-side on the non-blank narrator line; the call re-renders the
  /// take. Records intent; the caller reloads the nodes to read the
  /// resulting `pending`/`ready` take. Without TTS credentials the backend
  /// records `pending` instead of throwing.
  Future<void> generateNodeVoice({
    required String storyId,
    required String nodeId,
  }) async {
    final story = storyId.trim();
    final node = nodeId.trim();
    if (story.isEmpty || node.isEmpty) throw const AppFailure(.invalid);
    await callFunction('generateNodeVoice', {'storyId': story, 'nodeId': node});
  }

  /// Uploads a picked video for one node to the trigger path
  /// `uploads/{uid}/{storyId}_{nodeId}_{takeId}.mp4|.mov` (backend
  /// contract: `onUploadFinalized` parses the filename — Firestore
  /// auto-ids and the client take id never contain `_`, so the split is
  /// unambiguous). Extension follows the content type. [takeId] is the
  /// client take nonce the trigger echoes as `uploadTakeId` on every
  /// terminal path, so the bloc can tell its own trigger write apart from
  /// pre-trigger state. The trigger re-encodes, saves the node video,
  /// extracts E as the last frame, and deletes the upload. Failures leave
  /// the node untouched and set only `uploadError` (see
  /// [fetchUploadMarker]).
  ///
  /// Blank ids, a blank take id, an unsupported content type, or empty
  /// bytes throw [AppFailure.invalid] without touching the network — the
  /// bloc runs [validateVideoUpload] first, so this is a second gate, not
  /// the UX. [onProgress] reports 0..1 (transport-dependent granularity).
  Future<void> uploadNodeVideo({
    required String uid,
    required String storyId,
    required String nodeId,
    required String takeId,
    required String contentType,
    required List<int> bytes,
    void Function(double progress)? onProgress,
  }) async {
    final user = uid.trim();
    final story = storyId.trim();
    final node = nodeId.trim();
    final take = takeId.trim();
    final type = contentType.trim();
    if (user.isEmpty ||
        story.isEmpty ||
        node.isEmpty ||
        take.isEmpty ||
        take.contains('_') ||
        !videoUploadContentTypes.contains(type) ||
        bytes.isEmpty) {
      throw const AppFailure(.invalid);
    }
    final extension = type == 'video/quicktime' ? 'mov' : 'mp4';
    try {
      await uploadVideoFile(
        path: 'uploads/$user/${story}_${node}_$take.$extension',
        contentType: type,
        bytes: bytes,
        onProgress: onProgress,
      );
    } on AppFailure {
      rethrow;
    } catch (error) {
      throw AppFailure(.failed, cause: error);
    }
  }

  /// Trigger-written upload outcome for one node, read from the raw doc —
  /// never the model — so upload-only fields never leak into [DraftNode].
  /// [UploadMarker.takeId] is the `uploadTakeId` echo of the take that
  /// wrote it; the bloc polls until it matches its own take before
  /// trusting [UploadMarker.error], so a pre-trigger read never resolves
  /// the upload.
  Future<UploadMarker> fetchUploadMarker({
    required String storyId,
    required String nodeId,
  }) async {
    final story = storyId.trim();
    final node = nodeId.trim();
    if (story.isEmpty || node.isEmpty) throw const AppFailure(.invalid);
    final read = fetchNodeDoc;
    final docs = read == null
        ? await fetchNodeDocs(story)
        : [MapEntry(node, await read(story, node) ?? <String, dynamic>{})];
    for (final doc in docs) {
      if (doc.key == node) {
        final error = doc.value['uploadError'];
        final take = doc.value['uploadTakeId'];
        return (
          error: error is String && error.trim().isNotEmpty
              ? error.trim()
              : null,
          takeId: take is String && take.trim().isNotEmpty ? take.trim() : null,
        );
      }
    }
    return (error: null, takeId: null);
  }

  /// Reads the trigger-recorded upload error for one node (`uploadError`
  /// on the node doc), or null when the last upload did not fail. The
  /// bloc reads the full [fetchUploadMarker] after its own upload, so a
  /// stale error from an older attempt never surfaces on open.
  Future<String?> fetchUploadError({
    required String storyId,
    required String nodeId,
  }) async {
    final marker = await fetchUploadMarker(storyId: storyId, nodeId: nodeId);
    return marker.error;
  }
}

/// Production source:
///
/// * story doc: `stories` with `status == 'draft'`, created/updated
///   client-direct — firestore.rules only opens drafts to their author,
///   so no new backend was needed for the draft doc itself;
/// * node saves: a client merge of [nodeSavePatch] on the author's draft.
///   `createNode`, `deleteNode`, and `generateNodeText` stay callables.
CreateRepository createFirebaseCreateRepository([
  FirebaseFirestore? firestore,
  FunctionsClient? functions,
  UploadVideoFile? uploadVideoFile,
]) {
  final store = FirestoreDocumentStore(firestore ?? FirebaseFirestore.instance);
  String? uid() => FirebaseAuth.instance.currentUser?.uid;
  final drafts = ClientDraftPersistence(store, uid);
  final calls = functions ?? FunctionsClient();
  return CreateRepository(
    drafts: drafts,
    publisher: ClientPublisher(store, uid),
    createDraftDoc: ({required authorId, required title}) async =>
        (await drafts.createDraft(authorId, title)).$1.storyId,
    updateStoryDoc: ({required storyId, title, synopsis}) =>
        drafts.updateStory(storyId, title: title, synopsis: synopsis),
    fetchStoryDoc: (id) => store.get('stories/${documentId(id)}'),
    fetchNodeDocs: (id) async {
      final docs = await store.list('stories/${documentId(id)}/nodes');
      drafts.remember(id, [
        for (final doc in docs) DraftNode.fromMap(doc.key, doc.value),
      ]);
      return docs;
    },
    fetchNodeDoc: (storyId, nodeId) =>
        store.get('stories/${documentId(storyId)}/nodes/${documentId(nodeId)}'),
    fetchAuthorStoryDocs: ({required String authorId}) =>
        store.list('stories', equals: {'authorId': authorId}),
    callFunction: (name, data) => calls(name, data),
    uploadVideoFile: uploadVideoFile ?? uploadVideoToFirebase,
  );
}

Future<void> uploadVideoToFirebase({
  required String path,
  required String contentType,
  required List<int> bytes,
  void Function(double progress)? onProgress,
}) async {
  final task = FirebaseStorage.instance
      .ref(path)
      .putData(
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        SettableMetadata(contentType: contentType),
      );
  final subscription = task.snapshotEvents.listen((snapshot) {
    if (snapshot.totalBytes > 0) {
      onProgress?.call(snapshot.bytesTransferred / snapshot.totalBytes);
    }
  }, onError: (Object _) {});
  try {
    await task.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        task.cancel();
        throw const AppFailure(
          .offline,
          detail: 'Upload timed out. Try again.',
        );
      },
    );
  } on FirebaseException catch (error) {
    throw AppFailure(
      appFailureCodeFor(error.code),
      detail: error.message,
      cause: error,
    );
  } finally {
    await subscription.cancel();
  }
}
