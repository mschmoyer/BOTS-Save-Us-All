-- Global screen-feel: trauma shake, hitstop, time dilation, zoom punch, flashes.
-- Everything routes through here so it can be tuned in one place and disabled for
-- accessibility without touching gameplay code.
local U = require("src.core.util")
local T = require("src.game.tuning").juice

local J = {
  trauma = 0,
  hitstop = 0,
  timeScale = 1,
  targetScale = 1,
  zoomPunch = 0,
  flash = 0,
  flashColor = { 1, 1, 1 },
  shakeX = 0, shakeY = 0, shakeR = 0,
  -- accessibility multipliers (0 disables)
  shakeAmount = 1,
  flashAmount = 1,
  -- The headless balance harness turns this off: hitstop and time dilation are
  -- measured in real seconds, so at 8x sim speed they would swallow the run.
  enabled = true,
  time = 0,
}

function J.reset()
  J.trauma, J.hitstop, J.timeScale, J.targetScale = 0, 0, 1, 1
  J.zoomPunch, J.flash = 0, 0
  J.shakeX, J.shakeY, J.shakeR = 0, 0, 0
end

--- Add camera trauma. Shake is trauma^2 so small hits stay subtle and big ones slam.
function J.shake(amount) J.trauma = math.min(T.maxTrauma, J.trauma + amount) end

--- Freeze the simulation briefly. The single best-value juice effect in games.
function J.stop(dur) J.hitstop = math.min(T.hitstopMax, math.max(J.hitstop, dur)) end

--- Slow time to `scale` for `dur`, then ease back.
function J.dilate(scale, dur)
  if not J.enabled then return end
  J.targetScale = scale
  J.dilateLeft = dur
end

function J.punch(amount) J.zoomPunch = math.max(J.zoomPunch, amount) end

function J.flashScreen(amount, r, g, b)
  J.flash = math.max(J.flash, amount * J.flashAmount)
  if r then J.flashColor[1], J.flashColor[2], J.flashColor[3] = r, g, b end
end

--- Convenience: the standard "solid hit" package.
function J.impact(power, r, g, b)
  J.shake(0.22 * power)
  J.stop(0.03 + 0.05 * power)
  J.punch(0.012 * power)
  if r then J.flashScreen(0.08 * power, r, g, b) end
end

--- Returns the dt gameplay should use. Real dt still drives UI and juice itself.
function J.update(realDt)
  J.time = J.time + realDt

  if J.dilateLeft then
    J.dilateLeft = J.dilateLeft - realDt
    if J.dilateLeft <= 0 then J.dilateLeft = nil J.targetScale = 1 end
  end
  J.timeScale = U.damp(J.timeScale, J.targetScale, 12, realDt)

  J.trauma = math.max(0, J.trauma - T.traumaDecay * realDt)
  J.zoomPunch = J.zoomPunch * math.exp(-T.zoomPunchDecay * realDt)
  J.flash = math.max(0, J.flash - realDt * 4.2)

  local s = J.trauma * J.trauma * J.shakeAmount
  if s > 0.0001 then
    local t = J.time * 34
    J.shakeX = (U.valueNoise(t, 11.3, 1) * 2 - 1) * T.shakeAmp * s
    J.shakeY = (U.valueNoise(t, 47.9, 2) * 2 - 1) * T.shakeAmp * s
    J.shakeR = (U.valueNoise(t * 0.7, 91.1, 3) * 2 - 1) * T.shakeRotAmp * s
  else
    J.shakeX, J.shakeY, J.shakeR = 0, 0, 0
  end

  if J.hitstop > 0 then
    J.hitstop = J.hitstop - realDt
    return 0
  end
  return realDt * J.timeScale
end

return J
