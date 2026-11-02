import * as admin from "firebase-admin";
import {createHash} from "crypto";
import {mkdtemp, readFile, rm, writeFile} from "fs/promises";
import {tmpdir} from "os";
import {join} from "path";
import {HttpsError} from "firebase-functions/v2/https";
import {onCallSafe} from "../callable";
import {metaApiKey} from "../config/ai";
import {
  cleanId,
  Db,
  docData,
  isEmulator,
  isoNow,
  optString,
  requireUid,
  toRecord,
} from "../feed/shared";
import {convertCover} from "../media/images";
import {NormalizedStill, normalizeStill} from "../media/processVideo";
import {readableStorageUrl} from "../media/storageUrl";
import {defaultImageGen, ImageGenFn} from "./generateNodeMedia";

/** Result of `generateStoryCover`. */
export interface GenerateStoryCoverResult {
  coverUrl: string;
  ogImageUrl: string;
  coverStatus: string;
  width?: number;
  height?: number;
}

/** Injectable cover uploader: bytes in, public URL out. */
export interface CoverUploadFn {
  (args: {
    storyId: string;
    hash: string;
    name: string;
    bytes: Buffer;
    contentType: string;
  }): Promise<string>;
}

/** Injectable cover art converter: source PNG in, web + preview out. */
export interface CoverConvertFn {
  (pngBytes: Buffer): Promise<{webp: Buffer; og: Buffer}>;
}

/** Injectable seams so tests run without GPU, Storage, or a provider. */
export interface StoryCoverDeps {
  imageGen?: ImageGenFn;
  normalizeImage?: (bytes: Buffer) => Promise<NormalizedStill>;
  convertArt?: CoverConvertFn;
  uploadCover?: CoverUploadFn;
}

/** Cost guard: one cover prompt cannot smuggle a novel into the bill. */
const maxPromptChars = 2000;

/**
 * Generates the key art for a draft story. Bills the same still path as
 * node frames, then derives the 480px cover plus the 1200x630 link
 * preview and points the story doc at both. Without a provider (emulator,
 * no still key) it fails with a reason and keeps the last good cover.
 * @param {unknown} _req Unused callable wrapper slot.
 */
