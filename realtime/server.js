'use strict';

// asr-relay: minimal WebSocket relay between app clients and Meta realtime ASR.
//
// Transport: client (app) <-> relay is JSON control frames + binary PCM16 LE
// mono 24 kHz. Relay <-> Meta (`wss://api.meta.ai/v1/asr/realtime`) is the Meta
// handshake below, raw PCM frames, and `{"type":"endStream"}` to finish.
//
// Relay protocol (client <-> relay), exact bytes:
//   client -> relay (first text frame, within 10 s):
//     {"type":"auth","idToken":"...","appCheckToken":"..."}
//   relay -> client (only after the Meta ack carrying `sessionId`):
//     {"type":"ready"}
//   client -> relay: binary PCM frames (forwarded immediately, never buffered;
//     frames arriving before `ready` are discarded)
//   relay -> client: {"type":"partial","text":"..."}  (Meta `transcript`)
//   relay -> client: {"type":"final","text":"..."}    (Meta `speechComplete`)
//   relay -> client: {"type":"error","message":"..."}
//   client -> relay: {"type":"end"}
//     -> relay sends `{"type":"endStream"}` to Meta, awaits `speechComplete`,
//        forwards the final text, then closes both sides with 1000.
// Auth failure closes the client with 4401 and Meta is never dialed.

const http = require('node:http');
const { WebSocketServer, WebSocket } = require('ws');

const META_REALTIME_URL = 'wss://api.meta.ai/v1/asr/realtime';
const META_DEFAULT_MODEL = 'muse-voice-transcribe-1.0';
const DEFAULT_AUTH_TIMEOUT_MS = 10_000;
const END_FINAL_TIMEOUT_MS = 5_000;

// Set on the local relay only. Skips App Check and accepts unsigned
// Auth-emulator tokens. Cloud Run does not set this. A production RS256
// ID token is still checked against Google's certs (verifyRelayIdToken).
function isEmulator() {
  return Boolean(process.env.FIREBASE_AUTH_EMULATOR_HOST);
}

function projectId() {
  return (
    process.env.GOOGLE_CLOUD_PROJECT ||
    process.env.GCLOUD_PROJECT ||
    'meta-ramifica'
  );
}

// JWT header `alg` only. The payload and the token are never logged.
function tokenAlg(idToken) {
  try {
    const part = String(idToken || '').split('.')[0];
    if (!part) return '';
    const json = JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
    return json && typeof json.alg === 'string' ? json.alg : '';
  } catch {
    return '';
  }
}

// Auth-emulator ID tokens use `alg: none`. Anything else is signed.
function isSignedAlg(alg) {
  return alg !== '' && alg !== 'none';
}

// Production verification clears FIREBASE_AUTH_EMULATOR_HOST for one call.
// firebase-admin reads that env synchronously inside verifyIdToken, so the
// calls must not overlap.
let verifyLock = Promise.resolve();

function withVerifyLock(fn) {
  const run = verifyLock.then(fn, fn);
  verifyLock = run.then(
    () => {},
    () => {},
  );
  return run;
}

function ensureApp(admin) {
  if (admin.apps.length === 0) {
    admin.initializeApp({ projectId: projectId() });
  }
}

// firebase-admin accepts only `alg: none` while the emulator host is set.
// Drop it for this call so an RS256 token is checked against Google certs.
async function verifyWithProductionCerts(admin, idToken) {
  const host = process.env.FIREBASE_AUTH_EMULATOR_HOST;
  if (host) delete process.env.FIREBASE_AUTH_EMULATOR_HOST;
  try {
    return await admin.auth().verifyIdToken(idToken || '');
  } finally {
    if (host) process.env.FIREBASE_AUTH_EMULATOR_HOST = host;
  }
}

// Unsigned emulator tokens pass the emulator verifier. A dev still signed
// in to production Auth sends RS256; that verifier reports "invalid
// signature". Fall back to Google's certs for signed tokens only.
async function verifyRelayIdToken(idToken, deps) {
  return withVerifyLock(async () => {
    if (!isEmulator()) {
      await deps.verifyProduction(idToken);
      return;
    }
    try {
      await deps.verifyEmulator(idToken);
    } catch (err) {
      if (!isSignedAlg(tokenAlg(idToken))) throw err;
      await deps.verifyProduction(idToken);
    }
  });
}

function authFailure(err, idToken) {
  const message = err && err.message ? err.message : String(err);
  const alg = tokenAlg(idToken) || 'unknown';
  return new Error(`${message} (alg=${alg})`);
}

