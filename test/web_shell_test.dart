import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('index.html keeps the hold on the page', () {
    final html = File('web/index.html').readAsStringSync();
    expect(html, contains('viewport-fit=cover'));
    expect(html, contains('height: 100dvh'));
    expect(html, contains('overscroll-behavior: none'));
    expect(html, contains('background: #131318'));
    expect(html, contains('touch-action: none'));
    expect(html, contains('user-select: none'));
    expect(html, contains('-webkit-touch-callout: none'));
    expect(html, contains('pointer-events: none'));
    expect(html, contains('manifest.webmanifest'));
    expect(html.contains('manifest.json'), isFalse);

    final guard = html.indexOf('location.hostname === "localhost"');
    final assignment = html.indexOf('FIREBASE_APPCHECK_DEBUG_TOKEN = true');
    final bootstrap = html.indexOf('flutter_bootstrap.js');
    expect(guard, greaterThanOrEqualTo(0));
    expect(assignment, greaterThan(guard));
    expect(bootstrap, greaterThan(assignment));

    final contextMenu = html.indexOf('"contextmenu"');
    final prevent = html.indexOf('preventDefault');
    expect(contextMenu, greaterThanOrEqualTo(0));
    expect(prevent, greaterThan(contextMenu));
  });

  test('the manifest is the install contract', () {
    expect(File('web/manifest.json').existsSync(), isFalse);

    final manifest =
        jsonDecode(File('web/manifest.webmanifest').readAsStringSync()) as Map;
    expect(manifest['name'], 'Ramifica');
    expect(manifest['short_name'], 'Ramifica');
    expect(manifest['start_url'], '/?source=pwa');
    expect(manifest['scope'], '/');
    expect(manifest['display'], 'standalone');
    expect(manifest['orientation'], 'portrait');
    expect(manifest['background_color'], '#131318');
    expect(manifest['theme_color'], '#131318');

    final icons = manifest['icons'] as List;
    expect(icons, hasLength(4));
    for (final icon in icons) {
      final src = (icon as Map)['src'] as String;
      expect(File('web/$src').existsSync(), isTrue);
    }
  });

  test('the service worker caches the shell and leaves video alone', () {
    final worker = File('web/sw.js').readAsStringSync();
    expect(worker.contains('respondWith'), isFalse);
    expect(worker, contains('stopImmediatePropagation'));
    expect(worker, contains('.endsWith(".mp4")'));
    expect(worker, contains('headers.has("range")'));

    final bypass = worker.indexOf('stopImmediatePropagation');
    final precache = worker.indexOf('precacheAndRoute');
    expect(bypass, greaterThanOrEqualTo(0));
    expect(precache, greaterThan(bypass));

    expect(worker, contains('NetworkFirst'));
    expect(worker, contains('request.mode === "navigate"'));
    expect(worker, contains('CacheFirst'));
    expect(worker, contains('maxEntries: 300'));
    expect(worker, contains('maxEntries: 100'));
    expect(worker, contains('30 * 24 * 60 * 60'));
    expect(worker, contains('.endsWith(".webp")'));
    expect(worker, contains('.endsWith(".m4a")'));
    expect(worker, contains('statuses: [200]'));
    expect(worker, contains('NetworkOnly'));
    expect(worker, contains('cloudfunctions.net'));
    expect(worker, contains('cloudfunctions.googleapis.com'));
    expect(worker.contains('skwasm'), isFalse);
    expect(worker.contains('flutter_service_worker.js'), isFalse);
    expect(worker.contains('index.html'), isFalse);

    expect(
      worker,
      contains('/assets/assets/fonts/PlusJakartaSans-Regular.woff2'),
    );
    expect(
      worker,
      contains('/assets/assets/fonts/PlusJakartaSans-SemiBold.woff2'),
    );
    expect(worker, contains('/assets/assets/fonts/PlusJakartaSans-Bold.woff2'));
    expect(worker, contains('/assets/assets/fonts/Montserrat-Bold.woff2'));
    expect(worker, contains('/canvaskit/canvaskit.wasm'));
    expect(worker, contains('/canvaskit/chromium/canvaskit.wasm'));
  });

  test('release builds register sw.js and dev builds do not', () {
    final bootstrap = File('web/flutter_bootstrap.js').readAsStringSync();
    expect(bootstrap, contains('{{flutter_service_worker_version}}'));
    expect(bootstrap, contains('ramificaServiceWorkerVersion == null'));
    expect(bootstrap, contains('sw.js?v='));
    expect(bootstrap.contains('flutter_service_worker.js'), isFalse);
    expect(
      bootstrap.indexOf('_flutter.loader.load()'),
      lessThan(bootstrap.indexOf('serviceWorkerUrl')),
    );
  });
}
