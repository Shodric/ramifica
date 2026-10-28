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
    this.videoSource,
    this.videoFromHash,
    this.videoToHash,
    this.videoJobId,
    this.videoPrompt,
    this.pauseAtSeconds,
    this.windowSeconds = 6,
    this.startImageSourceUrl,
    this.startImageStatus = 'idle',
    this.startHash,
    this.startImagePrompt,
    this.startImageApproved = false,
    this.startFromNodeId,
    this.startParentEndHash,
    this.endImageSourceUrl,
    this.endImageStatus = 'idle',
    this.endHash,
    this.endImagePrompt,
    this.endImageSource,
    this.endImageApproved = false,
    this.ttsText = '',
    this.lineApproved = false,
    this.ttsAudioUrl,
    this.ttsStatus = 'idle',
    this.ttsDurationSeconds,
    this.ttsApproved = false,
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
      videoSource: _optionalString(data['videoSource']),
      videoFromHash: _optionalString(data['videoFromHash']),
      videoToHash: _optionalString(data['videoToHash']),
      videoJobId: _optionalString(data['videoJobId']),
      videoPrompt: _optionalString(data['videoPrompt']),
      pauseAtSeconds: _optionalDouble(data['pauseAtSeconds']),
      windowSeconds: data['isEnding'] == true
          ? null
          : (_optionalInt(data['windowSeconds']) ?? 6),
      startImageSourceUrl: _optionalString(data['startImageSourceUrl']),
      startImageStatus: _optionalString(data['startImageStatus']) ?? 'idle',
      startHash: _optionalString(data['startHash']),
      startImagePrompt: _optionalString(data['startImagePrompt']),
      startImageApproved: data['startImageApproved'] == true,
      startFromNodeId: _optionalString(data['startFromNodeId']),
      startParentEndHash: _optionalString(data['startParentEndHash']),
      endImageSourceUrl: _optionalString(data['endImageSourceUrl']),
      endImageStatus: _optionalString(data['endImageStatus']) ?? 'idle',
      endHash: _optionalString(data['endHash']),
      endImagePrompt: _optionalString(data['endImagePrompt']),
      endImageSource: _optionalString(data['endImageSource']),
      endImageApproved: data['endImageApproved'] == true,
      ttsText: _optionalString(data['ttsText']) ?? '',
      lineApproved: data['lineApproved'] == true,
      ttsAudioUrl: _optionalString(data['ttsAudioUrl']),
      ttsStatus: _optionalString(data['ttsStatus']) ?? 'idle',
      ttsDurationSeconds: _optionalDouble(data['ttsDurationSeconds']),
      ttsApproved: data['ttsApproved'] == true,
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
  final String? videoSource;
  final String? videoFromHash;
  final String? videoToHash;
  final String? videoJobId;
  final String? videoPrompt;
  final double? pauseAtSeconds;

  /// Decision window in seconds, 3 to 15. Null on endings.
  final int? windowSeconds;

  /// S frame (root only): the source URL, generation status, content
  /// hash, and author approval. Non-root nodes inherit S from their
  /// parent E instead (see [startFromNodeId]/[startParentEndHash]).
  final String? startImageSourceUrl;
  final String? startImageStatus;
  final String? startHash;
  final String? startImagePrompt;
  final bool startImageApproved;

  /// Hash link to the parent E this node's S was inherited from.
  /// Desync detection compares it against the parent's [endHash].
  final String? startFromNodeId;
  final String? startParentEndHash;

  /// E frame (every node): the source URL, generation status, content
  /// hash, and author approval. Children inherit this as their S.
  final String? endImageSourceUrl;
  final String? endImageStatus;
  final String? endHash;
  final String? endImagePrompt;
  final String? endImageSource;
  final bool endImageApproved;

  /// The narrator line. Manual editing is the point: the view edits this
  /// in bloc state and only an explicit save sends it to the server.
  final String ttsText;
  final bool lineApproved;
  final String? ttsAudioUrl;
  final String? ttsStatus;
  final double? ttsDurationSeconds;
  /// The narrator take approval. Set when the author approves the
  /// generated voice (`generateNodeVoice` always lands unapproved);
  /// editing the line idles the voice and clears this server-side.
  final bool ttsApproved;
  final List<DraftChoice> choices;

  /// True while the map must hide the body from players.
  bool get secret => visibility == 'secret';

  /// Destination ids, in choice order. Drives canvas edges and orphans.
  List<String> get childIds =>
      [for (final choice in choices) choice.targetNodeId];

  /// True when this non-root node's video is stale: it inherited S from
  /// its parent E, the parent regenerated E since, and the backend forced
  /// this node's video back to `idle` (keeping the hashes as mismatch
  /// evidence) until it re-inherits via `generateNodeVideo`.
  bool isVideoDesyncedFrom(DraftNode? parent) {
    if (startFromNodeId == null || parent == null) return false;
    if (videoStatus != 'idle') return false;
    final inherited = startParentEndHash;
    final current = parent.endHash;
    if (inherited == null || inherited.isEmpty) return false;
    if (current == null || current.isEmpty) return false;
    return inherited != current;
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'visibility': visibility,
      'isEnding': isEnding,
      'endingName': endingName,
      'endingType': endingType,
      'videoUrl': videoUrl,
      'videoStatus': videoStatus,
      'videoSource': videoSource,
      'videoFromHash': videoFromHash,
      'videoToHash': videoToHash,
      'videoJobId': videoJobId,
      'videoPrompt': videoPrompt,
      'pauseAtSeconds': pauseAtSeconds,
      'windowSeconds': windowSeconds,
      'startImageSourceUrl': startImageSourceUrl,
      'startImageStatus': startImageStatus,
      'startHash': startHash,
      'startImagePrompt': startImagePrompt,
      'startImageApproved': startImageApproved,
      'startFromNodeId': startFromNodeId,
      'startParentEndHash': startParentEndHash,
      'endImageSourceUrl': endImageSourceUrl,
      'endImageStatus': endImageStatus,
      'endHash': endHash,
      'endImagePrompt': endImagePrompt,
      'endImageSource': endImageSource,
      'endImageApproved': endImageApproved,
      'ttsText': ttsText,
      'lineApproved': lineApproved,
      'ttsAudioUrl': ttsAudioUrl,
      'ttsStatus': ttsStatus,
      'ttsDurationSeconds': ttsDurationSeconds,
      'ttsApproved': ttsApproved,
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
    String? Function()? videoSource,
    String? Function()? videoFromHash,
    String? Function()? videoToHash,
    String? Function()? videoJobId,
    String? Function()? videoPrompt,
    double? Function()? pauseAtSeconds,
    int? Function()? windowSeconds,
    String? Function()? startImageSourceUrl,
    String? startImageStatus,
    String? Function()? startHash,
    String? Function()? startImagePrompt,
    bool? startImageApproved,
    String? Function()? startFromNodeId,
    String? Function()? startParentEndHash,
    String? Function()? endImageSourceUrl,
    String? endImageStatus,
    String? Function()? endHash,
    String? Function()? endImagePrompt,
    String? Function()? endImageSource,
    bool? endImageApproved,
    String? ttsText,
    bool? lineApproved,
    String? Function()? ttsAudioUrl,
    String? ttsStatus,
    double? Function()? ttsDurationSeconds,
    bool? ttsApproved,
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
      videoSource: videoSource == null ? this.videoSource : videoSource(),
      videoFromHash:
          videoFromHash == null ? this.videoFromHash : videoFromHash(),
      videoToHash: videoToHash == null ? this.videoToHash : videoToHash(),
      videoJobId: videoJobId == null ? this.videoJobId : videoJobId(),
      videoPrompt: videoPrompt == null ? this.videoPrompt : videoPrompt(),
      pauseAtSeconds:
          pauseAtSeconds == null ? this.pauseAtSeconds : pauseAtSeconds(),
      windowSeconds:
          windowSeconds == null ? this.windowSeconds : windowSeconds(),
      startImageSourceUrl: startImageSourceUrl == null
          ? this.startImageSourceUrl
          : startImageSourceUrl(),
      startImageStatus: startImageStatus ?? this.startImageStatus,
      startHash: startHash == null ? this.startHash : startHash(),
      startImagePrompt:
          startImagePrompt == null ? this.startImagePrompt : startImagePrompt(),
      startImageApproved: startImageApproved ?? this.startImageApproved,
      startFromNodeId:
          startFromNodeId == null ? this.startFromNodeId : startFromNodeId(),
      startParentEndHash: startParentEndHash == null
          ? this.startParentEndHash
          : startParentEndHash(),
      endImageSourceUrl: endImageSourceUrl == null
          ? this.endImageSourceUrl
          : endImageSourceUrl(),
      endImageStatus: endImageStatus ?? this.endImageStatus,
      endHash: endHash == null ? this.endHash : endHash(),
      endImagePrompt:
          endImagePrompt == null ? this.endImagePrompt : endImagePrompt(),
      endImageSource:
          endImageSource == null ? this.endImageSource : endImageSource(),
      endImageApproved: endImageApproved ?? this.endImageApproved,
      ttsText: ttsText ?? this.ttsText,
      lineApproved: lineApproved ?? this.lineApproved,
      ttsAudioUrl: ttsAudioUrl == null ? this.ttsAudioUrl : ttsAudioUrl(),
      ttsStatus: ttsStatus ?? this.ttsStatus,
      ttsDurationSeconds: ttsDurationSeconds == null
          ? this.ttsDurationSeconds
          : ttsDurationSeconds(),
      ttsApproved: ttsApproved ?? this.ttsApproved,
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
        other.videoSource == videoSource &&
        other.videoFromHash == videoFromHash &&
        other.videoToHash == videoToHash &&
        other.videoJobId == videoJobId &&
        other.videoPrompt == videoPrompt &&
        other.pauseAtSeconds == pauseAtSeconds &&
        other.windowSeconds == windowSeconds &&
        other.startImageSourceUrl == startImageSourceUrl &&
        other.startImageStatus == startImageStatus &&
        other.startHash == startHash &&
        other.startImagePrompt == startImagePrompt &&
        other.startImageApproved == startImageApproved &&
        other.startFromNodeId == startFromNodeId &&
        other.startParentEndHash == startParentEndHash &&
        other.endImageSourceUrl == endImageSourceUrl &&
        other.endImageStatus == endImageStatus &&
        other.endHash == endHash &&
        other.endImagePrompt == endImagePrompt &&
        other.endImageSource == endImageSource &&
        other.endImageApproved == endImageApproved &&
        other.ttsText == ttsText &&
        other.lineApproved == lineApproved &&
        other.ttsAudioUrl == ttsAudioUrl &&
        other.ttsStatus == ttsStatus &&
        other.ttsDurationSeconds == ttsDurationSeconds &&
        other.ttsApproved == ttsApproved &&
        _sameChoices(other.choices, choices);
  }

  @override
  int get hashCode => Object.hashAll([
        nodeId,
        title,
        visibility,
        isEnding,
        endingName,
        endingType,
        videoUrl,
        videoStatus,
        videoSource,
        videoFromHash,
        videoToHash,
        videoJobId,
        videoPrompt,
        pauseAtSeconds,
        windowSeconds,
        startImageSourceUrl,
        startImageStatus,
        startHash,
        startImagePrompt,
        startImageApproved,
        startFromNodeId,
        startParentEndHash,
        endImageSourceUrl,
        endImageStatus,
        endHash,
        endImagePrompt,
        endImageSource,
        endImageApproved,
        ttsText,
        lineApproved,
        ttsAudioUrl,
        ttsStatus,
        ttsDurationSeconds,
        ttsApproved,
        Object.hashAll(choices),
      ]);
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
