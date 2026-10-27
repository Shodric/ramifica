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

There is no local file API. Prefetch uses the browser HTTP cache. See [Prefetch](#prefetch).

## Firebase

Project id: `meta-ramifica`. Config lives in `firebase.json` and `.firebaserc`.

Emulators: Auth `9099`, Functions `5001`, Firestore `8080`, Hosting `5000`, Storage `9199`. One project mode. The UI is on.

Hosting serves `build/web` with `cleanUrls`. Every path rewrites to `/index.html`. `index.html`, `sw.js`, `manifest.json`, and `manifest.webmanifest` are `Cache-Control: no-cache`. `wasm`, `woff2`, `png`, `webp`, and `svg` are cached for one year, immutable. Do not send COOP or COEP headers.

`/story/**` is not rewritten to a function until `storyPage` is deployed. A rewrite to a missing function would break that path.

Bucket CORS is `cors.json`: `GET` and `HEAD` from `https://meta-ramifica.web.app`, `https://meta-ramifica.firebaseapp.com`, and `http://localhost:5000`. `gs://meta-ramifica.firebasestorage.app` (`US-CENTRAL1`) already has this config. Reapply it with:

```bash
gcloud storage buckets update gs://meta-ramifica.firebasestorage.app --cors-file=cors.json
```

Firestore and Storage rules are `firestore.rules` and `storage.rules`. Unmatched paths are denied. Players do not read `nodes` directly. Story media is not readable through the Storage SDK. A signed-in creator may upload one `mp4` or `mov` under `uploads/{uid}/`, under 100 MB.

Functions default to `us-central1` (`setGlobalOptions` in `functions/src/index.ts`). Callables enforce App Check when they are added. `web/index.html` sets `FIREBASE_APPCHECK_DEBUG_TOKEN` only when the hostname is `localhost` or `127.0.0.1`.

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
    prefetcher.dart             // Warms mp4 in the HTTP cache and decodes voice m4a. Not a bloc.
    web_audio.dart              // AudioContext, decodeAudioData, unlock on the first gesture.
    functions_client.dart       // Calls Cloud Functions.
  features/                     // One folder per screen. Bloc, events, state, view.
    access/                     // Google or email, before the tabs.
      access_bloc.dart          // signedOut, signingIn, signedIn, and the story id from the link.
      access_event.dart         // SignInWithGoogleRequested, SignInWithEmailRequested, PasswordResetRequested, SignOutRequested.
      access_state.dart         // Phase, pending storyId, error phrase.
      access_view.dart          // Google button, email fields, password reset. No tab bar.
    feed/
      feed_bloc.dart            // Run phase. Lives above the tabs.
      feed_event.dart           // StoryOpened, UserGestured, PauseReached, VoiceFinished, HoldStarted, HoldCancelled, HoldCompleted, WindowElapsed.
      feed_state.dart           // Phase, playback, mute, autoMuted, endingSpeaking, reward, saga, hold zone. No 0-to-1 progress.
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
      window_picker.dart        // windowSeconds, 3 to 15, default 6. The pause is always the last frame.
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

`ShellView` is an `IndexedStack` of the five tabs. Leaving Feed pauses the video and the voice. Coming back stays on the same phase.

Tab order: Feed, Explore, Create (center button, no label), Map, Profile. The bar stays visible over the video.

## Routes

Path URLs, from `usePathUrlStrategy()` in `main.dart`. No hash. Hosting rewrites every path to `/index.html`. When `storyPage` exists, `/story/**` is rewritten to that function first, for link previews.

| Path | Screen | Who provides it |
|---|---|---|
| `/access` | `AccessView` | `AuthBloc`, already created above. No tab bar. |
| `/` | `ShellView` on Feed | `ShellBloc` and `FeedBloc` |
| `/story/{storyId}` | `ShellView` on Feed with that story | Same. The first response is `storyPage`, with the Open Graph preview. |
| `/explore` | `ShellView` on Explore | Same |
| `/graph/{storyId}` | `ShellView` on Map | Same |
| `/profile` | `ShellView` on Profile | Same |
| `/create` | `ShellView` on Create | Same |

The tabs stay one `IndexedStack`. The URL picks the tab and the story. Changing tabs updates the URL and does not recreate Feed.

An external link opens `/story/{storyId}`. With no session, the view stores the id in `sessionStorage` (`pendingStoryId`), sends `PendingStorySaved` to `AuthBloc`, and shows Access. With a session, it sends `StoryOpenRequested` to `ShellBloc`. That bloc switches to Feed and `FeedBloc` receives `StoryOpened`.

There is no guest route.

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

`Prefetcher` uses the browser HTTP cache. It creates hidden `<video preload="auto" muted>` elements for each destination URL. Cap: 3 live videos (the current clip and up to two destinations). Past the cap, drop the oldest that is not the current clip.

| Priority | What | When |
|---|---|---|
| 0 | Current node mp4 and its voice `.m4a`, decoded | On entering the node. |
| — | Portal blur | Not downloaded. It is `videoFrameLastBlurData` of the current node, already in memory. |
| 1 | mp4 of each destination that is not secret | After the current clip. One or two. `HoldStarted` moves that zone's clip to the front. |

A `secret` destination is not prefetched before `commitChoice`. Do not prefetch grandchildren. Changing stories clears the queue and keeps only the new node. The service worker does not intercept mp4 or requests with a `Range` header.

Playback files are progressive MP4, H.264, 480x854, faststart. One resolution. No HLS.

## What the client reads

Firestore rules let only the story's author read `nodes`. A player does not read nodes directly. Playback and the map come from Functions.

| Screen | Source |
|---|---|
| Feed | `startRun` and `loadPlayback(runId)`. |
| Map | `graphStubs(storyId)`. An unvisited node returns its id, whether it is an ending, and destination ids. A visited node also returns title, `thumbnailUrl`, labels, and `choiceCounts`. An unvisited secret appears only when a visited option points at it, and only as an id: a lock, no title, no image. |
| Explore | Query of published `stories` and active `campaigns`. |
| Create | The author's `draft` story and its nodes, secrets included. This read is direct. The author owns it. |
| Profile | The user doc, `follows`, `endings`, and that person's `sagas`. |
| Link `/story/{storyId}` | HTTP function `storyPage`. It builds HTML with Open Graph title, synopsis, and `ogImageUrl`, then loads the app. No session. No nodes. |

### loadPlayback

`loadPlayback({runId})` reads the caller's run, the current node, and its destinations with the Admin SDK. It returns only this:

```json
{
  "runId": "run_8k2p",
  "status": "active",
  "story": { "storyId": "story_temple", "title": "The temple secret", "authorName": "Alex Vance" },
  "node": {
    "nodeId": "node_001",
    "title": "The temple door",
    "isEnding": false,
    "videoUrl": "https://firebasestorage.googleapis.com/.../video-9f3e1a2b.mp4?alt=media&token=...",
    "durationSeconds": 10.0,
    "pauseAtSeconds": 9.967,
    "windowSeconds": 6,
    "ttsText": "What do you think Jeff should do? Enter the temple, or climb the ridge?",
    "ttsAudioUrl": "https://firebasestorage.googleapis.com/.../voz-c4d5e6f7.m4a?alt=media&token=...",
    "ttsDurationSeconds": 4.1,
    "videoFrameLastBlurData": "data:image/webp;base64,...",
    "endingName": null,
    "endingType": null
  },
  "choices": [
    {
      "choiceId": "choice_temple",
      "label": "Enter the temple",
      "targetNodeId": "node_002",
      "isDefault": true,
      "x": 0.25, "y": 0.65, "radius": 0.15,
      "targetSecret": false,
      "target": {
        "nodeId": "node_002",
        "videoUrl": "https://firebasestorage.googleapis.com/.../video-5d6e7f80.mp4?alt=media&token=..."
      }
    },
    {
      "choiceId": "choice_ridge",
      "label": "Climb the ridge",
      "targetNodeId": "node_003",
      "isDefault": false,
      "x": 0.75, "y": 0.7, "radius": 0.15,
      "targetSecret": true,
      "target": null
    }
  ]
}
```

- `authorName` comes from `users/{authorId}.displayName`. It is not stored on the story.
- `targetNodeId` is always present. The client needs it to ask for video, blurs, and prefetch. The id alone leaks nothing, because nodes are not readable by a player.
- `targetSecret` is `visibility == "secret"` on the destination.
- `status` is `active` or `ended`. When `ended`, `node` is the ending and the client shows the last frame with the card.
- A secret destination travels with `target: null`: id and label, no title, image, or video. Its body arrives in the `commitChoice` response that reaches it.
- The portal does not need destination blurs. It reuses the current node's last frame, which matches the destination's first frame.
- `choiceCounts`, destination `ttsText`, prompts, and author fields do not travel.
- With an inline blur of about 600 bytes, the response is 1 to 2 KB.

## Writes

| Action | Who writes |
|---|---|
| Create `users/{uid}` and change name, handle, photo, locale | Client. |
| Follow or unfollow | Client, at `follows/{uid}/authors/{authorId}`. |
| Create a `draft` story and edit its story fields | Client. |
| Nodes, runs, endings, unlocks, codes, `status: published` | Functions. The client does not write those paths. |

| Function | Used by |
|---|---|
| `startRun` | Feed, Explore, Profile. `startRun({ storyId, restart })`. With no `storyId`, pick the story from `storyState.updatedAt`. With `restart: true`, create a new run at the root and mark it active. |
| `loadPlayback` | Feed. |
| `commitChoice` | Feed. Takes `runId`, `fromNodeId`, `choiceId`, and `requestId`. The same `requestId` returns the same result. Returns the destination playback, plus ending, saga, and code when those exist. |
| `rewindRun` | Map. |
| `playApproach` | Map. |
| `graphStubs` | Map. |
| `createNode` | Create. |
| `saveNode` | Create. |
| `generateNodeText` | Create. |
| `generateNodeImage` | Create. `generateNodeImage({ which: "start" \| "end" })`. E on any node. S only on the root. |
| `generateNodeVideo` | Create. Inherits S from the parent's approved E and asks for video from S to E. |
| `generateNodeVoice` | Create. |
| `onUploadFinalized` | Nobody calls it. Storage trigger on `uploads/`. Re-encodes the uploaded video. |
| `storyPage` | Hosting, on `/story/**`. HTTP. No session. |
| `deleteNode` | Create. |
| `publishStory` | Create. |

Callables use `onCall({ enforceAppCheck: true, maxInstances })` in `us-central1`. App Check on the web is reCAPTCHA Enterprise. `storyPage` is plain HTTP for crawlers and does not use App Check.

## Errors

A repository throws `AppFailure` with a code: `offline`, `denied`, `invalid`, `failed`. The bloc emits that as a short phrase. The view shows `FailureText`. The retry button sends the same event again.

## Later

Live room, guild, Jev, embeddings, and rerank have no networked bloc. Profile shows the place and calls no one. Offline play, a CDN in front of the bucket, store apps, and AV1 are out of this version.
