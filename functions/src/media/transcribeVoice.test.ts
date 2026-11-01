import {strict as assert} from "assert";
import {test} from "node:test";
import {MetaFetch} from "./meta";
import {transcribeVoiceWith} from "./transcribeVoice";

/**
 * Canned ASR transport; answers every slice with the given payload.
 * @param {unknown} payload Answer the provider should return.
 * @param {number} status HTTP status to report.
 * @return {MetaFetch} The stub transport.
 */
const stubAsr = (payload: unknown, status = 200): MetaFetch => {
  return async () => ({
    ok: status >= 200 && status < 300,
    status,
    json: async () => payload,
    arrayBuffer: async () => new ArrayBuffer(0),
  });
};

/**
 * Base take payload; callers override the audio per take.
 * @param {string} audioBase64 Test audio.
 * @param {boolean} last Whether this is the last slice.
 * @return {object} Callable payload.
 */
const slice = (audioBase64: string, last = false): object => ({
  sessionId: "session_1",
  seq: 0,
  audioBase64,
  format: "wav",
  last,
});

test("a slice returns its text and never done", async () => {
  const result = await transcribeVoiceWith(
    "u1",
    slice("c2xpY2UtMQ=="),
    {apiKey: "test-key", fetchFn: stubAsr({transcript: "a dark"})}
  );
  assert.deepEqual(result, {text: "a dark", done: false});
});

test("each call transcribes its slice and the full take replaces", async () => {
  const deps = {apiKey: "test-key"};
  const first = await transcribeVoiceWith(
    "u1",
    {...slice("c2xpY2UtMQ=="), seq: 0},
    {...deps, fetchFn: stubAsr({transcript: "a dark"})}
  );
  const second = await transcribeVoiceWith(
    "u1",
    {...slice("c2xpY2UtMg=="), seq: 1},
    {...deps, fetchFn: stubAsr({transcript: "gate ahead"})}
  );
  // Each answer is the transcript of the bytes in that call. The client
  // replaces the screen text. It does not append these strings.
  assert.deepEqual(first, {text: "a dark", done: false});
  assert.deepEqual(second, {text: "gate ahead", done: false});
  const full = await transcribeVoiceWith(
    "u1",
    {...slice("ZnVsbA=="), seq: 2, last: true},
    {...deps, fetchFn: stubAsr({transcript: "a dark gate"})}
  );
  assert.deepEqual(full, {text: "a dark gate", done: false});
});

test("a silent slice returns blank text without failing", async () => {
  const result = await transcribeVoiceWith(
    "u1",
    slice("c2lsZW5jZQ=="),
    {apiKey: "test-key", fetchFn: stubAsr({})}
  );
  assert.deepEqual(result, {text: "", done: false});
});

test("rejects callers without a session", async () => {
  await assert.rejects(
    transcribeVoiceWith("", slice("eA=="), {apiKey: "k"}),
    (error: unknown) =>
      (error as {code?: string}).code === "unauthenticated"
  );
});

test("rejects slices without audio, session, or sequence", async () => {
  const deps = {apiKey: "k", fetchFn: stubAsr({transcript: "x"})};
  await assert.rejects(
    transcribeVoiceWith("u1", {...slice("eA=="), sessionId: " "}, deps),
    (error: unknown) =>
      (error as {code?: string}).code === "invalid-argument"
  );
  await assert.rejects(
    transcribeVoiceWith("u1", {...slice(""), audioBase64: " "}, deps),
    (error: unknown) =>
      (error as {code?: string}).code === "invalid-argument"
  );
  await assert.rejects(
    transcribeVoiceWith("u1", {...slice("eA=="), seq: -1}, deps),
    (error: unknown) =>
      (error as {code?: string}).code === "invalid-argument"
  );
});

test("needs a configured provider key", async () => {
  const apiKey = process.env.META_API_KEY;
  try {
    delete process.env.META_API_KEY;
    await assert.rejects(
      transcribeVoiceWith("u1", slice("eA=="), {
        fetchFn: stubAsr({transcript: "x"}),
      }),
      (error: unknown) =>
        (error as {code?: string}).code === "failed-precondition"
    );
  } finally {
    if (apiKey === undefined) delete process.env.META_API_KEY;
    else process.env.META_API_KEY = apiKey;
  }
});

test("surfaces provider outages", async () => {
  await assert.rejects(
    transcribeVoiceWith("u1", slice("eA=="), {
      apiKey: "test-key",
      fetchFn: stubAsr({}, 503),
    }),
    (error: unknown) => (error as {code?: string}).code === "unavailable"
  );
});
