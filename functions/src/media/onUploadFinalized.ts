import * as admin from "firebase-admin";
import {execFile} from "child_process";
import {createHash} from "crypto";
import {mkdtemp, readFile, rm} from "fs/promises";
import {tmpdir} from "os";
import {join} from "path";
import {promisify} from "util";
import {onObjectFinalized} from "firebase-functions/v2/storage";
import {Db, docData} from "../feed/shared";
import {ffmpegBin} from "./bin";
import {ProcessedVideo, processVideo} from "./processVideo";

const run = promisify(execFile);

/** Max upload the trigger accepts: 100 MB, mirroring storage.rules. */
export const maxUploadBytes = 100 * 1024 * 1024;

/** Upload object layout the client writes; the trigger parses the rest. */
export const uploadsPrefix = "uploads/";

/** Accepted upload containers: mp4 or mov, case-insensitive. */
const uploadExt = /\.(mp4|mov)$/i;

/** Content types storage.rules allows under uploads/. */
const acceptedTypes: Record<string, true> = {
  "video/mp4": true,
  "video/quicktime": true,
};

/** Minimal object metadata the core needs; matches StorageObjectData. */
export interface UploadObject {
  name?: string | null;
  bucket?: string | null;
  size?: string | number | null;
  contentType?: string | null;
  generation?: string | null;
}

/** Injectable seams so tests run without Storage, ffmpeg, or Firestore. */
export interface UploadFinalizeDeps {
  download?: (objectName: string, destPath: string) => Promise<void>;
  process?: (inputPath: string, outDir: string) => Promise<ProcessedVideo>;
  uploadBytes?: (
    destPath: string,
    bytes: Buffer,
    contentType: string
  ) => Promise<string>;
  readLocal?: (path: string) => Promise<Buffer>;
  deleteObject?: (objectName: string) => Promise<void>;
  hasTools?: () => Promise<boolean>;
}

/** Outcome of one finalize pass; the client reads node fields, not this. */
export type FinalizeStatus =
  | "ready"
  | "rejected"
  | "duplicate"
  | "pending"
  | "ignored";

/** Terminal summary: what happened to the upload and the node. */
export interface FinalizeResult {
  status: FinalizeStatus;
  storyId?: string;
  nodeId?: string;
  videoUrl?: string;
  endHash?: string;
  uploadError?: string | null;
}

/**
 * Storage trigger: re-encodes one author upload into node video + E.
 * Nobody calls it; `onObjectFinalized` fires on every finalized object,
 * so objects outside `uploads/` are ignored, never deleted. The bucket
 * is explicit because registration throws without one when unit tests
 * import this module with no `FIREBASE_CONFIG`.
 */
export const onUploadFinalized = onObjectFinalized(
  {bucket: triggerBucket()},
  async (event) => {
    if (admin.apps.length === 0) {
      admin.initializeApp();
    }
    const data = event.data;
    await finalizeUploadWith(admin.firestore() as unknown as Db, {
      name: data.name ?? null,
      bucket: data.bucket ?? null,
      size: (data.size as string | number | null) ?? null,
      contentType: data.contentType ?? null,
      generation: data.generation == null ? null : String(data.generation),
    });
  }
);

/**
 * Default bucket in Cloud, dummy when unit tests register the trigger
 * with no `FIREBASE_CONFIG`.
 * @return {string} The trigger bucket.
 */
function triggerBucket(): string {
  try {
    const config = JSON.parse(process.env.FIREBASE_CONFIG ?? "{}") as {
      storageBucket?: unknown;
    };
    if (typeof config.storageBucket === "string") {
      return config.storageBucket;
    }
  } catch {
    return "demo-test-bucket";
  }
  return "demo-test-bucket";
}

/**
 * Testable core of `onUploadFinalized`. Rejects leave the node video
 * status untouched and record `uploadError` for the client; success
 * stores the re-encoded video, extracts E as the last frame (hash +
 * approval reset, children desynced like #47), then deletes the upload.
 * @param {Db} db Firestore.
 * @param {UploadObject} object Finalized object metadata.
 * @param {UploadFinalizeDeps} deps Injectable Storage/ffmpeg seams.
 * @return {Promise<FinalizeResult>} The finalize summary.
 */
