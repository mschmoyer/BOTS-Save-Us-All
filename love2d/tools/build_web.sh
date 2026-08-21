#!/usr/bin/env bash
# Packages the game to run LOVE in WebGL, in one of two shapes.
#
#   tools/build_web.sh [outDir]              hosted build: entry HTML + hashed
#                                            assets, the default and what ships
#   tools/build_web.sh --single [outHtml]    one self-contained HTML file
#
# The hosted build exists because the single file costs 12.9 s of JavaScript
# parsing before the shell runs -- see tools/pack_web.js for the measurements.
# The single file is kept because it still runs from a USB stick.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

MODE=multi
if [ "${1:-}" = "--single" ]; then MODE=single; shift; fi
if [ "$MODE" = single ]; then OUT="${1:-/tmp/bots_web/index.html}"
else                           OUT="${1:-/tmp/bots_web}"; fi

TC=/home/user/.toolchain/node_modules
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 0. bake the sound bank into src/bake/audio, which is inside the tree the zip
#    below already takes. The browser's interpreter needs the better part of
#    half a minute to synthesize this bank and gets 2 ms a frame to do it in;
#    baked, it is a stb_vorbis decode inside the wasm instead. It is a cache --
#    BOTS_SKIP_BAKE=1 ships without it and the game synthesizes as it always
#    has. See the note above BAKE_DIR in src/engine/audio.lua.
[ -n "${BOTS_SKIP_BAKE:-}" ] || tools/bake_audio.sh

# 0b. bake the tree mesh library into src/bake/trees, same deal: 250 cells of
#     geometry that depend on nothing but the species, the variant and the
#     growth bucket, tessellated by every tab today. Baked, load is a memcpy per
#     vertex buffer. It costs 12.5 MB on disk (4.7 MB gzipped, cached immutable
#     after the first visit) -- BOTS_SKIP_TREE_BAKE=1 ships without it and the
#     game tessellates as it always has. See the note above BAKE_DIR in
#     src/entities/tree.lua.
[ -n "${BOTS_SKIP_TREE_BAKE:-}" ] || tools/bake_trees.sh

# 1. zip the project into a .love (source only)
zip -qr "$WORK/game.love" main.lua conf.lua src \
  -x 'src/scenes/demo_*' -x '*.md'

# 2. emscripten-backed LOVE runtime (compatibility build: no SharedArrayBuffer
#    needed). NOTE: -c is not an Asyncify build -- the release wasm is actually
#    larger, and the difference is pthreads. Dropping -c does not recover
#    interpreter speed; see docs/PERFORMANCE_SPEC.md.
node "$TC/love.js/index.js" -t "BOTS: Save Us All" -c -m 335544320 \
  "$WORK/game.love" "$WORK/out" >/dev/null

# 3. lay the runtime, the game data and the loaders out for the chosen shape
if [ "$MODE" = single ]; then
  mkdir -p "$(dirname "$OUT")"
  node tools/inline_web.js "$WORK/out" "$OUT" "BOTS: Save Us All"
  # What a phone actually downloads. The HTML is one base64 blob, which inflates
  # the payload by a third on disk and then compresses most of that back off
  # again -- so the on-disk figure is not the figure that costs anybody anything,
  # and the gzip figure is the one to watch.
  RAW=$(wc -c < "$OUT")
  GZ=$(gzip -9 -c "$OUT" | wc -c)
  printf 'size: %.2f MB on disk, %.2f MB gzipped (serve it with Content-Encoding: gzip)\n' \
    "$(echo "$RAW/1048576" | bc -l)" "$(echo "$GZ/1048576" | bc -l)"
else
  node tools/pack_web.js "$WORK/out" "$OUT" "BOTS: Save Us All"
  # The entry document is the only file a returning player fetches: everything
  # else is content-hashed and can be served immutable. Both figures matter and
  # they are different figures, so print both.
  ENTRY=$(wc -c < "$OUT/index.html")
  ENTRY_GZ=$(gzip -9 -c "$OUT/index.html" | wc -c)
  TOTAL=$(cat "$OUT"/* | wc -c)
  TOTAL_GZ=$(cat "$OUT"/* | gzip -9 -c | wc -c)
  printf 'entry: %.1f KB (%.1f KB gzipped) -- the only uncacheable file\n' \
    "$(echo "$ENTRY/1024" | bc -l)" "$(echo "$ENTRY_GZ/1024" | bc -l)"
  printf 'total: %.2f MB (%.2f MB gzipped) -- first visit only\n' \
    "$(echo "$TOTAL/1048576" | bc -l)" "$(echo "$TOTAL_GZ/1048576" | bc -l)"
  cat > "$OUT/_headers" <<'HDR'
# Netlify/Cloudflare Pages style. See love2d/README.md for the equivalent in
# nginx or any other server: the rule is that everything with a hash in its
# name is immutable and the entry document never is.
/index.html
  Cache-Control: no-cache
/*.wasm
  Cache-Control: public, max-age=31536000, immutable
  Content-Type: application/wasm
/*.data
  Cache-Control: public, max-age=31536000, immutable
/*.js
  Cache-Control: public, max-age=31536000, immutable
HDR
  echo "wrote $OUT/_headers"
fi
