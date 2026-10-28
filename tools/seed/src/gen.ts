import {execFile} from "child_process";
import {promisify} from "util";

const run = promisify(execFile);

const ffmpeg = (): string => {
  return process.env.FFMPEG_PATH ?? "ffmpeg";
};

/**
 * Placeholder still: vertical gradient, grain, and vignette. Stands in
 * until a real still (upload) or ComfyUI generation arrives. Deterministic
 * per hue so nodes look different from each other.
 * @param {string} outPath PNG to write.
 * @param {number} hue Base hue 0-360.
 */
export async function synthStill(outPath: string, hue: number): Promise<void> {
  await run(ffmpeg(), [
    "-y",
    "-v",
    "error",
    "-f",
    "lavfi",
    "-i",
    "gradients=size=480x854:c0=0x141428:c1=0x2a1a3e",
    "-vf",
    `hue=h=${hue},noise=alls=10:allf=t,vignette=PI/4,format=rgb24`,
    "-frames:v",
    "1",
    outPath,
  ]);
}

/**
 * Ten-second cross-dissolve from S to E, both framed 9:16. The first frame
 * is S and the last is E, so the cut matches the portal contract
 * (`S(hijo) = E(padre)`).
 * @param {string} startPath S still.
 * @param {string} endPath E still.
 * @param {string} outPath MP4 to write.
 */
export async function kenBurnsClip(
  startPath: string,
  endPath: string,
  outPath: string
): Promise<void> {
  const scale =
    "scale=480:854:force_original_aspect_ratio=increase," +
    "crop=480:854,setsar=1,fps=30,format=yuv420p";
  await run(ffmpeg(), [
    "-y",
    "-v",
    "error",
    "-loop",
    "1",
    "-i",
    startPath,
    "-loop",
    "1",
    "-i",
    endPath,
    "-filter_complex",
    `[0:v]${scale}[s0];[1:v]${scale}[s1];` +
      "[s0][s1]xfade=transition=fade:duration=10:offset=0,format=yuv420p[v]",
    "-map",
    "[v]",
    "-t",
    "10",
    outPath,
  ]);
}

export interface SayVoice {
  name: string;
  locale: string;
}

/**
 * Installed `say` voices, English first.
 * @return {Promise<SayVoice[]>} The installed voices.
 */
export async function sayVoices(): Promise<SayVoice[]> {
  const {stdout} = await run("/usr/bin/say", ["-v", "?"]);
  const voices: SayVoice[] = [];
  for (const line of stdout.split("\n")) {
    const match = /^(.+?)\s+([a-z]{2}_[A-Z]{2})\s/.exec(line.trim());
    if (match) voices.push({name: match[1].trim(), locale: match[2]});
  }
  const rank = (locale: string): number => {
    if (locale === "en_US") return 0;
    if (locale.startsWith("en")) return 1;
    return 2;
  };
  return voices.sort((a, b) => rank(a.locale) - rank(b.locale));
}

/**
 * @param {string} text Narrator line.
 * @param {string} outPath WAV file to write.
 * @param {string} voice Voice name, or empty for the first English one.
 */
export async function sayLine(
  text: string,
  outPath: string,
  voice: string
): Promise<void> {
  if (process.platform !== "darwin") {
    throw new Error("say voices need macOS; pass --tts-provider openrouter.");
  }
  let name = voice;
  if (!name) {
    const installed = await sayVoices();
    if (installed.length === 0) {
      throw new Error("No English say voice is installed.");
    }
    name = installed[0].name;
  }
  await run("/usr/bin/say", [
    "-v",
    name,
    "-o",
    outPath,
    "--data-format=LEF32@48000",
    text,
  ]);
}
