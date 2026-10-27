import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hosting serves the app without cross-origin isolation', () {
    final config =
        jsonDecode(File('firebase.json').readAsStringSync()) as Map;
    final hosting = config['hosting'] as Map;
    expect(hosting['public'], 'build/web');
    expect(hosting['cleanUrls'], isTrue);

    expect(hosting['rewrites'], [
      {'source': '**', 'destination': '/index.html'},
    ]);

    final headers = {
      for (final entry in hosting['headers'] as List)
        entry['source'] as String:
            ((entry['headers'] as List).single as Map)['value'],
    };
    expect(headers['/index.html'], 'no-cache');
    expect(headers['/sw.js'], 'no-cache');
    expect(headers['/manifest.json'], 'no-cache');
    expect(headers['/manifest.webmanifest'], 'no-cache');
    expect(
      headers['**/*.@(wasm|woff2|png|webp|svg)'],
      'public, max-age=31536000, immutable',
    );

    final raw = File('firebase.json').readAsStringSync();
    expect(raw.contains('Cross-Origin-Embedder-Policy'), isFalse);
    expect(raw.contains('Cross-Origin-Opener-Policy'), isFalse);
    expect(raw.contains('storyPage'), isFalse);
  });

  test('emulators and the default project are fixed', () {
    final config =
        jsonDecode(File('firebase.json').readAsStringSync()) as Map;
    final emulators = config['emulators'] as Map;
    expect(emulators['auth'], {'port': 9099});
    expect(emulators['functions'], {'port': 5001});
    expect(emulators['firestore'], {'port': 8080});
    expect(emulators['hosting'], {'port': 5000});
    expect(emulators['storage'], {'port': 9199});
    expect(emulators['singleProjectMode'], isTrue);

    final rc = jsonDecode(File('.firebaserc').readAsStringSync()) as Map;
    expect((rc['projects'] as Map)['default'], 'meta-ramifica');
  });

  test('bucket CORS allows the app origins to read media', () {
    final cors = jsonDecode(File('cors.json').readAsStringSync()) as List;
    final entry = cors.single as Map;
    expect(entry['origin'], [
      'https://meta-ramifica.web.app',
      'https://meta-ramifica.firebaseapp.com',
      'http://localhost:5000',
    ]);
    expect(entry['method'], ['GET', 'HEAD']);
    expect(entry['responseHeader'], [
      'Content-Type',
      'Content-Length',
      'Content-Range',
      'Accept-Ranges',
      'Range',
    ]);
    expect(entry['maxAgeSeconds'], 3600);
  });

  test('App Check debug token is limited to localhost', () {
    final html = File('web/index.html').readAsStringSync();
    final guard = html.indexOf('location.hostname === "localhost"');
    final assignment = html.indexOf('FIREBASE_APPCHECK_DEBUG_TOKEN = true');
    expect(guard, greaterThanOrEqualTo(0));
    expect(html, contains('location.hostname === "127.0.0.1"'));
    expect(assignment, greaterThan(guard));
  });

  test('rules keep nodes and story media off the client SDK', () {
    final firestore = File('firestore.rules').readAsStringSync();
    expect(firestore, contains('match /nodes/{nodeId}'));
    expect(firestore, contains('allow write: if false'));
    expect(firestore, contains('authorId == request.auth.uid'));

    final storage = File('storage.rules').readAsStringSync();
    expect(storage, contains('match /stories/{storyId}/{allPaths=**}'));
    expect(storage, contains('allow read, write: if false'));
    expect(storage, contains("video/(mp4|quicktime)"));
    expect(
      File('functions/src/index.ts').readAsStringSync(),
      contains('us-central1'),
    );
  });
}
