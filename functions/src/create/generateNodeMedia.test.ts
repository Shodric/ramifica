import {strict as assert} from "assert";
import {createHash} from "crypto";
import {test} from "node:test";
import {Db, DbCol, DbDoc, DbRef, DbTx} from "../feed/shared";
import {
  buildImagePrompt,
  generateNodeImageWith,
  generateNodeVideoWith,
  imageProviderKind,
  NodeMediaDeps,
} from "./generateNodeMedia";
import {OpenRouterHttpError} from "../media/openrouter";

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
  normalizeImage: async (bytes) => ({bytes, width: 480, height: 854}),
  requestVideo: async () => ({jobId: "or_test-job"}),
  downloadVideo: async () => Buffer.from("normalized-clip"),
  normalizeVideo: async (bytes) => ({
    bytes,
    width: 480,
    height: 854,
    durationSeconds: 10,
    lastFrame: Buffer.from("last-frame"),
    lastBlurData: "blur",
  }),
  uploadVideo: async () => "https://cdn.example/v-new.mp4",
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
 * One author-owned draft: root with ready S, ready video, and an
 * extracted last frame; one child linked to that last frame with its
 * own ready video and last frame.
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
    videoStatus: "ready",
    videoSource: "generated",
    videoUrl: "https://cdn.example/v1.mp4",
    videoFromHash: "hash-s1",
    videoJobId: "job-1",
    videoFrameLastUrl: "https://cdn.example/f1.png",
    videoFrameLastHash: "hash-f1",
  });
  await db.doc("stories/story_draft/nodes/node_002").set({
    title: "Ridge",
    startFromNodeId: "node_001",
    startParentFrameHash: "hash-f1",
    startImageSourceUrl: "https://cdn.example/f1.png",
    startImageStatus: "ready",
    videoStatus: "ready",
    videoSource: "generated",
    videoUrl: "https://cdn.example/v2.mp4",
    videoFromHash: "hash-f1",
    videoJobId: "job-2",
    videoFrameLastUrl: "https://cdn.example/f2.png",
    videoFrameLastHash: "hash-f2",
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
  await rejectsWith(
    generateNodeImageWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_001", which: "end"},
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
      {storyId: "story_draft", nodeId: "node_001", which: "start"},
      mockDeps()
    ),
    "unauthenticated"
  );
  await rejectsWith(
    generateNodeImageWith(
      db,
      "u1",
      {storyId: "story_foreign", nodeId: "node_001", which: "start"},
      mockDeps()
    ),
    "permission-denied"
  );
  await rejectsWith(
    generateNodeImageWith(
      db,
      "u1",
      {storyId: "story_pub", nodeId: "node_001", which: "start"},
      mockDeps()
    ),
    "failed-precondition"
  );
  assert.equal(snapshot(db), before);
});

test("missing image credentials fail immediately and preserve " +
    "the last take", async () => {
  const metaKey = process.env.META_API_KEY;
  const comfyUrl = process.env.COMFYUI_URL;
  delete process.env.META_API_KEY;
  delete process.env.COMFYUI_URL;
  try {
    const db = new MemDb();
    await seedDraft(db);
    await rejectsWith(generateNodeImageWith(db, "u1", {
      storyId: "story_draft", nodeId: "node_001", which: "start",
    }), "failed-precondition");
    const node = await db.doc("stories/story_draft/nodes/node_001").get();
    assert.equal(node.data()?.startImageStatus, "failed");
    assert.equal(
      node.data()?.mediaError,
      "Image provider credentials are missing."
    );
    assert.equal(node.data()?.generationKind, null);
    assert.equal(node.data()?.generationPhase, null);
    assert.equal(node.data()?.startHash, "hash-s1");
  } finally {
    if (metaKey === undefined) delete process.env.META_API_KEY;
    else process.env.META_API_KEY = metaKey;
    if (comfyUrl === undefined) delete process.env.COMFYUI_URL;
    else process.env.COMFYUI_URL = comfyUrl;
  }
});