function log(sessionId, ...args) {
  const tag = sessionId ? `session=${sessionId}` : 'session=n/a';
  console.log(`[asr-relay ${tag}]`, ...args);
}

function buildHandshake(apiKey, model) {
  return JSON.stringify({
    authorization: { accessToken: `Bearer ${apiKey}` },
    audioEncoding: 'PCM_24KHZ',
    model,
    mode: 'PUSH_TO_TALK',
    partialMode: 'CUMULATIVE',
  });
}

function messageText(msg) {
  if (msg && typeof msg.transcript === 'string') return msg.transcript;
  if (msg && typeof msg.text === 'string') return msg.text;
  return '';
}

function parseJson(data) {
  try {
    const text = Buffer.isBuffer(data) ? data.toString('utf8') : String(data);
    const msg = JSON.parse(text);
    return msg && typeof msg === 'object' ? msg : null;
  } catch {
    return null;
  }
}

function sendJson(ws, obj) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(obj));
  }
}

// Production auth: Firebase ID token always verified; App Check verified
// except in the emulator. Lazy-requires firebase-admin so tests can inject a
// stub without credentials.
async function defaultVerifyAuth(idToken, appCheckToken) {
  const admin = require('firebase-admin');
  ensureApp(admin);
  try {
    await verifyRelayIdToken(idToken, {
      verifyEmulator: (token) => admin.auth().verifyIdToken(token || ''),
      verifyProduction: (token) => verifyWithProductionCerts(admin, token),
    });
  } catch (err) {
    throw authFailure(err, idToken);
  }
  if (isEmulator()) return;
  if (!appCheckToken) throw new Error('missing App Check token');
  await admin.appCheck().verifyToken(appCheckToken);
}

function createRelay(options) {
  const opts = options || {};
  const metaUrl = opts.metaUrl || process.env.META_REALTIME_URL || META_REALTIME_URL;
  const verifyAuth = opts.verifyAuth || defaultVerifyAuth;
  const apiKey =
    opts.apiKey !== undefined ? opts.apiKey : process.env.META_API_KEY || '';
  const model =
    opts.model || process.env.META_TRANSCRIBE_MODEL || META_DEFAULT_MODEL;
  const authTimeoutMs = opts.authTimeoutMs || DEFAULT_AUTH_TIMEOUT_MS;

  const server = http.createServer((req, res) => {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
  });
  const wss = new WebSocketServer({ noServer: true });

  // Only GET /asr upgrades. `sessionId` query is logs-only.
  server.on('upgrade', (req, socket, head) => {
    let pathname = '';
    try {
      pathname = new URL(req.url || '/', 'http://localhost').pathname;
    } catch {
      pathname = '';
    }
    if (req.method !== 'GET' || pathname !== '/asr') {
      socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit('connection', ws, req);
    });
  });

  wss.on('connection', (client, req) => {
    let sessionId = '';
    try {
      sessionId =
        new URL(req.url || '/', 'http://localhost').searchParams.get(
          'sessionId',
        ) || '';
    } catch {
      sessionId = '';
    }
    log(sessionId, 'client connected');
    handleClient(client, {
      sessionId,
      metaUrl,
      verifyAuth,
      apiKey,
      model,
      authTimeoutMs,
    });
  });

  return server;
}

