#!/usr/bin/env bash
# Bakes the sound bank: renders every cue offline and leaves Ogg Vorbis files
# plus a manifest in src/bake/audio, which engine/audio loads instead of
# synthesizing. See the note above BAKE_DIR in src/engine/audio.lua for why.
#
#   tools/bake_audio.sh [destDir]        # default src/bake/audio
#   BOTS_BAKE_Q=3 tools/bake_audio.sh    # oggenc quality (default 3)
#
# The quality sweep, measured with tools/abaudio.lua over all 324 variants
# (mean coding error / worst 50 Hz envelope delta / bytes of ogg):
#
#   q-1  1.62 MB  -11.5 dB  0.306      q3  2.20 MB  -20.2 dB  0.122
#   q0   1.81 MB  -15.3 dB  0.189      q4  2.36 MB  -21.6 dB  0.128
#   q2   2.05 MB  -18.7 dB  0.153      q6  2.80 MB  -24.7 dB  0.076
#
# The envelope delta -- the metric that says whether a cue still has the same
# shape -- stops improving above q3 while the payload keeps growing, and 44% of
# what is left is Vorbis setup headers (~2.8 KB a file, 324 files), not audio.
# q3 is where that curve flattens.
#
# The bake is a cache. Deleting src/bake/audio is always safe: the game notices
# and synthesizes the bank the way it always did.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
DEST="${1:-src/bake/audio}"
Q="${BOTS_BAKE_Q:-3}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. render. BOTS_AUDIO_STREAM keeps love.load from building a bank the bake is
#    about to throw away; the scene takes its own clean copy of the module.
BOTS_HEADLESS=1 BOTS_FRAMES=1 BOTS_SHOTS=0 BOTS_AUDIO_STREAM=1 BOTS_AUDIO_BAKE=0 \
  BOTS_BAKE_OUT="$WORK" BOTS_SCENE=tools.bakescene SDL_AUDIODRIVER=dummy \
  xvfb-run -a -s "-screen 0 320x200x24" love . 2>&1 |
  grep -viE 'alsa|could not open device' || true
[ -f "$WORK/manifest.lua" ] || { echo "bake: the render produced no manifest"; exit 1; }

# 2. encode. Vorbis at q$Q. --serial pins the Ogg bitstream serial, which is
#    otherwise random per file and is the only thing in an oggenc output that
#    changes run to run: with it pinned, the same tree bakes to the same bytes
#    and `tools/bake_audio.sh && git status` is a real reproducibility check.
find "$WORK" -name '*.wav' -print0 |
  xargs -0 -P "$(nproc)" -I{} oggenc -Q -q "$Q" --serial 1 -o {}.ogg {}
for f in "$WORK"/*.wav.ogg; do mv "$f" "${f%.wav.ogg}.ogg"; done

# 3. install, replacing whatever was there -- a cue that no longer exists must
#    not be left behind for the loader to find.
rm -rf "$DEST"
mkdir -p "$DEST"
mv "$WORK"/*.ogg "$WORK/manifest.lua" "$DEST"/

OGG=$(cat "$DEST"/*.ogg | wc -c)
MAN=$(wc -c < "$DEST/manifest.lua")
MANGZ=$(gzip -9 -c "$DEST/manifest.lua" | wc -c)
N=$(find "$DEST" -name '*.ogg' | wc -l)
printf 'bake: %d files at q%s, %.2f MB of ogg + %.2f MB of manifest (%.2f MB gzipped) -> %s\n' \
  "$N" "$Q" "$(echo "$OGG/1048576" | bc -l)" "$(echo "$MAN/1048576" | bc -l)" \
  "$(echo "($OGG+$MANGZ)/1048576" | bc -l)" "$DEST"
