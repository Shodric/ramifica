import * as admin from "firebase-admin";
import {HttpsError} from "firebase-functions/v2/https";
import {onCallSafe} from "../callable";
import {aiDefaults, metaApiKey, metaConfig} from "../config/ai";
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
  completeChatMeta,
  MetaFetch,
  MetaHttpError,
} from "../media/meta";

/** One proposed choice: label plus optional hotspot styling. Unknown
 * icon/color names fail closed to null, so the client draws its index
 * fallback the way legacy choices without icons do. */
export interface GeneratedChoice {
  label: string;
  icon: string | null;
  iconColor: string | null;
}

/**
 * Proposed node text. Whole-scene answers fill every key; section scopes
 * return only their own keys with nulls dropped. Missing keys read as
 * null (empty choices) on the client.
 */
export interface GenerateNodeTextResult {
  title?: string | null;
  ttsText?: string | null;
  choices?: GeneratedChoice[];
  endingName?: string | null;
  startImagePrompt?: string | null;
  videoPrompt?: string | null;
}

/** Minimal POST surface the text provider needs; keeps tests offline. */
export type TextFetch = MetaFetch;

/** Injectable provider pieces so tests run without Meta. */
export interface TextGenDeps {
  apiKey?: string;
  model?: string;
  fetchFn?: TextFetch;
}

/** Default chat model; override with META_TEXT_MODEL. */
export const defaultTextModel = aiDefaults.meta.textModel;

/**
 * Cost guard: author prompt plus context past this is rejected, so one
 * call cannot smuggle a novel into the provider bill.
 */
const maxPromptChars = 2000;

/** Narrator lines past this are clipped; the player reads them verbatim. */
const maxTtsChars = 280;

/**
 * Per-scope output caps. Meta counts reasoning plus visible tokens
 * against `max_tokens`, so these stay generous: a tight cap lets the
 * reasoning eat the budget and yields an empty answer. Speed comes
 * from minimal reasoning, not from the cap. Only the whole-scene
 * scope keeps the model default.
 */
const scopeMaxTokens: Record<string, number> = {
  narration: 1024,
  info: 1024,
  options: 1024,
  startframe: 2048,
  clip: 2048,
};

/** Media prompts past this are clipped; mirrors generateNodeMedia builds. */
const maxMediaPromptChars = 2000;

/** Choice labels past this are clipped, like every label field. */
const maxLabelChars = 24;

/** At most two choices: the canvas draws slots A/B only. */
const maxChoices = 2;

/**
 * Hotspot icon names the text proposal may use. Mirrors
 * `lib/core/widgets/choice_icon.dart` (`choiceIconOptions`) and the
 * shared `catalog.json` reference; unknown names fail closed to null.
 */