function handleClient(client, opts) {
  const { sessionId, metaUrl, verifyAuth, apiKey, model, authTimeoutMs } = opts;
  let authed = false;
  let ready = false;
  let ended = false;
  let finalSent = false;
  let latestText = '';
  let meta = null;
  let endTimer = null;

  const authTimer = setTimeout(() => {
    if (!authed) {
      log(sessionId, 'auth timeout; closing 4401');
      closeClient(4401, 'auth timeout');
    }
  }, authTimeoutMs);

  client.on('message', (data, isBinary) => {
    onClientMessage(data, !!isBinary).catch((err) => {
      log(sessionId, 'auth failed:', err && err.message ? err.message : String(err));
      closeClient(4401, 'unauthorized');
    });
  });
  client.on('close', () => {
    clearTimeout(authTimer);
    clearTimeout(endTimer);
    if (meta && meta.readyState === WebSocket.OPEN) {
      try {
        meta.close(1000);
      } catch {
        // Already closing; nothing to do.
      }
    }
  });
  client.on('error', () => {});

  async function onClientMessage(data, isBinary) {
    if (isBinary) {
      // Forwarded immediately, never accumulated. PCM arriving before the
      // Meta ack (`ready`) is discarded.
      if (ready && meta && meta.readyState === WebSocket.OPEN) {
        meta.send(data, { binary: true });
      }
      return;
    }
    const msg = parseJson(data);
    if (!authed) {
      if (!msg || msg.type !== 'auth') throw new Error('first frame must be auth');
      await verifyAuth(msg.idToken, msg.appCheckToken);
      authed = true;
      clearTimeout(authTimer);
      log(sessionId, 'authenticated; dialing Meta');
      openMeta();
      return;
    }
    if (msg && msg.type === 'end' && !ended) {
      ended = true;
      if (meta && meta.readyState === WebSocket.OPEN) {
        meta.send(JSON.stringify({ type: 'endStream' }));
        endTimer = setTimeout(onEndTimeout, END_FINAL_TIMEOUT_MS);
      } else {
        closeClient(1000);
      }
    }
    // Any other post-auth text frame is ignored.
  }

  function openMeta() {
    meta = new WebSocket(metaUrl);
    meta.on('open', () => {
      meta.send(buildHandshake(apiKey, model));
    });
    meta.on('message', (data, isBinary) => {
      if (isBinary) return;
      onMetaMessage(parseJson(data));
    });
    meta.on('error', (err) => {
      log(sessionId, 'meta error:', err && err.message ? err.message : String(err));
    });
    meta.on('close', onMetaClose);
  }

  function onMetaMessage(msg) {
    if (!msg) return;
    // Ack: the first frame carrying `sessionId` releases `ready`.
    if (!ready && typeof msg.sessionId === 'string' && msg.sessionId.length > 0) {
      ready = true;
      log(sessionId, 'meta ack; client ready');
      sendJson(client, { type: 'ready' });
      return;
    }
    if (
      msg.type === 'transcript' ||
      (msg.type === undefined && typeof msg.transcript === 'string')
    ) {
      latestText = messageText(msg);
      sendJson(client, { type: 'partial', text: latestText });
      return;
    }
    if (msg.type === 'speechStart' || msg.type === 'speechEnd') return;
    if (msg.type === 'speechComplete') {
      const text = messageText(msg) || latestText;
      latestText = text;
      finalSent = true;
      if (endTimer) {
        clearTimeout(endTimer);
        endTimer = null;
      }
      sendJson(client, { type: 'final', text });
      if (ended) closeBoth(1000);
      return;
    }
    if (msg.type === 'error' || typeof msg.error === 'string') {
      const message =
        typeof msg.message === 'string'
          ? msg.message
          : typeof msg.error === 'string'
            ? msg.error
            : 'transcription error';
      sendJson(client, { type: 'error', message });
    }
  }

  function onMetaClose(code) {
    meta = null;
    if (ended && finalSent) {
      closeClient(1000);
      return;
    }
    // Upstream internal error: deliver what we have as the final text, then
    // a clean close.
    if (code === 1011) {
      if (latestText && !finalSent) {
        finalSent = true;
        sendJson(client, { type: 'final', text: latestText });
      }
      closeClient(1000);
      return;
    }
    if (code !== 1000 && !ended && client.readyState === WebSocket.OPEN) {
      sendJson(client, { type: 'error', message: `upstream closed (${code})` });
    }
    closeClient(1000);
  }

  function onEndTimeout() {
    endTimer = null;
    if (!finalSent && latestText) {
      finalSent = true;
      sendJson(client, { type: 'final', text: latestText });
    }
    closeBoth(1000);
  }

  function closeBoth(code) {
    if (endTimer) {
      clearTimeout(endTimer);
      endTimer = null;
    }
    if (meta && meta.readyState === WebSocket.OPEN) {
      try {
        meta.close(code);
      } catch {
        // Already closing; nothing to do.
      }
    }
    closeClient(code);
  }

  function closeClient(code, reason) {
    if (client.readyState === WebSocket.OPEN) {
      try {
        client.close(code, reason);
      } catch {
        // Already closing; nothing to do.
      }
    }
  }
}

if (require.main === module) {
  const port = Number(process.env.PORT || '8080');
  const server = createRelay();
  server.listen(port, () => {
    console.log(
      `[asr-relay] listening on :${port}` +
        ` emulator=${isEmulator()} project=${projectId()}`,
    );
  });
}

module.exports = {
  createRelay,
  isEmulator,
  verifyRelayIdToken,
  verifyWithProductionCerts,
};
