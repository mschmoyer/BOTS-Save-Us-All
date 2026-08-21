-- Persistent ground marks.
--
--   Static marks (scorch, blight stains, footprints, felling rings) are stamped
--   once into a world-sized canvas and then forgotten: ten thousand of them
--   cost exactly one draw call. The canvas is periodically multiplied down so
--   everything fades over minutes without any per-decal bookkeeping.
--
--   "Live" decals (acid puddles) also matter to gameplay, so those keep a small
--   pooled record that can be queried, and burn a faded stain into the canvas
--   when they expire.
--
--   The canvas holds premultiplied alpha: stamps premultiply on the way in and
--   it is drawn back with the "premultiplied" alpha mode, which keeps overlaps
--   from fringing.
local U   = require("src.core.util")
local P   = require("src.engine.palette")
local VFX = require("src.engine.vfx")

local D = {}

local floor, sqrt, sin, cos, random, min, max =
      math.floor, math.sqrt, math.sin, math.cos, math.random, math.min, math.max
local TAU = U.TAU
local R = P.ramp

--------------------------------------------------------------------- tuning
local CFG = {
  res        = 0.5,     -- canvas pixels per world pixel
  fadeStep   = 0.35,    -- seconds between fade passes
  halfLife   = 105,     -- seconds for a stamp to lose half its alpha
  maxQueue   = 512,     -- stamps buffered between flushes
  maxLive    = 256,     -- concurrent live (queryable) decals
}
D.CFG = CFG

--------------------------------------------------------------------- state
local canvas, quad
local cw, ch = 0, 0
local ox, oy = 0, 0
local worldW, worldH = 0, 0
local fadeAcc = 0
local ready = false

local qn = 0
local qKind, qX, qY, qR, qA, qAl, qSeed = {}, {}, {}, {}, {}, {}, {}

local live, liveN = {}, 0     -- pooled records, 1..liveN are alive
local stamped = 0

--------------------------------------------------------------------- helpers
local function pre(c, a)
  a = a * (c[4] or 1)
  love.graphics.setColor(c[1] * a, c[2] * a, c[3] * a, a)
end

local function blob(shape, x, y, r, rot, sx)
  local q = VFX.quads[VFX.quadIndex[shape]]
  local s = r * 2 / 57         -- the atlas shape spans ~57 of its 64 px cell
  love.graphics.draw(VFX.tex, q, x, y, rot, s * (sx or 1), s, 32, 32)
end

--------------------------------------------------------------------- stamps
-- Each stamp function draws into the bound canvas in world/2 space, with
-- premultiplied blending already set. `a` is the master alpha.
local STAMP = {}

STAMP.scorch = function(x, y, r, ang, a)
  for i = 1, 6 do
    local t = i / 6
    local d = r * 0.42 * random()
    local an = random() * TAU
    pre(P.mix(R.rock[1], R.soil[1], random()), a * (0.30 + 0.28 * (1 - t)))
    blob("smoke", x + cos(an) * d, y + sin(an) * d, r * (0.55 + 0.5 * random()),
         random() * TAU, 0.8 + 0.4 * random())
  end
  pre(R.ember[1], a * 0.30)
  blob("blob", x, y, r * 0.55, random() * TAU)
  pre(P.black, a * 0.42)
  blob("blob", x, y, r * 0.34, random() * TAU)
end

STAMP.blight_stain = function(x, y, r, ang, a)
  -- A bruise, not a sweet. The stain is carried by the two near-neutral stops
  -- of the ramp; the hot stop is a bead at the centre and never a magenta haze
  -- the width of the whole mark, which is what it used to be.
  for i = 1, 5 do
    local an, d = random() * TAU, r * 0.4 * random()
    pre(P.mix(R.blight[1], R.blight[2], random() * 0.8), a * 0.32)
    blob("blob", x + cos(an) * d, y + sin(an) * d, r * (0.5 + 0.55 * random()),
         random() * TAU, 0.75 + 0.5 * random())
  end
  pre(R.blight[2], a * 0.18)
  blob("smoke", x, y, r * 0.8, random() * TAU)
  pre(R.blight[3], a * 0.20)
  blob("blob", x, y, r * 0.16, random() * TAU)
end

STAMP.acid_stain = function(x, y, r, ang, a)
  for i = 1, 4 do
    local an, d = random() * TAU, r * 0.35 * random()
    pre(P.mix(R.moss[1], P.acid, 0.25 + 0.3 * random()), a * 0.26)
    blob("blob", x + cos(an) * d, y + sin(an) * d, r * (0.55 + 0.4 * random()),
         random() * TAU)
  end
end

