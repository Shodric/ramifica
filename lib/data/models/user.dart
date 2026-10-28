class UserAccount {
  const UserAccount({
    required this.uid,
    this.displayName,
    this.handle,
    this.photoUrl,
    this.locale = defaultUserLocale,
    this.providers = const [],
    this.createdAt,
  });

  final String uid;
  final String? displayName;
  final String? handle;
  final String? photoUrl;
  final String locale;
  final List<String> providers;
  final DateTime? createdAt;


  /// Reads a `users/{uid}` doc. Missing or mistyped fields fall back to
  /// nulls (and [defaultUserLocale]); foreign docs are usually
  /// unreadable under firestore.rules, so callers treat a denied read
  /// as "minimal profile", not as malformed data.
  factory UserAccount.fromDoc(String uid, Map<String, dynamic> data) {
    final displayName = data['displayName'];
    final handle = data['handle'];
    final photoUrl = data['photoUrl'];
    final locale = data['locale'];
    final providers = data['providers'];
    return UserAccount(
      uid: uid,
      displayName: displayName is String && displayName.trim().isNotEmpty
          ? displayName.trim()
          : null,
      handle: handle is String && handle.trim().isNotEmpty
          ? handle.trim()
          : null,
      photoUrl: photoUrl is String && photoUrl.trim().isNotEmpty
          ? photoUrl.trim()
          : null,
      locale: locale is String && locale.trim().isNotEmpty
          ? locale.trim()
          : defaultUserLocale,
      providers: [for (final entry in providers is List ? providers : const []) if (entry is String) entry],
    );
  }

  /// Fields `users/{uid}` may contain on create.
  /// `handle` stays out until Profile sets it.
  Map<String, Object?> toCreateMap({required Object createdAt}) {
    return {
      if (displayName != null) 'displayName': displayName,
      if (photoUrl != null) 'photoUrl': photoUrl,
      'providers': providers,
      'locale': locale,
      'createdAt': createdAt,
    };
  }

  /// Editable `users/{uid}` fields for an update call. Always the same
  /// four keys firestore.rules allows on update
  /// (`displayName`, `handle`, `photoUrl`, `locale`); unchanged values
  /// are harmless because the rule diffs affected keys.
  Map<String, Object?> toUpdateMap() {
    return {
      'displayName': displayName,
      'handle': handle,
      'photoUrl': photoUrl,
      'locale': locale,
    };
  }
}

const defaultUserLocale = 'es-AR';
