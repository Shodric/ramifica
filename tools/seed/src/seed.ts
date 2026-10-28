import {mkdirSync, mkdtempSync, readFileSync, writeFileSync} from "fs";
import {tmpdir} from "os";
import {dirname, extname, join} from "path";
import * as admin from "firebase-admin";
import {ComfyClient} from "../../../functions/lib/media/comfy";
import {
  convertCover,
  convertEndImage,
} from "../../../functions/lib/media/images";
import {processVideo} from "../../../functions/lib/media/processVideo";
import {
  convertVoiceToM4a,
  synthesizePcm,
} from "../../../functions/lib/media/voice";
import {
  validateStory,
  ValidatableNode,
} from "../../../functions/lib/publish/validateStory";
import {kenBurnsClip, sayLine, synthStill} from "./gen";
import {
  coverFile,
  Manifest,
  ManifestNode,
  nodeFiles,
  readManifest,
} from "./manifest";
import {initTarget, SeedTarget, sha8, uploadVersioned} from "./store";

interface SeedArgs {
  dir: string;
  emulator: boolean;
  project?: string;
  tts: boolean;
  ttsProvider: "openrouter" | "say";
  sayVoice: string;
  images: "comfy" | "synth";
  prune: boolean;
}

interface BuiltNode {
  doc: Record<string, unknown>;
  endHash: string;
}

interface ResolvedMedia {
  startPath: string;
  startFromNodeId: string | null;
  startParentEndHash: string | null;
  startImagePrompt: string | null;
  endPath: string;
  endExt: string;
  endSource: "upload" | "muse";
  endHash: string;
  clipPath: string;
  videoSource: "upload" | "generated";
  voicePath: string | null;
  voiceDuration: number | null;
  voiceId: string;
}

/**
 * Loads the launch story by hand: media, voices, validation, publish.
 * Idempotent: fixed ids, content-hashed file names, docs overwritten.
 */
async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const manifest = readManifest(args.dir);
  const target = initTarget({emulator: args.emulator, project: args.project});
  const tmp = mkdtempSync(join(tmpdir(), "ramifica-seed-"));
  console.log(`Seeding ${manifest.storyId} (${tmp}).`);

  const built = new Map<string, BuiltNode>();
  const endBytes = new Map<string, Buffer>();
  for (const node of resolveOrder(manifest)) {
    console.log(`Node ${node.nodeId}: processing media.`);
    const media = await buildMedia(args, manifest, node, endBytes, tmp);
    const storyDir = `stories/${manifest.storyId}/nodes/${node.nodeId}`;
    const doc = await uploadNode(target, node, media, storyDir);
    built.set(node.nodeId, {doc, endHash: media.endHash});
  }

  const cover = await buildCover(args, target, manifest, tmp);
  const db = admin.firestore();
  const storyRef = db.doc(`stories/${manifest.storyId}`);
  await storyRef.set({
    authorId: manifest.authorId,
    title: manifest.title,
    synopsis: manifest.synopsis,
    status: "draft",
    rootNodeId: manifest.rootNodeId,
    coverUrl: cover.webpUrl,
    ogImageUrl: cover.ogUrl,
    tags: manifest.tags ?? [],
    locale: manifest.locale,
    featured: manifest.featured ?? false,
    publishedAt: null,
    createdAt: new Date().toISOString(),
  });
  for (const [nodeId, node] of built) {
    await db.doc(`stories/${manifest.storyId}/nodes/${nodeId}`).set(node.doc);
  }

  const problems = validateStory(
    {
      storyId: manifest.storyId,
      status: "draft",
      rootNodeId: manifest.rootNodeId,
    },
    [...built.entries()].map(([nodeId, node]) => ({
      ...(node.doc as {[field: string]: unknown}),
      nodeId,
      endHash: node.endHash,
      // The validator reads the caller-computed E hash; docs omit it.
    }) as unknown as ValidatableNode)
  );
  if (problems.length > 0) {
    console.log("Not publishing:");
    for (const problem of problems) console.log(`- ${problem}`);
    process.exitCode = 1;
    return;
  }
  await storyRef.update({
    status: "published",
    publishedAt: new Date().toISOString(),
  });
  console.log(`Published ${manifest.storyId}.`);

  if (args.prune) {
    await pruneNodes(manifest, [...built.keys()]);
  }
}

