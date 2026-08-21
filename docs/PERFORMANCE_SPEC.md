# Performance Spec — the hosted web build

`docs/PERFORMANCE.md` is the *frame* budget: where the 62 ms go once the game is
running. This document is the *delivery* budget — everything between a player
clicking a link and the game being playable — plus the frame items that
`PERFORMANCE.md` left open.

The premise that makes this document possible: **the game is hosted now.** It no
longer has to be one file that runs from any URL with no server, and that single
constraint was buying us a 12.8-second parse, a rebuilt asset set on every visit,
and a runtime chosen for the lowest common denominator.

## Baseline

Measured today, from this branch, at `cf4db20`. Chromium 1194 under SwiftShader,
1280x720, `file://`, single-file build from `tools/build_web.sh`:

| Phase | Wall clock | How |
| --- | --- | --- |
| Document downloaded | 120 ms | `navigation.responseEnd` |
| **Document parsed** | **12,947 ms** | `navigation.domInteractive` |
| base64 → bytes (wasm + data) | 167 ms | `BOOTPHASE wasm-decoded` / `data-decoded` |
| Runtime linked, Begin appears | ~13,100 ms | `monitorRunDependencies(0)` |
| First rendered frame | ~28,100 ms | `BOOTPHASE first-frame` |
| Peak JS heap | 440.6 MB | `performance.memory` |

Payload: **7.00 MB on disk, 2.69 MB gzipped.**

Title screen steady state in the same browser: 416 draw calls/frame, 13.4 ms in
the rAF callback, 100.5 ms between frames.

Reproduce with:

```bash
love2d/tools/build_web.sh /tmp/web_base/index.html
NODE_PATH=/home/user/.toolchain/node_modules \
  node love2d/tools/webperf.js /tmp/web_base/index.html 20000 1280 720
```

SwiftShader makes GPU-bound numbers pessimistic and CPU-bound numbers
representative. Every figure above is CPU-bound. Say which you are quoting.

## Two corrections to the record

Both of these are load-bearing, and both contradict comments currently in the
tree. Fix the comments as part of the work.

**1. The 13 seconds is the JavaScript parser, not base64 decoding.**
`main.lua:102` says the build "spends thirteen seconds decoding a base64 wasm
blob". It does not. Decoding both blobs takes **167 ms**. The document is
downloaded at 120 ms and `domInteractive` does not fire until 12,947 ms: the cost
is Chromium parsing a 7 MB HTML document whose `<script>` contains a 6.3 MB
string literal. The decode loop at `web_shell.html:199` is not the problem and
optimising it would buy nothing.

This *strengthens* the case for splitting the build — a separate `.wasm` never
enters the JS parser at all — but it changes what success looks like. The
acceptance test is `domInteractive`, not decode time.

**2. The `-c` compatibility build is not an Asyncify build.**
`build_web.sh:12` passes `-c` and the two love.js runtimes differ by far less
than folklore suggests:

| | `love.wasm` | `love.js` | threads |
| --- | --- | --- | --- |
| `compat` | 4,720,726 B | 325,454 B | none |
| `release` | 4,746,105 B | 386,198 B | pthreads + `love.worker.js` |

The release wasm is *larger*, and neither contains meaningful Asyncify
instrumentation. The difference is pthreads and `SharedArrayBuffer`. So dropping
`-c` does **not** recover interpreter speed, and the 2.7x browser-Lua penalty
`PERFORMANCE.md` measures is simply PUC Lua 5.1 against LuaJIT's interpreter —
that gap is not addressable by changing build flags. What `release` actually buys
is `love.thread`, which is a different and narrower prize (see C3).

## Work items

Each item states the change, how it is proven, and what would make it fail.

### C — Container: how the game is delivered

**C1. Split the build into separate files.** *(the single biggest win)*

`tools/inline_web.js` folds `love.wasm` and `game.data` into the HTML as base64
string literals. Emit them as real files instead, and load the wasm with
`WebAssembly.instantiateStreaming` so it compiles during download. `game.data`
goes back to a normal fetch, which means the `fetchRemotePackage` patch at
`inline_web.js:16` can be dropped.

Keep `build_web.sh`'s single-file mode working — it is genuinely useful for
sharing a build over any dumb file host — but make multi-file the default.

