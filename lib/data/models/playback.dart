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

/// The `commitChoice` payload: the destination playback.
///
/// A later slice adds the ending, the saga unlock, and the reward code.
class CommitResult {
  const CommitResult({required this.playback});

  factory CommitResult.fromJson(Map<String, dynamic> json) {
    return CommitResult(
      playback: Playback.fromJson(_objectMap(json['playback'])),
    );
  }

  final Playback playback;

  @override
  bool operator ==(Object other) {
    return other is CommitResult && other.playback == playback;
  }

  @override
  int get hashCode => playback.hashCode;
}

/// The `loadPlayback` payload: story, current node, and choices.
class Playback {
  const Playback({
    required this.runId,
    required this.status,
    required this.story,
    required this.node,
    required this.choices,
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
    );
  }

  final String runId;
  final RunStatus status;
  final PlaybackStory story;
  final PlaybackNode node;
  final List<PlaybackChoice> choices;

  @override
  bool operator ==(Object other) {
    return other is Playback &&
        other.runId == runId &&
        other.status == status &&
        other.story == story &&
        other.node == node &&
        _sameList(other.choices, choices);
  }

  @override
  int get hashCode =>
      Object.hash(runId, status, story, node, Object.hashAll(choices));
}

class PlaybackStory {
  const PlaybackStory({
    required this.storyId,
    required this.title,
    required this.authorName,
  });

  factory PlaybackStory.fromJson(Map<String, dynamic> json) {
    return PlaybackStory(
      storyId: _requiredString(json['storyId']),
      title: _requiredString(json['title']),
      authorName: _requiredString(json['authorName']),
    );
  }

  final String storyId;
  final String title;
  final String authorName;

  @override
  bool operator ==(Object other) {
    return other is PlaybackStory &&
        other.storyId == storyId &&
        other.title == title &&
        other.authorName == authorName;
  }

  @override
  int get hashCode => Object.hash(storyId, title, authorName);
}

class PlaybackNode {
  const PlaybackNode({
    required this.nodeId,
    required this.title,
    required this.isEnding,
    required this.videoUrl,
    required this.durationSeconds,
    required this.pauseAtSeconds,
    required this.windowSeconds,
    required this.videoFrameLastBlurData,
    this.ttsText,
    this.ttsAudioUrl,
    this.ttsDurationSeconds,
    this.endingName,
    this.endingType,
  });

  factory PlaybackNode.fromJson(Map<String, dynamic> json) {
    return PlaybackNode(
      nodeId: _requiredString(json['nodeId']),
      title: _requiredString(json['title']),
      isEnding: _requiredBool(json['isEnding']),
      videoUrl: _requiredString(json['videoUrl']),
      durationSeconds: _requiredDouble(json['durationSeconds']),
      pauseAtSeconds: _requiredDouble(json['pauseAtSeconds']),
      windowSeconds: _requiredInt(json['windowSeconds']),
      videoFrameLastBlurData: _requiredString(json['videoFrameLastBlurData']),
      ttsText: _optionalString(json['ttsText']),
      ttsAudioUrl: _optionalString(json['ttsAudioUrl']),
      ttsDurationSeconds: _optionalDouble(json['ttsDurationSeconds']),
      endingName: _optionalString(json['endingName']),
      endingType: _optionalString(json['endingType']),
    );
  }

  final String nodeId;
  final String title;
  final bool isEnding;
  final String videoUrl;
  final double durationSeconds;
  final double pauseAtSeconds;
  final int windowSeconds;
  final String videoFrameLastBlurData;
  final String? ttsText;
  final String? ttsAudioUrl;
  final double? ttsDurationSeconds;
  final String? endingName;
  final String? endingType;

  @override
  bool operator ==(Object other) {
    return other is PlaybackNode &&
        other.nodeId == nodeId &&
        other.title == title &&
        other.isEnding == isEnding &&
        other.videoUrl == videoUrl &&
        other.durationSeconds == durationSeconds &&
        other.pauseAtSeconds == pauseAtSeconds &&
        other.windowSeconds == windowSeconds &&
        other.videoFrameLastBlurData == videoFrameLastBlurData &&
        other.ttsText == ttsText &&
        other.ttsAudioUrl == ttsAudioUrl &&
        other.ttsDurationSeconds == ttsDurationSeconds &&
        other.endingName == endingName &&
        other.endingType == endingType;
  }

  @override
  int get hashCode => Object.hash(
    nodeId,
    title,
    isEnding,
    videoUrl,
    durationSeconds,
    pauseAtSeconds,
    windowSeconds,
    videoFrameLastBlurData,
    ttsText,
    ttsAudioUrl,
    ttsDurationSeconds,
    endingName,
    endingType,
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
        other.target == target;
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

int _requiredInt(Object? value) {
  if (value is! num) throw const AppFailure(.invalid);
  final number = value.toDouble();
  if (!number.isFinite || number != number.roundToDouble()) {
    throw const AppFailure(.invalid);
  }
  return number.toInt();
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
