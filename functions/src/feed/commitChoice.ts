import * as admin from "firebase-admin";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {fetchPlayback, PlaybackView} from "./playback";
import {
  asRecord,
  cleanId,
  Db,
  docData,
  findSagaUnlock,
  isoNow,
  optString,
  parseSagaDoc,
  requireUid,
  rewardCodeFor,
  rewardIdFor,
  SagaDoc,
  toRecord,
} from "./shared";

/** Reached ending, or null when the run is still active. */
export interface CommitEnding {
  storyId: string;
  nodeId: string;
  endingName: string | null;
  endingType: string | null;
}

/** Story this commit newly opened, or null when nothing opened. */
export interface CommitSagaUnlock {
  sagaId: string;
  storyId: string;
  title: string | null;
}

/** Reward grant for the reached ending, or null when still active. */
export interface CommitReward {
  rewardId: string;
  code: string;
}

export interface CommitResult {
  playback: PlaybackView;
  ending: CommitEnding | null;
  sagaUnlocked: CommitSagaUnlock | null;
  reward: CommitReward | null;
}

/**
 * Confirms one hold. Minimum slice: advances the run, appends to the
 * history, counts the choice, marks `ended` on finals, and returns the
 * destination playback. Same `requestId` returns the stored outcome
 * without writing twice. On finals the same transaction also unions the
 * profile-level `endings`, opens the saga follow-up
 * (`fromStoryId` + `endingNodeId` only), and grants the reward: all
 * idempotent, so replays, restarts, and re-commits never duplicate.
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

  const sagas = await readAuthorSagas(db, uid, runId);
  const unlockTitles = await readUnlockTitles(db, sagas);

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
      return {
        storyId,
        toNodeId: last.toNodeId,
        ...restoreOutcome(last.outcome, uid, storyId, last.toNodeId),
      };
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
    const toData = docData(toSnap, "Target node");
    const ending = toData.isEnding === true;
    const stateRef = db.doc(`users/${uid}/storyState/${storyId}`);
    const stateSnap = await tx.get(stateRef);
    const stateData = stateSnap.exists ? stateSnap.data() : undefined;
    const visited: unknown = stateData?.visitedNodeIds;
    const priorEndings: unknown = stateData?.endings;
    const now = isoNow();
    const history: unknown[] = Array.isArray(run.choices) ? run.choices : [];
    const endingView: CommitEnding | null = ending ?
      {
        storyId,
        nodeId: toNodeId,
        endingName: optString(toData.endingName),
        endingType: optString(toData.endingType),
      } :
      null;
    // The rule that opens a next story for this exact finish, if any.
    const unlock = ending ? findSagaUnlock(sagas, storyId, toNodeId) : null;
    let sagaUnlocked: CommitSagaUnlock | null = null;
    if (unlock) {
      const targetRef = db.doc(
        `users/${uid}/storyState/${unlock.rule.toStoryId}`
      );
      const targetSnap = await tx.get(targetRef);
      const already =
        asRecord(targetSnap.exists ? targetSnap.data() : null)
          ?.sagaUnlocked === true;
      if (!already) {
        await tx.set(
          targetRef,
          {sagaUnlocked: true, updatedAt: now},
          {merge: true}
        );
        sagaUnlocked = {
          sagaId: unlock.saga.sagaId,
          storyId: unlock.rule.toStoryId,
          title: unlockTitles.get(unlock.rule.toStoryId) ?? null,
        };
      }
    }
    // One grant per story ending: the deterministic id makes replays and
    // restarts overwrite the same doc instead of duplicating.
    let reward: CommitReward | null = null;
    if (ending) {
      const rewardId = rewardIdFor(storyId, toNodeId);
      const rewardRef = db.doc(`users/${uid}/rewards/${rewardId}`);
      const rewardSnap = await tx.get(rewardRef);
      // The code is fixed per earner and ending: the first grant stores
      // it, later commits reuse it, and legacy docs without one get the
      // same value backfilled. Never reissued.
      const code = rewardCodeFor(uid, storyId, toNodeId);
      if (!rewardSnap.exists) {
        await tx.set(rewardRef, {
          storyId,
          endingNodeId: toNodeId,
          sagaId: unlock?.saga.sagaId ?? null,
          code,
          grantedAt: now,
          requestId,
        });
      } else if (optString(rewardSnap.data()?.code) === null) {
        await tx.update(rewardRef, {code});
      }
      reward = {rewardId, code};
    }
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
      lastCommit: {
        requestId,
        fromNodeId,
        choiceId,
        toNodeId,
        outcome: {ending: endingView, sagaUnlocked, reward},
      },
      updatedAt: now,
    });
    const priorCounts = asRecord(node.choiceCounts) ?? {};
    const counts: {[choice: string]: unknown} = {...priorCounts};
    const seen = counts[choiceId];
    counts[choiceId] = (typeof seen === "number" ? seen : 0) + 1;
    await tx.update(fromRef, {choiceCounts: counts});
    await tx.set(
      stateRef,
      {
        activeRunId: runId,
        activeRunStatus: ending ? "ended" : "active",
        visitedNodeIds: [
          ...new Set([...(Array.isArray(visited) ? visited : []), toNodeId]),
        ],
        ...(ending ?
          {
            endings: [
              ...new Set([
                ...(Array.isArray(priorEndings) ? priorEndings : []),
                toNodeId,
              ]),
            ],
          } :
          {}),
        updatedAt: now,
      },
      {merge: true}
    );
    return {storyId, toNodeId, ending: endingView, sagaUnlocked, reward};
  });
  const sagaUnlocked = await completeUnlockTitle(
    db,
    unlockTitles,
    landed.sagaUnlocked
  );
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
  return {
    playback,
    ending: landed.ending,
    sagaUnlocked,
    reward: landed.reward,
  };
};

/**
 * Author sagas holding the run's story, by saga id. Reads stay outside
 * the commit transaction; the writes inside stay atomic. Empty when the
 * run or story is gone, or the story has no author: the commit still
 * lands, saga writes are skipped.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {string} runId Run id.
 * @return {Promise<SagaDoc[]>} The usable author sagas.
 */
