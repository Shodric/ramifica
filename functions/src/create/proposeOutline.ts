import {knownChoiceIcons, knownChoiceIconColors} from "./generateNodeText";
import * as admin from "firebase-admin";
import {HttpsError} from "firebase-functions/v2/https";
import {onCallSafe} from "../callable";
import {aiDefaults, metaApiKey, metaConfig} from "../config/ai";
import {
  cleanId,
  Db,
  docData,
  isEmulator,
  optString,
  requireUid,
  toRecord,
} from "../feed/shared";
import {completeChatMeta, MetaFetch, MetaHttpError} from "../media/meta";

/** One proposed opening option: label plus optional hotspot styling. */
export interface ProposedOutlineOption {
  label: string;
  icon: string | null;
  iconColor: string | null;
}

/** Proposed story outline. Nulls mean the provider offered nothing usable. */
export interface ProposeStoryOutlineResult {
  title: string | null;
  synopsis: string | null;
  narratorLine: string | null;
  options: ProposedOutlineOption[];
}

/** Injectable provider pieces so tests run without Meta. */
export interface OutlineGenDeps {
  apiKey?: string;
  model?: string;
  fetchFn?: MetaFetch;
}

/** Default chat model; override with META_TEXT_MODEL. */
export const defaultOutlineModel = aiDefaults.meta.textModel;

/**
 * Cost guard: spoken transcripts past this are rejected, so one call
 * cannot smuggle a monologue into the provider bill. 90 seconds of
 * speech is ~250 words, well under this ceiling.
 */
const maxTranscriptChars = 4000;

/** Story titles past this are clipped; the premise sheet reads them. */
const maxTitleChars = 40;

/** Narrator lines past this are clipped; the player reads them verbatim. */
const maxLineChars = 280;

/** Option labels past this are clipped, like every label field. */
const maxLabelChars = 24;

/** Synopsis past this is clipped; the premise sheet shows it. */
const maxSynopsisChars = 500;

/** At most two opening options: the canvas draws A/B only. */
const maxOptions = 2;

/**
 * Hotspot icon names the premise proposal may use. Mirrors
 * `lib/core/widgets/choice_icon.dart` (`choiceIconOptions`); unknown
 * names fail closed to null so the client draws its index fallback.
 */
export const knownIcons: Record<string, true> = Object.fromEntries(
  knownChoiceIcons.map((name) => [name, true as const])
);

/**
 * Hotspot color names the premise proposal may use. Mirrors
 * `lib/core/widgets/choice_icon.dart` (`choiceColorOptions`).
 */
export const knownIconColors: Record<string, true> = Object.fromEntries(
  knownChoiceIconColors.map((name) => [name, true as const])
);

/** What Spark may propose: the story outline fields only, as JSON. */
const systemPrompt = [
  "You propose the opening of an interactive audio story.",
  "Answer with one JSON object only: {\"title\", \"synopsis\", ",
  "\"narratorLine\", \"options\":[{\"label\", \"icon\", \"iconColor\"}]}.",
  "Title <= 40 chars, narratorLine <= 280 chars, each label <= 24 chars,",
  "at most 2 options.",
  `Icons must come from: ${knownChoiceIcons.join(", ")}.`,
  `Colors must come from: ${knownChoiceIconColors.join(", ")}.`,
].join(" ");

/**
 * Spark proposes the story outline from a spoken transcript: title,
 * synopsis, narrator line, and up to two opening options with hotspot
 * styling. Proposal-only: this reads the draft and returns text. It
 * never writes; the client shows the proposal editable and applies it
 * through `updateStoryDoc` + node writes only on `Aplicar`.
 */