test("image provider failure fails with a reason and keeps " +
    "last good bytes", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await rejectsWith(
    generateNodeImageWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_001", which: "start"},
      mockDeps({imageGen: async () => {
        throw new Error("GPU is down.");
      }})
    ),
    "internal"
  );
  const node = await db.doc("stories/story_draft/nodes/node_001").get();
  assert.equal(node.data()?.startImageStatus, "failed");
  assert.equal(node.data()?.mediaError, "GPU is down.");
  assert.equal(node.data()?.generationKind, null);
  assert.equal(node.data()?.generationPhase, null);
  assert.equal(node.data()?.startHash, "hash-s1");
});

test("a finished parent clip desyncs children linked to the old last " +
    "frame", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeVideoWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_001"},
    mockDeps({
      requestVideo: async () => ({
        jobId: "seedance-7",
        videoUrl: "https://cdn.example/v-new.mp4",
      }),
    })
  );
  const expectedHash = sha8("last-frame");
  assert.equal(result.videoStatus, "ready");

  const parent = await db.doc("stories/story_draft/nodes/node_001").get();
  assert.equal(parent.data()?.videoFrameLastHash, expectedHash);
  assert.equal(
    parent.data()?.videoFrameLastUrl, `https://cdn.example/${expectedHash}.png`
  );

  const child = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(child.data()?.videoStatus, "idle");
  assert.equal(child.data()?.videoUrl, null);
  assert.equal(child.data()?.startParentFrameHash, "hash-f1");
  assert.notEqual(child.data()?.startParentFrameHash, expectedHash);
});


test("video needs the parent clip ready, unapproved or not", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_001").set(
    {videoFrameLastHash: null, videoFrameLastUrl: null},
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

test("root video needs its own S ready, unapproved or not", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_001").set(
    {startImageStatus: "idle", startHash: null, startImageSourceUrl: null},
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

test("root video without a generated S falls back to the reference still",
  async () => {
    const db = new MemDb();
    await seedDraft(db);
    await db.doc("stories/story_draft/nodes/node_001").set(
      {
        startImageStatus: "idle", startHash: null, startImageSourceUrl: null,
        startImageReferenceUrl: "https://cdn.example/ref.png",
      },
      {merge: true}
    );
    let seenUrl = "";
    const result = await generateNodeVideoWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_001"},
      mockDeps({
        requestVideo: async ({startUrl}) => {
          seenUrl = startUrl;
          return {jobId: "job-ref"};
        },
      })
    );
    assert.equal(seenUrl, "https://cdn.example/ref.png");
    assert.equal(result.videoStatus, "pending");
    assert.equal(result.videoJobId, "job-ref");
  });

test("video inherits the parent clip's last frame as S and records " +
    "a pending job", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeVideoWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_002"},
    mockDeps()
  );
  assert.equal(result.videoStatus, "pending");
  assert.equal(result.videoFromHash, "hash-f1");
  assert.equal(result.videoJobId, "or_test-job");
  assert.equal(result.poll, true);
  assert.equal(result.videoUrl, "https://cdn.example/v2.mp4");
  const child = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(child.data()?.startParentFrameHash, "hash-f1");
  assert.equal(
    child.data()?.startImageSourceUrl,
    "https://cdn.example/f1.png"
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
  assert.equal(result.videoUrl, "https://cdn.example/v-new.mp4");
  assert.equal(result.poll, false);
  const parent = await db.doc("stories/story_draft/nodes/node_001").get();
  assert.equal(parent.data()?.videoFrameLastHash, sha8("last-frame"));
});

test("re-inheriting after a parent clip re-links the child", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await generateNodeVideoWith(
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
  const parent = await db.doc("stories/story_draft/nodes/node_001").get();
  const frameHash = parent.data()?.videoFrameLastHash as string;
  assert.ok(frameHash && frameHash !== "hash-f1");
  const video = await generateNodeVideoWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_002"},
    mockDeps({
      requestVideo: async () => ({jobId: "seedance-9"}),
    })
  );
  assert.equal(video.videoFromHash, frameHash);
  const child = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(child.data()?.startParentFrameHash, frameHash);
  assert.equal(child.data()?.videoStatus, "pending");
});

