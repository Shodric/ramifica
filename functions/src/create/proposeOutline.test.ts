import {strict as assert} from "assert";
import {test} from "node:test";
import {Db, DbCol, DbDoc, DbRef, DbTx} from "../feed/shared";
import {
  OutlineGenDeps,
  proposeStoryOutlineWith,
  sanitizeOutline,
} from "./proposeOutline";
import {MetaFetch} from "../media/meta";

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

/** In-memory collection: only doc() is needed for the outline path. */
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
   * Unused stub: outline tests never query.
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
   * Unused stub: outline tests never query.
   * @param {string} field Field name.
   * @param {string} dir Sort direction.
   */
  orderBy(field: string, dir: "asc" | "desc" = "asc"): DbCol {
    void field;
    void dir;
    throw new Error("MemCol.orderBy is not stubbed.");
  }

  /**
   * Unused stub: outline tests never query.
   * @param {number} n Max docs.
   */
  limit(n: number): DbCol {
    void n;
    throw new Error("MemCol.limit is not stubbed.");
  }

  /** @return {Promise<Object>} Never resolves; outline tests never query. */
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
   * @param {string} path Collection path.
   * @return {DbCol} The collection.
   */
  collection(path: string): DbCol {
    return new MemCol(this, path);
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
 * Canned provider answer; the shape mirrors chat completions.
 * @param {unknown} content Answer text the provider should return.
 * @return {MetaFetch} The stub transport.
 */
const stubFetch = (content: unknown): MetaFetch => {
  return async () => ({
    ok: true,
    status: 200,
    json: async () => ({choices: [{message: {content}}]}),
    arrayBuffer: async () => new ArrayBuffer(0),
  });
};

/**
 * Failing provider transport.
 * @param {number} status HTTP status the provider should report.
 * @return {MetaFetch} The stub transport.
 */
const failingFetch = (status: number): MetaFetch => {
  return async () => ({
    ok: false,
    status,
    json: async () => ({}),
    arrayBuffer: async () => new ArrayBuffer(0),
  });
};

/**
 * Snapshot every doc to prove the proposal path never writes.
 * @param {MemDb} db Test database.
 * @return {string} Serialized documents.
 */
const snapshot = (db: MemDb): string => {
  return JSON.stringify([...db.store.entries()]);
};

/**
 * One author-owned draft plus published and foreign lookalikes.
 * @param {MemDb} db Test database.
 */
const seedDraft = async (db: MemDb): Promise<void> => {
  await db.doc("stories/story_draft").set({
    authorId: "u1",
    title: "",
    synopsis: "",
    status: "draft",
    rootNodeId: "node_001",
  });
  await db.doc("stories/story_pub").set({
    authorId: "u1",
    title: "Published",
    status: "published",
    rootNodeId: "node_001",
  });
  await db.doc("stories/story_foreign").set({
    authorId: "u2",
    title: "Foreign",
    status: "draft",
    rootNodeId: "node_001",
  });
};

/**
 * Valid outline answer; callers override fields per case.
 * @param {object} overrides Fields for this case.
 * @return {string} Provider JSON.
 */
const outlineAnswer = (overrides: object = {}): string =>
  JSON.stringify({
    title: "The gate",
    synopsis: "A cursed door.",
    narratorLine: "The stones remember your name.",
    options: [
      {label: "Enter", icon: "door", iconColor: "gold"},
      {label: "Climb", icon: "mountain", iconColor: "blue"},
    ],
    ...overrides,
  });

/**
 * Deps with a canned outline answer.
 * @param {object} overrides Fields for this case.
 * @return {OutlineGenDeps} Test dependencies.
 */
const depsFor = (overrides: object = {}): OutlineGenDeps => ({
  apiKey: "test-key",
  fetchFn: stubFetch(outlineAnswer(overrides)),
});

test("proposes an outline without writing", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const before = snapshot(db);
  const result = await proposeStoryOutlineWith(
    db,
    "u1",
    {storyId: "story_draft", transcript: "A cursed gate in the hills."},
    depsFor()
  );
  assert.equal(result.title, "The gate");
  assert.equal(result.synopsis, "A cursed door.");
  assert.equal(result.narratorLine, "The stones remember your name.");
  assert.deepEqual(result.options, [
    {label: "Enter", icon: "door", iconColor: "gold"},
    {label: "Climb", icon: "mountain", iconColor: "blue"},
  ]);
  assert.equal(snapshot(db), before);
});

