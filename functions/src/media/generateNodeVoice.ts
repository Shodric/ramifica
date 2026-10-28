import * as admin from "firebase-admin";
import {createHash} from "crypto";
import {mkdtemp, readFile, rm, writeFile} from "fs/promises";
import {tmpdir} from "os";
import {join} from "path";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {
  cleanId,
  Db,
  docData,
  optString,
  requireUid,
  toRecord,
} from "../feed/shared";
import {convertVoiceToM4a, synthesizePcm} from "./voice";

/** Raw PCM take from the TTS provider. */
export interface VoiceTake {
  pcm: Buffer;
}

/** Converted take: app-format bytes plus their spoken length. */
export interface ConvertedTake {
  bytes: Buffer;
  durationSeconds: number;
}

/** Injectable seams so tests run without OpenRouter, ffmpeg, or Storage. */
export interface NodeVoiceDeps {
  synthesize?: (text: string) => Promise<VoiceTake>;
  convertTake?: (pcm: Buffer) => Promise<ConvertedTake>;
  uploadVoice?: (args: {
    storyId: string;
    nodeId: string;
    hash: string;
    bytes: Buffer;
  }) => Promise<string>;
}

/** Result of `generateNodeVoice`: the stored take, ready to preview. */
export interface GenerateNodeVoiceResult {
  nodeId: string;
  ttsStatus: string;
  ttsAudioUrl: string | null;
  ttsDurationSeconds: number | null;
  ttsApproved: boolean;
}

/** Default TTS voice, matching the seed fixtures. */
const defaultVoice = "Kore";

/** Narrator direction sent with every take. */
const defaultInstructions =
  "Off-screen narrator, one take. " +
  "Do not add, translate, or repeat words. " +
  "Speak natural American English.";

/**
 * Synthesizes the approved narrator line into a voice take. Gated on the
 * approved line: the line must be approved first, and every take (including
 * another take of the same line) stores fresh bytes and clears the voice
 * approval, so the author previews before the take counts.
 */
