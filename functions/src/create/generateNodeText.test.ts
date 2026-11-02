import {knownIcons, knownIconColors} from "./proposeOutline";
import {strict as assert} from "assert";
import * as fs from "fs";
import {test} from "node:test";
import * as path from "path";
import {Db, DbCol, DbDoc, DbRef, DbTx} from "../feed/shared";
import {
  generateNodeTextWith,
  GenerateNodeTextResult,
  knownChoiceIconColors,
  knownChoiceIcons,
  TextFetch,
} from "./generateNodeText";

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

/** In-memory collection: only doc() is needed for the text path. */
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
   * Unused stub: text tests never query.
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
   * Unused stub: text tests never query.
   * @param {string} field Field name.
   * @param {string} dir Sort direction.
   */
  orderBy(field: string, dir: "asc" | "desc" = "asc"): DbCol {
    void field;
    void dir;
    throw new Error("MemCol.orderBy is not stubbed.");
  }

  /**
   * Unused stub: text tests never query.
   * @param {number} n Max docs.
   */
  limit(n: number): DbCol {
    void n;
    throw new Error("MemCol.limit is not stubbed.");
  }

  /** @return {Promise<Object>} Never resolves; text tests never query. */
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
 * @return {TextFetch} The stub transport.
 */
const stubFetch = (content: unknown): TextFetch => {
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
 * @return {TextFetch} The stub transport.
 */
const failingFetch = (status: number): TextFetch => {
  return async () => ({
    ok: false,
    status,
    json: async () => ({}),
    arrayBuffer: async () => new ArrayBuffer(0),
  });
};

/**
 * Snapshot of every doc, to prove the proposal path never writes.
 * @param {MemDb} db Backing store.
 * @return {string} The serialized store.
 */
const snapshot = (db: MemDb): string => {
  return JSON.stringify([...db.store.entries()]);
};

/**
 * One author-owned draft with a decision node and an ending node.
 * @param {MemDb} db Backing store to seed.
 * @return {Promise<void>} When the seed is written.
 */
const seedDraft = async (db: MemDb): Promise<void> => {
  await db.doc("stories/story_draft").set({
    authorId: "u1",
    title: "The temple",
    synopsis: "A door, a ridge, a choice.",
    status: "draft",
    rootNodeId: "node_001",
  });
  await db.doc("stories/story_draft/nodes/node_001").set({
    title: "Old title",
    isEnding: false,
    ttsText: "Old line.",
    choices: [{choiceId: "c1", label: "Old label", targetNodeId: "node_002"}],
  });
  await db.doc("stories/story_draft/nodes/node_002").set({
    title: "The end",
    isEnding: true,
    ttsText: "",
    choices: [],
  });
  await db.doc("stories/story_draft/nodes/node_003").set({
    title: "The fork",
    isEnding: false,
    ttsText: "",
    choices: [],
    startFromNodeId: "node_001",
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

test("proposes decision text without writing", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const before = snapshot(db);
  const result: GenerateNodeTextResult = await generateNodeTextWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_001", prompt: "A storm arrives."},
    {
      apiKey: "test-key",
      fetchFn: stubFetch(
        JSON.stringify({
          title: "The storm door",
          ttsText: "Thunder rolls. Do you enter, or climb?",
          choices: [{label: "Enter"}, {label: "Climb"}],
          endingName: null,
        })
      ),
    }
  );
  assert.equal(result.title, "The storm door");
  assert.equal(result.ttsText, "Thunder rolls. Do you enter, or climb?");
  assert.deepEqual(result.choices, [
    {label: "Enter", icon: null, iconColor: null},
    {label: "Climb", icon: null, iconColor: null},
  ]);
  assert.equal(result.endingName, null);
  assert.equal(result.startImagePrompt, null);
  assert.equal(result.videoPrompt, null);
  assert.equal(snapshot(db), before);
});

test("scene purpose includes the narrator line", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeTextWith(
    db, "u1",
    {storyId: "story_draft", nodeId: "node_001", purpose: "scene"},
    {apiKey: "test", fetchFn: stubFetch(JSON.stringify({
      title: "The gate", ttsText: "You must choose.",
      choices: ["Enter", "Wait"],
    }))}
  );
  assert.equal(result.ttsText, "You must choose.");
  assert.equal(result.title, "The gate");
  assert.equal(result.choices.length, 2);
});

test("scene purpose strips volunteered choice icons", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeTextWith(
    db, "u1",
    {storyId: "story_draft", nodeId: "node_001", purpose: "scene"},
    {apiKey: "test", fetchFn: stubFetch(JSON.stringify({
      title: "The gate", ttsText: "You must choose.",
      choices: [{label: "Enter", icon: "door", iconColor: "cyan"}],
    }))}
  );
  assert.deepEqual(result.choices, [
    {label: "Enter", icon: null, iconColor: null},
  ]);
});

