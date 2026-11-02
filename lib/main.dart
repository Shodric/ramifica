import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:ramifica/app/app.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/repositories/catalog_repository.dart';
import 'package:ramifica/data/repositories/firebase_auth_gateway.dart';
import 'package:ramifica/data/repositories/pending_story_binding.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/firebase_options.dart';
import 'package:web/web.dart' as web;

/// Local demo: `flutter run --dart-define=EMULATOR=true -d chrome`.
const emulator = bool.fromEnvironment('EMULATOR');
const allEmulators = bool.fromEnvironment('FIREBASE_EMULATORS');
const localProject = String.fromEnvironment(
  'FIREBASE_PROJECT_ID',
  defaultValue: 'demo-ramifica',
);

/// Public reCAPTCHA Enterprise site key. The secret stays in Firebase
/// App Check, not in this repo. Override with
/// `--dart-define=APP_CHECK_SITE_KEY=...`.
const _appCheckSiteKey = String.fromEnvironment(
  'APP_CHECK_SITE_KEY',
  defaultValue: '6LfuVAkuAAAAAKGGjyADqCGQJg171YeUVmoafuve',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await Firebase.initializeApp(
    options: allEmulators
        ? const FirebaseOptions(
            apiKey: 'fake-api-key',
            appId: '1:123:web:demo',
            messagingSenderId: '123',
            projectId: localProject,
            storageBucket: '$localProject.appspot.com',
            authDomain: 'localhost',
          )
        : DefaultFirebaseOptions.web,
  );
  if (allEmulators) {
    await FirebaseAuth.instance.useAuthEmulator('127.0.0.1', 9099);
    FirebaseFirestore.instance.useFirestoreEmulator('127.0.0.1', 8080);
    FirebaseStorage.instance.useStorageEmulator('127.0.0.1', 9199);
  } else {
    await _activateAppCheck();
  }
  if (emulator || allEmulators) {
    // Functions emulator only (local code). Auth, Firestore, and Storage
    // stay real so login and drafts persist across runs. (Real Firestore
    // rejects Auth-emulator tokens, hence Auth is not emulated.)
    FirebaseFunctions.instanceFor(region: functionsRegion)
        .useFunctionsEmulator('localhost', 5001);
  }
  await configureFirebaseAuth();
  runApp(
    RamificaApp(
      authRepository: createFirebaseAuthRepository(),
      pendingStoryStore: createPendingStoryStore(),
      runRepository: createFirebaseRunRepository(),
      catalogRepository: createFirebaseCatalogRepository(),
    ),
  );
}

/// App Check immediately after [Firebase.initializeApp], before Auth,
/// Firestore, or Functions. Production uses reCAPTCHA Enterprise.
/// Localhost and debug builds use the debug provider: a placeholder site
/// key would fail every callable, and the production key must not list
/// localhost. `web/index.html` sets the debug token on localhost.
Future<void> _activateAppCheck() async {
  final WebProvider? provider;
  if (_debugAppCheck) {
    provider = WebDebugProvider();
  } else if (_appCheckSiteKey.isNotEmpty) {
    provider = ReCaptchaEnterpriseProvider(_appCheckSiteKey);
  } else {
    provider = null;
  }
  if (provider == null) return;
  try {
    await FirebaseAppCheck.instance.activate(providerWeb: provider);
  } catch (_) {}
}

/// Debug attestation wherever a production reCAPTCHA key must not run.
bool get _debugAppCheck => kDebugMode || emulator || _localhost;

bool get _localhost {
  if (!kIsWeb) return false;
  final host = web.window.location.hostname;
  return host == 'localhost' || host == '127.0.0.1';
}
