import 'package:ramifica/core/widgets/choice_icon.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/draft_story.dart';
import 'package:ramifica/data/persistence/document_store.dart';
import 'package:ramifica/data/persistence/node_fields.dart';
import 'package:uuid/uuid.dart';

class DraftChange {
  const DraftChange(this.nodes, this.selectedId);
  final List<DraftNode> nodes;
  final String selectedId;
}

abstract interface class DraftPersistence {
  Future<(DraftStory, DraftNode)> createDraft(String authorId, String title);
  Future<void> save(String storyId, DraftNode node);
  Future<void> updateStory(String storyId, {String? title, String? synopsis});

  /// Flips a published story back to `draft`: players lose access
  /// because every read rule requires `status: 'published'`. Guarded:
  /// author-owned and currently published.
  Future<void> unpublishStory(String storyId);

  /// Deletes the draft story doc. Node and publication docs become
  /// unreachable orphans (every rule path reads the story doc) and
  /// Storage bytes stay, matching node deletes.
  Future<void> deleteStory(String storyId);
  Future<DraftChange> createAndLink(
    String storyId,
    String parentId, {
    String? slot,
    String? requestId,
    String label = '',
    String? icon,
    String? iconColor,
  });
  Future<DraftChange> applyScene(
    String storyId,
    String nodeId,
    Json fields,
    List<Json> proposals,
  );
  Future<void> delete(String storyId, String nodeId);
  Stream<List<DraftNode>> watchNodes(String storyId);
}

/// All authoring writes are direct Firestore transactions/batches.
class ClientDraftPersistence implements DraftPersistence {
  ClientDraftPersistence(this.store, this.currentUid);
  final DocumentStore store;
  final String? Function() currentUid;
  final _requestNodes = <String, String>{};
  final _loadedStories = <String>{};

  String _uid() {
    final uid = currentUid();
    if (uid == null || uid.isEmpty) throw const AppFailure(.denied);
    return uid;
  }

  Future<Json> _draft(DocumentTransaction tx, String id) async {
    final story = await tx.get('stories/${documentId(id)}');
    if (story == null) invalid('Story not found.');
    if (story['authorId'] != _uid()) throw const AppFailure(.denied);
    if (story['status'] != 'draft') invalid('Only drafts can be edited.');
    return story;
  }

  void remember(String storyId, Iterable<DraftNode> nodes) {
    _loadedStories.add(storyId);
    for (final node in nodes) {
      if (node.requestId != null) {
        _requestNodes['$storyId:${node.requestId}'] = node.nodeId;
      }
    }
  }

  @override
  Stream<List<DraftNode>> watchNodes(String storyId) =>
      store.watch('stories/${documentId(storyId)}/nodes').map((docs) {
        final nodes = [
          for (final doc in docs) DraftNode.fromMap(doc.key, doc.value),
        ];
        remember(storyId, nodes);
        return nodes;
      });

  @override
  Future<(DraftStory, DraftNode)> createDraft(
    String authorId,
    String title,
  ) async {
    if (authorId != _uid()) throw const AppFailure(.denied);
    final storyId = store.newId('stories');
    final root = DraftNode(
      nodeId: store.newId('stories/$storyId/nodes'),
      visibility: 'secret',
    );
    final story = DraftStory(
      storyId: storyId,
      authorId: authorId,
      title: title,
      rootNodeId: root.nodeId,
    );
    await store.batch([
      DocumentWrite('stories/$storyId', {
        'authorId': authorId,
        'title': title,
        'synopsis': '',
        'status': 'draft',
        'rootNodeId': root.nodeId,
        'revision': 0,
        'createdAt': commitTime,
        'updatedAt': commitTime,
      }),
      DocumentWrite('stories/$storyId/nodes/${root.nodeId}', root.toJson()),
    ]);
    _loadedStories.add(storyId);
    return (story, root);
  }

  @override
  Future<void> updateStory(String storyId, {String? title, String? synopsis}) =>
      store.transaction((tx) async {
        final story = await _draft(tx, storyId);
        tx.set('stories/$storyId', {
          'title': ?title,
          'synopsis': ?synopsis,
        }, merge: true);
        advanceRevision(tx, storyId, story);
      });

