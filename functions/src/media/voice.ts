import {execFile, type ExecFileOptions} from "child_process";
import {join} from "path";
import {promisify} from "util";
import {probeDuration} from "./processVideo";
import {OpenRouterFetch, OpenRouterHttpError, speakText} from "./openrouter";
import {ffmpegBin} from "./bin";
import {aiDefaults, openRouterConfig} from "../config/ai";

const exec = promisify(execFile);
/**
 * ffmpeg never reads interactive stdin: the static build polls for input
 * and an execFile pipe never EOFs, hanging the call at 0% CPU.
 * @param {string} bin Binary path.
 * @param {string[]} args CLI args.
 * @param {ExecFileOptions} options Exec options.
 * @return {Promise<object>} Exec output.
 */
const run = (bin: string, args: string[], options?: ExecFileOptions) =>
  exec(bin, bin === ffmpegBin() ? ["-nostdin", ...args] : args, options);

export interface ConvertedVoice {
  path: string;
  durationSeconds: number;
}

export interface SynthesizeOptions {
  apiKey: string;
  model?: string;
  voice: string;
  text: string;
  instructions?: string;
  fetchFn?: OpenRouterFetch;
}
/** Default TTS model; override with OPENROUTER_TTS_MODEL. */
export const defaultTtsModel = aiDefaults.openRouter.ttsModel;

/**
 * Converts an existing voice take (m4a, mp3, wav, or raw 24 kHz mono PCM)
 * to the app format: AAC mono 48 kbps `.m4a`.
 * @param {string} srcPath Source audio path.
 * @param {string} outDir Directory for the converted file.
 * @param {number} pcmSampleRate Input sample rate for raw PCM takes.
 * @return {Promise<ConvertedVoice>} The converted file and its duration.
 */
export const convertVoiceToM4a = async (
  srcPath: string,
  outDir: string,
  pcmSampleRate: number = aiDefaults.ttsPcmSampleRate
): Promise<ConvertedVoice> => {
  const path = join(outDir, "voz-converted.m4a");
  const input: string[] = srcPath.endsWith(".pcm") ?
    ["-f", "s16le", "-ar", String(pcmSampleRate), "-ac", "1", "-i", srcPath] :
    ["-i", srcPath];
  await run(ffmpegBin(), [
    "-y",
    "-v",
    "error",
    ...input,
    "-map",
    "0:a:0",
    "-c:a",
    "aac",
    "-b:a",
    "48k",
    "-ar",
    "48000",
    "-ac",
    "1",
    "-movflags",
    "+faststart",
    path,
  ]);
  return {path, durationSeconds: await probeDuration(path)};
};

/**
 * Asks OpenRouter for a Gemini TTS take. Returns raw 16-bit 24 kHz mono PCM,
 * the format `convertVoiceToM4a` turns into the app `.m4a`.
 * @param {SynthesizeOptions} options Text, voice, and credentials.
 * @return {Promise<Buffer>} Raw PCM bytes.
 */
export const synthesizePcm = async (
  options: SynthesizeOptions
): Promise<Buffer> => {
  try {
    return await speakText({
      apiKey: options.apiKey,
      fetchFn: options.fetchFn,
      model: options.model ?? openRouterConfig().ttsModel,
      voice: options.voice,
      text: options.text,
      instructions: options.instructions,
    });
  } catch (error) {
    if (error instanceof OpenRouterHttpError) {
      throw new Error(`TTS request failed: ${error.status}.`);
    }
    throw error;
  }
};
