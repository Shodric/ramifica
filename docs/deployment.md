# Deployment

Build, release, and operations. Firebase specifics (Hosting headers, CORS, App Check) are in [Architecture](architecture.md); models and secrets are in [AI configuration](ai-configuration.md); the relay deploys separately ([realtime/README.md](../realtime/README.md)).

## Client

```sh
fvm flutter build web
firebase deploy --only hosting --project meta-ramifica
```

`build/web` is what Hosting serves. For a preview URL instead of production:

```sh
firebase hosting:channel:deploy preview --project meta-ramifica
```

A release build registers the full service worker with a new version, which forces open tabs to reload onto the fresh shell.

## Functions

```sh
firebase deploy --only functions --project meta-ramifica
```

Deploy runs the `firebase.json` predeploy steps (`lint`, then `build`) and prunes functions no longer exported from `functions/src/index.ts`. Only the AI callables plus `onUploadFinalized` ship; the region is `us-central1`. Redeploy after changing keys or deployment configuration — a local terminal export never reconfigures a deployed function.

Credentials are set under the names the callables bind:

```sh
firebase functions:secrets:set META_API_KEY --project meta-ramifica
firebase functions:secrets:set OPENROUTER_API_KEY --project meta-ramifica
```

Non-secret model and URL settings belong in `functions/.env.meta-ramifica`.

## Storage CORS

After changing `cors.json`, reapply it to the bucket:

```sh
gcloud storage buckets update gs://meta-ramifica.firebasestorage.app --cors-file=cors.json
```

## Relay

The dictation relay is its own Cloud Run service, deployed from the repo root:

```sh
gcloud run deploy asr-relay --source realtime --project meta-ramifica --region us-central1 --timeout 600 --concurrency 20 --max-instances 10 --min-instances 0 --allow-unauthenticated --set-secrets META_API_KEY=META_API_KEY:latest --set-env-vars META_REALTIME_URL=wss://api.meta.ai/v1/asr/realtime,META_TRANSCRIBE_MODEL=muse-voice-transcribe-1.0
```

The runtime service account needs Secret Manager Secret Accessor on `META_API_KEY`. Editing a Functions `.env` file never changes this deployment.
