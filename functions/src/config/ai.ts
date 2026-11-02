import {defineSecret} from "firebase-functions/params";

/** Credentials are injected into only the callables that bind them. */
export const metaApiKey = defineSecret("META_API_KEY");
export const openRouterApiKey = defineSecret("OPENROUTER_API_KEY");

/** Request hints for new editor media (provider may return other sizes).
 * Stored dimensions always come from probing the returned bytes. */
export const mediaProfile = {
  width: 480, height: 854, fps: 24, durationSeconds: 10,
  resolution: "480p", aspectRatio: "9:16", stillSize: "480x854",
} as const;

/** Provider defaults; credentials remain on the server. */
export const aiDefaults = {
  meta: {
    baseUrl: "https://api.meta.ai/v1",
    textModel: "muse-spark-1.3-contributor",
    imageModel: "muse-image-1.0",
    transcribeModel: "muse-voice-transcribe-1.0",
  },
  openRouter: {
    baseUrl: "https://openrouter.ai/api/v1",
    decisionModel: "baseten/joey-1",
    imageModel: "meta/muse-image",
    videoModel: "heygen/heygen-video-1",
    ttsModel: "google/gemini-3.8-flash-lite-tts",
    ttsVoice: "Kore",
    ttsInstructions: "Off-screen narrator, one take. " +
      "Do not add, translate, or repeat words. " +
      "Speak naturally in the language of the supplied text.",
  },
  comfy: {
    checkpoint: "v1-5-pruned-emaonly.safetensors",
    steps: 20,
    cfg: 7,
    sampler: "euler",
    scheduler: "normal",
  },
  video: mediaProfile,
  ttsPcmSampleRate: 24000,
  stillSize: mediaProfile.stillSize,
} as const;

type Env = Readonly<Record<string, string | undefined>>;

/**
 * Reads trimmed settings; blank values use the established default.
 * @param {Env} env Runtime environment (injectable in tests).
 * @param {string} name Setting name.
 * @param {string} fallback Default value.
 * @return {string} Configured value.
 */
const setting = (env: Env, name: string, fallback: string): string =>
  env[name]?.trim() || fallback;

/**
 * Resolves an endpoint override against a provider base URL.
 * @param {Env} env Runtime environment.
 * @param {string} name Endpoint setting.
 * @param {string} baseUrl Provider base.
 * @param {string} path API path relative to the base.
 * @return {string} Endpoint URL without a trailing slash.
 */
const endpoint = (
  env: Env, name: string, baseUrl: string, path: string
): string => setting(env, name, `${baseUrl}/${path}`).replace(/\/+$/, "");

/**
 * Reads a positive numeric setting, rejecting typos before an API call.
 * @param {Env} env Runtime environment.
 * @param {string} name Setting name.
 * @param {number} fallback Default value.
 * @return {number} Configured number.
 */
