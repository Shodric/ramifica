import ffmpegStatic from "ffmpeg-static";
import {path as ffprobeStatic} from "ffprobe-static";

/**
 * ffmpeg binary: explicit override for local runs, bundled static binary in
 * Cloud Functions, system PATH as a last resort.
 * @return {string} The ffmpeg executable path.
 */
export function ffmpegBin(): string {
  return process.env.FFMPEG_PATH ?? ffmpegStatic ?? "ffmpeg";
}

/**
 * ffprobe binary, resolved with the same precedence as ffmpeg.
 * @return {string} The ffprobe executable path.
 */
export function ffprobeBin(): string {
  return process.env.FFPROBE_PATH ?? ffprobeStatic ?? "ffprobe";
}
