import {randomUUID} from "crypto";

/** Object handle the Admin SDK returns from `bucket.file`. */
interface StoredFile {
  name: string;
  bucket: {name: string};
  setMetadata: (meta: {
    metadata: {[key: string]: string};
  }) => Promise<unknown>;
  getSignedUrl: (cfg: {
    action: "read";
    expires: string;
  }) => Promise<string[]>;
}

/**
 * Read URL for bytes Functions just wrote.
 *
 * Production signs with the runtime service account. The emulator
 * has no `client_email`, so `getSignedUrl` throws SigningError and
 * the callable becomes a bare INTERNAL. There we stamp a download
 * token. Storage rules deny client reads; the token bypasses them
 * the same way a signed URL does.
 * @param {StoredFile} file The object that was just saved.
 * @return {Promise<string>} A URL the client can GET.
 */
export const readableStorageUrl = async (
  file: StoredFile
): Promise<string> => {
  const host = process.env.FIREBASE_STORAGE_EMULATOR_HOST;
  if (host !== undefined && host !== "") {
    const token = randomUUID();
    await file.setMetadata({
      metadata: {firebaseStorageDownloadTokens: token},
    });
    const objectPath = encodeURIComponent(file.name);
    const bucket = file.bucket.name;
    return (
      `http://${host}/v0/b/${bucket}/o/${objectPath}` +
      `?alt=media&token=${token}`
    );
  }
  const [url] = await file.getSignedUrl({
    action: "read",
    expires: "2100-01-01",
  });
  return url;
};
