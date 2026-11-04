import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/draft_story.dart';
import 'package:ramifica/data/persistence/document_store.dart';
import 'package:ramifica/data/persistence/draft_persistence.dart';
import 'package:ramifica/data/persistence/publication.dart';
import 'package:ramifica/data/repositories/create_repository.dart';

import 'memory_document_store.dart';

/// Compatibility harness for older UI tests whose fake transports record action
/// names. These callbacks never reach Functions. Direct transaction semantics are
/// tested separately using the production writers in direct_persistence_test.
CreateRepository testCreateRepository({
  required Future<String> Function({
    required String authorId,
    required String title,
  })
  createDraftDoc,
  UpdateStoryDoc? updateStoryDoc,
  required Future<Json?> Function(String) fetchStoryDoc,
  required Future<List<StoredDoc>> Function(String) fetchNodeDocs,
  required Future<Json> Function(String, Json) callFunction,
  Future<List<StoredDoc>> Function({required String authorId})?
  fetchAuthorStoryDocs,
  SaveNodeDoc? saveNodeDoc,
  UploadVideoFile? uploadVideoFile,
}) {
  final drafts = _DraftHarness(
    createDraftDoc,
    fetchStoryDoc,
    fetchNodeDocs,
    callFunction,
    saveNodeDoc,
    updateStoryDoc,
  );
  return CreateRepository(
    createDraftDoc: createDraftDoc,
    updateStoryDoc: updateStoryDoc,
    fetchStoryDoc: fetchStoryDoc,
    fetchNodeDocs: fetchNodeDocs,
    fetchAuthorStoryDocs: fetchAuthorStoryDocs,
    callFunction: callFunction,
    saveNodeDoc: saveNodeDoc,
    uploadVideoFile: uploadVideoFile,
    drafts: drafts,
    publisher: _PublisherHarness(callFunction),
  );
}

class _PublisherHarness extends ClientPublisher {
  _PublisherHarness(this.call) : super(MemoryDocumentStore(), () => 'test');
  final Future<Json> Function(String, Json) call;
  @override
  Future<List<String>> publish(String storyId) async {
    final result = await call('publishStory', {'storyId': storyId});
    return [for (final p in result['problems'] as List? ?? []) p.toString()];
  }
}

class _DraftHarness implements DraftPersistence {
  _DraftHarness(
    this.create,
    this.story,
    this.nodes,
    this.call,
    this.directSave,
    this.update,
  );
  final Future<String> Function({
    required String authorId,
    required String title,
  })
  create;
  final Future<Json?> Function(String) story;
  final Future<List<StoredDoc>> Function(String) nodes;
  final Future<Json> Function(String, Json) call;
  final SaveNodeDoc? directSave;
  final UpdateStoryDoc? update;
  final _overrides = <String, DraftNode>{};
  Future<List<DraftNode>> _read(String id) async => [
    for (final doc in await nodes(id))
      _overrides[doc.key] ?? DraftNode.fromMap(doc.key, doc.value),
  ];
  @override
  Stream<List<DraftNode>> watchNodes(String storyId) => const Stream.empty();
  @override
  Future<(DraftStory, DraftNode)> createDraft(
    String authorId,
    String title,
  ) async {
    final id = await create(authorId: authorId, title: title);
    final child = await call('createNode', {'storyId': id});
    final raw = await story(id) ?? {'authorId': authorId, 'title': title};
    final rootId =
        child['nodeId'] as String? ?? raw['rootNodeId'] as String? ?? 'root';
    final root =
        (await _read(id)).where((n) => n.nodeId == rootId).firstOrNull ??
        DraftNode(nodeId: rootId);
    return (DraftStory.fromDoc(id, {...raw, 'rootNodeId': rootId}), root);
  }

  @override
  Future<void> save(String storyId, DraftNode node) async {
    if (directSave != null) {
      await directSave!(storyId: storyId, nodeId: node.nodeId, node: node);
    } else {
      await call('saveNode', {
        'storyId': storyId,
        'node': {...node.toJson(), 'nodeId': node.nodeId},
      });
    }
    _overrides[node.nodeId] = node;
  }

  @override
  Future<void> updateStory(
    String storyId, {
    String? title,
    String? synopsis,
  }) async {
    await update?.call(storyId: storyId, title: title, synopsis: synopsis);
  }

  @override
  Future<void> unpublishStory(String storyId) async {
    await call('unpublishStory', {'storyId': storyId});
  }

  @override
  Future<void> deleteStory(String storyId) async {
    await call('deleteStory', {'storyId': storyId});
  }

