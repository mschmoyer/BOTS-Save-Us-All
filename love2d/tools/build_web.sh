#!/usr/bin/env bash
# Packages the game as a single self-contained HTML file that runs LOVE in WebGL.
#   tools/build_web.sh [outHtml]
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
OUT="${1:-/tmp/bots_web/index.html}"
TC=/home/user/.toolchain/node_modules
WORK=$(mktemp -d)
mkdir -p "$(dirname "$OUT")"

# 1. zip the project into a .love (source only)
zip -qr "$WORK/game.love" main.lua conf.lua src \
  -x 'src/scenes/demo_*' -x '*.md'

# 2. emscripten-backed LOVE runtime (compatibility build: no SharedArrayBuffer needed)
node "$TC/love.js/index.js" -t "BOTS: Save Us All" -c -m 335544320 \
  "$WORK/game.love" "$WORK/out" >/dev/null

# 3. fold wasm + game data + loaders into one HTML document
node tools/inline_web.js "$WORK/out" "$OUT" "BOTS: Save Us All"
rm -rf "$WORK"
ls -la "$OUT"
