export interface ValidatableChoice {
  choiceId: string;
  label: string;
  targetNodeId: string;
  isDefault: boolean;
  x: number;
  y: number;
  radius: number;
}

export interface ValidatableNode {
  nodeId: string;
  title: string;
  visibility: string;
  isEnding: boolean;
  endingName?: string | null;
  endingType?: string | null;
  videoUrl?: string | null;
  videoStatus?: string | null;
  videoSource?: string | null;
  videoFrameLastUrl?: string | null;
  durationSeconds?: number | null;
  pauseAtSeconds?: number | null;
  windowSeconds?: number | null;
  startImageApproved?: boolean | null;
  startFromNodeId?: string | null;
  startParentEndHash?: string | null;
  endImageApproved?: boolean | null;
  endHash?: string | null;
  ttsText?: string | null;
  lineApproved?: boolean | null;
  ttsAudioUrl?: string | null;
  ttsStatus?: string | null;
  ttsDurationSeconds?: number | null;
  ttsApproved?: boolean | null;
  choices: ValidatableChoice[];
}

export interface ValidatableStory {
  storyId: string;
  status: string;
  rootNodeId: string | null;
}

/**
 * Publishing checklist from the game rules. Pure: takes the story doc and
 * its nodes, returns one message per missing piece, empty when it can go
 * `published`. `endHash` is caller-computed (sha of the current E bytes),
 * not a Firestore field; it anchors the desync check.
 * @param {ValidatableStory} story Story doc.
 * @param {ValidatableNode[]} nodes All nodes of the story.
 * @return {string[]} One message per missing piece.
 */
export const validateStory = (
  story: ValidatableStory,
  nodes: ValidatableNode[]
): string[] => {
  const problems: string[] = [];
  const byId = new Map(nodes.map((node) => [node.nodeId, node]));

  const root = story.rootNodeId ? byId.get(story.rootNodeId) : undefined;
  if (!root) {
    problems.push("Missing root node.");
  }
  if (!nodes.some((node) => node.isEnding)) {
    problems.push("At least one ending is required.");
  }

  if (root) {
    const seen = new Set<string>([root.nodeId]);
    const queue = [root];
    while (queue.length > 0) {
      const node = queue.shift() as ValidatableNode;
      for (const choice of node.choices) {
        const target = byId.get(choice.targetNodeId);
        if (target && !seen.has(target.nodeId)) {
          seen.add(target.nodeId);
          queue.push(target);
        }
      }
    }
    for (const node of nodes) {
      if (!seen.has(node.nodeId)) {
        problems.push(`Node ${node.nodeId} is not reachable from the root.`);
      }
    }
  }

  for (const node of nodes) {
    problems.push(
      ...validateNode(node, byId, node.nodeId === story.rootNodeId)
    );
  }
  return problems;
};

const validateNode = (
  node: ValidatableNode,
  byId: Map<string, ValidatableNode>,
  isRoot: boolean
): string[] => {
  const problems: string[] = [];
  if (node.title.trim() === "" || node.title.length > 40) {
    problems.push(`Node ${node.nodeId} needs a title of 1-40 characters.`);
  }
  if (node.visibility !== "visible" && node.visibility !== "secret") {
    problems.push(`Node ${node.nodeId} needs a valid visibility.`);
  }
  if (node.videoStatus !== "ready" || !node.videoUrl) {
    problems.push(`Node ${node.nodeId} needs a ready video.`);
  }
  if (!isPositive(node.pauseAtSeconds)) {
    problems.push(`Node ${node.nodeId} needs pauseAtSeconds from extraction.`);
  }
  problems.push(...validateFrames(node, byId, isRoot));
  if (node.isEnding) {
    problems.push(...validateEnding(node));
  } else {
    problems.push(...validateDecision(node, byId));
  }
  return problems;
};