  @override
  Future<void> unpublishStory(String storyId) => store.transaction((tx) async {
    final path = 'stories/${documentId(storyId)}';
    final story = await tx.get(path);
    if (story == null) invalid('Story not found.');
    if (story['authorId'] != _uid()) throw const AppFailure(.denied);
    if (story['status'] != 'published') {
      invalid('Only published stories can be hidden.');
    }
    // The rules' unpublish branch allows exactly these three keys.
    tx.set(path, {
      'status': 'draft',
      'revision': revisionOf(story) + 1,
      'updatedAt': commitTime,
    }, merge: true);
  });

  @override
  Future<void> deleteStory(String storyId) => store.transaction((tx) async {
    final path = 'stories/${documentId(storyId)}';
    final story = await tx.get(path);
    if (story == null) invalid('Story not found.');
    if (story['authorId'] != _uid()) throw const AppFailure(.denied);
    if (story['status'] != 'draft') {
      invalid('Hide the story before deleting it.');
    }
    tx.delete(path);
  });

  @override
  Future<void> save(String storyId, DraftNode node) =>
      store.transaction((tx) async {
        final story = await _draft(tx, storyId);
        final path = 'stories/$storyId/nodes/${documentId(node.nodeId)}';
        final before = await tx.get(path);
        if (before == null) invalid('Scene not found.');
        final patch = nodeSavePatch(node, before['ttsText'] as String? ?? '');
        validateAuthorNode({...before, ...patch});
        tx.set(path, patch, merge: true);
        advanceRevision(tx, storyId, story);
      });

  String _childId(String storyId, String requestId) =>
      _requestNodes['$storyId:$requestId'] ??
      const Uuid().v5(Namespace.url.value, 'ramifica:$storyId:$requestId');

  Future<String> _resolveRequest(String storyId, String requestId) async {
    final cacheKey = '$storyId:$requestId';
    if (!_loadedStories.contains(storyId) &&
        !_requestNodes.containsKey(cacheKey)) {
      final legacy = await store.list(
        'stories/${documentId(storyId)}/nodes',
        equals: {'requestId': requestId},
        limit: 1,
        server: true,
      );
      if (legacy.isNotEmpty) _requestNodes[cacheKey] = legacy.first.key;
    }
    return _childId(storyId, requestId);
  }

  @override
  Future<DraftChange> createAndLink(
    String storyId,
    String parentId, {
    String? slot,
    String? requestId,
    String label = '',
    String? icon,
    String? iconColor,
  }) async {
    final key = requestId ?? const Uuid().v4();
    final childId = requestId == null
        ? _childId(storyId, key)
        : await _resolveRequest(storyId, key);
    return store.transaction((tx) async {
      final story = await _draft(tx, storyId);
      final parentPath = 'stories/$storyId/nodes/${documentId(parentId)}';
      final raw = await tx.get(parentPath);
      if (raw == null) invalid('Parent scene not found.');
      final parent = DraftNode.fromMap(parentId, raw);
      if (parent.isEnding) invalid('An ending cannot have Options.');
      if (slot != null && parent.isSlotCut(slot)) {
        invalid('That path is cut.');
      }
      final wanted = slot ?? _autoSlot(parent);
      if (wanted == null) invalid('No open path left.');
      if (wanted != 'A' && wanted != 'B') invalid('Invalid Option slot.');
      final occupied = parent.choices.where((c) => _slot(parent, c) == wanted);
      if (occupied.isNotEmpty) {
        return DraftChange([parent], occupied.first.targetNodeId);
      }
      if (parent.choices.length >= 2) {
        invalid('At most two Options are allowed.');
      }
      final childPath = 'stories/$storyId/nodes/$childId';
      final existing = await tx.get(childPath);
      final child = existing == null
          ? DraftNode(
              nodeId: childId,
              visibility: 'secret',
              startFromNodeId: parentId,
              requestId: key,
            )
          : DraftNode.fromMap(childId, existing);
      if (existing != null &&
          (child.requestId != key || child.startFromNodeId != parentId)) {
        invalid('The requestId belongs to another scene.');
      }
      final choice = DraftChoice(
        choiceId: const Uuid().v5(
          Namespace.url.value,
          '$parentId:$wanted:$childId',
        ),
        label: label,
        targetNodeId: childId,
        slot: wanted,
        isDefault: parent.choices.isEmpty,
        icon: _icon(icon) ?? (wanted == 'A' ? 'compass' : 'moon'),
        iconColor: _color(iconColor) ?? (wanted == 'A' ? 'cyan' : 'blue'),
        x: DraftChoice.defaultXFor(wanted),
      );
      final linked = parent.copy(choices: [...parent.choices, choice]);
      if (existing == null) tx.set(childPath, child.toJson());
      tx.set(parentPath, {'choices': linked.toJson()['choices']}, merge: true);
      advanceRevision(tx, storyId, story);
      return DraftChange([linked, child], childId);
    });
  }

