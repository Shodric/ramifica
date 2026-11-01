import {execFile} from "child_process";
import {mkdtemp, readFile, rm, writeFile} from "fs/promises";
import {tmpdir} from "os";
import {mediaProfile} from "../config/ai";
import {join} from "path";
import {promisify} from "util";
import {ffmpegBin, ffprobeBin} from "./bin";
import {blurDataUri} from "./images";

const run = promisify(execFile);

export interface ProcessedVideo {
  videoPath: string;
  durationSeconds: number;
  width: number;
  height: number;
  firstFramePath: string;
  lastFramePath: string;
  firstBlurData: string;
  lastBlurData: string;
}

/**
 * Re-encodes a clip to the app format with `encode.sh`, measures it, and
 * extracts the first and last frames with their portal blurs. Reads and
 * writes local paths only; uploading is the caller's job.
 * @param {string} inputPath Source clip path.
 * @param {string} outDir Directory for the derived files.
 * @return {Promise<ProcessedVideo>} Video, duration, frames, and blurs.
 */
export const processVideo = async (
  inputPath: string,
  outDir: string,
  options: {generated?: boolean} = {}
): Promise<ProcessedVideo> => {
  const {width, height, fps, durationSeconds: target} = mediaProfile;
  if (options.generated && (await probeDuration(inputPath)) < target - 1 / fps) {
    throw new Error(`Generated video is shorter than ${target} seconds.`);
  }
  const env = {...process.env, PATH: toolPath()};
  const videoPath = join(outDir, "video.mp4");
  await run("bash", [join(__dirname, "encode.sh"), inputPath, videoPath,
    String(width), String(height), String(fps),
    ...(options.generated ? [String(target)] : []),
  ], {
    env,
  });
  const durationSeconds = await probeDuration(videoPath);
  const size = await probeSize(videoPath);
  if (size.width !== width || size.height !== height) {
    throw new Error("Encoded video dimensions do not match the output profile.");
  }
  if (options.generated && Math.abs(durationSeconds - target) > 1 / fps + 0.001) {
    throw new Error(`Encoded video must last ${target} seconds (one frame tolerance).`);
  }
  const firstFramePath = join(outDir, "first.png");
  const lastFramePath = join(outDir, "last.png");
  await run(ffmpegBin(), [
    "-y",
    "-v",
    "error",
    "-i",
    videoPath,
    "-frames:v",
    "1",
    firstFramePath,
  ]);
  await run(ffmpegBin(), [
    "-sseof",
    "-0.1",
    "-i",
    videoPath,
    "-frames:v",
    "1",
    "-update",
    "1",
    lastFramePath,
  ]);
  const [firstBlurData, lastBlurData] = await Promise.all([
    blurDataUri(firstFramePath),
    blurDataUri(lastFramePath),
  ]);
  return {
    videoPath,
    durationSeconds,
    width, height,
    firstFramePath,
    lastFramePath,
    firstBlurData,
    lastBlurData,
  };
};

/**
 * Duration of a media file in seconds, from its container metadata.
 * @param {string} path File path.
 * @return {Promise<number>} Duration in seconds.
 */
export const probeDuration = async (path: string): Promise<number> => {
  const {stdout} = await run(ffprobeBin(), [
    "-v",
    "error",
    "-show_entries",
    "format=duration",
    "-of",
    "csv=p=0",
    path,
  ]);
  const seconds = Number(String(stdout).trim());
  if (!Number.isFinite(seconds) || seconds <= 0) {
    throw new Error(`Cannot read duration of ${path}.`);
  }
  return seconds;
};

/**
 * Width and height of an image or video stream, via ffprobe.
 * @param {string} path File path.
 * @return {Promise<{width: number, height: number}>} Stream dimensions.
 */
export const probeSize = async (
  path: string
): Promise<{width: number; height: number}> => {
  const {stdout} = await run(ffprobeBin(), [
    "-v",
    "error",
    "-select_streams",
    "v:0",
    "-show_entries",
    "stream=width,height",
    "-of",
    "csv=p=0",
    path,
  ]);
  const [width, height] = String(stdout)
    .trim()
    .split(",")
    .map((part) => Number(part));
  if (!Number.isInteger(width) || !Number.isInteger(height)) {
    throw new Error(`Cannot read size of ${path}.`);
  }
  return {width, height};
};

const toolPath = (): string => {
  const toDir = (bin: string): string | null => {
    return bin.includes("/") ? bin.slice(0, bin.lastIndexOf("/")) : null;
  };
  const dirs = [ffmpegBin(), ffprobeBin()]
    .map(toDir)
    .filter((dir): dir is string => dir !== null);
  return [...dirs, process.env.PATH ?? ""].join(":");
};


export interface NormalizedStill {
  bytes: Buffer; width: number; height: number;
}
export interface NormalizedVideo extends NormalizedStill {
  durationSeconds: number; lastFrame: Buffer; lastBlurData: string;
}

/** Center-crop to the profile before hashing; never distort the image. */
export const normalizeStill = async (bytes: Buffer): Promise<NormalizedStill> => {
  const dir = await mkdtemp(join(tmpdir(), "ramifica-still-"));
  try {
    const input = join(dir, "input");
    const output = join(dir, "normalized.png");
    await writeFile(input, bytes);
    const {width, height} = mediaProfile;
    await run(ffmpegBin(), ["-y", "-v", "error", "-i", input,
      "-vf", `scale=${width}:${height}:force_original_aspect_ratio=increase,` +
        `crop=${width}:${height},setsar=1`, "-frames:v", "1", output]);
    const size = await probeSize(output);
    if (size.width !== width || size.height !== height) {
      throw new Error("Image dimensions do not match the output profile.");
    }
    return {bytes: await readFile(output), ...size};
  } finally { await rm(dir, {recursive: true, force: true}); }
};

/** Generated clips use the same browser-compatible pipeline as uploads. */
export const normalizeGeneratedVideo = async (bytes: Buffer): Promise<NormalizedVideo> => {
  const dir = await mkdtemp(join(tmpdir(), "ramifica-generated-"));
  try {
    const input = join(dir, "input.mp4");
    await writeFile(input, bytes);
    const output = await processVideo(input, dir, {generated: true});
    return {bytes: await readFile(output.videoPath), width: output.width,
      height: output.height, durationSeconds: output.durationSeconds,
      lastFrame: await readFile(output.lastFramePath), lastBlurData: output.lastBlurData};
  } finally { await rm(dir, {recursive: true, force: true}); }
};
