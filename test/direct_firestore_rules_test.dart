import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/persistence/document_store.dart';
import 'package:ramifica/data/persistence/draft_persistence.dart';
import 'package:ramifica/data/persistence/game_service.dart';
import 'package:ramifica/data/persistence/publication.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/data/repositories/graph_repository.dart';

import 'support/rest_document_store.dart';
import 'direct_persistence_test.dart' show readyNode, choice;

void main() {
  final host = Platform.environment['RAMIFICA_RULES_EMULATOR_HOST'];
  test(
    'real rules: atomic authoring, publication, private prompts, own progress and secret unlock',
    () async {
      final admin = RestDocumentStore(host!, 'owner');
      final author = RestDocumentStore(host, 'author');
      final player = RestDocumentStore(host, 'player');
      final foreign = RestDocumentStore(host, 'stranger');
      addTearDown(() {
        admin.close();
        author.close();
        player.close();
        foreign.close();
      });
      final writer = ClientDraftPersistence(author, () => 'author');
      final (story, root) = await writer.createDraft('author', 'Rules story');
      final id = story.storyId;
      final child = await writer.createAndLink(
        id,
        root.nodeId,
        slot: 'A',
        requestId: 'rules-key',
        label: 'Enter',
      );
      expect(
        (await writer.createAndLink(
          id,
          root.nodeId,
          slot: 'A',
          requestId: 'rules-key',
        )).selectedId,
        child.selectedId,
      );
      await writer.save(
        id,
        DraftNode.fromMap(
          root.nodeId,
          (await author.get('stories/$id/nodes/${root.nodeId}'))!,
        ).copy(title: 'Updated'),
      );
      await expectLater(
        foreign.get('stories/$id'),
        throwsA(isA<HttpException>()),
      );
      await expectLater(
        foreign.get('stories/$id/nodes/${root.nodeId}'),
        throwsA(isA<HttpException>()),
      );
      final rootPath = 'stories/$id/nodes/${root.nodeId}';
      final endPath = 'stories/$id/nodes/${child.selectedId}';
      await admin.batch([
        DocumentWrite('users/author', {'displayName': 'Author'}, merge: true),
        DocumentWrite(rootPath, {
          ...readyNode(),
          'choices': [choice(child.selectedId)],
        }),
        DocumentWrite(endPath, {
          ...readyNode(ending: true, secret: true),
          'startFromNodeId': root.nodeId,
          'startParentFrameHash': 'end',
          'endingBadgeUrl': 'https://example.com/badge.png',
        }),
      ]);
      // No approvals exist anymore: ready nodes publish as-is.
      // Staged projections are still unavailable even if their shape is valid.
      await author.batch([
        DocumentWrite('stories/$id/publications/incomplete', {
          'sourceRevision': 3,
        }),
        DocumentWrite(
          'stories/$id/publications/incomplete/nodes/${root.nodeId}',
          {'title': 'Leaked'},
        ),
      ]);
      await expectLater(
        player.get('stories/$id/publications/incomplete/nodes/${root.nodeId}'),
        throwsA(isA<HttpException>()),
      );
      expect(
        await ClientPublisher(author, () => 'author').publish(id),
        isEmpty,
      );
      final live = (await player.get('stories/$id'))!;
      final base = 'stories/$id/publications/${live['activePublicationId']}';
      await expectLater(player.get(rootPath), throwsA(isA<HttpException>()));
      await expectLater(
        player.get('$base/nodes/${child.selectedId}'),
        throwsA(isA<HttpException>()),
      );
      await expectLater(
        player.list('$base/nodes'),
        throwsA(isA<HttpException>()),
      );
      expect(await player.get('$base/map/${child.selectedId}'), {
        'secret': true,
      });
      final game = ClientGameService(player, () => 'player');
      final runs = RunRepository(execute: game.execute);
      final graphs = GraphRepository(execute: game.execute);
      final start = await runs.startRun(storyId: id);
      final playback = await runs.loadPlayback(start.runId);
      expect(playback.node.nodeId, root.nodeId);
      expect(playback.choices.single.target, isNull);
      final before = await graphs.fetchStubs(storyId: id, runId: start.runId);
      expect(
        before.nodes.singleWhere((n) => n.nodeId == child.selectedId).locked,
        true,
      );
      final result = await runs.commitChoice(
        runId: start.runId,
        fromNodeId: root.nodeId,
        choiceId: 'c',
        requestId: 'decision',
      );
      expect(result.playback.node.isEnding, true);
      expect(result.reward?.code, isNotEmpty);
      await runs.commitChoice(
        runId: start.runId,
        fromNodeId: root.nodeId,
        choiceId: 'c',
        requestId: 'decision',
      );
      final stats = (await player.get('$base/stats/${root.nodeId}'))!;
      expect(stats['choiceCounts'], {'c': 1});
      expect((await player.list('users/player/rewards')).length, 1);
      final rewards = await player.list('users/player/rewards');
      expect(rewards.single.value['badgeUrl'], 'https://example.com/badge.png');
      await expectLater(
        foreign.get('users/player/storyState/$id'),
        throwsA(isA<HttpException>()),
      );
      await expectLater(
        foreign.get('$base/nodes/${child.selectedId}'),
        throwsA(isA<HttpException>()),
      );
      final after = await graphs.fetchStubs(storyId: id, runId: start.runId);
      expect(
        after.nodes.singleWhere((n) => n.nodeId == child.selectedId).locked,
        false,
      );
      expect((await graphs.rewind(start.runId)).node.nodeId, root.nodeId);
    },
    skip: host == null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
