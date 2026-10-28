/**
 * End-to-end check against the emulators: sign up, play the seeded story
 * through the real HTTP callables (hold, default, replay, stale, restart,
 * ending), then fetch the link preview. Needs the emulator suite running.
 *
 * Usage: npm run verify -- --dir stories/temple [--project demo-ramifica]
 */
import {join} from "path";
const BASE = "http://127.0.0.1";
const DEFAULT_PROJECT = "demo-ramifica";

interface Ctx {
  project: string;
  functionsPort: number;
  hostingPort: number;
  authPort: number;
  storyId: string;
  rootNodeId: string;
}

interface Choice {
  choiceId: string;
  isDefault?: boolean;
}

interface PlaybackNode {
  nodeId: string;
  isEnding?: boolean;
  endingName?: unknown;
  choices: Choice[];
  status?: string;
}

type Caller = (fn: string, data: unknown) => Promise<Record<string, unknown>>;

/**
 * Runs the full arc and throws on the first mismatch.
 */
async function main(): Promise<void> {
  const ctx = parseArgs(process.argv.slice(2));
  const email = `e2e-${Date.now()}@example.com`;
  const idToken = await signUp(ctx, email);
  const call = async (
    fn: string,
    data: unknown
  ): Promise<Record<string, unknown>> => {
    return callFunction(ctx, fn, idToken, data);
  };

  const started = (await call("startRun", {storyId: ctx.storyId})) as {
    runId: string;
    storyId: string;
    status: string;
  };
  assert(started.runId, "startRun returns a run");
  assert(started.storyId === ctx.storyId, `opens ${ctx.storyId}`);
  assert(started.status === "active", "run starts active");

  let runId = started.runId;
  let current = await playback(call, runId);
  assert(current.nodeId === ctx.rootNodeId, "starts at the root");
  assert(current.choices.length >= 1, "root decides");

  const seen = new Set<string>([current.nodeId]);
  for (let step = 0; step < 8; step++) {
    if (current.isEnding) break;
    const fallback = current.choices.find((choice) => choice.isDefault);
    if (!fallback) throw new Error("Decision without a default.");
    const requestId = `e2e-${step}-${Date.now()}`;
    const params = {
      runId,
      fromNodeId: current.nodeId,
      choiceId: fallback.choiceId,
      requestId,
    };
    const result = (await call("commitChoice", params)) as {
      playback: {node: {nodeId: string}};
    };
    const nextId = result.playback.node.nodeId;
    assert(nextId !== current.nodeId, `commit advances (${nextId})`);
    if (seen.has(nextId)) {
      throw new Error(`Run looped back to ${nextId}.`);
    }
    seen.add(nextId);
    const replayed = (await call("commitChoice", params)) as {
      playback: {node: {nodeId: string}};
    };
    assert(
      replayed.playback.node.nodeId === nextId,
      "same requestId returns the stored result"
    );
    current = await playback(call, runId);
  }
  assert(current.isEnding, "the walk reaches an ending");
  assert(
    typeof current.endingName === "string" && current.endingName !== "",
    "ending has a name"
  );

  const stale = await tryCall(call, "commitChoice", {
    runId,
    fromNodeId: ctx.rootNodeId,
    choiceId: "choice_nope",
    requestId: "e2e-stale",
  });
  assert(stale === "INVALID_ARGUMENT", "stale node is rejected");

  const restarted = (await call("startRun", {
    storyId: ctx.storyId,
    restart: true,
  })) as {runId: string; status: string};
  assert(restarted.runId !== runId, "restart opens a new run");
  runId = restarted.runId;
  current = await playback(call, runId);
  assert(current.nodeId === ctx.rootNodeId, "restart parks at the root");
  assert(current.status === "active", "restarted run is active");

  const page = await fetch(
    `http://127.0.0.1:${ctx.hostingPort}/story/${ctx.storyId}`
  );
  const html = await page.text();
  assert(page.status === 200, "storyPage answers 200");
  assert(html.includes("og:title"), "preview carries OG tags");
  console.log(`E2E OK: ${seen.size} nodes.`);
}

/**
 * Loads the current node through the real `loadPlayback`.
 * @param {Caller} call Callable caller.
 * @param {string} runId Run id.
 */
async function playback(
  call: Caller,
  runId: string
): Promise<PlaybackNode & {status: string}> {
  const loaded = (await call("loadPlayback", {runId})) as {
    status: string;
    node: Record<string, unknown>;
    choices: Choice[];
  };
  return {
    nodeId: String(loaded.node.nodeId),
    isEnding: loaded.node.isEnding === true,
    endingName: loaded.node.endingName,
    choices: loaded.choices,
    status: loaded.status,
  };
}

