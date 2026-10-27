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
}

const defaultUserLocale = 'es-AR';
