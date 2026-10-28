import {readFileSync, statSync} from "fs";
import {join} from "path";

export interface ManifestChoice {
  choiceId: string;
  label: string;
  targetNodeId: string;
  isDefault: boolean;
  x: number;
  y: number;
  radius: number;
}

export interface ManifestNode {
  nodeId: string;
  title: string;
  visibility: string;
  isEnding: boolean;
  endingName?: string;
  endingType?: string;
  ttsText?: string;
  voiceId?: string;
  windowSeconds?: number;
  startImagePrompt?: string;
  endImagePrompt?: string;
  choices?: ManifestChoice[];
}

export interface Manifest {
  storyId: string;
  authorId: string;
  title: string;
  synopsis: string;
  locale: string;
  tags?: string[];
  featured?: boolean;
  rootNodeId: string;
  coverPrompt?: string;
  nodes: ManifestNode[];
}

export interface NodeFiles {
  video?: string;
  start?: string;
  end?: string;
  voice?: string;
}

/**
 * Reads and lightly checks `story.json`. Deep validation happens later
 * with `validateStory`, once media is processed.
 * @param {string} dir Story folder.
 * @return {Manifest} The parsed manifest.
 */
export function readManifest(dir: string): Manifest {
  const raw = JSON.parse(
    readFileSync(join(dir, "story.json"), "utf8")
  ) as Partial<Manifest>;
  if (!raw || typeof raw !== "object") {
    throw new Error(`Bad story.json in ${dir}.`);
  }
  const required: Array<keyof Manifest> = [
    "storyId",
    "authorId",
    "title",
    "synopsis",
    "locale",
    "rootNodeId",
    "nodes",
  ];
  for (const field of required) {
    if (raw[field] === undefined || raw[field] === null) {
      throw new Error(`story.json is missing ${field}.`);
    }
  }
  if (!Array.isArray(raw.nodes) || raw.nodes.length === 0) {
    throw new Error("story.json needs at least one node.");
  }
  return {
    tags: [],
    featured: false,
    ...(raw as Manifest),
  };
}

/**
 * Optional per-node input files. Whatever is missing is generated.
 * @param {string} dir Story folder.
 * @param {string} nodeId Node id.
 * @return {NodeFiles} The files that exist.
 */
export function nodeFiles(dir: string, nodeId: string): NodeFiles {
  const folder = join(dir, "nodes", nodeId);
  const found: NodeFiles = {};
  const pick = (names: string[]): string | undefined => {
    for (const name of names) {
      const full = join(folder, name);
      try {
        if (statSync(full).isFile()) return full;
      } catch {
        continue;
      }
    }
    return undefined;
  };
  const video = pick(["video.mp4", "video.mov"]);
  const start = pick(["start.png", "start.jpg", "start.jpeg"]);
  const end = pick(["end.png", "end.jpg", "end.jpeg"]);
  const voice = pick(["voz.m4a", "voz.mp3", "voz.wav", "voz.pcm"]);
  if (video) found.video = video;
  if (start) found.start = start;
  if (end) found.end = end;
  if (voice) found.voice = voice;
  return found;
}

/**
 * Optional story-level art. Whatever is missing is generated.
 * @param {string} dir Story folder.
 * @return {string | undefined} The cover file, when present.
 */
export function coverFile(dir: string): string | undefined {
  for (const name of ["cover.png", "cover.jpg", "cover.jpeg"]) {
    const full = join(dir, name);
    try {
      if (statSync(full).isFile()) return full;
    } catch {
      continue;
    }
  }
  return undefined;
}
