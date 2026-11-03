import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/repositories/create_repository.dart';

void main() {
  test('one-shot sends the whole body in a single request', () async {
    final seen = <http.BaseRequest>[];
    final client = MockClient((request) async {
      seen.add(request);
      return http.Response('', 200);
    });

    await putVideoBytesToUrl(
      url: 'https://upload.invalid/media',
      method: 'POST',
      resumable: false,
      contentType: 'video/mp4',
      bytes: const [1, 2, 3],
      client: client,
    );

    expect(seen, hasLength(1));
    expect(seen.single.method, 'POST');
    expect(seen.single.headers['Content-Type'], 'video/mp4');
  });

  test('resumable sends 1 MiB chunks with ranges and progress', () async {
    final ranges = <String?>[];
    final ticks = <double>[];
    final client = MockClient((request) async {
      final range = request.headers['Content-Range'];
      ranges.add(range);
      // Last chunk finalizes; the rest resume.
      if (range != null &&
          range.endsWith('/2097664') &&
          range.startsWith('bytes 2097152-')) {
        return http.Response('{}', 200);
      }
      return http.Response('', 308);
    });

    final bytes = List<int>.filled(2 * 1024 * 1024 + 512, 7);
    await putVideoBytesToUrl(
      url: 'https://upload.invalid/session',
      method: 'PUT',
      resumable: true,
      contentType: 'video/mp4',
      bytes: bytes,
      onProgress: ticks.add,
      client: client,
    );

    final total = bytes.length;
    expect(ranges, [
      'bytes 0-1048575/$total',
      'bytes 1048576-2097151/$total',
      'bytes 2097152-2097663/$total',
    ]);
    expect(ticks.last, 1);
    expect(ticks.length, 3);
    expect(ticks[0], closeTo(1048576 / total, 1e-9));
  });

  test('an unreadable final chunk is tolerated for trigger confirm', () async {
    final ticks = <double>[];
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) return http.Response('', 308);
      throw http.ClientException('Failed to fetch');
    });

    await putVideoBytesToUrl(
      url: 'https://upload.invalid/session',
      method: 'PUT',
      resumable: true,
      contentType: 'video/mp4',
      bytes: List<int>.filled(1024 * 1024 + 8, 3),
      onProgress: ticks.add,
      client: client,
    );

    expect(calls, 2);
    expect(ticks.last, 1);
  });

  test('an unreadable intermediate chunk still fails', () async {
    final client = MockClient((request) async {
      throw http.ClientException('Failed to fetch');
    });

    final failure = await putVideoBytesToUrl(
      url: 'https://upload.invalid/session',
      method: 'PUT',
      resumable: true,
      contentType: 'video/mp4',
      bytes: List<int>.filled(2 * 1024 * 1024 + 8, 3),
      client: client,
    ).then<AppFailure?>(
      (_) => null,
      onError: (Object e) => e as AppFailure,
    );

    expect(failure, isNotNull);
  });

  test('a refused chunk carries the status and server body', () async {
    final client = MockClient((request) async {
      return http.Response('{"error": {"message": "bad range"}}', 400);
    });

    final failure = await putVideoBytesToUrl(
      url: 'https://upload.invalid/session',
      method: 'PUT',
      resumable: true,
      contentType: 'video/mp4',
      bytes: const [1, 2, 3],
      client: client,
    ).then<AppFailure?>((_) => null, onError: (Object e) => e as AppFailure);

    expect(failure, isNotNull);
    expect(failure!.hint, contains('400'));
    expect(failure.hint, contains('bad range'));
  });

  test('off-shape targets fail without network', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response('', 200);
    });

    await expectLater(
      putVideoBytesToUrl(
        url: 'https://upload.invalid/put',
        method: 'PUT',
        resumable: false,
        contentType: 'video/mp4',
        bytes: const [],
        client: client,
      ),
      throwsA(const AppFailure(.invalid)),
    );
    await expectLater(
      putVideoBytesToUrl(
        url: 'https://upload.invalid/put',
        method: 'DELETE',
        resumable: false,
        contentType: 'video/mp4',
        bytes: const [1],
        client: client,
      ),
      throwsA(const AppFailure(.invalid)),
    );
    expect(calls, 0);
  });
}
