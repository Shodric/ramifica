import {strict as assert} from "assert";
import {test} from "node:test";
import * as admin from "firebase-admin";
import {Db} from "../feed/shared";
import {createNodeWith} from "./nodes";

const emulatorHost = process.env.RAMIFICA_RULES_EMULATOR_HOST;
const projectId = "demo-ramifica-plan";

/**
 * Emulator-only unsigned Firebase token; no real credentials or services.
 * @param {string} uid Test author.
 * @return {string} Unsigned emulator token.
 */
const tokenFor = (uid: string): string => {
  const encode = (value: unknown): string =>
    Buffer.from(JSON.stringify(value)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  return `${encode({alg: "none", typ: "JWT"})}.${encode({
    iss: `https://securetoken.google.com/${projectId}`,
    aud: projectId,
    iat: now,
    exp: now + 3600,
    sub: uid,
    user_id: uid,
    firebase: {sign_in_provider: "custom", identities: {}},
  })}.`;
};

/**
 * Encode the primitive patch fields used by the rules cases.
 * @param {unknown} value Primitive field value.
 * @return {object} Firestore REST value.
 */
const restValue = (value: unknown): Record<string, unknown> => {
  if (value === null) return {nullValue: null};
  if (typeof value === "boolean") return {booleanValue: value};
  if (typeof value === "number") return {integerValue: String(value)};
  return {stringValue: value};
};

test("scene creation and author prompts against Firestore rules", {
  skip: !emulatorHost,
}, async (t) => {
  assert.ok(emulatorHost);
  assert.match(emulatorHost, /^127\.0\.0\.1:\d+$/);
  const app = admin.initializeApp({projectId}, "create-flow-integration");
  const firestore = app.firestore();
  firestore.settings({host: emulatorHost, ssl: false});
  t.after(async () => {
    await firestore.terminate();
    await app.delete();
  });
  const storyId = "scene_flow_integration";
  const story = firestore.doc(`stories/${storyId}`);
  await story.set({
    authorId: "author", status: "draft", title: "Story", rootNodeId: "root",
  });
  const base = {
    title: "Scene", visibility: "visible", isEnding: false,
    endingName: null, endingType: null, ttsText: "Choose", lineApproved: true,
    ttsApproved: false, choices: [], ttsStatus: "idle", ttsAudioUrl: null,
    ttsDurationSeconds: null, videoStatus: "idle", requestId: "immutable-key",
  };
  await story.collection("nodes").doc("root").set(base);
  const patch = async (fields: Record<string, unknown>, uid = "author") => {
    const mask = Object.keys(fields).map((key) =>
      `updateMask.fieldPaths=${encodeURIComponent(key)}`).join("&");
    const response = await fetch(
      `http://${emulatorHost}/v1/projects/${projectId}/databases/(default)` +
        `/documents/stories/${storyId}/nodes/root?${mask}`,
      {
        method: "PATCH",
        headers: {
          "Authorization": `Bearer ${tokenFor(uid)}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({fields: Object.fromEntries(
          Object.entries(fields).map(([key, value]) => [key, restValue(value)])
        )}),
      }
    );
    return response.status;
  };
  await t.test("legacy node without prompts permits title edits", async () => {
    assert.equal(await patch({title: "Edited"}), 200);
  });
  await t.test("author can store and clear all three prompts", async () => {
    assert.equal(await patch({
      startImagePrompt: "S", endImagePrompt: "E", videoPrompt: "V",
    }), 200);
    assert.equal(await patch({
      startImagePrompt: null, endImagePrompt: null, videoPrompt: null,
    }), 200);
  });
  await t.test("prompt bounds and types are enforced", async () => {
    assert.equal(await patch({endImagePrompt: "x".repeat(2001)}), 403);
    assert.equal(await patch({endImagePrompt: 3}), 403);
    assert.equal(await patch({endImagePrompt: "x".repeat(2000)}), 200);
  });
  await t.test("media state and requestId stay server-owned", async () => {
    assert.equal(await patch({videoStatus: "ready"}), 403);
    assert.equal(await patch({requestId: "replace"}), 403);
  });
  await t.test("foreign and published stories cannot be edited", async () => {
    assert.equal(await patch({title: "Other"}, "someone-else"), 403);
    await story.update({status: "published"});
    assert.equal(await patch({title: "Published"}), 403);
    await story.update({status: "draft"});
  });
  await t.test("new narration requires the old voice to be idled", async () => {
    assert.equal(await patch({ttsText: "New line"}), 200);
    await story.collection("nodes").doc("root").update({
      ttsStatus: "ready", ttsAudioUrl: "old.wav", ttsApproved: true,
    });
    assert.equal(await patch({ttsText: "Another line"}), 403);
    assert.equal(await patch({
      ttsText: "Another line", ttsStatus: "idle", ttsAudioUrl: null,
      ttsDurationSeconds: null, ttsApproved: false, lineApproved: false,
    }), 200);
  });
  await t.test("keyed creation reuses the child and its contents", async () => {
    const requestId = `v1:author:${storyId}:root:A`;
    const data = {storyId, parentNodeId: "root", requestId};
    const created = await Promise.all(Array.from({length: 4}, () =>
      createNodeWith(firestore as unknown as Db, "author", data)));
    assert.equal(new Set(created.map((result) => result.nodeId)).size, 1);
    const child = story.collection("nodes").doc(created[0].nodeId);
    await child.update({title: "Keep this child"});
    const replay = await createNodeWith(
      firestore as unknown as Db, "author", data
    );
    assert.equal(replay.nodeId, child.id);
    assert.equal((await child.get()).data()?.title, "Keep this child");
    const matches = await story.collection("nodes")
      .where("requestId", "==", requestId).get();
    assert.equal(matches.size, 1);
  });
});
