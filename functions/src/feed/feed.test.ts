import {strict as assert} from "assert";
import {test} from "node:test";
import {commitChoiceWith} from "./commitChoice";
import {loadPlaybackWith} from "./loadPlayback";
import {Db, DbCol, DbDoc, DbRef, DbTx, rewardCodeFor} from "./shared";
import {startRunWith} from "./startRun";

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

/** In-memory collection with chained filters, like a Firestore query. */
class MemCol implements DbCol {
  private filters: Array<(fields: Fields) => boolean> = [];
  private order?: {field: string; dir: "asc" | "desc"};
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
   * @param {string} field Field name.
   * @param {string} dir Sort direction.
   * @return {DbCol} The ordered query.
   */
  orderBy(field: string, dir: "asc" | "desc" = "asc"): DbCol {
    const next = this.child();
    next.order = {field, dir};
    return next;
  }

  /**
   * @param {number} n Max docs.
   * @return {DbCol} The limited query.
   */
  limit(n: number): DbCol {
    const next = this.child();
    next.take = n;
    return next;
  }

  /** @return {Promise<Object>} The matches. */
  async get(): Promise<{empty: boolean; docs: DbDoc[]}> {
    const prefix = `${this.path}/`;
    let docs = [...this.db.store.entries()]
      .filter(([path]) => {
        return (
          path.startsWith(prefix) && !path.slice(prefix.length).includes("/")
        );
      })
      .map(([path, fields]) => {
        return new MemDoc(true, path.slice(prefix.length), fields);
      });
    for (const match of this.filters) {
      docs = docs.filter((doc) => match(doc.data() ?? {}));
    }
    if (this.order) {
      const {field, dir} = this.order;
      const sign = dir === "desc" ? -1 : 1;
      docs = [...docs].sort((a, b) => {
        const left = String(a.data()?.[field] ?? "");
        const right = String(b.data()?.[field] ?? "");
        return left < right ? -sign : left > right ? sign : 0;
      });
    }
    if (this.take !== undefined) docs = docs.slice(0, this.take);
    return {empty: docs.length === 0, docs};
  }

  /** @return {MemCol} The forked query. */
  private child(): MemCol {
    const next = new MemCol(this.db, this.path);
    next.filters = [...this.filters];
    next.order = this.order;
    next.take = this.take;
    return next;
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

const seed = async (db: MemDb): Promise<void> => {
  await db.doc("users/u1").set({displayName: "Alex Vance"});
  await db.doc("stories/story_a").set({
    authorId: "u1",
    title: "Story A",
    status: "published",
    rootNodeId: "node_001",
    featured: true,
  });
  await db.doc("stories/story_b").set({
    authorId: "u1",
    title: "Story B",
    status: "published",
    rootNodeId: "node_b01",
  });
  await db.doc("sagas/saga_ab").set({
    authorId: "u1",
    title: "Saga AB",
    storyIds: ["story_a", "story_b"],
    unlocks: [
      {
        fromStoryId: "story_a",
        endingNodeId: "node_002",
        toStoryId: "story_b",
      },
    ],
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
        {
          choiceId: "choice_far",
          label: "Go far",
          targetNodeId: "node_004",
          isDefault: false,
          x: 0.7,
          y: 0.4,
          radius: 0.15,
        },
      ],
    })
  );
  await db.doc("stories/story_a/nodes/node_004").set(
    nodeFields({
      title: "The overlook",
      isEnding: true,
      endingName: "The overlook",
      endingType: "secreto",
      videoUrl: "https://example.com/end_far.mp4",
      choices: [],
    })
  );
  await db.doc("stories/story_b/nodes/node_b01").set(
    nodeFields({
      title: "Story B root",
      choices: [
        {
          choiceId: "choice_rest",
          label: "Rest",
          targetNodeId: "node_b02",
          isDefault: true,
          x: 0.5,
          y: 0.5,
          radius: 0.2,
        },
      ],
    })
  );
  await db.doc("stories/story_b/nodes/node_b02").set(
    nodeFields({
      title: "Story B end",
      isEnding: true,
      endingName: "Rest",
      endingType: "abierto",
      videoUrl: "https://example.com/end_b.mp4",
      choices: [],
    })
  );
};

interface CallableError {
  code?: unknown;
}

const codeOf = async (run: () => Promise<unknown>): Promise<string> => {
  try {
    await run();
  } catch (error) {
    return String((error as CallableError).code ?? error);
  }
  return "no-throw";
};