  @override
  Future<DraftChange> applyScene(
    String storyId,
    String nodeId,
    Json fields,
    List<Json> proposals,
  ) async {
    final uid = _uid();
    final ids = <String, String>{
      for (final slot in ['A', 'B'])
        slot: await _resolveRequest(storyId, 'v1:$uid:$storyId:$nodeId:$slot'),
    };
    return store.transaction((tx) async {
      final story = await _draft(tx, storyId);
      final path = 'stories/$storyId/nodes/${documentId(nodeId)}';
      final before = await tx.get(path);
      if (before == null) invalid('Scene not found.');
      final childDocs = <String, Json?>{};
      for (final id in ids.values) {
        childDocs[id] = await tx.get('stories/$storyId/nodes/$id');
      }
      final isRoot = story['rootNodeId'] == nodeId;
      final merged = Json.of(before);
      for (final name in [
        'title',
        'ttsText',
        'startImagePrompt',
        'videoPrompt',
      ]) {
        if (name == 'startImagePrompt' && !isRoot) {
          continue;
        }
        final value = fields[name];
        if (value is String && value.trim().isNotEmpty) {
          final cap = name == 'title'
              ? 40
              : name == 'ttsText'
              ? 280
              : 2000;
          merged[name] = _clip(value.trim(), cap);
        }
      }
      // The start prompt is inherited on children: force it null.
      if (!isRoot) {
        merged['startImagePrompt'] = null;
      }
      var node = DraftNode.fromMap(nodeId, merged);
      final choices = [...node.choices];
      final children = <DraftNode>[];
      if (!node.isEnding) {
        for (var index = 0; index < proposals.length && index < 2; index++) {
          final proposal = proposals[index];
          final label = (proposal['label'] as String? ?? '').trim();
          if (label.isEmpty) continue;
          final slot = index == 0 ? 'A' : 'B';
          if (node.isSlotCut(slot)) continue;
          final at = choices.indexWhere((c) => _slot(node, c) == slot);
          if (at >= 0) {
            final choice = choices[at];
            choices[at] = DraftChoice(
              choiceId: choice.choiceId,
              label: _clip(label, 24),
              targetNodeId: choice.targetNodeId,
              isDefault: choice.isDefault,
              slot: choice.slot,
              icon: _icon(proposal['icon']),
              iconColor: _color(proposal['iconColor']),
              x: choice.x,
              y: choice.y,
              radius: choice.radius,
            );
            continue;
          }
          if (choices.length >= 2) continue;
          final id = ids[slot]!;
          final raw = childDocs[id];
          final child = raw == null
              ? DraftNode(
                  nodeId: id,
                  startFromNodeId: nodeId,
                  requestId: 'v1:$uid:$storyId:$nodeId:$slot',
                )
              : DraftNode.fromMap(id, raw);
          children.add(child);
          choices.add(
            DraftChoice(
              choiceId: const Uuid().v5(
                Namespace.url.value,
                '$nodeId:$slot:$id',
              ),
              targetNodeId: id,
              label: _clip(label, 24),
              slot: slot,
              isDefault: choices.isEmpty,
              icon:
                  _icon(proposal['icon']) ?? (slot == 'A' ? 'compass' : 'moon'),
              iconColor:
                  _color(proposal['iconColor']) ??
                  (slot == 'A' ? 'cyan' : 'blue'),
              x: DraftChoice.defaultXFor(slot),
            ),
          );
        }
      }
      node = node.copy(choices: node.isEnding ? const [] : choices);
      final patch = nodeSavePatch(node, before['ttsText'] as String? ?? '');
      validateAuthorNode({...before, ...patch});
      for (final child in children) {
        if (childDocs[child.nodeId] == null) {
          tx.set('stories/$storyId/nodes/${child.nodeId}', child.toJson());
        }
      }
      tx.set(path, patch, merge: true);
      final storyPatch = <String, dynamic>{};
      if (fields['_storyTitle'] case final String title
          when title.trim().isNotEmpty) {
        storyPatch['title'] = _clip(title.trim(), 40);
      }
      if (fields['_synopsis'] case final String synopsis
          when synopsis.trim().isNotEmpty) {
        storyPatch['synopsis'] = synopsis.trim();
      }
      if (storyPatch.isNotEmpty) {
        tx.set('stories/$storyId', storyPatch, merge: true);
      }
      advanceRevision(tx, storyId, story);
      return DraftChange([
        DraftNode.fromMap(nodeId, {...before, ...patch}),
        ...children,
      ], nodeId);
    });
  }

