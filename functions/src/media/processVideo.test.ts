import {execFile} from "child_process";
import {mkdtemp, rm} from "fs/promises";
import {tmpdir} from "os";
import {join} from "path";
import {strict as assert} from "assert";
import {test} from "node:test";
import {promisify} from "util";
import {ffmpegBin, ffprobeBin} from "./bin";
import {
  blurDataUri,
  contentHash8,
  convertCover,
  convertEndImage,
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
    assert.equal(out.pauseAtSeconds, out.durationSeconds - 1 / 30);
    assert.deepEqual(await probeSize(out.videoPath), {
      width: 480,
      height: 854,
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
        width: 480,
        height: 854,
      });
    } finally {
      await rm(dir, {recursive: true, force: true});
    }
  }
);

test("convertEndImage makes cover, thumbnail, and blur", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ramifica-end-"));
  try {
    const src = join(dir, "e.png");
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
    const end = await convertEndImage(src, dir);
    assert.deepEqual(await probeSize(end.webpPath), {
      width: 480,
      height: 854,
    });
    const thumb = await probeSize(end.thumbPath);
    assert.equal(thumb.width, 160);
    assert.equal(end.blurData.startsWith("data:image/webp;base64,"), true);
    assert.equal(await blurDataUri(src), end.blurData);
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
});

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
