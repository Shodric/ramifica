import {strict as assert} from "assert";
import {createHash} from "crypto";
import {test} from "node:test";
import {Db, DbCol, DbDoc, DbRef, DbTx} from "../feed/shared";
import {
  generateNodeVoiceWith,
  NodeVoiceDeps,
} from "./generateNodeVoice";

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

/** In-memory Firestore. Voice takes never query collections. */
class MemDb implements Db {
  readonly store = new Map<string, Fields>();

  /**
   * @param {string} path Full doc path.
   * @return {DbRef} The doc reference.
   */
  doc(path: string): DbRef {
    return new MemRef(this, path);
  }

  /**
   * Unused stub: voice takes address docs directly.
   * @param {string} path Collection path.
   */
  collection(path: string): DbCol {
    void path;
    throw new Error("MemDb.collection is not stubbed.");
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
 * First 8 hex chars of the sha256, mirroring the version stamp.
 * @param {string} text Bytes stand-in.
 * @return {string} The stamp.
 */
const sha8 = (text: string): string => {
  return createHash("sha256").update(text).digest("hex").slice(0, 8);
};

/**
 * One author-owned draft node with an approved narrator line.
 * @param {MemDb} db Backing store.
 * @param {Fields} overrides Node field replacements.
 */
const seedDraft = (db: MemDb, overrides: Fields = {}): void => {
  db.store.set("stories/story_draft", {
    authorId: "uid_a",
    status: "draft",
    rootNodeId: "node_001",
  });
  db.store.set("stories/story_draft/nodes/node_001", {
    title: "Ridge",
    ttsText: "Wind over the ridge.",
    lineApproved: true,
    ttsAudioUrl: null,
    ttsStatus: "idle",
    ttsDurationSeconds: null,
    ttsApproved: false,
    ...overrides,
  });
};

/**
 * Mocked voice seams: canned PCM in, canned bytes out, hashed URL.
 * @param {string} take Take bytes stand-in.
 * @param {NodeVoiceDeps} overrides Per-test seam replacements.
 * @return {NodeVoiceDeps} The mocked deps.
 */
const mockVoice = (
  take: string,
  overrides: NodeVoiceDeps = {}
): NodeVoiceDeps => ({
  synthesize: async (text: string) => ({pcm: Buffer.from(`pcm:${text}`)}),
  convertTake: async (pcm: Buffer) => ({
    bytes: Buffer.from(`${take}:${pcm.toString()}`),
    durationSeconds: 2.5,
  }),
  uploadVoice: async (args) =>
    `https://cdn.example/${args.nodeId}-voice-${args.hash}.m4a`,
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
  await assert.rejects(
    pending,
    (error: unknown) => (error as {code?: string}).code === expected
  );
};

test("voice is gated on the approved line without writing", async () => {
  const db = new MemDb();
  seedDraft(db, {lineApproved: false});
  const before = snapshot(db);
  await rejectsWith(
    generateNodeVoiceWith(
      db,
      "uid_a",
      {storyId: "story_draft", nodeId: "node_001"},
      mockVoice("take-one")
    ),
    "failed-precondition"
  );
  assert.equal(snapshot(db), before);
});

test("voice gates: auth, owner, draft, target, and words", async () => {
  const db = new MemDb();
  seedDraft(db);
  const good = {storyId: "story_draft", nodeId: "node_001"};
  const deps = mockVoice("take-one");
  await rejectsWith(generateNodeVoiceWith(db, "", good, deps),
    "unauthenticated");
  await rejectsWith(generateNodeVoiceWith(db, "uid_b", good, deps),
    "permission-denied");
  await rejectsWith(
    generateNodeVoiceWith(db, "uid_a", {...good, nodeId: "nope"}, deps),
    "not-found"
  );
  await rejectsWith(
    generateNodeVoiceWith(db, "uid_a", {storyId: "nope", nodeId: "n"}, deps),
    "not-found"
  );
  db.store.set("stories/story_pub", {
    authorId: "uid_a",
    status: "published",
    rootNodeId: "node_p1",
  });
  db.store.set("stories/story_pub/nodes/node_p1", {
    ttsText: "Wind.",
    lineApproved: true,
  });
  await rejectsWith(
    generateNodeVoiceWith(
      db, "uid_a", {storyId: "story_pub", nodeId: "node_p1"}, deps
    ),
    "failed-precondition"
  );
  db.store.set("stories/story_draft/nodes/node_blank", {
    ttsText: "   ",
    lineApproved: true,
  });
  await rejectsWith(
    generateNodeVoiceWith(
      db, "uid_a", {storyId: "story_draft", nodeId: "node_blank"}, deps
    ),
    "failed-precondition"
  );
});

test("happy path speaks the approved line and clears approval", async () => {
  const db = new MemDb();
  seedDraft(db, {
    ttsAudioUrl: "https://cdn.example/old.m4a",
    ttsStatus: "ready",
    ttsDurationSeconds: 1.1,
    ttsApproved: true,
  });
  let spoken: string | null = null;
  const result = await generateNodeVoiceWith(
    db,
    "uid_a",
    {storyId: "story_draft", nodeId: "node_001"},
    mockVoice("take-one", {
      synthesize: async (text: string) => {
        spoken = text;
        return {pcm: Buffer.from(`pcm:${text}`)};
      },
    })
  );
  assert.equal(spoken, "Wind over the ridge.");
  const bytes = "take-one:pcm:Wind over the ridge.";
  const url = `https://cdn.example/node_001-voice-${sha8(bytes)}.m4a`;
  assert.deepEqual(result, {
    nodeId: "node_001",
    ttsStatus: "ready",
    ttsAudioUrl: url,
    ttsDurationSeconds: 2.5,
    ttsApproved: false,
  });
  const saved =
    (await db.doc("stories/story_draft/nodes/node_001").get()).data() ?? {};
  assert.equal(saved.ttsAudioUrl, url);
  assert.equal(saved.ttsStatus, "ready");
  assert.equal(saved.ttsDurationSeconds, 2.5);
  assert.equal(saved.ttsApproved, false);
  assert.equal(saved.lineApproved, true);
  assert.equal(saved.ttsText, "Wind over the ridge.");
});

test("another take replaces bytes and resets approval", async () => {
  const db = new MemDb();
  seedDraft(db);
  const first = await generateNodeVoiceWith(
    db,
    "uid_a",
    {storyId: "story_draft", nodeId: "node_001"},
    mockVoice("take-one")
  );
  await db.doc("stories/story_draft/nodes/node_001").set(
    {ttsApproved: true},
    {merge: true}
  );
  const second = await generateNodeVoiceWith(
    db,
    "uid_a",
    {storyId: "story_draft", nodeId: "node_001"},
    mockVoice("take-two")
  );
  assert.notEqual(second.ttsAudioUrl, first.ttsAudioUrl);
  assert.equal(second.ttsStatus, "ready");
  assert.equal(second.ttsApproved, false);
  const saved =
    (await db.doc("stories/story_draft/nodes/node_001").get()).data() ?? {};
  assert.equal(saved.ttsAudioUrl, second.ttsAudioUrl);
  assert.equal(saved.ttsApproved, false);
});

test("duplicate dispatches converge on the same take", async () => {
  const db = new MemDb();
  seedDraft(db);
  const deps = mockVoice("take-one");
  const first = await generateNodeVoiceWith(
    db,
    "uid_a",
    {storyId: "story_draft", nodeId: "node_001"},
    deps
  );
  const second = await generateNodeVoiceWith(
    db,
    "uid_a",
    {storyId: "story_draft", nodeId: "node_001"},
    deps
  );
  assert.deepEqual(second, first);
  const saved =
    (await db.doc("stories/story_draft/nodes/node_001").get()).data() ?? {};
  assert.equal(saved.ttsStatus, "ready");
  assert.equal(saved.ttsAudioUrl, first.ttsAudioUrl);
});

test("no credentials records pending and keeps last good bytes", async () => {
  const key = process.env.OPENROUTER_API_KEY;
  delete process.env.OPENROUTER_API_KEY;
  try {
    const db = new MemDb();
    seedDraft(db, {
      ttsAudioUrl: "https://cdn.example/old.m4a",
      ttsStatus: "ready",
      ttsDurationSeconds: 1.1,
      ttsApproved: true,
    });
    const result = await generateNodeVoiceWith(
      db,
      "uid_a",
      {storyId: "story_draft", nodeId: "node_001"},
      {convertTake: async () => ({bytes: Buffer.from("x"), durationSeconds: 1})}
    );
    assert.deepEqual(result, {
      nodeId: "node_001",
      ttsStatus: "pending",
      ttsAudioUrl: "https://cdn.example/old.m4a",
      ttsDurationSeconds: 1.1,
      ttsApproved: true,
    });
    const saved =
      (await db.doc("stories/story_draft/nodes/node_001").get()).data() ?? {};
    assert.equal(saved.ttsStatus, "pending");
    assert.equal(saved.ttsAudioUrl, "https://cdn.example/old.m4a");
    assert.equal(saved.ttsApproved, true);
  } finally {
    if (key !== undefined) process.env.OPENROUTER_API_KEY = key;
  }
});

test("provider failure marks failed and keeps last good bytes", async () => {
  const db = new MemDb();
  seedDraft(db, {
    ttsAudioUrl: "https://cdn.example/old.m4a",
    ttsStatus: "ready",
    ttsDurationSeconds: 1.1,
  });
  const before = snapshot(db);
  await rejectsWith(
    generateNodeVoiceWith(
      db,
      "uid_a",
      {storyId: "story_draft", nodeId: "node_001"},
      mockVoice("take-one", {
        synthesize: async () => {
          throw new Error("TTS is down.");
        },
      })
    ),
    "internal"
  );
  const saved =
    (await db.doc("stories/story_draft/nodes/node_001").get()).data() ?? {};
  assert.equal(saved.ttsStatus, "failed");
  assert.equal(saved.ttsAudioUrl, "https://cdn.example/old.m4a");
  assert.equal(saved.ttsDurationSeconds, 1.1);
  assert.ok(snapshot(db) !== before);
});
