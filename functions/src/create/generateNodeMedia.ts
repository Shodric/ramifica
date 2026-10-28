import * as admin from "firebase-admin";
import {createHash} from "crypto";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {
  cleanId,
  Db,
  docData,
  optString,
  requireUid,
  toRecord,
} from "../feed/shared";
import {ComfyClient} from "../media/comfy";

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

/** Injectable seams so tests run without GPU, Storage, or Seedance. */
export interface NodeMediaDeps {
  imageGen?: ImageGenFn;
  uploadStill?: StillUploadFn;
  requestVideo?: VideoRequestFn;
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
}

/** Cost guard: one still prompt cannot smuggle a novel into the bill. */
const maxPromptChars = 2000;

/** Still size matches the seed covers: 480x854 vertical. */
const stillWidth = 480;
const stillHeight = 854;

/**
 * Generates the S or E still for a draft node. S is root-only; E fits
 * any node. Without a provider (emulator, no COMFYUI_URL) it records
 * intent as `pending` and keeps the last good bytes. A ready E with a
 * new hash desyncs children: their video drops to `idle` while their
 * stale `startParentEndHash` stays as the mismatch evidence, and the
 * node's own video drops too when its `videoToHash` no longer fits.
 * @param {unknown} _req Unused callable wrapper slot.
 */
export const generateNodeImage = onCall(
  {enforceAppCheck: true, maxInstances: 10},
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
export const approveNodeImage = onCall(
  {enforceAppCheck: true, maxInstances: 20},
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
export const generateNodeVideo = onCall(
  {enforceAppCheck: true, maxInstances: 10},
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

  const fallback = `Vertical still, ${titleOf(node)}, no text.`;
  const storedPrompt =
    which === "start" ?
      optString(node.startImagePrompt) :
      optString(node.endImagePrompt);
  const prompt = promptOverride ?? storedPrompt ?? fallback;

  const gen = deps.imageGen ?? defaultImageGen();
  if (!gen) {
    const pending = await markImagePending(
      db,
      storyId,
      nodeId,
      which,
      prompt,
      story.rootNodeId === null ? {adoptRoot: true} : {}
    );
    return {...pending, desyncedNodeIds: []};
  }

  let bytes: Buffer;
  try {
    bytes = (await gen(prompt)).bytes;
  } catch (error) {
    await db.doc(`stories/${storyId}/nodes/${nodeId}`).set(
      {
        [which === "start" ? "startImageStatus" : "endImageStatus"]:
          "failed",
      },
      {merge: true}
    );
    throw new HttpsError(
      "internal",
      `Still generation failed: ${(error as Error).message}`
    );
  }
  const hash = sha8(bytes);
  const upload = deps.uploadStill ?? defaultStillUpload();
  const url = await upload({storyId, nodeId, which, hash, bytes});

  if (which === "start") {
    return applyStartReady(db, storyId, nodeId, {prompt, url, hash});
  }
  return applyEndReady(db, storyId, nodeId, node, {prompt, url, hash});
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
  const request = deps.requestVideo;
  const now = deps.now ?? (() => Date.now());
  let jobId = `pending_${nodeId}_${now()}`;
  let videoUrl: string | null = null;
  let videoStatus = "pending";
  if (request) {
    const job = await request({startUrl: fromUrl, endUrl, prompt});
    jobId = job.jobId;
    if (job.videoUrl) {
      videoUrl = job.videoUrl;
      videoStatus = "ready";
    }
  }

  const update: Record<string, unknown> = {
    videoStatus,
    videoSource: "generated",
    videoUrl,
    videoFromHash: fromHash,
    videoToHash: endHash,
    videoJobId: jobId,
    videoPrompt: prompt,
  };
  if (!isRoot) {
    update.startFromNodeId = optString(node.startFromNodeId);
    update.startParentEndHash = fromHash;
    update.startImageSourceUrl = fromUrl;
    update.startImageStatus = "ready";
  }
  await db.doc(`stories/${storyId}/nodes/${nodeId}`).set(update, {merge: true});
  return {
    nodeId,
    videoStatus,
    videoFromHash: fromHash,
    videoToHash: endHash,
    videoJobId: jobId,
    videoUrl,
  };
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
 * First 8 hex chars of the sha256: the hash-link version stamp.
 * @param {Buffer} bytes Raw bytes.
 * @return {string} The stamp.
 */
const sha8 = (bytes: Buffer): string => {
  return createHash("sha256").update(bytes).digest("hex").slice(0, 8);
};

/**
 * Default still provider: ComfyUI when configured, else null so the
 * caller records `pending` instead of burning a GPU it cannot reach.
 * @return {ImageGenFn | null} The provider, or null.
 */
const defaultImageGen = (): ImageGenFn | null => {
  if (!process.env.COMFYUI_URL) return null;
  const client = new ComfyClient({});
  return async (prompt: string) => {
    const image = await client.textToImage({
      prompt,
      width: stillWidth,
      height: stillHeight,
    });
    return {bytes: image.bytes};
  };
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
    const [url] = await file.getSignedUrl({
      action: "read",
      expires: "2100-01-01",
    });
    return url;
  };
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
  prompt: string,
  opts: {adoptRoot?: boolean} = {}
): Promise<Omit<GenerateNodeImageResult, "desyncedNodeIds">> => {
  const prefix = which === "start" ? "start" : "end";
  const update: Record<string, unknown> = {
    [`${prefix}ImageStatus`]: "pending",
    [`${prefix}ImagePrompt`]: prompt,
    [`${prefix}ImageApproved`]: false,
  };
  if (which === "end") update.endImageSource = "muse";
  if (opts.adoptRoot) {
    await db.doc(`stories/${storyId}`).set({rootNodeId: nodeId}, {merge: true});
  }
  await db.doc(`stories/${storyId}/nodes/${nodeId}`).set(update, {merge: true});
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
  still: {prompt: string; url: string; hash: string}
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
  };
  const fromHash = optString(node.videoFromHash);
  if (fromHash !== null && fromHash !== still.hash) {
    update.videoStatus = "idle";
    update.videoUrl = null;
  }
  await ref.set(update, {merge: true});
  return {
    nodeId,
    which: "start",
    imageStatus: "ready",
    imageUrl: still.url,
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
  still: {prompt: string; url: string; hash: string}
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
  await db.runTransaction(async (tx) => {
    const ref = db.doc(`stories/${storyId}/nodes/${nodeId}`);
    const update: Record<string, unknown> = {
      endImageSourceUrl: still.url,
      endImageStatus: "ready",
      endHash: still.hash,
      endImagePrompt: still.prompt,
      endImageSource: "muse",
      endImageApproved: false,
    };
    const toHash = optString(node.videoToHash);
    if (toHash !== null && toHash !== still.hash) {
      update.videoStatus = "idle";
      update.videoUrl = null;
    }
    tx.set(ref, update, {merge: true});
    for (const childId of desynced) {
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
    endHash: still.hash,
    desyncedNodeIds: desynced,
  };
};
