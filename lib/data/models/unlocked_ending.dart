/// One unlocked ending: which story it belongs to plus its display name
/// and type. Rows come from the unlocked-endings read (`users/{uid}`
/// `storyState` joined with `rewards`); [fromRow] maps one, [listFromRows]
/// maps many and drops the unreadable ones.
class UnlockedEnding {
  const UnlockedEnding({
    required this.storyId,
    required this.name,
    this.type,
    this.badgeUrl,
  });

  /// Maps one unlocked-endings row (`storyId`, `name`, `type`, `badgeUrl`).
  /// Throws [ArgumentError] when the row has no usable story id.
  factory UnlockedEnding.fromRow(Map<String, dynamic> row) {
    final storyId = row['storyId'];
    if (storyId is! String || storyId.isEmpty) {
      throw ArgumentError('Unlocked ending row needs a storyId.');
    }
    String text(Object? value, String fallback) {
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? fallback : text;
    }

    String? optional(Object? value) {
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? null : text;
    }

    return UnlockedEnding(
      storyId: storyId,
      name: text(row['name'], 'Ending'),
      type: optional(row['type']),
      badgeUrl: optional(row['badgeUrl']),
    );
  }

  /// Maps every row, skipping the malformed ones. A bad row never fails
  /// the tab: that story or node is unreadable and stays out.
  static List<UnlockedEnding> listFromRows(List<Map<String, dynamic>> rows) {
    final endings = <UnlockedEnding>[];
    for (final row in rows) {
      try {
        endings.add(UnlockedEnding.fromRow(row));
      } on ArgumentError {
        continue;
      }
    }
    return endings;
  }

  /// The story whose graph opens on tap (`/graph/{storyId}`).
  final String storyId;

  final String name;

  /// One of the nine ending types; see `EndingBadge`.
  final String? type;

  /// The unlocked prize image. Null hides the row thumbnail.
  final String? badgeUrl;

  @override
  bool operator ==(Object other) {
    return other is UnlockedEnding &&
        other.storyId == storyId &&
        other.name == name &&
        other.type == type &&
        other.badgeUrl == badgeUrl;
  }

  @override
  int get hashCode => Object.hash(storyId, name, type, badgeUrl);
}
