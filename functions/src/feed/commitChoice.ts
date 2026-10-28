import * as admin from "firebase-admin";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {fetchPlayback, PlaybackView} from "./playback";
import {
  asRecord,
  cleanId,
  Db,
  docData,
  isoNow,
  requireUid,
  toRecord,
} from "./shared";

export interface CommitResult {
  playback: PlaybackView;
  ending: null;
  sagaUnlocked: null;
  reward: null;
}

/**
 * Confirms one hold. Minimum slice: advances the run, appends to the
 * history, counts the choice, marks `ended` on finals, and returns the
 * destination playback. Same `requestId` returns the stored result without
 * writing twice. Finals, sagas, and codes land in a later slice.
 */
export const commitChoice = onCall(
  {enforceAppCheck: true, maxInstances: 20},
  async (req) => {
    const uid = requireUid(req.auth);
    return commitChoiceWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `commitChoice`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{runId, fromNodeId, choiceId, requestId}`.
 */
export const commitChoiceWith = async (
  db: Db,
  uid: string,
  data: unknown
): Promise<CommitResult> => {
  const fields = toRecord(data);
  const runId = cleanId(fields.runId, "runId");
  const fromNodeId = cleanId(fields.fromNodeId, "fromNodeId");
  const choiceId = cleanId(fields.choiceId, "choiceId");
  const requestId = cleanId(fields.requestId, "requestId");

  const landed = await db.runTransaction(async (tx) => {
    const runRef = db.doc(`users/${uid}/runs/${runId}`);
    const runSnap = await tx.get(runRef);
    if (!runSnap.exists) {
      throw new HttpsError("not-found", "Run not found.");
    }
    const run = docData(runSnap, "Run");
    const storyId = run.storyId;
    if (typeof storyId !== "string" || storyId === "") {
      throw new HttpsError("invalid-argument", "Run has no story.");
    }
    const last = asRecord(run.lastCommit);
    if (
      last?.requestId === requestId &&
      typeof last.toNodeId === "string"
    ) {
      return {storyId, toNodeId: last.toNodeId};
    }
    if (run.currentNodeId !== fromNodeId) {
      throw new HttpsError("invalid-argument", "Run moved on.");
    }
    const fromRef = db.doc(`stories/${storyId}/nodes/${fromNodeId}`);
    const nodeSnap = await tx.get(fromRef);
    const node = docData(nodeSnap, "Node");
    const rawChoices = Array.isArray(node.choices) ? node.choices : [];
    const choice = rawChoices
      .map((entry) => asRecord(entry))
      .find((entry) => entry?.choiceId === choiceId);
    const toNodeId =
      choice && typeof choice.targetNodeId === "string" ?
        choice.targetNodeId :
        null;
    if (!choice || !toNodeId) {
      throw new HttpsError("invalid-argument", "Choice is not valid.");
    }
    const toRef = db.doc(`stories/${storyId}/nodes/${toNodeId}`);
    const toSnap = await tx.get(toRef);
    if (!toSnap.exists) {
      throw new HttpsError("invalid-argument", "Choice points nowhere.");
    }
    const ending = docData(toSnap, "Target node").isEnding === true;
    const now = isoNow();
    const history: unknown[] = Array.isArray(run.choices) ? run.choices : [];
    await tx.update(runRef, {
      currentNodeId: toNodeId,
      status: ending ? "ended" : run.status,
      ...(ending ? {endedAt: now, endingNodeId: toNodeId} : {}),
      choices: [
        ...history,
        {
          nodeId: fromNodeId,
          choiceId,
          targetNodeId: toNodeId,
          requestId,
          at: now,
        },
      ],
      lastCommit: {requestId, fromNodeId, choiceId, toNodeId},
      updatedAt: now,
    });
    const priorCounts = asRecord(node.choiceCounts) ?? {};
    const counts: {[choice: string]: unknown} = {...priorCounts};
    const seen = counts[choiceId];
    counts[choiceId] = (typeof seen === "number" ? seen : 0) + 1;
    await tx.update(fromRef, {choiceCounts: counts});
    const stateRef = db.doc(`users/${uid}/storyState/${storyId}`);
    const stateSnap = await tx.get(stateRef);
    const visited: unknown =
      stateSnap.exists ? stateSnap.data()?.visitedNodeIds : null;
    await tx.set(
      stateRef,
      {
        activeRunId: runId,
        activeRunStatus: ending ? "ended" : "active",
        visitedNodeIds: [
          ...new Set([...(Array.isArray(visited) ? visited : []), toNodeId]),
        ],
        updatedAt: now,
      },
      {merge: true}
    );
    return {storyId, toNodeId};
  });

  const runSnap = await db.doc(`users/${uid}/runs/${runId}`).get();
  const run = docData(runSnap, "Run");
  const status = run.status === "ended" ? "ended" : "active";
  if (typeof run.currentNodeId !== "string" || run.currentNodeId === "") {
    throw new HttpsError("failed-precondition", "Run has no node.");
  }
  const playback = await fetchPlayback(db, uid, {
    runId,
    storyId: landed.storyId,
    status,
    currentNodeId: run.currentNodeId,
  });
  return {playback, ending: null, sagaUnlocked: null, reward: null};
};
