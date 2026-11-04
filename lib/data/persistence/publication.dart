import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/persistence/document_store.dart';

const fallbackBlur =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAF'
    'gAI/ScLbtAAAAABJRU5ErkJggg==';

/// Mirrors the original publication checklist, now run on the client.
/// Existing published stories are migrated without revalidating legacy media.
List<String> validatePublication(Json story, Map<String, Json> nodes) {
  final problems = <String>[];
  final root = story['rootNodeId'] as String?;
  if (!nodes.containsKey(root)) problems.add('Missing root node.');
  if (!nodes.values.any((n) => n['isEnding'] == true)) {
    problems.add('At least one ending is required.');
  }
  if (nodes.containsKey(root)) {
    final seen = <String>{};
    final queue = <String>[root!];
    while (queue.isNotEmpty) {
      final id = queue.removeLast();
      if (!seen.add(id)) continue;
      for (final c in nodes[id]?['choices'] as List? ?? const []) {
        final target = jsonMap(c)['targetNodeId'];
        if (target is String && nodes.containsKey(target)) queue.add(target);
      }
    }
    for (final id in nodes.keys) {
      if (!seen.contains(id)) {
        problems.add('Node $id is not reachable from the root.');
      }
    }
  }
  bool hasText(Object? value) => value is String && value.trim().isNotEmpty;
  bool positive(Object? value) => value is num && value.isFinite && value > 0;
  for (final entry in nodes.entries) {
    final id = entry.key;
    final n = entry.value;
    final title = n['title'];
    if (!hasText(title) || (title as String).length > 40) {
      problems.add('Node $id needs a title of 1-40 characters.');
    }
    if (!['visible', 'secret'].contains(n['visibility'])) {
      problems.add('Node $id needs a valid visibility.');
    }
    if (n['videoStatus'] != 'ready' || !hasText(n['videoUrl'])) {
      problems.add('Node $id needs a ready video.');
    }
    // Media ships as returned: any size and duration publish. Only a
    // measured duration is required (the player needs it).
    if (!positive(n['durationSeconds'])) {
      problems.add('Node $id needs a measured video duration.');
    }
    if (!hasText(n['videoFrameLastUrl'])) {
      problems.add('Node $id needs its extracted last frame.');
    }
    if (id == root) {
      if (n['startImageStatus'] != 'ready') {
        problems.add('Node $id needs a ready start image.');
      }
    } else {
      final parent = nodes[n['startFromNodeId']];
      if (parent == null) {
        problems.add('Node $id is missing its parent link.');
      } else if (!hasText(n['startParentFrameHash']) ||
          !hasText(parent['videoFrameLastHash']) ||
          n['startParentFrameHash'] != parent['videoFrameLastHash']) {
        problems.add('Node $id is out of sync with its parent.');
      }
    }
    final choices = [
      for (final c in n['choices'] as List? ?? const []) jsonMap(c),
    ];
    final ending = n['isEnding'] == true;
    if (ending) {
      if (choices.isNotEmpty) problems.add('Ending $id must not have choices.');
      if (![
        'open',
        'tragic',
        'secret',
        'heroic',
        'mysterious',
        'bittersweet',
        'dark',
        'epic',
        'incomplete',
      ].contains(n['endingType'])) {
        problems.add('Ending $id needs a valid type.');
      }
    } else {
      if (choices.isEmpty || choices.length > 2) {
        problems.add('Node $id needs one or two choices.');
      }
      if (choices.where((c) => c['isDefault'] == true).length != 1) {
        problems.add('Node $id needs exactly one default choice.');
      }
      for (final c in choices) {
        final label = c['label'];
        if (!hasText(label) || (label as String).length > 24) {
          problems.add(
            'Choice ${c['choiceId']} needs a label of 1-24 characters.',
          );
        }
        if (!nodes.containsKey(c['targetNodeId'])) {
          problems.add('Choice ${c['choiceId']} points to a missing node.');
        }
        for (final key in ['x', 'y', 'radius']) {
          final value = c[key];
          if (value is! num || !value.isFinite || value < 0 || value > 1) {
            problems.add(
              'Choice ${c['choiceId']} needs a zone inside the 0-1 frame.',
            );
            break;
          }
        }
      }
    }
    if (!ending || hasText(n['ttsText'])) {
      if (!hasText(n['ttsText'])) {
        problems.add('Node $id needs a narrator line.');
      }
      if (n['ttsStatus'] != 'ready' ||
          !hasText(n['ttsAudioUrl']) ||
          !positive(n['ttsDurationSeconds'])) {
        problems.add('Node $id needs a ready narrator voice.');
      }
    }
  }
  return problems;
}