  @override
  Future<void> delete(String storyId, String nodeId) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final head = await store.get('stories/$storyId', server: true);
      if (head == null) invalid('Story not found.');
      final docs = await store.list('stories/$storyId/nodes', server: true);
      if (head['rootNodeId'] == nodeId) {
        invalid('The root scene cannot be deleted.');
      }
      if (docs.any(
        (doc) =>
            doc.key != nodeId &&
            (doc.value['choices'] as List? ?? []).any(
              (c) => jsonMap(c)['targetNodeId'] == nodeId,
            ),
      )) {
        invalid('This scene is still targeted by an Option.');
      }
      final deleted = await store.transaction((tx) async {
        final story = await _draft(tx, storyId);
        final node = await tx.get('stories/$storyId/nodes/$nodeId');
        if (revisionOf(story) != revisionOf(head)) return false;
        if (node == null) return true;
        if (story['rootNodeId'] == nodeId) {
          invalid('The root scene cannot be deleted.');
        }
        tx.delete('stories/$storyId/nodes/${documentId(nodeId)}');
        advanceRevision(tx, storyId, story);
        return true;
      });
      if (deleted) return;
    }
    invalid('The story changed. Try deleting the scene again.');
  }
}

/// First open slot no Option occupies; cut slots never come back here.
String? _autoSlot(DraftNode parent) {
  final taken = {for (final c in parent.choices) _slot(parent, c)};
  for (final slot in parent.openSlots) {
    if (!taken.contains(slot)) return slot;
  }
  return null;
}

String _slot(DraftNode node, DraftChoice choice) {
  if (choice.slot == 'A' || choice.slot == 'B') return choice.slot!;
  final free = ['A', 'B']
    ..removeWhere((slot) => node.choices.any((c) => c.slot == slot));
  final legacy = node.choices
      .where((c) => c.slot != 'A' && c.slot != 'B')
      .toList();
  final index = legacy.indexOf(choice);
  return index >= 0 && index < free.length ? free[index] : '';
}

String _clip(String text, int count) =>
    text.length > count ? text.substring(0, count) : text;
String? _icon(Object? value) =>
    choiceIconOptions.any((option) => option.name == value)
    ? value as String
    : null;
String? _color(Object? value) =>
    choiceColorOptions.any((option) => option.name == value)
    ? value as String
    : null;

void validateAuthorNode(Json node) {
  void text(String key, int max) {
    final value = node[key];
    if (value != null && (value is! String || value.length > max)) {
      invalid('$key is limited to $max characters.');
    }
  }

  text('title', 40);
  text('ttsText', 1000);
  for (final key in ['startImagePrompt', 'videoPrompt', 'sceneDirection']) {
    text(key, 2000);
  }
  if (!['visible', 'secret'].contains(node['visibility'])) {
    invalid('Invalid visibility.');
  }
  final choices = node['choices'];
  if (choices is! List ||
      choices.length > 2 ||
      (node['isEnding'] == true && choices.isNotEmpty)) {
    invalid('Invalid Options.');
  }
  final cut = node['cutSlots'];
  if (cut != null && (cut is! List || cut.any((s) => s != 'A' && s != 'B'))) {
    invalid('Invalid cut paths.');
  }
  final ids = <String>{};
  final slots = <String>{};
  for (final raw in choices) {
    final c = jsonMap(raw);
    final label = c['label'];
    if (label is! String || label.length > 24) {
      invalid('Option labels allow 24 characters.');
    }
    documentId(c['targetNodeId'] as String? ?? '');
    final id = documentId(c['choiceId'] as String? ?? '');
    if (!ids.add(id)) invalid('Option ids must be unique.');
    final slot = c['slot'];
    if (slot != null &&
        (!['A', 'B'].contains(slot) || !slots.add(slot as String))) {
      invalid('Option slots must be unique.');
    }
    for (final key in ['x', 'y', 'radius']) {
      final value = c[key];
      if (value is! num || !value.isFinite || value < 0 || value > 1) {
        invalid('Invalid Option zone.');
      }
    }
  }
}
