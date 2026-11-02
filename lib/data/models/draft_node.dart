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
    this.slot,
    this.icon,
    this.iconColor,
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
      slot: _optionalString(json['slot']),
      icon: _optionalString(json['icon']),
      iconColor: _optionalString(json['iconColor']),
      x: _optionalDouble(json['x']) ?? 0.5,
      y: _optionalDouble(json['y']) ?? 0.5,
      radius: _optionalDouble(json['radius']) ?? 0.15,
    );
  }

  final String choiceId;
  final String label;
  final String targetNodeId;
  final bool isDefault;

  /// Branch slot: `A` (left) or `B` (right). Tells the canvas exactly
  /// where the child lands. Null on legacy choices, which keep
  /// append-order placement.
  final String? slot;

  /// Persisted hotspot icon name from the shared catalog
  /// (`choice_icon.dart`); null on legacy choices, which draw the
  /// index-based fallback until the author picks one.
  final String? icon;

  /// Persisted hotspot icon color name from the shared palette; null
  /// draws the per-index accent until the author picks one.
  final String? iconColor;
  final double x;
  final double y;
  final double radius;
  Map<String, dynamic> toJson() {
    return {
      'choiceId': choiceId,
      'label': label,
      'targetNodeId': targetNodeId,
      'isDefault': isDefault,
      if (slot != null) 'slot': slot,
      if (icon != null) 'icon': icon,
      if (iconColor != null) 'iconColor': iconColor,
      'x': x,
      'y': y,
      'radius': radius,
    };
  }

  DraftChoice copy({
    String? label,
    String? targetNodeId,
    bool? isDefault,
    String? slot,
    String? icon,
    String? iconColor,
    double? x,
    double? y,
    double? radius,
  }) {
    return DraftChoice(
      choiceId: choiceId,
      label: label ?? this.label,
      targetNodeId: targetNodeId ?? this.targetNodeId,
      isDefault: isDefault ?? this.isDefault,
      slot: slot ?? this.slot,
      icon: icon ?? this.icon,
      iconColor: iconColor ?? this.iconColor,
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
        other.slot == slot &&
        other.icon == icon &&
        other.iconColor == iconColor &&
        other.x == x &&
        other.y == y &&
        other.radius == radius;
  }

  @override
  int get hashCode => Object.hash(
    choiceId,
    label,
    targetNodeId,
    isDefault,
    slot,
    icon,
    iconColor,
    x,
    y,
    radius,
  );
}

