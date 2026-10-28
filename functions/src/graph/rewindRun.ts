import * as admin from "firebase-admin";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {fetchPlayback, PlaybackView} from "../feed/playback";
import {
  asRecord,
  cleanId,
  Db,
  docData,
  isoNow,
  readPlayableStory,
  requireUid,
  toRecord,
} from "../feed/shared";
import {newestParent, readRunView} from "./shared";

/**
 * Steps the run back to the parent of its current node, derived from
 * the append-only history (entries are never popped). A finished run
 * flips back to `active`; a run already at the root cannot rewind.
 */
export const rewindRun = onCall(
  {enforceAppCheck: true, maxInstances: 20},
  async (req) => {
    const uid = requireUid(req.auth);
    return rewindRunWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `rewindRun`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{runId}` payload.
 * @return {Promise<PlaybackView>} The playback at the parent node.
 */
export const rewindRunWith = async (
  db: Db,
  uid: string,
  data: unknown
): Promise<PlaybackView> => {
  const fields = toRecord(data);
  const runId = cleanId(fields.runId, "runId");
  const run = await readRunView(db, uid, runId);
  await readPlayableStory(db, run.storyId, uid);
  if (!newestParent(run.history, run.currentNodeId)) {
    throw new HttpsError("failed-precondition", "Already at the start.");
  }
  const now = isoNow();
  const parentId = await db.runTransaction(async (tx) => {
    const ref = db.doc(`users/${uid}/runs/${runId}`);
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new HttpsError("not-found", "Run not found.");
    }
    const live = docData(snap, "Run");
    const current =
      typeof live.currentNodeId === "string" ? live.currentNodeId : "";
    const raw = Array.isArray(live.choices) ? live.choices : [];
    const history = raw.map((entry) => asRecord(entry) ?? {});
    const parent = newestParent(history, current);
    if (!parent) {
      throw new HttpsError("failed-precondition", "Already at the start.");
    }
    await tx.update(ref, {
      currentNodeId: parent,
      status: "active",
      updatedAt: now,
    });
    await tx.set(
      db.doc(`users/${uid}/storyState/${run.storyId}`),
      {
        activeRunId: runId,
        activeRunStatus: "active",
        updatedAt: now,
      },
      {merge: true}
    );
    return parent;
  });
  return fetchPlayback(db, uid, {
    runId,
    storyId: run.storyId,
    status: "active",
    currentNodeId: parentId,
  });
};
