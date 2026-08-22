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

7. ~~**Per-frame allocation.**~~ **DONE for everything reachable, and the
   "zero in the entity paths" was exactly backwards.**

   Re-measured before touching anything, with `tools/alloc.sh` (the allocation
   sibling of `tools/perf.sh`: same fixed scene, `collectgarbage("count")` around
   each pass, collector stopped for the window, JIT off so the numbers are the
   browser's). The total was right — **119.1 KB a frame** against the estimated
   125 — but the split was not. `World:draw`'s own container code allocates
   **0.2 KB**. Every remaining kilobyte was in code the containers *call*:

   | | before | after |
   | --- | --- | --- |
   | whole update | 48.9 | **3.0** |
   | whole draw (incl. HUD, lights) | 70.2 | **49.7** |
   | `World:update` | 48.2 | 2.7 |
   | — `updateSpread` | 24.4 | 0.0 |
   | — bot updates | 20.5 | 1.7 |
   | `World:draw` | 47.7 | 28.9 |
   | — bot draw | 26.0 | 26.0 |
   | — cobalt draw | 17.8 | 1.0 |
   | `World:emitLights` | 6.9 | 5.2 |
   | HUD | 8.1 | 8.1 |

   Two allocators produced most of it, and neither is a container.

   **`Spatial:nearest` built a closure per call: 0.32 KB, ~106 calls a frame,
   ~34 KB — the single largest allocator in the game.** A closure is not one
   object: every captured local is boxed separately, and that visitor captured
   five. It walks the grid longhand now, in `each`'s exact cell order so ties
   resolve identically. The `nearest` filters in `world.lua` were the same
   mistake one level up (`beaconAt` alone is 73 calls a frame) and are now one
   shared function each, with the couple of parameters they need in module
   slots; the two entry points that pass a caller's own filter through save and
   restore that slot, because such a filter may query the world itself.

   **`P.shade` returns a fresh table, and the draw code asks it for constants.**
   A cobalt deposit resolved twenty of them a frame at ramp positions that never
   change, the player a dozen, the rig six. They are resolved once now — module
   constants where the position is a literal in one place, a tiny cache on the
   `suit()`/`bare()`/`metal()` helpers where a dozen call sites each pass their
   own literal. `Lighting.addLight`'s options tables went the same way: it reads
   the table and copies out, so a constant `{ flicker = 0.04 }` can be a
   constant, which is what `demo_light.lua` was already doing.

   *Measured, Lua only (GPU nulled, JIT off), six interleaved A/B rounds because
   this machine's per-round spread (7.74–9.01 ms on the same code) is wider than
   the effect: whole frame **min 7.738 → 7.187 ms (−7.1%)**, mean 8.447 → 7.876,
   and the new side is lower in 6 of 6 paired rounds; `sim` min 3.979 → 3.658
   (−8.1%). At the 2.7x browser factor that is ~1.5 ms of the browser's 17 ms
   Lua half.*

   The picture is unchanged and so is the run: a deterministic capture probe
   (the game with the clock nailed to the frame counter, because the grade reads
   the wall clock and the ordinary capture cannot be diffed) is **byte-identical
   before and after** at frames 150/300 of a 900-tree night and at frames
   500/1000/1500 of a different seed — which also means 1,500 frames of
   simulation went through the rewritten spatial queries and landed on the same
   world.

   **52.7 KB a frame is left, and 33 of it is `bot.lua`** — 26 KB of
   `P.shade` and friends in `Bot:draw`, 5 KB of `{ flicker = 0.03 }` in
   `Bot:emitLight` (the very tables this item named), 1.7 KB in `Bot:update`.
   Every one takes the same two-line fix applied to the cobalt, the player and
   the rig. The other 8 KB is `Text.display`, which concatenates a six-part
   cache key on every string it draws; that one wants the type cache
   restructured, which is its own item and its own risk. The last ~11 KB is
   spread thin: no remaining single site is worth a kilobyte.

### The one that actually reaches 60 fps

8. ~~**Trees through a sprite atlas.**~~ **BUILT AND MEASURED. NOT SHIPPED —
   it is behind `TUNE.atlas` (`BOTS_TREE_ATLAS=1`), default OFF, and it needs a
   human to look at the pictures and at one number the item never costed.**

   The draw-call premise was right and the win is the biggest on this list.
   *Measured on the standard 723-tree night island at 1600x900: total draw calls
   **1263 -> 473**. Tree canopy 462.0 -> 22.6, tree shadow 336.5 -> 6.5, and
   entity draws fall 402.2 -> 379.5 for free, because the tree meshes were
   flushing the entity batches too.*

   **And the browser frame did not get faster.** Real Chromium, 1280x720,
   `BOTS_JUMP=night`, 600 trees, 40 bots, three 240-second runs taken strictly
   one at a time on an otherwise idle machine:

   | | GL draw calls | uniform uploads | rAF callback |
   | --- | --- | --- | --- |
   | mesh (shipped) | 1142 | 2007 | **76.6 ms** |
   | atlas, canopy + shadow | 439 | 457 | **80.0 ms** |
   | atlas, canopy only | 728 | 1053 | **79.2 ms** |

   **703 fewer draw calls and 1,550 fewer uniform uploads bought nothing.** The
   reason is a cost this item never named: **a mesh rasterises its own triangles
   and a sprite rasterises its whole rectangle**, so tree fill goes **20.2 ->
   46.5 screens a frame** — the shadow silhouette is the worst of it, 7.1 ->
   25.7, because it is a sparse shape in a quad that the sun's shear then
   stretches. This machine rasterises through SwiftShader, where fill is the
   entire budget, so it reads the trade at its worst; on a desktop GPU 26 extra
   screens at 720p is a fraction of a millisecond and the draw calls would be
   the whole story. **Nobody has run this on a real GPU. That is the measurement
   the decision needs, and it is not in this document.**

   It does not pay for itself in Lua either. GPU nulled and JIT off, two
   interleaved rounds: whole frame 8.932/9.141 (mesh) against 8.707/9.561
   (atlas) — noise, and lower on each side once. The tree passes themselves move
   consistently the wrong way: `treeDraw` 0.610/0.584 -> 0.758/0.819 ms and
   `treeShadow` 0.338/0.348 -> 0.340/0.394, so **about +0.25 ms of interpreted
   Lua**, and that is with `SpriteBatch:add` nulled out by the profiler, so the
   true figure is higher.

   Note also what this does to the model at the top of the page. If WebGL
   submission were really ~16 ms of a 33 ms frame at ~26 us a call, deleting 703
   calls should have been worth most of a frame. It was worth zero. Either the
   per-call figure does not hold at this scale or the fill exactly ate it; the
   fill measurement says the latter, but the two are in tension and somebody
   should say which on hardware that rasterises.

   The picture changes, and by two orders of magnitude more than anything else
   here. *Deterministic A/B, seed 12345, `BOTS_JUMP=extraction` and `night`,
   frames 300/600/900: **5.6-7.0% of pixels move by more than 10/255**, against
   0.022-0.045% for F1+F2+F4 combined.* Two things cause it and both are in the
   captures:

   - **Sway stops being a bend.** The shader displaces every vertex by
     `sway * h * h`, so the foot of the trunk never moves and the crown swings.
     A sprite gets one linear transform. It is a shear about the root rather
     than a rotation, which keeps the crown's blobs upright and the tree's
     height honest, but the trunk still leans as a straight pole. Using a
     rotation instead measured 9.5% of pixels rather than 6.8%.
   - **Resolution.** A cell is `atlasCell` px; at the game's zoom a grown tree
     is 250-300 px, so a 128 px cell is a 2x blow-up and the near forest reads
     as blurred. 256 fixes it and costs **168 MB of VRAM** against 40 MB — the
     browser has no `rgba8`, so the page has to be `rgba16f` at 8 bytes a pixel.

   **The hybrid the item suggested cannot pay.** Batching only trees below a
   screen-pixel threshold, sweeping the threshold on that same scene:
   64 px -> 1259 draw calls, 96 -> 1206, 128 -> 1168, 200 -> 852, all -> 473.
   It is the same finding as item 4's: **a mature forest has no small trees**,
   and the trees the atlas would have to leave alone for sway's sake are exactly
   the ones that own the draw calls.

   Also carried, all visible in `/tmp/f6_png`: a batched tree can sort one depth
   band out of order against a bot (a lamp bot goes behind foliage it was in
   front of); the crown shadow loses its internal structure because the page
   pre-composites the shadow mesh's translucent blobs instead of stacking them
   per fragment; elders lose their gold rim; and the page is re-baked when the
   sun turns (5 times over 244 frames of night, 31 ms each natively).

   With the switch OFF the picture is the shipped one: against the file before
   this item existed, 0.010-0.020% of in-game pixels differ by more than 10/255,
   inside the same floor F1/F2/F4 measured.

Items 3-6 take 62 ms to roughly 30 (16 fps -> ~33). Item 8 was the only route to
60 at 720p on the draw-call side, and it delivers there — but it buys the draw
calls with fill, and until somebody measures it on a real GPU rather than a
software rasteriser, "the only route to 60" is a claim the numbers do not yet
support.

## Measuring it yourself

    tools/perf.sh                                         # draw calls and fill
    BOTS_TREE_ATLAS=1 tools/perf.sh                       # ...with item 8 on
    BOTS_TREE_ATLAS_CELL=256 BOTS_TREE_ATLAS_PX=220 ...   # ...its two knobs
    BOTS_TREE_ATLAS_SHADOW=0 ...                          # ...canopy only
    tools/alloc.sh                                        # KB allocated per pass
    BOTS_ALLOC_T2=1 tools/alloc.sh                        # ...and who it calls
    BOTS_PERF_NULLGPU=1 BOTS_PERF_NOJIT=1 tools/perf.sh   # the Lua half alone
    BOTS_DRAWCALLS=1 BOTS_SCENE=src.scenes.game tools/shot.sh 200 199 /tmp/dc
    BOTS_PERF=1 ...                                       # in-game readout

The capture harness renders only the frames it photographs, so wall-clock from
a capture is meaningless. Use the in-Lua timings. The test machine rasterises
through SwiftShader, so GPU-bound numbers there are pessimistic and CPU-bound
numbers are representative — always say which you are quoting.
