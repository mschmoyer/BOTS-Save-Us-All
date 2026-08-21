-- The shape vocabulary the whole game draws with.
--
-- Everything here is a *pure* drawing helper: it takes numbers and palette
-- colours and puts pixels on whatever canvas is current. No state of its own
-- beyond a lazily-built registry of cached Meshes (built once, on first use)
-- and a handful of scratch tables that are reused so that a per-frame call
-- allocates nothing.
--
-- Colour arguments are palette tables `{r, g, b, a}` (see engine/palette.lua).
-- Never pass a literal.
local U = require("src.core.util")
local P = require("src.engine.palette")

local lg   = love.graphics
local cos, sin, atan2   = math.cos, math.sin, math.atan2
local floor, ceil, abs  = math.floor, math.ceil, math.abs
local min, max, sqrt    = math.min, math.max, math.sqrt
local pi                = math.pi
local TAU               = U.TAU

local Draw = {}

--------------------------------------------------------------- scratch tables
-- Named (rather than pooled) so two helpers can never alias each other.
local SPOLY  = {}   -- polygon / polyline point list
local SPOLY2 = {}   -- second simultaneous point list
local SPTS   = {}   -- love.graphics.points payload
local SVERT  = { {}, {}, {}, {} }  -- 4 reusable mesh vertices

--- Deterministic 0..1 hash. U.hash2 multiplies past 2^53 and loses every
--- low bit, so the drawing layer keeps its own: sine-scramble, stable in
--- doubles, identical on every platform LOVE runs on.
local function hash(a, b, c)
  local n = a * 127.1 + b * 311.7 + (c or 0) * 74.7
  local s = sin(n) * 43758.5453123
  return s - floor(s)
end
Draw.hash = hash

local function trim(t, n)
  for i = #t, n + 1, -1 do t[i] = nil end
  return t
end
Draw.trim = trim

--------------------------------------------------------------------- colour
--- Set the draw colour from a palette table. `alphaMul` scales its alpha.
function Draw.setColor(c, alphaMul)
  if not c then lg.setColor(1, 1, 1, alphaMul or 1) return end
  local a = c[4] or 1
  if alphaMul then a = a * alphaMul end
  lg.setColor(c[1], c[2], c[3], a)
end
local setColor = Draw.setColor

function Draw.reset()
  lg.setColor(1, 1, 1, 1)
  lg.setLineWidth(1)
  lg.setLineJoin("miter")
  lg.setLineStyle("smooth")
  lg.setBlendMode("alpha", "alphamultiply")
end

--------------------------------------------------------------- state sugar
function Draw.push(kind) lg.push(kind or "transform") end
function Draw.pop() lg.pop() end
function Draw.setLineWidth(w) lg.setLineWidth(w) end

--- Run `fn` under a different blend mode, restoring the previous one after.
--- Accepts Draw.withBlend(mode, fn, ...) or Draw.withBlend(mode, alphamode, fn, ...).
function Draw.withBlend(mode, alphamode, fn, ...)
  if type(alphamode) == "function" then
    return Draw.withBlend(mode, "alphamultiply", alphamode, fn, ...)
  end
  local bm, am = lg.getBlendMode()
  lg.setBlendMode(mode, alphamode)
  fn(...)
  lg.setBlendMode(bm, am)
end

--- Additive block: the single most-used blend in this game.
function Draw.additive(fn, ...)
  local bm, am = lg.getBlendMode()
  lg.setBlendMode("add", "alphamultiply")
  fn(...)
  lg.setBlendMode(bm, am)
end

--------------------------------------------------------- cached mesh registry
-- Radial falloff meshes. One unit-radius mesh per falloff curve, built the
-- first time it is asked for and then drawn scaled. This is how every glow,
-- shadow and radial gradient in the game is rendered: one draw call, no
-- per-frame geometry, no banding from concentric alpha circles.
local RAMP_BANDS, RAMP_SEGS = 22, 64

