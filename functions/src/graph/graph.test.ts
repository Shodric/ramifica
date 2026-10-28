import {strict as assert} from "assert";
import {test} from "node:test";
import {commitChoiceWith} from "../feed/commitChoice";
import {
  Db,
  DbCol,
  DbDoc,
  DbRef,
  DbTx,
  requireUid,
} from "../feed/shared";
import {startRunWith} from "../feed/startRun";
import {graphStubsWith} from "./graphStubs";
import {playApproachWith} from "./playApproach";
import {rewindRunWith} from "./rewindRun";

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

/** In-memory collection listing its direct children. */
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
   * @return {DbCol} This collection; filters are unused here.
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
   * @return {DbCol} This collection; order is unused here.
   */
  orderBy(field: string, dir: "asc" | "desc" = "asc"): DbCol {
    void field;
    void dir;
    return this;
  }

  /**
   * @param {number} n Max docs.
   * @return {DbCol} This collection; limits are unused here.
   */
  limit(n: number): DbCol {
    void n;
    return this;
  }

  /** @return {Promise<Object>} The direct children. */
  async get(): Promise<{empty: boolean; docs: DbDoc[]}> {
    const prefix = `${this.path}/`;
    const docs = [...this.db.store.entries()]
      .filter(([path]) => {
        return (
          path.startsWith(prefix) && !path.slice(prefix.length).includes("/")
        );
      })
      .map(([path, fields]) => {
        return new MemDoc(true, path.slice(prefix.length), fields);
      });
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
 * @param {Fields} overrides Field overrides.
 * @return {Fields} A playable node.
 */
const nodeFields = (overrides: Fields = {}): Fields => ({
  title: "Node",
  visibility: "visible",
  isEnding: false,
  videoUrl: "https://example.com/video.mp4",
  durationSeconds: 10,
  pauseAtSeconds: 9.967,
  windowSeconds: 6,
  videoFrameLastBlurData: "data:image/webp;base64,abc",
  ...overrides,
});

/** Seeds a three-node story: root, ending, and a secret middle.
 * @param {MemDb} db Backing store.
 */
const seed = async (db: MemDb): Promise<void> => {
  await db.doc("users/u1").set({displayName: "Alex Vance"});
  await db.doc("stories/story_a").set({
    authorId: "u1",
    title: "Story A",
    status: "published",
    rootNodeId: "node_001",
    featured: true,
  });
  await db.doc("stories/story_a/nodes/node_001").set(
    nodeFields({
      title: "The temple door",
      choices: [
        {
          choiceId: "choice_temple",
          label: "Enter the temple",
          targetNodeId: "node_002",
          isDefault: true,
          x: 0.25,
          y: 0.65,
          radius: 0.15,
        },
        {
          choiceId: "choice_ridge",
          label: "Climb the ridge",
          targetNodeId: "node_003",
          isDefault: false,
          x: 0.75,
          y: 0.7,
          radius: 0.15,
        },
      ],
    })
  );
  await db.doc("stories/story_a/nodes/node_002").set(
    nodeFields({
      title: "The last door",
      isEnding: true,
      endingName: "The door",
      endingType: "abierto",
      videoUrl: "https://example.com/end.mp4",
      choices: [],
    })
  );
  await db.doc("stories/story_a/nodes/node_003").set(
    nodeFields({
      title: "The ridge",
      visibility: "secret",
      choices: [
        {
          choiceId: "choice_on",
          label: "Go on",
          targetNodeId: "node_002",
          isDefault: true,
          x: 0.5,
          y: 0.5,
          radius: 0.2,
        },
      ],
    })
  );
  await db.doc("stories/story_a/nodes/node_004").set(
    nodeFields({
      title: "The overlook",
      choices: [
        {
          choiceId: "choice_down",
          label: "Climb down",
          targetNodeId: "node_002",
          isDefault: true,
          x: 0.5,
          y: 0.5,
          radius: 0.2,
        },
      ],
    })
  );
};

interface CallableError {
  code?: unknown;
}

/**
 * @param {Function} run Failing call.
 * @return {Promise<string>} The `HttpsError` code, or `no-throw`.
 */
const codeOf = async (run: () => Promise<unknown>): Promise<string> => {
  try {
    await run();
  } catch (error) {
    return String((error as CallableError).code ?? error);
  }
  return "no-throw";
};

/**
 * @param {MemDb} db Backing store.
 * @return {Promise<string>} A run id at the story root.
 */
const startAtRoot = async (db: MemDb): Promise<string> => {
  const started = await startRunWith(db, "u1", {storyId: "story_a"});
  return started.runId;
};

test("graphStubs lists every node, hiding unvisited secrets", async () => {
  const db = new MemDb();
  await seed(db);
  const runId = await startAtRoot(db);
  const stubs = await graphStubsWith(db, "u1", {
    storyId: "story_a",
    runId,
  });
  assert.equal(stubs.currentNodeId, "node_001");
  assert.equal(stubs.nodes.length, 4);
  const root = stubs.nodes.find((node) => node.nodeId === "node_001");
  assert.equal(root?.title, "The temple door");
  assert.equal(root?.visited, true);
  assert.equal(root?.secret, false);
  assert.equal(root?.isEnding, false);
  assert.equal(root?.choiceCount, 0);
  assert.deepEqual(root?.childIds, ["node_002", "node_003"]);
  assert.deepEqual(root?.choices, [
    {choiceId: "choice_temple", label: "Enter the temple", count: 0},
    {choiceId: "choice_ridge", label: "Climb the ridge", count: 0},
  ]);
  const secret = stubs.nodes.find((node) => node.nodeId === "node_003");
  assert.deepEqual(secret, {
    nodeId: "node_003",
    title: null,
    isEnding: false,
    visited: false,
    secret: true,
  });
  const ending = stubs.nodes.find((node) => node.nodeId === "node_002");
  assert.equal(ending?.title, "The last door");
  assert.equal(ending?.visited, false);
  assert.equal(ending?.choices, undefined);
  const far = stubs.nodes.find((node) => node.nodeId === "node_004");
  assert.equal(far?.title, "The overlook");
  assert.equal(far?.visited, false);
  assert.deepEqual(far?.childIds, ["node_002"]);
  assert.equal(far?.choices, undefined);
});

test("graphStubs counts each exit of visited nodes", async () => {
  const db = new MemDb();
  await seed(db);
  const runId = await startAtRoot(db);
  await commitChoiceWith(db, "u1", {
    runId,
    fromNodeId: "node_001",
    choiceId: "choice_ridge",
    requestId: "req_1",
  });
  const stubs = await graphStubsWith(db, "u1", {
    storyId: "story_a",
    runId,
  });
  const root = stubs.nodes.find((node) => node.nodeId === "node_001");
  assert.deepEqual(root?.choices, [
    {choiceId: "choice_temple", label: "Enter the temple", count: 0},
    {choiceId: "choice_ridge", label: "Climb the ridge", count: 1},
  ]);
  assert.equal(stubs.currentNodeId, "node_003");
  const secret = stubs.nodes.find((node) => node.nodeId === "node_003");
  assert.equal(secret?.title, "The ridge");
  assert.equal(secret?.visited, true);
  assert.equal(secret?.secret, true);
  assert.deepEqual(secret?.childIds, ["node_002"]);
  assert.deepEqual(secret?.choices, [
    {choiceId: "choice_on", label: "Go on", count: 0},
  ]);
});

test("graphStubs rejects a foreign run", async () => {
  const db = new MemDb();
  await seed(db);
  await db.doc("users/u2/runs/run_x").set({
    storyId: "story_a",
    status: "active",
    currentNodeId: "node_001",
  });
  assert.equal(
    await codeOf(() =>
      graphStubsWith(db, "u1", {storyId: "story_a", runId: "run_x"})
    ),
    "not-found"
  );
});

test("graphStubs rejects a mismatched story", async () => {
  const db = new MemDb();
  await seed(db);
  const runId = await startAtRoot(db);
  assert.equal(
    await codeOf(() =>
      graphStubsWith(db, "u1", {storyId: "story_b", runId})
    ),
    "invalid-argument"
  );
});

test("graph callables require sign-in", async () => {
  assert.equal(
    await codeOf(async () => requireUid(undefined)),
    "unauthenticated"
  );
  assert.equal(
    await codeOf(async () => requireUid({})),
    "unauthenticated"
  );
});

test("playApproach replays the parent without touching history", async () => {
  const db = new MemDb();
  await seed(db);
  const runId = await startAtRoot(db);
  await commitChoiceWith(db, "u1", {
    runId,
    fromNodeId: "node_001",
    choiceId: "choice_temple",
    requestId: "req_1",
  });
  const playback = await playApproachWith(db, "u1", {
    runId,
    nodeId: "node_002",
  });
  assert.equal(playback.node.nodeId, "node_001");
  assert.equal(playback.status, "ended");
  const run = db.store.get(`users/u1/runs/${runId}`);
  assert.equal(run?.currentNodeId, "node_002");
  assert.equal(run?.status, "ended");
  assert.equal((run?.choices as unknown[]).length, 1);
});

test("playApproach rejects the root and unknown nodes", async () => {
  const db = new MemDb();
  await seed(db);
  const runId = await startAtRoot(db);
  assert.equal(
    await codeOf(() => playApproachWith(db, "u1", {runId, nodeId: "node_001"})),
    "failed-precondition"
  );
  assert.equal(
    await codeOf(() => playApproachWith(db, "u1", {runId, nodeId: "nope"})),
    "not-found"
  );
});

test("playApproach rejects a foreign run", async () => {
  const db = new MemDb();
  await seed(db);
  await db.doc("users/u2/runs/run_x").set({
    storyId: "story_a",
    status: "active",
    currentNodeId: "node_001",
  });
  assert.equal(
    await codeOf(() =>
      playApproachWith(db, "u1", {runId: "run_x", nodeId: "node_001"})
    ),
    "not-found"
  );
});

test("rewindRun steps an ended run back to its parent", async () => {
  const db = new MemDb();
  await seed(db);
  const runId = await startAtRoot(db);
  await commitChoiceWith(db, "u1", {
    runId,
    fromNodeId: "node_001",
    choiceId: "choice_temple",
    requestId: "req_1",
  });
  const playback = await rewindRunWith(db, "u1", {runId});
  assert.equal(playback.node.nodeId, "node_001");
  assert.equal(playback.status, "active");
  const run = db.store.get(`users/u1/runs/${runId}`);
  assert.equal(run?.currentNodeId, "node_001");
  assert.equal(run?.status, "active");
  assert.equal((run?.choices as unknown[]).length, 1);
  assert.equal(
    db.store.get("users/u1/storyState/story_a")?.activeRunStatus,
    "active"
  );
});

test("rewindRun walks a two-hop trail one step at a time", async () => {
  const db = new MemDb();
  await seed(db);
  const runId = await startAtRoot(db);
  await commitChoiceWith(db, "u1", {
    runId,
    fromNodeId: "node_001",
    choiceId: "choice_ridge",
    requestId: "req_1",
  });
  await commitChoiceWith(db, "u1", {
    runId,
    fromNodeId: "node_003",
    choiceId: "choice_on",
    requestId: "req_2",
  });
  const first = await rewindRunWith(db, "u1", {runId});
  assert.equal(first.node.nodeId, "node_003");
  const second = await rewindRunWith(db, "u1", {runId});
  assert.equal(second.node.nodeId, "node_001");
  const run = db.store.get(`users/u1/runs/${runId}`);
  assert.equal(run?.currentNodeId, "node_001");
  assert.equal((run?.choices as unknown[]).length, 2);
});

test("rewindRun at the root fails", async () => {
  const db = new MemDb();
  await seed(db);
  const runId = await startAtRoot(db);
  assert.equal(await codeOf(() => rewindRunWith(db, "u1", {runId})),
    "failed-precondition");
});

test("rewindRun rejects a foreign run", async () => {
  const db = new MemDb();
  await seed(db);
  await db.doc("users/u2/runs/run_x").set({
    storyId: "story_a",
    status: "active",
    currentNodeId: "node_001",
  });
  assert.equal(
    await codeOf(() => rewindRunWith(db, "u1", {runId: "run_x"})),
    "not-found"
  );
});
