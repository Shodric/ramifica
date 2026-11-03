import {strict as assert} from "assert";
import {test} from "node:test";
import {Db, DbDoc, DbRef} from "../feed/shared";
import {createVideoUploadUrlWith} from "./createVideoUploadUrl";

type Fields = {[field: string]: unknown};

/** In-memory store with one draft, one node, one foreign story. */
class MemDb implements Db {
  private readonly store = new Map<string, Fields>([
    ["stories/story_draft", {
      authorId: "u1",
      title: "The temple",
      status: "draft",
      rootNodeId: "node_001",
    }],
    ["stories/story_draft/nodes/node_001", {title: "Old title"}],
    ["stories/story_foreign", {
      authorId: "u2",
      title: "Foreign",
      status: "draft",
      rootNodeId: "node_001",
    }],
    ["stories/story_live", {
      authorId: "u1",
      title: "Live",
      status: "published",
      rootNodeId: "node_001",
    }],
  ]);

  /**
   * In-memory doc reference backed by the shared store.
   * @param {string} path Document path.
   * @return {DbRef} Reference reading from the store.
   */
  doc(path: string): DbRef {
    const fields = this.store.get(path);
    const snapshot: DbDoc = {
      exists: fields !== undefined,
      id: path.slice(path.lastIndexOf("/") + 1),
      data: () => fields === undefined ?
        undefined :
        JSON.parse(JSON.stringify(fields)),
    };
    return {
      id: snapshot.id,
      get: async () => snapshot,
      set: async () => {
        throw new Error("read-only");
      },
      update: async () => {
        throw new Error("read-only");
      },
    };
  }

  /** Unused collection path for the mint flow. */
  collection(): never {
    throw new Error("unused");
  }

  /** Unused transaction path for the mint flow. */
  runTransaction(): never {
    throw new Error("unused");
  }
}

const fields = {
  storyId: "story_draft",
  nodeId: "node_001",
  takeId: "take1",
  contentType: "video/mp4",
  byteLength: 12,
};

/**
 * Stub session initiation answering with one session URI.
 * @param {Array<Object>} seen Captures the request URL and init.
 * @param {string} session The session URI to answer.
 * @return {Function} The stub transport.
 */
const stubSession = (
  seen: Array<{url: unknown; init: unknown}>,
  session: string
): typeof fetch =>
  (async (url, init) => {
    seen.push({url, init});
    return {
      ok: true,
      headers: new Headers({location: session}),
    } as Response;
  }) as typeof fetch;

test("mints a resumable session for the uploads path", async () => {
  const db = new MemDb();
  const seen: Array<{url: unknown; init: unknown}> = [];
  const result = await createVideoUploadUrlWith(db, "u1", fields, {
    bucketName: "bkt",
    emulatorHost: null,
    accessToken: async () => "stub-token-7",
    fetchFn: stubSession(seen, "https://session.invalid/abc"),
  });
  assert.equal(result.method, "PUT");
  assert.equal(result.resumable, true);
  assert.equal(result.path, "uploads/u1/story_draft_node_001_take1.mp4");
  assert.equal(result.uploadUrl, "https://session.invalid/abc");
  assert.equal(seen.length, 1);
  assert.equal(
    seen[0].url,
    "https://storage.googleapis.com/upload/storage/v1/b/bkt/o" +
      "?uploadType=resumable"
  );
  const init = seen[0].init as {
    method: string;
    headers: Record<string, string>;
    body: string;
  };
  assert.equal(init.method, "POST");
  assert.equal(init.headers["Authorization"], "Bearer stub-token-7");
  assert.equal(init.headers["X-Upload-Content-Type"], "video/mp4");
  assert.equal(init.headers["X-Upload-Content-Length"], "12");
  assert.deepEqual(JSON.parse(init.body), {
    name: "uploads/u1/story_draft_node_001_take1.mp4",
    contentType: "video/mp4",
  });
});

test("quicktime takes the mov extension", async () => {
  const db = new MemDb();
  const result = await createVideoUploadUrlWith(
    db,
    "u1",
    {...fields, contentType: "video/quicktime"},
    {
      bucketName: "bkt",
      emulatorHost: null,
      accessToken: async () => "tok",
      fetchFn: stubSession([], "https://session.invalid/abc"),
    }
  );
  assert.equal(result.path, "uploads/u1/story_draft_node_001_take1.mov");
});

test("the emulator answers a one-shot media URL", async () => {
  const db = new MemDb();
  const result = await createVideoUploadUrlWith(db, "u1", fields, {
    bucketName: "demo-ramifica.appspot.com",
    emulatorHost: "127.0.0.1:9199",
    accessToken: async () => {
      throw new Error("must not start a session in the emulator");
    },
  });
  assert.equal(result.method, "POST");
  assert.equal(result.resumable, false);
  assert.equal(
    result.uploadUrl,
    "http://127.0.0.1:9199/upload/storage/v1/b/" +
      "demo-ramifica.appspot.com/o" +
      "?uploadType=media&name=" +
      encodeURIComponent("uploads/u1/story_draft_node_001_take1.mp4")
  );
});

test("a failed initiation surfaces unavailable", async () => {
  const db = new MemDb();
  const fetchFn = (async () => ({
    ok: false,
    headers: new Headers(),
  })) as unknown as typeof fetch;
  await assert.rejects(
    createVideoUploadUrlWith(db, "u1", fields, {
      bucketName: "bkt",
      emulatorHost: null,
      accessToken: async () => "tok",
      fetchFn,
    }),
    /Could not start the upload session/
  );
});

test("rejects bad ids, types, and sizes before minting", async () => {
  const db = new MemDb();
  const deps = {
    bucketName: "bkt",
    emulatorHost: null,
    accessToken: async () => {
      throw new Error("must not mint rejected uploads");
    },
  };
  const cases: unknown[] = [
    {...fields, takeId: "has_underscore"},
    {...fields, contentType: "video/webm"},
    {...fields, byteLength: 0},
    {...fields, byteLength: 11 * 1024 * 1024},
    {...fields, byteLength: "12"},
    {...fields, storyId: "story_missing"},
    {...fields, nodeId: "node_missing"},
    {...fields, storyId: "story_foreign"},
    {...fields, storyId: "story_live"},
  ];
  for (const data of cases) {
    await assert.rejects(createVideoUploadUrlWith(db, "u1", data, deps));
  }
  await assert.rejects(createVideoUploadUrlWith(db, "", fields, deps));
});
