import 'package:ramifica/data/models/app_failure.dart';

enum RunStatus { active, ended }

/// What `startRun` returns. The node payload arrives from `loadPlayback`.
class RunStart {
  const RunStart({
    required this.runId,
    required this.storyId,
    required this.status,
  });

  factory RunStart.fromJson(Map<String, dynamic> json) {
    return RunStart(
      runId: _requiredString(json['runId']),
      storyId: _requiredString(json['storyId']),
      status: _runStatus(json['status']),
    );
  }

  final String runId;
  final String storyId;
  final RunStatus status;

  @override
  bool operator ==(Object other) {
    return other is RunStart &&
        other.runId == runId &&
        other.storyId == storyId &&
        other.status == status;
  }

  @override
  int get hashCode => Object.hash(runId, storyId, status);
}

/// The `commitChoice` payload: the destination playback plus the ending
/// outcome. `ending`, `sagaUnlocked`, and `reward` are null while the run
/// is still active; absent keys parse the same as null so old payloads
/// still parse.
class CommitResult {
  const CommitResult({
    required this.playback,
    this.ending,
    this.sagaUnlocked,
    this.reward,
  });

  factory CommitResult.fromJson(Map<String, dynamic> json) {
    return CommitResult(
      playback: Playback.fromJson(_objectMap(json['playback'])),
      ending: _maybeMap(json['ending'], EndingResult.fromJson),
      sagaUnlocked: _maybeMap(json['sagaUnlocked'], SagaUnlocked.fromJson),
      reward: _maybeMap(json['reward'], RewardGrant.fromJson),
    );
  }

  final Playback playback;

  /// The reached ending. Null while the run is still active.
  final EndingResult? ending;

  /// The newly opened story, if this ending unlocked one. Null when the
  /// run is active or when the saga was already unlocked (re-earn).
  final SagaUnlocked? sagaUnlocked;

  /// The idempotent grant for this ending. Null while the run is active.
  /// Display only: granting decisions live server-side.
  final RewardGrant? reward;

  @override
  bool operator ==(Object other) {
    return other is CommitResult &&
        other.playback == playback &&
        other.ending == ending &&
        other.sagaUnlocked == sagaUnlocked &&
        other.reward == reward;
  }

  @override
  int get hashCode => Object.hash(playback, ending, sagaUnlocked, reward);
}

/// The ending reached by `commitChoice`. All display fields are optional:
/// a partial map still parses, and the card hides what is missing.
class EndingResult {
  const EndingResult({this.storyId, this.nodeId, this.name, this.type});

  factory EndingResult.fromJson(Map<String, dynamic> json) {
    return EndingResult(
      storyId: _optionalString(json['storyId']),
      nodeId: _optionalString(json['nodeId']),
      name: _optionalString(json['title']),
      type: _optionalString(json['endingType']),
    );
  }

  final String? storyId;
  final String? nodeId;
  final String? name;
  final String? type;

  @override
  bool operator ==(Object other) {
    return other is EndingResult &&
        other.storyId == storyId &&
        other.nodeId == nodeId &&
        other.name == name &&
        other.type == type;
  }

  @override
  int get hashCode => Object.hash(storyId, nodeId, name, type);
}

/// The story this ending newly opened, if any. `title` is the display
/// name the card announces as `Unlocked {title}`.
class SagaUnlocked {
  const SagaUnlocked({this.sagaId, this.storyId, this.title});

  factory SagaUnlocked.fromJson(Map<String, dynamic> json) {
    return SagaUnlocked(
      sagaId: _optionalString(json['sagaId']),
      storyId: _optionalString(json['storyId']),
      title: _optionalString(json['title']),
    );
  }

  final String? sagaId;
  final String? storyId;
  final String? title;

  @override
  bool operator ==(Object other) {
    return other is SagaUnlocked &&
        other.sagaId == sagaId &&
        other.storyId == storyId &&
        other.title == title;
  }

  @override
  int get hashCode => Object.hash(sagaId, storyId, title);
}

/// The reward grant for an ending. `rewardId` is the deterministic
/// `{storyId}_{endingNodeId}` doc id; `code` is the displayable code the
/// card shows. Display only: granting decisions live server-side.
class RewardGrant {
  const RewardGrant({this.rewardId, this.code});

