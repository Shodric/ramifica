import * as admin from "firebase-admin";
import {execFile, type ExecFileOptions} from "child_process";
import {mkdtemp, readFile, rm, writeFile} from "fs/promises";
import {tmpdir} from "os";
import {join} from "path";
import {promisify} from "util";
import {deflateSync, inflateSync} from "zlib";
import {HttpsError} from "firebase-functions/v2/https";
import {onCallSafe} from "../callable";
import {metaApiKey, metaConfig} from "../config/ai";
import {
  cleanId,
  Db,
  docData,
  isEmulator,
  optString,
  requireCreator,
  toRecord,
} from "../feed/shared";
import {ffmpegBin} from "../media/bin";
import {
  generateImageMeta,
  generateImageWithReferenceMeta,
  MetaFetch,
  MetaHttpError,
} from "../media/meta";
import {probeSize} from "../media/processVideo";
import {writeMedia} from "../media/draftWrites";
import {readableStorageUrl} from "../media/storageUrl";

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

/** Result of `generateEndingBadge`. */
export interface GenerateEndingBadgeResult {
  badgeUrl: string;
  width?: number;
  height?: number;
}

/** Processed badge bytes plus their probed dimensions. */
export interface NormalizedBadge {
  bytes: Buffer;
  width: number;
  height: number;
}

/** Injectable badge uploader: bytes in, public URL out. */
export interface BadgeUploadFn {
  (args: {
    storyId: string;
    nodeId: string;
    bytes: Buffer;
  }): Promise<string>;
}

/** Injectable seams so tests run without GPU, Storage, or Meta. */
export interface EndingBadgeDeps {
  fetchFn?: MetaFetch;
  normalizeBadge?: (bytes: Buffer) => Promise<NormalizedBadge>;
  uploadBadge?: BadgeUploadFn;
  downloadFrame?: (url: string) => Promise<Buffer | null>;
}

/** Longest badge side in px; the client renders the badge at card size. */
export const maxBadgePx = 480;

/** Per-channel tolerance for the edge flood fill, out of 255. */
const chromaTolerance = 32;

/**
 * Generates the trophy badge for an ending node. Bills one Meta still
 * (framed on the last video frame when available), fits the PNG
 * within 480px untouched, stores it under `badges/{storyId}/{nodeId}`,
 * and links it from the draft node as `endingBadgeUrl`.
 * @param {unknown} _req Unused callable wrapper slot.
 */
export const generateEndingBadge = onCallSafe(
  {
    enforceAppCheck: !isEmulator(), maxInstances: 10,
    timeoutSeconds: 300, memory: "1GiB", concurrency: 2,
    secrets: [metaApiKey],
  },
  async (req) => {
    const uid = requireCreator(req.auth);
    return generateEndingBadgeWith(
      admin.firestore() as unknown as Db,
      uid,
      req.data ?? {}
    );
  }
);

/**
 * Testable core of `generateEndingBadge`.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {unknown} data Raw `{storyId, nodeId, endingType?}`.
 * @param {EndingBadgeDeps} deps Injectable provider seams.
 * @return {Promise<GenerateEndingBadgeResult>} The badge URL.
 */
export const generateEndingBadgeWith = async (
  db: Db,
  uid: string,
  data: unknown,
  deps: EndingBadgeDeps = {}
): Promise<GenerateEndingBadgeResult> => {
  assertUid(uid);
  const fields = toRecord(data);
  const storyId = cleanId(fields.storyId, "storyId");
  const nodeId = cleanId(fields.nodeId, "nodeId");
  const loaded = await loadDraftNode(db, uid, storyId, nodeId);
  const node = loaded.node;
  const title = optString(node.title);
  const endingType =
    optString(fields.endingType) ?? optString(node.endingType);
  const frameUrl = optString(node.videoFrameLastUrl);
  let raw: Buffer;
  try {
    raw = frameUrl === null ?
      await generateBadgeBytes(
        buildBadgePrompt({title, endingType}),
        deps.fetchFn
      ) :
      await generateFramedBadgeBytes({
        db,
        storyId,
        nodeId,
        rootNodeId: optString(loaded.story.rootNodeId),
        frameUrl,
        title,
        endingType,
        deps,
      });
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    throw new HttpsError(
      "internal",
      `Badge generation failed: ${(error as Error).message}`
    );
  }
  const normalized = await (deps.normalizeBadge ?? normalizeBadge)(raw);
  const badgeUrl = await (deps.uploadBadge ?? defaultUploadBadge())({
    storyId, nodeId, bytes: normalized.bytes,
  });
  await writeMedia(db, storyId, nodeId, {endingBadgeUrl: badgeUrl});
  // A badge minted after publish never reaches players through the draft
  // copy: mirror it into the live publication node of the same id.
  const publicationId = optString(loaded.story.activePublicationId);
  if (publicationId !== null) {
    await db
      .doc(`stories/${storyId}/publications/${publicationId}/nodes/${nodeId}`)
      .set({endingBadgeUrl: badgeUrl}, {merge: true});
  }
  return {badgeUrl, width: normalized.width, height: normalized.height};
};

