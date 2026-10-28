import {createHash, randomUUID} from "crypto";
import {readFileSync} from "fs";
import * as admin from "firebase-admin";

export interface SeedTarget {
  emulator: boolean;
  project: string;
  bucketName: string;
  storageHost: string;
}

/**
 * Admin SDK pointed at the emulator or at the real project. Emulator mode
 * needs no credentials; project mode uses application-default credentials.
 * @param {object} opts Target options.
 * @return {SeedTarget} Upload target.
 */
export function initTarget(opts: {
  emulator: boolean;
  project?: string;
}): SeedTarget {
  if (opts.emulator) {
    const project = opts.project ?? "demo-ramifica";
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
    process.env.STORAGE_EMULATOR_HOST = "http://127.0.0.1:9199";
    if (admin.apps.length === 0) {
      admin.initializeApp({
        projectId: project,
        storageBucket: `${project}.appspot.com`,
      });
    }
    return {
      emulator: true,
      project,
      bucketName: `${project}.appspot.com`,
      storageHost: "http://127.0.0.1:9199",
    };
  }
  if (!opts.project) {
    throw new Error("Pass --project <id> for a real project.");
  }
  if (admin.apps.length === 0) {
    admin.initializeApp();
  }
  const bucketName = `${opts.project}.appspot.com`;
  return {
    emulator: false,
    project: opts.project,
    bucketName,
    storageHost: "https://firebasestorage.googleapis.com",
  };
}

/** Content sha, first 8 hex chars, for versioned storage names.
 * @param {Buffer} bytes File bytes.
 * @return {string} The hash.
 */
export function sha8(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex").slice(0, 8);
}

export interface UploadedFile {
  url: string;
  hash: string;
}

/**
 * Uploads a file under a content-hashed name, skipping the bytes when the
 * name already exists. Download URLs carry a token so players can read
 * them with plain HTTP, in the emulator and in production.
 * @param {SeedTarget} target Upload target.
 * @param {string} destDir Storage prefix.
 * @param {string} prefix File prefix.
 * @param {string} ext Extension without dot.
 * @param {string} contentType MIME type.
 * @param {string} srcPath Local file.
 * @return {Promise<UploadedFile>} URL and hash.
 */
export async function uploadVersioned(
  target: SeedTarget,
  destDir: string,
  prefix: string,
  ext: string,
  contentType: string,
  srcPath: string
): Promise<UploadedFile> {
  const hash = sha8(readFileSync(srcPath));
  const name = `${destDir}/${prefix}-${hash}.${ext}`;
  const bucket = admin.storage().bucket(target.bucketName);
  const file = bucket.file(name);
  const [exists] = await file.exists();
  let token: string;
  if (exists) {
    const [metadata] = await file.getMetadata();
    const stored = (metadata.metadata ?? {}).firebaseStorageDownloadTokens;
    token = typeof stored === "string" && stored !== "" ? stored : randomUUID();
  } else {
    token = randomUUID();
  }
  if (!exists) {
    await bucket.upload(srcPath, {
      destination: name,
      contentType,
      metadata: {
        cacheControl: "public, max-age=31536000, immutable",
        metadata: {firebaseStorageDownloadTokens: token},
      },
    });
  } else {
    await file.setMetadata({
      metadata: {firebaseStorageDownloadTokens: token},
    });
  }
  const url =
    `${target.storageHost}/v0/b/${target.bucketName}/o/` +
    `${encodeURIComponent(name)}?alt=media&token=${token}`;
  return {url, hash};
}
