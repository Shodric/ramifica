import {execFile} from "child_process";
import {mkdtemp, rm} from "fs/promises";
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