  factory RewardGrant.fromJson(Map<String, dynamic> json) {
    return RewardGrant(
      rewardId: _optionalString(json['rewardId']),
      code: _optionalString(json['code']),
    );
  }

  final String? rewardId;
  final String? code;

  @override
  bool operator ==(Object other) {
    return other is RewardGrant &&
        other.rewardId == rewardId &&
        other.code == code;
  }

  @override
  int get hashCode => Object.hash(rewardId, code);
}

/// The `loadPlayback` payload: story, current node, choices, and the story's
/// scene table. The table carries every scene's full body keyed by node id,
/// so a hold resolves its destination locally and the commit never blocks
/// the next clip. Missing on publications staged before the table existed:
/// those play through the legacy await-the-commit path.
class Playback {
  const Playback({
    required this.runId,
    required this.status,
    required this.story,
    required this.node,
    required this.choices,
    this.nodes = const {},
  });

  factory Playback.fromJson(Map<String, dynamic> json) {
    final rawChoices = json['choices'];
    if (rawChoices is! List) throw const AppFailure(.invalid);
    return Playback(
      runId: _requiredString(json['runId']),
      status: _runStatus(json['status']),
      story: PlaybackStory.fromJson(_objectMap(json['story'])),
      node: PlaybackNode.fromJson(_objectMap(json['node'])),
      choices: [
        for (final choice in rawChoices)
          PlaybackChoice.fromJson(_objectMap(choice)),
      ],
      nodes: _scenes(json['nodes']),
    );
  }

  final String runId;
  final RunStatus status;
  final PlaybackStory story;
  final PlaybackNode node;
  final List<PlaybackChoice> choices;

  /// Every scene by node id. Empty for legacy publications and previews.
  final Map<String, PlaybackScene> nodes;

  @override
  bool operator ==(Object other) {
    return other is Playback &&
        other.runId == runId &&
        other.status == status &&
        other.story == story &&
        other.node == node &&
        _sameList(other.choices, choices) &&
        _sameScenes(other.nodes, nodes);
  }

  @override
  int get hashCode => Object.hash(
    runId,
    status,
    story,
    node,
    Object.hashAll(choices),
    Object.hashAllUnordered(
      nodes.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );
}

/// One scene of the story table: the destination body a hold arrives at,
/// with its own choices. The entry key is the node id; bodies carry no id
/// of their own.
class PlaybackScene {
  const PlaybackScene({required this.node, required this.choices});

  factory PlaybackScene.fromJson(String nodeId, Map<String, dynamic> json) {
    final rawChoices = json['choices'];
    if (rawChoices is! List) throw const AppFailure(.invalid);
    return PlaybackScene(
      node: PlaybackNode.fromJson({...json, 'nodeId': nodeId}),
      choices: [
        for (final choice in rawChoices)
          PlaybackChoice.fromJson(_objectMap(choice)),
      ],
    );
  }

  final PlaybackNode node;
  final List<PlaybackChoice> choices;

  @override
  bool operator ==(Object other) {
    return other is PlaybackScene &&
        other.node == node &&
        _sameList(other.choices, choices);
  }

  @override
  int get hashCode => Object.hash(node, Object.hashAll(choices));
}

class PlaybackStory {
  const PlaybackStory({
    required this.storyId,
    required this.title,
    required this.authorName,
    this.authorId,
    this.authorPhotoUrl,
  });

  factory PlaybackStory.fromJson(Map<String, dynamic> json) {
    return PlaybackStory(
      storyId: _requiredString(json['storyId']),
      title: _requiredString(json['title']),
      authorName: _requiredString(json['authorName']),
      authorId: _optionalString(json['authorId']),
      authorPhotoUrl: _optionalString(json['authorPhotoUrl']),
    );
  }

  final String storyId;
  final String title;
  final String authorName;
  final String? authorId;
  final String? authorPhotoUrl;

  @override
  bool operator ==(Object other) {
    return other is PlaybackStory &&
        other.storyId == storyId &&
        other.title == title &&
        other.authorName == authorName &&
        other.authorId == authorId &&
        other.authorPhotoUrl == authorPhotoUrl;
  }

