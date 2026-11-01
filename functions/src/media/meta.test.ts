import {strict as assert} from "assert";
import {test} from "node:test";
import {
  completeChatMeta,
  generateImageMeta,
  metaGetJson,
  MetaFetch,
  MetaHttpError,
  metaPostJson,
  transcribeAudioMeta,
} from "./meta";

/** Captured request for body/header assertions. */
interface SeenRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string | FormData;
}

/**
 * Canned transport; records the request and answers with canned JSON.
 * @param {unknown} payload Answer the provider should return.
 * @param {number} status HTTP status to report.
 * @param {SeenRequest[]} seen Sink for the captured request.
 * @return {MetaFetch} The stub transport.
 */
const stubJson = (
  payload: unknown,
  status: number,
  seen: SeenRequest[]
): MetaFetch => {
  return async (url, init) => {
    seen.push({
      url,
      method: init.method,
      headers: init.headers,
      body: init.body,
    });
    return {
      ok: status >= 200 && status < 300,
      status,
      json: async () => payload,
      arrayBuffer: async () => new ArrayBuffer(0),
    };
  };
};

/**
 * Asserts the rejection carries the provider status.
 * @param {Promise<unknown>} pending Call expected to fail.
 * @param {number} expected HTTP status the error should carry.
 */
const rejectsStatus = async (
  pending: Promise<unknown>,
  expected: number
): Promise<void> => {
  await assert.rejects(pending, (error: unknown) => {
    assert.ok(error instanceof MetaHttpError);
    assert.equal(error.status, expected);
    return true;
  });
};

test("metaPostJson sends bearer auth and decodes the answer", async () => {
  const seen: SeenRequest[] = [];
  const answer = await metaPostJson("https://api.meta.ai/v1/chat/completions", {
    apiKey: "meta-key",
    body: {model: "m", messages: []},
    fetchFn: stubJson({ok: true}, 200, seen),
  });
  assert.deepEqual(answer, {ok: true});
  assert.equal(seen.length, 1);
  assert.equal(seen[0].method, "POST");
  assert.equal(seen[0].headers.Authorization, "Bearer meta-key");
  assert.equal(seen[0].headers["Content-Type"], "application/json");
});

test("metaPostJson failures carry the status", async () => {
  await rejectsStatus(
    metaPostJson("https://api.meta.ai/v1/chat/completions", {
      apiKey: "meta-key",
      body: {},
      fetchFn: stubJson({}, 429, []),
    }),
    429
  );
});

test("metaGetJson polls with GET and auth", async () => {
  const seen: SeenRequest[] = [];
  const answer = await metaGetJson("https://api.meta.ai/v1/x", {
    apiKey: "meta-key",
    fetchFn: stubJson({status: "completed"}, 200, seen),
  });
  assert.deepEqual(answer, {status: "completed"});
  assert.equal(seen[0].method, "GET");
  assert.equal(seen[0].headers.Authorization, "Bearer meta-key");
});

test("completeChatMeta returns the first choice content", async () => {
  const seen: SeenRequest[] = [];
  const text = await completeChatMeta({
    apiKey: "meta-key",
    model: "muse-spark-1.3-contributor",
    system: "sys",
    user: "user",
    maxTokens: 500,
    fetchFn: stubJson(
      {choices: [{message: {content: "hello"}}]},
      200,
      seen
    ),
  });
  assert.equal(text, "hello");
  const body = JSON.parse((seen[0].body as string) ?? "{}");
  assert.equal(body.model, "muse-spark-1.3-contributor");
  assert.equal(body.max_tokens, 500);
  assert.deepEqual(body.messages, [
    {role: "system", content: "sys"},
    {role: "user", content: "user"},
  ]);
});

test("completeChatMeta blanks off-shape answers", async () => {
  const text = await completeChatMeta({
    apiKey: "meta-key",
    model: "m",
    system: "sys",
    user: "user",
    fetchFn: stubJson({choices: [{message: {}}]}, 200, []),
  });
  assert.equal(text, "");
});

