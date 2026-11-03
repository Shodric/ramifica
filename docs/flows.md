# Flows

Visual overview of Ramifica: the user journey, the play loop, authoring, generation, data, and deployment. Behavior details live in [Architecture](architecture.md); paths in [Data model](data-model.md); models in [AI configuration](ai-configuration.md). Diagrams are Mermaid and render on GitHub.

## User journey

```mermaid
flowchart TD
    open([Open app]) --> session{Session?}
    session -- No --> access["Access: Google or email"]
    access --> shell
    session -- Yes --> shell["Shell: five tabs"]
    shell --> feed["Feed: run resumes"]
    shell --> explore["Explore: catalog + search"]
    shell --> create["Create: drafts + wizard"]
    shell --> map["Map: visited graph"]
    shell --> profile["Profile: runs + endings"]
    feed --> clip["Clip plays, then pauses"]
    clip --> narrate["Narrator asks the question"]
    narrate --> hold["Hold a zone for one second"]
    hold -- "Release early" --> narrate
    hold -- "One second" --> next{"Run ended?"}
    next -- No --> clip
    next -- Yes --> ending["Ending card: map or another path"]
    ending --> map
    explore -- "Open story" --> feed
    create -- Publish --> feed
    map -- "Continue / rewind" --> feed
    profile -- "Play from start" --> feed
```

## Play flow

One decision round trip, from the player gesture to the persisted commit. `commitChoice` carries a `requestId` and retries with the same id, so the server never advances twice.

```mermaid
sequenceDiagram
    participant P as Player
    participant V as FeedView
    participant B as FeedBloc
    participant R as RunRepository
    participant F as Firestore
    V->>B: StoryOpened
    B->>R: startRun
    R->>F: read or create run
    B->>R: loadPlayback
    R->>F: read node + progress
    B->>V: playing (clip from first frame)
    V->>B: PauseReached (clip ended)
    B->>V: speaking (voice, or subtitle muted)
    V->>B: VoiceFinished
    B->>V: window (one zone per exit)
    P->>V: press and hold a zone
    V->>B: HoldStarted
    B->>V: holding (portal grows, 1s)
    alt release early
        V->>B: HoldCancelled
        B->>V: window
    else one second
        V->>B: HoldCompleted
        B->>R: commitChoice (requestId)
        R->>F: choice + history + visit + counter, atomic
        B->>R: loadPlayback (destination)
        R->>F: read next node body
        B->>V: playing (or ending card)
    end
```

## Feed phases

```mermaid
stateDiagram-v2
    [*] --> loading : StoryOpened
    loading --> playing : active playback
    loading --> ending : ended run
    loading --> failed : AppFailure
    playing --> speaking : PauseReached
    playing --> playing : StorySwiped (new story)
    speaking --> window : VoiceFinished
    window --> holding : HoldStarted
    holding --> window : HoldCancelled
    holding --> committing : HoldCompleted
    committing --> playing : next node
    committing --> ending : run ended
    ending --> [*]
    failed --> loading : retry (same event)
    note right of ending : Ending card offers the map or another path
```

## Authoring flow

Each node walks the wizard. Continue names the first missing piece until the step is complete; children skip Scenes and inherit the start frame from the parent clip. Full step reference: [Creating stories](creating.md).

```mermaid
flowchart TD
    create["Create tab: draft canvas"] --> open["Open a node"]
    open --> idea["Idea chip (root): premise"]
    idea --> info["0 Info: title + narrator line"]
    info --> scenes["1 Scenes: start frame S (root only)"]
    scenes --> voice["2 Voice: line + generated voice"]
    voice --> clip["3 Clip: generated video"]
    clip --> options["4 Options: zones on the last frame"]
    options --> gate{"Step complete?"}
    gate -- "Missing piece" --> options
    gate -- Yes --> persist["Save or Apply persists the draft"]
    persist --> gen["Generate + approve each medium"]
    gen --> publish{"Publish"}
    publish -- "Edits unsaved" --> persist
    publish -- "Graph invalid" --> open
    publish -- "Valid + revision current" --> stage["Stage projections"]
    stage --> active["Activate publication"]
    active --> play["Story plays in Feed"]
```