/**
 * Fixed badge prompt: a legendary shield/trophy insignia with a
 * transparent background and no text, themed by the ending. Pure so
 * tests pin the copy without a Db.
 * @param {Object} args Scene title and ending type, when known.
 * @return {string} The image prompt.
 */
export const buildBadgePrompt = (args: {
  title?: string | null;
  endingType?: string | null;
}): string => {
  const name = clip(args.title, 40);
  const type = clip(args.endingType, 24);
  const parts = [
    "Legendary trophy shield badge emblem, centered achievement " +
    "insignia, ornate metallic crest, isolated on a transparent " +
    "background, full transparency outside the emblem, " +
    "no text, no letters, no numbers, no watermark.",
  ];
  if (name !== "") {
    parts.push(`THEME: an emblem honoring the ending named "${name}".`);
  }
  const mood = badgeMood(type);
  if (mood !== "") parts.push(`MOOD: ${mood}.`);
  return parts.join(" ");
};

/**
 * Fit `width`x`height` inside a 480px box, preserving aspect ratio and
 * never upscaling. Pure so tests pin the bounds without ffmpeg.
 * @param {number} width Probed width.
 * @param {number} height Probed height.
 * @return {Object} The target dimensions.
 */
export const badgeTargetSize = (
  width: number,
  height: number
): {width: number; height: number} => {
  if (
    !Number.isFinite(width) || !Number.isFinite(height) ||
    width <= 0 || height <= 0
  ) {
    throw new Error(`Cannot size a badge from ${width}x${height}.`);
  }
  const longest = Math.max(width, height);
  if (longest <= maxBadgePx) {
    return {width: Math.round(width), height: Math.round(height)};
  }
  const scale = maxBadgePx / longest;
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
};

/**
 * Default badge post-process: keep the provider pixels exactly as
 * they arrive (blurred backdrop included), only scaling them into
 * the 480px box as PNG (same ffmpeg pipeline as the other stills).
 * @param {Buffer} bytes Raw provider bytes.
 * @return {Promise<NormalizedBadge>} The badge bytes plus dimensions.
 */
export const normalizeBadge = async (
  bytes: Buffer
): Promise<NormalizedBadge> => {
  const dir = await mkdtemp(join(tmpdir(), "ramifica-badge-"));
  try {
    const input = join(dir, "input");
    const output = join(dir, "badge.png");
    await writeFile(input, bytes);
    const probed = await probeSize(input);
    const target = badgeTargetSize(probed.width, probed.height);
    await run(ffmpegBin(), ["-y", "-v", "error", "-i", input, "-vf",
      `scale=${target.width}:${target.height},format=rgba`,
      "-frames:v", "1", output]);
    const size = await probeSize(output);
    const converted = await readFile(output);
    return {bytes: converted, ...size};
  } finally {
    await rm(dir, {recursive: true, force: true});
  }
};

/**
 * Plan B transparency: when the model returns a solid backdrop,
 * flood-fills the edge color into alpha. Already-transparent art and
 * undecodable bytes pass through untouched.
 * @param {Buffer} png Badge PNG bytes.
 * @return {Buffer} The transparent PNG, or the input.
 */
export const stripSolidBackground = (png: Buffer): Buffer => {
  try {
    const decoded = decodePng(png);
    if (decoded === null || decoded.hasAlpha) return png;
    const cleared = floodFillAlpha(
      decoded.pixels, decoded.width, decoded.height, chromaTolerance
    );
    const total = decoded.width * decoded.height;
    if (cleared === 0 || cleared >= total) return png;
    return encodePng(decoded.pixels, decoded.width, decoded.height);
  } catch {
    return png;
  }
};

