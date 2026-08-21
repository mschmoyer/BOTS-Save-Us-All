#!/usr/bin/env bash
# Runs the game headless and copies the captured frames next to the project.
# Usage: tools/shot.sh [frames] [comma,separated,shot,frames] [outdir]
set -u
cd "$(dirname "$0")/.." || exit 1
FRAMES="${1:-420}"
SHOTS="${2:-$FRAMES}"
OUT="${3:-/tmp/bots_shots}"
SAVE="$HOME/.local/share/love/bots_reforest"
rm -rf "$SAVE" "$OUT"; mkdir -p "$OUT"
BOTS_HEADLESS=1 BOTS_FRAMES="$FRAMES" BOTS_SHOTS="$SHOTS" BOTS_SCENE="${BOTS_SCENE:-}" \
  SDL_AUDIODRIVER=dummy xvfb-run -a -s "-screen 0 1600x900x24" \
  love . 2>&1 | grep -viE 'alsa|could not open device' | head -40
cp "$SAVE"/shot_*.png "$OUT"/ 2>/dev/null
ls -1 "$OUT" 2>/dev/null
