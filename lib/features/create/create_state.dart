import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/draft_story.dart';

/// Which async job is in flight, if any. One at a time: a new job
/// replaces the previous description.
enum CreateJob { none, loading, saving, generating, imaging, uploading }

/// Create tab state: the draft story, its nodes, the open node, the job
/// in flight, and what is missing per node.
class CreateState {
  const CreateState({
    this.story,
    this.nodes = const [],
    this.openNodeId,
    this.job = CreateJob.none,
    this.jobNodeId,
    this.uploadProgress,
    this.failure,
    this.publishedStoryId,
  });

  final DraftStory? story;
  final List<DraftNode> nodes;

  /// The node open in the inspector. Null before the first node exists.
  final String? openNodeId;

  /// The async work in flight. `none` while idle.
  final CreateJob job;

  /// The node the [job] works on, if it targets one node.
  final String? jobNodeId;

  /// Upload progress 0..1 while [job] is [CreateJob.uploading], else null.
  final double? uploadProgress;

  /// The phrase the bloc already emitted, or null. Retry sends the same
  /// event again.
  final String? failure;

  /// The story id once `publishStory` succeeds, or null while a draft.
  /// The view navigates to Explore exactly once per value.
  final String? publishedStoryId;

  /// True once a draft is open.
  bool get hasDraft => story != null;

  DraftNode? get openNode {
    final id = openNodeId;
    if (id == null) return null;
    for (final node in nodes) {
      if (node.nodeId == id) return node;
    }
    return null;
  }

  /// Nodes unreachable from the root. Shown distinctly on the canvas as
  /// orphans: they exist but no choice leads to them, so players would
  /// never reach them (and publish lists them as missing).
  Set<String> get orphanNodeIds {
    final rootId = story?.rootNodeId;
    if (rootId == null || rootId.isEmpty) {
      return {for (final node in nodes) node.nodeId};
    }
    final byId = {for (final node in nodes) node.nodeId: node};
    if (!byId.containsKey(rootId)) {
      return {for (final node in nodes) node.nodeId};
    }
    final seen = <String>{rootId};
    final queue = [rootId];
    while (queue.isNotEmpty) {
      final next = queue.removeAt(0);
      for (final child in byId[next]?.childIds ?? const <String>[]) {
        if (byId.containsKey(child) && seen.add(child)) queue.add(child);
      }
    }
    return {
      for (final node in nodes)
        if (!seen.contains(node.nodeId)) node.nodeId,
    };
  }

  /// Unmet publish conditions for [node], one message each. Mirrors the
  /// per-node checklist in functions/src/publish/validateStory.ts, minus
  /// the server-verified frame sync hashes and the extraction-owned
  /// `pauseAtSeconds` (the image/video milestones own those): title,
  /// visibility, video, images, voice, window, and choices. Empty when
  /// the node can publish.
  List<String> missingFor(DraftNode node) {
    return missingForNode(node: node, isRoot: isRoot(node.nodeId));
  }

  /// Per-node status for the inspector [StatusPill]: the job in flight
  /// while it targets [nodeId], the failure right after it fails, ready
  /// when nothing is missing, idle otherwise.
  StatusPillState statusOf(String nodeId) {
    if ((job == CreateJob.saving ||
            job == CreateJob.generating ||
            job == CreateJob.imaging ||
            job == CreateJob.uploading) &&
        jobNodeId == nodeId) {
      return .running;
    }
    if (failure != null && jobNodeId == nodeId && job == CreateJob.none) {
      return .failed;
    }
    final node = _byId(nodeId);
    if (node == null) return .idle;
    return missingFor(node).isEmpty ? .ready : .idle;
  }

