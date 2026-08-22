// Bundles a love.js build directory into ONE self-contained HTML file.
// Usage: node inline_web.js <buildDir> <outHtml> <title>
//
// This is no longer the default -- see pack_web.js for the hosted build and for
// the measurements. Keep it: a single file that runs from any dumb file host,
// a USB stick or a file:// URL is genuinely useful for sharing a build, and it
// is the only mode that works with no server at all.
//
// Its cost, and it is not small: the wasm becomes a 6.3 MB string literal in
// the document, and Chromium spends 12.9 s parsing that before a line of the
// shell runs. Do not ship this to players.
const fs = require('fs');
const W = require('./web_patch');

const [, , buildDir, outHtml, title = 'Game'] = process.argv;
if (!buildDir || !outHtml) {
  console.error('usage: node inline_web.js <buildDir> <outHtml> <title>');
  process.exit(1);
}

const wasmB64 = W.readBuild(buildDir, 'love.wasm').toString('base64');
const dataB64 = W.readBuild(buildDir, 'game.data').toString('base64');
const gameJs = W.patchGameJsForMemory(W.readBuild(buildDir, 'game.js').toString('utf8'));
const loveJs = W.patchLoveJs(W.readBuild(buildDir, 'love.js').toString('utf8'));

const assetBoot = `window.__LOVE_WASM__ = b64('${wasmB64}');
  say('runtime decoded', 'ok'); setProgress(0.07); mark('wasm-decoded');
  window.__LOVE_DATA__ = b64('${dataB64}');
  say('island data unpacked', 'ok'); setProgress(0.10); mark('data-decoded');`;

const scripts = `<script>${gameJs}</script>\n<script>${loveJs}</script>`;

const html = W.renderShell(title, { __ASSET_BOOT__: assetBoot, __SCRIPTS__: scripts });
fs.writeFileSync(outHtml, html);
console.log(`wrote ${outHtml} (${(html.length / 1048576).toFixed(2)} MB)`);
