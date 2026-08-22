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

**L1. Bake the tree mesh library.** — **DONE, and it is half the win the item
assumed.** The tessellation goes away; the 750 GL buffer creations do not.

`Tree.ensure(spi, variant, bucket)` keys on species, variant and growth bucket
only — no run seed anywhere. 5 species x 5 variants x 10 buckets = 250 cells and
**750 meshes / 247,897 vertices**, byte-identical on every machine and every run.
`tools/bake_trees.sh` runs the tessellator once at build time through
`tools/treebakescene.lua` and writes one blob of the exact bytes the vertex
buffers want, plus a manifest carrying `extentY`, `extentR` and the three
triangle areas — the metadata `ensure` returns that no vertex buffer holds.
`build_web.sh` bakes it alongside the sound bank; the loader is in `tree.lua`
beside the tessellator, which stays as the reference implementation and the
fallback.

*Measured. Native `Tree.prewarm()` **325 → 53 ms** (min of five). Native
`Warmup.report()` `trees=` **402 → 42 ms** (min of three; medians 767 → 110, the
spread is the machine). In the hosted browser build, Chromium 1194 under
SwiftShader at 1280x720 over HTTP, one uninterrupted `Tree.prewarm()`:
**2,872 → 1,274 ms** (min of three; medians 4,849 → 1,725).*

**The half that remains is not Lua, and no bake can remove it.** Timed inside
the browser, a 3,399 ms baked load is **1,723 ms in `newMesh` and 1,493 ms in
`setVertexMap`** — 750 GL buffer objects created one at a time through
emscripten. Reading the 12.5 MB blob out of the `.love` is 70 ms, slicing 1,500
`ByteData`s out of it is 15 ms, and `setVertices` is 7 ms. The data was never
the cost. What is left is the same per-mesh GL price that makes a visible tree a
draw call, which is **F6's prize, not this one's** — and it is a third piece of
independent evidence for F6.

*Payload: the blob is 12.54 MB (4.70 MB gzipped) plus a 51 KB manifest, and the
hosted build's first visit goes **7.43 MB → 12.14 MB on disk, 4.17 → 8.71 MB
gzipped**. It is inside content-hashed `game.data`, so it is a first-visit cost
only. Whether that trade is worth ~1.6 s of browser load is a judgement someone
should make deliberately: `BOTS_SKIP_TREE_BAKE=1 tools/build_web.sh` ships
without it and the game tessellates as it always has.*

*Pixel-identical: `demo_tree` frames 100 and 300, baked against tessellated,
**0 of 1,329,600 pixels differ** outside the two HUD bands that print wall-clock
timings — and a control run of the tessellator against itself differs on 62
pixels inside those same bands, so the bake is closer to the reference than the
reference is to itself. Reproducible: two bakes of the same tree are
byte-identical in both files (`md5 1e3fdb27…` / `2c2b63be…`).*

All four fallbacks were exercised, not assumed: no manifest → tessellates
silently; `version` mismatch, `md5(tree.lua .. palette.lua .. util.lua)`
mismatch, and a truncated blob → each prints why and tessellates;
`BOTS_TREE_BAKE=1` turns all of them into an error for a build script.
`BOTS_TREE_BAKE=0` forces the tessellator, which is how the A/B above was taken.

- **Risk, discharged:** the format carries the metadata and version-checks three
  ways. Two things worth knowing for anyone touching it: raw index data handed
  to `Mesh:setVertexMap(Data, type)` is **0-based**, where the table form is
  1-based; and adding a field to a demo scene's HUD string moves ~20 antialias
  pixels elsewhere on the frame, because a new glyph repacks LÖVE's font atlas.
  That cost an hour of chasing a phantom regression — leave `demo_tree`'s HUD
  alone, it is a reference probe.

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

**L2: measured, and NOT SHIPPED. The CPU generator stays.** The blocker is not
the readback and not the load — it is that this noise cannot be reproduced in
32-bit float at all.

*Baseline, re-measured.* `fields = 9,744 ms` single-file over `file://`,
`10,709 ms` in the hosted multi-file build over HTTP (Chromium 1194, SwiftShader,
1280x720) — worse than the 6.3 s in the warmup header, not better. Natively it is
709 ms: 500 ms in the noise loop, 136 ms in `_scars`, 27 ms in `_classify`,
35 ms in `_buildFields`. **25.8 million `sin` calls**, 69% of the loop's LuaJIT
time.