/// A draft node: `stories/{storyId}/nodes/{nodeId}`. Secrets included —
/// the author owns the whole draft, unlike players on the map.
///
/// Field names match the server node doc (seed + validateStory).
/// A save merges the author fields only; [toJson] is the full doc.
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
    this.videoJobId,
    this.requestId,
    this.videoWidth,
    this.videoHeight,
    this.durationSeconds,
    this.videoFrameLastUrl,
    this.videoFrameLastHash,
    this.videoFrameLastBlurData,
    this.thumbnailUrl,
    this.startImageWidth,
    this.startImageHeight,
    this.generationKind,
    this.generationPhase,
    this.generationStartedAt,
    this.generationExpiresAt,
    this.mediaError,
    this.videoPrompt,
    this.startImageSourceUrl,
    this.startImageStatus = 'idle',
    this.startHash,
    this.startImagePrompt,
    this.startImageApproved = false,
    this.startFromNodeId,
    this.startParentFrameHash,
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
    final rawTitle = data['title'];
    if (rawTitle != null && rawTitle is! String) {
      throw const AppFailure(.invalid);
    }
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
      videoJobId: _optionalString(data['videoJobId']),
      requestId: _optionalString(data['requestId']),
      videoWidth: _optionalInt(data['videoWidth']),
      videoHeight: _optionalInt(data['videoHeight']),
      durationSeconds: _optionalDouble(data['durationSeconds']),
      videoFrameLastUrl: _optionalString(data['videoFrameLastUrl']),
      videoFrameLastHash: _optionalString(data['videoFrameLastHash']),
      videoFrameLastBlurData: _optionalString(data['videoFrameLastBlurData']),
      thumbnailUrl: _optionalString(data['thumbnailUrl']),
      startImageWidth: _optionalInt(data['startImageWidth']),
      startImageHeight: _optionalInt(data['startImageHeight']),
      generationKind: _optionalString(data['generationKind']),
      generationPhase: _optionalString(data['generationPhase']),
      generationStartedAt: _optionalString(data['generationStartedAt']),
      generationExpiresAt: _optionalString(data['generationExpiresAt']),
      mediaError: _optionalString(data['mediaError']),
      videoPrompt: _optionalString(data['videoPrompt']),
      startImageSourceUrl: _optionalString(data['startImageSourceUrl']),
      startImageStatus: _optionalString(data['startImageStatus']) ?? 'idle',
      startHash: _optionalString(data['startHash']),
      startImagePrompt: _optionalString(data['startImagePrompt']),
      startImageApproved: data['startImageApproved'] == true,
      startFromNodeId: _optionalString(data['startFromNodeId']),
      startParentFrameHash: _optionalString(data['startParentFrameHash']),
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
  final String? videoJobId;
  final String? requestId;
  final int? videoWidth;
  final int? videoHeight;
  final double? durationSeconds;
  final String? videoFrameLastUrl;

  /// sha8 of the extracted last frame. Children inherit S from the
  /// parent clip by this hash link (see [startParentFrameHash]).
  final String? videoFrameLastHash;
  final String? videoFrameLastBlurData;
  final String? thumbnailUrl;
  final int? startImageWidth;
  final int? startImageHeight;
  final String? generationKind;
  final String? generationPhase;
  final String? generationStartedAt, generationExpiresAt;
  bool get generationExpired {
    if (generationExpiresAt == null) {
      return startImageStatus == 'pending' || ttsStatus == 'pending';
    }
    return generationKind != null &&
        generationPhase != null &&
        DateTime.tryParse(generationExpiresAt!)?.isBefore(DateTime.now()) ==
            true;
  }

  final String? mediaError;
  final String? videoPrompt;

  /// S frame (root only): the source URL, generation status, and content
  /// hash. Non-root nodes inherit S from their parent clip's extracted
  /// last frame instead (see [startFromNodeId]/[startParentFrameHash]).
  final String? startImageSourceUrl;
  final String? startImageStatus;
  final String? startHash;
  final String? startImagePrompt;

  /// Ignored legacy: old docs carry this flag, but no gate reads it.
  /// Generated media is accepted as-is; regen replaces it.
  final bool startImageApproved;

  /// Hash link to the parent clip's last frame this node's S was
  /// inherited from. Desync detection compares it against the
  /// parent's [videoFrameLastHash].
  final String? startFromNodeId;
  final String? startParentFrameHash;

  /// The narrator line. Manual editing is the point: the view edits this
  /// in bloc state and only an explicit save sends it to the server.
  final String ttsText;

  /// Ignored legacy: old docs carry this flag, but no gate reads it.
  /// The line is accepted as-is.
  final bool lineApproved;
  final String? ttsAudioUrl;
  final String? ttsStatus;
  final double? ttsDurationSeconds;

  /// Ignored legacy: old docs carry this flag, but no gate reads it.
  /// The generated voice is accepted as-is; regen replaces it.
  final bool ttsApproved;
  final List<DraftChoice> choices;

  /// True while the map must hide the body from players.
  bool get secret => visibility == 'secret';

  /// Destination ids, in choice order. Drives canvas edges and orphans.
  List<String> get childIds => [
    for (final choice in choices) choice.targetNodeId,
  ];

  /// True when this non-root node's video is stale: it inherited S from
  /// its parent clip's last frame, the parent clip finished again since,
  /// and the backend forced this node's video back to `idle` (keeping
  /// the hashes as mismatch evidence) until it re-inherits via
  /// `generateNodeVideo`.
  bool isVideoDesyncedFrom(DraftNode? parent) {
    if (startFromNodeId == null || parent == null) return false;
    if (videoStatus != 'idle') return false;
    final inherited = startParentFrameHash;
    final current = parent.videoFrameLastHash;
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
      'videoJobId': videoJobId,
      'requestId': requestId,
      'videoWidth': videoWidth,
      'videoHeight': videoHeight,
      'durationSeconds': durationSeconds,
      'videoFrameLastUrl': videoFrameLastUrl,
      'videoFrameLastHash': videoFrameLastHash,
      'videoFrameLastBlurData': videoFrameLastBlurData,
      'thumbnailUrl': thumbnailUrl,
      'startImageWidth': startImageWidth,
      'startImageHeight': startImageHeight,
      'generationKind': generationKind,
      'generationPhase': generationPhase,
      'generationStartedAt': generationStartedAt,
      'generationExpiresAt': generationExpiresAt,
      'mediaError': mediaError,
      'videoPrompt': videoPrompt,
      'startImageSourceUrl': startImageSourceUrl,
      'startImageStatus': startImageStatus,
      'startHash': startHash,
      'startImagePrompt': startImagePrompt,
      'startImageApproved': startImageApproved,
      'startFromNodeId': startFromNodeId,
      'startParentFrameHash': startParentFrameHash,
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
    String? Function()? videoJobId,
    String? Function()? requestId,
    int? Function()? videoWidth,
    int? Function()? videoHeight,
    double? Function()? durationSeconds,
    String? Function()? videoFrameLastUrl,
    String? Function()? videoFrameLastHash,
    String? Function()? videoFrameLastBlurData,
    String? Function()? thumbnailUrl,
    int? Function()? startImageWidth,
    int? Function()? startImageHeight,
    String? Function()? generationKind,
    String? Function()? generationPhase,
    String? Function()? generationStartedAt,
    String? Function()? generationExpiresAt,
    String? Function()? mediaError,
    String? Function()? videoPrompt,
    String? Function()? startImageSourceUrl,
    String? startImageStatus,
    String? Function()? startHash,
    String? Function()? startImagePrompt,
    bool? startImageApproved,
    String? Function()? startFromNodeId,
    String? Function()? startParentFrameHash,
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
      videoFromHash: videoFromHash == null
          ? this.videoFromHash
          : videoFromHash(),
      videoJobId: videoJobId == null ? this.videoJobId : videoJobId(),
      requestId: requestId == null ? this.requestId : requestId(),
      videoWidth: videoWidth == null ? this.videoWidth : videoWidth(),
      videoHeight: videoHeight == null ? this.videoHeight : videoHeight(),
      durationSeconds: durationSeconds == null
          ? this.durationSeconds
          : durationSeconds(),
      videoFrameLastUrl: videoFrameLastUrl == null
          ? this.videoFrameLastUrl
          : videoFrameLastUrl(),
      videoFrameLastHash: videoFrameLastHash == null
          ? this.videoFrameLastHash
          : videoFrameLastHash(),
      videoFrameLastBlurData: videoFrameLastBlurData == null
          ? this.videoFrameLastBlurData
          : videoFrameLastBlurData(),
      thumbnailUrl: thumbnailUrl == null ? this.thumbnailUrl : thumbnailUrl(),
      startImageWidth: startImageWidth == null
          ? this.startImageWidth
          : startImageWidth(),
      startImageHeight: startImageHeight == null
          ? this.startImageHeight
          : startImageHeight(),
      generationKind: generationKind == null
          ? this.generationKind
          : generationKind(),
      generationPhase: generationPhase == null
          ? this.generationPhase
          : generationPhase(),
      generationStartedAt: generationStartedAt == null
          ? this.generationStartedAt
          : generationStartedAt(),
      generationExpiresAt: generationExpiresAt == null
          ? this.generationExpiresAt
          : generationExpiresAt(),
      mediaError: mediaError == null ? this.mediaError : mediaError(),
      videoPrompt: videoPrompt == null ? this.videoPrompt : videoPrompt(),
      startImageSourceUrl: startImageSourceUrl == null
          ? this.startImageSourceUrl
          : startImageSourceUrl(),
      startImageStatus: startImageStatus ?? this.startImageStatus,
      startHash: startHash == null ? this.startHash : startHash(),
      startImagePrompt: startImagePrompt == null
          ? this.startImagePrompt
          : startImagePrompt(),
      startImageApproved: startImageApproved ?? this.startImageApproved,
      startFromNodeId: startFromNodeId == null
          ? this.startFromNodeId
          : startFromNodeId(),
      startParentFrameHash: startParentFrameHash == null
          ? this.startParentFrameHash
          : startParentFrameHash(),
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
        other.videoJobId == videoJobId &&
        other.requestId == requestId &&
        other.videoWidth == videoWidth &&
        other.videoHeight == videoHeight &&
        other.durationSeconds == durationSeconds &&
        other.videoFrameLastUrl == videoFrameLastUrl &&
        other.videoFrameLastHash == videoFrameLastHash &&
        other.videoFrameLastBlurData == videoFrameLastBlurData &&
        other.thumbnailUrl == thumbnailUrl &&
        other.startImageWidth == startImageWidth &&
        other.startImageHeight == startImageHeight &&
        other.generationKind == generationKind &&
        other.generationPhase == generationPhase &&
        other.generationStartedAt == generationStartedAt &&
        other.generationExpiresAt == generationExpiresAt &&
        other.mediaError == mediaError &&
        other.videoPrompt == videoPrompt &&
        other.startImageSourceUrl == startImageSourceUrl &&
        other.startImageStatus == startImageStatus &&
        other.startHash == startHash &&
        other.startImagePrompt == startImagePrompt &&
        other.startImageApproved == startImageApproved &&
        other.startFromNodeId == startFromNodeId &&
        other.startParentFrameHash == startParentFrameHash &&
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
    videoJobId,
    requestId,
    videoWidth,
    videoHeight,
    durationSeconds,
    videoFrameLastUrl,
    videoFrameLastHash,
    videoFrameLastBlurData,
    thumbnailUrl,
    startImageWidth,
    startImageHeight,
    generationKind,
    generationPhase,
    generationStartedAt,
    generationExpiresAt,
    mediaError,
    videoPrompt,
    startImageSourceUrl,
    startImageStatus,
    startHash,
    startImagePrompt,
    startImageApproved,
    startFromNodeId,
    startParentFrameHash,
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
