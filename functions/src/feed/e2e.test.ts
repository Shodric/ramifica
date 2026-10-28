import * as admin from "firebase-admin";
import {strict as assert} from "assert";
import {test} from "node:test";
import makeTest from "firebase-functions-test";
import type {
  CallableFunction,
  CallableRequest,
} from "firebase-functions/v2/https";
import {commitChoice} from "./commitChoice";
import {loadPlayback} from "./loadPlayback";
import {startRun} from "./startRun";

process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";

if (admin.apps.length === 0) {
  admin.initializeApp({projectId: "demo-ramifica"});
}

const db = admin.firestore();

interface CallData {
  [field: string]: unknown;
}

/**
 * Calls a v2 callable the way the emulator would, with the auth context
 * the Functions emulator does not attach on its own. App Check is not
 * enforced on wrapped calls.
 * @param {CallableFunction<unknown, unknown>} fn Callable under test.
 * @param {string} uid Caller.
 * @param {CallData} data Payload.
 * @return {Promise<Record<string, unknown>>} The result.
 */
async function call(
  fn: CallableFunction<unknown, unknown>,
  uid: string,
  data: CallData
): Promise<Record<string, unknown>> {
  const wrapped = makeTest().wrap(fn);
  const request = {
    auth: {uid, token: {uid}},
    data,
  } as unknown as CallableRequest;
  return (await wrapped(request)) as Record<string, unknown>;
}

/** A doc ref in the emulator project.
 * @param {string} path Full doc path.
 * @return {FirebaseFirestore.DocumentReference} The ref.
 */
function doc(path: string): FirebaseFirestore.DocumentReference {
  return db.doc(path);
}
/** Seeds a published two-node story straight into the emulator. */
async function seed(): Promise<void> {
  await doc("users/u1").set({displayName: "Alex Vance"});
  await doc("stories/story_e2e").set({
    authorId: "u1",
    title: "E2E",
    status: "published",
    rootNodeId: "node_1",
    featured: true,
  });
  await doc("stories/story_e2e/nodes/node_1").set({
    title: "Root",
    visibility: "visible",
    isEnding: false,
    videoUrl: "https://example.com/a.mp4",
    durationSeconds: 10,
    pauseAtSeconds: 9.967,
    windowSeconds: 6,
    videoFrameLastBlurData: "data:image/webp;base64,abc",
    choices: [
      {
        choiceId: "c_default",
        label: "Go",
        targetNodeId: "node_2",
        isDefault: true,
        x: 0.5,
        y: 0.5,
        radius: 0.2,
      },
    ],
  });
  await doc("stories/story_e2e/nodes/node_2").set({
    title: "End",
    visibility: "visible",
    isEnding: true,
    endingName: "Done",
    endingType: "abierto",
    videoUrl: "https://example.com/b.mp4",
    durationSeconds: 10,
    pauseAtSeconds: 9.967,
    windowSeconds: 6,
    videoFrameLastBlurData: "data:image/webp;base64,abc",
    choices: [],
  });
}

test("plays a story end to end through the real handlers", async () => {
  await seed();

  const started = (await call(startRun, "u1", {})) as {
    runId: string;
    storyId: string;
    status: string;
  };
  assert.equal(started.storyId, "story_e2e");
  assert.equal(started.status, "active");

  const opened = (await call(loadPlayback, "u1", {
    runId: started.runId,
  })) as {node: {nodeId: string; isEnding: boolean}};
  assert.equal(opened.node.nodeId, "node_1");

  const done = (await call(commitChoice, "u1", {
    runId: started.runId,
    fromNodeId: "node_1",
    choiceId: "c_default",
    requestId: "req-1",
  })) as {playback: {node: {nodeId: string}; status: string}};
  assert.equal(done.playback.node.nodeId, "node_2");
  assert.equal(done.playback.status, "ended");

  const replayed = (await call(commitChoice, "u1", {
    runId: started.runId,
    fromNodeId: "node_1",
    choiceId: "c_default",
    requestId: "req-1",
  })) as {playback: {node: {nodeId: string}}};
  assert.equal(replayed.playback.node.nodeId, "node_2");

  const fresh = (await call(startRun, "u1", {
    storyId: "story_e2e",
    restart: true,
  })) as {runId: string; status: string};
  assert.notEqual(fresh.runId, started.runId);
  const parked = (await call(loadPlayback, "u1", {
    runId: fresh.runId,
  })) as {node: {nodeId: string}};
  assert.equal(parked.node.nodeId, "node_1");
});
