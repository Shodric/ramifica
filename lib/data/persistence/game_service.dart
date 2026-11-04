import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/persistence/document_store.dart';
import 'package:ramifica/data/persistence/publication.dart';

/// Playback, progress, graph and rewards run on the signed-in client.
/// Only immutable publication bodies are cached; progress is always live.
class ClientGameService {
  ClientGameService(this.store, this.currentUid);
  final DocumentStore store;
  final String? Function() currentUid;
  String? _cacheUid;
  final _stories = <String, Json>{};
  final _nodes = <String, Json>{};
  final _maps = <String, List<StoredDoc>>{};
  final _tables = <String, Json>{};

  static ClientGameService? _shared;
  static ClientGameService get shared => _shared ??= ClientGameService(
    FirestoreDocumentStore(FirebaseFirestore.instance),
    () => FirebaseAuth.instance.currentUser?.uid,
  );

  static final _ownerZone = Object();

  String get uid {
    final id = currentUid();
    final owner = Zone.current[_ownerZone];
    if (owner != null && owner != id) throw const AppFailure(.denied);
    if (id != _cacheUid) {
      _stories.clear();
      _nodes.clear();
      _maps.clear();
      _tables.clear();
      _cacheUid = id;
    }
    if (id == null || id.isEmpty) throw const AppFailure(.denied);
    return id;
  }

  Future<Json> execute(String operation, Json data) {
    final owner = uid;
    return runZoned(() async {
      final result = await switch (operation) {
        'startRun' => startRun(data),
        'loadPlayback' => loadPlayback(
          documentId(data['runId'] as String? ?? ''),
        ),
        'commitChoice' => commitChoice(data),
        'unlockedEndings' => unlockedEndings(),
        'graphStubs' => graph(data),
        'playApproach' => approach(data),
        'rewindRun' => rewind(documentId(data['runId'] as String? ?? '')),
        'jumpToNode' => jump(data),
        _ => invalid('Unknown local operation.'),
      };
      if (uid != owner) throw const AppFailure(.denied);
      return result;
    }, zoneValues: {_ownerZone: owner});
  }

  String get _user => 'users/$uid';
  String _runPath(String id) => '$_user/runs/${documentId(id)}';
  String _statePath(String id) => '$_user/storyState/${documentId(id)}';

  Future<Json> _story(String storyId) async {
    uid; // Invalidate all account-scoped caches before accessing a cache.
    final cached = _stories[storyId];
    if (cached != null) return cached;
    final story = await store.get('stories/${documentId(storyId)}');
    if (story == null) invalid('Story not found.');
    if (story['status'] != 'published' && story['authorId'] != uid) {
      throw const AppFailure(.denied);
    }
    if (story['status'] == 'published') {
      if (story['activePublicationId'] is! String) {
        invalid(
          'This story needs the publication migration before it can be played.',
        );
      }
      uid;
      _stories[storyId] = story;
    }
    return story;
  }

  String _base(String storyId, Json story) => story['status'] == 'published'
      ? 'stories/$storyId/publications/${story['activePublicationId']}'
      : 'stories/$storyId';

  Future<Json> _node(String storyId, String nodeId, Json story) async {
    final path = '${_base(storyId, story)}/nodes/${documentId(nodeId)}';
    final published = story['status'] == 'published';
    if (published && _nodes.containsKey(path)) return _nodes[path]!;
    final raw = await store.get(path);
    if (raw == null) invalid('Scene not found.');
    uid;
    if (published) {
      _nodes[path] = raw;
      return raw;
    }
    final docs = await store.list('stories/$storyId/nodes');
    return playbackDocument(nodeId, raw, Map.fromEntries(docs));
  }

  Future<Json> _run(String runId) async {
    final run = await store.get(_runPath(runId));
    if (run == null) invalid('Run not found.');
    return run;
  }

