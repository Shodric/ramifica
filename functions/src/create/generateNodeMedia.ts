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
} from "../media/meta";
import {
  NormalizedStill, NormalizedVideo, normalizeStill, normalizeGeneratedVideo,
} from "../media/processVideo";
import {draftTransaction, writeMedia} from "../media/draftWrites";
import {readableStorageUrl} from "../media/storageUrl";

/** Which frame a still belongs to: `start` (root only) or `end`. */
export type FrameWhich = "start" | "end";

/** Raw still bytes from the image provider. */
export interface StillResult {
  bytes: Buffer;
}

/** Injectable still provider: prompt in, PNG bytes out. */
export interface ImageGenFn {
  (prompt: string): Promise<StillResult>;
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

/** Injectable Seedance-class video provider: S+E in, job out. */
export interface VideoRequestFn {
  (args: {
    startUrl: string;
    endUrl: string;
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
  endHash: string | null;
  desyncedNodeIds: string[];
  width?: number;
  height?: number;
}

/** Result of `approveNodeImage`. */
export interface ApproveNodeImageResult {
  nodeId: string;
  which: FrameWhich;
  approved: boolean;
}

/** Result of `generateNodeVideo`. */
export interface GenerateNodeVideoResult {
  nodeId: string;
  videoStatus: string;
  videoFromHash: string;
  videoToHash: string;
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
 * Generates the S or E still for a draft node. S is root-only; E fits
 * any node. Without a provider (emulator, no COMFYUI_URL) it records
 * intent as `pending` and keeps the last good bytes. A ready E with a
 * new hash desyncs children: their video drops to `idle` while their
 * stale `startParentEndHash` stays as the mismatch evidence, and the
 * node's own video drops too when its `videoToHash` no longer fits.
 * @param {unknown} _req Unused callable wrapper slot.
 */
export const generateNodeImage = onCallSafe(
  {
    enforceAppCheck: !isEmulator(), maxInstances: 10,
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
 * Approves (or, with `approved: false`, rejects) the S or E still after
 * the author eyeballs it. Approval is the video gate: a non-root child
 * inherits its S from the parent's approved E, the root from its own
 * approved S. Rejecting flips approval back without regen; it does not
 * cascade, since the bytes (and hashes) are unchanged.
 */
export const approveNodeImage = onCallSafe(
  {enforceAppCheck: !isEmulator(), maxInstances: 20},
  async (req) => {
    const uid = requireUid(req.auth);
    return approveNodeImageWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Requests the S-to-E video for a draft node. Gated on the approved S:
 * the parent's approved E for children (inherited as S by hash link),
 * the node's own approved S for the root. Without a video provider it
 * records the job as `pending`; it never keeps a stale video quietly.
 */
export const generateNodeVideo = onCallSafe(
  {
    enforceAppCheck: !isEmulator(), maxInstances: 10,
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

  const storedPrompt =
    which === "start" ?
      optString(node.startImagePrompt) :
      optString(node.endImagePrompt);
  const prompt =
    promptOverride ?? storedPrompt ?? buildImagePrompt(story, node, which);

  const gen = deps.imageGen ?? defaultImageGen();
  if (!gen) throw new HttpsError("failed-precondition", "Image provider credentials are missing.");
  await markImagePending(db, storyId, nodeId, which, prompt);
  try {
    const raw = (await gen(prompt)).bytes;
    await writeMedia(db, storyId, nodeId, {generationPhase: "processing"});
    const result = await (deps.normalizeImage ?? normalizeStill)(raw);
    const bytes = result.bytes;
    const hash = sha8(bytes);
    const url = await (deps.uploadStill ?? defaultStillUpload())({storyId, nodeId, which, hash, bytes});
    const still = {prompt, url, hash, width: result.width, height: result.height};
    return which === "start" ? await applyStartReady(db, storyId, nodeId, still) :
      await applyEndReady(db, storyId, nodeId, node, still);
  } catch (error) {
    await writeMedia(db, storyId, nodeId, {
      [`${which}ImageStatus`]: "failed", generationKind: null,
      generationPhase: null, mediaError: (error as Error).message,
    }).catch(() => undefined);
    throw new HttpsError("internal", `Still generation failed: ${(error as Error).message}`);
  }
};

/**
 * Testable core of `approveNodeImage`. `approved` defaults to true;
 * false rejects (un-approves) without regen.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, nodeId, which, approved?}`.
 * @return {Promise<ApproveNodeImageResult>} The approval.
 */
export const approveNodeImageWith = async (
  db: Db,
  uid: string,
  data: unknown
): Promise<ApproveNodeImageResult> => {
  assertUid(uid);
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  const nodeId = cleanId(fields.nodeId, "nodeId");
  const which = parseWhich(fields.which);
  const approved = parseApproved(fields.approved);

  const loaded = await loadDraftNode(db, uid, storyId, nodeId);
  const hashField = which === "start" ? "startHash" : "endHash";
  const hash = loaded.node[hashField];
  if (typeof hash !== "string" || hash === "") {
    throw new HttpsError(
      "failed-precondition",
      "Generate the frame before approving it."
    );
  }
  await db.doc(`stories/${storyId}/nodes/${nodeId}`).set(
    {[which === "start" ? "startImageApproved" : "endImageApproved"]: approved},
    {merge: true}
  );
  return {nodeId, which, approved};
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

  const endHash = optString(node.endHash);
  const endUrl =
    optString(node.endImageSourceUrl) ?? optString(node.endImageUrl);
  if (endHash === null || endUrl === null) {
    throw new HttpsError(
      "failed-precondition",
      "Generate the end frame before requesting video."
    );
  }

  let fromHash: string;
  let fromUrl: string;
  if (isRoot) {
    if (node.startImageApproved !== true) {
      throw new HttpsError(
        "failed-precondition",
        "Approve the start frame before requesting video."
      );
    }
    const hash = optString(node.startHash);
    const url = optString(node.startImageSourceUrl);
    if (hash === null || url === null) {
      throw new HttpsError(
        "failed-precondition",
        "Generate the start frame before requesting video."
      );
    }
    fromHash = hash;
    fromUrl = url;
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
    if (parent.endImageApproved !== true) {
      throw new HttpsError(
        "failed-precondition",
        "Approve the parent end frame before requesting video."
      );
    }
    const hash = optString(parent.endHash);
    const url =
      optString(parent.endImageSourceUrl) ?? optString(parent.endImageUrl);
    if (hash === null || url === null) {
      throw new HttpsError(
        "failed-precondition",
        "The parent end frame is not ready yet."
      );
    }
    fromHash = hash;
    fromUrl = url;
  }

  const prompt =
    promptOverride ??
    optString(node.videoPrompt) ??
    `Slow morph from S to E, ${titleOf(node)}, vertical video.`;
  const storedJob = optString(node.videoJobId);
  if (
    storedJob !== null &&
    storedJob.startsWith(openRouterJobPrefix) &&
    optString(node.videoStatus) === "pending"
  ) {
    if ((node.videoFromHash != null && node.videoFromHash !== fromHash) ||
        (node.videoToHash != null && node.videoToHash !== endHash)) {
      await failVideo(db, storyId, nodeId, "Frames changed during video generation.");
      throw new HttpsError("failed-precondition", "Frames changed; generate a new video.");
    }
    return resumeVideoJob(
      db,
      storyId,
      nodeId,
      storedJob,
      fromHash,
      endHash,
      deps
    );
  }
  const request = deps.requestVideo ?? defaultRequestVideo();
  if (!request) throw new HttpsError("failed-precondition", "Video provider credentials are missing.");
  const update: Record<string, unknown> = {
    videoStatus: "pending", videoSource: "generated", videoPrompt: prompt,
    videoFromHash: fromHash, videoToHash: endHash,
    generationKind: "video", generationPhase: "generating", mediaError: null,
  };
  if (!isRoot) Object.assign(update, {
    startParentEndHash: fromHash, startImageSourceUrl: fromUrl,
    startImageStatus: "ready", startImageWidth: mediaProfile.width,
    startImageHeight: mediaProfile.height,
  });
  await writeMedia(db, storyId, nodeId, update);
  try {
    const job = await request({startUrl: fromUrl, endUrl, prompt});
    await writeMedia(db, storyId, nodeId, {videoJobId: job.jobId});
    if (job.videoUrl) {
      return await finishVideo(db, storyId, nodeId, job.jobId, fromHash, endHash, job.videoUrl, deps);
    }
    return {nodeId, videoStatus: "pending", videoFromHash: fromHash,
      videoToHash: endHash, videoJobId: job.jobId,
      videoUrl: optString(node.videoUrl), poll: job.jobId.startsWith(openRouterJobPrefix)};
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
 * Parses the frame selector.
 * @param {unknown} value Raw `which`.
 * @return {FrameWhich} The frame.
 */
const parseWhich = (value: unknown): FrameWhich => {
  if (value === "start" || value === "end") return value;
  throw new HttpsError(
    "invalid-argument",
    "which must be \"start\" or \"end\"."
  );
};

/**
 * Parses the approval flag: missing or true approves, false rejects
 * (un-approves without regen).
 * @param {unknown} value Raw `approved`.
 * @return {boolean} Whether the frame counts as approved.
 */
const parseApproved = (value: unknown): boolean => {
  if (value === undefined || value === null) return true;
  if (typeof value === "boolean") return value;
  throw new HttpsError("invalid-argument", "approved must be a boolean.");
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
 * clip context. Stills anchor the S-to-E morph, so each prompt
 * describes a stable endpoint: the opening composition for `start`,
 * the payoff beat for `end`. Stored and author prompts still win —
 * this only replaces the old one-line title fallback. Pure so tests
 * pin the copy without a Db.
 * @param {Object} story Draft story fields.
 * @param {Object} node Draft node fields.
 * @param {FrameWhich} which Frame side.
 * @return {string} The image prompt.
 */
export const buildImagePrompt = (
  story: {[field: string]: unknown},
  node: {[field: string]: unknown},
  which: FrameWhich
): string => {
  const storyTitle = clip(story.title, 60) || "Untitled story";
  const synopsis = clip(story.synopsis, 300).replace(/[.\s]+$/, "");
  const scene = clip(node.title, 60) || "Untitled scene";
  const line = clip(node.ttsText, 280);
  const ending = clip(node.endingName, 40);
  const clipContext = clip(node.videoPrompt, 200);
  const frame =
    which === "start" ?
      "Opening frame: wide establishing composition, " +
      "subject entering, room for the scene to unfold." :
      "Closing frame: the payoff beat of the moment below, " +
      "stable centered composition, suitable as the end anchor " +
      "of a short video clip.";
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
 * ComfyUI is the fallback, else null so the caller records `pending`.
 * Pure env read so tests pin the ordering without billing a provider.
 * @return {string | null} The provider kind, or null.
 */
export const imageProviderKind = imageProvider;

/**
 * Default still provider: Meta first, ComfyUI fallback, else null
 * so the caller records `pending` instead of billing what it cannot reach.
 * @return {ImageGenFn | null} The provider, or null.
 */
const defaultImageGen = (): ImageGenFn | null => {
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
 * caller records `pending` instead of throwing without credentials.
 * Sends the start frame by default (HeyGen); optionally includes the end
 * frame when OPENROUTER_VIDEO_USE_END_FRAME enables a compatible model.
 * @return {VideoRequestFn | null} The submitter, or null.
 */
const defaultRequestVideo = (): VideoRequestFn | null => {
  const config = openRouterConfig();
  const apiKey = config.apiKey;
  if (!apiKey) return null;
  const video = videoConfig();
  return async ({startUrl, endUrl, prompt}) => {
    try {
      const {jobId} = await submitVideo({
        apiKey,
        model: config.videoModel,
        prompt,
        startUrl,
        ...(video.useEndFrame ? {endUrl} : {}),
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
 * Null credentials cannot happen for a stored job (submit needed the key),
 * so a missing key reads as still pending and the client cap bounds it.
 * @return {VideoCheckFn} The poller.
 */
const defaultCheckVideo = (): VideoCheckFn => {
  return async (jobId: string) => {
    const apiKey = openRouterConfig().apiKey;
    if (!apiKey) throw new HttpsError("failed-precondition", "Video provider credentials are missing.");
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
 * @param {string} endHash Verified E hash for the result echo.
 * @param {NodeMediaDeps} deps Injectable provider seams.
 * @return {Promise<GenerateNodeVideoResult>} The job state plus poll flag.
 */
const resumeVideoJob = async (
  db: Db,
  storyId: string,
  nodeId: string,
  storedJob: string,
  fromHash: string,
  endHash: string,
  deps: NodeMediaDeps
): Promise<GenerateNodeVideoResult> => {
  try {
    const outcome = await (deps.checkVideo ?? defaultCheckVideo())(
      storedJob.slice(openRouterJobPrefix.length));
    if (["pending", "queued", "in_progress", "processing"].includes(outcome.status)) {
      return {nodeId, videoStatus: "pending", videoFromHash: fromHash,
        videoToHash: endHash, videoJobId: storedJob, videoUrl: null, poll: true};
    }
    if (outcome.status !== "completed" || !outcome.videoUrl) {
      throw new HttpsError("internal", "Video generation failed.");
    }
    return await finishVideo(db, storyId, nodeId, storedJob, fromHash, endHash, outcome.videoUrl, deps);
  } catch (error) {
    // Transient service errors can be resumed with the same provider job.
    if (error instanceof OpenRouterHttpError && error.status >= 500) {
      throw new HttpsError("unavailable", `Video status check failed: ${error.status}.`);
    }
    await failVideo(db, storyId, nodeId, (error as Error).message);
    if (error instanceof OpenRouterHttpError && error.status === 404) {
      throw new HttpsError("internal", "The video job expired before finishing.");
    }
    throw error;
  }
};

const failVideo = async (db: Db, storyId: string, nodeId: string, message: string): Promise<void> => {
  await writeMedia(db, storyId, nodeId, {videoStatus: "failed", videoJobId: null,
    generationKind: null, generationPhase: null, mediaError: message}).catch(() => undefined);
};

const finishVideo = async (
  db: Db, storyId: string, nodeId: string, jobId: string, fromHash: string,
  endHash: string, sourceUrl: string, deps: NodeMediaDeps
): Promise<GenerateNodeVideoResult> => {
  await writeMedia(db, storyId, nodeId, {generationPhase: "processing"});
  const raw = await (deps.downloadVideo ?? defaultDownloadVideo())(sourceUrl);
  const out = await (deps.normalizeVideo ?? normalizeGeneratedVideo)(raw);
  const hash = sha8(out.bytes);
  const videoUrl = await (deps.uploadVideo ?? defaultUploadVideo())({storyId, nodeId, hash, bytes: out.bytes});
  const frameUrl = await (deps.uploadStill ?? defaultStillUpload())({storyId, nodeId,
    which: "end", hash: sha8(out.lastFrame), bytes: out.lastFrame});
  await writeMedia(db, storyId, nodeId, {videoStatus: "ready", videoUrl,
    videoJobId: jobId, videoWidth: out.width, videoHeight: out.height,
    durationSeconds: out.durationSeconds, videoFrameLastUrl: frameUrl,
    videoFrameLastBlurData: out.lastBlurData, generationKind: null,
    generationPhase: null, mediaError: null}, (fresh) => {
    if (fresh.videoJobId !== jobId ||
        (fresh.videoFromHash != null && fresh.videoFromHash !== fromHash) ||
        (fresh.videoToHash != null && fresh.videoToHash !== endHash) || fresh.endHash !== endHash) {
      throw new HttpsError("aborted", "Frames or video request changed while processing.");
    }
  });
  return {nodeId, videoStatus: "ready", videoFromHash: fromHash, videoToHash: endHash,
    videoJobId: jobId, videoUrl, poll: false, videoWidth: out.width,
    videoHeight: out.height, durationSeconds: out.durationSeconds};
};

/**
 * Records generation intent when no provider can run: status
 * `pending`, approval cleared, last good bytes kept so the portal and
 * FrameCompare still render while the job waits.
 * @param {Db} db Firestore.
 * @param {string} storyId Story id.
 * @param {string} nodeId Node id.
 * @param {FrameWhich} which Frame side.
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
  const prefix = which === "start" ? "start" : "end";
  const update: Record<string, unknown> = {
    [`${prefix}ImageStatus`]: "pending",
    [`${prefix}ImagePrompt`]: prompt,
    [`${prefix}ImageApproved`]: false,
    generationKind: `${prefix}Image`, generationPhase: "generating", mediaError: null,
  };
  if (which === "end") update.endImageSource = "muse";
  await writeMedia(db, storyId, nodeId, update);
  const snap = await db.doc(`stories/${storyId}/nodes/${nodeId}`).get();
  const node = docData(snap, "Node");
  return {
    nodeId,
    which,
    imageStatus: "pending",
    imageUrl:
      optString(node[`${prefix}ImageSourceUrl`]) ??
      (which === "end" ? optString(node.endImageUrl) : null),
    endHash: optString(node.endHash),
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
  still: {prompt: string; url: string; hash: string; width: number; height: number}
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
    endHash: optString(node.endHash),
    desyncedNodeIds: [],
  };
};

/**
 * Applies a ready E: stores bytes URL + hash, clears approval, idles
 * the node's own stale video, and desyncs every child still linked to
 * the old hash (their `startParentEndHash` stays as the evidence and
 * their video drops to `idle`, never silently stale).
 * @param {Db} db Firestore.
 * @param {string} storyId Story id.
 * @param {string} nodeId Node id.
 * @param {Object} node Current node fields.
 * @param {Object} still Prompt, URL, and hash.
 * @return {Promise<GenerateNodeImageResult>} The still status + desync.
 */
const applyEndReady = async (
  db: Db,
  storyId: string,
  nodeId: string,
  node: {[field: string]: unknown},
  still: {prompt: string; url: string; hash: string; width: number; height: number}
): Promise<GenerateNodeImageResult> => {
  const query = await db
    .collection(`stories/${storyId}/nodes`)
    .where("startFromNodeId", "==", nodeId)
    .get();
  const desynced = query.docs
    .map((doc) => ({id: doc.id, fields: doc.data() ?? {}}))
    .filter((child) => {
      return optString(child.fields.startParentEndHash) !== still.hash;
    })
    .map((child) => child.id);
  await draftTransaction(db, storyId, async (tx) => {
    const ref = db.doc(`stories/${storyId}/nodes/${nodeId}`);
    const fresh = await tx.get(ref);
    if (!fresh.exists) throw new HttpsError("not-found", "Node was deleted.");
    node = docData(fresh, "Node");
    const children = await Promise.all(desynced.map((id) => tx.get(db.doc(`stories/${storyId}/nodes/${id}`))));
    const update: Record<string, unknown> = {
      endImageSourceUrl: still.url,
      endImageStatus: "ready",
      endHash: still.hash,
      endImagePrompt: still.prompt,
      endImageSource: "muse",
      endImageApproved: false,
      endImageWidth: still.width, endImageHeight: still.height,
      generationKind: null, generationPhase: null, mediaError: null,
    };
    const toHash = optString(node.videoToHash);
    if (toHash !== null && toHash !== still.hash) {
      update.videoStatus = "idle";
      update.videoUrl = null;
    }
    tx.set(ref, update, {merge: true});
    for (const childId of desynced.filter((_, i) => children[i].exists)) {
      tx.set(
        db.doc(`stories/${storyId}/nodes/${childId}`),
        {videoStatus: "idle", videoUrl: null},
        {merge: true}
      );
    }
  });
  return {
    nodeId,
    which: "end",
    imageStatus: "ready",
    imageUrl: still.url,
    width: still.width, height: still.height,
    endHash: still.hash,
    desyncedNodeIds: desynced,
  };
};
