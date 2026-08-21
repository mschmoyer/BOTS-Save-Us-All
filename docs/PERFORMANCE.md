# Performance

The browser is the ship target and it is a different machine from the one this
was written on: PUC Lua 5.1 with no JIT, inside WebAssembly, over WebGL, on one
thread. Numbers taken on the desktop build predict almost nothing about it.

## Where the frames actually go

Measured in real Chromium at 1280x720, night, 722 trees (411 visible), 48 bots:

**62.4 ms per frame and 1,566 GL draw calls — a 16 fps ceiling before the GPU
rasterises a single pixel.**

The clean split, taken at 854x480 by running the same scene twice, once with
every GPU entry point nulled:

| | ms/frame | draw calls |
| --- | --- | --- |
| Browser, full | 33.0 | 626 |
| Browser, Lua only | 17.0 | 0 |
| → WebGL submission | 16.0 | ~26 us per draw call |
| Native LuaJIT (JIT off), Lua only | 6.4 | — |

So it is **half interpreted Lua and half draw-call submission**, both on the
main thread. Browser Lua costs about 2.7x native-with-JIT-off, and far more
against JIT-on. Fill rate is a distant third on a desktop GPU and first on a
phone.

## What is NOT the problem

Measured, and ruled out. Do not spend time here:

- **Particles.** In real play the pool sits at 300-1,000, not the demo's
  stress-phase 7,800. Update plus draw is 2.9 ms of 33 — 9%.
- **Lighting CPU.** 27-54 lights a frame, correctly view-culled: 3 draw calls,
  0.25 ms. The enemy lights added in the night-visibility pass cost nothing.
- **The simulation.** 48 bots update in 0.34 ms; enemies in 0.08 ms. Everything
  in `World:update` outside the entity ticks is 1.3 ms of a 10.9 ms native
  frame.
- **Terrain, water, decals.** 0.6 ms and 7 draw calls combined. The baked
  canvases are earning their keep.
- **Post-processing CPU.** 0.23 ms, 10 draw calls. FXAA is off by default.

The instinct that it is "too many objects" points at the right place and the
wrong objects: it is not the count, it is that **a bot costs about ten draw
calls and a tree costs two**.

## The plan, in order of value per unit of risk

### Done

1. **`Draw.glow` baked to one quad.** It drew `layers` concentric additive
   quads and is called ~120 times a frame — every bot, enemy, deposit,
   projectile and lit prop sits on one. That was 417 of 1,178 draw calls.
   Additive blending is a sum and a sum does not care in what order it
   accumulates, so the layers are summed into the falloff once at build time.
   *Measured: 941 -> 741 draw calls on a fixed scene, max channel difference
   7/255 against the old image.*

2. **Browser light buffer capped at half resolution.** Settings default to
   "high", which is a 1:1 light canvas, and the boot-time auto-downgrade only
   fires at 2.2 megapixels — a 720p browser window is 0.92, so it never fired.
   Capped in the lighting module rather than by changing the preset, because
   the preset also governs particle density and post-processing. *Free on a
   desktop GPU; on the fill proxy the pass is 47.1 ms at 1:1 against 28.9 at
   half.*

### Next

3. ~~**Bake the bot bodies.**~~ **DONE, and this entry's premise was wrong.**

   The claim was that a bot's ~20 procedural primitives are "~450 draw calls",
   and that baking each hull to a `Mesh` would collapse them to one quad each:
   "entity draw calls 583 -> under 150".

   They are not ~450 draw calls. **LÖVE batches consecutive stream primitives**
   (`polygon`/`circle`/`line`) into one GL call with the colour folded into the
   vertices. A `Mesh` is never batched — it is its own draw call *and* it
   flushes whatever was accumulating. So the proposed fix was pointed the wrong
   way, and implementing it literally made things worse: on a fixed 24-bot
   probe, hull-to-`Mesh` measured **222 -> 288 draw calls**, with builder 8->12,
   harvester 6->12 and beacon 8->11. Only the planter improved, because its
   seedling blobs were already unbatchable `fillFan` meshes.

   What shipped instead keeps the batching and removes only the arithmetic:
   `Draw.bake` records a hull's colours and point lists once, and `Draw.replay`
   re-issues them through `lg.polygon("fill", pts)` every frame. The `cos`/`sin`
   never runs again; the batch survives.

   *Measured (seed 7, night, 735 trees, 48 bots, 1600x900): entity draw calls
   465.2 -> 420.2, total 1522.8 -> 1477.8. The real win is the Lua: entity draw
   with the GPU nulled and the JIT off, **3.19 ms -> 1.59 ms**, a 50% cut in the
   interpreter — which is the browser's currency. `demo_draw` is pixel-identical
   (0 of 1,440,000 pixels differ).*

   Two consequences worth carrying forward. **This is why item 8 is right**: mesh
   draws do not batch, so per-tree uniforms are not the only thing forcing a call
   per tree. And **the autoplay game capture is not a valid pixel A/B** — two
   runs of identical code differ on 96% of pixels by ±1, because the grade is
   wall-clock dependent. Use a fixed probe scene for pixel regression.

