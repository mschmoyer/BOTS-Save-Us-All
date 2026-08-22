-- RELICS -- the people who were here before, and the fact that they are not.
--
-- The premise of this game is that one mechanic appears to be the last human
-- alive. Before this file the entire weight of that rested on two spoken lines
-- in the prologue and one in the ending, which is exactly the failure the whole
-- build is trying to avoid: a world that says nothing and a character who says
-- everything. So the claim goes in the ground instead.
--
-- Six kinds of object, placed once at world generation and never touched
-- again, plus one -- the husk -- that the run itself lays down:
--
--   wreck   a second Home Rig, burnt out, mast snapped, lamp dead. The strongest
--           single object here: it is unmistakably the same machine the player
--           lives in, and it says somebody else tried this.
--   road    a buried road running past the rig, in overlapping segments. Two
--           wheel ruts under a meadow. Where the wood closes over it, it is gone.
--   suit    an empty pressure suit sitting against a boulder. Seven of them, and
--           one of the seven has its helmet off, lying a metre from the body.
--   pallet  a pallet of atmosphere canisters with the strapping cut and two
--           canisters gone. They are painted in `P.o2` -- the colour the HUD has
--           spent the whole run teaching the player means air -- which is the
--           only reason this reads without a word on it. The deck carries the
--           Harvester Prime's own hazard yellow, which is who brought it.
--   mast    a relay mast on its face with its dish in the dirt. The radio on the
--           player's own rig has never been answered; this is the other end.
--   hauler  a flatbed on its side, half-buried in beach sand.
--   husk    one of your own machines, where it died. Not placed at generation:
--           spawned on `bot:lost` and permanent after that, so the island
--           accumulates the run's own history and the forest grows around it.
--
-- THE RULES, and they are the design rather than a style note:
--
--   * None of them is interactive. Walking onto one raises no toast, no
--     tooltip, no codex entry, no achievement and no bot line. There is no
--     reward for finding one and no acknowledgement that you did.
--   * None of them has a caption. Not a label, not a name, not a number. If a
--     relic only works with a line of text attached, the relic is wrong and
--     gets cut, and one was.
--   * None of them is on the minimap and none of them emits light. At night
--     they are dark shapes, which is correct: they are not important, they are
--     true.
--   * A Planter refuses to plant inside `T.relic.noPlant` of one, so the forest
--     grows *around* them and they are still standing in their clearings at the
--     ending when the camera pulls back over the canopy. That exclusion is the
--     only line of gameplay code any of this touches.
--
-- The empty suits are the load-bearing item and the easiest thing here to ruin.
-- They are not posed pathetically, not arranged in a tableau and never grouped
-- with anything else. One suit, sitting against a rock, doing nothing, in the
-- middle of a field the player is planting. If it ever reads as set dressing
-- placed to be found, it has failed, and the fix is to place fewer rather than
-- to explain more.
--
-- THREE THINGS ABOUT THE SUITS CHANGED, on evidence from four played runs:
--
--   * There are seven, not four, and `T.relic.sameKindBy.suit` lets two of them
--     stand within a screen and a half of each other. The old rule -- never two
--     in one view -- was written to stop the object reading as a spawner, and it
--     bought that at the price of the count. Two bodies in one field is not a
--     diorama; it is a fact, and it is the fact the whole set is for.
--   * The one in the near band, the suit a player who never explores is
--     guaranteed to meet, is drawn HALF AGAIN AS BIG (`T.relic.suitNear.scale`).
--     At 5x magnification this object is the best thing in the game -- helmet,
--     black void where a visor should be, legs stretched, back against the
--     stone -- and at play zoom it was a grey lump you walked past four times
--     without registering. One of the seven survives the zoom.
--   * One suit, exactly one per island, has its helmet OFF and lying a metre
--     from the body (pose 4). It is the only image in the set that says he took
--     it off, and it only works once.
--
-- WHAT WAS CUT, because the reasons are the design too:
--
--   * THE LANDING PAD. A poured apron with a blast scar in the middle, and it
--     was the loudest object in the set. It also said the exact opposite of the
--     thing this file exists to say: a blast scar in the middle of an apron
--     says a thing TOOK OFF from here, which is evacuation, and the premise is
--     extinction. Its one true sentence -- who built the rig that came for the
--     air -- is paint, so the paint moved to the pallet's deck, where it sits
--     under a load somebody was rationing rather than under a departure.
--   * ONE OF THE TWO PALLETS, and the other one is open now. Two untouched
--     pallets of air said they had plenty and did not need it. Strapping cut,
--     two canisters gone: somebody was counting them out.
--   * A tally scratched into the player's own hull, stopping at eleven. Cut
--     because homerig.lua is not this file's to edit, and because the agent who
--     does own it put a personal trace there anyway -- a radio mast with a
--     SIGNALS RECEIVED readout that reads zero for the whole run.
--   * Graves. A row of cairns is the most on-the-nose object this set could
--     have, it is the one most likely to read as an arranged tableau, and it
--     makes a claim the script never makes: nothing in the writing says he
--     buried anybody. The husks are not this: nobody arranged them, the player
--     watched each one happen, and none of them is a human being.
--   * A poured foundation with anchor bolts and nothing built on it. At this
--     camera it is a grey rectangle with no silhouette.
--
-- THE HUSKS ARE THE ONE THING HERE THE RUN WRITES, and they are the reason the
-- exclusion rule is worth its cost. Every other object in this file was placed
-- before the player arrived; a husk is placed by something the player watched
-- happen, at the spot they watched it happen, and it never goes away. Four
-- things fall out of that and all four are the point:
--
--   1. Both of the script's funeral beats now have a body to point a camera at.
--      They were playing over empty grass -- the corpse despawns in seconds and
--      the beat's delay and patience are measured in minutes -- and story.lua's
--      own comment admits it for one of the two.
--   2. The island accumulates its own history. By cycle six there is a line of
--      them along whatever perimeter kept failing.
--   3. The memorial at the end reads names the player has physically walked
--      past.
--   4. A Planter refuses to plant inside `T.relic.noPlant.husk` of one, so the
--      forest grows AROUND the dead. That is the whole game in one system.
--
-- What keeps (4) from eating the island: the husk's exclusion is 34 units
-- against the wreck's 112 -- a body is small and does not need protecting from
-- occlusion the way a hundred-unit machine does -- and there are never more
-- than `T.relic.husk.cap` of them. Measured cost is in that tuning block.
--
-- PERFORMANCE. Every one of these is static geometry, so each kind's picture is
-- recorded once through `Draw.bake` and replayed from its point lists for the
-- rest of the session -- the same idiom, and the same reason, as bot.lua's
-- hulls (docs/PERFORMANCE_SPEC.md F1): replaying polygons keeps LOVE's batching
-- where a Mesh per relic would break it, and the cos/sin happens once instead of
-- sixty times a second. Nothing here allocates, ticks, or is swept. There are
-- about twenty on a 3400x2400 island and the camera can see two.
--
-- NOTE FOR ANYONE EDITING A MODEL: a `g.push()/rotate()` *inside* a builder is
-- silently lost. `Draw.bake` records the raw points handed to `lg.polygon`,
-- before the transform stack is applied, so anything tilted has to be built
-- from `Draw.capsule` endpoints or an explicit polygon. Per-instance rotation
-- and mirroring are applied around the replay, where they work.
local Class  = require("src.core.class")
local U      = require("src.core.util")
local Entity = require("src.entities.entity")
local P      = require("src.engine.palette")
local Draw   = require("src.engine.draw")
local TU     = require("src.game.tuning")

local Relic = Class("Relic", Entity)

local lg  = love.graphics
local cos, sin, floor = math.cos, math.sin, math.floor
local TAU = U.TAU
local R   = P.ramp

