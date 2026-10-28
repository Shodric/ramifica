import * as admin from "firebase-admin";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {
  cleanId,
  Db,
  docData,
  optionalId,
  optString,
  requireUid,
  toRecord,
} from "../feed/shared";

/** One proposed choice label for a decision node. */
export interface GeneratedChoice {
  label: string;
}

/** Proposed node text. Nulls mean the provider offered nothing usable. */
export interface GenerateNodeTextResult {
  title: string | null;
  ttsText: string | null;
  choices: GeneratedChoice[];
  endingName: string | null;
}

/** Minimal POST surface the text provider needs; keeps tests offline. */
export interface TextFetch {
  (url: string, init: {
    method: string;
    headers: Record<string, string>;
    body: string;
  }): Promise<{
    ok: boolean;
    status: number;
    json: () => Promise<unknown>;
  }>;
}

/** Injectable provider pieces so tests run without OpenRouter. */
export interface TextGenDeps {
  apiKey?: string;
  model?: string;
  fetchFn?: TextFetch;
}

/** OpenRouter chat endpoint; TTS in media/voice uses the same provider. */
const chatUrl = "https://openrouter.ai/api/v1/chat/completions";

/** Default chat model: cheap and fast; override with OPENROUTER_TEXT_MODEL. */
const defaultTextModel = "google/gemini-2.5-flash-lite";

/**
 * Cost guard: author prompt plus context past this is rejected, so one
 * call cannot smuggle a novel into the provider bill.
 */
const maxPromptChars = 2000;

/** Cost guard: the provider answer is cut off past this many tokens. */
const maxTokens = 500;

/** Narrator lines past this are clipped; the player reads them verbatim. */
const maxTtsChars = 280;

/** What Spark is allowed to propose: node text fields only, as JSON. */
const systemPrompt = [
  "You write micro-fiction text for Ramifica, a vertical-video story app.",
  "Propose node text fields only: a title of 1-40 characters, one narrator",
  "line of one or two sentences, one or two choice labels of 1-24 characters",
  "each for decision nodes, and an ending name for ending nodes.",
  "Write in the same language as the story context; default to Spanish.",
  "Answer with a single JSON object only, no fences or commentary:",
  "{\"title\": string|null, \"ttsText\": string|null,",
  "\"choices\": [{\"label\": string}], \"endingName\": string|null}.",
].join(" ");

/**
 * Spark proposes node text: title, narrator line, choice labels, and (for
 * endings) the ending name. Proposal-only: this reads the draft and the
 * node, then returns text. It never writes; the client saves through an
 * explicit save the author approves, so generated text never overwrites
 * manual edits unasked.
 */
