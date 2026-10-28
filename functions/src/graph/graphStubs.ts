import * as admin from "firebase-admin";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {
  asRecord,
  cleanId,
  Db,
  readPlayableStory,
  requireUid,
  toRecord,
} from "../feed/shared";
import {readRunView, visitedNodeIds} from "./shared";

/** One exit of a visited node: label plus recorded plays. */
export interface GraphChoice {
  choiceId: string;
  label: string;
  count: number;
}

/** One map stub: full body when seen, id-only when still secret. */
export interface GraphStub {
  nodeId: string;
  title: string | null;
  isEnding: boolean;
  visited: boolean;
  secret: boolean;
  choiceCount?: number;
  childIds?: string[];
  /**
   * Per-exit labels and counts, visited non-endings only. `choices[i]`
   * targets `childIds[i]`: both derive from the same node `choices`
   * order.
   */
  choices?: GraphChoice[];
}

/** Every node of the story, plus where this run stands. */
export interface GraphStubsResult {
  nodes: GraphStub[];
  currentNodeId: string;
}

/**
 * Lists every node of the story for the progress map. Visited nodes
 * and public ones carry their body; unvisited secret nodes travel as
 * id-only stubs so the map cannot leak them. Pure reads, no writes.
 */
export const graphStubs = onCall(
  {enforceAppCheck: true, maxInstances: 20},
  async (req) => {
    const uid = requireUid(req.auth);
    return graphStubsWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `graphStubs`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, runId}` payload.
 * @return {Promise<GraphStubsResult>} The stubs contract.
 */
export const graphStubsWith = async (
  db: Db,
  uid: string,
  data: unknown
): Promise<GraphStubsResult> => {
  const fields = toRecord(data);
  const runId = cleanId(fields.runId, "runId");
  const storyId = cleanId(fields.storyId, "storyId");
  const run = await readRunView(db, uid, runId);
  if (run.storyId !== storyId) {
    throw new HttpsError("invalid-argument", "Run is on another story.");
  }
  await readPlayableStory(db, storyId, uid);
  const visited = await visitedNodeIds(db, uid, run);
  const col = await db.collection(`stories/${storyId}/nodes`).get();
  const nodes = col.docs.map((snap) => {
    return stubOf(snap.id, snap.data() ?? {}, visited.has(snap.id));
  });
  nodes.sort((left, right) => {
    return left.nodeId < right.nodeId ?
      -1 :
      left.nodeId > right.nodeId ? 1 : 0;
  });
  return {nodes, currentNodeId: run.currentNodeId};
};

/**
 * Builds one stub: full body when seen or public, id-only when the
 * node is still secret. Visited non-endings also carry per-exit
 * labels and counts for the sheet share bars.
 * @param {string} nodeId Node id.
 * @param {Object} data Node fields.
 * @param {boolean} seen Whether the caller has opened it.
 * @return {GraphStub} The stub.
 */
const stubOf = (
  nodeId: string,
  data: {[field: string]: unknown},
  seen: boolean
): GraphStub => {
  const secret = data.visibility === "secret";
  if (!seen && secret) {
    return {nodeId, title: null, isEnding: false, visited: false,
      secret: true};
  }
  const title = typeof data.title === "string" && data.title !== "" ?
    data.title :
    null;
  const ending = data.isEnding === true;
  const rawChoices = Array.isArray(data.choices) ? data.choices : [];
  const exits: Array<{choiceId: string; label: string; target: string}> = [];
  for (const raw of rawChoices) {
    const choice = asRecord(raw);
    const choiceId = choice?.choiceId;
    const target = choice?.targetNodeId;
    if (typeof choiceId !== "string" || choiceId === "") continue;
    if (typeof target !== "string" || target === "") continue;
    const label = typeof choice?.label === "string" ? choice.label : "";
    exits.push({choiceId, label, target});
  }
  const counts = asRecord(data.choiceCounts) ?? {};
  let choiceCount = 0;
  for (const count of Object.values(counts)) {
    if (typeof count === "number") choiceCount += count;
  }
  const stub: GraphStub = {
    nodeId,
    title,
    isEnding: ending,
    visited: seen,
    secret,
    choiceCount,
    childIds: exits.map((exit) => exit.target),
  };
  if (seen && !ending) {
    stub.choices = exits.map((exit) => {
      const count = counts[exit.choiceId];
      return {
        choiceId: exit.choiceId,
        label: exit.label,
        count: typeof count === "number" ? count : 0,
      };
    });
  }
  return stub;
};
