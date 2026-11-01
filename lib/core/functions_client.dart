import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:ramifica/data/models/app_failure.dart';

const functionsRegion = 'us-central1';

typedef FunctionsCaller = Future<dynamic> Function(
  String name,
  Map<String, dynamic>? data,
);

class FunctionsClient {
  FunctionsClient({FunctionsCaller? call}) : _call = call ?? _callFirebase;

  final FunctionsCaller _call;

  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic>? data,
  ]) async {
    try {
      final raw = await _call(name, data);
      if (raw is Map) {
        return raw.map((key, value) => MapEntry(key.toString(), value));
      }
      throw const AppFailure(.invalid);
    } on AppFailure {
      rethrow;
    } on FirebaseFunctionsException catch (error) {
      final message = error.message?.trim();
      debugPrint(
        'callable $name ${error.code}: '
        '${message == null || message.isEmpty ? '(no message)' : message}'
        '${error.details == null ? '' : ' details=${error.details}'}',
      );
      throw AppFailure(
        appFailureCodeFor(error.code),
        cause: error,
        detail: message == null || message.isEmpty ? null : message,
      );
    } catch (error) {
      throw AppFailure(.failed, cause: error);
    }
  }

  static Future<dynamic> _callFirebase(
    String name,
    Map<String, dynamic>? data,
  ) {
    return FirebaseFunctions.instanceFor(region: functionsRegion)
        .httpsCallable(name)
        .call<dynamic>(data)
        .then((result) => result.data);
  }
}

AppFailureCode appFailureCodeFor(String code) {
  return switch (code) {
    'unavailable' || 'deadline-exceeded' => .offline,
    'unauthenticated' || 'permission-denied' => .denied,
    'invalid-argument' ||
    'failed-precondition' ||
    'not-found' ||
    'already-exists' => .invalid,
    _ => .failed,
  };
}
