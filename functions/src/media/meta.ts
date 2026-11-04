import {asRecord} from "../feed/shared";
import {aiDefaults, metaConfig} from "../config/ai";

/**
 * Shared Meta Model API transport for Ramifica generations (text, images,
 * voice transcription). Mirrors `openrouter.ts`: one place for the key,
 * headers, and failure mapping so every caller behaves the same and tests
 * stub a single seam. Video and TTS stay on OpenRouter (Meta has no TTS
 * model), so those paths keep using `openrouter.ts` untouched.
 */

/** Injectable HTTP surface; matches the shape tests stub. */
export interface MetaFetch {
  (
    url: string,
    init: {
      method: string;
      headers: Record<string, string>;
      body?: string | FormData;
    }
  ): Promise<{
    ok: boolean;
    status: number;
    json: () => Promise<unknown>;
    arrayBuffer: () => Promise<ArrayBuffer>;
  }>;
}

/** Provider failure carrying its HTTP status for caller mapping. */
export class MetaHttpError extends Error {
  readonly status: number;
  /**
   * Provider failure with its HTTP status.
   * @param {number} status HTTP status.
   * @param {string} message Failure message.
   */
  constructor(status: number, message: string) {
    super(message);
    this.name = "MetaHttpError";
    this.status = status;
  }
}

/**
 * Auth headers every Meta call carries.
 * @param {string} apiKey Provider key.
 * @return {Record<string, string>} The headers.
 */
const headers = (apiKey: string): Record<string, string> => ({
  "Authorization": `Bearer ${apiKey}`,
  "Content-Type": "application/json",
});

/**
 * Default fetch adapter over the global fetch.
 * @param {string} url Endpoint.
 * @param {Object} init Method, headers, and body.
 * @return {Promise<Object>} The status plus body decoders.
 */
const defaultFetch: MetaFetch = (url, init) =>
  fetch(url, init).then((res) => ({
    ok: res.ok,
    status: res.status,
    json: () => res.json(),
    arrayBuffer: () => res.arrayBuffer(),
  }));

/**
 * POSTs a JSON body and decodes the JSON answer. Transport failures
 * throw [MetaHttpError] so callers map codes to their own errors.
 * @param {string} url Endpoint.
 * @param {Object} args Key, body, and optional test seams.
 * @return {Promise<unknown>} The decoded payload.
 */
export const metaPostJson = async (
  url: string,
  args: {
    apiKey: string;
    body: unknown;
    fetchFn?: MetaFetch;
  }
): Promise<unknown> => {
  const response = await (args.fetchFn ?? defaultFetch)(url, {
    method: "POST",
    headers: headers(args.apiKey),
    body: JSON.stringify(args.body),
  });
  if (!response.ok) {
    throw new MetaHttpError(
      response.status,
      `Meta request failed: ${response.status}.`
    );
  }
  return response.json();
};

/**
 * GETs a JSON document with auth. Same failure contract as [metaPostJson].
 * @param {string} url Endpoint.
 * @param {Object} args Key and optional test seams.
 * @return {Promise<unknown>} The decoded payload.
 */
