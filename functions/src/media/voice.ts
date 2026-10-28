import {execFile} from "child_process";
import {join} from "path";
import {promisify} from "util";
import {ffmpegBin} from "./bin";
import {probeDuration} from "./processVideo";

const run = promisify(execFile);

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
}

const defaultTtsModel = "google/gemini-3.8-flash-lite-tts";

/**
 * Converts an existing voice take (m4a, mp3, wav, or raw 24 kHz mono PCM)
 * to the app format: AAC mono 48 kbps `.m4a`.
 * @param {string} srcPath Source audio path.
 * @param {string} outDir Directory for the converted file.
 * @return {Promise<ConvertedVoice>} The converted file and its duration.
 */
export const convertVoiceToM4a = async (
  srcPath: string,
  outDir: string
): Promise<ConvertedVoice> => {
  const path = join(outDir, "voz-converted.m4a");
  const input: string[] = srcPath.endsWith(".pcm") ?
    ["-f", "s16le", "-ar", "24000", "-ac", "1", "-i", srcPath] :
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
  const response = await fetch("https://openrouter.ai/api/v1/audio/speech", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${options.apiKey}`,
      "Content-Type": "application/json",
      "HTTP-Referer": "https://ramifica.app",
      "X-Title": "Ramifica seed",
    },
    body: JSON.stringify({
      model: options.model ?? defaultTtsModel,
      input: options.text,
      voice: options.voice,
      response_format: "pcm",
      ...(options.instructions ? {instructions: options.instructions} : {}),
    }),
  });
  if (!response.ok) {
    throw new Error(`TTS request failed: ${response.status}.`);
  }
  return Buffer.from(await response.arrayBuffer());
};
