import {createHash} from "crypto";
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
 * One saga step: finishing `fromStoryId` at `endingNodeId` opens
 * `toStoryId`. The first story of `storyIds` is open to everyone.
 */
export interface SagaUnlockRule {
  fromStoryId: string;
  endingNodeId: string;
  toStoryId: string;
}

/**
 * A saga doc from `sagas/{sagaId}`: one author's ordered stories plus
 * the rules that open each next story.
 */
export interface SagaDoc {
  sagaId: string;
  authorId: string;
  storyIds: string[];
  unlocks: SagaUnlockRule[];
}

/**
 * Optional text field: trims, null when missing or blank.
 * @param {unknown} value Raw field value.
 * @return {string | null} The trimmed text, or null.
 */
export function optString(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ?
    value.trim() :
    null;
}

/**
 * String list field. Non-strings and blanks are dropped.
 * @param {unknown} value Raw field value.
 * @return {string[]} The clean strings.
 */
export function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const out: string[] = [];
  for (const entry of value) {
    if (typeof entry === "string" && entry.trim() !== "") {
      out.push(entry.trim());
    }
  }
  return out;
}

/**
 * Parses one `sagas/{sagaId}` doc. Missing author, title, or ordered
 * stories means a console-written half doc: skipped, not fatal.
 * @param {string} id Saga doc id.
 * @param {unknown} data Raw doc fields.
 * @return {SagaDoc | null} The saga, or null when unusable.
 */
export function parseSagaDoc(
  id: string,
  data: {[field: string]: unknown} | null
): SagaDoc | null {
  if (data === null) return null;
  const authorId = optString(data.authorId);
  const title = optString(data.title);
  const storyIds = stringList(data.storyIds);
  if (authorId === null || title === null || storyIds.length === 0) {
    return null;
  }
  const unlocks: SagaUnlockRule[] = [];
  if (Array.isArray(data.unlocks)) {
    for (const raw of data.unlocks) {
      const rule = asRecord(raw);
      const from = rule ? optString(rule.fromStoryId) : null;
      const ending = rule ? optString(rule.endingNodeId) : null;
      const to = rule ? optString(rule.toStoryId) : null;
      if (from === null || ending === null || to === null) continue;
      if (!storyIds.includes(from) || !storyIds.includes(to)) continue;
      unlocks.push({fromStoryId: from, endingNodeId: ending, toStoryId: to});
    }
  }
  return {sagaId: id, authorId, storyIds, unlocks};
}

/**
 * First saga rule (by saga id) that opens a next story for this finish.
 * Finishing another ending opens nothing.
 * @param {SagaDoc[]} sagas Author sagas holding this story, by saga id.
 * @param {string} storyId Finished story.
 * @param {string} endingNodeId Reached ending node.
 * @return {Object | null} The saga and rule, or null when locked.
 */
export function findSagaUnlock(
  sagas: SagaDoc[],
  storyId: string,
  endingNodeId: string
): {saga: SagaDoc; rule: SagaUnlockRule} | null {
  for (const saga of sagas) {
    const rule = saga.unlocks.find(
      (entry) =>
        entry.fromStoryId === storyId && entry.endingNodeId === endingNodeId
    );
    if (rule) return {saga, rule};
  }
  return null;
}

/**
 * Deterministic reward doc id: one grant per story ending, so replays
 * and restarts overwrite the same doc instead of duplicating.
 * @param {string} storyId Finished story.
 * @param {string} endingNodeId Reached ending node.
 * @return {string} The reward doc id.
 */
export function rewardIdFor(storyId: string, endingNodeId: string): string {
  return `${storyId}_${endingNodeId}`;
}

/**
 * Human-readable reward code for one earner and ending. Deterministic in
 * the earner, so replays, restarts, and legacy docs without a stored code
 * all complete the same value without reissuing.
 * @param {string} uid Earner.
 * @param {string} storyId Finished story.
 * @param {string} endingNodeId Reached ending node.
 * @return {string} The code, as `XXXX-XXXX`.
 */
export function rewardCodeFor(
  uid: string,
  storyId: string,
  endingNodeId: string
): string {
  const hash = createHash("sha256")
    .update(`${uid}\n${storyId}\n${endingNodeId}`)
    .digest("hex")
    .toUpperCase();
  return `${hash.slice(0, 4)}-${hash.slice(4, 8)}`;
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
