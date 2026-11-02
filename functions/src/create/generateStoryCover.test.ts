import {strict as assert} from "assert";
import {test} from "node:test";
import {Db, DbCol, DbDoc, DbRef, DbTx} from "../feed/shared";
import {
  buildCoverPrompt,
  generateStoryCoverWith,
} from "./generateStoryCover";

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

/** In-memory collection. Cover tests never query; the stub satisfies Db. */
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
   */
  where(field: string, op: string, value: unknown): DbCol {
    void field;
    void op;
    void value;
    throw new Error("MemCol.where is not stubbed.");
  }

  /**
   * @param {string} field Field name.
   * @param {string} dir Sort direction.
   */
  orderBy(field: string, dir: "asc" | "desc" = "asc"): DbCol {
    void field;
    void dir;
    throw new Error("MemCol.orderBy is not stubbed.");
  }

  /**
   * @param {number} n Max docs.
   */
  limit(n: number): DbCol {
    void n;
    throw new Error("MemCol.limit is not stubbed.");
  }

  /** @return {Promise<Object>} No docs. */
  async get(): Promise<{empty: boolean; docs: DbDoc[]}> {
    return {empty: true, docs: []};
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
 * Seeds one draft story.
 * @param {MemDb} db Backing store.
 * @param {Fields} overrides Field overrides.
 */
const seedStory = (db: MemDb, overrides: Fields = {}): void => {
  db.store.set("stories/story_1", {
    authorId: "uid_1",
    title: "Temple",
    synopsis: "A descent.",
    status: "draft",
    rootNodeId: "node_1",
    revision: 0,
    ...overrides,
  });
};

/**
 * Runs the callable expecting an HttpsError with the given code.
 * @param {Promise<unknown>} call The in-flight call.
 * @param {string} code The expected error code.
 */
const rejectsWith = async (
  call: Promise<unknown>,
  code: string
): Promise<void> => {
  await assert.rejects(call, (error: unknown) => {
    assert.equal((error as {code?: unknown}).code, code);
    return true;
  });
};

test("buildCoverPrompt pins the key-art copy", () => {
  const prompt = buildCoverPrompt({title: "Temple", synopsis: "A descent."});
  assert.match(prompt, /Vertical 9:16 cinematic key art/);
  assert.match(prompt, /STORY: "Temple" — A descent\./);
  assert.match(prompt, /COVER:/);
  assert.match(prompt, /no text, no watermark, no logo/);
});

test("buildCoverPrompt falls back on blank fields", () => {
  const prompt = buildCoverPrompt({title: "  ", synopsis: ""});
  assert.match(prompt, /STORY: "Untitled story"\./);
});

test("cover rejects a blank caller", async () => {
  const db = new MemDb();
  seedStory(db);
  await rejectsWith(
    generateStoryCoverWith(db, "  ", {storyId: "story_1"}),
    "unauthenticated"
  );
});

test("cover rejects a blank story id", async () => {
  const db = new MemDb();
  seedStory(db);
  await rejectsWith(
    generateStoryCoverWith(db, "uid_1", {storyId: "  "}),
    "invalid-argument"
  );
});

test("cover rejects unknown stories", async () => {
  const db = new MemDb();
  await rejectsWith(
    generateStoryCoverWith(db, "uid_1", {storyId: "missing"}),
    "not-found"
  );
});

test("cover rejects foreign drafts", async () => {
  const db = new MemDb();
  seedStory(db);
  await rejectsWith(
    generateStoryCoverWith(db, "uid_2", {storyId: "story_1"}),
    "permission-denied"
  );
});

test("cover rejects published stories", async () => {
  const db = new MemDb();
  seedStory(db, {status: "published"});
  await rejectsWith(
    generateStoryCoverWith(db, "uid_1", {storyId: "story_1"}),
    "failed-precondition"
  );
});

test("cover rejects an overlong prompt", async () => {
  const db = new MemDb();
  seedStory(db);
  await rejectsWith(
    generateStoryCoverWith(
      db, "uid_1", {storyId: "story_1", prompt: "x".repeat(2001)}
    ),
    "invalid-argument"
  );
});

test("cover fails with a reason and keeps the last bytes", async () => {
  const db = new MemDb();
  seedStory(db, {coverUrl: "https://cdn.invalid/old.webp"});
  await rejectsWith(
    generateStoryCoverWith(db, "uid_1", {storyId: "story_1"}, {}),
    "failed-precondition"
  );
  const story = db.store.get("stories/story_1");
  assert.equal(story?.coverStatus, "failed");
  assert.equal(story?.coverUrl, "https://cdn.invalid/old.webp");
});

test("cover generates, converts, uploads, and points the story", async () => {
  const db = new MemDb();
  seedStory(db);
  const seen: string[] = [];
  const uploads: string[] = [];
  const result = await generateStoryCoverWith(
    db,
    "uid_1",
    {storyId: "story_1"},
    {
      imageGen: async (prompt: string) => {
        seen.push(prompt);
        return {bytes: Buffer.from("raw-still")};
      },
      normalizeImage: async (bytes: Buffer) => ({
        bytes: Buffer.concat([Buffer.from("png:"), bytes]),
        width: 480,
        height: 854,
      }),
      convertArt: async (png: Buffer) => ({
        webp: Buffer.concat([Buffer.from("webp:"), png]),
        og: Buffer.concat([Buffer.from("og:"), png]),
      }),
      uploadCover: async (args) => {
        uploads.push(`${args.name}:${args.contentType}`);
        return `https://cdn.invalid/${args.name}`;
      },
    }
  );
  assert.match(seen[0], /Temple/);
  assert.match(result.coverUrl, /\.webp$/);
  assert.match(result.ogImageUrl, /\.jpg$/);
  assert.equal(result.coverStatus, "ready");
  assert.equal(result.width, 480);
  assert.equal(result.height, 854);
  assert.deepEqual(uploads, [
    "cover-c5f21771-480.webp:image/webp",
    "og-c5f21771-1200.jpg:image/jpeg",
    "cover-c5f21771.png:image/png",
  ]);
  const story = db.store.get("stories/story_1");
  assert.equal(story?.coverUrl, result.coverUrl);
  assert.equal(story?.ogImageUrl, result.ogImageUrl);
  assert.equal(story?.coverStatus, "ready");
  assert.equal(story?.revision, 1);
});

test("cover honors the prompt override", async () => {
  const db = new MemDb();
  seedStory(db);
  const seen: string[] = [];
  await generateStoryCoverWith(
    db,
    "uid_1",
    {storyId: "story_1", prompt: "A lighthouse at dawn."},
    {
      imageGen: async (prompt: string) => {
        seen.push(prompt);
        return {bytes: Buffer.from("raw")};
      },
      normalizeImage: async (bytes: Buffer) => ({bytes, width: 1, height: 1}),
      convertArt: async (png: Buffer) => ({webp: png, og: png}),
      uploadCover: async (args) => `https://cdn.invalid/${args.name}`,
    }
  );
  assert.deepEqual(seen, ["A lighthouse at dawn."]);
});

test("cover marks the story failed when the provider throws", async () => {
  const db = new MemDb();
  seedStory(db, {coverUrl: "https://cdn.invalid/old.webp"});
  await rejectsWith(
    generateStoryCoverWith(
      db,
      "uid_1",
      {storyId: "story_1"},
      {
        imageGen: async () => {
          throw new Error("provider down");
        },
      }
    ),
    "internal"
  );
  const story = db.store.get("stories/story_1");
  assert.equal(story?.coverStatus, "failed");
  assert.equal(story?.coverError, "provider down");
  assert.equal(story?.coverUrl, "https://cdn.invalid/old.webp");
});