STAMP.stump = function(x, y, r, ang, a)
  -- What a felled tree leaves: turned earth and a cut trunk. This used to put a
  -- bright sand annulus around it, which over a night forest read as a glowing
  -- ring - forty of them turned a shoreline into a field of pale doughnuts.
  pre(R.soil[1], a * 0.34)
  blob("blob", x, y, r * 0.95, random() * TAU, 0.9)
  pre(R.soil[2], a * 0.22)
  blob("blob", x, y, r * 0.62, random() * TAU, 1.1)
  pre(R.bark[1], a * 0.5)
  blob("blob", x, y, r * 0.4, random() * TAU)
  pre(R.bark[3], a * 0.32)
  blob("disc", x - r * 0.05, y - r * 0.05, r * 0.24, random() * TAU)
end

STAMP.footprint = function(x, y, r, ang, a)
  local px, py = -sin(ang), cos(ang)
  local off = r * 0.55
  pre(R.soil[2], a * 0.4)
  blob("disc", x + px * off, y + py * off, r * 0.5, ang, 1.5)
  pre(R.soil[1], a * 0.28)
  blob("disc", x - px * off * 0.4, y - py * off * 0.4, r * 0.38, ang, 1.4)
end

STAMP.splat = function(x, y, r, ang, a, col)
  col = col or R.blight[2]
  pre(col, a * 0.5)
  blob("blob", x, y, r, random() * TAU, 0.8 + 0.4 * random())
  for i = 1, 5 do
    local an = random() * TAU
    local d = r * (0.9 + random() * 1.1)
    pre(col, a * 0.36)
    blob("blob", x + cos(an) * d, y + sin(an) * d, r * (0.14 + 0.2 * random()), an)
  end
end

STAMP.crater = function(x, y, r, ang, a)
  pre(R.rock[1], a * 0.45)
  blob("blob", x, y, r, random() * TAU)
  pre(R.rock[4], a * 0.22)
  blob("annulus", x, y, r * 1.2, random() * TAU)
  pre(P.black, a * 0.3)
  blob("blob", x, y, r * 0.5, random() * TAU)
end

STAMP.dust = function(x, y, r, ang, a)
  pre(R.sand[2], a * 0.3)
  blob("smoke", x, y, r, random() * TAU)
end

D.KINDS = { "scorch", "blight_stain", "acid_stain", "stump", "footprint",
            "splat", "crater", "dust", "acid" }

-- default radius per kind, in world pixels
local DEF_R = {
  scorch = 26, blight_stain = 30, acid_stain = 26, stump = 22,
  footprint = 7, splat = 14, crater = 40, dust = 34, acid = 34,
}

--------------------------------------------------------------------- init
function D.init(w, h, opts)
  VFX.init()
  worldW = w or 3400
  worldH = h or 2400
  if opts then
    CFG.res = opts.res or CFG.res
    CFG.halfLife = opts.halfLife or CFG.halfLife
    ox, oy = opts.ox or 0, opts.oy or 0
  end
  cw = max(1, floor(worldW * CFG.res))
  ch = max(1, floor(worldH * CFG.res))
  local prev = love.graphics.getCanvas()
  canvas = love.graphics.newCanvas(cw, ch)
  canvas:setFilter("linear", "linear")
  quad = love.graphics.newQuad(0, 0, cw, ch, cw, ch)
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setCanvas(prev)
  qn, liveN, stamped, fadeAcc = 0, 0, 0, 0
  ready = true
end

function D.clear()
  if not ready then return end
  local prev = love.graphics.getCanvas()
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setCanvas(prev)
  qn, liveN, stamped = 0, 0, 0
end

function D.count() return stamped, liveN end

--------------------------------------------------------------------- add
--- opts: r, angle, alpha, life (live kinds), color (splat only)
function D.add(kind, x, y, opts)
  if not ready then return end
  local r     = (opts and opts.r) or DEF_R[kind] or 20
  local ang   = (opts and opts.angle) or 0
  local a     = (opts and opts.alpha) or 1

  if kind == "acid" then
    if liveN >= CFG.maxLive then return end
    liveN = liveN + 1
    local L = live[liveN]
    if not L then L = { x = 0, y = 0, r = 0, age = 0, life = 1, seed = 0 } live[liveN] = L end
    L.x, L.y, L.r = x, y, r
    L.age = 0
    L.life = (opts and opts.life) or 9
    L.seed = random()
    L.alpha = a
    return L
  end

  if not STAMP[kind] then return end
  if qn >= CFG.maxQueue then return end
  qn = qn + 1
  qKind[qn], qX[qn], qY[qn] = kind, x, y
  qR[qn], qA[qn], qAl[qn] = r, ang, a
  qSeed[qn] = (opts and opts.color) or false
end

--------------------------------------------------------------------- update
local function flush()
  if qn == 0 then return end
  local g = love.graphics
  local s = CFG.res
  g.push()
  g.origin()
  g.scale(s, s)
  g.translate(-ox, -oy)
  for i = 1, qn do
    STAMP[qKind[i]](qX[i], qY[i], qR[i], qA[i], qAl[i], qSeed[i] or nil)
  end
  g.pop()
  stamped = stamped + qn
  qn = 0
end