  @override
  int get hashCode =>
      Object.hash(storyId, title, authorName, authorId, authorPhotoUrl);
}

class PlaybackNode {
  const PlaybackNode({
    required this.nodeId,
    required this.title,
    required this.isEnding,
    required this.videoUrl,
    required this.durationSeconds,
    required this.videoFrameLastBlurData,
    this.videoFrameFirstBlurData,
    this.ttsText,
    this.ttsAudioUrl,
    this.ttsDurationSeconds,
    this.endingType,
    this.endingBadgeUrl,
    this.rewardCode,
  });

  factory PlaybackNode.fromJson(Map<String, dynamic> json) {
    return PlaybackNode(
      nodeId: _requiredString(json['nodeId']),
      title: _requiredString(json['title']),
      isEnding: _requiredBool(json['isEnding']),
      videoUrl: _requiredString(json['videoUrl']),
      durationSeconds: _requiredDouble(json['durationSeconds']),
      videoFrameLastBlurData: _requiredString(json['videoFrameLastBlurData']),
      videoFrameFirstBlurData: _optionalString(json['videoFrameFirstBlurData']),
      ttsText: _optionalString(json['ttsText']),
      ttsAudioUrl: _optionalString(json['ttsAudioUrl']),
      ttsDurationSeconds: _optionalDouble(json['ttsDurationSeconds']),
      endingType: _optionalString(json['endingType']),
      endingBadgeUrl: _optionalString(json['endingBadgeUrl']),
      rewardCode: _optionalString(json['rewardCode']),
    );
  }

  final String nodeId;
  final String title;
  final bool isEnding;
  final String videoUrl;
  final double durationSeconds;
  final String videoFrameLastBlurData;

  /// The clip's opening frame in the same encoding. Optional: older
  /// payloads only carry the last frame. The gap poster prefers this and
  /// falls back to [videoFrameLastBlurData].
  final String? videoFrameFirstBlurData;
  final String? ttsText;
  final String? ttsAudioUrl;
  final double? ttsDurationSeconds;
  final String? endingType;
  final String? endingBadgeUrl;
  final String? rewardCode;

  /// Returns this node with the background commit's reward code filled in.
  /// Only the code arrives late; every other field rides the scene table.
  PlaybackNode copy({String? rewardCode}) {
    return PlaybackNode(
      nodeId: nodeId,
      title: title,
      isEnding: isEnding,
      videoUrl: videoUrl,
      durationSeconds: durationSeconds,
      videoFrameLastBlurData: videoFrameLastBlurData,
      videoFrameFirstBlurData: videoFrameFirstBlurData,
      ttsText: ttsText,
      ttsAudioUrl: ttsAudioUrl,
      ttsDurationSeconds: ttsDurationSeconds,
      endingType: endingType,
      endingBadgeUrl: endingBadgeUrl,
      rewardCode: rewardCode ?? this.rewardCode,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PlaybackNode &&
        other.nodeId == nodeId &&
        other.title == title &&
        other.isEnding == isEnding &&
        other.videoUrl == videoUrl &&
        other.durationSeconds == durationSeconds &&
        other.videoFrameLastBlurData == videoFrameLastBlurData &&
        other.videoFrameFirstBlurData == videoFrameFirstBlurData &&
        other.ttsText == ttsText &&
        other.ttsAudioUrl == ttsAudioUrl &&
        other.ttsDurationSeconds == ttsDurationSeconds &&
        other.endingType == endingType &&
        other.endingBadgeUrl == endingBadgeUrl &&
        other.rewardCode == rewardCode;
  }

  @override
  int get hashCode => Object.hash(
    nodeId,
    title,
    isEnding,
    videoUrl,
    durationSeconds,
    videoFrameLastBlurData,
    videoFrameFirstBlurData,
    ttsText,
    ttsAudioUrl,
    ttsDurationSeconds,
    endingType,
    endingBadgeUrl,
    rewardCode,
  );
}

class PlaybackChoice {
  const PlaybackChoice({
    required this.choiceId,
    required this.label,
    required this.targetNodeId,
    required this.isDefault,
    required this.x,
    required this.y,
    required this.radius,
    required this.targetSecret,
    required this.target,
    this.icon,
    this.iconColor,
  });

