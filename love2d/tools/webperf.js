// Browser-side profile of the single-file build. Absolute times under
// SwiftShader are meaningless, but these are not:
//   * bytes on the wire and time to the click gate (a phone downloads this)
//   * time from the click to the first real rendered frame (boot cost)
//   * WebGL draw calls, uniform uploads and texture binds *per frame* -- the
//     numbers that decide whether a real phone GPU driver keeps up
//   * relative frame cost between two builds of the same scene
//
// Usage:
//   NODE_PATH=/home/user/.toolchain/node_modules \
//   node tools/webperf.js <html> [ms] [W] [H] [dev-flags]
// env: MOBILE=1 (iPhone UA + DPR3 + touch), OUT=shot.png
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

(async () => {
  const [, , html, msRaw, W = '1280', H = '720', dev = ''] = process.argv;
  const ms = +(msRaw || 20000);
  const mobile = !!process.env.MOBILE;
  const browser = await chromium.launch({
    executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome',
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
      '--ignore-gpu-blocklist', '--enable-webgl', '--no-sandbox'],
  });
  const page = await browser.newPage({
    viewport: { width: +W, height: +H },
    deviceScaleFactor: mobile ? 3 : 1,
    hasTouch: mobile, isMobile: mobile,
    userAgent: mobile
      ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
      + '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1' : undefined,
  });

  // Count GL work per animation frame, from before any of the page's own code runs.
  await page.addInitScript(() => {
    window.__perf = { frames: [], t0: performance.now(), gl: { d: 0, u: 0, t: 0, p: 0 } };
    const g = window.__perf.gl;
    const patch = (proto) => {
      if (!proto) return;
      for (const n of ['drawElements', 'drawArrays']) {
        const o = proto[n]; if (!o) continue;
        proto[n] = function (...a) { g.d++; return o.apply(this, a); };
      }
      for (const n of Object.getOwnPropertyNames(proto)) {
        if (/^uniform/.test(n)) {
          const o = proto[n];
          if (typeof o === 'function') proto[n] = function (...a) { g.u++; return o.apply(this, a); };
        }
      }
      for (const n of ['bindTexture', 'useProgram', 'bindFramebuffer']) {
        const o = proto[n]; if (!o) continue;
        proto[n] = function (...a) { if (n === 'bindTexture') g.t++; else g.p++; return o.apply(this, a); };
      }
    };
    patch(window.WebGLRenderingContext && WebGLRenderingContext.prototype);
    patch(window.WebGL2RenderingContext && WebGL2RenderingContext.prototype);
    const raf = window.requestAnimationFrame.bind(window);
    window.requestAnimationFrame = (cb) => raf((t) => {
      const s = performance.now();
      const d0 = g.d, u0 = g.u, t0 = g.t, p0 = g.p;
      try { return cb(t); } finally {
        window.__perf.frames.push([s, performance.now() - s,
          g.d - d0, g.u - u0, g.t - t0, g.p - p0]);
      }
    });
  });

  const logs = [];
  page.on('console', m => logs.push(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', e => logs.push(`[pageerror] ${e.message}`));

  // Accepts a path or an http(s) URL. The hosted build must be measured over
  // HTTP: emscripten refuses its instantiateStreaming path for a file:// URI,
  // so a file:// run of a multi-file build under-reports it.
  const isURL = /^https?:\/\//.test(html);
  const url = (isURL ? html : 'file://' + path.resolve(html)) + (dev ? '?dev=' + dev : '');
  // The webfont stylesheet is a third-party request this page deliberately no
  // longer blocks on (see web_shell.html). Waiting for 'load' here would put
  // that wait back inside every number below -- on a machine with no route to
  // fonts.googleapis.com it reads as a 13 s boot that is not happening.
  // 'commit' starts the clock when the document does.
  const tNav = Date.now();
  await page.goto(url, { waitUntil: 'commit' });
  await page.waitForSelector('#start', { state: 'visible', timeout: 180000 });
  const tGate = Date.now() - tNav;
  const clickAt = await page.evaluate(() => performance.now());
  await page.evaluate(() => document.getElementById('start').click());
  await page.waitForTimeout(ms);

  const r = await page.evaluate((clickAt) => {
    const f = window.__perf.frames;
    // a "real" frame is one that issued a meaningful number of draw calls
    let first = null;
    for (const x of f) if (x[0] > clickAt && x[2] > 300) { first = x; break; }
    const tail = f.filter(x => x[0] > clickAt).slice(-90);
    const med = (a) => { const s = [...a].sort((x, y) => x - y); return s.length ? s[Math.floor(s.length / 2)] : 0; };
    const gaps = [];
    for (let i = 1; i < tail.length; i++) gaps.push(tail[i][0] - tail[i - 1][0]);
    return {
      totalFrames: f.length,
      firstFrameMs: first ? first[0] - clickAt : null,
      msNavToFirstFrame: first ? Math.round(first[0]) : null,
      msNavToClick: Math.round(clickAt),
      cbMedMs: med(tail.map(x => x[1])),
      gapMedMs: med(gaps),
      drawCalls: med(tail.map(x => x[2])),
      uniformCalls: med(tail.map(x => x[3])),
      texBinds: med(tail.map(x => x[4])),
      progFbo: med(tail.map(x => x[5])),
      heapMB: performance.memory ? +(performance.memory.usedJSHeapSize / 1048576).toFixed(1) : null,
      canvas: (() => { const c = document.querySelector('canvas'); return c ? [c.width, c.height] : null; })(),
      // The first frames after the click: LOVE's love.load (audio synthesis and
      // the terrain bake) runs inside the first main-loop tick, so it shows up
      // as one very long callback before any drawing happens.
      firstTicks: f.filter(x => x[0] > clickAt).slice(0, 6)
        .map(x => ({ atMs: Math.round(x[0] - clickAt), ms: Math.round(x[1]), draws: x[2] })),
    };
  }, clickAt);

  if (process.env.OUT) await page.screenshot({ path: process.env.OUT });
  const size = isURL ? 0 : fs.statSync(path.resolve(html)).size;
  console.log('WEBPERF ' + JSON.stringify({
    file: path.basename(html), bytes: size, mb: +(size / 1048576).toFixed(2),
    msToClickGate: tGate, viewport: [+W, +H], mobile, dev, ...r,
  }, null, 0));
  const errs = logs.filter(l => /pageerror|error/i.test(l));
  if (errs.length) console.log(errs.slice(-10).join('\n'));
  await browser.close();
})();