test("image prefers Meta over Comfy when the key is set", async () => {
  const apiKey = process.env.META_API_KEY;
  const comfyUrl = process.env.COMFYUI_URL;
  try {
    process.env.META_API_KEY = "key-1";
    process.env.COMFYUI_URL = "http://comfy.example";
    assert.equal(imageProviderKind(), "meta");
    delete process.env.META_API_KEY;
    assert.equal(imageProviderKind(), "comfy");
    delete process.env.COMFYUI_URL;
    assert.equal(imageProviderKind(), null);
  } finally {
    if (apiKey === undefined) delete process.env.META_API_KEY;
    else process.env.META_API_KEY = apiKey;
    if (comfyUrl === undefined) delete process.env.COMFYUI_URL;
    else process.env.COMFYUI_URL = comfyUrl;
  }
});

test("video provider submit asks the client to poll", async () => {
  const db = new MemDb();
  await seedDraft(db);
  const result = await generateNodeVideoWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_002"},
    mockDeps({
      requestVideo: async () => ({jobId: "or_job-9"}),
    })
  );
  assert.equal(result.videoStatus, "pending");
  assert.equal(result.videoJobId, "or_job-9");
  assert.equal(result.videoUrl, "https://cdn.example/v2.mp4");
  assert.equal(result.poll, true);
  const child = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(child.data()?.videoJobId, "or_job-9");
});

test("configured video model sends the start frame only and resumes " +
    "at the same endpoint",
async (t) => {
  const env = {
    OPENROUTER_API_KEY: "test-key",
    OPENROUTER_VIDEOS_URL: "https://router.example/video-jobs",
    OPENROUTER_VIDEO_MODEL: "vendor/start-frame-video",
    OPENROUTER_VIDEO_RESOLUTION: "480p",
    OPENROUTER_VIDEO_ASPECT_RATIO: "9:16",
    OPENROUTER_VIDEO_DURATION_SECONDS: "10",
  };
  const before = Object.fromEntries(
    Object.keys(env).map((key) => [key, process.env[key]])
  );
  try {
    Object.assign(process.env, env);
    const seen: Array<{url: string; init?: RequestInit}> = [];
    t.mock.method(globalThis, "fetch", async (
      url: string | URL | Request, init?: RequestInit
    ) => {
      seen.push({url: String(url), init});
      return new Response(JSON.stringify(init?.method === "POST" ?
        {id: "job-config"} : {status: "pending"}), {status: 200});
    });
    const db = new MemDb();
    await seedDraft(db);
    const args = {storyId: "story_draft", nodeId: "node_002"};
    const first = await generateNodeVideoWith(db, "u1", args);
    const second = await generateNodeVideoWith(db, "u1", args);
    assert.equal(first.videoJobId, "or_job-config");
    assert.equal(second.videoJobId, first.videoJobId);
    assert.deepEqual(seen.map((request) => request.url), [
      "https://router.example/video-jobs",
      "https://router.example/video-jobs/job-config",
    ]);
    const body = JSON.parse(String(seen[0].init?.body));
    assert.equal(body.model, "vendor/start-frame-video");
    assert.equal(body.duration, 10);
    assert.equal(body.resolution, "480p");
    assert.deepEqual(body.frame_images.map((frame: {
        frame_type: string; image_url: {url: string};
      }) => [frame.frame_type, frame.image_url.url]), [
      ["first_frame", "https://cdn.example/f1.png"],
    ]);
  } finally {
    for (const [key, value] of Object.entries(before)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});

test("video resumes a stored job without resubmitting", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_002").set(
    {videoJobId: "or_job-9", videoStatus: "pending"},
    {merge: true}
  );
  let submitted = false;
  const result = await generateNodeVideoWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_002"},
    mockDeps({
      requestVideo: async () => {
        submitted = true;
        return {jobId: "or_job-10"};
      },
      checkVideo: async (jobId: string) => {
        assert.equal(jobId, "job-9");
        return {status: "pending"};
      },
    })
  );
  assert.equal(submitted, false);
  assert.equal(result.videoStatus, "pending");
  assert.equal(result.videoJobId, "or_job-9");
  assert.equal(result.poll, true);
});