- **Accept:** `domInteractive` < 500 ms; Begin appears in under 2 s; first frame
  strictly better than the 28.1 s baseline. No change to what is on screen.
- **Risk:** low. The IDBFS persistence patch (`inline_web.js:24`) must survive;
  it is independent of how the binary arrives.

**C2. Cache headers, compression, and a hosting note.**

Separate files can be cached individually and immutably. `love.wasm` is 4.7 MB
and changes only when the engine does — today it is re-downloaded on every visit
because it is glued to the HTML. Emit content-hashed filenames, document the
headers (`Cache-Control: immutable` for hashed assets, `no-cache` for the entry
HTML), and ship a brotli pass alongside the existing gzip figure.

- **Accept:** a second visit fetches only the entry HTML. Documented in
  `love2d/README.md`.
- **Risk:** low.

**C3. Evaluate the `release` (pthreads) runtime behind COOP/COEP.**

Hosting means we can set `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`, which is what `SharedArrayBuffer`
needs. Per correction 2 this is not a general speed-up — it is specifically an
attempt to get `love.thread` so audio synthesis can leave the main thread.

This is an **experiment, not a commitment**. Run it, measure it, and if
`love.thread` does not come up cleanly under love.js, write down that it does not
and close the item. Do not ship a runtime swap on hope.

- **Accept:** either a measured frame-time improvement with the bank synthesised
  off-thread, or a written negative result.
- **Risk:** medium. COOP/COEP breaks any cross-origin subresource — note that
  `web_shell.html:2` currently pulls Google Fonts, which would need `crossorigin`
  or self-hosting.

### L — Load: stop rebuilding deterministic assets on every visit

The rule that decides these: **bake what does not depend on the run seed; move
what does to the GPU.**

**L1. Bake the tree mesh library.**

`Tree.ensure(spi, variant, bucket)` keys on species, variant and growth bucket
only — no run seed anywhere (`tree.lua:779`). 5 species x 5 variants x 10 buckets
x 3 meshes = **750 meshes**, byte-identical on every machine and every run. The
warmup header measures this at 1.5 s in one burst and 26.4 s when sliced badly.

Serialise the vertex buffers at build time; load them instead of tessellating.

- **Accept:** `Warmup.report()` shows `trees=` near zero. Tree rendering is
  pixel-identical — compare `demo_tree` captures before and after.
- **Risk:** medium. The format must carry `extentY`/`extentR`/area metadata that
  `ensure` returns alongside the meshes, and it must version-check so a stale
  bake fails loudly rather than rendering wrong trees.

**L2. Generate the terrain fields on the GPU.**

`Terrain:_generate` walks a 426 x 301 grid — **128,226 cells** — each doing a
domain warp plus several fbm calls, each fbm 4-6 octaves of `sin`-based value
noise, in interpreted Lua. That is the `fields = 6.3 s` in the warmup header, and
it is millions of transcendentals on the main thread.

This one cannot be baked: the island is seeded per run and procedural islands are
the point. But the bake shader already consumes these fields as two RGBA8
textures (`terrain.lua:1226`), so the target format is unchanged — this is
porting the existing noise into a fragment shader and reading back, not a
redesign.

- **Accept:** `fields=` drops by an order of magnitude; islands for a fixed seed
  are visually equivalent. Exact float equality is *not* required and should not
  be asserted — GPU and CPU `sin` differ. Gameplay-relevant derived values
  (`landArea`, `landBox`, biome classification) must stay within tolerance.
- **Risk:** medium-high. CPU-side consumers sample these fields (`terrain.lua:1240`),
  so a readback is required and readback stalls are real. If the readback costs
  more than the 6.3 s it saves, keep the CPU path and say so.

**L3. Bake the sound bank.**

`audio.lua:2110`: **46 cues, 324 variants, 11.8 MB of SoundData, ~3 s of DSP with
a JIT, "most of half a minute" in the browser**, and a measured 21.4 s dead tab
before the streaming path was built.

Streaming fixed the *hang*, not the *cost*, and it has a live consequence.
`main.lua:264` gives the queue `STREAM_TARGET - frameCost`, clamped to
`STREAM_MIN = 0.002`. Every browser frame is already over the 1/30 target, so the
bank drains at 2 ms/frame — against ~30 s of remaining DSP that is **minutes** of
play before late cues exist. Boss and rig cues can still be unbuilt when the
finale asks for them: `Audio.play` degrades to silence and a queue-jump, which is
correct behaviour covering a real defect at the emotional peak of the game.

