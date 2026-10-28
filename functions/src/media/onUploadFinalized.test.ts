import {createHash} from "crypto";
import {strict as assert} from "assert";
import {test} from "node:test";
import {Db, DbCol, DbDoc, DbRef, DbTx} from "../feed/shared";
import {
  finalizeUploadWith,
  maxUploadBytes,
  parseUploadName,
  UploadFinalizeDeps,
  UploadObject,
} from "./onUploadFinalized";
import {ProcessedVideo} from "./processVideo";

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
   * Unused stub: upload tests never sort.
   * @param {string} field Field name.
   * @param {string} dir Sort direction.
   */
  orderBy(field: string, dir: "asc" | "desc" = "asc"): DbCol {
    void field;
    void dir;
    throw new Error("MemCol.orderBy is not stubbed.");
  }

  /**
   * Unused stub: upload tests never page.
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

  /**
   * @param {Function} fn Transaction body.
   * @return {Promise<unknown>} The body result.
   */
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

/** One author-owned draft node with an approved E and a ready video. */
interface Script {
  db: MemDb;
  obj: UploadObject;
  frameBytes: Buffer;
  videoBytes: Buffer;
  processed: ProcessedVideo;
  uploaded: Array<{dest: string; type: string}>;
  downloaded: string[];
  deleted: string[];
  processCalls: number;
}

/**
 * Draft story plus an upload script with canned encode outputs.
 * @param {Partial<UploadObject>} overrides Object metadata replacements.
 * @return {Script} The script.
 */
const script = (overrides: Partial<UploadObject> = {}): Script => {
  const db = new MemDb();
  db.store.set("stories/storyA", {
    authorId: "uidA",
    status: "draft",
    rootNodeId: "nodeA",
  });
  db.store.set("stories/storyA/nodes/nodeA", {
    title: "Take one",
    videoStatus: "ready",
    videoSource: "generated",
    videoUrl: "https://cdn.example/old.mp4",
    videoFromHash: "hash-s1",
    videoToHash: "hash-e1",
    videoJobId: "job-old",
    endHash: "hash-e1",
    endImageSourceUrl: "https://cdn.example/old-e.png",
    endImageStatus: "ready",
    endImageApproved: true,
  });
  return {
    db,
    obj: {
      name: "uploads/uidA/storyA_nodeA.mp4",
      bucket: "demo",
      size: 8 * 1024 * 1024,
      contentType: "video/mp4",
      generation: "7",
      ...overrides,
    },
    frameBytes: Buffer.from("last-frame-bytes"),
    videoBytes: Buffer.from("video-bytes"),
    processed: {
      videoPath: "/tmp/work/video.mp4",
      durationSeconds: 12.5,
      pauseAtSeconds: 12.5 - 1 / 30,
      firstFramePath: "/tmp/work/first.png",
      lastFramePath: "/tmp/work/last.png",
      firstBlurData: "data:image/webp;base64,AAA",
      lastBlurData: "data:image/webp;base64,BBB",
    },
    uploaded: [],
    downloaded: [],
    deleted: [],
    processCalls: 0,
  };
};

/**
 * Mocked Storage/ffmpeg seams recording every side effect.
 * @param {Script} s The script holding canned bytes and traces.
 * @param {object} extra Per-test seam replacements.
 * @return {UploadFinalizeDeps} The mocked deps.
 */
const depsOf = (
  s: Script,
  extra: Partial<UploadFinalizeDeps> = {}
): UploadFinalizeDeps => ({
  download: async (name: string) => {
    s.downloaded.push(name);
  },
  process: async () => {
    s.processCalls += 1;
    return s.processed;
  },
  uploadBytes: async (dest: string, bytes: Buffer, type: string) => {
    s.uploaded.push({dest, type});
    return `https://signed.example/${dest}?h=${sha8(bytes.toString())}`;
  },
  readLocal: async (path: string) => {
    if (path === s.processed.lastFramePath) return s.frameBytes;
    if (path === s.processed.videoPath) return s.videoBytes;
    throw new Error(`Unexpected read ${path}.`);
  },
  deleteObject: async (name: string) => {
    s.deleted.push(name);
  },
  hasTools: async () => true,
  ...extra,
});