local FALLOFF = {
  -- soft, wide: radial gradients
  smooth = function(t) local k = 1 - t return k * k * (3 - 2 * k) end,
  -- tight core, long tail: light bloom
  glow   = function(t)
    local k = 1 - t
    return k * (0.42 + 0.58 * k)
  end,
  -- plateau then quick falloff: contact shadows
  shadow = function(t)
    local k = U.saturate((t - 0.12) / 0.88)
    local s = 1 - k * k
    return s * s
  end,
  -- flat disc with a hairline feathered rim (anti-aliased fill)
  disc   = function(t) return t < 0.965 and 1 or (1 - (t - 0.965) / 0.035) end,
  linear = function(t) return 1 - t end,
}

local meshes = {}

local function buildRamp(fn)
  local verts = {}
  local n = 0
  local function vert(t, a)
    n = n + 1
    verts[n] = { cos(a) * t, sin(a) * t, 0, 0, 1, 1, 1, fn(t) }
  end
  for b = 0, RAMP_BANDS - 1 do
    local t0 = b / RAMP_BANDS
    local t1 = (b + 1) / RAMP_BANDS
    for s = 0, RAMP_SEGS - 1 do
      local a0 = s / RAMP_SEGS * TAU
      local a1 = (s + 1) / RAMP_SEGS * TAU
      if b == 0 then
        vert(0, 0); vert(t1, a0); vert(t1, a1)
      else
        vert(t0, a0); vert(t1, a0); vert(t1, a1)
        vert(t0, a0); vert(t1, a1); vert(t0, a1)
      end
    end
  end
  return lg.newMesh(verts, "triangles", "static")
end

local function ramp(name)
  local m = meshes[name]
  if not m then
    m = buildRamp(FALLOFF[name] or FALLOFF.smooth)
    meshes[name] = m
  end
  return m
end
Draw.ramp = ramp

-- A 4-vertex quad whose corner positions and colours are rewritten per call.
local function quadMesh()
  local m = meshes.__quad
  if not m then
    m = lg.newMesh({ { 0, 0, 0, 0, 1, 1, 1, 1 }, { 1, 0, 0, 0, 1, 1, 1, 1 },
                     { 1, 1, 0, 0, 1, 1, 1, 1 }, { 0, 1, 0, 0, 1, 1, 1, 1 } },
                   "fan", "stream")
    meshes.__quad = m
  end
  return m
end

-- Star-shaped (concave-but-fan-able) fills go through one reusable Mesh in
-- "fan" mode: exact, one draw call, and immune to however the polygon
-- triangulator feels about a 5-pointed star today.
local FAN_CAP = 192
local fanVerts = nil

local function fanMesh()
  local m = meshes.__fan
  if not m then
    fanVerts = {}
    for i = 1, FAN_CAP do fanVerts[i] = { 0, 0, 0, 0, 1, 1, 1, 1 } end
    m = lg.newMesh(fanVerts, "fan", "stream")
    meshes.__fan = m
  end
  return m
end

--- Fill a closed point list as a fan around (cx, cy). Current colour applies.
function Draw.fillFan(cx, cy, pts, n)
  local m = fanMesh()
  local count = n * 0.5
  if count + 2 > FAN_CAP then count = FAN_CAP - 2 end
  local v = fanVerts[1]
  v[1], v[2] = cx, cy
  for i = 1, count do
    v = fanVerts[i + 1]
    v[1], v[2] = pts[i * 2 - 1], pts[i * 2]
  end
  v = fanVerts[count + 2]
  v[1], v[2] = pts[1], pts[2]
  m:setVertices(fanVerts)
  m:setDrawRange(1, count + 2)
  lg.draw(m)
end

local function setV(i, x, y, c, aMul)
  local v = SVERT[i]
  v[1], v[2], v[3], v[4] = x, y, 0, 0
  v[5], v[6], v[7] = c[1], c[2], c[3]
  v[8] = (c[4] or 1) * (aMul or 1)
end