The bank is bit-for-bit deterministic and the codebase already guarantees it —
`jobSeed(key, variant)` plus a per-buffer `Synth.noiseSeed`, with the comment at
`audio.lua:2124` promising that queue reordering cannot change a sound. That
property is exactly what makes offline baking safe.

Render the bank at build time, ship Ogg Vorbis (`oggenc` is the encoder), decode
through stb_vorbis in wasm instead of interpreted Lua.

- **Accept:** every cue is available at first frame; `Audio.stats.loadTime` at
  runtime is ~0; added payload under 3 MB compressed. A/B the rendered bank
  against the synthesised one and confirm they match.
- **Risk:** medium. Keep `synth.lua` and the streaming path — they are how the
  bank is *authored* and the fallback if a bake is missing. Do not delete the
  generator to celebrate the cache.
- **Fallback if payload is judged too large:** cache the synthesised bank in
  IndexedDB after first run. IDBFS is already mounted and already patched to
  flush (`inline_web.js:24-43`), so first visit pays and no later visit does.

### F — Frame: the open items from `PERFORMANCE.md`

Restated here for sequencing; the analysis and the costings live in that
document and are not repeated.

- **F1. Bake the bot bodies.** ~450 draw calls, two thirds of entity draw Lua.
  Keep eye, antenna, load pips, boot unfold, bob, squash and speak live.
- **F2. Drop contact shadows on small trees.** 259 draw calls, 40% of tree
  overdraw, under a canopy anyway.
- **F3. Tick off-screen trees on a rota.** 3.5 ms of the browser's 17 ms of Lua.
  No visual change.
- **F4. One persistent visible list.** Removes two sweeps and a Lua-comparator
  sort. 3.0 ms.
- **F5. Per-frame allocation.** ~125 KB/frame, all in container code.
  `Lighting.addLight(..., {flicker=...})` alone is 5-7 KB.
- **F6. Trees through a sprite atlas.** The only route to 60 fps at 720p, and the
  one item that changes how the game looks: sway becomes a per-sprite rotation
  instead of vertex-shader displacement. **Requires a visual sign-off before it
  ships** — the forest's character is the game's whole power fantasy. If the
  captures look worse, the correct outcome is to not ship it and say why.

## Verification protocol

Nothing here is judgeable from source. Every item is proven the same way:

```bash
cd love2d
tools/check.sh                                     # gate: must pass, always
BOTS_SCENE=src.scenes.demo_tree tools/shot.sh 300 100,300 /tmp/out
BOTS_AUTOPLAY=1 BOTS_SPEED=8 BOTS_SCENE=src.scenes.game \
  tools/shot.sh 24000 8000,16000,24000 /tmp/run    # full run + CSV balance trace
tools/build_web.sh /tmp/web/index.html
NODE_PATH=/home/user/.toolchain/node_modules \
  node tools/webperf.js /tmp/web/index.html 20000 1280 720
```

**Read the PNGs.** A draw-call count that improved and a picture that changed is
a regression, not a win.

Rules that apply to every item:

1. **The browser is the ship target and it is not the same renderer.** Three bugs
   have already reached the build that native LÖVE never showed: a zero-length
   line segment WebGL culls, `string.format("%F")`, and unqualified shader
   precision. Verify visual and shader work in a web build, not only natively.
2. **`tuning.lua` owns gameplay constants; `palette.lua` owns colours.** A bake
   pipeline does not get to introduce a third config layer.
3. **Every generator stays.** Baking adds a cache in front of procedural code; it
   never replaces it. A missing or stale bake must fall back or fail loudly.
4. **A bake must be reproducible.** Same input, same bytes, checked in CI-ish
   fashion by rebuilding and diffing.

## Sequencing

C1 → C2 land first: they touch no game code, carry the largest measured win, and
make every later measurement cheaper to take.

L1 → L3 → L2 next, hardest last. F3 → F4 → F2 → F5 are low-risk frame work that
can proceed in parallel with the load items since they touch different files.
F1 is self-contained in `bot.lua`.

C3 and F6 are the two that may legitimately end in "we measured it and it is not
worth it". That is an acceptable outcome for both, provided the negative result
is written down here.
