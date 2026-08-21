-- 2D light accumulation.
--
-- Lights are accumulated additively into a (usually half-resolution) canvas and
-- then composited over the scene in two passes:
--
--     scene *= (ambient + light)      -- the darkness / multiply pass
--     scene += light * lightGain      -- the glow / additive pass
--
-- which is what makes a night frame read as *night* (blue crushed shadows) with
-- *warm pools* around every lamp, rather than a uniformly dimmed day frame.
--
--   Lighting.init(w, h)
--   Lighting.beginFrame(camera)
--   Lighting.setAmbient(color, strength)
--   Lighting.addLight(x, y, radius, color, intensity, opts)
--   Lighting.finish()
--
-- Point lights are a single cached falloff texture drawn additively, so LÖVE
-- batches all of them into one draw call: hundreds are free. Cone lights use
-- cached fan meshes, quantised by half-angle. Nothing here allocates per frame.
local U = require("src.core.util")
local P = require("src.engine.palette")

local L = {}

------------------------------------------------------------------------ state
local MAXLIGHTS = 256
local TEXSIZE   = 128

-- parallel arrays: no per-light tables, no garbage
local lx, ly, lr = {}, {}, {}
local cr, cg, cb, li = {}, {}, {}, {}
local lsoft, lang, lcone, lflick = {}, {}, {}, {}
local count = 0

local canvas, cw, ch = nil, 0, 0
local scrW, scrH = 0, 0
local scale = 0.5
local quality = 1

local falloff = {}          -- [1..3] soft / normal / tight
local coneMesh = {}         -- [quantised half-angle bucket] -> Mesh
local shader

local ambR, ambG, ambB, ambS = 1, 1, 1, 1
local ambSend = { 0, 0, 0 }
local lightGain = 0.35

local camX, camY, camZoom = 0, 0, 1

L.sunAngle  = math.pi * 0.5
L.sunLength = 0.5
L.enabled   = true

-- quality presets: canvas scale, cone rings, cone segments
local Q = {
  [0] = { scale = 0.34, rings = 4,  segs = 12 },
  [1] = { scale = 0.50, rings = 6,  segs = 20 },
  [2] = { scale = 1.00, rings = 10, segs = 32 },
}

--------------------------------------------------------------------- shaders
local COMPOSITE_SRC = [[
// Multiply pass: turns the accumulated light buffer into the factor the scene
// is multiplied by. Ambient sets the floor (the colour of unlit ground), the
// light buffer lifts it back toward and past white inside a light pool.
extern vec3 ambient;
vec4 effect(vec4 vc, Image tex, vec2 tc, vec2 sc) {
  vec3 l = Texel(tex, tc).rgb;
  return vec4(ambient + l, 1.0);
}
]]

--------------------------------------------------------------- falloff textures
-- Normalised inverse-square: a hot core with a long tail that reaches exactly
-- zero at the rim, so lights never show a hard edge.
local function makeFalloff(k)
  local data = love.image.newImageData(TEXSIZE, TEXSIZE)
  local half = TEXSIZE * 0.5
  local edge = 1 / (1 + k)
  local norm = 1 / (1 - edge)
  data:mapPixel(function(x, y)
    local dx = (x + 0.5 - half) / half
    local dy = (y + 0.5 - half) / half
    local d = math.sqrt(dx * dx + dy * dy)
    if d >= 1 then return 1, 1, 1, 0 end
    local a = (1 / (1 + k * d * d) - edge) * norm
    -- fade the last 12% to kill the texture-edge seam entirely
    a = a * U.smoothstep(1.0, 0.88, d)
    return 1, 1, 1, U.saturate(a)
  end)
  local img = love.graphics.newImage(data)
  img:setFilter("linear", "linear")
  img:setWrap("clampzero", "clampzero")
  return img
end

--- Fan mesh for a cone light, unit radius, pointing along +x, half-angle `half`.
local function makeCone(half, rings, segs)
  local verts = {}
  local n = 0
  local k = 14
  local edge = 1 / (1 + k)
  local norm = 1 / (1 - edge)
  local function falloffAt(d)
    if d >= 1 then return 0 end
    return U.saturate((1 / (1 + k * d * d) - edge) * norm * U.smoothstep(1.0, 0.9, d))
  end
  local function push(r, a)
    -- soft angular shoulder so the cone edge is a gradient, not a blade
    local t = math.abs(a) / half
    local ang = 1 - U.smoothstep(0.55, 1.0, t)
    local v = falloffAt(r) * ang
    n = n + 1
    verts[n] = { math.cos(a) * r, math.sin(a) * r, 0, 0, 1, 1, 1, v }
  end
  for i = 0, rings - 1 do
    local r0 = i / rings
    local r1 = (i + 1) / rings
    for j = 0, segs - 1 do
      local a0 = -half + (j / segs) * half * 2
      local a1 = -half + ((j + 1) / segs) * half * 2
      push(r0, a0); push(r1, a0); push(r1, a1)
      push(r0, a0); push(r1, a1); push(r0, a1)
    end
  end
  local m = love.graphics.newMesh(verts, "triangles", "static")
  m:setTexture(nil)
  return m
