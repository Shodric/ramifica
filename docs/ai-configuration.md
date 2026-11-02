# AI configuration

Backend models and endpoints use the variables in `functions/.env.example`.
Defaults and runtime readers live together in `functions/src/config/ai.ts`.
Adapters read configuration for each request, after secrets have been injected.

## Current connections

| Feature | Connection | Default model | Credential |
| --- | --- | --- | --- |
| Premise, scene proposal, narrator line | Meta, `/chat/completions` | `muse-spark-1.3-contributor` | `META_API_KEY` |
| S/E images | Meta, `/images/generations` | `muse-image-1.0` | `META_API_KEY` |
| Alternative S/E images | ComfyUI, local workflow | `COMFYUI_CKPT` | Server at `COMFYUI_URL` |
| Narrator TTS | OpenRouter, `/audio/speech` | `google/gemini-3.8-flash-lite-tts`, voice `Kore` | `OPENROUTER_API_KEY` |
| Video | OpenRouter, `/videos` | `heygen/heygen-video-1` | `OPENROUTER_API_KEY` |
| Complete audio transcription | Meta, `/asr/transcribe` | `muse-voice-transcribe-1.0` | `META_API_KEY` |
| Live dictation | Own Cloud Run relay → Meta WebSocket | `muse-voice-transcribe-1.0` | Relay's `META_API_KEY` |

Google supplies the TTS model and HeyGen supplies the video model. Both connect
through OpenRouter: they use an OpenRouter key, without an additional Google or
HeyGen key. This table lists code defaults; model access depends on the provider
catalog and the account's permissions.

## Local emulator

From the repository root:

```sh
cp -n functions/.env.example functions/.env.local
cp -n functions/.secret.local.example functions/.secret.local
```

Edit `functions/.env.local` to choose models and URLs. Fill in `META_API_KEY` and
`OPENROUTER_API_KEY` in `functions/.secret.local`. Git ignores both local files;
the tracked templates contain no keys.

```sh
npm --prefix functions run build
firebase emulators:start --only functions --project meta-ramifica
```

Firebase CLI loads these files automatically. `.env.local` overrides `.env` and
`.env.<project-id>`; `.secret.local` supplies local secret values. This lets local
development run without permissions to production secrets. Node also accepts
injected process variables; a dotenv file needs a loader such as Firebase CLI or
`node --env-file` to enter the environment.

The emulator still calls external providers when credentials are present.
Missing credentials fail explicitly for every generator and clear terminal pending states. Empty keys cannot generate media.

The current `--dart-define=EMULATOR=true` connects only Functions to its emulator.
Auth, Firestore and Storage still use the real project unless connected to their
emulators explicitly. AI configuration does not change those connections.

## Deployed Firebase

Copy the non-secret template to `functions/.env.meta-ramifica` (use a different
suffix for a different project). Models, voices and URLs belong there.
`.env.local` is local-only and does not configure production.

Set credentials under the names already bound by the callables:

```sh
firebase functions:secrets:set META_API_KEY --project meta-ramifica
firebase functions:secrets:set OPENROUTER_API_KEY --project meta-ramifica
firebase deploy --only functions --project meta-ramifica
```

The commands prompt for each key. Keep values out of command arguments and
tracked configuration. Firebase stores them in Google Secret Manager and injects
each secret into the functions declaring it: Meta for text/outline/images/ASR,
OpenRouter for TTS/video. Image approval is a direct client transaction and needs no callable or key. Image generation declares
the Meta secret even when ComfyUI is selected; the rest of the project's text and
dictation features also need this secret.

Redeploy functions after changing keys or deployment configuration. Exporting a
variable in a local terminal does not configure an already-deployed function.
No Firestore collection is required to store these credentials.

## Changing models and providers

The main backend settings look like this:

```dotenv
META_TEXT_MODEL=muse-spark-1.3-contributor
META_IMAGE_MODEL=muse-image-1.0
OPENROUTER_TTS_MODEL=google/gemini-3.8-flash-lite-tts
OPENROUTER_TTS_VOICE=Kore
OPENROUTER_VIDEO_MODEL=heygen/heygen-video-1
```

`META_BASE_URL` and `OPENROUTER_BASE_URL` change each API root. Per-endpoint
overrides are also available: `META_CHAT_URL`, `META_IMAGES_URL`,
`META_TRANSCRIBE_URL`, `OPENROUTER_SPEECH_URL` and `OPENROUTER_VIDEOS_URL`.
The last setting controls job creation, polling and fallback content download.

Current adapters support Meta text/ASR, Meta or ComfyUI images, and OpenRouter
TTS/video. A custom URL works with services using the same protocol and Bearer
authentication; a different contract requires its own adapter. A Google, Fal,
Replicate or Runway URL alone cannot replace `OPENROUTER_BASE_URL`. Within
OpenRouter, the video model ID selects the model family and model vendor.

To force ComfyUI while retaining a Meta key for text and dictation:

```dotenv
AI_IMAGE_PROVIDER=comfy
COMFYUI_URL=http://127.0.0.1:8188
COMFYUI_CKPT=v1-5-pruned-emaonly.safetensors
```

`auto` preserves the previous order: Meta with a key, otherwise ComfyUI with a URL.
The checkpoint must exist on the ComfyUI server. Deployed functions need a URL
reachable from that environment. The current ComfyUI adapter does not add auth.

TTS requests signed 16-bit little-endian mono PCM and converts it to M4A for the
app. When changing models, select a supported voice and set the response's actual
sample rate in `TTS_PCM_SAMPLE_RATE` (default 24000). This configures decoding; it
does not request resampling from the API. A model returning only MP3 needs an
adapted converter input. `OPENROUTER_TTS_INSTRUCTIONS` changes voice direction;
an empty value omits instructions. The default respects the supplied text's language.

Video requests use 480p, 9:16 and 10 seconds at 24 fps. `OPENROUTER_VIDEO_RESOLUTION=480p`,
`OPENROUTER_VIDEO_DURATION_SECONDS=10`, and `OPENROUTER_VIDEO_ASPECT_RATIO=9:16` express
the request; the pipeline stores what the provider returns (browser-compatible
H.264 + faststart) and records the probed dimensions and duration. Nothing is
scaled, cropped, trimmed, or rejected for size. Uploaded clips keep their duration.
HeyGen's default connection uses the first frame only: the pipeline sends the
start frame and never conditions on an authored end frame. The extracted last
frame of each finished clip is stored for playback and for chaining the next
node's start. Finish
pending jobs before switching video API backends or models, since the new endpoint
may be unable to poll the old job IDs.

## Live dictation relay

The relay runs separately. Its templates are `realtime/.env.example` and
`realtime/.secret.local.example`. For local use, copy them to `.env.local` and
`.secret.local`, fill in the key and run `npm run start:local` from `realtime/`
using Node 22. On Cloud Run, inject `META_API_KEY` from Secret Manager and set
`META_REALTIME_URL` / `META_TRANSCRIBE_MODEL` as ordinary environment variables.
See `realtime/README.md` for commands. Editing a Functions `.env` file does not
change the Cloud Run deployment.

## References

- [Firebase: environment variables and secrets](https://firebase.google.com/docs/functions/config-env)
- [OpenRouter: TTS API](https://openrouter.ai/blog/tutorials/text-to-speech/)
- [OpenRouter: video models and capabilities](https://openrouter.ai/docs/api/api-reference/video-generation/list-videos-models)