test("startRun creates a run at the root and marks it state", async () => {
  const db = new MemDb();
  await seed(db);
  const started = await startRunWith(db, "u1", {});
  assert.equal(started.storyId, "story_a");
  assert.equal(started.status, "active");
  const run = db.store.get(`users/u1/runs/${started.runId}`);
  assert.equal(run?.currentNodeId, "node_001");
  assert.deepEqual(run?.choices, []);
  const state = db.store.get("users/u1/storyState/story_a");
  assert.equal(state?.activeRunId, started.runId);
  assert.deepEqual(state?.visitedNodeIds, ["node_001"]);
});

test("startRun without stories fails", async () => {
  const db = new MemDb();
  assert.equal(
    await codeOf(() => startRunWith(db, "u1", {})),
    "failed-precondition"
  );
});

test("startRun resumes the active run", async () => {
  const db = new MemDb();
  await seed(db);
  const first = await startRunWith(db, "u1", {});
  const second = await startRunWith(db, "u1", {});
  assert.equal(second.runId, first.runId);
  assert.equal(
    [...db.store.keys()].filter((key) => key.includes("/runs/")).length,
    1
  );
});

test("startRun with restart keeps the old run active", async () => {
  const db = new MemDb();
  await seed(db);
  const first = await startRunWith(db, "u1", {});
  const second = await startRunWith(db, "u1", {restart: true});
  assert.notEqual(second.runId, first.runId);
  assert.equal(db.store.get(`users/u1/runs/${first.runId}`)?.status, "active");
  assert.equal(
    db.store.get("users/u1/storyState/story_a")?.activeRunId,
    second.runId
  );
});

test("startRun rejects a foreign draft", async () => {
  const db = new MemDb();
  await seed(db);
  await db.doc("stories/story_draft").set({
    authorId: "u2",
    title: "Draft",
    status: "draft",
    rootNodeId: "node_001",
  });
  assert.equal(
    await codeOf(() => startRunWith(db, "u1", {storyId: "story_draft"})),
    "permission-denied"
  );
});

test("loadPlayback returns the contract with secrets hidden", async () => {
  const db = new MemDb();
  await seed(db);
  const started = await startRunWith(db, "u1", {});
  const playback = await loadPlaybackWith(db, "u1", {runId: started.runId});
  assert.equal(playback.story.title, "Story A");
  assert.equal(playback.story.authorName, "Alex Vance");
  assert.equal(playback.choices.length, 2);
  assert.deepEqual(playback.choices[0].target, {
    nodeId: "node_002",
    videoUrl: "https://example.com/end.mp4",
  });
  assert.equal(playback.choices[0].targetSecret, false);
  assert.equal(playback.choices[1].targetSecret, true);
  assert.equal(playback.choices[1].target, null);
});

test("loadPlayback rejects another user's run", async () => {
  const db = new MemDb();
  await seed(db);
  await db.doc("users/u2/runs/run_x").set({
    storyId: "story_a",
    status: "active",
    currentNodeId: "node_001",
  });
  assert.equal(
    await codeOf(() => loadPlaybackWith(db, "u1", {runId: "run_x"})),
    "not-found"
  );
});

test("commitChoice advances, counts, visits, and ends", async () => {
  const db = new MemDb();
  await seed(db);
  const started = await startRunWith(db, "u1", {});
  const result = await commitChoiceWith(db, "u1", {
    runId: started.runId,
    fromNodeId: "node_001",
    choiceId: "choice_temple",
    requestId: "req_1",
  });
  assert.equal(result.playback.node.nodeId, "node_002");
  assert.equal(result.playback.status, "ended");
  assert.deepEqual(result.ending, {
    storyId: "story_a",
    nodeId: "node_002",
    endingName: "The door",
    endingType: "abierto",
  });
  assert.deepEqual(result.sagaUnlocked, {
    sagaId: "saga_ab",
    storyId: "story_b",
    title: "Story B",
  });
  assert.deepEqual(result.reward, {
    rewardId: "story_a_node_002",
    code: rewardCodeFor("u1", "story_a", "node_002"),
  });
  const run = db.store.get(`users/u1/runs/${started.runId}`);
  assert.equal(run?.status, "ended");
  assert.equal(run?.endingNodeId, "node_002");
  const history = run?.choices as Array<Record<string, unknown>>;
  assert.equal(history.length, 1);
  assert.equal(typeof history[0].at, "string");
  assert.deepEqual({...history[0], at: "at"}, {
    nodeId: "node_001",
    choiceId: "choice_temple",
    targetNodeId: "node_002",
    requestId: "req_1",
    at: "at",
  });
  assert.deepEqual(
    db.store.get("stories/story_a/nodes/node_001")?.choiceCounts,
    {choice_temple: 1}
  );
  const state = db.store.get("users/u1/storyState/story_a");
  assert.deepEqual(state?.visitedNodeIds, ["node_001", "node_002"]);
  assert.equal(state?.activeRunStatus, "ended");
  assert.deepEqual(state?.endings, ["node_002"]);
  assert.equal(
    db.store.get("users/u1/storyState/story_b")?.sagaUnlocked,
    true
  );
  assert.equal(
    db.store.get("users/u1/rewards/story_a_node_002")?.storyId,
    "story_a"
  );
  assert.equal(
    db.store.get("users/u1/rewards/story_a_node_002")?.endingNodeId,
    "node_002"
  );
});

