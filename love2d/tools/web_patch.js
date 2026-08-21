// Shared between the two web packers: read a love.js build directory and apply
// the patches both output modes need.
//
// There are two modes, and the only real difference between them is where the
// 4.7 MB of wasm and the game data live:
//
//   pack_web.js    separate content-hashed files next to the HTML  (default)
//   inline_web.js  base64 string literals inside the HTML          (one file)
//
// Everything else -- the IDBFS persistence patch, the shell, the boot panel --
// is identical, so it lives here rather than being copy-pasted and drifting.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

/// Read one file out of a love.js build directory.
const readBuild = (dir, f) => fs.readFileSync(path.join(dir, f));

/// Short content hash, for cache-busting a file whose URL is `immutable`.
function hash(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex').slice(0, 8);
}

// Make the save directory actually survive a reload.
//
// love.js mounts IndexedDB over /home/web_user/love and then flushes it in
// exactly one place: a `beforeunload` handler. In an iframe -- which is where
// this build is played -- beforeunload is unreliable and on mobile it
// effectively never fires, so every setting and every saved run was written to
// memory and thrown away. Expose FS, and flush on a timer and on the events
// that do fire when a page goes away.
const IDB_ANCHOR = 'FS.mount(IDBFS,{},"/home/web_user/love");';
const IDB_PATCH = `
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
`;

function patchLoveJs(raw) {
  if (!raw.includes(IDB_ANCHOR)) {
    throw new Error('love.js IDBFS mount layout changed - persistence patch point missing');
  }
  return raw.replace(IDB_ANCHOR, IDB_ANCHOR + IDB_PATCH);
}

// Serve the preloaded package from an in-memory buffer instead of XHR. Only the
// single-file build wants this: with the .data on disk next to the HTML the
// stock XHR path is what we want, and it reports download progress for free.
const PKG_ANCHOR = 'function fetchRemotePackage(packageName, packageSize, callback, errback) {';

function patchGameJsForMemory(raw) {
  if (!raw.includes(PKG_ANCHOR)) {
    throw new Error('love.js game.js layout changed - patch point missing');
  }
  return raw.replace(PKG_ANCHOR, PKG_ANCHOR + ' callback(window.__LOVE_DATA__.buffer); return;');
}

/// Fill the shell template. `parts` supplies the two placeholders the packers
/// differ on; the rest of the document is the same either way.
function renderShell(title, parts) {
  const shell = fs.readFileSync(path.join(__dirname, 'web_shell.html'), 'utf8');
  for (const [k, v] of Object.entries({ '__TITLE__': title, ...parts })) {
    const token = k === '__TITLE__' ? k : `/*${k}*/`;
    if (!shell.includes(token)) throw new Error(`web_shell.html is missing ${token}`);
  }
  return shell
    .replace('__TITLE__', title)
    .replace('/*__ASSET_BOOT__*/', () => parts.__ASSET_BOOT__)
    .replace('/*__SCRIPTS__*/', () => parts.__SCRIPTS__);
}

module.exports = { readBuild, hash, patchLoveJs, patchGameJsForMemory, renderShell };
