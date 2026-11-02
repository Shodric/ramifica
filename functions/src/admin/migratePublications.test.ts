import {strict as assert} from "assert";
import {test} from "node:test";
import * as admin from "firebase-admin";
import {migrateStory, projectNode} from "./migratePublications";

test("migration projections preserve legacy URLs/counts and omit " +
    "all private fields", () => {
  const root = {
    title: "Gate",
    videoUrl: "legacy-url",
    durationSeconds: 6,
    videoPrompt: "private",
    choices: [{choiceId: "c", targetNodeId: "secret", label: "Enter"}],
    choiceCounts: {c: 12},
  };
  const secret = {
    title: "Hidden",
    visibility: "secret",
    videoUrl: "hidden-url",
    isEnding: true,
  };
  const nodes = new Map(Object.entries({root, secret}));
  const projected = projectNode("root", root, nodes);
  assert.equal(projected.body.videoUrl, "legacy-url");
  assert.equal(projected.body.durationSeconds, 6);
  assert.equal("videoPrompt" in projected.body, false);
  assert.equal(projected.body.choices[0].target, null);
  assert.deepEqual(projected.stats.choiceCounts, {c: 12});
  assert.deepEqual(projectNode("secret", secret, nodes).map, {secret: true});
});

test("admin migration inspects, activates once, and preserves " +
    "source IDs/URLs/hashes/stats", {
  skip: !process.env.RAMIFICA_RULES_EMULATOR_HOST,
}, async () => {
  const host = process.env.RAMIFICA_RULES_EMULATOR_HOST!;
  assert.match(host, /^127\.0\.0\.1:\d+$/);
  const app = admin.initializeApp(
    {projectId: "demo-ramifica-plan"},
    "publication-migration"
  );
  const db = app.firestore(); db.settings({host, ssl: false});
  try {
    const ref = db.doc("stories/migration_case");
    const root = {
      title: "Legacy",
      videoUrl: "https://cdn.example/legacy.mp4",
      durationSeconds: 6,
      legacyField: "unchanged",
      videoPrompt: "private",
      choices: [
        {choiceId: "c", targetNodeId: "end", label: "Enter"},
      ],
      choiceCounts: {c: 5},
    };
    await ref.set({
      authorId: "author",
      status: "published",
      rootNodeId: "root",
    });
    await ref.collection("nodes").doc("root").set(root);
    await ref.collection("nodes").doc("end").set({
      title: "End",
      isEnding: true,
      videoUrl: "https://cdn.example/end.mp4",
      durationSeconds: 6,
      choices: [],
    });
    const inspect = await migrateStory(
      db,
      ref.id,
      {apply: false, probe: false}
    );
    assert.equal(inspect.status, "inspect");
    assert.equal(
      (await ref.get()).data()?.activePublicationId,
      undefined
    );
    assert.equal(
      (await migrateStory(db, ref.id, {apply: true, probe: false}))
        .status,
      "migrated"
    );
    const current = (await ref.get()).data()!;
    assert.equal(
      (await migrateStory(db, ref.id, {apply: true, probe: false}))
        .status,
      "already-current"
    );
    assert.deepEqual(
      (await ref.collection("nodes").doc("root").get()).data(),
      root
    );
    const stats = await ref
      .collection("publications")
      .doc(current.activePublicationId)
      .collection("stats")
      .doc("root")
      .get();
    assert.deepEqual(stats.data()?.choiceCounts, {c: 5});
  } finally {
    await db.terminate(); await app.delete();
  }
});
