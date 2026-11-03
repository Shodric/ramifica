# Ramifica

Vertical interactive video. A clip plays, then pauses. A narrator asks which decision the protagonist should take, and you choose by holding a point on the scene for one second.

Ramifica is a Flutter web app, installed as a PWA and hosted on Firebase. Anyone can play branching stories, and anyone can author one: describe an idea, shape each scene with AI-assisted text, images, voice, and video, place the choice hotspots, and publish.

## Play

A story is a chain of vertical clips. Each clip carries the picture and sound of its scene, including dialogue when the scene has it.

At the decision point the video pauses and the clip's audio stops. An off-screen narrator asks what the protagonist should do and names the options. That voice is separate from the clip. With sound, the question is spoken. While muted, it appears as a subtitle.

You choose by holding a zone on the scene for one second. A circle grows from that point until it covers the frame. Letting go early cancels the choice. If the time to choose runs out, the story takes the default option through the same one-second transition.

The next clip starts from its first frame. The run is saved.

## Runs and the map

You can keep more than one run of the same story. A finished run stays on its ending card. Starting again from the beginning keeps the endings already unlocked.

The map shows where you have been. An unplayed branch is a lock, with no title and no image, until you reach it.

## Create

The Create tab walks an author through each scene: premise, script, frames, narration and voice, clip, and hotspots. Text, images, voice, and video are generated on the backend; the author reviews and approves every piece before it can publish. See [Creating stories](docs/creating.md).

## Quickstart

Prerequisites: Flutter 3.47.8 (via FVM), Node 22, and the Firebase CLI. Full setup is in [Getting started](docs/getting-started.md).

```sh
fvm flutter pub get
fvm flutter run --dart-define=EMULATOR=true -d chrome
```

That runs the client against the Functions emulator with real Auth, Firestore, and Storage, so sign-in and drafts persist across runs.

## Stack

- Client: Flutter web (dart2js, CanvasKit), BLoC per screen, PWA with a media-caching service worker.
- Backend: Firebase Auth, Firestore, Storage, Hosting, and Cloud Functions in `us-central1`.
- AI generation: text, images, transcription, TTS, and video through Meta and OpenRouter-backed providers. See [AI configuration](docs/ai-configuration.md).
- Live dictation: a small Cloud Run WebSocket relay in `realtime/` bridges the browser to realtime speech recognition.

## Repository layout

```text
lib/        Flutter client: app shell, features, data layer.
functions/  Cloud Functions: AI generation callables and media pipeline.
realtime/   Standalone dictation relay for Cloud Run.
web/        PWA shell: manifest, bootstrap, service worker, media cache.
docs/       Product and engineering documentation.
test/       Client unit and widget tests.
tools/      Local utilities (seeding, media checks).
```

## Scripts

| Command | What it does |
|---|---|
| `fvm flutter analyze` | Static analysis for the client. |
| `fvm flutter test` | Client unit and widget tests. |
| `npm --prefix functions run lint` | ESLint for the backend. |
| `npm --prefix functions run build` | Compile the backend (`tsc`). |
| `npm --prefix functions test` | Backend tests (builds first). |
| `npm --prefix realtime test` | Relay tests. |
| `firebase emulators:start` | Local Firebase emulators. |

CI runs all of these plus a docs link check on every push to `main` and every pull request. See [.github/workflows/ci.yml](.github/workflows/ci.yml).

## Docs

- [Getting started](docs/getting-started.md): install, configure, and run.
- [Architecture](docs/architecture.md): client spec, routes, theme, layers.
- [Design](docs/design.md): visual spec and tokens.
- [Flows](docs/flows.md): user journey and system diagrams in Mermaid.
- [Creating stories](docs/creating.md): the authoring wizard, step by step.
- [Data model](docs/data-model.md): Firestore paths, publications, progress.
- [Security](docs/security.md): rules, App Check, and auth flows.
- [AI configuration](docs/ai-configuration.md): models, endpoints, credentials.
- [Media pipeline](docs/media-pipeline.md): formats, generation, uploads.
- [Development](docs/development.md): daily workflow and conventions.
- [Testing](docs/testing.md): suites and how to run them.
- [Deployment](docs/deployment.md): build, release, and operations.
- [Troubleshooting](docs/troubleshooting.md): common failures and fixes.

Code, docs, and UI copy in this repo are English. The web build is `flutter build web` (dart2js, CanvasKit).

Sign-in is required to play and to create. Google, or email and password.
