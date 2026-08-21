-- The clock that drives every visual in the game.
--
-- Owns the continuous time-of-day state: sun direction and shadow length, the
-- ambient colour and strength, the atmosphere/fog, the exposure and grade the
-- post chain should run, and the star/moon fade. Nothing here snaps: every
-- value is interpolated between the `P.tod` anchors so a phase change is a
-- slow bruise, not a cut.
--
--   DayNight.set("dusk", 0.4)      -- driven by the cycle manager
--   DayNight.update(dt)            -- advances flicker/auto clock, recomputes
--   DayNight.apply(Post, Lighting) -- pushes grade + ambient into the renderers
--
-- All exported colours are persistent tables that are mutated in place: read
-- them, never keep a reference expecting it to stay still, and never allocate.
local U = require("src.core.util")
local P = require("src.engine.palette")

-- Resolved lazily: postfx pulls in the palette, and this file is required from
-- places that have no graphics context yet.
local Post

local DN = {}

------------------------------------------------------------------ cycle layout
-- Fractions of one full cycle. The clock runs day -> dusk -> night -> dawn.
local NEXT  = { day = "dusk", dusk = "night", night = "dawn", dawn = "day" }
local SPAN  = { day = 0.40,   dusk = 0.12,    night = 0.36,   dawn = 0.12 }
local START = { day = 0.00,   dusk = 0.40,    night = 0.52,   dawn = 0.88 }

-- Scalar lighting response per phase. The *colours* all come from P.tod; these
-- are the numbers the palette does not carry.
local AMB    = { day = 1.06, dusk = 0.52, night = 0.40, dawn = 0.70 } -- ambient strength
local CONTR  = { day = 1.06, dusk = 1.12, night = 1.20, dawn = 1.06 } -- grade contrast
-- How much of the phase's hue goes into the *ambient* (which multiplies albedo)
-- rather than into the grade. Pushing a saturated hue through a multiply is what
-- makes a sunset look like mud, so the warm phases keep the ambient near-neutral
-- and let the grade carry the colour; night keeps its blue, because moonlight
-- really does recolour everything it touches.
local AMBTINT = { day = 0.26, dusk = 0.55, night = 0.96, dawn = 0.50 }
-- Saturation is the main thing that separates the phases. Day is *more*
-- saturated than the raw albedo, so noon reads as a bright stylised frame and
-- not as a photograph; night keeps enough chroma to stay blue rather than grey,
-- and leans on the ambient hue and the warm pools to say "night".
local SATU   = { day = 1.22, dusk = 0.94, night = 0.86, dawn = 1.04 } -- grade saturation
local GAIN   = { day = 0.03, dusk = 0.14, night = 0.30, dawn = 0.09 } -- additive light gain
local BLOOM  = { day = 0.55, dusk = 0.90, night = 1.15, dawn = 0.78 } -- bloom response

-- The transition occupies the tail of each phase, so a phase reads as itself for
-- most of its length and then turns. smootherstep keeps the first and second
-- derivative calm across the boundary.
-- Day and night are the phases the player *lives* in, so they hold their look
-- almost to the end; dusk and dawn exist to be transitions, so they start
-- turning immediately.
local TURN_AT = { day = 0.76, dusk = 0.10, night = 0.80, dawn = 0.15 }

------------------------------------------------------------------ public state
DN.phase   = "day"
DN.t       = 0            -- 0..1 progress through the current phase
DN.clock   = 0            -- 0..1 position in the whole cycle (continuous)
DN.auto    = false        -- when true, update(dt) advances the clock itself
DN.durations = { day = 80, dusk = 12, night = 70, dawn = 10 }
DN.time    = 0            -- seconds since load; drives flicker/twinkle

DN.sunAngle  = math.pi * 0.5   -- radians; the direction shadows are cast toward
DN.sunLength = 0.5             -- 0..1 shadow length multiplier
DN.sunHeight = 1               -- -1..1, +1 = overhead sun, -1 = overhead moon

