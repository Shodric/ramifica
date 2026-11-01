import {strict as assert} from "assert";
import {test} from "node:test";
import {Db, DbCol, DbDoc, DbRef, DbTx} from "../feed/shared";
import {createNodeWith, deleteNodeWith, saveNodeWith} from "./nodes";

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


  /** Deletes the doc. Extra beyond DbRef: served through a narrow cast. */
  async delete(): Promise<void> {
    this.db.store.delete(this.path);
  }
}

/** In-memory collection with chained filters, like a Firestore query. */
class MemCol implements DbCol {
  private filters: Array<(fields: Fields) => boolean> = [];
  private take?: number;

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
   * Narrows the query to docs whose field strictly equals the value.
   * @param {string} field Field name.
   * @param {string} op Only `==`.
   * @param {unknown} value Expected value.
   * @return {DbCol} The filtered query.
   */
  where(field: string, op: string, value: unknown): DbCol {
    const next = this.child();
    if (op !== "==") throw new Error(`unsupported op ${op}`);
    next.filters.push((fields) => fields[field] === value);
    return next;
  }

  /**
   * Unused stub: node tests never order.
   * @param {string} field Field name.
   * @param {string} dir Sort direction.
   */
  orderBy(field: string, dir: "asc" | "desc" = "asc"): DbCol {
    void field;
    void dir;
    throw new Error("MemCol.orderBy is not stubbed.");
  }

  /**
   * Caps the matches, like the idempotency lookup's `limit(1)`.
   * @param {number} n Max docs.
   * @return {DbCol} The limited query.
   */
  limit(n: number): DbCol {
    const next = this.child();
    next.take = n;
    return next;
  }

  /**
   * Lists direct children, by id, honoring `where`/`limit`. Delete guards
   * scan choices this way; the idempotency lookup filters by `requestId`.
   * @return {Promise<Object>} Whether empty, plus the doc snapshots.
   */
  async get(): Promise<{empty: boolean; docs: DbDoc[]}> {
    const prefix = `${this.path}/`;
    let docs: DbDoc[] = [];
    for (const [key, fields] of this.db.store) {
      if (!key.startsWith(prefix)) continue;
      if (key.slice(prefix.length).includes("/")) continue;
      docs.push(new MemDoc(true, key.slice(prefix.length), fields));
    }
    for (const match of this.filters) {
      docs = docs.filter((doc) => match(doc.data() ?? {}));
    }
    docs.sort((left, right) => (left.id < right.id ? -1 : 1));
    if (this.take !== undefined) docs = docs.slice(0, this.take);
    return {empty: docs.length === 0, docs};
  }

  /** @return {MemCol} The forked query. */
  private child(): MemCol {
    const next = new MemCol(this.db, this.path);
    next.filters = [...this.filters];
    next.take = this.take;
    return next;
  }
}

/** In-memory Firestore. Transactions serialize: each body runs to
 * completion before the next starts, like Firestore's serializable
 * retries, so concurrent same-key calls deterministically dedupe. */
class MemDb implements Db {
  readonly store = new Map<string, Fields>();
  autoId = 0;
  private tail: Promise<void> = Promise.resolve();

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
    const run = this.tail.then(() => fn(this.makeTx()));
    this.tail = run.then(
      () => undefined,
      () => undefined
    );
    return run;
  }

  /** @return {DbTx} A transaction over the shared store. */
  private makeTx(): DbTx {
    // Delete rides along untyped: the Db surface stays get/set/update.
    const tx = {
      get: (ref: DbRef) => ref.get(),
      set: (
        ref: DbRef,
        data: Record<string, unknown>,
        opts?: {merge?: boolean}
      ) => ref.set(data, opts),
      update: (ref: DbRef, data: Record<string, unknown>) =>
        ref.update(data),
      delete: (ref: DbRef) => (ref as unknown as MemRef).delete(),
    };
    return tx;
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

test("createNode without a key always creates a fresh child", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const first = await createNodeWith(
    db,
    "u1",
    {storyId: "story_draft", parentNodeId: "node_001"}
  );
  const second = await createNodeWith(
    db,
    "u1",
    {storyId: "story_draft", parentNodeId: "node_001"}
  );
  assert.notEqual(first.nodeId, second.nodeId);
  const stored = await db
    .doc(`stories/story_draft/nodes/${second.nodeId}`)
    .get();
  assert.equal("requestId" in (stored.data() ?? {}), false);
});