/**
 * Resolves every local file for one node: S, E, clip, and voice take.
 * @param {SeedArgs} args CLI options.
 * @param {Manifest} manifest Story manifest.
 * @param {ManifestNode} node Node manifest.
 * @param {Map<string, Buffer>} endBytes Parent E bytes, filled in order.
 * @param {string} tmp Work dir.
 * @return {Promise<ResolvedMedia>} The resolved media.
 */
async function buildMedia(
  args: SeedArgs,
  manifest: Manifest,
  node: ManifestNode,
  endBytes: Map<string, Buffer>,
  tmp: string
): Promise<ResolvedMedia> {
  const files = nodeFiles(args.dir, node.nodeId);
  const nodeTmp = join(tmp, node.nodeId);
  mkdirSync(nodeTmp, {recursive: true});

  const end = await endSource(args, node, files.end, nodeTmp);
  endBytes.set(node.nodeId, end.bytes);
  const endPath = writeTmp(nodeTmp, `end.${end.ext}`, end.bytes);

  let startPath: string;
  let startFromNodeId: string | null = null;
  let startParentEndHash: string | null = null;
  let startImagePrompt: string | null = null;
  if (node.nodeId === manifest.rootNodeId) {
    startImagePrompt = node.startImagePrompt ?? null;
    if (files.start) {
      startPath = files.start;
    } else {
      startPath = join(nodeTmp, "start.png");
      const prompt =
        startImagePrompt ?? `Vertical still, ${node.title}, no text.`;
      await genStill(args, prompt, startPath, node.nodeId);
    }
  } else {
    const parentId = parentOf(manifest, node.nodeId);
    const parentEnd = endBytes.get(parentId);
    if (!parentEnd) {
      throw new Error(`Parent of ${node.nodeId} is not resolved.`);
    }
    startPath = writeTmp(nodeTmp, "start.png", parentEnd);
    startFromNodeId = parentId;
    startParentEndHash = sha8(parentEnd);
  }

  const clipPath = files.video ??
    (await assembledClip(nodeTmp, startPath, endPath));
  const voice = await buildVoice(args, node, files.voice, nodeTmp);
  return {
    startPath,
    startFromNodeId,
    startParentEndHash,
    startImagePrompt,
    endPath,
    endExt: end.ext,
    endSource: end.source,
    endHash: sha8(end.bytes),
    clipPath,
    videoSource: files.video ? "upload" : "generated",
    voicePath: voice.path,
    voiceDuration: voice.durationSeconds,
    voiceId: node.voiceId ?? "Kore",
  };
}

interface StillSource {
  bytes: Buffer;
  ext: string;
  source: "upload" | "muse";
}

/**
 * E bytes: the end image file, ComfyUI, or a synthetic placeholder.
 * @param {SeedArgs} args CLI options.
 * @param {ManifestNode} node Node manifest.
 * @param {string} endFile End file, when present.
 * @param {string} nodeTmp Node work dir.
 * @return {Promise<StillSource>} The E bytes.
 */
async function endSource(
  args: SeedArgs,
  node: ManifestNode,
  endFile: string | undefined,
  nodeTmp: string
): Promise<StillSource> {
  if (endFile) {
    return {
      bytes: readFileSync(endFile),
      ext: extOf(endFile),
      source: "upload",
    };
  }
  const prompt =
    node.endImagePrompt ?? `Vertical still, ${node.title}, no text.`;
  const out = join(nodeTmp, "end.png");
  await genStill(args, prompt, out, node.nodeId);
  return {bytes: readFileSync(out), ext: "png", source: "muse"};
}

/**
 * A still via ComfyUI when configured, else a synthetic placeholder.
 * @param {SeedArgs} args CLI options.
 * @param {string} prompt Image prompt.
 * @param {string} out PNG to write.
 * @param {string} nodeId Node id, for the placeholder hue.
 */
