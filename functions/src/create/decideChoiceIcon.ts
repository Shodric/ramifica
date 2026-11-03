import * as admin from "firebase-admin";
import {HttpsError} from "firebase-functions/v2/https";
import {onCallSafe} from "../callable";
import {openRouterApiKey, openRouterConfig} from "../config/ai";
import {
  asRecord,
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
import {choiceIconCategories} from "./choiceIconCategories";
import {OpenRouterFetch, postDecisions} from "../media/openrouter";

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

/**
 * Choice criteria from a catalog. Keys are the valid answers; the names
 * double as descriptions since they are plain English words.
 * @param {string[]} names Catalogued names.
 * @return {Record<string, string>} The criteria map.
 */
const criteriaFrom = (
  names: readonly string[]
): Record<string, string> =>
  Object.fromEntries(names.map((name) => [name, name]));

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
  const state = [
    "Ramifica hotspot styling: pick the icon and color for one choice.",
    previous === null ? null : `Previous decision: ${previous}.`,
    title === null ? null : `Scene title: ${title}.`,
    line === null ? null : `Narrator line: ${line}.`,
    clip === null ? null : `Clip: ${clip}.`,
    siblings.length === 0 ?
      null :
      "Sibling choices (pick an icon none of them uses): " +
      `${siblings.join(" / ")}.`,
    `Choice to style: ${label}.`,
  ].filter((part): part is string => part !== null);
  if (state.join("\n").length > maxContextChars) {
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
  const callArgs = {
    apiKey: deps.apiKey ?? config.apiKey,
    model: deps.model ?? config.decisionModel,
    state,
    fetchFn: deps.fetchFn,
  };
  // Stage 1: the catalog holds more icons than one `choice` question
  // accepts (256), so the model first picks a category and the color.
  const first = await postDecisions({
    ...callArgs,
    questions: {
      iconCategory: {
        type: "choice",
        instructions:
          `Which icon category best represents the choice "${label}" ` +
          "in this story?",
        criteria: criteriaFrom(Object.keys(choiceIconCategories)),
      },
      iconColor: {
        type: "choice",
        instructions:
          `Which color fits the mood of the choice "${label}"?`,
        criteria: criteriaFrom(knownChoiceIconColors),
      },
    },
  });
  const firstAnswers = asRecord(asRecord(first)?.answers);
  const category = pickAnswer(firstAnswers, "iconCategory");
  const color = pickAnswer(firstAnswers, "iconColor");
  const iconColor =
    color !== null &&
    (knownChoiceIconColors as readonly string[]).includes(color) ?
      color :
      null;
  const names =
    category === null ? undefined : choiceIconCategories[category];
  if (names === undefined) return {icon: null, iconColor};
  // Stage 2: the icon inside the chosen category.
  const second = await postDecisions({
    ...callArgs,
    questions: {
      icon: {
        type: "choice",
        instructions:
          `Which icon best represents the choice "${label}" ` +
          "in this story? Prefer one the siblings do not use.",
        criteria: criteriaFrom(names),
      },
    },
  });
  const icon = pickAnswer(asRecord(asRecord(second)?.answers), "icon");
  return {
    icon:
      icon !== null &&
      (names as readonly string[]).includes(icon) &&
      (knownChoiceIcons as readonly string[]).includes(icon) ?
        icon :
        null,
    iconColor,
  };
};

/**
 * Reads one typed answer from a Decisions payload.
 * @param {Record<string, unknown> | null} answers The `answers` map.
 * @param {string} name The question name.
 * @return {string | null} The choice, or null when off-shape.
 */
const pickAnswer = (
  answers: Record<string, unknown> | null,
  name: string
): string | null => {
  const choice = asRecord(answers?.[name])?.choice;
  return typeof choice === "string" ? choice : null;
};