  /// The story's scene table: every scene body for local holds. Published
  /// stories read it once from their publication doc and cache it (a
  /// publication never changes); drafts project it live from the draft
  /// nodes. Null for publications staged before the table existed, which
  /// play through the legacy await-the-commit path.
  Future<Json?> _table(String storyId, Json story) async {
    if (story['status'] != 'published') {
      final docs = await store.list('stories/$storyId/nodes');
      final nodes = Map<String, Json>.fromEntries(docs);
      return {
        for (final entry in nodes.entries)
          entry.key: playbackDocument(entry.key, entry.value, nodes),
      };
    }
    final base = _base(storyId, story);
    final cached = _tables[base];
    if (cached != null) return cached;
    final publication = await store.get(base);
    final table = jsonMap(publication?['nodes']);
    if (table.isEmpty) return null;
    uid;
    _tables[base] = table;
    return table;
  }

  Future<Json> startRun(Json data) async {
    var storyId = (data['storyId'] as String?)?.trim();
    if (storyId == null || storyId.isEmpty) {
      final states = await store.list(
        '$_user/storyState',
        orderBy: 'updatedAt',
        descending: true,
        limit: 1,
      );
      if (states.isNotEmpty) storyId = states.first.key;
      if (storyId == null || storyId.isEmpty) {
        final stories = await store.list(
          'stories',
          equals: {'status': 'published'},
        );
        if (stories.isEmpty) invalid('No stories yet.');
        stories.sort(
          (a, b) =>
              _rank(b.value['publishedAt'])
                  .compareTo(_rank(a.value['publishedAt'])),
        );
        storyId =
            (stories.where((s) => s.value['featured'] == true).firstOrNull ??
                    stories.first)
                .key;
      }
    }
    final id = documentId(storyId);
    final story = await _story(id);
    final root = documentId(story['rootNodeId'] as String? ?? '');
    final statePath = _statePath(id);
    final newRunId = store.newId('$_user/runs');
    final runId = await store.transaction((tx) async {
      final state = await tx.get(statePath) ?? {};
      final oldId = state['activeRunId'];
      Json? old;
      if (oldId is String && oldId.isNotEmpty) {
        old = await tx.get(_runPath(oldId));
      }
      if (data['restart'] != true &&
          old != null &&
          old['storyId'] == id &&
          old['currentNodeId'] is String) {
        return oldId as String;
      }
      final now = _now();
      tx.set(_runPath(newRunId), {
        'storyId': id,
        'status': 'active',
        'currentNodeId': root,
        'choices': [],
        'createdAt': now,
        'updatedAt': now,
      });
      tx.set(statePath, {
        'activeRunId': newRunId,
        'activeRunStatus': 'active',
        'visitedNodeIds': {..._strings(state['visitedNodeIds']), root}.toList(),
        'updatedAt': now,
      }, merge: true);
      return newRunId;
    });
    final run = await _run(runId);
    return {'runId': runId, 'storyId': id, 'status': run['status'] ?? 'active'};
  }

  Future<Json> loadPlayback(String runId) async {
    var run = await _run(runId);
    final storyId = documentId(run['storyId'] as String? ?? '');
    final story = await _story(storyId);
    final nodeId = documentId(run['currentNodeId'] as String? ?? '');
    await _restoreVisits(runId, storyId, run);
    final node = await _node(storyId, nodeId, story);
    if (node['isEnding'] == true) {
      await _finalize(runId, storyId, nodeId, node, story);
      run = await _run(runId);
    }
    final table = await _table(storyId, story);
    return _playback(runId, run, storyId, story, nodeId, node, table);
  }

  /// Legacy or interrupted runs may predate visitedNodeIds. Restore only this
  /// account's known history before reading a newly protected publication body.
  Future<void> _restoreVisits(String runId, String storyId, Json run) async {
    final path = _statePath(storyId);
    final state = await store.get(path) ?? {};
    if (_strings(state['visitedNodeIds']).contains(run['currentNodeId'])) {
      return;
    }
    await store.transaction((tx) async {
      final current = await tx.get(_runPath(runId));
      final progress = await tx.get(path) ?? {};
      if (current == null || current['currentNodeId'] != run['currentNodeId']) {
        invalid('Run moved on.');
      }
      tx.set(path, {
        'visitedNodeIds': {
          ..._strings(progress['visitedNodeIds']),
          current['currentNodeId'],
          for (final raw in current['choices'] as List? ?? []) ...[
            if (jsonMap(raw)['nodeId'] is String) jsonMap(raw)['nodeId'],
            if (jsonMap(raw)['targetNodeId'] is String)
              jsonMap(raw)['targetNodeId'],
          ],
        }.toList(),
        'updatedAt': _now(),
      }, merge: true);
    });
  }

