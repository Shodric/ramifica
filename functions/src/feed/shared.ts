import {HttpsError} from "firebase-functions/v2/https";

/**
 * Authenticated uid or bust. Every player-facing callable starts here.
 * @param {unknown} auth Callable auth payload.
 * @return {string} The uid.
 */
export function requireUid(auth: unknown): string {
  if (!auth || typeof auth !== "object" || !("uid" in auth)) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid: unknown = auth.uid;
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  return uid;
}

/**
 * Required id field: trims, rejects blanks as invalid, not unauthenticated.
 * @param {unknown} value Raw field value.
 * @param {string} field Field name for the error.
 * @return {string} The trimmed id.
 */
export function cleanId(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new HttpsError("invalid-argument", `${field} is required.`);
  }
  return value.trim();
}

/**
 * Optional id field: trims, null when missing or blank.
 * @param {unknown} value Raw field value.
 * @return {string | null} The trimmed id, or null.
 */
export function optionalId(value: unknown): string | null {
  if (typeof value !== "string" || value.trim() === "") return null;
  return value.trim();
}

/**
 * Raw callable payload as a field map. Non-objects become empty.
 * @param {unknown} data Raw payload.
 * @return {Object} The fields.
 */
export const toRecord = (data: unknown): {[field: string]: unknown} => {
  return asRecord(data) ?? {};
};

/**
 * Plain field map, or null. Firestore docs and callable payloads arrive
 * untyped; this narrows one level after the object check. Nested values
 * stay unknown and are validated at their own reads.
 * @param {unknown} value Raw value.
 * @return {Object} The map, or null.
 */
export const asRecord = (
  value: unknown
): {[field: string]: unknown} | null => {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  // Only the container shape is asserted; field reads stay unknown.
  return value as unknown as {[field: string]: unknown};
};

/**
 * Now as the ISO strings the run docs store.
 * @return {string} UTC timestamp.
 */
export function isoNow(): string {
  return new Date().toISOString();
}

export interface DbDoc {
  readonly exists: boolean;
  readonly id: string;
  data(): {[field: string]: unknown} | undefined;
}

export interface DbRef {
  readonly id: string;
  get(): Promise<DbDoc>;
  set(data: Record<string, unknown>, opts?: {merge?: boolean}): Promise<void>;
  update(data: Record<string, unknown>): Promise<void>;
}

export interface DbQuery {
  where(field: string, op: string, value: unknown): DbQuery;
  orderBy(field: string, dir?: "asc" | "desc"): DbQuery;
  limit(n: number): DbQuery;
  get(): Promise<{empty: boolean; docs: DbDoc[]}>;
}

export interface DbCol extends DbQuery {
  doc(id?: string): DbRef;
}

export interface DbTx {
  get(ref: DbRef): Promise<DbDoc>;
  set(
    ref: DbRef,
    data: Record<string, unknown>,
    opts?: {merge?: boolean}
  ): Promise<void>;
  update(ref: DbRef, data: Record<string, unknown>): Promise<void>;
}

export interface Db {
  doc(path: string): DbRef;
  collection(path: string): DbCol;
  runTransaction<T>(fn: (tx: DbTx) => Promise<T>): Promise<T>;
}

/**
 * Reads a doc that must exist. Missing is corruption, not a bad request.
 * @param {DbDoc} snap Fetched doc.
 * @param {string} what What it is, for the error.
 * @return {Object} The doc fields.
 */
export function docData(
  snap: DbDoc,
  what: string
): {[field: string]: unknown} {
  const data = snap.data();
  if (!snap.exists || !data) {
    throw new HttpsError("failed-precondition", `${what} is gone.`);
  }
  return data;
}

/**
 * Story doc the caller may open: published, or their own draft for the
 * author preview. Anything else is denied.
 * @param {Db} db Firestore.
 * @param {string} storyId Story id.
 * @param {string} uid Caller.
 * @return {Promise<DbDoc>} The story doc.
 */
export async function readPlayableStory(
  db: Db,
  storyId: string,
  uid: string
): Promise<DbDoc> {
  const snap = await db.doc(`stories/${storyId}`).get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Story not found.");
  }
  const data = docData(snap, "Story");
  if (data.status !== "published" && data.authorId !== uid) {
    throw new HttpsError("permission-denied", "Story not found.");
  }
  return snap;
}

/**
 * Run doc owned by the caller.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {string} runId Run id.
 * @return {Promise<DbDoc>} The run doc.
 */
export async function readOwnRun(
  db: Db,
  uid: string,
  runId: string
): Promise<DbDoc> {
  const snap = await db.doc(`users/${uid}/runs/${runId}`).get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Run not found.");
  }
  return snap;
}