--------------------------------------------------------------------- colour
-- Mixed once at load. Draw code may not hold a colour literal and `P.shade`
-- allocates a table per call (PERFORMANCE_SPEC F5), so every shade any model
-- asks for is a constant in this table. It is read and never edited.
local C = {
  void     = P.mix(R.derelict[1], P.black, 0.45),
  deep     = R.derelict[1],
  body     = R.derelict[2],
  lit      = R.derelict[3],
  rim      = R.derelict[4],
  rimSoft  = P.alpha(R.derelict[4], 0.55),
  -- Rust is a stain and never a light. At 0.55 over a dark hull, four streaks
  -- down a wreck read as four lit windows -- which is the exact opposite of the
  -- thing the object is for.
  rust     = P.alpha(P.rust, 0.20),
  rustDeep = P.alpha(P.rust, 0.12),
  chalk    = P.alpha(P.chalk, 0.34),
  chalkDim = P.alpha(P.chalk, 0.20),
  encroach = P.alpha(P.encroach, 0.62),
  encroachHi = P.alpha(P.mix(P.encroach, R.grass[2], 0.5), 0.5),
  hazard   = P.alpha(P.warn, 0.62),
  hazDark  = P.mix(R.derelict[1], P.black, 0.35),
  char     = P.mix(R.derelict[1], P.black, 0.35),
  charLit  = P.mix(R.derelict[2], P.ramp.ash[2], 0.55),
  ash      = P.alpha(P.shade(R.ash, 2), 0.5),

  -- The suit. Cut from the player's own ramp so it is unmistakably the same
  -- garment, dragged most of the way toward `derelict` so it is unmistakably
  -- not switched on. What actually separates them is subtraction: this one has
  -- no accent chest bars, no cyan visor and no lamp. The bright marks the
  -- player is read by are exactly the marks these do not have.
  suitDeep = P.mix(R.suit[1], R.derelict[1], 0.55),
  suitMid  = P.mix(R.suit[2], R.derelict[2], 0.62),
  suitLit  = P.mix(R.suit[3], R.derelict[3], 0.62),
  suitBar  = P.mix(R.suit[1], P.black, 0.35),

  -- Bedded stone, matching the blocks the terrain bake scatters on the rock:
  -- cast, body, one lit top facet, and nothing else. Sun-bleached deliberately
  -- high on the ramp: the suit in front of it is the darkest thing the game
  -- draws, and if the rock is not clearly PALER the two merge into one lump and
  -- the whole object is a smudge on grass. Contrast, not detail, is what makes
  -- a thirty-unit figure legible.
  stoneShade = P.shade(R.stone, 1.5),
  stoneBody  = P.mix(P.shade(R.stone, 3.1), P.shade(R.sand, 1.8), 0.22),
  stoneTop   = P.mix(P.shade(R.stone, 4.0), P.shade(R.sand, 2.4), 0.30),

  wood     = P.shade(R.bark, 1.4),
  woodLit  = P.shade(R.bark, 2.2),
  air      = P.alpha(P.o2, 0.80),
  airDim   = P.alpha(P.o2, 0.34),

  roadBed  = P.mix(R.soil[1], R.derelict[1], 0.30),
  roadRut  = P.mix(R.soil[1], P.black, 0.36),

  -- The husk. Cut from `P.ramp.metal` -- the ramp every working machine in the
  -- crew is drawn from -- and dragged toward `derelict` and toward black, which
  -- is the same trick, and the same argument, as the empty suit two blocks up:
  -- it has to be unmistakably one of YOURS and unmistakably switched off. What
  -- separates it from a live bot is subtraction. No eye, no antenna bead, no
  -- load pips, no nameplate, no light.
--
  -- The values are pulled a long way down on purpose. A first pass at this
  -- mixed only halfway to `derelict` and the result read as a working machine
  -- that happened to be lying down -- pale blue-grey chassis, bright top face,
  -- the whole thing looking like it was about to get up. Dark is most of what
  -- says dead here; the one hard rim is what stops dark becoming a smudge.
  huskDeep = P.mix(P.shade(P.ramp.metal, 1.2), P.black, 0.56),
  huskBody = P.mix(P.shade(P.ramp.metal, 1.9), R.derelict[1], 0.64),
  huskLit  = P.mix(P.shade(P.ramp.metal, 2.6), R.derelict[2], 0.58),
  huskRim  = P.alpha(P.mix(P.shade(P.ramp.metal, 3.4), R.derelict[3], 0.42), 0.55),
  -- the ground it went down on, under the shadow: a scuff, not a crater. The
  -- death already dropped a `scorch` decal here.
  scuff    = P.alpha(P.mix(R.soil[1], P.black, 0.30), 0.40),

  sandLo   = P.alpha(P.shade(R.sand, 1.4), 0.42),
  sandHi   = P.alpha(P.shade(R.sand, 1.9), 0.48),
  tyre     = P.mix(R.derelict[1], P.black, 0.30),
}

--------------------------------------------------------------------- helpers
--- A hard rim highlight along part of a circle, built out of short capsules so
--- it survives `Draw.bake` (`lg.arc` does not). One light, upper-left, the way
--- everything else on this island is lit.
local function rimArc(cx, cy, rad, a0, a1, w, segs)
  segs = segs or 4
  for i = 0, segs - 1 do
    local t0 = a0 + (a1 - a0) * (i / segs)
    local t1 = a0 + (a1 - a0) * ((i + 1) / segs)
    Draw.capsule("fill", cx + cos(t0) * rad, cy + sin(t0) * rad,
                         cx + cos(t1) * rad, cy + sin(t1) * rad, w)
  end
end

--- Clip a convex polygon to one half-plane, Sutherland-Hodgman, into `dst`.
--- Two scratch buffers and no allocation: the hazard band runs this four times
--- per stripe and it only ever runs at bake time, but the buffers are shared
--- with nothing so it is safe to nest inside a model.
local CLIP_A, CLIP_B = {}, {}
local function clipHalf(src, n, nx, ny, d, dst)
  local m = 0
  for i = 1, n do
    local j = (i % n) + 1
    local ax, ay = src[i * 2 - 1], src[i * 2]
    local bx, by = src[j * 2 - 1], src[j * 2]
    local da = nx * ax + ny * ay - d
    local db = nx * bx + ny * by - d
    if da <= 0 then m = m + 1; dst[m * 2 - 1] = ax; dst[m * 2] = ay end
    if (da < 0) ~= (db < 0) then
      local t = da / (da - db)
      m = m + 1
      dst[m * 2 - 1] = ax + (bx - ax) * t
      dst[m * 2] = ay + (by - ay) * t
    end
  end
  return m
end

--- Hazard paint: 45-degree stripes clipped exactly to a rect. The same device,
--- and deliberately the same yellow, that boss.lua paints on the Harvester
--- Prime's deck and ankles. Nobody says who built the pad. The paint does.
local HZ = {}
local function hazardBand(x, y, w, h, stripe, cBar, cGap)
  Draw.setColor(cGap)
  Draw.roundRect("fill", x, y, w, h, 0)
  local period = stripe * 2
  local u = floor((x - y - h) / period) * period
  while u < x + w do
    -- one stripe, as the band between the lines (px - py) = u and u + stripe
    HZ[1], HZ[2] = x - h * 2, y - h
    HZ[3], HZ[4] = x + w + h * 2, y - h
    HZ[5], HZ[6] = x + w + h * 2, y + h * 2
    HZ[7], HZ[8] = x - h * 2, y + h * 2
    local n = clipHalf(HZ, 4, -1, 1, -u, CLIP_A)                 -- px - py >= u
    if n >= 3 then n = clipHalf(CLIP_A, n, 1, -1, u + stripe, CLIP_B) end
    if n >= 3 then n = clipHalf(CLIP_B, n, -1, 0, -x, CLIP_A) end
    if n >= 3 then n = clipHalf(CLIP_A, n, 1, 0, x + w, CLIP_B) end
    if n >= 3 then n = clipHalf(CLIP_B, n, 0, -1, -y, CLIP_A) end
    if n >= 3 then n = clipHalf(CLIP_A, n, 0, 1, y + h, CLIP_B) end
    if n >= 3 then
      Draw.trim(CLIP_B, n * 2)
      Draw.setColor(cBar)
      lg.polygon("fill", CLIP_B)
    end
    u = u + period
  end
end

--- Deterministic scatter, so a model's weathering is the same every session and
--- in every replay without any model holding an RNG.
local hash = Draw.hash

---------------------------------------------------------------------- models
-- Each entry is `function(r, variant)`. `r` is the kind's radius in world
-- units and the model is built at that size, so replay never scales.
local MODEL = {}

------------------------------------------------------------------ wreck
-- The other rig. Everything about it is homerig.lua's shape read back with the
-- power off: the same five splayed struts, the same squat hexagonal shell, the
-- same deck bar and the same mast in the same place. Three things are different
-- and all three are absences -- the top hex is a hole instead of a highlight,
-- the mast is lying on the ground instead of standing, and the bead on the end
-- of it is dead metal instead of a green light with a glow under it. That last
-- one is the whole object. Do not put a light on this.
MODEL.wreck = function(r)
  -- struts, splayed lower than a standing rig's and half sunk
  Draw.setColor(C.char)
  for i = 1, 5 do
    local a = hash(i, 7) * TAU
    local len = 0.72 + hash(i, 11) * 0.5
    Draw.capsule("fill", 0, 0, cos(a) * r * len, sin(a) * r * len * 0.55 + r * 0.34,
                 r * (0.085 + hash(i, 13) * 0.06))
  end

  -- the burn under it: this did not merely stop working
  Draw.setColor(C.ash)
  Draw.blob(0, r * 0.24, r * 1.15, 12, 41, 0.26, 0.44)

  -- hull. Listing harder than the player's, and the third hex -- the bright
  -- one, the one you read the rig by -- is a torn opening instead.
  Draw.setColor(C.char)
  Draw.hexagon(-r * 0.03, r * 0.12, r * 0.94, 0.26)
  Draw.setColor(C.charLit)
  Draw.hexagon(-r * 0.08, -r * 0.02, r * 0.76, 0.26)
  Draw.setColor(C.lit)
  Draw.hexagon(-r * 0.10, -r * 0.06, r * 0.50, 0.26)
  -- The tear. Small, off centre and toward the up-sun side: a hole through the
  -- middle of the hull is a doughnut, and a doughnut is not a wreck.
  Draw.setColor(C.void)
  Draw.blob(-r * 0.22, -r * 0.20, r * 0.27, 11, 61, 0.36, 0.82)
  -- the lip of it, three plates standing up out of the hull
  Draw.setColor(C.rim)
  for i = 1, 3 do
    local a = 2.3 + i * 1.5
    Draw.capsule("fill", -r * 0.22 + cos(a) * r * 0.24, -r * 0.20 + sin(a) * r * 0.20,
                 -r * 0.22 + cos(a) * r * 0.36, -r * 0.20 + sin(a) * r * 0.32, r * 0.030)
  end

  -- deck bar, snapped in the middle
  Draw.setColor(C.deep)
  Draw.roundRect("fill", -r * 0.88, -r * 0.58, r * 0.62, r * 0.28, r * 0.11)
  Draw.roundRect("fill", r * 0.06, -r * 0.52, r * 0.52, r * 0.26, r * 0.11)

  -- rust running out of the seams. Short, and only on the lower half where the
  -- water sits: four full-height streaks down a dark hull read as lit windows,
  -- which is what the first pass at this looked like.
  Draw.setColor(C.rust)
  for i = 1, 3 do
    local x = -r * 0.42 + i * r * 0.34
    Draw.capsule("fill", x, r * 0.10, x + r * 0.03, r * 0.30 + hash(i, 31) * r * 0.18,
                 r * 0.022)
  end

  -- The mast. Snapped at the collar; the stub still stands, the rest of it is
  -- lying across the ground pointing away downhill.
  Draw.setColor(C.body)
  Draw.capsule("fill", r * 0.30, -r * 0.36, r * 0.34, -r * 0.62, r * 0.075)
  Draw.setColor(C.deep)
  Draw.capsule("fill", r * 0.52, -r * 0.22, r * 1.92, r * 0.36, r * 0.075)
  Draw.setColor(C.body)
  Draw.capsule("fill", r * 0.52, -r * 0.26, r * 1.20, -r * 0.02, r * 0.045)
  -- the lamp housing, face down, and the bead in it. Dead metal. No glow.
  Draw.setColor(C.deep)
  lg.circle("fill", r * 1.98, r * 0.38, r * 0.15)
  Draw.setColor(C.charLit)
  lg.circle("fill", r * 1.98, r * 0.38, r * 0.09)
  Draw.setColor(C.void)
  Draw.blob(r * 1.97, r * 0.37, r * 0.062, 8, 3, 0.22, 0.9)

  -- One hard rim, upper-left, so it is a solid and not a stain. Kept short and
  -- close to the silhouette: swept round a third of the hull it read as a pale
  -- scratch drawn across the machine rather than as a lit edge on it.
  Draw.setColor(C.rimSoft)
  rimArc(-r * 0.08, -r * 0.02, r * 0.90, 3.35, 4.05, r * 0.032, 3)