  Future<Json> _playback(
    String runId,
    Json run,
    String storyId,
    Json story,
    String nodeId,
    Json node,
    Json? table,
  ) async {
    Json? reward;
    if (run['status'] == 'ended') {
      final id = rewardId(storyId, nodeId);
      final raw = await store.get('$_user/rewards/$id');
      if (raw != null) {
        reward = {
          'rewardId': id,
          'code': raw['code'] ?? rewardCode(uid, storyId, nodeId),
        };
      }
    }
    return {
      'runId': runId,
      'status': run['status'] ?? 'active',
      'story': {
        'storyId': storyId,
        'title': story['title'],
        'authorName': story['authorName'] ?? 'Unknown',
        'authorId': story['authorId'],
        'authorPhotoUrl': story['authorPhotoUrl'],
      },
      'node': {
        ...node,
        'nodeId': nodeId,
        'rewardCode': reward?['code'],
        'videoFrameLastBlurData':
            node['videoFrameLastBlurData'] ?? fallbackBlur,
      },
      'choices': node['choices'] ?? [],
      'nodes': ?table,
      'reward': reward,
    };
  }

  Future<Json> commitChoice(Json data) async {
    final runId = documentId(data['runId'] as String? ?? '');
    final fromId = documentId(data['fromNodeId'] as String? ?? '');
    final choiceId = documentId(data['choiceId'] as String? ?? '');
    final requestId = documentId(data['requestId'] as String? ?? '');
    final before = await _run(runId);
    final storyId = documentId(before['storyId'] as String? ?? '');
    final story = await _story(storyId);
    final base = _base(storyId, story);
    final runPath = _runPath(runId);
    final statePath = _statePath(storyId);
    await store.transaction((tx) async {
      final run = await tx.get(runPath);
      if (run == null) invalid('Run not found.');
      if (jsonMap(run['lastCommit'])['requestId'] == requestId ||
          (run['choices'] as List? ?? []).any(
            (entry) => jsonMap(entry)['requestId'] == requestId,
          )) {
        return;
      }
      if (run['currentNodeId'] != fromId || run['status'] != 'active') {
        invalid('Run moved on.');
      }
      final node = await tx.get('$base/nodes/$fromId');
      if (node == null) invalid('Scene not found.');
      final choice = (node['choices'] as List? ?? [])
          .map(jsonMap)
          .where((c) => c['choiceId'] == choiceId)
          .firstOrNull;
      if (choice == null) invalid('Choice is not valid.');
      final target = documentId(choice['targetNodeId'] as String? ?? '');
      final state = await tx.get(statePath) ?? {};
      final statsPath = '$base/stats/$fromId';
      final published = story['status'] == 'published';
      final stats = published ? await tx.get(statsPath) : null;
      final now = _now();
      tx.set(runPath, {
        'currentNodeId': target,
        'endingOutcome': null,
        'choices': [
          ...run['choices'] as List? ?? [],
          {
            'nodeId': fromId,
            'choiceId': choiceId,
            'targetNodeId': target,
            'requestId': requestId,
            'at': now,
          },
        ],
        'lastCommit': {
          'requestId': requestId,
          'fromNodeId': fromId,
          'choiceId': choiceId,
          'toNodeId': target,
          'outcome': null,
        },
        'updatedAt': now,
      }, merge: true);
      tx.set(statePath, {
        'activeRunId': runId,
        'activeRunStatus': 'active',
        'visitedNodeIds': {
          ..._strings(state['visitedNodeIds']),
          fromId,
          target,
        }.toList(),
        'updatedAt': now,
      }, merge: true);
      if (published) {
        final counts = jsonMap(stats?['choiceCounts']);
        counts[choiceId] = ((counts[choiceId] as num?)?.toInt() ?? 0) + 1;
        tx.set(statsPath, {
          'visibility': node['visibility'] ?? 'visible',
          'choiceCounts': counts,
        }, merge: true);
      }
    });
    // The visit commits before this read; secret bodies remain unreadable
    // until the player's own state grants access. A restart resumes here.
    final playback = await loadPlayback(runId);
    final live = await _run(runId);
    final same = jsonMap(live['lastCommit'])['requestId'] == requestId;
    final outcome = same
        ? jsonMap(jsonMap(live['lastCommit'])['outcome'])
        : <String, dynamic>{};
    return {
      'playback': playback,
      'ending': outcome['ending'],
      'sagaUnlocked': outcome['sagaUnlocked'],
      'reward': outcome['reward'],
    };
  }

