# BOTS: Save Us All — *Reforest*

A full rebuild of the 2019 Chillenium jam game in **LÖVE 11.4 (Lua)**, with no external
assets: the island, the trees, the robots, the typeface and every sound are generated at
runtime.

> You are the last human alive. You cannot fight. You build small machines that can — and by
> the end of the night you will care whether they come back.

- **Design spec:** [`../docs/REFOREST_SPEC.md`](../docs/REFOREST_SPEC.md)
- **The original:** [`../docs/GAME_DESIGN.md`](../docs/GAME_DESIGN.md)

## Running it

```bash
love .                       # LÖVE 11.4+
```

Keyboard/mouse, gamepad (DualSense and Xbox glyphs are detected automatically) and touch are
all supported; the UI re-glyphs itself live when you change device.

| | Keyboard | Gamepad |
| --- | --- | --- |
| Move | `WASD` / arrows | left stick |
| Dash | `Space` | ✕ / A |
| Shove | `E` / left mouse | ▢ / X |
| Pulse (hold) | `Q` / right mouse | R2 |
| Hand-plant | `F` | △ / Y |
| Build | `1`–`6`, or hold `Tab` for the wheel | L1 wheel |
| Map | `M` | View |
| Pause | `Esc` | Options |

`F3` toggles the performance readout, `F5` restarts, `F11` is fullscreen.

The native window opens fullscreen. Setting `BOTS_W`/`BOTS_H` (or running the headless
harness) opens a plain window of that size instead. In the browser the canvas fills the page,
and pressing **Begin** asks for browser fullscreen -- the bottom-right control toggles it.

## Building the web version

The game ships as **one self-contained HTML file** — LÖVE compiled to WebAssembly, with the
runtime and the game data inlined, so it runs from a single URL with no server:

```bash
tools/build_web.sh build/index.html
```

Requires `node` with the `love.js` package available (see `tools/inline_web.js`). The build
script finds it in `node_modules/love.js` -- `npm install` at the repository root -- or
wherever `LOVEJS` points.

This build is what the repository hosts. From the repository root:

```bash
npm run build            # -> public/index.html
vercel deploy --prod     # https://bots-save-us-all.vercel.app
```

Vercel runs the same `npm run build`, so a git-connected deploy produces the same file.
Nothing else in this repository is hosted -- the 2019 GameMaker project is excluded by
`.vercelignore`.

## Tools

| Command | What it does |
| --- | --- |
| `tools/check.sh` | LuaJIT syntax check over every file. Must pass before anything is done. |
| `tools/shot.sh N SHOTS DIR` | Runs the game headless under Xvfb and captures PNGs at the given frames. Only renders the frames it photographs, so long captures are fast. |
| `BOTS_SCENE=src.scenes.demo_x tools/shot.sh …` | Boots straight into a subsystem's demo scene. |
| `BOTS_AUTOPLAY=1 … tools/shot.sh …` | Drives the player with a scripted agent and prints a CSV balance trace (`TRACE,…`). |
| `BOTS_SPEED=8` | Runs the simulation faster (juice is disabled so the trace stays honest). |
| `BOTS_JUMP=night\|extraction` | Starts a session late, with `BOTS_JUMP_TREES` / `BOTS_JUMP_BOTS`. |
| `tools/webshot.js` | Loads a built HTML file in headless Chromium and screenshots it. |

## Layout

```
main.lua            entry point, main loop, headless capture harness
conf.lua            window and module configuration
src/core/           class, math/easing/noise/rng, signal bus, timers, spatial hash
src/engine/         palette, draw kit, text + typeface, input, camera, juice,
                    lighting, post-processing, day/night, particles, decals,
                    synth, audio, music, touch, screen stack, UI kit
src/world/          terrain generation, water, wind, weather, the world itself
src/entities/       player, bots, enemies, boss, trees, cobalt, projectiles, home rig
src/game/           tuning constants, chips, director, story, dialogue, HUD, minimap
src/scenes/         title, game, draft, pause, options, ending, and demo_* test scenes
tools/              syntax check, headless capture, web build, browser capture
```

Two rules keep the codebase coherent:

1. **`src/game/tuning.lua` holds every gameplay constant.** Behaviour code has no magic numbers.
2. **`src/engine/palette.lua` holds every colour.** Draw code has no colour literals.
