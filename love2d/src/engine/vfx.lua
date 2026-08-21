-- Pooled, data-driven particle system.
--
--   Effects are DATA. `DEFS[name]` is either one emitter table or an array of
--   emitter tables that fire together (that is how a single "impact" becomes a
--   flash + shards + a ring). Adding an effect means adding a table entry;
--   it never means writing new code.
--
--   Everything batches through one procedurally generated texture atlas: a
--   SpriteBatch per (layer, blend) pair. Rings and arcs are the only geometry
--   particles, and there are never many of them alive.
--
--   Zero table allocation after init: the pool hands out particle tables that
--   are reused forever, and the draw pass writes straight into SpriteBatches.
local U = require("src.core.util")
local P = require("src.engine.palette")

local VFX = {}

local floor, sqrt, sin, cos, exp, abs = math.floor, math.sqrt, math.sin, math.cos, math.exp, math.abs
local atan2, random, pi = math.atan2, math.random, math.pi
local TAU = U.TAU
local sat, lerp, ease = U.saturate, U.lerp, U.ease

--------------------------------------------------------------------- constants
local CELL      = 64          -- atlas cell size in px
local ATLAS_C   = 4           -- cells across
local ATLAS_R   = 4           -- cells down
local POOL_MAX  = 14000
local LAYERS    = { "ground", "world", "air", "additive" }
local LAYER_IX  = { ground = 1, world = 2, air = 3, additive = 4 }
local KIND_SPR, KIND_RING, KIND_ARC = 0, 1, 2
local QMUL      = { [0] = 0.5, [1] = 0.78, [2] = 1.0 }

VFX.LAYERS = LAYERS

--------------------------------------------------------------------- atlas gen
-- Shape names in draw order of the atlas grid. Index = quad index.
local SHAPES = {
  "dot", "disc", "streak", "spark",
  "shard", "leaf", "smoke", "heart",
  "annulus", "mote", "bubble", "drop",
  "flare", "plus", "blob", "halo",
}
local QUAD_IX = {}
for i, n in ipairs(SHAPES) do QUAD_IX[n] = i end

