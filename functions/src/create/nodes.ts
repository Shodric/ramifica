import * as admin from "firebase-admin";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {
  cleanId,
  Db,
  docData,
  isoNow,
  optionalId,
  optString,
  requireUid,
  toRecord,
} from "../feed/shared";
import {asFields} from "./generateNodeText";

/** Result of `createNode`: the new node id. */
export interface CreateNodeResult {
  nodeId: string;
}

/** Node text fields; node writes are Functions-only. */
interface ChoiceFields {
  [field: string]: unknown;
}

/** Title cap mirrors the publish checklist: 1-40 characters. */
const maxTitleChars = 40;

/** Choice label cap mirrors the publish checklist: 1-24 characters. */
const maxLabelChars = 24;

/** Narrator lines past this are rejected; the player reads them verbatim. */
const maxTtsChars = 1000;

/** Decisions carry one or two choices, like the publish checklist. */
const maxChoices = 2;

/** Ending types from the publish checklist. */
const endingTypes = ["abierto", "tragico", "secreto"];

/**
 * Creates one node in an author-owned draft. Atomic entry: when
 * `stories/{storyId}` is missing it is created in the same transaction
 * as the first node (author = caller, status = draft, root = new node),
 * so one call can never leave a draft story without its root. The
 * client-direct story write the rules allow still works — an existing
 * draft simply gains the node — but the recommended flow is this
 * callable first, which keeps the orphan-story failure mode (story
 * written, root call lost) unreachable. Linking is explicit: pass
 * `parentNodeId` to record the parent link, then point a choice at the
 * new id with `saveNode` on the parent. This never touches other
 * stories, runs, or published docs.
 */
