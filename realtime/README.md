# asr-relay

## Run

```sh
npm ci
cp -n .env.example .env.local
cp -n .secret.local.example .secret.local
# Fill META_API_KEY in .secret.local, then:
npm run start:local
```

Node 22 loads these files explicitly for `start:local`. `npm start` uses the
process environment, as Cloud Run does. See [AI configuration](../docs/ai-configuration.md)
for models, URLs, credentials, and the other generation services.

## Test

```sh
npm test
```

## Deploy

```sh
gcloud run deploy asr-relay --source realtime --project meta-ramifica --region us-central1 --timeout 600 --concurrency 20 --max-instances 10 --min-instances 0 --allow-unauthenticated --set-secrets META_API_KEY=META_API_KEY:latest --set-env-vars META_REALTIME_URL=wss://api.meta.ai/v1/asr/realtime,META_TRANSCRIBE_MODEL=muse-voice-transcribe-1.0
```

Run the deployment command from the repository root. The Cloud Run runtime
service account needs Secret Manager Secret Accessor on `META_API_KEY`.
Local `.env*` and `.secret*` files are excluded from the upload and Docker
copies only the server and package manifests.

Configured client URL: `wss://asr-relay-209293545230.us-central1.run.app/asr`.
Changing a Functions `.env` file does not change the relay: they are separate
deployments. Configure the relay environment as well when switching ASR models.
