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
-- batches all of them into one draw call: hundreds are free. Cone lights are
-- one analytic shader quad each. Nothing here allocates per frame.
local U = require("src.core.util")

local L = {}

------------------------------------------------------------------------ state
local MAXLIGHTS = 256
local TEXSIZE   = 128

-- parallel arrays: no per-light tables, no garbage
local lx, ly, lr = {}, {}, {}
local cr, cg, cb, li = {}, {}, {}, {}
local lsoft, lang, lcone, lflick = {}, {}, {}, {}
local lk = {}                       -- resolved intensity, filled in L.finish
local b1, b2, b3 = {}, {}, {}       -- per-falloff-bucket index lists, reused
local BK = { b1, b2, b3 }           -- hoisted: nothing in here allocates per frame
local BN = { 0, 0, 0 }
local count = 0

local canvas, cw, ch = nil, 0, 0
local scrW, scrH = 0, 0
local scale = 0.5
local quality = 1

local falloff = {}          -- [1..3] soft / normal / tight
local quad                  -- unit quad used by the cone shader
local shader, coneShader

local ambR, ambG, ambB, ambS = 1, 1, 1, 1
local ambSend = { 0, 0, 0 }
local zeroSend = { 0, 0, 0 }
local lightGain = 0.12
local lightScale = 0.3
local scaleOverride = nil

-- How hard the light sum is rolled off before it multiplies the scene.
L.compress = 0.42

local camX, camY, camZoom = 0, 0, 1

L.sunAngle  = math.pi * 0.5
L.sunLength = 0.5
L.enabled   = true

-- quality presets: light-buffer resolution scale
local Q = {
  [0] = { scale = 0.34 },
  [1] = { scale = 0.50 },
  [2] = { scale = 1.00 },
}

--- The browser never gets a 1:1 light buffer, whatever the quality preset says.
---
--- Settings default to "high", which is scale 1.00, and the boot-time
--- auto-downgrade only fires at 2.2 megapixels -- a 1280x720 browser window is
--- 0.92, so it never fired and the ship target has been running a full-
--- resolution light pass this whole time. Measured on a software rasteriser
--- the pass costs 47.1 ms at 1:1 against 28.9 ms at half, which is nothing on
--- a desktop GPU and is the difference between playable and not on a phone.
--- The CPU cost is identical either way: three draw calls, a quarter of a
--- millisecond.
---
--- Capped here rather than by changing the default preset, because the preset
--- also governs particle density and post-processing, and there is no reason
--- to take those away from a machine that can afford them.
local WEB_MAX_SCALE = 0.5
local function scaleFor(q)
  local sc = Q[q].scale
  local web = (_G.BOTS_CFG and _G.BOTS_CFG("BOTS_WEB"))
           or (love.system and love.system.getOS() == "Web")
  if web and sc > WEB_MAX_SCALE then sc = WEB_MAX_SCALE end
  return sc
end

