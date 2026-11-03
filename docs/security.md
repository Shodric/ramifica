# Security

Access control and trust boundaries. The rules are the contract: `firestore.rules` and `storage.rules`. The path layout is [Data model](data-model.md); Firebase specifics are [Architecture](architecture.md#firebase).

## Rules deny by default

Unmatched paths are denied. The split:

| Who | Reads | Writes |
|---|---|---|
| Player (signed in) | Published stories, the active publication's map, visited node bodies, visible stats, own progress | Own progress, own follows, one stats counter +1 per choice |
| Author | Own drafts including nodes, prompts, and staged publications | Own drafts, with `revision` +1 per write |

Draft bodies, other accounts' progress, and unvisited secret bodies stay isolated. `sagas` and `campaigns` accept no client writes; `follows/{uid}` is owner-only.

## App Check

The client activates App Check in `lib/main.dart` right after `Firebase.initializeApp`, before Auth, Firestore, or Functions. Production uses reCAPTCHA Enterprise with the site key in that file; override it with `--dart-define=APP_CHECK_SITE_KEY=...`. Localhost, debug builds, and `EMULATOR` use the debug provider instead. `web/index.html` sets `FIREBASE_APPCHECK_DEBUG_TOKEN` only when the hostname is `localhost` or `127.0.0.1`. Callables set `enforceAppCheck` whenever they are not on the emulator. The reCAPTCHA secret is registered in Firebase App Check, not in the repo or in Secret Manager.

## Auth

Sign-in is required to play and to create (`lib/features/access/access_bloc.dart`, `lib/data/repositories/auth_repository.dart`):

- Google uses a popup first. A blocked popup, or an installed iOS PWA (detected in `lib/data/repositories/auth_redirect_web.dart`), uses redirect; the result is completed when the bloc starts.
- Email and password: sign-up requires an 8-character minimum; sign-in rejects an empty password.
- Password reset always shows "If that email has an account, we sent a link." A missing account gets that same notice.
- The session uses `Persistence.LOCAL`, so it survives closing the tab. First sign-in creates `users/{uid}` with the profile fields.

## Uploads and media

`uploads/{uid}/` is create-only: the signed-in creator may write one `mp4` or `mov` under 100 MB. No client read, update, or delete. `onUploadFinalized` validates the object and re-encodes it; `stories/**` admits no client SDK access at all — playback uses signed URLs only.

## Secrets

`META_API_KEY` and `OPENROUTER_API_KEY` live in Secret Manager in production and in `functions/.secret.local` (git-ignored) for the emulator. Only the templates (`functions/.secret.local.example`) are tracked. Keys never go in Flutter code, `--dart-define`, or tracked files. Full details are in [AI configuration](ai-configuration.md).

## Non-goal

Accounts can write their own progress; there is intentionally no anti-cheat. Another account's drafts, progress, and secret bodies remain isolated.
