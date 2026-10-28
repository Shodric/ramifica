import 'package:ramifica/data/models/app_failure.dart';

/// One published story for the Explore grid. No nodes.
///
/// Display-only author fields ride the story doc when present
/// (`authorName`); `users/{uid}` is self-readable only, so Explore never
/// joins the user doc. The card falls back to [authorId] when [authorName]
/// is null.
class StorySummary {
  const StorySummary({
    required this.storyId,
    required this.title,
    this.authorId,
    this.authorName,
    this.synopsis,
    this.coverUrl,
    this.campaignLabel,
    this.featured = false,
  });

  /// Parses one `stories` doc. Throws [AppFailure] (`.invalid`) when the
  /// doc has no usable id or title; the repository skips such docs.
  factory StorySummary.fromDoc(String id, Map<String, dynamic> data) {
    final storyId = id.trim();
    if (storyId.isEmpty) throw const AppFailure(.invalid);
    return StorySummary(
      storyId: storyId,
      title: _requiredTitle(data['title']),
      authorId: _optionalText(data['authorId']),
      authorName: _optionalText(data['authorName']),
      synopsis: _optionalText(data['synopsis']),
      coverUrl:
          _optionalText(data['coverUrl']) ?? _optionalText(data['ogImageUrl']),
      campaignLabel: _optionalText(data['campaignLabel']),
      featured: data['featured'] == true,
    );
  }

  final String storyId;
  final String title;
  final String? authorId;
  final String? authorName;
  final String? synopsis;
  final String? coverUrl;
  final String? campaignLabel;
  final bool featured;

  @override
  bool operator ==(Object other) {
    return other is StorySummary &&
        other.storyId == storyId &&
        other.title == title &&
        other.authorId == authorId &&
        other.authorName == authorName &&
        other.synopsis == synopsis &&
        other.coverUrl == coverUrl &&
        other.campaignLabel == campaignLabel &&
        other.featured == featured;
  }

  @override
  int get hashCode => Object.hash(
    storyId,
    title,
    authorId,
    authorName,
    synopsis,
    coverUrl,
    campaignLabel,
    featured,
  );
}

String _requiredTitle(Object? value) {
  if (value is! String) throw const AppFailure(.invalid);
  final title = value.trim();
  if (title.isEmpty) throw const AppFailure(.invalid);
  return title;
}

String? _optionalText(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const AppFailure(.invalid);
  final text = value.trim();
  if (text.isEmpty) return null;
  return text;
}
