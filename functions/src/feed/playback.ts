import {HttpsError} from "firebase-functions/v2/https";
import {
  asRecord,
  Db,
  docData,
  readPlayableStory,
  rewardCodeFor,
  rewardIdFor,
} from "./shared";

export interface PlaybackChoiceView {
  choiceId: string;
  label: string;
  targetNodeId: string;
  isDefault: boolean;
  x: number;
  y: number;
  radius: number;
  targetSecret: boolean;
  target: {nodeId: string; videoUrl: string} | null;
}

export interface PlaybackReward {
  rewardId: string;
  code: string;
}

export interface PlaybackView {
  runId: string;
  status: string;
  story: {storyId: string; title: string; authorName: string};
  node: {
    nodeId: string;
    title: string;
    isEnding: boolean;
    videoUrl: string;
    durationSeconds: number;
    pauseAtSeconds: number;
    windowSeconds: number;
    ttsText: string | null;
    ttsAudioUrl: string | null;
    ttsDurationSeconds: number | null;
    videoFrameLastBlurData: string;
    endingName: string | null;
    endingType: string | null;
    rewardCode: string | null;
  };
  choices: PlaybackChoiceView[];
  reward: PlaybackReward | null;
}

/**
 * Builds the `loadPlayback` contract from live docs: the story, the
 * current node, and one entry per exit. Secret destinations travel as id
 * and label only; their body arrives with the `commitChoice` that reaches
 * them. On an ended run the earner's reward doc is read for the code, so
 * reopening the run completes the same code without reissuing. Pure reads,
 * no writes.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {object} run Run locator.
 * @return {Promise<PlaybackView>} The playback contract.
 */
export async function fetchPlayback(
  db: Db,
  uid: string,
  run: {runId: string; storyId: string; status: string; currentNodeId: string}
): Promise<PlaybackView> {
  const storySnap = await readPlayableStory(db, run.storyId, uid);
  const story = docData(storySnap, "Story");
  const nodeSnap = await db
    .doc(`stories/${run.storyId}/nodes/${run.currentNodeId}`)
    .get();
  const node = docData(nodeSnap, "Node");
  const authorName = await fetchAuthorName(db, story.authorId);
  const rawChoices = Array.isArray(node.choices) ? node.choices : [];
  const choices = await Promise.all(
    rawChoices.map((raw) => buildChoice(db, run.storyId, raw))
  );
  const reward =
    run.status === "ended" ?
      await readEndingReward(db, uid, run.storyId, run.currentNodeId) :
      null;
  return {
    runId: run.runId,
    status: run.status,
    story: {
      storyId: run.storyId,
      title: reqString(story.title, "story title"),
      authorName,
    },
    node: {
      nodeId: run.currentNodeId,
      title: reqString(node.title, "node title"),
      isEnding: node.isEnding === true,
      videoUrl: reqString(node.videoUrl, "node video"),
      durationSeconds: reqNumber(node.durationSeconds, "node duration"),
      pauseAtSeconds: reqNumber(node.pauseAtSeconds, "node pause"),
      windowSeconds: node.isEnding === true ?
        windowOrDefault(node.windowSeconds) :
        reqInt(node.windowSeconds, "node window"),
      ttsText: optString(node.ttsText),
      ttsAudioUrl: optString(node.ttsAudioUrl),
      ttsDurationSeconds: optNumber(node.ttsDurationSeconds),
      videoFrameLastBlurData: reqString(
        node.videoFrameLastBlurData,
        "node blur"
      ),
      endingName: optString(node.endingName),
      endingType: optString(node.endingType),
      rewardCode: reward ? reward.code : null,
    },
    choices,
    reward,
  };
}

/**
 * The earner's reward for one ending, read only. Missing docs stay null;
 * legacy docs without a stored code complete the same deterministic value
 * the grant path stores, so reopening never writes or reissues.
 * @param {Db} db Firestore.
 * @param {string} uid Earner.
 * @param {string} storyId Finished story.
 * @param {string} endingNodeId Reached ending node.
 * @return {Promise<PlaybackReward | null>} The reward, or null.
 */
const readEndingReward = async (
  db: Db,
  uid: string,
  storyId: string,
  endingNodeId: string
): Promise<PlaybackReward | null> => {
  const rewardId = rewardIdFor(storyId, endingNodeId);
  const snap = await db.doc(`users/${uid}/rewards/${rewardId}`).get();
  if (!snap.exists) return null;
  const data = snap.data();
  const code =
    optString(data?.code) ?? rewardCodeFor(uid, storyId, endingNodeId);
  return {rewardId, code};
};

const buildChoice = async (
  db: Db,
  storyId: string,
  raw: unknown
): Promise<PlaybackChoiceView> => {
  const choice = asRecord(raw);
  if (!choice) {
    throw new HttpsError("invalid-argument", "Choice is not valid.");
  }
  const targetNodeId = reqString(choice.targetNodeId, "choice target");
  const targetSnap = await db
    .doc(`stories/${storyId}/nodes/${targetNodeId}`)
    .get();
  if (!targetSnap.exists) {
    throw new HttpsError("invalid-argument", "Choice points nowhere.");
  }
  const target = docData(targetSnap, "Target node");
  const secret = target.visibility === "secret";
  return {
    choiceId: reqString(choice.choiceId, "choice id"),
    label: reqString(choice.label, "choice label"),
    targetNodeId,
    isDefault: choice.isDefault === true,
    x: reqNumber(choice.x, "choice x"),
    y: reqNumber(choice.y, "choice y"),
    radius: reqNumber(choice.radius, "choice radius"),
    targetSecret: secret,
    target: secret ?
      null :
      {
        nodeId: targetNodeId,
        videoUrl: reqString(target.videoUrl, "target video"),
      },
  };
};

const fetchAuthorName = async (
  db: Db,
  authorId: unknown
): Promise<string> => {
  if (typeof authorId !== "string" || authorId === "") return "Unknown";
  const snap = await db.doc(`users/${authorId}`).get();
  const name = snap.data()?.displayName;
  return typeof name === "string" && name.trim() !== "" ? name : "Unknown";
};

const reqString = (value: unknown, field: string): string => {
  if (typeof value !== "string" || value === "") {
    throw new HttpsError("invalid-argument", `Node is missing its ${field}.`);
  }
  return value;
};

const reqNumber = (value: unknown, field: string): number => {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new HttpsError("invalid-argument", `Node is missing its ${field}.`);
  }
  return value;
};

const reqInt = (value: unknown, field: string): number => {
  if (!Number.isInteger(value)) {
    throw new HttpsError("invalid-argument", `Node is missing its ${field}.`);
  }
  return value as number;
};

/**
 * Endings carry no window; the client contract still needs the number.
 * @param {unknown} value Raw window.
 * @return {number} The window, or the 6 s default.
 */
const windowOrDefault = (value: unknown): number => {
  return Number.isInteger(value) ? (value as number) : 6;
};

const optString = (value: unknown): string | null => {
  return typeof value === "string" && value !== "" ? value : null;
};

const optNumber = (value: unknown): number | null => {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
};
