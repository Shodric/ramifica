import {strict as assert} from "assert";
import {test} from "node:test";
import {Db, DbCol, DbDoc, DbRef, DbTx} from "../feed/shared";
import {createNodeWith, saveNodeWith} from "./nodes";

type Fields = {[field: string]: unknown};

/** In-memory doc snapshot. Reads deep-copy so tests cannot leak writes. */
class MemDoc implements DbDoc {
  /**
   * @param {boolean} exists Whether the doc exists.
   * @param {string} id Doc id.
   * @param {Fields} fields Doc fields, when present.
   */
  constructor(
    readonly exists: boolean,
    readonly id: string,
    private readonly fields?: Fields
  ) {}

  /** @return {Fields | undefined} A copy of the fields. */
  data(): Fields | undefined {
    return this.fields === undefined ?
      undefined :
      JSON.parse(JSON.stringify(this.fields));
  }
}

/** In-memory doc reference backed by the shared store. */
class MemRef implements DbRef {
  /**
   * @param {MemDb} db Backing store.
   * @param {string} path Full doc path.
   */
  constructor(readonly db: MemDb, readonly path: string) {}

  /** @return {string} The last path segment. */
  get id(): string {
    return this.path.slice(this.path.lastIndexOf("/") + 1);
  }

  /** @return {Promise<DbDoc>} The snapshot. */
  async get(): Promise<DbDoc> {
    const fields = this.db.store.get(this.path);
    return new MemDoc(fields !== undefined, this.id, fields);
  }

  /**
   * @param {Record<string, unknown>} data Fields to write.
   * @param {object} opts Merge option.
   */
  async set(
    data: Record<string, unknown>,
    opts?: {merge?: boolean}
  ): Promise<void> {
    const before = this.db.store.get(this.path) ?? {};
    this.db.store.set(
      this.path,
      opts?.merge ? {...before, ...data} : {...data}
    );
  }

  /** @param {Record<string, unknown>} data Fields to merge. */
  async update(data: Record<string, unknown>): Promise<void> {
    if (!this.db.store.has(this.path)) {
      throw new Error(`not-found: ${this.path}`);
    }
    this.db.store.set(this.path, {...this.db.store.get(this.path), ...data});
  }
}

/** In-memory collection: doc() plus stubs that throw, like the real use. */
class MemCol implements DbCol {
  /**
   * @param {MemDb} db Backing store.
   * @param {string} path Collection path.
   */
  constructor(readonly db: MemDb, readonly path: string) {}

  /**
   * @param {string} id Doc id, or an auto id.
   * @return {DbRef} The doc reference.
   */
  doc(id?: string): DbRef {
    const child = id ?? `auto_${(this.db.autoId += 1)}`;
    return new MemRef(this.db, `${this.path}/${child}`);
  }

  /**
   * Unused stub: node tests never query.
   * @param {string} field Field name.
   * @param {string} op Only `==`.
   * @param {unknown} value Expected value.
   */
  where(field: string, op: string, value: unknown): DbCol {
    void field;
    void op;
    void value;
    throw new Error("MemCol.where is not stubbed.");
  }

  /**
   * Unused stub: node tests never query.
   * @param {string} field Field name.
   * @param {string} dir Sort direction.
   */
  orderBy(field: string, dir: "asc" | "desc" = "asc"): DbCol {
    void field;
    void dir;
    throw new Error("MemCol.orderBy is not stubbed.");
  }

  /**
   * Unused stub: node tests never query.
   * @param {number} n Max docs.
   */
  limit(n: number): DbCol {
    void n;
    throw new Error("MemCol.limit is not stubbed.");
  }

  /** @return {Promise<Object>} Never resolves; node tests never query. */
  async get(): Promise<{empty: boolean; docs: DbDoc[]}> {
    throw new Error("MemCol.get is not stubbed.");
  }
}

