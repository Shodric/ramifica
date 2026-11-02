import * as admin from "firebase-admin";
import {HttpsError} from "firebase-functions/v2/https";
import {onCallSafe} from "../callable";
import {openRouterApiKey, openRouterConfig} from "../config/ai";
import {
  cleanId,
  Db,
  docData,
  isEmulator,
  optionalId,
  optString,
  requireUid,
  toRecord,
} from "../feed/shared";
import {
  knownChoiceIconColors,
  knownChoiceIcons,
} from "./generateNodeText";
import {completeChat, OpenRouterFetch} from "../media/openrouter";

/** Decided hotspot styling. Nulls mean the model offered nothing usable. */
export interface DecideChoiceIconResult {
  icon: string | null;
  iconColor: string | null;
}

/** Injectable provider pieces so tests run without OpenRouter. */
export interface DecideDeps {
  apiKey?: string;
  model?: string;
  fetchFn?: OpenRouterFetch;
}

/**
 * Cost guard: the whole decision context past this is rejected, so one
 * call cannot smuggle a novel into the provider bill.
 */
const maxContextChars = 2000;

/** The answer is one tiny JSON object; cap the completion hard. */
const maxAnswerTokens = 64;

/** What the decision model may return: one catalogued icon plus color. */
const systemPrompt = [
  "You style hotspot choices for Ramifica, a vertical-video story app.",
  "Pick exactly one icon and one iconColor from the lists below for the",
  "given choice, matching its meaning in the story context. Prefer an",
  "icon the sibling choices do not use.",
  `Icons: ${knownChoiceIcons.join(", ")}.`,
  `Colors: ${knownChoiceIconColors.join(", ")}.`,
  "Answer with a single JSON object only, no fences or commentary:",
  "{\"icon\": string|null, \"iconColor\": string|null}.",
].join(" ");

export const decideChoiceIcon = onCallSafe(
  // Lower ceiling than the player paths: decision calls bill per token.
  {
    enforceAppCheck: !isEmulator(), maxInstances: 10,
    secrets: [openRouterApiKey],
  },
  async (req) => {
    const uid = requireUid(req.auth);
    return decideChoiceIconWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `decideChoiceIcon`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, nodeId?, choiceLabel,
 * siblingLabels?, previousDecision?, sceneTitle?, narratorLine?,
 * videoPrompt?}`.
 * @param {DecideDeps} deps Provider overrides for tests.
 * @return {Promise<DecideChoiceIconResult>} The styling, nulls when unusable.
 */
export const decideChoiceIconWith = async (
  db: Db,
  uid: string,
  data: unknown,
  deps: DecideDeps = {}
): Promise<DecideChoiceIconResult> => {
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  const nodeId = optionalId(fields.nodeId);
  const label = optString(fields.choiceLabel);
  if (label === null || label.length > 24) {
    throw new HttpsError("invalid-argument", "A choice label is required.");
  }
  const siblings = Array.isArray(fields.siblingLabels) ?
    fields.siblingLabels
      .filter((item): item is string =>
        typeof item === "string" && item.trim() !== "")
      .map((item) => item.trim().slice(0, 24)) :
    [];
  const previous = optString(fields.previousDecision);
  const title = optString(fields.sceneTitle);
  const line = optString(fields.narratorLine);
  const clip = optString(fields.videoPrompt);
  const context = [
    previous === null ? null : `Previous decision: ${previous}.`,
    title === null ? null : `Scene title: ${title}.`,
    line === null ? null : `Narrator line: ${line}.`,
    clip === null ? null : `Clip: ${clip}.`,
    siblings.length === 0 ?
      null :
      "Sibling choices (pick an icon none of them uses): " +
      `${siblings.join(" / ")}.`,
    `Choice to style: ${label}.`,
  ]
    .filter((part): part is string => part !== null)
    .join("\n");
  if (context.length > maxContextChars) {
    throw new HttpsError(
      "invalid-argument",
      `Context is limited to ${maxContextChars} characters.`
    );
  }

  const storySnap = await db.doc(`stories/${storyId}`).get();
  if (!storySnap.exists) {
    throw new HttpsError("not-found", "Story not found.");
  }
  const story = docData(storySnap, "Story");
  if (story.authorId !== uid) {
    throw new HttpsError("permission-denied", "Not your draft.");
  }
  if (story.status !== "draft") {
    throw new HttpsError("failed-precondition", "Only drafts can use Spark.");
  }
  if (nodeId !== null) {
    const nodeSnap = await db.doc(`stories/${storyId}/nodes/${nodeId}`).get();
    if (!nodeSnap.exists) {
      throw new HttpsError("not-found", "Node not found.");
    }
  }

  const config = openRouterConfig();
  const content = await completeChat({
    apiKey: deps.apiKey ?? config.apiKey,
    model: deps.model ?? config.decisionModel,
    system: systemPrompt,
    user: context,
    maxTokens: maxAnswerTokens,
    fetchFn: deps.fetchFn,
  });
  let parsed: unknown = null;
  try {
    const start = content.indexOf("{");
    const end = content.lastIndexOf("}");
    if (start < 0 || end <= start) throw new Error("no JSON object");
    parsed = JSON.parse(content.slice(start, end + 1));
  } catch {
    return {icon: null, iconColor: null};
  }
  if (parsed === null || typeof parsed !== "object") {
    return {icon: null, iconColor: null};
  }
  const record = parsed as Record<string, unknown>;
  const icon =
    typeof record.icon === "string" &&
    (knownChoiceIcons as readonly string[]).includes(record.icon) ?
      record.icon :
      null;
  const iconColor =
    typeof record.iconColor === "string" &&
    (knownChoiceIconColors as readonly string[]).includes(record.iconColor) ?
      record.iconColor :
      null;
  return {icon, iconColor};
};