export const knownChoiceIcons: readonly string[] = [
  "mountain", "forest", "lightning", "key", "unlock", "shield",
  "fingerprint", "compass", "door", "star", "heart", "eye", "sun",
  "moon", "fire", "water", "castle", "anchor", "ship", "plane", "car",
  "run", "walk", "diamond", "flag", "map", "home", "beach", "snow",
  "trophy", "rocket", "bulb", "pets", "leaf", "music", "dice",
  "puzzle", "camera", "food", "coffee", "masks", "sparkles",
  "question", "lock", "clock", "tree", "gift", "book",
  "church", "mosque", "temple", "thunder", "tornado", "waves",
  "grass", "flower", "bug", "backpack", "cake", "wine",
  "icecream", "hourglass", "history", "satellite", "globe",
  "umbrella", "magic", "moonshield", "desert", "river", "cloud",
  "fog", "wind", "night", "dawn", "eclipse", "pest", "wildlife",
  "pizza", "burger", "noodles", "breakfast", "bakery", "tea",
  "tavern", "bar", "bike", "boat", "train", "tram", "bus",
  "subway", "moto", "scooter", "city", "factory", "shop",
  "garden", "arena", "gym", "school", "library", "museum",
  "bank", "hospital", "pharmacy", "inn", "fuel", "hammer",
  "wrench", "tools", "gear", "search", "torch", "bed",
  "tv", "radio", "phone", "watch", "audio", "speaker", "mic",
  "game", "cards", "coin", "cash", "card", "wallet", "world",
  "radar", "song", "album", "playlist", "festival", "ball",
  "hoop", "tennis", "swim", "surf", "ski", "skate", "yoga",
  "medal", "robot", "check", "cross", "warning", "info", "ban",
  "power", "infinity", "chip", "code", "terminal", "signal",
  "bluetooth", "gps", "battery", "scan", "hike", "kayak",
  "dive", "glide", "pencil", "math", "lab", "art", "brush",
  "image", "print", "mail", "dates", "face", "hand", "smile",
  "sorrow", "sleep", "party", "crew", "chat", "call", "share",
  "box", "bag", "cart", "tag", "ticket", "receipt", "news",
  "tap", "gesture", "swipe", "drag", "launch", "portal", "input",
  "output", "login", "logout", "undo", "redo", "shuffle", "repeat",
  "renew", "sync", "swap", "more", "zoom", "tune", "pact",
  "like", "dislike", "wave", "halt", "reach", "pin", "target",
  "locate", "tribe", "voice", "access", "mood", "calm", "joy",
  "grief", "sick", "clean", "play", "blaze", "burst", "bright",
  "volcano", "flood", "tsunami", "cyclone", "snowfall", "rescue",
  "crush", "heartbreak", "blood", "aid", "pulse", "medic", "heal",
  "pills", "safe", "halfstar", "wish", "elite", "crescent", "dish",
  "premium", "member", "verified", "approval", "debut", "redeem",
  "ranks", "verdict", "scales", "unseen", "guard", "ward",
  "fighter", "wrestle", "build", "plan", "keys", "beat", "levels",
  "headset", "surround", "video", "tunes", "hive", "dash", "park",
  "spa", "tub", "fast", "dinner", "brunch", "meal", "soup",
  "kebab", "donut", "egg", "omelette", "rice", "bbq", "tapas",
  "apartment", "villa", "cabin", "cottage", "chalet", "bungalow",
  "houseboat", "fort", "police", "post", "synagogue", "cinema",
  "film", "boutique", "mall", "laundry", "press", "carwash",
  "repair", "shuttle", "camper", "truck", "forklift", "tractor",
  "ebike", "moped", "roller", "iceskate", "snowmobile", "sled",
  "chair", "table", "sofa", "lounge", "bath", "wc", "counter",
  "kitchen", "microwave", "mop", "paint", "wallpaper", "curtains",
  "window", "balcony", "fence", "garage", "warehouse", "elevator",
  "stairs", "escalator", "roofing", "fireplace", "deck", "laptop",
  "desktop", "monitor", "tablet", "keyboard", "mouse", "webcam",
  "router", "server", "storage", "feed", "podcast", "tower",
  "megaphone", "timer", "timelapse", "schedule", "event", "bell",
  "badge", "unread", "drafts", "send", "inbox", "outbox",
  "archive", "folder", "doc", "file", "save", "download", "upload",
  "backup", "restore", "update", "upgrade", "charge", "plug",
  "cable", "usb", "sdcard", "sim", "ar", "spin", "droid", "toys",
];

/**
 * Hotspot color names the text proposal may use. Mirrors
 * `lib/core/widgets/choice_icon.dart` (`choiceColorOptions`) and the
 * shared `catalog.json` reference; unknown names fail closed to null.
 */
export const knownChoiceIconColors: readonly string[] = [
  "cyan", "blue", "violet", "pink", "red", "orange", "gold", "green",
  "mint", "white", "teal", "indigo", "lime", "amber", "brown", "grey",
];