--- A gouraud-shaded quad. Corner colours may differ; nothing is allocated.
function Draw.quad(x1, y1, x2, y2, x3, y3, x4, y4, c1, c2, c3, c4, aMul)
  c2, c3, c4 = c2 or c1, c3 or c2 or c1, c4 or c3 or c1
  setV(1, x1, y1, c1, aMul); setV(2, x2, y2, c2, aMul)
  setV(3, x3, y3, c3, aMul); setV(4, x4, y4, c4, aMul)
  local m = quadMesh()
  m:setVertices(SVERT)
  lg.setColor(1, 1, 1, 1)
  lg.draw(m)
end

------------------------------------------------------------------- gradients
--- Radial gradient disc. Inner colour at the centre, outer at radius `r`.
function Draw.radialGradient(x, y, r, cInner, cOuter, ry)
  ry = ry or r
  if cOuter then
    setColor(cOuter)
    lg.draw(ramp("disc"), x, y, 0, r, ry)
  end
  setColor(cInner)
  lg.draw(ramp("smooth"), x, y, 0, r, ry)
end

--- Linear gradient over an axis-aligned rect. `angle` is the gradient
--- direction in radians (0 = left to right, pi/2 = top to bottom).
function Draw.linearGradient(x, y, w, h, c1, c2, angle)
  angle = angle or 0
  local dx, dy = cos(angle), sin(angle)
  local x1, y1 = x, y
  local x2, y2 = x + w, y
  local x3, y3 = x + w, y + h
  local x4, y4 = x, y + h
  local p1 = x1 * dx + y1 * dy
  local p2 = x2 * dx + y2 * dy
  local p3 = x3 * dx + y3 * dy
  local p4 = x4 * dx + y4 * dy
  local lo = min(p1, p2, p3, p4)
  local hi = max(p1, p2, p3, p4)
  local span = (hi - lo)
  if span < 1e-6 then span = 1 end
  local function stop(p)
    return P.mix(c1, c2, U.saturate((p - lo) / span))
  end
  -- P.mix allocates, so do it once per corner per call: four small tables.
  -- Corner colours cannot be interpolated any other way and four tables a
  -- frame is inside the noise floor; call sites that draw thousands of
  -- gradients should cache the result to a canvas instead.
  Draw.quad(x1, y1, x2, y2, x3, y3, x4, y4, stop(p1), stop(p2), stop(p3), stop(p4))
end

--------------------------------------------------------------- light & shadow
--- Layered elliptical falloff. Every entity in the game sits on one of these.
function Draw.softShadow(x, y, rx, ry, alpha, color)
  setColor(color or P.black, alpha or 0.34)
  lg.draw(ramp("shadow"), x, y, 0, rx, ry or rx * 0.42)
end

--- Additive radial bloom. `layers` concentric passes tighten the core.
function Draw.glow(x, y, r, color, intensity, layers)
  layers = layers or 3
  intensity = intensity or 0.75
  local bm, am = lg.getBlendMode()
  lg.setBlendMode("add", "alphamultiply")
  local g = ramp("glow")
  for i = 1, layers do
    local k = 1 - (i - 1) / layers * 0.62
    setColor(color, intensity / layers * 0.95)
    lg.draw(g, x, y, 0, r * k, r * k)
  end
  lg.setBlendMode(bm, am)
end

