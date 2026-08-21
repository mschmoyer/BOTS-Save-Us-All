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

Measured from this branch. Chromium 1194 under SwiftShader, 1280x720, median of
three runs, **with the webfont request failed fast** — see the trap below.

| | single-file (`file://`) | multi-file (HTTP) |
| --- | --- | --- |
| `navigation.responseEnd` | 124 ms | 20 ms |
| `navigation.domInteractive` | 969 ms | **224 ms** |
| Begin appears | 1,108 ms | **431 ms** |
| base64 → bytes | 150 ms | 13 ms |
| Payload | 7.00 MB (2.69 MB gzip) | 5.33 MB (2.12 MB gzip) |
| Payload on a *second* visit | 7.00 MB | **26 KB** |

Title screen steady state: 416 draw calls/frame, 13.4 ms in the rAF callback.
Peak JS heap 440 MB (single) / 412 MB (multi).

### The measurement trap, which cost us a wrong headline

`web_shell.html` used to load its webfonts through a **render-blocking**
`<link rel="stylesheet">` pointed at `fonts.googleapis.com`. On a machine with no
route to that host the browser waits out the connection timeout before parsing
the rest of the document, and every boot number absorbs it:

| | fonts unreachable | fonts failed fast |
| --- | --- | --- |
| `domInteractive` (single-file) | 12,947 ms | 969 ms |
| Begin appears (single-file) | 13,100 ms | 1,108 ms |

**The first draft of this spec quoted the left-hand column and blamed the
JavaScript parser.** It was measuring a third-party network stall. The parse is
real but it is ~750 ms, not thirteen seconds.

Two lessons, both now enforced in the tooling: measure with the font request
resolved or failed, never hanging (`tools/webperf.js` now navigates on `commit`
rather than `load`, so a hung subresource cannot silently enter the numbers);
and a boot measurement taken once, on one machine, with no A/B against a
changed variable is not a measurement.

Reproduce with:

```bash
cd love2d
tools/build_web.sh          /tmp/web_multi          # hosted, default
tools/build_web.sh --single /tmp/web_single/index.html
node tools/serve.js /tmp/web_multi 8123 &           # HTTP: streaming needs it
NODE_PATH=/home/user/.toolchain/node_modules \
  node tools/webperf.js http://127.0.0.1:8123/index.html 20000 1280 720
```

Serve it over HTTP, not `file://`: emscripten checks `isFileURI` before taking
its `instantiateStreaming` path, so a multi-file build opened as a file quietly
under-reports itself.

SwiftShader makes GPU-bound numbers pessimistic and CPU-bound numbers
representative. Every figure above is CPU-bound. Say which you are quoting.

## Two corrections to the record

Both of these are load-bearing, and both contradict comments currently in the
tree. Fix the comments as part of the work.

**1. The thirteen seconds was never base64 decoding, and it was mostly not the
build's fault at all.** `main.lua:102` says the build "spends thirteen seconds
decoding a base64 wasm blob before LÖVE exists at all". Decoding both blobs takes
**150 ms**. The thirteen seconds reproduces only when `fonts.googleapis.com` is
unreachable, and it is the render-blocking stylesheet, not the payload. With that
request failed fast the same single-file build reaches `domInteractive` in 969 ms.

The residual cost of inlining — parsing a 6.3 MB string literal — is real and
worth removing, but it is ~750 ms. Fix the comment in `main.lua` to say so, and
do not let anyone quote "thirteen seconds" for the payload again.

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

**C0. Stop blocking first paint on a third-party stylesheet.** — **DONE**

The webfont link in `web_shell.html` was render-blocking against a host we do not
control. Now `media="print"` with an `onload` promotion, so it is a non-blocking
fetch; every CSS var already named a real fallback stack, so the panel is legible
from first paint and merely gets nicer if the webfont arrives.

*Measured, with the font request never answered at all — the pathological case:
Begin at **490 ms**, `domInteractive` **287 ms**. The old shell in the same
conditions sat at 12.8 s.* This also unblocks C3: under COOP/COEP a cross-origin
stylesheet without CORP is refused outright, and the page now survives that
instead of hanging on it.

**C1. Split the build into separate files.** — **DONE**

`tools/inline_web.js` folds `love.wasm` and `game.data` into the HTML as base64
string literals. Emit them as real files instead, and load the wasm with
`WebAssembly.instantiateStreaming` so it compiles during download. `game.data`
goes back to a normal fetch, which means the `fetchRemotePackage` patch at
`inline_web.js:16` can be dropped.

Keep `build_web.sh`'s single-file mode working — it is genuinely useful for
sharing a build over any dumb file host — but make multi-file the default.