async function genStill(
  args: SeedArgs,
  prompt: string,
  out: string,
  nodeId: string
): Promise<void> {
  if (args.images === "comfy") {
    const client = new ComfyClient({});
    const image = await client.textToImage({
      prompt,
      width: 480,
      height: 854,
    });
    writeFileSync(out, image.bytes);
    return;
  }
  await synthStill(out, hueFor(nodeId));
}

/**
 * A 10s cross-dissolve from S to E, first frame S and last frame E.
 * @param {string} nodeTmp Node work dir.
 * @param {string} startPath S still.
 * @param {string} endPath E still.
 * @return {Promise<string>} The clip path.
 */
async function assembledClip(
  nodeTmp: string,
  startPath: string,
  endPath: string
): Promise<string> {
  const out = join(nodeTmp, "assembled.mp4");
  await kenBurnsClip(startPath, endPath, out);
  return out;
}

/**
 * Voice take: the voz file, OpenRouter TTS, or macOS say as a dev
 * placeholder. Endings without ttsText skip this step.
 * @param {SeedArgs} args CLI options.
 * @param {ManifestNode} node Node manifest.
 * @param {string} voiceFile Voice file, when present.
 * @param {string} nodeTmp Node work dir.
 */
async function buildVoice(
  args: SeedArgs,
  node: ManifestNode,
  voiceFile: string | undefined,
  nodeTmp: string
): Promise<{path: string | null; durationSeconds: number | null}> {
  if (voiceFile) {
    const converted = await convertVoiceToM4a(voiceFile, nodeTmp);
    const done = {
      path: converted.path,
      durationSeconds: converted.durationSeconds,
    };
    return done;
  }
  const text = (node.ttsText ?? "").trim();
  if (text === "" || !args.tts) return {path: null, durationSeconds: null};
  if (args.ttsProvider === "openrouter") {
    const key = process.env.OPENROUTER_API_KEY;
    if (!key) throw new Error("OPENROUTER_API_KEY is not set.");
    const pcm = await synthesizePcm({
      apiKey: key,
      voice: node.voiceId ?? "Kore",
      text,
      instructions: "Off-screen narrator, one take. Do not add, translate, " +
        "or repeat words. Speak natural American English. Intimate and " +
        "clear, not announcer-like.",
    });
    const pcmPath = join(nodeTmp, "voice.pcm");
    writeFileSync(pcmPath, pcm);
    const converted = await convertVoiceToM4a(pcmPath, nodeTmp);
    return {path: converted.path, durationSeconds: converted.durationSeconds};
  }
  const wavPath = join(nodeTmp, "voice.wav");
  await sayLine(text, wavPath, args.sayVoice);
  const converted = await convertVoiceToM4a(wavPath, nodeTmp);
  return {path: converted.path, durationSeconds: converted.durationSeconds};
}

/**
 * Uploads every derived file and returns the node doc.
 * @param {SeedTarget} target Upload target.
 * @param {ManifestNode} node Node manifest.
 * @param {ResolvedMedia} media Resolved media.
 * @param {string} storyDir Storage prefix for the node.
 */