export const proposeStoryOutline = onCallSafe(
  // Lower ceiling than the player paths: outline calls bill per token.
  {
    enforceAppCheck: !isEmulator(), maxInstances: 10,
    secrets: [metaApiKey],
  },
  async (req) => {
    const uid = requireUid(req.auth);
    return proposeStoryOutlineWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `proposeStoryOutline`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, transcript}`.
 * @param {OutlineGenDeps} deps Provider overrides for tests.
 * @return {Promise<ProposeStoryOutlineResult>} The proposed outline.
 */
export const proposeStoryOutlineWith = async (
  db: Db,
  uid: string,
  data: unknown,
  deps: OutlineGenDeps = {}
): Promise<ProposeStoryOutlineResult> => {
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  const transcript = optString(fields.transcript);
  if (transcript === null || transcript.trim() === "") {
    throw new HttpsError("invalid-argument", "A transcript is required.");
  }
  if (transcript.length > maxTranscriptChars) {
    throw new HttpsError(
      "invalid-argument",
      `Transcript is limited to ${maxTranscriptChars} characters.`
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

  const content = await completeOutline(transcript, deps);
  return sanitizeOutline(content);
};

/**
 * Asks Meta for the outline and returns the raw answer string.
 * @param {string} transcript Spoken premise, already capped.
 * @param {OutlineGenDeps} deps Provider overrides for tests.
 * @return {Promise<string>} The raw provider answer.
 */
const completeOutline = async (
  transcript: string,
  deps: OutlineGenDeps
): Promise<string> => {
  const config = metaConfig();
  const apiKey = deps.apiKey ?? config.apiKey;
  if (!apiKey) {
    throw new HttpsError(
      "failed-precondition",
      "Outline generation is not configured."
    );
  }
  const model = deps.model ?? config.textModel;
  let content: string;
  try {
    content = await completeChatMeta({
      apiKey,
      model,
      system: systemPrompt,
      user: `TRANSCRIPT: "${transcript}"`,
      fetchFn: deps.fetchFn,
    });
  } catch (error) {
    if (error instanceof MetaHttpError) {
      throw new HttpsError(
        "unavailable",
        `Outline generation failed: ${error.status}.`
      );
    }
    throw error;
  }
  if (content.trim() === "") {
    throw new HttpsError(
      "internal",
      "Outline generation returned nothing usable."
    );
  }
  return content;
};

/**
 * Parses and clamps the provider answer to the outline contract.
 * Malformed fields are discarded, never thrown: overlong text is
 * clipped, extra options are dropped, unknown icons/colors are nulled,
 * and blank labels drop their option.
 * @param {string} content Raw provider answer.
 * @return {ProposeStoryOutlineResult} The clean proposal.
 */
export const sanitizeOutline = (
  content: string
): ProposeStoryOutlineResult => {
  let parsed: unknown = null;
  try {
    parsed = JSON.parse(content);
  } catch {
    const start = content.indexOf("{");
    const end = content.lastIndexOf("}");
    if (start >= 0 && end > start) {
      try {
        parsed = JSON.parse(content.slice(start, end + 1));
      } catch {
        parsed = null;
      }
    }
  }
  const record =
    typeof parsed === "object" && parsed !== null && !Array.isArray(parsed) ?
      (parsed as {[field: string]: unknown}) :
      null;
  if (record === null) {
    throw new HttpsError(
      "internal",
      "Outline generation returned nothing usable."
    );
  }
  return {
    title: clampText(record.title, maxTitleChars),
    synopsis: clampText(record.synopsis, maxSynopsisChars),
    narratorLine: clampText(record.narratorLine, maxLineChars),
    options: clampOptions(record.options),
  };
};

/**
 * Trims and caps one text field; blanks become null.
 * @param {unknown} value Raw field value.
 * @param {number} max Cap in characters.
 * @return {string | null} The clean text, or null.
 */
const clampText = (value: unknown, max: number): string | null => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed === "") return null;
  return trimmed.slice(0, max);
};

/**
 * Clamps the proposed options to at most two well-formed entries.
 * @param {unknown} value Raw `options` value.
 * @return {ProposedOutlineOption[]} The clean options.
 */
const clampOptions = (value: unknown): ProposedOutlineOption[] => {
  if (!Array.isArray(value)) return [];
  const options: ProposedOutlineOption[] = [];
  for (const item of value) {
    if (options.length >= maxOptions) break;
    const record =
      typeof item === "object" && item !== null && !Array.isArray(item) ?
        (item as {[field: string]: unknown}) :
        null;
    const label =
      record === null ? null : clampText(record.label, maxLabelChars);
    if (label === null) continue;
    const icon =
      record !== null &&
      typeof record.icon === "string" &&
      knownIcons[record.icon] === true ?
        record.icon :
        null;
    const iconColor =
      record !== null &&
      typeof record.iconColor === "string" &&
      knownIconColors[record.iconColor] === true ?
        record.iconColor :
        null;
    options.push({label, icon, iconColor});
  }
  return options;
};