*The shader works.* The argument reduction is the interesting part and it is
solved: `x*127.1 + y*311.7 + s*74.7` is `(x*1271 + y*3117 + s*747)/10` with all
three inputs integers, so the numerator is an exact integer below 2^24 (measured
worst case 4.6e6) and survives float32 intact. Split it into four 6-bit digits,
reduce each modulo 2π with a Cody-Waite pair chosen so every product and
difference is exact, and evaluate sin/cos from a Taylor pair on [-π/4, π/4]
rather than the hardware's (GLSL ES only promises `sin` to 2^-11 absolute, which
times 43758 is pure noise). Measured against the Lua hash over 65k lattice
points: **mean error 0.0012, max 0.0057** — the float32 floor. The full field
pass then ran in **~90 ms natively including readback and decode, against 500 ms
of Lua**, and the same trick took `_scars` from 136 ms to 20 ms.

*And it still generates a different island.* The hash's last step is
`fract(sin(A) * 43758.5453)`, and `fract` is discontinuous. A float32 sine is
granular at 6e-8; times 43758 that is 0.0026 of pre-fract value, so **about one
hash in two hundred lands the wrong side of an integer** and comes back wrong by
a whole unit rather than by a rounding error. At ~200 hashes per cell that is
roughly one wrapped lattice point per cell, and a wrapped point in a low octave
takes a whole bay with it. Seed 31337, GPU against CPU: **1.9% of cells changed
land/water, `landArea` +4.5% (3,099,840 → 3,240,576), `landBox` moved 104 units
(432,128,2064,2120 → 328,120,2160,2128)**, and the `demo_terrain` captures are
plainly not the same island — the western shore moves several hundred world
units. Seed 12345 happened to land well (`landArea` +0.15%, `landBox` identical);
seeds 777, 424242, 1, 500000 and 31337 did not. Per-seed luck is not a result.

Closing the gap means the sine to ~1e-11 — software double-float through the
reduction, the polynomial *and* the final multiply, in a language that does not
promise IEEE single precision to begin with. Estimated 4-6x the shader cost for
a browser win of maybe 3-5x, not the order of magnitude asked for. Not worth it.

*Two things worth keeping from the attempt, both browser-only:*

1. **`rgba8` canvases do not exist in the web build.**
   `love.graphics.getCanvasFormats()` under love.js reports `depth16, hdr,
   normal, rgb565, rgb5a1, rgba16f, rgba4, srgba8, stencil8`. No `rgba8`, and
   `normal` resolves to **rgba4** — four bits a channel, 2 bytes a pixel. Worse,
   asking for `"rgba8"` does not fail softly: LÖVE's "format is not supported by
   your graphics drivers" error escapes `pcall` inside love.js and takes the
   frame down on the title screen. Any GPU pass here must use the default format
   and expect four bits, or `rgba16f`, and must not assume `pcall` will save it.
2. **The readback is cheap and was never the risk.** 426x301 in the hosted build
   under SwiftShader: `Canvas:newImageData` **23 ms** warm (132 ms on the first
   call), `getString` 1 ms, the whole round trip well under 1% of what it would
   save. Natively it is 0.8 ms plus 7.5 ms to decode. If someone finds a way to
   reproduce the hash, the transport is not what will stop them.

Also worth recording for whoever picks this up: `setBlendMode("replace")` is
**not** enough for a data canvas. LÖVE rewrites `srcRGB` to `SRC_ALPHA` whenever
the alpha mode is the default `alphamultiply`, so packed RGB comes back scaled by
the packed alpha byte. It must be `setBlendMode("replace", "premultiplied")` —
which is a live bug waiting in `_bakeCoroutine`'s shore-distance pass if its
alpha ever stops being 1.

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

