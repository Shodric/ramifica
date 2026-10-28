import * as admin from "firebase-admin";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {fetchPlayback, PlaybackView} from "./playback";
import {cleanId, Db, docData, requireUid, toRecord} from "./shared";

/**
 * Reads the caller's run, the current node, and its destinations. Secret
 * destinations travel as id and label only.
 */
export const loadPlayback = onCall(
  {enforceAppCheck: true, maxInstances: 20},
  async (req) => {
    const uid = requireUid(req.auth);
    return loadPlaybackWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `loadPlayback`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{runId}` payload.
 * @return {Promise<PlaybackView>} The playback contract.
 */
export const loadPlaybackWith = async (
  db: Db,
  uid: string,
  data: unknown
): Promise<PlaybackView> => {
  const fields = toRecord(data);
  const runId = cleanId(fields.runId, "runId");
  const snap = await db.doc(`users/${uid}/runs/${runId}`).get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Run not found.");
  }
  const run = docData(snap, "Run");
  if (typeof run.storyId !== "string" || run.storyId === "") {
    throw new HttpsError("invalid-argument", "Run has no story.");
  }
  if (typeof run.currentNodeId !== "string" || run.currentNodeId === "") {
    throw new HttpsError("invalid-argument", "Run has no node.");
  }
  const status = run.status === "ended" ? "ended" : "active";
  return fetchPlayback(db, uid, {
    runId,
    storyId: run.storyId,
    status,
    currentNodeId: run.currentNodeId,
  });
};