  @override
  Future<void> delete(String storyId, String nodeId) async {
    await call('deleteNode', {'storyId': storyId, 'nodeId': nodeId});
    _overrides.remove(nodeId);
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
    final before = await _read(storyId);
    var parent = before.firstWhere((n) => n.nodeId == parentId);
    final slots = {
      for (var i = 0; i < parent.choices.length; i++)
        parent.choices[i].slot ?? (i == 0 ? 'A' : 'B'),
    };
    final wanted = slot ?? (slots.contains('A') ? 'B' : 'A');
    final existing = parent.choices.where((c) => c.slot == wanted);
    if (existing.isNotEmpty) {
      return DraftChange([parent], existing.first.targetNodeId);
    }
    final raw = await call('createNode', {
      'storyId': storyId,
      'parentNodeId': parentId,
      'requestId': ?requestId,
    });
    final childId = raw['nodeId'] as String? ?? 'child';
    final child =
        before.where((n) => n.nodeId == childId).firstOrNull ??
        DraftNode(nodeId: childId, startFromNodeId: parentId);
    parent = parent.copy(
      choices: [
        ...parent.choices,
        DraftChoice(
          choiceId: '$parentId:$wanted:$childId',
          targetNodeId: childId,
          label: label,
          slot: wanted,
          isDefault: parent.choices.isEmpty,
          icon: icon ?? (wanted == 'A' ? 'compass' : 'moon'),
          iconColor: iconColor ?? (wanted == 'A' ? 'cyan' : 'blue'),
          x: DraftChoice.defaultXFor(wanted),
        ),
      ],
    );
    await save(storyId, parent);
    return DraftChange([parent, child], childId);
  }

  @override
  Future<DraftChange> applyScene(
    String storyId,
    String nodeId,
    Json fields,
    List<Json> proposals,
  ) async {
    final source = await _read(storyId);
    final rawStory = await story(storyId) ?? {};
    final isRoot = rawStory['rootNodeId'] == nodeId;
    var node = source.firstWhere((n) => n.nodeId == nodeId);
    final data = node.toJson();
    String clip(String value, int cap) =>
        value.length > cap ? value.substring(0, cap) : value;
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
        data[name] = clip(value.trim(), cap);
      }
    }
    if (!isRoot) {
      data['startImagePrompt'] = null;
    }
    node = DraftNode.fromMap(nodeId, data);
    if (node.ttsText != source.firstWhere((n) => n.nodeId == nodeId).ttsText) {
      node = node.copy(
        ttsStatus: 'idle',
        ttsAudioUrl: () => null,
        ttsDurationSeconds: () => null,
      );
    }
    if (fields.entries.any(
      (e) => !e.key.startsWith('_') && e.value != null && e.value != '',
    )) {
      await save(storyId, node);
    }
    if (fields['_storyTitle'] != null || fields['_synopsis'] != null) {
      await updateStory(
        storyId,
        title: fields['_storyTitle'],
        synopsis: fields['_synopsis'],
      );
    }
    final changed = <DraftNode>[node];
    if (!node.isEnding) {
      for (var i = 0; i < proposals.length && i < 2; i++) {
        final label = (proposals[i]['label'] as String? ?? '').trim();
        if (label.isEmpty) continue;
        final slot = i == 0 ? 'A' : 'B';
        final at = node.choices.indexWhere(
          (c) => (c.slot ?? (node.choices.indexOf(c) == 0 ? 'A' : 'B')) == slot,
        );
        if (at >= 0) {
          final current = node.choices[at];
          final overwritten = DraftChoice(
            choiceId: current.choiceId,
            label: clip(label, 24),
            targetNodeId: current.targetNodeId,
            isDefault: current.isDefault,
            slot: current.slot,
            icon: proposals[i]['icon'] as String?,
            iconColor: proposals[i]['iconColor'] as String?,
            x: current.x,
            y: current.y,
            radius: current.radius,
          );
          node = node.copy(
            choices: [
              for (var j = 0; j < node.choices.length; j++)
                if (j == at) overwritten else node.choices[j],
            ],
          );
          await save(storyId, node);
          changed.removeWhere((n) => n.nodeId == nodeId);
          changed.add(node);
          continue;
        }
        final c = await createAndLink(
          storyId,
          nodeId,
          slot: slot,
          requestId: 'v1:${rawStory['authorId']}:$storyId:$nodeId:$slot',
          label: clip(label, 24),
          icon: proposals[i]['icon'] as String?,
          iconColor: proposals[i]['iconColor'] as String?,
        );
        changed.removeWhere((n) => n.nodeId == nodeId);
        changed.addAll(c.nodes);
        node = changed.firstWhere((n) => n.nodeId == nodeId);
      }
    }
    return DraftChange(changed, nodeId);
  }
}