4. ~~**Drop contact shadows on small trees.**~~ **DONE, and the 40% was not
   reachable.** The estimate assumed a population of small trees that a mature
   forest does not have: at the end of a run essentially *every* visible tree
   draws a shadow, so taking 40% of the shadow fill would mean taking shadows
   off grown trees, which is the contact the shadow exists to sell.

   Swept on a 900-tree night scene, the threshold sits at **128 px** with a
   128→160 fade band (a pop at 128 px would be visible where one at 24 px never
   was; the ramp is free, those trees were already drawing). *Measured: shadow
   draw calls 479.3 -> 363.4 (−116, −24%, 7% of the frame's 1,628), shadow
   overdraw −17%. In-game picture cost: 798 of 1.44 M pixels move by more than
   10/255, all inside canopy shade.* 160 starts taking the shadow out from under
   trees standing alone on bare rock; 96 is the documented fallback.

   Note for anyone reading a `demo_tree` capture: that scene's FOREST phase sits
   at zoom 0.62, below the game's 1.16–1.25, so it renders almost no shadows now
   and its capture moves ~8% of its pixels. That is the LOD behaving correctly at
   a zoom the game never uses, not a regression.

5. ~~**Tick off-screen trees on a rota.**~~ **DONE — correct, but the 3.5 ms is
   not there.** Equivalence is proven: 240 trees parked off screen for 2,400
   frames accumulate growth at rates agreeing to 0.00004% and elder time to
   0.00000% between `sleepFrames` 1 and 4.

   The saving is not measurable on this scene — `treeUpdate` 1.677 -> 1.597 ms
   min-of-3, but −0.109/−0.080/+0.127 round by round, which is inside the noise.
   The reason is that the perf scene's forest is fully grown, and a grown,
   unbothered tree falls out of the block after a handful of instructions. Kept
   anyway: it is free, it is proven equivalent, and it makes the block scale with
   the view rather than with the forest.

   Also worth knowing: **the autoplay trace could never have tested this.** In
   headless capture `love.draw()` only runs on photographed frames, so
   `Tree.setViewFromCamera` is never called, `view` stays at its ±1e9 default,
   every tree reports `onScreen`, and the rota never engages.

6. ~~**One persistent visible list instead of two sweeps and a sort.**~~
   **DONE, and it is the real win of the three.** *Measured, Lua-only:
   `sortEtc` 1.247 -> 0.536 ms (−57%), `World:draw` 3.757 -> 3.048 (−19%),
   whole Lua frame 12.207 -> 11.445 (−6%).* At the 2.7x browser factor that is
   ~1.9 ms of the browser's 17 ms, against 3.0 predicted.

   `self.trees` order is deliberately untouched — the spread cursor draws from
   the shared RNG, so reordering it would move the run. A parallel `treesZ` is
   kept in depth order by binary-search insert at plant time.

   One trap worth recording: `t:isDone()` per tree per frame is a metatable
   lookup plus a call, and measured ~0.5 ms at 825 trees — it ate most of the
   win until the loop asked `t.alive` first.

7. **Per-frame allocation.** ~125 KB a frame with the GC stopped: ~50 KB in
   `World:update`, ~60 KB in `World:draw`, and zero in the entity paths — so it
   is container code, not entities. `Lighting.addLight(..., {flicker=...})`
   allocating an options table per light per frame is 5-7 KB of it.

### The one that actually reaches 60 fps

8. **Trees through a sprite atlas.** Each tree sends its own `uT` uniform, so
   LÖVE cannot batch the mesh draws: **visible tree count is the draw-call
   count, twice over.** Rendering the 250 mesh variants to an atlas once and
   drawing LOD-range trees through a `SpriteBatch` collapses the far forest to
   one call. *Risk: medium-high — sway becomes a per-sprite rotation rather
   than a vertex-shader displacement, and that is the forest's whole character.*

Items 3-6 take 62 ms to roughly 30 (16 fps -> ~33). Item 8 is the only route to
60 at 720p: there is no way to draw 400 individually-uniformed meshes a frame
through emscripten's WebGL inside the budget.

## Measuring it yourself

    tools/perf.sh                                         # draw calls and fill
    BOTS_PERF_NULLGPU=1 BOTS_PERF_NOJIT=1 tools/perf.sh   # the Lua half alone
    BOTS_DRAWCALLS=1 BOTS_SCENE=src.scenes.game tools/shot.sh 200 199 /tmp/dc
    BOTS_PERF=1 ...                                       # in-game readout

The capture harness renders only the frames it photographs, so wall-clock from
a capture is meaningless. Use the in-Lua timings. The test machine rasterises
through SwiftShader, so GPU-bound numbers there are pessimistic and CPU-bound
numbers are representative — always say which you are quoting.