  /// Story-level publish problems, mirroring `validateStory`: draft
  /// presence, root presence, at least one ending, reachability from the
  /// root, then every node's [missingFor]. Empty when the story can go
  /// `published` (modulo the server-verified hashes in [missingFor]).
  List<String> publishProblems() {
    if (story == null) return ['No draft open yet.'];
    final problems = <String>[];
    final rootId = story?.rootNodeId;
    final byId = {for (final node in nodes) node.nodeId: node};
    final root = rootId == null ? null : byId[rootId];
    if (root == null) {
      problems.add('Missing root node.');
    }
    if (!nodes.any((node) => node.isEnding)) {
      problems.add('At least one ending is required.');
    }
    if (root != null) {
      for (final orphanId in orphanNodeIds) {
        problems.add('Node $orphanId is not reachable from the root.');
      }
    }
    for (final node in nodes) {
      problems.addAll(missingFor(node));
    }
    return problems;
  }

  DraftNode? _byId(String nodeId) {
    for (final node in nodes) {
      if (node.nodeId == nodeId) return node;
    }
    return null;
  }

  /// True when [nodeId] is the draft root. Only the root generates its
  /// own S frame and shows S approval controls; children inherit S.
  bool isRoot(String nodeId) => story?.rootNodeId == nodeId;

  /// The node [node] inherited its S from, or null for the root and for
  /// nodes whose parent link is missing.
  DraftNode? parentOf(DraftNode node) {
    final parentId = node.startFromNodeId;
    if (parentId == null || parentId.isEmpty) return null;
    return _byId(parentId);
  }

  /// Why [node] cannot generate video yet, or null when the gate is open.
  /// The root needs its own S approved and present; any other node needs
  /// its parent E approved and present (the call inherits it as S).
  String? videoGateMessage(DraftNode node) {
    if (isRoot(node.nodeId)) {
      if (!node.startImageApproved || node.startImageSourceUrl == null) {
        return 'Approve the start frame to generate video.';
      }
      return null;
    }
    final parent = parentOf(node);
    if (parent == null ||
        !parent.endImageApproved ||
        parent.endImageSourceUrl == null) {
      return 'The parent end frame must be approved first.';
    }
    return null;
  }

  /// True when [node] carries a stale video: its inherited S no longer
  /// matches the parent E (the parent regenerated E and the backend
  /// forced this video back to `idle` until it re-inherits).
  bool videoDesynced(DraftNode node) =>
      node.isVideoDesyncedFrom(parentOf(node));

