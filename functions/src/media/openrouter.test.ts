import {strict as assert} from "assert";
import {test} from "node:test";
import {
  checkVideo,
  completeChat,
  downloadBytes,
  generateImageBytes,
  getJson,
  OpenRouterFetch,
  OpenRouterHttpError,
  postBytes,
  postJson,
  submitVideo,
  speakText,
  videoContentUrl,
} from "./openrouter";

/** Captured request for body/header assertions. */
interface SeenRequest {
  url: string;
  init: {method: string; headers: Record<string, string>; body?: string};
}

/**
 * Canned transport; records the request and answers with canned JSON.
 * @param {unknown} payload Decoded JSON the provider should return.
 * @param {number} status HTTP status to report.
 * @param {SeenRequest[]} seen Sink for the captured request.
 * @return {OpenRouterFetch} The stub transport.
 */
const stubJson = (
  payload: unknown,
  status: number,
  seen: SeenRequest[]
): OpenRouterFetch => {
  return async (url: string, init) => {
    seen.push({url, init});
    return {
      ok: status >= 200 && status < 300,
      status,
      json: async () => payload,
      arrayBuffer: async () => new ArrayBuffer(0),
    };
  };
};

/**
 * Canned byte transport; answers with the given bytes.
 * @param {Buffer} bytes Raw bytes the provider should return.
 * @param {SeenRequest[]} seen Sink for the captured request.
 * @return {OpenRouterFetch} The stub transport.
 */
const stubBytes = (bytes: Buffer, seen: SeenRequest[]): OpenRouterFetch => {
  return async (url: string, init) => {
    seen.push({url, init});
    const copy = new ArrayBuffer(bytes.length);
    Buffer.from(copy).set(bytes);
    return {
      ok: true,
      status: 200,
      json: async () => ({}),
      arrayBuffer: async () => copy,
    };
  };
};

/**
 * Asserts the rejection carries the provider status.
 * @param {Promise<unknown>} pending Promise under test.
 * @param {number} expected Expected provider status.
 * @return {Promise<void>} When the assertion passes.
 */
const rejectsStatus = async (
  pending: Promise<unknown>,
  expected: number
): Promise<void> => {
  await assert.rejects(pending, (error: unknown) => {
    return error instanceof OpenRouterHttpError && error.status === expected;
  });
};

test("postJson sends auth headers and decodes the answer", async () => {
  const seen: SeenRequest[] = [];
  const payload = {choices: [{message: {content: "hi"}}]};
  const out = await postJson("https://example.com/chat", {
    apiKey: "key-1",
    body: {model: "m"},
    fetchFn: stubJson(payload, 200, seen),
  });
  assert.deepEqual(out, payload);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].init.method, "POST");
  assert.equal(seen[0].init.headers["Authorization"], "Bearer key-1");
  assert.equal(seen[0].init.headers["HTTP-Referer"], "https://ramifica.app");
  assert.deepEqual(JSON.parse(seen[0].init.body ?? ""), {model: "m"});
});

test("postJson failures carry the status", async () => {
  await rejectsStatus(
    postJson("https://example.com/chat", {
      apiKey: "key-1",
      body: {},
      fetchFn: stubJson({}, 429, []),
    }),
    429
  );
});

test("getJson polls with GET and auth", async () => {
  const seen: SeenRequest[] = [];
  const out = await getJson("https://example.com/videos/abc", {
    apiKey: "key-1",
    fetchFn: stubJson({status: "pending"}, 200, seen),
  });
  assert.deepEqual(out, {status: "pending"});
  assert.equal(seen[0].init.method, "GET");
  assert.equal(seen[0].init.headers["Authorization"], "Bearer key-1");
});

