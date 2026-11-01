import {execFile} from "child_process";
import {mkdtemp, rm, writeFile} from "fs/promises";
import {tmpdir} from "os";
import {existsSync} from "fs";
import {join} from "path";
import {strict as assert} from "assert";
import {test} from "node:test";
import {promisify} from "util";
import {ffmpegBin} from "./bin";
import {convertVoiceToM4a, synthesizePcm} from "./voice";

const run = promisify(execFile);

test("convertVoiceToM4a normalizes a wav take", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ramifica-voice-"));
  try {
    const src = join(dir, "take.wav");
    await run(ffmpegBin(), [
      "-y",
      "-v",
      "error",
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=2",
      "-ar",
      "44100",
      "-ac",
      "2",
      src,
    ]);
    const out = await convertVoiceToM4a(src, dir);
    assert.equal(existsSync(out.path), true);
    assert.equal(Math.abs(out.durationSeconds - 2) < 0.3, true);
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
});

test("raw PCM decoding honors the configured sample rate", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ramifica-pcm-"));
  try {
    const src = join(dir, "take.pcm");
    await writeFile(src, Buffer.alloc(16000 * 2));
    const out = await convertVoiceToM4a(src, dir, 16000);
    assert.ok(Math.abs(out.durationSeconds - 1) < 0.05);
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
});

test("TTS uses the configured URL and model without a hardcoded bypass",
  async () => {
    const env = {
      OPENROUTER_TTS_MODEL: "vendor/custom-tts",
      OPENROUTER_SPEECH_URL: "https://speech.example/v2/speak",
    };
    const before = Object.fromEntries(
      Object.keys(env).map((key) => [key, process.env[key]])
    );
    try {
      Object.assign(process.env, env);
      let seenUrl = "";
      let seenBody: Record<string, unknown> = {};
      await synthesizePcm({
        apiKey: "test-key", voice: "custom-voice", text: "Hola.",
        fetchFn: async (url, init) => {
          seenUrl = url;
          seenBody = JSON.parse(init.body ?? "{}");
          return {
            ok: true, status: 200, json: async () => ({}),
            arrayBuffer: async () => new ArrayBuffer(2),
          };
        },
      });
      assert.equal(seenUrl, "https://speech.example/v2/speak");
      assert.equal(seenBody.model, "vendor/custom-tts");
      assert.equal(seenBody.voice, "custom-voice");
      assert.equal(seenBody.response_format, "pcm");
    } finally {
      for (const [key, value] of Object.entries(before)) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
    }
  });

test(
  "synthesizePcm needs credentials",
  {skip: !process.env.OPENROUTER_API_KEY},
  async () => {
    const pcm = await synthesizePcm({
      apiKey: process.env.OPENROUTER_API_KEY as string,
      voice: "Kore",
      text: "Hola.",
    });
    assert.equal(pcm.length > 1000, true);
  }
);