test("createNode reuses the child stored for the same key", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const key = "v1:u1:story_draft:node_001:A";
  const first = await createNodeWith(
    db,
    "u1",
    {storyId: "story_draft", parentNodeId: "node_001", requestId: key}
  );
  const created = await db
    .doc(`stories/story_draft/nodes/${first.nodeId}`)
    .get();
  assert.equal(created.data()?.requestId, key);
  // An edit between the calls must survive the replay untouched.
  await db
    .doc(`stories/story_draft/nodes/${first.nodeId}`)
    .update({title: "Kept"});
  const second = await createNodeWith(
    db,
    "u1",
    {storyId: "story_draft", parentNodeId: "node_001", requestId: key}
  );
  assert.equal(second.nodeId, first.nodeId);
  const stored = await db
    .doc(`stories/story_draft/nodes/${first.nodeId}`)
    .get();
  assert.equal(stored.data()?.title, "Kept");
  assert.equal(stored.data()?.requestId, key);
  assert.equal(stored.data()?.startFromNodeId, "node_001");
  const listed = await db.collection("stories/story_draft/nodes").get();
  assert.equal(listed.docs.length, 2);
  const story = await db.doc("stories/story_draft").get();
  assert.equal(story.data()?.rootNodeId, "node_001");
});

test("createNode dedupes concurrent calls with the same key", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const key = "v1:u1:story_draft:node_001:A";
  const calls = Array.from({length: 5}, () =>
    createNodeWith(
      db,
      "u1",
      {storyId: "story_draft", parentNodeId: "node_001", requestId: key}
    )
  );
  const results = await Promise.all(calls);
  for (const result of results) {
    assert.equal(result.nodeId, results[0].nodeId);
  }
  const listed = await db.collection("stories/story_draft/nodes").get();
  assert.equal(listed.docs.length, 2);
});

test("createNode isolates keys by story", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_other").set({
    authorId: "u1",
    title: "Other",
    synopsis: "",
    status: "draft",
    rootNodeId: null,
  });
  const key = "v1:u1:shared:A";
  const inDraft = await createNodeWith(
    db,
    "u1",
    {storyId: "story_draft", parentNodeId: "node_001", requestId: key}
  );
  const inOther = await createNodeWith(
    db,
    "u1",
    {storyId: "story_other", requestId: key}
  );
  assert.notEqual(inDraft.nodeId, inOther.nodeId);
  const other = await db
    .doc(`stories/story_other/nodes/${inOther.nodeId}`)
    .get();
  assert.equal(other.data()?.requestId, key);
  assert.equal(other.data()?.startFromNodeId, null);
});

test("createNode isolates a reused key by parent", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const key = "v1:u1:story_draft:node_001:A";
  const first = await createNodeWith(
    db,
    "u1",
    {storyId: "story_draft", parentNodeId: "node_001", requestId: key}
  );
  const replay = await createNodeWith(
    db,
    "u1",
    {storyId: "story_draft", parentNodeId: first.nodeId, requestId: key}
  );
  assert.notEqual(replay.nodeId, first.nodeId);
  const stored = await db
    .doc(`stories/story_draft/nodes/${first.nodeId}`)
    .get();
  assert.equal(stored.data()?.startFromNodeId, "node_001");
  const listed = await db.collection("stories/story_draft/nodes").get();
  assert.equal(listed.docs.length, 3);
});

test("createNode stores the key on the root of a new story", async () => {
  const db = new MemDb();
  const key = "v1:u1:story_new::A";
  const first = await createNodeWith(
    db,
    "u1",
    {storyId: "story_new", requestId: key}
  );
  const replay = await createNodeWith(
    db,
    "u1",
    {storyId: "story_new", requestId: key}
  );
  assert.equal(replay.nodeId, first.nodeId);
  const story = await db.doc("stories/story_new").get();
  assert.equal(story.data()?.rootNodeId, first.nodeId);
  const listed = await db.collection("stories/story_new/nodes").get();
  assert.equal(listed.docs.length, 1);
});

