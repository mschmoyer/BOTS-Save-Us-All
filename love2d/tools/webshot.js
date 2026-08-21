// Loads a single-file HTML build in headless Chromium and screenshots it.
// Usage: node webshot.js <html> <outPng> [waitMs] [w] [h]
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const [,, html, out, waitMs = '9000', W = '1280', H = '720'] = process.argv;
  const browser = await chromium.launch({
    executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome',
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
           '--ignore-gpu-blocklist', '--enable-webgl', '--no-sandbox']
  });
  const mobile = !!process.env.MOBILE;
  const page = await browser.newPage({
    viewport: { width: +W, height: +H },
    deviceScaleFactor: mobile ? 3 : 1,
    hasTouch: mobile,
    isMobile: mobile,
    userAgent: mobile
      ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
        + '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
      : undefined,
  });
  const logs = [];
  page.on('console', m => logs.push(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', e => logs.push(`[pageerror] ${e.message}`));
  await page.goto('file://' + path.resolve(html));
  // dismiss the click gate, then let the game run
  try {
    await page.waitForSelector('#start', { state: 'visible', timeout: 90000 });
    if (process.env.NOCLICK) {
      await page.waitForTimeout(600);
      await page.screenshot({ path: out.replace(/\.png$/, '_loader.png') });
    }
    if (!process.env.NOCLICK) await page.click('#start');
  } catch (e) { logs.push('[warn] start button never appeared: ' + e.message); }
  await page.waitForTimeout(+waitMs);
  // let keys be scripted from the command line: KEYS="w:2000,e:200"
  if (process.env.KEYS) {
    for (const part of process.env.KEYS.split(',')) {
      const [k, ms] = part.split(':');
      await page.keyboard.down(k);
      await page.waitForTimeout(+(ms || 300));
      await page.keyboard.up(k);
    }
  }
  // drag a virtual thumb so the touch layer has something to show
  if (process.env.TOUCH) {
    const [x1, y1, x2, y2] = process.env.TOUCH.split(',').map(Number);
    await page.touchscreen.tap(x1, y1);
    await page.waitForTimeout(200);
  }
  if (process.env.POSTWAIT) await page.waitForTimeout(+process.env.POSTWAIT);
  await page.screenshot({ path: out });
  console.log(logs.slice(-40).join('\n'));
  await browser.close();
})();
