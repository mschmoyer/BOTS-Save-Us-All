-- A single global wind field for the whole world.
--
-- Every swaying thing (trees, grass, banners, smoke) samples this instead of
-- running its own oscillator, so a gust visibly *travels* across the forest
-- rather than each tree wobbling on its own clock.
--
-- The field is:
--   * two scrolling sine octaves aligned to the prevailing direction
--     (cheap, smooth, C-infinity, and identical on CPU and GPU),
--   * plus up to `maxGusts` travelling gust fronts - a gaussian band that
--     sweeps along its own axis at speed, so you see the ripple arrive.
--
-- Wind.at() is called ~2x per on-screen tree per frame, so it is written to
-- allocate nothing and to cost 4 sines + a few exps.
local U = require("src.core.util")

local sin, cos, exp, atan2 = math.sin, math.cos, math.exp, math.atan2

------------------------------------------------------------------ tuning
-- PROPOSED for tuning.lua as `T.wind` - kept local so tuning.lua stays owned
-- by its author. Everything the wind does is in this block.
local TUNE = {
  baseStrength = 0.40,        -- resting wind 0..1
  strengthWave = 0.16,        -- how much the resting wind breathes
  strengthRate = 0.09,        -- breath speed

  dirBase      = 0.42,        -- prevailing direction, radians
  dirWander    = 0.30,        -- +/- radians of slow direction drift
  dirRate      = 0.037,

  -- octave 1: long, slow ground swell
  f1 = 1 / 620, s1 = 1.15, a1 = 0.64,
  -- octave 2: short, quick chop
  f2 = 1 / 155, s2 = 2.45, a2 = 0.36,
  crossWarp = 1.65,           -- how much the cross-wind coordinate warps octave 1

  gustEvery    = { 6.5, 15.0 },   -- seconds between automatic gusts
  gustStrength = { 0.40, 0.95 },
  gustWidth    = 300,             -- half-width of the front in world units
  gustSpeed    = 900,             -- world units / second the front travels
  gustRipple   = 5.5,             -- ripple frequency inside the front
  span         = 4600,            -- how far a front travels before it dies
  maxGusts     = 4,
  autoGusts    = true,

  canopyLag    = 0.15,            -- default seconds the canopy trails the trunk
}

------------------------------------------------------------------ state
local Wind = {
  time         = 0,
  direction    = TUNE.dirBase,
  dirX         = cos(TUNE.dirBase),
  dirY         = sin(TUNE.dirBase),
  baseStrength = TUNE.baseStrength,
  strength     = TUNE.baseStrength,
  gustLevel    = 0,          -- 0..1, the strongest gust currently overhead-ish
  tune         = TUNE,
  lag          = TUNE.canopyLag,
}

-- Fixed pool: gusts never allocate.
local gusts = {}
for i = 1, TUNE.maxGusts do
  gusts[i] = { live = false, dx = 1, dy = 0, pos = 0, span = 0, str = 0,
               width = TUNE.gustWidth, speed = TUNE.gustSpeed, phase = 0 }
end
Wind.gusts = gusts

local rng = U.rng(0xB0757)
local nextGust = 3.0

------------------------------------------------------------------ control
--- Fire a gust front. `dirX,dirY` default to the prevailing direction.
--- The front starts off-map upwind and sweeps the whole world.
function Wind.gust(strength, dirX, dirY)
  strength = strength or 0.7
  local dx, dy = dirX or Wind.dirX, dirY or Wind.dirY
  local nx, ny = U.norm(dx, dy)
  if nx == 0 and ny == 0 then nx, ny = Wind.dirX, Wind.dirY end

  -- take a free slot, else stomp the weakest one
  local slot, weakest = nil, math.huge
  for i = 1, TUNE.maxGusts do
    local G = gusts[i]
    if not G.live then slot = i break end
    if G.str < weakest then weakest, slot = G.str, i end
  end

  local G = gusts[slot]
  G.live  = true
  G.dx, G.dy = nx, ny
  G.span  = TUNE.span
  G.pos   = -G.span * 0.5
  G.str   = U.clamp(strength, 0, 1.4)
  G.width = TUNE.gustWidth * (0.7 + strength * 0.7)
  G.speed = TUNE.gustSpeed * (0.75 + strength * 0.5)
  G.phase = rng:angle()
  return G
