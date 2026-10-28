import {HttpsError} from "firebase-functions/v2/https";
import {
  asRecord,
  Db,
  docData,
  readOwnRun,
} from "../feed/shared";

/** Run pointers every graph callable starts from. */
export interface RunView {
  runId: string;
  storyId: string;
  status: string;
  currentNodeId: string;
  history: Array<{[field: string]: unknown}>;
}

/**
 * Loads the caller's run. Foreign runs 404, like `commitChoice`: runs
 * live under `users/{uid}`, so another player's id simply is not there.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {string} runId Run id.
 * @return {Promise<RunView>} The run pointers.
 */
export async function readRunView(
  db: Db,
  uid: string,
  runId: string
): Promise<RunView> {
  const snap = await readOwnRun(db, uid, runId);
  const run = docData(snap, "Run");
  if (typeof run.storyId !== "string" || run.storyId === "") {
    throw new HttpsError("invalid-argument", "Run has no story.");
  }
  if (typeof run.currentNodeId !== "string" || run.currentNodeId === "") {
    throw new HttpsError("invalid-argument", "Run has no node.");
  }
  const raw = Array.isArray(run.choices) ? run.choices : [];
  return {
    runId,
    storyId: run.storyId,
    status: run.status === "ended" ? "ended" : "active",
    currentNodeId: run.currentNodeId,
    history: raw.map((entry) => asRecord(entry) ?? {}),
  };
}

/**
 * Node ids the caller has already opened: the run's trail plus the
 * story state, which `commitChoice` keeps across restarts.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {RunView} run Run pointers.
 * @return {Promise<Set<string>>} The visited ids.
 */
export async function visitedNodeIds(
  db: Db,
  uid: string,
  run: RunView
): Promise<Set<string>> {
  const seen = new Set<string>([run.currentNodeId]);
  for (const entry of run.history) {
    if (typeof entry.nodeId === "string") seen.add(entry.nodeId);
    if (typeof entry.targetNodeId === "string") {
      seen.add(entry.targetNodeId);
    }
  }
  const state = await db.doc(`users/${uid}/storyState/${run.storyId}`).get();
  const ids = state.exists ? state.data()?.visitedNodeIds : null;
  if (Array.isArray(ids)) {
    for (const id of ids) {
      if (typeof id === "string") seen.add(id);
    }
  }
  return seen;
}

/**
 * Newest history hop landing on `nodeId`, if any.
 * @param {Array} history Run `choices`, oldest first.
 * @param {string} nodeId Destination node.
 * @return {string | null} The parent, or null.
 */
export function newestParent(
  history: Array<{[field: string]: unknown}>,
  nodeId: string
): string | null {
  for (let i = history.length - 1; i >= 0; i--) {
    const entry = history[i];
    if (
      entry.targetNodeId === nodeId &&
      typeof entry.nodeId === "string"
    ) {
      return entry.nodeId;
    }
  }
  return null;
}

/**
 * Parent approach for `nodeId`: this run's own hop first, then any
 * visited node with a choice pointing at it.
 * @param {Db} db Firestore.
 * @param {string} storyId Story id.
 * @param {string} nodeId Destination node.
 * @param {Array} history Run `choices`, oldest first.
 * @param {Set<string>} visited Visited node ids.
 * @return {Promise<string | null>} The parent, or null.
 */
export async function findParentNodeId(
  db: Db,
  storyId: string,
  nodeId: string,
  history: Array<{[field: string]: unknown}>,
  visited: Set<string>
): Promise<string | null> {
  const own = newestParent(history, nodeId);
  if (own) return own;
  const col = await db.collection(`stories/${storyId}/nodes`).get();
  for (const snap of col.docs) {
    if (!visited.has(snap.id)) continue;
    const data = snap.data() ?? {};
    const raw = Array.isArray(data.choices) ? data.choices : [];
    for (const choice of raw) {
      if (asRecord(choice)?.targetNodeId === nodeId) return snap.id;
    }
  }
  return null;
}