test("createNode validates before reusing a key", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const key = "v1:u1:story_draft:node_001:A";
  const first = await createNodeWith(
    db,
    "u1",
    {storyId: "story_draft", parentNodeId: "node_001", requestId: key}
  );
  const hostile = {
    storyId: "story_draft",
    parentNodeId: "node_001",
    requestId: key,
  };
  await assert.rejects(
    createNodeWith(db, "u2", hostile),
    (error: unknown) => (error as {code?: string}).code === "permission-denied"
  );
  await assert.rejects(
    createNodeWith(
      db,
      "u1",
      {storyId: "story_pub", parentNodeId: "node_p1", requestId: key}
    ),
    (error: unknown) =>
      (error as {code?: string}).code === "failed-precondition"
  );
  await assert.rejects(
    createNodeWith(
      db,
      "u1",
      {storyId: "story_draft", parentNodeId: "node_nope", requestId: key}
    ),
    (error: unknown) => (error as {code?: string}).code === "not-found"
  );
  await assert.rejects(
    createNodeWith(db, "", hostile),
    (error: unknown) => (error as {code?: string}).code === "unauthenticated"
  );
  const stored = await db
    .doc(`stories/story_draft/nodes/${first.nodeId}`)
    .get();
  assert.equal(stored.data()?.requestId, key);
  const listed = await db.collection("stories/story_draft/nodes").get();
  assert.equal(listed.docs.length, 2);
});

test("saveNode ignores requestId outside the author whitelist", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {
      nodeId: "node_001",
      title: "New title",
      requestId: "v1:u1:story_draft:node_001:A",
    },
  });
  const node = await db.doc("stories/story_draft/nodes/node_001").get();
  const saved = node.data() ?? {};
  assert.equal(saved.title, "New title");
  assert.equal("requestId" in saved, false);
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
      choices: [
        {
          choiceId: "c1",
          label: "Enter",
          targetNodeId: "node_002",
          isDefault: true,
          icon: "mountain",
          iconColor: "gold",
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
      ttsApproved: true,
      startFromNodeId: "node_hack",
    },
  });
  assert.deepEqual(result, {});
  const node = await db.doc("stories/story_draft/nodes/node_001").get();
  const saved = node.data() ?? {};
  assert.equal(saved.title, "New title");
  assert.equal(saved.visibility, "secret");
  assert.equal(saved.ttsText, "New line.");
  assert.deepEqual(saved.choices, [
    {
      choiceId: "c1",
      label: "Enter",
      targetNodeId: "node_002",
      isDefault: true,
      x: 0.25,
      y: 0.65,
      radius: 0.15,
      icon: "mountain",
      iconColor: "gold",
    },
  ]);
  assert.equal(saved.videoUrl, "https://old.example/v.mp4");
  assert.equal(saved.lineApproved, false);
  assert.equal(saved.ttsStatus, "idle");
  assert.equal(saved.ttsAudioUrl, null);
  assert.equal(saved.ttsDurationSeconds, null);
  assert.equal(saved.ttsApproved, false);
  assert.equal(saved.startFromNodeId, null);
  assert.equal("authorId" in saved, false);
  assert.equal("status" in saved, false);
  assert.equal("rootNodeId" in saved, false);
  assert.equal(outsideSnapshot(db, "story_draft"), before);
});

test("saveNode persists the branch slot and rejects bad ones", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {
      nodeId: "node_001",
      choices: [
        {
          choiceId: "c1",
          label: "Left",
          targetNodeId: "node_002",
          isDefault: true,
          slot: "A",
        },
        {
          choiceId: "c2",
          label: "Right",
          targetNodeId: "node_003",
          slot: "B",
        },
      ],
    },
  });
  const node = await db.doc("stories/story_draft/nodes/node_001").get();
  const saved = node.data() ?? {};
  assert.deepEqual(
    (saved.choices as Array<Record<string, unknown>>).map(
      (choice) => choice.slot
    ),
    ["A", "B"]
  );
  for (const bad of ["C", "", 42]) {
    await assert.rejects(
      saveNodeWith(db, "u1", {
        storyId: "story_draft",
        node: {
          nodeId: "node_001",
          choices: [
            {
              choiceId: "c1",
              label: "Left",
              targetNodeId: "node_002",
              slot: bad,
            },
          ],
        },
      }),
      (error: unknown) => (error as {code?: string}).code === "invalid-argument"
    );
  }
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