test("video completion stores the finished clip", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_002").set(
    {videoJobId: "or_job-9", videoStatus: "pending"},
    {merge: true}
  );
  const seen: string[] = [];
  const result = await generateNodeVideoWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_002"},
    mockDeps({
      checkVideo: async () => ({
        status: "completed",
        videoUrl: "https://openrouter.example/content",
      }),
      downloadVideo: async (url: string) => {
        seen.push(url);
        return Buffer.from("fake-clip");
      },
      normalizeVideo: async (bytes) => ({
        bytes,
        width: 480,
        height: 854,
        durationSeconds: 10,
        lastFrame: Buffer.from("frame"),
        lastBlurData: "blur",
      }),
      uploadVideo: async (args) => {
        assert.equal(args.storyId, "story_draft");
        assert.equal(args.nodeId, "node_002");
        return `https://cdn.example/${args.hash}.mp4`;
      },
    })
  );
  assert.deepEqual(seen, ["https://openrouter.example/content"]);
  const hash = createHash("sha256")
    .update("fake-clip")
    .digest("hex")
    .slice(0, 8);
  assert.equal(result.videoStatus, "ready");
  assert.equal(result.videoUrl, `https://cdn.example/${hash}.mp4`);
  assert.equal(result.videoJobId, "or_job-9");
  assert.equal(result.poll, false);
  const child = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(child.data()?.videoStatus, "ready");
  assert.equal(child.data()?.durationSeconds, 10);
});

test("video failure clears the job and fails", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_002").set(
    {videoJobId: "or_job-9", videoStatus: "pending"},
    {merge: true}
  );
  await rejectsWith(
    generateNodeVideoWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_002"},
      mockDeps({checkVideo: async () => ({status: "failed"})})
    ),
    "internal"
  );
  const child = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(child.data()?.videoStatus, "failed");
  assert.equal(child.data()?.mediaError, "Video generation failed.");
  assert.equal(child.data()?.generationKind, null);
  assert.equal(child.data()?.generationPhase, null);
  assert.equal(child.data()?.videoJobId, null);
});

test("an expired video job clears and fails", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_002").set(
    {videoJobId: "or_job-9", videoStatus: "pending"},
    {merge: true}
  );
  await rejectsWith(
    generateNodeVideoWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_002"},
      mockDeps({
        checkVideo: async () => {
          throw new OpenRouterHttpError(404, "gone");
        },
      })
    ),
    "internal"
  );
  const child = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(child.data()?.videoStatus, "failed");
  assert.equal(child.data()?.mediaError, "gone");
  assert.equal(child.data()?.generationKind, null);
  assert.equal(child.data()?.generationPhase, null);
  assert.equal(child.data()?.videoJobId, null);
});

test("missing video credentials fail immediately with a reason", async () => {
  const key = process.env.OPENROUTER_API_KEY;
  delete process.env.OPENROUTER_API_KEY;
  try {
    const db = new MemDb();
    await seedDraft(db);
    const deps = mockDeps();
    delete deps.requestVideo;
    await rejectsWith(
      generateNodeVideoWith(
        db,
        "u1",
        {storyId: "story_draft", nodeId: "node_002"},
        deps
      ),
      "failed-precondition"
    );
    const node = await db.doc("stories/story_draft/nodes/node_002").get();
    assert.equal(node.data()?.videoStatus, "failed");
    assert.equal(
      node.data()?.mediaError,
      "Video provider credentials are missing."
    );
    assert.equal(node.data()?.generationKind, null);
    assert.equal(node.data()?.generationPhase, null);
    assert.equal(node.data()?.videoUrl, "https://cdn.example/v2.mp4");
  } finally {
    if (key !== undefined) process.env.OPENROUTER_API_KEY = key;
  }
});

