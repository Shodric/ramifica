import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:ramifica/app/app.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/repositories/catalog_repository.dart';
import 'package:ramifica/data/repositories/firebase_auth_gateway.dart';
import 'package:ramifica/data/repositories/pending_story_binding.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.web);
  await configureFirebaseAuth();
  runApp(
    RamificaApp(
      authRepository: createFirebaseAuthRepository(),
      pendingStoryStore: createPendingStoryStore(),
      runRepository: RunRepository(functions: FunctionsClient()),
      catalogRepository: createFirebaseCatalogRepository(),
    ),
  );
}