const validateFrames = (
  node: ValidatableNode,
  byId: Map<string, ValidatableNode>,
  isRoot: boolean
): string[] => {
  if (node.videoSource === "upload") {
    return node.videoFrameLastUrl ?
      [] :
      [`Node ${node.nodeId} needs its extracted end frame.`];
  }
  const problems: string[] = [];
  if (node.endImageApproved !== true) {
    problems.push(`Node ${node.nodeId} needs an approved end image.`);
  }
  if (isRoot) {
    if (node.startImageApproved !== true) {
      problems.push(`Node ${node.nodeId} needs an approved start image.`);
    }
    return problems;
  }
  if (!node.startFromNodeId) {
    problems.push(`Node ${node.nodeId} is missing its parent link.`);
    return problems;
  }
  const parent = byId.get(node.startFromNodeId);
  if (!parent) {
    problems.push(`Node ${node.nodeId} points to a missing parent.`);
    return problems;
  }
  if (!node.startParentEndHash) {
    problems.push(`Node ${node.nodeId} is missing its parent end hash.`);
  } else if (!parent.endHash) {
    problems.push(
      `Node ${node.nodeId} cannot verify sync: parent end hash missing.`
    );
  } else if (node.startParentEndHash !== parent.endHash) {
    problems.push(`Node ${node.nodeId} is out of sync with its parent.`);
  }
  return problems;
};

const validateDecision = (
  node: ValidatableNode,
  byId: Map<string, ValidatableNode>
): string[] => {
  const problems: string[] = [];
  if (node.choices.length < 1 || node.choices.length > 2) {
    problems.push(`Node ${node.nodeId} needs one or two choices.`);
  }
  for (const choice of node.choices) {
    if (choice.label.trim() === "" || choice.label.length > 24) {
      problems.push(
        `Choice ${choice.choiceId} needs a label of 1-24 characters.`
      );
    }
    if (!byId.has(choice.targetNodeId)) {
      problems.push(`Choice ${choice.choiceId} points to a missing node.`);
    }
    if (!isUnit(choice.x) || !isUnit(choice.y) || !isUnit(choice.radius)) {
      problems.push(
        `Choice ${choice.choiceId} needs a zone inside the 0-1 frame.`
      );
    }
  }
  if (node.choices.filter((choice) => choice.isDefault).length !== 1) {
    problems.push(`Node ${node.nodeId} needs exactly one default choice.`);
  }
  problems.push(...validateVoice(node));
  if (!isWindow(node.windowSeconds)) {
    problems.push(`Node ${node.nodeId} needs windowSeconds between 3 and 15.`);
  }
  return problems;
};

const validateEnding = (node: ValidatableNode): string[] => {
  const problems: string[] = [];
  if (node.choices.length > 0) {
    problems.push(`Ending ${node.nodeId} must not have choices.`);
  }
  if (node.windowSeconds !== undefined && node.windowSeconds !== null) {
    problems.push(`Ending ${node.nodeId} must not have windowSeconds.`);
  }
  if (!node.endingName || node.endingName.trim() === "") {
    problems.push(`Ending ${node.nodeId} needs a name.`);
  }
  if (!["abierto", "tragico", "secreto"].includes(node.endingType ?? "")) {
    problems.push(`Ending ${node.nodeId} needs a valid type.`);
  }
  if (node.ttsText && node.ttsText.trim() !== "") {
    problems.push(...validateVoice(node));
  }
  return problems;
};

const validateVoice = (node: ValidatableNode): string[] => {
  const problems: string[] = [];
  if (node.lineApproved !== true) {
    problems.push(`Node ${node.nodeId} needs an approved narrator line.`);
  }
  if (
    node.ttsStatus !== "ready" ||
    !node.ttsAudioUrl ||
    !isPositive(node.ttsDurationSeconds)
  ) {
    problems.push(`Node ${node.nodeId} needs a ready narrator voice.`);
  }
  if (node.ttsApproved !== true) {
    problems.push(`Node ${node.nodeId} needs an approved narrator voice.`);
  }
  return problems;
};

const isPositive = (value: number | null | undefined): value is number => {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
};

const isUnit = (value: number | null | undefined): value is number => {
  return (
    typeof value === "number" &&
    Number.isFinite(value) &&
    value >= 0 &&
    value <= 1
  );
};

const isWindow = (value: number | null | undefined): value is number => {
  return (
    Number.isInteger(value) && (value as number) >= 3 && (value as number) <= 15
  );
};