--- Tapered additive beam, wide at (x1,y1) and narrow at (x2,y2).
function Draw.beam(x1, y1, x2, y2, width, color, softness)
  softness = softness or 0.9
  local dx, dy = x2 - x1, y2 - y1
  local l = sqrt(dx * dx + dy * dy)
  if l < 1e-5 then return end
  local nx, ny = -dy / l, dx / l
  local w1 = width * 0.5
  local w2 = width * 0.5 * 0.32
  local s1 = w1 * (1 + softness * 2)
  local s2 = w2 * (1 + softness * 2)
  local fade = P.alpha(color, 0)
  local bm, am = lg.getBlendMode()
  lg.setBlendMode("add", "alphamultiply")
  -- soft flanks
  Draw.quad(x1 + nx * s1, y1 + ny * s1, x1 + nx * w1, y1 + ny * w1,
            x2 + nx * w2, y2 + ny * w2, x2 + nx * s2, y2 + ny * s2,
            fade, color, color, fade)
  Draw.quad(x1 - nx * s1, y1 - ny * s1, x1 - nx * w1, y1 - ny * w1,
            x2 - nx * w2, y2 - ny * w2, x2 - nx * s2, y2 - ny * s2,
            fade, color, color, fade)
  -- hot core
  Draw.quad(x1 + nx * w1, y1 + ny * w1, x1 - nx * w1, y1 - ny * w1,
            x2 - nx * w2, y2 - ny * w2, x2 + nx * w2, y2 + ny * w2,
            color, color, P.alpha(color, (color[4] or 1) * 0.45),
            P.alpha(color, (color[4] or 1) * 0.45))
  lg.setBlendMode(bm, am)
end

--------------------------------------------------------------------- shapes
--- Rounded rectangle. `r` is a number or a per-corner table {tl, tr, br, bl}.
function Draw.roundRect(mode, x, y, w, h, r, segs)
  local tl, tr, br, bl
  if type(r) == "table" then
    tl, tr, br, bl = r[1] or 0, r[2] or 0, r[3] or 0, r[4] or 0
  else
    r = r or 0
    tl, tr, br, bl = r, r, r, r
  end
  local lim = min(abs(w), abs(h)) * 0.5
  tl, tr, br, bl = min(tl, lim), min(tr, lim), min(br, lim), min(bl, lim)
  segs = segs or U.clamp(ceil(max(tl, tr, br, bl) / 2.1), 2, 12)

  local n = 0
  local function corner(cx, cy, rad, a0)
    if rad <= 0.001 then
      n = n + 1; SPOLY[n] = cx
      n = n + 1; SPOLY[n] = cy
      return
    end
    for i = 0, segs do
      local a = a0 + (i / segs) * (pi * 0.5)
      n = n + 1; SPOLY[n] = cx + cos(a) * rad
      n = n + 1; SPOLY[n] = cy + sin(a) * rad
    end
  end
  corner(x + tl,     y + tl,     tl, pi)
  corner(x + w - tr, y + tr,     tr, pi * 1.5)
  corner(x + w - br, y + h - br, br, 0)
  corner(x + bl,     y + h - bl, bl, pi * 0.5)
  trim(SPOLY, n)
  if mode == "line" then
    n = n + 1; SPOLY[n] = SPOLY[1]
    n = n + 1; SPOLY[n] = SPOLY[2]
    lg.line(SPOLY)
    trim(SPOLY, n - 2)
  else
    lg.polygon("fill", SPOLY)
  end
end

--- Stadium/capsule between two points.
function Draw.capsule(mode, x1, y1, x2, y2, r, segs)
  local a = atan2(y2 - y1, x2 - x1)
  segs = segs or U.clamp(ceil(r / 1.6), 5, 24)
  local n = 0
  for i = 0, segs do
    local t = a + pi * 0.5 + (i / segs) * pi
    n = n + 1; SPOLY[n] = x1 + cos(t) * r
    n = n + 1; SPOLY[n] = y1 + sin(t) * r
  end
  for i = 0, segs do
    local t = a - pi * 0.5 + (i / segs) * pi
    n = n + 1; SPOLY[n] = x2 + cos(t) * r
    n = n + 1; SPOLY[n] = y2 + sin(t) * r
  end
  trim(SPOLY, n)
  if mode == "line" then
    n = n + 1; SPOLY[n] = SPOLY[1]
    n = n + 1; SPOLY[n] = SPOLY[2]
    lg.line(SPOLY)
    trim(SPOLY, n - 2)
  else
    lg.polygon("fill", SPOLY)
  end
end

