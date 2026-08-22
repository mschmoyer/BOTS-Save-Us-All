-- Weather. Mostly atmosphere, but rain genuinely accelerates growth, and a
-- storm front is the game's way of telling you a hard night is coming.
local U      = require("src.core.util")
local P      = require("src.engine.palette")
local Signal = require("src.core.signal")
local Opt    = require("src.core.optional")

local VFX  = Opt.require("src.engine.vfx")
local Wind = Opt.require("src.world.wind")
local Audio = Opt.require("src.engine.audio")
local Draw = Opt.require("src.engine.draw")
local TU   = require("src.game.tuning")

local W = {
  state = "clear",       -- clear | breezy | overcast | rain | storm
  rain = 0,              -- 0..1 current rain intensity
  target = 0,
  wetness = 0,           -- ground darkening, lags the rain
  cloud = 0,             -- 0..1 overcast dimming
  cloudTarget = 0,
  t = 0,
  nextChange = 45,
  rng = U.rng(8081),
}

local STATES = {
  clear    = { rain = 0.00, cloud = 0.00, wind = 0.35, weight = 5, dur = { 70, 140 } },
  breezy   = { rain = 0.00, cloud = 0.12, wind = 0.85, weight = 4, dur = { 50, 100 } },
  overcast = { rain = 0.00, cloud = 0.42, wind = 0.5,  weight = 3, dur = { 45, 90 } },
  rain     = { rain = 0.62, cloud = 0.58, wind = 0.6,  weight = 3, dur = { 55, 110 } },
  storm    = { rain = 1.00, cloud = 0.78, wind = 1.0,  weight = 1, dur = { 40, 70 } },
}
W.states = STATES

-- Iterated instead of `pairs(STATES)`. LuaJIT randomises its string hash seed
-- per process, so `pairs` over a string-keyed table walks in a different order
-- in every run -- and this loop builds a weighted pool that `rng:pick` then
-- indexes, so the same seed drew different weather in different processes.
-- That was the first divergence in any traced run, at about t=45s, every time,
-- and it is most of why BOTS_SEED has never reproduced a campaign.
local ORDER = { "clear", "breezy", "overcast", "rain", "storm" }

