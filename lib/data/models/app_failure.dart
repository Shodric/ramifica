enum AppFailureCode { offline, denied, invalid, failed }

class AppFailure implements Exception {
  const AppFailure(this.code, {this.cause});

  final AppFailureCode code;
  final Object? cause;

  @override
  String toString() => 'AppFailure(${code.name})';
}
