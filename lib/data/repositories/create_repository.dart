import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/draft_story.dart';

/// What `generateNodeText` proposes. Proposal-only: the server writes
/// nothing; the bloc merges the proposal into empty fields and the author
/// saves explicitly. Every value is nullable and `choices` may be empty —
/// a partial proposal still parses.
///
/// Backend contract (functions/src/create/generateNodeText.ts): every key
/// is always present; `choices` is always an array of `{label}` maps;
/// `endingName` is non-null only for ending nodes.
class GeneratedNodeText {
  const GeneratedNodeText({
    this.title,
    this.ttsText,
    this.choiceLabels = const [],
    this.endingName,
  });

  factory GeneratedNodeText.fromJson(Map<String, dynamic> json) {
    return GeneratedNodeText(
      title: _optionalString(json['title']),
      ttsText: _optionalString(json['ttsText']),
      choiceLabels: _optionalLabels(json['choices'] ?? json['choiceLabels']),
      endingName: _optionalString(json['endingName']),
    );
  }

  final String? title;
  final String? ttsText;

  /// Proposed choice labels, in order. Applied to existing choices by
  /// index, never creating or deleting choices on their own.
  final List<String> choiceLabels;

  /// Proposed ending name, for ending nodes only.
  final String? endingName;

  /// True when the proposal carries nothing usable.
  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (ttsText == null || ttsText!.isEmpty) &&
      choiceLabels.isEmpty &&
      (endingName == null || endingName!.isEmpty);
}

String? _optionalString(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value;
  return null;
}