test("narration uses the options without changing the scene",
  async () => {
    const db = new MemDb();
    await seedDraft(db);
    await db.doc("stories/story_draft/nodes/node_001").set({
      choices: [{label: "Enter"}, {label: "Wait"}],
    }, {merge: true});
    const before = snapshot(db);
    let request = "";
    const fetchFn: TextFetch = async (url, init) => {
      request = String(init.body);
      return stubFetch(JSON.stringify({
        ttsText: "Do you enter the gate or wait?",
        title: "Unasked change", choices: ["Replace"],
      }))(url, init);
    };
    const result = await generateNodeTextWith(
      db, "u1",
      {storyId: "story_draft", nodeId: "node_001", purpose: "narration"},
      {apiKey: "test", fetchFn}
    );
    assert.match(request, /Enter \/ Wait/);
    assert.match(request, /just before/);
    assert.deepEqual(result, {
      title: null, ttsText: "Do you enter the gate or wait?", choices: [],
      endingName: null, startImagePrompt: null,
      videoPrompt: null,
    });
    assert.equal(snapshot(db), before);
  });

test("rejects unknown text purposes", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await assert.rejects(generateNodeTextWith(db, "u1", {
    storyId: "story_draft", nodeId: "node_001", purpose: "video",
  }), (error: unknown) =>
    (error as {code?: string}).code === "invalid-argument");
});

test("proposes an ending name for ending nodes", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const before = snapshot(db);
  const result = await generateNodeTextWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_002"},
    {
      apiKey: "test-key",
      fetchFn: stubFetch(
        JSON.stringify({
          title: "The quiet ridge",
          ttsText: "The wind settles.",
          choices: [],
          endingName: "Dawn",
        })
      ),
    }
  );
  assert.equal(result.endingName, "Dawn");
  assert.deepEqual(result.choices, []);
  assert.equal(result.startImagePrompt, null);
  assert.equal(result.videoPrompt, null);
  assert.equal(snapshot(db), before);
});

test("works without a nodeId for a new node", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeTextWith(
    db,
    "u1",
    {storyId: "story_draft", context: "A river crossing."},
    {
      apiKey: "test-key",
      fetchFn: stubFetch(
        JSON.stringify({title: "The crossing", ttsText: null, choices: []})
      ),
    }
  );
  assert.equal(result.title, "The crossing");
  assert.equal(result.ttsText, null);
});

test("clamps overlong provider fields", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeTextWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_001"},
    {
      apiKey: "test-key",
      fetchFn: stubFetch(
        JSON.stringify({
          title: "x".repeat(100),
          ttsText: "y".repeat(1000),
          choices: [{label: "z".repeat(100)}, {label: "ok"}, {label: "extra"}],
          endingName: null,
        })
      ),
    }
  );
  assert.equal(result.title?.length, 40);
  assert.equal(result.ttsText?.length, 280);
  assert.deepEqual(result.choices, [
    {label: "z".repeat(24), icon: null, iconColor: null},
    {label: "ok", icon: null, iconColor: null},
  ]);
});

test("rejects callers without a session", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await assert.rejects(
    generateNodeTextWith(db, "", {storyId: "story_draft"}),
    (error: unknown) =>
      (error as {code?: string}).code === "unauthenticated"
  );
});

test("rejects foreign drafts", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await assert.rejects(
    generateNodeTextWith(db, "u1", {storyId: "story_foreign"}),
    (error: unknown) =>
      (error as {code?: string}).code === "permission-denied"
  );
});

test("rejects published stories", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await assert.rejects(
    generateNodeTextWith(db, "u1", {storyId: "story_pub"}),
    (error: unknown) =>
      (error as {code?: string}).code === "failed-precondition"
  );
});

test("rejects unknown stories and nodes", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await assert.rejects(
    generateNodeTextWith(db, "u1", {storyId: "story_missing"}),
    (error: unknown) => (error as {code?: string}).code === "not-found"
  );
  await assert.rejects(
    generateNodeTextWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_missing"},
      {apiKey: "test-key", fetchFn: stubFetch("{}")}
    ),
    (error: unknown) => (error as {code?: string}).code === "not-found"
  );
});

test("rejects oversized prompts", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await assert.rejects(
    generateNodeTextWith(
      db,
      "u1",
      {storyId: "story_draft", prompt: "p".repeat(2001)},
      {apiKey: "test-key", fetchFn: stubFetch("{}")}
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
    generateNodeTextWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_001"},
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
    generateNodeTextWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_001"},
      {apiKey: "test-key", fetchFn: stubFetch("not json at all")}
    ),
    (error: unknown) => (error as {code?: string}).code === "internal"
  );
});

test("needs a configured provider key", async () => {
  const db = new MemDb();
  await seedDraft(db);
  delete process.env.META_API_KEY;
  await assert.rejects(
    generateNodeTextWith(db, "u1", {storyId: "story_draft"}),
    (error: unknown) =>
      (error as {code?: string}).code === "failed-precondition"
  );
});

