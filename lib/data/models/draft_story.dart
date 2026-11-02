import 'package:ramifica/data/models/app_failure.dart';

/// A draft story doc: `stories/{storyId}` with `status == 'draft'`.
///
/// The author owns this doc. Client-direct create/update is allowed by
/// firestore.rules (authorId must stay the caller's uid, status must stay
/// `draft`); nodes under it are Functions-only.
class DraftStory {
  const DraftStory({
    required this.storyId,
    required this.authorId,
    required this.title,
    this.synopsis = '',
    this.coverUrl,
    this.nodeCount,
    this.endingCount,
    this.rootNodeId,
    this.revision = 0,
    this.status = 'draft',
    this.updatedAt,
  });

  factory DraftStory.fromDoc(String id, Map<String, dynamic> data) {
    if (id.isEmpty) throw const AppFailure(.invalid);
    return DraftStory(
      storyId: id,
      authorId: _requiredString(data['authorId']),
      title: _optionalString(data['title']) ?? '',
      synopsis: _optionalString(data['synopsis']) ?? '',
      coverUrl: _optionalString(data['coverUrl']),
      rootNodeId: _optionalString(data['rootNodeId']),
      revision: (data['revision'] as num?)?.toInt() ?? 0,
      status: _optionalString(data['status']) ?? 'draft',
      updatedAt: _optionalDateTime(data['updatedAt']),
    );
  }

  final String storyId;
  final String authorId;
  final String title;
  final String synopsis;

  /// Key art from `generateStoryCover`. Null until the first cover exists.
  final String? coverUrl;

  /// Scene and ending counts for the creations list. Null while unknown:
  /// the story doc carries no counts, so only the list fetch attaches them.
  final int? nodeCount;
  final int? endingCount;

  /// The root node id. Null until the first node exists.
  final String? rootNodeId;
  final int revision;

  /// `draft` or `published`. Missing docs read as drafts.
  final String status;

  /// Last server write, when the backend recorded one. Null sorts last.
  final DateTime? updatedAt;

  DraftStory copy({
    String? title,
    String? synopsis,
    String? Function()? coverUrl,
    int? Function()? nodeCount,
    int? Function()? endingCount,
    String? Function()? rootNodeId,
    int? revision,
    String? status,
    DateTime? Function()? updatedAt,
  }) {
    return DraftStory(
      storyId: storyId,
      authorId: authorId,
      title: title ?? this.title,
      synopsis: synopsis ?? this.synopsis,
      coverUrl: coverUrl == null ? this.coverUrl : coverUrl(),
      nodeCount: nodeCount == null ? this.nodeCount : nodeCount(),
      endingCount: endingCount == null ? this.endingCount : endingCount(),
      rootNodeId: rootNodeId == null ? this.rootNodeId : rootNodeId(),
      revision: revision ?? this.revision,
      status: status ?? this.status,
      updatedAt: updatedAt == null ? this.updatedAt : updatedAt(),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DraftStory &&
        other.storyId == storyId &&
        other.authorId == authorId &&
        other.title == title &&
        other.synopsis == synopsis &&
        other.coverUrl == coverUrl &&
        other.nodeCount == nodeCount &&
        other.endingCount == endingCount &&
        other.rootNodeId == rootNodeId &&
        other.revision == revision &&
        other.status == status &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode => Object.hash(
    storyId,
    authorId,
    title,
    synopsis,
    coverUrl,
    nodeCount,
    endingCount,
    rootNodeId,
    revision,
    status,
    updatedAt,
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

/// Server timestamps arrive as Firestore `Timestamp`s (or millis in
/// tests). Anything else reads as null and sorts last.
DateTime? _optionalDateTime(Object? value) {
  if (value == null) return null;
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
  if (value is String) return DateTime.tryParse(value);
  try {
    final dynamic stamped = value;
    final DateTime? date = stamped.toDate() as DateTime?;
    return date?.toUtc();
  } catch (_) {
    return null;
  }
}
