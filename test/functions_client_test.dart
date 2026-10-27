import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/models/app_failure.dart';

void main() {
  test('call returns the function payload', () async {
    final client = FunctionsClient(
      call: (name, data) async {
        expect(name, 'loadPlayback');
        expect(data, {'runId': 'run_1'});
        return {'runId': 'run_1', 'status': 'active'};
      },
    );

    final payload = await client.call('loadPlayback', {'runId': 'run_1'});
    expect(payload['status'], 'active');
  });

  test('a payload that is not a map is invalid', () async {
    final client = FunctionsClient(call: (name, data) async => 'nope');

    expect(
      () => client.call('loadPlayback'),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.code,
          'code',
          AppFailureCode.invalid,
        ),
      ),
    );
  });

  test('an unknown error is failed', () async {
    final client = FunctionsClient(
      call: (name, data) async => throw StateError('down'),
    );

    expect(
      () => client.call('loadPlayback'),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.code,
          'code',
          AppFailureCode.failed,
        ),
      ),
    );
  });

  test('function codes map onto AppFailure', () {
    expect(appFailureCodeFor('unavailable'), AppFailureCode.offline);
    expect(appFailureCodeFor('deadline-exceeded'), AppFailureCode.offline);
    expect(appFailureCodeFor('permission-denied'), AppFailureCode.denied);
    expect(appFailureCodeFor('unauthenticated'), AppFailureCode.denied);
    expect(appFailureCodeFor('invalid-argument'), AppFailureCode.invalid);
    expect(appFailureCodeFor('not-found'), AppFailureCode.invalid);
    expect(appFailureCodeFor('internal'), AppFailureCode.failed);
    expect(const AppFailure(.offline).phrase, 'No connection');
  });
}