/// Accepts `[{label}]` maps or plain strings; anything else is skipped so
/// one malformed entry cannot sink the proposal.
List<String> _optionalLabels(Object? value) {
  if (value is! List) return const [];
  final labels = <String>[];
  for (final raw in value) {
    if (raw is String && raw.trim().isNotEmpty) {
      labels.add(raw);
    } else if (raw is Map) {
      final label = _optionalString(raw['label']);
      if (label != null) labels.add(label);
    }
  }
  return labels;
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
/// * nodes are Functions-only (`nodes` writes are `false`), so every node
///   mutation goes through the `createNode` / `saveNode` callables named
///   in docs/architecture.md (backend to provide; the text-gen half of
///   #45 implements `generateNodeText` only — see module doc);
/// * `generateNodeText` proposes text without writing anything.
///
/// Tests inject the lambdas; production uses
/// [createFirebaseCreateRepository].
class CreateRepository {
  CreateRepository({
    required this.createDraftDoc,
    required this.fetchStoryDoc,
    required this.fetchNodeDocs,
    required this.callFunction,
    UploadVideoFile? uploadVideoFile,
  }) : uploadVideoFile = uploadVideoFile ?? _unwiredUpload;

  /// Creates `stories/{id}` with `status: 'draft'` owned by [authorId].
  /// Returns the new story id.
  final Future<String> Function({
    required String authorId,
    required String title,
  })
  createDraftDoc;

  /// Reads one story doc. Returns null when it does not exist.
  final Future<Map<String, dynamic>?> Function(String storyId) fetchStoryDoc;

  /// Reads every node doc of [storyId]: `(nodeId, data)` entries.
  final Future<List<MapEntry<String, Map<String, dynamic>>>> Function(
    String storyId,
  )
  fetchNodeDocs;

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
  /// `createNode` callable (node writes are Functions-only). A blank
  /// author id throws [AppFailure.invalid] without touching the network.
  Future<(DraftStory, DraftNode)> createDraft({
    required String authorId,
    String title = 'Untitled story',
  }) async {
    final author = authorId.trim();
    if (author.isEmpty) throw const AppFailure(.invalid);
    final storyId = await createDraftDoc(authorId: author, title: title);
    final payload = await callFunction('createNode', {'storyId': storyId});
    final nodeId = payload['nodeId'];
    if (nodeId is! String || nodeId.isEmpty) {
      throw const AppFailure(.invalid);
    }
    final story = await fetchDraft(storyId);
    if (story == null) throw const AppFailure(.failed);
    final nodes = await fetchNodes(storyId);
    final root = nodes.where((node) => node.nodeId == nodeId);
    if (root.isEmpty) throw const AppFailure(.failed);
    return (story, root.first);
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

  /// Adds a child node under [parentNodeId] through the `createNode`
  /// callable. Returns the new node id.
  Future<String> createNode({
    required String storyId,
    required String parentNodeId,
  }) async {
    final story = storyId.trim();
    final parent = parentNodeId.trim();
    if (story.isEmpty || parent.isEmpty) throw const AppFailure(.invalid);
    final payload = await callFunction('createNode', {
      'storyId': story,
      'parentNodeId': parent,
    });
    final nodeId = payload['nodeId'];
    if (nodeId is! String || nodeId.isEmpty) {
      throw const AppFailure(.invalid);
    }
    return nodeId;
  }

  /// Persists the author's edits through the `saveNode` callable.
  Future<void> saveNode({
    required String storyId,
    required DraftNode node,
  }) async {
    final story = storyId.trim();
    if (story.isEmpty) throw const AppFailure(.invalid);
    await callFunction('saveNode', {
      'storyId': story,
      'node': {'nodeId': node.nodeId, ...node.toJson()},
    });
  }

  /// Asks Spark for proposed text. Proposal-only: nothing is written;
  /// the bloc merges the proposal into empty fields (or every field on
  /// an explicit regenerate) and the author saves by hand.
  ///
  /// The server also accepts an optional `context` key and a null
  /// `nodeId` for new-node proposals; the client always has an open node
  /// here, so it sends both ids and the optional author prompt.
  Future<GeneratedNodeText> generateNodeText({
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
    final payload = await callFunction('generateNodeText', data);
    final proposal = GeneratedNodeText.fromJson(payload);
    if (proposal.isEmpty) throw const AppFailure(.invalid);
    return proposal;
  }

  /// Asks for a node frame via the `generateNodeImage` callable. [which]
  /// is `start` (root only) or `end` (any node); anything else throws
  /// [AppFailure.invalid] without touching the network. Generation is
  /// server-side: this records intent, then the caller reloads the nodes
  /// to read the resulting `pending`/`ready` status and approval reset.
  Future<void> generateNodeImage({
    required String storyId,
    required String nodeId,
    required String which,
    String? prompt,
  }) async {
    final story = storyId.trim();
    final node = nodeId.trim();
    if (story.isEmpty || node.isEmpty) throw const AppFailure(.invalid);
    if (which != 'start' && which != 'end') {
      throw const AppFailure(.invalid);
    }
    final data = {'storyId': story, 'nodeId': node, 'which': which};
    final hint = prompt?.trim();
    if (hint != null && hint.isNotEmpty) data['prompt'] = hint;
    await callFunction('generateNodeImage', data);
  }

  /// Approves or rejects one node frame via the `approveNodeImage`
  /// callable. The backend records the approval (an E approval lets
  /// children inherit it as their S); the caller reloads the nodes after.
  Future<void> approveNodeImage({
    required String storyId,
    required String nodeId,
    required String which,
    required bool approved,
  }) async {
    final story = storyId.trim();
    final node = nodeId.trim();
    if (story.isEmpty || node.isEmpty) throw const AppFailure(.invalid);
    if (which != 'start' && which != 'end') {
      throw const AppFailure(.invalid);
    }
    await callFunction('approveNodeImage', {
      'storyId': story,
      'nodeId': node,
      'which': which,
      'approved': approved,
    });
  }

  /// Asks for the node video via the `generateNodeVideo` callable. GATED
  /// server-side on the approved parent E (own S on the root); the call
  /// inherits that E as this node's S. Records intent; the caller reloads
  /// the nodes to read the resulting `pending`/`ready` status.
  Future<void> generateNodeVideo({
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
    await callFunction('generateNodeVideo', data);
  }

  /// Renders the node voice via the `generateNodeVoice` callable. GATED
  /// server-side on the approved, non-blank narrator line; every take
  /// lands with `ttsApproved: false` for the author to preview. Records
  /// intent; the caller reloads the nodes to read the resulting
  /// `pending`/`ready` take. Without TTS credentials the backend records
  /// `pending` instead of throwing.
  Future<void> generateNodeVoice({
    required String storyId,
    required String nodeId,
  }) async {
    final story = storyId.trim();
    final node = nodeId.trim();
    if (story.isEmpty || node.isEmpty) throw const AppFailure(.invalid);
    await callFunction('generateNodeVoice', {
      'storyId': story,
      'nodeId': node,
    });
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
    final docs = await fetchNodeDocs(story);
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
/// * nodes: the `createNode`, `saveNode`, and `generateNodeText`
///   callables in `us-central1` (node writes are `false` in the rules).
CreateRepository createFirebaseCreateRepository([
  FirebaseFirestore? firestore,
  FunctionsClient? functions,
  UploadVideoFile? uploadVideoFile,
]) {
  final db = firestore ?? FirebaseFirestore.instance;
  final calls = functions ?? FunctionsClient();
  return CreateRepository(
    createDraftDoc: ({required authorId, required title}) async {
      try {
        final ref = await db.collection('stories').add({
          'authorId': authorId,
          'title': title,
          'synopsis': '',
          'status': 'draft',
          'rootNodeId': null,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return ref.id;
      } on FirebaseException catch (error) {
        throw AppFailure(appFailureCodeFor(error.code), cause: error);
      } catch (error) {
        throw AppFailure(.failed, cause: error);
      }
    },
    fetchStoryDoc: (storyId) async {
      try {
        final doc = await db.collection('stories').doc(storyId).get();
        if (!doc.exists) return null;
        return doc.data();
      } on FirebaseException catch (error) {
        throw AppFailure(appFailureCodeFor(error.code), cause: error);
      } catch (error) {
        throw AppFailure(.failed, cause: error);
      }
    },
    fetchNodeDocs: (storyId) async {
      try {
        final snap = await db
            .collection('stories')
            .doc(storyId)
            .collection('nodes')
            .get();
        return [for (final doc in snap.docs) MapEntry(doc.id, doc.data())];
      } on FirebaseException catch (error) {
        throw AppFailure(appFailureCodeFor(error.code), cause: error);
      } catch (error) {
        throw AppFailure(.failed, cause: error);
      }
    },
    callFunction: (name, data) => calls(name, data),
    // No firebase_storage dependency yet: production upload transport is
    // Main's wiring (putData/putFile with the content type, single-shot —
    // storage.rules allows create only, so chunked resumption needs care).
    // Omitted here so the constructor default fails closed.
    uploadVideoFile: uploadVideoFile,
  );
}
