'use strict';

// asr-relay tests (run with `node --test`). A fake Meta WS stands in for
// `wss://api.meta.ai/v1/asr/realtime`; auth is stubbed so no credentials are
// needed. These tests are NOT run by agents; the owner runs them.

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { WebSocketServer, WebSocket } = require('ws');
const {
  createRelay,
  verifyRelayIdToken,
  verifyWithProductionCerts,
} = require('./server');

const GOOD_TOKEN = 'good-token';

let fake;
let fakeUrl = '';
let upstreams = [];
let metaInbox = [];
let handshaken = new Set();
let autoAck = true;

let relay;
let relayWs = '';

function waitFor(predicate, timeoutMs = 5000) {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    (function poll() {
      let ok = false;
      try {
        ok = predicate();
      } catch {
        ok = false;
      }
      if (ok) return resolve();
      if (Date.now() - start > timeoutMs) {
        return reject(new Error('timed out waiting for condition'));
      }
      setTimeout(poll, 10);
    })();
  });
}

function onceOpen(ws) {
  return new Promise((resolve, reject) => {
    ws.on('open', resolve);
    ws.on('error', reject);
  });
}

function waitClose(ws) {
  return new Promise((resolve) => {
    ws.on('close', (code, reason) =>
      resolve({ code, reason: reason.toString() }),
    );
  });
}

// Collects inbound messages; next() resolves with the next one or rejects on
// timeout (used to assert that nothing arrives).
function track(ws) {
  const queue = [];
  const waiters = [];
  ws.on('message', (data, isBinary) => {
    const item = { data: Buffer.from(data), isBinary: !!isBinary };
    if (waiters.length) waiters.shift()(item);
    else queue.push(item);
  });
  return {
    next(timeoutMs = 5000) {
      if (queue.length) return Promise.resolve(queue.shift());
      return new Promise((resolve, reject) => {
        const waiter = (item) => {
          clearTimeout(t);
          resolve(item);
        };
        const t = setTimeout(() => {
          const i = waiters.indexOf(waiter);
          if (i >= 0) waiters.splice(i, 1);
          reject(new Error('timed out waiting for message'));
        }, timeoutMs);
        waiters.push(waiter);
      });
    },
  };
}

before(async () => {
  fake = new WebSocketServer({ port: 0 });
  fake.on('connection', (socket) => {
    upstreams.push(socket);
    socket.on('message', (data, isBinary) => {
      const buf = Buffer.from(data);
      metaInbox.push({ socket, data: buf, isBinary: !!isBinary });
      if (!isBinary && !handshaken.has(socket)) {
        let msg = null;
        try {
          msg = JSON.parse(buf.toString('utf8'));
        } catch {
          msg = null;
        }
        if (msg && msg.authorization) {
          handshaken.add(socket);
          if (autoAck) socket.send(JSON.stringify({ sessionId: 'meta-test-1' }));
        }
      }
    });
  });
  await new Promise((resolve) => fake.on('listening', resolve));
  fakeUrl = `ws://127.0.0.1:${fake.address().port}`;

  relay = createRelay({
    metaUrl: fakeUrl,
    verifyAuth: async (idToken) => {
      if (idToken !== GOOD_TOKEN) throw new Error('bad token');
    },
  });
  await new Promise((resolve) => relay.listen(0, '127.0.0.1', resolve));
  relayWs = `ws://127.0.0.1:${relay.address().port}`;
});

after(async () => {
  for (const s of upstreams) {
    try {
      s.close();
    } catch {
      // Already closed.
    }
  }
  await new Promise((resolve) => relay.close(resolve));
  await new Promise((resolve) => fake.close(resolve));
});

async function newReadyClient(tag) {
  const client = new WebSocket(`${relayWs}/asr?sessionId=${tag}`);
  const t = track(client);
  await onceOpen(client);
  client.send(JSON.stringify({ type: 'auth', idToken: GOOD_TOKEN }));
  const ready = await t.next();
  assert.deepEqual(JSON.parse(ready.data.toString('utf8')), { type: 'ready' });
  return { client, t, upstream: upstreams[upstreams.length - 1] };
}