/// Explicit whitelist: never publish prompts, job ids or authoring metadata.
Json playbackDocument(String id, Json node, Map<String, Json> nodes) => {
  'title': node['title'],
  'isEnding': node['isEnding'] == true,
  'visibility': node['visibility'] ?? 'visible',
  'videoUrl': node['videoUrl'],
  'durationSeconds': node['durationSeconds'],
  'videoWidth': node['videoWidth'],
  'videoHeight': node['videoHeight'],
  'ttsText': node['ttsText'],
  'ttsAudioUrl': node['ttsAudioUrl'],
  'ttsDurationSeconds': node['ttsDurationSeconds'],
  'videoFrameLastBlurData': node['videoFrameLastBlurData'] ?? fallbackBlur,
  'endingType': node['endingType'],
  'endingBadgeUrl': node['endingBadgeUrl'],
  'thumbnailUrl': node['thumbnailUrl'],
  'choices': [
    for (final raw in node['choices'] as List? ?? const [])
      _playbackChoice(jsonMap(raw), nodes),
  ],
};

Json _playbackChoice(Json choice, Map<String, Json> nodes) {
  final targetId = choice['targetNodeId'];
  final target = nodes[targetId];
  final secret = target?['visibility'] == 'secret';
  return {
    for (final key in [
      'choiceId',
      'label',
      'targetNodeId',
      'isDefault',
      'x',
      'y',
      'radius',
      'icon',
      'iconColor',
    ])
      key: choice[key],
    'targetSecret': secret,
    'target': secret
        ? null
        : {'nodeId': targetId, 'videoUrl': target?['videoUrl']},
  };
}

Json mapDocument(Json node) => node['visibility'] == 'secret'
    ? {'secret': true}
    : {
        'secret': false,
        'title': node['title'],
        'isEnding': node['isEnding'] == true,
        'thumbnailUrl': node['thumbnailUrl'],
        'childIds': [
          for (final c in node['choices'] as List? ?? const [])
            jsonMap(c)['targetNodeId'],
        ],
      };

Json statsDocument(Json node) => {
  'visibility': node['visibility'] ?? 'visible',
  'choiceCounts': {
    for (final c in node['choices'] as List? ?? const [])
      jsonMap(c)['choiceId'] as String:
          (jsonMap(node['choiceCounts'])[jsonMap(c)['choiceId']] as num?)
              ?.toInt() ??
          0,
  },
};

class ClientPublisher {
  ClientPublisher(this.store, this.currentUid);
  final DocumentStore store;
  final String? Function() currentUid;

  Future<List<String>> publish(String storyId) async {
    final path = 'stories/${documentId(storyId)}';
    final story = await store.get(path, server: true);
    if (story == null) invalid('Story not found.');
    if (story['authorId'] != currentUid()) throw const AppFailure(.denied);
    if (story['status'] == 'published') return const [];
    if (story['status'] != 'draft') invalid('Only drafts can be published.');
    final docs = await store.list('$path/nodes', server: true);
    final nodes = Map<String, Json>.fromEntries(docs);
    final problems = validatePublication(story, nodes);
    if (problems.isNotEmpty) return problems;
    final pubId = store.newId('$path/publications');
    final base = '$path/publications/$pubId';
    final author = await store.get('users/${currentUid()}');
    final writes = <DocumentWrite>[
      DocumentWrite(base, {
        'sourceRevision': revisionOf(story),
        'nodeCount': nodes.length,
        'rootNodeId': story['rootNodeId'],
        'createdAt': commitTime,
      }),
      for (final entry in nodes.entries) ...[
        DocumentWrite(
          '$base/nodes/${entry.key}',
          playbackDocument(entry.key, entry.value, nodes),
        ),
        DocumentWrite('$base/map/${entry.key}', mapDocument(entry.value)),
        DocumentWrite('$base/stats/${entry.key}', statsDocument(entry.value)),
      ],
    ];
    for (var start = 0; start < writes.length; start += 150) {
      await store.batch(
        writes.sublist(start, (start + 150).clamp(0, writes.length)),
      );
    }
    return store.transaction((tx) async {
      final live = await tx.get(path);
      if (live == null || live['authorId'] != currentUid()) {
        throw const AppFailure(.denied);
      }
      if (live['status'] == 'published') return <String>[];
      if (live['status'] != 'draft' || revisionOf(live) != revisionOf(story)) {
        invalid('The draft changed during publication. Publish it again.');
      }
      tx.set(path, {
        'status': 'published',
        'activePublicationId': pubId,
        'authorName':
            author?['displayName'] ?? story['authorName'] ?? 'Unknown',
        'revision': revisionOf(live) + 1,
        'publishedAt': commitTime,
        'updatedAt': commitTime,
      }, merge: true);
      return <String>[];
    });
  }
}