export const generateNodeVoice = onCall(
  {enforceAppCheck: true, maxInstances: 10},
  async (req) => {
    const uid = requireUid(req.auth);
    return generateNodeVoiceWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `generateNodeVoice`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, nodeId}`.
 * @param {NodeVoiceDeps} deps Injectable provider seams.
 * @return {Promise<GenerateNodeVoiceResult>} The stored take.
 */
export const generateNodeVoiceWith = async (
  db: Db,
  uid: string,
  data: unknown,
  deps: NodeVoiceDeps = {}
): Promise<GenerateNodeVoiceResult> => {
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  const nodeId = cleanId(fields.nodeId, "nodeId");

  const storySnap = await db.doc(`stories/${storyId}`).get();
  if (!storySnap.exists) {
    throw new HttpsError("not-found", "Story not found.");
  }
  const story = docData(storySnap, "Story");
  if (story.authorId !== uid) {
    throw new HttpsError("permission-denied", "Not your draft.");
  }
  if (story.status !== "draft") {
    throw new HttpsError("failed-precondition", "Only drafts can edit media.");
  }
  const nodeRef = db.doc(`stories/${storyId}/nodes/${nodeId}`);
  const nodeSnap = await nodeRef.get();
  if (!nodeSnap.exists) {
    throw new HttpsError("not-found", "Node not found.");
  }
  const node = docData(nodeSnap, "Node");
  if (node.lineApproved !== true) {
    throw new HttpsError(
      "failed-precondition",
      "Approve the narrator line before generating voice."
    );
  }
  const text = optString(node.ttsText);
  if (text === null || text === "") {
    throw new HttpsError(
      "failed-precondition",
      "Add a narrator line before generating voice."
    );
  }

  const synthesize = deps.synthesize ?? defaultSynthesize();
  if (!synthesize) {
    await nodeRef.set({ttsStatus: "pending"}, {merge: true});
    return {
      nodeId,
      ttsStatus: "pending",
      ttsAudioUrl: optString(node.ttsAudioUrl),
      ttsDurationSeconds: optDuration(node.ttsDurationSeconds),
      ttsApproved: node.ttsApproved === true,
    };
  }

  let pcm: Buffer;
  try {
    pcm = (await synthesize(text)).pcm;
  } catch (error) {
    await nodeRef.set({ttsStatus: "failed"}, {merge: true});
    throw new HttpsError(
      "internal",
      `Voice generation failed: ${(error as Error).message}`
    );
  }
  const convert = deps.convertTake ?? defaultConvertTake;
  let take: ConvertedTake;
  try {
    take = await convert(pcm);
  } catch (error) {
    await nodeRef.set({ttsStatus: "failed"}, {merge: true});
    throw new HttpsError(
      "internal",
      `Voice conversion failed: ${(error as Error).message}`
    );
  }
  if (!optDuration(take.durationSeconds)) {
    await nodeRef.set({ttsStatus: "failed"}, {merge: true});
    throw new HttpsError("internal", "Voice take has no duration.");
  }
  const hash = createHash("sha256")
    .update(take.bytes).digest("hex").slice(0, 8);
  const upload = deps.uploadVoice ?? defaultUploadVoice();
  const url = await upload({storyId, nodeId, hash, bytes: take.bytes});

  await nodeRef.set(
    {
      ttsAudioUrl: url,
      ttsStatus: "ready",
      ttsDurationSeconds: take.durationSeconds,
      ttsApproved: false,
    },
    {merge: true}
  );
  return {
    nodeId,
    ttsStatus: "ready",
    ttsAudioUrl: url,
    ttsDurationSeconds: take.durationSeconds,
    ttsApproved: false,
  };
};

/**
 * Default TTS seam: OpenRouter Gemini TTS. Null without credentials, so
 * the caller records `pending` instead of billing a key it cannot reach.
 * @return {Function | null} The synthesizer, or null.
 */
const defaultSynthesize = ():
  | ((text: string) => Promise<VoiceTake>)
  | null => {
  const apiKey = process.env.OPENROUTER_API_KEY;
  if (!apiKey) return null;
  const voice = process.env.OPENROUTER_TTS_VOICE ?? defaultVoice;
  return async (text: string) => ({
    pcm: await synthesizePcm({
      apiKey,
      voice,
      text,
      instructions: defaultInstructions,
    }),
  });
};

/**
 * Default conversion seam: raw PCM to the app `.m4a` via ffmpeg.
 * @param {Buffer} pcm Raw 16-bit 24 kHz mono PCM.
 * @return {Promise<ConvertedTake>} The app-format bytes and duration.
 */
const defaultConvertTake = async (pcm: Buffer): Promise<ConvertedTake> => {
  const dir = await mkdtemp(join(tmpdir(), "ramifica-voice-"));
  try {
    const src = join(dir, "take.pcm");
    await writeFile(src, pcm);
    const out = await convertVoiceToM4a(src, dir);
    const bytes = await readFile(out.path);
    return {bytes, durationSeconds: out.durationSeconds};
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
};

/**
 * Default voice uploader: versioned Storage path keyed by the hash, so
 * retakes never collide and URLs stay stable per bytes.
 * @return {Function} The uploader.
 */
const defaultUploadVoice = (): NonNullable<NodeVoiceDeps["uploadVoice"]> => {
  return async (args) => {
    const path =
      `stories/${args.storyId}/${args.nodeId}-voice-` + `${args.hash}.m4a`;
    const bucket = admin.storage().bucket();
    const file = bucket.file(path);
    await file.save(args.bytes, {metadata: {contentType: "audio/mp4"}});
    const [url] = await file.getSignedUrl({
      action: "read",
      expires: "2100-01-01",
    });
    return url;
  };
};

/**
 * Positive finite duration, or null. The publish checklist needs a real
 * spoken length, so blanks and garbage read as missing.
 * @param {unknown} value Raw duration.
 * @return {number | null} The duration, or null.
 */
const optDuration = (value: unknown): number | null => {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ?
    value :
    null;
};
