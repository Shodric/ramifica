import 'package:ramifica/data/models/app_failure.dart';

/// One exit of a draft node. Mirrors the server `ValidatableChoice`
/// shape (see functions/src/publish/validateStory.ts): the label the
/// player reads, the target node, which exit is the default, and the
/// hold zone inside the 0-1 frame.
class DraftChoice {
  const DraftChoice({
    required this.choiceId,
    required this.label,
    required this.targetNodeId,
    required this.isDefault,
    this.x = 0.5,
    this.y = 0.5,
    this.radius = 0.15,
  });

  factory DraftChoice.fromJson(Map<String, dynamic> json) {
    return DraftChoice(
      choiceId: _requiredString(json['choiceId']),
      label: _optionalString(json['label']) ?? '',
      targetNodeId: _requiredString(json['targetNodeId']),
      isDefault: json['isDefault'] == true,
      x: _optionalDouble(json['x']) ?? 0.5,
      y: _optionalDouble(json['y']) ?? 0.5,
      radius: _optionalDouble(json['radius']) ?? 0.15,
    );
  }

  final String choiceId;
  final String label;
  final String targetNodeId;
  final bool isDefault;
  final double x;
  final double y;
  final double radius;

  Map<String, dynamic> toJson() {
    return {
      'choiceId': choiceId,
      'label': label,
      'targetNodeId': targetNodeId,
      'isDefault': isDefault,
      'x': x,
      'y': y,
      'radius': radius,
    };
  }

  DraftChoice copy({
    String? label,
    String? targetNodeId,
    bool? isDefault,
    double? x,
    double? y,
    double? radius,
  }) {
    return DraftChoice(
      choiceId: choiceId,
      label: label ?? this.label,
      targetNodeId: targetNodeId ?? this.targetNodeId,
      isDefault: isDefault ?? this.isDefault,
      x: x ?? this.x,
      y: y ?? this.y,
      radius: radius ?? this.radius,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DraftChoice &&
        other.choiceId == choiceId &&
        other.label == label &&
        other.targetNodeId == targetNodeId &&
        other.isDefault == isDefault &&
        other.x == x &&
        other.y == y &&
        other.radius == radius;
  }

  @override
  int get hashCode =>
      Object.hash(choiceId, label, targetNodeId, isDefault, x, y, radius);
}

/// A draft node: `stories/{storyId}/nodes/{nodeId}`. Secrets included —
/// the author owns the whole draft, unlike players on the map.
///
/// Field names match the server node doc (seed + validateStory) so
/// `saveNode` can send [toJson] back unchanged.
class DraftNode {
  const DraftNode({
    required this.nodeId,
    this.title = '',
    this.visibility = 'visible',
    this.isEnding = false,
    this.endingName,
    this.endingType,
    this.videoUrl,
    this.videoStatus = 'idle',
    this.pauseAtSeconds,
    this.windowSeconds = 6,
    this.ttsText = '',
    this.lineApproved = false,
    this.ttsAudioUrl,
    this.ttsStatus = 'idle',
    this.ttsDurationSeconds,
    this.choices = const [],
  });

  factory DraftNode.fromMap(String nodeId, Map<String, dynamic> data) {
    if (nodeId.isEmpty) throw const AppFailure(.invalid);
    final rawChoices = data['choices'];
    return DraftNode(
      nodeId: nodeId,
      title: _optionalString(data['title']) ?? '',
      visibility: _optionalString(data['visibility']) ?? 'visible',
      isEnding: data['isEnding'] == true,
      endingName: _optionalString(data['endingName']),
      endingType: _optionalString(data['endingType']),
      videoUrl: _optionalString(data['videoUrl']),
      videoStatus: _optionalString(data['videoStatus']) ?? 'idle',
      pauseAtSeconds: _optionalDouble(data['pauseAtSeconds']),
      windowSeconds: _optionalInt(data['windowSeconds']) ?? 6,
      ttsText: _optionalString(data['ttsText']) ?? '',
      lineApproved: data['lineApproved'] == true,
      ttsAudioUrl: _optionalString(data['ttsAudioUrl']),
      ttsStatus: _optionalString(data['ttsStatus']) ?? 'idle',
      ttsDurationSeconds: _optionalDouble(data['ttsDurationSeconds']),
      choices: rawChoices is List
          ? [
              for (final raw in rawChoices)
                if (raw is Map)
                  DraftChoice.fromJson(
                    raw.map((key, value) => MapEntry(key.toString(), value)),
                  ),
            ]
          : const [],
    );
  }

  final String nodeId;
  final String title;

