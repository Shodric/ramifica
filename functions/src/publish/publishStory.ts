import * as admin from "firebase-admin";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {
  cleanId,
  Db,
  docData,
  isoNow,
  requireUid,
  toRecord,
} from "../feed/shared";
import {
  ValidatableChoice,
  ValidatableNode,
  validateStory,
} from "./validateStory";

/** Result of `publishStory`: whether the story is now published. */
export interface PublishStoryResult {
  storyId: string;
  published: boolean;
  problems: string[];
}

/**
 * Publishes an author-owned draft that passes the checklist. Validation
 * reuses `validateStory`: reachable nodes, a start node plus an ending,
 * approved start/end frames, ready video and voice with approvals, one
 * default choice per decision node, and no parent-hash desync. A clean
 * story flips `draft` to `published` with `publishedAt` (the field
 * Explore sorts on); a failing story returns the missing list with no
 * state change. Re-publishing an already-published story is a no-op
 * success, so retries and double taps are safe. Only the author may call
 * it — the client rules forbid writing `status`, so this Admin-SDK path
 * is the single writer. This never touches other stories or runs.
 */
export const publishStory = onCall(
  {enforceAppCheck: true, maxInstances: 20},
  async (req) => {
    const uid = requireUid(req.auth);
    return publishStoryWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `publishStory`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId}`.
 * @return {Promise<PublishStoryResult>} The publish outcome.
 */
export const publishStoryWith = async (
  db: Db,
  uid: string,
  data: unknown
): Promise<PublishStoryResult> => {
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  // Node docs are listed outside the transaction (the Db transaction only
  // serves single refs); the story guards and the node reads below run
  // again on transaction-fresh data before anything is written.
  const storyHead = await db.doc(`stories/${storyId}`).get();
  if (!storyHead.exists) {
    throw new HttpsError("not-found", "Story not found.");
  }
  const head = docData(storyHead, "Story");
  if (head.authorId !== uid) {
    throw new HttpsError("permission-denied", "Not your draft.");
  }
  if (head.status === "published") {
    return {storyId, published: true, problems: []};
  }
  if (head.status !== "draft") {
    throw new HttpsError(
      "failed-precondition",
      "Only drafts can be published."
    );
  }
  const listed = await db.collection(`stories/${storyId}/nodes`).get();
  const listedIds = listed.docs.map((snap) => snap.id);
  return db.runTransaction(async (tx) => {
    const storySnap = await tx.get(db.doc(`stories/${storyId}`));
    if (!storySnap.exists) {
      throw new HttpsError("not-found", "Story not found.");
    }
    const story = docData(storySnap, "Story");
    if (story.authorId !== uid) {
      throw new HttpsError("permission-denied", "Not your draft.");
    }
    if (story.status === "published") {
      return {storyId, published: true, problems: []};
    }
    if (story.status !== "draft") {
      throw new HttpsError(
        "failed-precondition",
        "Only drafts can be published."
      );
    }
    const nodes: ValidatableNode[] = [];
    for (const nodeId of listedIds) {
      const nodeSnap = await tx.get(
        db.doc(`stories/${storyId}/nodes/${nodeId}`)
      );
      if (!nodeSnap.exists) {
        return {
          storyId,
          published: false,
          problems: [`Node ${nodeId} is gone.`],
        };
      }
      nodes.push(toValidatable(nodeId, nodeSnap.data() ?? {}));
    }
    const problems = validateStory(
      {
        storyId,
        status: typeof story.status === "string" ? story.status : "draft",
        rootNodeId:
          typeof story.rootNodeId === "string" ? story.rootNodeId : null,
      },
      nodes
    );
    if (problems.length > 0) {
      // No state change: the missing list is the whole result.
      return {storyId, published: false, problems};
    }
    const now = isoNow();
    tx.set(
      db.doc(`stories/${storyId}`),
      {status: "published", publishedAt: now, updatedAt: now},
      {merge: true}
    );
    return {storyId, published: true, problems: []};
  });
};

/**
 * Maps one stored node doc onto the publish checklist shape. Missing
 * fields fall back to failing values (blank title, idle media) so thin
 * drafts report checklist problems instead of crashing the read.
 * @param {string} nodeId Doc id.
 * @param {Object} data Stored node fields.
 * @return {ValidatableNode} The checklist view.
 */
const toValidatable = (
  nodeId: string,
  data: {[field: string]: unknown}
): ValidatableNode => {
  const rawChoices = Array.isArray(data.choices) ? data.choices : [];
  return {
    nodeId,
    title: asText(data.title),
    visibility: asText(data.visibility, "visible"),
    isEnding: data.isEnding === true,
    endingName: asNullableText(data.endingName),
    endingType: asNullableText(data.endingType),
    videoUrl: asNullableText(data.videoUrl),
    videoStatus: asNullableText(data.videoStatus),
    videoSource: asNullableText(data.videoSource),
    videoFrameLastUrl: asNullableText(data.videoFrameLastUrl),
    durationSeconds: asNumber(data.durationSeconds),
    pauseAtSeconds: asNumber(data.pauseAtSeconds),
    windowSeconds: asNumber(data.windowSeconds),
    startImageApproved: data.startImageApproved === true,
    startFromNodeId: asNullableText(data.startFromNodeId),
    startParentEndHash: asNullableText(data.startParentEndHash),
    endImageApproved: data.endImageApproved === true,
    endHash: asNullableText(data.endHash),
    ttsText: asNullableText(data.ttsText),
    lineApproved: data.lineApproved === true,
    ttsAudioUrl: asNullableText(data.ttsAudioUrl),
    ttsStatus: asNullableText(data.ttsStatus),
    ttsDurationSeconds: asNumber(data.ttsDurationSeconds),
    ttsApproved: data.ttsApproved === true,
    choices: rawChoices.map((raw) => toValidatableChoice(toRecord(raw))),
  };
};

/**
 * Maps one stored choice onto the publish checklist shape. Zones are
 * numbers on every saved choice; a missing one maps to NaN so the
 * checklist reports it instead of the read crashing.
 * @param {Object} choice Stored choice fields.
 * @return {ValidatableChoice} The checklist view.
 */
const toValidatableChoice = (choice: {
  [field: string]: unknown;
}): ValidatableChoice => ({
  choiceId: asText(choice.choiceId),
  label: asText(choice.label),
  targetNodeId: asText(choice.targetNodeId),
  isDefault: choice.isDefault === true,
  x: asNumber(choice.x) ?? NaN,
  y: asNumber(choice.y) ?? NaN,
  radius: asNumber(choice.radius) ?? NaN,
});

/**
 * Text field, blank when missing or mistyped.
 * @param {unknown} value Raw value.
 * @param {string} fallback Default text.
 * @return {string} The text.
 */
const asText = (value: unknown, fallback = ""): string => {
  return typeof value === "string" ? value : fallback;
};

/**
 * Nullable text field, null when missing or mistyped.
 * @param {unknown} value Raw value.
 * @return {string | null} The text, or null.
 */
const asNullableText = (value: unknown): string | null => {
  return typeof value === "string" ? value : null;
};

/**
 * Numeric field, null when missing or mistyped.
 * @param {unknown} value Raw value.
 * @return {number | null} The number, or null.
 */
const asNumber = (value: unknown): number | null => {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
};
