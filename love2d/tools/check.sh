#!/usr/bin/env bash
# Syntax-checks every Lua file in the project. Must pass before any change is done.
cd "$(dirname "$0")/.." || exit 1
fail=0
while IFS= read -r f; do
  if ! out=$(luajit -bl "$f" 2>&1 >/dev/null); then
    echo "SYNTAX ERROR: $f"; echo "$out" | head -3; fail=1
  fi
done < <(find . -name '*.lua' -not -path './build/*')
[ $fail -eq 0 ] && echo "lua syntax OK ($(find . -name '*.lua' -not -path './build/*' | wc -l) files)"
exit $fail
