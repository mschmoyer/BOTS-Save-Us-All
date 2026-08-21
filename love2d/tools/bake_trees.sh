#!/usr/bin/env bash
# Bakes the tree mesh library: tessellates all 250 (species, variant, growth)
# cells offline and leaves one blob of vertex buffers plus a manifest in
# src/bake/trees, which src/entities/tree.lua loads instead of tessellating.
# See the note above BAKE_DIR in that file for why.
#
#   tools/bake_trees.sh [destDir]        # default src/bake/trees
#
# There is nothing to tune here and no encoder in the way: the bytes written are
# the bytes the vertex buffers get, so the baked library and the live one are the
# same geometry by construction and not by resemblance.
#
# The bake is a cache. Deleting src/bake/trees is always safe: the game notices
# and tessellates the library the way it always did.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
DEST="${1:-src/bake/trees}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# BOTS_AUDIO_STREAM keeps love.load from synthesizing a sound bank nobody is
# going to hear; BOTS_TREE_BAKE=0 keeps a bake already on disk from being read
# back in and re-emitted, so a re-bake always comes from the tessellator.
BOTS_HEADLESS=1 BOTS_FRAMES=1 BOTS_SHOTS=0 BOTS_AUDIO_STREAM=1 BOTS_AUDIO_BAKE=0 \
  BOTS_TREE_BAKE=0 BOTS_TREEBAKE_OUT="$WORK" BOTS_SCENE=tools.treebakescene \
  SDL_AUDIODRIVER=dummy \
  xvfb-run -a -s "-screen 0 320x200x24" love . 2>&1 |
  grep -viE 'alsa|could not open device' || true
[ -f "$WORK/manifest.lua" ] || { echo "bake: the render produced no manifest"; exit 1; }
[ -f "$WORK/trees.bin" ]    || { echo "bake: the render produced no blob"; exit 1; }

# Replace whatever was there: a cell that no longer exists must not be left
# behind for the loader to find.
rm -rf "$DEST"
mkdir -p "$DEST"
mv "$WORK/trees.bin" "$WORK/manifest.lua" "$DEST"/

BIN=$(wc -c < "$DEST/trees.bin")
BINGZ=$(gzip -9 -c "$DEST/trees.bin" | wc -c)
MAN=$(wc -c < "$DEST/manifest.lua")
MANGZ=$(gzip -9 -c "$DEST/manifest.lua" | wc -c)
printf 'bake: %.2f MB of vertex data + %.0f KB of manifest (%.2f MB gzipped) -> %s\n' \
  "$(echo "$BIN/1048576" | bc -l)" "$(echo "$MAN/1024" | bc -l)" \
  "$(echo "($BINGZ+$MANGZ)/1048576" | bc -l)" "$DEST"
