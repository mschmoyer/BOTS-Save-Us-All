-- Lighting / post-processing test bed.
--
--   BOTS_SCENE=src.scenes.demo_light tools/shot.sh 400 50,140,240,340,400 /tmp/shots_light
--
-- Stand-in ground (the terrain owner will replace it), 40 drifting point
-- lights, 2 cone lights, a handful of emissive props to make bloom visible,
-- and a full day -> dusk -> night -> dawn cycle compressed into 6 seconds.
local U        = require("src.core.util")
local P        = require("src.engine.palette")
local Camera   = require("src.engine.camera")
local J        = require("src.engine.juice")
local DN       = require("src.engine.daynight")
local Lighting = require("src.engine.lighting")
local Post     = require("src.engine.postfx")

local S = {}

local NLIGHTS = 40
local WORLD_W, WORLD_H = 1600, 900

local lights, props, stars, ground
local cam
local rng
local shockTimer = 0
local frameMs, lastT = 0, nil
local coneA, coneB = 0, 0

-- persistent option tables: addLight must never allocate at the call site
local OPT_SOFT  = { softness = 0.9 }
local OPT_MID   = { softness = 0.5 }
local OPT_TIGHT = { softness = 0.1 }
local OPT_FIRE  = { softness = 0.5, flicker = 0.45 }

---------------------------------------------------------------------- ground
local function bakeGround()
  local g = love.graphics
  local prev = g.getCanvas()
  local c = g.newCanvas(WORLD_W, WORLD_H)
  g.setCanvas(c)
  g.clear(P.ramp.grass[1])
  g.push() g.origin()

  local r = U.rng(9001)
  -- broad grass variation
  for _ = 1, 260 do
    local x, y = r:range(0, WORLD_W), r:range(0, WORLD_H)
    local rad = r:range(70, 240)
    g.setColor(P.shade(P.ramp.grass, r:range(1.6, 2.6), 0.5))
    g.ellipse("fill", x, y, rad, rad * r:range(0.5, 0.8))
  end
  -- a soil path
  g.setColor(P.shade(P.ramp.soil, 2.2, 0.9))
  local px, py = 90, 640
  for i = 1, 42 do
    local t = i / 42
    px = 90 + t * 1460
    py = 640 - math.sin(t * 5.2) * 190
    g.ellipse("fill", px, py, 62, 34)
  end
  -- rock scatter
  for _ = 1, 46 do
    local x, y = r:range(0, WORLD_W), r:range(0, WORLD_H)
    local rad = r:range(14, 44)
    g.setColor(P.shade(P.ramp.rock, r:range(1.4, 2.4), 1))
    g.ellipse("fill", x, y, rad, rad * 0.72)
    g.setColor(P.shade(P.ramp.rock, 3.4, 0.6))
    g.ellipse("fill", x - rad * 0.18, y - rad * 0.22, rad * 0.55, rad * 0.34)
  end
  -- water inlet, bottom-right
  g.setColor(P.ramp.water[2])
  g.ellipse("fill", 1520, 880, 420, 260)
  g.setColor(P.ramp.water[3][1], P.ramp.water[3][2], P.ramp.water[3][3], 0.5)
  g.ellipse("fill", 1520, 880, 350, 205)

  g.pop()
  g.setCanvas(prev)
  g.setColor(1, 1, 1, 1)
  return c
end