/**
 * Creates an auth emulator user and returns its ID token.
 * @param {Ctx} ctx Ports and project.
 * @param {string} email Login email.
 */
async function signUp(ctx: Ctx, email: string): Promise<string> {
  const url =
    `${BASE}:${ctx.authPort}/identitytoolkit.googleapis.com` +
    "/v1/accounts:signUp?key=fake-api-key";
  const response = await fetch(url, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({
      email,
      password: "password123",
      returnSecureToken: true,
    }),
  });
  if (!response.ok) {
    throw new Error(`Auth emulator sign-up failed: ${response.status}.`);
  }
  const body = (await response.json()) as {idToken?: unknown};
  if (typeof body.idToken !== "string" || body.idToken === "") {
    throw new Error("Auth emulator returned no token.");
  }
  return body.idToken;
}

/**
 * Calls a callable over HTTP like the Flutter repository does. The
 * functions enforce App Check, and the emulator unsafe-decodes tokens
 * (skipTokenVerification), so an unsigned debug JWT is enough here.
 * @param {Ctx} ctx Ports and project.
 * @param {string} fn Function name.
 * @param {string} idToken Auth token.
 * @param {unknown} data Callable payload.
 */
async function callFunction(
  ctx: Ctx,
  fn: string,
  idToken: string,
  data: unknown
): Promise<Record<string, unknown>> {
  const url = `${BASE}:${ctx.functionsPort}/${ctx.project}/us-central1/${fn}`;
  const encode = (value: unknown): string =>
    Buffer.from(JSON.stringify(value)).toString("base64url");
  const appCheck = `${encode({alg: "none"})}.${encode({sub: ctx.project})}.`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${idToken}`,
      "X-Firebase-AppCheck": appCheck,
    },
    body: JSON.stringify({data}),
  });
  const body = (await response.json()) as {
    result?: unknown;
    error?: {message?: unknown; status?: unknown};
  };
  if (!response.ok || body.error || body.result === undefined) {
    const status =
      typeof body.error?.status === "string" ?
        body.error.status :
        `HTTP ${response.status}`;
    const message =
      typeof body.error?.message === "string" ?
        body.error.message :
        "request failed";
    throw new Error(`${fn} failed (${status}): ${message}`);
  }
  return body.result as Record<string, unknown>;
}
/**
 * Runs a callable that is expected to fail, returning its status code.
 * @param {Caller} call Callable caller.
 * @param {string} fn Function name.
 * @param {unknown} data Callable payload.
 */
async function tryCall(
  call: Caller,
  fn: string,
  data: unknown
): Promise<string> {
  try {
    await call(fn, data);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const match = new RegExp(
      "INVALID_ARGUMENT|NOT_FOUND|PERMISSION_DENIED|" +
        "FAILED_PRECONDITION|UNAUTHENTICATED"
    ).exec(message);
    return match ? match[0] : `unexpected: ${message}`;
  }
  return "no-throw";
}

/**
 * Asserts a step and logs it, so the run reads as a checklist.
 * @param {unknown} condition Step result.
 * @param {string} what Step name.
 */
function assert(condition: unknown, what: string): void {
  if (!condition) throw new Error(`E2E failed: ${what}.`);
  console.log(`ok - ${what}`);
}

interface Args {
  dir: string;
  project: string;
  functionsPort: number;
  hostingPort: number;
  authPort: number;
}

/**
 * CLI flags plus the story coordinates from its manifest.
 * @param {string[]} argv Raw args.
 * @return {Object} Parsed options and story coordinates.
 */
function parseArgs(argv: string[]): Ctx & Args {
  const get = (flag: string): string | undefined => {
    const index = argv.indexOf(flag);
    return index === -1 ? undefined : argv[index + 1];
  };
  const dir = get("--dir");
  if (!dir) throw new Error("Pass --dir <story folder>.");
  const manifestPath = join(
    process.cwd(),
    dir.replace(/\/+$/, ""),
    "story.json"
  );
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const manifest = require(manifestPath) as {
    storyId?: unknown;
    rootNodeId?: unknown;
  };
  if (
    typeof manifest.storyId !== "string" ||
    typeof manifest.rootNodeId !== "string"
  ) {
    throw new Error("story.json needs storyId and rootNodeId.");
  }
  return {
    dir,
    project: get("--project") ?? DEFAULT_PROJECT,
    functionsPort: Number(get("--functions-port") ?? 5001),
    hostingPort: Number(get("--hosting-port") ?? 5000),
    authPort: Number(get("--auth-port") ?? 9099),
    storyId: manifest.storyId,
    rootNodeId: manifest.rootNodeId,
  };
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
