import 'package:ramifica/data/models/app_failure.dart';

/// One active campaign for Explore. The card shows the story plus the
/// brand label. The reward is never exposed to the client.
class CampaignSummary {
  const CampaignSummary({
    required this.campaignId,
    required this.storyId,
    required this.brandLabel,
    this.title,
    this.coverUrl,
  });

  /// Parses one `campaigns` doc. Throws [AppFailure] (`.invalid`) when the
  /// doc has no usable id, story, or brand; the repository skips such docs.
  factory CampaignSummary.fromDoc(String id, Map<String, dynamic> data) {
    final campaignId = id.trim();
    if (campaignId.isEmpty) throw const AppFailure(.invalid);
    final storyId = _optionalText(data['storyId']);
    final brand =
        _optionalText(data['brandLabel']) ??
        _optionalText(data['brand']) ??
        _optionalText(data['brandName']);
    if (storyId == null || brand == null) {
      throw const AppFailure(.invalid);
    }
    return CampaignSummary(
      campaignId: campaignId,
      storyId: storyId,
      brandLabel: brand,
      title: _optionalText(data['title']),
      coverUrl:
          _optionalText(data['coverUrl']) ?? _optionalText(data['ogImageUrl']),
    );
  }

  final String campaignId;
  final String storyId;
  final String brandLabel;
  final String? title;
  final String? coverUrl;

  @override
  bool operator ==(Object other) {
    return other is CampaignSummary &&
        other.campaignId == campaignId &&
        other.storyId == storyId &&
        other.brandLabel == brandLabel &&
        other.title == title &&
        other.coverUrl == coverUrl;
  }

  @override
  int get hashCode =>
      Object.hash(campaignId, storyId, brandLabel, title, coverUrl);
}

String? _optionalText(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const AppFailure(.invalid);
  final text = value.trim();
  if (text.isEmpty) return null;
  return text;
}