/** In-memory Firestore. Transactions run the callback once, inline. */
class MemDb implements Db {
  readonly store = new Map<string, Fields>();
  autoId = 0;

  /**
   * @param {string} path Full doc path.
   * @return {DbRef} The doc reference.
   */
  doc(path: string): DbRef {
    return new MemRef(this, path);
  }

  /**
   * @param {string} collectionPath Collection path.
   * @return {DbCol} The collection.
   */
  collection(collectionPath: string): DbCol {
    return new MemCol(this, collectionPath);
  }

  /** @param {Function} fn Transaction body. */
  async runTransaction<T>(fn: (tx: DbTx) => Promise<T>): Promise<T> {
    const tx: DbTx = {
      get: (ref) => ref.get(),
      set: (ref, data, opts) => ref.set(data, opts),
      update: (ref, data) => ref.update(data),
    };
    return fn(tx);
  }
}

/**
 * One owned draft with a decision node, plus neighbors that must stay
 * untouched: a published story, a foreign draft, and an unrelated run.
 * @param {MemDb} db Backing store to seed.
 * @return {Promise<void>} When the seed is written.
 */
const seedDraft = async (db: MemDb): Promise<void> => {
  await db.doc("stories/story_draft").set({
    authorId: "u1",
    title: "The temple",
    synopsis: "A door.",
    status: "draft",
    rootNodeId: "node_001",
  });
  await db.doc("stories/story_draft/nodes/node_001").set({
    title: "Old title",
    visibility: "visible",
    isEnding: false,
    endingName: null,
    endingType: null,
    videoUrl: "https://old.example/v.mp4",
    videoStatus: "ready",
    pauseAtSeconds: 9.967,
    windowSeconds: 6,
    ttsText: "Old line.",
    lineApproved: true,
    ttsAudioUrl: "https://old.example/v.m4a",
    ttsStatus: "ready",
    ttsDurationSeconds: 4.1,
    choices: [],
    startFromNodeId: null,
    startParentEndHash: null,
  });
  await db.doc("stories/story_pub").set({
    authorId: "u1",
    title: "Published",
    status: "published",
    rootNodeId: "node_p1",
  });
  await db.doc("stories/story_pub/nodes/node_p1").set({title: "P"});
  await db.doc("stories/story_foreign").set({
    authorId: "u2",
    title: "Foreign",
    status: "draft",
    rootNodeId: "node_f1",
  });
  await db.doc("users/u9/runs/run_x").set({storyId: "story_pub"});
};

/**
 * Snapshot of every doc outside the given story, to prove node writes
 * stay inside the draft.
 * @param {MemDb} db Backing store.
 * @param {string} storyId Draft under test.
 * @return {string} The serialized outside docs.
 */
const outsideSnapshot = (db: MemDb, storyId: string): string => {
  const prefix = `stories/${storyId}/`;
  const entries = [...db.store.entries()].filter(([path]) => {
    return path !== `stories/${storyId}` && !path.startsWith(prefix);
  });
  return JSON.stringify(entries);
};

test("createNode creates the story and its root atomically", async () => {
  const db = new MemDb();
  const result = await createNodeWith(
    db,
    "u1",
    {storyId: "story_new", title: "Fresh", synopsis: "A start."}
  );
  assert.match(result.nodeId, /^auto_/);
  const story = await db.doc("stories/story_new").get();
  assert.equal(story.exists, true);
  assert.deepEqual(story.data(), {
    authorId: "u1",
    title: "Fresh",
    synopsis: "A start.",
    status: "draft",
    rootNodeId: result.nodeId,
    createdAt: story.data()?.createdAt,
    updatedAt: story.data()?.updatedAt,
  });
  const node = await db
    .doc(`stories/story_new/nodes/${result.nodeId}`)
    .get();
  assert.equal(node.exists, true);
  assert.equal(node.data()?.startFromNodeId, null);
  assert.equal(node.data()?.isEnding, false);
});

