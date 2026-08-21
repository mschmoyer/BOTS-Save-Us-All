# BOTS: Save Us All — *REFOREST*
### Master design & engineering spec for the Love2D rebuild

> This is the single source of truth. Every module owner reads this file before writing code.
> It supersedes nothing in `docs/GAME_DESIGN.md` — that document describes the 2019 GameMaker
> jam original, and is the *narrative and thematic* source we are honouring. This document
> describes the new game.

---

## 0. One-line pitch

*You are the last human alive. You cannot fight. You build small machines that can — and by the
end of the night you will care whether they come back.*

---

## 1. Pillars

| Pillar | What it means in code |
| --- | --- |
| **Growth is the verb** | The player's power fantasy is a forest filling the screen. Every system must make growth legible and gorgeous: trees grow *geometrically over time*, canopies knit together, the sky and grade shift as O₂ climbs. |
| **The bots are people** | Every bot has a generated name, a personality line, idle chatter, a boot-up animation and a death that costs you something. Downed bots can be *carried* to a Beacon and revived. |
| **You are fragile** | The player has 2 offensive verbs (shove, pulse) and 1 movement verb (dash). You never out-damage the swarm; you *reposition* and *protect*. |
| **The victory is hollow** | The ending is not a celebration. Keep the 2019 punchline and give it room to breathe. |
| **Everything is procedural** | Zero external art or audio assets. Terrain, trees, bots, UI, the display typeface and every sound are generated at runtime. This is a hard constraint *and* the visual identity. |

---

## 2. Structure of a run

A run is **7 Cycles**, ~25–35 minutes, one continuous island. No level loads.

```
TITLE → PROLOGUE (cutscene) → [ DAY → DUSK → NIGHT → DAWN DRAFT ] × 7 → EXTRACTION (boss) → ENDING
```

| Phase | Length | Player does |
| --- | --- | --- |
| **Day** | 75–95 s (grows per cycle) | Harvest cobalt, place bots, hand-plant saplings, rescue/repair bots, explore. Safe. |
| **Dusk** | 12 s | Telegraphed. Rift edge highlighted, siren, sky bruises. Last build window, UI countdown. |
| **Night** | 55–100 s | Blight waves. Defend trees and bots. Shove/dash/pulse. Sentries fire. Beacons glow. |
| **Dawn** | — | Tally: trees gained/lost, O₂ delta, bots lost (**by name**). Draft 1 of 3 **Chips**. |
| **Extraction** | ~3 min | Harvester Prime boss, 3 phases. **Boss max HP = number of living bots** (inherited from the original). Bots rebel at phase 2 and charge it. |

**O₂ %** is the campaign meter, target `O2_TARGET`. It rises with living trees and falls when Siphons feed. It gates the ending, drives the colour grade, the music layers and the sky.

---

## 3. Player

| Verb | Input (KB / Pad / Touch) | Feel notes |
| --- | --- | --- |
| Move | WASD·Arrows / L-stick / L-stick pad | Acceleration + friction, 8-way blend, footstep puffs, grass parting, lean-into-velocity tilt. |
| **Dash** | Space / ✕ / A-button | 0.16 s, i-frames, 5 afterimages, radial dust ring, slight time-dilation on the frame it starts, cooldown ring under the player. |
| **Shove** | E·LMB / ▢ / B-button | 100° arc, 78 px, knockback + **hitstop 60 ms** + shake + a white flash on struck enemies. 0.28 s cooldown. |
| **Pulse** | Q·RMB / R2 (hold) / hold button | Charge 0.9 s, radial shockwave with a distortion shader ring, staggers everything in 190 px. Costs 8 cobalt. |
| Hand-plant | F / △ / button | Places a sapling at the player. Costs 3 cobalt. Ties the player into the growth loop. |
| **Carry bot** | auto on touch / hold | Downed bots are carried at reduced speed; drop one inside a Beacon radius to revive it. |
| Build | 1–6 / D-pad+R1 / radial | Radial build menu, holds time at 0.25× while open (never fully pauses — keeps tension). |

