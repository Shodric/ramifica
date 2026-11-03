import * as admin from "firebase-admin";
import {HttpsError} from "firebase-functions/v2/https";
import {onCallSafe} from "../callable";
import {
  cleanId,
  Db,
  docData,
  isEmulator,
  optString,
  requireUid,
  toRecord,
} from "../feed/shared";

/**
 * Minted upload target: a resumable session URI the client PUTs chunks
 * to (`resumable`), or a one-shot media URL (`POST`, emulator only —
 * the emulator finalizes on the first chunk).
 */
export interface VideoUploadUrl {
  uploadUrl: string;
  path: string;
  method: "PUT" | "POST";
  resumable: boolean;
}

/** Injectable pieces so tests run without Storage. */
export interface UploadUrlDeps {
  bucketName?: string;
  emulatorHost?: string | null;
  fetchFn?: typeof fetch;
  accessToken?: () => Promise<string>;
}

/**
 * Upload constraints, mirroring storage.rules (`video/(mp4|quicktime)`,
 * <=10MB): the callable rejects what the rules would reject, before
 * minting anything.
 */
const maxUploadBytes = 10 * 1024 * 1024;
const uploadContentTypes = ["video/mp4", "video/quicktime"];

export const createVideoUploadUrl = onCallSafe(
  {enforceAppCheck: !isEmulator(), maxInstances: 10},
  async (req) => {
    const uid = requireUid(req.auth);
    return createVideoUploadUrlWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `createVideoUploadUrl`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, nodeId, takeId, contentType,
 * byteLength}`.
 * @param {UploadUrlDeps} deps Bucket, emulator, and signing overrides.
 * @return {Promise<VideoUploadUrl>} The upload target.
 */
export const createVideoUploadUrlWith = async (
  db: Db,
  uid: string,
  data: unknown,
  deps: UploadUrlDeps = {}
): Promise<VideoUploadUrl> => {
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  const nodeId = cleanId(fields.nodeId, "nodeId");
  const takeId = cleanId(fields.takeId, "takeId");
  if (takeId.includes("_")) {
    throw new HttpsError(
      "invalid-argument",
      "Take ids cannot contain underscores."
    );
  }
  const contentType = optString(fields.contentType);
  if (contentType === null || !uploadContentTypes.includes(contentType)) {
    throw new HttpsError(
      "invalid-argument",
      "Only MP4 and QuickTime clips can be uploaded."
    );
  }
  const byteLength = fields.byteLength;
  if (
    typeof byteLength !== "number" ||
    !Number.isInteger(byteLength) ||
    byteLength <= 0 ||
    byteLength > maxUploadBytes
  ) {
    throw new HttpsError(
      "invalid-argument",
      "Clips are limited to 10MB."
    );
  }

  const storySnap = await db.doc(`stories/${storyId}`).get();
  if (!storySnap.exists) {
    throw new HttpsError("not-found", "Story not found.");
  }
  const story = docData(storySnap, "Story");
  if (story.authorId !== uid) {
    throw new HttpsError("permission-denied", "Not your draft.");
  }
  if (story.status !== "draft") {
    throw new HttpsError(
      "failed-precondition",
      "Only drafts can upload clips."
    );
  }
  const nodeSnap = await db.doc(`stories/${storyId}/nodes/${nodeId}`).get();
  if (!nodeSnap.exists) {
    throw new HttpsError("not-found", "Node not found.");
  }

  const ext = contentType === "video/quicktime" ? "mov" : "mp4";
  const path = `uploads/${uid}/${storyId}_${nodeId}_${takeId}.${ext}`;
  const bucket = deps.bucketName ?? defaultBucketName();
  const emulatorHost =
    deps.emulatorHost ?? process.env.FIREBASE_STORAGE_EMULATOR_HOST ?? "";
  if (emulatorHost !== "") {
    // The emulator finalizes on the first chunk, so it takes the whole
    // object in one media upload instead of a session.
    return {
      uploadUrl:
        `http://${emulatorHost}/upload/storage/v1/b/${bucket}/o` +
        `?uploadType=media&name=${encodeURIComponent(path)}`,
      path,
      method: "POST",
      resumable: false,
    };
  }
  const token = deps.accessToken !== undefined ?
    await deps.accessToken() :
    await defaultAccessToken();
  const fetcher = deps.fetchFn ?? fetch;
  const init = await fetcher(
    `https://storage.googleapis.com/upload/storage/v1/b/${bucket}/o` +
      "?uploadType=resumable",
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json; charset=UTF-8",
        "X-Upload-Content-Type": contentType,
        "X-Upload-Content-Length": String(byteLength),
      },
      body: JSON.stringify({name: path, contentType}),
    }
  );
  const sessionUri = init.headers.get("location");
  if (!init.ok || sessionUri === null || sessionUri === "") {
    throw new HttpsError(
      "unavailable",
      "Could not start the upload session."
    );
  }
  return {uploadUrl: sessionUri, path, method: "PUT", resumable: true};
};

/**
 * Default bucket from the functions config, else `<project>.appspot.com`.
 * @return {string} The bucket name.
 */
const defaultBucketName = (): string => {
  try {
    const config = JSON.parse(process.env.FIREBASE_CONFIG ?? "{}") as {
      storageBucket?: unknown;
    };
    if (
      typeof config.storageBucket === "string" &&
      config.storageBucket !== ""
    ) {
      return config.storageBucket;
    }
  } catch {
    // Fall through to the project-derived name.
  }
  const project =
    process.env.GCLOUD_PROJECT ?? process.env.GOOGLE_CLOUD_PROJECT ?? "";
  if (project !== "") return `${project}.appspot.com`;
  throw new HttpsError(
    "failed-precondition",
    "Storage bucket is not configured."
  );
};

/**
 * OAuth token for the session initiation. Application-default
 * credentials cover Cloud and local runs alike; unlike signing, no
 * private key is needed.
 * @return {Promise<string>} The bearer token.
 */
const defaultAccessToken = async (): Promise<string> => {
  const credentials = admin.credential.applicationDefault();
  const {access_token: token} = await credentials.getAccessToken();
  if (token === null || token === "") {
    throw new HttpsError(
      "unavailable",
      "Could not start the upload session."
    );
  }
  return token;
};
