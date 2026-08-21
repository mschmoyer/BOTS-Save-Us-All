#!/usr/bin/env bash
# Runs the game headless and copies the captured frames somewhere you can look at them.
# Usage: [BOTS_SCENE=src.scenes.demo_x] tools/shot.sh [frames] [shotFrames] [outdir]
set -u
cd "$(dirname "$0")/.." || exit 1
FRAMES="${1:-420}"
SHOTS="${2:-$FRAMES}"
OUT="${3:-/tmp/bots_shots}"
ID="bots_$(echo "${BOTS_SCENE:-main}${OUT}" | md5sum | cut -c1-10)"
SAVE="$HOME/.local/share/love/$ID"
rm -rf "$SAVE" "$OUT"; mkdir -p "$OUT"
BOTS_IDENTITY="$ID" BOTS_HEADLESS=1 BOTS_FRAMES="$FRAMES" BOTS_SHOTS="$SHOTS" \
  BOTS_SCENE="${BOTS_SCENE:-}" SDL_AUDIODRIVER=dummy \
  xvfb-run -a -s "-screen 0 ${BOTS_W:-1600}x${BOTS_H:-900}x24" \
  love . 2>&1 | grep -viE 'alsa|could not open device' | head -60
cp "$SAVE"/shot_*.png "$OUT"/ 2>/dev/null
ls -1 "$OUT" 2>/dev/null
