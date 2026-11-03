# Architecture

Ramifica is a Flutter web PWA. A clip plays, then pauses while a narrator asks which decision the protagonist should take. The person chooses by holding a point on the scene for one second. The run is saved.

This file is the client spec. Code, docs, and UI copy are English. Screen folders use the English names below. Public URLs keep the path segments in [Routes](#routes).

Firebase region is `us-central1`. The client does not use `dart:io`. Browser-only behavior (Hosting, service worker, CORS, App Check) is specified here only where it constrains the client.

## Style

When the context type is already known, use a dot shorthand. Do not repeat the type.

```dart
switch (status) {
  .idle => RamificaColors.textSecondary,
  .running => RamificaColors.nodeActive,
  .ready => RamificaColors.hotspot,
  .failed => RamificaColors.error,
}

borderRadius: .circular(999)
border: .all(color: RamificaColors.glassBorder)
padding: const .symmetric(horizontal: 10, vertical: 4)
this.padding = const .all(16)
this.borderRadius = const .all(.circular(16))
```

A value with no context type keeps its type name. `expect` matchers are untyped, so `AppFailureCode.offline` stays written out there. An unnamed constructor such as `Color(0xFF00F2FE)` or `Offset(0, 2)` keeps its type name too.

## Build

Ship with `flutter build web`. That compile is dart2js and the CanvasKit renderer. `flutter build web --wasm` uses Skwasm where the browser supports it and falls back to CanvasKit. Skwasm wants cross-origin isolation. Do not send `Cross-Origin-Opener-Policy` or `Cross-Origin-Embedder-Policy`. `require-corp` would block video and images from Storage.

CanvasKit draws text on a canvas, so a hold does not select text by accident.

The web worker keeps downloaded media in browser storage. See [Prefetch](#prefetch).

## Web shell

`web/index.html` is the Flutter host. `viewport-fit=cover` lets the engine read the safe area. The body is not padded, so the video stays edge to edge and each screen insets its own chrome.

`html` and `body` are `100dvh`, with `overscroll-behavior: none` and background `#131318`. `body` sets `touch-action: none` and `user-select: none` (including the WebKit prefixes) so a hold does not become a scroll or a selection. `video` sets `pointer-events: none`. `contextmenu` is cancelled. `FIREBASE_APPCHECK_DEBUG_TOKEN` stays limited to `localhost` and `127.0.0.1`, and that script stays before `flutter_bootstrap.js`. A capture-phase `pointerdown` listener records `window.__ramificaGestured`, so a login or link tap before Feed exists still counts as the first gesture.

`web/manifest.webmanifest` is the only manifest. Name `Ramifica`, `start_url` `/?source=pwa`, scope `/`, `display` standalone, `orientation` portrait, colors `#131318`. Icons are the existing `icons/Icon-*.png` files. `/?source=pwa` parses as Feed because the parser uses the path.

`web/flutter_bootstrap.js` is the build template. `flutter run` registers `sw.js?media-only=1`, which leaves the development shell and hot reload on the network. A release build registers the full `sw.js?v=` plus the build version. Flutter still emits `flutter_service_worker.js`. This app does not register it. Local Storage CORS expects the app at `http://localhost:5000`, as in `.vscode/launch.json`.

`web/sw.js` uses Workbox 7.3.0 from the Workbox CDN for the release shell and imports the local `media_cache.js` in both modes. Media caching continues if the Workbox CDN is unavailable.

| Request | What the worker does |
|---|---|
| Document navigation, including `/story/**` | Network first, then the cached shell. `/story/**` opens the SPA with generic Ramifica share metadata. |
| JS, wasm, and fonts in the precache list | Precache. The revision is the `v` query on the worker script, so the next build fetches a new shell. |
| Images, including PNG, JPEG, WebP and extensionless CORS responses | Cache first; refresh mutable URLs after one hour. Up to 300 entries. |
| Audio and video | Save the bytes that the player actually consumes. Once ranges cover the complete file, store it locally and serve subsequent byte ranges from that copy. Up to 100 audio and 30 video entries. |
| `cloudfunctions.net` and `cloudfunctions.googleapis.com` | Network only. |

The worker keeps incomplete media ranges in IndexedDB, bounded by the same entry limits; it never downloads the rest of a video solely to fill the cache. A completed, readable response goes to Cache Storage. Content-hashed URLs are reused for 30 days; mutable audio/video URLs are refreshed on a later playback after one hour. Requests with authorization headers, credentialed CORS requests, errors and `no-store` responses are not cached. Signed URLs are stored with their complete query string. Byte ranges require a readable CORS response; otherwise playback falls back to the normal network request. The browser may evict local data under storage pressure. The application still needs its network services to load stories and progress.

The release precache list is the CanvasKit shell (full and Chromium, not Skwasm), `main.dart.js`, `flutter.js`, the icon PNGs, the four WOFF2 files, and the manifest. The document itself is not precached.

## Firebase

Project id: `meta-ramifica`. Config lives in `firebase.json` and `.firebaserc`.

Emulators: Auth `9099`, Functions `5001`, Firestore `8080`, Hosting `5000`, Storage `9199`. One project mode. The UI is on.

Hosting serves `build/web` with `cleanUrls`. Every path, including `/story/**`, rewrites directly to `/index.html`. Share metadata is generic and never includes a private scene. `index.html`, `sw.js`, `media_cache.js`, `manifest.json`, and `manifest.webmanifest` are `Cache-Control: no-cache`. `wasm`, `woff2`, `png`, `webp`, and `svg` are cached for one year, immutable. Do not send COOP or COEP headers.

The first `pointerdown` anywhere sends `UserGestured`: it clears `autoMuted`, resumes the audio context, and resumes a clip parked by hiding. It never overrides a manual mute. `FeedView` also reads `window.__ramificaGestured` on start, so a login tap counts. Hiding the browser tab sends `AppHidden`, which parks the video until the next tap; becoming visible again never resumes on its own. Switching tabs uses `TickerMode` instead and does resume.

Bucket CORS is `cors.json`: `GET` and `HEAD` from `https://meta-ramifica.web.app`, `https://meta-ramifica.firebaseapp.com`, and `http://localhost:5000`. `gs://meta-ramifica.firebasestorage.app` (`US-CENTRAL1`) already has this config. Reapply it with:

```bash
gcloud storage buckets update gs://meta-ramifica.firebasestorage.app --cors-file=cors.json
```

Firestore and Storage rules are `firestore.rules` and `storage.rules`. Unmatched paths are denied. Players do not read `nodes` directly. Story media is not readable through the Storage SDK. A signed-in creator may upload one `mp4` or `mov` under `uploads/{uid}/`, under 100 MB.

Functions default to `us-central1` (`setGlobalOptions` in `functions/src/index.ts`). Callables enforce App Check when they are added. The client activates App Check right after `Firebase.initializeApp`: reCAPTCHA Enterprise with the site key in `lib/main.dart` (override with `--dart-define=APP_CHECK_SITE_KEY`), and the debug provider on localhost, in debug, or with `EMULATOR`. The reCAPTCHA secret is registered in Firebase App Check, not in the repo or in Secret Manager. `web/index.html` sets `FIREBASE_APPCHECK_DEBUG_TOKEN` only when the hostname is `localhost` or `127.0.0.1`.

## Layers

Each screen is a `Bloc<Event, State>`. The view sends an event and draws the state that comes back. Do not use Cubit.

| Layer | What it is | May | May not |
|---|---|---|---|
| Model | Immutable class and repository | Read and write the stored model. Parse JSON. | Import widgets. Choose a screen. |
| Bloc | `Bloc<Event, State>` | Take an event. Call repositories. Emit a new state. Turn an error into a short phrase. | Call Firestore, Auth, or Functions directly. Import widgets. Mutate the previous state. |
| View | Widget with `BlocBuilder` | Draw the state. Send events with `add`. | Read Firebase. Apply game rules. Store business state. |

A repository is model. It is the only code that imports the Firebase SDKs. `FunctionsClient` lives in `lib/core/functions_client.dart`. Repositories call it.

The view does not use `setState` for business data. A `BlocListener` is for a one-shot effect: open Feed, go to the map, clear the prefetch queue. A bloc does not import Flutter.

Two event transformers are enough:

| Transformer | When | Example |
|---|---|---|
| `restartable` | A new action cancels the one in flight. | Open another story while the first is still loading. |
| `droppable` | If one is in flight, drop the next. | A second `HoldCompleted` while Feed is `committing`. |

The one-second circle is not an event per frame. The view animates it with an `AnimationController`. Pointer down sends `HoldStarted`. Releasing early sends `HoldCancelled`. Reaching one second sends `HoldCompleted`. The handler creates a `requestId` and, if the network fails, retries `commitChoice` with the same id. The server does not advance twice.

## Folders

```
lib/
  main.dart                     // usePathUrlStrategy(), then runApp.
  app/                          // Shell: theme, routes, five tabs. Does not know a story.
    app.dart                    // MaterialApp. AuthBloc. Jump between Access and Shell.
    routes.dart                 // Path routes.
    theme.dart                  // Color tokens and the two font families.
    shell_bloc.dart             // Active tab and open story. Lives above the IndexedStack.
    shell_event.dart            // TabSelected, StoryOpenRequested.
    shell_state.dart            // Tab index and open storyId.
    shell_view.dart             // Tab bar and IndexedStack. Pauses Feed when that tab is left.
  core/                         // Shared by two or more screens. No game rules.
    widgets/
      story_card.dart           // Cover, title, author. Explore and Profile.
      author_row.dart           // Photo, name, handle, Follow.
      ending_badge.dart         // Ending type: open, tragic, or secret.
      lock_mark.dart            // Lock, no title. Map and saga.
      glass_panel.dart          // Blurred panel. Sheets and bars.
      status_pill.dart          // idle, running, ready, failed. Create.
      empty_state.dart          // One sentence and, when needed, a button.
      failure_text.dart         // The phrase the bloc already emitted, with retry.
    prefetcher.dart             // Warms mp4 in the HTTP cache. Not a bloc.
    web_audio.dart              // AudioContext and decodeAudioData for the narrator.
    functions_client.dart       // Calls Cloud Functions.
  features/                     // One folder per screen. Bloc, events, state, view.
    access/                     // Google or email, before the tabs.
      access_bloc.dart          // signedOut, signingIn, signedIn, and the story id from the link.
      access_event.dart         // SignInWithGoogleRequested, SignInWithEmailRequested, PasswordResetRequested, SignOutRequested.
      access_state.dart         // Phase, pending storyId, error phrase.
      access_view.dart          // Google button, email fields, password reset. No tab bar.
    feed/
      feed_bloc.dart            // Run phase. Lives above the tabs.
      feed_event.dart           // StoryOpened, StorySwiped, UserGestured, AppHidden, PauseReached, MuteToggled, VoiceFinished, HoldStarted, HoldCancelled, HoldCompleted, OtherPathRequested, MapRequested.
      feed_state.dart           // Phase, playback, mute, autoMuted, endingSpeaking, hiddenPaused, hold zone. No 0-to-1 progress.
      feed_view.dart            // Stack: video, chip, zones, portal, subtitle, ending card.
      node_video.dart           // Paints the mp4. Reports the first frame and PauseReached (ended).
      story_chip.dart           // Title and author during the clip. Hidden while the narrator speaks.
      subtitle.dart             // ttsText while muted.
      choice_zone.dart          // Option circle and label. Pointer down, up, and cancel.
      hold_portal.dart          // One-second circle with the inline blur. The view animates it.
      ending_card.dart          // Ending name, see map, try another path.
      mute_button.dart          // Mutes the clip and the narrator.
    explore/
      explore_bloc.dart         // Both lists, the campaign, and the search text.
      explore_event.dart        // CatalogRequested, CatalogTabSelected, QueryChanged, StoryStartRequested.
      explore_state.dart        // For you or Following, cards, error phrase.
      explore_view.dart         // Scrolling column. The tab bar belongs to the shell.
      campaign_card.dart        // StoryCard plus the brand label.
    graph/
      graph_bloc.dart           // Stubs, open sheet, and the you-are-here node.
      graph_event.dart          // GraphRequested, NodeSelected, ContinueRequested, ApproachRequested, RewindRequested.
      graph_state.dart          // Stubs, currentNodeId, selectedId, error phrase.
      graph_view.dart           // Canvas plus the sheet.
      graph_canvas.dart         // Pan, zoom, and edges. CustomPainter.
      node_sheet.dart           // Visited node, with percents.
    create/
      create_bloc.dart          // Draft, open node, and the job in flight.
      create_event.dart         // DraftRequested, generations, approvals, ZonesSaved, PublishRequested.
      create_state.dart         // Story, nodes, open node, job, and what is missing.
      create_view.dart          // Draft canvas plus the inspector.
      draft_canvas.dart         // Draft nodes and arrows, secrets included.
      node_inspector.dart       // Prompts, S, E, clip, line, voice, and StatusPill.
      frame_compare.dart        // S and E of the same node.
      zone_marker.dart          // The finger marks the circle on the last frame.
      publish_bar.dart          // Publish, and the list of what is missing.
    profile/
      profile_bloc.dart         // Own profile or another author's, from authorId.
      profile_event.dart        // ProfileRequested, name changes, FollowToggled, PlayFromStartRequested.
      profile_state.dart        // Data, follow, sagas, endings, error phrase.
      profile_view.dart         // Header, lists, and the two disabled blocks.
      profile_header.dart       // Photo, name, handle, and locale when it is the signed-in person.
      saga_list.dart            // Saga stories. A locked story is a lock.
      ending_list.dart          // Endings unlocked by the person who is looking.
      later_block.dart          // Live room and guild. No network.
  data/                         // JSON and Firebase. Widgets do not import this. Blocs do.
    models/
      user.dart                 // users/{uid}: name, handle, photo, locale, providers.
      playback.dart             // What loadPlayback returns.
      story_summary.dart        // Explore card. No nodes.
      campaign_summary.dart     // Active campaign: story and brand.
      graph_stub.dart           // Id, lock, and, if visited, title, thumbnail, and counts.
      draft_story.dart          // Story with status draft.
      draft_node.dart           // Draft node, secrets included.
      profile.dart              // Author header.
      saga_progress.dart        // Saga order and which story is unlocked.
      app_failure.dart          // offline, denied, invalid, failed.
    repositories/
      auth_repository.dart      // Session, users/{uid} create, password reset, sign out.
      run_repository.dart       // startRun, loadPlayback, commitChoice.
      catalog_repository.dart   // Published stories and active campaigns.
      follow_repository.dart    // follows/{uid}/authors.
      graph_repository.dart     // graphStubs, rewindRun, playApproach.
      create_repository.dart    // Nodes, generations, uploads/, zones, delete, publish.
      profile_repository.dart   // Profile, sagas, unlocked endings.
```

A widget used by one screen lives in that feature. A widget used by two screens lives in `core/widgets/`.

Issue titles that still say Acceso, Explorar, Grafo, Crear, or Perfil mean the English types Access, Explore, Graph, Create, and Profile.

## What stays alive

| Object | Created | Why it survives a tab change |
|---|---|---|
| `AuthBloc` | Above the whole app | The session decides whether there is an app. |
| `ShellBloc` | Above the tabs | The tab and the open story. |
| `Prefetcher` | Next to `FeedBloc`, as a Dart class | Warmed mp4 files and decoded voices stay when the person opens Explore. It is not a bloc. It has no events. |
| `FeedBloc` | Above the `IndexedStack` | The run and the player phase survive a tab change. |

Other blocs are created with `BlocProvider` on their tab.

`ShellView` is one `IndexedStack` of the five tabs. The router keeps that page mounted and writes the path, so changing tabs does not recreate Feed. `TickerMode` stops Feed's tickers while another tab is selected. Coming back stays on the same phase.

On a signed-in feed route, the shell sends `StoryOpened` once. `FeedBloc` lives above the shell. It calls `startRun`, then `loadPlayback` for that run. `startRun` returns `runId`, `storyId`, and `status` (`active` or `ended`). The client does not send `restart` from this event. An `active` playback enters `playing`. An `ended` playback enters `ending`. An `AppFailure` enters `failed` with that phrase. `StoryOpened` is restartable. While the same story is already `playing`, `speaking`, `window`, `holding`, `committing`, or `ending`, opening that feed route again does not send another `StoryOpened`. The repository methods so far are `startRun`, `loadPlayback`, and `commitChoice`.

`StorySwiped` draws another published story at random, excluding the current one, and opens it with the same resume rule (`CatalogRepository.publishedStoryIds`, drawn in memory in this slice). It is only accepted from `playing` or with the ending card visible (`ending` without `endingSpeaking`); speaking, window, holding, committing, and the closing line ignore it. With no other story, or with no catalog, it is ignored. A catalog failure keeps the current clip. `StorySwiped` is restartable. When the open story changes, the view moves the route to `/story/{id}` so the shell and the URL follow; the shell's same-story guard skips any reload.

 While `playing`, `FeedView` stacks `NodeVideo`, `StoryChip`, and `MuteButton`. The mp4 starts muted (`autoMuted`) so the browser can autoplay, with `playsinline` and no native controls. `MuteToggled` flips `muted` and clears `autoMuted`. Turning sound on resumes the audio context from that tap. `NodeVideo` reports the first frame. Its `ended` event sends `PauseReached`, which moves `playing` to `speaking` and leaves the last frame up. The chip fades out over 200 ms. The voice file is decoded when the node opens. With sound, Web Audio plays it and hides the line. While muted, `ttsText` sits in the lower third for `ttsDurationSeconds`. `VoiceFinished` then enters `window`. The window shows one `ChoiceZone` per exit — the author's picked icon inside the ring, its label under the ring — and stays open until the player holds one. A pointer down sends `HoldStarted`. `HoldPortal` grows from that point for one second, filled with the current node's `videoFrameLastBlurData`. Zones map 0..1 frame coordinates through the 9:16 cover rect, and a full-screen release catcher ends the tracked pointer's hold anywhere; other fingers cannot cancel it. Releasing early sends `HoldCancelled` and the circle shrinks back to the window. `HoldCompleted` seals the hold, keeps the portal full, and calls `commitChoice` with a fresh `requestId`. A lost network sends the same `requestId` once more. An `invalid` answer falls back to `loadPlayback` and continues from the real node. The destination clip then starts from its first frame, or parks on the ending when the run ended. Leaving the Feed tab pauses the clip. An `ended` run does not play the clip or the line. The first-gesture unmute comes later.

Tab order: Feed, Explore, Create (center button, no label), Map, Profile. The bar is a `NavigationBar` drawn over the body.

## Routes

Path URLs, from `usePathUrlStrategy()` in `main.dart`. No hash. Hosting rewrites every path to `/index.html`. Share URLs use the same SPA shell.

| Path | Screen | Who provides it |
|---|---|---|
| `/access` | `AccessView` | `AuthBloc`, already created above. No tab bar. |
| `/` | `ShellView` on Feed | `ShellBloc` and `FeedBloc` |
| `/story/{storyId}` | `ShellView` on Feed with that story | Same SPA, with a generic Ramifica preview. |
| `/explore` | `ShellView` on Explore | Same |
| `/graph/{storyId}` | `ShellView` on Map | Same |
| `/profile` | `ShellView` on Profile | Same |
| `/create` | `ShellView` on Create | Same |

The tabs stay one `IndexedStack`. The URL picks the tab and the story. Changing tabs updates the URL and does not recreate Feed.

An external link opens `/story/{storyId}`. With no session, the view stores the id in `sessionStorage` (`pendingStoryId`), sends `PendingStorySaved` to `AuthBloc`, and shows Access. With a session, it sends `StoryOpenRequested` to `ShellBloc`. That bloc switches to Feed and `FeedBloc` receives `StoryOpened`.

There is no guest route.

## Auth

`AuthBloc` is `features/access/access_bloc.dart`. `RamificaApp` creates it when an `AuthRepository` is passed, above `MaterialApp`. `main` calls `Firebase.initializeApp` with the web config in `firebase_options.dart`, then passes `createFirebaseAuthRepository()` and `createPendingStoryStore()`.

| Field | Values |
|---|---|
| `phase` | `signedOut`, `signingIn`, `signedIn` |
| `pendingStoryId` | The story id from the link, or null |
| `failure` | A short phrase, or null |
| `notice` | The password-reset confirmation, or null. This is not a failure. |

| Event | What it does |
|---|---|
| `SignInWithGoogleRequested` | Emits `signingIn`. Uses a popup. If the popup is blocked, or the page is an installed iOS PWA, it uses redirect. `droppable`. |
| `SignInWithEmailRequested` | Same, with email and password. `droppable`. |
| `SignUpWithEmailRequested` | Creates the account. The password needs 8 characters. `droppable`. |
| `PasswordResetRequested` | Does not change `phase`. The notice is always "If that email has an account, we sent a link." A missing account gets that same notice. `droppable`. |
| `PendingStorySaved` | Stores the id on the state and in `sessionStorage` (`pendingStoryId`). |
| `PendingStoryConsumed` | Clears that id. The shell reads it first. |
| `SignOutRequested` | Signs out. |

`AuthRepository.ensureUser` reads `users/{uid}`. If the doc is missing, it creates `displayName`, `photoUrl`, `providers`, `locale` `es-AR`, and `createdAt`. It does not write `handle`. A wrong email or password, and an email that already has an account, both use "Email or password is wrong".

`main` calls `configureFirebaseAuth` before it creates the repository. That sets `Persistence.LOCAL`, which is `browserLocalPersistence`, so the session survives closing the tab. `authDomain` is `meta-ramifica.web.app`. Hosting on that domain serves `/__/auth/`, and the password-reset email link is `https://meta-ramifica.web.app/__/auth/action`. The redirect return is read with `getRedirectResult` when the bloc starts.

`AccessView` is the column on `surface` at `/access`. It has no tab bar. The order is the title "Sign in", Continue with Google, email, password, Forgot my password, Sign in, and Create account. `FailureText` shows `failure`. The reset `notice` is secondary text. While `signingIn`, the actions are disabled. When the phase becomes `signedIn`, the view opens `/` or `/story/{id}` from `pendingStoryId`. `ShellView` then sends `StoryOpenRequested` and `PendingStoryConsumed`.

`/` and `/story/{id}` show that same column until the phase is `signedIn`. With no `AuthBloc`, they still show it, because there is no session. A story link sends `PendingStorySaved` before the form is used. `/explore`, `/graph/{id}`, `/profile`, and `/create` stay open.

## Theme

Tokens live in `app/theme.dart`. The visual spec is [design.md](design.md).

| Token | Value | Use |
|---|---|---|
| `hotspot` | `#00F2FE` | Zone, active tab, primary button, portal ring. |
| `nodeActive` | `#4FACFE` | Visited node and map edge. |
| `nodeLocked` | `#2A2A38` | Lock. |
| `surface` | `#131318` | Backgrounds. |
| `textPrimary` | `#FFFFFF` | Text. On video it gets an 8 px black shadow. |
| `textSecondary` | `#A0A0B0` | Meta. |
| `glass` | white at 12% | Bars and sheets. |
| `error` | `#FFB4AB` | Failures. |

Montserrat 700 is only for the story title, the ending name, and the screen title. Everything else is Plus Jakarta Sans 400, 600, or 700. Both families ship as build assets, subset latin and latin-ext (WOFF2), served from Hosting and cached by the service worker. The client does not request them from Google Fonts at runtime.

`GlassPanel` uses a blur and a white border at 18%.

## Core widgets

They serve more than one screen. They take data and callbacks. They have no bloc.

| Widget | Used by | Input |
|---|---|---|
| `StoryCard` | Explore, Profile | Cover, title, author, optional campaign label. `onOpen`. |
| `AuthorRow` | Explore, Profile | Photo, name, handle, whether the person already follows. `onFollow`, `onOpen`. |
| `EndingBadge` | Feed, Map, Profile | `endingType`: open, tragic, or secret. |
| `LockMark` | Map, Profile | A lock, no title. |
| `GlassPanel` | All | Container with blur and a white border at 18%. |
| `StatusPill` | Create | `idle`, `running`, `ready`, `failed`. |
| `EmptyState` | Explore, Map, Profile | One sentence and, when it applies, a button. |
| `FailureText` | All | The text the bloc already wrote. `onRetry` sends the same event again. |

The portal, the zones, and the player live in Feed. The map canvas lives in Graph. The zone marker lives in Create.

## Prefetch

`Prefetcher` creates hidden `<video preload="auto" muted>` elements for each destination URL. The browser chooses how much to request; the worker records received bytes without requesting the rest. Cap: 3 live videos (the current clip and up to two destinations). Past the cap, drop the oldest that is not the current clip.

| Priority | What | When |
|---|---|---|
| 0 | Current node mp4 and its voice `.m4a`, decoded | On entering the node. |
| — | Portal blur | Not downloaded. It is `videoFrameLastBlurData` of the current node, already in memory. |
| 1 | mp4 of each destination that is not secret | After the current clip. One or two. `HoldStarted` moves that zone's clip to the front. |

A `secret` destination is not prefetched before `commitChoice`. Do not prefetch grandchildren. Changing stories clears the queue and keeps only the new node. Signing out clears the queue too. The URLs are the ones `loadPlayback` already returned. `promote` moves one destination to the newest slot. The voice file is decoded with the narrator.

Playback files are progressive MP4, H.264, 480x854, faststart. One resolution. No HLS.

## Client persistence and privacy

`lib/data/persistence/` contains the business logic. `DocumentStore` is the narrow
Firestore adapter; tests use the same Dart writers with an atomic memory store
and with the real Firestore emulator. RunRepository and GraphRepository retain
their methods and models and share one account-scoped `ClientGameService` cache.

- `ClientDraftPersistence` creates a story and root in one batch, creates/links a
  child in one transaction, and applies an outline/scene in one transaction.
  Request IDs produce deterministic child IDs. Existing legacy keyed children
  are reused; an occupied slot is preserved. There is no pending-operation journal.
- Saving and image approval use direct transactions. Image approval compares the
  reviewed hash with the current hash. Deletion checks references against a fresh
  graph and then checks its revision inside the delete transaction.
- Each open draft has one nodes listener. Pending author edits merge by field;
  media metadata and unrelated remote changes still arrive. Creating, saving,
  approving and Apply do not re-fetch the full collection. Media polling refreshes
  only its own node. Errors preserve local edits.
- `story.revision` advances atomically for author writes and for media results.
  Publishing requires saved edits, validates the graph in Dart, stages sanitized
  projections in batches, and activates only if that revision is still current.

Publication paths are `stories/{storyId}/publications/{publicationId}`:

| Path | Reader |
| --- | --- |
| Original `stories/{id}/nodes/{node}` | Author only, including prompts and job metadata. |
| `publications/{pub}/nodes/{node}` | Author, or a player whose own progress visited the node, for the active publication only. |
| `publications/{pub}/map/{node}` | Active players. An unvisited secret contributes only its ID and `{secret:true}`. |
| `publications/{pub}/stats/{node}` | Aggregated counts, separate from authoring; secret counts require a visit. |

Staged publications are inaccessible to players. Playback documents explicitly
whitelist game fields and copy nonsecret immediate target URLs for prefetch.
Secret choices contain a target ID but no target body or URL. The author's public
name is copied onto the story at publication time. Author preview remains private.

The client commits a choice, history entry, visit and counter atomically. Only
then does it read the destination body. An ending is completed in a second,
idempotent transaction; loading an interrupted run completes it. Reward IDs,
request IDs, `lastCommit`, existing codes and append-only history are preserved.
Rewind changes the current node without deleting visits/history. A legacy run
can restore its visits from its own history before loading protected content.
Accounts can write their own progress; this intentionally does not implement
anti-cheat. Another account's drafts, progress and secret bodies remain isolated.

## Functions

Only six callables are deployed: `generateNodeText`, `proposeStoryOutline`,
`generateNodeImage`, `generateNodeVideo`, `generateNodeVoice`, `transcribeVoice`.
`onUploadFinalized` processes uploaded clips. The live dictation relay continues
in Cloud Run. API keys remain in server secrets. No business operation calls
Functions and `/story/{id}` does not invoke a function.

## Media format and editor players

`functions/src/config/ai.ts` owns the output profile: 480 × 854, vertical, 30 fps;
generated clips last 10 seconds and request 480p. Conflicting legacy overrides
fail explicitly. Images are center-cropped without distortion before hashing.
Generated clips and uploads use the same H.264/yuv420p/AAC faststart pipeline.
ffprobe checks final dimensions and measured duration. AI clips shorter than ten
seconds minus one frame fail; longer clips are trimmed. Uploads keep their duration.
Hashes and saved metadata describe the normalized files. Existing assets are
never regenerated by migration; incompatible draft media is identified for replacement.

Each local generation sets its media/node/frame and phase before saving, so
loading appears on the first tap. Persisted generation state covers reloads;
terminal failures clear it. Another take keeps the preceding take visible until
a validated replacement arrives. Image download, player buffering, generation
and measured upload progress have distinct indicators.

P3 uses `VoicePlayback` with preparation, pause, seek and observable real position,
duration, buffering and errors. Its conventional player includes a moving,
draggable slider. P4 embeds video with play/pause, seek, elapsed/total time, sound,
retry and measured dimensions. Both use the existing video_player plugin. They
initialize on the active step, pause leaving it, replace changed URLs and dispose
on removal. Opening the general preview pauses inline players; it also has
explicit controls and does not depend on autoplay.

See `docs/client-persistence-rollout.md` for migration and release ordering.

## Premise dictation

Step 0 records the premise with the FAB (tap starts, tap stops, no hold). The live path is the `asr-relay` Cloud Run service (`realtime/`, outside `functions/`): it holds `wss://api.meta.ai/v1/asr/realtime` per client socket and streams partials back. One client socket = one Meta session on that instance; reconnecting opens a new session.

Realtime flow:

- The browser sends PCM16 LE mono 24 kHz in ~80ms binary frames. There is no `seq`; the relay forwards each frame as it arrives. Frames that land before `ready` are held and flushed in order once the session is live. Each `transcript` from Meta replaces the on-screen text (`partialMode: CUMULATIVE`, whole hypothesis, not a delta), unless the transcript field is focused. `speechComplete` arrives as `final` and always replaces. A mid-take relay error closes the client socket; the take still falls back to one WAV.
- Releasing the FAB (or the 90s cap) sends `{type:'end'}`; the relay sends `endStream`, waits for `speechComplete`, delivers it as `{type:'final'}`, and closes both sockets clean. Auth is a first-frame `{type:'auth', idToken, appCheckToken}` (4401 without it); `META_API_KEY` lives in Secret Manager, never in the client.
- If the socket fails to open in 15s or drops, the client builds one WAV (RIFF header + saved PCM) and sends it once via `transcribeVoice` (`format: 'wav'`, `last: true`); that text replaces the field with hint `Live dictation is unavailable. The full take was transcribed.` A failed take shows the server message when there is one. `transcribeVoice` stays as the unary WAV fallback only — it is no longer the live path. The root node opens this as step 0 in the wizard shell, before Script. The root stepper starts with an Idea chip; child nodes do not. It is not a canvas button. The step uses the same filled inputs as Script. Title is its own field. "Tell your idea" fills the height left under the header. Continue advances without saving. Save or Apply persists the premise; decision narration remains separate in P3. Decision narration is authored separately in S3. On later steps Continue stays and names the first missing piece until the step is complete.

## Scene proposals and prompt editing

S1 uses the same `DictationController` and microphone bar as S0: live PCM,
with one complete WAV transcription when realtime is unavailable. A denied
microphone, empty take, or transcription error preserves the previous direction.
Continue calls the existing `generateNodeText` after flushing pending node
edits, then auto-applies the proposal without review UI. Apply fills empty
author fields and missing A/B branches, preserving existing choice IDs,
destinations, geometry, defaults, and the manual title/ending name. S1 scene
proposals include the narrator line, and Script requires a valid scene title
plus the line to continue.
S3 owns the decision narration: write or generate the line, approve it, then
generate and approve voice. This line is heard after the clip, just before the
player chooses an option; endings use a closing line without inventing choices.
`generateNodeText` accepts a scene or narration purpose on the existing callable.
Narration uses the closing-frame prompt and current choices as context, and only
updates `ttsText`. Editing it invalidates both approvals and the old voice.
`wizard_gates.dart` requires the approved line in S3, before the audio checks.

All author writes share a client queue. Apply first flushes pending edits and
then merges the current parent and missing children atomically. Only empty fields
and slots are filled; IDs, geometry, defaults and existing destinations survive
retries. Stable per-slot request IDs also recover legacy orphans. No full reload,
extra callable, recovery journal or separate operation collection is needed.
Scene proposals carry no icons. After a successful apply the client fires one
`decideChoiceIcon` call per unstyled choice — previous decision plus proposal
context plus the sibling label — and merges each answer only while the choice
is still unstyled, so a late answer never overwrites a manual pick. A failed
decision stays silent and the usual display fallback remains.

The text contract caps title/ending name at 40 characters, narration at 280,
choice labels at 24, and the three media prompts at 2000, with at most two choices.
Children have no proposed start prompt; endings have no proposed choices. Legacy
responses with string choices or missing prompts still parse. `catalog.json` is
the reference for mirror tests against Dart and TypeScript; TS consumers import
the same lists, and unknown names become null with the usual display fallback.

S2 edits the prompt before Generate or Another take and shows one image per
frame. S2 is root-only: children skip the step and inherit S from the parent
clip. S4 edits the video prompt; a pending provider job keeps its submitted
prompt until resumed.
For prompts and `endingName`, a null `NodeFieldChanged` value preserves the field;
a blank value clears it to null. A cleared image prompt uses `buildImagePrompt`.
Manual node edits stay local, with an Unsaved changes status, until the scene
Save button or a text/image/voice/video generation request persists them. Typing,
step changes, and leaving the scene do not schedule writes or automatic retries.
Frame approval preserves pending author edits without saving them. Apply remains
an explicit persistence action for proposals. Backend errors stay visible.

## Errors

A repository throws `AppFailure` with a code: `offline`, `denied`, `invalid`, `failed`. The bloc emits that as a short phrase. The view shows `FailureText`. The retry button sends the same event again.

## Later

Live room, guild, Jev, embeddings, and rerank have no networked bloc. Profile shows the place and calls no one. Offline play, a CDN in front of the bucket, store apps, and AV1 are out of this version.
