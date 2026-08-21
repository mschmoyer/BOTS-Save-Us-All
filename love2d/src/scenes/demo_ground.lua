-- Ground-review scene. Six fixed panels -- rock, scar, shore, meadow -- each with
-- its own camera parked on a representative point of the generated island, so one
-- screenshot shows every surface at the zoom it ships at. The patrol in
-- demo_terrain flies over the coast and rarely crosses the ground that needs
-- judging; this is the faster loop for terrain.lua's shading work.
--
--   BOTS_SEED=9 BOTS_SCENE=src.scenes.demo_ground tools/shot.sh 30 30 /tmp/g
--   BOTS_LOOK=rock|scar          six views of one biome instead
--   BOTS_LOOK=seam|seamrock      panels parked on the bake's tile boundaries,
--                                which is where a seam in the bake shows up
local P       = require("src.engine.palette")
local Camera  = require("src.engine.camera")
local Terrain = require("src.world.terrain")
local Water   = require("src.world.water")

local S = {}

local function envN(k, d) return tonumber(os.getenv(k) or "") or d end

function S:enter()
  self.seed = envN("BOTS_SEED", 20190101)
  self.terrain = Terrain.new(self.seed)
  self.terrain:bake()
  local T = self.terrain
  local gw, cell = T.gw, T.cell

  -- representative points
  local function centroid(pred)
    local sx, sy, n = 0, 0, 0
    for i = 1, gw * T.gh do
      if pred(i) then
        sx = sx + ((i - 1) % gw); sy = sy + math.floor((i - 1) / gw); n = n + 1
      end
    end
    if n == 0 then return T.w * 0.5, T.h * 0.5 end
    return sx / n * cell, sy / n * cell
  end
  local rx, ry = centroid(function(i) return T.biome[i] == 3 end)
  local sc = T.scarCentres[1]
  local scx, scy = sc and sc.x or T.w * 0.5, sc and sc.y or T.h * 0.5
  local bx, by = centroid(function(i) return T.biome[i] == 1 end)
  -- a beach cell near that centroid
  local best, bd = nil, 1e18
  for i = 1, gw * T.gh do
    if T.biome[i] == 1 then
      local x, y = ((i - 1) % gw) * cell, math.floor((i - 1) / gw) * cell
      local d = (x - bx) ^ 2 + (y - by) ^ 2
      if d < bd then bd, best = d, { x, y } end
    end
  end
  if best then bx, by = best[1], best[2] end
  local mx, my = centroid(function(i) return T.biome[i] == 2 end)

  self.panels = {
    { "ROCK z1.0",  rx, ry, 1.0 },
    { "ROCK z2.5",  rx, ry, 2.5 },
    { "SCAR z1.0",  scx, scy, 1.0 },
    { "SCAR z2.5",  scx, scy, 2.5 },
    { "SHORE z1.0", bx, by, 1.0 },
    { "MEADOW z1.0", mx, my, 1.0 },
  }
  local ov = os.getenv("BOTS_LOOK")
  if ov == "rock" then
    self.panels = { { "ROCK z1", rx, ry, 1 }, { "ROCK z2", rx, ry, 2 },
                    { "ROCK z3.5", rx, ry, 3.5 }, { "ROCK edge", rx + 260, ry + 200, 1.6 },
                    { "ROCK z0.6", rx, ry, 0.6 }, { "ROCK alt", rx - 300, ry - 240, 1.6 } }
  elseif ov == "seamrock" then
    local TWx, THy = Terrain.TILE_W, Terrain.TILE_H
    local sx = math.floor(rx / TWx + 0.5) * TWx
    local sy = math.floor(ry / THy + 0.5) * THy
    self.panels = {
      { "rock tileY z1", rx, sy, 1.0 },
      { "rock tileY z2.5", rx, sy, 2.5 },
      { "rock tileX z2.5", sx, ry, 2.5 },
      { "rock corner z2.5", sx, sy, 2.5 },
      { "scar tileY z2.5", scx, math.floor(scy / THy + 0.5) * THy, 2.5 },
      { "meadow tileY z2.5", mx, math.floor(my / THy + 0.5) * THy, 2.5 },
    }
  elseif ov == "seam" then
    local TWx, THy = Terrain.TILE_W, Terrain.TILE_H
    self.panels = {
      { "seam y800 z1", TWx * 1.5, THy, 1.0 },
      { "seam y800 z1.37", TWx * 1.5 + 0.37, THy + 0.41, 1.37 },
      { "seam x850 z1", TWx, THy * 1.5, 1.0 },
      { "seam x850 z2.13", TWx + 0.29, THy * 1.5, 2.13 },
      { "corner z0.8", TWx * 2, THy, 0.8 },
      { "corner z1.62", TWx * 2 + 0.5, THy + 0.5, 1.62 },
    }
  elseif ov == "shore" then
    -- Six stretches of coast spread round the island, plus the whole island.
    -- The surf is the one thing that cannot be judged from one panel: it is
    -- meant to be violent in one place and absent in another, and a single
    -- close view of it proves nothing either way.
    local cxw, cyw = T.w * 0.5, T.h * 0.5
    local picks = {}
    for k = 0, 4 do
      local want = k / 5 * math.pi * 2 - math.pi
      local best, bd = nil, 1e18
      for i = 1, gw * T.gh do
        if T.biome[i] == 1 then
          local x, y = ((i - 1) % gw) * cell, math.floor((i - 1) / gw) * cell
          local a = math.atan2(y - cyw, x - cxw)
          local d = math.abs(((a - want + math.pi) % (math.pi * 2)) - math.pi)
          if d < bd then bd, best = d, { x, y } end
        end
      end
      picks[#picks + 1] = best or { cxw, cyw }
    end
    self.panels = { { "ISLAND z0.26", cxw, cyw, 0.26 } }
    for k, pk in ipairs(picks) do
      self.panels[#self.panels + 1] = { "COAST " .. k, pk[1], pk[2], 1.0 }
    end
  elseif ov == "scar" then
    self.panels = { { "SCAR z1", scx, scy, 1 }, { "SCAR z2", scx, scy, 2 },
                    { "SCAR z3.5", scx, scy, 3.5 }, { "SCAR edge", scx + 190, scy, 2 },
                    { "SCAR z0.6", scx, scy, 0.6 }, { "SCAR alt", scx - 170, scy + 140, 2 } }
  end
  self.t = 0
end

function S:update(dt) self.t = self.t + dt; self.terrain:update(dt) end

function S:draw()
  local T = self.terrain
  local t0 = love.timer.getTime()
  local w, h = love.graphics.getDimensions()
  local cols, rows = 3, 2
  local pw, ph = math.floor(w / cols), math.floor(h / rows)
  love.graphics.clear(P.black)
  for k, p in ipairs(self.panels) do
    local ix = (k - 1) % cols
    local iy = math.floor((k - 1) / cols)
    local px, py = ix * pw, iy * ph
    love.graphics.setScissor(px, py, pw, ph)
    love.graphics.push()
    love.graphics.translate(px, py)
    local cam = Camera.new(pw, ph)
    cam.freeBounds = true
    cam.zoom = p[4]
    cam:snapTo(p[2], p[3])
    cam:attach()
    Water.draw(cam, T.time, T.shoreCanvas)
    T:draw(cam)
    T:drawOverlay(cam)
    cam:detach()
    love.graphics.pop()
    love.graphics.setScissor()
    love.graphics.setColor(P.alpha(P.black, 0.6))
    love.graphics.rectangle("fill", px + 4, py + 4, 150, 16)
    love.graphics.setColor(P.ink)
    love.graphics.print(p[1], px + 8, py + 5)
    love.graphics.setColor(P.alpha(P.inkFaint, 0.5))
    love.graphics.rectangle("line", px, py, pw, ph)
    love.graphics.setColor(1, 1, 1, 1)
  end
  -- Measured across the panels only: this is the ground's whole per-frame cost.
  -- Under Xvfb it is software-rasterised and enormous in absolute terms, but it
  -- is comparable between two runs of the same capture, which is what it is for.
  self.frameMs = love.timer.getTime() - t0
  -- Cost readout. The bake may get slower; the frame may not.
  love.graphics.setColor(P.alpha(P.black, 0.66))
  love.graphics.rectangle("fill", 0, h - 20, 560, 20)
  love.graphics.setColor(P.inkDim)
  love.graphics.print(string.format(
    "seed %d   gen %.0f ms   bake %.0f ms   %.1f MB   tiles/panel %d   frame %.2f ms",
    self.seed, (T.genTime or 0) * 1000, (T.bakeTime or 0) * 1000,
    T:memoryEstimate(), T.tilesDrawn or 0, (self.frameMs or 0) * 1000), 8, h - 17)
  love.graphics.setColor(1, 1, 1, 1)
end

function S:keypressed(k) if k == "escape" then love.event.quit() end end

return S
