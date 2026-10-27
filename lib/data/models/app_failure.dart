enum AppFailureCode { offline, denied, invalid, failed }

class AppFailure implements Exception {
  const AppFailure(this.code, {this.cause});

  final AppFailureCode code;
  final Object? cause;

  String get phrase {
    return switch (code) {
      .offline => 'No connection',
      .denied => 'Not allowed',
      .invalid => 'That action is not valid',
      .failed => 'Something failed',
    };
  }

  @override
  String toString() => 'AppFailure(${code.name})';
}
