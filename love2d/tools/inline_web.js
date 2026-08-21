// Bundles a love.js build directory into ONE self-contained HTML file.
// Usage: node inline_web.js <buildDir> <outHtml> <title>
const fs = require('fs');
const path = require('path');
const [,, buildDir, outHtml, title = 'Game'] = process.argv;
const rd = f => fs.readFileSync(path.join(buildDir, f));

const wasmB64 = rd('love.wasm').toString('base64');
const dataB64 = rd('game.data').toString('base64');
let gameJs = rd('game.js').toString('utf8');
const loveJs = rd('love.js').toString('utf8');

// Serve the preloaded package from an in-memory buffer instead of XHR.
const marker = 'function fetchRemotePackage(packageName, packageSize, callback, errback) {';
if (!gameJs.includes(marker)) throw new Error('love.js game.js layout changed - patch point missing');
gameJs = gameJs.replace(marker, marker + ' callback(window.__LOVE_DATA__.buffer); return;');

const shell = fs.readFileSync(path.join(__dirname, 'web_shell.html'), 'utf8');
const html = shell
  .replace('__TITLE__', title)
  .replace('/*__WASM_B64__*/', () => wasmB64)
  .replace('/*__DATA_B64__*/', () => dataB64)
  .replace('/*__GAME_JS__*/', () => gameJs)
  .replace('/*__LOVE_JS__*/', () => loveJs);

fs.writeFileSync(outHtml, html);
console.log(`wrote ${outHtml} (${(html.length / 1048576).toFixed(2)} MB)`);
