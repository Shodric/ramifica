import * as admin from "firebase-admin";
import {initTarget} from "./store";

/**
 * Loads the launch saga by hand with the Admin SDK (never client code).
 * Idempotent: fixed doc id, plain `set` overwrite, safe to re-run.
 * The launch catalog holds one story, so the saga opens with that single
 * entry; appending a second story later is the same command after adding
 * its id to `storyIds` and its opening rule to `unlocks`.
 *
 * Usage:
 *   npm run seed:saga                       # emulator (demo-ramifica)
 *   npm run seed:saga -- --project <id>     # real project
 */
async function main(): Promise<void> {
  const project = flag("--project");
  initTarget({emulator: !project, project});
  const db = admin.firestore();
  await db.doc("sagas/saga_temple").set({
    authorId: "uid_ramifica",
    title: "The Temple Saga",
    storyIds: ["story_temple"],
    unlocks: [],
    updatedAt: new Date().toISOString(),
  });
  console.log("Seeded sagas/saga_temple (story_temple).");
}

/**
 * Value of `--flag <value>`, when present.
 * @param {string} name Flag name.
 * @return {string | undefined} The value, or undefined.
 */
function flag(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
