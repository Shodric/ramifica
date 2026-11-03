# Getting started

Install, configure, and run Ramifica locally. For the daily workflow once you are set up, see [Development](development.md).

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Flutter | 3.47.8 | Managed with FVM; see `.fvmrc`. |
| Dart | Ships with Flutter | SDK constraint is `^3.13.7`. |
| Node | 22 | Backend (`functions/`) and relay (`realtime/`). |
| Firebase CLI | Latest | `npm install -g firebase-tools`. |
| Chrome | Latest | Local run target and PWA testing. |

Check yours:

```sh
fvm flutter --version
node --version
firebase --version
```

## Clone and install

```sh
git clone https://github.com/Shodric/ramifica.git
cd ramifica
fvm flutter pub get
npm --prefix functions ci
npm --prefix realtime ci
```

## Run the client

The fastest loop runs the client against the Functions emulator, with real Auth, Firestore, and Storage so sign-in and drafts persist:

```sh
fvm flutter run --dart-define=EMULATOR=true -d chrome
```

A full-local mode connects Auth, Firestore, and Storage to their emulators instead:

```sh
firebase emulators:start
fvm flutter run --dart-define=FIREBASE_EMULATORS=true -d chrome
```

Emulator ports are in `firebase.json`: Auth `9099`, Functions `5001`, Firestore `8080`, Hosting `5000`, Storage `9199`.

To run a release build locally:

```sh
fvm flutter build web
firebase hosting:channel:deploy preview --project meta-ramifica
```

## Configure AI generation (optional for playing, required for creating)

Without provider credentials the app plays stories, but every generation fails explicitly with a reason. To create with AI:

```sh
cp -n functions/.env.example functions/.env.local
cp -n functions/.secret.local.example functions/.secret.local
```

Put `META_API_KEY` and `OPENROUTER_API_KEY` in `functions/.secret.local`, choose models in `functions/.env.local`, then start the Functions emulator:

```sh
npm --prefix functions run build
firebase emulators:start --only functions --project meta-ramifica
```

Git ignores both local files. Full details, including production secrets and the live dictation relay, are in [AI configuration](ai-configuration.md).

## Project pointers

- Firebase project id: `meta-ramifica`, region `us-central1`.
- Web entry: `lib/main.dart`; routes are listed in [Architecture](architecture.md#routes).
- Backend entry: `functions/src/index.ts`; only the callables exported there are deployed.
- The relay is a separate deployment: [realtime/README.md](../realtime/README.md).

Next: [Development](development.md) for conventions and workflow, [Testing](testing.md) for the suites, [Troubleshooting](troubleshooting.md) when something breaks.