  /// Every ending this account unlocked, newest story first.
  ///
  /// Reads `users/{uid}/storyState/*/endings` plus each `rewards/{id}` for
  /// the earned badge. A story or node that is gone or unreadable is
  /// skipped, never fatal: one bad row must not empty the profile tab.
  Future<Json> unlockedEndings() async {
    final rows = <Json>[];
    final states = await store.list(
      '$_user/storyState',
      orderBy: 'updatedAt',
      descending: true,
    );
    for (final state in states) {
      final storyId = state.key;
      Json story;
      try {
        story = await _story(storyId);
      } on AppFailure {
        continue;
      }
      for (final nodeId in _strings(state.value['endings'])) {
        Json node;
        try {
          node = await _node(storyId, nodeId, story);
        } on AppFailure {
          continue;
        }
        if (node['isEnding'] != true) continue;
        final raw = await store.get('$_user/rewards/${rewardId(storyId, nodeId)}');
        rows.add({
          'storyId': storyId,
          'name': node['endingName'] ?? node['title'] ?? 'Ending',
          'type': node['endingType'],
          'badgeUrl': raw?['badgeUrl'] ?? node['endingBadgeUrl'],
        });
      }
    }
    return {'rows': rows};
  }

  Future<void> _finalize(
    String runId,
    String storyId,
    String nodeId,
    Json node,
    Json story,
  ) async {
    final before = await _run(runId);
    if (before['status'] == 'ended' && before['endingOutcome'] != null) return;
    final sagas = await store.list(
      'sagas',
      equals: {'authorId': story['authorId']},
    );
    sagas.sort((a, b) => a.key.compareTo(b.key));
    String? unlockStory;
    String? sagaId;
    for (final saga in sagas) {
      if (!_strings(saga.value['storyIds']).contains(storyId)) continue;
      for (final rule in saga.value['unlocks'] as List? ?? []) {
        final r = jsonMap(rule);
        if (r['fromStoryId'] == storyId &&
            r['endingNodeId'] == nodeId &&
            r['toStoryId'] is String) {
          unlockStory = r['toStoryId'] as String;
          sagaId = saga.key;
          break;
        }
      }
      if (unlockStory != null) break;
    }
    final unlock = unlockStory;
    final unlockTitle = unlock == null
        ? null
        : (await store.get('stories/$unlock'))?['title'];
    final reward = rewardId(storyId, nodeId);
    final rewardPath = '$_user/rewards/$reward';
    final statePath = _statePath(storyId);
    final runPath = _runPath(runId);
    await store.transaction((tx) async {
      final run = await tx.get(runPath);
      final state = await tx.get(statePath) ?? {};
      final earned = await tx.get(rewardPath);
      final unlocked = unlock == null ? null : await tx.get(_statePath(unlock));
      if (run == null || run['currentNodeId'] != nodeId) return;
      if (run['status'] == 'ended' && run['endingOutcome'] != null) return;
      final code = earned?['code'] ?? rewardCode(uid, storyId, nodeId);
      final rawBadge = node['endingBadgeUrl'];
      final badgeUrl = rawBadge is String && rawBadge.trim().isNotEmpty
          ? rawBadge.trim()
          : null;
      final now = _now();
      Json? saga;
      if (unlock != null && unlocked?['sagaUnlocked'] != true) {
        tx.set(_statePath(unlock), {
          'sagaUnlocked': true,
          'updatedAt': now,
        }, merge: true);
        saga = {'sagaId': sagaId, 'storyId': unlock, 'title': unlockTitle};
      }
      final outcome = <String, dynamic>{
        'ending': {
          'storyId': storyId,
          'nodeId': nodeId,
          'title': node['title'],
          'endingType': node['endingType'],
          'badgeUrl': ?badgeUrl,
        },
        'sagaUnlocked': saga,
        'reward': {'rewardId': reward, 'code': code, 'badgeUrl': ?badgeUrl},
      };
      if (earned == null) {
        tx.set(rewardPath, {
          'storyId': storyId,
          'endingNodeId': nodeId,
          'sagaId': sagaId,
          'code': code,
          'badgeUrl': ?badgeUrl,
          'grantedAt': now,
          'requestId':
              jsonMap(run['lastCommit'])['requestId'] ?? 'start:$runId',
        });
      } else if (earned['code'] == null ||
          (badgeUrl != null && earned['badgeUrl'] == null)) {
        tx.set(rewardPath, {
          if (earned['code'] == null) 'code': code,
          if (badgeUrl != null && earned['badgeUrl'] == null)
            'badgeUrl': badgeUrl,
        }, merge: true);
      }
      tx.set(runPath, {
        'status': 'ended',
        'endedAt': now,
        'endingNodeId': nodeId,
        'endingOutcome': outcome,
        if (run['lastCommit'] != null)
          'lastCommit': {...jsonMap(run['lastCommit']), 'outcome': outcome},
        'updatedAt': now,
      }, merge: true);
      tx.set(statePath, {
        'activeRunId': runId,
        'activeRunStatus': 'ended',
        'visitedNodeIds': {
          ..._strings(state['visitedNodeIds']),
          nodeId,
        }.toList(),
        'endings': {..._strings(state['endings']), nodeId}.toList(),
        'updatedAt': now,
      }, merge: true);
    });
  }