/** What Spark is allowed to propose: node text and media prompts, as JSON. */
const systemPrompt = [
  "You write micro-fiction text for Ramifica, a vertical-video story app.",
  "Each node plays as a vertical 9:16 clip with no on-screen text: ",
  "propose a title of 1-40 characters, one narrator line of one or two ",
  "sentences, and matching visual prompts: a start image prompt (opening ",
  "establishing frame), an end image prompt (closing payoff frame, ",
  "continuous with the start frame), and a video prompt (slow morph from ",
  "start to end). Keep each media prompt photorealistic and under 2000 ",
  "characters.",
  "For decision nodes propose one or two choices: each a label of 1-24 ",
  "characters naming the moment of choosing. Do not propose icons: a ",
  "later decision step styles each choice. For ending nodes propose an ",
  "ending name of 1-40 characters and no choices.",
  "Write in the same language as the story context; default to Spanish.",
  "Answer with a single JSON object only, no fences or commentary:",
  "{\"title\": string|null, \"ttsText\": string|null,",
  "\"choices\": [{\"label\": string}], \"endingName\": string|null,",
  "\"startImagePrompt\": string|null, \"videoPrompt\": string|null}.",
].join(" ");

/** Info opens a node: title, narrator line, and ending name. */
const infoPrompt = [
  "Propose the opening text for one story node: a title of 1-40",
  "characters, one narrator line of at most 280 characters, and for",
  "ending nodes an ending name of 1-40 characters. The narrator line",
  "presents the scene in one short sentence, then closes with the",
  "question that mirrors the current options, addressing the player",
  "in the second person. For an ending, close it in the second",
  "person without inventing a choice or question.",
  "Match the story's language; default to Spanish.",
  "Return only JSON: {\"title\": string|null, \"ttsText\": string,",
  "\"endingName\": string|null}.",
].join(" ");

/** The start frame is the first still the player sees. */
const startFramePrompt = [
  "Propose the opening establishing-frame image prompt for one story",
  "node: one photorealistic prompt under 2000 characters describing",
  "the first frame the player sees.",
  "Match the story's language; default to Spanish.",
  "Return only JSON: {\"startImagePrompt\": string}.",
].join(" ");

/** The clip prompt drives the slow vertical morph. */
const clipPrompt = [
  "Propose the vertical 9:16 video prompt for one story node: one",
  "photorealistic prompt under 2000 characters describing a slow",
  "continuous morph with no on-screen text.",
  "Match the story's language; default to Spanish.",
  "Return only JSON: {\"videoPrompt\": string}.",
].join(" ");

/** Options name the moment of choosing, unstyled. */
const optionsPrompt = [
  "Propose one or two choices for one decision node: each a label of",
  "1-24 characters naming the moment of choosing. Do not propose",
  "icons: a later decision step styles each choice.",
  "Match the story's language; default to Spanish.",
  "Return only JSON: {\"choices\": [{\"label\": string}]}.",
].join(" ");

/** Narration is heard after the clip, at the decision point. */
const narrationPrompt = [
  "Write the narrator line for an interactive story's decision point.",
  "The clip has already ended. The player hears this line just before",
  "choosing one of the current options. Present the scene in one short",
  "sentence, then close with the question that mirrors those options.",
  "Address the player in the second person. Invite a choice without",
  "making it for the player or revealing its outcome. Do not narrate",
  "the whole clip or premise.",
  "For an ending, close the ending in the second person without",
  "inventing a choice or question.",
  "Use at most 280 characters.",
  "Match the story's language; default to Spanish.",
  "Return only JSON: {\"ttsText\": string}.",
].join(" ");

type TextPurpose =
  "scene" | "narration" | "info" | "startframe" | "clip" | "options" | null;

/**
 * Spark proposes node text: title, narrator line, choice labels, and (for
 * endings) the ending name. Proposal-only: this reads the draft and the
 * node, then returns text. It never writes; the client saves through an
 * explicit save the author approves, so generated text never overwrites
 * manual edits unasked.
 */
