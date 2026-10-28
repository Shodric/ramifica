import {strict as assert} from "assert";
import {createHash} from "crypto";
import {test} from "node:test";
import {Db, DbCol, DbDoc, DbRef, DbTx} from "../feed/shared";
import {
  approveNodeImageWith,
  generateNodeImageWith,
  generateNodeVideoWith,
  NodeMediaDeps,
} from "./generateNodeMedia";

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

/** In-memory collection with `==` filtering for the desync lookup. */
class MemCol implements DbCol {
  private readonly filters: Array<{field: string; value: unknown}>;

  /**
   * @param {MemDb} db Backing store.
   * @param {string} path Collection path.
   * @param {Array} filters Accumulated `==` filters.
   */
  constructor(
    readonly db: MemDb,
    readonly path: string,
    filters: Array<{field: string; value: unknown}> = []
  ) {
    this.filters = filters;
  }

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
   * @return {DbCol} The filtered collection.
   */
  where(field: string, op: string, value: unknown): DbCol {
    assert.equal(op, "==");
    return new MemCol(this.db, this.path, [...this.filters, {field, value}]);
  }

  /**
   * Unused stub: media tests never sort.
   * @param {string} field Field name.
   * @param {string} dir Sort direction.
   */
  orderBy(field: string, dir: "asc" | "desc" = "asc"): DbCol {
    void field;
    void dir;
    throw new Error("MemCol.orderBy is not stubbed.");
  }

  /**
   * Unused stub: media tests never page.
   * @param {number} n Max docs.
   */
  limit(n: number): DbCol {
    void n;
    throw new Error("MemCol.limit is not stubbed.");
  }

  /** @return {Promise<Object>} Direct children matching every filter. */
  async get(): Promise<{empty: boolean; docs: DbDoc[]}> {
    const docs: DbDoc[] = [];
    for (const [path, fields] of this.db.store) {
      if (!path.startsWith(`${this.path}/`)) continue;
      if (path.slice(this.path.length + 1).includes("/")) continue;
      const matches = this.filters.every(
        (filter) => fields[filter.field] === filter.value
      );
      if (matches) {
        docs.push(
          new MemDoc(true, path.slice(path.lastIndexOf("/") + 1), fields)
        );
      }
    }
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
 * First 8 hex chars of the sha256, mirroring the hash link.
 * @param {string} text Bytes stand-in.
 * @return {string} The stamp.
 */
const sha8 = (text: string): string => {
  return createHash("sha256").update(text).digest("hex").slice(0, 8);
};

/**
 * Mocked provider seams: distinct prompt in, distinct bytes out.
 * @param {NodeMediaDeps} overrides Per-test seam replacements.
 * @return {NodeMediaDeps} The mocked deps.
 */
const mockDeps = (overrides: NodeMediaDeps = {}): NodeMediaDeps => ({
  imageGen: async (prompt: string) => ({bytes: Buffer.from(`still:${prompt}`)}),
  uploadStill: async (args) => `https://cdn.example/${args.hash}.png`,
  now: () => 1234,
  ...overrides,
});

/**
 * Snapshot of every doc, to prove gated-out calls never write.
 * @param {MemDb} db Backing store.
 * @return {string} The serialized store.
 */
const snapshot = (db: MemDb): string => {
  return JSON.stringify([...db.store.entries()]);
};

/**
 * Asserts the rejection code.
 * @param {Promise<unknown>} pending Promise under test.
 * @param {string} expected Expected HttpsError code.
 */
const rejectsWith = async (
  pending: Promise<unknown>,
  expected: string
): Promise<void> => {
  await assert.rejects(pending, (error: unknown) => {
    // HttpsError always carries `code`; MemDb throws plain Errors instead.
    const code = (error as {code?: string}).code;
    return code === expected;
  });
};

/**
 * One author-owned draft: root with approved S+E and ready video, one
 * child linked to the root E with its own approved E and ready video.
 * @param {MemDb} db Backing store to seed.
 * @return {Promise<void>} When the seed is written.
 */
const seedDraft = async (db: MemDb): Promise<void> => {
  await db.doc("stories/story_draft").set({
    authorId: "u1",
    title: "The temple",
    status: "draft",
    rootNodeId: "node_001",
  });
  await db.doc("stories/story_draft/nodes/node_001").set({
    title: "Gate",
    startImageSourceUrl: "https://cdn.example/s1.png",
    startImageStatus: "ready",
    startHash: "hash-s1",
    startImageApproved: true,
    endImageSourceUrl: "https://cdn.example/e1.png",
    endImageStatus: "ready",
    endHash: "hash-e1",
    endImageSource: "muse",
    endImageApproved: true,
    videoStatus: "ready",
    videoSource: "generated",
    videoUrl: "https://cdn.example/v1.mp4",
    videoFromHash: "hash-s1",
    videoToHash: "hash-e1",
    videoJobId: "job-1",
  });
  await db.doc("stories/story_draft/nodes/node_002").set({
    title: "Ridge",
    startFromNodeId: "node_001",
    startParentEndHash: "hash-e1",
    startImageSourceUrl: "https://cdn.example/e1.png",
    startImageStatus: "ready",
    endImageSourceUrl: "https://cdn.example/e2.png",
    endImageStatus: "ready",
    endHash: "hash-e2",
    endImageSource: "muse",
    endImageApproved: true,
    videoStatus: "ready",
    videoSource: "generated",
    videoUrl: "https://cdn.example/v2.mp4",
    videoFromHash: "hash-e1",
    videoToHash: "hash-e2",
    videoJobId: "job-2",
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
  await db.doc("stories/story_foreign/nodes/node_001").set({title: "X"});
  await db.doc("stories/story_pub/nodes/node_001").set({title: "Y"});
};

test("S on a non-root node is rejected without writing", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const before = snapshot(db);
  await rejectsWith(
    generateNodeImageWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_002", which: "start"},
      mockDeps()
    ),
    "failed-precondition"
  );
  assert.equal(snapshot(db), before);
});

test("unknown which is rejected without writing", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const before = snapshot(db);
  await rejectsWith(
    generateNodeImageWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_001", which: "middle"},
      mockDeps()
    ),
    "invalid-argument"
  );
  assert.equal(snapshot(db), before);
});