test("all Meta transports use runtime endpoint overrides", async () => {
  const env = {
    META_BASE_URL: "https://proxy.example/meta/v2/",
    META_TRANSCRIBE_URL: "https://asr.example/take",
  };
  const before = Object.fromEntries(
    Object.keys(env).map((key) => [key, process.env[key]])
  );
  try {
    Object.assign(process.env, env);
    const seen: SeenRequest[] = [];
    await completeChatMeta({
      apiKey: "test-key", model: "custom", system: "s", user: "u",
      fetchFn: stubJson({choices: []}, 200, seen),
    });
    await generateImageMeta({
      apiKey: "test-key", model: "custom", prompt: "scene", size: "480x854",
      fetchFn: stubJson({data: [{b64_json: "eA=="}]}, 200, seen),
    });
    await transcribeAudioMeta({
      apiKey: "test-key", model: "custom", audioBase64: "eA==", format: "wav",
      fetchFn: stubJson({text: "word"}, 200, seen),
    });
    assert.deepEqual(seen.map((request) => request.url), [
      "https://proxy.example/meta/v2/chat/completions",
      "https://proxy.example/meta/v2/images/generations",
      "https://asr.example/take",
    ]);
  } finally {
    for (const [key, value] of Object.entries(before)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});

test("generateImageMeta decodes the first payload", async () => {
  const bytes = Buffer.from("fake-png");
  const out = await generateImageMeta({
    apiKey: "meta-key",
    model: "muse-image-1.0",
    prompt: "a gate",
    size: "480x854",
    fetchFn: stubJson(
      {data: [{b64_json: bytes.toString("base64")}]},
      200,
      []
    ),
  });
  assert.deepEqual(out, bytes);
});

test("generateImageMeta rejects imageless answers", async () => {
  await assert.rejects(
    generateImageMeta({
      apiKey: "meta-key",
      model: "m",
      prompt: "a gate",
      size: "480x854",
      fetchFn: stubJson({data: []}, 200, []),
    })
  );
});

test("transcribeAudioMeta returns the take text", async () => {
  const seen: SeenRequest[] = [];
  const text = await transcribeAudioMeta({
    apiKey: "meta-key",
    model: "muse-voice-transcribe-1.0",
    audioBase64: "AAAA",
    format: "wav",
    fetchFn: stubJson({transcript: "a dark gate"}, 200, seen),
  });
  assert.equal(text, "a dark gate");
  assert.equal(seen[0].headers.Authorization, "Bearer meta-key");
  const form = seen[0].body as FormData;
  const request = JSON.parse(String(form.get("request")));
  assert.equal(request.model, "muse-voice-transcribe-1.0");
  assert.equal(request.audioEncoding, "WAV");
  const audio = form.get("audio");
  assert.ok(audio instanceof Blob);
  assert.equal((audio as Blob).type, "audio/wav");
});

test("transcribeAudioMeta falls back to the text field", async () => {
  const text = await transcribeAudioMeta({
    apiKey: "meta-key",
    model: "m",
    audioBase64: "AAAA",
    format: "wav",
    fetchFn: stubJson({text: "drift"}, 200, []),
  });
  assert.equal(text, "drift");
});

test("transcribeAudioMeta blanks voiceless takes", async () => {
  const text = await transcribeAudioMeta({
    apiKey: "meta-key",
    model: "m",
    audioBase64: "AAAA",
    format: "wav",
    fetchFn: stubJson({}, 200, []),
  });
  assert.equal(text, "");
});

test("transcribe failures carry the status", async () => {
  await rejectsStatus(
    transcribeAudioMeta({
      apiKey: "meta-key",
      model: "m",
      audioBase64: "AAAA",
      format: "wav",
      fetchFn: stubJson({}, 503, []),
    }),
    503
  );
});