export const metaGetJson = async (
  url: string,
  args: {apiKey: string; fetchFn?: MetaFetch}
): Promise<unknown> => {
  const response = await (args.fetchFn ?? defaultFetch)(url, {
    method: "GET",
    headers: headers(args.apiKey),
  });
  if (!response.ok) {
    throw new MetaHttpError(
      response.status,
      `Meta request failed: ${response.status}.`
    );
  }
  return response.json();
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
 * Asks Meta for one chat completion and returns its text.
 * @param {Object} args Key, model, messages, and optional test seams.
 * @return {Promise<string>} The answer text, or blank when off-shape.
 */
export const completeChatMeta = async (args: {
  apiKey: string;
  model: string;
  system: string;
  user: string;
  maxTokens?: number;
  reasoningEffort?: string;
  fetchFn?: MetaFetch;
}): Promise<string> => {
  const payload = await metaPostJson(metaConfig().chatUrl, {
    apiKey: args.apiKey,
    fetchFn: args.fetchFn,
    body: {
      model: args.model,
      ...(args.maxTokens === undefined ? {} : {max_tokens: args.maxTokens}),
      ...(args.reasoningEffort === undefined ?
        {} :
        {reasoning_effort: args.reasoningEffort}),
      messages: [
        {role: "system", content: args.system},
        {role: "user", content: args.user},
      ],
    },
  });
  const text = firstChoiceContent(payload);
  if (text === "") {
    // Shape-only diagnostics: keys reveal truncation vs. error
    // payloads without logging prompt or completion content.
    const record = asRecord(payload);
    const choices = record === null ? undefined : record.choices;
    const first = Array.isArray(choices) ? asRecord(choices[0]) : null;
    console.warn(
      "completeChatMeta: blank answer. top=" +
        JSON.stringify(record === null ? [] : Object.keys(record)) +
        " choice=" +
        JSON.stringify(first === null ? [] : Object.keys(first))
    );
  }
  return text;
};

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
 * Asks Meta for one still and returns its PNG bytes.
 * @param {Object} args Key, model, prompt, size, and optional seams.
 * @return {Promise<Buffer>} The PNG bytes.
 */
export const generateImageMeta = async (args: {
  apiKey: string;
  model: string;
  prompt: string;
  size: string;
  fetchFn?: MetaFetch;
}): Promise<Buffer> => {
  const payload = await metaPostJson(metaConfig().imagesUrl, {
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
 * Responses `image_generation_call` result, or null when the output
 * carries no image. Accepts a bare base64 string or an object holding
 * it under `b64_json`, `base64`, or `data`.
 * @param {unknown} payload Decoded provider JSON.
 * @return {Buffer | null} The PNG bytes, or null.
 */
const firstResponsesImageBytes = (payload: unknown): Buffer | null => {
  const record = asRecord(payload);
  const output = record === null ? undefined : record.output;
  if (!Array.isArray(output)) return null;
  for (const item of output) {
    const call = asRecord(item);
    if (call === null || call.type !== "image_generation_call") continue;
    const result = call.result;
    if (typeof result === "string" && result !== "") {
      return Buffer.from(result, "base64");
    }
    const holder = asRecord(result);
    const b64 = holder?.b64_json ?? holder?.base64 ?? holder?.data;
    if (typeof b64 === "string" && b64 !== "") {
      return Buffer.from(b64, "base64");
    }
  }
  return null;
};

/**
 * Asks Meta `/v1/responses` for one still guided by a reference image:
 * the frame travels as an `input_image` data URL, the behaviour as
 * `input_text`, and the returned PNG comes from the
 * `image_generation_call` output. Reasoning stays low for speed.
 * @param {Object} args Key, model, frame, instructions, and seams.
 * @return {Promise<Buffer>} The PNG bytes.
 */
export const generateImageWithReferenceMeta = async (args: {
  apiKey: string;
  model: string;
  frameBase64: string;
  frameMimeType: string;
  instructions: string;
  fetchFn?: MetaFetch;
}): Promise<Buffer> => {
  const payload = await metaPostJson(metaConfig().responsesUrl, {
    apiKey: args.apiKey,
    fetchFn: args.fetchFn,
    body: {
      model: args.model,
      store: false,
      stream: false,
      max_output_tokens: 2048,
      temperature: 0.6,
      top_p: 0.9,
      input: [
        {
          type: "message",
          role: "user",
          content: [
            {
              type: "input_image",
              image_url:
                `data:${args.frameMimeType};base64,${args.frameBase64}`,
            },
            {type: "input_text", text: args.instructions},
          ],
        },
      ],
      tools: [
        {
          type: "image_generation",
          size: "1024x1024",
          output_format: "png",
          reasoning_strength: "low",
          enable_web_search: false,
          enable_image_search: false,
          enable_shell: false,
        },
      ],
    },
  });
  const bytes = firstResponsesImageBytes(payload);
  if (bytes === null) {
    throw new Error("Image generation returned nothing usable.");
  }
  return bytes;
};

/**
 * Transcribed text from a decoded ASR payload, or blank when the shape
 * carries none. Reads `transcript`, falling back to `text` for drift.
 * @param {unknown} payload Decoded provider JSON.
 * @return {string} The transcript text, or blank.
 */
const firstTranscriptText = (payload: unknown): string => {
  const record = asRecord(payload);
  const transcript = record?.transcript;
  const text = record?.text;
  if (typeof transcript === "string") return transcript;
  return typeof text === "string" ? text : "";
};

/**
 * Sends one WAV take to Meta ASR (`POST /asr/transcribe`, multipart with
 * a `request` JSON part plus the `audio` file) and returns its transcript
 * text. Blank text is a valid answer: silence carries no words.
 * @param {Object} args Key, model, base64 audio, format, and seams.
 * @return {Promise<string>} The transcript text, possibly blank.
 */
export const transcribeAudioMeta = async (args: {
  apiKey: string;
  model: string;
  audioBase64: string;
  format: string;
  fetchFn?: MetaFetch;
}): Promise<string> => {
  const wav = args.format.toLowerCase() === "wav";
  const audioEncoding = wav ? "WAV" : args.format.toUpperCase();
  const contentType = wav ? "audio/wav" : "audio/webm";
  const filename = wav ? "audio.wav" : "audio.webm";
  const form = new FormData();
  form.append("request", JSON.stringify({model: args.model, audioEncoding}));
  form.append(
    "audio",
    new Blob([Buffer.from(args.audioBase64, "base64")], {type: contentType}),
    filename
  );
  const url = metaConfig().transcribeUrl;
  const response = await (args.fetchFn ?? defaultFetch)(url, {
    method: "POST",
    headers: {Authorization: `Bearer ${args.apiKey}`},
    body: form,
  });
  if (!response.ok) {
    throw new MetaHttpError(
      response.status,
      `Meta request failed: ${response.status}.`
    );
  }
  return firstTranscriptText(await response.json());
};

/** Default chat model; override with META_TEXT_MODEL. */
export const defaultTextModel = aiDefaults.meta.textModel;

/** Default image model; override with META_IMAGE_MODEL. */
export const defaultImageModel = aiDefaults.meta.imageModel;

/** Default transcription model; override with META_TRANSCRIBE_MODEL. */
export const defaultTranscribeModel = aiDefaults.meta.transcribeModel;

/** Vertical still size matching the app's 480x854 canvas. */
export const stillSize = aiDefaults.stillSize;
