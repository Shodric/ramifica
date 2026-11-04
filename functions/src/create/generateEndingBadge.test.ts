import {strict as assert} from "assert";
import {test} from "node:test";
import {Db, DbCol, DbDoc, DbRef, DbTx} from "../feed/shared";
import {
  badgeTargetSize,
  buildBadgePrompt,
  EndingBadgeDeps,
  floodFillAlpha,
  generateEndingBadgeWith,
} from "./generateEndingBadge";
import {MetaFetch, MetaHttpError} from "../media/meta";

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

/** In-memory collection with `==` filtering. */
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
   * Unused stub: badge tests never sort.
   * @param {string} field Field name.
   * @param {string} dir Sort direction.
   */
  orderBy(field: string, dir: "asc" | "desc" = "asc"): DbCol {
    void field;
    void dir;
    throw new Error("MemCol.orderBy is not stubbed.");
  }

  /**
   * Unused stub: badge tests never page.
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

/** One canned provider answer: status plus decoded JSON payload. */
interface CannedAnswer {
  status: number;
  payload: unknown;
}

/**
 * Scripted Meta transport: records each requested size, then answers
 * each call from the script in order (last answer repeats).
 * @param {CannedAnswer[]} script Answers per call.
 * @param {string[]} seenSizes Sink for requested sizes.
 * @param {string[]} seenPrompts Sink for requested prompts.
 * @return {MetaFetch} The stub transport.
 */
const stubFetch = (
  script: CannedAnswer[],
  seenSizes: string[],
  seenPrompts: string[] = []
): MetaFetch => {
  let call = 0;
  return async (url, init) => {
    void url;
    const body = JSON.parse(String(init.body ?? "{}"));
    seenSizes.push(String(body.size ?? ""));
    seenPrompts.push(String(body.prompt ?? ""));
    const step = script[Math.min(call, script.length - 1)];
    call += 1;
    return {
      ok: step.status >= 200 && step.status < 300,
      status: step.status,
      json: async () => step.payload,
      arrayBuffer: async () => new ArrayBuffer(0),
    };
  };
};

/**
 * A decodable provider image payload carrying `bytes` as base64.
 * @param {Buffer} bytes Raw image bytes to encode.
 * @return {unknown} The provider JSON payload.
 */
const imagePayload = (bytes: Buffer): unknown => ({
  data: [{b64_json: bytes.toString("base64")}],
});

/**
 * Mocked badge seams: fetch answers `script`, normalize passes bytes
 * through at 256px, upload mints a stable URL.
 * @param {CannedAnswer[]} script Provider answers.
 * @param {Object} seen Sinks for sizes, prompts, and upload args.
 * @param {EndingBadgeDeps} overrides Per-test seam replacements.
 * @return {EndingBadgeDeps} The mocked deps.
 */
const mockDeps = (
  script: CannedAnswer[],
  seen: {
    sizes: string[];
    prompts: string[];
    uploads: Array<{storyId: string; nodeId: string; bytes: Buffer}>;
  },
  overrides: EndingBadgeDeps = {}
): EndingBadgeDeps => ({
  fetchFn: stubFetch(script, seen.sizes, seen.prompts),
  normalizeBadge: async (bytes) => ({bytes, width: 256, height: 256}),
  uploadBadge: async (args) => {
    seen.uploads.push(args);
    return `https://cdn.example/badges/${args.storyId}/${args.nodeId}.png`;
  },
  ...overrides,
});

/**
 * Fresh sinks per test.
 * @return {Object} Empty size, prompt, and upload sinks.
 */
const freshSeen = (): {
  sizes: string[];
  prompts: string[];
  uploads: Array<{storyId: string; nodeId: string; bytes: Buffer}>;
} => ({sizes: [], prompts: [], uploads: []});

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
    const code = (error as {code?: string}).code;
    return code === expected;
  });
};