const positiveNumber = (env: Env, name: string, fallback: number): number => {
  const value = Number(setting(env, name, String(fallback)));
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be a positive number.`);
  }
  return value;
};

/**
 * Meta settings are resolved at request time, after secret injection.
 * @param {Env} env Runtime environment.
 * @return {Object} Provider credentials, models, and endpoints.
 */
export const metaConfig = (env: Env = process.env) => {
  const base = setting(env, "META_BASE_URL", aiDefaults.meta.baseUrl)
    .replace(/\/+$/, "");
  return {
    apiKey: env.META_API_KEY || "",
    textModel: setting(env, "META_TEXT_MODEL", aiDefaults.meta.textModel),
    imageModel: setting(env, "META_IMAGE_MODEL", aiDefaults.meta.imageModel),
    transcribeModel: setting(
      env, "META_TRANSCRIBE_MODEL", aiDefaults.meta.transcribeModel
    ),
    chatUrl: endpoint(env, "META_CHAT_URL", base, "chat/completions"),
    imagesUrl: endpoint(env, "META_IMAGES_URL", base, "images/generations"),
    transcribeUrl: endpoint(
      env, "META_TRANSCRIBE_URL", base, "asr/transcribe"
    ),
  };
};

/**
 * OpenRouter-compatible endpoints, used for TTS and asynchronous video.
 * @param {Env} env Runtime environment.
 * @return {Object} Provider credentials, models, voices, and endpoints.
 */
export const openRouterConfig = (env: Env = process.env) => {
  const base = setting(
    env, "OPENROUTER_BASE_URL", aiDefaults.openRouter.baseUrl
  )
    .replace(/\/+$/, "");
  return {
    apiKey: env.OPENROUTER_API_KEY || "",
    decisionModel: setting(
      env, "OPENROUTER_DECISION_MODEL", aiDefaults.openRouter.decisionModel
    ),
    imageModel: setting(
      env, "OPENROUTER_IMAGE_MODEL", aiDefaults.openRouter.imageModel
    ),
    videoModel: setting(
      env, "OPENROUTER_VIDEO_MODEL", aiDefaults.openRouter.videoModel
    ),
    ttsModel: setting(
      env, "OPENROUTER_TTS_MODEL", aiDefaults.openRouter.ttsModel
    ),
    ttsVoice: setting(
      env, "OPENROUTER_TTS_VOICE", aiDefaults.openRouter.ttsVoice
    ),
    ttsInstructions: env.OPENROUTER_TTS_INSTRUCTIONS ??
      aiDefaults.openRouter.ttsInstructions,
    chatUrl: endpoint(env, "OPENROUTER_CHAT_URL", base, "chat/completions"),
    speechUrl: endpoint(env, "OPENROUTER_SPEECH_URL", base, "audio/speech"),
    imagesUrl: endpoint(
      env, "OPENROUTER_IMAGES_URL", base, "images/generations"
    ),
    videosUrl: endpoint(env, "OPENROUTER_VIDEOS_URL", base, "videos"),
  };
};

/**
 * Explicit image selection overrides the legacy Meta-then-Comfy fallback.
 * @param {Env} env Runtime environment.
 * @return {string | null} Configured provider, or null without credentials.
 */
export const imageProvider = (
  env: Env = process.env
): "meta" | "comfy" | null => {
  const provider = setting(env, "AI_IMAGE_PROVIDER", "auto");
  if (!["auto", "meta", "comfy"].includes(provider)) {
    throw new Error("AI_IMAGE_PROVIDER must be auto, meta, or comfy.");
  }
  if (provider === "meta") return env.META_API_KEY ? "meta" : null;
  if (provider === "comfy") return env.COMFYUI_URL ? "comfy" : null;
  if (env.META_API_KEY) return "meta";
  return env.COMFYUI_URL ? "comfy" : null;
};

/**
 * Settings specific to the existing OpenRouter video adapter.
 * @param {Env} env Runtime environment.
 * @return {Object} Output shape.
 */
export const videoConfig = (env: Env = process.env) => {
  const output = {
    resolution: setting(
      env, "OPENROUTER_VIDEO_RESOLUTION", aiDefaults.video.resolution
    ),
    aspectRatio: setting(
      env, "OPENROUTER_VIDEO_ASPECT_RATIO", aiDefaults.video.aspectRatio
    ),
    duration: positiveNumber(
      env, "OPENROUTER_VIDEO_DURATION_SECONDS", aiDefaults.video.durationSeconds
    ),
  };
  return output;
};

/**
 * Raw signed 16-bit mono PCM rate returned by the selected TTS model.
 * This configures decoding; it does not request resampling from the API.
 * @param {Env} env Runtime environment.
 * @return {number} Input sample rate for ffmpeg.
 */
export const ttsPcmSampleRate = (env: Env = process.env): number => {
  const value = positiveNumber(
    env, "TTS_PCM_SAMPLE_RATE", aiDefaults.ttsPcmSampleRate
  );
  if (!Number.isInteger(value)) {
    throw new Error("TTS_PCM_SAMPLE_RATE must be an integer.");
  }
  return value;
};

/**
 * GPU workflow settings for the bundled ComfyUI image adapter.
 * @param {Env} env Runtime environment.
 * @return {Object} Server, checkpoint, and sampling configuration.
 */
export const comfyConfig = (env: Env = process.env) => ({
  baseUrl: setting(env, "COMFYUI_URL", ""),
  checkpoint: setting(env, "COMFYUI_CKPT", aiDefaults.comfy.checkpoint),
  steps: positiveNumber(env, "COMFYUI_STEPS", aiDefaults.comfy.steps),
  cfg: positiveNumber(env, "COMFYUI_CFG", aiDefaults.comfy.cfg),
  sampler: setting(env, "COMFYUI_SAMPLER", aiDefaults.comfy.sampler),
  scheduler: setting(env, "COMFYUI_SCHEDULER", aiDefaults.comfy.scheduler),
});