export const generateNodeText = onCallSafe(
  // Lower ceiling than the player paths: text calls bill per token.
  {
    enforceAppCheck: !isEmulator(), maxInstances: 10,
    secrets: [metaApiKey],
  },
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
  const purpose = optString(fields.purpose);
  if (
    purpose !== null &&
    purpose !== "scene" &&
    purpose !== "narration" &&
    purpose !== "info" &&
    purpose !== "startframe" &&
    purpose !== "clip" &&
    purpose !== "options"
  ) {
    throw new HttpsError("invalid-argument", "Unknown text purpose.");
  }
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
  let isChild = false;
  let current: {[field: string]: unknown} | null = null;
  const rootId = optString(story.rootNodeId);
  if (nodeId !== null) {
    const nodeSnap = await db.doc(`stories/${storyId}/nodes/${nodeId}`).get();
    if (!nodeSnap.exists) {
      throw new HttpsError("not-found", "Node not found.");
    }
    current = docData(nodeSnap, "Node");
    isEnding = current.isEnding === true;
    // Non-root nodes inherit the S frame from their parent, so they
    // carry no start prompt of their own.
    isChild = rootId !== null && rootId !== nodeId;
  } else {
    // A new node in a story that already has a root will be attached as
    // a child; only the first node is a root.
    isChild = rootId !== null;
  }

  const content = await completeText(story, current, authorText, deps, purpose);
  const proposal = sanitizeProposal(content, isEnding, isChild);
  if (purpose === "scene") {
    // Icons are decided separately per choice; the scene carries labels.
    return {
      ...proposal,
      choices: (proposal.choices ?? []).map((choice) => ({
        ...choice, icon: null, iconColor: null,
      })),
    };
  }
  if (purpose === "narration") {
    return compactSection({ttsText: proposal.ttsText});
  }
  if (purpose === "info") {
    return compactSection({
      title: proposal.title,
      ttsText: proposal.ttsText,
      endingName: proposal.endingName,
    });
  }
  if (purpose === "startframe") {
    return compactSection({startImagePrompt: proposal.startImagePrompt});
  }
  if (purpose === "clip") {
    return compactSection({videoPrompt: proposal.videoPrompt});
  }
  if (purpose === "options") {
    // Icons are decided separately per choice; options carry labels.
    return compactSection({
      choices: (proposal.choices ?? []).map((choice) => ({
        label: choice.label,
      })),
    });
  }
  return proposal;
};

/**
 * Minimal JSON for one section scope: only the scope's keys, dropping
 * nulls and empty lists so scoped answers stay small on the wire.
 * @param {Object} fields The scope's raw fields.
 * @return {GenerateNodeTextResult} The compact answer.
 */