DN.ambient         = { 1, 1, 1, 1 }
DN.ambientStrength = 1
DN.sunColor        = { 1, 1, 1, 1 }   -- colour of the key light (sun or moon)
DN.exposure        = 1
DN.fogColor        = { 1, 1, 1, 1 }
DN.fogStrength     = 0
DN.skyTint         = { 1, 1, 1, 1 }   -- grades the whole frame
DN.lift            = { 0, 0, 0, 1 }   -- shadow tint pushed in by the grade
DN.contrast        = 1
DN.saturation      = 1
DN.lightGain       = 0.3              -- how hot light pools read over the scene
DN.bloom           = 0.6
DN.starAlpha       = 0
DN.moonAlpha       = 0
DN.o2              = 0.18             -- 0..1, drives the "cleaning sky"

-- scratch, never reallocated
local mixA = { 0, 0, 0, 1 }

local function mixInto(out, a, b, t)
  out[1] = a[1] + (b[1] - a[1]) * t
  out[2] = a[2] + (b[2] - a[2]) * t
  out[3] = a[3] + (b[3] - a[3]) * t
  out[4] = 1
  return out
end

local function lerp(a, b, t) return a + (b - a) * t end

--------------------------------------------------------------------- the maths
--- Recompute every derived value from `DN.phase` / `DN.t`. Cheap; called on set
--- and every update.
local function recompute()
  local p  = DN.phase
  local nx = NEXT[p]
  local a, b = P.tod[p], P.tod[nx]
  local w = U.smootherstep(TURN_AT[p] or 0.5, 1.0, DN.t)

  DN.clock = (START[p] + SPAN[p] * DN.t) % 1

  -- ambient / atmosphere -----------------------------------------------------
  mixInto(mixA, a.amb, b.amb, w)
  mixInto(DN.ambient, P.white, mixA, lerp(AMBTINT[p], AMBTINT[nx], w))
  mixInto(DN.fogColor, a.fog, b.fog, w)
  DN.exposure        = lerp(a.exposure, b.exposure, w)
  DN.fogStrength     = lerp(a.strength, b.strength, w)
  DN.ambientStrength = lerp(AMB[p],   AMB[nx],   w)
  DN.contrast        = lerp(CONTR[p], CONTR[nx], w)
  DN.saturation      = lerp(SATU[p],  SATU[nx],  w)
  DN.lightGain       = lerp(GAIN[p],  GAIN[nx],  w)
  DN.bloom           = lerp(BLOOM[p], BLOOM[nx], w)

  -- sun geometry -------------------------------------------------------------
  -- One rotation per cycle: the moon is therefore always opposite the sun, and
  -- shadows sweep continuously instead of flipping at a phase boundary.
  local noon = START.day + SPAN.day * 0.5
  local swing = (DN.clock - noon) * U.TAU
  DN.sunHeight = math.cos(swing)
  DN.sunAngle  = (math.pi * 0.5 + swing) % U.TAU
  local low    = 1 - math.abs(DN.sunHeight)         -- 1 when the key light is low
  DN.sunLength = U.saturate(0.30 + 0.70 * low ^ 0.7)

  -- key light colour: the ambient hue, pushed warm when low and toward the
  -- moon's steel when the sun is below the horizon.
  local night = U.saturate(-DN.sunHeight)
  mixInto(DN.sunColor, DN.ambient, P.ramp.ember[4], low * 0.45 * (1 - night))
  mixInto(DN.sunColor, DN.sunColor, P.ramp.metal[4], night * 0.55)

  -- oxygen: a dead sky is brown, hazy and flat; a healthy one is clean and blue.
  -- The *floor* of this ramp matters more than the ceiling: cycle 1 is the first
  -- impression, so a dead sky may only ever be slightly hazier and slightly
  -- flatter than a live one, never dingy.
  local o2 = DN.o2
  mixInto(DN.fogColor, DN.fogColor, P.ramp.cobalt[3], 0.18 * o2)
  DN.fogStrength = DN.fogStrength * lerp(1.06, 0.66, o2)
  DN.saturation  = DN.saturation * lerp(0.97, 1.08, o2)
  DN.exposure    = DN.exposure * lerp(1.00, 1.05, o2)

  -- the grade tint: mostly the atmosphere, pulled toward the ambient so lit
  -- surfaces do not turn to fog.
  mixInto(DN.skyTint, DN.fogColor, DN.ambient, 0.45)
  mixInto(DN.skyTint, DN.skyTint, P.ramp.cobalt[4], 0.06 * o2)

  -- shadows take the sky's colour, strongest when the ambient is weakest. This
  -- is the *floor* of the frame: at night it is the difference between a scene
  -- you can read the silhouettes in and a black rectangle with lamps on it.
  local liftAmt = 0.30 * U.saturate(1 - DN.ambientStrength) + 0.018
  DN.lift[1] = DN.skyTint[1] * liftAmt
  DN.lift[2] = DN.skyTint[2] * liftAmt
  DN.lift[3] = DN.skyTint[3] * liftAmt

  -- sky bodies ---------------------------------------------------------------
  DN.starAlpha = U.saturate((0.70 - DN.ambientStrength) / 0.40) ^ 1.4
  DN.moonAlpha = U.saturate((0.96 - DN.ambientStrength) / 0.58)

  -- The split-tone highlight is the other half of the grade, and the scenes that
  -- drive setGrade() by hand have no reason to know that. Push it from here so
  -- the key-light colour is never silently left at white.
  if Post == nil then Post = require("src.engine.postfx") end
  if Post.setSplit then Post.setSplit(DN.sunColor, 0.78) end