/**
 * Clears the 4-connected border region into alpha, keyed on the
 * top-left pixel. Mutates `pixels` in place. Pure so tests pin the
 * fill without encoding a PNG.
 * @param {Buffer} pixels RGBA pixels, row-major.
 * @param {number} width Image width.
 * @param {number} height Image height.
 * @param {number} tolerance Per-channel match distance.
 * @return {number} How many pixels were cleared.
 */
export const floodFillAlpha = (
  pixels: Buffer,
  width: number,
  height: number,
  tolerance = chromaTolerance
): number => {
  if (pixels.length !== width * height * 4 || width <= 0 || height <= 0) {
    return 0;
  }
  const seed = [pixels[0], pixels[1], pixels[2]];
  const visited = new Uint8Array(width * height);
  const stack: number[] = [
    0, width - 1, (height - 1) * width, width * height - 1,
  ];
  let cleared = 0;
  const matches = (index: number): boolean => {
    const base = index * 4;
    return Math.abs(pixels[base] - seed[0]) <= tolerance &&
      Math.abs(pixels[base + 1] - seed[1]) <= tolerance &&
      Math.abs(pixels[base + 2] - seed[2]) <= tolerance;
  };
  while (stack.length > 0) {
    const index = stack.pop() as number;
    if (visited[index] === 1) continue;
    visited[index] = 1;
    if (!matches(index)) continue;
    pixels[index * 4 + 3] = 0;
    cleared += 1;
    const x = index % width;
    const y = Math.floor(index / width);
    if (x > 0) stack.push(index - 1);
    if (x < width - 1) stack.push(index + 1);
    if (y > 0) stack.push(index - width);
    if (y < height - 1) stack.push(index + width);
  }
  return cleared;
};

/**
 * Mood line for the known ending types; unknown types pass through
 * verbatim so future types still theme the badge.
 * @param {string} type Clipped ending type.
 * @return {string} The mood phrase, or blank.
 */
const badgeMood = (type: string): string => {
  switch (type.toLowerCase()) {
  case "open":
    return "hopeful open dawn, gold and sky blue";
  case "tragic":
    return "somber fallen dusk, iron and ember red";
  case "secret":
    return "mysterious hidden rune, silver and deep violet";
  default:
    return type;
  }
};

/**
 * Trims a raw field to at most `max` chars; blanks and non-strings
 * become "". Keeps one long field from eating the prompt budget.
 * @param {unknown} value Raw field.
 * @param {number} max Character cap.
 * @return {string} The clipped text.
 */
const clip = (value: unknown, max: number): string => {
  const text = typeof value === "string" ? value.trim() : "";
  return text.length <= max ? text : text.slice(0, max);
};

/**
 * Authenticated uid or bust, mirroring the other create callables.
 * @param {unknown} uid Caller uid.
 */
const assertUid = (uid: unknown): void => {
  if (typeof uid !== "string" || uid.trim() === "") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
};

/**
 * Loads the story + node, enforcing author-owned draft like the other
 * create callables.
 * @param {Db} db Firestore.
 * @param {string} uid Caller.
 * @param {string} storyId Story id.
 * @param {string} nodeId Node id.
 * @return {Promise<Object>} The story and node fields.
 */
const loadDraftNode = async (
  db: Db,
  uid: string,
  storyId: string,
  nodeId: string
): Promise<{
  story: {[field: string]: unknown};
  node: {[field: string]: unknown};
}> => {
  const storySnap = await db.doc(`stories/${storyId}`).get();
  if (!storySnap.exists) {
    throw new HttpsError("not-found", "Story not found.");
  }
  const story = docData(storySnap, "Story");
  if (story.authorId !== uid) {
    throw new HttpsError("permission-denied", "Not your draft.");
  }
  if (story.status !== "draft") {
    throw new HttpsError("failed-precondition", "Only drafts can edit media.");
  }
  const nodeSnap = await db.doc(`stories/${storyId}/nodes/${nodeId}`).get();
  if (!nodeSnap.exists) {
    throw new HttpsError("not-found", "Node not found.");
  }
  return {story, node: docData(nodeSnap, "Node")};
};

/**
 * One badge still from Meta: 256px first, 480px when the provider
 * rejects that size. An injected fetch carries test transport; without
 * it a missing key fails before billing. Empty answers reject: only a
 * provider HTTP rejection earns the fallback attempt.
 * @param {string} prompt Badge prompt.
 * @param {MetaFetch} fetchFn Optional test transport.
 * @return {Promise<Buffer>} The raw still bytes.
 */
