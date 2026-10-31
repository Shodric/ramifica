import {asRecord} from "../feed/shared";

/**
 * Shared OpenRouter transport for all Ramifica generations (text, images,
 * voice, video). One place for the key, headers, and failure mapping so
 * every caller behaves the same and tests stub a single seam.
 *
 * Text and voice already called OpenRouter directly; they now route
 * through here with identical semantics. Image (new) and video (new)
 * generation build on the same transport.
 */

/** Injectable HTTP surface; matches the shape tests stub. */
export interface OpenRouterFetch {
  (
    url: string,
    init: {method: string; headers: Record<string, string>; body?: string}
  ): Promise<{
    ok: boolean;
    status: number;
    json: () => Promise<unknown>;
    arrayBuffer: () => Promise<ArrayBuffer>;
  }>;
}

/** Provider failure carrying its HTTP status for caller mapping. */
export class OpenRouterHttpError extends Error {
  readonly status: number;
  /**
   * Provider failure with its HTTP status.
   * @param {number} status HTTP status.
   * @param {string} message Failure message.
   */
  constructor(status: number, message: string) {
    super(message);
    this.name = "OpenRouterHttpError";
    this.status = status;
  }
}

/** Chat completions endpoint backing text proposals. */
const chatUrl = "https://openrouter.ai/api/v1/chat/completions";

/** Speech endpoint backing narrator takes. */
const speechUrl = "https://openrouter.ai/api/v1/audio/speech";

/** Images endpoint backing still generation. */
const imagesUrl = "https://openrouter.ai/api/v1/images/generations";

/** Video jobs endpoint backing clip generation. */
const videosUrl = "https://openrouter.ai/api/v1/videos";

/**
 * Auth + attribution headers every OpenRouter call carries.
 * @param {string} apiKey Provider key.
 * @param {string} title Request attribution.
 * @return {Record<string, string>} The headers.
 */
const headers = (apiKey: string, title: string): Record<string, string> => ({
  "Authorization": `Bearer ${apiKey}`,
  "Content-Type": "application/json",
  "HTTP-Referer": "https://ramifica.app",
  "X-Title": title,
});

/**
 * Default fetch adapter over the global fetch.
 * @param {string} url Endpoint.
 * @param {Object} init Method, headers, and body.
 * @return {Promise<Object>} The status plus body decoders.
 */
const defaultFetch: OpenRouterFetch = (url, init) =>
  fetch(url, init).then((res) => ({
    ok: res.ok,
    status: res.status,
    json: () => res.json(),
    arrayBuffer: () => res.arrayBuffer(),
  }));

/**
 * POSTs a JSON body and decodes the JSON answer. Transport failures
 * throw [OpenRouterHttpError] so callers map codes to their own errors.
 * @param {string} url Endpoint.
 * @param {Object} args Key, body, and optional test seams.
 * @return {Promise<unknown>} The decoded payload.
 */
export const postJson = async (
  url: string,
  args: {
    apiKey: string;
    body: unknown;
    title?: string;
    fetchFn?: OpenRouterFetch;
  }
): Promise<unknown> => {
  const response = await (args.fetchFn ?? defaultFetch)(url, {
    method: "POST",
    headers: headers(args.apiKey, args.title ?? "Ramifica create"),
    body: JSON.stringify(args.body),
  });
  if (!response.ok) {
    throw new OpenRouterHttpError(
      response.status,
      `OpenRouter request failed: ${response.status}.`
    );
  }
  return response.json();
};

/**
 * GETs a JSON document with auth. Same failure contract as [postJson].
 * @param {string} url Endpoint.
 * @param {Object} args Key and optional test seams.
 * @return {Promise<unknown>} The decoded payload.
 */
export const getJson = async (
  url: string,
  args: {apiKey: string; title?: string; fetchFn?: OpenRouterFetch}
): Promise<unknown> => {
  const response = await (args.fetchFn ?? defaultFetch)(url, {
    method: "GET",
    headers: headers(args.apiKey, args.title ?? "Ramifica create"),
  });
  if (!response.ok) {
    throw new OpenRouterHttpError(
      response.status,
      `OpenRouter request failed: ${response.status}.`
    );
  }
  return response.json();
};

/**
 * POSTs a JSON body and returns the raw response bytes (TTS audio).
 * Same failure contract as [postJson].
 * @param {string} url Endpoint.
 * @param {Object} args Key, body, and optional test seams.
 * @return {Promise<Buffer>} The raw bytes.
 */