test('rejects clients without a valid token with 4401 and never dials Meta', async () => {
  const seen = upstreams.length;
  const client = new WebSocket(`${relayWs}/asr?sessionId=t-4401`);
  await onceOpen(client);
  const closed = waitClose(client);
  client.send(JSON.stringify({ type: 'auth', idToken: 'wrong-token' }));
  const { code } = await closed;
  assert.equal(code, 4401);
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal(upstreams.length, seen);
});

test('sends ready only after the Meta ack and discards pre-ready PCM', async () => {
  autoAck = false;
  try {
    const seen = upstreams.length;
    const client = new WebSocket(`${relayWs}/asr?sessionId=t-ready`);
    const t = track(client);
    await onceOpen(client);
    client.send(JSON.stringify({ type: 'auth', idToken: GOOD_TOKEN }));
    await waitFor(() => upstreams.length > seen);
    const sock = upstreams[upstreams.length - 1];
    await waitFor(() =>
      metaInbox.some((m) => m.socket === sock && !m.isBinary),
    );

    // Handshake carries the exact contract fields.
    const hs = metaInbox.find((m) => m.socket === sock && !m.isBinary);
    const hsMsg = JSON.parse(hs.data.toString('utf8'));
    assert.equal(hsMsg.audioEncoding, 'PCM_24KHZ');
    assert.equal(hsMsg.model, 'muse-voice-transcribe-1.0');
    assert.equal(hsMsg.mode, 'PUSH_TO_TALK');
    assert.equal(hsMsg.partialMode, 'CUMULATIVE');
    assert.ok(
      hsMsg.authorization &&
        typeof hsMsg.authorization.accessToken === 'string' &&
        hsMsg.authorization.accessToken.startsWith('Bearer '),
    );

    // No ready before the ack.
    await assert.rejects(t.next(200), /timed out/);

    // PCM before ready never reaches Meta.
    client.send(Buffer.from([1, 2, 3, 4]));
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.ok(
      !metaInbox.some((m) => m.socket === sock && m.isBinary),
      'pre-ready PCM must not reach Meta',
    );

    sock.send(JSON.stringify({ sessionId: 'meta-ack-1' }));
    const ready = await t.next();
    assert.deepEqual(JSON.parse(ready.data.toString('utf8')), {
      type: 'ready',
    });
    client.close();
  } finally {
    autoAck = true;
  }
});

test('forwards binary PCM frames intact', async () => {
  const { client, upstream } = await newReadyClient('t-pcm');
  const pcm = Buffer.from([0, 127, 255, 16, 32, 48, 64, 80]);
  client.send(pcm);
  await waitFor(() =>
    metaInbox.some((m) => m.socket === upstream && m.isBinary),
  );
  const got = metaInbox.find((m) => m.socket === upstream && m.isBinary);
  assert.ok(got.data.equals(pcm));
  client.close();
});