Player has **3 hearts** (shield chevrons). Damage → knockback, 1.2 s invuln, red vignette pulse, controller rumble. Death is not a game over: you **reboot at your Home Rig** after 6 s and lose 25% of carried cobalt. (Losing a run to a death is un-fun; losing *trees* while you are down is the real cost.)

---

## 4. Bots

| Bot | Cost | Role | Behaviour |
| --- | --- | --- | --- |
| **Planter** (`SEED-`) | 10 | Growth | Wanders on a soil-preference heuristic, plants a sapling every 9 s, refuses spots < 46 px from another tree. |
| **Builder** (`FRAME-`) | 35 | Growth | Wanders, builds a Planter every 14 s from carried cobalt (starts with 3), tops up by walking over cobalt. |
| **Repulsor** (`PYLON-`) | 5 | Defence | Static. Pulses every 3.4 s, 200 px knockback. 10 charges, then powers down with a little goodbye. |
| **Sentry** (`THORN-`) | 25 | Defence | Static. Fires seed-darts at Blight in 260 px, 1.1 s cadence, leads its target. |
| **Harvester** (`SCRAP-`) | 20 | Economy | Seeks cobalt, carries up to 5, returns it to the player or Home Rig. Draws a little tether beam. |
| **Beacon** (`LAMP-`) | 30 | Support | Static. +45% tree growth and +1 light source in 240 px; slows Blight 35%; **revives downed bots dropped inside it**. |

Every bot: a **name** (`SEED-07`), one of ~24 **traits** that tint idle chatter, a boot-up sequence (unfold + eye flicker + a chirp), an idle bob, a directional eye that looks at what it cares about, and a death (sparks, a descending 3-note motif, a scorch decal that fades over a cycle).

Downed ≠ destroyed: bots at 0 HP enter **DOWNED** for 20 s (sparking, dim eye, a tiny distress beep) and can be rescued. Un-rescued, they expire.

---

## 5. Blight (enemies)

| Enemy | From cycle | Behaviour |
| --- | --- | --- |
| **Chomper** | 1 | Walks to nearest un-marked tree, chews it (tree dies in 9 s unless driven off). Shoveable. |
| **Skitter** | 2 | Fast, erratic, targets bots not trees. Low HP. |
| **Spitter** | 3 | Ranged arcing acid; kills saplings, damages bots, leaves a corrosive puddle. |
| **Siphon** | 3 | Floats over the canopy, drains O₂ directly. Must be popped — ignores knockback. |
| **Bulwark** | 4 | Armoured, immune to shove, walks straight at Beacons/Sentries. Needs Sentry fire, Pulse, or a Repulsor chain. |
| **Rift Maw** | 5 | A stationary spawner that opens mid-map and vomits Chompers until closed (shove it 6× / Sentry it down). |
| **Harvester Prime** | 8 | Boss. Phase 1 beam sweep + drones; phase 2 ground slam + armour plates; phase 3 exposed core, bots rebel. |

Waves are authored by a **Director** (`game/director.lua`) that spends a per-night budget on enemy
cards, respecting a max-alive cap and a pacing curve (pressure peaks at 40% and 85% of the night).

---

## 6. Chips (dawn draft)

Draft 1 of 3 each dawn; ~40 chips over 5 families. Rarity tiers tint the card frame.

- **GROWTH** — Mycelium (trees spread 25% faster), Old Growth (trees mature into +2 O₂ elders), Rain Memory (rain lasts 2× longer), Seed Bank (hand-plant free)…
- **COMBAT** — Kinetic Cuffs (shove arc +40%), Recoil (shove refunds 1 cobalt on hit), Thornburst (killed Blight leaves a damaging spore cloud)…
- **LOGISTICS** — Vein Sense (cobalt outlined through fog), Deep Deposits (+50% node yield), Tithe (Harvesters carry 3 more)…
- **BOTS** — Warranty (bots revive once for free), Chorus (bots within 120 px of each other work 20% faster), Second Shift (Planters plant 2 saplings)…
- **PLAYER** — Kickstart (dash leaves a shockwave), Long Legs (+12% speed), Held Breath (1 extra heart)…

