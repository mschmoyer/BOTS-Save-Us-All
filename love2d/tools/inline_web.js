// Bundles a love.js build directory into ONE self-contained HTML file.
// Usage: node inline_web.js <buildDir> <outHtml> <title>
const fs = require('fs');
const path = require('path');
const [,, buildDir, outHtml, title = 'Game'] = process.argv;
const rd = f => fs.readFileSync(path.join(buildDir, f));

const wasmB64 = rd('love.wasm').toString('base64');
const dataB64 = rd('game.data').toString('base64');
let gameJs = rd('game.js').toString('utf8');
const loveJsRaw = rd('love.js').toString('utf8');

// Serve the preloaded package from an in-memory buffer instead of XHR.
const marker = 'function fetchRemotePackage(packageName, packageSize, callback, errback) {';
if (!gameJs.includes(marker)) throw new Error('love.js game.js layout changed - patch point missing');
gameJs = gameJs.replace(marker, marker + ' callback(window.__LOVE_DATA__.buffer); return;');

// Make the save directory actually survive a reload.
//
// love.js mounts IndexedDB over /home/web_user/love and then flushes it in
// exactly one place: a `beforeunload` handler. In an iframe -- which is where
// this build is played -- beforeunload is unreliable and on mobile it
// effectively never fires, so every setting and every saved run was written to
// memory and thrown away. Expose FS, and flush on a timer and on the events
// that do fire when a page goes away.
const idbAnchor = 'FS.mount(IDBFS,{},"/home/web_user/love");';
if (!loveJsRaw.includes(idbAnchor)) {
  throw new Error('love.js IDBFS mount layout changed - persistence patch point missing');
}
const loveJs = loveJsRaw.replace(idbAnchor, idbAnchor + `
Module["FS"]=FS;
var __botsFlushing=false,__botsAgain=false;
var __botsFlush=function(){
  if(__botsFlushing){__botsAgain=true;return}
  __botsFlushing=true;
  try{FS.syncfs(false,function(){__botsFlushing=false;if(__botsAgain){__botsAgain=false;__botsFlush()}})}
  catch(e){__botsFlushing=false}
};
Module["__flush"]=__botsFlush;
setInterval(__botsFlush,4000);
document.addEventListener("visibilitychange",function(){if(document.hidden)__botsFlush()});
window.addEventListener("pagehide",__botsFlush);
window.addEventListener("blur",__botsFlush);
`);

const shell = fs.readFileSync(path.join(__dirname, 'web_shell.html'), 'utf8');
const html = shell
  .replace('__TITLE__', title)
  .replace('/*__WASM_B64__*/', () => wasmB64)
  .replace('/*__DATA_B64__*/', () => dataB64)
  .replace('/*__GAME_JS__*/', () => gameJs)
  .replace('/*__LOVE_JS__*/', () => loveJs);

fs.writeFileSync(outHtml, html);
console.log(`wrote ${outHtml} (${(html.length / 1048576).toFixed(2)} MB)`);