export const generateStoryCover = onCallSafe(
  {
    enforceAppCheck: !isEmulator(), maxInstances: 10,
    timeoutSeconds: 300, memory: "1GiB", concurrency: 2,
    secrets: [metaApiKey],
  },
  async (req) => {
    const uid = requireUid(req.auth);
    return generateStoryCoverWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `generateStoryCover`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, prompt?}`.
 * @param {StoryCoverDeps} deps Injectable provider seams.
 * @return {Promise<GenerateStoryCoverResult>} The cover URLs.
 */
export const generateStoryCoverWith = async (
  db: Db,
  uid: string,
  data: unknown,
  deps: StoryCoverDeps = {}
): Promise<GenerateStoryCoverResult> => {
  assertUid(uid);
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  const promptOverride = optString(fields.prompt);
  if (promptOverride !== null && promptOverride.length > maxPromptChars) {
    throw new HttpsError(
      "invalid-argument",
      `Prompt is limited to ${maxPromptChars} characters.`
    );
  }

  const story = await loadDraftStory(db, uid, storyId);
  const prompt = promptOverride ?? buildCoverPrompt(story);

  const gen = deps.imageGen ?? defaultImageGen();
  if (!gen) {
    await markCoverFailed(
      db, storyId, "Image provider credentials are missing."
    ).catch(() => undefined);
    throw new HttpsError(
      "failed-precondition",
      "Image provider credentials are missing."
    );
  }
  await db.doc(`stories/${storyId}`).update({coverStatus: "pending"});
  try {
    const raw = (await gen(prompt)).bytes;
    const result = await (deps.normalizeImage ?? normalizeStill)(raw);
    const bytes = result.bytes;
    const hash = sha8(bytes);
    const art = await (deps.convertArt ?? defaultConvertArt)(bytes);
    const upload = deps.uploadCover ?? defaultUploadCover();
    const [coverUrl, ogImageUrl] = await Promise.all([
      upload({
        storyId, hash, name: `cover-${hash}-480.webp`, bytes: art.webp,
        contentType: "image/webp",
      }),
      upload({
        storyId, hash, name: `og-${hash}-1200.jpg`, bytes: art.og,
        contentType: "image/jpeg",
      }),
    ]);
    await upload({
      storyId, hash, name: `cover-${hash}.png`, bytes,
      contentType: "image/png",
    });
    const revision = typeof story.revision === "number" ? story.revision : 0;
    await db.doc(`stories/${storyId}`).update({
      coverUrl,
      ogImageUrl,
      coverStatus: "ready",
      coverError: null,
      revision: revision + 1,
      updatedAt: isoNow(),
    });
    return {
      coverUrl, ogImageUrl, coverStatus: "ready",
      width: result.width, height: result.height,
    };
  } catch (error) {
    await markCoverFailed(db, storyId, (error as Error).message)
      .catch(() => undefined);
    throw new HttpsError(
      "internal",
      `Cover generation failed: ${(error as Error).message}`
    );
  }
};

/**
 * Key art prompt from the story bible: title plus synopsis, composed as
 * the one image that sells the whole story. Pure so tests pin the copy
 * without a Db.
 * @param {Object} story Draft story fields.
 * @return {string} The image prompt.
 */
export const buildCoverPrompt = (
  story: {[field: string]: unknown}
): string => {
  const title = clip(story.title, 60) || "Untitled story";
  const synopsis = clip(story.synopsis, 300).replace(/[.\s]+$/, "");
  const parts = [
    "Vertical 9:16 cinematic key art, 480x854, photorealistic, " +
    "no text, no watermark, no logo.",
    `STORY: "${title}"${synopsis === "" ? "" : ` — ${synopsis}`}.`,
    "COVER: the iconic centered composition of this story, dramatic " +
    "lighting, strong readable silhouette, room for a title band " +
    "at the top.",
  ];
  return parts.join(" ");
};

/**
 * Rejects blank uids as unauthenticated, not invalid.
 * @param {string} uid Caller.
 */
const assertUid = (uid: string): void => {
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
};

/**
 * Loads the draft story or throws: unknown stories read as not-found,
 * foreign ones as permission-denied, published ones as failed-precondition.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {string} storyId Story id.
 * @return {Promise<Object>} The story fields.
 */
const loadDraftStory = async (
  db: Db,
  uid: string,
  storyId: string
): Promise<{[field: string]: unknown}> => {
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
  return story;
};

/**
 * Marks the cover failed with a reason, keeping the last good bytes.
 * @param {Db} db Firestore.
 * @param {string} storyId Story id.
 * @param {string} message Failure reason.
 */
const markCoverFailed = async (
  db: Db,
  storyId: string,
  message: string
): Promise<void> => {
  await db.doc(`stories/${storyId}`).update({
    coverStatus: "failed",
    coverError: message,
  });
};

/**
 * First 8 hex chars of the sha256: the hash-link version stamp.
 * @param {Buffer} bytes Raw bytes.
 * @return {string} The stamp.
 */
const sha8 = (bytes: Buffer): string => {
  return createHash("sha256").update(bytes).digest("hex").slice(0, 8);
};

/**
 * Trims a raw field to at most `max` chars; blanks and non-strings
 * become "". Keeps one long field from eating the prompt budget.
 * @param {unknown} value Raw field.
 * @param {number} max Character cap.
 * @return {string} The clipped text.
 */
const clip = (value: unknown, max: number): string => {
  const text = typeof value === "string" ? value.trim() : "";
  return text.length <= max ? text : text.slice(0, max);
};

/**
 * Default art converter: source PNG through `convertCover` into the
 * 480px web cover plus the 1200x630 link preview.
 * @param {Buffer} pngBytes Source PNG bytes.
 * @return {Promise<Object>} The web and preview buffers.
 */
const defaultConvertArt: CoverConvertFn = async (pngBytes: Buffer) => {
  const dir = await mkdtemp(join(tmpdir(), "ramifica-cover-"));
  try {
    const input = join(dir, "cover.png");
    await writeFile(input, pngBytes);
    const {webpPath, ogPath} = await convertCover(input, dir);
    const [webp, og] = await Promise.all([
      readFile(webpPath),
      readFile(ogPath),
    ]);
    return {webp, og};
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
};

/**
 * Default cover uploader: versioned Storage path keyed by the hash, so
 * regens never collide and URLs stay stable per bytes.
 * @return {CoverUploadFn} The uploader.
 */
const defaultUploadCover = (): CoverUploadFn => {
  return async (args) => {
    const path = `stories/${args.storyId}/${args.name}`;
    const bucket = admin.storage().bucket();
    const file = bucket.file(path);
    await file.save(args.bytes, {metadata: {contentType: args.contentType}});
    return readableStorageUrl(file);
  };
};