test("image gates: auth, owner, draft", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const before = snapshot(db);
  await rejectsWith(
    generateNodeImageWith(
      db,
      "",
      {storyId: "story_draft", nodeId: "node_001", which: "end"},
      mockDeps()
    ),
    "unauthenticated"
  );
  await rejectsWith(
    generateNodeImageWith(
      db,
      "u1",
      {storyId: "story_foreign", nodeId: "node_001", which: "end"},
      mockDeps()
    ),
    "permission-denied"
  );
  await rejectsWith(
    generateNodeImageWith(
      db,
      "u1",
      {storyId: "story_pub", nodeId: "node_001", which: "end"},
      mockDeps()
    ),
    "failed-precondition"
  );
  assert.equal(snapshot(db), before);
});

test("no provider records pending and keeps last good bytes", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeImageWith(db, "u1", {
    storyId: "story_draft",
    nodeId: "node_002",
    which: "end",
  });
  assert.equal(result.imageStatus, "pending");
  assert.equal(result.imageUrl, "https://cdn.example/e2.png");
  assert.equal(result.endHash, "hash-e2");
  assert.deepEqual(result.desyncedNodeIds, []);
  const node = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(node.data()?.endImageStatus, "pending");
  assert.equal(node.data()?.endImageApproved, false);
  assert.equal(node.data()?.endHash, "hash-e2");
});