- **F1. Bake the bot bodies.** — **DONE, premise corrected.** The "~450 draw
  calls" in `PERFORMANCE.md` was wrong: LÖVE batches consecutive stream
  primitives, and a `Mesh` is never batched, so the prescribed fix measured
  *worse* (222 → 288 draw calls on a fixed probe). What shipped records the
  hull's point lists once and replays them through `lg.polygon`, keeping the
  batch and dropping the per-frame `cos`/`sin`. *Entity draw calls 465 → 420;
  entity draw Lua, GPU nulled and JIT off, **3.19 ms → 1.59 ms**. `demo_draw`
  pixel-identical.* Full write-up in `PERFORMANCE.md` item 3.

  Two by-products worth keeping: this is independent evidence for F6 (mesh draws
  do not batch), and **the autoplay capture is not a valid pixel A/B** — two runs
  of identical code differ on 96% of pixels by ±1 because the grade is
  wall-clock dependent. Use a fixed probe scene.

  Carried risk: planter seedling sway became a shear about the root rather than a
  translate of the tip (~0.5 px slant on a ~3 px leaf), and baked circles use a
  scale-independent segment count, so a large zoom shows a coarser disc. Both
  documented in the code; both invisible at play scale.

  **Verified on the ship target.** The whole item rests on a renderer behaviour,
  so it was re-measured in the browser rather than assumed: a probe drawing 100
  consecutive `lg.polygon` fills and then the same 100 shapes as meshes reports
  **polygons=1, meshes=100 draw calls — identically under native GL and under
  WebGL.** The batching holds, and the `Mesh` approach the item prescribed would
  have been worse in the browser too.
- **F2. Drop contact shadows on small trees.** — **DONE at 128 px**, with a
  128→160 fade band. *Shadow draw calls 479 → 363 (−24%), shadow overdraw −17%,
  798 of 1.44 M in-game pixels moved.* The item's "40% of the overdraw" was not
  reachable: a mature forest has no population of small trees, so 40% would mean
  taking shadows off grown trees.
- **F3. Tick off-screen trees on a rota.** — **DONE, and honestly a null
  result.** Equivalence proven to 0.00004% on growth rate over 2,400 frames, but
  the predicted 3.5 ms is not measurable — a grown, unbothered tree leaves the
  block after a handful of instructions. Kept because it is free, proven, and
  makes the block scale with the view rather than the forest.
- **F4. One persistent visible list.** — **DONE, and the real win of the three.**
  *`sortEtc` 1.247 → 0.536 ms (−57%), whole Lua frame −6%.*

Three measurement traps came out of this batch, all now recorded in
`PERFORMANCE.md`: the autoplay **trace** is not reproducible run to run on a
contended machine (two identical runs ended at 466 and 250 trees); the autoplay
**capture** is not a valid pixel A/B (±1 on 96% of pixels, the grade is
wall-clock dependent); and headless capture only calls `love.draw()` on
photographed frames, so `Tree.setViewFromCamera` never runs and **every tree
reports on-screen** — which would have silently invalidated any view-culling
measurement taken that way. Use a deterministic probe scene.

**Found, not fixed** — worth its own item. `World:draw` gates both tree passes on
`t.alive`, and `Tree:kill` clears `alive` immediately, so a felled tree's topple
animation and `Tree:drawStump` never render in gameplay. Pre-existing, preserved
deliberately so "no visual change" held for F4.
- **F5. Per-frame allocation.** — **DONE, and "all in container code" was
  wrong.** The 125 KB estimate was close (119.1 KB measured), but `World:draw`'s
  own container code allocates **0.2 KB** of it: the garbage is in what the
  containers call. Two allocators dominated — `Spatial:nearest` building a
  five-upvalue closure per call (0.32 KB × ~106 calls = ~34 KB, the largest
  single allocator in the game), and `P.shade` returning a fresh table to draw
  code that asks it for constants (37 KB over 366 calls, twenty of them in one
  cobalt deposit). *Measured: **119.1 → 52.7 KB/frame**, update 48.9 → 3.0.
  Lua-only frame min 7.738 → 7.187 ms (−7.1%) over six interleaved rounds, lower
  in 6 of 6 — the per-round spread on this machine is wider than the effect, so
  the pairing is the evidence. A deterministic capture probe is byte-identical
  before and after over 1,500 frames of simulation.* Full write-up in
  `PERFORMANCE.md` item 7. **33 KB a frame is left in `bot.lua`** (including the
  `{flicker=...}` tables this item named) and 8 KB in `Text.display`'s cache-key
  concatenation; the bot fixes are the same two lines already applied to the
  cobalt, the player and the rig.