const readAuthorSagas = async (
  db: Db,
  uid: string,
  runId: string
): Promise<SagaDoc[]> => {
  const runSnap = await db.doc(`users/${uid}/runs/${runId}`).get();
  if (!runSnap.exists) {
    throw new HttpsError("not-found", "Run not found.");
  }
  const storyId = runSnap.data()?.storyId;
  if (typeof storyId !== "string" || storyId === "") return [];
  const storySnap = await db.doc(`stories/${storyId}`).get();
  const authorId = storySnap.exists ?
    optString(storySnap.data()?.authorId) :
    null;
  if (authorId === null) return [];
  const snap = await db
    .collection("sagas")
    .where("authorId", "==", authorId)
    .get();
  const sagas: SagaDoc[] = [];
  for (const doc of snap.docs) {
    const saga = parseSagaDoc(doc.id, doc.data() ?? null);
    if (saga && saga.storyIds.includes(storyId)) sagas.push(saga);
  }
  sagas.sort((left, right) => (left.sagaId < right.sagaId ? -1 : 1));
  return sagas;
};

/**
 * Display titles for every story the author's sagas can open, read
 * outside the commit transaction so the unlock payload can carry the
 * opened story's title with no reads inside the tx.
 * @param {Db} db Firestore.
 * @param {SagaDoc[]} sagas Author sagas holding the run's story.
 * @return {Promise<Map<string, string>>} Titles by opened story id.
 */
const readUnlockTitles = async (
  db: Db,
  sagas: SagaDoc[]
): Promise<Map<string, string>> => {
  const ids = new Set<string>();
  for (const saga of sagas) {
    for (const rule of saga.unlocks) ids.add(rule.toStoryId);
  }
  const titles = new Map<string, string>();
  for (const storyId of ids) {
    const snap = await db.doc(`stories/${storyId}`).get();
    const title = snap.exists ? optString(snap.data()?.title) : null;
    if (title !== null) titles.set(storyId, title);
  }
  return titles;
};

/**
 * Fills a null unlock title from the pre-read map, or with one read for
 * unlocks stored before titles existed. Read-only: the stored outcome is
 * left untouched, so replays still write nothing.
 * @param {Db} db Firestore.
 * @param {Map<string, string>} titles Pre-read titles by story id.
 * @param {CommitSagaUnlock | null} unlock The unlock to complete.
 * @return {Promise<CommitSagaUnlock | null>} The unlock with its title.
 */
const completeUnlockTitle = async (
  db: Db,
  titles: Map<string, string>,
  unlock: CommitSagaUnlock | null
): Promise<CommitSagaUnlock | null> => {
  if (unlock === null || unlock.title !== null) return unlock;
  const known = titles.get(unlock.storyId) ?? null;
  if (known !== null) return {...unlock, title: known};
  const snap = await db.doc(`stories/${unlock.storyId}`).get();
  const title = snap.exists ? optString(snap.data()?.title) : null;
  return {...unlock, title};
};

/**
 * Stored commit outcome for a hold replay. Same `requestId` returns the
 * same ending, unlock, and reward without writing twice. Commits written
 * before the outcome existed replay as all null. Outcomes stored before
 * the code existed complete the same deterministic code, never a new one;
 * unlocks stored before the title existed pass a null title, completed
 * after the transaction by reading the unlocked story.
 * @param {unknown} raw Stored `lastCommit.outcome`.
 * @param {string} uid Earner, for the deterministic code.
 * @param {string} storyId Finished story.
 * @param {string} toNodeId Destination node.
 * @return {Object} The ending, unlock, and reward to return.
 */
const restoreOutcome = (
  raw: unknown,
  uid: string,
  storyId: string,
  toNodeId: string
): {
  ending: CommitEnding | null;
  sagaUnlocked: CommitSagaUnlock | null;
  reward: CommitReward | null;
} => {
  const outcome = asRecord(raw);
  if (!outcome) return {ending: null, sagaUnlocked: null, reward: null};
  const rawEnding = asRecord(outcome.ending);
  const rawUnlock = asRecord(outcome.sagaUnlocked);
  const rawReward = asRecord(outcome.reward);
  const unlockSagaId = rawUnlock ? optString(rawUnlock.sagaId) : null;
  const unlockStoryId = rawUnlock ? optString(rawUnlock.storyId) : null;
  const unlockTitle = rawUnlock ? optString(rawUnlock.title) : null;
  const rewardId = rawReward ? optString(rawReward.rewardId) : null;
  const stored = rawReward ? optString(rawReward.code) : null;
  const code =
    stored ??
    (rewardId !== null ? rewardCodeFor(uid, storyId, toNodeId) : null);
  return {
    ending: rawEnding ?
      {
        storyId,
        nodeId: optString(rawEnding.nodeId) ?? toNodeId,
        endingName: optString(rawEnding.endingName),
        endingType: optString(rawEnding.endingType),
      } :
      null,
    sagaUnlocked:
      unlockSagaId !== null && unlockStoryId !== null ?
        {sagaId: unlockSagaId, storyId: unlockStoryId, title: unlockTitle} :
        null,
    reward: rewardId !== null && code !== null ? {rewardId, code} : null,
  };
};