test("saveNode stores author prompts and clears on blank", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {
      nodeId: "node_001",
      startImagePrompt: "  Wide dawn establishing shot  ",
      endImagePrompt: "Close on the gate",
      videoPrompt: "Slow push in",
    },
  });
  const saved =
    (await db.doc("stories/story_draft/nodes/node_001").get()).data() ?? {};
  assert.equal(saved.startImagePrompt, "Wide dawn establishing shot");
  assert.equal(saved.endImagePrompt, "Close on the gate");
  assert.equal(saved.videoPrompt, "Slow push in");
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {
      nodeId: "node_001",
      startImagePrompt: "   ",
      endImagePrompt: null,
      videoPrompt: "",
    },
  });
  const cleared =
    (await db.doc("stories/story_draft/nodes/node_001").get()).data() ?? {};
  assert.equal(cleared.startImagePrompt, null);
  assert.equal(cleared.endImagePrompt, null);
  assert.equal(cleared.videoPrompt, null);
});

test("saveNode rejects overlong media prompts", async () => {
  const db = new MemDb();
  await seedDraft(db);
  for (const field of ["startImagePrompt", "endImagePrompt", "videoPrompt"]) {
    await assert.rejects(
      saveNodeWith(db, "u1", {
        storyId: "story_draft",
        node: {nodeId: "node_001", [field]: "x".repeat(2001)},
      }),
      (error: unknown) => (error as {code?: string}).code === "invalid-argument"
    );
  }
});

test("saveNode approves the line and voice without new words", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {nodeId: "node_001", lineApproved: false, ttsApproved: false},
  });
  const denied =
    (await db.doc("stories/story_draft/nodes/node_001").get()).data() ?? {};
  assert.equal(denied.lineApproved, false);
  assert.equal(denied.ttsApproved, false);
  assert.equal(denied.ttsStatus, "ready");
  assert.equal(denied.ttsAudioUrl, "https://old.example/v.m4a");
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {nodeId: "node_001", lineApproved: true, ttsApproved: true},
  });
  const approved =
    (await db.doc("stories/story_draft/nodes/node_001").get()).data() ?? {};
  assert.equal(approved.lineApproved, true);
  assert.equal(approved.ttsApproved, true);
  assert.equal(approved.ttsStatus, "ready");
  assert.equal(approved.ttsAudioUrl, "https://old.example/v.m4a");
});

test("saveNode idles the voice when the words change", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {nodeId: "node_001", ttsText: "Brand new line."},
  });
  const idled =
    (await db.doc("stories/story_draft/nodes/node_001").get()).data() ?? {};
  assert.equal(idled.ttsText, "Brand new line.");
  assert.equal(idled.lineApproved, false);
  assert.equal(idled.ttsStatus, "idle");
  assert.equal(idled.ttsAudioUrl, null);
  assert.equal(idled.ttsDurationSeconds, null);
  assert.equal(idled.ttsApproved, false);
});

test("saveNode honors an explicit line approval with new words", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {
      nodeId: "node_001",
      ttsText: "Reviewed new line.",
      lineApproved: true,
      ttsApproved: true,
    },
  });
  const saved =
    (await db.doc("stories/story_draft/nodes/node_001").get()).data() ?? {};
  assert.equal(saved.lineApproved, true);
  assert.equal(saved.ttsStatus, "idle");
  assert.equal(saved.ttsAudioUrl, null);
  assert.equal(saved.ttsApproved, false);
});

test("saveNode keeps approvals when the words are unchanged", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {nodeId: "node_001", ttsText: "Old line."},
  });
  const saved =
    (await db.doc("stories/story_draft/nodes/node_001").get()).data() ?? {};
  assert.equal(saved.lineApproved, true);
  assert.equal(saved.ttsStatus, "ready");
  assert.equal(saved.ttsAudioUrl, "https://old.example/v.m4a");
});

test("saveNode normalizes endings and rejects choices on them", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {
      nodeId: "node_001",
      isEnding: true,
      endingName: "Dawn",
      endingType: "abierto",
    },
  });
  const node = await db.doc("stories/story_draft/nodes/node_001").get();
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
    {nodeId: "node_001", lineApproved: "yes"},
    {nodeId: "node_001", ttsApproved: 1},
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
    {nodeId: "node_001", choices: [{choiceId: "c1", label: "L",
      targetNodeId: "n2", icon: "spaceship"}]},
    {nodeId: "node_001", choices: [{choiceId: "c1", label: "L",
      targetNodeId: "n2", iconColor: "neon"}]},
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

