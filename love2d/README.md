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

LÖVE compiled to WebAssembly, in one of two shapes. Requires `node` with the `love.js`
package available.

```bash
tools/build_web.sh build/web              # hosted: entry HTML + hashed assets (default)
tools/build_web.sh --single build/one.html  # one self-contained file, no server needed
```

The **hosted** build is what ships. The entry document is ~26 KB; the 4.5 MB runtime, the
game data and the loaders are written as `<name>.<hash>.<ext>` beside it, so they can be
served `immutable` and a returning player downloads only the entry document. Leaving the
wasm out of the HTML also lets emscripten fetch it with `WebAssembly.instantiateStreaming`,
compiling it while it downloads.

`build_web.sh` writes a `_headers` file in the Netlify/Cloudflare Pages format. The rule it
encodes, for any other server: **anything with a hash in its name is immutable, the entry
document never is.** In nginx:

```nginx
location = /index.html            { add_header Cache-Control "no-cache"; }
location ~ \.[0-9a-f]{8}\.(wasm|data|js)$ {
  add_header Cache-Control "public, max-age=31536000, immutable";
}
types { application/wasm wasm; }
gzip on; gzip_types application/wasm application/octet-stream text/javascript;
```

Serve `.wasm` as `application/wasm` or streaming compilation is silently skipped. Compress
`.wasm` and `.data` — brotli if the host offers it, gzip otherwise.

To run and profile it locally (streaming needs HTTP; `file://` disables it):

```bash
node tools/serve.js build/web 8123
NODE_PATH=… node tools/webperf.js http://127.0.0.1:8123/index.html 20000 1280 720
```

The **single-file** build is kept for handing someone a build with no server at all. It
costs an extra ~750 ms of JavaScript parsing on every load and re-downloads the whole 7 MB
on every visit, so it is not what you point players at.

See [`../docs/PERFORMANCE_SPEC.md`](../docs/PERFORMANCE_SPEC.md) for the measurements.

`love.js` is found wherever this machine keeps it: `LOVEJS`, the repository's own
`node_modules` (what Vercel installs -- `npm install` at the repository root), or the
original toolchain path.

### The hosted deploy

From the repository root:

```bash
npm run build            # -> public/, the hosted build
vercel deploy --prod     # https://bots-save-us-all.vercel.app
```

Vercel runs the same `npm run build`, so a git-connected deploy produces the same tree.
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
| `tools/bake_audio.sh` | Renders the sound bank offline into `src/bake/audio` as Ogg Vorbis. `tools/build_web.sh` runs it; the game loads it if it is there and synthesizes if it is not. |
| `BOTS_AUDIO_BAKE=0\|1` | Force synthesis, or make a missing or stale bake an error instead of a fallback. |
| `BOTS_SCENE=tools.abaudio tools/shot.sh 1 1 …` | A/Bs the baked bank against the synthesized one and prints the coding error per cue. |
| `tools/bake_trees.sh` | Tessellates the 250-cell tree mesh library offline into `src/bake/trees` as one blob of vertex buffers plus a manifest. `tools/build_web.sh` runs it; the game loads it if it is there and tessellates if it is not. |
| `BOTS_TREE_BAKE=0\|1` | Force tessellation, or make a missing or stale bake an error instead of a fallback. |
| `BOTS_SKIP_TREE_BAKE=1 tools/build_web.sh …` | Ships a web build without the tree bake — it is 4.7 MB gzipped of first-visit payload for ~1.6 s of browser load. |

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
assets/music/       the score -- the only binary media in the game (Ogg Vorbis)
tools/              syntax check, headless capture, web build, browser capture
```

## The score

Three streamed tracks -- `title`, `day`, `night` -- named in `T.music.tracks` in
`src/game/tuning.lua` and played by `src/engine/music.lua`. The game's seven musical
states fold onto those three slots, so dusk plays the day's track and the extraction
the night's; a state change landing on the file already playing does not restart it.

Day and night are the exception: they *blend*. Both tracks run at once, split by a
continuous `M.night` that dusk pulls to 1 over `dayToNight` seconds and dawn pulls
back over `nightToDay`. The split is smootherstep-eased (no corner at either end)
and mixed equal-power (no 3 dB sag in the middle). `dayToNight` matches
`T.cycle.duskLen`, so the score is dark on the frame the sky is.

To add or replace a track, encode to Ogg Vorbis at ~96 kbps and repoint the slot:

```bash
ffmpeg -i master.mp3 -vn -map 0:a:0 -c:a pcm_s16le -ar 44100 -ac 2 -f wav - \
  | oggenc -Q -b 96 -o assets/music/the-track.ogg -
BOTS_SCENE=src.scenes.demo_track tools/shot.sh 3400 1250,2350,3350 /tmp/track
```

`demo_track` walks a whole cycle and plots the mix: the blend should cross at 0.71
with flat ends, and a fold should move nothing. `assets/music/frontier-static.ogg`
is encoded and shipped but bound to no slot yet.

Before this, the score was generated the same way everything else is: a sequencer
firing synthesized one-shots on a musical clock, with six layers, seven modes and a
five-part finale. It still runs -- `src/engine/music_procedural.lua`, driven by
`demo_music` and `demo_audio` -- but nothing in the shipped game calls it.

Two rules keep the codebase coherent:

1. **`src/game/tuning.lua` holds every gameplay constant.** Behaviour code has no magic numbers.
2. **`src/engine/palette.lua` holds every colour.** Draw code has no colour literals.
