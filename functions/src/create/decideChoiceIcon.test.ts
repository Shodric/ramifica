import {strict as assert} from "assert";
import {test} from "node:test";
import {Db, DbDoc, DbRef} from "../feed/shared";
import {OpenRouterFetch} from "../media/openrouter";
import {choiceIconCategories} from "./choiceIconCategories";
import {decideChoiceIconWith} from "./decideChoiceIcon";
import {knownChoiceIcons} from "./generateNodeText";

type Fields = {[field: string]: unknown};

/** In-memory read-only store; the decision never writes. */
class MemDb implements Db {
  private readonly store = new Map<string, Fields>([
    ["stories/story_draft", {
      authorId: "u1",
      title: "The temple",
      status: "draft",
      rootNodeId: "node_001",
    }],
    ["stories/story_draft/nodes/node_001", {title: "Old title"}],
    ["stories/story_foreign", {
      authorId: "u2",
      title: "Foreign",
      status: "draft",
      rootNodeId: "node_001",
    }],
    ["stories/story_live", {
      authorId: "u1",
      title: "Live",
      status: "published",
      rootNodeId: "node_001",
    }],
  ]);

  /**
   * In-memory doc reference backed by the shared store.
   * @param {string} path Document path.
   * @return {DbRef} Reference reading from the store.
   */
  doc(path: string): DbRef {
    const fields = this.store.get(path);
    const snapshot: DbDoc = {
      exists: fields !== undefined,
      id: path.slice(path.lastIndexOf("/") + 1),
      data: () => fields === undefined ?
        undefined :
        JSON.parse(JSON.stringify(fields)),
    };
    return {
      id: snapshot.id,
      get: async () => snapshot,
      set: async () => {
        throw new Error("read-only");
      },
      update: async () => {
        throw new Error("read-only");
      },
    };
  }

  /** Unused collection path for the decision flow. */
  collection(): never {
    throw new Error("unused");
  }

  /** Unused transaction path for the decision flow. */
  runTransaction(): never {
    throw new Error("unused");
  }
}

/**
 * Stub OpenRouter transport answering one Decisions call.
 * @param {unknown} payload The decoded `{answers}` payload to return.
 * @param {string[]} seen Captures request bodies.
 * @return {OpenRouterFetch} The stub transport.
 */
const stubFetch = (
  payload: unknown, seen: string[] = []
): OpenRouterFetch => {
  return async (_url, init) => {
    if (init.body !== undefined) seen.push(init.body);
    return {
      ok: true,
      status: 200,
      json: async () => payload,
      arrayBuffer: async () => new ArrayBuffer(0),
    };
  };
};

/**
 * Decisions answer payload from question/choice pairs.
 * @param {Array<[string, unknown]>} pairs Question names and choices.
 * @return {unknown} The `{answers}` payload.
 */
const answersWith = (...pairs: Array<[string, unknown]>): unknown => ({
  answers: Object.fromEntries(
    pairs.map(([name, choice]) => [
      name,
      {type: "choice", choice, probabilities: {}},
    ])
  ),
});

/**
 * Stub OpenRouter transport answering each Decisions call in order.
 * @param {unknown[]} payloads Decoded payloads, one per call.
 * @param {string[]} seen Captures request bodies.
 * @return {OpenRouterFetch} The stub transport.
 */
const stubFetchQueue = (
  payloads: unknown[], seen: string[] = []
): OpenRouterFetch => {
  let at = 0;
  return async (_url, init) => {
    if (init.body !== undefined) seen.push(init.body);
    const payload = payloads[Math.min(at, payloads.length - 1)];
    at += 1;
    return {
      ok: true,
      status: 200,
      json: async () => payload,
      arrayBuffer: async () => new ArrayBuffer(0),
    };
  };
};

test("decides a category, then a catalogued icon and color", async () => {
  const db = new MemDb();
  const seen: string[] = [];
  const result = await decideChoiceIconWith(
    db,
    "u1",
    {
      storyId: "story_draft",
      nodeId: "node_001",
      choiceLabel: "Enter",
      siblingLabels: ["Climb"],
      previousDecision: "Open the door",
      sceneTitle: "The gate",
    },
    {
      apiKey: "test",
      fetchFn: stubFetchQueue(
        [
          answersWith(["iconCategory", "places"], ["iconColor", "cyan"]),
          answersWith(["icon", "door"]),
        ],
        seen
      ),
    }
  );
  assert.deepEqual(result, {icon: "door", iconColor: "cyan"});
  assert.equal(seen.length, 2);
  const first = JSON.parse(seen[0]);
  assert.equal(first.model, "baseten/joey-1");
  assert.ok(Array.isArray(first.state));
  assert.match(JSON.stringify(first.state), /Choice to style: Enter/);
  assert.match(JSON.stringify(first.state), /Climb/);
  assert.match(JSON.stringify(first.state), /Open the door/);
  assert.equal(first.questions.iconCategory.type, "choice");
  assert.equal(first.questions.iconColor.type, "choice");
  assert.deepEqual(
    Object.keys(first.questions.iconCategory.criteria).sort(),
    Object.keys(choiceIconCategories).sort()
  );
  const second = JSON.parse(seen[1]);
  assert.equal(second.model, "baseten/joey-1");
  assert.deepEqual(
    Object.keys(second.questions.icon.criteria).sort(),
    [...choiceIconCategories["places"]].sort()
  );
});

