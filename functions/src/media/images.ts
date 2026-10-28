import {createHash} from "crypto";
import {execFile} from "child_process";
import {readFile} from "fs/promises";
import {join} from "path";
import {promisify} from "util";
import {ffmpegBin} from "./bin";

const run = promisify(execFile);

export interface EndImage {
  webpPath: string;
  thumbPath: string;
  blurData: string;
}

export interface CoverImage {
  webpPath: string;
  ogPath: string;
}

/**
 * Inline WebP blur for the hold portal: the source scaled to 24 px wide.
 * @param {string} imagePath Source image path.
 * @return {Promise<string>} The `data:image/webp;base64,…` URI.
 */
export const blurDataUri = async (imagePath: string): Promise<string> => {
  const {stdout} = await run(
    ffmpegBin(),
    ["-v", "error", "-i", imagePath, "-vf", "scale=24:-1",
      "-f", "webp", "pipe:1"],
    {encoding: "buffer", maxBuffer: 4 * 1024 * 1024}
  );
  const bytes = stdout as Buffer;
  if (bytes.length === 0 || bytes.length > 1024) {
    throw new Error(`Unexpected blur size for ${imagePath}.`);
  }
  return `data:image/webp;base64,${bytes.toString("base64")}`;
};

/**
 * Node cover set from E: 480x854 WebP, 160 px wide thumbnail, inline blur.
 * @param {string} srcPath Source image path.
 * @param {string} outDir Directory for the derived files.
 * @return {Promise<EndImage>} Paths and blur data.
 */
export const convertEndImage = async (
  srcPath: string,
  outDir: string
): Promise<EndImage> => {
  const webpPath = join(outDir, "end-480.webp");
  const thumbPath = join(outDir, "thumb-160.webp");
  await run(ffmpegBin(), [
    "-y",
    "-v",
    "error",
    "-i",
    srcPath,
    "-vf",
    "scale=480:854:force_original_aspect_ratio=increase,crop=480:854",
    "-q:v",
    "75",
    webpPath,
  ]);
  await run(ffmpegBin(), [
    "-y",
    "-v",
    "error",
    "-i",
    srcPath,
    "-vf",
    "scale=160:-1",
    "-q:v",
    "70",
    thumbPath,
  ]);
  return {webpPath, thumbPath, blurData: await blurDataUri(srcPath)};
};

/**
 * Story art from the cover: 480x854 WebP plus the 1200x630 link preview.
 * @param {string} srcPath Source image path.
 * @param {string} outDir Directory for the derived files.
 * @return {Promise<CoverImage>} Cover and preview paths.
 */
export const convertCover = async (
  srcPath: string,
  outDir: string
): Promise<CoverImage> => {
  const webpPath = join(outDir, "cover-480.webp");
  const ogPath = join(outDir, "og-1200.jpg");
  await run(ffmpegBin(), [
    "-y",
    "-v",
    "error",
    "-i",
    srcPath,
    "-vf",
    "scale=480:854:force_original_aspect_ratio=increase,crop=480:854",
    "-q:v",
    "75",
    webpPath,
  ]);
  await run(ffmpegBin(), [
    "-y",
    "-v",
    "error",
    "-i",
    srcPath,
    "-vf",
    "scale=1200:630:force_original_aspect_ratio=increase,crop=1200:630",
    "-q:v",
    "3",
    ogPath,
  ]);
  return {webpPath, ogPath};
};

/**
 * First 8 hex chars of the file sha256. Versioned storage names embed it,
 * so an unchanged file keeps its URL and a changed one gets a new one.
 * @param {string} path File path.
 * @return {Promise<string>} The 8-char hash.
 */
export const contentHash8 = async (path: string): Promise<string> => {
  const bytes = await readFile(path);
  return createHash("sha256").update(bytes).digest("hex").slice(0, 8);
};
