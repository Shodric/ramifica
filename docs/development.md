# Development

Daily workflow and conventions. The client spec is [Architecture](architecture.md); this file is about how to work in the repo.

## Branches and checks

Work on a short-lived branch off `main`. Before opening a pull request, run what CI runs:

```sh
fvm flutter analyze
fvm flutter test
npm --prefix functions run lint
npm --prefix functions run build
npm --prefix functions test
npm --prefix realtime test
python3 .github/workflows/check_doc_links.py
```

CI runs the same on every push to `main` and every pull request (`.github/workflows/ci.yml`).

## Client conventions

- One screen is one `Bloc<Event, State>`. No Cubit. The view sends events and draws state; it never reads Firebase or applies game rules.
- Repositories are the only code that imports the Firebase SDKs. `FunctionsClient` lives in `lib/core/functions_client.dart`.
- Two event transformers cover everything: `restartable` cancels the in-flight action, `droppable` drops the next one. See [Architecture](architecture.md#layers).
- Use the dot shorthand when the context type is known (`.idle`, `.circular(999)`); keep the type name when there is no context type. See [Architecture](architecture.md#style).
- A widget used by one screen lives in that feature folder. A widget used by two or more lives in `lib/core/widgets/`.
- The client does not use `dart:io`. Browser-only code goes behind `*_web.dart` / `*_stub.dart` pairs with conditional imports.
- Screen folders and types are English (Access, Explore, Graph, Create, Profile). Public URL segments stay as documented in [Routes](architecture.md#routes).

## Backend conventions

- Functions default to `us-central1` via `setGlobalOptions` in `functions/src/index.ts`. Only the exports there are deployed: the AI callables plus `onUploadFinalized`.
- API keys live in server secrets, never in tracked files. Templates are `functions/.env.example` and `functions/.secret.local.example`.
- Adapters read configuration per request, after secrets are injected. Defaults and readers live together in `functions/src/config/ai.ts`.
- Every `ffmpeg`/`ffprobe` invocation passes `-nostdin` so a hung stdin can never stall a function.
- Unknown icon or color names fail closed to `null` on every side; `catalog.json` at the repo root is the shared reference, with mirror tests against Dart and TypeScript.

## Firestore and Storage

- Rules are `firestore.rules` and `storage.rules`. Unmatched paths are denied.
- Authoring writes go through the client persistence layer in `lib/data/persistence/`, not through callables. Business logic executes no Functions at play time.
- Story media is not readable through the Storage SDK; clients play signed URLs. The bucket CORS config is `cors.json`; reapply it after changes (see [Architecture](architecture.md#firebase)).

## Docs conventions

- Code, docs, and UI copy are English.
- Every Markdown file with relative links is checked by CI (`docs` job). External URLs are not checked, so verify those by hand.
- Behavior changes update the matching doc in the same branch: client behavior in `docs/architecture.md`, visuals in `docs/design.md`, models and credentials in `docs/ai-configuration.md`.

## Useful commands

```sh
# Client against the Functions emulator, real Auth/Firestore/Storage.
fvm flutter run --dart-define=EMULATOR=true -d chrome

# Everything against local emulators.
firebase emulators:start
fvm flutter run --dart-define=FIREBASE_EMULATORS=true -d chrome

# Backend only, with local AI credentials.
npm --prefix functions run build
firebase emulators:start --only functions --project meta-ramifica

# Dictation relay only.
npm --prefix realtime run start:local
```