test("createNode defaults the story title when missing", async () => {
  const db = new MemDb();
  await createNodeWith(db, "u1", {storyId: "story_new"});
  const story = await db.doc("stories/story_new").get();
  assert.equal(story.data()?.title, "Untitled story");
});

test("createNode links a child and keeps the root", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const before = outsideSnapshot(db, "story_draft");
  const result = await createNodeWith(
    db,
    "u1",
    {storyId: "story_draft", parentNodeId: "node_001"}
  );
  const node = await db
    .doc(`stories/story_draft/nodes/${result.nodeId}`)
    .get();
  assert.equal(node.data()?.startFromNodeId, "node_001");
  const story = await db.doc("stories/story_draft").get();
  assert.equal(story.data()?.rootNodeId, "node_001");
  assert.equal(story.data()?.title, "The temple");
  assert.equal(outsideSnapshot(db, "story_draft"), before);
});

test("createNode sets the root on a client-direct story", async () => {
  const db = new MemDb();
  await db.doc("stories/story_direct").set({
    authorId: "u1",
    title: "Direct",
    synopsis: "",
    status: "draft",
    rootNodeId: null,
  });
  const result = await createNodeWith(db, "u1", {storyId: "story_direct"});
  const story = await db.doc("stories/story_direct").get();
  assert.equal(story.data()?.rootNodeId, result.nodeId);
});

test("createNode rejects bad callers and targets", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const codes: Array<[unknown, string]> = [
    [{storyId: ""}, "invalid-argument"],
    [{storyId: "story_missing", parentNodeId: "nope"}, "not-found"],
    [{storyId: "story_draft", parentNodeId: "node_nope"}, "not-found"],
    [{storyId: "story_foreign"}, "permission-denied"],
    [{storyId: "story_pub"}, "failed-precondition"],
  ];
  for (const [data, code] of codes) {
    await assert.rejects(
      createNodeWith(db, "u1", data),
      (error: unknown) => (error as {code?: string}).code === code
    );
  }
  await assert.rejects(
    createNodeWith(db, "", {storyId: "story_draft"}),
    (error: unknown) => (error as {code?: string}).code === "unauthenticated"
  );
});

test("saveNode persists the whitelist and ignores the rest", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const before = outsideSnapshot(db, "story_draft");
  const result = await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {
      nodeId: "node_001",
      title: "  New title  ",
      visibility: "secret",
      isEnding: false,
      endingName: null,
      endingType: null,
      ttsText: "New line.",
      windowSeconds: 9,
      choices: [
        {
          choiceId: "c1",
          label: "Enter",
          targetNodeId: "node_002",
          isDefault: true,
          x: 0.25,
          y: 0.65,
          radius: 0.15,
        },
      ],
      authorId: "u2",
      status: "published",
      rootNodeId: "node_hack",
      videoUrl: "https://evil.example/v.mp4",
      videoStatus: "ready",
      lineApproved: false,
      startFromNodeId: "node_hack",
    },
  });
  assert.deepEqual(result, {});
  const node = await db.doc("stories/story_draft/nodes/node_001").get();
  const saved = node.data() ?? {};
  assert.equal(saved.title, "New title");
  assert.equal(saved.visibility, "secret");
  assert.equal(saved.ttsText, "New line.");
  assert.equal(saved.windowSeconds, 9);
  assert.deepEqual(saved.choices, [
    {
      choiceId: "c1",
      label: "Enter",
      targetNodeId: "node_002",
      isDefault: true,
      x: 0.25,
      y: 0.65,
      radius: 0.15,
    },
  ]);
  assert.equal(saved.videoUrl, "https://old.example/v.mp4");
  assert.equal(saved.lineApproved, true);
  assert.equal(saved.startFromNodeId, null);
  assert.equal("authorId" in saved, false);
  assert.equal("status" in saved, false);
  assert.equal("rootNodeId" in saved, false);
  assert.equal(outsideSnapshot(db, "story_draft"), before);
});