test("a video poll past its lease fails with a timeout reason", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_002").set(
    {videoJobId: "or_job-9", videoStatus: "pending",
      generationExpiresAt: new Date(Date.now() - 1000).toISOString()},
    {merge: true}
  );
  await rejectsWith(
    generateNodeVideoWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_002"},
      mockDeps({checkVideo: async () => {
        throw new Error("must not poll after expiry");
      }})
    ),
    "deadline-exceeded"
  );
  const child = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(child.data()?.videoStatus, "failed");
  assert.equal(
    child.data()?.mediaError,
    "Video generation timed out before finishing."
  );
  assert.equal(child.data()?.generationKind, null);
  assert.equal(child.data()?.generationPhase, null);
  assert.equal(child.data()?.videoJobId, null);
});

test("video finish failure fails the node with a reason", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await rejectsWith(
    generateNodeVideoWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_002"},
      mockDeps({
        requestVideo: async () => ({jobId: "or_test-job", videoUrl: "https://cdn.example/clip.mp4"}),
        downloadVideo: async () => {
          throw new Error("blob gone");
        },
      })
    ),
    "internal"
  );
  const child = await db.doc("stories/story_draft/nodes/node_002").get();
  assert.equal(child.data()?.videoStatus, "failed");
  assert.equal(child.data()?.generationKind, null);
  assert.equal(child.data()?.generationPhase, null);
  assert.ok(String(child.data()?.mediaError ?? "").includes("blob gone"));
});

test("image prompts ground the still in story, line, and frame", () => {
  const story = {title: "The temple", synopsis: "A cursed gate."};
  const node = {
    title: "Gate",
    ttsText: "The stones remember your name.",
    endingName: null,
    videoPrompt: null,
  };
  const start = buildImagePrompt(story, node);
  assert.match(start, /Opening frame/);
  assert.match(start, /The temple/);
  assert.match(start, /A cursed gate/);
  assert.match(start, /The stones remember your name/);
});

test("image prompts omit blanks and stay within budget", () => {
  const prompt = buildImagePrompt(
    {title: "T", synopsis: "x".repeat(500)},
    {title: "", ttsText: null, endingName: "Fin", videoPrompt: "morph"}
  );
  assert.doesNotMatch(prompt, /MOMENT/);
  assert.match(prompt, /Fin/);
  assert.match(prompt, /CLIP CONTEXT: morph/);
  assert.ok(prompt.length <= 2000);
});

test("image generation falls back to the story-grounded prompt", async () => {
  const db = new MemDb();
  await seedDraft(db);
  await db.doc("stories/story_draft/nodes/node_001").set(
    {ttsText: "The stones remember your name."},
    {merge: true}
  );
  let seen = "";
  await generateNodeImageWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_001", which: "start"},
    mockDeps({
      imageGen: async (prompt: string) => {
        seen = prompt;
        return {bytes: Buffer.from("still")};
      },
    })
  );
  assert.match(seen, /The temple/);
  assert.match(seen, /The stones remember your name/);
  assert.match(seen, /Opening frame/);
});