  /// `visible` or `secret`. Anything else fails publish validation.
  final String visibility;
  final bool isEnding;
  final String? endingName;
  final String? endingType;
  final String? videoUrl;
  final String? videoStatus;
  final double? pauseAtSeconds;

  /// Decision window in seconds, 3 to 15. Null on endings.
  final int? windowSeconds;

  /// The narrator line. Manual editing is the point: the view edits this
  /// in bloc state and only an explicit save sends it to the server.
  final String ttsText;
  final bool lineApproved;
  final String? ttsAudioUrl;
  final String? ttsStatus;
  final double? ttsDurationSeconds;
  final List<DraftChoice> choices;

  /// True while the map must hide the body from players.
  bool get secret => visibility == 'secret';

  /// Destination ids, in choice order. Drives canvas edges and orphans.
  List<String> get childIds =>
      [for (final choice in choices) choice.targetNodeId];

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'visibility': visibility,
      'isEnding': isEnding,
      'endingName': endingName,
      'endingType': endingType,
      'videoUrl': videoUrl,
      'videoStatus': videoStatus,
      'pauseAtSeconds': pauseAtSeconds,
      'windowSeconds': windowSeconds,
      'ttsText': ttsText,
      'lineApproved': lineApproved,
      'ttsAudioUrl': ttsAudioUrl,
      'ttsStatus': ttsStatus,
      'ttsDurationSeconds': ttsDurationSeconds,
      'choices': [for (final choice in choices) choice.toJson()],
    };
  }

  DraftNode copy({
    String? title,
    String? visibility,
    bool? isEnding,
    String? Function()? endingName,
    String? Function()? endingType,
    String? Function()? videoUrl,
    String? videoStatus,
    double? Function()? pauseAtSeconds,
    int? Function()? windowSeconds,
    String? ttsText,
    bool? lineApproved,
    String? Function()? ttsAudioUrl,
    String? ttsStatus,
    double? Function()? ttsDurationSeconds,
    List<DraftChoice>? choices,
  }) {
    return DraftNode(
      nodeId: nodeId,
      title: title ?? this.title,
      visibility: visibility ?? this.visibility,
      isEnding: isEnding ?? this.isEnding,
      endingName: endingName == null ? this.endingName : endingName(),
      endingType: endingType == null ? this.endingType : endingType(),
      videoUrl: videoUrl == null ? this.videoUrl : videoUrl(),
      videoStatus: videoStatus ?? this.videoStatus,
      pauseAtSeconds:
          pauseAtSeconds == null ? this.pauseAtSeconds : pauseAtSeconds(),
      windowSeconds:
          windowSeconds == null ? this.windowSeconds : windowSeconds(),
      ttsText: ttsText ?? this.ttsText,
      lineApproved: lineApproved ?? this.lineApproved,
      ttsAudioUrl: ttsAudioUrl == null ? this.ttsAudioUrl : ttsAudioUrl(),
      ttsStatus: ttsStatus ?? this.ttsStatus,
      ttsDurationSeconds: ttsDurationSeconds == null
          ? this.ttsDurationSeconds
          : ttsDurationSeconds(),
      choices: choices ?? this.choices,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DraftNode &&
        other.nodeId == nodeId &&
        other.title == title &&
        other.visibility == visibility &&
        other.isEnding == isEnding &&
        other.endingName == endingName &&
        other.endingType == endingType &&
        other.videoUrl == videoUrl &&
        other.videoStatus == videoStatus &&
        other.pauseAtSeconds == pauseAtSeconds &&
        other.windowSeconds == windowSeconds &&
        other.ttsText == ttsText &&
        other.lineApproved == lineApproved &&
        other.ttsAudioUrl == ttsAudioUrl &&
        other.ttsStatus == ttsStatus &&
        other.ttsDurationSeconds == ttsDurationSeconds &&
        _sameChoices(other.choices, choices);
  }

  @override
  int get hashCode => Object.hash(
        nodeId,
        title,
        visibility,
        isEnding,
        endingName,
        endingType,
        videoUrl,
        videoStatus,
        pauseAtSeconds,
        windowSeconds,
        ttsText,
        lineApproved,
        ttsAudioUrl,
        ttsStatus,
        ttsDurationSeconds,
        Object.hashAll(choices),
      );
}

String _requiredString(Object? value) {
  if (value is String && value.isNotEmpty) return value;
  throw const AppFailure(.invalid);
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  if (value is String && value.isNotEmpty) return value;
  return null;
}

double? _optionalDouble(Object? value) {
  if (value is num) return value.toDouble();
  return null;
}

int? _optionalInt(Object? value) {
  if (value is num) return value.toInt();
  return null;
}

bool _sameChoices(List<DraftChoice> a, List<DraftChoice> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