test("every question stays under the 256-option ceiling", async () => {
  const db = new MemDb();
  const seen: string[] = [];
  await decideChoiceIconWith(
    db,
    "u1",
    {storyId: "story_draft", choiceLabel: "Enter"},
    {
      apiKey: "test",
      fetchFn: stubFetchQueue(
        [
          answersWith(["iconCategory", "symbols"], ["iconColor", "cyan"]),
          answersWith(["icon", "star"]),
        ],
        seen
      ),
    }
  );
  for (const body of seen.map((raw) => JSON.parse(raw))) {
    for (const question of Object.values(body.questions) as Array<{
      criteria: Record<string, string>;
    }>) {
      assert.ok(Object.keys(question.criteria).length <= 256);
    }
  }
  for (const names of Object.values(choiceIconCategories)) {
    assert.ok(names.length <= 256);
  }
});

test("categories cover the catalog exactly once", () => {
  const covered = Object.values(choiceIconCategories).flat();
  assert.equal(covered.length, knownChoiceIcons.length);
  assert.equal(new Set(covered).size, knownChoiceIcons.length);
  for (const name of knownChoiceIcons) {
    assert.ok(covered.includes(name));
  }
});

test("an unknown category fails the icon closed but keeps the color",
  async () => {
    const db = new MemDb();
    const seen: string[] = [];
    const result = await decideChoiceIconWith(
      db,
      "u1",
      {storyId: "story_draft", choiceLabel: "Enter"},
      {
        apiKey: "test",
        fetchFn: stubFetchQueue(
          [answersWith(["iconCategory", "nope"], ["iconColor", "cyan"])],
          seen
        ),
      }
    );
    assert.deepEqual(result, {icon: null, iconColor: "cyan"});
    assert.equal(seen.length, 1);
  });

test("unknown names fail closed to null", async () => {
  const db = new MemDb();
  const result = await decideChoiceIconWith(
    db,
    "u1",
    {storyId: "story_draft", choiceLabel: "Enter"},
    {
      apiKey: "test",
      fetchFn: stubFetchQueue([
        answersWith(["iconCategory", "places"], ["iconColor", "nope"]),
        answersWith(["icon", "nope"]),
      ]),
    }
  );
  assert.deepEqual(result, {icon: null, iconColor: null});
});

test("an icon outside its category fails closed", async () => {
  const db = new MemDb();
  const result = await decideChoiceIconWith(
    db,
    "u1",
    {storyId: "story_draft", choiceLabel: "Enter"},
    {
      apiKey: "test",
      fetchFn: stubFetchQueue([
        answersWith(["iconCategory", "places"], ["iconColor", "cyan"]),
        answersWith(["icon", "star"]),
      ]),
    }
  );
  assert.deepEqual(result, {icon: null, iconColor: "cyan"});
});

test("unreadable answers fail closed to null", async () => {
  const db = new MemDb();
  const seen: string[] = [];
  const result = await decideChoiceIconWith(
    db,
    "u1",
    {storyId: "story_draft", choiceLabel: "Enter"},
    {apiKey: "test", fetchFn: stubFetch("not json at all", seen)},
  );
  assert.deepEqual(result, {icon: null, iconColor: null});
  assert.equal(seen.length, 1);
});

test("rejects foreign, missing, and live stories", async () => {
  const db = new MemDb();
  const deps = {
    apiKey: "test",
    fetchFn: stubFetch(
      answersWith(["icon", "door"], ["iconColor", "cyan"])
    ),
  };
  await assert.rejects(
    decideChoiceIconWith(
      db, "u1", {storyId: "story_foreign", choiceLabel: "Enter"}, deps),
    /Not your draft/
  );
  await assert.rejects(
    decideChoiceIconWith(
      db, "u1", {storyId: "story_missing", choiceLabel: "Enter"}, deps),
    /Story not found/
  );
  await assert.rejects(
    decideChoiceIconWith(
      db, "u1", {storyId: "story_live", choiceLabel: "Enter"}, deps),
    /Only drafts/
  );
  await assert.rejects(
    decideChoiceIconWith(db, "u1", {storyId: "story_draft"}, deps),
    /choice label/i
  );
});