test("byte transports return raw buffers", async () => {
  const pcm = Buffer.from([1, 2, 3, 4]);
  const dumped = await postBytes("https://example.com/speech", {
    apiKey: "key-1",
    body: {input: "hi"},
    fetchFn: stubBytes(pcm, []),
  });
  assert.ok(Buffer.isBuffer(dumped));
  assert.deepEqual([...dumped], [1, 2, 3, 4]);
  const clip = await downloadBytes("https://example.com/content", {
    apiKey: "key-1",
    fetchFn: stubBytes(pcm, []),
  });
  assert.deepEqual([...clip], [1, 2, 3, 4]);
  await rejectsStatus(
    downloadBytes("https://example.com/content", {
      apiKey: "key-1",
      fetchFn: stubJson({}, 500, []),
    }),
    500
  );
});

test("completeChat returns the first choice content", async () => {
  const seen: SeenRequest[] = [];
  const out = await completeChat({
    apiKey: "key-1",
    model: "model-x",
    system: "sys",
    user: "usr",
    maxTokens: 500,
    fetchFn: stubJson({choices: [{message: {content: "line"}}]}, 200, seen),
  });
  assert.equal(out, "line");
  const body = JSON.parse(seen[0].init.body ?? "");
  assert.equal(body.model, "model-x");
  assert.equal(body.max_tokens, 500);
  assert.deepEqual(body.messages, [
    {role: "system", content: "sys"},
    {role: "user", content: "usr"},
  ]);
});

test("completeChat blanks off-shape answers", async () => {
  const blank = {
    apiKey: "key-1",
    model: "m",
    system: "s",
    user: "u",
  };
  assert.equal(
    await completeChat({...blank, fetchFn: stubJson({}, 200, [])}),
    ""
  );
  assert.equal(
    await completeChat({
      ...blank,
      fetchFn: stubJson({choices: [{message: {}}]}, 200, []),
    }),
    ""
  );
});

test("speakText posts the TTS body and keeps the seed title", async () => {
  const seen: SeenRequest[] = [];
  const out = await speakText({
    apiKey: "key-1",
    model: "tts-m",
    voice: "Kore",
    text: "hello",
    instructions: "narrate",
    fetchFn: stubBytes(Buffer.from([9]), seen),
  });
  assert.deepEqual([...out], [9]);
  assert.equal(seen[0].init.headers["X-Title"], "Ramifica seed");
  assert.deepEqual(JSON.parse(seen[0].init.body ?? ""), {
    model: "tts-m",
    input: "hello",
    voice: "Kore",
    response_format: "pcm",
    instructions: "narrate",
  });
});

test("generateImageBytes decodes the first payload", async () => {
  const png = Buffer.from("fake-png");
  const out = await generateImageBytes({
    apiKey: "key-1",
    model: "img-m",
    prompt: "a gate",
    size: "480x854",
    fetchFn: stubJson(
      {data: [{b64_json: png.toString("base64")}]},
      200,
      []
    ),
  });
  assert.deepEqual([...out], [...png]);
  await assert.rejects(
    generateImageBytes({
      apiKey: "key-1",
      model: "img-m",
      prompt: "a gate",
      size: "480x854",
      fetchFn: stubJson({data: []}, 200, []),
    }),
    /nothing usable/
  );
});

test("submitVideo posts the start frame and omits unset fields", async () => {
  const seen: SeenRequest[] = [];
  const out = await submitVideo({
    apiKey: "key-1",
    model: "vid-m",
    prompt: "morph",
    startUrl: "https://cdn.example/s.png",
    resolution: "768p",
    aspectRatio: "9:16",
    duration: 6,
    fetchFn: stubJson({id: "job-1"}, 202, seen),
  });
  assert.deepEqual(out, {jobId: "job-1"});
  assert.deepEqual(JSON.parse(seen[0].init.body ?? ""), {
    model: "vid-m",
    prompt: "morph",
    frame_images: [
      {
        type: "image_url",
        image_url: {url: "https://cdn.example/s.png"},
        frame_type: "first_frame",
      },
    ],
    resolution: "768p",
    aspect_ratio: "9:16",
    duration: 6,
  });
  await assert.rejects(
    submitVideo({
      apiKey: "key-1",
      model: "vid-m",
      prompt: "morph",
      startUrl: "s",
      fetchFn: stubJson({}, 202, []),
    }),
    /no job id/
  );
});