end

local function coneFor(half)
  -- quantise to 6-degree buckets so a sweeping sentry reuses one mesh
  local bucket = math.max(1, math.min(30, U.round(math.deg(half) / 6)))
  local m = coneMesh[bucket]
  if not m then
    local q = Q[quality] or Q[1]
    m = makeCone(math.rad(bucket * 6), q.rings, q.segs)
    coneMesh[bucket] = m
  end
  return m
end

----------------------------------------------------------------------- canvas
local function allocate(w, h)
  scrW, scrH = math.max(1, math.floor(w)), math.max(1, math.floor(h))
  cw = math.max(1, math.floor(scrW * scale))
  ch = math.max(1, math.floor(scrH * scale))
  if canvas then canvas:release() end
  local fmts = love.graphics.getCanvasFormats()
  local fmt = (fmts and fmts.rgba16f) and "rgba16f" or "rgba8"
  canvas = love.graphics.newCanvas(cw, ch, { format = fmt })
  canvas:setFilter("linear", "linear")
  L.format = fmt
end

function L.init(w, h)
  w = w or love.graphics.getWidth()
  h = h or love.graphics.getHeight()
  if not shader then shader = love.graphics.newShader(COMPOSITE_SRC) end
  if not falloff[1] then
    falloff[1] = makeFalloff(5)    -- soft: a wide, gentle wash
    falloff[2] = makeFalloff(14)   -- normal
    falloff[3] = makeFalloff(44)   -- tight: a hot little bulb
  end
  allocate(w, h)
  return L
end

function L.resize(w, h) allocate(w, h) end

--- 0 = weak device (third-res), 1 = default (half-res), 2 = full-res.
function L.setQuality(q)
  q = math.max(0, math.min(2, math.floor(q or 1)))
  if q == quality and canvas then return end
  quality = q
  scale = Q[q].scale
  for k in pairs(coneMesh) do coneMesh[k]:release() coneMesh[k] = nil end
  if scrW > 0 then allocate(scrW, scrH) end
end

function L.getQuality() return quality end

--------------------------------------------------------------------- the list
--- Start a frame. `camera` supplies the world->screen transform used at
--- composite time; pass nil for a screen-space scene.
function L.beginFrame(camera)
  count = 0
  if camera then
    camX, camY, camZoom = camera.x, camera.y, camera.zoom or 1
    if camera.w and camera.w > 0 then
      if camera.w ~= scrW or camera.h ~= scrH then allocate(camera.w, camera.h) end
    end
  else
    camX, camY, camZoom = scrW * 0.5, scrH * 0.5, 1
  end
end

function L.setAmbient(color, strength)
  ambR, ambG, ambB = color[1], color[2], color[3]
  ambS = strength or 1
end

--- How hot light pools read *over* the scene (the additive pass). The day/night
--- clock drives this: at noon light barely registers, at midnight it blooms.
function L.setLightGain(g) lightGain = g or 0.35 end

--- Stored for whoever draws contact shadows; lighting itself does not cast them.
function L.addSunShadowParams(angle, length)
  L.sunAngle, L.sunLength = angle, length
end

--- Shadow offset for an object `height` units tall.
function L.shadowOffset(height)
  local l = (height or 16) * L.sunLength
  return math.cos(L.sunAngle) * l, math.sin(L.sunAngle) * l * 0.62
end

--- Add a light in **world** space.
--- opts: { flicker = 0..1, angle = rad, cone = rad half-angle, softness = 0..1 }
function L.addLight(x, y, radius, color, intensity, opts)
  if not L.enabled or count >= MAXLIGHTS or radius <= 0 then return end
  -- cull: anything whose disc cannot touch the view is free to skip
  local sx = (x - camX) * camZoom + scrW * 0.5
  local sy = (y - camY) * camZoom + scrH * 0.5
  local sr = radius * camZoom
  if sx + sr < 0 or sy + sr < 0 or sx - sr > scrW or sy - sr > scrH then return end

  local i = count + 1
  count = i
  lx[i], ly[i], lr[i] = sx, sy, sr
  cr[i], cg[i], cb[i] = color[1], color[2], color[3]
  li[i] = intensity or 1
  if opts then
    local s = opts.softness
    lsoft[i] = s and (s < 0.34 and 3 or (s < 0.67 and 2 or 1)) or 2
    lang[i]  = opts.angle
    lcone[i] = opts.cone
    lflick[i] = opts.flicker
  else
    lsoft[i], lang[i], lcone[i], lflick[i] = 2, nil, nil, nil
  end