test("commitChoice replays the same requestId", async () => {
  const db = new MemDb();
  await seed(db);
  const started = await startRunWith(db, "u1", {});
  const payload = {
    runId: started.runId,
    fromNodeId: "node_001",
    choiceId: "choice_temple",
    requestId: "req_1",
  };
  const first = await commitChoiceWith(db, "u1", payload);
  const second = await commitChoiceWith(db, "u1", payload);
  assert.deepEqual(second, first);
  const replayed = db.store.get(`users/u1/runs/${started.runId}`)?.choices;
  assert.equal((replayed as unknown[]).length, 1);
  assert.deepEqual(
    db.store.get("stories/story_a/nodes/node_001")?.choiceCounts,
    {choice_temple: 1}
  );
  assert.deepEqual(
    db.store.get("users/u1/storyState/story_a")?.endings,
    ["node_002"]
  );
  assert.equal(
    [...db.store.keys()].filter((key) => key.startsWith("users/u1/rewards/"))
      .length,
    1
  );
});

test("commitChoice rejects a stale node", async () => {
  const db = new MemDb();
  await seed(db);
  const started = await startRunWith(db, "u1", {});
  await commitChoiceWith(db, "u1", {
    runId: started.runId,
    fromNodeId: "node_001",
    choiceId: "choice_temple",
    requestId: "req_1",
  });
  assert.equal(
    await codeOf(() =>
      commitChoiceWith(db, "u1", {
        runId: started.runId,
        fromNodeId: "node_001",
        choiceId: "choice_temple",
        requestId: "req_2",
      })
    ),
    "invalid-argument"
  );
});

test("commitChoice rejects an unknown choice", async () => {
  const db = new MemDb();
  await seed(db);
  const started = await startRunWith(db, "u1", {});
  assert.equal(
    await codeOf(() =>
      commitChoiceWith(db, "u1", {
        runId: started.runId,
        fromNodeId: "node_001",
        choiceId: "choice_nope",
        requestId: "req_1",
      })
    ),
    "invalid-argument"
  );
});

test("commitChoice keeps a non-ending run active", async () => {
  const db = new MemDb();
  await seed(db);
  const started = await startRunWith(db, "u1", {restart: true});
  const result = await commitChoiceWith(db, "u1", {
    runId: started.runId,
    fromNodeId: "node_001",
    choiceId: "choice_ridge",
    requestId: "req_1",
  });
  assert.equal(result.playback.node.nodeId, "node_003");
  assert.equal(result.playback.status, "active");
  assert.equal(result.playback.choices[0].targetSecret, false);
});

test("commitChoice re-earn after restart unlocks nothing twice", async () => {
  const db = new MemDb();
  await seed(db);
  const first = await startRunWith(db, "u1", {});
  await commitChoiceWith(db, "u1", {
    runId: first.runId,
    fromNodeId: "node_001",
    choiceId: "choice_temple",
    requestId: "req_1",
  });
  const second = await startRunWith(db, "u1", {restart: true});
  const reEarned = await commitChoiceWith(db, "u1", {
    runId: second.runId,
    fromNodeId: "node_001",
    choiceId: "choice_temple",
    requestId: "req_2",
  });
  assert.equal(reEarned.playback.status, "ended");
  assert.equal(reEarned.ending?.nodeId, "node_002");
  assert.equal(reEarned.sagaUnlocked, null);
  assert.deepEqual(reEarned.reward, {
    rewardId: "story_a_node_002",
    code: rewardCodeFor("u1", "story_a", "node_002"),
  });
  assert.deepEqual(
    db.store.get("users/u1/storyState/story_a")?.endings,
    ["node_002"]
  );
  assert.equal(
    [...db.store.keys()].filter((key) => key.startsWith("users/u1/rewards/"))
      .length,
    1
  );
  assert.equal(
    db.store.get("users/u1/rewards/story_a_node_002")?.requestId,
    "req_1"
  );
});

