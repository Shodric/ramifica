import * as admin from "firebase-admin";
import {createHash} from "crypto";
import {mkdtemp, readFile, rm, writeFile} from "fs/promises";
import {tmpdir} from "os";
import {join} from "path";
import {HttpsError} from "firebase-functions/v2/https";
import {onCallSafe} from "../callable";
import {
  cleanId,
  Db,
  docData,
  isEmulator,
  optString,
  requireCreator,
  toRecord,
} from "../feed/shared";
import {beginMedia, writeMedia} from "./draftWrites";
import {readableStorageUrl} from "./storageUrl";
import {convertVoiceToM4a, synthesizePcm} from "./voice";
import {
  openRouterApiKey, openRouterConfig, ttsPcmSampleRate,
} from "../config/ai";

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

/**
 * Synthesizes the narrator line into a voice take. Gated only on a
 * non-blank line: every take (including another take of the same line)
 * stores fresh bytes, so the author previews the take as-is.
 */
export const generateNodeVoice = onCallSafe(
  {
    enforceAppCheck: !isEmulator(), maxInstances: 10,
    timeoutSeconds: 180, concurrency: 2,
    secrets: [openRouterApiKey],
  },
  async (req) => {
    const uid = requireCreator(req.auth);
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
  const text = optString(node.ttsText);
  if (text === null) {
    throw new HttpsError(
      "failed-precondition",
      "Add a narrator line before generating voice."
    );
  }

  const synthesize = deps.synthesize ?? defaultSynthesize();
  if (!synthesize) {
    await writeMedia(
      db,
      storyId,
      nodeId,
      {
        ttsStatus: "failed",
        generationKind: null,
        generationPhase: null,
        mediaError: "TTS provider credentials are missing.",
      }
    );
    throw new HttpsError(
      "failed-precondition",
      "TTS provider credentials are missing."
    );
  }
  await beginMedia(
    db,
    storyId,
    nodeId,
    "voice",
    {
      ttsStatus: "pending",
      generationKind: "voice",
      generationPhase: "generating",
      mediaError: null,
    }
  );

  let pcm: Buffer;
  try {
    pcm = (await synthesize(text)).pcm;
  } catch (error) {
    await writeMedia(
      db,
      storyId,
      nodeId,
      {
        ttsStatus: "failed",
        generationKind: null,
        generationPhase: null,
        mediaError: (error as Error).message,
      }
    );
    throw new HttpsError(
      "internal",
      `Voice generation failed: ${(error as Error).message}`
    );
  }
  const convert = deps.convertTake ?? defaultConvertTake;
  let take: ConvertedTake;
  try {
    await writeMedia(db, storyId, nodeId, {generationPhase: "processing"});
    take = await convert(pcm);
  } catch (error) {
    await writeMedia(
      db,
      storyId,
      nodeId,
      {
        ttsStatus: "failed",
        generationKind: null,
        generationPhase: null,
        mediaError: (error as Error).message,
      }
    );
    throw new HttpsError(
      "internal",
      `Voice conversion failed: ${(error as Error).message}`
    );
  }
  if (!optDuration(take.durationSeconds)) {
    await writeMedia(
      db,
      storyId,
      nodeId,
      {
        ttsStatus: "failed",
        generationKind: null,
        generationPhase: null,
        mediaError: "Voice take has no duration.",
      }
    );
    throw new HttpsError("internal", "Voice take has no duration.");
  }
  const hash = createHash("sha256")
    .update(take.bytes).digest("hex").slice(0, 8);
  const upload = deps.uploadVoice ?? defaultUploadVoice();
  let url: string;
  try {
    url = await upload({storyId, nodeId, hash, bytes: take.bytes});
  } catch (error) {
    await writeMedia(
      db,
      storyId,
      nodeId,
      {
        ttsStatus: "failed",
        generationKind: null,
        generationPhase: null,
        mediaError: (error as Error).message,
      }
    );
    throw error;
  }

  await writeMedia(db, storyId, nodeId,
    {
      ttsAudioUrl: url,
      ttsStatus: "ready",
      ttsDurationSeconds: take.durationSeconds,
      ttsApproved: false,
      generationKind: null,
      generationPhase: null,
      mediaError: null,
    }, (fresh) => {
      if (fresh.ttsText !== text) {
        throw new HttpsError(
          "aborted",
          "The narrator line changed while generating voice."
        );
      }
    }
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
 * the caller fails with a reason instead of billing a key it cannot reach.
 * @return {Function | null} The synthesizer, or null.
 */
const defaultSynthesize = ():
  | ((text: string) => Promise<VoiceTake>)
  | null => {
  const config = openRouterConfig();
  const apiKey = config.apiKey;
  if (!apiKey) return null;
  return async (text: string) => ({
    pcm: await synthesizePcm({
      apiKey,
      model: config.ttsModel,
      voice: config.ttsVoice,
      text,
      instructions: config.ttsInstructions || undefined,
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
    const out = await convertVoiceToM4a(src, dir, ttsPcmSampleRate());
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
    return readableStorageUrl(file);
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