  Future<Json> graph(Json data) async {
    final storyId = documentId(data['storyId'] as String? ?? '');
    final runId = documentId(data['runId'] as String? ?? '');
    final run = await _run(runId);
    if (run['storyId'] != storyId) invalid('Run is on another story.');
    final story = await _story(storyId);
    final state = await store.get(_statePath(storyId)) ?? {};
    final visited = {
      ..._strings(state['visitedNodeIds']),
      run['currentNodeId'],
    };
    final base = _base(storyId, story);
    final published = story['status'] == 'published';
    final docs = published
        ? (_maps[base] ??= await store.list('$base/map'))
        : [
            for (final d in await store.list('$base/nodes'))
              MapEntry(d.key, mapDocument(d.value)),
          ];
    final stats = published
        ? Map<String, Json>.fromEntries(
            await store.list('$base/stats', equals: {'visibility': 'visible'}),
          )
        : <String, Json>{};
    final results = await Future.wait(
      docs.map((doc) async {
        final secret = doc.value['secret'] == true;
        final seen = visited.contains(doc.key);
        if (secret && !seen) {
          return <String, dynamic>{
            'nodeId': doc.key,
            'title': null,
            'isEnding': false,
            'visited': false,
            'secret': true,
          };
        }
        final body = seen ? await _node(storyId, doc.key, story) : null;
        final counts = jsonMap(
          (stats[doc.key] ??
              (published && seen
                  ? await store.get('$base/stats/${doc.key}')
                  : null))?['choiceCounts'],
        );
        final choices = [
          for (final c in body?['choices'] as List? ?? []) jsonMap(c),
        ];
        return <String, dynamic>{
          'nodeId': doc.key,
          'title': body?['title'] ?? doc.value['title'],
          'isEnding': body?['isEnding'] ?? doc.value['isEnding'] ?? false,
          'thumbnailUrl': body?['thumbnailUrl'] ?? doc.value['thumbnailUrl'],
          // Seen nodes only (body is null otherwise): the hub card image.
          'imageBlurData': body?['videoFrameLastBlurData'],
          'endingType': seen && body != null ? body['endingType'] : null,
          'visited': seen,
          'secret': secret,
          'childIds': seen
              ? [for (final c in choices) c['targetNodeId']]
              : doc.value['childIds'] ?? [],
          'choiceCount': counts.values.fold<int>(
            0,
            (total, value) => total + ((value as num?)?.toInt() ?? 0),
          ),
          if (seen && body?['isEnding'] != true)
            'choices': [
              for (final c in choices)
                {
                  'choiceId': c['choiceId'],
                  'label': c['label'],
                  'icon': c['icon'],
                  'iconColor': c['iconColor'],
                  'count': counts[c['choiceId']] ?? 0,
                },
            ],
        };
      }),
    );
    results.sort(
      (a, b) => (a['nodeId'] as String).compareTo(b['nodeId'] as String),
    );
    return {
      'nodes': results,
      'currentNodeId': run['currentNodeId'],
      'story': {'title': story['title'], 'coverUrl': story['coverUrl']},
    };
  }