--- Organic closed shape. Deterministic from `seed`: the same seed always
--- produces the same silhouette, which is how a tree canopy or a rock can be
--- generated at spawn and redrawn every frame without storing geometry.
--- Three seeded harmonics keep it smooth *and* periodic, so there is never a
--- seam where the ring closes.
function Draw.blobPoints(out, x, y, r, points, seed, wobble, squash, rot)
  points = points or 18
  wobble = wobble or 0.2
  squash = squash or 1
  rot    = rot or 0
  seed   = seed or 0
  local h1, h2, h3 = hash(seed, 1), hash(seed, 2), hash(seed, 3)
  local h4, h5     = hash(seed, 4), hash(seed, 5)
  local k1 = 2 + floor(h4 * 2)
  local k2 = 4 + floor(h5 * 3)
  local k3 = 7 + floor(h1 * 3)
  local a1 = 1.0
  local a2 = 0.46 + h2 * 0.34
  local a3 = 0.18 + h3 * 0.2
  local nrm = a1 + a2 + a3
  local p1, p2, p3 = h1 * TAU, h2 * TAU, h3 * TAU
  local n = 0
  for i = 0, points - 1 do
    local a = i / points * TAU
    local d = (sin(a * k1 + p1) * a1 + sin(a * k2 + p2) * a2 + sin(a * k3 + p3) * a3) / nrm
    local rr = r * (1 + wobble * d)
    local ca, sa = cos(a + rot), sin(a + rot)
    n = n + 1; out[n] = x + ca * rr
    n = n + 1; out[n] = y + sa * rr * squash
  end
  trim(out, n)
  return out, n
end

function Draw.blob(x, y, r, points, seed, wobble, squash, mode, rot)
  local pts, n = Draw.blobPoints(SPOLY, x, y, r, points, seed, wobble, squash, rot)
  if mode == "line" then
    n = n + 1; pts[n] = pts[1]
    n = n + 1; pts[n] = pts[2]
    lg.line(pts)
    trim(pts, n - 2)
  else
    Draw.fillFan(x, y, pts, n)
  end
end

function Draw.hexagon(x, y, r, rot, mode)
  rot = rot or 0
  local n = 0
  for i = 0, 5 do
    local a = rot + i / 6 * TAU
    n = n + 1; SPOLY[n] = x + cos(a) * r
    n = n + 1; SPOLY[n] = y + sin(a) * r
  end
  trim(SPOLY, n)
  if mode == "line" then
    n = n + 1; SPOLY[n] = SPOLY[1]; n = n + 1; SPOLY[n] = SPOLY[2]
    lg.line(SPOLY); trim(SPOLY, n - 2)
  else
    lg.polygon("fill", SPOLY)
  end
end

function Draw.diamond(x, y, rx, ry, mode)
  ry = ry or rx
  SPOLY[1], SPOLY[2] = x, y - ry
  SPOLY[3], SPOLY[4] = x + rx, y
  SPOLY[5], SPOLY[6] = x, y + ry
  SPOLY[7], SPOLY[8] = x - rx, y
  trim(SPOLY, 8)
  if mode == "line" then
    SPOLY[9], SPOLY[10] = x, y - ry
    lg.line(SPOLY); trim(SPOLY, 8)
  else
    lg.polygon("fill", SPOLY)
  end
end

function Draw.star(x, y, rOuter, rInner, points, rot, mode)
  points = points or 5
  rInner = rInner or rOuter * 0.44
  rot = rot or -pi * 0.5
  local n = 0
  for i = 0, points * 2 - 1 do
    local a = rot + i / (points * 2) * TAU
    local rr = (i % 2 == 0) and rOuter or rInner
    n = n + 1; SPOLY[n] = x + cos(a) * rr
    n = n + 1; SPOLY[n] = y + sin(a) * rr
  end
  trim(SPOLY, n)
  if mode == "line" then
    n = n + 1; SPOLY[n] = SPOLY[1]; n = n + 1; SPOLY[n] = SPOLY[2]
    lg.line(SPOLY); trim(SPOLY, n - 2)
  else
    Draw.fillFan(x, y, SPOLY, n)
  end
end

