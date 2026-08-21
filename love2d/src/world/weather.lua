-- Weather. Mostly atmosphere, but rain genuinely accelerates growth, and a
-- storm front is the game's way of telling you a hard night is coming.
local U      = require("src.core.util")
local P      = require("src.engine.palette")
local Signal = require("src.core.signal")
local Opt    = require("src.core.optional")

local VFX  = Opt.require("src.engine.vfx")
local Wind = Opt.require("src.world.wind")
local Audio = Opt.require("src.engine.audio")

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

--- Weather is not purely random: it is weighted by the phase, so nights are
--- more likely to be foul and the day you need to rebuild is more likely clear.
local function pick(rng, phase, cycle)
  local pool = {}
  for name, def in pairs(STATES) do
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

function W.reset()
  W.state, W.rain, W.target = "clear", 0, 0
  W.cloud, W.cloudTarget, W.wetness = 0, 0, 0
  W.t, W.nextChange = 0, 50
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
end

return W