test("saveNode supports partial updates", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {nodeId: "node_001", title: "Only this"},
  });
  const node = await db.doc("stories/story_draft/nodes/node_001").get();
  assert.equal(node.data()?.title, "Only this");
  assert.equal(node.data()?.ttsText, "Old line.");
});

test("saveNode normalizes endings and rejects choices on them", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {
      nodeId: "node_001",
      isEnding: true,
      windowSeconds: 6,
      endingName: "Dawn",
      endingType: "abierto",
    },
  });
  const node = await db.doc("stories/story_draft/nodes/node_001").get();
  assert.equal(node.data()?.windowSeconds, null);
  assert.equal(node.data()?.endingName, "Dawn");
  await assert.rejects(
    saveNodeWith(db, "u1", {
      storyId: "story_draft",
      node: {
        nodeId: "node_001",
        isEnding: true,
        choices: [{choiceId: "c1", label: "X", targetNodeId: "n2"}],
      },
    }),
    (error: unknown) => (error as {code?: string}).code === "invalid-argument"
  );
});

test("saveNode rejects bad callers and targets", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const good = {nodeId: "node_001", title: "Fine"};
  const codes: Array<[unknown, string]> = [
    [{storyId: "story_draft"}, "invalid-argument"],
    [{storyId: "story_draft", node: null}, "invalid-argument"],
    [{storyId: "story_draft", node: {title: "No id"}}, "invalid-argument"],
    [{storyId: "story_missing", node: good}, "not-found"],
    [{storyId: "story_draft", node: {...good, nodeId: "nope"}}, "not-found"],
    [{storyId: "story_foreign", node: good}, "permission-denied"],
    [{storyId: "story_pub", node: {nodeId: "node_p1", title: "X"}},
      "failed-precondition"],
  ];
  for (const [data, code] of codes) {
    await assert.rejects(
      saveNodeWith(db, "u1", data),
      (error: unknown) => (error as {code?: string}).code === code
    );
  }
  await assert.rejects(
    saveNodeWith(db, "", {storyId: "story_draft", node: good}),
    (error: unknown) => (error as {code?: string}).code === "unauthenticated"
  );
});

test("saveNode validates every whitelisted field", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const bad: unknown[] = [
    {nodeId: "node_001", title: "x".repeat(41)},
    {nodeId: "node_001", title: 7},
    {nodeId: "node_001", visibility: "hidden"},
    {nodeId: "node_001", endingType: "sad"},
    {nodeId: "node_001", ttsText: "x".repeat(1001)},
    {nodeId: "node_001", windowSeconds: null},
    {nodeId: "node_001", windowSeconds: 2},
    {nodeId: "node_001", windowSeconds: 3.5},
    {nodeId: "node_001", choices: "nope"},
    {nodeId: "node_001", choices: [{choiceId: "c1", label: "L",
      targetNodeId: "n2"}, {choiceId: "c2", label: "L", targetNodeId: "n3"},
    {choiceId: "c3", label: "L", targetNodeId: "n4"}]},
    {nodeId: "node_001", choices: [{label: "No id", targetNodeId: "n2"}]},
    {nodeId: "node_001", choices: [{choiceId: "c1", label: "L"}]},
    {nodeId: "node_001", choices: [{choiceId: "c1",
      label: "x".repeat(25), targetNodeId: "n2"}]},
    {nodeId: "node_001", choices: [{choiceId: "c1", label: "L",
      targetNodeId: "n2", x: 2}]},
    {nodeId: "node_001", isEnding: "yes"},
  ];
  for (const node of bad) {
    await assert.rejects(
      saveNodeWith(db, "u1", {storyId: "story_draft", node}),
      (error: unknown) =>
        (error as {code?: string}).code === "invalid-argument"
    );
  }
  const node = await db.doc("stories/story_draft/nodes/node_001").get();
  assert.equal(node.data()?.title, "Old title");
});
