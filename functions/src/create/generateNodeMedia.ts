import * as admin from "firebase-admin";
import {createHash} from "crypto";
import {HttpsError} from "firebase-functions/v2/https";
import {onCallSafe} from "../callable";
import {
  imageProvider, mediaProfile, metaApiKey, metaConfig, openRouterApiKey,
  openRouterConfig, videoConfig,
} from "../config/ai";
import {
  cleanId,
  Db,
  docData,
  isEmulator,
  optString,
  requireUid,
  toRecord,
} from "../feed/shared";
import {ComfyClient} from "../media/comfy";
import {
  checkVideo,
  downloadBytes,
  OpenRouterHttpError,
  stillSize,
  submitVideo,
} from "../media/openrouter";
import {
  generateImageMeta,
  generateImageWithReferenceMeta,
} from "../media/meta";
import {
  downloadFrameBytes as downloadBadgeFrameBytes,
  sniffImageMime as sniffBadgeImageMime,
} from "./generateEndingBadge";
import {
  NormalizedStill, NormalizedVideo, normalizeStill, normalizeGeneratedVideo,
} from "../media/processVideo";
import {beginMedia, writeMedia} from "../media/draftWrites";
import {readableStorageUrl} from "../media/storageUrl";

/**
 * Which still a Storage path holds: `start` (the root-authored S) or
 * `end` (the last frame extracted from a finished clip). Still
 * generation only accepts `start`; no model conditions on an authored E.
 */
export type FrameWhich = "start" | "end";

/** Raw still bytes from the image provider. */
export interface StillResult {
  bytes: Buffer;
}

/** Injectable still provider: prompt in, PNG bytes out. */
export interface ImageGenFn {
  (prompt: string): Promise<StillResult>;
}

/** Injectable reference still provider: prompt plus reference in, bytes out. */
export interface ReferenceImageGenFn {
  (args: {
    prompt: string;
    referenceBase64: string;
    referenceMimeType: string;
  }): Promise<StillResult>;
}

/** Injectable reference downloader: signed URL in, bytes or null. */
export interface ReferenceDownloadFn {
  (url: string): Promise<Buffer | null>;
}

/** Injectable still uploader: bytes in, public URL out. */
export interface StillUploadFn {
  (args: {
    storyId: string;
    nodeId: string;
    which: FrameWhich;
    hash: string;
    bytes: Buffer;
  }): Promise<string>;
}

/** Injectable image-to-video provider: S in, job out. */
export interface VideoRequestFn {
  (args: {
    startUrl: string;
    prompt: string;
  }): Promise<{jobId: string; videoUrl?: string}>;
}

/**
 * Injectable video status poll: provider job id in, status plus the
 * download URL once the clip is ready out.
 */
export interface VideoCheckFn {
  (jobId: string): Promise<{status: string; videoUrl?: string}>;
}

/** Injectable clip downloader: content URL in, bytes out. */
export interface VideoDownloadFn {
  (url: string): Promise<Buffer>;
}

/** Injectable clip reviewer: bytes in, playable seconds out. */
export interface VideoProbeFn {
  (bytes: Buffer): Promise<number>;
}

/** Injectable clip uploader: bytes in, Storage URL out. */
export interface VideoStoreFn {
  (args: {
    storyId: string;
    nodeId: string;
    hash: string;
    bytes: Buffer;
  }): Promise<string>;
}

/** Injectable seams so tests run without GPU, Storage, or OpenRouter. */
export interface NodeMediaDeps {
  imageGen?: ImageGenFn;
  referenceImageGen?: ReferenceImageGenFn;
  downloadReference?: ReferenceDownloadFn;
  uploadStill?: StillUploadFn;
  requestVideo?: VideoRequestFn;
  checkVideo?: VideoCheckFn;
  downloadVideo?: VideoDownloadFn;
  normalizeImage?: (bytes: Buffer) => Promise<NormalizedStill>;
  normalizeVideo?: (bytes: Buffer) => Promise<NormalizedVideo>;
  uploadVideo?: VideoStoreFn;
  now?: () => number;
}

