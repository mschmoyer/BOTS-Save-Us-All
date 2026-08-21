-- Terrain / water review scene. Generates an island and flies a camera across it.
--   BOTS_SCENE=src.scenes.demo_terrain tools/shot.sh 300 40,140,300 /tmp/shots_terrain
--   BOTS_SEED=4 to look at a different island.

local U       = require("src.core.util")
local P       = require("src.engine.palette")
local Camera  = require("src.engine.camera")
local Terrain = require("src.world.terrain")
local Water   = require("src.world.water")

local S = {}

local function envSeed()
  local s = tonumber(os.getenv("BOTS_SEED") or "")
  return s or 20190101
end

function S:enter()
  local w, h = love.graphics.getDimensions()
  self.seed = envSeed()

  local t0 = love.timer.getTime()
  self.terrain = Terrain.new(self.seed)
  self.genTime = love.timer.getTime() - t0

  self.cam = Camera.new(w, h)
  self.cam:setBounds(self.terrain:bounds())
  self.cam.zoom = 1.0
  self.t = 0
  self.frames = 0

  -- a patrol route across the island so successive frames show new ground
  local bw, bh = self.terrain.w, self.terrain.h
  self.route = {
    { 0.16, 0.20 }, { 0.50, 0.13 }, { 0.83, 0.28 }, { 0.90, 0.62 },
    { 0.62, 0.84 }, { 0.30, 0.78 }, { 0.12, 0.52 },
  }
  for _, p in ipairs(self.route) do p[1] = p[1] * bw; p[2] = p[2] * bh end
  self.cam:snapTo(self.route[1][1], self.route[1][2])
end

local function routePoint(route, s)
  local n = #route
  local f = (s % 1) * n
  local i = math.floor(f)
  local u = f - i
  local function at(k) return route[(k % n) + 1] end
  -- catmull-rom for a smooth, non-linear glide
  local p0, p1, p2, p3 = at(i - 1), at(i), at(i + 1), at(i + 2)
  local function cr(a, b, c, d)
    return 0.5 * ((2 * b) + (-a + c) * u + (2 * a - 5 * b + 4 * c - d) * u * u
                  + (-a + 3 * b - 3 * c + d) * u * u * u)
  end
  return cr(p0[1], p1[1], p2[1], p3[1]), cr(p0[2], p1[2], p2[2], p3[2])
end

function S:update(dt)
  self.t = self.t + dt
  self.frames = self.frames + 1

  if not self.terrain.baked then
    self.terrain:bakeStep(0.30)
    return
  end

  self.terrain:update(dt)

  -- one lap in ~34 s; the shot frames land on different parts of the island
  local s = self.t * 0.0295
  local x, y = routePoint(self.route, s)
  self.cam.tx, self.cam.ty = x, y
  self.cam.x = U.damp(self.cam.x, x, 6, dt)
  self.cam.y = U.damp(self.cam.y, y, 6, dt)
  self.cam.zoom = 0.94 + 0.10 * math.sin(self.t * 0.21)
  self.cam:clampToBounds()

  -- prove the reclamation path works: heal one scar as the demo runs
  if self.t > 2.0 and not self.healed and self.terrain.scarCentres[1] then
    local c = self.terrain.scarCentres[1]
    for k = 1, 5 do
      local a = k / 5 * U.TAU
      self.terrain:healAt(c.x + math.cos(a) * c.r * 0.4,
                          c.y + math.sin(a) * c.r * 0.4, c.r * 0.55, 0.75)
    end
    self.healed = true
  end
end

function S:draw()
  local T = self.terrain
  love.graphics.clear(P.ramp.water[1])

  if not T.baked then
    local w, h = love.graphics.getDimensions()
    love.graphics.setColor(P.inkDim)
    love.graphics.printf("BAKING TERRAIN", 0, h / 2 - 30, w, "center")
    love.graphics.setColor(P.accent)
    love.graphics.rectangle("fill", w * 0.3, h / 2, w * 0.4 * T.progress, 6)
    love.graphics.setColor(P.inkFaint)
    love.graphics.rectangle("line", w * 0.3, h / 2, w * 0.4, 6)
    love.graphics.setColor(1, 1, 1, 1)
    return
  end

  self.cam:attach()
  Water.draw(self.cam, T.time, T.shoreCanvas)
  T:draw(self.cam)
  T:drawOverlay(self.cam)
  self.cam:detach()

  self:legend()
end

function S:legend()
  local T = self.terrain
  local cx, cy = self.cam.x, self.cam.y
  local w, h = love.graphics.getDimensions()

  -- crosshair at the sampled point
  love.graphics.setColor(P.alpha(P.ink, 0.35))
  love.graphics.setLineWidth(1)
  love.graphics.line(w / 2 - 9, h / 2, w / 2 + 9, h / 2)
  love.graphics.line(w / 2, h / 2 - 9, w / 2, h / 2 + 9)

  local lines = {
    string.format("SEED %d      island %dx%d      grid %dx%d @ %d",
                  self.seed, T.w, T.h, T.gw, T.gh, T.cell),
    string.format("gen %.0f ms      bake %.0f ms      canvas %.1f MB      tiles drawn %d/%d",
                  self.genTime * 1000, (T.bakeTime or 0) * 1000, T:memoryEstimate(),
                  T.tilesDrawn or 0, #T.tiles),
    string.format("camera %.0f, %.0f      zoom %.2f      t %.1fs",
                  cx, cy, self.cam.zoom, self.t),
    string.format("under centre:  biome %-7s  height %.2f  soil %.2f  shore %+.0f  land %s",
                  T:biomeAt(cx, cy), T:heightAt(cx, cy), T:soilAt(cx, cy),
                  T:shoreDistAt(cx, cy), tostring(T:isLand(cx, cy))),
    string.format("land area %.0f%%   scars %d   fps %d",
                  T.landArea / (T.w * T.h) * 100, #T.scarCentres, love.timer.getFPS()),
  }

  local pad, lh = 12, 16
  love.graphics.setColor(P.alpha(P.black, 0.55))
  love.graphics.rectangle("fill", 16, 16, 640, #lines * lh + pad * 2, 4)
  love.graphics.setColor(P.ink)
  for i, s in ipairs(lines) do
    love.graphics.print(s, 16 + pad, 16 + pad + (i - 1) * lh)
  end

  -- biome legend swatches
  local names = { "beach", "meadow", "rock", "marsh", "scar" }
  local ramps = { P.ramp.sand, P.ramp.grass, P.ramp.rock, P.ramp.moss, P.ramp.blight }
  local bx = 16 + pad
  local by = 16 + pad + #lines * lh + 4
  love.graphics.setColor(P.alpha(P.black, 0.55))
  love.graphics.rectangle("fill", 16, by - 6, 640, 26, 4)
  for i = 1, #names do
    love.graphics.setColor(P.shade(ramps[i], 2.4))
    love.graphics.rectangle("fill", bx, by, 12, 12, 2)
    love.graphics.setColor(P.inkDim)
    love.graphics.print(names[i], bx + 16, by - 1)
    bx = bx + 24 + #names[i] * 8 + 18
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function S:keypressed(k)
  if k == "escape" then love.event.quit() end
end

return S