Cards are a first-class UI moment: hold, hover, lift, tilt-to-cursor, foil sheen, a satisfying *thunk* on pick.

---

## 7. Visual language

**"Luminous flat-vector with volumetric light."** Crisp geometry, no outlines except deliberate rim
light, soft contact shadows, a shallow atmospheric depth cue, real bloom.

- **Palette** lives in `engine/palette.lua`. Five graded ramps: `soil`, `flora`, `metal`, `blight`, `sky`.
  Nothing anywhere in the codebase may hardcode a colour literal — pull from the palette.
- **Terrain** — procedural island (layered value noise → height → biome), baked once to a canvas at
  load, with cliff drop-shadows, wet-sand ring, and a water shader (refraction, foam bands, sparkle,
  shore lapping).
- **Trees** — the centrepiece. Each tree owns a *seed*; branch geometry is generated by a recursive
  rule set and **animates as it grows** (a sapling is genuinely the first two segments of the adult).
  Canopy = clustered blobs shaded by sun direction with a rim term. A global **wind field** (2 octaves
  of scrolling noise) sways trunks and canopies coherently, so gusts travel visibly across the forest.
- **Lighting** — a light list rendered to an additive buffer: sun/moon directional, Beacons, bot eyes,
  the player lamp, rift glow, projectiles, fires. Tree shadows rotate and stretch with the sun.
- **Post chain** — `scene → brightpass → 2×gaussian bloom → grade(time-of-day LUT) → vignette →
  chromatic aberration → grain → impact distortion`. Every stage toggleable from Options.
- **Particles** — pollen motes (day), fireflies (night), leaf litter on gusts, footstep dust, cobalt
  shimmer, blight spores, rain, sparks, embers.
- **Screen feel** — `engine/juice.lua` owns hitstop, shake (trauma-based, decays quadratically),
  camera kick, zoom punch and time dilation. Everything routes through it so it can be tuned globally
  and turned off for accessibility.

---

## 8. Typography & UI

A **hand-vectored display typeface** (`assets/typeface.lua`) — uppercase, digits, punctuation, drawn
as stroked polylines with round joins, variable weight and tracking. Used for the logo, headers, HUD
numerals and card titles. Body copy uses Love's built-in font at tuned sizes.

UI rules: 8 px grid, one accent colour per screen, motion on every state change (nothing snaps),
diegetic where possible (the O₂ bar is the sky, not a rectangle).

---

## 9. Audio

100% synthesized into `SoundData` at load (`engine/synth.lua`), played through Love sources with
`love.audio.setEffect` reverb/EQ buses.

- **Adaptive score** — a generative bed in a modal centre that shifts per cycle. Layers: pad, bass
  pulse, arpeggio (unlocks with O₂), percussion (night only), choir (boss). Layers crossfade on
  game-state signals, never hard-cut.
- **SFX** — plant chime rises through a pentatonic scale as the forest grows (the single most
  satisfying sound in the game), pickup blip, shove whump + transient click, dash whoosh, bot boot
  chirp, bot death motif (a minor third falling to a fifth), rift tear, boss impacts.
- Ducking: SFX bus ducks music by 3 dB on impacts.

---

## 10. Input

`engine/input.lua` exposes **actions**, never raw keys. Devices auto-detect and the UI re-glyphs live.

- **Keyboard/Mouse** — WASD/arrows, Space dash, E/LMB shove, Q/RMB pulse, F plant, 1–6 build, Tab radial, Esc pause.
- **Gamepad** — full analog. **DualSense detected by joystick name** (`DualSense`, `Wireless Controller`,
  GUID match) → PlayStation glyphs (✕ ○ ▢ △) and rumble via `setVibration`. Xbox/other → ABXY.