--- Weather is not purely random: it is weighted by the phase, so nights are
--- more likely to be foul and the day you need to rebuild is more likely clear.
local function pick(rng, phase, cycle)
  local pool = {}
  for oi = 1, #ORDER do
    local name = ORDER[oi]
    local def = STATES[name]
    local w = def.weight
    if phase == "night" then
      if name == "storm" then w = w + 1 + cycle * 0.3 end
      if name == "clear" then w = w * 0.6 end
    elseif phase == "day" then
      if name == "clear" or name == "breezy" then w = w * 1.4 end
      if name == "storm" then w = w * 0.35 end
    end
    for _ = 1, math.max(1, math.floor(w * 2)) do pool[#pool + 1] = name end
  end
  return rng:pick(pool)
end

------------------------------------------------------------------ sky contact
-- Something crosses the top of the frame, three times, before the Harvester
-- Prime comes down.
--
-- It lives in the weather because that is what it is to the player: a thing the
-- sky does. It is not an entity, it has no sound, it puts nothing on the
-- minimap, it never lands, and no line of dialogue acknowledges it. The only
-- job it has is that when a machine finally does descend, it is the fourth time
-- the player has seen a light up there rather than the first.
--
-- Three sightings: the 75% oxygen milestone -- the point at which the sky is
-- worth looking at from somewhere else -- and then dusk on each of the last two
-- cycles. Suppressed once the rig is actually here, because by then the thing
-- has arrived and a fourth light in the sky is just weather.
local sky = { t = 0, live = false, n = 0, dir = 1, drop = 0, fired = false,
              phase = nil }
W.skyContact = sky

local function skyStart()
  local C = TU.skyContact
  sky.live = true
  sky.t = 0
  sky.n = sky.n + 1
  -- alternate the heading: three passes on one track is a looping animation,
  -- three passes on different ones is traffic
  sky.dir = (sky.n % 2 == 1) and 1 or -1
  sky.drop = W.rng:range(-0.5, 1.0) * (C.y1 - C.y0)
end

local function skyUpdate(dt, world)
  if sky.live then
    sky.t = sky.t + dt
    if sky.t >= TU.skyContact.dur then sky.live = false end
    return
  end
  if not world then return end
  local phase = world.phase
  local prev = sky.phase
  sky.phase = phase
  if phase == "extraction" or phase == "ending" then return end

  local C = TU.skyContact
  if not sky.fired and (world.o2Step or 0) >= C.o2Mark then
    sky.fired = true
    skyStart()
    return
  end
  if phase == "dusk" and prev ~= "dusk"
     and (world.cycle or 1) > TU.cycle.count - C.lastCycles then
    skyStart()
  end
end

--- One point of light, on a straight track, over about eight seconds. Drawn
--- inside the scene so the grade and the bloom have it -- it is up there with
--- the weather, not printed on the interface.
local function skyDraw()
  if not sky.live then return end
  local C = TU.skyContact
  local g = love.graphics
  local w, h = g.getDimensions()
  local k = sky.t / C.dur
  local pad = 40
  local x = sky.dir > 0 and (-pad + (w + pad * 2) * k) or (w + pad - (w + pad * 2) * k)
  local y = h * (C.y0 + (C.y1 - C.y0) * k + sky.drop)
  -- in and out at the ends, so it enters and leaves rather than appearing
  local a = C.alpha * U.saturate(k / C.edge) * U.saturate((1 - k) / C.edge)
  if a <= 0.004 then return end
  -- Additively, and by hand. This is called at the tail of the scene pass,
  -- straight after the lighting composite, and two things there will eat it:
  -- whatever blend mode and shader that pass left bound, and the grade, whose
  -- shoulder turns a 95% white alpha blend into a grey smear. A light in the
  -- sky is a light: it goes on top of the frame, not into it.
  local pbm, pam = g.getBlendMode()
  local psh = g.getShader()
  g.setShader()
  if Draw.glow then Draw.glow(x, y, C.glow, P.skyContact, a * 0.55, 3) end
  g.setBlendMode("add", "alphamultiply")
  g.setColor(P.skyContact[1], P.skyContact[2], P.skyContact[3], a)
  g.circle("fill", x, y, C.r, 12)
  g.setColor(1, 1, 1, 1)
  g.setBlendMode(pbm, pam)
  g.setShader(psh)
end

function W.reset()
  W.state, W.rain, W.target = "clear", 0, 0
  W.cloud, W.cloudTarget, W.wetness = 0, 0, 0
  W.t, W.nextChange = 0, 50
  sky.t, sky.live, sky.n, sky.fired, sky.phase = 0, false, 0, false, nil
end

function W.set(state, immediate)
  local def = STATES[state]
  if not def then return end
  local prev = W.state
  W.state = state
  W.target = def.rain
  W.cloudTarget = def.cloud
  if Wind.setStrength then Wind.setStrength(def.wind) end
  if immediate then W.rain, W.cloud = def.rain, def.cloud end
  if state == "storm" and prev ~= "storm" then
    if Wind.gust then Wind.gust(1, W.rng:range(-1, 1), W.rng:range(-1, 1)) end
  end
  if def.rain > 0 and (STATES[prev] and STATES[prev].rain or 0) == 0 then
    Audio.play("wave_start", { volume = 0.15, pitch = 0.6 })
  end
  local d = def.dur
  W.nextChange = W.rng:range(d[1], d[2])
  Signal.emit("weather:changed", state, prev)
end

function W.isRaining() return W.rain > 0.15 end
--- Growth multiplier the world applies to trees.
function W.growthBonus(memory)
  return 1 + W.rain * (memory and 1.0 or 0.5)
end

function W.update(dt, world)
  W.t = W.t + dt
  skyUpdate(dt, world)
  W.nextChange = W.nextChange - dt
  if W.nextChange <= 0 then
    local phase = world and world.phase or "day"
    local cycle = world and world.cycle or 1
    W.set(pick(W.rng, phase, cycle))
  end

  W.rain = U.damp(W.rain, W.target, 0.5, dt)
  W.cloud = U.damp(W.cloud, W.cloudTarget, 0.4, dt)
  -- the ground stays wet for a while after the rain stops
  W.wetness = U.damp(W.wetness, W.rain, W.rain > W.wetness and 0.35 or 0.09, dt)

  if W.rain > 0.05 and VFX.emit then
    W.emitT = (W.emitT or 0) - dt
    if W.emitT <= 0 then
      W.emitT = 0.05
      -- Rain falls where the player is looking. Emitted at the world origin it
      -- piled into a permanent grey smear in the island's top-left corner.
      local cx, cy = 0, 0
      local cam = world and world.camera
      if cam and cam.focus then cx, cy = cam:focus() end
      VFX.emit("rain", cx, cy, { power = W.rain, count = math.floor(6 + W.rain * 22) })
    end
    if W.state == "storm" and W.rng:chance(dt * 0.14) then
      W.strike = 0.5
      if Wind.gust then Wind.gust(0.8, W.rng:range(-1, 1), W.rng:range(-1, 1)) end
    end
  end

  if W.strike then
    W.strike = W.strike - dt
    if W.strike <= 0 then W.strike = nil end
  end
end

--- Overcast dimming and the lightning flash, applied over the graded frame.
function W.drawOverlay()
  local g = love.graphics
  if W.cloud > 0.02 then
    local c = P.ramp.rock[1]
    g.setColor(c[1], c[2], c[3], W.cloud * 0.34)
    g.rectangle("fill", 0, 0, g.getDimensions())
  end
  if W.strike then
    local a = U.saturate(W.strike / 0.5)
    g.setColor(1, 1, 1, a * a * 0.4)
    g.rectangle("fill", 0, 0, g.getDimensions())
  end
  g.setColor(1, 1, 1, 1)
  skyDraw()
end

return W