local function sdSeg(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local t = l2 > 1e-9 and sat(((px - ax) * dx + (py - ay) * dy) / l2) or 0
  local qx, qy = ax + dx * t - px, ay + dy * t - py
  return sqrt(qx * qx + qy * qy)
end

local function g2(d, k) return exp(-(d * k) * (d * k)) end

-- Each shape returns (alpha, luminance). Luminance bakes volume/hot-core into
-- the texture so a flat tint still reads as a lit object.
local SHAPE_FN = {}

SHAPE_FN.dot = function(u, v, r)
  return g2(r, 2.35), 0.58 + 0.42 * g2(r, 3.6)
end

SHAPE_FN.disc = function(u, v, r)
  local a = U.smoothstep(0.86, 0.60, r)
  local lr = sqrt((u + 0.30) * (u + 0.30) + (v + 0.30) * (v + 0.30))
  return a, U.clamp(1.06 - lr * 0.60, 0.34, 1)
end

-- a spindle, not a capsule: it tapers to a point at both ends so a stretched
-- streak reads as motion rather than as a bar
SHAPE_FN.streak = function(u, v, r)
  if abs(u) > 0.97 then return 0, 0 end
  local w = 0.29 * (1 - u * u) ^ 0.7
  local d = abs(v) - w
  local a = U.smoothstep(0.03, -0.055, d)
  return a, 0.42 + 0.58 * g2(d + w * 0.5, 6)
end

SHAPE_FN.spark = function(u, v, r)
  local core = g2(r, 3.1)
  local h = g2(v, 15) * g2(u, 1.45) * 0.6
  local w = g2(u, 15) * g2(v, 1.45) * 0.6
  local a = U.saturate(core + h + w)
  return a, 0.62 + 0.38 * core
end

-- shrapnel: a convex quad with a sharp leading point, solved as a signed
-- distance so the silhouette stays crisp at any spin
local SHARD_X = { 0.95, -0.10, -0.88, -0.34 }
local SHARD_Y = { -0.04, -0.30,  0.02,  0.24 }
SHAPE_FN.shard = function(u, v, r)
  local d = -1e9
  for i = 1, 4 do
    local j = i % 4 + 1
    local ax, ay = SHARD_X[i], SHARD_Y[i]
    local ex, ey = SHARD_X[j] - ax, SHARD_Y[j] - ay
    local l = sqrt(ex * ex + ey * ey)
    local s = ((u - ax) * -ey + (v - ay) * ex) / l
    if s > d then d = s end
  end
  local a = U.smoothstep(0.035, -0.02, d)
  local l = 0.5 + 0.5 * U.saturate((u + 0.75) / 1.5) - 0.18 * U.saturate(v * 2)
  return a, U.clamp(l, 0.32, 1)
end

-- an asymmetric leaf: broad near the stem, drawn out to a tip, with a midrib
SHAPE_FN.leaf = function(u, v, r)
  local t = (u + 0.86) / 1.72
  if t <= 0 or t >= 1 then return 0, 0 end
  local w = 0.72 * sqrt(t) * (1 - t) ^ 0.6
  local vv = v - 0.07 * sin(t * pi)          -- a little curl
  local d = abs(vv) - w
  local a = U.smoothstep(0.025, -0.05, d)
  if t < 0.10 then                            -- stem
    a = math.max(a, U.smoothstep(0.045, 0.012, abs(vv)) * (1 - t / 0.10))
  end
  local rib = g2(vv, 22) * 0.30
  local edge = U.smoothstep(-0.02, -0.16, d) * 0.18
  return a, U.clamp(0.98 - rib - edge - abs(vv) * 0.55, 0.3, 1)
end

SHAPE_FN.smoke = function(u, v, r)
  local a = 0
  local ox = { 0.00, 0.34, -0.32, 0.10, -0.22, 0.24 }
  local oy = { 0.00, -0.24, -0.12, 0.34, 0.28, 0.18 }
  local sc = { 1.7, 2.3, 2.4, 2.4, 2.6, 2.8 }
  for i = 1, 6 do
    local dx, dy = u - ox[i], v - oy[i]
    a = a + g2(sqrt(dx * dx + dy * dy), sc[i]) * 0.5
  end
  a = U.saturate(a) * U.smoothstep(1.08, 0.62, r)
  local lr = sqrt((u + 0.26) * (u + 0.26) + (v + 0.26) * (v + 0.26))
  return a, U.clamp(1.0 - lr * 0.48, 0.4, 1)
end

SHAPE_FN.heart = function(u, v, r)
  local x, y = u * 1.42, -v * 1.42 + 0.10
  local q = x * x + y * y - 1
  local f = q * q * q - x * x * y * y * y
  local a = U.smoothstep(0.14, -0.04, f)
  local lr = sqrt((u + 0.24) * (u + 0.24) + (v + 0.30) * (v + 0.30))
  return a, U.clamp(1.05 - lr * 0.55, 0.42, 1)
end

SHAPE_FN.annulus = function(u, v, r)
  local a = g2(r - 0.62, 6.2)
  return a, 0.6 + 0.4 * a
end

SHAPE_FN.mote = function(u, v, r)
  local core = g2(r, 5.0)
  local halo = g2(r, 1.9) * 0.26
  local h = g2(v, 20) * g2(u, 2.2) * 0.22
  local w = g2(u, 20) * g2(v, 2.2) * 0.22
  return U.saturate(core + halo + h + w), 0.7 + 0.3 * core
end

SHAPE_FN.bubble = function(u, v, r)
  local rim = g2(r - 0.70, 9.5)
  local fill = r < 0.70 and 0.10 * (1 - r) or 0
  local hx, hy = u + 0.30, v + 0.32
  local hl = g2(sqrt(hx * hx + hy * hy), 6.5) * 0.55
  return U.saturate(rim + fill + hl), 0.65 + 0.35 * U.saturate(rim + hl)
end

-- teardrop lying along +u so `align` points the fat head down-range
SHAPE_FN.drop = function(u, v, r)
  local d = sdSeg(u, v, -0.74, 0, 0.42, 0)
  local taper = 0.05 + 0.17 * U.smoothstep(-0.85, 0.45, u)
  local a = U.smoothstep(taper, taper * 0.25, d)
  return a, 0.55 + 0.45 * g2(d, 10)
end

SHAPE_FN.flare = function(u, v, r)
  local core = g2(r, 1.75) * 0.9
  local h = g2(v, 7.5) * g2(u, 1.15) * 0.42
  local w = g2(u, 11) * g2(v, 1.15) * 0.24
  return U.saturate(core + h + w), 0.7 + 0.3 * g2(r, 3.4)
end

SHAPE_FN.plus = function(u, v, r)
  local h = g2(v, 24) * g2(u, 1.32)
  local w = g2(u, 24) * g2(v, 1.32)
  local core = g2(r, 7)
  return U.saturate(h + w + core * 0.8), 0.72 + 0.28 * core
end

SHAPE_FN.blob = function(u, v, r)
  local th = atan2(v, u)
  local rr = 0.66 + 0.075 * sin(3 * th + 1.1) + 0.055 * sin(5 * th + 2.4)
                  + 0.04 * sin(7 * th + 0.6) + 0.025 * sin(11 * th + 3.1)
  local a = U.smoothstep(rr, rr - 0.20, r)
  local lr = sqrt((u + 0.24) * (u + 0.24) + (v + 0.24) * (v + 0.24))
  return a, U.clamp(1.02 - lr * 0.5, 0.4, 1)
end

SHAPE_FN.halo = function(u, v, r)
  return g2(r - 0.52, 2.9) * 0.72, 0.75 + 0.25 * g2(r - 0.52, 5)
end

local function buildAtlas()
  local w, h = CELL * ATLAS_C, CELL * ATLAS_R
  local idata = love.image.newImageData(w, h)
  local inv = 2 / (CELL - 4)
  idata:mapPixel(function(px, py)
    local cx, cy = floor(px / CELL), floor(py / CELL)
    local idx = cy * ATLAS_C + cx + 1
    local fn = SHAPE_FN[SHAPES[idx]]
    if not fn then return 0, 0, 0, 0 end
    local u = (px % CELL - (CELL - 1) * 0.5) * inv
    local v = (py % CELL - (CELL - 1) * 0.5) * inv
    local r = sqrt(u * u + v * v)
    if r > 1.12 then return 0, 0, 0, 0 end
    local a, l = fn(u, v, r)
    if a <= 0 then return 0, 0, 0, 0 end
    l = U.clamp(l, 0, 1)
    return l, l, l, U.saturate(a)
  end)
  return idata
end

--------------------------------------------------------------------- curves
local CURVES = {
  hold      = function(t) return 1 end,
  fade      = function(t) return 1 - t end,
  fadeIn    = function(t) return t end,
  smoothOut = function(t) local k = 1 - t return k * k end,
  sharpOut  = function(t) local k = 1 - t return k * k * k end,
  lateOut   = function(t) return 1 - t * t * t end,
  grow      = function(t) return 0.26 + 0.74 * t end,
  puff      = function(t) return 0.52 + 0.48 * t end,
  riseIn    = function(t)
    if t < 0.16 then return ease.outBack(t / 0.16) end
    return 1 - 0.18 * (t - 0.16) / 0.84
  end,
  swell     = function(t) local k = 1 - t return 1 - k * k * k end,
  shrink    = function(t) return (1 - t) ^ 0.6 end,
  pop       = function(t)
    if t < 0.16 then return ease.outQuad(t / 0.16) end
    return (1 - (t - 0.16) / 0.84) ^ 1.4
  end,
  bloom     = function(t)
    if t < 0.28 then return ease.outCubic(t / 0.28) end
    local k = 1 - (t - 0.28) / 0.72
    return k * k
  end,
  softIn    = function(t)
    if t < 0.22 then return t / 0.22 end
    return 1 - (t - 0.22) / 0.78
  end,
  breathe   = function(t) return sin(t * pi) end,
  flick     = function(t) return (1 - t) * (0.45 + 0.55 * abs(sin(t * 27))) end,
  emberFade = function(t) return (1 - t) * (0.55 + 0.45 * sin(t * 34 + t * t * 40)) end,
}

--------------------------------------------------------------------- palette
local W  = P.white
local R  = P.ramp
local function c(col, a) return { col[1], col[2], col[3], a or col[4] or 1 } end
local function lt(col, k, a) local m = P.lighten(col, k) return { m[1], m[2], m[3], a or 1 } end
local function dk(col, k, a) local m = P.darken(col, k) return { m[1], m[2], m[3], a or 1 } end

---------------------------------------------------------------------- DEFS
-- Field reference (all optional):
--   layer  "ground"|"world"|"air"|"additive"   blend "alpha"|"add"
--   shape  atlas name, or "ring"/"arc" for geometry
--   count  n | {a,b}          life {a,b}
--   emit   "point"|"disc"|"ring"|"box"        radius {a,b}   boxW boxH
--   speed  {a,b}   angle rad   spread rad (full cone)  inward true
--   drag (1/s, negative accelerates)  grav (px/s^2)  wind 0..1
--   swirl amp      swirlFreq
--   size {a,b}  sizeCurve  alphaCurve  alpha (master)
--   colors { {r,g,b,a}, ... }  evenly spaced stops across the lifetime
--   spin {a,b}  align true  stretch (px/s -> extra length)  tumble freq
--   pulse amp    pulseFreq   flickerAmt
--   ring0 ring1 ringW ringSegs ringCurve   (shape="ring")
--   arcR0 arcR1 arcW arcSpan arcHead arcTail (shape="arc")
--   onDeath "effect"  onDeathChance
--   rate n/s (for VFX.stream)   detail 0..2 (skipped below that quality)
local DEFS = {}

------------------------------------------------------------------ ambient
DEFS.pollen = {
  layer = "air", blend = "add", shape = "mote", rate = 7,
  count = { 1, 2 }, life = { 7, 13 }, emit = "box", boxW = 900, boxH = 600,
  speed = { 4, 16 }, spread = TAU, drag = 0.2, wind = 0.55,
  swirl = 9, swirlFreq = 0.7,
  size = { 3.2, 6.2 }, sizeCurve = "hold", alphaCurve = "breathe",
  pulse = 0.45, pulseFreq = 1.7, alpha = 0.75,
  colors = { c(R.leafHi[4], 0.55), c(R.sand[4], 0.85), lt(R.leafHi[4], 0.5, 0.7) },
}

DEFS.fireflies = {
  { layer = "air", blend = "add", shape = "halo", rate = 2.4,
    count = 1, life = { 5, 9 }, emit = "box", boxW = 900, boxH = 600,
    speed = { 6, 16 }, spread = TAU, drag = 0.9, swirl = 26, swirlFreq = 0.55,
    size = { 26, 42 }, sizeCurve = "hold", alphaCurve = "breathe",
    pulse = 0.9, pulseFreq = 2.3, alpha = 0.30,
    colors = { c(P.accent, 0.7), c(R.ember[4], 0.9), c(P.accent, 0.7) } },
  { layer = "air", blend = "add", shape = "mote",
    count = 1, life = { 5, 9 }, emit = "box", boxW = 900, boxH = 600,
    speed = { 6, 16 }, spread = TAU, drag = 0.9, swirl = 26, swirlFreq = 0.55,
    size = { 4, 6.5 }, sizeCurve = "hold", alphaCurve = "breathe",
    pulse = 0.9, pulseFreq = 2.3,
    colors = { lt(R.ember[4], 0.6, 1), c(W, 1), lt(P.accent, 0.4, 1) } },
}

DEFS.leaf_litter = {
  layer = "world", blend = "alpha", shape = "leaf", rate = 5,
  count = { 1, 3 }, life = { 3.2, 6.0 }, emit = "box", boxW = 700, boxH = 420,
  speed = { 30, 90 }, spread = 0.9, drag = 0.7, grav = 16, wind = 0.9,
  swirl = 34, swirlFreq = 1.9,
  size = { 9, 16 }, sizeCurve = "hold", alphaCurve = "lateOut",
  spin = { -3.4, 3.4 }, tumble = 6.5,
  colors = { c(R.leaf[3]), c(R.leafHi[4]), c(R.ember[3], 0.9), c(R.bark[3], 0) },
}

DEFS.ash = {
  layer = "air", blend = "alpha", shape = "disc", rate = 9,
  count = { 1, 2 }, life = { 5, 10 }, emit = "box", boxW = 900, boxH = 560,
  speed = { 8, 26 }, spread = TAU, drag = 0.5, grav = 9, wind = 0.7,
  swirl = 14, swirlFreq = 1.1,
  size = { 2.8, 6.0 }, sizeCurve = "hold", alphaCurve = "lateOut", alpha = 0.85,
  spin = { -1.4, 1.4 },
  colors = { c(R.rock[4], 0.55), c(R.rock[3], 0.75), c(R.rock[2], 0) },
}

DEFS.rain = {
  layer = "air", blend = "alpha", shape = "drop", rate = 120,
  count = { 2, 4 }, life = { 0.42, 0.62 }, emit = "box", boxW = 1000, boxH = 120,
  speed = { 760, 940 }, angle = pi * 0.5 - 0.16, spread = 0.05,
  drag = 0, grav = 220, wind = 0.15, align = true, stretch = 0.006,
  size = { 6, 10 }, sizeCurve = "hold", alphaCurve = "hold", alpha = 0.6,
  colors = { c(R.water[4], 0.5), c(R.water[4], 0.85), c(R.water[3], 0.5) },
  onDeath = "rain_splash", onDeathChance = 0.55,
}

DEFS.rain_splash = {
  { layer = "ground", blend = "alpha", shape = "ring",
    count = 1, life = { 0.28, 0.4 }, emit = "point",
    ring0 = 1, ring1 = 13, ringW = 2.2, ringSegs = 18, ringCurve = "swell",
    alphaCurve = "smoothOut", alpha = 0.5,
    colors = { c(R.water[4], 0.9), c(R.water[3], 0) } },
  { layer = "ground", blend = "alpha", shape = "dot",
    count = { 3, 5 }, life = { 0.2, 0.36 }, emit = "point",
    speed = { 40, 110 }, spread = TAU, drag = 5.5, grav = 260,
    size = { 1.8, 3.2 }, sizeCurve = "shrink", alphaCurve = "fade", alpha = 0.7,
    colors = { c(R.water[4], 0.9), c(R.water[3], 0) } },
}

DEFS.mist = {
  layer = "ground", blend = "alpha", shape = "smoke", rate = 2.2,
  count = 1, life = { 9, 15 }, emit = "box", boxW = 900, boxH = 400,
  speed = { 5, 16 }, spread = TAU, drag = 0.3, wind = 0.5,
  size = { 150, 300 }, sizeCurve = "grow", alphaCurve = "breathe", alpha = 0.2,
  spin = { -0.12, 0.12 },
  colors = { c(P.tod.night.fog, 0.5), c(R.water[4], 0.55), c(P.inkFaint, 0.3) },
}

------------------------------------------------------------------- player
DEFS.footstep = {
  layer = "ground", blend = "alpha", shape = "smoke",
  count = { 4, 6 }, life = { 0.4, 0.72 }, emit = "disc", radius = { 0, 5 },
  speed = { 22, 62 }, spread = 1.5, drag = 4.6, grav = -6,
  size = { 10, 21 }, sizeCurve = "swell", alphaCurve = "smoothOut", alpha = 0.66,
  spin = { -1.6, 1.6 },
  colors = { c(R.sand[4], 0.55), c(R.sand[3], 0.4), c(R.soil[3], 0) },
}

DEFS.dash_burst = {
  { layer = "ground", blend = "alpha", shape = "ring",
    count = 1, life = 0.34, emit = "point",
    ring0 = 6, ring1 = 62, ringW = 7, ringSegs = 40, ringCurve = "swell",
    alphaCurve = "smoothOut", alpha = 0.85,
    colors = { c(R.sand[4], 0.9), c(R.sand[3], 0.6), c(R.sand[2], 0) } },
  { layer = "world", blend = "add", shape = "streak",
    count = { 8, 11 }, life = { 0.18, 0.34 }, emit = "disc", radius = { 2, 10 },
    speed = { 220, 480 }, spread = 1.15, drag = 7.5, align = true, stretch = 0.0125,
    size = { 6, 11 }, sizeCurve = "shrink", alphaCurve = "sharpOut",
    colors = { c(W, 1), c(P.accentCool, 0.8), c(P.accentCool, 0) } },
  { layer = "ground", blend = "alpha", shape = "smoke",
    count = { 6, 9 }, life = { 0.34, 0.62 }, emit = "disc", radius = { 3, 14 },
    speed = { 60, 190 }, spread = 2.4, drag = 5.2,
    size = { 15, 31 }, sizeCurve = "swell", alphaCurve = "smoothOut", alpha = 0.6,
    spin = { -2.4, 2.4 },
    colors = { c(R.sand[4], 0.6), c(R.sand[3], 0.35), c(R.soil[2], 0) } },
}

DEFS.dash_trail = {
  layer = "world", blend = "add", shape = "streak", rate = 70,
  count = 1, life = { 0.16, 0.26 }, emit = "disc", radius = { 0, 5 },
  speed = { 10, 40 }, spread = TAU, drag = 6, align = true, stretch = 0.035,
  size = { 12, 19 }, sizeCurve = "shrink", alphaCurve = "sharpOut", alpha = 0.6,
  colors = { c(P.accentCool, 0.9), c(P.o2, 0.5), c(P.accentCool, 0) },
}

DEFS.land = {
  { layer = "ground", blend = "alpha", shape = "ring",
    count = 1, life = 0.4, emit = "point",
    ring0 = 4, ring1 = 54, ringW = 9, ringSegs = 36, ringCurve = "swell",
    alphaCurve = "smoothOut", alpha = 0.8,
    colors = { c(R.sand[4], 0.85), c(R.soil[3], 0) } },
  { layer = "ground", blend = "alpha", shape = "smoke",
    count = { 9, 13 }, life = { 0.4, 0.8 }, emit = "disc", radius = { 2, 12 },
    speed = { 70, 175 }, spread = TAU, drag = 5.4, grav = -14,
    size = { 15, 30 }, sizeCurve = "swell", alphaCurve = "smoothOut", alpha = 0.68,
    spin = { -2, 2 },
    colors = { c(R.sand[4], 0.8), c(R.sand[3], 0.5), c(R.soil[2], 0) } },
  { layer = "world", blend = "alpha", shape = "shard",
    count = { 4, 7 }, life = { 0.35, 0.6 }, emit = "disc", radius = { 0, 8 },
    speed = { 120, 260 }, spread = 1.9, drag = 2.2, grav = 900,
    size = { 4, 8 }, sizeCurve = "hold", alphaCurve = "lateOut",
    spin = { -13, 13 }, tumble = 9,
    colors = { c(R.soil[3]), c(R.soil[2]), c(R.soil[1], 0) } },
}

DEFS.hurt_spray = {
  { layer = "air", blend = "alpha", shape = "shard",
    count = { 14, 19 }, life = { 0.35, 0.66 }, emit = "disc", radius = { 0, 6 },
    speed = { 150, 400 }, spread = 1.5, drag = 3.4, grav = 620,
    size = { 8, 15 }, sizeCurve = "hold", alphaCurve = "lateOut",
    spin = { -16, 16 }, tumble = 11,
    colors = { lt(P.danger, 0.5), c(P.danger), dk(P.danger, 0.55, 0) } },
  { layer = "air", blend = "add", shape = "flare",
    count = 1, life = 0.14, emit = "point",
    speed = 0, size = { 54, 54 }, sizeCurve = "sharpOut", alphaCurve = "sharpOut",
    colors = { c(W, 0.85), c(P.danger, 0) } },
}

DEFS.heal = {
  { layer = "air", blend = "add", shape = "plus",
    count = { 7, 10 }, life = { 0.6, 1.1 }, emit = "disc", radius = { 4, 20 },
    speed = { 26, 62 }, angle = -pi * 0.5, spread = 1.0, drag = 1.4, grav = -70,
    swirl = 22, swirlFreq = 2.6,
    size = { 8, 15 }, sizeCurve = "softIn", alphaCurve = "softIn",
    colors = { c(P.accent, 0.9), c(W, 1), c(P.accent, 0) } },
  { layer = "ground", blend = "add", shape = "ring",
    count = 1, life = 0.55, emit = "point",
    ring0 = 8, ring1 = 44, ringW = 4.5, ringSegs = 34, ringCurve = "swell",
    alphaCurve = "smoothOut",
    colors = { c(P.accent, 0.9), c(P.accent, 0) } },
}

------------------------------------------------------------------- combat
DEFS.shove_arc = {
  { layer = "air", blend = "add", shape = "arc",
    count = 1, life = 0.3, emit = "point",
    arcR0 = 34, arcR1 = 88, arcW = 26, arcSpan = 1.75, arcHead = 0.42, arcTail = 0.3,
    alphaCurve = "smoothOut",
    colors = { c(W, 0.95), c(P.accentCool, 0.8), c(P.accentCool, 0) } },
  { layer = "air", blend = "add", shape = "streak",
    count = { 7, 10 }, life = { 0.14, 0.26 }, emit = "ring", radius = { 40, 72 },
    speed = { 130, 300 }, spread = 1.7, drag = 8, align = true, stretch = 0.015,
    size = { 6, 12 }, sizeCurve = "shrink", alphaCurve = "sharpOut",
    colors = { c(W, 1), c(P.o2, 0.7), c(P.accentCool, 0) } },
}

DEFS.impact = {
  { layer = "air", blend = "add", shape = "flare",
    count = 1, life = 0.11, emit = "point",
    size = { 76, 76 }, sizeCurve = "sharpOut", alphaCurve = "sharpOut",
    colors = { c(W, 1), lt(R.ember[4], 0.4, 0.6), c(R.ember[3], 0) } },
  { layer = "air", blend = "add", shape = "ring",
    count = 1, life = 0.24, emit = "point",
    ring0 = 5, ring1 = 58, ringW = 12, ringSegs = 32, ringCurve = "swell",
    alphaCurve = "sharpOut",
    colors = { lt(R.ember[4], 0.55, 0.95), c(R.ember[4], 0.7), c(R.ember[3], 0) } },
  { layer = "air", blend = "alpha", shape = "shard",
    count = { 13, 18 }, life = { 0.26, 0.5 }, emit = "disc", radius = { 0, 7 },
    speed = { 220, 520 }, spread = TAU, drag = 5.5, grav = 320,
    size = { 7, 15 }, sizeCurve = "hold", alphaCurve = "lateOut",
    spin = { -20, 20 }, tumble = 13,
    colors = { c(W, 1), c(R.ember[4]), c(R.ember[2], 0) } },
  { layer = "air", blend = "add", shape = "spark",
    count = { 8, 12 }, life = { 0.15, 0.3 }, emit = "point",
    speed = { 260, 620 }, spread = TAU, drag = 7, align = true, stretch = 0.00875,
    size = { 10, 18 }, sizeCurve = "shrink", alphaCurve = "sharpOut",
    colors = { c(W, 1), lt(R.ember[4], 0.3, 0.9), c(R.ember[3], 0) } },
  { layer = "world", blend = "alpha", shape = "smoke",
    count = { 4, 6 }, life = { 0.3, 0.6 }, emit = "disc", radius = { 0, 10 },
    speed = { 60, 170 }, spread = TAU, drag = 5,
    size = { 14, 30 }, sizeCurve = "swell", alphaCurve = "smoothOut", alpha = 0.4,
    spin = { -2.5, 2.5 },
    colors = { c(R.rock[4], 0.6), c(R.rock[3], 0.35), c(R.rock[1], 0) } },
}

DEFS.pulse_ring = {
  { layer = "air", blend = "add", shape = "ring",
    count = 1, life = 0.62, emit = "point",
    ring0 = 14, ring1 = 210, ringW = 34, ringSegs = 72, ringCurve = "swell",
    alphaCurve = "smoothOut", alpha = 0.7,
    colors = { c(W, 0.8), c(P.o2, 0.6), c(P.accentCool, 0) } },
  { layer = "air", blend = "add", shape = "ring",
    count = 1, life = 0.5, emit = "point",
    ring0 = 10, ring1 = 200, ringW = 5, ringSegs = 72, ringCurve = "swell",
    alphaCurve = "sharpOut",
    colors = { c(W, 1), c(P.o2, 0.9), c(P.accentCool, 0) } },
  { layer = "air", blend = "alpha", shape = "halo",
    count = 1, life = 0.55, emit = "point",
    size = { 130, 430 }, sizeCurve = "swell", alphaCurve = "smoothOut", alpha = 0.16,
    colors = { c(P.accentCool, 0.6), c(P.o2, 0.3), c(P.accentCool, 0) } },
  { layer = "air", blend = "add", shape = "mote",
    count = { 14, 20 }, life = { 0.3, 0.6 }, emit = "ring", radius = { 20, 40 },
    speed = { 240, 460 }, spread = 0.5, drag = 2.6,
    size = { 5, 10 }, sizeCurve = "shrink", alphaCurve = "smoothOut",
    colors = { c(W, 1), c(P.o2, 0.8), c(P.accentCool, 0) } },
}

DEFS.hit_spark = {
  layer = "air", blend = "add", shape = "streak",
  count = { 7, 11 }, life = { 0.1, 0.24 }, emit = "point",
  speed = { 200, 460 }, spread = 1.6, drag = 9, align = true, stretch = 0.0125,
  size = { 8, 15 }, sizeCurve = "shrink", alphaCurve = "sharpOut",
  colors = { c(W, 1), lt(R.ember[4], 0.4, 0.9), c(R.ember[3], 0) },
}

DEFS.crit = {
  { layer = "air", blend = "add", shape = "flare",
    count = 1, life = 0.2, emit = "point",
    size = { 130, 130 }, sizeCurve = "sharpOut", alphaCurve = "sharpOut",
    colors = { c(W, 1), c(P.warn, 0.7), c(R.ember[3], 0) } },
  { layer = "air", blend = "add", shape = "ring",
    count = 2, life = { 0.3, 0.42 }, emit = "point",
    ring0 = 8, ring1 = 96, ringW = 9, ringSegs = 44, ringCurve = "swell",
    alphaCurve = "sharpOut",
    colors = { lt(P.warn, 0.55, 1), c(P.warn, 0.85), c(R.ember[2], 0) } },
  { layer = "air", blend = "add", shape = "spark",
    count = { 12, 16 }, life = { 0.2, 0.42 }, emit = "point",
    speed = { 340, 760 }, spread = TAU, drag = 6.2, align = true, stretch = 0.0075,
    size = { 13, 24 }, sizeCurve = "shrink", alphaCurve = "sharpOut",
    colors = { c(W, 1), c(P.warn, 0.9), c(R.ember[2], 0) } },
  { layer = "air", blend = "alpha", shape = "shard",
    count = { 8, 12 }, life = { 0.3, 0.6 }, emit = "point",
    speed = { 180, 430 }, spread = TAU, drag = 4, grav = 400,
    size = { 6, 12 }, sizeCurve = "hold", alphaCurve = "lateOut",
    spin = { -22, 22 }, tumble = 14,
    colors = { c(W, 1), c(P.warn), c(R.ember[2], 0) } },
}

------------------------------------------------------------------- growth
DEFS.plant_burst = {
  -- 1. the soft green pop
  { layer = "air", blend = "add", shape = "flare",
    count = 1, life = 0.3, emit = "point",
    size = { 84, 84 }, sizeCurve = "bloom", alphaCurve = "smoothOut", alpha = 0.85,
    colors = { c(W, 0.95), lt(R.leafHi[4], 0.35, 0.8), c(R.leaf[3], 0) } },
  -- 2. the ring
  { layer = "ground", blend = "add", shape = "ring",
    count = 1, life = 0.52, emit = "point",
    ring0 = 5, ring1 = 66, ringW = 8, ringSegs = 40, ringCurve = "swell",
    alphaCurve = "smoothOut",
    colors = { lt(R.leafHi[4], 0.5, 0.95), c(R.leafHi[4], 0.8), c(R.leaf[3], 0) } },
  -- 3. leaves thrown out, settling
  { layer = "world", blend = "alpha", shape = "leaf",
    count = { 5, 7 }, life = { 0.8, 1.5 }, emit = "disc", radius = { 0, 6 },
    speed = { 90, 220 }, spread = TAU, drag = 3.4, grav = 130,
    swirl = 40, swirlFreq = 3.2,
    size = { 10, 17 }, sizeCurve = "hold", alphaCurve = "lateOut",
    spin = { -8, 8 }, tumble = 7,
    colors = { c(R.leafHi[4]), c(R.leaf[3]), c(R.leaf[2], 0) } },
  -- 4. rising sparkles - the joy
  { layer = "air", blend = "add", shape = "mote",
    count = { 17, 23 }, life = { 0.7, 1.4 }, emit = "disc", radius = { 2, 16 },
    speed = { 30, 90 }, angle = -pi * 0.5, spread = 1.4, drag = 1.6, grav = -95,
    swirl = 30, swirlFreq = 3.0,
    size = { 7, 13 }, sizeCurve = "softIn", alphaCurve = "softIn",
    pulse = 0.35, pulseFreq = 9,
    colors = { c(W, 1), c(P.accent, 0.95), lt(R.leafHi[4], 0.3, 0.5), c(P.accent, 0) } },
  -- 5. base dust
  { layer = "ground", blend = "alpha", shape = "smoke",
    count = { 4, 6 }, life = { 0.4, 0.8 }, emit = "disc", radius = { 2, 12 },
    speed = { 40, 110 }, spread = TAU, drag = 5,
    size = { 11, 22 }, sizeCurve = "swell", alphaCurve = "smoothOut", alpha = 0.4,
    spin = { -2, 2 },
    colors = { c(R.soil[4], 0.6), c(R.soil[3], 0.4), c(R.soil[2], 0) } },
}

DEFS.grow_up = {
  { layer = "air", blend = "add", shape = "ring",
    count = 3, life = { 0.5, 0.85 }, emit = "point",
    ring0 = 40, ring1 = 8, ringW = 5, ringSegs = 34, ringCurve = "swell",
    alphaCurve = "breathe",
    colors = { c(P.accent, 0.8), lt(P.accent, 0.45, 0.9), c(R.leafHi[4], 0) } },
  { layer = "air", blend = "add", shape = "plus",
    count = { 10, 14 }, life = { 0.7, 1.3 }, emit = "ring", radius = { 14, 30 },
    speed = { 18, 44 }, angle = -pi * 0.5, spread = 0.7, drag = 1.1, grav = -120,
    swirl = 46, swirlFreq = 3.4,
    size = { 8, 15 }, sizeCurve = "softIn", alphaCurve = "softIn",
    colors = { c(W, 1), c(P.accent, 0.9), c(R.leafHi[4], 0) } },
  { layer = "world", blend = "alpha", shape = "leaf",
    count = { 6, 9 }, life = { 0.9, 1.6 }, emit = "disc", radius = { 4, 18 },
    speed = { 40, 130 }, spread = TAU, drag = 2.6, grav = -30, wind = 0.4,
    swirl = 40, swirlFreq = 2.4,
    size = { 9, 15 }, sizeCurve = "hold", alphaCurve = "lateOut",
    spin = { -6, 6 }, tumble = 6,
    colors = { c(R.leafHi[4]), c(R.leaf[3]), c(R.leaf[2], 0) } },
}

DEFS.heal_ground = {
  { layer = "ground", blend = "add", shape = "ring",
    count = 2, life = { 0.7, 1.0 }, emit = "point",
    ring0 = 10, ring1 = 150, ringW = 6, ringSegs = 56, ringCurve = "swell",
    alphaCurve = "smoothOut", alpha = 0.8,
    colors = { c(P.accent, 0.85), c(R.moss[4], 0.5), c(R.moss[3], 0) } },
  { layer = "air", blend = "add", shape = "mote",
    count = { 16, 22 }, life = { 0.8, 1.5 }, emit = "disc", radius = { 10, 130 },
    speed = { 14, 40 }, angle = -pi * 0.5, spread = 0.8, drag = 1, grav = -60,
    swirl = 18, swirlFreq = 2,
    size = { 5, 9 }, sizeCurve = "softIn", alphaCurve = "softIn",
    colors = { c(P.accent, 0.9), c(W, 0.8), c(R.moss[4], 0) } },
}

------------------------------------------------------------------ economy
DEFS.cobalt_shimmer = {
  layer = "air", blend = "add", shape = "mote", rate = 11,
  count = 1, life = { 0.7, 1.4 }, emit = "disc", radius = { 3, 15 },
  speed = { 10, 34 }, angle = -pi * 0.5, spread = 1.6, drag = 1.2, grav = -46,
  swirl = 24, swirlFreq = 3.4,
  size = { 4, 8 }, sizeCurve = "softIn", alphaCurve = "softIn",
  pulse = 0.4, pulseFreq = 11,
  colors = { c(R.cobalt[4], 0.9), c(W, 1), c(R.cobalt[3], 0) },
}

DEFS.cobalt_pickup = {
  -- sparks fall inward from a spread of radii, so they arrive as a rush
  { layer = "air", blend = "add", shape = "streak",
    count = { 20, 26 }, life = { 0.2, 0.46 }, emit = "ring", radius = { 26, 82 },
    speed = { 120, 250 }, inward = true, drag = -2.6, align = true, stretch = 0.014,
    size = { 7, 13 }, sizeCurve = "shrink", alphaCurve = "lateOut",
    colors = { c(R.cobalt[3], 0.4), c(R.cobalt[4], 1), c(W, 1) } },
  { layer = "air", blend = "add", shape = "mote",
    count = { 8, 12 }, life = { 0.25, 0.5 }, emit = "ring", radius = { 30, 78 },
    speed = { 90, 190 }, inward = true, drag = -2.2,
    size = { 5, 9 }, sizeCurve = "shrink", alphaCurve = "lateOut",
    colors = { c(R.cobalt[4], 0.5), c(W, 1) } },
  -- the core lighting up as they land
  { layer = "air", blend = "add", shape = "flare",
    count = 1, life = 0.5, emit = "point",
    size = { 46, 46 }, sizeCurve = "softIn", alphaCurve = "softIn",
    colors = { c(R.cobalt[4], 0.6), c(W, 1), c(R.cobalt[3], 0) } },
  { layer = "air", blend = "add", shape = "ring",
    count = 1, life = 0.42, emit = "point",
    ring0 = 78, ring1 = 5, ringW = 5, ringSegs = 34, ringCurve = "swell",
    alphaCurve = "lateOut",
    colors = { c(R.cobalt[3], 0.35), c(R.cobalt[4], 0.9), c(W, 0) } },
}

DEFS.deposit_pop = {
  { layer = "air", blend = "alpha", shape = "shard",
    count = { 9, 13 }, life = { 0.4, 0.75 }, emit = "disc", radius = { 0, 6 },
    speed = { 130, 280 }, angle = -pi * 0.5, spread = 2.0, drag = 2.6, grav = 700,
    size = { 7, 13 }, sizeCurve = "hold", alphaCurve = "lateOut",
    spin = { -14, 14 }, tumble = 10,
    colors = { c(W, 1), c(R.cobalt[4]), c(R.cobalt[2], 0) } },
  { layer = "air", blend = "add", shape = "ring",
    count = 1, life = 0.3, emit = "point",
    ring0 = 4, ring1 = 46, ringW = 6, ringSegs = 30, ringCurve = "swell",
    alphaCurve = "sharpOut",
    colors = { lt(R.cobalt[4], 0.5, 0.9), c(R.cobalt[4], 0.75), c(R.cobalt[3], 0) } },
}

--------------------------------------------------------------------- bots
DEFS.bot_boot = {
  { layer = "air", blend = "add", shape = "ring",
    count = 1, life = 0.42, emit = "point",
    ring0 = 52, ring1 = 12, ringW = 5, ringSegs = 30, ringCurve = "swell",
    alphaCurve = "breathe",
    colors = { c(P.eye, 0.6), lt(P.eye, 0.4, 0.95), c(P.eye, 0) } },
  { layer = "air", blend = "add", shape = "streak",
    count = { 8, 10 }, life = { 0.2, 0.36 }, emit = "disc", radius = { 2, 8 },
    speed = { 130, 260 }, spread = TAU, drag = 11, align = true, stretch = 0.0125,
    size = { 6, 11 }, sizeCurve = "shrink", alphaCurve = "sharpOut",
    colors = { c(W, 1), c(P.eye, 0.9), c(R.metal[4], 0) } },
  { layer = "air", blend = "add", shape = "flare",
    count = 1, life = 0.3, emit = "point",
    size = { 44, 44 }, sizeCurve = "bloom", alphaCurve = "smoothOut", alpha = 0.7,
    colors = { c(W, 0.9), c(P.eye, 0.7), c(R.metalW[3], 0) } },
}

DEFS.bot_spark = {
  layer = "air", blend = "add", shape = "streak", rate = 7,
  count = { 1, 3 }, life = { 0.12, 0.3 }, emit = "disc", radius = { 0, 7 },
  speed = { 90, 260 }, spread = TAU, drag = 4.5, grav = 520,
  align = true, stretch = 0.01125,
  size = { 4, 8 }, sizeCurve = "shrink", alphaCurve = "flick",
  colors = { c(W, 1), c(P.warn, 0.9), c(R.ember[3], 0) },
}

DEFS.bot_death = {
  -- the hard shard burst: the body coming apart
  { layer = "world", blend = "alpha", shape = "shard",
    count = { 14, 19 }, life = { 0.7, 1.3 }, emit = "disc", radius = { 0, 8 },
    speed = { 130, 380 }, spread = TAU, drag = 3.0, grav = 720,
    size = { 6, 13 }, sizeCurve = "hold", alphaCurve = "lateOut",
    spin = { -18, 18 }, tumble = 12,
    colors = { c(R.metal[4]), c(R.metal[3]), c(R.metal[2]), c(R.metal[1], 0) } },
  -- a short, colourless flash: no celebration
  { layer = "air", blend = "add", shape = "flare",
    count = 1, life = 0.13, emit = "point",
    size = { 62, 62 }, sizeCurve = "sharpOut", alphaCurve = "sharpOut", alpha = 0.7,
    colors = { c(R.metal[4], 0.9), c(P.eyeDown, 0.5), c(R.metal[2], 0) } },
  -- smoke that hangs
  { layer = "air", blend = "alpha", shape = "smoke",
    count = { 8, 12 }, life = { 1.4, 2.6 }, emit = "disc", radius = { 2, 12 },
    speed = { 20, 70 }, spread = TAU, drag = 2.4, grav = -22, wind = 0.35,
    swirl = 12, swirlFreq = 1.1,
    size = { 22, 54 }, sizeCurve = "puff", alphaCurve = "lateOut", alpha = 0.55,
    spin = { -1.2, 1.2 },
    colors = { c(R.rock[4], 0.7), c(R.rock[3], 0.5), c(R.rock[1], 0) } },
  -- lingering embers in the wreck
  { layer = "air", blend = "add", shape = "dot",
    count = { 5, 8 }, life = { 1.8, 3.4 }, emit = "disc", radius = { 0, 10 },
    speed = { 8, 40 }, spread = TAU, drag = 1.8, grav = -14, wind = 0.3,
    swirl = 10, swirlFreq = 1.4,
    size = { 3, 6 }, sizeCurve = "shrink", alphaCurve = "emberFade",
    colors = { c(P.eyeDown, 0.9), c(R.ember[3], 0.7), c(R.ember[2], 0) } },
  -- the eye going out
  { layer = "air", blend = "add", shape = "dot",
    count = 1, life = 0.9, emit = "point",
    size = { 16, 16 }, sizeCurve = "shrink", alphaCurve = "flick",
    colors = { c(P.eyeDown, 1), c(P.eyeDown, 0.4), c(P.eyeDown, 0) } },
}

DEFS.love_heart = {
  { layer = "air", blend = "alpha", shape = "heart",
    count = { 3, 5 }, life = { 1.7, 2.6 }, emit = "disc", radius = { 2, 12 },
    speed = { 16, 34 }, angle = -pi * 0.5, spread = 0.7, drag = 0.9, grav = -22,
    swirl = 15, swirlFreq = 1.5,
    size = { 18, 29 }, sizeCurve = "riseIn", alphaCurve = "softIn", alpha = 0.95,
    spin = { -0.5, 0.5 },
    colors = { c(P.love, 0.8), lt(P.love, 0.35, 1), c(P.love, 0) } },
  { layer = "air", blend = "add", shape = "halo",
    count = { 3, 5 }, life = { 1.7, 2.6 }, emit = "disc", radius = { 2, 12 },
    speed = { 16, 34 }, angle = -pi * 0.5, spread = 0.7, drag = 0.9, grav = -22,
    swirl = 15, swirlFreq = 1.5,
    size = { 42, 64 }, sizeCurve = "riseIn", alphaCurve = "softIn", alpha = 0.15,
    colors = { c(P.love, 0.7), c(P.love, 0.5), c(P.love, 0) } },
  { layer = "air", blend = "add", shape = "mote",
    count = { 5, 8 }, life = { 1.1, 2.0 }, emit = "disc", radius = { 4, 22 },
    speed = { 8, 26 }, angle = -pi * 0.5, spread = 1.2, drag = 0.8, grav = -18,
    swirl = 20, swirlFreq = 2.2,
    size = { 3.5, 6 }, sizeCurve = "softIn", alphaCurve = "softIn", alpha = 0.8,
    colors = { lt(P.love, 0.5, 0.9), c(P.love, 0.7), c(P.love, 0) } },
}

DEFS.confused_bubble = {
  { layer = "air", blend = "alpha", shape = "bubble",
    count = { 2, 3 }, life = { 0.9, 1.5 }, emit = "disc", radius = { 2, 10 },
    speed = { 14, 30 }, angle = -pi * 0.5, spread = 1.1, drag = 1.3, grav = -30,
    swirl = 26, swirlFreq = 2.8,
    size = { 12, 22 }, sizeCurve = "riseIn", alphaCurve = "softIn", alpha = 0.85,
    spin = { -1.2, 1.2 },
    colors = { c(P.inkDim, 0.8), c(P.ink, 0.9), c(P.inkFaint, 0) } },
  { layer = "air", blend = "alpha", shape = "dot",
    count = { 2, 3 }, life = { 0.7, 1.1 }, emit = "disc", radius = { 2, 8 },
    speed = { 10, 22 }, angle = -pi * 0.5, spread = 1.4, drag = 1.4, grav = -24,
    size = { 4, 7 }, sizeCurve = "softIn", alphaCurve = "softIn", alpha = 0.6,
    colors = { c(P.inkDim, 0.7), c(P.inkFaint, 0) } },
}

-------------------------------------------------------------------- blight
DEFS.blight_spore = {
  layer = "air", blend = "add", shape = "mote", rate = 9,
  count = { 1, 2 }, life = { 1.8, 3.6 }, emit = "disc", radius = { 2, 16 },
  speed = { 12, 40 }, spread = TAU, drag = 1.1, grav = -18, wind = 0.3,
  swirl = 26, swirlFreq = 2.2,
  size = { 4, 9 }, sizeCurve = "softIn", alphaCurve = "softIn", alpha = 0.8,
  pulse = 0.3, pulseFreq = 6,
  colors = { c(R.blight[4], 0.9), c(R.blight[3], 0.8), c(R.blight[2], 0) },
}

DEFS.blight_death = {
  { layer = "air", blend = "add", shape = "mote",
    count = { 26, 34 }, life = { 0.5, 1.1 }, emit = "disc", radius = { 0, 12 },
    speed = { 40, 170 }, spread = TAU, drag = 4.6, grav = -60,
    swirl = 40, swirlFreq = 5,
    size = { 6, 14 }, sizeCurve = "shrink", alphaCurve = "flick",
    colors = { lt(R.blight[4], 0.4, 1), c(R.blight[4], 0.9), c(R.blight[2], 0) } },
  { layer = "air", blend = "add", shape = "ring",
    count = 1, life = 0.34, emit = "point",
    ring0 = 46, ring1 = 6, ringW = 6, ringSegs = 30, ringCurve = "swell",
    alphaCurve = "lateOut",
    colors = { c(R.blight[3], 0.4), c(R.blight[4], 0.9), c(W, 0) } },
  { layer = "world", blend = "alpha", shape = "smoke",
    count = { 5, 8 }, life = { 0.7, 1.4 }, emit = "disc", radius = { 0, 10 },
    speed = { 20, 70 }, spread = TAU, drag = 3.4, grav = -30,
    size = { 16, 38 }, sizeCurve = "puff", alphaCurve = "smoothOut", alpha = 0.5,
    spin = { -2, 2 },
    colors = { c(R.blight[2], 0.7), c(R.blight[1], 0.4), c(R.blight[1], 0) } },
}

DEFS.acid_splash = {
  { layer = "world", blend = "alpha", shape = "blob",
    count = { 10, 14 }, life = { 0.35, 0.7 }, emit = "disc", radius = { 0, 8 },
    speed = { 90, 240 }, spread = TAU, drag = 2.4, grav = 620,
    size = { 7, 15 }, sizeCurve = "shrink", alphaCurve = "lateOut",
    spin = { -6, 6 },
    colors = { lt(P.acid, 0.4, 1), c(P.acid, 0.9), dk(P.acid, 0.5, 0) } },
  { layer = "ground", blend = "alpha", shape = "blob",
    count = 1, life = 0.6, emit = "point",
    size = { 18, 40 }, sizeCurve = "swell", alphaCurve = "smoothOut", alpha = 0.6,
    colors = { c(P.acid, 0.8), dk(P.acid, 0.45, 0.5), dk(P.acid, 0.7, 0) } },
  { layer = "air", blend = "add", shape = "mote",
    count = { 4, 7 }, life = { 0.4, 0.9 }, emit = "disc", radius = { 2, 14 },
    speed = { 10, 34 }, angle = -pi * 0.5, spread = 1.2, drag = 1.4, grav = -40,
    size = { 3, 7 }, sizeCurve = "softIn", alphaCurve = "softIn", alpha = 0.7,
    colors = { c(P.acid, 0.9), c(P.acid, 0) } },
}

DEFS.rift_open = {
  { layer = "air", blend = "add", shape = "flare",
    count = 1, life = 0.5, emit = "point",
    size = { 150, 150 }, sizeCurve = "bloom", alphaCurve = "smoothOut", alpha = 0.9,
    colors = { c(W, 0.9), c(R.rift[4], 0.9), c(R.rift[3], 0) } },
  { layer = "air", blend = "add", shape = "ring",
    count = 2, life = { 0.4, 0.6 }, emit = "point",
    ring0 = 8, ring1 = 130, ringW = 12, ringSegs = 50, ringCurve = "swell",
    alphaCurve = "sharpOut",
    colors = { lt(R.rift[4], 0.5, 0.95), c(R.rift[4], 0.85), c(R.rift[2], 0) } },
  { layer = "air", blend = "alpha", shape = "shard",
    count = { 16, 22 }, life = { 0.4, 0.9 }, emit = "disc", radius = { 0, 14 },
    speed = { 200, 560 }, spread = TAU, drag = 4.4,
    size = { 7, 16 }, sizeCurve = "hold", alphaCurve = "lateOut",
    spin = { -24, 24 }, tumble = 15,
    colors = { c(R.rift[4]), c(R.rift[3]), c(R.rift[1], 0) } },
  -- motes sucked inward: the tear breathing in
  { layer = "air", blend = "add", shape = "mote",
    count = { 20, 28 }, life = { 0.5, 0.9 }, emit = "ring", radius = { 110, 230 },
    speed = { 130, 300 }, inward = true, drag = -1.6,
    align = true, stretch = 0.005,
    size = { 4, 9 }, sizeCurve = "shrink", alphaCurve = "lateOut",
    colors = { c(R.rift[3], 0.4), c(R.rift[4], 1), c(W, 0.9) } },
}

DEFS.rift_ambient = {
  { layer = "air", blend = "add", shape = "mote", rate = 14,
    count = 1, life = { 0.8, 1.5 }, emit = "ring", radius = { 60, 120 },
    speed = { 60, 130 }, inward = true, drag = -0.8, align = true, stretch = 0.00625,
    size = { 3, 7 }, sizeCurve = "shrink", alphaCurve = "lateOut", alpha = 0.85,
    colors = { c(R.rift[3], 0.3), c(R.rift[4], 0.9), c(P.love, 0.5) } },
  { layer = "air", blend = "add", shape = "streak", rate = 2.5,
    count = 1, life = { 0.2, 0.4 }, emit = "disc", radius = { 6, 26 },
    speed = { 80, 200 }, spread = TAU, drag = 6, align = true, stretch = 0.0125,
    size = { 6, 12 }, sizeCurve = "shrink", alphaCurve = "flick",
    colors = { c(W, 1), c(R.rift[4], 0.8), c(R.rift[2], 0) } },
}

---------------------------------------------------------------------- boss
DEFS.beam_charge = {
  { layer = "air", blend = "add", shape = "mote", rate = 40,
    count = 1, life = { 0.3, 0.55 }, emit = "ring", radius = { 90, 190 },
    speed = { 220, 420 }, inward = true, drag = -1.2, align = true, stretch = 0.005,
    size = { 4, 9 }, sizeCurve = "shrink", alphaCurve = "lateOut",
    colors = { c(P.danger, 0.3), c(P.warn, 0.9), c(W, 1) } },
  { layer = "air", blend = "add", shape = "flare", rate = 12,
    count = 1, life = 0.3, emit = "point",
    size = { 40, 90 }, sizeCurve = "breathe", alphaCurve = "breathe", alpha = 0.7,
    colors = { c(P.warn, 0.8), c(W, 1), c(P.danger, 0) } },
  { layer = "air", blend = "add", shape = "ring", rate = 5,
    count = 1, life = 0.45, emit = "point",
    ring0 = 120, ring1 = 14, ringW = 4, ringSegs = 44, ringCurve = "swell",
    alphaCurve = "lateOut",
    colors = { c(P.danger, 0.25), c(P.warn, 0.8), c(W, 0) } },
}

DEFS.slam_dust = {
  { layer = "ground", blend = "alpha", shape = "ring",
    count = 1, life = 0.6, emit = "point",
    ring0 = 10, ring1 = 240, ringW = 18, ringSegs = 64, ringCurve = "swell",
    alphaCurve = "smoothOut", alpha = 0.7,
    colors = { c(R.sand[4], 0.9), c(R.soil[3], 0.5), c(R.soil[1], 0) } },
  { layer = "world", blend = "alpha", shape = "smoke",
    count = { 20, 26 }, life = { 0.8, 1.6 }, emit = "ring", radius = { 20, 90 },
    speed = { 140, 340 }, spread = 0.55, drag = 3.2, grav = -30,
    size = { 28, 68 }, sizeCurve = "puff", alphaCurve = "smoothOut", alpha = 0.7,
    spin = { -1.8, 1.8 },
    colors = { c(R.sand[3], 0.75), c(R.soil[3], 0.45), c(R.soil[1], 0) } },
  { layer = "world", blend = "alpha", shape = "shard",
    count = { 12, 18 }, life = { 0.6, 1.1 }, emit = "disc", radius = { 0, 26 },
    speed = { 180, 460 }, spread = TAU, drag = 2.4, grav = 950,
    size = { 6, 14 }, sizeCurve = "hold", alphaCurve = "lateOut",
    spin = { -16, 16 }, tumble = 11,
    colors = { c(R.rock[4]), c(R.rock[3]), c(R.rock[1], 0) } },
}

DEFS.armour_break = {
  { layer = "air", blend = "add", shape = "flare",
    count = 1, life = 0.16, emit = "point",
    size = { 110, 110 }, sizeCurve = "sharpOut", alphaCurve = "sharpOut",
    colors = { c(W, 1), c(R.metal[4], 0.7), c(R.metal[2], 0) } },
  { layer = "world", blend = "alpha", shape = "shard",
    count = { 16, 22 }, life = { 0.8, 1.5 }, emit = "disc", radius = { 0, 16 },
    speed = { 200, 520 }, spread = TAU, drag = 2.2, grav = 900,
    size = { 9, 20 }, sizeCurve = "hold", alphaCurve = "lateOut",
    spin = { -15, 15 }, tumble = 9,
    colors = { c(R.metal[4]), c(R.metal[3]), c(R.metal[2]), c(R.metal[1], 0) } },
  { layer = "air", blend = "add", shape = "spark",
    count = { 12, 18 }, life = { 0.2, 0.5 }, emit = "disc", radius = { 0, 12 },
    speed = { 260, 640 }, spread = TAU, drag = 5.4, grav = 300,
    align = true, stretch = 0.0075,
    size = { 7, 14 }, sizeCurve = "shrink", alphaCurve = "flick",
    colors = { c(W, 1), c(P.warn, 0.9), c(R.ember[2], 0) } },
}

DEFS.core_expose = {
  { layer = "air", blend = "add", shape = "ring",
    count = 3, life = { 0.6, 1.0 }, emit = "point",
    ring0 = 12, ring1 = 180, ringW = 11, ringSegs = 56, ringCurve = "swell",
    alphaCurve = "smoothOut",
    colors = { lt(P.danger, 0.55, 1), c(P.danger, 0.85), c(R.blight[2], 0) } },
  { layer = "air", blend = "add", shape = "halo",
    count = 1, life = 1.1, emit = "point",
    size = { 60, 230 }, sizeCurve = "swell", alphaCurve = "breathe", alpha = 0.5,
    colors = { c(P.danger, 0.9), c(P.warn, 0.6), c(P.danger, 0) } },
  { layer = "air", blend = "add", shape = "streak",
    count = { 18, 24 }, life = { 0.3, 0.7 }, emit = "disc", radius = { 0, 18 },
    speed = { 200, 520 }, spread = TAU, drag = 4, align = true, stretch = 0.01,
    size = { 8, 16 }, sizeCurve = "shrink", alphaCurve = "smoothOut",
    colors = { c(W, 1), c(P.danger, 0.9), c(P.warn, 0) } },
}

VFX.DEFS = DEFS

------------------------------------------------------------- normalisation
local function pair2(v, a, b)
  if type(v) == "table" then return v[1], v[2] end
  if v ~= nil then return v, v end
  return a, b
end

local function normEmitter(e)
  e.life0, e.life1   = pair2(e.life, 0.5, 0.8)
  e.cnt0, e.cnt1     = pair2(e.count, 1, 1)
  e.spd0, e.spd1     = pair2(e.speed, 0, 0)
  e.rad0, e.rad1     = pair2(e.radius, 0, 0)
  e.sz0, e.sz1       = pair2(e.size, 6, 6)
  e.spin0, e.spin1   = pair2(e.spin, 0, 0)
  e.spread           = e.spread or 0
  e.angle            = e.angle or 0
  e.drag             = e.drag or 0
  e.grav             = e.grav or 0
  e.wind             = e.wind or 0
  e.swirl            = e.swirl or 0
  e.swirlFreq        = e.swirlFreq or 1
  e.alpha            = e.alpha or 1
  e.stretch          = e.stretch or 0
  e.tumble           = e.tumble or 0
  e.pulse            = e.pulse or 0
  e.pulseFreq        = e.pulseFreq or 1
  e.rate             = e.rate or 0
  e.detail           = e.detail or 0
  e.boxW             = e.boxW or 0
  e.boxH             = e.boxH or 0
  e.emit             = e.emit or "point"
  e.szFn             = CURVES[e.sizeCurve or "hold"]
  e.alFn             = CURVES[e.alphaCurve or "fade"]
  e.ringFn           = CURVES[e.ringCurve or "swell"]
  e.colors           = e.colors or { c(W, 1), c(W, 0) }
  e.nCol             = #e.colors
  e.li               = LAYER_IX[e.layer or "world"] or 2
  e.bi               = (e.blend == "add" or e.layer == "additive") and 2 or 1
  if e.shape == "ring" then
    e.kind = KIND_RING
    e.ring0 = e.ring0 or 2
    e.ring1 = e.ring1 or 40
    e.ringW = e.ringW or 4
    e.ringSegs = e.ringSegs or 32
  elseif e.shape == "arc" then
    e.kind = KIND_ARC
    e.arcR0 = e.arcR0 or 20; e.arcR1 = e.arcR1 or 70
    e.arcW = e.arcW or 20; e.arcSpan = e.arcSpan or 1.6
    e.arcHead = e.arcHead or 0.45; e.arcTail = e.arcTail or 0.3
  else
    e.kind = KIND_SPR
    e.quad = QUAD_IX[e.shape or "dot"] or QUAD_IX.dot
  end
  return e
end

local NAMES = {}
local function normalise()
  for name, def in pairs(DEFS) do
    local list = def
    if def.shape or def.colors or def.count then list = { def } end
    for i = 1, #list do normEmitter(list[i]) end
    DEFS[name] = list
    NAMES[#NAMES + 1] = name
  end
  table.sort(NAMES)
end

function VFX.names() return NAMES end

------------------------------------------------------------------- state
local parts   = {}          -- dense pool; 1..alive are live
local alive   = 0
local quality = 2
local qmul    = 1
local windX, windY = 0, 0

local batches = {}          -- [layerIx][blendIx] = SpriteBatch
local geo     = {}          -- [layerIx][blendIx] = { n = 0, [i] = particle }
local quads   = {}
local atlasTex

local deathN, deathX, deathY, deathFx = 0, {}, {}, {}

VFX.time  = 0
VFX.stats = { alive = 0, spawned = 0, peak = 0, simMs = 0, buildMs = 0, culled = 0 }

-- Optional cull rect (world space). Particles outside it are simulated but not
-- submitted, which is most of the win on a big map.
local cullOn = false
local cullX0, cullY0, cullX1, cullY1 = 0, 0, 0, 0
function VFX.setViewport(x, y, w, h, pad)
  if not x then cullOn = false return end
  pad = pad or 96
  cullOn = true
  cullX0, cullY0 = x - pad, y - pad
  cullX1, cullY1 = x + w + pad, y + h + pad
end

local function newPart()
  return {
    x = 0, y = 0, vx = 0, vy = 0, age = 0, life = 1, seed = 0,
    sz = 1, rot = 0, spin = 0, sx = 0, sy = 0,
    tr = 1, tg = 1, tb = 1, ta = 1,
    cr = 1, cg = 1, cb = 1, ca = 1,
    e = nil, r0 = 0, r1 = 0, w0 = 0, a0 = 0, span = 0, kind = 0,
  }
end

--------------------------------------------------------------------- init
local inited = false
function VFX.init()
  if inited then return end
  inited = true
  normalise()

  atlasTex = love.graphics.newImage(buildAtlas())
  atlasTex:setFilter("linear", "linear")
  for i, name in ipairs(SHAPES) do
    local cx = (i - 1) % ATLAS_C
    local cy = floor((i - 1) / ATLAS_C)
    quads[i] = love.graphics.newQuad(cx * CELL, cy * CELL, CELL, CELL,
                                     CELL * ATLAS_C, CELL * ATLAS_R)
  end
  VFX.tex, VFX.quads, VFX.quadIndex = atlasTex, quads, QUAD_IX

  for li = 1, #LAYERS do
    batches[li] = {
      love.graphics.newSpriteBatch(atlasTex, 4096, "stream"),
      love.graphics.newSpriteBatch(atlasTex, 4096, "stream"),
    }
    geo[li] = { { n = 0 }, { n = 0 } }
  end
  VFX.setQuality(quality)
end

function VFX.setQuality(q)
  quality = U.clamp(floor(q or 2), 0, 2)
  qmul = QMUL[quality]
end

function VFX.getQuality() return quality end
function VFX.setWind(vx, vy) windX, windY = vx or 0, vy or 0 end
function VFX.getWind() return windX, windY end
function VFX.count() return alive end
function VFX.capacity() return POOL_MAX end

function VFX.clear()
  alive = 0
  deathN = 0
  for li = 1, #LAYERS do
    if batches[li] then
      batches[li][1]:clear(); batches[li][2]:clear()
      geo[li][1].n = 0; geo[li][2].n = 0
    end
  end
end

--------------------------------------------------------------------- spawning
local function rnd(a, b) return a + (b - a) * random() end

--- Spawn from one normalised emitter table. Internal.
local function fire(e, x, y, o)
  if e.detail > quality then return 0 end

  local n = floor(rnd(e.cnt0, e.cnt1 + 0.999) * qmul + 0.5)
  if n < 1 then n = 1 end
  local oCount, oScale, oPower, oAngle, oSpread, oCol, oAlpha, oLife, oArea
  if o then
    oCount, oScale, oPower = o.count, o.scale, o.power
    oAngle, oSpread, oCol  = o.angle, o.spread, o.color
    oAlpha, oLife, oArea   = o.alpha, o.lifeMul, o.area
  end
  if oCount then n = floor(oCount * qmul + 0.5) end
  if oPower then n = floor(n * (0.6 + 0.4 * oPower) + 0.5) end
  if n < 1 then n = 1 end

  local scale  = oScale or 1
  local area   = oArea or scale
  local power  = oPower or 1
  local baseA  = oAngle or e.angle
  local spread = oSpread or e.spread
  local alphaM = (oAlpha or 1) * e.alpha
  local lifeM  = oLife or 1

  local tr, tg, tb = 1, 1, 1
  if oCol then tr, tg, tb = oCol[1], oCol[2], oCol[3] end

  local spawned = 0
  for _ = 1, n do
    if alive >= POOL_MAX then break end
    alive = alive + 1
    local p = parts[alive]
    if not p then p = newPart(); parts[alive] = p end

    local ang = baseA + (random() - 0.5) * spread
    local r = rnd(e.rad0, e.rad1) * area
    local px, py = x, y

    local em = e.emit
    if em == "disc" then
      local a2 = random() * TAU
      local d = sqrt(random()) * r
      px, py = x + cos(a2) * d, y + sin(a2) * d
    elseif em == "ring" then
      -- placement runs right around the ring (or `ringSpread` of it) and the
      -- velocity is radial from wherever the particle landed
      local pa
      if e.ringSpread then pa = baseA + (random() - 0.5) * e.ringSpread
      else pa = random() * TAU end
      px, py = x + cos(pa) * r, y + sin(pa) * r
      ang = pa + (random() - 0.5) * spread
    elseif em == "box" then
      px = x + (random() - 0.5) * e.boxW * area
      py = y + (random() - 0.5) * e.boxH * area
    elseif r > 0 then
      px, py = x + (random() - 0.5) * r, y + (random() - 0.5) * r
    end

    local sp = rnd(e.spd0, e.spd1) * power * scale
    local dirA = ang
    if e.inward then dirA = ang + pi end
    p.vx = cos(dirA) * sp
    p.vy = sin(dirA) * sp
    if o and o.vx then p.vx = p.vx + o.vx end
    if o and o.vy then p.vy = p.vy + o.vy end

    p.x, p.y   = px, py
    p.age      = 0
    p.life     = rnd(e.life0, e.life1) * lifeM
    p.seed     = random()
    p.sz       = rnd(e.sz0, e.sz1) * scale
    p.spin     = rnd(e.spin0, e.spin1)
    p.rot      = e.align and atan2(p.vy, p.vx) or (random() * TAU)
    p.e        = e
    p.kind     = e.kind
    p.tr, p.tg, p.tb, p.ta = tr, tg, tb, alphaM
    p.sx, p.sy = 0, 0

    if e.kind == KIND_RING then
      p.r0 = e.ring0 * scale
      p.r1 = e.ring1 * scale
      p.w0 = e.ringW * scale
      p.x, p.y = x, y
      p.vx, p.vy = 0, 0
    elseif e.kind == KIND_ARC then
      p.r0, p.r1 = e.arcR0 * scale, e.arcR1 * scale
      p.w0 = e.arcW * scale
      p.a0 = baseA
      p.span = e.arcSpan
      p.x, p.y = x, y
      p.vx, p.vy = 0, 0
    end
    spawned = spawned + 1
  end
  VFX.stats.spawned = VFX.stats.spawned + spawned
  return spawned
end

--- Fire a named effect. `opts` is never retained.
function VFX.emit(name, x, y, o)
  local def = DEFS[name]
  if not def then return 0 end
  if o and (o.dx or o.dy) then
    local dx, dy = o.dx or 0, o.dy or 0
    if dx * dx + dy * dy > 1e-9 then o.angle = atan2(dy, dx) end
  end
  local total = 0
  for i = 1, #def do total = total + fire(def[i], x, y, o) end
  return total
end

--- Fire an ad-hoc definition table (single emitter or array of them).
function VFX.spawn(def, x, y, o)
  if not def then return 0 end
  local list = def
  if def.shape or def.colors or def.count then list = { def } end
  if not list[1].kind then
    for i = 1, #list do normEmitter(list[i]) end
  end
  if o and (o.dx or o.dy) then
    local dx, dy = o.dx or 0, o.dy or 0
    if dx * dx + dy * dy > 1e-9 then o.angle = atan2(dy, dx) end
  end
  local total = 0
  for i = 1, #list do total = total + fire(list[i], x, y, o) end
  return total
end

--- Rate-based emission for continuous effects (`def.rate` per second).
--- Fractional counts accumulate on the definition, so many callers of the same
--- effect still add up to the right aggregate rate.
function VFX.stream(name, x, y, dt, o)
  local def = DEFS[name]
  if not def then return 0 end
  local mul = (o and o.rate) or 1
  local total = 0
  for i = 1, #def do
    local e = def[i]
    if e.rate > 0 then
      e._carry = (e._carry or random()) + e.rate * mul * dt * qmul
      local whole = floor(e._carry)
      if whole > 0 then
        e._carry = e._carry - whole
        local saveA, saveB = e.cnt0, e.cnt1
        e.cnt0, e.cnt1 = whole, whole
        local savedQ = qmul
        qmul = 1                      -- quality already applied to the rate
        total = total + fire(e, x, y, o)
        qmul = savedQ
        e.cnt0, e.cnt1 = saveA, saveB
      end
    else
      total = total + fire(e, x, y, o)
    end
  end
  return total
end

--------------------------------------------------------------------- update
local function evalColor(cols, n, t)
  if n == 1 then local a = cols[1] return a[1], a[2], a[3], a[4] end
  local f = t * (n - 1)
  local i = floor(f)
  if i >= n - 1 then local a = cols[n] return a[1], a[2], a[3], a[4] end
  local a, b = cols[i + 1], cols[i + 2]
  local k = f - i
  return a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k,
         a[3] + (b[3] - a[3]) * k, a[4] + (b[4] - a[4]) * k
end

local function buildBatches()
  local now = VFX.time
  local culled = 0
  for li = 1, #LAYERS do
    batches[li][1]:clear(); batches[li][2]:clear()
    geo[li][1].n = 0; geo[li][2].n = 0
  end
  local half = CELL * 0.5
  local invCell = 1 / (CELL * 0.9)
  for i = 1, alive do
    local p = parts[i]
    -- Cull FIRST. Off-screen sprites used to walk a colour ramp, evaluate an
    -- alpha curve and a pulse before being thrown away; on a big island most of
    -- the pool is off-screen most of the time, and none of that work was ever
    -- going to reach a pixel.
    local kind = p.kind
    if cullOn and kind == KIND_SPR
       and (p.x <= cullX0 or p.x >= cullX1 or p.y <= cullY0 or p.y >= cullY1) then
      culled = culled + 1
    else
      local e = p.e
      local t = p.age / p.life
      if t > 1 then t = 1 end
      local cr, cg, cb, ca = evalColor(e.colors, e.nCol, t)
      local a = ca * e.alFn(t) * p.ta
      if e.pulse > 0 then
        local s = sin(now * e.pulseFreq * TAU + p.seed * TAU)
        a = a * (1 - e.pulse + e.pulse * s * s)
      end
      if a > 0.002 then
        p.ca = a
        p.cr, p.cg, p.cb = cr * p.tr, cg * p.tg, cb * p.tb
        if kind == KIND_SPR then
          local sz = p.sz * e.szFn(t)
          if sz > 0.05 then
            local sx = sz * invCell
            local sy = sx
            if e.stretch > 0 then
              local sp = sqrt(p.vx * p.vx + p.vy * p.vy)
              sx = sx * (1 + sp * e.stretch)
            end
            if e.tumble > 0 then
              sy = sy * (0.25 + 0.75 * abs(cos(now * e.tumble + p.seed * TAU)))
            end
            local b = batches[e.li][e.bi]
            b:setColor(p.cr, p.cg, p.cb, a)
            b:add(quads[e.quad], p.x, p.y, p.rot, sx, sy, half, half)
          end
        else
          local g = geo[e.li][e.bi]
          local n = g.n + 1
          g.n = n
          g[n] = p
        end
      else
        culled = culled + 1
      end
    end
  end
  VFX.stats.culled = culled
end

function VFX.update(dt)
  if not inited then VFX.init() end
  if dt > 1 / 20 then dt = 1 / 20 end
  local clock = love.timer and love.timer.getTime
  local t0 = clock and clock() or 0
  VFX.time = VFX.time + dt
  local now = VFX.time
  deathN = 0

  local i, n = 1, alive
  while i <= n do
    local p = parts[i]
    p.age = p.age + dt
    if p.age >= p.life then
      local e = p.e
      if e.onDeath and deathN < 192 then
        if not e.onDeathChance or random() < e.onDeathChance then
          deathN = deathN + 1
          deathX[deathN], deathY[deathN], deathFx[deathN] = p.x, p.y, e.onDeath
        end
      end
      parts[i], parts[n] = parts[n], parts[i]
      n = n - 1
    else
      local e = p.e
      if p.kind == KIND_SPR then
        local vx, vy = p.vx, p.vy
        if e.drag ~= 0 then
          local d = exp(-e.drag * dt)
          vx, vy = vx * d, vy * d
        end
        if e.grav ~= 0 then vy = vy + e.grav * dt end
        if e.wind ~= 0 then
          local k = e.wind * dt
          vx = vx + (windX - vx) * k
          vy = vy + (windY - vy) * k
        end
        if e.swirl ~= 0 then
          local s = p.seed * TAU
          local f = now * e.swirlFreq
          vx = vx + sin(f + s) * e.swirl * dt
          vy = vy + cos(f * 0.83 + s * 1.7) * e.swirl * dt
        end
        p.vx, p.vy = vx, vy
        p.x = p.x + vx * dt
        p.y = p.y + vy * dt
        if e.align then
          if vx * vx + vy * vy > 1e-6 then p.rot = atan2(vy, vx) end
        elseif p.spin ~= 0 then
          p.rot = p.rot + p.spin * dt
        end
      end
      i = i + 1
    end
  end
  alive = n

  for k = 1, deathN do VFX.emit(deathFx[k], deathX[k], deathY[k], nil) end
  deathN = 0

  local st = VFX.stats
  st.alive = alive
  if alive > st.peak then st.peak = alive end
  local t1 = clock and clock() or 0
  buildBatches()
  if clock then
    st.simMs = (t1 - t0) * 1000
    st.buildMs = (clock() - t1) * 1000
  end
end

---------------------------------------------------------------------- draw
-- Three concentric strokes: a wide dim halo, a body, and a thin hot core.
-- A single stroke reads as a wireframe circle; this reads as a shockwave.
local function drawRing(p, t)
  local e = p.e
  local g = love.graphics
  local r = p.r0 + (p.r1 - p.r0) * e.ringFn(t)
  if r < 0.5 then return end
  local w = p.w0 * (1 - t) ^ 0.55
  if w < 0.7 then w = 0.7 end
  local segs = e.ringSegs
  local cr, cg, cb, ca = p.cr, p.cg, p.cb, p.ca
  g.setColor(cr, cg, cb, ca * 0.13)
  g.setLineWidth(w * 2.5)
  g.circle("line", p.x, p.y, r, segs)
  g.setColor(cr, cg, cb, ca * 0.38)
  g.setLineWidth(w * 1.35)
  g.circle("line", p.x, p.y, r, segs)
  local k = 0.2
  g.setColor(cr + (W[1] - cr) * k, cg + (W[2] - cg) * k, cb + (W[3] - cb) * k, ca)
  g.setLineWidth(w * 0.5 < 0.9 and 0.9 or w * 0.5)
  g.circle("line", p.x, p.y, r, segs)
end

local ARC_SEGS = 20
local function drawArc(p, t)
  local e = p.e
  local g = love.graphics
  local rad = p.r0 + (p.r1 - p.r0) * ease.outCubic(t)
  local head = sat(t / e.arcHead)
  local tail = sat((t - e.arcTail) / (1 - e.arcTail))
  local a0 = p.a0 - p.span * 0.5
  local aHead = a0 + p.span * ease.outQuad(head)
  local aTail = a0 + p.span * ease.inQuad(tail)
  local sweep = aHead - aTail
  if sweep <= 1e-3 then return end
  local w = p.w0 * (1 - t * 0.5)
  g.setColor(p.cr, p.cg, p.cb, p.ca)
  for s = 0, ARC_SEGS - 1 do
    local u0, u1 = s / ARC_SEGS, (s + 1) / ARC_SEGS
    local an0, an1 = aTail + sweep * u0, aTail + sweep * u1
    local w0 = w * (0.12 + 0.88 * u0 ^ 1.5) * 0.5
    local w1 = w * (0.12 + 0.88 * u1 ^ 1.5) * 0.5
    local c0, s0 = cos(an0), sin(an0)
    local c1, s1 = cos(an1), sin(an1)
    g.polygon("fill",
      p.x + c0 * (rad - w0), p.y + s0 * (rad - w0),
      p.x + c1 * (rad - w1), p.y + s1 * (rad - w1),
      p.x + c1 * (rad + w1), p.y + s1 * (rad + w1),
      p.x + c0 * (rad + w0), p.y + s0 * (rad + w0))
  end
  -- the bright leading edge
  local eA0 = aHead - sweep * 0.16
  local ew = w * 0.62
  g.setColor(W[1], W[2], W[3], p.ca * 0.9)
  local steps = 5
  for s = 0, steps - 1 do
    local u0, u1 = s / steps, (s + 1) / steps
    local an0 = eA0 + (aHead - eA0) * u0
    local an1 = eA0 + (aHead - eA0) * u1
    local w0 = ew * (0.25 + 0.75 * u0) * 0.5
    local w1 = ew * (0.25 + 0.75 * u1) * 0.5
    local c0, s0 = cos(an0), sin(an0)
    local c1, s1 = cos(an1), sin(an1)
    g.polygon("fill",
      p.x + c0 * (rad - w0), p.y + s0 * (rad - w0),
      p.x + c1 * (rad - w1), p.y + s1 * (rad - w1),
      p.x + c1 * (rad + w1), p.y + s1 * (rad + w1),
      p.x + c0 * (rad + w0), p.y + s0 * (rad + w0))
  end
end

local function drawGeo(li, bi)
  local list = geo[li][bi]
  for i = 1, list.n do
    local p = list[i]
    local t = p.age / p.life
    if t > 1 then t = 1 end
    if p.kind == KIND_RING then drawRing(p, t) else drawArc(p, t) end
  end
end

--- Draw one layer. Leaves blend mode, colour and line width at their defaults.
local SKIP = os.getenv("BOTS_VFX_SKIP")
function VFX.draw(layerName)
  local li = LAYER_IX[layerName or "world"]
  if not li or not inited then return end
  if SKIP and layerName == SKIP then return end
  local g = love.graphics
  local bAlpha, bAdd = batches[li][1], batches[li][2]

  g.setColor(1, 1, 1, 1)
  if bAlpha:getCount() > 0 then
    g.setBlendMode("alpha", "alphamultiply")
    g.draw(bAlpha)
  end
  if geo[li][1].n > 0 then
    g.setBlendMode("alpha", "alphamultiply")
    drawGeo(li, 1)
  end
  if bAdd:getCount() > 0 then
    g.setColor(1, 1, 1, 1)
    g.setBlendMode("add", "alphamultiply")
    g.draw(bAdd)
  end
  if geo[li][2].n > 0 then
    g.setBlendMode("add", "alphamultiply")
    drawGeo(li, 2)
  end

  g.setBlendMode("alpha", "alphamultiply")
  g.setColor(1, 1, 1, 1)
  g.setLineWidth(1)
end

--- Convenience for scenes that do not interleave world geometry.
function VFX.drawAll()
  for i = 1, #LAYERS do VFX.draw(LAYERS[i]) end
end

return VFX
