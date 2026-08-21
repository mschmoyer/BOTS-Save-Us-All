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
-- Chroma is deliberate: a stylised frame lives or dies on whether the greens
-- separate from each other. `grass` is the warm sunlit sward, `moss` is the
-- cool blue-green counterweight, and the two leaf ramps straddle them, so a
-- forest built from all four never collapses into one olive mass.
P.ramp = {
  grass  = { hex "#143a26", hex "#357d42", hex "#66b64f", hex "#b0e768" },
  moss   = { hex "#0d2b23", hex "#1b5340", hex "#2f8659", hex "#61bd85" },
  soil   = { hex "#261a12", hex "#452e1d", hex "#6b4c2d", hex "#957044" },
  sand   = { hex "#5e4527", hex "#a08049", hex "#d6b374", hex "#f6e2ad" },
  rock   = { hex "#171f2b", hex "#2e3f55", hex "#54677e", hex "#8a9db2" },
  water  = { hex "#031321", hex "#093c5b", hex "#0f86a3", hex "#a9f0f2" },
  bark   = { hex "#26170f", hex "#412b1a", hex "#634427", hex "#8c6339" },
  leaf   = { hex "#0f3a2a", hex "#1d7047", hex "#37a95a", hex "#7ee06d" },
  leafHi = { hex "#204527", hex "#428f45", hex "#77cf58", hex "#c8f584" },
  metal  = { hex "#1d262e", hex "#4c5f6c", hex "#96abb7", hex "#e2eef4" },
  metalW = { hex "#2b2119", hex "#67543c", hex "#a98c66", hex "#e6d7b4" }, -- warm/brass bots
  -- The blight is a *bruise*, not a sweet. The wide-area stops are near-neutral
  -- so a scar reads by value and texture; only the last stop is allowed to be
  -- hot, and it is only ever used on hairline veins.
  blight = { hex "#150a17", hex "#33202f", hex "#6b2a6b", hex "#d552bd" },
  -- Dead, poisoned ground: warm ash over cold cinder. Carries the scar's value
  -- structure so the purple never has to.
  ash    = { hex "#151215", hex "#2b2422", hex "#4d423a", hex "#857665" },
  rift   = { hex "#170430", hex "#3d0f6b", hex "#7b2ff7", hex "#c79bff" },
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
  dawn  = { amb = hex "#ffb98c", exposure = 1.08, fog = hex "#ffd2a6", strength = 0.50 },
  day   = { amb = hex "#ffffff", exposure = 1.14, fog = hex "#c8e6ff", strength = 0.11 },
  dusk  = { amb = hex "#b06a9c", exposure = 1.00, fog = hex "#e88bab", strength = 0.46 },
  night = { amb = hex "#3a63a6", exposure = 0.86, fog = hex "#0f2447", strength = 0.66 },
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
