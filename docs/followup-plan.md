# Follow-up plan: simplify Ramifica and fix media generation/playback

Tracks what is still missing from the simplification plan, in the plan's own order. No plan changes here.

## Status baseline (2026-11-01)

- Backend `tsc` clean. New index exports only the 6 AI callables plus `onUploadFinalized`.
- `dart analyze lib` clean (fixed `glass_panel.dart` private named parameters).
- Media pipeline in `functions/src/media`: passthrough (no scale/crop/trim/reject, `-nostdin` everywhere, measured `-ss` last frame); requests 480x854, 10s, 480p, 24 fps; dims/duration stored from probe.
- ffmpeg stdin hang fixed (`-nostdin` on all calls + `encode.sh`); `-sseof` replaced by measured `-ss`; missing `-y` on last frame fixed; backend media suites green (processVideo 7, voice 4, finalized 11, retakes 2, meta 12, openrouter 13, comfy 4, ai 4, generateNodeMedia 22, generateNodeText 21, proposeOutline 9, validateStory 12).
- Provider facts (live test 2026-11-01): HeyGen via OpenRouter accepts first_frame only (`last_frame` → 400); returns 480x832@24fps for a 5s request. Accepted: 832 height ok, 24 fps ok.

## P0 — Wire the client to direct persistence (§2) — DONE 2026-11-01

- [x] Replace `create_bloc` calls to deleted callables with `draft_persistence`/`document_store` paths. Verified: grep empty, `analyze` clean, 101 unit tests green (`create_bloc`, `scene_proposal`).
- [x] Confirm `RunRepository`/`GraphRepository` delegate to `ClientGameService`; no flow (Explore, map, profile) hits removed callables at runtime. Verified: both repos delegate to `ClientGameService.shared` (real Firestore + uid); feed/graph call repository methods only.
- [x] Verify `story.revision` increments on media results and publish requires Save when dirty. Verified: all media writes go through `draftTransaction`/`writeMedia` (+1 atomically); save-guard kept in bloc.
- [x] Review and track untracked files: `video_picker*.dart`, `media/draftWrites.ts`, `data/persistence/`, `test/support/`. Verified: nothing untracked left.
- [x] Confirm `web/index.html`/`sw.js` changes (`/story/{id}` opens the SPA directly). Verified: `routes.dart` maps `/story/{id}` to `FeedLocation`; hosting rewrites `**` to index.

## P1 — Prove the media spec against the real provider (§3)

- [ ] End-to-end 10s/480p HeyGen clip. Proven so far: 5s/480p/9:16/24fps clip returned 480x832@24fps, 5.17s ($0.05, `/tmp/heygen_test_5s.mp4`). Open: 10s run + `last_frame` unsupported by the integration (first_frame only).
- [x] Confirm `ai.ts` defaults suffice in production (no `env` block in `firebase.json`) or set non-secret vars. Decided: request values are hints only, no enforcement; defaults ship in code.
- [x] Surface drafts with incompatible media for replacement; keep existing files untouched, no paid calls during migration. Moot: passthrough accepts any provider dims, nothing is incompatible anymore.

## P2 — Players and generation indicators (§4) — DONE 2026-11-01

- [x] Navigation with open players: node/step/screen change pauses and disposes; narration never plays behind video or global preview. Done: P5 pauses + disposes off-step (pause-only while generating), P4 stops off-step, child screen deactivates both; `analyze` clean, 101 unit tests green.
- [x] P5 initializes on enter, new URL loads without screen reload, no autoplay. Done: reload-in-place on take URL, tap-only play, seek/elapsed/total/volume/buffering/error/retry + real size/duration.
- [x] Credential-less or terminal failure ends `pending` with a reason; never hangs. Done: video no-creds → failed with reason, poll-expiry → `deadline-exceeded`, finish failures via guarded `failVideo`; voice/upload failures record `mediaError`. Backend suites green (generateNodeMedia 26, generateNodeVoice 9, onUploadFinalized 12, retakes 2, ai 4).

## P3 — Tests and rollout (§5) — DONE 2026-11-01

- [x] Backend suite plus rules on emulator. 146 unit tests + rules/emulator tests green.
- [x] Deploy rules + AI functions (prunes deleted functions in prod); rotate `OPENROUTER_*` if needed. Rules live; 6 AI callables + trigger live, 12 business functions pruned; OPENROUTER key already v4.
- [x] Run `migratePublications` in inspect mode, then for real; verify old stories still play. Inspect: 3 stories, 0 updates; apply: no-op. All prod stories are drafts (nothing published to break); drafts open via direct author reads.
- [x] Ship client, force reload of old versions. `flutter build web` + hosting deploy live at meta-ramifica.web.app; fresh SW version forces tab reload on activate.
- [x] Take the timing baseline now. HeyGen 5s 480p job ~46s ($0.05); local processVideo ~1-3s; TTS direct <3s; backend suites ~7s.

## Acceptance (from the plan, with decided adjustments)

Zero business Functions; no full reloads after create/save/Apply; new media stored as returned (provider dims/fps/duration, no enforcement); 10s AI video pending live proof (5s proven); visible loading from first tap; video playable inside P5; audio with duration and working slider.