export const createNode = onCall(
  {enforceAppCheck: true, maxInstances: 20},
  async (req) => {
    const uid = requireUid(req.auth);
    return createNodeWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Persists the author's node edits. Field whitelist: title, visibility,
 * isEnding, endingName, endingType, ttsText, windowSeconds, choices, and
 * the line/voice approvals. Everything else in the payload — nodeId
 * routing aside — is ignored, so pipeline-owned media fields and
 * story-level authorId, status, and rootNodeId can never escalate through
 * this path. New words idle the stored voice and clear both approvals
 * unless the same save approves the line. Endings normalize windowSeconds
 * to null; non-empty choices on an ending are rejected rather than
 * dropped. Target ids stay unchecked here on purpose: a choice may point
 * at a node created next, and the publish checklist reports dangling
 * targets. This never touches other stories, runs, or published docs.
 */
export const saveNode = onCall(
  {enforceAppCheck: true, maxInstances: 20},
  async (req) => {
    const uid = requireUid(req.auth);
    return saveNodeWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `createNode`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, parentNodeId?, title?, synopsis?}`.
 * `title`/`synopsis` seed the story only when it is created here.
 * @return {Promise<CreateNodeResult>} The new node id.
 */
export const createNodeWith = async (
  db: Db,
  uid: string,
  data: unknown
): Promise<CreateNodeResult> => {
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  const parentNodeId = optionalId(fields.parentNodeId);
  const title = optString(fields.title);
  const synopsis = optString(fields.synopsis);
  return db.runTransaction(async (tx) => {
    const storyRef = db.doc(`stories/${storyId}`);
    const storySnap = await tx.get(storyRef);
    let rootNodeId: string | null = null;
    if (!storySnap.exists) {
      tx.set(storyRef, {
        authorId: uid,
        title: title ?? "Untitled story",
        synopsis: synopsis ?? "",
        status: "draft",
        rootNodeId: null,
        createdAt: isoNow(),
        updatedAt: isoNow(),
      });
    } else {
      const story = docData(storySnap, "Story");
      if (story.authorId !== uid) {
        throw new HttpsError("permission-denied", "Not your draft.");
      }
      if (story.status !== "draft") {
        throw new HttpsError(
          "failed-precondition",
          "Only drafts can grow nodes."
        );
      }
      rootNodeId = optString(story.rootNodeId);
    }
    if (parentNodeId !== null) {
      const parentSnap = await tx.get(
        db.doc(`stories/${storyId}/nodes/${parentNodeId}`)
      );
      if (!parentSnap.exists) {
        throw new HttpsError("not-found", "Parent node not found.");
      }
    }
    const nodeRef = db.collection(`stories/${storyId}/nodes`).doc();
    tx.set(nodeRef, {
      title: "",
      visibility: "visible",
      isEnding: false,
      endingName: null,
      endingType: null,
      videoUrl: null,
      videoStatus: "idle",
      pauseAtSeconds: null,
      windowSeconds: 6,
      ttsText: "",
      lineApproved: false,
      ttsAudioUrl: null,
      ttsStatus: "idle",
      ttsDurationSeconds: null,
      ttsApproved: false,
      choices: [],
      startFromNodeId: parentNodeId,
      startParentEndHash: null,
    });
    if (rootNodeId === null) {
      tx.set(
        storyRef,
        {rootNodeId: nodeRef.id, updatedAt: isoNow()},
        {merge: true}
      );
    }
    return {nodeId: nodeRef.id};
  });
};

/**
 * Testable core of `saveNode`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, node: {nodeId, ...fields}}`.
 * @return {Promise<Object>} Empty; the client keeps its own copy.
 */
export const saveNodeWith = async (
  db: Db,
  uid: string,
  data: unknown
): Promise<Record<string, unknown>> => {
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  const rawNode = fields.node;
  if (rawNode === null || typeof rawNode !== "object" ||
    Array.isArray(rawNode)) {
    throw new HttpsError("invalid-argument", "node is required.");
  }
  const nodeFields = toRecord(rawNode);
  const nodeId = cleanId(nodeFields.nodeId, "nodeId");
  return db.runTransaction(async (tx) => {
    const storySnap = await tx.get(db.doc(`stories/${storyId}`));
    if (!storySnap.exists) {
      throw new HttpsError("not-found", "Story not found.");
    }
    const story = docData(storySnap, "Story");
    if (story.authorId !== uid) {
      throw new HttpsError("permission-denied", "Not your draft.");
    }
    if (story.status !== "draft") {
      throw new HttpsError("failed-precondition", "Only drafts can be edited.");
    }
    const nodeRef = db.doc(`stories/${storyId}/nodes/${nodeId}`);
    const nodeSnap = await tx.get(nodeRef);
    if (!nodeSnap.exists) {
      throw new HttpsError("not-found", "Node not found.");
    }
    tx.set(nodeRef, parseNodeUpdate(nodeFields, docData(nodeSnap, "Node")), {
      merge: true,
    });
    return {};
  });
};

/**
 * Builds the whitelisted node update. Absent keys stay unchanged;
 * present keys are validated, so full-shape and partial saves share
 * this path.
 * @param {Object} nodeFields Raw node payload.
 * @param {Object} current Stored node fields.
 * @return {Object} The validated update.
 */
const parseNodeUpdate = (
  nodeFields: {[field: string]: unknown},
  current: {[field: string]: unknown}
): Record<string, unknown> => {
  const update: Record<string, unknown> = {};
  const isEnding = "isEnding" in nodeFields ?
    parseBoolean(nodeFields.isEnding, "isEnding") :
    current.isEnding === true;
  if ("isEnding" in nodeFields) update.isEnding = isEnding;
  if ("title" in nodeFields) {
    update.title = parseText(nodeFields.title, "title", maxTitleChars);
  }
  if ("visibility" in nodeFields) {
    update.visibility = parseVisibility(nodeFields.visibility);
  }
  if ("endingName" in nodeFields) {
    update.endingName = parseNullableText(
      nodeFields.endingName,
      "endingName",
      maxTitleChars
    );
  }
  if ("endingType" in nodeFields) {
    update.endingType = parseEndingType(nodeFields.endingType);
  }
  if ("ttsText" in nodeFields) {
    update.ttsText = parseText(nodeFields.ttsText, "ttsText", maxTtsChars);
  }
  if ("lineApproved" in nodeFields) {
    update.lineApproved = parseBoolean(
      nodeFields.lineApproved,
      "lineApproved"
    );
  }
  if ("ttsApproved" in nodeFields) {
    update.ttsApproved = parseBoolean(nodeFields.ttsApproved, "ttsApproved");
  }
  if ("windowSeconds" in nodeFields) {
    update.windowSeconds = parseWindow(nodeFields.windowSeconds, isEnding);
  }
  if ("choices" in nodeFields) {
    update.choices = parseChoices(nodeFields.choices, isEnding);
  }
  idleVoiceOnNewLine(nodeFields, current, update);
  return update;
};

/**
 * New words invalidate both approvals: the stored voice still speaks the
 * old line, so it drops to idle and the voice approval clears. An explicit
 * line approval in the same save is honored (the author just reviewed the
 * new words); an explicit voice approval is not (no take speaks them yet).
 * @param {Object} nodeFields Raw node payload.
 * @param {Object} current Stored node fields.
 * @param {Object} update The validated update under construction.
 */
const idleVoiceOnNewLine = (
  nodeFields: {[field: string]: unknown},
  current: {[field: string]: unknown},
  update: Record<string, unknown>
): void => {
  if (!("ttsText" in nodeFields)) return;
  const before = typeof current.ttsText === "string" ? current.ttsText : "";
  if (update.ttsText === before) return;
  if (!("lineApproved" in nodeFields)) update.lineApproved = false;
  update.ttsStatus = "idle";
  update.ttsAudioUrl = null;
  update.ttsDurationSeconds = null;
  update.ttsApproved = false;
};

/**
 * Strict boolean field.
 * @param {unknown} value Raw value.
 * @param {string} field Field name for the error.
 * @return {boolean} The value.
 */
const parseBoolean = (value: unknown, field: string): boolean => {
  if (typeof value !== "boolean") {
    throw new HttpsError("invalid-argument", `${field} must be a boolean.`);
  }
  return value;
};

/**
 * Trims and caps a required text field; blanks stay blank in drafts.
 * @param {unknown} value Raw value.
 * @param {string} field Field name for the error.
 * @param {number} max Kept characters.
 * @return {string} The clean text.
 */
const parseText = (value: unknown, field: string, max: number): string => {
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", `${field} must be a string.`);
  }
  if (value.length > max) {
    throw new HttpsError(
      "invalid-argument",
      `${field} is limited to ${max} characters.`
    );
  }
  return value.trim();
};

/**
 * Trims and caps a nullable text field; blanks become null.
 * @param {unknown} value Raw value.
 * @param {string} field Field name for the error.
 * @param {number} max Kept characters.
 * @return {string | null} The clean text, or null.
 */
const parseNullableText = (
  value: unknown,
  field: string,
  max: number
): string | null => {
  if (value === null) return null;
  const text = parseText(value, field, max);
  return text === "" ? null : text;
};

/**
 * Author-facing visibility.
 * @param {unknown} value Raw value.
 * @return {string} `visible` or `secret`.
 */
const parseVisibility = (value: unknown): string => {
  if (value !== "visible" && value !== "secret") {
    throw new HttpsError(
      "invalid-argument",
      "visibility must be visible or secret."
    );
  }
  return value;
};

/**
 * Ending type, or null when the author cleared it.
 * @param {unknown} value Raw value.
 * @return {string | null} The type, or null.
 */
const parseEndingType = (value: unknown): string | null => {
  if (value === null) return null;
  if (typeof value !== "string" || value.trim() === "") return null;
  if (!endingTypes.includes(value)) {
    throw new HttpsError(
      "invalid-argument",
      "endingType must be abierto, tragico, or secreto."
    );
  }
  return value;
};

/**
 * Decision window. Endings normalize to null to match the checklist.
 * @param {unknown} value Raw value.
 * @param {boolean} isEnding Whether the node is an ending.
 * @return {number | null} The window, or null.
 */
const parseWindow = (value: unknown, isEnding: boolean): number | null => {
  if (isEnding) return null;
  if (typeof value !== "number" || !Number.isInteger(value) ||
    value < 3 || value > 15) {
    throw new HttpsError(
      "invalid-argument",
      "windowSeconds must be an integer between 3 and 15."
    );
  }
  return value;
};

/**
 * Validates the choice list. Targets stay unchecked: a choice may point
 * at the node created next, and publish validation reports danglers.
 * @param {unknown} value Raw `choices` value.
 * @param {boolean} isEnding Whether the node is an ending.
 * @return {ChoiceFields[]} The clean choices.
 */
const parseChoices = (value: unknown, isEnding: boolean): ChoiceFields[] => {
  if (!Array.isArray(value)) {
    throw new HttpsError("invalid-argument", "choices must be an array.");
  }
  if (value.length > maxChoices) {
    throw new HttpsError(
      "invalid-argument",
      `At most ${maxChoices} choices per node.`
    );
  }
  if (isEnding && value.length > 0) {
    throw new HttpsError(
      "invalid-argument",
      "Clear choices before marking an ending."
    );
  }
  return value.map((item, index) => parseChoice(item, index));
};

/**
 * Validates one choice. Zones default to the frame center.
 * @param {unknown} item Raw choice item.
 * @param {number} index Position for the error.
 * @return {ChoiceFields} The clean choice.
 */
const parseChoice = (item: unknown, index: number): ChoiceFields => {
  const itemFields = asFields(item);
  if (itemFields === null) {
    throw new HttpsError(
      "invalid-argument",
      `Choice ${index} must be an object.`
    );
  }
  const rawId = itemFields.choiceId;
  if (typeof rawId !== "string" || rawId.trim() === "") {
    throw new HttpsError(
      "invalid-argument",
      `Choice ${index} needs a choiceId.`
    );
  }
  const rawTarget = itemFields.targetNodeId;
  if (typeof rawTarget !== "string" || rawTarget.trim() === "") {
    throw new HttpsError(
      "invalid-argument",
      `Choice ${index} needs a targetNodeId.`
    );
  }
  return {
    choiceId: rawId.trim(),
    label: parseText(
      itemFields.label ?? "", `Choice ${index} label`, maxLabelChars
    ),
    targetNodeId: rawTarget.trim(),
    isDefault: "isDefault" in itemFields ?
      parseBoolean(itemFields.isDefault, `Choice ${index} isDefault`) :
      false,
    x: parseZone(itemFields.x, `Choice ${index} x`, 0.5),
    y: parseZone(itemFields.y, `Choice ${index} y`, 0.5),
    radius: parseZone(itemFields.radius, `Choice ${index} radius`, 0.15),
  };
};

/**
 * Hold-zone coordinate inside the 0-1 frame; absent means the default.
 * @param {unknown} value Raw value.
 * @param {string} field Field name for the error.
 * @param {number} fallback Default when absent.
 * @return {number} The coordinate.
 */
const parseZone = (value: unknown, field: string, fallback: number): number => {
  if (value === undefined) return fallback;
  if (typeof value !== "number" || !Number.isFinite(value) ||
    value < 0 || value > 1) {
    throw new HttpsError(
      "invalid-argument",
      `${field} must be inside the 0-1 frame.`
    );
  }
  return value;
};
