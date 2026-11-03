# Testing

Suites and how to run them. Setup is in [Getting started](getting-started.md); CI runs everything below plus the docs link check ([ci.yml](../.github/workflows/ci.yml)).

## Client

```sh
fvm flutter analyze
fvm flutter test
```

`test/` holds unit and widget suites: blocs, views, steps, holds, feed phases, graph, explore, profile, dictation, prefetch, and the web shell. Shared helpers live in `test/support/` (`memory_document_store.dart`, `rest_document_store.dart`, `create_repository_harness.dart`, `fake_media_platform.dart`); `RestDocumentStore` is the emulator-only REST adapter that runs the production Dart writers against real Firestore rules.

## Rules against the emulator

`test/direct_firestore_rules_test.dart` exercises atomic authoring, publication, private prompts, own progress, and secret unlock against the real rules. It needs the Firestore emulator and is skipped when `RAMIFICA_RULES_EMULATOR_HOST` is unset:

```sh
firebase emulators:start --only firestore --project demo-ramifica-plan
RAMIFICA_RULES_EMULATOR_HOST=127.0.0.1:8080 fvm flutter test test/direct_firestore_rules_test.dart
```

The host must be `127.0.0.1` plus the emulator port; anything else is rejected.

## Backend

```sh
npm --prefix functions run lint
npm --prefix functions run build
npm --prefix functions test
```

`npm test` rebuilds with `tsc` first, then runs `node --test` over the compiled suites: generation, media, transcription, retakes, icons, outlines, publication validation, and config.

## Relay

```sh
npm --prefix realtime test
```

`node --test` over `realtime/server.test.js`. A fake Meta WebSocket stands in for the upstream, and auth is stubbed, so no credentials are needed.

## CI jobs

| Job | What it runs |
|---|---|
| client | `flutter analyze`, `flutter test` (3.47.8, stable) |
| functions | `npm run lint`, `build`, `test` on Node 22 |
| relay | `npm test` on Node 22 |
| docs | `check_doc_links.py`: every relative Markdown link must resolve |
