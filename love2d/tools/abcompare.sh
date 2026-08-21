#!/usr/bin/env bash
# Interleaved A/B against a shared, noisy machine. llvmpipe wall-clock swings
# 40% run to run depending on what else has the cores, so the runs alternate and
# the *minimum* is reported: the fastest observed frame is the one that had the
# machine to itself, and it is the only number that compares.
#   tools/abcompare.sh <rounds> <env...>
set -u
ROUNDS="$1"; shift
for r in $(seq 1 "$ROUNDS"); do
  for t in base after; do
    (cd /tmp/bench/$t && env "$@" tools/perf.sh "$t" | grep PERFSUM | sed "s/^/R$r /")
  done
done