test("mirrors the shared icon/color catalog", async () => {
  const catalogPath = path.resolve(__dirname, "../../../catalog.json");
  const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8")) as {
    icons: string[];
    iconColors: string[];
    limits: {title: number; ttsText: number; label: number; prompt: number};
  };
  assert.deepEqual([...knownChoiceIcons], catalog.icons);
  assert.deepEqual([...knownChoiceIconColors], catalog.iconColors);
  assert.deepEqual(Object.keys(knownIcons), catalog.icons);
  assert.deepEqual(Object.keys(knownIconColors), catalog.iconColors);
  assert.equal(catalog.limits.title, 40);
  assert.equal(catalog.limits.ttsText, 280);
  assert.equal(catalog.limits.label, 24);
  assert.equal(catalog.limits.prompt, 2000);
  assert.ok(catalog.icons.length > 0);
  assert.ok(catalog.iconColors.length > 0);
});

test("proposes full media prompts with styled choices on roots", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const before = snapshot(db);
  const result = await generateNodeTextWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_001"},
    {
      apiKey: "test-key",
      fetchFn: stubFetch(
        JSON.stringify({
          title: "The storm door",
          ttsText: "Thunder rolls.",
          choices: [
            {label: "Enter", icon: "door", iconColor: "cyan"},
            {label: "Climb", icon: "mountain", iconColor: "gold"},
          ],
          endingName: null,
          startImagePrompt: "Wide 9:16 hall, door ajar.",
          videoPrompt: "Slow drift across the hall.",
        })
      ),
    }
  );
  assert.deepEqual(result.choices, [
    {label: "Enter", icon: "door", iconColor: "cyan"},
    {label: "Climb", icon: "mountain", iconColor: "gold"},
  ]);
  assert.equal(result.startImagePrompt, "Wide 9:16 hall, door ajar.");
  assert.equal(result.videoPrompt, "Slow drift across the hall.");
  assert.equal(snapshot(db), before);
});

test("drops the start prompt on child nodes", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const before = snapshot(db);
  const result = await generateNodeTextWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_003"},
    {
      apiKey: "test-key",
      fetchFn: stubFetch(
        JSON.stringify({
          title: "The fork",
          ttsText: "Two paths.",
          choices: [{label: "Left", icon: "forest", iconColor: "green"}],
          endingName: null,
          startImagePrompt: "Should be dropped.",
          videoPrompt: "Kept clip.",
        })
      ),
    }
  );
  assert.deepEqual(result.choices, [
    {label: "Left", icon: "forest", iconColor: "green"},
  ]);
  assert.equal(result.startImagePrompt, null);
  assert.equal(result.videoPrompt, "Kept clip.");
  assert.equal(snapshot(db), before);
});

test("drops choices on endings even when proposed", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeTextWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_002"},
    {
      apiKey: "test-key",
      fetchFn: stubFetch(
        JSON.stringify({
          title: "The quiet ridge",
          ttsText: "The wind settles.",
          choices: [{label: "Stay", icon: "moon", iconColor: "blue"}],
          endingName: "Dawn",
          startImagePrompt: "Should be dropped.",
          videoPrompt: "Slow drift to stillness.",
        })
      ),
    }
  );
  assert.deepEqual(result.choices, []);
  assert.equal(result.endingName, "Dawn");
  assert.equal(result.startImagePrompt, null);
  assert.equal(result.videoPrompt, "Slow drift to stillness.");
});

test("reads legacy proposals without prompts or styled choices", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const before = snapshot(db);
  const result = await generateNodeTextWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_001"},
    {
      apiKey: "test-key",
      fetchFn: stubFetch(
        JSON.stringify({
          title: "The storm door",
          ttsText: "Thunder rolls.",
          choices: ["Enter", "Climb"],
          endingName: null,
        })
      ),
    }
  );
  assert.deepEqual(result.choices, [
    {label: "Enter", icon: null, iconColor: null},
    {label: "Climb", icon: null, iconColor: null},
  ]);
  assert.equal(result.startImagePrompt, null);
  assert.equal(result.videoPrompt, null);
  assert.equal(snapshot(db), before);
});

test("nulls unknown styling and clamps malformed proposals", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeTextWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_001"},
    {
      apiKey: "test-key",
      fetchFn: stubFetch(
        JSON.stringify({
          title: "The storm door",
          ttsText: "Thunder rolls.",
          choices: [
            {label: "Enter", icon: "neon", iconColor: "rainbow"},
            {label: "   ", icon: "door", iconColor: "cyan"},
            {label: "Climb", icon: "mountain", iconColor: "gold"},
            {label: "Extra"},
          ],
          endingName: null,
          startImagePrompt: "s".repeat(2500),
          videoPrompt: "v".repeat(2500),
        })
      ),
    }
  );
  assert.deepEqual(result.choices, [
    {label: "Enter", icon: null, iconColor: null},
    {label: "Climb", icon: "mountain", iconColor: "gold"},
  ]);
  assert.equal(result.startImagePrompt?.length, 2000);
  assert.equal(result.videoPrompt?.length, 2000);
});