test("clamps overlong provider fields and drops the third option", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await proposeStoryOutlineWith(
    db,
    "u1",
    {storyId: "story_draft", transcript: "A gate."},
    depsFor({
      title: "T".repeat(50),
      narratorLine: "L".repeat(300),
      options: [
        {label: "A".repeat(30), icon: "door", iconColor: "gold"},
        {label: "  ", icon: "key", iconColor: "red"},
        {label: "Third", icon: "star", iconColor: "pink"},
        {label: "Fourth", icon: "moon", iconColor: "mint"},
      ],
    })
  );
  assert.equal(result.title, "T".repeat(40));
  assert.equal(result.narratorLine, "L".repeat(280));
  // Blank labels drop, extras past two drop: only two survive.
  assert.deepEqual(result.options, [
    {label: "A".repeat(24), icon: "door", iconColor: "gold"},
    {label: "Third", icon: "star", iconColor: "pink"},
  ]);
});

test("unknown icons fail closed to null, keeping the option", async () => {
  const unknownNames = ["rocket-ship", "toString", "constructor", "__proto__"];
  for (const unknown of unknownNames) {
    const parsed = sanitizeOutline(
      outlineAnswer({
        options: [{label: "Run", icon: unknown, iconColor: unknown}],
      })
    );
    assert.deepEqual(parsed.options, [
      {label: "Run", icon: null, iconColor: null},
    ]);
  }
});

test("rejects callers without a session", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await assert.rejects(
    proposeStoryOutlineWith(db, "", {storyId: "story_draft", transcript: "x"}),
    (error: unknown) =>
      (error as {code?: string}).code === "unauthenticated"
  );
});

test("rejects foreign drafts and published stories", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await assert.rejects(
    proposeStoryOutlineWith(
      db,
      "u1",
      {storyId: "story_foreign", transcript: "x"},
      depsFor()
    ),
    (error: unknown) =>
      (error as {code?: string}).code === "permission-denied"
  );
  await assert.rejects(
    proposeStoryOutlineWith(
      db,
      "u1",
      {storyId: "story_pub", transcript: "x"},
      depsFor()
    ),
    (error: unknown) =>
      (error as {code?: string}).code === "failed-precondition"
  );
});

test("rejects blank and oversized transcripts", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await assert.rejects(
    proposeStoryOutlineWith(
      db,
      "u1",
      {storyId: "story_draft", transcript: "  "},
      depsFor()
    ),
    (error: unknown) =>
      (error as {code?: string}).code === "invalid-argument"
  );
  await assert.rejects(
    proposeStoryOutlineWith(
      db,
      "u1",
      {storyId: "story_draft", transcript: "x".repeat(4001)},
      depsFor()
    ),
    (error: unknown) =>
      (error as {code?: string}).code === "invalid-argument"
  );
});

test("surfaces provider outages without writing", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const before = snapshot(db);
  await assert.rejects(
    proposeStoryOutlineWith(
      db,
      "u1",
      {storyId: "story_draft", transcript: "A gate."},
      {apiKey: "test-key", fetchFn: failingFetch(500)}
    ),
    (error: unknown) => (error as {code?: string}).code === "unavailable"
  );
  assert.equal(snapshot(db), before);
});

test("rejects unreadable provider answers", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await assert.rejects(
    proposeStoryOutlineWith(
      db,
      "u1",
      {storyId: "story_draft", transcript: "A gate."},
      {apiKey: "test-key", fetchFn: stubFetch("not json at all {{{")}
    ),
    (error: unknown) => (error as {code?: string}).code === "internal"
  );
});

test("needs a configured provider key", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const apiKey = process.env.META_API_KEY;
  try {
    delete process.env.META_API_KEY;
    await assert.rejects(
      proposeStoryOutlineWith(db, "u1", {
        storyId: "story_draft",
        transcript: "A gate.",
      }),
      (error: unknown) =>
        (error as {code?: string}).code === "failed-precondition"
    );
  } finally {
    if (apiKey === undefined) delete process.env.META_API_KEY;
    else process.env.META_API_KEY = apiKey;
  }
});