test("commitChoice wrong ending opens no saga story", async () => {
  const db = new MemDb();
  await seed(db);
  const started = await startRunWith(db, "u1", {});
  await commitChoiceWith(db, "u1", {
    runId: started.runId,
    fromNodeId: "node_001",
    choiceId: "choice_ridge",
    requestId: "req_1",
  });
  const result = await commitChoiceWith(db, "u1", {
    runId: started.runId,
    fromNodeId: "node_003",
    choiceId: "choice_far",
    requestId: "req_2",
  });
  assert.equal(result.playback.status, "ended");
  assert.deepEqual(result.ending, {
    storyId: "story_a",
    nodeId: "node_004",
    endingName: "The overlook",
    endingType: "secreto",
  });
  assert.equal(result.sagaUnlocked, null);
  assert.deepEqual(result.reward, {
    rewardId: "story_a_node_004",
    code: rewardCodeFor("u1", "story_a", "node_004"),
  });
  assert.deepEqual(
    db.store.get("users/u1/storyState/story_a")?.endings,
    ["node_004"]
  );
  assert.equal(db.store.get("users/u1/storyState/story_b"), undefined);
});

test("commitChoice off the ending path writes no saga or reward", async () => {
  const db = new MemDb();
  await seed(db);
  const started = await startRunWith(db, "u1", {restart: true});
  const result = await commitChoiceWith(db, "u1", {
    runId: started.runId,
    fromNodeId: "node_001",
    choiceId: "choice_ridge",
    requestId: "req_1",
  });
  assert.equal(result.playback.status, "active");
  assert.equal(result.ending, null);
  assert.equal(result.sagaUnlocked, null);
  assert.equal(result.reward, null);
  assert.equal(
    db.store.get("users/u1/storyState/story_a")?.endings,
    undefined
  );
  assert.equal(
    [...db.store.keys()].filter((key) => key.startsWith("users/u1/rewards/"))
      .length,
    0
  );
});

test("commitChoice mints the code once", async () => {
  const db = new MemDb();
  await seed(db);
  const started = await startRunWith(db, "u1", {});
  const earned = await commitChoiceWith(db, "u1", {
    runId: started.runId,
    fromNodeId: "node_001",
    choiceId: "choice_temple",
    requestId: "req_1",
  });
  const code = rewardCodeFor("u1", "story_a", "node_002");
  assert.deepEqual(earned.reward, {rewardId: "story_a_node_002", code});
  assert.deepEqual(earned.sagaUnlocked, {
    sagaId: "saga_ab",
    storyId: "story_b",
    title: "Story B",
  });
  assert.equal(earned.playback.node.rewardCode, code);
  assert.equal(earned.playback.reward?.code, code);
  assert.equal(db.store.get("users/u1/rewards/story_a_node_002")?.code, code);

  // Reopening the ended run reads the same code and writes nothing new.
  const before = db.store.size;
  const reopened = await loadPlaybackWith(db, "u1", {runId: started.runId});
  assert.equal(reopened.status, "ended");
  assert.equal(reopened.node.rewardCode, code);
  assert.deepEqual(reopened.reward, {rewardId: "story_a_node_002", code});
  assert.equal(db.store.size, before);

  // Same-request replay and a fresh-request re-earn never reissue.
  const replayed = await commitChoiceWith(db, "u1", {
    runId: started.runId,
    fromNodeId: "node_001",
    choiceId: "choice_temple",
    requestId: "req_1",
  });
  assert.equal(replayed.reward?.code, code);
  assert.equal(replayed.playback.node.rewardCode, code);
  // Stored outcomes from before the code and title existed complete both.
  const legacyRun = db.store.get(`users/u1/runs/${started.runId}`);
  const legacyLast = legacyRun?.lastCommit as Record<string, unknown>;
  const legacyOutcome = legacyLast?.outcome as Record<string, unknown>;
  legacyLast.outcome = {
    ...legacyOutcome,
    reward: {rewardId: "story_a_node_002"},
    sagaUnlocked: {sagaId: "saga_ab", storyId: "story_b"},
  };
  const legacyReplay = await commitChoiceWith(db, "u1", {
    runId: started.runId,
    fromNodeId: "node_001",
    choiceId: "choice_temple",
    requestId: "req_1",
  });
  assert.equal(legacyReplay.reward?.code, code);
  assert.deepEqual(legacyReplay.sagaUnlocked, {
    sagaId: "saga_ab",
    storyId: "story_b",
    title: "Story B",
  });
  const restarted = await startRunWith(db, "u1", {restart: true});
  const reEarned = await commitChoiceWith(db, "u1", {
    runId: restarted.runId,
    fromNodeId: "node_001",
    choiceId: "choice_temple",
    requestId: "req_2",
  });
  assert.equal(reEarned.reward?.code, code);
  assert.equal(
    db.store.get("users/u1/rewards/story_a_node_002")?.code,
    code
  );
  assert.equal(
    [...db.store.keys()].filter((key) => key.startsWith("users/u1/rewards/"))
      .length,
    1
  );
});