/**
 * One author-owned draft with an ending node plus foreign/published
 * stories for the ownership gates.
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
  await db.doc("stories/story_draft/nodes/node_007").set({
    title: "The last gate",
    isEnding: true,
    endingType: "open",
  });
  await db.doc("stories/story_pub").set({
    authorId: "u1",
    title: "Published",
    status: "published",
    rootNodeId: "node_001",
  });
  await db.doc("stories/story_pub/nodes/node_001").set({title: "Y"});
  await db.doc("stories/story_foreign").set({
    authorId: "u2",
    title: "Foreign",
    status: "draft",
    rootNodeId: "node_001",
  });
  await db.doc("stories/story_foreign/nodes/node_001").set({title: "X"});
};

test("badge ok: 256px request, Storage upload, node link", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const seen = freshSeen();
  const raw = Buffer.from("raw-badge-bytes");
  const result = await generateEndingBadgeWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_007"},
    mockDeps([{status: 200, payload: imagePayload(raw)}], seen)
  );
  assert.deepEqual(seen.sizes, ["256x256"]);
  assert.equal(
    result.badgeUrl,
    "https://cdn.example/badges/story_draft/node_007.png"
  );
  assert.equal(seen.uploads.length, 1);
  assert.equal(seen.uploads[0].storyId, "story_draft");
  assert.equal(seen.uploads[0].nodeId, "node_007");
  assert.deepEqual(seen.uploads[0].bytes, raw);
  const node = await db.doc("stories/story_draft/nodes/node_007").get();
  assert.equal(node.data()?.endingBadgeUrl, result.badgeUrl);
});

test("badge falls back to 480 when the provider rejects 256", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const seen = freshSeen();
  const raw = Buffer.from("fallback-badge-bytes");
  const result = await generateEndingBadgeWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_007"},
    mockDeps(
      [
        {status: 400, payload: {error: "size not supported"}},
        {status: 200, payload: imagePayload(raw)},
      ],
      seen
    )
  );
  assert.deepEqual(seen.sizes, ["256x256", "480x480"]);
  assert.equal(
    result.badgeUrl,
    "https://cdn.example/badges/story_draft/node_007.png"
  );
  const node = await db.doc("stories/story_draft/nodes/node_007").get();
  assert.equal(node.data()?.endingBadgeUrl, result.badgeUrl);
});

test("badge rejects when the provider answers without an image", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const seen = freshSeen();
  await rejectsWith(
    generateEndingBadgeWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_007"},
      mockDeps([{status: 200, payload: {data: []}}], seen)
    ),
    "internal"
  );
  assert.equal(seen.uploads.length, 0);
  const node = await db.doc("stories/story_draft/nodes/node_007").get();
  assert.equal("endingBadgeUrl" in (node.data() ?? {}), false);
});

test("badge rejects when the 480 fallback also fails", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const seen = freshSeen();
  await rejectsWith(
    generateEndingBadgeWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_007"},
      mockDeps(
        [
          {status: 400, payload: {error: "size not supported"}},
          {status: 500, payload: {error: "provider down"}},
        ],
        seen
      )
    ),
    "internal"
  );
  assert.deepEqual(seen.sizes, ["256x256", "480x480"]);
  assert.equal(seen.uploads.length, 0);
});

test("badge gates: auth, owner, draft, and node", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const args = {storyId: "story_draft", nodeId: "node_007"};
  await rejectsWith(
    generateEndingBadgeWith(db, "", args, mockDeps([], freshSeen())),
    "unauthenticated"
  );
  await rejectsWith(
    generateEndingBadgeWith(
      db, "u1", {storyId: "story_foreign", nodeId: "node_001"},
      mockDeps([], freshSeen())
    ),
    "permission-denied"
  );
  await rejectsWith(
    generateEndingBadgeWith(
      db, "u1", {storyId: "story_pub", nodeId: "node_001"},
      mockDeps([], freshSeen())
    ),
    "failed-precondition"
  );
  await rejectsWith(
    generateEndingBadgeWith(
      db, "u1", {storyId: "story_draft", nodeId: "node_missing"},
      mockDeps([], freshSeen())
    ),
    "not-found"
  );
});

test("badge without credentials fails before billing", async () => {
  const key = process.env.META_API_KEY;
  delete process.env.META_API_KEY;
  try {
    const db = new MemDb();
    await seedDraft(db);
    await rejectsWith(
      generateEndingBadgeWith(db, "u1", {
        storyId: "story_draft", nodeId: "node_007",
      }),
      "failed-precondition"
    );
  } finally {
    if (key !== undefined) process.env.META_API_KEY = key;
  }
});

test("badge prompt is a textless shield themed by the ending", () => {
  const prompt = buildBadgePrompt({title: "Dawn", endingType: "open"});
  assert.match(prompt, /shield|badge|insignia|emblem/i);
  assert.match(prompt, /transparent/i);
  assert.match(prompt, /no text/i);
  assert.match(prompt, /Dawn/);
  const bare = buildBadgePrompt({title: null, endingType: null});
  assert.match(bare, /transparent/i);
  assert.doesNotMatch(bare, /undefined/);
});

test("badge prompt reads the scene title from the stored node", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const seen = freshSeen();
  await generateEndingBadgeWith(
    db,
    "u1",
    {
      storyId: "story_draft", nodeId: "node_007",
      endingType: "tragic",
    },
    mockDeps(
      [{status: 200, payload: imagePayload(Buffer.from("x"))}],
      seen
    )
  );
  assert.equal(seen.prompts.length, 1);
  assert.match(seen.prompts[0], /The last gate/);
});

test("badge resize fits within 480px and never upscales", () => {
  assert.deepEqual(badgeTargetSize(1024, 768), {width: 480, height: 360});
  assert.deepEqual(badgeTargetSize(768, 1024), {width: 360, height: 480});
  assert.deepEqual(badgeTargetSize(600, 600), {width: 480, height: 480});
  assert.deepEqual(badgeTargetSize(480, 480), {width: 480, height: 480});
  assert.deepEqual(badgeTargetSize(200, 100), {width: 200, height: 100});
});

test("flood fill clears the border background and keeps the emblem", () => {
  // 3x3 RGBA: red border, one green center pixel.
  const pixels = Buffer.alloc(3 * 3 * 4, 255);
  for (let i = 0; i < 9; i++) {
    pixels[i * 4] = 255; pixels[i * 4 + 1] = 0; pixels[i * 4 + 2] = 0;
  }
  const center = 4 * 4;
  pixels[center] = 0; pixels[center + 1] = 255; pixels[center + 2] = 0;
  const cleared = floodFillAlpha(pixels, 3, 3, 32);
  assert.equal(cleared, 8);
  for (let i = 0; i < 9; i++) {
    if (i === 4) assert.equal(pixels[i * 4 + 3], 255);
    else assert.equal(pixels[i * 4 + 3], 0);
  }
});

test("MetaHttpError is the rejection the fallback catches", () => {
  assert.ok(new MetaHttpError(400, "nope") instanceof Error);
});