test('reads the realtime URL, model and key from the runtime environment', async () => {
  const env = {
    META_REALTIME_URL: fakeUrl,
    META_TRANSCRIBE_MODEL: 'custom-asr-model',
    META_API_KEY: 'fake-relay-key',
  };
  const before = Object.fromEntries(
    Object.keys(env).map((key) => [key, process.env[key]]),
  );
  let envRelay;
  let client;
  try {
    Object.assign(process.env, env);
    envRelay = createRelay({ verifyAuth: async () => {} });
    await new Promise((resolve) => envRelay.listen(0, '127.0.0.1', resolve));
    client = new WebSocket(`ws://127.0.0.1:${envRelay.address().port}/asr`);
    const messages = track(client);
    await onceOpen(client);
    client.send(JSON.stringify({ type: 'auth', idToken: GOOD_TOKEN }));
    const ready = await messages.next();
    assert.equal(JSON.parse(ready.data.toString()).type, 'ready');
    const upstream = upstreams[upstreams.length - 1];
    const handshake = metaInbox.find((m) => m.socket === upstream && !m.isBinary);
    const body = JSON.parse(handshake.data.toString());
    assert.equal(body.model, 'custom-asr-model');
    assert.equal(body.authorization.accessToken, 'Bearer fake-relay-key');
  } finally {
    if (client) {
      const closed = waitClose(client);
      client.close();
      await closed;
    }
    if (envRelay) await new Promise((resolve) => envRelay.close(resolve));
    for (const [key, value] of Object.entries(before)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});

test('maps Meta transcript frames to partial', async () => {
  const { client, t, upstream } = await newReadyClient('t-partial');
  upstream.send(JSON.stringify({ type: 'transcript', transcript: 'hola mundo' }));
  const msg = await t.next();
  assert.deepEqual(JSON.parse(msg.data.toString('utf8')), {
    type: 'partial',
    text: 'hola mundo',
  });
  client.close();
});

test('maps Meta speechComplete to final', async () => {
  const { client, t, upstream } = await newReadyClient('t-final');
  upstream.send(
    JSON.stringify({ type: 'speechComplete', transcript: 'hola mundo completo' }),
  );
  const msg = await t.next();
  assert.deepEqual(JSON.parse(msg.data.toString('utf8')), {
    type: 'final',
    text: 'hola mundo completo',
  });
  client.close();
});

test('client end sends endStream, then final, then closes both cleanly', async () => {
  const { client, t, upstream } = await newReadyClient('t-end');
  const upstreamClosed = waitClose(upstream);
  const clientClosed = waitClose(client);
  client.send(JSON.stringify({ type: 'end' }));
  await waitFor(() =>
    metaInbox.some(
      (m) =>
        m.socket === upstream &&
        !m.isBinary &&
        m.data.toString('utf8') === JSON.stringify({ type: 'endStream' }),
    ),
  );
  upstream.send(
    JSON.stringify({ type: 'speechComplete', transcript: 'texto final' }),
  );
  const msg = await t.next();
  assert.deepEqual(JSON.parse(msg.data.toString('utf8')), {
    type: 'final',
    text: 'texto final',
  });
  const [uc, cc] = await Promise.all([upstreamClosed, clientClosed]);
  assert.equal(uc.code, 1000);
  assert.equal(cc.code, 1000);
});

function fakeJwt(alg) {
  const header = Buffer.from(JSON.stringify({ alg })).toString('base64url');
  const payload = Buffer.from(JSON.stringify({ sub: 'u' })).toString(
    'base64url',
  );
  const sig = alg === 'none' ? '' : 'sig';
  return `${header}.${payload}.${sig}`;
}

test('local auth accepts emulator and production tokens', async () => {
  const prev = process.env.FIREBASE_AUTH_EMULATOR_HOST;
  const none = fakeJwt('none');
  const rs = fakeJwt('RS256');
  try {
    delete process.env.FIREBASE_AUTH_EMULATOR_HOST;
    const prodOnly = [];
    await verifyRelayIdToken(rs, {
      verifyEmulator: async () => {
        prodOnly.push('emu');
      },
      verifyProduction: async () => {
        prodOnly.push('prod');
      },
    });
    assert.deepEqual(prodOnly, ['prod']);

    process.env.FIREBASE_AUTH_EMULATOR_HOST = '127.0.0.1:9099';
    const emuOnly = [];
    await verifyRelayIdToken(none, {
      verifyEmulator: async () => {
        emuOnly.push('emu');
      },
      verifyProduction: async () => {
        emuOnly.push('prod');
      },
    });
    assert.deepEqual(emuOnly, ['emu']);

    const skipped = [];
    await assert.rejects(
      () =>
        verifyRelayIdToken(none, {
          verifyEmulator: async () => {
            throw new Error('user disabled');
          },
          verifyProduction: async () => {
            skipped.push('prod');
          },
        }),
      /user disabled/,
    );
    assert.deepEqual(skipped, []);

    const fellBack = [];
    await verifyRelayIdToken(rs, {
      verifyEmulator: async () => {
        throw new Error('Firebase ID token has invalid signature.');
      },
      verifyProduction: async (token) => {
        fellBack.push(token);
      },
    });
    assert.deepEqual(fellBack, [rs]);

    let seenHost = 'unset';
    const admin = {
      auth() {
        return {
          verifyIdToken() {
            seenHost = process.env.FIREBASE_AUTH_EMULATOR_HOST || '';
            return Promise.reject(new Error('rejected'));
          },
        };
      },
    };
    await assert.rejects(
      () => verifyWithProductionCerts(admin, rs),
      /rejected/,
    );
    assert.equal(seenHost, '');
    assert.equal(process.env.FIREBASE_AUTH_EMULATOR_HOST, '127.0.0.1:9099');
  } finally {
    if (prev === undefined) delete process.env.FIREBASE_AUTH_EMULATOR_HOST;
    else process.env.FIREBASE_AUTH_EMULATOR_HOST = prev;
  }
});