  String? _parent(Json run, String target) {
    for (final raw in (run['choices'] as List? ?? []).reversed) {
      final hop = jsonMap(raw);
      if (hop['targetNodeId'] == target && hop['nodeId'] is String) {
        return hop['nodeId'] as String;
      }
    }
    return null;
  }

  Future<Json> approach(Json data) async {
    final runId = documentId(data['runId'] as String? ?? '');
    final target = documentId(data['nodeId'] as String? ?? '');
    final run = await _run(runId);
    final storyId = run['storyId'] as String;
    final story = await _story(storyId);
    var parent = _parent(run, target);
    if (parent == null) {
      final state = await store.get(_statePath(storyId)) ?? {};
      for (final id in _strings(state['visitedNodeIds'])) {
        final node = await _node(storyId, id, story);
        if ((node['choices'] as List? ?? []).any(
          (c) => jsonMap(c)['targetNodeId'] == target,
        )) {
          parent = id;
          break;
        }
      }
    }
    if (parent == null) invalid('Nothing to replay.');
    final node = await _node(storyId, parent, story);
    return _playback(
      runId,
      {...run, 'status': 'active'},
      storyId,
      story,
      parent,
      node,
      await _table(storyId, story),
    );
  }

  Future<Json> rewind(String runId) async {
    final runPath = _runPath(runId);
    await store.transaction((tx) async {
      final run = await tx.get(runPath);
      if (run == null) invalid('Run not found.');
      final storyId = run['storyId'] as String;
      final parent = _parent(run, run['currentNodeId'] as String);
      if (parent == null) invalid('Already at the start.');
      final now = _now();
      tx.set(runPath, {
        'currentNodeId': parent,
        'status': 'active',
        'endingOutcome': null,
        'updatedAt': now,
      }, merge: true);
      tx.set(_statePath(storyId), {
        'activeRunId': runId,
        'activeRunStatus': 'active',
        'updatedAt': now,
      }, merge: true);
    });
    return loadPlayback(runId);
  }

  /// Moves the run pointer to a visited node without touching history.
  /// Powers map play: rewatch from any visited scene. Already-there is
  /// a no-op returning the current playback; unvisited targets fail.
  Future<Json> jump(Json data) async {
    final runId = documentId(data['runId'] as String? ?? '');
    final target = documentId(data['nodeId'] as String? ?? '');
    final run = await _run(runId);
    final storyId = run['storyId'] as String;
    await _story(storyId); // Fails when the story is gone.
    if (target.isEmpty) invalid('Missing scene.');
    final state = await store.get(_statePath(storyId)) ?? {};
    final visited = {
      ..._strings(state['visitedNodeIds']),
      run['currentNodeId'],
    };
    if (!visited.contains(target)) invalid('Scene not visited yet.');
    if (target == run['currentNodeId']) return loadPlayback(runId);
    final now = _now();
    await store.transaction((tx) async {
      final fresh = await tx.get(_runPath(runId));
      if (fresh == null) invalid('Run not found.');
      tx.set(_runPath(runId), {
        'currentNodeId': target,
        'status': 'active',
        'endingOutcome': null,
        'updatedAt': now,
      }, merge: true);
      tx.set(_statePath(storyId), {
        'activeRunId': runId,
        'activeRunStatus': 'active',
        'updatedAt': now,
      }, merge: true);
    });
    return loadPlayback(runId);
  }
}

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : [];
String _now() => DateTime.now().toUtc().toIso8601String();
int _rank(Object? value) => switch (value) {
  Timestamp() => value.millisecondsSinceEpoch,
  num() => value.toInt(),
  String() => DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0,
  _ => 0,
};
String rewardId(String storyId, String nodeId) => '${storyId}_$nodeId';
String rewardCode(String uid, String storyId, String nodeId) {
  final hash = sha256
      .convert(utf8.encode('$uid\n$storyId\n$nodeId'))
      .toString()
      .toUpperCase();
  return '${hash.substring(0, 4)}-${hash.substring(4, 8)}';
}
