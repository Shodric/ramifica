import {createHash} from "crypto";
import {strict as assert} from "assert";
import {test} from "node:test";
import {Db, DbCol, DbDoc, DbRef, DbTx} from "../feed/shared";
import {
  generateNodeImageWith,
  generateNodeVideoWith,
  NodeMediaDeps,
} from "../create/generateNodeMedia";

type Fields = {[field: string]: unknown};

/**
 * Voice retakes: there is no `generateNodeVoice` callable in
 * functions/src (voice today is node fields only: `ttsText`,
 * `lineApproved`, `ttsAudioUrl`, `ttsStatus`, `ttsDurationSeconds`,
 * with no backend generator). A voice "another take" has no backend
 * to re-dispatch yet; only image and video retakes are proven below.
 * Image and video need no new code: both generators overwrite bytes,
 * reset approvals, and desync per #47, so a same-params second call
 * is a new take by construction.
 */

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
   * Unused stub: retake tests never sort.
   * @param {string} field Field name.
   * @param {string} dir Sort direction.
   */
  orderBy(field: string, dir: "asc" | "desc" = "asc"): DbCol {
    void field;
    void dir;
    throw new Error("MemCol.orderBy is not stubbed.");
  }

  /**
   * Unused stub: retake tests never page.
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

/**
 * One author-owned root draft with approved S+E and a ready video.
 * @param {MemDb} db Backing store.
 */
const seedRoot = (db: MemDb): void => {
  db.store.set("stories/story_draft", {
    authorId: "uid_a",
    status: "draft",
    rootNodeId: "node_001",
  });
  db.store.set("stories/story_draft/nodes/node_001", {
    title: "Ridge",
    startHash: sha8("s1"),
    startImageSourceUrl: "https://cdn.example/s1.png",
    startImageStatus: "ready",
    startImageApproved: true,
    endHash: sha8("e1"),
    endImageSourceUrl: "https://cdn.example/e1.png",
    endImageStatus: "ready",
    endImageApproved: true,
    videoStatus: "ready",
    videoSource: "generated",
    videoUrl: "https://cdn.example/v1.mp4",
    videoFromHash: sha8("s1"),
    videoToHash: sha8("e1"),
    videoJobId: "job-1",
    ttsText: "Wind.",
    lineApproved: true,
    ttsAudioUrl: "https://cdn.example/v1.m4a",
    ttsStatus: "ready",
    ttsDurationSeconds: 2.1,
  });
};

/**
 * Still seams returning one canned take.
 * @param {string} take Take bytes stand-in.
 * @return {NodeMediaDeps} The mocked deps.
 */
const imageDeps = (take: string): NodeMediaDeps => ({
  imageGen: async () => ({bytes: Buffer.from(take)}),
  uploadStill: async (args) =>
    `https://cdn.example/${args.nodeId}-${args.which}-${args.hash}.png`,
});

/**
 * Video seams returning one canned job.
 * @param {string} jobId Job id stand-in.
 * @param {string} url Video URL stand-in.
 * @return {NodeMediaDeps} The mocked deps.
 */
const videoDeps = (jobId: string, url: string): NodeMediaDeps => ({
  requestVideo: async () => ({jobId, videoUrl: url}),
});

test("image retake replaces bytes and resets approval", async () => {
  const db = new MemDb();
  seedRoot(db);
  const first = await generateNodeImageWith(
    db,
    "uid_a",
    {storyId: "story_draft", nodeId: "node_001", which: "end"},
    imageDeps("take-one")
  );
  const second = await generateNodeImageWith(
    db,
    "uid_a",
    {storyId: "story_draft", nodeId: "node_001", which: "end"},
    imageDeps("take-two")
  );
  assert.notEqual(second.imageUrl, first.imageUrl);
  assert.equal(second.endHash, sha8("take-two"));
  const snap = await db.doc("stories/story_draft/nodes/node_001").get();
  const fields = snap.data();
  assert.ok(fields !== undefined);
  assert.equal(fields["endImageApproved"], false);
  assert.equal(fields["endHash"], sha8("take-two"));
  assert.equal(fields["videoStatus"], "idle");
  assert.equal(fields["videoUrl"], null);
});

test("video retake replaces the job", async () => {
  const db = new MemDb();
  seedRoot(db);
  const first = await generateNodeVideoWith(
    db,
    "uid_a",
    {storyId: "story_draft", nodeId: "node_001"},
    videoDeps("job-2", "https://cdn.example/v2.mp4")
  );
  const second = await generateNodeVideoWith(
    db,
    "uid_a",
    {storyId: "story_draft", nodeId: "node_001"},
    videoDeps("job-3", "https://cdn.example/v3.mp4")
  );
  assert.equal(first.videoJobId, "job-2");
  assert.equal(second.videoJobId, "job-3");
  assert.equal(second.videoUrl, "https://cdn.example/v3.mp4");
  assert.equal(second.videoStatus, "ready");
  const snap = await db.doc("stories/story_draft/nodes/node_001").get();
  const fields = snap.data();
  assert.ok(fields !== undefined);
  assert.equal(fields["videoJobId"], "job-3");
  assert.equal(fields["videoUrl"], "https://cdn.example/v3.mp4");
});
