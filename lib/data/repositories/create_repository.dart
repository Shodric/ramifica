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
  });

  /// Creates `stories/{id}` with `status: 'draft'` owned by [authorId].
  /// Returns the new story id.
  final Future<String> Function({
    required String authorId,
    required String title,
  }) createDraftDoc;

  /// Reads one story doc. Returns null when it does not exist.
  final Future<Map<String, dynamic>?> Function(String storyId) fetchStoryDoc;

  /// Reads every node doc of [storyId]: `(nodeId, data)` entries.
  final Future<List<MapEntry<String, Map<String, dynamic>>>> Function(
    String storyId,
  ) fetchNodeDocs;

  /// Calls a Create callable by name with the given payload.
  final Future<Map<String, dynamic>> Function(
    String name,
    Map<String, dynamic> data,
  ) callFunction;

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
        return [
          for (final doc in snap.docs) MapEntry(doc.id, doc.data()),
        ];
      } on FirebaseException catch (error) {
        throw AppFailure(appFailureCodeFor(error.code), cause: error);
      } catch (error) {
        throw AppFailure(.failed, cause: error);
      }
    },
    callFunction: (name, data) => calls(name, data),
  );
}
