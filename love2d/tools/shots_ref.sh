#!/usr/bin/env bash
# The fixed set of frames every performance change has to leave unchanged.
#   tools/shots_ref.sh <outdir>
set -u
cd "$(dirname "$0")/.." || exit 1
OUT="${1:-/tmp/ref}"
rm -rf "$OUT"; mkdir -p "$OUT"
shot() { # name  frames  shots  extra-env...
  local name="$1" fr="$2" sh="$3"; shift 3
  local d; d=$(mktemp -d)
  env "$@" BOTS_SCENE=src.scenes.game BOTS_AUTOPLAY=1 BOTS_SEED=7 \
    tools/shot.sh "$fr" "$sh" "$d" >/dev/null 2>&1
  local i=0
  for f in "$d"/shot_*.png; do
    [ -e "$f" ] || continue
    cp "$f" "$OUT/${name}_$(basename "$f" .png | tr -d 'shot_').png"
    i=$((i+1))
  done
  rm -rf "$d"
  echo "$name: $i"
}
shot night900 200 "120 200" BOTS_JUMP=night   BOTS_JUMP_TREES=900 BOTS_JUMP_BOTS=45 BOTS_TUNE=o2.target=400
shot ex900    200 "120 200" BOTS_JUMP=extraction BOTS_JUMP_TREES=900 BOTS_JUMP_BOTS=45
shot day260   200 "120 200" BOTS_JUMP=day    BOTS_JUMP_TREES=260 BOTS_JUMP_BOTS=30 BOTS_TUNE=o2.target=400
shot phone    200 "200"     BOTS_JUMP=extraction BOTS_JUMP_TREES=900 BOTS_JUMP_BOTS=45 BOTS_W=1180 BOTS_H=545 BOTS_INPUT=touch
ls -1 "$OUT"