/**
 * @param {MemDb} db Backing store.
 * @return {Promise<Fields>} The node fields.
 */
const nodeOf = async (db: MemDb): Promise<Fields> => {
  const snap = await db.doc("stories/storyA/nodes/nodeA").get();
  assert.equal(snap.exists, true);
  const fields = snap.data();
  assert.ok(fields !== undefined);
  return fields;
};

test("parseUploadName routes filename to story and node", () => {
  assert.deepEqual(parseUploadName("uploads/uidA/storyA_nodeA.mp4"), {
    uid: "uidA",
    storyId: "storyA",
    nodeId: "nodeA",
    takeId: null,
  });
  assert.deepEqual(parseUploadName("uploads/uidA/storyA_nodeA.MOV"), {
    uid: "uidA",
    storyId: "storyA",
    nodeId: "nodeA",
    takeId: null,
  });
  assert.deepEqual(parseUploadName("uploads/uidA/storyA_nodeA_take9.mp4"), {
    uid: "uidA",
    storyId: "storyA",
    nodeId: "nodeA",
    takeId: "take9",
  });
  assert.equal(parseUploadName("uploads/uidA/bad-name.mp4"), null);
  assert.equal(parseUploadName("uploads/uidA/storyA_nodeA.avi"), null);
  assert.equal(parseUploadName("uploads/uidA/storyA_nodeA_.mp4"), null);
  assert.equal(parseUploadName("uploads/uidA/a_b_c_d.mp4"), null);
  assert.equal(parseUploadName("stories/storyA/nodeA-end-x.png"), null);
});

test("happy path stores video, E last frame, deletes upload", async () => {
  const s = script();
  const result = await finalizeUploadWith(s.db, s.obj, depsOf(s));
  assert.equal(result.status, "ready");
  const node = await nodeOf(s.db);
  assert.equal(node.videoSource, "upload");
  assert.equal(node.videoStatus, "ready");
  assert.equal(typeof node.videoUrl, "string");
  assert.equal(node.endHash, sha8("last-frame-bytes"));
  assert.equal(node.uploadTakeId, null);
  assert.equal(node.endImageSource, "upload");
  assert.equal(node.endImageStatus, "ready");
  assert.equal(node.endImageApproved, false);
  assert.equal(node.videoFrameLastUrl, node.endImageSourceUrl);
  assert.equal(node.durationSeconds, 12.5);
  assert.equal(node.pauseAtSeconds, 12.5 - 1 / 30);
  assert.equal(node.uploadError, null);
  assert.equal(node.uploadObjectName, s.obj.name);
  assert.deepEqual(s.downloaded, [s.obj.name]);
  assert.deepEqual(s.deleted, [s.obj.name]);
  assert.equal(
    s.uploaded.some((u) => u.type === "video/mp4" && u.dest.endsWith(".mp4")),
    true
  );
  assert.equal(
    s.uploaded.some((u) => u.type === "image/png" && u.dest.endsWith(".png")),
    true
  );
});

test("three-part take stamps uploadTakeId on success", async () => {
  const s = script({name: "uploads/uidA/storyA_nodeA_take9.mp4"});
  const result = await finalizeUploadWith(s.db, s.obj, depsOf(s));
  assert.equal(result.status, "ready");
  const node = await nodeOf(s.db);
  assert.equal(node.uploadTakeId, "take9");
  assert.equal(node.uploadError, null);
  assert.equal(node.videoStatus, "ready");
});

test("wrong type is rejected with the node video untouched", async () => {
  const s = script({
    name: "uploads/uidA/storyA_nodeA_take9.mp4",
    contentType: "image/png",
  });
  const result = await finalizeUploadWith(s.db, s.obj, depsOf(s));
  assert.equal(result.status, "rejected");
  assert.equal(result.uploadError, "invalid-type");
  const node = await nodeOf(s.db);
  assert.equal(node.videoStatus, "ready");
  assert.equal(node.videoUrl, "https://cdn.example/old.mp4");
  assert.equal(node.endHash, "hash-e1");
  assert.equal(node.uploadError, "invalid-type");
  assert.equal(s.processCalls, 0);
  assert.deepEqual(s.deleted, [s.obj.name]);
  assert.equal(node.uploadTakeId, "take9");
});

