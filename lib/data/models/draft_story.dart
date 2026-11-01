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
    this.rootNodeId,
    this.revision = 0,
  });

  factory DraftStory.fromDoc(String id, Map<String, dynamic> data) {
    if (id.isEmpty) throw const AppFailure(.invalid);
    return DraftStory(
      storyId: id,
      authorId: _requiredString(data['authorId']),
      title: _optionalString(data['title']) ?? '',
      synopsis: _optionalString(data['synopsis']) ?? '',
      rootNodeId: _optionalString(data['rootNodeId']),
      revision: (data['revision'] as num?)?.toInt() ?? 0,
    );
  }

  final String storyId;
  final String authorId;
  final String title;
  final String synopsis;

  /// The root node id. Null until the first node exists.
  final String? rootNodeId;
  final int revision;

  DraftStory copy({
    String? title,
    String? synopsis,
    String? Function()? rootNodeId,
    int? revision,
  }) {
    return DraftStory(
      storyId: storyId,
      authorId: authorId,
      title: title ?? this.title,
      synopsis: synopsis ?? this.synopsis,
      rootNodeId: rootNodeId == null ? this.rootNodeId : rootNodeId(),
      revision: revision ?? this.revision,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DraftStory &&
        other.storyId == storyId &&
        other.authorId == authorId &&
        other.title == title &&
        other.synopsis == synopsis &&
        other.rootNodeId == rootNodeId &&
        other.revision == revision;
  }

  @override
  int get hashCode =>
      Object.hash(storyId, authorId, title, synopsis, rootNodeId, revision);
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
