import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/draft_story.dart';
import 'package:ramifica/data/models/playback.dart';
import 'package:ramifica/features/create/draft_canvas.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_state.dart';
import 'package:ramifica/features/feed/feed_view.dart';

/// Opens a draft scene in the same full-screen feed used by players.
/// The preview has its own playback state and never creates a run.
///
/// Tapping a hotspot jumps to the target scene when its video is finished
/// and plays it like the feed would. Otherwise a notice names the target,
/// e.g. `Node "1A" not finished yet`.
Future<void> showCreatePreview(
  BuildContext context, {
  required DraftNode node,
  DraftStory? story,
  String? authorName,
  Future<String>? authorNameLookup,
  List<DraftNode>? nodes,
  String? rootNodeId,
  void Function(String nodeId)? onOpenNode,
}) {
  final byId = {
    for (final item in nodes ?? const <DraftNode>[]) item.nodeId: item,
  };
  byId.putIfAbsent(node.nodeId, () => node);
  final all = byId.values.toList();
  final root = rootNodeId ?? story?.rootNodeId;
  final badges = levelBadges(all, root);
  final scenes = sceneIndexes(all, root);
  String labelFor(String targetNodeId) {
    final badge = (badges[targetNodeId] ?? '').trim();
    if (badge.isNotEmpty && badge != 'root') return badge.toUpperCase();
    final scene = scenes[targetNodeId];
    if (scene != null) return 'Scene $scene';
    return targetNodeId;
  }

  ({Playback? playback, bool exists}) resolve(String targetNodeId) {
    final target = byId[targetNodeId];
    if (target == null) return (playback: null, exists: false);
    if (target.videoStatus != 'ready') {
      return (playback: null, exists: true);
    }
    if ((target.videoUrl ?? '').trim().isEmpty) {
      return (playback: null, exists: true);
    }
    return (playback: _draftPlayback(target, story, authorName), exists: true);
  }

  final bloc = FeedBloc.preview(
    playback: _draftPlayback(node, story, authorName),
    resolvePreview: resolve,
    previewNodeLabel: labelFor,
  );
  // The preview button is a user gesture, so unlock Web Audio before
  // navigating and allow the clip and narration to play with sound.
  bloc.narrator.unlock();
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => BlocProvider(
        create: (_) => bloc,
        lazy: false,
        child: CreatePreview(
          authorNameLookup: authorNameLookup,
          videoSize: _nodeVideoSize(node),
          nodesById: byId,
          onOpenNode: onOpenNode,
        ),
      ),
    ),
  );
}

/// A full-screen scene with a close control for the editor.
class CreatePreview extends StatelessWidget {
  const CreatePreview({
    super.key,
    this.authorNameLookup,
    this.videoSize,
    this.nodesById = const {},
    this.onOpenNode,
  });

  final Future<String>? authorNameLookup;
  final Size? videoSize;

  /// Draft scenes by id. Picks the decoded-size hint for the scene the
  /// preview currently plays, so jumped-to scenes frame their own video.
  final Map<String, DraftNode> nodesById;

  /// Opens a draft node for editing from the unfinished-target notice.
  final void Function(String nodeId)? onOpenNode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: .expand,
        children: [
          FutureBuilder<String>(
            future: authorNameLookup,
            builder: (context, snapshot) => BlocBuilder<FeedBloc, FeedState>(
              builder: (context, state) {
                final currentId = state.playback?.node.nodeId;
                final current = currentId == null ? null : nodesById[currentId];
                return FeedView(
                  key: ValueKey('preview-feed-$currentId'),
                  preview: true,
                  previewAuthorName: snapshot.data,
                  previewVideoSize: _nodeVideoSize(current) ?? videoSize,
                  previewOpenNode: onOpenNode,
                );
              },
            ),
          ),
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            right: 8,
            child: IconButton.filled(
              key: const ValueKey('close-preview'),
              tooltip: 'Close preview',
              onPressed: () => Navigator.of(context).pop(),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black54,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }
}

Size? _nodeVideoSize(DraftNode? node) {
  final width = node?.videoWidth;
  final height = node?.videoHeight;
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return Size(width.toDouble(), height.toDouble());
}

Playback _draftPlayback(DraftNode node, DraftStory? story, String? authorName) {
  final title = story?.title.trim() ?? '';
  final author = authorName?.trim() ?? '';
  return Playback(
    runId: 'preview',
    status: .active,
    story: PlaybackStory(
      storyId: story?.storyId ?? 'preview',
      title: title.isEmpty ? 'Untitled story' : title,
      authorName: author.isEmpty ? 'Unknown' : author,
    ),
    node: PlaybackNode(
      nodeId: node.nodeId,
      title: node.title,
      isEnding: node.isEnding,
      videoUrl: node.videoUrl ?? '',
      durationSeconds: node.durationSeconds ?? 0,
      videoFrameLastBlurData: node.videoFrameLastBlurData ?? '',
      ttsText: node.ttsText,
      ttsAudioUrl: node.ttsAudioUrl,
      ttsDurationSeconds: node.ttsDurationSeconds,
      endingName: node.endingName,
      endingType: node.endingType,
    ),
    choices: [
      for (final choice in node.choices)
        PlaybackChoice(
          choiceId: choice.choiceId,
          label: choice.label,
          targetNodeId: choice.targetNodeId,
          isDefault: choice.isDefault,
          x: choice.x,
          y: choice.y,
          radius: choice.radius,
          icon: choice.icon,
          iconColor: choice.iconColor,
          targetSecret: true,
          target: null,
        ),
    ],
  );
}
