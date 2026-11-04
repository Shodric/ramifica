enum AppFailureCode { offline, denied, invalid, failed }

class AppFailure implements Exception {
  const AppFailure(this.code, {this.cause, this.detail});

  final AppFailureCode code;
  final Object? cause;

  /// Server text when [phrase] would hide the cause. Blank counts as absent.
  final String? detail;

  String get phrase {
    return switch (code) {
      .offline => 'No connection',
      .denied => 'Not allowed',
      .invalid => 'That action is not valid',
      .failed => 'Something failed',
    };
  }

  /// What the screen should show: [detail] when the server sent one.
  String get hint {
    final text = detail?.trim();
    if (text != null && text.isNotEmpty) return text;
    return phrase;
  }

  /// Missing, or hidden by the rules. Firestore answers an absent story
  /// with permission-denied, so a bad id looks like [AppFailureCode.denied].
  bool get unavailable {
    if (code == .denied) return true;
    final text = detail?.toLowerCase() ?? '';
    return text.contains('not found');
  }

  @override
  String toString() => 'AppFailure(${code.name})';
}
