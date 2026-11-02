// Build test/browser/media_harness.dart and serve it. No generation providers.
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const url = process.env.RAMIFICA_BROWSER_URL || 'http://127.0.0.1:8383';
(async () => {
  const browser = await chromium.launch({channel: 'chrome', headless: true});
  try {
    const page = await browser.newPage({viewport: {width: 430, height: 932}});
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    await page.addInitScript(() => {
      window.__ramificaTestMedia = [];
      const create = Document.prototype.createElement;
      Document.prototype.createElement = function (tag, ...args) {
        const element = create.call(this, tag, ...args);
        if (tag.toLowerCase() === 'video') window.__ramificaTestMedia.push(element);
        return element;
      };
    });
    await page.goto(url);
    await page.waitForFunction(() => typeof window.ramificaTestBounds === 'function' && window.ramificaTestBounds('wizard-step-3') !== 'null');
    // Flutter's test-only bridge reports actual RenderBox bounds, not the
    // native accessibility thumb proxy. All actions below are real pointer input.
    async function bounds(key) { return page.evaluate(key => JSON.parse(window.ramificaTestBounds(key)), key); }
    async function tap(key) {
      await page.waitForFunction(key => { const r=JSON.parse(window.ramificaTestBounds(key)); return r && r.enabled !== false && r.height > 0; }, key);
      const r = await bounds(key); await page.mouse.click(r.x + r.width / 2, r.y + r.height / 2);
    }
    async function seek(key, fraction, from) {
      const r = await bounds(key);
      await page.mouse.move(r.x + 24 + (r.width - 48) * from, r.y + r.height / 2);
      await page.mouse.down();
      await page.mouse.move(r.x + 24 + (r.width - 48) * fraction, r.y + r.height / 2, {steps: 12});
      await page.mouse.up();
      console.log('SEEK DEBUG', key, r, from, fraction, await page.evaluate(() => window.__ramificaTestMedia.map(v => ({src:v.src,position:v.currentTime,paused:v.paused}))));
      await page.screenshot({path:'/tmp/ramifica-after-seek.png'});
    }
    await tap('wizard-step-3');
    await page.waitForFunction(() => window.__ramificaTestMedia.some(v => /voice\.m4a/.test(v.src) && v.readyState >= 2));
    await tap('voice-play-root');
    await page.waitForFunction(() => window.__ramificaTestMedia.some(v => /voice\.m4a/.test(v.src) && v.currentTime > .3));
    await tap('voice-play-root');
    const pos = await page.evaluate(() => window.__ramificaTestMedia.find(v => /voice\.m4a/.test(v.src)).currentTime);
    assert(pos > .25);
    await seek('voice-seek-root', .65, pos / 3);
    await page.waitForFunction(() => window.__ramificaTestMedia.some(v => /voice\.m4a/.test(v.src) && v.currentTime > 1), {}, {timeout: 3000});
    await tap('voice-play-root');
    await page.waitForFunction(() => window.__ramificaTestMedia.some(v => /voice\.m4a/.test(v.src) && v.ended));
    await tap('voice-play-root');
    await page.waitForFunction(() => window.__ramificaTestMedia.some(v => /voice\.m4a/.test(v.src) && !v.paused && v.currentTime < 1));
    await page.screenshot({path: '/tmp/ramifica-p4-audio.png'});
    await tap('wizard-step-4');
    assert(await page.evaluate(() => window.__ramificaTestMedia.filter(v => /voice\.m4a/.test(v.src)).every(v => v.paused)));
    await page.waitForFunction(() => window.__ramificaTestMedia.some(v => /clip\.mp4/.test(v.src) && v.readyState >= 2));
    await tap('video-play');
    await page.waitForFunction(() => window.__ramificaTestMedia.some(v => /clip\.mp4/.test(v.src) && v.currentTime > .3));
    const original = await page.evaluate(() => {
      const v = window.__ramificaTestMedia.find(v => /clip\.mp4/.test(v.src));
      return {width: v.videoWidth, height: v.videoHeight, duration: v.duration, error: v.error};
    });
    assert.equal(original.width, 480); assert.equal(original.height, 854);
    assert(Math.abs(original.duration - 10) < 1/30); assert.equal(original.error, null);
    await tap('video-play');
    const videoPos = await page.evaluate(() => window.__ramificaTestMedia.find(v => /clip\.mp4/.test(v.src)).currentTime);
    await seek('video-seek', .65, videoPos / 10);
    await page.waitForFunction(() => window.__ramificaTestMedia.some(v => /clip\.mp4/.test(v.src) && v.currentTime > 4));
    await tap('video-mute');
    assert(await page.evaluate(() => window.__ramificaTestMedia.find(v => /clip\.mp4/.test(v.src)).volume === 0));
    await tap('gen-video-root');
    await page.waitForFunction(() => window.ramificaTestText('Generating video…'), {}, {timeout: 600});
    assert(await page.evaluate(() => window.__ramificaTestMedia.some(v => /clip\.mp4/.test(v.src))));
    await page.waitForFunction(() => window.ramificaTestText('Processing video…'));
    await page.waitForFunction(() => window.__ramificaTestMedia.some(v => /clip2\.mp4/.test(v.src) && v.readyState >= 2));
    await tap('video-play');
    await page.waitForFunction(() => window.__ramificaTestMedia.some(v => /clip2\.mp4/.test(v.src) && !v.paused));
    await page.screenshot({path: '/tmp/ramifica-p5-video.png'});
    await tap('preview-node-root');
    assert(await page.evaluate(() => window.__ramificaTestMedia.filter(v => /clip2\.mp4/.test(v.src)).every(v => v.paused)));
    await tap('close-preview');
    await tap('wizard-step-3');
    assert(await page.evaluate(() => window.__ramificaTestMedia.filter(v => /clip2\.mp4/.test(v.src)).every(v => v.paused)));
    // Cross-origin Storage URLs must permit browser reads with correct MIME.
    const mediaHeaders = await page.evaluate(async () => Promise.all(window.__ramificaTestMedia
      .filter(v => v.src && /\.(mp4|m4a)/.test(v.src)).slice(0, 2).map(async v => {
        const response = await fetch(v.src, {method: 'HEAD'});
        return {ok: response.ok, type: response.headers.get('content-type')};
      })));
    assert(mediaHeaders.every(r => r.ok && ['audio/mp4', 'video/mp4'].includes(r.type)));
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({passed: true, audio: 'play/pause/physical slider drag/end/restart; pauses leaving P4',
      video: '480x854/10s; play/pause/physical slider drag/mute/new URL/preview',
      generation: 'immediate local loading, processing, previous take retained', mediaHeaders}, null, 2));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