const compactSection = (fields: {
  title?: string | null;
  ttsText?: string | null;
  choices?: Array<{label: string}>;
  endingName?: string | null;
  startImagePrompt?: string | null;
  videoPrompt?: string | null;
}): GenerateNodeTextResult => {
  const out: {[key: string]: unknown} = {};
  for (const [key, value] of Object.entries(fields)) {
    if (value === null || value === undefined) continue;
    if (Array.isArray(value) && value.length === 0) continue;
    out[key] = value;
  }
  return out as GenerateNodeTextResult;
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
 * System prompt for one text scope: whole-scene, one section, or legacy.
 * @param {TextPurpose} purpose Requested text scope.
 * @return {string} The system message.
 */
const scopeSystemPrompt = (purpose: TextPurpose): string => {
  switch (purpose) {
  case "narration":
    return narrationPrompt;
  case "info":
    return infoPrompt;
  case "startframe":
    return startFramePrompt;
  case "clip":
    return clipPrompt;
  case "options":
    return optionsPrompt;
  case "scene":
    return systemPrompt +
        " This request covers the whole scene, narrator line included.";
  default:
    return systemPrompt;
  }
};

/**
 * Asks Meta for the node text and returns the raw answer string.
 * @param {Object} story Draft story fields for context.
 * @param {Object} node Node fields for context, or null without a node.
 * @param {string} authorText Author prompt plus context, already capped.
 * @param {TextGenDeps} deps Provider overrides for tests.
 * @param {TextPurpose} purpose Scene, one section, or legacy full text.
 * @return {Promise<string>} The raw provider answer.
 */
const completeText = async (
  story: {[field: string]: unknown},
  node: {[field: string]: unknown} | null,
  authorText: string,
  deps: TextGenDeps,
  purpose: TextPurpose
): Promise<string> => {
  const config = metaConfig();
  const apiKey = deps.apiKey ?? config.apiKey;
  if (!apiKey) {
    throw new HttpsError(
      "failed-precondition",
      "Text generation is not configured."
    );
  }
  const model = deps.model ?? config.textModel;
  let content: string;
  try {
    content = await completeChatMeta({
      apiKey,
      model,
      system: scopeSystemPrompt(purpose),
      user: userPrompt(story, node, authorText, purpose),
      // Scoped calls answer small shaped JSON: minimal reasoning (Spark
      // has no off switch) and a tight token cap keep them fast.
      ...(purpose !== null && purpose in scopeMaxTokens ?
        {maxTokens: scopeMaxTokens[purpose], reasoningEffort: "minimal"} :
        {}),
      fetchFn: deps.fetchFn,
    });
  } catch (error) {
    if (error instanceof MetaHttpError) {
      throw new HttpsError(
        "unavailable",
        `Text generation failed: ${error.status}.`
      );
    }
    throw error;
  }
  if (content.trim() === "") {
    throw new HttpsError(
      "internal",
      "Text generation returned nothing usable."
    );
  }
  return content;
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
 * @param {TextPurpose} purpose Requested text scope.
 * @return {string} The user message.
 */
const userPrompt = (
  story: {[field: string]: unknown},
  node: {[field: string]: unknown} | null,
  authorText: string,
  purpose: TextPurpose
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
        "This node is an ending: close its final beat, no choices." :
        purpose === "narration" || purpose === "info" ?
          "This node is a decision: speak just before the player chooses." :
          purpose === "clip" || purpose === "startframe" ?
            "This node is a decision: describe its visuals only." :
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
 * Endings carry no choices; child nodes carry no start prompt (the S
 * frame is inherited). Legacy answers — plain-string choices, missing
 * prompts — still parse.
 * @param {string} content Raw provider answer.
 * @param {boolean} isEnding Whether the target node is an ending.
 * @param {boolean} isChild Whether the target node inherits S from a parent.
 * @return {GenerateNodeTextResult} The proposal, never a write.
 */
const sanitizeProposal = (
  content: string,
  isEnding: boolean | null,
  isChild: boolean
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
  const choices =
    isEnding === true ? [] : clampChoices(fields.choices);
  const endingName =
    isEnding === false ? null : clampText(fields.endingName, 40);
  const startImagePrompt =
    isChild ? null : clampText(fields.startImagePrompt, maxMediaPromptChars);
  const videoPrompt = clampText(fields.videoPrompt, maxMediaPromptChars);
  return {
    title,
    ttsText,
    choices,
    endingName,
    startImagePrompt,
    videoPrompt,
  };
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
 * Clamps the proposed choices to at most two entries with clean labels
 * and catalogued styling. Plain strings pass as labels (legacy answers);
 * unknown icon/color names fail closed to null.
 * @param {unknown} value Raw `choices` value.
 * @return {GeneratedChoice[]} The clean choices.
 */
const clampChoices = (value: unknown): GeneratedChoice[] => {
  if (!Array.isArray(value)) return [];
  const choices: GeneratedChoice[] = [];
  for (const item of value) {
    if (choices.length >= maxChoices) break;
    const label = clampText(labelOf(item), maxLabelChars);
    if (label === null) continue;
    const fields = asFields(item);
    const icon =
      fields !== null &&
      typeof fields.icon === "string" &&
      (knownChoiceIcons as readonly string[]).includes(fields.icon) ?
        fields.icon :
        null;
    const iconColor =
      fields !== null &&
      typeof fields.iconColor === "string" &&
      (knownChoiceIconColors as readonly string[]).includes(
        fields.iconColor
      ) ?
        fields.iconColor :
        null;
    choices.push({label, icon, iconColor});
  }
  return choices;
};