- **Touch (iPhone)** — enabled when `love.system.getOS() == "iOS"` or on first touch. Floating left
  stick (spawns where you press), right-side action cluster, safe-area insets, larger hit targets,
  auto-aim assist. Layout defined once in `engine/touch.lua`.

---

## 11. Engineering rules

1. **Love 11.5.** No external libraries. Everything in `love2d/src`.
2. **`game/tuning.lua` holds every gameplay constant.** No magic numbers in behaviour code.
3. **`engine/palette.lua` holds every colour.** No colour literals in draw code.
4. Modules return a table. Use `src/core/class.lua` for OOP. Requires are absolute: `require("src.engine.camera")`.
5. Fixed-step logic where it matters; `dt` is clamped to `1/30`.
6. Draw order is owned by `world/renderer.lua` — entities register a `z` and a `draw(self)`.
7. Everything that ticks registers with `core/signal.lua` rather than reaching across modules.
8. **`tools/check.sh` must pass** (`luac -p` over every file) and **`tools/shot.sh` must produce a
   screenshot** before any change is considered done.
9. Target 60 fps with 400 trees, 60 bots, 40 enemies and full post on a mid laptop. Profile with
   `tools/bench.lua`.

---

## 12. Narrative beats

Same spine as 2019, more room:

1. **Prologue** — the suit, the dead sky, "they took the air". Player wakes at the Home Rig.
2. **First bot** — it boots up, looks at you, chirps. You name it (or it names itself).
3. **First attack** — the fighting tutorial, unchanged in spirit.
4. **First loss** — scripted-ish: the game makes sure you lose a named bot early, and shows you the
   rescue mechanic one beat too late to save it.
5. **Cycle 5, the question** — a bot asks what the trees are *for*.
6. **Extraction** — the Harvester Prime arrives. Bots go confused, bubbles up.
7. **"You've taught us love. Save the human."** — the rebellion. Unchanged line. It is perfect.
8. **Ending** — the suit comes off. The surviving bots form a circle around you. Nobody says anything
   for a long time. Then the credits grow over the world you made.

---

## 13. What the build actually does that this document did not plan

Three critic passes — design, art direction, audio, UI, narrative — and a code review changed
the game. Where the build and this document disagree, **the build is right**; these are the
decisions worth writing down.

**Oxygen reads the standing forest.** It is not an accumulator. `o2 = 100 · (forest / island
capacity)^0.78`, eased toward, with siphons applying a recoverable debt capped relative to the
reading. Plant a tree and the needle moves; lose a grove and it falls. The capacity is derived
from the island's plantable area, so a small island is not an unwinnable one.

**The forest is a frontier.** Only trees with fewer than four neighbours within 130 px put out
seedlings, so the wood advances with an edge instead of filling in as a mat — which gives the
Blight something to attack and the player something to hold.

**The night scales with what there is to lose.** The Director's budget and its cap on living
Blight both grow with the forest. A fixed budget against an exponential forest is a threat that
shrinks while the numbers on screen go up.

**Two decisions the original design did not have.**
*HOLD THE DAWN* (`R` at dusk): thirty more seconds of daylight for a 45% worse night, once a
cycle. *The standing order* (`G`): one flag; mobile bots look for ground near it and work 18%
faster inside it. The ground you point at is ground you are not defending.

**There is a way to lose.** While Harvester Prime lives it drains the sky, scaled so the fight
is always the same length whatever the meter read when it arrived. Empty the sky and the run
ends with a memorial instead of a victory.

**The finale is a procession.** The workforce always pays exactly 70% of the rig however large
it is; cohorts leave every 4.2 s so the health bar falls in visible steps; phases are time-gated
so the beam sweep and ground slam get their moment; and the last stretch is the player's alone.

**Every bot carries an epitaph.** `Bot:epitaph()` — "planted 41 trees", "held the line 4 times",
"never got to fire". It is spoken once by a survivor and printed beside the name in the
memorial, which lists the dead in the order they died rather than alphabetically.

### Measured, not assumed

