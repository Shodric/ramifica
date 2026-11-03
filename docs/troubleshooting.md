# Troubleshooting

Common failures, each with cause and fix. Setup is in [Getting started](getting-started.md); suites are in [Testing](testing.md).

## Generation fails immediately

Missing or empty provider credentials fail every generator explicitly with a reason — never a hang. Fill `META_API_KEY` and `OPENROUTER_API_KEY` in `functions/.secret.local` for the emulator, or set them with `functions:secrets:set` in production. Details are in [AI configuration](ai-configuration.md).

## Live dictation is unavailable

If the relay socket fails to open within 15 seconds or drops mid-take, the client transcribes the complete take as one WAV through `transcribeVoice` and shows "Live dictation is unavailable. The full take was transcribed." Check that the relay is reachable and that its own `META_API_KEY` is valid; the Functions key does not apply to that deployment.

## Stuck video jobs after switching providers

Finish pending jobs before switching video backends or models: the new endpoint may be unable to poll the old job IDs. A job that outlives the switch has to be regenerated.

## Blank media or blocked playback

Storage media requires readable CORS responses. Do not send `Cross-Origin-Opener-Policy` or `Cross-Origin-Embedder-Policy`: `require-corp` blocks video and images from Storage. If the bucket config drifted, reapply `cors.json` (see [Architecture](architecture.md#firebase)).

## App Check failures on localhost

`FIREBASE_APPCHECK_DEBUG_TOKEN` is set only for `localhost` and `127.0.0.1`, and the debug provider applies on localhost, in debug builds, or with `EMULATOR`. Serve the app from `http://localhost:5000` (the Hosting emulator port) so debug tokens and CORS both match.

## Rules test does nothing

`test/direct_firestore_rules_test.dart` skips silently when `RAMIFICA_RULES_EMULATOR_HOST` is unset. Start the Firestore emulator and export `RAMIFICA_RULES_EMULATOR_HOST=127.0.0.1:8080` first; any non-localhost value is rejected.

## Wrong emulator wiring

`--dart-define=EMULATOR=true` connects only Functions to its emulator; Auth, Firestore, and Storage stay on the real project. For everything local, start the emulators and use `--dart-define=FIREBASE_EMULATORS=true` instead. Ports: Auth `9099`, Functions `5001`, Firestore `8080`, Hosting `5000`, Storage `9199`.
