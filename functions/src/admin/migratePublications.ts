import * as admin from "firebase-admin";
import {probeDuration, probeSize} from "../media/processVideo";

type Fields = Record<string, unknown>;
const record = (v: unknown): Fields => {
  if (v && typeof v === "object" && !Array.isArray(v)) return v as Fields;
  return {};
};
const list = (v: unknown): Fields[] => Array.isArray(v) ? v.map(record) : [];
const fallbackBlur = "data:image/png;base64," +
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAF" +
  "gAI/ScLbtAAAAABJRU5ErkJggg==";

/**
 * Explicit public projections. Never spread private source node fields.
 * @param {string} id Node id.
 * @param {Fields} node Source node fields.
 * @param {Map<string, Fields>} nodes Sibling nodes by id.
 * @return {Object} The public projection.
 */
export const projectNode = (
  id: string,
  node: Fields,
  nodes: Map<string, Fields>
) => {
  const choices: Fields[] = list(node.choices).map((c) => {
    const targetId = String(c.targetNodeId);
    const target = nodes.get(targetId);
    const secret = target?.visibility === "secret";
    return {
      ...Object.fromEntries(["choiceId", "label", "targetNodeId",
        "isDefault", "x", "y", "radius", "icon", "iconColor"]
        .map((key) => [key, c[key] ?? null])), targetSecret: secret,
      target: secret ? null : {
        nodeId: targetId, videoUrl: target?.videoUrl ?? null,
      },
    };
  });
  const body: Fields & {choices: Fields[]} = {
    ...Object.fromEntries(["title", "videoUrl", "durationSeconds",
      "videoWidth", "videoHeight",
      "ttsText", "ttsAudioUrl", "ttsDurationSeconds", "endingName",
      "endingType", "thumbnailUrl"]
      .map((key) => [key, node[key] ?? null])),
    isEnding: node.isEnding === true, visibility: node.visibility ?? "visible",
    videoFrameLastBlurData: node.videoFrameLastBlurData ??
      fallbackBlur,
    choices,
  };
  const map = node.visibility === "secret" ? {secret: true} : {
    secret: false, title: node.title ?? null, isEnding: node.isEnding === true,
    thumbnailUrl: node.thumbnailUrl ?? null,
    childIds: choices.map((c) => c.targetNodeId),
  };
  const stats = {
    visibility: node.visibility ?? "visible",
    choiceCounts: Object.fromEntries(
      choices.map((c) => [
        String(c.choiceId),
        Number(record(node.choiceCounts)[String(c.choiceId)] ?? 0),
      ])
    ),
  };
  return {id, body, map, stats};
};

export interface MigrationOptions {
  apply: boolean;
  probe: boolean;
  storyId?: string;
}
export interface MigrationReport {
  storyId: string;
  status: "inspect" | "migrated" | "already-current" | "conflict";
  nodes: number;
  metadataUpdates: number;
  warnings: string[];
}

/**
 * Fill missing metadata only. Probing reads existing bytes;
 * never re-encodes.
 * @param {Fields} node Source node fields.
 * @return {Promise<Fields>} The missing metadata patch.
 */