test("deleteNode removes an unlinked node", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_leaf").set({
    title: "Leaf",
    visibility: "secret",
    isEnding: false,
    videoUrl: "https://media.example/leaf.mp4",
    videoStatus: "ready",
    ttsAudioUrl: "https://media.example/leaf.m4a",
    ttsStatus: "ready",
    choices: [],
  });
  const storyBefore = await db.doc("stories/story_draft").get();
  const before = outsideSnapshot(db, "story_draft");
  const result = await deleteNodeWith(db, "u1", {
    storyId: "story_draft",
    nodeId: "node_leaf",
  });
  assert.deepEqual(result, {nodeId: "node_leaf"});
  const gone = await db.doc("stories/story_draft/nodes/node_leaf").get();
  assert.equal(gone.exists, false);
  assert.equal(
    [...db.store.keys()].some((key) => key.endsWith("/node_leaf")),
    false
  );
  const storyAfter = await db.doc("stories/story_draft").get();
  assert.deepEqual(storyAfter.data(), storyBefore.data());
  assert.equal(storyAfter.data()?.rootNodeId, "node_001");
  const kept = await db.doc("stories/story_draft/nodes/node_001").get();
  assert.equal(kept.exists, true);
  assert.equal(outsideSnapshot(db, "story_draft"), before);
});

test("deleteNode refuses the root node", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const storyBefore = JSON.stringify(
    (await db.doc("stories/story_draft").get()).data()
  );
  await assert.rejects(
    deleteNodeWith(db, "u1", {storyId: "story_draft", nodeId: "node_001"}),
    (error: unknown) => {
      const got = error as {code?: string; message?: string};
      return got.code === "failed-precondition" &&
        got.message === "The root node cannot be deleted.";
    }
  );
  const kept = await db.doc("stories/story_draft/nodes/node_001").get();
  assert.equal(kept.exists, true);
  assert.equal(
    JSON.stringify((await db.doc("stories/story_draft").get()).data()),
    storyBefore
  );
});

test("deleteNode refuses a node targeted by another choice", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_leaf").set({
    title: "Leaf",
    choices: [],
  });
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {
      nodeId: "node_001",
      choices: [
        {
          choiceId: "c1",
          label: "Down",
          targetNodeId: "node_leaf",
          isDefault: true,
        },
      ],
    },
  });
  await assert.rejects(
    deleteNodeWith(db, "u1", {storyId: "story_draft", nodeId: "node_leaf"}),
    (error: unknown) =>
      (error as {code?: string}).code === "failed-precondition" &&
      ((error as {message?: string }).message ?? "").includes("c1") &&
      ((error as {message?: string }).message ?? "").includes("node_001")
  );
  const kept = await db.doc("stories/story_draft/nodes/node_leaf").get();
  assert.equal(kept.exists, true);
});

test("deleteNode deletes again once the link is gone", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_leaf").set({
    title: "Leaf",
    choices: [],
  });
  await saveNodeWith(db, "u1", {
    storyId: "story_draft",
    node: {nodeId: "node_001", choices: []},
  });
  const result = await deleteNodeWith(db, "u1", {
    storyId: "story_draft",
    nodeId: "node_leaf",
  });
  assert.deepEqual(result, {nodeId: "node_leaf"});
  assert.equal(
    (await db.doc("stories/story_draft/nodes/node_leaf").get()).exists,
    false
  );
});

test("deleteNode rejects bad callers and targets", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const codes: Array<[unknown, string]> = [
    [{storyId: "", nodeId: "node_001"}, "invalid-argument"],
    [{storyId: "story_draft", nodeId: ""}, "invalid-argument"],
    [{storyId: "story_draft", nodeId: "nope"}, "not-found"],
    [{storyId: "story_missing", nodeId: "node_001"}, "not-found"],
    [{storyId: "story_foreign", nodeId: "node_f1"}, "permission-denied"],
    [{storyId: "story_pub", nodeId: "node_p1"}, "failed-precondition"],
  ];
  for (const [data, code] of codes) {
    await assert.rejects(
      deleteNodeWith(db, "u1", data),
      (error: unknown) => (error as {code?: string}).code === code
    );
  }
  await assert.rejects(
    deleteNodeWith(db, "", {storyId: "story_draft", nodeId: "node_001"}),
    (error: unknown) => (error as {code?: string}).code === "unauthenticated"
  );
});
