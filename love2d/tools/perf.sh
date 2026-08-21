#!/usr/bin/env bash
# Repeatable frame profile. Fixed seed, fixed jump state, fixed frame count.
#   tools/perf.sh [tag]
# env: BOTS_JUMP BOTS_JUMP_TREES BOTS_JUMP_BOTS BOTS_SEED BOTS_W BOTS_H BOTS_TUNE
#      BOTS_PERF_FRAMES  frames measured, after BOTS_PERF_WARM warm-up frames
#      BOTS_PERF_NULLGPU every GPU entry point becomes a no-op: Lua cost only
#      BOTS_PERF_ABLATE  comma list: rim,shadow,trees,post,bloom,lights,hud,vfx,
#                        decals,water,terrain,entities,leaves
set -u
cd "$(dirname "$0")/.." || exit 1
TAG="${1:-run}"
FR="${BOTS_PERF_FRAMES:-180}"
WARM="${BOTS_PERF_WARM:-60}"
TOTAL=$((FR + WARM + 4))
ID="bots_perf"
SAVE="$HOME/.local/share/love/$ID"
rm -rf "$SAVE"
BOTS_IDENTITY="$ID" BOTS_HEADLESS=1 BOTS_DRAW_ALL=1 \
  BOTS_FRAMES="$TOTAL" BOTS_SHOTS="$TOTAL" \
  BOTS_SCENE=tools.perfscene BOTS_AUTOPLAY=1 \
  BOTS_SEED="${BOTS_SEED:-7}" \
  BOTS_JUMP="${BOTS_JUMP:-night}" \
  BOTS_JUMP_TREES="${BOTS_JUMP_TREES:-900}" \
  BOTS_JUMP_BOTS="${BOTS_JUMP_BOTS:-45}" \
  BOTS_TUNE="${BOTS_TUNE:-o2.target=400}" \
  BOTS_PERF_TAG="$TAG" BOTS_PERF_FRAMES="$FR" BOTS_PERF_WARM="$WARM" \
  SDL_AUDIODRIVER=dummy \
  xvfb-run -a -s "-screen 0 ${BOTS_W:-1600}x${BOTS_H:-900}x24" \
  love . 2>&1 | grep -E '^PERF|ERROR|Error' | grep -viE 'alsa'
