import {strict as assert} from "assert";
import {test} from "node:test";
import {Db, DbCol, DbDoc, DbRef, DbTx} from "../feed/shared";
import {publishStoryWith} from "./publishStory";

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

/** In-memory collection with direct-children listing. */
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
   * @param {string} field Field name.
   * @param {string} op Only `==`.
   * @param {unknown} value Expected value.
   * @return {DbCol} This collection.
   */
  where(field: string, op: string, value: unknown): DbCol {
    void field;
    void op;
    void value;
    return this;
  }

  /**
   * @param {string} field Field name.
   * @param {string} dir Sort direction.
   * @return {DbCol} This collection.
   */
  orderBy(field: string, dir: "asc" | "desc" = "asc"): DbCol {
    void field;
    void dir;
    return this;
  }

  /**
   * @param {number} n Max docs.
   * @return {DbCol} This collection.
   */
  limit(n: number): DbCol {
    void n;
    return this;
  }

  /**
   * @return {Promise<Object>} Whether empty, plus the doc snapshots.
   */
  async get(): Promise<{empty: boolean; docs: DbDoc[]}> {
    const prefix = `${this.path}/`;
    const docs: DbDoc[] = [];
    for (const [key, fields] of this.db.store) {
      if (!key.startsWith(prefix)) continue;
      if (key.slice(prefix.length).includes("/")) continue;
      docs.push(new MemDoc(true, key.slice(prefix.length), fields));
    }
    docs.sort((left, right) => (left.id < right.id ? -1 : 1));
    return {empty: docs.length === 0, docs};
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
 * One valid choice.
 * @param {Fields} overrides Field overrides.
 * @return {Fields} The choice fields.
 */
const choice = (overrides: Fields = {}): Fields => ({
  choiceId: "choice_temple",
  label: "Enter the temple",
  targetNodeId: "node_002",
  isDefault: true,
  x: 0.25,
  y: 0.65,
  radius: 0.15,
  ...overrides,
});

/**
 * One valid decision node.
 * @param {Fields} overrides Field overrides.
 * @return {Fields} The node fields.
 */
const decision = (overrides: Fields = {}): Fields => ({
  title: "The temple door",
  visibility: "visible",
  isEnding: false,
  endingName: null,
  endingType: null,
  videoUrl: "https://example.com/video.mp4",
  videoStatus: "ready",
  videoSource: "generated",
  pauseAtSeconds: 9.967,
  windowSeconds: 6,
  startImageApproved: true,
  endImageApproved: true,
  endHash: "hash-e1",
  ttsText: "Enter or climb?",
  lineApproved: true,
  ttsAudioUrl: "https://example.com/voz.m4a",
  ttsStatus: "ready",
  ttsDurationSeconds: 4.1,
  ttsApproved: true,
  choices: [choice()],
  ...overrides,
});

/**
 * Seeds one author-owned draft that passes the whole checklist, plus a
 * foreign draft and a published story that must stay untouched.
 * @param {MemDb} db Backing store to seed.
 * @return {Promise<void>} When the seed is written.
 */
const seedValid = async (db: MemDb): Promise<void> => {
  await db.doc("stories/story_draft").set({
    authorId: "u1",
    title: "The temple",
    synopsis: "A door.",
    status: "draft",
    rootNodeId: "node_001",
  });
  await db.doc("stories/story_draft/nodes/node_001").set(decision());
  await db.doc("stories/story_draft/nodes/node_002").set(
    decision({
      title: "The ridge",
      startFromNodeId: "node_001",
      startParentEndHash: "hash-e1",
      endHash: "hash-e2",
      choices: [
        choice({choiceId: "choice_end", label: "Keep going",
          targetNodeId: "node_003"}),
      ],
    })
  );
  await db.doc("stories/story_draft/nodes/node_003").set({
    title: "The last door",
    visibility: "visible",
    isEnding: true,
    endingName: "The door",
    endingType: "tragico",
    videoUrl: "https://example.com/end.mp4",
    videoStatus: "ready",
    videoSource: "generated",
    pauseAtSeconds: 9.967,
    windowSeconds: null,
    endImageApproved: true,
    startFromNodeId: "node_002",
    startParentEndHash: "hash-e2",
    ttsText: "",
    choices: [],
  });
  await db.doc("stories/story_foreign").set({
    authorId: "u2",
    title: "Foreign",
    status: "draft",
    rootNodeId: "node_f1",
  });
  await db.doc("stories/story_pub").set({
    authorId: "u1",
    title: "Published",
    status: "published",
    rootNodeId: "node_p1",
    publishedAt: "2026-01-01T00:00:00.000Z",
  });
};

/**
 * Snapshot of every doc outside the given story, to prove publish writes
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

/**
 * Reads the draft status, failing loudly when the story is gone.
 * @param {MemDb} db Backing store.
 * @return {Promise<string>} The status.
 */
const draftStatus = async (db: MemDb): Promise<string> => {
  const snap = await db.doc("stories/story_draft").get();
  return String(snap.data()?.status ?? "");
};

test("publishStory publishes a clean story with publishedAt", async () => {
  const db = new MemDb();
  await seedValid(db);
  const nodesBefore = JSON.stringify(
    (await db.collection("stories/story_draft/nodes").get()).docs.map(
      (snap) => [snap.id, snap.data()]
    )
  );
  const before = outsideSnapshot(db, "story_draft");
  const result = await publishStoryWith(db, "u1", {storyId: "story_draft"});
  assert.deepEqual(result, {
    storyId: "story_draft",
    published: true,
    problems: [],
  });
  const story = await db.doc("stories/story_draft").get();
  assert.equal(story.data()?.status, "published");
  assert.match(String(story.data()?.publishedAt ?? ""), /^\d{4}-\d{2}-\d{2}T/);
  assert.equal(story.data()?.authorId, "u1");
  assert.equal(story.data()?.rootNodeId, "node_001");
  const nodesAfter = JSON.stringify(
    (await db.collection("stories/story_draft/nodes").get()).docs.map(
      (snap) => [snap.id, snap.data()]
    )
  );
  assert.equal(nodesAfter, nodesBefore);
  assert.equal(outsideSnapshot(db, "story_draft"), before);
});

test("publishStory reports unreachable nodes without writing", async () => {
  const db = new MemDb();
  await seedValid(db);
  await db.doc("stories/story_draft/nodes/node_009").set(
    decision({
      title: "Lost",
      startFromNodeId: "node_001",
      startParentEndHash: "hash-e1",
      choices: [choice({choiceId: "choice_out", label: "Out",
        targetNodeId: "node_003"})],
    })
  );
  const storeBefore = JSON.stringify([...db.store.entries()]);
  const result = await publishStoryWith(db, "u1", {storyId: "story_draft"});
  assert.equal(result.published, false);
  assert.ok(
    result.problems.includes("Node node_009 is not reachable from the root.")
  );
  assert.equal(await draftStatus(db), "draft");
  assert.equal(JSON.stringify([...db.store.entries()]), storeBefore);
});

test("publishStory reports a missing ending without writing", async () => {
  const db = new MemDb();
  await seedValid(db);
  await db.doc("stories/story_draft/nodes/node_003").set(
    decision({
      title: "The ridge end",
      startFromNodeId: "node_002",
      startParentEndHash: "hash-e2",
      endHash: "hash-e3",
      choices: [choice({choiceId: "choice_back", label: "Back",
        targetNodeId: "node_001"})],
    })
  );
  const result = await publishStoryWith(db, "u1", {storyId: "story_draft"});
  assert.equal(result.published, false);
  assert.ok(result.problems.includes("At least one ending is required."));
  assert.equal(await draftStatus(db), "draft");
});

test("publishStory reports a missing root node without writing", async () => {
  const db = new MemDb();
  await seedValid(db);
  await db.doc("stories/story_draft").set({rootNodeId: null}, {merge: true});
  const result = await publishStoryWith(db, "u1", {storyId: "story_draft"});
  assert.equal(result.published, false);
  assert.ok(result.problems.includes("Missing root node."));
  assert.equal(await draftStatus(db), "draft");
});

test("publishStory reports unapproved start and end frames", async () => {
  const db = new MemDb();
  await seedValid(db);
  await db.doc("stories/story_draft/nodes/node_001").set(
    {startImageApproved: false}, {merge: true}
  );
  await db.doc("stories/story_draft/nodes/node_002").set(
    {endImageApproved: false}, {merge: true}
  );
  const storeBefore = JSON.stringify([...db.store.entries()]);
  const result = await publishStoryWith(db, "u1", {storyId: "story_draft"});
  assert.equal(result.published, false);
  assert.ok(
    result.problems.includes("Node node_001 needs an approved start image.")
  );
  assert.ok(
    result.problems.includes("Node node_002 needs an approved end image.")
  );
  assert.equal(await draftStatus(db), "draft");
  assert.equal(JSON.stringify([...db.store.entries()]), storeBefore);
});

test("publishStory reports an unapproved narrator line", async () => {
  const db = new MemDb();
  await seedValid(db);
  await db.doc("stories/story_draft/nodes/node_001").set(
    {lineApproved: false}, {merge: true}
  );
  const result = await publishStoryWith(db, "u1", {storyId: "story_draft"});
  assert.equal(result.published, false);
  assert.ok(
    result.problems.includes("Node node_001 needs an approved narrator line.")
  );
  assert.equal(await draftStatus(db), "draft");
});

test("publishStory reports video and voice that are not ready", async () => {
  const db = new MemDb();
  await seedValid(db);
  await db.doc("stories/story_draft/nodes/node_001").set(
    {videoStatus: "idle", videoUrl: null}, {merge: true}
  );
  await db.doc("stories/story_draft/nodes/node_002").set(
    {ttsStatus: "idle", ttsAudioUrl: null, ttsDurationSeconds: null},
    {merge: true}
  );
  const result = await publishStoryWith(db, "u1", {storyId: "story_draft"});
  assert.equal(result.published, false);
  assert.ok(result.problems.includes("Node node_001 needs a ready video."));
  assert.ok(
    result.problems.includes("Node node_002 needs a ready narrator voice.")
  );
  assert.equal(await draftStatus(db), "draft");
});

test("publishStory reports a ready voice that is not approved", async () => {
  const db = new MemDb();
  await seedValid(db);
  await db.doc("stories/story_draft/nodes/node_002").set(
    {ttsApproved: false}, {merge: true}
  );
  const result = await publishStoryWith(db, "u1", {storyId: "story_draft"});
  assert.equal(result.published, false);
  assert.ok(
    result.problems.includes("Node node_002 needs an approved narrator voice.")
  );
  assert.equal(await draftStatus(db), "draft");
});

test("publishStory reports a missing default choice", async () => {
  const db = new MemDb();
  await seedValid(db);
  await db.doc("stories/story_draft/nodes/node_001").set(
    {choices: [
      choice({isDefault: false}),
      choice({choiceId: "choice_b", label: "Climb",
        targetNodeId: "node_003", isDefault: false}),
    ]},
    {merge: true}
  );
  const result = await publishStoryWith(db, "u1", {storyId: "story_draft"});
  assert.equal(result.published, false);
  assert.ok(
    result.problems.includes("Node node_001 needs exactly one default choice.")
  );
  assert.equal(await draftStatus(db), "draft");
});

test("publishStory reports parent desync without writing", async () => {
  const db = new MemDb();
  await seedValid(db);
  await db.doc("stories/story_draft/nodes/node_002").set(
    {startParentEndHash: "hash-stale"}, {merge: true}
  );
  const storeBefore = JSON.stringify([...db.store.entries()]);
  const result = await publishStoryWith(db, "u1", {storyId: "story_draft"});
  assert.equal(result.published, false);
  assert.ok(
    result.problems.includes("Node node_002 is out of sync with its parent.")
  );
  assert.equal(await draftStatus(db), "draft");
  assert.equal(JSON.stringify([...db.store.entries()]), storeBefore);
});

test("publishStory is an idempotent no-op on a published story", async () => {
  const db = new MemDb();
  await seedValid(db);
  const first = await publishStoryWith(db, "u1", {storyId: "story_draft"});
  assert.equal(first.published, true);
  const publishedAt =
    (await db.doc("stories/story_draft").get()).data()?.publishedAt;
  const storeBefore = JSON.stringify([...db.store.entries()]);
  const second = await publishStoryWith(db, "u1", {storyId: "story_draft"});
  assert.deepEqual(second, {
    storyId: "story_draft",
    published: true,
    problems: [],
  });
  assert.equal(
    (await db.doc("stories/story_draft").get()).data()?.publishedAt,
    publishedAt
  );
  assert.equal(JSON.stringify([...db.store.entries()]), storeBefore);
});

test("publishStory rejects bad callers and targets", async () => {
  const db = new MemDb();
  await seedValid(db);
  await assert.rejects(
    publishStoryWith(db, "u1", {storyId: "story_missing"}),
    (error: unknown) => (error as {code?: string}).code === "not-found"
  );
  await assert.rejects(
    publishStoryWith(db, "u2", {storyId: "story_draft"}),
    (error: unknown) => (error as {code?: string}).code === "permission-denied"
  );
  await assert.rejects(
    publishStoryWith(db, "u2", {storyId: "story_pub"}),
    (error: unknown) => (error as {code?: string}).code === "permission-denied"
  );
  await db.doc("stories/story_draft").set({status: "archived"},
    {merge: true});
  await assert.rejects(
    publishStoryWith(db, "u1", {storyId: "story_draft"}),
    (error: unknown) =>
      (error as {code?: string}).code === "failed-precondition"
  );
  await assert.rejects(
    publishStoryWith(db, "", {storyId: "story_draft"}),
    (error: unknown) => (error as {code?: string}).code === "unauthenticated"
  );
  await assert.rejects(
    publishStoryWith(db, "u1", {storyId: ""}),
    (error: unknown) => (error as {code?: string}).code === "invalid-argument"
  );
});