export const generateNodeText = onCall(
  // Lower ceiling than the player paths: text calls bill per token.
  {enforceAppCheck: true, maxInstances: 10},
  async (req) => {
    const uid = requireUid(req.auth);
    return generateNodeTextWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `generateNodeText`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, nodeId?, prompt?, context?}`.
 * @param {TextGenDeps} deps Provider overrides for tests.
 * @return {Promise<GenerateNodeTextResult>} The proposed text.
 */
export const generateNodeTextWith = async (
  db: Db,
  uid: string,
  data: unknown,
  deps: TextGenDeps = {}
): Promise<GenerateNodeTextResult> => {
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  const nodeId = optionalId(fields.nodeId);
  const authorText = [optString(fields.prompt), optString(fields.context)]
    .filter((part): part is string => part !== null)
    .join("\n\n");
  if (authorText.length > maxPromptChars) {
    throw new HttpsError(
      "invalid-argument",
      `Prompt is limited to ${maxPromptChars} characters.`
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

  let isEnding: boolean | null = null;
  let current: {[field: string]: unknown} | null = null;
  if (nodeId !== null) {
    const nodeSnap = await db.doc(`stories/${storyId}/nodes/${nodeId}`).get();
    if (!nodeSnap.exists) {
      throw new HttpsError("not-found", "Node not found.");
    }
    current = docData(nodeSnap, "Node");
    isEnding = current.isEnding === true;
  }

  const content = await completeText(story, current, authorText, deps);
  return sanitizeProposal(content, isEnding);
};

/**
 * Unknown value as a field map, or null. Narrows with runtime checks so
 * callers read validated fields instead of casting unchecked shapes.
 * @param {unknown} value Raw value.
 * @return {Object} The field map, or null.
 */
export const asFields = (value: unknown): {[field: string]: unknown} | null => {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }
  const fields: {[field: string]: unknown} = {};
  for (const [key, entry] of Object.entries(value)) fields[key] = entry;
  return fields;
};
/**
 * Asks OpenRouter for the node text and returns the raw answer string.
 * @param {Object} story Draft story fields for context.
 * @param {Object} node Node fields for context, or null without a node.
 * @param {string} authorText Author prompt plus context, already capped.
 * @param {TextGenDeps} deps Provider overrides for tests.
 * @return {Promise<string>} The raw provider answer.
 */
const completeText = async (
  story: {[field: string]: unknown},
  node: {[field: string]: unknown} | null,
  authorText: string,
  deps: TextGenDeps
): Promise<string> => {
  const apiKey = deps.apiKey ?? process.env.OPENROUTER_API_KEY;
  if (!apiKey) {
    throw new HttpsError(
      "failed-precondition",
      "Text generation is not configured."
    );
  }
  const model =
    deps.model ?? process.env.OPENROUTER_TEXT_MODEL ?? defaultTextModel;
  const fetchFn: TextFetch = deps.fetchFn ?? ((url, init) =>
    fetch(url, init).then((res) => ({
      ok: res.ok,
      status: res.status,
      json: () => res.json() as Promise<unknown>,
    }))
  );
  const response = await fetchFn(chatUrl, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "HTTP-Referer": "https://ramifica.app",
      "X-Title": "Ramifica create",
    },
    body: JSON.stringify({
      model,
      max_tokens: maxTokens,
      messages: [
        {role: "system", content: systemPrompt},
        {role: "user", content: userPrompt(story, node, authorText)},
      ],
    }),
  });
  if (!response.ok) {
    throw new HttpsError(
      "unavailable",
      `Text generation failed: ${response.status}.`
    );
  }
  const payload = await response.json();
  const content = firstContent(payload);
  if (content.trim() === "") {
    throw new HttpsError(
      "internal",
      "Text generation returned nothing usable."
    );
  }
  return content;
};

/**
 * First chat choice message content, or blank when the shape is off.
 * @param {unknown} payload Decoded provider JSON.
 * @return {string} The answer text, or blank.
 */
const firstContent = (payload: unknown): string => {
  const choices = asFields(payload)?.choices;
  if (!Array.isArray(choices) || choices.length === 0) return "";
  const content = asFields(asFields(choices[0])?.message)?.content;
  return typeof content === "string" ? content : "";
};

/**
 * One choice item as its raw label: plain strings pass through, maps
 * contribute their label field, anything else is null.
 * @param {unknown} item Raw choice item.
 * @return {unknown} The raw label.
 */
const labelOf = (item: unknown): unknown => {
  if (typeof item === "string") return item;
  return asFields(item)?.label ?? null;
};

/**
 * User prompt: story and node context plus the author's ask.
 * @param {Object} story Draft story fields.
 * @param {Object} node Node fields, or null without a node.
 * @param {string} authorText Author prompt plus context.
 * @return {string} The user message.
 */
const userPrompt = (
  story: {[field: string]: unknown},
  node: {[field: string]: unknown} | null,
  authorText: string
): string => {
  const lines = [
    `Story title: ${optString(story.title) ?? "(untitled)"}.`,
  ];
  const synopsis = optString(story.synopsis);
  if (synopsis !== null) lines.push(`Synopsis: ${synopsis}.`);
  if (node !== null) {
    const title = optString(node.title);
    if (title !== null) lines.push(`Current node title: ${title}.`);
    const line = optString(node.ttsText);
    if (line !== null) lines.push(`Current narrator line: ${line}.`);
    if (Array.isArray(node.choices)) {
      const labels: string[] = [];
      for (const item of node.choices) {
        const raw = labelOf(item);
        if (typeof raw === "string" && raw.trim() !== "") {
          labels.push(raw.trim());
        }
      }
      if (labels.length > 0) {
        lines.push(`Current choice labels: ${labels.join(" / ")}.`);
      }
    }
    lines.push(
      node.isEnding === true ?
        "This node is an ending: propose an ending name, no choices." :
        "This node is a decision: propose one or two choice labels."
    );
  } else {
    lines.push("No node is open: propose text for a new node.");
  }
  if (authorText !== "") lines.push(`Author ask: ${authorText}.`);
  return lines.join("\n");
};


/**
 * Parses and clamps the provider answer to the node text contract.
 * @param {string} content Raw provider answer.
 * @param {boolean} isEnding Whether the target node is an ending.
 * @return {GenerateNodeTextResult} The proposal, never a write.
 */
const sanitizeProposal = (
  content: string,
  isEnding: boolean | null
): GenerateNodeTextResult => {
  let parsed: unknown = null;
  try {
    const start = content.indexOf("{");
    const end = content.lastIndexOf("}");
    if (start < 0 || end <= start) throw new Error("no JSON object");
    parsed = JSON.parse(content.slice(start, end + 1));
  } catch {
    throw new HttpsError(
      "internal",
      "Text generation returned an unreadable draft."
    );
  }
  const fields = asFields(parsed) ?? {};
  const title = clampText(fields.title, 40);
  const ttsText = clampText(fields.ttsText, maxTtsChars);
  const choices = clampChoices(fields.choices);
  const endingName =
    isEnding === false ? null : clampText(fields.endingName, 40);
  return {title, ttsText, choices, endingName};
};

/**
 * Trims and caps one text field; blanks become null.
 * @param {unknown} value Raw field value.
 * @param {number} max Kept characters.
 * @return {string | null} The clean text, or null.
 */
const clampText = (value: unknown, max: number): string | null => {
  if (typeof value !== "string") return null;
  const text = value.trim().slice(0, max);
  return text === "" ? null : text;
};

/**
 * Clamps the proposed labels to at most two non-blank choice labels.
 * @param {unknown} value Raw `choices` value.
 * @return {GeneratedChoice[]} The clean labels.
 */
const clampChoices = (value: unknown): GeneratedChoice[] => {
  if (!Array.isArray(value)) return [];
  const choices: GeneratedChoice[] = [];
  for (const item of value.slice(0, 2)) {
    const label = clampText(labelOf(item), 24);
    if (label !== null) choices.push({label});
  }
  return choices;
};