| | |
| --- | --- |
| Simulation cost, 900 trees + 60 bots + particles | **~3.3 ms/frame** (one core, no rendering) |
| Audio synthesis at boot | ~2.0 s, 10.7 MB, 302 variants |
| Terrain generate + bake | ~0.9 s, ~35 MB of canvases |
| Web build | one HTML file, ~7.1 MB, LÖVE 11.4 in WebGL |

### Three bugs the browser had and the desktop never did

The shipping target is WebAssembly in a browser, and it is not the same renderer or the same
Lua. A zero-length line segment that desktop GL tolerates makes WebGL drop the segment before
it (every `U` rendered as a `J`). `string.format("%F")` is rejected outright. And LÖVE injects
`highp` into the vertex stage and `mediump` into the fragment stage, so an unqualified shared
uniform links on desktop and fails to link under GLSL ES. **Verify rendering work in the web
build, not only natively.**

---

## 14. What the outside review found, and what changed

An external critic played it and scored it 6/10. Everything below is what that review, and the
screenshots taken to check it, actually turned up. It supersedes the numbers in §13 where they
disagree.

### The climax did not play

**The Extraction was over in six to ten seconds.** Phases keyed off health, the player's shove
was secretly multiplied by five, and `rebelDelay` was longer than the whole fight, so the first
cohort never left the treeline. The run spends thirteen minutes building a workforce for a set
piece the workforce never reached.

`Boss:damage` now owns every point of damage the rig takes. A bot that reaches the hull lands
its full share; everything else is scaled into hull terms and then **clamped to a per-phase
floor** — the plates come off when the procession arrives, not when the player hits hard enough.
The bar visibly stalls against a lit rule and the HUD says `ARMOUR HOLDING`. Phases advance on
cohorts landing, with a stall failsafe so a crewless run cannot lock.

**The workforce's share scales with the crew.** Twelve bots cannot carry three quarters of a
fight that size, and pretending they could made a small crew's fight *shorter* than a large
one's — exactly backwards. It is a curve now: 42% at a dozen, capped at 72%. Building more bots
does not mean more damage per bot, it means less of the rig left for you.

**Not everyone goes.** A reserve is held back and never asked, and once the hull is under 16%
no further cohort leaves. Before this the whole crew was always spent and the last shot of the
game was the player alone on a beach, in front of an ending built around survivors gathering in
a ring.

Traced, 45-bot crew, headless autoplay: 12 / 34 / 60 bots → **102 s / 92 s / 87 s**, player
paying 51% / 38% / 32% of the hull, three / five / seven survivors.

### The run-ending crash

The rig sits in the enemy spatial hash so shoves and darts can find it, but it carried neither
`stun` nor `def`. Owning BRITTLE or PIN BREAKER — two of forty-six chips — and shoving it
compared a number with nil. A hard crash at the climax, in roughly a quarter of runs.

### You could not see your own workforce

Past five hundred trees the canopy is a solid mass. A 1600×900 capture of an extraction with
thirty-four bots alive contained **no visible bots**. Only the player had an occlusion-proof
marker. Every bot now carries one: shape for role, colour for state, fading in only when canopy
is actually over it. The downed get a ring that empties as their rescue window does and a hole
punched in the canopy above them. Rebels get an arrowhead on their heading and a wake.

### The rig was a smudge

A hundred-foot extraction platform standing *on* the canopy was depth-sorted into the tree list
by its feet, at 62 units across — smaller than one tree's crown. It is 88 units now, drawn after
the canopy and after the canopy's additive rim pass, with a crushed-canopy footprint, warning
lights, and a column of taken air going up out of the frame that is visible from anywhere on the
island.

### Smaller things that were wrong

- The camera clamped to the whole 3400×2400 world rect, so a shore filled half the screen with
  ocean. It clamps to the land's real bounding box now, measured ignoring the scattered skerries.
- The prologue drew the gameplay HUD under the cinematic bars. The whole chrome layer fades with
  the letterbox.
