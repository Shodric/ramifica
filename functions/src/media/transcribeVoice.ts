import {HttpsError} from "firebase-functions/v2/https";
import {onCallSafe} from "../callable";
import {metaApiKey, metaConfig} from "../config/ai";
import {isEmulator, optString, requireCreator, toRecord} from "../feed/shared";
import {
  MetaFetch,
  MetaHttpError,
  transcribeAudioMeta,
} from "./meta";

/** One transcription answer: slice text, never done from the server. */
export interface TranscribeVoiceResult {
  text: string;
  done: boolean;
}

/** Injectable provider pieces so tests run without Meta. */
export interface TranscribeVoiceDeps {
  apiKey?: string;
  model?: string;
  fetchFn?: MetaFetch;
}

/**
 * Transcribes one closed WAV take with Meta ASR (`POST /asr/transcribe`,
 * multipart `request` JSON plus the `audio` file). Unary: the answer is
 * the transcript of the bytes in this call, and `done` stays false. The
 * client sends a single take with `format: "wav"` and `last: true` on
 * FAB release, and replaces the on-screen text with the answer.
 * Word-by-word dictation needs `wss://api.meta.ai/v1/asr/realtime` on a
 * Cloud Run service outside this package.
 */
export const transcribeVoice = onCallSafe(
  {
    enforceAppCheck: !isEmulator(), maxInstances: 10,
    secrets: [metaApiKey],
  },
  async (req) => {
    const uid = requireCreator(req.auth);
    return transcribeVoiceWith(uid, req.data ?? {});
  }
);

/**
 * Testable core of `transcribeVoice`.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{sessionId, seq, audioBase64, format?, last}`.
 * @param {TranscribeVoiceDeps} deps Provider overrides for tests.
 * @return {Promise<TranscribeVoiceResult>} The slice text, never done.
 */
export const transcribeVoiceWith = async (
  uid: string,
  data: unknown,
  deps: TranscribeVoiceDeps = {}
): Promise<TranscribeVoiceResult> => {
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const fields = toRecord(data);
  const sessionId = optString(fields.sessionId);
  if (sessionId === null || sessionId.trim() === "") {
    throw new HttpsError("invalid-argument", "A session id is required.");
  }
  const seq = fields.seq;
  if (typeof seq !== "number" || !Number.isInteger(seq) || seq < 0) {
    throw new HttpsError("invalid-argument", "A slice sequence is required.");
  }
  const audioBase64 = optString(fields.audioBase64);
  if (audioBase64 === null || audioBase64.trim() === "") {
    throw new HttpsError("invalid-argument", "Audio is required.");
  }
  const format = optString(fields.format) ?? "webm";
  const config = metaConfig();
  const apiKey = deps.apiKey ?? config.apiKey;
  if (!apiKey) {
    throw new HttpsError(
      "failed-precondition",
      "Voice transcription is not configured."
    );
  }
  const model = deps.model ?? config.transcribeModel;
  let text: string;
  try {
    text = await transcribeAudioMeta({
      apiKey,
      model,
      audioBase64,
      format,
      fetchFn: deps.fetchFn,
    });
  } catch (error) {
    if (error instanceof MetaHttpError) {
      throw new HttpsError(
        "unavailable",
        `Voice transcription failed: ${error.status}.`
      );
    }
    throw error;
  }
  return {text, done: false};
};
