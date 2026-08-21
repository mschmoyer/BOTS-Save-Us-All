#!/usr/bin/env bash
# Builds two clean trees -- committed HEAD, and HEAD with only this workstream's
# files replaced -- and profiles the same scenario in both. Three other
# workstreams are editing this repo live; without this, a measurement is a
# measurement of whatever else landed in the last five minutes (and a run can
# simply be broken by somebody else's in-flight edit).
#
# BASE_REF pins the baseline to the last commit *before* this workstream
# started, so the comparison stays a comparison of these five files and not of
# whatever the other three workstreams landed while a run was in flight.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
BASE=/tmp/bench/base
AFTER=/tmp/bench/after
MINE=(src/entities/tree.lua src/engine/vfx.lua src/engine/lighting.lua
      src/engine/postfx.lua src/engine/draw.lua)

rm -rf /tmp/bench; mkdir -p "$BASE" "$AFTER"
git -C "$REPO" archive "${BASE_REF:-446e0ab}" love2d | tar -x -C "$BASE" --strip-components=1
cp -r "$BASE"/. "$AFTER"/
for f in "${MINE[@]}"; do cp "$ROOT/$f" "$AFTER/$f"; done
cp -r "$ROOT/tools/." "$BASE/tools/"
cp -r "$ROOT/tools/." "$AFTER/tools/"
echo "base=$BASE after=$AFTER"