function D.update(dt)
  if not ready then return end

  -- age live decals; expiring ones leave a stain behind
  local i, n = 1, liveN
  while i <= n do
    local L = live[i]
    L.age = L.age + dt
    if L.age >= L.life then
      D.add("acid_stain", L.x, L.y, { r = L.r * 0.9, alpha = 0.85 })
      live[i], live[n] = live[n], live[i]
      n = n - 1
    else
      i = i + 1
    end
  end
  liveN = n

  fadeAcc = fadeAcc + dt
  local needFade = fadeAcc >= CFG.fadeStep
  if qn == 0 and not needFade then return end

  local prev = love.graphics.getCanvas()
  love.graphics.setCanvas(canvas)

  if qn > 0 then
    love.graphics.setBlendMode("alpha", "premultiplied")
    flush()
  end

  if needFade then
    local k = 0.5 ^ (fadeAcc / CFG.halfLife)
    fadeAcc = 0
    love.graphics.setBlendMode("multiply", "premultiplied")
    love.graphics.setColor(k, k, k, k)
    love.graphics.rectangle("fill", 0, 0, cw, ch)
  end

  love.graphics.setBlendMode("alpha", "alphamultiply")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setCanvas(prev)
end

--------------------------------------------------------------------- queries
--- The nearest live acid puddle containing (x, y), or nil. Gameplay uses this.
function D.acidAt(x, y, pad)
  pad = pad or 0
  for i = 1, liveN do
    local L = live[i]
    local rr = L.r + pad
    local dx, dy = x - L.x, y - L.y
    if dx * dx + dy * dy <= rr * rr then return L end
  end
  return nil
end

function D.eachLive(fn)
  for i = 1, liveN do fn(live[i]) end
end

--------------------------------------------------------------------- draw
--- Call with the camera attached; `cam` is used only to trim the blit.
function D.draw(cam)
  if not ready then return end
  local g = love.graphics
  g.setColor(1, 1, 1, 1)
  g.setBlendMode("alpha", "premultiplied")

  local inv = 1 / CFG.res
  if cam and cam.viewRect then
    local vx, vy, vw, vh = cam:viewRect(48)
    -- Snap the blit to whole canvas texels. On a fractional viewport the
    -- half-resolution canvas is resampled off-centre every frame and the whole
    -- decal layer crawls and softens as the camera moves.
    local x0 = floor(U.clamp((vx - ox) * CFG.res, 0, cw))
    local y0 = floor(U.clamp((vy - oy) * CFG.res, 0, ch))
    local x1 = math.ceil(U.clamp((vx + vw - ox) * CFG.res, 0, cw))
    local y1 = math.ceil(U.clamp((vy + vh - oy) * CFG.res, 0, ch))
    if x1 - x0 > 0.5 and y1 - y0 > 0.5 then
      quad:setViewport(x0, y0, x1 - x0, y1 - y0, cw, ch)
      g.draw(canvas, quad, ox + x0 * inv, oy + y0 * inv, 0, inv, inv)
    end
  else
    g.draw(canvas, ox, oy, 0, inv, inv)
  end

  g.setBlendMode("alpha", "alphamultiply")

  -- live puddles: drawn every frame so they can breathe and read as hazards
  local t = VFX.time
  for i = 1, liveN do
    local L = live[i]
    local k = U.saturate(L.age / L.life)
    local fade = k < 0.12 and (k / 0.12) or U.smoothstep(1, 0.55, k)
    local a = fade * (L.alpha or 1)
    local wob = 1 + 0.035 * sin(t * 2.1 + L.seed * TAU)
    local r = L.r * wob

    g.setColor(R.moss[1][1], R.moss[1][2], R.moss[1][3], a * 0.55)
    blob("blob", L.x, L.y, r, L.seed * TAU)
    g.setColor(P.acid[1], P.acid[2], P.acid[3], a * 0.30)
    blob("blob", L.x, L.y, r * 0.82, L.seed * TAU + 1.4)
    g.setBlendMode("add", "alphamultiply")
    g.setColor(P.acid[1], P.acid[2], P.acid[3], a * 0.22)
    blob("annulus", L.x, L.y, r * 1.02, L.seed * TAU)
    -- a couple of slow bubbles so it looks alive
    for b = 1, 3 do
      local ph = t * 0.55 + L.seed * 7 + b * 2.1
      local bt = ph - floor(ph)
      local an = (L.seed * 13 + b * 2.4) * TAU
      local d = r * 0.55 * ((b * 0.31 + L.seed) % 1)
      local br = r * 0.09 * (1 - bt) * fade
      if br > 0.4 then
        g.setColor(P.acid[1], P.acid[2], P.acid[3], a * 0.5 * (1 - bt))
        blob("bubble", L.x + cos(an) * d, L.y + sin(an) * d - bt * r * 0.1, br)
      end
    end
    g.setBlendMode("alpha", "alphamultiply")
  end
  g.setColor(1, 1, 1, 1)
end

return D