- **F6. Trees through a sprite atlas.** — **BUILT AND MEASURED, NOT SHIPPED.
  It is behind `TUNE.atlas` / `BOTS_TREE_ATLAS=1`, default OFF, and the visual
  sign-off this entry asked for has not happened.** The full write-up is
  `PERFORMANCE.md` item 8; the short version is three numbers.

  *Draw calls, the prize: **1263 -> 473** natively on the 723-tree night island,
  **1142 -> 439** in the browser at 720p, with uniform uploads 2,007 -> 457.
  Tree draw calls specifically go 798 -> 29.*

  *Frame time, the point of the exercise: **it did not move.** Three 240-second
  Chromium runs taken one at a time on an idle machine — mesh 76.6 ms, atlas
  80.0 ms, atlas-canopy-only (728 calls) 79.2 ms. Seven hundred fewer draw calls
  and fifteen hundred fewer uniform uploads bought nothing measurable.*

  *Fill is why, and it is the cost the item never costed: **20.2 -> 46.5 screens
  a frame**. A mesh rasterises its triangles; a sprite rasterises its rectangle.
  This machine rasterises through SwiftShader, where fill is the entire budget,
  so it reads the trade at its worst; on a desktop GPU those 26 screens are
  noise and the draw calls would be the whole story. **Nobody has run this on a
  real GPU, and that is the measurement the decision needs.***

  *Picture: **5.6-7.0% of pixels move by more than 10/255** on the deterministic
  jump A/B, against 0.022-0.045% for F1+F2+F4 together. Sway becomes a shear
  about the root — chosen over the rotation this entry predicted, because the
  shader's bend is a pure sideways displacement and so is a shear; the rotation
  measured 9.5% instead of 6.8%. The other half is resolution: a 128 px cell is
  a 2x blow-up of a near tree, and the 256 px cell that fixes it costs 168 MB of
  VRAM instead of 40, because love.js has no `rgba8` and the page must be
  `rgba16f`.*

  **The hybrid this document and PERFORMANCE.md both proposed does not pay.**
  Sweeping the screen-pixel threshold: 64 px -> 1259 draw calls, 96 -> 1206,
  128 -> 1168, 200 -> 852, unbounded -> 473. Same shape as F2's finding — a
  mature forest has no small trees, and the trees whose sway is most legible are
  exactly the ones holding the draw calls.

  With the switch off, the game is byte-for-byte the shipped picture within the
  usual floor (0.010-0.020% over 10/255).

## Open, and deliberately not closed here

**Green streak artifacts, seen once, not reproduced.** A 12,000-frame autoplay capture at
seed 12345 showed long horizontal green bands and thin diagonal lines across the lower
screen, in a late-game dialogue state. It is recorded here rather than dismissed, because it
was real and nobody has explained it.

What was then established:

- A second capture of the *same build at the same seed* is clean at frames 3,000 / 6,000 /
  9,000 / 12,000, including a frame in the same kind of state (ending dialogue, camera pulled
  back, bot labels up).
- A **matched deterministic A/B** — `BOTS_JUMP=extraction`, fixed seed and identity, the two
  builds landing on the same frame with the same dialogue line — is clean on both sides at
  300 / 600 / 900. Difference over 10/255: **0.022–0.045% of sampled pixels**, consistent with
  F2's shadow tips and nothing else.

So F1/F2/F4 are cleared *for the states that can be reached deterministically*, which is not
the same as cleared. The honest position is that this is an unreproduced one-off in a state
nobody can currently re-enter on demand.

**The gap it exposes is the real finding.** The first instinct — capture the same seed before
and after — is worthless here, because autoplay runs diverge into different game states
entirely. There is no fixed probe for *gameplay* rendering the way `demo_tree` and `demo_draw`
are fixed probes for their subsystems, and every visual claim about gameplay in this document
rests on either a deterministic jump state or an agent's own probe scene. A committed probe
scene that parks a known set of entities, weather, time of day and dialogue in front of the
camera would make this class of question answerable in seconds. **Worth its own item.**

**Also found, unfixed** (see the F2/F3/F4 entry): `World:draw` gates both tree passes on
`t.alive` and `Tree:kill` clears `alive` immediately, so a felled tree's topple animation and
`Tree:drawStump` never render in gameplay.

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

F6 has now ended in neither: it is built, it works, it is switched off, and the
number that decides it — the frame cost of 26 extra screens of overdraw on
hardware that is not a software rasteriser — has not been taken. See the F6
entry above.