async function uploadNode(
  target: SeedTarget,
  node: ManifestNode,
  media: ResolvedMedia,
  storyDir: string
): Promise<Record<string, unknown>> {
  const outDir = dirname(media.clipPath);
  const video = await processVideo(media.clipPath, outDir);
  const videoUp = await uploadVersioned(
    target,
    storyDir,
    "video",
    "mp4",
    "video/mp4",
    video.videoPath
  );
  const firstUp = await uploadVersioned(
    target,
    storyDir,
    "frame-first",
    "png",
    "image/png",
    video.firstFramePath
  );
  const lastUp = await uploadVersioned(
    target,
    storyDir,
    "frame-last",
    "png",
    "image/png",
    video.lastFramePath
  );
  const startUp = await uploadVersioned(
    target,
    storyDir,
    "start",
    extOf(media.startPath),
    extOf(media.startPath) === "jpg" ? "image/jpeg" : "image/png",
    media.startPath
  );
  const endUp = await uploadVersioned(
    target,
    storyDir,
    "end-src",
    media.endExt,
    media.endExt === "jpg" ? "image/jpeg" : "image/png",
    media.endPath
  );
  const endSet = await convertEndImage(media.endPath, dirname(media.endPath));
  const endWebpUp = await uploadVersioned(
    target,
    storyDir,
    "end",
    "webp",
    "image/webp",
    endSet.webpPath
  );
  const thumbUp = await uploadVersioned(
    target,
    storyDir,
    "thumb",
    "webp",
    "image/webp",
    endSet.thumbPath
  );
  let voiceUrl: string | null = null;
  if (media.voicePath) {
    const voiceUp = await uploadVersioned(
      target,
      storyDir,
      "voice",
      "m4a",
      "audio/mp4",
      media.voicePath
    );
    voiceUrl = voiceUp.url;
  }
  const doc: Record<string, unknown> = {
    title: node.title,
    visibility: node.visibility,
    isEnding: node.isEnding,
    endingName: node.endingName ?? null,
    endingType: node.endingType ?? null,
    videoUrl: videoUp.url,
    videoStatus: "ready",
    videoFrameFirstUrl: firstUp.url,
    videoFrameLastUrl: lastUp.url,
    videoFrameFirstBlurData: video.firstBlurData,
    videoFrameLastBlurData: video.lastBlurData,
    startImageSourceUrl: startUp.url,
    startFromNodeId: media.startFromNodeId,
    startParentEndHash: media.startParentEndHash,
    startImagePrompt: media.startImagePrompt,
    startImageApproved: true,
    endImageSourceUrl: endUp.url,
    endImageUrl: endWebpUp.url,
    thumbnailUrl: thumbUp.url,
    endImageBlurData: endSet.blurData,
    endImagePrompt: node.endImagePrompt ?? null,
    endImageSource: media.endSource === "upload" ? "upload" : "muse",
    endImageApproved: true,
    videoSource: media.videoSource,
    pauseAtSeconds: video.pauseAtSeconds,
    durationSeconds: video.durationSeconds,
    ttsText: node.ttsText ?? "",
    lineApproved: true,
    ttsAudioUrl: voiceUrl,
    ttsDurationSeconds: media.voiceDuration,
    voiceId: media.voiceId,
    ttsStatus: voiceUrl ? "ready" : "idle",
    choiceCounts: Object.fromEntries(
      (node.choices ?? []).map((choice) => [choice.choiceId, 0])
    ),
    choices: (node.choices ?? []).map((choice) => ({...choice})),
  };
  if (!node.isEnding) {
    doc.windowSeconds = node.windowSeconds ?? 6;
  }
  return doc;
}

/**
 * Story cover and link preview, then their URLs.
 * @param {SeedArgs} args CLI options.
 * @param {SeedTarget} target Upload target.
 * @param {Manifest} manifest Story manifest.
 * @param {string} tmp Work dir.
 */
async function buildCover(
  args: SeedArgs,
  target: SeedTarget,
  manifest: Manifest,
  tmp: string
): Promise<{webpUrl: string; ogUrl: string}> {
  const file = coverFile(args.dir);
  let src: string;
  if (file) {
    src = file;
  } else if (args.images === "comfy") {
    const client = new ComfyClient({});
    const image = await client.textToImage({
      prompt: manifest.coverPrompt ??
        `Vertical cover, ${manifest.title}, no text.`,
      width: 480,
      height: 854,
    });
    src = join(tmp, "cover-src.png");
    writeFileSync(src, image.bytes);
  } else {
    src = join(tmp, "cover-src.png");
    await synthStill(src, 210);
  }
  const cover = await convertCover(src, tmp);
  const storyDir = `stories/${manifest.storyId}`;
  const webp = await uploadVersioned(
    target,
    storyDir,
    "cover",
    "webp",
    "image/webp",
    cover.webpPath
  );
  const og = await uploadVersioned(
    target,
    storyDir,
    "og",
    "jpg",
    "image/jpeg",
    cover.ogPath
  );
  return {webpUrl: webp.url, ogUrl: og.url};
}