test("image with a reference guides the still via the reference path",
  async () => {
    const db = new MemDb();
    await seedDraft(db);
    await db.doc("stories/story_draft/nodes/node_001").set(
      {startImageReferenceUrl: "https://cdn.example/ref.png"},
      {merge: true}
    );
    let plainCalled = false;
    const seen: Array<{
      prompt: string; referenceBase64: string; referenceMimeType: string;
    }> = [];
    const result = await generateNodeImageWith(
      db,
      "u1",
      {storyId: "story_draft", nodeId: "node_001", which: "start"},
      mockDeps({
        imageGen: async () => {
          plainCalled = true;
          return {bytes: Buffer.from("plain-still")};
        },
        downloadReference: async (url: string) => {
          assert.equal(url, "https://cdn.example/ref.png");
          return Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x00]);
        },
        referenceImageGen: async (args) => {
          seen.push(args);
          return {bytes: Buffer.from("guided-still")};
        },
      })
    );
    assert.equal(plainCalled, false);
    assert.equal(seen.length, 1);
    assert.equal(
      seen[0].referenceBase64,
      Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x00]).toString("base64")
    );
    assert.equal(seen[0].referenceMimeType, "image/png");
    assert.match(seen[0].prompt, /The temple/);
    assert.ok(result.imageUrl?.startsWith("https://cdn.example/"));
  });

test("image without a reference uses the plain path unchanged", async () => {
  const db = new MemDb();
  await seedDraft(db);
  let referenceCalled = false;
  let downloadCalled = false;
  let seenPrompt = "";
  await generateNodeImageWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_001", which: "start"},
    mockDeps({
      imageGen: async (prompt: string) => {
        seenPrompt = prompt;
        return {bytes: Buffer.from("plain-still")};
      },
      downloadReference: async () => {
        downloadCalled = true;
        return Buffer.from("ref");
      },
      referenceImageGen: async () => {
        referenceCalled = true;
        return {bytes: Buffer.from("guided-still")};
      },
    })
  );
  assert.equal(downloadCalled, false);
  assert.equal(referenceCalled, false);
  assert.match(seenPrompt, /The temple/);
});

test("image falls back to the plain path when the reference fails",
  async () => {
    for (const failingDeps of [
      {downloadFails: true, referenceFails: false},
      {downloadFails: false, referenceFails: true},
    ]) {
      const db = new MemDb();
      await seedDraft(db);
      await db.doc("stories/story_draft/nodes/node_001").set(
        {startImageReferenceUrl: "https://cdn.example/ref.png"},
        {merge: true}
      );
      let plainCalls = 0;
      const result = await generateNodeImageWith(
        db,
        "u1",
        {storyId: "story_draft", nodeId: "node_001", which: "start"},
        mockDeps({
          imageGen: async () => {
            plainCalls += 1;
            return {bytes: Buffer.from("plain-still")};
          },
          downloadReference: async () => {
            if (failingDeps.downloadFails) throw new Error("blob gone");
            return Buffer.from("ref-bytes");
          },
          referenceImageGen: async () => {
            if (failingDeps.referenceFails) {
              throw new Error("provider is down");
            }
            return {bytes: Buffer.from("guided-still")};
          },
        })
      );
      assert.equal(plainCalls, 1);
      assert.equal(result.imageStatus, "ready");
    }
  });

test("image metadata and hash refer to normalized bytes and " +
    "advance draft revision", async () => {
  const db = new MemDb(); await seedDraft(db);
  const normalized = Buffer.from("normalized-480x854");
  const sha8String = sha8(normalized.toString());
  let stored: Buffer | undefined;
  const result = await generateNodeImageWith(
    db,
    "u1",
    {storyId: "story_draft", nodeId: "node_001", which: "start"},
    mockDeps({
      normalizeImage: async () => ({
        bytes: normalized,
        width: 480,
        height: 854,
      }),
      uploadStill: async (args) => {
        stored = args.bytes;
        return `https://cdn.example/${args.hash}.png`;
      },
    })
  );
  assert.deepEqual(stored, normalized);
  assert.equal(result.imageUrl, `https://cdn.example/${sha8String}.png`);
  const node = (
    await db.doc("stories/story_draft/nodes/node_001").get()
  ).data();
  assert.equal(node?.startHash, sha8String);
  assert.equal(node?.startImageWidth, 480);
  assert.equal(node?.startImageHeight, 854);
  assert.equal(node?.generationKind, null);
  const story = (await db.doc("stories/story_draft").get()).data();
  assert.ok(Number(story?.revision) >= 1);
});
