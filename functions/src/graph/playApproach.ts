import * as admin from "firebase-admin";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {fetchPlayback, PlaybackView} from "../feed/playback";
import {
  cleanId,
  Db,
  readPlayableStory,
  requireUid,
  toRecord,
} from "../feed/shared";
import {findParentNodeId, readRunView, visitedNodeIds} from "./shared";

/**
 * Replays the visited parent approach of a node: the clip that leads
 * into it. Prefers this run's own hop, falls back to any visited
 * parent. Pure reads: history and status stay untouched.
 */
export const playApproach = onCall(
  {enforceAppCheck: true, maxInstances: 20},
  async (req) => {
    const uid = requireUid(req.auth);
    return playApproachWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `playApproach`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{runId, nodeId}` payload.
 * @return {Promise<PlaybackView>} The parent approach playback.
 */
export const playApproachWith = async (
  db: Db,
  uid: string,
  data: unknown
): Promise<PlaybackView> => {
  const fields = toRecord(data);
  const runId = cleanId(fields.runId, "runId");
  const nodeId = cleanId(fields.nodeId, "nodeId");
  const run = await readRunView(db, uid, runId);
  await readPlayableStory(db, run.storyId, uid);
  const target = await db
    .doc(`stories/${run.storyId}/nodes/${nodeId}`)
    .get();
  if (!target.exists) {
    throw new HttpsError("not-found", "Node not found.");
  }
  const visited = await visitedNodeIds(db, uid, run);
  const parentId = await findParentNodeId(
    db,
    run.storyId,
    nodeId,
    run.history,
    visited
  );
  if (!parentId) {
    throw new HttpsError("failed-precondition", "Nothing to replay.");
  }
  return fetchPlayback(db, uid, {
    runId,
    storyId: run.storyId,
    status: run.status,
    currentNodeId: parentId,
  });
};