const generateBadgeBytes = async (
  prompt: string,
  fetchFn?: MetaFetch
): Promise<Buffer> => {
  const config = metaConfig();
  if (config.apiKey === "" && !fetchFn) {
    throw new HttpsError(
      "failed-precondition",
      "Image provider credentials are missing."
    );
  }
  const request = (size: string): Promise<Buffer> => generateImageMeta({
    apiKey: config.apiKey,
    model: config.imageModel,
    prompt,
    size,
    fetchFn,
  });
  try {
    return await request("256x256");
  } catch (error) {
    if (!(error instanceof MetaHttpError)) throw error;
    return await request("480x480");
  }
};

/** One step of the path the player walked to reach this ending. */
interface ChainLink {
  title: string | null;
  choiceLabel: string | null;
}

/** Longest parent chain sent as badge inspiration; bounds the prompt. */
const maxChainLinks = 24;

/**
 * One badge still guided by the ending's last video frame: the frame
 * is widened into a square blurred backdrop behind the emblem, and
 * the full parent-node path themes the art. A missing frame falls
 * back to the plain prompt so legacy nodes still get a badge.
 * @param {Object} args Story/node ids, frame URL, ending fields, deps.
 * @return {Promise<Buffer>} The raw still bytes.
 */
export const generateFramedBadgeBytes = async (args: {
  db: Db;
  storyId: string;
  nodeId: string;
  rootNodeId: string | null;
  frameUrl: string;
  title: string | null;
  endingType: string | null;
  deps: EndingBadgeDeps;
}): Promise<Buffer> => {
  const config = metaConfig();
  if (config.apiKey === "" && !args.deps.fetchFn) {
    throw new HttpsError(
      "failed-precondition",
      "Image provider credentials are missing."
    );
  }
  const download = args.deps.downloadFrame ?? downloadFrameBytes;
  const frame = await download(args.frameUrl);
  if (frame === null) {
    return generateBadgeBytes(
      buildBadgePrompt({
        title: args.title,
        endingType: args.endingType,
      }),
      args.deps.fetchFn
    );
  }
  const chain = await loadEndingChain(
    args.db, args.storyId, args.rootNodeId, args.nodeId
  );
  return generateImageWithReferenceMeta({
    apiKey: config.apiKey,
    model: config.imageModel,
    frameBase64: frame.toString("base64"),
    frameMimeType: sniffImageMime(frame),
    instructions: buildBadgeInstructions({
      title: args.title,
      endingType: args.endingType,
      chain,
    }),
    fetchFn: args.deps.fetchFn,
  });
};

/**
 * Downloads the last-frame reference for badge framing. Any failure
 * returns null so the caller falls back to the plain badge prompt.
 * @param {string} url Signed frame URL.
 * @return {Promise<Buffer | null>} The frame bytes, or null.
 */
export const downloadFrameBytes = async (
  url: string
): Promise<Buffer | null> => {
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    return Buffer.from(await res.arrayBuffer());
  } catch {
    return null;
  }
};

/**
 * Sniffs the reference mime for the `input_image` data URL: PNG and
 * JPEG by magic bytes, PNG otherwise (the frame writer stores PNG).
 * @param {Buffer} bytes Frame bytes.
 * @return {string} The mime type.
 */
export const sniffImageMime = (bytes: Buffer): string => {
  if (
    bytes.length >= 4 &&
    bytes[0] === 0x89 && bytes[1] === 0x50 &&
    bytes[2] === 0x4E && bytes[3] === 0x47
  ) {
    return "image/png";
  }
  if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xD8) {
    return "image/jpeg";
  }
  return "image/png";
};

/**
 * Walks the parent chain from the ending node back to the root,
 * recording each node title and the choice label taken to leave it.
 * Broken links stop the walk instead of failing the badge.
 * @param {Db} db Firestore.
 * @param {string} storyId Story id.
 * @param {string | null} rootNodeId Root node id.
 * @param {string} nodeId Ending node id.
 * @return {Promise<ChainLink[]>} Root-first chain links.
 */
