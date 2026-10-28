import * as admin from "firebase-admin";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {fetchPlayback} from "./playback";
import {
  Db,
  DbRef,
  docData,
  isoNow,
  optionalId,
  readPlayableStory,
  requireUid,
  toRecord,
} from "./shared";
/**
 * Opens the active run, or picks a story when none is given: the
 * `storyState` with the newest `updatedAt`, then the featured story, then
 * the latest published one. `restart: true` starts a fresh run at the root
 * and marks it active; the old run stays `active` but stops being the one.
 */
export const startRun = onCall(
  {enforceAppCheck: true, maxInstances: 20},
  async (req) => {
    const uid = requireUid(req.auth);
    return startRunWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `startRun`: pure Firestore reads and writes.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId?, restart?}` payload.
 */
export const startRunWith = async (
  db: Db,
  uid: string,
  data: unknown
): Promise<{runId: string; storyId: string; status: string}> => {
  const fields = toRecord(data);
  const wanted = optionalId(fields.storyId);
  const restart = fields.restart === true;
  const storyId = wanted ?? (await pickStory(db, uid));
  if (!storyId) {
    throw new HttpsError("failed-precondition", "No stories yet.");
  }
  const storySnap = await readPlayableStory(db, storyId, uid);
  const story = docData(storySnap, "Story");
  if (typeof story.rootNodeId !== "string" || story.rootNodeId === "") {
    throw new HttpsError("failed-precondition", "Story has no root.");
  }
  const stateRef = db.doc(`users/${uid}/storyState/${storyId}`);
  if (!restart) {
    const resumed = await resumeActiveRun(db, uid, stateRef);
    if (resumed) return resumed;
  }
  const runRef = db.collection(`users/${uid}/runs`).doc();
  const now = isoNow();
  await runRef.set({
    storyId,
    status: "active",
    currentNodeId: story.rootNodeId,
    choices: [],
    updatedAt: now,
    createdAt: now,
  });
  const before = await stateRef.get();
  const seen: unknown = before.exists ? before.data()?.visitedNodeIds : null;
  const visited = [
    ...new Set([...(Array.isArray(seen) ? seen : []), story.rootNodeId]),
  ];
  await stateRef.set(
    {
      activeRunId: runRef.id,
      activeRunStatus: "active",
      visitedNodeIds: visited,
      updatedAt: now,
    },
    {merge: true}
  );
  return {runId: runRef.id, storyId, status: "active"};
};

const resumeActiveRun = async (
  db: Db,
  uid: string,
  stateRef: DbRef
): Promise<{runId: string; storyId: string; status: string} | null> => {
  const stateSnap = await stateRef.get();
  const raw: unknown = stateSnap.exists ? stateSnap.data() : null;
  if (!raw || typeof raw !== "object" || !("activeRunId" in raw)) return null;
  const activeRunId: unknown = raw.activeRunId;
  if (typeof activeRunId !== "string" || activeRunId === "") return null;
  const runSnap = await db.doc(`users/${uid}/runs/${activeRunId}`).get();
  if (!runSnap.exists) return null;
  const run = docData(runSnap, "Run");
  if (typeof run.storyId !== "string" || typeof run.status !== "string") {
    return null;
  }
  if (typeof run.currentNodeId !== "string" || run.currentNodeId === "") {
    return null;
  }
  const playback = await fetchPlayback(db, uid, {
    runId: activeRunId,
    storyId: run.storyId,
    status: run.status === "ended" ? "ended" : "active",
    currentNodeId: run.currentNodeId,
  });
  return {
    runId: playback.runId,
    storyId: playback.story.storyId,
    status: playback.status,
  };
};

const pickStory = async (db: Db, uid: string): Promise<string | null> => {
  const states = await db
    .collection(`users/${uid}/storyState`)
    .orderBy("updatedAt", "desc")
    .limit(1)
    .get();
  if (!states.empty) return states.docs[0].id;
  const published = await db
    .collection("stories")
    .where("status", "==", "published")
    .get();
  if (published.empty) return null;
  const featured = published.docs.find((doc) => {
    return doc.data()?.featured === true;
  });
  if (featured) return featured.id;
  const byDate = [...published.docs].sort((a, b) => {
    const left = a.data()?.publishedAt;
    const right = b.data()?.publishedAt;
    return String(right ?? "") < String(left ?? "") ? -1 : 1;
  });
  return byDate[0].id;
};