test("submitVideo adds the last frame when the provider takes it", async () => {
  const seen: SeenRequest[] = [];
  await submitVideo({
    apiKey: "key-1",
    model: "vid-m",
    prompt: "morph",
    startUrl: "https://cdn.example/s.png",
    endUrl: "https://cdn.example/e.png",
    generateAudio: true,
    fetchFn: stubJson({id: "job-1"}, 202, seen),
  });
  assert.deepEqual(JSON.parse(seen[0].init.body ?? ""), {
    model: "vid-m",
    prompt: "morph",
    frame_images: [
      {
        type: "image_url",
        image_url: {url: "https://cdn.example/s.png"},
        frame_type: "first_frame",
      },
      {
        type: "image_url",
        image_url: {url: "https://cdn.example/e.png"},
        frame_type: "last_frame",
      },
    ],
    generate_audio: true,
  });
});

test("custom video endpoint stays consistent across submit, poll and content",
  async () => {
    const before = process.env.OPENROUTER_VIDEOS_URL;
    try {
      process.env.OPENROUTER_VIDEOS_URL = "https://router.example/v2/jobs/";
      const seen: SeenRequest[] = [];
      await submitVideo({
        apiKey: "test-key", model: "custom", prompt: "scene", startUrl: "s",
        fetchFn: stubJson({id: "job-9"}, 202, seen),
      });
      const result = await checkVideo({
        apiKey: "test-key", jobId: "job-9",
        fetchFn: stubJson({status: "completed"}, 200, seen),
      });
      assert.deepEqual(seen.map((request) => request.url), [
        "https://router.example/v2/jobs",
        "https://router.example/v2/jobs/job-9",
      ]);
      assert.equal(result.videoUrl,
        "https://router.example/v2/jobs/job-9/content?index=0");
    } finally {
      if (before === undefined) delete process.env.OPENROUTER_VIDEOS_URL;
      else process.env.OPENROUTER_VIDEOS_URL = before;
    }
  });

test("checkVideo maps statuses and prefers unsigned urls", async () => {
  const base = {apiKey: "key-1", jobId: "job-1"};
  const pending = await checkVideo({
    ...base,
    fetchFn: stubJson({status: "pending"}, 200, []),
  });
  assert.deepEqual(pending, {status: "pending"});
  const progress = await checkVideo({
    ...base,
    fetchFn: stubJson({status: "in_progress"}, 200, []),
  });
  assert.deepEqual(progress, {status: "in_progress"});
  const done = await checkVideo({
    ...base,
    fetchFn: stubJson(
      {status: "completed", unsigned_urls: ["https://cdn.example/v.mp4"]},
      200,
      []
    ),
  });
  assert.deepEqual(done, {
    status: "completed",
    videoUrl: "https://cdn.example/v.mp4",
  });
  const fallback = await checkVideo({
    ...base,
    fetchFn: stubJson({status: "completed"}, 200, []),
  });
  assert.deepEqual(fallback, {
    status: "completed",
    videoUrl: videoContentUrl("job-1"),
  });
  const failed = await checkVideo({
    ...base,
    fetchFn: stubJson({status: "failed"}, 200, []),
  });
  assert.deepEqual(failed, {status: "failed"});
  const odd = await checkVideo({
    ...base,
    fetchFn: stubJson({status: 7}, 200, []),
  });
  assert.deepEqual(odd, {status: "pending"});
});

test("checkVideo failures carry the status", async () => {
  await rejectsStatus(
    checkVideo({
      apiKey: "key-1",
      jobId: "gone",
      fetchFn: stubJson({}, 404, []),
    }),
    404
  );
});