/**
 * Deletes nodes that are no longer in the manifest.
 * @param {Manifest} manifest Story manifest.
 * @param {string[]} kept Node ids to keep.
 * @return {Promise<void>} When done.
 */
async function pruneNodes(manifest: Manifest, kept: string[]): Promise<void> {
  const snap = await admin
    .firestore()
    .collection(`stories/${manifest.storyId}/nodes`)
    .get();
  const keep = new Set(kept);
  for (const doc of snap.docs) {
    if (!keep.has(doc.id)) {
      console.log(`Pruning ${doc.id}.`);
      await doc.ref.delete();
    }
  }
}

/**
 * First incoming link wins the S inheritance.
 * @param {Manifest} manifest Story manifest.
 * @param {string} nodeId Child node.
 * @return {string} The parent id.
 */
function parentOf(manifest: Manifest, nodeId: string): string {
  for (const node of manifest.nodes) {
    for (const choice of node.choices ?? []) {
      if (choice.targetNodeId === nodeId) return node.nodeId;
    }
  }
  throw new Error(`${nodeId} has no parent link.`);
}

/**
 * Nodes in play order from the root, parents before children.
 * @param {Manifest} manifest Story manifest.
 * @return {ManifestNode[]} Play order.
 */
function resolveOrder(manifest: Manifest): ManifestNode[] {
  const byId = new Map(manifest.nodes.map((node) => [node.nodeId, node]));
  const seen = new Set<string>();
  const order: ManifestNode[] = [];
  const visit = (nodeId: string): void => {
    if (seen.has(nodeId)) return;
    const node = byId.get(nodeId);
    if (!node) throw new Error(`Manifest is missing ${nodeId}.`);
    seen.add(nodeId);
    order.push(node);
    for (const choice of node.choices ?? []) visit(choice.targetNodeId);
  };
  visit(manifest.rootNodeId);
  return order;
}

/**
 * Deterministic hue per node, so placeholders differ.
 * @param {string} nodeId Node id.
 * @return {number} Hue 0-359.
 */
function hueFor(nodeId: string): number {
  let hash = 0;
  for (const char of nodeId) hash = (hash * 31 + char.charCodeAt(0)) % 360;
  return hash;
}

/**
 * Lowercase extension without the dot, defaulting to png.
 * @param {string} path File path.
 * @return {string} The extension.
 */
function extOf(path: string): string {
  return extname(path).replace(/^\./, "").toLowerCase() || "png";
}

/**
 * Writes bytes to the work dir.
 * @param {string} dir Directory.
 * @param {string} name File name.
 * @param {Buffer} bytes Content.
 * @return {string} The file path.
 */
function writeTmp(dir: string, name: string, bytes: Buffer): string {
  const out = join(dir, name);
  writeFileSync(out, bytes);
  return out;
}
/**
 * Minimal flag parser. `--dir` is required; `--project` switches from the
 * emulator to a real project.
 * @param {string[]} argv Raw args.
 * @return {SeedArgs} Parsed options.
 */
function parseArgs(argv: string[]): SeedArgs {
  const get = (flag: string): string | undefined => {
    const index = argv.indexOf(flag);
    return index === -1 ? undefined : argv[index + 1];
  };
  const dir = get("--dir");
  if (!dir) throw new Error("Pass --dir <story folder>.");
  const project = get("--project");
  const images = get("--images");
  const ttsProvider = get("--tts-provider");
  let imageMode: "comfy" | "synth" = "synth";
  if (images === "comfy" ||
    (images !== "synth" && process.env.COMFYUI_URL)) {
    imageMode = "comfy";
  }
  return {
    dir,
    emulator: !project,
    project,
    tts: argv.includes("--tts"),
    ttsProvider: ttsProvider === "say" ? "say" : "openrouter",
    sayVoice: get("--say-voice") ?? "",
    images: imageMode,
    prune: argv.includes("--prune"),
  };
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