/** Result of `generateNodeImage`. */
export interface GenerateNodeImageResult {
  nodeId: string;
  which: FrameWhich;
  imageStatus: string;
  imageUrl: string | null;
  desyncedNodeIds: string[];
  width?: number;
  height?: number;
}

/** Result of `generateNodeVideo`. */
export interface GenerateNodeVideoResult {
  nodeId: string;
  videoStatus: string;
  videoFromHash: string;
  videoJobId: string;
  videoUrl: string | null;
  poll: boolean;
  videoWidth?: number;
  videoHeight?: number;
  durationSeconds?: number;
}

/** Cost guard: one still prompt cannot smuggle a novel into the bill. */
const maxPromptChars = 2000;

/** Still size matches the seed covers: 480x854 vertical. */
const stillWidth = mediaProfile.width;
const stillHeight = mediaProfile.height;

/**
 * Generates the S still for the root node. Without a provider
 * (emulator, no still key) it fails with a reason and keeps the last
 * good bytes. A new S idles the root's own video when its
 * `videoFromHash` no longer fits; children desync later, when the
 * root clip finishes with a new last-frame hash.
 * @param {unknown} _req Unused callable wrapper slot.
 */
export const generateNodeImage = onCallSafe(
  {
    enforceAppCheck: !isEmulator(), maxInstances: 10,
    timeoutSeconds: 300, memory: "1GiB", concurrency: 2,
    secrets: [metaApiKey],
  },
  async (req) => {
    const uid = requireUid(req.auth);
    return generateNodeImageWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Requests the clip for a draft node. Gated only on ready frames:
 * the parent's finished clip for children (its extracted last frame
 * is inherited as S by hash link), the node's own ready S for the
 * root. Without a video provider it fails with a reason; it never
 * keeps a stale video quietly.
 */
export const generateNodeVideo = onCallSafe(
  {
    enforceAppCheck: !isEmulator(), maxInstances: 10,
    timeoutSeconds: 300, memory: "1GiB", concurrency: 2,
    secrets: [openRouterApiKey],
  },
  async (req) => {
    const uid = requireUid(req.auth);
    return generateNodeVideoWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `generateNodeImage`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, nodeId, which, prompt?}`.
 * @param {NodeMediaDeps} deps Injectable provider seams.
 * @return {Promise<GenerateNodeImageResult>} The still status + desync.
 */
export const generateNodeImageWith = async (
  db: Db,
  uid: string,
  data: unknown,
  deps: NodeMediaDeps = {}
): Promise<GenerateNodeImageResult> => {
  assertUid(uid);
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  const nodeId = cleanId(fields.nodeId, "nodeId");
  const which = parseWhich(fields.which);
  const promptOverride = optString(fields.prompt);
  if (promptOverride !== null && promptOverride.length > maxPromptChars) {
    throw new HttpsError(
      "invalid-argument",
      `Prompt is limited to ${maxPromptChars} characters.`
    );
  }

  const loaded = await loadDraftNode(db, uid, storyId, nodeId);
  const story = loaded.story;
  const node = loaded.node;
  const isRoot = story.rootNodeId === nodeId || story.rootNodeId === null;
  if (which === "start" && !isRoot) {
    throw new HttpsError(
      "failed-precondition",
      "Only the root node has its own start frame."
    );
  }

  const storedPrompt = optString(node.startImagePrompt);
  const prompt =
    promptOverride ?? storedPrompt ?? buildImagePrompt(story, node);

  const gen = deps.imageGen ?? defaultImageGen();
  if (!gen) {
    await writeMedia(db, storyId, nodeId, {
      [`${which}ImageStatus`]: "failed",
      generationKind: null,
      generationPhase: null,
      mediaError: "Image provider credentials are missing.",
    });
    throw new HttpsError(
      "failed-precondition",
      "Image provider credentials are missing."
    );
  }
  await markImagePending(db, storyId, nodeId, which, prompt);
  try {
    const raw = await generateStillBytes({node, prompt, deps, gen});
    await writeMedia(db, storyId, nodeId, {generationPhase: "processing"});
    const result = await (deps.normalizeImage ?? normalizeStill)(raw);
    const bytes = result.bytes;
    const hash = sha8(bytes);
    const url = await (deps.uploadStill ?? defaultStillUpload())({
      storyId, nodeId, which, hash, bytes,
    });
    const still = {
      prompt, url, hash, width: result.width, height: result.height,
    };
    return await applyStartReady(db, storyId, nodeId, still);
  } catch (error) {
    await writeMedia(db, storyId, nodeId, {
      [`${which}ImageStatus`]: "failed", generationKind: null,
      generationPhase: null, mediaError: (error as Error).message,
    }).catch(() => undefined);
    throw new HttpsError(
      "internal",
      `Still generation failed: ${(error as Error).message}`
    );
  }
};

/**
 * Still bytes for the node S: reference-guided when the node carries a
 * `startImageReferenceUrl`, plain prompt otherwise. Any download or
 * reference-path failure falls back to the plain path so reference use
 * never breaks what already works.
 * @param {Object} args Node fields, prompt, deps, and default provider.
 * @return {Promise<Buffer>} The raw still bytes.
 */
const generateStillBytes = async (args: {
  node: {[field: string]: unknown};
  prompt: string;
  deps: NodeMediaDeps;
  gen: ImageGenFn;
}): Promise<Buffer> => {
  const referenceUrl = optString(args.node.startImageReferenceUrl);
  if (referenceUrl === null) {
    return (await args.gen(args.prompt)).bytes;
  }
  try {
    const download =
      args.deps.downloadReference ?? downloadBadgeFrameBytes;
    const reference = await download(referenceUrl);
    if (reference === null) {
      return (await args.gen(args.prompt)).bytes;
    }
    const generate =
      args.deps.referenceImageGen ?? defaultReferenceImageGen();
    if (generate === null) return (await args.gen(args.prompt)).bytes;
    return (await generate({
      prompt: args.prompt,
      referenceBase64: reference.toString("base64"),
      referenceMimeType: sniffBadgeImageMime(reference),
    })).bytes;
  } catch {
    return (await args.gen(args.prompt)).bytes;
  }
};


/**
 * Default reference still provider: Meta responses API guided by the
 * node's reference image, else null so the caller falls back to the
 * plain prompt path instead of billing what it cannot reach.
 * @return {ReferenceImageGenFn | null} The provider, or null.
 */
const defaultReferenceImageGen = (): ReferenceImageGenFn | null => {
  const kind = imageProviderKind();
  if (kind !== "meta") return null;
  const config = metaConfig();
  return async ({prompt, referenceBase64, referenceMimeType}) => ({
    bytes: await generateImageWithReferenceMeta({
      apiKey: config.apiKey,
      model: config.imageModel,
      frameBase64: referenceBase64,
      frameMimeType: referenceMimeType,
      instructions: prompt,
    }),
  });
};

/**
 * Testable core of `generateNodeVideo`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, nodeId, prompt?}`.
 * @param {NodeMediaDeps} deps Injectable provider seams.
 * @return {Promise<GenerateNodeVideoResult>} The video job.
 */
export const generateNodeVideoWith = async (
  db: Db,
  uid: string,
  data: unknown,
  deps: NodeMediaDeps = {}
): Promise<GenerateNodeVideoResult> => {
  assertUid(uid);
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  const nodeId = cleanId(fields.nodeId, "nodeId");
  const promptOverride = optString(fields.prompt);
  if (promptOverride !== null && promptOverride.length > maxPromptChars) {
    throw new HttpsError(
      "invalid-argument",
      `Prompt is limited to ${maxPromptChars} characters.`
    );
  }

  const loaded = await loadDraftNode(db, uid, storyId, nodeId);
  const story = loaded.story;
  const node = loaded.node;
  const isRoot = story.rootNodeId === nodeId || story.rootNodeId === null;

  let fromHash: string;
  let fromUrl: string;
  let parentWidth: number | null = null;
  let parentHeight: number | null = null;
  if (isRoot) {
    const hash = optString(node.startHash);
    const url = optString(node.startImageSourceUrl);
    if (node.startImageStatus === "ready" && hash !== null && url !== null) {
      fromHash = hash;
      fromUrl = url;
    } else {
      // No generated S yet: fall back to the author's reference still as
      // the clip's first frame. The hash derives from the URL so the
      // stored job echoes a stable `videoFromHash`.
      const referenceUrl = optString(node.startImageReferenceUrl);
      if (referenceUrl === null) {
        throw new HttpsError(
          "failed-precondition",
          "Generate the start frame before requesting video."
        );
      }
      fromHash = sha8(Buffer.from(referenceUrl, "utf8"));
      fromUrl = referenceUrl;
    }
  } else {
    const parentId = optString(node.startFromNodeId);
    if (parentId === null) {
      throw new HttpsError(
        "failed-precondition",
        "This node is missing its parent link."
      );
    }
    const parentSnap = await db
      .doc(`stories/${storyId}/nodes/${parentId}`)
      .get();
    if (!parentSnap.exists) {
      throw new HttpsError("not-found", "Parent node not found.");
    }
    const parent = docData(parentSnap, "Node");
    const hash = optString(parent.videoFrameLastHash);
    const url = optString(parent.videoFrameLastUrl);
    if (hash === null || url === null) {
      throw new HttpsError(
        "failed-precondition",
        "Generate the parent clip first."
      );
    }
    fromHash = hash;
    fromUrl = url;
    parentWidth = typeof parent.videoWidth === "number" ?
      parent.videoWidth : null;
    parentHeight = typeof parent.videoHeight === "number" ?
      parent.videoHeight : null;
  }

  const prompt =
    promptOverride ??
    optString(node.videoPrompt) ??
    `Slow cinematic drift, ${titleOf(node)}, vertical video.`;
  const storedJob = optString(node.videoJobId);
  if (
    storedJob !== null &&
    storedJob.startsWith(openRouterJobPrefix) &&
    optString(node.videoStatus) === "pending"
  ) {
    if (node.videoFromHash != null && node.videoFromHash !== fromHash) {
      await failVideo(
        db, storyId, nodeId, "Frames changed during video generation."
      );
      throw new HttpsError(
        "failed-precondition",
        "Frames changed; generate a new video."
      );
    }
    // The client poll loop is bounded, but a slow or dead provider job would
    // otherwise sit in `pending` forever once polling stops. Past the lease,
    // fail with a reason so the next tap starts fresh instead of resuming.
    const expiresAt = Date.parse(String(node.generationExpiresAt ?? ""));
    if (Number.isFinite(expiresAt) && expiresAt <= Date.now()) {
      await failVideo(
        db, storyId, nodeId, "Video generation timed out before finishing."
      );
      throw new HttpsError(
        "deadline-exceeded",
        "Video generation timed out before finishing."
      );
    }
    return resumeVideoJob(
      db,
      storyId,
      nodeId,
      storedJob,
      fromHash,
      deps
    );
  }
  const request = deps.requestVideo ?? defaultRequestVideo();
  if (!request) {
    await writeMedia(db, storyId, nodeId, {
      videoStatus: "failed",
      generationKind: null,
      generationPhase: null,
      mediaError: "Video provider credentials are missing.",
    });
    throw new HttpsError(
      "failed-precondition",
      "Video provider credentials are missing."
    );
  }
  const update: Record<string, unknown> = {
    videoStatus: "pending", videoSource: "generated", videoPrompt: prompt,
    videoFromHash: fromHash,
    generationKind: "video", generationPhase: "generating", mediaError: null,
  };
  if (!isRoot) {
    Object.assign(update, {
      startParentFrameHash: fromHash, startImageSourceUrl: fromUrl,
      startImageStatus: "ready",
      ...(parentWidth !== null ? {startImageWidth: parentWidth} : {}),
      ...(parentHeight !== null ? {startImageHeight: parentHeight} : {}),
    });
  }
  await beginMedia(db, storyId, nodeId, "video", update);
  try {
    const job = await request({startUrl: fromUrl, prompt});
    await writeMedia(db, storyId, nodeId, {videoJobId: job.jobId});
    if (job.videoUrl) {
      return await finishVideo(
        db, storyId, nodeId, job.jobId, fromHash, job.videoUrl,
        deps
      );
    }
    return {
      nodeId,
      videoStatus: "pending",
      videoFromHash: fromHash,
      videoJobId: job.jobId,
      videoUrl: optString(node.videoUrl),
      poll: job.jobId.startsWith(openRouterJobPrefix),
    };
  } catch (error) {
    await failVideo(db, storyId, nodeId, (error as Error).message);
    throw error;
  }
};

/**
 * Authenticated uid or bust, mirroring the other create callables.
 * @param {unknown} uid Caller uid.
 */
const assertUid = (uid: unknown): void => {
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
};

/**
 * Parses the frame selector. Only the root S is generatable; the
 * extracted clip end is never authored.
 * @param {unknown} value Raw `which`.
 * @return {FrameWhich} The frame.
 */
const parseWhich = (value: unknown): FrameWhich => {
  if (value === "start") return value;
  throw new HttpsError(
    "invalid-argument",
    "which must be \"start\"."
  );
};

/**
 * Loads the story + node, enforcing author-owned draft like the other
 * create callables.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {string} storyId Story id.
 * @param {string} nodeId Node id.
 * @return {Promise<Object>} The story and node fields.
 */
const loadDraftNode = async (
  db: Db,
  uid: string,
  storyId: string,
  nodeId: string
): Promise<{
  story: {[field: string]: unknown};
  node: {[field: string]: unknown};
}> => {
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
  const nodeSnap = await db.doc(`stories/${storyId}/nodes/${nodeId}`).get();
  if (!nodeSnap.exists) {
    throw new HttpsError("not-found", "Node not found.");
  }
  return {story, node: docData(nodeSnap, "Node")};
};

/**
 * Node title for prompt fallbacks; blanks become "untitled".
 * @param {Object} node Node fields.
 * @return {string} The title.
 */
const titleOf = (node: {[field: string]: unknown}): string => {
  const title = optString(node.title);
  return title === null || title === "" ? "untitled" : title;
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
 * Rich still prompt from the story bible, the narrator line, and the
 * clip context. The still anchors the clip start, so the prompt
 * describes a stable opening composition. Stored and author prompts
 * still win — this only replaces the old one-line title fallback.
 * Pure so tests pin the copy without a Db.
 * @param {Object} story Draft story fields.
 * @param {Object} node Draft node fields.
 * @return {string} The image prompt.
 */
export const buildImagePrompt = (
  story: {[field: string]: unknown},
  node: {[field: string]: unknown}
): string => {
  const storyTitle = clip(story.title, 60) || "Untitled story";
  const synopsis = clip(story.synopsis, 300).replace(/[.\s]+$/, "");
  const scene = clip(node.title, 60) || "Untitled scene";
  const line = clip(node.ttsText, 280);
  const ending = clip(node.endingName, 40);
  const clipContext = clip(node.videoPrompt, 200);
  const frame = "Opening frame: wide establishing composition, " +
    "subject entering, room for the scene to unfold.";
  const parts = [
    "Vertical 9:16 cinematic film still, 480x854, photorealistic, " +
    "no text, no watermark, no logo.",
    `STORY: "${storyTitle}"${synopsis === "" ? "" : ` — ${synopsis}`}.`,
    `SCENE: "${scene}".`,
    ...(line === "" ? [] : [`MOMENT (narrator line): "${line}".`]),
    ...(ending === "" ? [] : [`This is an ending: "${ending}".`]),
    `FRAME: ${frame}`,
    ...(clipContext === "" ? [] : [`CLIP CONTEXT: ${clipContext}.`]),
  ];
  return parts.join(" ");
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
 * Still provider preference: a Meta key wins (no GPU to reach),
 * ComfyUI is the fallback, else null so the caller fails with a reason.
 * Pure env read so tests pin the ordering without billing a provider.
 * @return {string | null} The provider kind, or null.
 */
export const imageProviderKind = imageProvider;

/**
 * Default still provider: Meta first, ComfyUI fallback, else null
 * so the caller fails with a reason instead of billing what it cannot reach.
 * Shared with the story cover callable, which bills the same still path.
 * @return {ImageGenFn | null} The provider, or null.
 */
export const defaultImageGen = (): ImageGenFn | null => {
  const kind = imageProviderKind();
  if (kind === "meta") {
    const config = metaConfig();
    return async (prompt: string) => ({
      bytes: await generateImageMeta({
        apiKey: config.apiKey,
        model: config.imageModel,
        prompt,
        size: stillSize,
      }),
    });
  }
  if (kind === "comfy") {
    const client = new ComfyClient({});
    return async (prompt: string) => {
      const image = await client.textToImage({
        prompt,
        width: stillWidth,
        height: stillHeight,
      });
      return {bytes: image.bytes};
    };
  }
  return null;
};

/**
 * Default still uploader: versioned Storage path keyed by the hash, so
 * regens never collide and URLs stay stable per bytes.
 * @return {StillUploadFn} The uploader.
 */
const defaultStillUpload = (): StillUploadFn => {
  return async (args) => {
    const path =
      `stories/${args.storyId}/${args.nodeId}-${args.which}-` +
      `${args.hash}.png`;
    const bucket = admin.storage().bucket();
    const file = bucket.file(path);
    await file.save(args.bytes, {metadata: {contentType: "image/png"}});
    return readableStorageUrl(file);
  };
};

/**
 * Stored video jobs from OpenRouter carry this prefix, so a later tap
 * resumes the same job instead of billing a duplicate submit.
 */
const openRouterJobPrefix = "or_";

/**
 * Default video submitter: OpenRouter when keyed, else null so the
 * caller fails with a reason instead of throwing without credentials.
 * Sends the start frame only (HeyGen supports `first_frame` only).
 * @return {VideoRequestFn | null} The submitter, or null.
 */
const defaultRequestVideo = (): VideoRequestFn | null => {
  const config = openRouterConfig();
  const apiKey = config.apiKey;
  if (!apiKey) return null;
  const video = videoConfig();
  return async ({startUrl, prompt}) => {
    try {
      const {jobId} = await submitVideo({
        apiKey,
        model: config.videoModel,
        prompt,
        startUrl,
        resolution: video.resolution,
        aspectRatio: video.aspectRatio,
        duration: video.duration,
      });
      return {jobId: `${openRouterJobPrefix}${jobId}`};
    } catch (error) {
      if (error instanceof OpenRouterHttpError) {
        throw new HttpsError(
          "unavailable",
          `Video request failed: ${error.status}.`
        );
      }
      throw error;
    }
  };
};

/**
 * Default job poll: OpenRouter status with the download URL on completion.
 * A missing key throws, so the resume path fails the node with a reason
 * instead of leaving `pending` behind.
 * @return {VideoCheckFn} The poller.
 */
const defaultCheckVideo = (): VideoCheckFn => {
  return async (jobId: string) => {
    const apiKey = openRouterConfig().apiKey;
    if (!apiKey) {
      throw new HttpsError(
        "failed-precondition",
        "Video provider credentials are missing."
      );
    }
    return checkVideo({apiKey, jobId});
  };
};

/**
 * Default clip downloader: content URL with auth, same as polling.
 * @return {VideoDownloadFn} The downloader.
 */
const defaultDownloadVideo = (): VideoDownloadFn => {
  return async (url: string) => {
    const apiKey = openRouterConfig().apiKey;
    return downloadBytes(url, {apiKey: new URL(url).origin ===
      new URL(openRouterConfig().videosUrl).origin ? apiKey : ""});
  };
};

/**
 * Default clip uploader: versioned Storage path keyed by the hash, so
 * repolls never collide and URLs stay stable per bytes.
 * @return {VideoStoreFn} The uploader.
 */
const defaultUploadVideo = (): VideoStoreFn => {
  return async (args) => {
    const path =
      `stories/${args.storyId}/${args.nodeId}-video-` + `${args.hash}.mp4`;
    const bucket = admin.storage().bucket();
    const file = bucket.file(path);
    await file.save(args.bytes, {metadata: {contentType: "video/mp4"}});
    return readableStorageUrl(file);
  };
};

/**
 * Follows one stored OpenRouter job: checks status once; on completion
 * downloads the clip, probes its length, stores it, and marks the node
 * ready (the client picks the URL up on its next poll). Pending stays
 * pending for the client to re-poll; terminal states clear the job and
 * fail so the next tap starts fresh instead of re-checking a dead job.
 * @param {Db} db Firestore.
 * @param {string} storyId Story id.
 * @param {string} nodeId Node id.
 * @param {string} storedJob Stored `or_`-prefixed job id.
 * @param {string} fromHash Verified S hash for the result echo.
 * @param {NodeMediaDeps} deps Injectable provider seams.
 * @return {Promise<GenerateNodeVideoResult>} The job state plus poll flag.
 */
const resumeVideoJob = async (
  db: Db,
  storyId: string,
  nodeId: string,
  storedJob: string,
  fromHash: string,
  deps: NodeMediaDeps
): Promise<GenerateNodeVideoResult> => {
  try {
    const outcome = await (deps.checkVideo ?? defaultCheckVideo())(
      storedJob.slice(openRouterJobPrefix.length));
    if (
      ["pending", "queued", "in_progress", "processing"].includes(
        outcome.status
      )
    ) {
      return {
        nodeId,
        videoStatus: "pending",
        videoFromHash: fromHash,
        videoJobId: storedJob,
        videoUrl: null,
        poll: true,
      };
    }
    if (outcome.status !== "completed" || !outcome.videoUrl) {
      throw new HttpsError("internal", "Video generation failed.");
    }
    return await finishVideo(
      db, storyId, nodeId, storedJob, fromHash,
      outcome.videoUrl, deps
    );
  } catch (error) {
    // Transient service errors can be resumed with the same provider job.
    if (error instanceof OpenRouterHttpError && error.status >= 500) {
      throw new HttpsError(
        "unavailable",
        `Video status check failed: ${error.status}.`
      );
    }
    await failVideo(db, storyId, nodeId, (error as Error).message, storedJob);
    if (error instanceof OpenRouterHttpError && error.status === 404) {
      throw new HttpsError(
        "internal",
        "The video job expired before finishing."
      );
    }
    throw error;
  }
};

const failVideo = async (
  db: Db,
  storyId: string,
  nodeId: string,
  message: string,
  expectedJob?: string
): Promise<void> => {
  await writeMedia(
    db,
    storyId,
    nodeId,
    {
      videoStatus: "failed",
      videoJobId: null,
      generationKind: null,
      generationPhase: null,
      mediaError: message,
    },
    (node) => {
      if (expectedJob != null && node.videoJobId !== expectedJob) {
        throw new Error("Superseded video job.");
      }
    }
  ).catch(() => undefined);
};

const finishVideo = async (
  db: Db, storyId: string, nodeId: string, jobId: string, fromHash: string,
  sourceUrl: string, deps: NodeMediaDeps
): Promise<GenerateNodeVideoResult> => {
  await writeMedia(db, storyId, nodeId, {generationPhase: "processing"});
  try {
    const raw = await (deps.downloadVideo ?? defaultDownloadVideo())(sourceUrl);
    const out = await (deps.normalizeVideo ?? normalizeGeneratedVideo)(raw);
    const hash = sha8(out.bytes);
    const videoUrl = await (deps.uploadVideo ?? defaultUploadVideo())({
      storyId, nodeId, hash, bytes: out.bytes,
    });
    const frameHash = sha8(out.lastFrame);
    const frameUrl = await (deps.uploadStill ?? defaultStillUpload())({
      storyId, nodeId, which: "end", hash: frameHash, bytes: out.lastFrame,
    });
    await writeMedia(db, storyId, nodeId, {videoStatus: "ready", videoUrl,
      videoJobId: jobId, videoWidth: out.width, videoHeight: out.height,
      durationSeconds: out.durationSeconds, videoFrameLastUrl: frameUrl,
      videoFrameLastHash: frameHash,
      videoFrameLastBlurData: out.lastBlurData, generationKind: null,
      generationPhase: null, mediaError: null}, (fresh) => {
      if (
        fresh.videoJobId !== jobId ||
        (fresh.videoFromHash != null && fresh.videoFromHash !== fromHash)
      ) {
        throw new HttpsError(
          "aborted",
          "Frames or video request changed while processing."
        );
      }
    });
    // Children inherit S from this clip's last frame: any child still
    // linked to an older hash idles, never silently stale. Best-effort
    // after the ready-write; the next request re-links them anyway.
    const linked = await db
      .collection(`stories/${storyId}/nodes`)
      .where("startFromNodeId", "==", nodeId)
      .get();
    for (const child of linked.docs) {
      const fields = child.data() ?? {};
      if (optString(fields.startParentFrameHash) === frameHash) continue;
      await writeMedia(
        db, storyId, child.id, {videoStatus: "idle", videoUrl: null}
      ).catch(() => undefined);
    }
    return {
      nodeId,
      videoStatus: "ready",
      videoFromHash: fromHash,
      videoJobId: jobId,
      videoUrl,
      poll: false,
      videoWidth: out.width,
      videoHeight: out.height,
      durationSeconds: out.durationSeconds,
    };
  } catch (error) {
    // Download, normalize, upload, and the ready-write all leave a `pending`
    // job hanging when they throw, so fail here with the reason. The expected
    // job guard keeps a superseding request's `pending` intact.
    await failVideo(db, storyId, nodeId, (error as Error).message, jobId);
    throw error instanceof HttpsError ? error :
      new HttpsError(
        "internal",
        `Video processing failed: ${(error as Error).message}`
      );
  }
};

/**
 * Records generation start once a provider is confirmed: status
 * `pending`, approval cleared, last good bytes kept so the portal and
 * FrameCompare still render while the job runs.
 * @param {Db} db Firestore.
 * @param {string} storyId Story id.
 * @param {string} nodeId Node id.
 * @param {FrameWhich} which Frame side (always `start`).
 * @param {string} prompt Prompt used.
 * @param {Object} opts Whether to adopt a missing root link.
 * @return {Promise<Object>} The pending payload core.
 */
const markImagePending = async (
  db: Db,
  storyId: string,
  nodeId: string,
  which: FrameWhich,
  prompt: string
): Promise<Omit<GenerateNodeImageResult, "desyncedNodeIds">> => {
  const update: Record<string, unknown> = {
    startImageStatus: "pending",
    startImagePrompt: prompt,
    startImageApproved: false,
    generationKind: "startImage",
    generationPhase: "generating",
    mediaError: null,
  };
  await beginMedia(db, storyId, nodeId, "startImage", update);
  const snap = await db.doc(`stories/${storyId}/nodes/${nodeId}`).get();
  const node = docData(snap, "Node");
  return {
    nodeId,
    which,
    imageStatus: "pending",
    imageUrl: optString(node.startImageSourceUrl),
  };
};

/**
 * Applies a ready S: stores bytes URL + hash, clears approval, and
 * idles the node's own video when its `videoFromHash` no longer fits.
 * @param {Db} db Firestore.
 * @param {string} storyId Story id.
 * @param {string} nodeId Node id.
 * @param {Object} still Prompt, URL, and hash.
 * @return {Promise<GenerateNodeImageResult>} The still status.
 */
const applyStartReady = async (
  db: Db,
  storyId: string,
  nodeId: string,
  still: {
    prompt: string;
    url: string;
    hash: string;
    width: number;
    height: number;
  }
): Promise<GenerateNodeImageResult> => {
  const ref = db.doc(`stories/${storyId}/nodes/${nodeId}`);
  const snap = await ref.get();
  const node = docData(snap, "Node");
  const update: Record<string, unknown> = {
    startImageSourceUrl: still.url,
    startImageStatus: "ready",
    startHash: still.hash,
    startImagePrompt: still.prompt,
    startImageApproved: false,
    startImageWidth: still.width, startImageHeight: still.height,
    generationKind: null, generationPhase: null, mediaError: null,
  };
  const fromHash = optString(node.videoFromHash);
  if (fromHash !== null && fromHash !== still.hash) {
    update.videoStatus = "idle";
    update.videoUrl = null;
  }
  await writeMedia(db, storyId, nodeId, update);
  return {
    nodeId,
    which: "start",
    imageStatus: "ready",
    imageUrl: still.url,
    width: still.width, height: still.height,
    desyncedNodeIds: [],
  };
};