const loadEndingChain = async (
  db: Db,
  storyId: string,
  rootNodeId: string | null,
  nodeId: string
): Promise<ChainLink[]> => {
  const snap = await db.collection(`stories/${storyId}/nodes`).get();
  const byId = new Map<string, {[field: string]: unknown}>();
  for (const doc of snap.docs) {
    const data = doc.data();
    if (data !== undefined) byId.set(doc.id, data);
  }
  const parent = new Map<string, {from: string; label: string | null}>();
  for (const [id, data] of byId) {
    if (!Array.isArray(data.choices)) continue;
    for (const choice of data.choices) {
      const fields = toRecord(choice);
      const target = optString(fields.targetNodeId);
      if (target !== null && !parent.has(target)) {
        parent.set(target, {from: id, label: optString(fields.label)});
      }
    }
  }
  const reversed: ChainLink[] = [];
  const seen = new Set<string>();
  let current: string | null = nodeId;
  while (current !== null && !seen.has(current)) {
    seen.add(current);
    const data = byId.get(current);
    const link = parent.get(current);
    reversed.push({
      title: data === undefined ? null : optString(data.title),
      choiceLabel: link === undefined ? null : link.label,
    });
    if (current === rootNodeId || reversed.length > maxChainLinks) break;
    current = link === undefined ? null : link.from;
  }
  return reversed.reverse();
};

/**
 * Behaviour text for the reference-guided badge call: widen the
 * vertical last frame into a blurred square backdrop, center one
 * emblem on it, and theme the art with the parent-node path. Pure
 * so tests pin the copy without a Db.
 * @param {Object} args Ending name/type plus the parent chain.
 * @return {string} The instructions text.
 */
export const buildBadgeInstructions = (args: {
  title?: string | null;
  endingType?: string | null;
  chain?: ChainLink[];
}): string => {
  const name = clip(args.title, 40);
  const type = clip(args.endingType, 24);
  const kind = type === "" ? "EPIC" : type.toUpperCase();
  const mood = badgeMood(type);
  const gem = mood === "" ? "gem" : `gem (${mood})`;
  const parts = [
    "Expand this vertical last frame into a SQUARE badge illustration " +
    `for a ${kind} story ending trophy. Widen the sides to square, ` +
    "heavily blur the background with bokeh, and generate on top ONE " +
    "centered epic legendary trophy badge: ornate metallic shield, " +
    "trophy cup on top, laurel branches, a cracked central crystal " +
    `${gem}. Sticker style with a thin ` +
    "light outline so it reads as an unlocked prize. Single centered " +
    "emblem, fully inside the frame with margin, no people, no " +
    "readable text.",
  ];
  if (name !== "") {
    parts.push(`Ending name: "${name}".`);
  }
  const lines = (args.chain ?? [])
    .map((link, index) => formatChainLink(link, index))
    .filter((line) => line !== "");
  if (lines.length > 0) {
    parts.push(
      "Story inspiration (player decisions that led here):\n" +
      lines.join("\n")
    );
  }
  return parts.join("\n\n");
};

/**
 * One chain step as inspiration text: the node title plus the choice
 * label taken to leave it.
 * @param {ChainLink} link Chain step.
 * @param {number} index Zero-based position in the root-first chain.
 * @return {string} The step line, or blank when untitled.
 */
const formatChainLink = (link: ChainLink, index: number): string => {
  const title = clip(link.title, 40);
  if (title === "") return "";
  const label = clip(link.choiceLabel, 24);
  const step = index + 1;
  return label === "" ?
    `${step}. "${title}".` :
    `${step}. "${title}" — chose "${label}".`;
};

/**
 * Default badge uploader: one PNG per ending node, overwritten on
 * regen so the node link stays stable.
 * @return {BadgeUploadFn} The uploader.
 */
const defaultUploadBadge = (): BadgeUploadFn => {
  return async (args) => {
    const path = `badges/${args.storyId}/${args.nodeId}.png`;
    const bucket = admin.storage().bucket();
    const file = bucket.file(path);
    await file.save(args.bytes, {metadata: {contentType: "image/png"}});
    return readableStorageUrl(file);
  };
};

/** PNG magic: every decoder input must start with these 8 bytes. */
const pngSignature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

/** Decoded badge pixels plus whether the art already fades out. */
interface DecodedPng {
  pixels: Buffer;
  width: number;
  height: number;
  hasAlpha: boolean;
}

/**
 * Paeth predictor for PNG unfiltering.
 * @param {number} a Left pixel.
 * @param {number} b Above pixel.
 * @param {number} c Upper-left pixel.
 * @return {number} The predicted value.
 */
const paeth = (a: number, b: number, c: number): number => {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
};

/**
 * Minimal PNG decoder: 8-bit non-interlaced truecolor (with or
 * without alpha), the shapes ffmpeg's `format=rgba` output takes.
 * Anything else returns null so the caller keeps the input.
 * @param {Buffer} png Badge PNG bytes.
 * @return {DecodedPng | null} The pixels, or null.
 */