- Tutorial hints drew through the boss bar during the final fight.
- HOLD THE DAWN — a real decision — was surfaced only as a tutorial hint capped at two repeats.
  It is a panel under the cycle dial for the whole of dusk.
- The title screen's light shafts started at the sun's centre at full strength, stamping a hard
  trapezoid across the disc.
- The ending's clearing faded canopies to 0.16, and three hundred of those stack into an opaque
  milk over the one image the run is for.
- The dialogue panel's body was a `linearGradient`, which is a rectangle: rounded shadow, hard
  corners, and the island's shoreline showing through it at 0.80 alpha.
- `Enemy` seeded its own RNG from the wall clock, so two runs of the same seed diverged and every
  headless balance trace compared two different games.

### Dev switches added for this work

| | |
| --- | --- |
| `BOTS_TUNE=tree.frontierMax=7;cycle.budgetPerTree=0.31` | override numeric tuning for one run |
| `BOTS_CHIPS=brittle,pinBreaker` | hand a run a specific loadout |
| `BOTS_INPUT=touch\|pad\|kb` | force an input scheme, to capture the touch layout |
| `BOTS_WEB=1` | tell the game it is running in a page (the shell passes this) |

`tools/shot.sh [frames] ["frame numbers to photograph"] [outdir]` — the second argument is a
list of frame numbers, not a count.

---

## 15. The second review, and the systems it rebuilt

A second harsh review scored the game **5/10** — lower than the first, because it
looked at different things: the middle of the run, the economy, the chip pool, the
verbs, and the arithmetic underneath the win condition. Almost everything it found
was true. This section records what changed, because several of these are systems
rather than fixes.

### The win condition could not be reached

A full sky was pegged at one tree-point per 4300 square units of land, clamped over
a range wide enough that a large island demanded nearly two and a half times what a
small one did. A forest does not scale with an island that way, because the player's
time does not. Traced across three seeds the meter finished at 65 / 79 / 96 percent
with no way to close the gap. **A full sky is now about twelve hundred tree-points
wherever you land**, and the clamp does most of the work: a linear-in-area target
cannot be right for both ends of the seed range.

That number moved three times as the economy fixes below landed, each of which made
the forest grow faster. Runs now fill the sky between cycle five and cycle seven, or
not at all. Filling early is the win condition firing early and is paid for by
arriving at the extraction with a smaller crew.

### Growth was self-punishing

`budgetPerTree` was 0.28, so every tree the player grew bought the Blight that much
more of a night, in exact proportion. Growth was self-punishing and loss was
self-relieving. The night's spend is authored per cycle now and the forest term is a
much smaller reminder that a bigger wood is a longer perimeter.

### Two invisible economies

**Builders were spending the player's bank** — every fourteen seconds, per builder,
at half of an escalating price, with no way to see it, dismiss it or turn it off.
Their own card says they build "from cobalt it finds", and now they do.

**Deposits were being strip-mined at sixty chunks a second.** The player was
throttled at 0.55s a chunk; the bots were not throttled at all, so a Harvester
emptied a seven-chunk node in seven frames. The rate belongs to the rock now.

Both fixes made the player much richer, and *both* then had to be braked again:
removing the Builder's bank charge removed the only thing limiting the size of the
workforce, and traced runs reached **138 bots** where twenty to forty is the shape of
the game. A Builder now pays three chunks of its own carry per Planter and walks the
same escalation curve the player does. `costGrowthMax` went from 6 to 14, because a
cap that stops biting at twenty planters is a speed bump rather than a brake.

### The middle of the run was a treadmill

The enemy roster was fully unlocked by cycle 4 and the Director's type weights had no
cycle term at all, so night six was night three with a bigger number in front of it.
Now:

- **Weights are a function of the cycle.** The Chomper share falls 100% → 32% → 10%
  across the run as the armoured and ranged share rises; the average wave card
  triples in cost.
