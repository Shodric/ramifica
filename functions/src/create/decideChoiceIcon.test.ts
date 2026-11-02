import {strict as assert} from "assert";
import {test} from "node:test";
import {Db, DbDoc, DbRef} from "../feed/shared";
import {OpenRouterFetch} from "../media/openrouter";
import {decideChoiceIconWith} from "./decideChoiceIcon";

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
 * Decisions answer payload for one icon plus color.
 * @param {unknown} icon The icon answer choice.
 * @param {unknown} iconColor The color answer choice.
 * @return {unknown} The `{answers}` payload.
 */
const answersWith = (icon: unknown, iconColor: unknown): unknown => ({
  answers: {
    icon: {type: "choice", choice: icon, probabilities: {}},
    iconColor: {type: "choice", choice: iconColor, probabilities: {}},
  },
});

test("decides a catalogued icon and color", async () => {
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
      fetchFn: stubFetch(answersWith("door", "cyan"), seen),
    }
  );
  assert.deepEqual(result, {icon: "door", iconColor: "cyan"});
  const body = JSON.parse(seen[0]);
  assert.equal(body.model, "baseten/joey-1");
  assert.ok(Array.isArray(body.state));
  assert.match(JSON.stringify(body.state), /Choice to style: Enter/);
  assert.match(JSON.stringify(body.state), /Climb/);
  assert.match(JSON.stringify(body.state), /Open the door/);
  assert.equal(body.questions.icon.type, "choice");
  assert.equal(body.questions.iconColor.type, "choice");
  assert.ok(Object.keys(body.questions.icon.criteria).length > 100);
  assert.ok(Object.keys(body.questions.iconColor.criteria).length > 1);
});

test("unknown names fail closed to null", async () => {
  const db = new MemDb();
  const result = await decideChoiceIconWith(
    db,
    "u1",
    {storyId: "story_draft", choiceLabel: "Enter"},
    {apiKey: "test", fetchFn: stubFetch(answersWith("nope", "nope"))}
  );
  assert.deepEqual(result, {icon: null, iconColor: null});
});

test("unreadable answers fail closed to null", async () => {
  const db = new MemDb();
  const result = await decideChoiceIconWith(
    db,
    "u1",
    {storyId: "story_draft", choiceLabel: "Enter"},
    {apiKey: "test", fetchFn: stubFetch("not json at all")},
  );
  assert.deepEqual(result, {icon: null, iconColor: null});
});

test("rejects foreign, missing, and live stories", async () => {
  const db = new MemDb();
  const deps = {
    apiKey: "test",
    fetchFn: stubFetch(answersWith("door", "cyan")),
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
