// Run with: node test/browser/media_cache_browser_test.mjs
// Requires Chrome and ffmpeg. Uses temporary local servers and a fresh profile.
// Set RAMIFICA_WORKBOX_DIR to a local Workbox 7.3.0 distribution to also test
// the release worker, without requiring the browser to reach the CDN.
import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const chromePath = process.env.CHROME_EXECUTABLE ||
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const temporary = await mkdtemp(join(tmpdir(), 'ramifica-media-test-'));
const requests = [];
const appRequests = [];
const unavailable = new Set();
let chrome;
let app;
let media;

async function listen(server) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return `http://127.0.0.1:${server.address().port}`;
}

try {
  const clipPath = join(temporary, 'clip.mp4');
  execFileSync('ffmpeg', [
    '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
    'color=c=black:s=32x32:r=10:d=1', '-c:v', 'libx264', '-pix_fmt',
    'yuv420p', '-movflags', '+faststart', '-y', clipPath,
  ]);
  const clip = await readFile(clipPath);
  const png = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    'base64',
  );
  const voice = Buffer.from('the narrated audio content');
  const sw = await readFile(resolve('web/sw.js'));
  const mediaWorker = await readFile(resolve('web/media_cache.js'));
  const workboxDirectory = process.env.RAMIFICA_WORKBOX_DIR;
  const workboxFiles = new Map();
  if (workboxDirectory) {
    for (const name of ['workbox-sw.js', 'workbox-core.prod.js',
      'workbox-precaching.prod.js', 'workbox-routing.prod.js',
      'workbox-strategies.prod.js']) {
      workboxFiles.set(name, await readFile(join(workboxDirectory, name)));
    }
  }
  const releaseWorker = sw.toString()
    .replace('https://storage.googleapis.com/workbox-cdn/releases/7.3.0/workbox-sw.js',
      '/test-workbox/workbox-sw.js')
    .replace('  } catch (error) {',
      '    self.workbox.setConfig({modulePathPrefix: "/test-workbox/", debug: false});\n  } catch (error) {');

  media = createServer((req, res) => {
    const url = new URL(req.url, 'http://media');
    const record = { path: url.pathname, range: req.headers.range || null };
    requests.push(record);
    if (!url.pathname.startsWith('/nocors')) {
      res.setHeader('Access-Control-Allow-Origin', '*');
      res.setHeader('Access-Control-Expose-Headers',
        'Content-Range,Content-Length,Content-Type,Accept-Ranges,ETag');
    }
    res.setHeader('Cache-Control', url.pathname === '/private.png'
      ? 'no-store' : 'max-age=0, must-revalidate');
    if (unavailable.has(url.pathname)) {
      res.writeHead(503).end('unavailable');
      return;
    }
    const isVideo = url.pathname.endsWith('.mp4');
    const isAudio = url.pathname.endsWith('.m4a');
    const bytes = url.pathname === '/slow.mp4'
      ? Buffer.alloc(1024 * 1024, 37)
      : (isVideo ? clip : (isAudio ? voice : png));
    res.setHeader('Content-Type', isVideo ? 'video/mp4' :
      (isAudio ? 'audio/mp4' : 'image/png'));
    res.setHeader('Accept-Ranges', 'bytes');
    const match = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || '');
    let start = 0;
    let end = bytes.length - 1;
    if (match) {
      start = Number(match[1]);
      if (match[2]) end = Math.min(Number(match[2]), end);
      res.setHeader('Content-Range', `bytes ${start}-${end}/${bytes.length}`);
      res.statusCode = 206;
    }
    res.setHeader('Content-Length', end - start + 1);
    if (url.pathname === '/slow.mp4') {
      record.sent = 0;
      const timer = setInterval(() => {
        if (start > end) {
          clearInterval(timer);
          res.end();
          return;
        }
        const next = Math.min(start + 4096, end + 1);
        res.write(bytes.subarray(start, next));
        record.sent += next - start;
        start = next;
      }, 20);
      res.on('close', () => clearInterval(timer));
      return;
    }
    res.end(bytes.subarray(start, end + 1));
  });
  const mediaOrigin = await listen(media);

  app = createServer((req, res) => {
    const url = new URL(req.url, 'http://app');
    appRequests.push(url.pathname);
    if (url.pathname.startsWith('/test-workbox/')) {
      const script = workboxFiles.get(url.pathname.split('/').pop());
      res.writeHead(script ? 200 : 404, { 'Content-Type': 'application/javascript' });
      res.end(script);
    } else if (url.pathname === '/sw.js' || url.pathname === '/media_cache.js') {
      res.writeHead(200, { 'Content-Type': 'application/javascript' });
      res.end(url.pathname === '/sw.js'
        ? (url.searchParams.has('v') && workboxDirectory ? releaseWorker : sw)
        : mediaWorker);
    } else if (url.pathname === '/disable') {
      unavailable.add(url.searchParams.get('path'));
      res.writeHead(204).end();
    } else {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end('<!doctype html><title>Media cache test</title>');
    }
  });
  const appOrigin = await listen(app);

  chrome = spawn(chromePath, [
    '--headless=new', '--no-sandbox', '--disable-gpu', '--no-first-run',
    '--no-default-browser-check', '--remote-debugging-port=0',
    `--user-data-dir=${join(temporary, 'chrome')}`, 'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  let log = '';
  const wsUrl = await Promise.race([
    new Promise((resolveUrl, reject) => {
      chrome.stderr.on('data', (chunk) => {
        log += chunk.toString();
        const match = /DevTools listening on (ws:\/\/\S+)/.exec(log);
        if (match) resolveUrl(match[1]);
      });
      chrome.once('exit', () => reject(new Error(`Chrome exited: ${log}`)));
    }),
    new Promise((_, reject) => setTimeout(() => reject(new Error(log)), 10000)),
  ]);
  const socket = new WebSocket(wsUrl);
  await once(socket, 'open');
  const pending = new Map();
  const events = new EventEmitter();
  let nextId = 0;
  socket.addEventListener('message', ({ data }) => {
    const message = JSON.parse(data);
    if (message.id && pending.has(message.id)) {
      const { resolve: ok, reject } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(message.error.message));
      else ok(message.result);
    } else if (message.method) {
      events.emit(message.method, message.params);
    }
  });
  function send(method, params = {}, sessionId) {
    const id = ++nextId;
    return new Promise((ok, reject) => {
      pending.set(id, { resolve: ok, reject });
      socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  await send('Page.enable', {}, sessionId);
  const loaded = once(events, 'Page.loadEventFired');
  await send('Page.navigate', { url: appOrigin }, sessionId);
  await loaded;

  const program = `(async () => {
    const origin = ${JSON.stringify(mediaOrigin)};
    const length = ${clip.length};
    const check = (value, message) => { if (!value) throw new Error(message); };
    const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
    const cacheHas = async (type, url) =>
      !!(await (await caches.open('ramifica-' + type + '-v2')).match(url));
    async function waitForCache(type, url) {
      for (let i = 0; i < 150; i++) {
        if (await cacheHas(type, url)) return;
        await delay(20);
      }
      throw new Error('Cache did not fill: ' + url);
    }
    async function disable(path) {
      await fetch('/disable?path=' + encodeURIComponent(path));
    }
    async function loadVideo(url) {
      const video = document.createElement('video');
      video.muted = true;
      video.preload = 'auto';
      document.body.append(video);
      const ready = new Promise((resolve, reject) => {
        video.addEventListener('canplaythrough', resolve, { once: true });
        video.addEventListener('error', () => reject(new Error('video error: ' + url)), { once: true });
        setTimeout(() => reject(new Error('video timeout: ' + url)), 5000);
      });
      video.src = url;
      video.load();
      await ready;
      return video;
    }
    await navigator.serviceWorker.register('/sw.js?media-only=1');
    await navigator.serviceWorker.ready;
    if (!navigator.serviceWorker.controller) {
      await new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange', resolve, { once: true }));
    }
    const image = origin + '/cover.png?signature=one';
    const imageBytes = await (await fetch(image)).arrayBuffer();
    await waitForCache('images', image);
    await disable('/cover.png');
    check((await fetch(image)).status === 200, 'cached image unavailable');
    check((await fetch(origin + '/cover.png?signature=two')).status === 503,
      'different signed URLs must have different cache keys');
    check(imageBytes.byteLength > 0, 'image body missing');

    const avatar = origin + '/avatar';
    await (await fetch(avatar)).arrayBuffer();
    await waitForCache('images', avatar);
    await disable('/avatar');
    check((await fetch(avatar)).status === 200, 'extensionless image not cached');

    const privateImage = origin + '/private.png';
    await (await fetch(privateImage)).arrayBuffer();
    await delay(100);
    check(!(await cacheHas('images', privateImage)), 'no-store response cached');

    const audio = origin + '/voice.m4a';
    check(await (await fetch(audio)).text() === 'the narrated audio content', 'audio body');
    await waitForCache('audio', audio);
    await disable('/voice.m4a');
    check(await (await fetch(audio)).text() === 'the narrated audio content', 'audio cache');

    const video = origin + '/fragments.mp4';
    const middle = Math.floor(length / 2);
    let response = await fetch(video, { headers: { Range: 'bytes=0-' + (middle - 1) } });
    const firstPart = new Uint8Array(await response.arrayBuffer());
    check(response.status === 206 && firstPart.byteLength === middle, 'first range failed');
    await delay(150);
    check(!(await cacheHas('video', video)), 'incomplete video was cached as complete');
    response = await fetch(video, { headers: { Range: 'bytes=' + middle + '-' } });
    const secondPart = new Uint8Array(await response.arrayBuffer());
    check(response.status === 206 && secondPart.byteLength === length - middle, 'second range failed');
    await waitForCache('video', video);
    await disable('/fragments.mp4');
    response = await fetch(video, { headers: { Range: 'bytes=10-29' } });
    check(response.status === 206 && response.headers.get('Content-Range') === 'bytes 10-29/' + length,
      'cached video range headers');
    const slice = new Uint8Array(await response.arrayBuffer());
    check(slice.length === 20 && slice.every((byte, i) => byte === firstPart[i + 10]),
      'cached video range body');
    const full = new Uint8Array(await (await fetch(video)).arrayBuffer());
    check(full.length === length && firstPart.every((byte, i) => full[i] === byte) &&
      secondPart.every((byte, i) => full[middle + i] === byte), 'cached video full body');
    await (await caches.open('ramifica-media-metadata-v2')).put(video, new Response('1'));
    response = await fetch(video, { headers: { Range: 'bytes=10-29' } });
    check(response.status === 206 && (await response.arrayBuffer()).byteLength === 20,
      'stale video should remain available if the server fails');

    const concurrent = origin + '/concurrent.mp4';
    const oneThird = Math.floor(length / 3);
    async function downloadRanges() {
      const spans = [
        'bytes=' + (oneThird * 2) + '-',
        'bytes=0-' + (oneThird - 1),
        'bytes=' + oneThird + '-' + (oneThird * 2 - 1),
      ];
      await Promise.all(spans.map(async range => {
        const part = await fetch(concurrent, { headers: { Range: range } });
        check(part.status === 206, 'concurrent range failed');
        await part.arrayBuffer();
      }));
      await waitForCache('video', concurrent);
    }
    await downloadRanges();
    await (await caches.open('ramifica-video-v2')).delete(concurrent);
    await downloadRanges();

    const slow = origin + '/slow.mp4';
    response = await fetch(slow, { headers: { Range: 'bytes=0-' } });
    const reader = response.body.getReader();
    await reader.read();
    await reader.cancel();
    await delay(300);
    check(!(await cacheHas('video', slow)), 'cancelled video was cached as complete');

    const player = origin + '/player.mp4';
    const first = await loadVideo(player);
    await waitForCache('video', player);
    first.remove();
    await disable('/player.mp4');
    const second = await loadVideo(player);
    second.remove();

    const fallback = await loadVideo(origin + '/nocors.mp4');
    fallback.remove();
    return 'images, audio, fragments, concurrency, cancellation, playback, CORS fallback';
  })()`;
  const result = await send('Runtime.evaluate', {
    expression: program, awaitPromise: true, returnByValue: true,
  }, sessionId);
  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.exception?.description ||
      result.exceptionDetails.text);
  }
  assert.equal(result.result.value,
    'images, audio, fragments, concurrency, cancellation, playback, CORS fallback');
  const ranges = requests.filter(({ path }) => path === '/fragments.mp4');
  // The one extra ranged request checks fallback when the server is unavailable.
  assert.equal(ranges.length, 3, JSON.stringify(ranges));
  assert.ok(ranges.every(({ range }) => range), JSON.stringify(ranges));
  const concurrent = requests.filter(({ path }) => path === '/concurrent.mp4');
  assert.equal(concurrent.length, 6, JSON.stringify(concurrent));
  assert.ok(concurrent.every(({ range }) => range), JSON.stringify(concurrent));
  const slow = requests.filter(({ path }) => path === '/slow.mp4');
  assert.equal(slow.length, 1, JSON.stringify(slow));
  assert.ok(slow[0].sent < 512 * 1024, JSON.stringify(slow));
  console.log('Chrome media cache integration passed:', result.result.value);

  if (workboxDirectory) {
    // Install in a narrower scope with no controlled clients. Production reloads
    // its clients on activation, so navigate into the scope only afterwards.
    const installed = await send('Runtime.evaluate', {
      expression: `(async () => {
        const registration = await navigator.serviceWorker.register(
          '/sw.js?v=release-test', {scope: '/release/'});
        const worker = registration.installing || registration.waiting || registration.active;
        if (!worker) throw new Error('No release worker');
        if (worker.state === 'activated') return true;
        return new Promise((resolve, reject) => {
          worker.addEventListener('statechange', () => {
            if (worker.state === 'activated') resolve(true);
            if (worker.state === 'redundant') reject(new Error('Release worker became redundant'));
          });
          setTimeout(() => reject(new Error('Release worker activation timed out')), 8000);
        });
      })()`,
      awaitPromise: true,
      returnByValue: true,
    }, sessionId);
    if (installed.exceptionDetails) {
      throw new Error((installed.exceptionDetails.exception?.description || installed.exceptionDetails.text) +
        ' requests=' + JSON.stringify(appRequests.filter(path => path.includes('workbox') || path === '/sw.js')));
    }
    const reloaded = once(events, 'Page.loadEventFired');
    await send('Page.navigate', { url: appOrigin + '/release/' }, sessionId);
    await reloaded;
    const release = await send('Runtime.evaluate', {
      expression: `(async () => {
        const controller = navigator.serviceWorker.controller;
        if (!controller || !controller.scriptURL.includes('v=release-test')) {
          throw new Error('Release worker is not controlling the page');
        }
        const url = ${JSON.stringify(mediaOrigin)} + '/release.mp4';
        const middle = Math.floor(${clip.length} / 2);
        for (const range of ['bytes=0-' + (middle - 1), 'bytes=' + middle + '-']) {
          const response = await fetch(url, { headers: { Range: range } });
          if (response.status !== 206) throw new Error('Release worker range failed');
          await response.arrayBuffer();
        }
        const cache = await caches.open('ramifica-video-v2');
        for (let i = 0; i < 150; i++) {
          if (await cache.match(url)) return (await caches.keys()).some(key => key.includes('workbox-precache'));
          await new Promise(resolve => setTimeout(resolve, 20));
        }
        throw new Error('Release worker did not cache the completed video');
      })()`,
      awaitPromise: true,
      returnByValue: true,
    }, sessionId);
    if (release.exceptionDetails) {
      throw new Error(release.exceptionDetails.exception?.description || release.exceptionDetails.text);
    }
    const releaseRanges = requests.filter(({ path }) => path === '/release.mp4');
    assert.equal(releaseRanges.length, 2, JSON.stringify(releaseRanges));
    assert.ok(releaseRanges.every(({ range }) => range), JSON.stringify(releaseRanges));
    assert.equal(release.result.value, true, 'Workbox shell was not precached');
    console.log('Chrome release worker passed with the Workbox shell');
  }
  socket.close();
} finally {
  if (chrome && chrome.exitCode === null) {
    const exited = once(chrome, 'exit');
    chrome.kill();
    await exited;
  }
  if (app) await new Promise((resolveClose) => app.close(resolveClose));
  if (media) await new Promise((resolveClose) => media.close(resolveClose));
  await rm(temporary, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
}
