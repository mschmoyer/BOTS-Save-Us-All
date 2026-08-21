#!/usr/bin/env bash
# Syntax-checks every Lua file in the project. Must pass before any change is done.
cd "$(dirname "$0")/.." || exit 1
fail=0
while IFS= read -r f; do
  if ! out=$(luajit -bl "$f" 2>&1 >/dev/null); then
    echo "SYNTAX ERROR: $f"; echo "$out" | head -3; fail=1
  fi
done < <(find . -name '*.lua' -not -path './build/*')
# %F and %A are C99 specifiers. LuaJIT accepts them; the PUC Lua 5.1 inside the
# WebAssembly build does not, and throws "invalid option" at the point of the
# call -- which means a format string nobody exercised natively takes the whole
# frame down in the browser and nowhere else. This has now shipped four times,
# in Text.format, in the pause screen and twice more, so it is a build failure.
while IFS= read -r hit; do
  echo "BAD FORMAT (%F/%A is not valid in the browser's Lua 5.1): $hit"; fail=1
# No space in the flag class on purpose: `x % ATLAS_C` is a modulo, not a
# format, and the space flag is not worth the false positives.
done < <(grep -rnE '%[-+#0-9.]*[FA][^A-Za-z_]' --include='*.lua' src main.lua conf.lua 2>/dev/null \
         | grep -vE '^[^:]*:[0-9]+: *--')

[ $fail -eq 0 ] && echo "lua syntax OK ($(find . -name '*.lua' -not -path './build/*' | wc -l) files), no bad format specifiers"
exit $fail