end

------------------------------------------------------------------ road
-- Two wheel ruts under a meadow, in segments so the culling and the baking both
-- work on something the size of a screen. It is drawn in the *ground* pass
-- rather than the sorted entity pass -- see `Relic:drawShadow` -- because it has
-- no height and belongs under everything that does.
--
-- The three variants differ only in where the verge has broken in and whether
-- there is any paint left on the centre line, which is enough that a dozen of
-- them in a row do not read as tiling.
MODEL.road = function(r, v)
  local RD = TU.relic.road
  local L, W = RD.segLen * 0.5 + RD.overlap, RD.width
  local s = v * 977

  Draw.setColor(C.roadBed)
  Draw.roundRect("fill", -L, -W * 0.5, L * 2, W, W * 0.10)

  -- the two bands: worn down to bare soil where the wheels ran
  Draw.setColor(C.roadRut)
  Draw.roundRect("fill", -L, -W * 0.34, L * 2, W * 0.20, W * 0.08)
  Draw.roundRect("fill", -L, W * 0.14, L * 2, W * 0.20, W * 0.08)

  -- what is left of the centre line. Faint, broken, and on two variants in
  -- three -- a fully painted road is a road somebody still maintains.
  if v ~= 2 then
    Draw.setColor(C.chalkDim)
    for i = 0, 1 do
      local x = -L * 0.5 + i * L
      Draw.roundRect("fill", x, -W * 0.035, L * 0.34, W * 0.07, W * 0.03)
    end
  end

  -- potholes
  Draw.setColor(C.void)
  for i = 1, 3 do
    local x = (hash(i, s) - 0.5) * L * 1.7
    local y = (hash(i, s + 5) - 0.5) * W * 0.6
    Draw.blob(x, y, W * (0.06 + hash(i, s + 9) * 0.05), 8, s + i, 0.3, 0.7)
  end

  -- the verge, coming in from both sides. This is what stops it being a
  -- rectangle, and it is most of the reason the thing reads as old.
  -- Small and many rather than large and few: six fat lozenges along an edge
  -- read as stickers, eighteen small ones read as a verge closing in. Half of
  -- them are soil rather than grass, so the break-up is not a row of green dots.
  Draw.setColor(C.encroach)
  for i = 1, 18 do
    local x = (hash(i, s + 21) - 0.5) * L * 2.0
    local side = (i % 2 == 0) and 1 or -1
    local y = side * W * (0.42 + hash(i, s + 27) * 0.16)
    Draw.blob(x, y, W * (0.07 + hash(i, s + 33) * 0.10), 8, s + i * 3, 0.36, 0.58)
  end
  Draw.setColor(C.encroachHi)
  for i = 1, 8 do
    local x = (hash(i, s + 45) - 0.5) * L * 1.9
    local side = (i % 2 == 0) and 1 or -1
    Draw.blob(x, side * W * 0.40, W * (0.045 + hash(i, s + 51) * 0.06), 8,
              s + i * 7, 0.34, 0.56)
  end
  -- and some of the bed showing through as bare soil, so it is not one flat tone
  Draw.setColor(P.alpha(C.roadBed, 0.55))
  for i = 1, 6 do
    Draw.blob((hash(i, s + 61) - 0.5) * L * 1.8, (hash(i, s + 67) - 0.5) * W * 0.9,
              W * (0.10 + hash(i, s + 71) * 0.14), 9, s + i * 11, 0.32, 0.6)
  end
end

------------------------------------------------------------------ suit
-- An empty suit sitting against a boulder.
--
-- Three poses, and the discipline in all three is that nothing is happening.
-- No arms out, no head in hands, no reaching, no arrangement. Somebody sat
-- down against a rock and the suit is still sitting there. It is drawn at very
-- nearly the player's own scale out of very nearly the player's own parts,
-- because the half-second of "is that me?" is the entire effect and every
-- bright mark that would resolve it -- the accent bars, the cyan visor, the
-- lamp -- has been removed rather than recoloured.
--
-- Pose 4 is the exception and it is the only one in the set that makes a claim:
-- the helmet is OFF, sitting in the grass a metre from the body, and the collar
-- ring is open and dark. Every other object in this file is evidence of a thing
-- that happened to somebody. This is the one that says he did it himself, and
-- because it says something it is rationed hard -- `Relic.populate` places
-- exactly one per island, deliberately, rather than rolling for it.
local SUIT_POSE = {
  { lean = 0.16, tip = 0.10, knee = 0.00, armOut = false },
  { lean = 0.10, tip = 0.18, knee = 0.62, armOut = false },
  { lean = 0.30, tip = 0.26, knee = 0.22, armOut = true  },
  { lean = 0.22, tip = 0.34, knee = 0.44, armOut = true, helmetOff = true },
}