end

--- Set the resting wind. Storms raise it, the boss arriving raises it a lot.
function Wind.setStrength(s) Wind.baseStrength = U.saturate(s) end
function Wind.setDirection(a)
  Wind.direction = a
  Wind.dirX, Wind.dirY = cos(a), sin(a)
end

function Wind.reset()
  Wind.time = 0
  Wind.baseStrength = TUNE.baseStrength
  Wind.setDirection(TUNE.dirBase)
  for i = 1, TUNE.maxGusts do gusts[i].live = false end
  nextGust = 3.0
end

------------------------------------------------------------------ update
function Wind.update(dt)
  local t = Wind.time + dt
  Wind.time = t

  -- direction wanders slowly; strength breathes
  local a = TUNE.dirBase + sin(t * TUNE.dirRate * U.TAU) * TUNE.dirWander
  Wind.direction = a
  Wind.dirX, Wind.dirY = cos(a), sin(a)
  Wind.strength = U.saturate(Wind.baseStrength +
                             sin(t * TUNE.strengthRate * U.TAU) * TUNE.strengthWave)

  local peak = 0
  for i = 1, TUNE.maxGusts do
    local G = gusts[i]
    if G.live then
      G.pos = G.pos + G.speed * dt
      if G.pos > G.span * 0.5 + G.width * 3 then
        G.live = false
      else
        -- fade in and out at the edges of the sweep so nothing pops
        local u = (G.pos + G.span * 0.5) / G.span
        local f = U.smoothstep(0, 0.14, u) * (1 - U.smoothstep(0.82, 1.0, u))
        if G.str * f > peak then peak = G.str * f end
      end
    end
  end
  Wind.gustLevel = U.saturate(peak)

  if TUNE.autoGusts then
    nextGust = nextGust - dt
    if nextGust <= 0 then
      nextGust = rng:range(TUNE.gustEvery[1], TUNE.gustEvery[2])
      Wind.gust(rng:range(TUNE.gustStrength[1], TUNE.gustStrength[2]))
    end
  end
end

------------------------------------------------------------------ sampling
--- Sway (-1..1) and local strength (0..1) at a world point.
--- `tOff` shifts the sample in time - pass a negative value to get the wind as
--- it was a moment ago, which is how canopies are made to lag their trunks.
function Wind.at(x, y, tOff)
  local t = Wind.time + (tOff or 0)
  local dx, dy = Wind.dirX, Wind.dirY
  -- u runs along the wind, v across it
  local u = x * dx + y * dy
  local v = y * dx - x * dy

  local o1 = sin(u * TUNE.f1 - t * TUNE.s1 + sin(v * TUNE.f1 * 0.55 + t * 0.29) * TUNE.crossWarp)
  local o2 = sin(u * TUNE.f2 - t * TUNE.s2 + v * TUNE.f2 * 0.42)
  local base = o1 * TUNE.a1 + o2 * TUNE.a2

  local s = Wind.strength
  local g = 0
  for i = 1, TUNE.maxGusts do
    local G = gusts[i]
    if G.live then
      local pos = G.pos + (tOff or 0) * G.speed
      local d = (x * G.dx + y * G.dy) - pos
      local e = d / G.width
      e = e * e
      if e < 12 then
        local up = (pos + G.span * 0.5) / G.span
        local f = U.smoothstep(0, 0.14, up) * (1 - U.smoothstep(0.82, 1.0, up))
        g = g + exp(-e) * G.str * f * (0.75 + 0.35 * sin(d / G.width * TUNE.gustRipple + G.phase))
      end
    end
  end

  local sway = base * (s * 0.85 + g * 0.55) + g * 0.72
  return U.clamp(sway, -1, 1), U.saturate(s * 0.8 + g)
end

--- Convenience for anything that just wants a push vector at a point.
function Wind.vectorAt(x, y)
  local sway, str = Wind.at(x, y)
  local m = sway * str
  return Wind.dirX * m, Wind.dirY * m, str
end

--- Angle of travel of the strongest live gust (used by leaf litter).
function Wind.gustAngle()
  local best, ba = 0, Wind.direction
  for i = 1, TUNE.maxGusts do
    local G = gusts[i]
    if G.live and G.str > best then best, ba = G.str, atan2(G.dy, G.dx) end
  end
  return ba
end

return Wind