`tools/pack_web.js` writes an entry document plus content-hashed assets;
`tools/inline_web.js` keeps the single-file mode for a build you want to hand
someone on a USB stick. The shared patching lives in `tools/web_patch.js` so the
two modes cannot drift. `tools/build_web.sh` defaults to multi-file;
`--single` selects the old shape.

Emscripten needed no persuading: leaving `Module.wasmBinary` undefined puts it on
its own fetch path, which already uses `WebAssembly.instantiateStreaming`, and
both `love.wasm` and `game.data` resolve through one `Module.locateFile` map.

*Measured: `domInteractive` 969 → **224 ms**, Begin 1,108 → **431 ms**, entry
document 7.00 MB → **26 KB**. Title screen renders identically — same 416 draw
calls, screenshots compared.*

- **Risk:** low, and discharged. The IDBFS persistence patch survives (it is in
  `web_patch.js` now, applied in both modes).

**C2. Cache headers, compression, and a hosting note.** — **DONE**

Separate files can be cached individually and immutably. `love.wasm` is 4.7 MB
and changes only when the engine does — today it is re-downloaded on every visit
because it is glued to the HTML. Emit content-hashed filenames, document the
headers (`Cache-Control: immutable` for hashed assets, `no-cache` for the entry
HTML), and ship a brotli pass alongside the existing gzip figure.

Assets are written as `<stem>.<hash><ext>`, `build_web.sh` emits a `_headers`
file for Netlify/Cloudflare-style hosts, and `tools/serve.js` applies the same
rules locally so the claim is testable rather than asserted.

*A second visit fetches 26 KB instead of 7.00 MB: everything else is
content-hashed and served `immutable`.*

- **Risk:** low.

**C3. Evaluate the `release` (pthreads) runtime behind COOP/COEP.** — **DONE:
measured, and NOT adopted.**

It works. Dropping `-c` and serving with `Cross-Origin-Opener-Policy:
same-origin` + `Cross-Origin-Embedder-Policy: require-corp` gives a page where
`crossOriginIsolated` and `SharedArrayBuffer` are both live, the runtime boots,
and the title screen renders identically (410 draw calls against 414).

It is not faster. Two runs of each, same source tree, same host, 1280x720:

| | compat (`-c`) | release (pthreads) |
| --- | --- | --- |
| rAF callback, median | 18.6 / 24.8 ms | 25.1 / 36.9 ms |
| frame gap, median | 204 / 208 ms | 206 / 225 ms |
| first frame | 20.8 / 24.6 s | 24.1 / 28.0 s |

The variance under SwiftShader is wide enough that "release is slower" overstates
it; "no improvement, at a cost" does not. And the JS-heap drop it appears to show
(415 MB → 31 MB) is an artefact: the wasm memory moves into a `SharedArrayBuffer`,
which `usedJSHeapSize` does not count. Nothing was saved.

That is the expected result once correction 2 is taken seriously. The runtimes
differ by pthreads, and **the game does not call `love.thread` anywhere.** The
prize was never the runtime, it was moving audio synthesis off the main thread —
and L3 removes that work altogether rather than relocating it, which is strictly
better than betting on LÖVE's thread support surviving emscripten.

Not adopted. The cost is real and ongoing: COOP/COEP refuses any cross-origin
subresource without CORP, starting with the webfonts. Revisit only if something
genuinely needs a worker.

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

**L3. Bake the sound bank.** — **DONE**

*Measured: `Audio.load()` 3.581 s → 0.433 s native (verified independently of the
implementer, same 47 cues / 324 variants / 11.72 MB); `love.load` → first frame
13.1 s → 3.6 s in the hosted browser build. Payload +2.37 MB on disk, ~2.04 MB
gzipped — inside the 3 MB budget, so the IndexedDB fallback was not needed.*

Determinism was verified rather than assumed: two independent bake processes
produce 324 byte-identical WAVs, with `oggenc --serial` pinning the one
non-deterministic byte. A/B against the synthesized bank across all 324 variants:
0 length mismatches, mean coding error −20.15 dB, worst-case envelope delta 0.122
of peak on a noise cue where the error is phase rather than shape.

Both fallbacks are exercised and both were re-checked here: no bake →
synthesizes; fingerprint mismatch (md5 of `synth.lua` + `audio.lua`) → warns and
synthesizes. The bake is gitignored and regenerated by `build_web.sh` on every
build, which is what keeps it from going stale.

Two things worth knowing. **44% of the baked bytes are Vorbis setup headers** —
~2.8 KB × 324 files, not audio. Grouping variants per cue would recover ~0.75 MB
but needs a per-sample copy in Lua to slice the decode, which is the cost we are
avoiding; left alone deliberately. And `rig_intake`'s loop seam grew from 0.15%
to 1.9% of peak: judged inaudible (it plays at volume 0.0015 ramping up, and
`rig_core`'s own synthesized seam is larger) but it is a real measured
regression and **wants a listener with headphones at the finale**.

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
