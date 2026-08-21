-- Flora test bed. Three phases, driven by time so `tools/shot.sh` catches one
-- of each, or by 1/2/3 when you run it by hand.
--
--   1  SPECIMENS  every species at five points in its life
--   2  FOREST     900 trees, drifting camera, travelling gusts, frame timings
--   3  LIFECYCLE  seed -> elder -> chewed -> felled, side by side and live
--
-- Keys: 1/2/3 phase, SPACE gust, G toggle rim pass, S toggle shadows,
--       H toggle HUD, [ / ] zoom.
local U      = require("src.core.util")
local P      = require("src.engine.palette")
local Camera = require("src.engine.camera")
local Tree   = require("src.entities.tree")
local Wind   = require("src.world.wind")
local T      = require("src.game.tuning").tree

local S = {}

local FOREST_N  = 900
local FOREST_W  = 2320
local FOREST_H  = 1340
local PHASE_AT  = { 0, 1.6, 5.6 }        -- seconds each phase begins

------------------------------------------------------------------ ground
local function makeGround()
  local size = 256
  local cv = love.graphics.newCanvas(size, size)
  local prev = love.graphics.getCanvas()
  love.graphics.setCanvas(cv)
  love.graphics.clear(P.shade(P.ramp.moss, 1.15))
  local r = U.rng(4242)
  local OFF = { -size, 0, size }
  for _ = 1, 620 do
    local x, y = r:next() * size, r:next() * size
    local rx, ry = r:range(7, 30), r:range(5, 18)
    local c = P.shade(P.ramp.grass, 1.0 + r:next() * 1.25, 0.13 + r:next() * 0.13)
    love.graphics.setColor(c)
    for i = 1, 3 do
      for j = 1, 3 do
        love.graphics.ellipse("fill", x + OFF[i], y + OFF[j], rx, ry, 10)
      end
    end
  end
  -- a few soil scuffs so it is not uniformly green
  for _ = 1, 90 do
    local x, y = r:next() * size, r:next() * size
    local c = P.shade(P.ramp.soil, 2.0 + r:next(), 0.13)
    love.graphics.setColor(c)
    for i = 1, 3 do
      for j = 1, 3 do
        love.graphics.ellipse("fill", x + OFF[i], y + OFF[j], r:range(5, 15), r:range(3, 9), 8)
      end
    end
  end
  love.graphics.setCanvas(prev)
  love.graphics.setColor(1, 1, 1, 1)
  cv:setWrap("repeat", "repeat")
  cv:setFilter("linear", "linear")
  return cv
end