## AI generation and media

Eight callables plus one trigger, all in `us-central1`. Formats in [Media pipeline](media-pipeline.md).

```mermaid
flowchart LR
    subgraph client["Client (Create wizard)"]
        W[Wizard steps]
        U[Upload mp4 or mov]
        D[Dictation mic]
    end
    subgraph callables["Cloud Functions callables"]
        T["generateNodeText<br/>proposeStoryOutline<br/>decideChoiceIcon<br/>generateStoryCover"]
        I["generateNodeImage"]
        V["generateNodeVoice"]
        VV["generateNodeVideo"]
        TR["transcribeVoice"]
    end
    subgraph providers["Providers"]
        M["Meta: chat, images, ASR"]
        C["ComfyUI: alt images"]
        O["OpenRouter: TTS, video"]
    end
    subgraph store["Storage + Firestore"]
        S["stories/** media"]
        F["draft metadata<br/>(status, hashes, errors)"]
    end
    subgraph relay["Cloud Run: asr-relay"]
        R["PCM socket to Meta realtime"]
    end
    subgraph trigger["Storage trigger"]
        Z["onUploadFinalized:<br/>re-encode to H.264 MP4"]
    end
    W --> T & I & V & VV
    T --> M
    I --> M & C
    V & VV --> O
    D --> R
    R --> M
    R -. "socket fails" .-> TR
    TR --> M
    T & I & V & VV & TR --> S & F
    U --> Z
    Z --> S & F
```

## Database

Firestore paths with their readers, plus the Storage layout. Field reference: [Data model](data-model.md); enforcement: [Security](security.md).

```mermaid
flowchart TD
    subgraph stories["stories/{storyId}"]
        direction TB
        S["story doc<br/>(authorId, status, revision,<br/>activePublicationId)"]
        N["nodes/{node}<br/>author only<br/>(prompts, jobs, media)"]
        S --> N
        P["publications/{pub}<br/>staged: author only<br/>active: players"]
        S --> P
        PN["nodes/{node}<br/>visited bodies only"]
        PM["map/{node}<br/>all players<br/>(secret: id only)"]
        PS["stats/{node}<br/>choiceCounts"]
        P --> PN & PM & PS
    end
    subgraph users["users/{uid} (owner only)"]
        direction TB
        R["runs/{run}<br/>status, current node,<br/>append-only history"]
        ST["storyState/{story}<br/>active run, visits, endings"]
        RW["rewards/{reward}<br/>ending grants"]
    end
    subgraph open["Open reads (signed in)"]
        direction TB
        FO["follows/{uid}/authors<br/>(owner only)"]
        SA["sagas (read only)"]
        CA["campaigns (read, active)"]
    end
    subgraph storage["Storage"]
        direction TB
        SM["stories/**<br/>Functions write only<br/>clients play signed URLs"]
        UP["uploads/{uid}/<br/>creator create-only<br/>mp4 or mov, under 100 MB"]
    end
    R -. "visits gate" .-> PN
    R -. "visits gate" .-> PS
    UP -. "onUploadFinalized" .-> SM
```

## Deploy

```mermaid
flowchart LR
    B["fvm flutter build web"] --> H["firebase deploy --only hosting"]
    H --> P1["meta-ramifica.web.app"]
    L["functions: lint + build"] --> F["firebase deploy --only functions"]
    SEC["functions:secrets:set<br/>META_API_KEY<br/>OPENROUTER_API_KEY"] --> F
    F --> P2["6 AI callables + trigger<br/>(us-central1)"]
    R["realtime/"] --> G["gcloud run deploy asr-relay"]
    G --> P3["dictation relay<br/>(own env + secrets)"]
    P1 -. "new SW version" .-> T["open tabs reload"]
```