export const finalizeUploadWith = async (
  db: Db,
  object: UploadObject,
  deps: UploadFinalizeDeps = {}
): Promise<FinalizeResult> => {
  const name = object.name ?? "";
  if (!name.startsWith(uploadsPrefix)) {
    return {status: "ignored"};
  }
  const parsed = parseUploadName(name);
  if (!parsed) {
    await safeDelete(deps, name);
    return {status: "rejected", uploadError: "unknown-target"};
  }
  const {uid, storyId, nodeId, takeId} = parsed;

  const extOk = uploadExt.test(name);
  const type = (object.contentType ?? "").toLowerCase();
  if (!extOk || (object.contentType != null && !acceptedTypes[type])) {
    await rejectOnNode(db, deps, storyId, nodeId, name, "invalid-type", takeId);
    return {status: "rejected", storyId, nodeId, uploadError: "invalid-type"};
  }
  const size = Number(object.size);
  if (Number.isFinite(size) && size > maxUploadBytes) {
    await rejectOnNode(db, deps, storyId, nodeId, name, "too-large", takeId);
    return {status: "rejected", storyId, nodeId, uploadError: "too-large"};
  }

  const storySnap = await db.doc(`stories/${storyId}`).get();
  if (!storySnap.exists) {
    await safeDelete(deps, name);
    return {status: "rejected", storyId, nodeId, uploadError: "unknown-target"};
  }
  const story = docData(storySnap, "Story");
  if (story.authorId !== uid) {
    await rejectOnNode(db, deps, storyId, nodeId, name, "not-author", takeId);
    return {status: "rejected", storyId, nodeId, uploadError: "not-author"};
  }
  if (story.status !== "draft") {
    await rejectOnNode(db, deps, storyId, nodeId, name, "not-draft", takeId);
    return {status: "rejected", storyId, nodeId, uploadError: "not-draft"};
  }
  const nodeRef = db.doc(`stories/${storyId}/nodes/${nodeId}`);
  const nodeSnap = await nodeRef.get();
  if (!nodeSnap.exists) {
    await safeDelete(deps, name);
    return {status: "rejected", storyId, nodeId, uploadError: "unknown-target"};
  }
  const node = docData(nodeSnap, "Node");

  if (
    node.uploadObjectName === name &&
    (node.uploadGeneration ?? null) === (object.generation ?? null)
  ) {
    await safeDelete(deps, name);
    return {status: "duplicate", storyId, nodeId};
  }

  const tools = deps.hasTools ?? defaultHasTools;
  if (!(await tools())) {
    await nodeRef.set(
      {
        videoSource: "upload",
        videoStatus: node.videoStatus === "ready" ? "ready" : "pending",
        uploadObjectName: name,
        uploadGeneration: object.generation ?? null,
        uploadTakeId: takeId,
        uploadError: "encode-unavailable",
      },
      {merge: true}
    );
    await safeDelete(deps, name);
    return {
      status: "pending",
      storyId,
      nodeId,
      uploadError: "encode-unavailable",
    };
  }

  const download = deps.download ?? defaultDownload;
  const process = deps.process ?? processVideo;
  const uploadBytes = deps.uploadBytes ?? defaultUploadBytes;
  const readLocal = deps.readLocal ?? readFile;
  const dir = await mkdtemp(join(tmpdir(), "ramifica-upload-"));
  try {
    const suffix = name.toLowerCase().endsWith(".mov") ? ".mov" : ".mp4";
    const inputPath = join(dir, `input${suffix}`);
    await download(name, inputPath);
    const out = await process(inputPath, dir);
    const frameBytes = await readLocal(out.lastFramePath);
    const endHash = createHash("sha256")
      .update(frameBytes)
      .digest("hex")
      .slice(0, 8);
    const videoBytes = await readLocal(out.videoPath);
    const videoHash = createHash("sha256")
      .update(videoBytes)
      .digest("hex")
      .slice(0, 8);
    const videoUrl = await uploadBytes(
      `stories/${storyId}/${nodeId}-upload-${videoHash}.mp4`,
      videoBytes,
      "video/mp4"
    );
    const frameUrl = await uploadBytes(
      `stories/${storyId}/${nodeId}-end-${endHash}.png`,
      frameBytes,
      "image/png"
    );
    const desynced = await childIdsDesyncedBy(db, storyId, nodeId, endHash);
    await db.runTransaction(async (tx) => {
      tx.set(
        nodeRef,
        {
          videoSource: "upload",
          videoStatus: "ready",
          videoUrl,
          videoJobId: `upload_${object.generation ?? "local"}`,
          videoToHash: endHash,
          durationSeconds: out.durationSeconds,
          pauseAtSeconds: out.pauseAtSeconds,
          videoFrameLastUrl: frameUrl,
          endImageSourceUrl: frameUrl,
          endImageStatus: "ready",
          endHash,
          endImageSource: "upload",
          endImageApproved: false,
          uploadObjectName: name,
          uploadGeneration: object.generation ?? null,
          uploadTakeId: takeId,
          uploadError: null,
        },
        {merge: true}
      );
      for (const childId of desynced) {
        tx.set(
          db.doc(`stories/${storyId}/nodes/${childId}`),
          {videoStatus: "idle", videoUrl: null},
          {merge: true}
        );
      }
    });
    await safeDelete(deps, name);
    return {status: "ready", storyId, nodeId, videoUrl, endHash};
  } catch (error) {
    await nodeRef.set(
      {
        uploadObjectName: name,
        uploadGeneration: object.generation ?? null,
        uploadTakeId: takeId,
        uploadError: "encode-failed",
      },
      {merge: true}
    );
    await safeDelete(deps, name);
    throw error;
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
};

/**
 * Parsed upload target: node coordinates plus the client take marker.
 * Filenames split as `{storyId}_{nodeId}[_{takeId}]`; auto ids and
 * client take ids never contain `_`, so two or three parts route.
 */
export interface UploadTarget {
  uid: string;
  storyId: string;
  nodeId: string;
  takeId: string | null;
}

/**
 * Splits the upload filename into its target, or null when the shape
 * is wrong. Anything else is rejected without touching a node.
 * @param {string} name Object name.
 * @return {Object} The upload coordinates, or null.
 */
export const parseUploadName = (name: string): UploadTarget | null => {
  const match = /^uploads\/([^/]+)\/([^/]+)$/.exec(name);
  if (!match) return null;
  const base = match[2];
  if (!uploadExt.test(base)) return null;
  const stem = base.replace(uploadExt, "");
  const parts = stem.split("_");
  if (parts.length < 2 || parts.length > 3) return null;
  if (parts.some((part) => part === "")) return null;
  return {
    uid: match[1],
    storyId: parts[0],
    nodeId: parts[1],
    takeId: parts.length === 3 ? parts[2] : null,
  };
};

/**
 * Records a validation rejection on the node when it exists, leaving
 * every video/status field untouched, then deletes the upload. The
 * take marker lands alongside so the client can poll for its own take.
 * @param {Db} db Firestore.
 * @param {UploadFinalizeDeps} deps Injectable seams.
 * @param {string} storyId Story id.
 * @param {string} nodeId Node id.
 * @param {string} name Upload object name.
 * @param {string} code Machine-readable client error.
 * @param {string} takeId Client take marker, or null.
 */
const rejectOnNode = async (
  db: Db,
  deps: UploadFinalizeDeps,
  storyId: string,
  nodeId: string,
  name: string,
  code: string,
  takeId: string | null
): Promise<void> => {
  try {
    const snap = await db.doc(`stories/${storyId}/nodes/${nodeId}`).get();
    if (snap.exists) {
      await db
        .doc(`stories/${storyId}/nodes/${nodeId}`)
        .set(
          {uploadObjectName: name, uploadError: code, uploadTakeId: takeId},
          {merge: true}
        );
    }
  } finally {
    await safeDelete(deps, name);
  }
};

/**
 * Children still linked to the old E: their `startParentEndHash` stays
 * as the mismatch evidence while their video idles, per #47 semantics.
 * @param {Db} db Firestore.
 * @param {string} storyId Story id.
 * @param {string} nodeId Changed node id.
 * @param {string} endHash Fresh E hash.
 * @return {Promise<string[]>} Desynced child ids.
 */
const childIdsDesyncedBy = async (
  db: Db,
  storyId: string,
  nodeId: string,
  endHash: string
): Promise<string[]> => {
  const query = await db
    .collection(`stories/${storyId}/nodes`)
    .where("startFromNodeId", "==", nodeId)
    .get();
  return query.docs
    .filter((child) => {
      const fields = child.data() ?? {};
      const linked = fields["startParentEndHash"];
      return typeof linked !== "string" || linked !== endHash;
    })
    .map((child) => child.id);
};

/**
 * Best-effort source cleanup; finalize already recorded the outcome,
 * so a missing object is not a failure.
 * @param {UploadFinalizeDeps} deps Injectable seams.
 * @param {string} name Object name.
 */
const safeDelete = async (
  deps: UploadFinalizeDeps,
  name: string
): Promise<void> => {
  const remove = deps.deleteObject ?? defaultDeleteObject;
  try {
    await remove(name);
  } catch {
    return;
  }
};

/**
 * ffmpeg presence probe: the emulator degrades to `pending` instead
 * of crashing when no binary is installed.
 * @return {Promise<boolean>} Whether encode.sh can run.
 */
const defaultHasTools = async (): Promise<boolean> => {
  try {
    await run(ffmpegBin(), ["-version"]);
    return true;
  } catch {
    return false;
  }
};

/**
 * Storage download for the default seam: object to a local tmp path.
 * @param {string} objectName Object name.
 * @param {string} destPath Local destination.
 */
const defaultDownload = async (
  objectName: string,
  destPath: string
): Promise<void> => {
  await admin.storage().bucket().file(objectName).download({
    destination: destPath,
  });
};

/**
 * Versioned Storage write for derived bytes; the hash keeps URLs
 * stable per bytes, like the still uploader in generateNodeMedia.
 * @param {string} destPath Destination object name.
 * @param {Buffer} bytes Derived bytes.
 * @param {string} contentType MIME type.
 * @return {Promise<string>} The signed read URL.
 */
const defaultUploadBytes = async (
  destPath: string,
  bytes: Buffer,
  contentType: string
): Promise<string> => {
  const file = admin.storage().bucket().file(destPath);
  await file.save(bytes, {metadata: {contentType}});
  const [url] = await file.getSignedUrl({
    action: "read",
    expires: "2100-01-01",
  });
  return url;
};

/**
 * Default source cleanup via the Admin SDK (bypasses storage.rules,
 * which rightly deny client deletes under uploads/).
 * @param {string} objectName Object name.
 */
const defaultDeleteObject = async (objectName: string): Promise<void> => {
  try {
    await admin.storage().bucket().file(objectName).delete({
      ignoreNotFound: true,
    });
  } catch {
    return;
  }
};