export const postBytes = async (
  url: string,
  args: {
    apiKey: string;
    body: unknown;
    title?: string;
    fetchFn?: OpenRouterFetch;
  }
): Promise<Buffer> => {
  const response = await (args.fetchFn ?? defaultFetch)(url, {
    method: "POST",
    headers: headers(args.apiKey, args.title ?? "Ramifica create"),
    body: JSON.stringify(args.body),
  });
  if (!response.ok) {
    throw new OpenRouterHttpError(
      response.status,
      `OpenRouter request failed: ${response.status}.`
    );
  }
  return Buffer.from(await response.arrayBuffer());
};

/**
 * Downloads bytes with auth (generated clips). Same failure contract
 * as [postJson].
 * @param {string} url Content URL.
 * @param {Object} args Key and optional test seams.
 * @return {Promise<Buffer>} The raw bytes.
 */
export const downloadBytes = async (
  url: string,
  args: {apiKey: string; title?: string; fetchFn?: OpenRouterFetch}
): Promise<Buffer> => {
  const response = await (args.fetchFn ?? defaultFetch)(url, {
    method: "GET",
    headers: headers(args.apiKey, args.title ?? "Ramifica create"),
  });
  if (!response.ok) {
    throw new OpenRouterHttpError(
      response.status,
      `OpenRouter request failed: ${response.status}.`
    );
  }
  return Buffer.from(await response.arrayBuffer());
};

/**
 * First chat choice message content, or blank when the shape is off.
 * @param {unknown} payload Decoded provider JSON.
 * @return {string} The answer text, or blank.
 */
const firstChoiceContent = (payload: unknown): string => {
  const record = asRecord(payload);
  const choices = record === null ? undefined : record.choices;
  if (!Array.isArray(choices)) return "";
  const message = asRecord(choices[0]);
  const content =
    message === null ? undefined : asRecord(message.message)?.content;
  return typeof content === "string" ? content : "";
};

/**
 * Asks OpenRouter for one chat completion and returns its text.
 * @param {Object} args Key, model, messages, and optional test seams.
 * @return {Promise<string>} The answer text, or blank when off-shape.
 */
export const completeChat = async (args: {
  apiKey: string;
  model: string;
  system: string;
  user: string;
  maxTokens?: number;
  fetchFn?: OpenRouterFetch;
}): Promise<string> => {
  const payload = await postJson(chatUrl, {
    apiKey: args.apiKey,
    fetchFn: args.fetchFn,
    body: {
      model: args.model,
      ...(args.maxTokens === undefined ? {} : {max_tokens: args.maxTokens}),
      messages: [
        {role: "system", content: args.system},
        {role: "user", content: args.user},
      ],
    },
  });
  return firstChoiceContent(payload);
};

/**
 * Asks OpenRouter for a Gemini TTS take. Returns raw 16-bit 24 kHz mono
 * PCM, the format the voice pipeline turns into the app `.m4a`.
 * @param {Object} args Key, model, voice, text, and optional test seams.
 * @return {Promise<Buffer>} Raw PCM bytes.
 */
export const speakText = async (args: {
  apiKey: string;
  model: string;
  voice: string;
  text: string;
  instructions?: string;
  fetchFn?: OpenRouterFetch;
}): Promise<Buffer> =>
  postBytes(speechUrl, {
    apiKey: args.apiKey,
    fetchFn: args.fetchFn,
    title: "Ramifica seed",
    body: {
      model: args.model,
      input: args.text,
      voice: args.voice,
      response_format: "pcm",
      ...(args.instructions === undefined ?
        {} :
        {instructions: args.instructions}),
    },
  });

/**
 * First image payload bytes, or null when the shape has no image.
 * @param {unknown} payload Decoded provider JSON.
 * @return {Buffer | null} The PNG bytes, or null.
 */
const firstImageBytes = (payload: unknown): Buffer | null => {
  const record = asRecord(payload);
  const data = record === null ? undefined : record.data;
  if (!Array.isArray(data)) return null;
  const b64 = asRecord(data[0])?.b64_json;
  if (typeof b64 !== "string" || b64 === "") return null;
  return Buffer.from(b64, "base64");
};

/**
 * Asks OpenRouter for one still and returns its PNG bytes.
 * @param {Object} args Key, model, prompt, size, and optional seams.
 * @return {Promise<Buffer>} The PNG bytes.
 */
