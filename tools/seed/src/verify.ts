/** Inspect the seeded publication without retired business callables.
 * Gameplay and rules are exercised by test/direct_firestore_rules_test.dart.
 */
import * as admin from "firebase-admin";
import {readManifest} from "./manifest";
import {initTarget} from "./store";
async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const flag = (name: string): string | undefined => {
    const at = args.indexOf(name); return at < 0 ? undefined : args[at + 1];
  };
  const project = flag("--project");
  initTarget({emulator: !project, project});
  const manifest = readManifest(flag("--dir") ?? "stories/temple");
  const db = admin.firestore();
  const ref = db.doc(`stories/${manifest.storyId}`);
  const story = (await ref.get()).data();
  if (!story?.activePublicationId) throw new Error("Run the publication migration first.");
  const base = ref.collection("publications").doc(story.activePublicationId);
  const [nodes, map, stats] = await Promise.all([
    base.collection("nodes").get(), base.collection("map").get(), base.collection("stats").get(),
  ]);
  if (nodes.size !== manifest.nodes.length || map.size !== nodes.size || stats.size !== nodes.size) {
    throw new Error("Incomplete publication projections.");
  }
  for (const doc of nodes.docs) {
    const node = doc.data();
    if (["videoPrompt", "startImagePrompt", "endImagePrompt", "videoJobId"].some((key) => key in node)) {
      throw new Error(`Private fields in publication node ${doc.id}.`);
    }
    if (!node.videoUrl || !node.durationSeconds) throw new Error(`Missing media for ${doc.id}.`);
  }
  for (const doc of map.docs) if (doc.data().secret && Object.keys(doc.data()).length !== 1) {
    throw new Error(`Secret map node ${doc.id} exposes content.`);
  }
  const page = await fetch(`http://127.0.0.1:${flag("--hosting-port") ?? "5000"}/story/${manifest.storyId}`);
  const html = await page.text();
  if (!page.ok || !html.includes('content="Ramifica"')) throw new Error("The generic SPA link preview is missing.");
  console.log(`Verified ${nodes.size} playback/map/stats projections and generic SPA share page.`);
  await db.terminate();
}
main().catch((error) => { console.error(error.message); process.exitCode = 1; });