  CreateState copy({
    DraftStory? Function()? story,
    List<DraftNode>? nodes,
    String? Function()? openNodeId,
    CreateJob? job,
    String? Function()? jobNodeId,
    double? Function()? uploadProgress,
    String? Function()? failure,
    String? Function()? publishedStoryId,
  }) {
    return CreateState(
      story: story == null ? this.story : story(),
      nodes: nodes ?? this.nodes,
      openNodeId: openNodeId == null ? this.openNodeId : openNodeId(),
      job: job ?? this.job,
      jobNodeId: jobNodeId == null ? this.jobNodeId : jobNodeId(),
      uploadProgress: uploadProgress == null
          ? this.uploadProgress
          : uploadProgress(),
      failure: failure == null ? this.failure : failure(),
      publishedStoryId: publishedStoryId == null
          ? this.publishedStoryId
          : publishedStoryId(),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CreateState &&
        other.story == story &&
        _sameNodes(other.nodes, nodes) &&
        other.openNodeId == openNodeId &&
        other.job == job &&
        other.jobNodeId == jobNodeId &&
        other.uploadProgress == uploadProgress &&
        other.failure == failure &&
        other.publishedStoryId == publishedStoryId;
  }

  @override
  int get hashCode => Object.hash(
    story,
    Object.hashAll(nodes),
    openNodeId,
    job,
    jobNodeId,
    uploadProgress,
    failure,
    publishedStoryId,
  );

  /// Why [nodeId] cannot be deleted, or null when `deleteNode` may run.
  /// The root can never go; any other node targeted by a choice must lose
  /// that choice first. Computed from the local graph like [orphanNodeIds]
  /// (the server re-guards both); the delete button disables with this.
  String? deleteBlockReason(String nodeId) {
    if ((story?.rootNodeId ?? '') == nodeId) {
      return 'The root node cannot be deleted.';
    }
    for (final node in nodes) {
      if (node.childIds.contains(nodeId)) {
        return 'Node $nodeId is a choice target — remove the choice first.';
      }
    }
    return null;
  }
  }

/// The publish checklist for one node, shared by the state and the tests.
/// Mirrors functions/src/publish/validateStory.ts per node, minus the
/// server-verified frame sync hashes and the extraction-owned
/// `pauseAtSeconds`: title, visibility, video, images, choices, window,
/// and voice. [isRoot] adds the start-image approval only the root needs
/// (children inherit S from their parent E). Reachability stays out: it
/// is story-level and the canvas marks orphans distinctly.
List<String> missingForNode({required DraftNode node, bool isRoot = false}) {
  final missing = <String>[];
  final id = node.nodeId;
  if (node.title.trim().isEmpty || node.title.length > 40) {
    missing.add('Node $id needs a title of 1-40 characters.');
  }
  if (node.visibility != 'visible' && node.visibility != 'secret') {
    missing.add('Node $id needs a valid visibility.');
  }
  if (node.videoStatus != 'ready' || node.videoUrl == null) {
    missing.add('Node $id needs a ready video.');
  }
  if (!node.endImageApproved) {
    missing.add('Node $id needs an approved end image.');
  }
  if (isRoot && !node.startImageApproved) {
    missing.add('Node $id needs an approved start image.');
  }
  if (node.isEnding) {
    if (node.choices.isNotEmpty) {
      missing.add('Ending $id must not have choices.');
    }
    if (node.windowSeconds != null) {
      missing.add('Ending $id must not have windowSeconds.');
    }
    if (node.endingName == null || node.endingName!.trim().isEmpty) {
      missing.add('Ending $id needs a name.');
    }
    if (!['abierto', 'tragico', 'secreto'].contains(node.endingType ?? '')) {
      missing.add('Ending $id needs a valid type.');
    }
  } else {
    if (node.choices.isEmpty || node.choices.length > 2) {
      missing.add('Node $id needs one or two choices.');
    }
    for (final choice in node.choices) {
      if (choice.label.trim().isEmpty || choice.label.length > 24) {
        missing.add(
          'Choice ${choice.choiceId} needs a label of 1-24 characters.',
        );
      }
      if (choice.targetNodeId.trim().isEmpty) {
        missing.add('Choice ${choice.choiceId} points to a missing node.');
      }
      if (!_isUnit(choice.x) || !_isUnit(choice.y) || !_isUnit(choice.radius)) {
        missing.add(
          'Choice ${choice.choiceId} needs a zone inside the 0-1 frame.',
        );
      }
    }
    if (node.choices.where((choice) => choice.isDefault).length != 1) {
      missing.add('Node $id needs exactly one default choice.');
    }
    final window = node.windowSeconds;
    if (window == null || window < 3 || window > 15) {
      missing.add('Node $id needs windowSeconds between 3 and 15.');
    }
  }
  // Voice: required on decisions; on endings only when a line exists.
  // Approval follows generation: fresh takes land unapproved and the
  // author approves after listening.
  if (!node.isEnding || node.ttsText.trim().isNotEmpty) {
    if (!node.lineApproved) {
      missing.add('Node $id needs an approved narrator line.');
    }
    if (node.ttsStatus != 'ready' ||
        node.ttsAudioUrl == null ||
        !_isPositive(node.ttsDurationSeconds)) {
      missing.add('Node $id needs a ready narrator voice.');
    }
    if (!node.ttsApproved) {
      missing.add('Node $id needs an approved narrator voice.');
    }
  }
  // Reachability is story-level: the canvas marks orphans distinctly.
  return missing;
}

bool _isPositive(double? value) => value != null && value.isFinite && value > 0;

bool _isUnit(double value) => value.isFinite && value >= 0 && value <= 1;

bool _sameNodes(List<DraftNode> a, List<DraftNode> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
