# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this project is

**BOTS: Save Us All!** — a top-down survival/base-builder made in **GameMaker Studio 2 (GML)**
for the **Chillenium 2019** 48-hour game jam. Two authors, both with roughly a day of GameMaker
experience at the time.

Open `bots.yyp` in GameMaker Studio 2 to run it. There is no build script, test suite, or
package manager in this repo — it is a pure GMS2 project tree.

See **[docs/GAME_DESIGN.md](docs/GAME_DESIGN.md)** for the plot, core loop, tuning numbers,
and theme.

## Repository layout

| Path | Contents |
| --- | --- |
| `bots.yyp` | GameMaker project file (asset registry — GMS2 rewrites it; avoid hand-editing) |
| `objects/<name>/*.gml` | One file per GML event: `Create_0`, `Step_0`, `Draw_0`, `Alarm_N`, `KeyPress_<keycode>`, `Collision_<guid>` |
| `scripts/<name>/<name>.gml` | Shared scripts — helpers (`clampMe`), the dialog system (`scr_*`), and conversation data (`convo_*`) |
| `rooms/rm_title \| rm_game \| rm_ending` | The three rooms. `rm_game/RoomCreationCode.gml` holds global init and unit costs |
| `sprites/`, `sounds/`, `fonts/`, `tilesets/`, `timelines/` | Standard GMS2 asset folders |
| `Soundtrack/` | Raw `.mp3` source for the four music tracks |

Collision event files are named by GUID (`Collision_<guid>.gml`), so grep for their contents
rather than trying to guess a filename. The `/// @description` comment at the top of each
event is usually the best hint about what it does.

## Conventions in this codebase

- **Prefixes:** `obj_` objects, `spr_` sprites, `snd_`/`music_` audio, `scr_` scripts,
  `convo_` dialog data, `rm_` rooms, `fnt_` fonts.
- **Layers** (in `rm_game`): `TilesLayer`, `TreeLayer`, `PhysicalObjectsLayer`,
  `EffectsLayer`, `InterfaceBackLayer`, `InterfaceLayer`. Create instances on the layer that
  matches their role — trees go on `TreeLayer`, units and pickups on `PhysicalObjectsLayer`,
  spawners/dialogs on `EffectsLayer`, tutorial tips on `InterfaceLayer`.
- **State lives on singletons, not in globals**, mostly. `obj_score` is the de-facto game-state
  manager (score, progression flags, stage transitions, HUD drawing) and other objects read it
  directly as `obj_score.<var>`. Only a handful of true globals exist, all initialized in
  `rooms/rm_game/RoomCreationCode.gml` or `obj_game/Create_0.gml`:
  `global.planterCost`, `global.builderCost`, `global.repulsorCost`, `global.dialogActive`,
  `global.dialogInstance`, `global.introductionDone`, `global.attackTipStarted`,
  `global.attackTipDone`, `global.current_song`.
- **Timers are alarms.** Nearly every recurring behaviour (spawning, planting, wandering,
  cutscene delays) is an `alarm[N]` that re-arms itself at the end of its own handler.
- **Guard gameplay input on `global.dialogActive`** so the player cannot act during cutscenes.
  Some existing code forgets to — that is a bug, not a pattern to copy.

## The dialog system

A small reusable cutscene system; each cutscene is its own object:

1. `scr_InitializeDialog1()` — called from the dialog object's `Create` event. Sets
   `global.dialogActive = true`, computes box/avatar/text layout, and clears the `dialog[]`
   2D array (100 rows of `[avatar sprite, text, sprite subimage]`).
2. A `convo_*` script fills that array via `scr_AddDialogLine(sprite, text, image_index)`.
3. `scr_DisplayConvoText()` — called every `Step`. Types the current line out one character
   per frame, then waits for `SPACE` to advance. Sets `finished = true` and clears
   `global.dialogActive` after the last line.
4. `scr_DrawDialog()` — called from `Draw`. Renders the box, avatar, and typed text.
5. The object's `Step` event checks `finished` and does the follow-up (start the game, set a
   tutorial flag, change room).

To add a cutscene: write a new `convo_*` script, then clone one of the `obj_dialog_*` objects
and point it at that script.

## Code quality expectations

The README says it plainly: the code is jam code. Expect duplicated blocks, commented-out
experiments, unused objects (`obj_egg` has no events), copy-paste bugs (e.g.
`obj_dialog_save_human` sets `global.attackTipDone`, which it has no business touching), and
malformed-but-tolerated GML such as the misplaced parentheses in `obj_player/Step_0.gml`'s
`keyboard_check` conditions.

When changing this project:

- Match the surrounding style; do not restyle files wholesale as a side effect of a fix.
- Keep gameplay-tuning constants where they already live (`Create` events or
  `RoomCreationCode.gml`) rather than introducing a new config layer.
- Changes cannot be verified without GameMaker Studio 2, so keep edits small and reason
  carefully about GML semantics — there is nothing here to run in CI.

---

## The Love2D rebuild — `love2d/`

The repository now contains a second, complete game: **BOTS: Save Us All — *Reforest***, a
full rebuild in **LÖVE 11.4 (Lua)** with **no external assets** — the island, the trees, the
robots, the display typeface and every sound are generated at runtime.

- **Design spec:** [`docs/REFOREST_SPEC.md`](docs/REFOREST_SPEC.md) — the single source of truth.
- **Project README:** [`love2d/README.md`](love2d/README.md) — controls, layout, tools.
- The GameMaker project at the repository root is the 2019 original and is left untouched.

### Working in `love2d/`

Two rules keep it coherent, and both are load-bearing:

1. **`src/game/tuning.lua` holds every gameplay constant.** Behaviour code has no magic numbers.
2. **`src/engine/palette.lua` holds every colour.** Draw code has no colour literals.

Everything is verifiable without a human at a keyboard, and you are expected to verify:

```bash
cd love2d
tools/check.sh                                    # luajit syntax check, must pass
BOTS_SCENE=src.scenes.demo_tree tools/shot.sh 300 100,300 /tmp/out   # any subsystem's demo
BOTS_AUTOPLAY=1 BOTS_SPEED=8 BOTS_SCENE=src.scenes.game \
  tools/shot.sh 24000 8000,16000,24000 /tmp/run   # a whole run + a CSV balance trace
BOTS_JUMP=night BOTS_JUMP_TREES=600 ...           # start a session late
BOTS_W=1280 BOTS_H=560 ...                        # a phone-landscape aspect
tools/build_web.sh build/web                      # hosted WebAssembly build (default)
tools/build_web.sh --single build/one.html        # one self-contained file, no server
node tools/serve.js build/web 8123                # serve it: streaming needs HTTP
NODE_PATH=/home/user/.toolchain/node_modules \
  node tools/webperf.js http://127.0.0.1:8123/index.html 20000 1280 720
```

### Hosting

The Love2D web build is the only thing this repository hosts. `vercel.json` at the root runs
`npm run build` (which is `love2d/tools/build_web.sh public`, the hosted multi-file shape) and
serves `public/`; `.vercelignore` keeps the GameMaker project out of the deployment. It is live at
<https://bots-save-us-all.vercel.app>. The build image has no LÖVE and no xvfb, so the audio and
tree bakes are skipped there and the hosted build is unbaked -- baking in CI would mean
committing the artifacts.

`tools/shot.sh` only renders the frames it photographs, so a full 20-minute session captures in
seconds. **Read the PNGs.** Nothing about this game can be judged from the source alone.

**Three traps in that harness**, each of which has produced a confident wrong number:

- The autoplay **trace** is not reproducible run to run on a contended machine — two identical
  runs ended at 466 and 250 trees. Do not A/B with it.
- The autoplay **capture** is not a valid pixel A/B: two runs of identical code differ on 96%
  of pixels by ±1, because the grade is wall-clock dependent, and after a few thousand frames
  the two runs are not even in the same game state.

  **What to use instead**, for a gameplay-rendering A/B: `BOTS_JUMP` with a fixed seed and a
  fixed identity reaches a matched late-game state in hundreds of frames rather than thousands
  of divergent ones, and two builds land on the same frame with the same dialogue line up.

  ```bash
  BOTS_IDENTITY=ab_a BOTS_SEED=12345 BOTS_JUMP=extraction \
    BOTS_JUMP_TREES=600 BOTS_JUMP_BOTS=40 BOTS_SCENE=src.scenes.game \
    tools/shot.sh 900 300,600,900 /tmp/ab_a
  ```

  Read the result as: ~66% of pixels differ by ±1 (the dither/grade floor, ignore it) and the
  signal is the count differing by **more than 10/255**. For reference, F1+F2+F4 against their
  baseline measured 0.022–0.045% over that threshold across three frames.
- Headless capture only calls `love.draw()` on photographed frames, so `Tree.setViewFromCamera`
  never runs and **every tree reports on-screen** — which silently invalidates any measurement
  of view-culling or anything else that depends on the camera.

### Two things that have bitten repeatedly

- **The browser is the ship target, and it is not the same renderer.** Bugs that reached the
  build and that native LÖVE never showed: a zero-length line segment that WebGL culls (every
  `U` rendered as a `J`), `string.format("%F")` (rejected by the WebAssembly Lua), unqualified
  shader precision (`highp` in the vertex stage, `mediump` in the fragment stage links on
  desktop GL and fails under GLSL ES), and — found while attempting the terrain GPU port —
  **`rgba8` canvases do not exist under love.js.** `getCanvasFormats()` there reports
  `depth16, hdr, normal, rgb565, rgb5a1, rgba16f, rgba4, srgba8, stencil8`; there is no
  `rgba8`, and `normal` resolves to **`rgba4` — four bits a channel**. Worse, requesting an
  unsupported format does not fail softly: LÖVE's "format is not supported by your graphics
  drivers" error **escapes `pcall`** inside love.js and takes the frame down. Any GPU pass
  that needs 8-bit channels must ask for `rgba16f` or handle four bits, and must not assume
  `pcall` will catch the failure.

  Two more, from the same attempt. `setBlendMode("replace")` alone is not enough for a data
  canvas — LÖVE rewrites `srcRGB` to `SRC_ALPHA` under the default `alphamultiply`, so packed
  RGB comes back scaled by the packed alpha byte; use `("replace", "premultiplied")`. And
  **`fract(sin(x) * 43758.5453)` noise cannot be ported to the GPU**: a float32 sine is
  granular at 6e-8, which times 43758 puts about one hash in two hundred on the wrong side of
  an integer, wrong by a whole unit. That is not a precision qualifier you can fix — it is the
  float32 floor. See `docs/PERFORMANCE_SPEC.md` item L2.

  Verify visual and shader work in `tools/build_web.sh` output, not only natively — and note
  that build is **multi-file** now and must be served over HTTP (`tools/serve.js`), because
  emscripten skips its streaming path for a `file://` URI.
- **Appending to a list while iterating it.** The entity sweep and the timer both compacted
  their arrays and left a hole where callbacks had appended. Both now slide new entries down;
  the same pattern will bite anywhere else it is repeated.