test("ready E resets approval and desyncs children", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeImageWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_001", which: "end"},
    mockDeps()
  );
  const expectedHash = sha8("still:Vertical still, Gate, no text.");
  assert.equal(result.imageStatus, "ready");
  assert.equal(result.endHash, expectedHash);
  assert.equal(result.imageUrl, `https://cdn.example/${expectedHash}.png`);
  assert.deepEqual(result.desyncedNodeIds, ["node_002"]);

  const parent = await db.doc("stories/story_draft/nodes/node_001").get();
  assert.equal(parent.data()?.endImageApproved, false);
  assert.equal(parent.data()?.videoStatus, "idle");
  assert.equal(parent.data()?.videoUrl, null);

  const child = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(child.data()?.videoStatus, "idle");
  assert.equal(child.data()?.videoUrl, null);
  assert.equal(child.data()?.startParentEndHash, "hash-e1");
  assert.notEqual(child.data()?.startParentEndHash, expectedHash);
});

test("approve needs a generated frame; reject un-approves", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await rejectsWith(
    approveNodeImageWith(db, "u1", {
      storyId: "story_draft",
      nodeId: "node_002",
      which: "start",
    }),
    "failed-precondition"
  );
  const approved = await approveNodeImageWith(db, "u1", {
    storyId: "story_draft",
    nodeId: "node_001",
    which: "end",
  });
  assert.deepEqual(approved, {
    nodeId: "node_001",
    which: "end",
    approved: true,
  });
  const rejected = await approveNodeImageWith(db, "u1", {
    storyId: "story_draft",
    nodeId: "node_001",
    which: "end",
    approved: false,
  });
  assert.equal(rejected.approved, false);
  const node = await db.doc("stories/story_draft/nodes/node_001").get();
  assert.equal(node.data()?.endImageApproved, false);
});

test("video is gated on the unapproved parent E without writing", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_001").set(
    {endImageApproved: false},
    {merge: true}
  );
  const before = snapshot(db);
  await rejectsWith(
    generateNodeVideoWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_002"},
      mockDeps()
    ),
    "failed-precondition"
  );
  assert.equal(snapshot(db), before);
});

test("root video is gated on its own unapproved S", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_001").set(
    {startImageApproved: false},
    {merge: true}
  );
  await rejectsWith(
    generateNodeVideoWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_001"},
      mockDeps()
    ),
    "failed-precondition"
  );
});

test("video inherits the parent E as S and records a pending job", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeVideoWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_002"},
    mockDeps()
  );
  assert.equal(result.videoStatus, "pending");
  assert.equal(result.videoFromHash, "hash-e1");
  assert.equal(result.videoToHash, "hash-e2");
  assert.equal(result.videoJobId, "pending_node_002_1234");
  assert.equal(result.videoUrl, null);
  const child = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(child.data()?.startParentEndHash, "hash-e1");
  assert.equal(
    child.data()?.startImageSourceUrl,
    "https://cdn.example/e1.png"
  );
  assert.equal(child.data()?.videoStatus, "pending");
});

test("video marks ready when the provider returns a URL", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeVideoWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_001"},
    mockDeps({
      requestVideo: async () => ({
        jobId: "seedance-8",
        videoUrl: "https://cdn.example/v-new.mp4",
      }),
    })
  );
  assert.equal(result.videoStatus, "ready");
  assert.equal(result.videoFromHash, "hash-s1");
  assert.equal(result.videoToHash, "hash-e1");
  assert.equal(result.videoUrl, "https://cdn.example/v-new.mp4");
});

test("video needs the node E generated first", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_002").set(
    {endHash: null, endImageSourceUrl: null},
    {merge: true}
  );
  await rejectsWith(
    generateNodeVideoWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_002"},
      mockDeps()
    ),
    "failed-precondition"
  );
});

test("re-inheriting after a regen re-links the child", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const regen = await generateNodeImageWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_001", which: "end"},
    mockDeps()
  );
  assert.deepEqual(regen.desyncedNodeIds, ["node_002"]);
  await approveNodeImageWith(db, "u1", {
    storyId: "story_draft",
    nodeId: "node_001",
    which: "end",
  });
  const video = await generateNodeVideoWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_002"},
    mockDeps({
      requestVideo: async () => ({jobId: "seedance-9"}),
    })
  );
  assert.equal(video.videoFromHash, regen.endHash);
  const child = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(child.data()?.startParentEndHash, regen.endHash);
  assert.equal(child.data()?.videoStatus, "pending");
});
