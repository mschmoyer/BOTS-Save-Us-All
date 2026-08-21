// Packs a love.js build directory into a HOSTED web build: one small entry
// document plus content-hashed asset files.
//   node pack_web.js <buildDir> <outDir> <title>
//
// WHY THIS EXISTS
//
// The single-file build (inline_web.js) was correct while the game had to run
// from any URL with no server. It costs, measured in Chromium at 1280x720:
//
//     navigation.responseEnd     120 ms   the 7 MB document is off the disk
//     navigation.domInteractive  12,947 ms   ...and finally parsed
//
// Nearly thirteen seconds, and it is the JavaScript parser, not the base64
// decode that the code used to blame -- decoding both blobs is 167 ms of that
// window. A 6.3 MB string literal has to be tokenised before any script on the
// page runs, and no amount of decoding cleverness touches it.
//
// Splitting the payload out deletes that parse, and buys three more things a
// hosted deployment should have anyway:
//
//   * emscripten fetches love.wasm itself, which means
//     WebAssembly.instantiateStreaming -- compiled while it downloads;
//   * the 4.7 MB runtime is content-hashed, so it is cached `immutable` and a
//     second visit does not re-download it (today it is glued to the HTML and
//     re-downloaded every single time);
//   * the .data package gets real XHR progress, which the boot panel already
//     knows how to display.
const fs = require('fs');
const path = require('path');
const W = require('./web_patch');

const [, , buildDir, outDir, title = 'Game'] = process.argv;
if (!buildDir || !outDir) {
  console.error('usage: node pack_web.js <buildDir> <outDir> <title>');
  process.exit(1);
}
fs.mkdirSync(outDir, { recursive: true });

// Every asset is written as <stem>.<hash><ext> so it can be served immutable.
// The map from logical name to real filename is the only thing the document
// needs to know, and it is what Module.locateFile answers from.
const assets = {};
function emit(logicalName, buf) {
  const ext = path.extname(logicalName);
  const stem = path.basename(logicalName, ext);
  const name = `${stem}.${W.hash(buf)}${ext}`;
  fs.writeFileSync(path.join(outDir, name), buf);
  assets[logicalName] = name;
  return name;
}

emit('love.wasm', W.readBuild(buildDir, 'love.wasm'));
emit('game.data', W.readBuild(buildDir, 'game.data'));

// game.js keeps its stock XHR package loader here -- only the single-file build
// needs the in-memory shim. love.js still needs the IDBFS persistence patch.
const gameJs = emit('game.js', W.readBuild(buildDir, 'game.js'));
const loveJs = emit('love.js',
  Buffer.from(W.patchLoveJs(W.readBuild(buildDir, 'love.js').toString('utf8')), 'utf8'));

const assetBoot = `window.__LOVE_ASSETS__ = ${JSON.stringify(assets)};
  say('runtime linked', 'ok'); setProgress(0.07); mark('wasm-decoded');
  say('island data queued', 'ok'); setProgress(0.10); mark('data-decoded');`;

// Plain ordered <script src> tags: no async/defer, so they run in source order
// after the inline shell script has defined Module, exactly as the inlined
// versions did.
const scripts = `<script src="${gameJs}"></script>\n<script src="${loveJs}"></script>`;

const html = W.renderShell(title, { __ASSET_BOOT__: assetBoot, __SCRIPTS__: scripts });
fs.writeFileSync(path.join(outDir, 'index.html'), html);

const total = Object.values(assets)
  .reduce((n, f) => n + fs.statSync(path.join(outDir, f)).size, html.length);
console.log(`wrote ${outDir}/index.html (${(html.length / 1024).toFixed(1)} KB entry, `
  + `${(total / 1048576).toFixed(2)} MB total)`);
for (const [k, v] of Object.entries(assets)) {
  console.log(`  ${k.padEnd(10)} -> ${v} (${(fs.statSync(path.join(outDir, v)).size / 1048576).toFixed(2)} MB)`);
}