test("oversize upload is rejected with the node video untouched", async () => {
  const s = script({size: String(maxUploadBytes + 1)});
  const result = await finalizeUploadWith(s.db, s.obj, depsOf(s));
  assert.equal(result.status, "rejected");
  assert.equal(result.uploadError, "too-large");
  const node = await nodeOf(s.db);
  assert.equal(node.videoStatus, "ready");
  assert.equal(node.videoUrl, "https://cdn.example/old.mp4");
  assert.equal(s.processCalls, 0);
  assert.deepEqual(s.deleted, [s.obj.name]);
});

test("unparseable filename deletes the object, writes nothing", async () => {
  const s = script({name: "uploads/uidA/scene.mp4"});
  const before = JSON.stringify([...s.db.store.entries()]);
  const result = await finalizeUploadWith(s.db, s.obj, depsOf(s));
  assert.equal(result.status, "rejected");
  assert.equal(result.uploadError, "unknown-target");
  assert.equal(JSON.stringify([...s.db.store.entries()]), before);
  assert.deepEqual(s.deleted, ["uploads/uidA/scene.mp4"]);
});

test("objects outside uploads/ are ignored, never deleted", async () => {
  const s = script({name: "stories/storyA/nodeA-end-x.png"});
  const before = JSON.stringify([...s.db.store.entries()]);
  const result = await finalizeUploadWith(s.db, s.obj, depsOf(s));
  assert.equal(result.status, "ignored");
  assert.equal(JSON.stringify([...s.db.store.entries()]), before);
  assert.deepEqual(s.deleted, []);
  assert.equal(s.processCalls, 0);
});

test("second take replaces the first and resets approval", async () => {
  const s = script();
  const first = await finalizeUploadWith(s.db, s.obj, depsOf(s));
  assert.equal(first.status, "ready");
  await s.db
    .doc("stories/storyA/nodes/nodeA")
    .set({endImageApproved: true}, {merge: true});
  s.frameBytes = Buffer.from("last-frame-take-two");
  s.videoBytes = Buffer.from("video-take-two");
  s.obj = {...s.obj, generation: "8"};
  const result = await finalizeUploadWith(s.db, s.obj, depsOf(s));
  assert.equal(result.status, "ready");
  const node = await nodeOf(s.db);
  assert.equal(node.endHash, sha8("last-frame-take-two"));
  assert.equal(node.endImageApproved, false);
  assert.notEqual(node.videoUrl, first.videoUrl);
  assert.equal(node.uploadError, null);
});

test("duplicate finalize events process once", async () => {
  const s = script();
  const first = await finalizeUploadWith(s.db, s.obj, depsOf(s));
  assert.equal(first.status, "ready");
  const second = await finalizeUploadWith(s.db, s.obj, depsOf(s));
  assert.equal(second.status, "duplicate");
  assert.equal(s.processCalls, 1);
});

test("missing ffmpeg degrades to pending without throwing", async () => {
  const s = script({name: "uploads/uidA/storyA_nodeA_take9.mp4"});
  await s.db.doc("stories/storyA/nodes/nodeA").set(
    {videoStatus: "idle", videoUrl: null},
    {merge: true}
  );
  const result = await finalizeUploadWith(
    s.db,
    s.obj,
    depsOf(s, {hasTools: async () => false})
  );
  assert.equal(result.status, "pending");
  assert.equal(result.uploadError, "encode-unavailable");
  const node = await nodeOf(s.db);
  assert.equal(node.videoStatus, "pending");
  assert.equal(node.uploadError, "encode-unavailable");
  assert.equal(node.uploadTakeId, "take9");
  assert.deepEqual(s.deleted, [s.obj.name]);
});

test("missing ffmpeg keeps an existing ready video", async () => {
  const s = script();
  const result = await finalizeUploadWith(
    s.db,
    s.obj,
    depsOf(s, {hasTools: async () => false})
  );
  assert.equal(result.status, "pending");
  const node = await nodeOf(s.db);
  assert.equal(node.videoStatus, "ready");
  assert.equal(node.videoUrl, "https://cdn.example/old.mp4");
  assert.equal(node.uploadError, "encode-unavailable");
});