end
DN.recompute = recompute

---------------------------------------------------------------------- setters
--- Jump the clock to `phase` at `t01` progress through it. This is the hook the
--- cycle manager drives; it never snaps because every consumer reads the
--- interpolated values, not the phase name.
function DN.set(phase, t01)
  if P.tod[phase] == nil then phase = "day" end
  DN.phase = phase
  DN.t = U.saturate(t01 or 0)
  recompute()
end

--- Set the cycle position directly (0..1 across day+dusk+night+dawn).
function DN.setClock(c)
  c = c % 1
  local best, bestT = "day", 0
  for name, s in pairs(START) do
    local rel = (c - s) % 1
    if rel < SPAN[name] then best, bestT = name, rel / SPAN[name] end
  end
  DN.set(best, bestT)
end

--- Oxygen percentage (0..100). As the forest breathes, the sky cleans up: less
--- haze, more saturation, a cooler and bluer atmosphere.
function DN.o2Influence(pct)
  DN.o2 = U.saturate((pct or 0) / 100)
  recompute()
  return DN.o2
end

--- Seconds the current phase should last (used by auto mode and by HUD readouts).
function DN.phaseLength() return DN.durations[DN.phase] or 60 end

function DN.update(dt)
  DN.time = DN.time + dt
  if DN.auto then
    local len = DN.phaseLength()
    local t = DN.t + dt / (len > 0 and len or 1)
    local phase = DN.phase
    while t >= 1 do
      t = t - 1
      phase = NEXT[phase]
    end
    DN.phase, DN.t = phase, t
  end
  recompute()
end

------------------------------------------------------------------- convenience
--- Push the current state into the light accumulator and the post chain. Saves
--- every scene repeating the same five lines.
function DN.apply(Post, Lighting)
  if Lighting then
    Lighting.setAmbient(DN.ambient, DN.ambientStrength)
    Lighting.setLightGain(DN.lightGain)
    Lighting.addSunShadowParams(DN.sunAngle, DN.sunLength)
  end
  if Post then
    Post.setGrade(DN.skyTint, DN.exposure, DN.contrast, DN.saturation, DN.lift)
    Post.setBloom(DN.bloom)
    Post.setFog(DN.fogColor, DN.fogStrength)
    Post.setSplit(DN.sunColor, 0.75)
  end
end

--- Shadow offset for something `height` units tall, in world units.
function DN.shadowOffset(height)
  local l = (height or 16) * DN.sunLength
  return math.cos(DN.sunAngle) * l, math.sin(DN.sunAngle) * l * 0.62
end

recompute()
return DN
