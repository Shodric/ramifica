import {strict as assert} from "assert";
import {test} from "node:test";
import {
  ValidatableChoice,
  ValidatableNode,
  ValidatableStory,
  validateStory,
} from "./validateStory";

const goodChoice = (overrides = {}): ValidatableChoice => ({
  choiceId: "choice_temple",
  label: "Enter the temple",
  targetNodeId: "node_002",
  isDefault: true,
  x: 0.25,
  y: 0.65,
  radius: 0.15,
  ...overrides,
});

const story = (overrides = {}): ValidatableStory => ({
  storyId: "story_templo",
  status: "draft",
  rootNodeId: "node_001",
  ...overrides,
});

const node = (overrides = {}): ValidatableNode => ({
  nodeId: "node_001",
  title: "The temple door",
  visibility: "visible",
  isEnding: false,
  videoUrl: "https://example.com/video.mp4",
  videoStatus: "ready",
  videoSource: "generated",
  videoFrameLastHash: "hash-e1",
  ttsText: "Enter or climb?",
  ttsAudioUrl: "https://example.com/voz.m4a",
  ttsStatus: "ready",
  ttsDurationSeconds: 4.1,
  choices: [goodChoice()],
  ...overrides,
});

const ending = (overrides = {}): ValidatableNode => ({
  nodeId: "node_002",
  title: "The last door",
  visibility: "visible",
  isEnding: true,
  endingName: "The door",
  endingType: "tragic",
  videoUrl: "https://example.com/end.mp4",
  videoStatus: "ready",
  videoSource: "generated",
  startFromNodeId: "node_001",
  startParentFrameHash: "hash-e1",
  ttsText: "",
  choices: [],
  ...overrides,
});

const validNodes = (): ValidatableNode[] => [
  node(),
  node({
    nodeId: "node_002",
    title: "The ridge",
    startFromNodeId: "node_001",
    startParentFrameHash: "hash-e1",
    videoFrameLastHash: "hash-e2",
    choices: [
      goodChoice({
        choiceId: "choice_end",
        label: "Keep going",
        targetNodeId: "node_003",
        x: 0.5,
        y: 0.5,
        radius: 0.2,
      }),
    ],
  }),
  ending({
    nodeId: "node_003",
    startFromNodeId: "node_002",
    startParentFrameHash: "hash-e2",
  }),
];

test("a complete story validates clean", () => {
  assert.deepEqual(validateStory(story(), validNodes()), []);
});

test("missing root and missing ending are reported", () => {
  assert.deepEqual(validateStory(story({rootNodeId: null}), []), [
    "Missing root node.",
    "At least one ending is required.",
  ]);
});

test("unreachable nodes are reported", () => {
  const nodes = validNodes();
  nodes.push(
    node({
      nodeId: "node_009",
      title: "Lost",
      startFromNodeId: "node_001",
      startParentFrameHash: "hash-e1",
    })
  );
  assert.deepEqual(validateStory(story(), nodes), [
    "Node node_009 is not reachable from the root.",
  ]);
});

test("titles, visibility, and video are required", () => {
  const bad = node({
    title: "",
    visibility: "hidden",
    videoStatus: "idle",
  });
  assert.deepEqual(validateStory(story(), [bad, ending()]), [
    "Node node_001 needs a title of 1-40 characters.",
    "Node node_001 needs a valid visibility.",
    "Node node_001 needs a ready video.",
  ]);
});

test("choices need labels, targets, zones, and one default", () => {
  const bad = node({
    choices: [
      goodChoice({
        choiceId: "choice_a",
        label: "",
        targetNodeId: "node_missing",
        x: -0.1,
      }),
      goodChoice({choiceId: "choice_b", label: "Fine"}),
    ],
  });
  assert.deepEqual(validateStory(story(), [bad, ending()]), [
    "Choice choice_a needs a label of 1-24 characters.",
    "Choice choice_a points to a missing node.",
    "Choice choice_a needs a zone inside the 0-1 frame.",
    "Node node_001 needs exactly one default choice.",
  ]);
});

test("decisions need a ready voice", () => {
  const bad = node({
    ttsStatus: "idle",
    ttsAudioUrl: null,
    ttsDurationSeconds: null,
  });
  assert.deepEqual(validateStory(story(), [bad, ending()]), [
    "Node node_001 needs a ready narrator voice.",
  ]);
});

test("uploaded video needs its extracted last frame", () => {
  const bad = node({videoSource: "upload"});
  assert.deepEqual(validateStory(story(), [bad, ending()]), [
    "Node node_001 needs its extracted last frame.",
  ]);
});

test("desync with the parent is reported", () => {
  const parent = node({videoFrameLastHash: "hash-new"});
  const child = node({
    nodeId: "node_002",
    startFromNodeId: "node_001",
    startParentFrameHash: "hash-old",
    videoFrameLastHash: "hash-e2",
    choices: [goodChoice({targetNodeId: "node_003"})],
  });
  assert.deepEqual(validateStory(story(), [parent, child, ending({
    nodeId: "node_003",
    startFromNodeId: "node_002",
    startParentFrameHash: "hash-e2",
  })]), ["Node node_002 is out of sync with its parent."]);
});

test("a child without a parent link is reported", () => {
  const nodes = validNodes();
  delete nodes[1].startFromNodeId;
  assert.deepEqual(validateStory(story(), nodes), [
    "Node node_002 is missing its parent link.",
  ]);
});

test("endings need a name, a type, and no choices", () => {
  const bad = ending({
    endingName: "",
    endingType: "epic",
    choices: [goodChoice({choiceId: "choice_x", label: "Out"})],
  });
  assert.deepEqual(validateStory(story(), [node(), bad]), [
    "Ending node_002 must not have choices.",
    "Ending node_002 needs a name.",
    "Ending node_002 needs a valid type.",
  ]);
});

test("an ending with a closing line needs its voice", () => {
  const bad = ending({
    ttsText: "The end.",
    ttsStatus: "idle",
    ttsAudioUrl: null,
    ttsDurationSeconds: null,
  });
  assert.deepEqual(validateStory(story(), [node(), bad]), [
    "Node node_002 needs a ready narrator voice.",
  ]);
});

test("legacy approvals are ignored", () => {
  const legacy = node({
    startImageApproved: false,
    lineApproved: false,
    ttsApproved: false,
  });
  assert.deepEqual(validateStory(story(), [legacy, ending()]), []);
});

test("endings accept every taxonomy type", () => {
  const types = [
    "open",
    "tragic",
    "secret",
    "heroic",
    "mysterious",
    "bittersweet",
    "dark",
    "epic",
    "incomplete",
  ];
  for (const endingType of types) {
    assert.deepEqual(
      validateStory(story(), [node(), ending({endingType})]),
      []
    );
  }
});

test("endings reject an unknown type", () => {
  assert.deepEqual(
    validateStory(story(), [node(), ending({endingType: "xyz"})]),
    ["Ending node_002 needs a valid type."]
  );
});