--------------------------------------------------------------------- shaders
local COMPOSITE_SRC = [[
// Turns the accumulated light buffer into the factor the scene is multiplied
// by (ambient sets the colour of unlit ground; light lifts it back toward and
// past white inside a pool), and, with `ambient` zeroed, into the additive
// glow pass.
//
// The reciprocal compression is what keeps a pile of overlapping lights
// *coloured* instead of a white hole: it rolls the sum off toward 1/compress
// while leaving hue untouched.
extern vec3  ambient;
extern float lightScale;
extern float compress;
extern float outAlpha;
vec4 effect(vec4 vc, Image tex, vec2 tc, vec2 sc) {
  vec3 l = Texel(tex, tc).rgb;
  l = l / (1.0 + l * compress);
  return vec4(ambient + l * lightScale, outAlpha);
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

--- Cone lights are drawn analytically: one quad, one shader, exact soft edges
--- at any angle. Cheap, because there are only ever a handful of them.
local CONE_SRC = [[
extern float halfAngle;
extern float kFall;
extern float edge;
extern float norm;
vec4 effect(vec4 vc, Image tex, vec2 tc, vec2 sc) {
  vec2 p = (tc - 0.5) * 2.0;          // -1..1, +x is the beam direction
  float d = length(p);
  if (d >= 1.0) { return vec4(0.0, 0.0, 0.0, 0.0); }
  float a = abs(atan(p.y, p.x));
  // soft angular shoulder, and an isotropic bulb near the source: a real lamp
  // spills before it beams
  float ang = 1.0 - smoothstep(0.40, 1.0, a / halfAngle);
  ang = mix(1.0, ang, smoothstep(0.0, 0.17, d));
  float fall = clamp((1.0 / (1.0 + kFall * d * d) - edge) * norm, 0.0, 1.0);
  fall *= smoothstep(1.0, 0.86, d);
  return vec4(vc.rgb * (fall * ang), 0.0);
}
]]

local CONE_K = 3.4

----------------------------------------------------------------------- canvas
local function allocate(w, h)
  scrW, scrH = math.max(1, math.floor(w)), math.max(1, math.floor(h))
  cw = math.max(1, math.floor(scrW * scale))
  ch = math.max(1, math.floor(scrH * scale))
  if canvas then canvas:release() end
  -- Same rule as postfx: never name a format without checking the driver has
  -- it. rgba8 does not exist under love.js, and asking for it raises an error
  -- that escapes pcall there.
  local fmts = love.graphics.getCanvasFormats()
  local fmt = "normal"
  if fmts then
    if fmts.rgba16f then fmt = "rgba16f" elseif fmts.rgba8 then fmt = "rgba8" end
  end
  canvas = love.graphics.newCanvas(cw, ch, { format = fmt })
  canvas:setFilter("linear", "linear")
  L.format = fmt
end

function L.init(w, h)
  w = w or love.graphics.getWidth()
  h = h or love.graphics.getHeight()
  if not shader then
    shader = love.graphics.newShader(COMPOSITE_SRC)
    coneShader = love.graphics.newShader(CONE_SRC)
    coneShader:send("kFall", CONE_K)
    coneShader:send("edge", 1 / (1 + CONE_K))
    coneShader:send("norm", 1 / (1 - 1 / (1 + CONE_K)))
  end
  if not quad then
    quad = love.graphics.newMesh({ { -1, -1, 0, 0 }, { 1, -1, 1, 0 },
                                   { 1, 1, 1, 1 }, { -1, 1, 0, 1 } }, "fan", "static")
  end
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
  scale = scaleFor(q)
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
  -- A torch does nothing at noon. Lights only fill in what the ambient has not
  -- already lit, which is what stops a day frame from blowing out.
  local k = (1 - U.saturate(ambS)) ^ 0.9
  lightScale = scaleOverride or U.clamp(k * 1.05 + 0.10, 0.10, 1.2)
end

--- Force the multiply-pass light weight (nil returns to the ambient-derived value).
function L.setLightScale(s) scaleOverride = s L.setAmbient({ ambR, ambG, ambB }, ambS) end

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

--- Add a light in **world** space. Returns its index, or nil if it was culled.
--- opts: { flicker = 0..1, angle = rad, cone = rad half-angle, softness = 0..1 }
function L.addLight(x, y, radius, color, intensity, opts)
  if not L.enabled or count >= MAXLIGHTS or radius <= 0 then return nil end
  -- cull: anything whose disc cannot touch the view is free to skip
  local sx = (x - camX) * camZoom + scrW * 0.5
  local sy = (y - camY) * camZoom + scrH * 0.5
  local sr = radius * camZoom
  if sx + sr < 0 or sy + sr < 0 or sx - sr > scrW or sy - sr > scrH then return nil end

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
  return i
end

--- Cone light without an options table (no allocation at the call site).
function L.addCone(x, y, radius, color, intensity, angle, half, flicker, softness)
  local i = L.addLight(x, y, radius, color, intensity)
  if not i then return nil end
  lang[i], lcone[i], lflick[i] = angle, half, flicker
  if softness then lsoft[i] = softness < 0.34 and 3 or (softness < 0.67 and 2 or 1) end
  return i
end

function L.lightCount() return count end
function L.getCanvas() return canvas end

------------------------------------------------------------------- the frame
-- `now` is stamped once per frame in L.finish: love.timer.getTime() is a
-- syscall-ish C call, and calling it once per light per frame is a hundred of
-- them for a value that must not change inside a frame anyway.
local flickNow = 0
local function flickerOf(i)
  local f = lflick[i]
  if not f or f <= 0 then return 1 end
  local t = flickNow
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
  flickNow = love.timer.getTime()
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

  local inv = 1 / TEXSIZE
  -- Points first, bucketed by falloff texture so LOVE batches each bucket into
  -- a single draw call. The buckets are gathered in one pass rather than by
  -- rescanning the whole list three times, and each light's flicker is
  -- evaluated once instead of once per bucket sweep.
  local bn1, bn2, bn3 = 0, 0, 0
  for i = 1, count do
    if not lcone[i] and lr[i] > 0.5 then
      local k = li[i] * flickerOf(i)
      if k > 0.004 then
        lk[i] = k
        local b = lsoft[i]
        if b == 1 then bn1 = bn1 + 1 b1[bn1] = i
        elseif b == 2 then bn2 = bn2 + 1 b2[bn2] = i
        else bn3 = bn3 + 1 b3[bn3] = i end
      end
    end
  end
  BN[1], BN[2], BN[3] = bn1, bn2, bn3
  for bucket = 1, 3 do
    local tex = falloff[bucket]
    local list, n = BK[bucket], BN[bucket]
    for j = 1, n do
      local i = list[j]
      local k = lk[i]
      g.setColor(cr[i] * k, cg[i] * k, cb[i] * k, 1)
      local s = lr[i] * 2 * inv
      g.draw(tex, lx[i], ly[i], 0, s, s, TEXSIZE * 0.5, TEXSIZE * 0.5)
    end
  end
  -- cones: analytic, so the edge stays soft at any half-angle
  local coneOn = false
  for i = 1, count do
    if lcone[i] then
      local k = li[i] * flickerOf(i)
      if k > 0.004 then
        if not coneOn then
          g.setShader(coneShader)
          g.setBlendMode("add", "premultiplied")
          coneOn = true
        end
        coneShader:send("halfAngle", math.max(lcone[i], 0.02))
        g.setColor(cr[i] * k, cg[i] * k, cb[i] * k, 1)
        g.draw(quad, lx[i], ly[i], lang[i] or 0, lr[i], lr[i])
      end
    end
  end
  if coneOn then g.setShader() end

  -- ---- composite ------------------------------------------------------------
  -- The accumulation pass owns its own transform; the composite runs under the
  -- caller's, because postfx scales window coordinates into a scene canvas that
  -- is smaller than the window. Resetting to origin here drew the light sheet
  -- at window size into that smaller canvas.
  g.pop()
  g.setCanvas(prevCanvas)
  local up = 1 / scale

  ambSend[1], ambSend[2], ambSend[3] = ambR * ambS, ambG * ambS, ambB * ambS
  g.setShader(shader)
  shader:send("ambient", ambSend)
  shader:send("compress", L.compress)
  shader:send("lightScale", lightScale)
  shader:send("outAlpha", 1)
  g.setBlendMode("multiply", "premultiplied")
  g.setColor(1, 1, 1, 1)
  g.draw(canvas, 0, 0, 0, up, up)

  if lightGain > 0.001 then
    shader:send("ambient", zeroSend)
    shader:send("lightScale", lightGain)
    shader:send("outAlpha", 0)
    g.setBlendMode("add", "premultiplied")
    g.draw(canvas, 0, 0, 0, up, up)
  end
  g.setShader()

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