const decodePng = (png: Buffer): DecodedPng | null => {
  if (png.length < 8 || !png.subarray(0, 8).equals(pngSignature)) return null;
  let offset = 8;
  let width = 0;
  let height = 0;
  let bitDepth = 0;
  let colorType = -1;
  let interlace = -1;
  const idat: Buffer[] = [];
  while (offset + 8 <= png.length) {
    const length = png.readUInt32BE(offset);
    const type = png.subarray(offset + 4, offset + 8).toString("ascii");
    const data = png.subarray(offset + 8, offset + 8 + length);
    if (data.length !== length || offset + 12 + length > png.length) {
      return null;
    }
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      interlace = data[12];
    } else if (type === "IDAT") {
      idat.push(Buffer.from(data));
    } else if (type === "IEND") {
      break;
    }
    offset += 12 + length;
  }
  if (bitDepth !== 8 || interlace !== 0) return null;
  const channels = colorType === 6 ? 4 : colorType === 2 ? 3 : -1;
  if (channels < 0 || width <= 0 || height <= 0) return null;
  let raw: Buffer;
  try {
    raw = inflateSync(Buffer.concat(idat));
  } catch {
    return null;
  }
  const stride = width * channels;
  if (raw.length !== (stride + 1) * height) return null;
  const pixels = Buffer.alloc(width * height * 4);
  const prev = Buffer.alloc(stride);
  const line = Buffer.alloc(stride);
  let hasAlpha = false;
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    raw.copy(line, 0, y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let i = 0; i < stride; i++) {
      const a = i >= channels ? line[i - channels] : 0;
      const b = prev[i];
      const c = i >= channels ? prev[i - channels] : 0;
      let recon: number;
      switch (filter) {
      case 0:
        recon = line[i];
        break;
      case 1:
        recon = (line[i] + a) & 255;
        break;
      case 2:
        recon = (line[i] + b) & 255;
        break;
      case 3:
        recon = (line[i] + ((a + b) >> 1)) & 255;
        break;
      case 4:
        recon = (line[i] + paeth(a, b, c)) & 255;
        break;
      default:
        return null;
      }
      line[i] = recon;
    }
    line.copy(prev);
    for (let x = 0; x < width; x++) {
      const dst = (y * width + x) * 4;
      const src = x * channels;
      pixels[dst] = line[src];
      pixels[dst + 1] = line[src + 1];
      pixels[dst + 2] = line[src + 2];
      const alpha = channels === 4 ? line[src + 3] : 255;
      pixels[dst + 3] = alpha;
      if (alpha < 250) hasAlpha = true;
    }
  }
  return {pixels, width, height, hasAlpha};
};

/** CRC table for PNG chunk checksums, built once at load. */
const crcTable: number[] = [];
for (let n = 0; n < 256; n++) {
  let c = n;
  for (let k = 0; k < 8; k++) {
    c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  }
  crcTable.push(c >>> 0);
}

/**
 * CRC32 over `bytes`, for PNG chunk trailers.
 * @param {Buffer} bytes Type plus data bytes.
 * @return {number} The checksum.
 */
const crc32 = (bytes: Buffer): number => {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc = (crcTable[(crc ^ byte) & 255] as number) ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
};

/**
 * One PNG chunk: length, type, data, and checksum.
 * @param {string} type 4-letter chunk type.
 * @param {Buffer} data Chunk payload.
 * @return {Buffer} The encoded chunk.
 */
const encodeChunk = (type: string, data: Buffer): Buffer => {
  const chunk = Buffer.alloc(12 + data.length);
  chunk.writeUInt32BE(data.length, 0);
  chunk.write(type, 4, "ascii");
  data.copy(chunk, 8);
  const check = Buffer.concat([Buffer.from(type, "ascii"), data]);
  chunk.writeUInt32BE(crc32(check), 8 + data.length);
  return chunk;
};

/**
 * Minimal PNG encoder: 8-bit truecolor plus alpha, no filtering.
 * @param {Buffer} pixels RGBA pixels, row-major.
 * @param {number} width Image width.
 * @param {number} height Image height.
 * @return {Buffer} The encoded PNG.
 */
const encodePng = (
  pixels: Buffer,
  width: number,
  height: number
): Buffer => {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    pixels.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  return Buffer.concat([
    pngSignature,
    encodeChunk("IHDR", ihdr),
    encodeChunk("IDAT", deflateSync(raw)),
    encodeChunk("IEND", Buffer.alloc(0)),
  ]);
};