--- A stroked chevron (a > shape). `angle` points the tip.
function Draw.chevron(x, y, size, angle, thickness, spread)
  angle = angle or 0
  spread = spread or 0.72
  local a1 = angle + pi - spread
  local a2 = angle + pi + spread
  SPOLY[1], SPOLY[2] = x + cos(a1) * size, y + sin(a1) * size
  SPOLY[3], SPOLY[4] = x, y
  SPOLY[5], SPOLY[6] = x + cos(a2) * size, y + sin(a2) * size
  trim(SPOLY, 6)
  if thickness then lg.setLineWidth(thickness) end
  lg.line(SPOLY)
end

--- Line with a solid arrow head at (x2,y2).
function Draw.arrow(x1, y1, x2, y2, width, headLen, headW)
  local dx, dy = x2 - x1, y2 - y1
  local l = sqrt(dx * dx + dy * dy)
  if l < 1e-5 then return end
  local ux, uy = dx / l, dy / l
  headLen = headLen or U.clamp(l * 0.28, 6, 22)
  headW   = headW or headLen * 0.62
  local bx, by = x2 - ux * headLen, y2 - uy * headLen
  lg.setLineWidth(width or 2)
  SPOLY[1], SPOLY[2], SPOLY[3], SPOLY[4] = x1, y1, bx, by
  trim(SPOLY, 4)
  lg.line(SPOLY)
  local nx, ny = -uy, ux
  SPOLY[1], SPOLY[2] = x2, y2
  SPOLY[3], SPOLY[4] = bx + nx * headW, by + ny * headW
  SPOLY[5], SPOLY[6] = bx - nx * headW, by - ny * headW
  trim(SPOLY, 6)
  lg.polygon("fill", SPOLY)
end

------------------------------------------------------------------ arcs & rings
--- Arc segment with optional feathered edge. Cooldown dials, progress rings.
function Draw.ring(x, y, radius, thickness, a0, a1, color, feather)
  local sweep = abs(a1 - a0)
  local segs = U.clamp(ceil(sweep * radius / 4), 6, 160)
  if feather and feather > 0 then
    for i = 3, 1, -1 do
      setColor(color, 0.13 * (4 - i) / 3)
      lg.setLineWidth(thickness + feather * 2 * i / 3)
      lg.arc("line", "open", x, y, radius, a0, a1, segs)
    end
  end
  setColor(color)
  lg.setLineWidth(thickness)
  lg.arc("line", "open", x, y, radius, a0, a1, segs)
end

function Draw.dashedCircle(x, y, r, dash, gap, offset, width, color)
  dash = dash or 10; gap = gap or 8; offset = offset or 0
  if color then setColor(color) end
  lg.setLineWidth(width or 2)
  local circ = TAU * r
  local step = dash + gap
  local count = max(1, floor(circ / step + 0.5))
  step = circ / count
  local dashA = (dash / step) * (TAU / count)
  local base = offset / r
  for i = 0, count - 1 do
    local a0 = base + i / count * TAU
    lg.arc("line", "open", x, y, r, a0, a0 + dashA, max(2, ceil(dashA * r / 4)))
  end
end

function Draw.dashedLine(x1, y1, x2, y2, dash, gap, offset, width, color)
  dash = dash or 10; gap = gap or 7; offset = offset or 0
  if color then setColor(color) end
  lg.setLineWidth(width or 2)
  local dx, dy = x2 - x1, y2 - y1
  local l = sqrt(dx * dx + dy * dy)
  if l < 1e-5 then return end
  local ux, uy = dx / l, dy / l
  local t = -(offset % (dash + gap))
  while t < l do
    local s = max(t, 0)
    local e = min(t + dash, l)
    if e > s then
      SPOLY[1], SPOLY[2] = x1 + ux * s, y1 + uy * s
      SPOLY[3], SPOLY[4] = x1 + ux * e, y1 + uy * e
      trim(SPOLY, 4)
      lg.line(SPOLY)
    end
    t = t + dash + gap
  end
end

