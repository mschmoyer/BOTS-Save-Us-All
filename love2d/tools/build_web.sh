#!/usr/bin/env bash
# Packages the game as a single self-contained HTML file that runs LOVE in WebGL.
#   tools/build_web.sh [outHtml]
set -euo pipefail
# Resolve the output path against the caller's directory, before the cd below
# moves us into the project -- otherwise a relative path lands somewhere the
# caller did not name.
OUT="${1:-/tmp/bots_web/index.html}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
cd "$(dirname "$0")/.." || exit 1
# love.js lives wherever this machine keeps it: an explicit LOVEJS, the
# repo's own node_modules (what Vercel installs), or the original toolchain.
LOVEJS="${LOVEJS:-}"
if [ -z "$LOVEJS" ]; then
  for c in node_modules/love.js/index.js ../node_modules/love.js/index.js \
           /home/user/.toolchain/node_modules/love.js/index.js; do
    if [ -f "$c" ]; then LOVEJS="$c"; break; fi
  done
fi
[ -n "$LOVEJS" ] || { echo "love.js not found; npm install love.js" >&2; exit 1; }
WORK=$(mktemp -d)
mkdir -p "$(dirname "$OUT")"

# 1. zip the project into a .love (source only)
zip -qr "$WORK/game.love" main.lua conf.lua src \
  -x 'src/scenes/demo_*' -x '*.md'

# 2. emscripten-backed LOVE runtime (compatibility build: no SharedArrayBuffer needed)
node "$LOVEJS" -t "BOTS: Save Us All" -c -m 335544320 \
  "$WORK/game.love" "$WORK/out" >/dev/null

# 3. fold wasm + game data + loaders into one HTML document
node tools/inline_web.js "$WORK/out" "$OUT" "BOTS: Save Us All"
rm -rf "$WORK"
ls -la "$OUT"
# What a phone actually downloads. The HTML is one base64 blob, which inflates
# the payload by a third on disk and then compresses most of that back off
# again -- so the on-disk figure is not the figure that costs anybody anything,
# and the gzip figure is the one to watch.
RAW=$(wc -c < "$OUT")
GZ=$(gzip -9 -c "$OUT" | wc -c)
printf 'size: %.2f MB on disk, %.2f MB gzipped (serve it with Content-Encoding: gzip)\n' \
  "$(echo "$RAW/1048576" | bc -l)" "$(echo "$GZ/1048576" | bc -l)"