  factory PlaybackChoice.fromJson(Map<String, dynamic> json) {
    final secret = _requiredBool(json['targetSecret']);
    final rawTarget = json['target'];
    if (secret) {
      if (rawTarget != null) throw const AppFailure(.invalid);
    } else if (rawTarget == null) {
      throw const AppFailure(.invalid);
    }
    return PlaybackChoice(
      choiceId: _requiredString(json['choiceId']),
      label: _requiredString(json['label']),
      targetNodeId: _requiredString(json['targetNodeId']),
      isDefault: _requiredBool(json['isDefault']),
      x: _requiredDouble(json['x']),
      y: _requiredDouble(json['y']),
      radius: _requiredDouble(json['radius']),
      targetSecret: secret,
      target: secret ? null : PlaybackTarget.fromJson(_objectMap(rawTarget)),
      icon: _optionalString(json['icon']),
      iconColor: _optionalString(json['iconColor']),
    );
  }

  final String choiceId;
  final String label;
  final String targetNodeId;
  final bool isDefault;
  final double x;
  final double y;
  final double radius;
  final bool targetSecret;
  final PlaybackTarget? target;

  /// Persisted hotspot icon name from the shared catalog; null on
  /// choices published before icons existed (fallback glyph applies).
  final String? icon;

  /// Persisted hotspot icon color name; null draws the accent fallback.
  final String? iconColor;

  @override
  bool operator ==(Object other) {
    return other is PlaybackChoice &&
        other.choiceId == choiceId &&
        other.label == label &&
        other.targetNodeId == targetNodeId &&
        other.isDefault == isDefault &&
        other.x == x &&
        other.y == y &&
        other.radius == radius &&
        other.targetSecret == targetSecret &&
        other.target == target &&
        other.icon == icon &&
        other.iconColor == iconColor;
  }

  @override
  int get hashCode => Object.hash(
    choiceId,
    label,
    targetNodeId,
    isDefault,
    x,
    y,
    radius,
    targetSecret,
    target,
    icon,
    iconColor,
  );
}

class PlaybackTarget {
  const PlaybackTarget({required this.nodeId, required this.videoUrl});

  factory PlaybackTarget.fromJson(Map<String, dynamic> json) {
    return PlaybackTarget(
      nodeId: _requiredString(json['nodeId']),
      videoUrl: _requiredString(json['videoUrl']),
    );
  }

  final String nodeId;
  final String videoUrl;

  @override
  bool operator ==(Object other) {
    return other is PlaybackTarget &&
        other.nodeId == nodeId &&
        other.videoUrl == videoUrl;
  }

  @override
  int get hashCode => Object.hash(nodeId, videoUrl);
}

Map<String, dynamic> _objectMap(Object? value) {
  if (value is! Map) throw const AppFailure(.invalid);
  return value.map((key, item) => MapEntry(key.toString(), item));
}

/// Null (or a missing key) parses as null; a present map parses with
/// [parse]. Anything else is invalid.
T? _maybeMap<T>(Object? value, T Function(Map<String, dynamic>) parse) {
  if (value == null) return null;
  return parse(_objectMap(value));
}

String _requiredString(Object? value) {
  if (value is! String) throw const AppFailure(.invalid);
  final trimmed = value.trim();
  if (trimmed.isEmpty) throw const AppFailure(.invalid);
  return trimmed;
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const AppFailure(.invalid);
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed;
}

double _requiredDouble(Object? value) {
  if (value is! num) throw const AppFailure(.invalid);
  final number = value.toDouble();
  if (!number.isFinite) throw const AppFailure(.invalid);
  return number;
}

double? _optionalDouble(Object? value) {
  if (value == null) return null;
  return _requiredDouble(value);
}

bool _requiredBool(Object? value) {
  if (value is! bool) throw const AppFailure(.invalid);
  return value;
}

RunStatus _runStatus(Object? value) {
  return switch (value) {
    'active' => .active,
    'ended' => .ended,
    _ => throw const AppFailure(.invalid),
  };
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The story table, or empty when the publication predates it. A present
/// but malformed table is invalid, like any other malformed payload.
Map<String, PlaybackScene> _scenes(Object? value) {
  if (value == null) return const {};
  final map = _objectMap(value);
  return {
    for (final entry in map.entries)
      entry.key: PlaybackScene.fromJson(entry.key, _objectMap(entry.value)),
  };
}

bool _sameScenes(Map<String, PlaybackScene> a, Map<String, PlaybackScene> b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (a[key] != b[key]) return false;
  }
  return true;
}
