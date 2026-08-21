#!/usr/bin/env bash
# TEMPORARY: per-frame allocation profile (item F5). Same fixed scene as perf.sh.
set -u
cd "$(dirname "$0")/.." || exit 1
TAG="${1:-run}"
FR="${BOTS_ALLOC_FRAMES:-180}"
WARM="${BOTS_ALLOC_WARM:-60}"
TOTAL=$((FR + WARM + 4))
ID="bots_alloc"
rm -rf "$HOME/.local/share/love/$ID"
BOTS_IDENTITY="$ID" BOTS_HEADLESS=1 BOTS_DRAW_ALL=1 \
  BOTS_FRAMES="$TOTAL" BOTS_SHOTS="$TOTAL" \
  BOTS_SCENE=tools.allocscene BOTS_AUTOPLAY=1 \
  BOTS_SEED="${BOTS_SEED:-7}" \
  BOTS_JUMP="${BOTS_JUMP:-night}" \
  BOTS_JUMP_TREES="${BOTS_JUMP_TREES:-900}" \
  BOTS_JUMP_BOTS="${BOTS_JUMP_BOTS:-45}" \
  BOTS_TUNE="${BOTS_TUNE:-o2.target=400}" \
  BOTS_ALLOC_TAG="$TAG" BOTS_ALLOC_FRAMES="$FR" BOTS_ALLOC_WARM="$WARM" \
  SDL_AUDIODRIVER=dummy \
  xvfb-run -a -s "-screen 0 ${BOTS_W:-1600}x${BOTS_H:-900}x24" \
  love . 2>&1 | grep -E '^ALLOC|ERROR|Error' | grep -viE 'alsa'
