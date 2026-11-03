# Data model

Firestore and Storage layout for Ramifica. The rules are the contract: `firestore.rules` and `storage.rules`. For the behavior around these paths, see [Architecture](architecture.md#client-persistence-and-privacy) and [Security](security.md).

## Stories and draft nodes

`stories/{storyId}` holds `authorId`, `title`, `synopsis`, `status` (`draft` or `published`), `rootNodeId`, `revision`, and timestamps; publishing adds `activePublicationId`, `publishedAt`, and `authorName`. Any signed-in account can read a published story; a draft is readable only by its author.

`stories/{storyId}/nodes/{nodeId}` is author-only, including prompts and generation metadata — players never read it. A node carries `title` (40 chars), `visibility` (`visible` or `secret`), `isEnding`, the narrator line `ttsText` (280 chars), media prompts, and at most two choices, each with a hold zone (`x`, `y`, `radius` in 0..1 frame coordinates). Authoring writes go through the client persistence layer in `lib/data/persistence/`, not through callables.

## Revisions and publishing

`story.revision` starts at 0 and advances by exactly one on every author write (`advanceRevision` in `lib/data/persistence/document_store.dart`); the rules reject any write that does not increment it. Publishing (`ClientPublisher` in `lib/data/persistence/publication.dart`) validates the graph in Dart, stages sanitized projections in batches under `stories/{storyId}/publications/{publicationId}`, then flips the story to `published` in one transaction — only if the revision is still current. The rules enforce the same guard: the new `activePublicationId` must point at a staged publication whose `sourceRevision` equals the pre-publish revision and that contains the root node. Staged publications are unreadable to players; only the active one opens.

## Publication reads

| Path | Reader |
|---|---|
| `publications/{pub}/nodes/{node}` | Author, or a player on the active publication who has visited the node. Listing is author-only. |
| `publications/{pub}/map/{node}` | Author, or any player on the active publication. An unvisited secret contributes only its ID and `{secret: true}`. |
| `publications/{pub}/stats/{node}` | Aggregated `choiceCounts`. Secret counts require a visit. A player may only increment one existing counter by one. |

Playback documents whitelist game fields; secret choices keep the target ID but no target body or URL. The author's public name is copied onto the story at publish time.

## Progress

`users/{uid}` and its subcollections are readable and writable only by that account:

| Path | Content |
|---|---|
| `users/{uid}` | Profile: `displayName`, `photoUrl`, `providers`, `locale`, `createdAt`. No `handle`. |
| `users/{uid}/runs/{runId}` | `storyId`, `currentNodeId`, `status` (`active` or `ended`), append-only `choices` history, `lastCommit`, ending fields. |
| `users/{uid}/storyState/{storyId}` | `activeRunId`, `visitedNodeIds`, `endings`, `sagaUnlocked`. |
| `users/{uid}/rewards/{rewardId}` | `storyId`, `endingNodeId`, `sagaId`, `code`, `grantedAt`, `requestId`. |

A run stays on its story: the rules reject changing `storyId` on update.

## Play transactions

`commitChoice` (`lib/data/persistence/game_service.dart`) commits the choice, the history entry, the new visits, and the stats counter atomically, and only then reads the destination body. A repeated `requestId` is a no-op, so a retried commit never advances twice. Endings complete in a second, idempotent transaction; loading an interrupted run finishes it. Reward IDs, existing codes, and history are preserved. Rewind moves `currentNodeId` back without deleting visits or history. `startRun` resumes the active run unless restarted.

## Follows, sagas, campaigns

- `follows/{uid}/authors/{authorId}`: read and write by that account only.
- `sagas/{sagaId}`: any signed-in account may read; no client writes.
- `campaigns/{campaignId}`: any signed-in account may read when `active` is true; no client writes.

## Storage

- `stories/{storyId}/**`: written by Functions. Rules deny all client SDK access; clients play the signed URLs Functions mint (`functions/src/media/storageUrl.ts`; download-token URLs on the emulator).
- `uploads/{uid}/{fileName}`: creator create-only. One `mp4` or `mov` under 100 MB; `onUploadFinalized` re-encodes it to H.264 MP4. No client read, update, or delete.