export const inspectMetadata = async (node: Fields): Promise<Fields> => {
  const patch: Fields = {};
  for (const [urlKey, widthKey, heightKey] of [
    ["videoUrl", "videoWidth", "videoHeight"],
    ["startImageSourceUrl", "startImageWidth", "startImageHeight"],
    ["videoFrameLastUrl", "videoWidth", "videoHeight"],
  ]) {
    const url = node[urlKey];
    if (typeof url !== "string" || !/^https?:\/\//.test(url)) continue;
    if (node[widthKey] == null || node[heightKey] == null) {
      const size = await probeSize(url);
      if (node[widthKey] == null) patch[widthKey] = size.width;
      if (node[heightKey] == null) patch[heightKey] = size.height;
    }
    if (urlKey === "videoUrl" && node.durationSeconds == null) {
      patch.durationSeconds = await probeDuration(url);
    }
  }
  return patch;
};

/**
 * Stage immutable projections, then atomically activate only the same
 * revision.
 * @param {admin.firestore.Firestore} db Firestore.
 * @param {string} storyId Story id.
 * @param {MigrationOptions} options Apply/probe flags.
 * @return {Promise<MigrationReport>} The migration report.
 */
export const migrateStory = async (
  db: admin.firestore.Firestore,
  storyId: string,
  options: MigrationOptions
): Promise<MigrationReport> => {
  const ref = db.doc(`stories/${storyId}`);
  const snapshot = await ref.get();
  const story = snapshot.data();
  if (!story) throw new Error(`Story ${storyId} is missing.`);
  const docs = await ref.collection("nodes").get();
  const nodes = new Map(docs.docs.map((d) => [d.id, d.data() as Fields]));
  const report: MigrationReport = {
    storyId,
    status: "inspect",
    nodes: nodes.size,
    metadataUpdates: 0,
    warnings: [],
  };
  const revision = Number(story.revision ?? 0);
  const metadata = new Map<string, Fields>();
  if (options.probe) {
    for (const [id, node] of nodes) {
      try {
        const patch = await inspectMetadata(node);
        if (Object.keys(patch).length) {
          metadata.set(id, patch); nodes.set(id, {...node, ...patch});
        }
      } catch {
        report.warnings.push(`Node ${id}: could not verify media metadata.`);
      }
    }
  }
  report.metadataUpdates = metadata.size;
  if (story.status !== "published") {
    // Metadata for a draft participates in its revision fence too.
    if (options.apply && metadata.size) {
      await db.runTransaction(async (tx) => {
        const live = (await tx.get(ref)).data();
        if (!live || Number(live.revision ?? 0) !== revision) {
          throw new Error("Draft changed during metadata inspection.");
        }
        for (const [id, patch] of metadata) {
          tx.update(ref.collection("nodes").doc(id), patch);
        }
        tx.update(ref, {revision: revision + 1});
      });
    }
    return report;
  }
  if (typeof story.activePublicationId === "string") {
    report.status = "already-current";
    return report;
  }
  if (!nodes.has(story.rootNodeId) || !nodes.size) {
    report.warnings.push(
      "Missing root or nodes: publication was not activated."
    );
    return report;
  }
  for (const [id, node] of nodes) {
    if (node.durationSeconds == null) {
      report.warnings.push(
        `Node ${id}: duration is missing; rerun with --probe.`
      );
    }
  }
  if (
    [...nodes.values()].some(
      (n) => n.durationSeconds == null || !n.videoUrl
    )
  ) {
    return report;
  }
  // A deterministic container makes interrupted admin runs idempotent.
  const publicationId = `migration-v1-r${revision}`;
  const publication = ref.collection("publications").doc(publicationId);
  const author = await db.doc(`users/${story.authorId}`).get();
  const writes: Array<[admin.firestore.DocumentReference, Fields]> = [
    [publication, {
      sourceRevision: revision,
      nodeCount: nodes.size,
      rootNodeId: story.rootNodeId,
      migrationVersion: 1,
      createdAt: new Date().toISOString(),
    }],
  ];
  for (const [id, node] of nodes) {
    const projected = projectNode(id, node, nodes);
    writes.push([publication.collection("nodes").doc(id), projected.body],
      [publication.collection("map").doc(id), projected.map],
      [publication.collection("stats").doc(id), projected.stats]);
  }
  if (!options.apply) return report;
  for (let start = 0; start < writes.length; start += 150) {
    const batch = db.batch();
    for (const [target, data] of writes.slice(start, start + 150)) {
      batch.set(target, data);
    }
    await batch.commit();
  }
  const activated = await db.runTransaction(async (tx) => {
    const live = (await tx.get(ref)).data();
    if (
      !live ||
      live.status !== "published" ||
      Number(live.revision ?? 0) !== revision
    ) {
      return false;
    }
    if (live.activePublicationId != null) {
      return live.activePublicationId === publicationId;
    }
    for (const [id, patch] of metadata) {
      tx.update(ref.collection("nodes").doc(id), patch);
    }
    tx.update(ref, {
      activePublicationId: publicationId,
      authorName: story.authorName ?? author.data()?.displayName ?? "Unknown",
      revision: revision + 1,
    });
    return true;
  });
  report.status = activated ? "migrated" : "conflict";
  return report;
};

/**
 * Administrative CLI. Inspection is the default; project is always
 * explicit.
 */
async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const value = (flag: string): string | undefined => {
    const index = args.indexOf(flag);
    return index < 0 ? undefined : args[index + 1];
  };
  const projectId = value("--project");
  if (!projectId || projectId.startsWith("--")) {
    throw new Error("Specify --project <firebase-project-id>.");
  }
  const options = {
    apply: args.includes("--apply"),
    probe: args.includes("--probe"),
    storyId: value("--story"),
  };
  const app = admin.initializeApp({projectId});
  const db = app.firestore();
  const ids = options.storyId ?
    [options.storyId] :
    (await db.collection("stories").get()).docs.map((d) => d.id);
  for (const id of ids) {
    console.log(JSON.stringify(await migrateStory(db, id, options)));
  }
  await db.terminate(); await app.delete();
}
if (require.main === module) {
  main().catch((error) => {
    console.error(error.message); process.exitCode = 1;
  });
}
