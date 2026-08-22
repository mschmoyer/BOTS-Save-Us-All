#!/usr/bin/env bash
# names.lua's header rule, enforced: no ambient chatter line may also be a line a
# bot says in a scripted beat. Hearing a cutscene's line from a passing harvester
# an hour early spends the cutscene, and it has happened twice in this project --
# "save the human" was in the rebel pool while the rebellion was being written.
# Run it after touching either file.
cd "$(dirname "$0")/.." || exit 1
exec luajit tools/poolcheck.lua "$@"
