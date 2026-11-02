import {execFile} from "child_process";
import {mkdtemp, rm} from "fs/promises";
import {tmpdir} from "os";
import {join} from "path";
import {strict as assert} from "assert";
import {test} from "node:test";
import {promisify} from "util";
import {ffmpegBin, ffprobeBin} from "./bin";
import {
  contentHash8,
  convertCover,
} from "./images";
import {probeSize, processVideo} from "./processVideo";

const run = promisify(execFile);

const makeClip = async (
  dir: string,
  withAudio: boolean
): Promise<string> => {
  const input = join(dir, withAudio ? "in-audio.mp4" : "in-silent.mp4");
  const args = [
    "-y",
    "-v",
    "error",
    "-f",
    "lavfi",
    "-i",
    "testsrc=size=320x480:rate=30:duration=2",
  ];
  if (withAudio) {
    args.push("-f", "lavfi", "-i", "sine=frequency=440:duration=2");
  }
  args.push(
    "-map",
    "0:v:0",
    ...(withAudio ? ["-map", "1:a:0"] : []),
    "-c:v",
    "mpeg4",
    "-t",
    "2",
    input
  );
  await run(ffmpegBin(), args);
  return input;
};

const audioStreams = async (path: string): Promise<number> => {
  const {stdout} = await run(ffprobeBin(), [
    "-v",
    "error",
    "-select_streams",
    "a",
    "-show_entries",
    "stream=index",
    "-of",
    "csv=p=0",
    path,
  ]);
  const out = String(stdout).trim();
  return out === "" ? 0 : out.split("\n").length;
};

test("processVideo re-encodes with audio and extracts frames", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ramifica-video-"));
  try {
    const out = await processVideo(await makeClip(dir, true), dir);
    assert.equal(Math.abs(out.durationSeconds - 2) < 0.3, true);
    assert.deepEqual(await probeSize(out.videoPath), {
      width: 320,
      height: 480,
    });
    assert.equal(await audioStreams(out.videoPath), 1);
    for (const blur of [out.firstBlurData, out.lastBlurData]) {
      assert.equal(blur.startsWith("data:image/webp;base64,"), true);
      assert.equal(blur.length < 2048, true);
    }
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
});

test("processVideo drops the audio track when the input is silent",
  async () => {
    const dir = await mkdtemp(join(tmpdir(), "ramifica-silent-"));
    try {
      const out = await processVideo(await makeClip(dir, false), dir);
      assert.equal(await audioStreams(out.videoPath), 0);
      assert.deepEqual(await probeSize(out.videoPath), {
        width: 320,
        height: 480,
      });
    } finally {
      await rm(dir, {recursive: true, force: true});
    }
  }
);

test("convertCover makes the story art and the link preview", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ramifica-cover-"));
  try {
    const src = join(dir, "cover.png");
    await run(ffmpegBin(), [
      "-y",
      "-v",
      "error",
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=640x480:rate=1:duration=1",
      "-frames:v",
      "1",
      src,
    ]);
    const cover = await convertCover(src, dir);
    assert.deepEqual(await probeSize(cover.webpPath), {
      width: 480,
      height: 854,
    });
    assert.deepEqual(await probeSize(cover.ogPath), {
      width: 1200,
      height: 630,
    });
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
});

test("contentHash8 is stable and content-addressed", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ramifica-hash-"));
  try {
    const src = join(dir, "e.png");
    await run(ffmpegBin(), [
      "-y",
      "-v",
      "error",
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=64x64:rate=1:duration=1",
      "-frames:v",
      "1",
      src,
    ]);
    const first = await contentHash8(src);
    assert.match(first, /^[0-9a-f]{8}$/);
    assert.equal(await contentHash8(src), first);
    assert.notEqual(await contentHash8(__filename), first);
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
});

test("large stills keep provider pixels without cropping", async () => {
  const {normalizeStill} = await import("./processVideo");
  const {readFile, writeFile} = await import("fs/promises");
  const dir = await mkdtemp(join(tmpdir(), "ramifica-still-profile-"));
  try {
    const src = join(dir, "large.png");
    await run(ffmpegBin(), ["-y", "-v", "error", "-f", "lavfi", "-i",
      "testsrc=size=1536x2688:duration=0.1", "-frames:v", "1", src]);
    const before = await readFile(src);
    const out = await normalizeStill(before);
    assert.equal(out.width, 1536); assert.equal(out.height, 2688);
    const saved = join(dir, "normalized.png");
    await writeFile(saved, out.bytes);
    assert.deepEqual(await probeSize(saved), {width: 1536, height: 2688});
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
});

test("clips keep provider length and size without trimming " +
  "or failing", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ramifica-ai-profile-"));
  try {
    const input = join(dir, "odd.mp4");
    await run(ffmpegBin(), ["-y", "-v", "error", "-f", "lavfi", "-i",
      "color=red:size=480x832:rate=24:duration=3", "-f", "lavfi", "-i",
      "sine=frequency=440:duration=3", "-c:v", "mpeg4", "-c:a", "aac", input]);
    const out = await processVideo(input, dir);
    assert.deepEqual(await probeSize(out.videoPath), {width: 480, height: 832});
    assert.ok(Math.abs(out.durationSeconds - 3) < 0.3);
    assert.equal(await audioStreams(out.videoPath), 1);
    const short = join(dir, "two.mp4");
    await run(ffmpegBin(), ["-y", "-v", "error", "-i", input, "-t",
      "2", "-c", "copy", short]);
    const shortOut = await processVideo(short, dir);
    assert.ok(Math.abs(shortOut.durationSeconds - 2) < 0.5);
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
});
