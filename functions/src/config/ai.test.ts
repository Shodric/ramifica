import {strict as assert} from "assert";
import {test} from "node:test";
import {
  imageProvider, metaConfig, openRouterConfig, ttsPcmSampleRate, videoConfig,
} from "./ai";
import {generateNodeText} from "../create/generateNodeText";
import {proposeStoryOutline} from "../create/proposeOutline";
import {
  generateNodeImage, generateNodeVideo,
} from "../create/generateNodeMedia";
import {generateNodeVoice} from "../media/generateNodeVoice";
import {transcribeVoice} from "../media/transcribeVoice";

test("secret bindings reach only their generation callables", () => {
  for (const callable of [
    generateNodeText, proposeStoryOutline, generateNodeImage, transcribeVoice,
  ]) {
    assert.deepEqual(callable.__endpoint.secretEnvironmentVariables,
      [{key: "META_API_KEY"}]);
  }
  for (const callable of [generateNodeVoice, generateNodeVideo]) {
    assert.deepEqual(callable.__endpoint.secretEnvironmentVariables,
      [{key: "OPENROUTER_API_KEY"}]);
  }
});

test("provider settings accept custom endpoints without stale defaults", () => {
  const meta = metaConfig({
    META_API_KEY: "test-key",
    META_BASE_URL: "https://meta-proxy.example/v2///",
    META_TEXT_MODEL: "custom-text",
    META_IMAGE_MODEL: "custom-image",
    META_TRANSCRIBE_MODEL: "custom-asr",
    META_IMAGES_URL: "https://images.example/generate",
  });
  assert.equal(meta.chatUrl, "https://meta-proxy.example/v2/chat/completions");
  assert.equal(meta.imagesUrl, "https://images.example/generate");
  assert.equal(meta.transcribeUrl, "https://meta-proxy.example/v2/asr/transcribe");
  assert.equal(meta.textModel, "custom-text");
  assert.equal(meta.imageModel, "custom-image");
  assert.equal(meta.transcribeModel, "custom-asr");
  const router = openRouterConfig({
    OPENROUTER_BASE_URL: "https://router.example/api/v2/",
    OPENROUTER_DECISION_MODEL: "vendor/custom-decision",
    OPENROUTER_VIDEO_MODEL: "vendor/custom-video",
    OPENROUTER_TTS_MODEL: "vendor/custom-tts",
    OPENROUTER_TTS_VOICE: "custom-voice",
    OPENROUTER_TTS_INSTRUCTIONS: "",
  });
  assert.equal(router.videosUrl, "https://router.example/api/v2/videos");
  assert.equal(router.speechUrl, "https://router.example/api/v2/audio/speech");
  assert.equal(router.decisionModel, "vendor/custom-decision");
  assert.equal(openRouterConfig({}).decisionModel, "baseten/joey-1");
  assert.equal(
    openRouterConfig({}).decisionsUrl,
    "https://openrouter.ai/api/alpha/decisions"
  );
  assert.equal(
    openRouterConfig({
      OPENROUTER_DECISIONS_URL: "https://router.example/api/alpha/decisions",
    }).decisionsUrl,
    "https://router.example/api/alpha/decisions"
  );
  assert.equal(router.videoModel, "vendor/custom-video");
  assert.equal(router.ttsModel, "vendor/custom-tts");
  assert.equal(router.ttsVoice, "custom-voice");
  assert.equal(router.ttsInstructions, "");
  assert.match(openRouterConfig({}).ttsInstructions,
    /language of the supplied text/);
});

test("explicit Comfy selection wins even with a Meta key", () => {
  const env = {META_API_KEY: "test-key", COMFYUI_URL: "http://gpu.example"};
  assert.equal(imageProvider(env), "meta");
  assert.equal(imageProvider({...env, AI_IMAGE_PROVIDER: "comfy"}), "comfy");
  assert.equal(imageProvider({AI_IMAGE_PROVIDER: "meta"}), null);
  assert.throws(() => imageProvider({AI_IMAGE_PROVIDER: "typo"}),
    /AI_IMAGE_PROVIDER/);
});

test("video and PCM settings reject invalid numbers and flags", () => {
  assert.throws(() => videoConfig({OPENROUTER_VIDEO_DURATION_SECONDS: "NaN"}),
    /DURATION_SECONDS/);
  assert.throws(() => ttsPcmSampleRate({TTS_PCM_SAMPLE_RATE: "0"}),
    /SAMPLE_RATE/);
  assert.throws(() => ttsPcmSampleRate({TTS_PCM_SAMPLE_RATE: "24000.5"}),
    /integer/);
});