----------------------------------------------------------------------- enter
function S:enter()
  local w, h = love.graphics.getDimensions()
  Lighting.init(w, h)
  Lighting.setQuality(1)
  Post.init(w, h)
  ground = bakeGround()

  cam = Camera(w, h)
  cam:snapTo(WORLD_W / 2, WORLD_H / 2)

  rng = U.rng(4242)
  lights = {}
  for i = 1, NLIGHTS do
    local hue = rng:next()
    local col
    if hue < 0.34 then col = P.ramp.cobalt[3]
    elseif hue < 0.62 then col = P.ramp.ember[3]
    elseif hue < 0.8 then col = P.accent
    elseif hue < 0.92 then col = P.love
    else col = P.ramp.rift[3] end
    lights[i] = {
      cx = rng:range(120, WORLD_W - 120),
      cy = rng:range(120, WORLD_H - 120),
      rad = rng:range(40, 190),
      spd = rng:range(0.4, 1.5) * rng:sign(),
      ph  = rng:angle(),
      r   = rng:range(110, 230),
      col = col,
      inten = rng:range(0.55, 1.05),
      flick = rng:chance(0.3) and rng:range(0.15, 0.4) or 0,
      x = 0, y = 0,
    }
  end

  -- emissive props: the things bloom is supposed to find
  props = {}
  local function prop(x, y, r, col, kind) props[#props + 1] =
    { x = x, y = y, r = r, col = col, kind = kind, ph = rng:angle() } end
  prop(400, 300, 26, P.ramp.cobalt[4], "crystal")
  prop(1180, 250, 22, P.ramp.cobalt[4], "crystal")
  prop(760, 690, 30, P.ramp.ember[4], "fire")
  prop(240, 760, 24, P.ramp.ember[4], "fire")
  prop(1320, 620, 20, P.accent, "beacon")
  prop(560, 140, 18, P.accent, "beacon")
  prop(980, 460, 34, P.ramp.rift[3], "rift")

  -- "trees": opaque blobs that cast the sun shadow, so shadow sweep is visible
  self.trees = {}
  for i = 1, 34 do
    self.trees[i] = {
      x = rng:range(80, WORLD_W - 80),
      y = rng:range(80, WORLD_H - 80),
      r = rng:range(26, 58),
    }
  end

  stars = {}
  for i = 1, 90 do
    stars[i] = { x = rng:range(0, WORLD_W), y = rng:range(0, WORLD_H * 0.55),
                 s = rng:range(0.7, 2.1), ph = rng:angle() }
  end

  -- 6-second cycle: 2s day, 1s dusk, 2s night, 1s dawn
  DN.durations.day, DN.durations.dusk = 2, 1
  DN.durations.night, DN.durations.dawn = 2, 1
  DN.auto = true
  DN.set("day", 0)
  DN.o2Influence(34)

  self.t = 0
end

function S:leave()
  DN.auto = false
  if ground then ground:release() ground = nil end
end

function S:resize(w, h)
  Lighting.resize(w, h)
  Post.resize(w, h)
  cam:resize(w, h)
end

---------------------------------------------------------------------- update
function S:update(dt, realDt)
  realDt = realDt or dt
  self.t = self.t + realDt
  DN.update(realDt)
  Post.update(realDt)

  -- O2 climbs across the run; the sky cleans up with it
  DN.o2Influence(34 + math.sin(self.t * 0.5) * 22)

  for i = 1, NLIGHTS do
    local l = lights[i]
    local a = l.ph + self.t * l.spd
    l.x = l.cx + math.cos(a) * l.rad
    l.y = l.cy + math.sin(a * 1.3) * l.rad * 0.7
  end

  coneA = coneA + realDt * 0.9
  coneB = -0.6 + math.sin(self.t * 1.6) * 0.55

  shockTimer = shockTimer - realDt
  if shockTimer <= 0 then
    shockTimer = 1.1
    local w, h = love.graphics.getDimensions()
    Post.addShockwave(w * (0.3 + 0.4 * rng:next()), h * (0.3 + 0.4 * rng:next()),
                      420, 1.0, 0.55)
    J.shake(0.16)
  end
end

------------------------------------------------------------------------ draw
local function drawShadows()
  local g = love.graphics
  local sx, sy = math.cos(DN.sunAngle), math.sin(DN.sunAngle)
  local len = DN.sunLength
  local dark = P.ramp.soil[1]
  g.setBlendMode("multiply", "premultiplied")
  for i = 1, #S.trees do
    local t = S.trees[i]
    local ox, oy = sx * t.r * 1.7 * len, sy * t.r * 1.1 * len
    local a = 0.55 * (0.4 + 0.6 * (1 - len * 0.5))
    g.setColor(U.lerp(1, dark[1], a), U.lerp(1, dark[2], a), U.lerp(1, dark[3], a), 1)
    g.ellipse("fill", t.x + ox, t.y + oy, t.r * (1 + len * 0.5), t.r * 0.72)
  end
  g.setBlendMode("alpha", "alphamultiply")
end

local function drawTrees()
  local g = love.graphics
  local rimx = -math.cos(DN.sunAngle)
  local rimy = -math.sin(DN.sunAngle)
  for i = 1, #S.trees do
    local t = S.trees[i]
    g.setColor(P.shade(P.ramp.bark, 1.8))
    g.rectangle("fill", t.x - 5, t.y - 6, 10, t.r * 0.7, 3)
    g.setColor(P.shade(P.ramp.leaf, 2.0))
    g.circle("fill", t.x, t.y - t.r * 0.35, t.r)
    g.setColor(P.shade(P.ramp.leaf, 2.9))
    g.circle("fill", t.x - t.r * 0.2, t.y - t.r * 0.55, t.r * 0.66)
    -- rim light on the sun-facing side
    g.setColor(P.alpha(DN.sunColor, 0.35))
    g.circle("fill", t.x + rimx * t.r * 0.45, t.y - t.r * 0.35 + rimy * t.r * 0.45, t.r * 0.34)
  end
end

local function addLights()
  for i = 1, NLIGHTS do
    local l = lights[i]
    local o = OPT_MID
    if l.flick > 0 then
      OPT_FIRE.flicker = l.flick
      o = OPT_FIRE
    elseif i % 3 == 0 then o = OPT_SOFT end
    Lighting.addLight(l.x, l.y, l.r, l.col, l.inten, o)
  end
  for i = 1, #props do
    local p = props[i]
    local pulse = 0.82 + math.sin(S.t * 3 + p.ph) * 0.18
    if p.kind == "fire" then
      Lighting.addLight(p.x, p.y, 260, P.ramp.ember[3], 1.5 * pulse, OPT_FIRE)
    elseif p.kind == "rift" then
      Lighting.addLight(p.x, p.y, 300, P.ramp.rift[3], 1.15 * pulse, OPT_SOFT)
    elseif p.kind == "beacon" then
      Lighting.addLight(p.x, p.y, 300, P.accent, 1.25 * pulse, OPT_MID)
    else
      Lighting.addLight(p.x, p.y, 210, P.ramp.cobalt[3], 1.2 * pulse, OPT_TIGHT)
    end
  end
  -- the player lamp and a sweeping sentry scan
  Lighting.addCone(WORLD_W * 0.5, WORLD_H * 0.52, 520, P.eye, 1.6, coneA, math.rad(26), 0.08)
  Lighting.addCone(1360, 200, 620, P.accentCool, 1.35, coneB, math.rad(15), 0)
  -- a soft key light so unlit ground still reads
  Lighting.addLight(WORLD_W * 0.5, WORLD_H * 0.45, 900, DN.sunColor,
                    0.35 * DN.ambientStrength, OPT_SOFT)
end

local function drawEmissive()
  local g = love.graphics
  g.setBlendMode("add", "alphamultiply")
  for i = 1, #props do
    local p = props[i]
    local pulse = 0.82 + math.sin(S.t * 3 + p.ph) * 0.18
    g.setColor(P.alpha(p.col, 0.95 * pulse))
    g.circle("fill", p.x, p.y, p.r * 0.55)
    g.setColor(P.alpha(p.col, 0.35 * pulse))
    g.circle("fill", p.x, p.y, p.r)
    if p.kind == "crystal" then
      g.setColor(P.alpha(P.white, 0.8 * pulse))
      g.circle("fill", p.x, p.y, p.r * 0.24)
    end
  end
  -- bot eyes: tiny, very hot, the classic bloom test
  for i = 1, NLIGHTS, 4 do
    local l = lights[i]
    g.setColor(P.alpha(P.white, 0.85))
    g.circle("fill", l.x, l.y, 3)
    g.setColor(P.alpha(l.col, 0.55))
    g.circle("fill", l.x, l.y, 8)
  end
  -- stars and moon
  if DN.starAlpha > 0.01 then
    for i = 1, #stars do
      local s = stars[i]
      local tw = 0.55 + 0.45 * math.sin(S.t * 2.2 + s.ph)
      g.setColor(P.alpha(P.ink, DN.starAlpha * 0.75 * tw))
      g.circle("fill", s.x, s.y, s.s)
    end
  end
  if DN.moonAlpha > 0.01 then
    g.setColor(P.alpha(P.ramp.metal[4], DN.moonAlpha * 0.9))
    g.circle("fill", 1420, 140, 34)
    g.setColor(P.alpha(P.ramp.metal[4], DN.moonAlpha * 0.18))
    g.circle("fill", 1420, 140, 78)
  end
  g.setBlendMode("alpha", "alphamultiply")
end

function S:draw()
  local now = love.timer.getTime()
  if lastT then frameMs = frameMs + ((now - lastT) * 1000 - frameMs) * 0.12 end
  lastT = now

  local g = love.graphics
  DN.apply(Post, Lighting)

  Post.beginScene()

  cam:attach()
  g.setColor(1, 1, 1, 1)
  g.draw(ground, 0, 0)
  drawShadows()
  drawTrees()
  cam:detach()

  Lighting.beginFrame(cam)
  addLights()
  Lighting.finish()

  cam:attach()
  drawEmissive()
  cam:detach()

  Post.endScene()
  Post.render()

  self:hud()
end

------------------------------------------------------------------------- hud
function S:hud()
  local g = love.graphics
  g.setColor(P.black[1], P.black[2], P.black[3], 0.55)
  g.rectangle("fill", 16, 16, 372, 150, 6)
  g.setColor(P.accent)
  g.print(string.format("%s  %3d%%", DN.phase:upper(), math.floor(DN.t * 100)), 30, 28)
  g.setColor(P.ink)
  g.print(string.format("frame  %5.2f ms   (%4.0f fps)", frameMs,
                        frameMs > 0 and 1000 / frameMs or 0), 30, 48)
  g.print(string.format("post   %5.2f ms cpu   %d passes", Post.stats.ms, Post.stats.passes), 30, 66)
  g.print(string.format("lights %d   quality %d   %s", Lighting.lightCount(),
                        Lighting.getQuality(), Post.hdr and "hdr16f" or "rgba8"), 30, 84)
  g.setColor(P.inkDim)
  g.print(string.format("sun %5.1f deg  len %.2f  amb %.2f  exp %.2f",
                        math.deg(DN.sunAngle) % 360, DN.sunLength,
                        DN.ambientStrength, DN.exposure), 30, 106)
  g.print(string.format("star %.2f  moon %.2f  o2 %.0f%%  bloom %.2f",
                        DN.starAlpha, DN.moonAlpha, DN.o2 * 100, DN.bloom), 30, 124)
  g.print(string.format("draws %d", love.graphics.getStats().drawcalls), 30, 142)
  g.setColor(1, 1, 1, 1)
end

function S:keypressed(k)
  if k == "1" then Post.settings.bloom = not Post.settings.bloom end
  if k == "2" then Post.settings.ca = not Post.settings.ca end
  if k == "3" then Post.settings.grain = not Post.settings.grain end
  if k == "4" then Post.settings.vignette = not Post.settings.vignette end
  if k == "5" then Post.settings.fxaa = not Post.settings.fxaa end
  if k == "q" then Lighting.setQuality((Lighting.getQuality() + 1) % 3) end
end

return S