export const generateImageBytes = async (args: {
  apiKey: string;
  model: string;
  prompt: string;
  size: string;
  fetchFn?: OpenRouterFetch;
}): Promise<Buffer> => {
  const payload = await postJson(imagesUrl, {
    apiKey: args.apiKey,
    fetchFn: args.fetchFn,
    body: {model: args.model, prompt: args.prompt, size: args.size},
  });
  const bytes = firstImageBytes(payload);
  if (bytes === null) {
    throw new Error("Image generation returned nothing usable.");
  }
  return bytes;
};

/**
 * Submits a clip job. With only a start frame the provider animates
 * from it (HeyGen supports `first_frame` only); with both ends it
 * interpolates the morph. Optional fields are omitted when unset —
 * providers reject unlisted values.
 * @param {Object} args Key, model, prompt, frames, shape, and seams.
 * @return {Promise<Object>} The provider job id.
 */
export const submitVideo = async (args: {
  apiKey: string;
  model: string;
  prompt: string;
  startUrl: string;
  endUrl?: string;
  resolution?: string;
  aspectRatio?: string;
  duration?: number;
  generateAudio?: boolean;
  fetchFn?: OpenRouterFetch;
}): Promise<{jobId: string}> => {
  const payload = await postJson(videosUrl, {
    apiKey: args.apiKey,
    fetchFn: args.fetchFn,
    body: {
      model: args.model,
      prompt: args.prompt,
      frame_images: [
        {
          type: "image_url",
          image_url: {url: args.startUrl},
          frame_type: "first_frame",
        },
        ...(args.endUrl === undefined ?
          [] :
          [
            {
              type: "image_url",
              image_url: {url: args.endUrl},
              frame_type: "last_frame",
            },
          ]),
      ],
      ...(args.resolution === undefined ?
        {} :
        {resolution: args.resolution}),
      ...(args.aspectRatio === undefined ?
        {} :
        {aspect_ratio: args.aspectRatio}),
      ...(args.duration === undefined ? {} : {duration: args.duration}),
      ...(args.generateAudio === undefined ?
        {} :
        {generate_audio: args.generateAudio}),
    },
  });
  const id = asRecord(payload)?.id;
  if (typeof id !== "string" || id === "") {
    throw new Error("Video request returned no job id.");
  }
  return {jobId: id};
};

/**
 * First unsigned download URL, or null when the shape has none.
 * @param {Object} payload Decoded poll JSON.
 * @return {string | null} The URL, or null.
 */
const firstUnsignedUrl = (payload: {
  [field: string]: unknown;
}): string | null => {
  const urls = payload.unsigned_urls;
  if (!Array.isArray(urls)) return null;
  const first = urls[0];
  return typeof first === "string" && first !== "" ? first : null;
};

/**
 * Direct content URL for a job output; fallback when the poll response
 * carries no `unsigned_urls` (same bytes, needs the API key header).
 * @param {string} jobId Provider job id.
 * @param {number} index Output index, default first.
 * @return {string} The content URL.
 */
export const videoContentUrl = (jobId: string, index = 0): string =>
  `${videosUrl}/${jobId}/content?index=${index}`;

/**
 * Polls one video job: raw provider status plus the download URL once
 * the clip is ready (unsigned URL preferred, content URL fallback).
 * @param {Object} args Key, job id, and optional test seams.
 * @return {Promise<Object>} The status and optional download URL.
 */
export const checkVideo = async (args: {
  apiKey: string;
  jobId: string;
  fetchFn?: OpenRouterFetch;
}): Promise<{status: string; videoUrl?: string}> => {
  const payload = await getJson(`${videosUrl}/${args.jobId}`, {
    apiKey: args.apiKey,
    fetchFn: args.fetchFn,
  });
  const record = asRecord(payload);
  if (record === null) return {status: "pending"};
  const status = record.status;
  if (status !== "completed") {
    return {status: typeof status === "string" ? status : "pending"};
  }
  return {
    status,
    videoUrl: firstUnsignedUrl(record) ?? videoContentUrl(args.jobId),
  };
};

/** Default image model; override with OPENROUTER_IMAGE_MODEL. */
export const defaultImageModel = "meta/muse-image";

/** Default video model; override with OPENROUTER_VIDEO_MODEL. */
export const defaultVideoModel = "heygen/heygen-video-1";

/** Vertical still size matching the app's 480x854 canvas. */
export const stillSize = "480x854";

/** Vertical 9:16 aspect for generated clips. */
export const videoAspectRatio = "9:16";

/** Default clip resolution; HeyGen serves 480p/768p/2K. */
export const defaultVideoResolution = "768p";

/** Video length cap seconds; matches supported provider durations. */
export const videoDurationSeconds = 6;