--- Polyline with round caps and round joins (LOVE has no round line join).
function Draw.polylineRound(points, width, color)
  local n = #points
  if n < 4 then return end
  if color then setColor(color) end
  lg.setLineWidth(width)
  local join = lg.getLineJoin()
  lg.setLineJoin("bevel")
  lg.line(points)
  lg.setLineJoin(join)
  local r = width * 0.5
  if r > 0.9 then
    local segs = U.clamp(ceil(r), 6, 24)
    for i = 1, n, 2 do
      lg.circle("fill", points[i], points[i + 1], r, segs)
    end
  end
end

------------------------------------------------------------------ texture
--- Horizontal scanlines inside a rect. Cheap CRT/holo texture, no assets.
function Draw.scanlineRect(x, y, w, h, spacing, color, alpha, offset, thickness)
  spacing = spacing or 4
  thickness = thickness or 1
  offset = (offset or 0) % spacing
  setColor(color or P.ink, alpha or 0.12)
  local yy = y + offset
  while yy < y + h do
    lg.rectangle("fill", x, yy, w, min(thickness, y + h - yy))
    yy = yy + spacing
  end
end

--- Deterministic speckle. Same seed, same grain, every frame.
function Draw.noiseSpeckle(x, y, w, h, seed, density, color, alpha, size)
  density = density or 0.0025
  seed = seed or 0
  local count = U.clamp(floor(w * h * density), 1, 4000)
  local n = 0
  for i = 1, count do
    local u = hash(seed, i, 11)
    local v = hash(seed, i, 29)
    n = n + 1; SPTS[n] = x + u * w
    n = n + 1; SPTS[n] = y + v * h
  end
  trim(SPTS, n)
  setColor(color or P.ink, alpha or 0.3)
  lg.setPointSize(size or 1)
  lg.points(SPTS)
end

--- Parallel hatching clipped to a rect. `angle` 0 = horizontal.
function Draw.crossHatch(x, y, w, h, spacing, angle, width, color, alpha, cross)
  spacing = spacing or 8
  angle = angle or -pi * 0.25
  local sx, sy, sw, sh = lg.getScissor()
  lg.setScissor(floor(x), floor(y), ceil(w), ceil(h))
  setColor(color or P.ink, alpha or 0.16)
  lg.setLineWidth(width or 1)
  local cx, cy = x + w * 0.5, y + h * 0.5
  local reach = (abs(w) + abs(h))
  local passes = cross and 2 or 1
  for p = 1, passes do
    local a = angle + (p - 1) * pi * 0.5
    local ux, uy = cos(a), sin(a)
    local nx, ny = -uy, ux
    local k = ceil(reach / spacing * 0.5)
    for i = -k, k do
      local ox, oy = nx * i * spacing, ny * i * spacing
      SPOLY[1] = cx + ox - ux * reach
      SPOLY[2] = cy + oy - uy * reach
      SPOLY[3] = cx + ox + ux * reach
      SPOLY[4] = cy + oy + uy * reach
      trim(SPOLY, 4)
      lg.line(SPOLY)
    end
  end
  lg.setScissor(sx, sy, sw, sh)
end

--- Jittered dot stipple: shading for flat areas without a texture.
function Draw.stipple(x, y, w, h, spacing, seed, color, alpha, size)
  spacing = spacing or 6
  seed = seed or 0
  local cols = max(1, ceil(w / spacing))
  local rows = max(1, ceil(h / spacing))
  local n = 0
  for j = 0, rows - 1 do
    for i = 0, cols - 1 do
      local jx = hash(i, j, seed + 3) - 0.5
      local jy = hash(i, j, seed + 91) - 0.5
      n = n + 1; SPTS[n] = x + (i + 0.5 + jx * 0.8) * spacing
      n = n + 1; SPTS[n] = y + (j + 0.5 + jy * 0.8) * spacing
    end
  end
  trim(SPTS, n)
  setColor(color or P.ink, alpha or 0.2)
  lg.setPointSize(size or 1)
  lg.points(SPTS)
end

return Draw