MODEL.suit = function(r, v)
  local pose = SUIT_POSE[((v - 1) % #SUIT_POSE) + 1]
  local lean, tip, knee = pose.lean, pose.tip, pose.knee

  -- THE BOULDER goes UP-SCREEN, not beside. This camera looks down at a slant,
  -- so "leaning against a rock" is the rock behind and above with the figure's
  -- back overlapping its near edge. Built beside, the two read as a rock and,
  -- separately, a body next to it -- which is the second-worst thing this
  -- object can be after a diorama.
  --
  -- Cast, body, one lit top facet: the same three flat shapes the terrain bake
  -- uses for a block of stone, so it belongs to the island. Bleached high on
  -- the ramp because the suit in front of it is the darkest thing the game
  -- draws, and contrast is the only thing that makes a figure this small read.
  Draw.setColor(C.stoneShade)
  Draw.blob(-r * 0.10, -r * 0.52, r * 1.10, 9, 21, 0.22, 0.62)
  Draw.setColor(C.stoneBody)
  Draw.blob(-r * 0.16, -r * 0.86, r * 1.02, 9, 21, 0.24, 0.70)
  Draw.setColor(C.stoneTop)
  Draw.blob(-r * 0.26, -r * 1.16, r * 0.60, 8, 5, 0.26, 0.48)

  -- Three points, and everything else hangs off them: hips on the ground,
  -- shoulders back against the stone, head tipped forward off the shoulders.
  local hx, hy = 0, r * 0.02
  local sx, sy = hx - r * (0.10 + lean * 0.9), hy - r * 0.54
  local kx, ky = sx - r * (0.04 + tip * 0.5), sy - r * (0.40 - tip * 0.10)
  local nx, ny = r * (0.60 - knee * 0.22), hy + r * (0.12 - knee * 0.34)
  local fx, fy = r * (0.94 - knee * 0.50), hy + r * (0.24 - knee * 0.02)

  -- the pack, wedged between the shoulders and the rock
  Draw.setColor(C.suitDeep)
  Draw.capsule("fill", hx - r * 0.16, hy - r * 0.14, sx - r * 0.16, sy + r * 0.02, r * 0.29)

  -- FAR LEG. Deliberately a whole stop under the near one: a seated figure at
  -- this size is legible only if the two legs separate by value, because they
  -- overlap for most of their length.
  Draw.setColor(C.suitDeep)
  Draw.capsule("fill", hx + r * 0.06, hy - r * 0.12, nx, ny - r * 0.13, r * 0.145)
  Draw.capsule("fill", nx, ny - r * 0.13, fx + r * 0.02, fy - r * 0.14, r * 0.130)
  Draw.setColor(C.suitBar)
  Draw.capsule("fill", fx, fy - r * 0.16, fx + r * 0.19, fy - r * 0.12, r * 0.145)

  -- torso
  Draw.setColor(C.suitMid)
  Draw.capsule("fill", hx, hy - r * 0.02, sx, sy, r * 0.29)
  Draw.setColor(C.suitLit)
  Draw.capsule("fill", hx - r * 0.02, hy - r * 0.14, sx + r * 0.02, sy + r * 0.10, r * 0.20)
  -- the two chest bars the player wears in bright green. Here they are the
  -- darkest thing on the body, and that swap is the whole costume note.
  Draw.setColor(C.suitBar)
  Draw.capsule("fill", hx - r * 0.13, hy - r * 0.21, hx + r * 0.08, hy - r * 0.24, r * 0.040)
  Draw.capsule("fill", hx - r * 0.15, hy - r * 0.36, hx + r * 0.10, hy - r * 0.39, r * 0.040)

  -- NEAR LEG, over the far one and a stop brighter, with a black boot on it
  Draw.setColor(C.suitLit)
  Draw.capsule("fill", hx + r * 0.06, hy + r * 0.10, nx - r * 0.04, ny + r * 0.14, r * 0.155)
  Draw.setColor(C.suitMid)
  Draw.capsule("fill", nx - r * 0.04, ny + r * 0.14, fx - r * 0.10, fy + r * 0.12, r * 0.140)
  Draw.setColor(C.suitBar)
  Draw.capsule("fill", fx - r * 0.14, fy + r * 0.12, fx + r * 0.07, fy + r * 0.16, r * 0.155)

  -- Arms. Both hang. One of the three poses has the near hand flat on the
  -- ground beside the hip, which is where a hand goes when nobody is using it.
  Draw.setColor(C.suitMid)
  local ex, ey = sx + r * 0.24, sy + r * 0.34
  Draw.capsule("fill", sx + r * 0.02, sy + r * 0.04, ex, ey, r * 0.130)
  if pose.armOut then
    Draw.capsule("fill", ex, ey, ex + r * 0.44, hy + r * 0.28, r * 0.120)
  else
    Draw.capsule("fill", ex, ey, ex + r * 0.32, hy + r * 0.02, r * 0.120)
  end

  -- neck and helmet, tipped forward off the shoulders
  Draw.setColor(C.suitDeep)
  Draw.capsule("fill", sx, sy, kx, ky + r * 0.14, r * 0.115)
  if pose.helmetOff then
    -- The collar ring, open, with the neck of the suit gone slack into it. A
    -- head-shaped hole where a head goes is worth more than any amount of
    -- weathering, and it is what makes the helmet on the ground read as HIS.
    Draw.setColor(C.suitMid)
    lg.circle("fill", kx, ky + r * 0.10, r * 0.26)
    Draw.setColor(C.void)
    Draw.blob(kx, ky + r * 0.11, r * 0.19, 9, 44, 0.10, 0.62)
    -- and the helmet itself, set down in the grass beside the near hip. Not
    -- dropped, not thrown, not rolled away: put down.
    local gx, gy = hx + r * 1.20, hy + r * 0.62
    Draw.setColor(C.suitDeep)
    Draw.blob(gx, gy + r * 0.10, r * 0.36, 9, 51, 0.16, 0.42)
    Draw.setColor(C.suitLit)
    lg.circle("fill", gx, gy, r * 0.33)
    Draw.setColor(C.suitMid)
    lg.circle("fill", gx - r * 0.04, gy + r * 0.03, r * 0.28)
    Draw.setColor(C.void)
    Draw.blob(gx - r * 0.05, gy + r * 0.05, r * 0.21, 9, 12, 0.08, 0.76)
    Draw.setColor(C.rim)
    rimArc(gx, gy, r * 0.33, 3.35, 4.45, r * 0.034, 4)
  else
    Draw.setColor(C.suitLit)
    lg.circle("fill", kx, ky, r * 0.37)
    Draw.setColor(C.suitMid)
    lg.circle("fill", kx - r * 0.04, ky + r * 0.03, r * 0.32)
    -- The visor. A hole. There is nothing behind it and it does not glow, and
    -- that -- an unlit version of the one bright mark the player is read by --
    -- is the only sentence this object says.
    Draw.setColor(C.void)
    Draw.blob(kx - r * 0.07, ky + r * 0.04, r * 0.24, 9, 12, 0.08, 0.76)
    Draw.setColor(C.rim)
    rimArc(kx, ky, r * 0.37, 3.35, 4.45, r * 0.038, 4)
  end
end

------------------------------------------------------------------ pallet
-- A pallet of atmosphere canisters, opened. Strapping cut, two of the six
-- gone, one of the two lying on its side in the grass beside it.
--
-- The bands are `P.o2` -- the colour the oxygen bar has been the whole run --
-- and that is the entire caption. A player who has watched that needle for
-- fifteen minutes knows what is in these without being told.
--
-- WHAT THE OPENING IS FOR. Strapped and untouched, this said they had air and
-- did not need it, which is a sentence about a supply run that got interrupted.
-- Cut open with two missing says somebody was counting them out one at a time,
-- which is a sentence about rationing, and rationing is a sentence about the
-- end of something. Same object, four primitives moved.
--
-- The hazard stripes on the deck came off the landing pad when that was cut.
-- `P.warn` at 0.62 is the exact paint boss.lua puts on the Harvester Prime's
-- deck and ankles, and it is the only thing in the game that says who built the
-- machine that came for the air. It says it on a crate somebody was rationing
-- out of instead of on an apron somebody took off from, which is the same
-- sentence pointed the right way. Nothing anywhere remarks on it.
MODEL.pallet = function(r)
  -- pallet: deck and three bearers
  Draw.setColor(C.wood)
  Draw.roundRect("fill", -r * 0.98, -r * 0.06, r * 1.96, r * 0.20, r * 0.05)
  Draw.setColor(P.mix(C.wood, P.black, 0.4))
  for i = 0, 2 do
    Draw.roundRect("fill", -r * 0.94 + i * r * 0.84, r * 0.24, r * 0.24, r * 0.16, r * 0.04)
  end
  -- The hazard stencil on the front edge of the deck. HALF the deck's width,
  -- not all of it: run edge to edge it was the brightest thing on the object
  -- and the pallet became a sign, which is the failure the landing pad was cut
  -- for. A worn patch of it under one end of the load is a stencil somebody
  -- painted on a crate.
  hazardBand(-r * 0.86, r * 0.06, r * 0.98, r * 0.15, r * 0.11, C.hazard, C.hazDark)
  Draw.setColor(C.woodLit)
  Draw.roundRect("fill", -r * 0.98, -r * 0.08, r * 1.96, r * 0.06, r * 0.03)

  -- canisters, back row then front row so the front overlaps
  local function can(cx, base, h, w)
    Draw.setColor(C.deep)
    Draw.capsule("fill", cx, base, cx, base - h, w)
    Draw.setColor(C.body)
    Draw.capsule("fill", cx - w * 0.42, base - h * 0.15, cx - w * 0.42, base - h * 0.85,
                 w * 0.22)
    Draw.setColor(C.air)
    Draw.capsule("fill", cx - w * 0.82, base - h * 0.58, cx + w * 0.82, base - h * 0.58,
                 w * 0.22)
    Draw.setColor(C.airDim)
    Draw.capsule("fill", cx - w * 0.82, base - h * 0.34, cx + w * 0.82, base - h * 0.34,
                 w * 0.10)
    Draw.setColor(C.lit)
    Draw.capsule("fill", cx, base - h - w * 0.10, cx, base - h - w * 0.34, w * 0.54)
    Draw.setColor(C.deep)
    Draw.capsule("fill", cx, base - h - w * 0.34, cx, base - h - w * 0.52, w * 0.26)
    Draw.setColor(C.rim)
    Draw.capsule("fill", cx - w * 0.66, base - h * 0.88, cx - w * 0.66, base - h * 0.22,
                 w * 0.13)
  end
  -- Four of six. The back row keeps its middle and right bottles; the front
  -- row is missing the one on the left, so the gap is on the near side where
  -- the silhouette actually shows it.
  for i = 0, 1 do can(i * r * 0.50 - r * 0.08, -r * 0.18, r * 0.94, r * 0.19) end
  for i = 0, 1 do can(i * r * 0.54 + r * 0.06, -r * 0.04, r * 1.04, r * 0.21) end

  -- ONE OF THE TWO THAT LEFT, lying on its side in the grass at the near
  -- corner, empty. It reads as a bottle rather than as a pipe because the
  -- collar and the o2 band are still on it and both are across its length.
  do
    local bx, by, w = -r * 0.66, r * 0.46, r * 0.20
    Draw.setColor(C.deep)
    Draw.capsule("fill", bx - r * 0.34, by, bx + r * 0.34, by - r * 0.05, w)
    Draw.setColor(C.body)
    Draw.capsule("fill", bx - r * 0.30, by - r * 0.07, bx + r * 0.26, by - r * 0.11, w * 0.44)
    Draw.setColor(C.airDim)
    Draw.capsule("fill", bx + r * 0.02, by - r * 0.17, bx + r * 0.04, by + r * 0.15, w * 0.22)
    Draw.setColor(C.lit)
    Draw.capsule("fill", bx + r * 0.38, by - r * 0.06, bx + r * 0.50, by - r * 0.07, w * 0.52)
  end

  -- THE STRAPS ARE CUT. Both ran the whole width and both are in two pieces
  -- now, the loose ends fallen away down the face of the load. This is the
  -- object: a strap that has been cut is a decision somebody made.
  -- The gap has to be wide. Cut with the ends left touching, this read as an
  -- intact strap with a seam in it at play zoom; the loose ends falling down
  -- the face of the load are what make it read as cut rather than as worn.
  Draw.setColor(C.chalk)
  Draw.capsule("fill", -r * 0.92, -r * 0.62, -r * 0.34, -r * 0.60, r * 0.045)
  Draw.capsule("fill", r * 0.40, -r * 0.58, r * 0.92, -r * 0.56, r * 0.045)
  Draw.setColor(C.chalkDim)
  Draw.capsule("fill", -r * 0.34, -r * 0.60, -r * 0.20, -r * 0.16, r * 0.038)
  Draw.capsule("fill", r * 0.40, -r * 0.58, r * 0.30, -r * 0.10, r * 0.038)
  Draw.setColor(C.chalk)
  Draw.capsule("fill", -r * 0.90, -r * 0.26, r * 0.10, -r * 0.23, r * 0.045)
  Draw.setColor(C.chalkDim)
  Draw.capsule("fill", r * 0.10, -r * 0.23, r * 0.30, r * 0.18, r * 0.038)
  -- ...and one end of it on the ground, off the near corner of the deck
  Draw.capsule("fill", r * 0.44, r * 0.40, r * 0.84, r * 0.30, r * 0.034)

  -- eleven days of drift piled against the windward side
  Draw.setColor(C.sandLo)
  Draw.blob(-r * 0.72, r * 0.16, r * 0.46, 10, 77, 0.28, 0.40)
end

------------------------------------------------------------------ mast
-- A relay mast on its face, dish in the dirt. Built centred on its own length
-- so the view cull has something honest to test.
--
-- The player's rig carries a radio that has never been answered. This is what
-- the other end of that looks like, and nothing anywhere says so.
MODEL.mast = function(r)
  local x0, x1 = -r * 0.98, r * 0.52

  -- the two rails, and the bracing between them
  Draw.setColor(C.deep)
  Draw.capsule("fill", x0, -r * 0.17, x1, -r * 0.10, r * 0.055)
  Draw.capsule("fill", x0, r * 0.17, x1, r * 0.10, r * 0.055)
  Draw.setColor(C.body)
  for i = 0, 5 do
    local t0, t1 = i / 6, (i + 1) / 6
    local ax = x0 + (x1 - x0) * t0
    local bx = x0 + (x1 - x0) * t1
    local up = (i % 2 == 0)
    Draw.capsule("fill", ax, (up and -1 or 1) * r * (0.17 - t0 * 0.07),
                         bx, (up and 1 or -1) * r * (0.17 - t1 * 0.07), r * 0.036)
  end

  -- The break: the base flange, and the anchor bolts that came out of the
  -- ground with it. Small. Drawn any larger it read as a torn flag on a pole.
  Draw.setColor(C.body)
  Draw.roundRect("fill", x0 - r * 0.10, -r * 0.20, r * 0.17, r * 0.40, r * 0.04)
  Draw.setColor(C.lit)
  Draw.roundRect("fill", x0 - r * 0.07, -r * 0.16, r * 0.10, r * 0.32, r * 0.03)
  Draw.setColor(C.deep)
  for i = -1, 1 do
    Draw.capsule("fill", x0 - r * 0.09, i * r * 0.13,
                 x0 - r * 0.22 - hash(i + 2, 131) * r * 0.06, i * r * 0.17, r * 0.020)
  end
  Draw.setColor(C.rustDeep)
  Draw.blob(x0 - r * 0.02, 0, r * 0.16, 9, 141, 0.3, 0.9)

  -- The dish, face up, half in the dirt. It is the readable half of this
  -- object: a pale ellipse the size of a car lying in a meadow is a silhouette
  -- nothing else in the game makes, and it is what carries the thing from a
  -- distance. Rim, bowl, shadowed lower lip -- three shapes, one light.
  local dx, dy = r * 0.74, -r * 0.02
  Draw.setColor(C.deep)
  Draw.blob(dx, dy + r * 0.07, r * 0.52, 16, 151, 0.04, 0.72)
  Draw.setColor(C.rim)
  Draw.blob(dx, dy - r * 0.01, r * 0.50, 16, 151, 0.04, 0.70)
  Draw.setColor(C.lit)
  Draw.blob(dx, dy + r * 0.02, r * 0.42, 16, 153, 0.05, 0.68)
  Draw.setColor(C.body)
  Draw.blob(dx, dy + r * 0.05, r * 0.30, 15, 157, 0.05, 0.66)
  -- the feed horn on its tripod, standing off the bowl
  Draw.setColor(C.deep)
  Draw.capsule("fill", dx - r * 0.16, dy + r * 0.10, dx - r * 0.06, dy - r * 0.22, r * 0.022)
  Draw.capsule("fill", dx + r * 0.16, dy + r * 0.10, dx - r * 0.06, dy - r * 0.22, r * 0.022)
  Draw.setColor(C.lit)
  lg.circle("fill", dx - r * 0.06, dy - r * 0.24, r * 0.062)

  -- the feeder cable, trailing back down the lattice into the grass
  Draw.setColor(C.void)
  Draw.capsule("fill", dx - r * 0.24, dy + r * 0.10, r * 0.10, r * 0.26, r * 0.020)
  Draw.capsule("fill", r * 0.10, r * 0.26, -r * 0.36, r * 0.16, r * 0.020)
  Draw.capsule("fill", -r * 0.36, r * 0.16, -r * 0.66, r * 0.34, r * 0.020)
end

------------------------------------------------------------------ hauler
-- A flatbed trailer, sunk to its axles in beach sand. No cab: whatever was
-- pulling it is not here.
--
-- The first version of this lay on its side, and from a top-down camera a
-- cylinder with a dark circle on the end is a cannon. It reads from above now,
-- which is the only view the game has: a long deck, three wheels a side under
-- it, stake pockets standing up off the rails, and a drawbar at the head end
-- with nothing on it.
MODEL.hauler = function(r)
  local L, W = r * 1.05, r * 0.44

  -- the drift it is sunk into
  Draw.setColor(C.sandLo)
  Draw.blob(r * 0.10, r * 0.06, r * 1.15, 14, 161, 0.26, 0.52)

  -- wheels, under the deck and mostly buried, so only their tops show
  Draw.setColor(C.tyre)
  for i = -1, 1 do
    local x = i * r * 0.52
    Draw.capsule("fill", x - r * 0.10, -W - r * 0.02, x + r * 0.10, -W - r * 0.02, r * 0.11)
    Draw.capsule("fill", x - r * 0.10, W + r * 0.02, x + r * 0.10, W + r * 0.02, r * 0.11)
  end

  -- the deck: a dark undercarriage band with a lighter top riding on it, which
  -- is what gives a flat rectangle its couple of inches of height
  Draw.setColor(C.deep)
  Draw.roundRect("fill", -L, -W + r * 0.03, L * 2, W * 2, r * 0.05)
  Draw.setColor(C.body)
  Draw.roundRect("fill", -L, -W, L * 2, W * 2 - r * 0.04, r * 0.05)
  Draw.setColor(C.lit)
  Draw.roundRect("fill", -L + r * 0.05, -W + r * 0.04, L * 2 - r * 0.10, W * 2 - r * 0.16,
                 r * 0.03)

  -- deck planking
  Draw.setColor(C.body)
  for i = 1, 9 do
    local x = -L + (i / 10) * L * 2
    Draw.capsule("fill", x, -W + r * 0.07, x, W - r * 0.13, r * 0.012)
  end

  -- stake pockets along both rails, empty
  Draw.setColor(C.deep)
  for i = -1, 1 do
    local x = i * r * 0.46
    Draw.capsule("fill", x, -W + r * 0.02, x - r * 0.02, -W - r * 0.16, r * 0.032)
    Draw.capsule("fill", x, W - r * 0.06, x - r * 0.02, W + r * 0.12, r * 0.032)
  end

  -- the drawbar, and the eye on the end of it
  Draw.setColor(C.body)
  Draw.capsule("fill", -L, 0, -L - r * 0.44, 0, r * 0.055)
  Draw.setColor(C.lit)
  lg.circle("fill", -L - r * 0.46, 0, r * 0.075, 12)
  Draw.setColor(C.deep)
  lg.circle("fill", -L - r * 0.46, 0, r * 0.038, 10)

  -- oxide, and then the sand that has come up over the tail since
  Draw.setColor(C.rust)
  for i = 1, 3 do
    local x = -L * 0.4 + i * r * 0.34
    Draw.capsule("fill", x, -W + r * 0.06, x + r * 0.02, -W + r * 0.24, r * 0.024)
  end
  Draw.setColor(C.sandHi)
  Draw.blob(r * 0.78, r * 0.06, r * 0.46, 14, 181, 0.26, 0.46)
  Draw.setColor(C.sandLo)
  Draw.blob(-r * 0.56, r * 0.28, r * 0.34, 13, 187, 0.28, 0.38)
end

------------------------------------------------------------------ husk
-- One of your own machines, lying where it stopped.
--
-- It reads from above, lying down, long axis along +x, and it takes any heading
-- (`spin`), because a body on the ground can point anywhere and the top-down
-- camera has no opinion about it. That is the mast's and the hauler's rule, not
-- the suit's -- a thing standing up in screen space is a thing that is still
-- standing up.
--
-- The discipline is bot.lua's own, run backwards. Six silhouettes, one per type,
-- because you can name any of the six from its outline and that has to survive
-- the machine falling over: treads, a jib, three feet, a diamond head, two
-- wheels, a mast. Everything that made it a working machine is subtracted --
-- the eye is a hole, the antenna is snapped off and lying beside it, there are
-- no load pips, no charge pips, no lamp, no glow and no nameplate. A husk is
-- the only object in this file the player has a memory of, so it does not need
-- any of that; it needs to be recognisable as SEED-04 and obviously off.
--
-- Do not put a light on this one either. The dead bead on the wreck's mast is
-- the whole of that object; the dead eye is the whole of this one.
local HUSK_CUE = {}

MODEL.husk = function(r, v)
  local s = v * 613

  -- the scuff it slid to a stop in. Small: the death already dropped a scorch
  -- decal on this exact spot and `drawShadow` puts a soft contact under it.
  Draw.setColor(C.scuff)
  Draw.blob(-r * 0.06, r * 0.16, r * 0.92, 11, s + 3, 0.30, 0.40)

  -- the type's own outline, under the chassis where it belongs
  local cue = HUSK_CUE[v]
  if cue then cue(r, "under") end

  -- The chassis. Two capsules and a rim: a body seen from above lying on its
  -- side is a long lozenge with one lit face up-sun, and any more shapes than
  -- that at fourteen units is mud.
  Draw.setColor(C.huskDeep)
  Draw.capsule("fill", -r * 0.60, r * 0.06, r * 0.46, r * 0.02, r * 0.50)
  Draw.setColor(C.huskBody)
  Draw.capsule("fill", -r * 0.54, -r * 0.06, r * 0.40, -r * 0.10, r * 0.40)
  Draw.setColor(C.huskLit)
  Draw.capsule("fill", -r * 0.38, -r * 0.20, r * 0.14, -r * 0.23, r * 0.17)

  -- a seam split down the side, and the oxide already coming out of it
  Draw.setColor(C.huskDeep)
  Draw.capsule("fill", -r * 0.30, r * 0.12, r * 0.30, r * 0.08, r * 0.045)
  Draw.setColor(C.rust)
  Draw.blob(r * 0.06, r * 0.24, r * 0.30, 9, s + 11, 0.30, 0.44)

  if cue then cue(r, "over") end

  -- THE EYE. The one bright mark every machine in the crew is read by, and it
  -- is a hole. Same sentence as the suit's visor, same reason it is the only
  -- one this object says.
  Draw.setColor(C.huskRim)
  lg.circle("fill", r * 0.50, -r * 0.14, r * 0.21)
  Draw.setColor(C.huskDeep)
  lg.circle("fill", r * 0.50, -r * 0.13, r * 0.165)
  Draw.setColor(C.void)
  Draw.blob(r * 0.51, -r * 0.12, r * 0.115, 9, s + 17, 0.10, 0.82)

  -- the antenna, snapped at the root and lying where it fell
  Draw.setColor(C.deep)
  Draw.capsule("fill", -r * 0.52, -r * 0.22, -r * 0.98, -r * 0.44, r * 0.032)

  -- one hard rim up-sun, so it is a solid on the grass and not a stain
  Draw.setColor(C.huskRim)
  Draw.capsule("fill", -r * 0.40, -r * 0.34, r * 0.18, -r * 0.38, r * 0.035)
end

-- The six outlines. `pass` is "under" (before the chassis is laid over it) or
-- "over"; nothing needs both often, but the wheels and the jib do.
HUSK_CUE[1] = function(r, pass)      -- planter: treads, and the sprout it dropped
  if pass == "under" then
    Draw.setColor(C.huskDeep)
    Draw.capsule("fill", -r * 0.56, -r * 0.40, r * 0.40, -r * 0.44, r * 0.15)
    Draw.capsule("fill", -r * 0.56, r * 0.40, r * 0.40, r * 0.36, r * 0.15)
  else
    -- the seedling it was carrying, out of the cradle and dead on the ground.
    -- Drawn in the husk's own dead metal rather than in leaf green: a live
    -- sprout beside a dead machine is a hopeful image and this is not one.
    Draw.setColor(C.deep)
    Draw.capsule("fill", r * 0.60, r * 0.34, r * 1.02, r * 0.50, r * 0.035)
    Draw.setColor(C.huskDeep)
    Draw.blob(r * 1.02, r * 0.46, r * 0.14, 7, 23, 0.22, 0.60)
    Draw.blob(r * 0.86, r * 0.56, r * 0.12, 7, 29, 0.22, 0.60)
  end
end

HUSK_CUE[2] = function(r, pass)      -- builder: the jib, out flat, block on the line
  if pass ~= "over" then return end
  Draw.setColor(C.huskDeep)
  Draw.capsule("fill", -r * 0.20, -r * 0.12, -r * 1.34, -r * 0.44, r * 0.10)
  Draw.setColor(C.huskBody)
  Draw.capsule("fill", -r * 0.24, -r * 0.16, -r * 1.10, -r * 0.42, r * 0.055)
  Draw.setColor(C.deep)
  Draw.capsule("fill", -r * 1.34, -r * 0.44, -r * 1.52, -r * 0.10, r * 0.028)
  Draw.setColor(C.huskLit)
  Draw.blob(-r * 1.54, -r * 0.04, r * 0.13, 6, 31, 0.10, 0.86)
end

HUSK_CUE[3] = function(r, pass)      -- repulsor: three feet, and a dark emitter ring
  if pass == "under" then
    Draw.setColor(C.huskDeep)
    for i = 0, 2 do
      local a = i * TAU / 3 + 0.7
      Draw.capsule("fill", -r * 0.30, 0, -r * 0.30 + cos(a) * r * 0.78,
                   sin(a) * r * 0.52, r * 0.12)
    end
  else
    -- the ring is the whole silhouette of a Repulsor and it is unlit here:
    -- a dark annulus rather than the cyan hoop the player builds
    Draw.setColor(C.huskBody)
    lg.circle("fill", r * 0.86, -r * 0.02, r * 0.36)
    Draw.setColor(C.void)
    lg.circle("fill", r * 0.86, -r * 0.02, r * 0.24)
  end
end

HUSK_CUE[4] = function(r, pass)      -- sentry: the diamond head, and the barrel
  if pass ~= "over" then return end
  Draw.setColor(C.huskBody)
  Draw.diamond(r * 0.72, -r * 0.16, r * 0.36, r * 0.30, "fill")
  Draw.setColor(C.huskDeep)
  Draw.capsule("fill", r * 0.86, -r * 0.20, r * 1.44, -r * 0.34, r * 0.10)
  Draw.setColor(C.void)
  lg.circle("fill", r * 1.46, -r * 0.35, r * 0.062)
end

HUSK_CUE[5] = function(r, pass)      -- harvester: wheels, one of them off the axle
  if pass == "under" then
    Draw.setColor(C.huskDeep)
    lg.circle("fill", -r * 0.34, -r * 0.44, r * 0.28)
    Draw.setColor(C.tyre)
    lg.circle("fill", -r * 0.34, -r * 0.44, r * 0.18)
  else
    Draw.setColor(C.huskDeep)
    lg.circle("fill", r * 0.94, r * 0.44, r * 0.28)
    Draw.setColor(C.tyre)
    lg.circle("fill", r * 0.94, r * 0.44, r * 0.18)
    -- the scoop, bent back under it
    Draw.setColor(C.huskBody)
    Draw.capsule("fill", -r * 0.62, r * 0.30, r * 0.24, r * 0.36, r * 0.09)
  end
end

HUSK_CUE[6] = function(r, pass)      -- beacon: the mast down, the lantern dark
  if pass ~= "over" then return end
  Draw.setColor(C.huskDeep)
  Draw.capsule("fill", -r * 0.30, -r * 0.10, -r * 1.30, -r * 0.30, r * 0.09)
  Draw.setColor(C.huskBody)
  Draw.roundRect("fill", -r * 1.62, -r * 0.52, r * 0.42, r * 0.42, r * 0.12)
  Draw.setColor(C.void)
  Draw.roundRect("fill", -r * 1.56, -r * 0.46, r * 0.30, r * 0.30, r * 0.10)
end

---------------------------------------------------------------------- kinds
-- `ground` means the thing has no height: it is painted in the ground pass with
-- the shadows, under every entity and every tree, instead of being sorted into
-- the depth list by its feet.
-- `spin` means it lies flat and may take any heading; the rest stand up in
-- screen space and are only ever mirrored.
local KIND = {
  wreck  = { radius = 46, variants = 1, shadow = { 1.20, 0.50, 0.42 } },
  road   = { radius = 78, variants = 3, ground = true, spin = true,
             halfLen = function() return TU.relic.road.segLen * 0.5 + TU.relic.road.overlap end },
  suit   = { radius = 30, variants = 4, shadow = { 1.15, 0.36, 0.32 } },
  pallet = { radius = 38, variants = 1, shadow = { 0.92, 0.28, 0.34 } },
  mast   = { radius = 76, variants = 1, spin = true, shadow = { 0.80, 0.20, 0.26 } },
  hauler = { radius = 46, variants = 1, spin = true, shadow = { 1.05, 0.40, 0.30 } },
  -- One variant per bot type, and it lies flat, so it spins like the mast.
  husk   = { radius = 20, variants = 6, spin = true, shadow = { 1.05, 0.44, 0.34 } },
}
Relic.KIND = KIND

-- kind .. variant -> baked shape, built on first draw and kept for the session
local baked = {}

--------------------------------------------------------------------- entity
function Relic:init(x, y, what, variant, angle, flip, scale)
  Relic.super.init(self, x, y)
  local k = KIND[what]
  self.kind    = "relic"
  self.what    = what
  self.variant = variant or 1
  -- Per-instance size, and there is exactly one caller: the near-band suit,
  -- which is drawn half again as big so that one of the seven is legible at
  -- play zoom rather than only at 5x in the gallery. The bake is per kind and
  -- variant and knows nothing about it -- `Draw.replay` takes a scale, so the
  -- shared point list is replayed larger. The shadow and the planting exclusion
  -- scale with it, because both are properties of how big the thing looks.
  self.scale   = scale or 1
  self.radius  = k.radius * self.scale
  self.angle   = k.spin and (angle or 0) or 0
  self.flip    = flip and true or false
  self.ground  = k.ground or false
  -- 1 unless something retires it; only husks ever set it. See `Relic.addHusk`.
  self.alpha   = 1
  self.noPlant = (TU.relic.noPlant[what] or k.radius) * self.scale
  -- Half-length along the object's own heading. A relic with one of these is
  -- excluded from planting as a CAPSULE rather than as a disc: a road segment
  -- is a hundred and fifty units long, and a disc at its centre left trees
  -- standing in the carriageway everywhere but the middle of each piece --
  -- which, in a nine-hundred-tree forest, is a road you cannot see at all.
  self.halfLen = k.halfLen and k.halfLen(k.radius) or 0
  -- The wreck is a rig and sorts like one: homerig.lua carries z = -6 so a
  -- machine standing among trees does not get sorted behind the one growing
  -- out of its own footprint.
  self.z = (what == "wreck") and -6 or 0
  self.shadow = k.shadow
  -- The baked picture, resolved once per instance and then held. `shape()`
  -- builds its cache key by concatenation, and a string built per relic per
  -- frame is exactly the allocation PERFORMANCE_SPEC F5 went hunting for in
  -- `Text.display`. The bake itself is still shared per kind and variant, so
  -- four suits hold three point lists between them, not four copies.
  self._shape = self:shape()
end

--- The point lists for one kind and variant, baked on first ask and kept for
--- the session. Model builders take `(radius, variant)` and nothing else, so
--- one bake serves every instance of a kind.
function Relic:shape()
  local key = self.what .. self.variant
  local s = baked[key]
  if s == nil then
    s = Draw.bake(MODEL[self.what], KIND[self.what].radius, self.variant) or false
    baked[key] = s
  end
  return s
end

--- `Draw.replay` sets each primitive's own recorded colour and has no alpha
--- multiplier, which is right for everything in this file except a husk being
--- retired. A baked shape is a list of `{r, g, b, a, points}` (see `Draw.bake`),
--- so replaying one at a weight is five lines here rather than a new parameter
--- on the function the entire game draws through. Only reached when a husk is
--- actually faded; everything else takes `Draw.replay` unchanged.
local function replayFaded(shape, a)
  for i = 1, #shape do
    local p = shape[i]
    lg.setColor(p[1], p[2], p[3], p[4] * a)
    lg.polygon("fill", p[5])
  end
end

function Relic:paint()
  local s = self._shape
  if not s then return end
  lg.push()
  lg.translate(self.x, self.y)
  if self.angle ~= 0 then lg.rotate(self.angle) end
  if self.flip then lg.scale(-1, 1) end
  if self.scale ~= 1 then lg.scale(self.scale) end
  if self.alpha < 1 then replayFaded(s, self.alpha) else Draw.replay(s) end
  lg.pop()
end

--- The ground pass.
---
--- `World:draw` walks the mobile lists here, straight after the forest's own
--- contact shadows and before anything is sorted, which is exactly where a road
--- surface and a landing deck belong -- they are ground, not objects standing on
--- it. Everything with height takes an ordinary soft shadow here instead and
--- paints itself in the sorted pass below.
---
--- One known and accepted cost: a tree's contact shadow is drawn just before
--- this, so where a canopy overhangs the road the shadow is painted over by the
--- road surface. Planting is excluded from the carriageway, so it is a verge
--- effect at most, and it is invisible against a band this dark.
function Relic:drawShadow()
  if self.ground then self:paint() return end
  local sh = self.shadow
  if not sh then return end
  Draw.softShadow(self.x, self.y + self.radius * 0.10,
                  self.radius * sh[1], self.radius * sh[2], sh[3] * self.alpha)
end

function Relic:draw()
  if self.ground then return end
  self:paint()
end

-- Deliberately absent: `update`, `emitLight`, `onTouch`, and any signal at all.
-- A relic is not swept, does not tick, lights nothing and is not told when
-- something walks over it. See the header.

------------------------------------------------------------------- placement
--- Squared distance, spelled out because this runs inside the placement retry
--- loops a few thousand times at world generation.
local function d2(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return dx * dx + dy * dy
end

--- Is (x, y) far enough from everything already placed? Two relics never share
--- a clearing: a pallet leaning against a wreck next to a suit is a diorama, and
--- a diorama is a thing somebody arranged for you to find.
local function clearOfOthers(list, x, y, what)
  local T = TU.relic
  for i = 1, #list do
    local o = list[i]
    -- `sameKindBy` is the per-kind exception to `sameKind`, and there is one
    -- entry in it. See the tuning note: two suits in a field is a fact, and the
    -- blanket rule that stopped it was costing more than it bought.
    local sep = (o.what == what) and (T.sameKindBy[what] or T.sameKind)
                or T.separation
    if o.what == "road" or what == "road" then sep = T.roadClear end
    if what == "road" and o.what == "road" then sep = 0 end
    if sep > 0 then
      local dx, dy = x - o.x, y - o.y
      if o.halfLen > 0 then
        local ca, sa = cos(o.angle), sin(o.angle)
        local t = U.clamp(dx * ca + dy * sa, -o.halfLen, o.halfLen)
        dx, dy = dx - ca * t, dy - sa * t
      end
      if dx * dx + dy * dy < sep * sep then return false end
    end
  end
  return true
end

--- Everything a spot has to be: on land, out of the surf, off the player's own
--- doorstep, and not on top of another relic.
local function usable(w, list, x, y, what)
  local T, t = TU.relic, w.terrain
  if t then
    if t.isLand and not t:isLand(x, y) then return false end
    if t.shoreDistAt and t:shoreDistAt(x, y) < T.minShore then return false end
  else
    if x < 120 or y < 120 or x > TU.world.w - 120 or y > TU.world.h - 120 then return false end
  end
  if d2(x, y, w.homeX, w.homeY) < T.homeClear * T.homeClear then return false end
  return clearOfOthers(list, x, y, what)
end

--- A spot in an annulus around the Home Rig, inside a given arc. This is how
--- the two or three a player is guaranteed to meet get placed: inside the
--- valley they wake up in, but never so close that they read as part of the rig.
---
--- The arc is the important half. Placed at free angles inside one annulus,
--- the road, the suit and the pallet can all land on the same side of the rig
--- and share a single screen -- and three of these in one frame is a heap,
--- which reads as a level designer rather than as an island. The caller hands
--- each of them a third of the compass, so they are met one at a time.
local function pickNear(w, list, rng, what, lo, hi, a0, span, score)
  local bx, by, bs = nil, nil, -math.huge
  for _ = 1, TU.relic.tries do
    local a = (a0 or 0) + rng:next() * (span or TAU)
    local d = rng:range(lo, hi)
    local x, y = w.homeX + cos(a) * d, w.homeY + sin(a) * d
    if usable(w, list, x, y, what) then
      if not score then return x, y end
      local sc = score(x, y)
      if sc > bs then bx, by, bs = x, y, sc end
    end
  end
  return bx, by
end

--- Poor ground: thin soil, and the rockier the better.
---
--- This is how the empty suits stay visible without denying half the island.
--- The occlusion problem is brutal -- a canopy is drawn above its trunk, so a
--- mature tree a hundred and fifty units SOUTH of a thirty-unit figure buries
--- it completely, and an exclusion radius wide enough to guarantee otherwise
--- costs a fifth of the plantable ground and measurably shortens the forest.
---
--- So the suits, and the pallets with them, are placed where the wood was never
--- going to close anyway: on and beside the island's stone, which
--- `T.tree.barrenBiomes` already refuses. The clearing is free, it costs the
--- forest nothing, and for both objects it is the reading they wanted in the
--- first place -- somebody sat down against a rock, and a tonne of cylinders
--- gets set down on hard standing rather than in a bog. Rock outcrops run all
--- through the meadows, so this is still a suit in the middle of a field the
--- player is planting; it is just a field with a rock in it.
local function poorGround(w)
  local t = w.terrain
  if not (t and t.soilAt) then return nil end
  return function(x, y)
    local slope = (t.slopeAt and t:slopeAt(x, y)) or 0
    return (1 - t:soilAt(x, y)) + slope * 0.35
  end
end

--- A spot anywhere on the island, optionally scored: `score(x, y)` returns a
--- number and the best-scoring valid candidate wins. That is how the second rig
--- ends up as far from yours as the island allows and the hauler ends up on a
--- beach, without either of them needing a hand-placed coordinate.
local LANDOPT = { minShore = 0, tries = 12 }
local function pickBest(w, list, rng, what, score, minFromHome)
  local bx, by, bs = nil, nil, -math.huge
  local t = w.terrain
  LANDOPT.minShore = TU.relic.minShore
  for _ = 1, TU.relic.tries do
    local x, y
    if t and t.randomLandPoint then
      x, y = t:randomLandPoint(rng, LANDOPT)
    else
      x, y = rng:range(200, TU.world.w - 200), rng:range(200, TU.world.h - 200)
    end
    if x and usable(w, list, x, y, what) then
      local ok = true
      if minFromHome then
        ok = d2(x, y, w.homeX, w.homeY) >= minFromHome * minFromHome
      end
      if ok then
        local s = score and score(x, y) or 0
        if s > bs then bx, by, bs = x, y, s end
      end
    end
  end
  return bx, by
end

local function add(w, list, what, x, y, variant, angle, flip, scale)
  if not x then return nil end
  local rel = Relic.new(x, y, what, variant, angle, flip, scale)
  list[#list + 1] = rel
  return rel
end

--- The road. An anchor a short walk from the rig, a heading, and then segments
--- laid both ways until the land runs out. It is deliberately the one relic the
--- player cannot avoid: he parked next to it.
local function layRoad(w, list, rng, bearing, span)
  local RD, T = TU.relic.road, TU.relic
  local ax, ay = pickNear(w, list, rng, "road", T.near.road[1], T.near.road[2],
                          bearing, span)
  if not ax then return end
  -- ...and it runs across the rig's bearing rather than away along it, so a
  -- road anchored to one side of the valley still crosses the whole of it.
  local base = bearing + math.pi * 0.5 + (rng:next() - 0.5) * 0.8
  local step = RD.segLen
  for dir = -1, 1, 2 do
    local x, y = ax, ay
    local a = base + ((dir < 0) and math.pi or 0)
    for i = 1, RD.perSide do
      x = x + cos(a) * step
      y = y + sin(a) * step
      local t = w.terrain
      local ok = true
      if t then
        if t.isLand and not t:isLand(x, y) then ok = false end
        if ok and t.shoreDistAt and t:shoreDistAt(x, y) < RD.width then ok = false end
      end
      if not ok then break end
      -- the heading drifts, so it is a road and not a ruler
      a = a + (rng:next() - 0.5) * 2 * RD.curve
      add(w, list, "road", x, y, rng:int(1, RD.variants), a, false)
    end
  end
  -- and the anchor segment itself, laid last so it sits over both joins
  add(w, list, "road", ax, ay, rng:int(1, RD.variants), base, false)
end

--- Place every relic on this island. Called once, from World:init, after the
--- Home Rig has a position and before anything has ticked.
function Relic.populate(w)
  local T = TU.relic
  local list = w.relics
  -- The kill switch, and the only one. `BOTS_NO_RELICS=1` leaves the island
  -- empty of them, which is how the frame cost of this whole file is measured
  -- against itself with `tools/perf.sh` -- there is nothing else to ablate,
  -- because nothing here ticks.
  local cfg = _G.BOTS_CFG
  if cfg and cfg("BOTS_NO_RELICS") then return list end
  local t = w.terrain
  -- Our own stream. See the note in tuning: spending `w.rng` here would move
  -- every island in the game and invalidate every balance trace taken before it.
  local rng = U.rng((w.seed or 1337) * 7919 + T.seedSalt)
  local hx, hy = w.homeX, w.homeY
  local x, y

  -- One compass, divided in three. See `pickNear`.
  local bearing = rng:angle()
  local third = TAU / 3

  -- The road first: everything else has to keep clear of it, and it is the one
  -- relic whose position is nearly forced.
  layRoad(w, list, rng, bearing, third)

  -- The second rig, as far away as the island allows. This is the object the
  -- whole set exists for and it must never be the first one you find.
  x, y = pickBest(w, list, rng, "wreck",
                  function(px, py) return d2(px, py, hx, hy) end, T.wreckMin)
  add(w, list, "wreck", x, y, 1, 0, rng:chance(0.5))

  -- ONE SUIT INSIDE THE VALLEY, and it is the big one. A player who never goes
  -- looking is guaranteed to meet this object, so it is the one that has to
  -- survive play zoom: `T.relic.suitNear.scale` draws it half again as large.
  -- Poses 1-3 only -- the helmet-off pose is placed once, further down, and it
  -- would be wasted on the suit the player is most likely to see first.
  x, y = pickNear(w, list, rng, "suit", T.near.suit[1], T.near.suit[2],
                  bearing + third, third, poorGround(w))
  add(w, list, "suit", x, y, rng:int(1, 3), 0, rng:chance(0.5), T.suitNear.scale)

  x, y = pickNear(w, list, rng, "pallet", T.near.pallet[1], T.near.pallet[2],
                  bearing + third * 2, third, poorGround(w))
  add(w, list, "pallet", x, y, 1, 0, rng:chance(0.5))

  -- The mast, on the highest ground that will take it, because that is where a
  -- relay goes.
  x, y = pickBest(w, list, rng, "mast", function(px, py)
    return (t and t.heightAt) and t:heightAt(px, py) or 0
  end, T.far.mast[1])
  add(w, list, "mast", x, y, 1, rng:angle(), rng:chance(0.5))

  -- The hauler, on the beach: the best candidate is the one closest to the
  -- water that is still on dry land.
  -- ...and kept out past `scatterMin`, because a trailer parked three hundred
  -- units from the rig reads as the player's own kit rather than as somebody
  -- else's.
  x, y = pickBest(w, list, rng, "hauler", function(px, py)
    return -((t and t.shoreDistAt) and t:shoreDistAt(px, py) or 0)
  end, T.scatterMin)
  add(w, list, "hauler", x, y, 1, rng:angle(), rng:chance(0.5))

  -- The rest of the suits, scattered. Nothing steers these toward anything:
  -- they are wherever the island had room.
  --
  -- EXACTLY ONE of them takes the helmet-off pose, chosen by index rather than
  -- rolled for. It is the only object in the set that makes a claim about what
  -- somebody did, so a random one-in-four that sometimes lands twice and
  -- sometimes never lands at all is the wrong instrument: two of them on one
  -- island turns a statement into a motif.
  local offPose = T.suitHelmetOff
  for i = 2, T.count.suit do
    x, y = pickBest(w, list, rng, "suit", poorGround(w), T.scatterMin)
    local v = (i == offPose) and 4 or rng:int(1, 3)
    add(w, list, "suit", x, y, v, 0, rng:chance(0.5))
  end
  for _ = 2, T.count.pallet do
    x, y = pickBest(w, list, rng, "pallet", poorGround(w), T.scatterMin)
    add(w, list, "pallet", x, y, 1, 0, rng:chance(0.5))
  end

  return list
end

------------------------------------------------------------------------ husks
-- Variant per bot type. A type this table does not know draws as a Planter,
-- which is the plainest of the six and the right thing to be wrong as.
local HUSK_V = { planter = 1, builder = 2, repulsor = 3, sentry = 4,
                 harvester = 5, beacon = 6 }

--- Recompute every husk's alpha from its place in the queue.
---
--- `w.husks` is the husks in the order they died, oldest first. A husk is
--- retired when `cap` newer ones have arrived on top of it, and it spends its
--- last `fade` deaths going out, so the island never pops a body away in front
--- of somebody. Nothing fades while there is headroom: with a cap of 30 and a
--- fade of 8, a run that loses a dozen machines has twelve husks at full
--- strength and no arithmetic anybody can see.
---
--- Runs once per death over at most `cap` entries.
local function refreshHusks(w)
  local list = w.husks
  if not list then return end
  local H, k = TU.relic.husk, #list
  for i = 1, k do
    local remaining = i + (H.cap - k)      -- deaths left before this one goes
    local t = remaining / H.fade
    if t > 1 then t = 1 end
    list[i].alpha = H.floor + (1 - H.floor) * t
  end
end

--- Leave a body where a machine died. Called from world.lua's `bot:lost`
--- handler, and it is the only thing in this file a run can add.
---
--- Deterministic pose: the heading and the mirror come out of the position
--- rather than out of an RNG, so two runs of the same seed that lose the same
--- machine in the same place lay it down the same way, and nothing here spends
--- from a stream the balance traces depend on.
function Relic.addHusk(w, x, y, botType)
  if not (w and w.relics and x) then return nil end
  local H = TU.relic.husk
  if not H or H.cap <= 0 then return nil end
  -- Same kill switch as the rest of the file: `BOTS_NO_RELICS=1` is how the
  -- frame cost of all of this is measured against itself.
  local cfg = _G.BOTS_CFG
  if cfg and cfg("BOTS_NO_RELICS") then return nil end

  local list = w.husks
  if not list then list = {} w.husks = list end

  -- ONE BODY PER PLACE. A perimeter that fails, fails repeatedly and in the
  -- same spot: a traced run put eight husks inside twenty world units, two of
  -- them on identical coordinates, and eight overlapping lozenges is not a
  -- history, it is a heap with z-fighting in it. If somewhere is already
  -- marked, it stays marked and this loss is recorded by the memorial instead,
  -- which is the thing that keeps the ledger. The walk is over at most `cap`
  -- entries and runs on a death.
  local g = H.minGap
  if g > 0 then
    local g2 = g * g
    for i = 1, #list do
      if d2(x, y, list[i].x, list[i].y) < g2 then return nil end
    end
  end

  local s = floor(x * 0.5) + floor(y * 0.5) * 977
  local rel = Relic.new(x, y, "husk", HUSK_V[botType] or 1,
                        hash(1, s) * TAU, hash(2, s) < 0.5)
  -- Remembered so the save can write down what this was without reversing
  -- HUSK_V. The angle and the flip are hashed off the floored coordinates
  -- above, so (x, y, botType) is the whole husk: replaying those three numbers
  -- on load rebuilds this exact one rather than a similar one.
  rel.botType = botType
  w.relics[#w.relics + 1] = rel
  list[#list + 1] = rel

  -- Retirement. The oldest comes out of both lists; `w.relics` is a couple of
  -- dozen entries and this runs on a death, so a linear find is cheaper than
  -- any index that would have to be kept.
  while #list > H.cap do
    local old = table.remove(list, 1)
    for i = 1, #w.relics do
      if w.relics[i] == old then table.remove(w.relics, i) break end
    end
  end
  refreshHusks(w)
  return rel
end

--- Would a sapling here be standing inside a relic? `World:plantTree` asks this
--- last, after the cheap terrain rejections, so a forest closes around a wreck
--- instead of over it and the thing is still there at the ending.
---
--- A linear walk: there are about twenty relics on an island and planting
--- happens a handful of times a second, so an index would cost more to keep
--- than it saves.
function Relic.blocksPlantingAt(w, x, y)
  local list = w.relics
  if not list then return false end
  for i = 1, #list do
    local o = list[i]
    local dx, dy = x - o.x, y - o.y
    local h = o.halfLen
    if h > 0 then
      -- project onto the segment's own axis and clamp: distance to a capsule
      local ca, sa = cos(o.angle), sin(o.angle)
      local t = U.clamp(dx * ca + dy * sa, -h, h)
      dx, dy = dx - ca * t, dy - sa * t
    end
    local n = o.noPlant
    if dx * dx + dy * dy < n * n then return true end
  end
  return false
end

return Relic