end

--- Cone light without an options table (no allocation at the call site).
function L.addCone(x, y, radius, color, intensity, angle, half, flicker, softness)
  L.addLight(x, y, radius, color, intensity)
  if count > 0 and lx[count] then
    local i = count
    lang[i], lcone[i], lflick[i] = angle, half, flicker
    if softness then lsoft[i] = softness < 0.34 and 3 or (softness < 0.67 and 2 or 1) end
  end
end

function L.lightCount() return count end
function L.getCanvas() return canvas end

------------------------------------------------------------------- the frame
local function flickerOf(i)
  local f = lflick[i]
  if not f or f <= 0 then return 1 end
  local t = love.timer.getTime()
  local seed = (lx[i] * 0.113 + ly[i] * 0.071)
  -- two octaves: a slow breathe plus a fast stutter
  local n = U.valueNoise(t * 5.7 + seed, seed * 0.37, 3) * 0.65
          + U.valueNoise(t * 17.3 + seed, seed * 1.91, 5) * 0.35
  return 1 - f * (1 - n) * 1.15
end

--- Accumulate every light into the buffer, then composite over whatever canvas
--- was bound when we were called. Leaves the graphics state exactly as found.
function L.finish()
  if not canvas then return end
  local g = love.graphics
  local prevCanvas = g.getCanvas()
  local prevShader = g.getShader()
  local pbm, pam = g.getBlendMode()
  local pr, pg, pb, pa = g.getColor()

  -- ---- accumulate -----------------------------------------------------------
  g.push()
  g.origin()
  g.setCanvas(canvas)
  g.clear(0, 0, 0, 0)
  g.setShader()
  g.setBlendMode("add", "alphamultiply")
  g.scale(scale)

  local tex = falloff[2]
  local inv = 1 / TEXSIZE
  -- points first, bucketed by falloff texture so LÖVE batches each bucket
  for bucket = 1, 3 do
    tex = falloff[bucket]
    local drew = false
    for i = 1, count do
      if lsoft[i] == bucket and not lcone[i] then
        local k = li[i] * flickerOf(i)
        if k > 0.004 then
          g.setColor(cr[i] * k, cg[i] * k, cb[i] * k, 1)
          local s = lr[i] * 2 * inv
          g.draw(tex, lx[i], ly[i], 0, s, s, TEXSIZE * 0.5, TEXSIZE * 0.5)
          drew = true
        end
      end
    end
    if drew then tex = falloff[bucket] end
  end
  -- cones
  for i = 1, count do
    if lcone[i] then
      local k = li[i] * flickerOf(i)
      if k > 0.004 then
        g.setColor(cr[i] * k, cg[i] * k, cb[i] * k, 1)
        g.draw(coneFor(lcone[i]), lx[i], ly[i], lang[i] or 0, lr[i], lr[i])
      end
    end
  end

  -- ---- composite ------------------------------------------------------------
  g.origin()
  g.setCanvas(prevCanvas)
  local up = 1 / scale

  ambSend[1], ambSend[2], ambSend[3] = ambR * ambS, ambG * ambS, ambB * ambS
  g.setShader(shader)
  shader:send("ambient", ambSend)
  g.setBlendMode("multiply", "premultiplied")
  g.setColor(1, 1, 1, 1)
  g.draw(canvas, 0, 0, 0, up, up)

  g.setShader()
  if lightGain > 0.001 then
    g.setBlendMode("add", "premultiplied")
    g.setColor(lightGain, lightGain, lightGain, 1)
    g.draw(canvas, 0, 0, 0, up, up)
  end

  g.pop()
  g.setShader(prevShader)
  g.setBlendMode(pbm, pam)
  g.setColor(pr, pg, pb, pa)
end

--- Debug: draw the raw light buffer.
function L.debugDraw(x, y, s)
  local g = love.graphics
  local pbm, pam = g.getBlendMode()
  g.setBlendMode("alpha", "premultiplied")
  g.setColor(1, 1, 1, 1)
  g.draw(canvas, x or 0, y or 0, 0, s or 0.25, s or 0.25)
  g.setBlendMode(pbm, pam)
end

return L