- **An early night has a lull; a late one has a floor** it never drops back through.
- **A second front opens at cycle 5**, and from cycle 4 the Blight *reinforces
  success* — a third of waves land on the last place it was winning, driven by an
  `enemy:targeted` signal that had been emitted since the beginning and consumed by
  nothing.
- **The Warden** (cycle 6) has no attack at all: everything Blight within 250 units
  shrugs off 55% of every hit and moves 22% faster. It changes the answer from "hit
  the nearest thing" to "get to the back".

### Half the run had no opposition

Days are 51% of a twenty-one minute campaign and the enemy count was zero in every
daylight sample of every trace. Now a Maw goes **dormant** at sunrise instead of
walking off, and anything still with its teeth in the wood at first light digs in and
leaves a **Blight Scar**.

A Scar is deliberately not a fight — it never moves, never chases, cannot touch the
player. It eats one tree at a time inside a creep radius that grows all day, it seeds
another if left to finish growing, it **denies the ground it covers to new planting**,
and at dusk it is where the night starts. It adds no budget; it moves where the
budget lands.

That last property had to be damped almost immediately. At four waves in five opening
on a Scar, a bad dawn compounded: the night began inside the wood you had already
lost, which cost more trees, which left more Scars. One seed went from 525 trees and
77% oxygen to 136 trees and 24%; another on the same build never let the Blight get a
hold at all. **A system with positive feedback and no damper is not difficulty, it is
a coin flip made at cycle three.**

### The chip pool was a stat-stick draft

Forty of forty-six cards were a scalar on a number the player cannot see, and not one
card in the pool changed what the player *does*. The pool is **26 cards**, sixteen of
which change a rule: Planters that walk the line to the flag planting as they go, a
dusk muster, Builders that copy your last build, the downed dragging themselves toward
the nearest light, a wood that makes anything chewing it bleed, a pulse that plants a
ring of saplings. From cycle four one seat in the hand is reserved for a rare.

Deleted outright: SURPLUS (no version of free scaling income is a decision), two rares
that bought a heart in a game where dying costs six seconds, one card that was purely
cosmetic, and one whose key was read by nothing anywhere in the tree.

### Three verbs were vestigial

The Pulse cost eight cobalt in a game whose bank sits at 0–13 from cycle two, so the
panic button was unaffordable at exactly the moments it exists for. It is priced in
seconds now. Hand-planting cost three cobalt and was dominated by a Planter inside a
minute; free on a long cooldown it is a placement decision. The rally flag could be
re-planted free and instantly, so its stated cost was not real. And the Repulsor fired
all four charges the instant it booted, whether or not anything was near it.

## 16. Bugs that had been there the whole time

Worth recording as a class. Every one of these was invisible because nothing ever
looked:

- **`VFX.draw("air")` was never called.** Sixty-six particle effects — pollen,
  fireflies, mist, blight spores, rift ambience — have been invisible for the entire
  life of the build.
- **`director:dawn` had never once fired.** The world advances its phase clock before
  it ticks the Director, so a night whose two clocks are equal ended without the
  Director seeing its own last frame. The HUD has had a `NIGHT SURVIVED` toast that
  was never shown.
- **`stats.lost` was pinned at zero for chew deaths in every run.** A tree could die
  two ways and the wrong one always won the sweep order, so the dawn tally and the
  ending memorial reported zero trees lost in a normal game.
- **A Bulwark's tree kills went through no ledger at all** — no sound, no shake, no
  stump, no tally — and it latched onto the first tree it ever slammed and never
  released it.
- **`Settings.recordRun` had no callers**, so the title screen had read
  `NO RUN RECORDED` since the feature was written.
- **The build bar displayed base prices** while the game charged escalated ones, so a
  slot lit up as buyable and then refused.
- **`Enemy` seeded its RNG from the wall clock**, so two runs of the same seed
  diverged and every headless balance trace compared two different games.
- **The canopy's additive backlight had no depth test** and ran after the whole
  forest, so a hidden tree's rim painted onto whatever stood in front of it. Removing
  it was worth half of all the fill in the game.
