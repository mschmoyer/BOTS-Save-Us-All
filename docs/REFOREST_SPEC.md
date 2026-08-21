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