------------------------------------------------------------------ building
local function buildSpecimens()
  local list = {}
  local growths = { 0.03, 0.22, 0.5, 1.0, 1.0 }
  for spi = 1, Tree.speciesCount do
    for col = 1, 5 do
      local t = Tree.new(150 + (col - 1) * 305, 330 + (spi - 1) * 250,
                         spi * 977 + col * 31 + 5,
                         { species = spi, growth = growths[col], elder = (col == 5) })
      t.demoLabel = (col == 1 and Tree.species[spi].label or nil)
      list[#list + 1] = t
    end
  end
  return list
end

local function buildForest()
  local list = {}
  local r = U.rng(20190101)
  local cols = math.ceil(math.sqrt(FOREST_N * FOREST_W / FOREST_H))
  local rows = math.ceil(FOREST_N / cols)
  local cw, ch = FOREST_W / cols, FOREST_H / rows
  local n = 0
  for iy = 0, rows - 1 do
    for ix = 0, cols - 1 do
      if n < FOREST_N then
        n = n + 1
        local x = (ix + 0.5 + r:gauss() * 0.58) * cw
        local y = (iy + 0.5 + r:gauss() * 0.58) * ch
        -- regional fields: where the grove is old, and which species likes it here
        local dens = U.fbm(x / 700, y / 700, 3, 2, 0.5, 11)
        local kind = U.fbm(x / 520 + 40, y / 520, 2, 2, 0.5, 77)
        local spi
        if kind < 0.40 then spi = 1
        elseif kind < 0.52 then spi = 4
        elseif kind < 0.62 then spi = 3
        elseif kind < 0.78 then spi = 1
        elseif kind < 0.90 then spi = 2
        else spi = 5 end
        local g = U.saturate(0.42 + dens * 1.35 + r:gauss() * 0.12)
        local t = Tree.new(x, y, n * 7919 + 13, {
          species = spi, growth = g,
          elder = (g >= 1 and dens > 0.66 and r:chance(0.35)),
        })
        if t.elderness > 0 then t.elderT = T.elderTime end
        list[#list + 1] = t
      end
    end
  end
  table.sort(list, function(a, b) return a.y < b.y end)
  return list
end

local LIFE_LABEL = {
  "PLANTED", "SAPLING", "YOUNG", "MATURE", "ELDER", "CHEWED", "FELLED",
}

local function buildLifecycle()
  local list = {}
  for i = 1, 7 do
    local t = Tree.new(180 + (i - 1) * 250, 470, 4200 + i * 613, { species = 1 })
    t.demoSlot = i
    t.demoLabel = LIFE_LABEL[i]
    list[#list + 1] = t
  end
  return list
end

local function resetLifecycle(list)
  for i = 1, #list do
    local t = list[i]
    t.alive, t.toppling, t.fade, t.deadT = true, false, 1, 0
    t.damage, t.death, t.chewers = 0, 0, 0
    t.elderness, t.elderT = 0, 0
    t.growth = ({ 0.0, 0.22, 0.55, 1.0, 1.0, 1.0, 1.0 })[i]
    t.growthMul = (i == 1) and 5 or 1
    if i >= 5 then t.elderness, t.elderT = 1, T.elderTime end
    if i == 6 then t.elderness, t.elderT = 0, 0 end
    t:refreshMesh()
    t:refreshStage(true)
    if i == 6 then t.damage = 0.62 t.death = 0.62 t:startChew("demo") end
    if i == 7 then t:kill("demo") t.toppleT = Tree.tune.toppleTime * 0.62 end
  end
end

--------------------------------------------------------------------- scene
function S:enter()
  self.t = 0
  self.phase = tonumber(os.getenv("BOTS_PHASE") or "") or 0   -- 0 = timed
  self.showHud = true
  self.rimPass = true
  self.shadows = true

  self.ground = makeGround()
  self.groundQuad = love.graphics.newQuad(0, 0, 8192, 8192, 256, 256)

  local t0 = love.timer.getTime()
  local warmT, cells = Tree.prewarm()
  local nMesh, nVert = Tree.libraryStats()
  self.buildInfo = string.format("mesh library %d cells / %d verts in %.0f ms",
                                 cells, nVert, warmT * 1000)

  self.specimens = buildSpecimens()
  self.forest    = buildForest()
  self.life      = buildLifecycle()
  resetLifecycle(self.life)
  self.spawnInfo = string.format("%d trees built in %.0f ms",
                                 #self.specimens + #self.forest + #self.life,
                                 (love.timer.getTime() - t0 - warmT) * 1000)
  print(self.buildInfo)
  print(self.spawnInfo)

  local w, h = love.graphics.getDimensions()
  self.cam = Camera(w, h)
  self.frameMs, self.updMs, self.drwMs = 0, 0, 0
  self.visible, self.lastPhase = 0, -1
  Wind.reset()
  self:setPhase(1)
end

function S:resize(w, h) self.cam:resize(w, h) end

function S:setPhase(p)
  if p == self.lastPhase then return end
  self.lastPhase = p
  local cam = self.cam
  if p == 1 then
    cam.zoom, cam.zoomTarget = 0.62, 0.62
    cam:snapTo(770, 720)
    self.list = self.specimens
    self.title = "SPECIMENS"
  elseif p == 2 then
    cam.zoom, cam.zoomTarget = 0.62, 0.62
    cam:snapTo(FOREST_W * 0.5, FOREST_H * 0.5)
    self.list = self.forest
    self.title = "FOREST"
    Wind.gust(0.85)
  else
    cam.zoom, cam.zoomTarget = 1.05, 1.05
    cam:snapTo(930, 400)
    resetLifecycle(self.life)
    self.list = self.life
    self.title = "LIFECYCLE"
  end
end

function S:keypressed(k)
  if k == "1" or k == "2" or k == "3" then
    self.phase = tonumber(k)
    self:setPhase(self.phase)
  elseif k == "space" then Wind.gust(1.0)
  elseif k == "g" then self.rimPass = not self.rimPass
  elseif k == "s" then self.shadows = not self.shadows
  elseif k == "h" then self.showHud = not self.showHud
  elseif k == "[" then self.cam.zoomTarget = self.cam.zoomTarget * 0.85
  elseif k == "]" then self.cam.zoomTarget = self.cam.zoomTarget * 1.18
  elseif k == "escape" then love.event.quit() end
end

--------------------------------------------------------------------- update
function S:update(dt)
  local now = love.timer.getTime()
  if self.lastFrame then
    self.frameMs = self.frameMs + ((now - self.lastFrame) * 1000 - self.frameMs) * 0.08
  end
  self.lastFrame = now

  self.t = self.t + dt
  if self.phase == 0 then
    local p = 1
    if self.t >= PHASE_AT[3] then p = 3 elseif self.t >= PHASE_AT[2] then p = 2 end
    self:setPhase(p)
  end

  Wind.update(dt)

  -- sun swings through the afternoon so the shadows rotate visibly
  local sa = -2.10 + math.sin(self.t * 0.11) * 0.55
  self.sunDirX, self.sunDirY = math.cos(sa), math.sin(sa)
  self.sunAngle = sa + math.pi
  self.sunLen = 1.05 + math.sin(self.t * 0.09) * 0.35

  local cam = self.cam
  if self.lastPhase == 2 then
    -- a slow drift across the canopy
    local a = self.t * 0.16
    cam:snapTo(FOREST_W * 0.5 + math.cos(a) * FOREST_W * 0.16,
               FOREST_H * 0.5 + math.sin(a * 1.37) * FOREST_H * 0.13)
  elseif self.lastPhase == 1 then
    cam:snapTo(770, 720)
  end
  cam:clampToBounds()
  -- Park the canopy x-ray off the map. It fades out whatever crown covers the
  -- focus point, and with no focus set the tree system falls back to what the
  -- camera is looking at -- which here is the middle of a row laid out to be
  -- looked at. The MATURE tree sat dead centre and rendered as a bare shadow,
  -- and read for a long time as a broken mesh rather than a working feature.
  Tree.setFocus(-1e6, -1e6, 1)
  Tree.setViewFromCamera(cam)

  local list = self.list
  if self.lastPhase == 3 then
    -- fast-forward: run the same fixed step several times instead of faking dt
    for _ = 1, 5 do
      for i = 1, #list do list[i]:update(dt) end
    end
    for i = 1, #list do
      local t = list[i]
      if t.demoSlot == 5 and t.elderness < 1 then t.growthMul = 90 end
      if t.demoSlot == 1 and t.growth >= 1 then
        t.growth, t.elderness, t.elderT = 0, 0, 0
        t:refreshMesh()
      end
      if t.demoSlot == 7 and t:isDone() then
        t.alive, t.toppling, t.fade, t.deadT, t.death = true, false, 1, 0, 0
        t.growth = 1
        t:refreshMesh() t:refreshStage(true) t:kill("demo")
      end
      if t.demoSlot == 6 and not t.alive then
        t.alive, t.toppling, t.fade, t.deadT = true, false, 1, 0
        t.damage, t.death = 0.35, 0.35
        t.growth = 1
        t:refreshMesh() t:refreshStage(true) t:startChew("demo")
      end
    end
  else
    for i = 1, #list do list[i]:update(dt) end
  end

  self.updMs = self.updMs + ((love.timer.getTime() - now) * 1000 - self.updMs) * 0.08
end

---------------------------------------------------------------------- draw
function S:draw()
  local t0 = love.timer.getTime()
  local g = love.graphics
  local cam = self.cam

  g.clear(P.shade(P.ramp.moss, 1.1))
  cam:attach()

  -- ground
  local vx, vy, vw, vh = cam:viewRect(64)
  g.setColor(1, 1, 1, 1)
  local qx, qy = math.floor(vx / 256) * 256, math.floor(vy / 256) * 256
  self.groundQuad:setViewport(0, 0, vw + 512, vh + 512, 256, 256)
  g.draw(self.ground, self.groundQuad, qx, qy)

  local list = self.list
  local n = 0

  if self.shadows then
    for i = 1, #list do list[i]:drawShadow(self.sunAngle, self.sunLen, 0.34) end
  end
  Tree.endPass()

  for i = 1, #list do
    local t = list[i]
    t:draw(self.sunDirX, self.sunDirY)
    if t.onScreen then n = n + 1 end
  end
  Tree.endPass()

  if self.rimPass then
    for i = 1, #list do list[i]:drawCanopyLight() end
    Tree.endPass()
  end

  self.visible = n
  cam:detach()
  g.setColor(1, 1, 1, 1)
  self.drwMs = self.drwMs + ((love.timer.getTime() - t0) * 1000 - self.drwMs) * 0.08
  self:drawHud()
end

function S:drawHud()
  if not self.showHud then return end
  local g = love.graphics
  local w, h = g.getDimensions()

  -- per-tree captions
  local list = self.list
  g.setColor(P.inkDim)
  for i = 1, #list do
    local t = list[i]
    if t.demoLabel and t.onScreen then
      local sx, sy = self.cam:toScreen(t.x, t.y + 26)
      g.print(t.demoLabel, math.floor(sx - 28), math.floor(sy))
    end
  end
  if self.lastPhase == 1 then
    g.setColor(P.inkFaint)
    for col, lab in ipairs({ "seed", "sapling", "young", "mature", "elder" }) do
      local sx, sy = self.cam:toScreen(150 + (col - 1) * 305, 170)
      g.print(lab, math.floor(sx - 14), math.floor(sy))
    end
  end

  g.setColor(P.black[1], P.black[2], P.black[3], 0.55)
  g.rectangle("fill", 0, 0, w, 86)
  g.setColor(P.accent)
  g.print(string.format("%d  %s", self.lastPhase, self.title), 18, 12)
  g.setColor(P.ink)
  g.print(string.format(
    "trees %d   visible %d   %.2f ms/frame (%.0f fps)   update %.2f   draw %.2f   %s",
    #list, self.visible, self.frameMs,
    self.frameMs > 0 and 1000 / self.frameMs or 0,
    self.updMs, self.drwMs,
    Tree.shadersAvailable() and "gpu wind" or "cpu fallback"), 18, 32)
  g.setColor(P.inkDim)
  g.print(string.format("wind %.2f  gust %.2f  dir %.0f deg   zoom %.2f   %s   %s",
    Wind.strength, Wind.gustLevel, math.deg(Wind.direction) % 360, self.cam.zoom,
    self.buildInfo, self.spawnInfo), 18, 52)
  g.setColor(P.inkFaint)
  g.print("1/2/3 phase   SPACE gust   G rim   S shadows   [ ] zoom", 18, h - 24)
  g.setColor(1, 1, 1, 1)
end

return S
