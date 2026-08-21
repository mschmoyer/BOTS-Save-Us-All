// Minimal static server for the hosted build.
//   node tools/serve.js <dir> [port]
//
// Exists because the thing the hosted build is FOR cannot be measured over
// file://: emscripten checks isFileURI before taking its streaming path, so a
// multi-file build opened as a file silently falls back to fetch-then-compile
// and reports numbers that flatter the old build. It also sets the two headers
// a real deployment needs, so `_headers` has something to be checked against.
const http = require('http');
const fs = require('fs');
const path = require('path');

const dir = path.resolve(process.argv[2] || '.');
const port = +(process.argv[3] || 8000);

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.data': 'application/octet-stream',
  '.png': 'image/png',
};

http.createServer((req, res) => {
  const rel = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
  const file = path.join(dir, rel);
  // Nothing outside the served directory, ever -- this is a dev server but it
  // is still a server.
  if (!file.startsWith(dir + path.sep) && file !== path.join(dir, 'index.html')) {
    res.writeHead(403).end('forbidden');
    return;
  }
  fs.readFile(file, (err, buf) => {
    if (err) { res.writeHead(404).end('not found'); return; }
    const ext = path.extname(file);
    res.writeHead(200, {
      'Content-Type': TYPES[ext] || 'application/octet-stream',
      // What tools/build_web.sh writes into _headers, applied for real so the
      // caching claim can be tested rather than asserted.
      'Cache-Control': ext === '.html'
        ? 'no-cache' : 'public, max-age=31536000, immutable',
      // Set unconditionally so a release-runtime (pthreads) experiment has the
      // isolation it needs without a second server. Harmless for the compat
      // build, which never asks for SharedArrayBuffer.
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
      'Cross-Origin-Resource-Policy': 'same-origin',
    });
    res.end(buf);
  });
}).listen(port, () => console.log(`serving ${dir} on http://127.0.0.1:${port}`));
