-- The single source of colour for the whole game.
-- Nothing outside this file may contain a colour literal.
local U = require("src.core.util")

local P = {}

local function hex(s, a)
  s = s:gsub("#", "")
  return {
    tonumber(s:sub(1, 2), 16) / 255,
    tonumber(s:sub(3, 4), 16) / 255,
    tonumber(s:sub(5, 6), 16) / 255,
    a or 1,
  }
end
P.hex = hex

--------------------------------------------------------------------- ramps
-- Every material is a 4-stop ramp: shadow, base, light, rim.
P.ramp = {
  grass  = { hex "#16342a", hex "#2b6444", hex "#4b9159", hex "#7fca77" },
  moss   = { hex "#14291f", hex "#28503a", hex "#3f7a4f", hex "#68a866" },
  soil   = { hex "#241a14", hex "#3d2c20", hex "#5b432f", hex "#7d6144" },
  sand   = { hex "#5c4a30", hex "#957c52", hex "#c0a476", hex "#e3cfa4" },
  rock   = { hex "#1b232b", hex "#333f4a", hex "#53616e", hex "#7d8c99" },
  water  = { hex "#05121d", hex "#0d3448", hex "#1a6d7f", hex "#8fe0e6" },
  bark   = { hex "#241812", hex "#3d2a1d", hex "#5a4029", hex "#7d5b3a" },
  leaf   = { hex "#123024", hex "#215c3a", hex "#3d8f4f", hex "#7ad06f" },
  leafHi = { hex "#1c4029", hex "#357a45", hex "#5cb45f", hex "#a8e77f" },
  metal  = { hex "#20282e", hex "#4c5d68", hex "#93a6b0", hex "#dce8ee" },
  metalW = { hex "#2b2119", hex "#63513c", hex "#a08663", hex "#ded0b0" }, -- warm/brass bots
  blight = { hex "#1d0a24", hex "#4a1259", hex "#8f22a3", hex "#e64fd0" },
  rift   = { hex "#180430", hex "#3d0f6b", hex "#7b2ff7", hex "#c79bff" },
}

P.ramp.cobalt = { hex "#062435", hex "#0f5f89", hex "#3fb6f0", hex "#cdf1ff" }
P.ramp.ember  = { hex "#3a1405", hex "#8a3a0b", hex "#e07a1f", hex "#ffd98a" }

--------------------------------------------------------------------- singles
P.ink        = hex "#e9f4f0"
P.inkDim     = hex "#9fb3ba"
P.inkFaint   = hex "#5f747d"
P.accent     = hex "#4fe3a8"
P.accentCool = hex "#7ba9ff"
P.warn       = hex "#ffb63d"
P.danger     = hex "#ff5470"
P.black      = hex "#05070b"
P.white      = hex "#ffffff"
P.eye        = hex "#ffc46b"
P.eyeDown    = hex "#ff6a4d"
P.love       = hex "#ff7ba8"
P.acid       = hex "#b6ff3d"
P.o2         = hex "#6fe4ff"

--------------------------------------------------------- time-of-day ambients
-- Each entry: ambient light colour, exposure, and the fog/atmosphere tint.
P.tod = {
  dawn  = { amb = hex "#ffb489", exposure = 1.02, fog = hex "#ffcfa8", strength = 0.55 },
  day   = { amb = hex "#ffffff", exposure = 1.00, fog = hex "#cfe9ff", strength = 0.16 },
  dusk  = { amb = hex "#b06a9c", exposure = 0.96, fog = hex "#e08cb4", strength = 0.50 },
  night = { amb = hex "#4b6ea8", exposure = 0.90, fog = hex "#1d3352", strength = 0.72 },
}

--------------------------------------------------------------------- helpers
--- Look up a ramp stop with a float index (1..4), blending between stops.
function P.shade(ramp, t, alpha)
  t = U.clamp(t, 1, 4)
  local i = math.floor(t)
  local f = t - i
  local a = ramp[i]
  local b = ramp[math.min(i + 1, 4)]
  return { U.lerp(a[1], b[1], f), U.lerp(a[2], b[2], f), U.lerp(a[3], b[3], f), alpha or 1 }
end

function P.mix(a, b, t, alpha)
  return {
    U.lerp(a[1], b[1], t), U.lerp(a[2], b[2], t), U.lerp(a[3], b[3], t),
    alpha or U.lerp(a[4] or 1, b[4] or 1, t),
  }
end

function P.alpha(c, a) return { c[1], c[2], c[3], a } end

--- Multiply brightness, keeping alpha.
function P.scale(c, k, a) return { c[1] * k, c[2] * k, c[3] * k, a or c[4] or 1 } end

--- Perceptual-ish lighten toward white.
function P.lighten(c, t, a) return P.mix(c, P.white, t, a or c[4]) end
function P.darken(c, t, a) return P.mix(c, P.black, t, a or c[4]) end

--- HSV -> linear-ish rgb table, for procedural variety.
function P.hsv(h, s, v, a)
  h = (h % 1) * 6
  local i = math.floor(h)
  local f = h - i
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  local r, g, b
  if i == 0 then r, g, b = v, t, p
  elseif i == 1 then r, g, b = q, v, p
  elseif i == 2 then r, g, b = p, v, t
  elseif i == 3 then r, g, b = p, q, v
  elseif i == 4 then r, g, b = t, p, v
  else r, g, b = v, p, q end
  return { r, g, b, a or 1 }
end

return P
