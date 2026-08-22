-- Relic review scene. Nothing in this game can be judged from source, and a
-- relic is a twenty-pixel object somewhere on a 3400x2400 island, so an
-- autoplay capture is a bad way to look at one.
--
-- Two modes:
--
--   gallery  (default) one panel per relic kind, parked on the real placed
--            instance, on real terrain, at the zoom the game ships at. This is
--            the loop for the models themselves.
--   map      the whole island at fit zoom with every relic marked, plus the
--            Home Rig. This is the placement audit: a relic in the sea, a relic
--            under the rig, or five relics in a heap all show up here in one
--            frame, and it takes a couple of seconds per seed.
--
--   BOTS_SEED=4242 BOTS_SCENE=src.scenes.demo_relic tools/shot.sh 8 8 /tmp/r
--   BOTS_RELIC=map BOTS_SEED=777 BOTS_SCENE=src.scenes.demo_relic tools/shot.sh 8 8 /tmp/m
local U       = require("src.core.util")
local P       = require("src.engine.palette")
local Camera  = require("src.engine.camera")
local Terrain = require("src.world.terrain")
local Water   = require("src.world.water")
local Relic   = require("src.entities.relic")
local TU      = require("src.game.tuning")
local World   = require("src.world.world")
local Tree    = require("src.entities.tree")

local S = {}

local function envN(k, d) return tonumber(os.getenv(k) or "") or d end

function S:enter()
  self.seed = envN("BOTS_SEED", 4242)
  self.mode = (os.getenv("BOTS_RELIC") or "gallery"):lower()
  self.zmul = envN("BOTS_ZOOM", 1)  -- gallery zoom multiplier, for judging geometry
  self.terrain = Terrain.new(self.seed)
  self.terrain:bake()

  -- Mirror World:placeHome exactly. Nothing consumes the world RNG before it,
  -- so a fresh stream on the same seed lands the rig where the game does, and
  -- the "near the valley" placements below are the real ones.
  local rng = U.rng(self.seed)
  local hx, hy = self.terrain:randomLandPoint(rng, { minSoil = 0.4, centerBias = 0.75 })

  if self.mode == "forest" then
    -- The real thing: a real World on this seed, filled with a mature forest
    -- through the same `plantTree` the game uses, so the relic exclusion is
    -- being exercised rather than described. This is the only honest answer to
    -- "are they still there at the ending".
    self.game = World.new(self.seed, { terrain = self.terrain, noPrewarm = false })
    local want = envN("BOTS_TREES", 900)
    for _ = 1, want * 6 do
      if self.game.treeCount >= want then break end
      local px, py = self.terrain:randomLandPoint(self.game.rng, {})
      if px then self.game:plantTree(px, py, "dev") end
    end
    for i = 1, #self.game.trees do
      local t = self.game.trees[i]
      t.growth = 1
      if t.refreshMesh then t:refreshMesh() end
      if t.refreshStage then t:refreshStage(true) end
    end
    self.game:refreshVisibleTrees()
    -- Did the exclusions cost the forest anything? Compare with BOTS_NO_RELICS=1
    -- at the same seed and target. A shortfall here is real; a shortfall only at
    -- an unrealistically high target is the island saturating, not the relics.
    print(string.format("RELICFILL,seed=%d,target=%d,planted=%d",
                        self.seed, want, self.game.treeCount))
    self.world = self.game
  else
    self.world = { seed = self.seed, terrain = self.terrain,
                   homeX = hx, homeY = hy, relics = {} }
    Relic.populate(self.world)
  end

  -- one panel per kind, on the first instance found of it
  local order = { "suit", "wreck", "pallet", "pad", "mast", "hauler", "road" }
  self.panels = {}
  for _, kind in ipairs(order) do
    for i = 1, #self.world.relics do
      local r = self.world.relics[i]
      if r.what == kind then
        self.panels[#self.panels + 1] = { kind, r.x, r.y, TU.camera.zoom * self.zmul, r }
        break
      end
    end
  end
  -- and one wide panel down the road, so the segment joins can be judged
  local first
  for i = 1, #self.world.relics do
    if self.world.relics[i].what == "road" then first = self.world.relics[i] break end
  end
  if first then
    self.panels[#self.panels + 1] = { "road run", first.x, first.y, 0.45 }
  end

  -- What each model actually costs, printed once. A baked shape is a list of
  -- polygons replayed through `lg.polygon`, which LOVE batches, so the number
  -- below is tessellation work done once at load rather than per frame -- and
  -- the whole set is one or two consecutive batches when any of it is on
  -- screen. Printed rather than drawn because it belongs in a report.
  local total = 0
  for kind, k in pairs(Relic.KIND) do
    for v = 1, k.variants do
      local r = Relic.new(0, 0, kind, v, 0, false)
      local sh = r:shape()
      local n = sh and #sh or 0
      total = total + n
      print(string.format("RELICSHAPE,%s,v%d,polys=%d", kind, v, n))
    end
  end
  do
    local c, keys = {}, {}
    for i = 1, #self.world.relics do
      local k = self.world.relics[i].what
      if not c[k] then c[k] = 0 keys[#keys + 1] = k end
      c[k] = c[k] + 1
    end
    table.sort(keys)
    local parts = {}
    for i = 1, #keys do parts[i] = keys[i] .. "=" .. c[keys[i]] end
    print(string.format("RELICSHAPE,TOTAL,baked_polys=%d,instances=%d,%s",
                        total, #self.world.relics, table.concat(parts, ",")))
  end

  -- How much plantable ground the exclusions actually deny. Sampled against the
  -- same two tests `World:plantTree` applies -- on land, and not a barren biome
  -- -- so the denominator is ground a Planter would otherwise have taken.
  do
    local T2 = self.terrain
    local rng2 = U.rng(9001)
    local plantable, denied = 0, 0
    for _ = 1, 40000 do
      local px = rng2:range(0, TU.world.w)
      local py = rng2:range(0, TU.world.h)
      if T2:isLand(px, py) and not TU.tree.barrenBiomes[T2:biomeAt(px, py)] then
        plantable = plantable + 1
        if Relic.blocksPlantingAt(self.world, px, py) then denied = denied + 1 end
      end
    end
    print(string.format("RELICAREA,seed=%d,plantable_samples=%d,denied=%d,pct=%.2f",
                        self.seed, plantable, denied,
                        plantable > 0 and denied / plantable * 100 or 0))
  end

  self.t = 0
end

function S:update(dt) self.t = self.t + dt self.terrain:update(dt) end

-- BOTS_RELIC_HIDE=1 keeps the panels and the cameras exactly where they are and
-- draws everything except the relics. Diffing love.graphics.getStats() between
-- the two is the only contention-free way to price this file: a wall-clock A/B
-- on a shared machine moved 1.0-1.6 s a frame between identical configurations.
local HIDE = (os.getenv("BOTS_RELIC_HIDE") or "") ~= ""

local function drawRelics(cam, list)
  if HIDE then return end
  for i = 1, #list do
    local r = list[i]
    if cam:visible(r.x, r.y, 200) then r:drawShadow() end
  end
  for i = 1, #list do
    local r = list[i]
    if cam:visible(r.x, r.y, 200) then r:draw() end
  end
end

function S:drawGallery()
  local T = self.terrain
  local w, h = love.graphics.getDimensions()
  local cols, rows = 4, 2
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
    if self.game then
      Tree.setViewFromCamera(cam)
      if HIDE then
        local keep = self.game.relics
        self.game.mobileLists[#self.game.mobileLists] = {}
        self.game:draw(cam)
        self.game.mobileLists[#self.game.mobileLists] = keep
      else
        self.game:draw(cam)
      end
    else
      Water.draw(cam, T.time, T.shoreCanvas)
      T:draw(cam)
      T:drawOverlay(cam)
      drawRelics(cam, self.world.relics)
    end
    cam:detach()
    love.graphics.pop()
    love.graphics.setScissor()
    love.graphics.setColor(P.alpha(P.black, 0.6))
    love.graphics.rectangle("fill", px + 4, py + 4, 170, 16)
    love.graphics.setColor(P.ink)
    love.graphics.print(string.format("%s  (%d, %d)", p[1], p[2], p[3]), px + 8, py + 5)
    love.graphics.setColor(P.alpha(P.inkFaint, 0.5))
    love.graphics.rectangle("line", px, py, pw, ph)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

function S:drawMap()
  local T = self.terrain
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(P.black)
  local zoom = math.min(w / TU.world.w, h / TU.world.h)
  local cam = Camera.new(w, h)
  cam.freeBounds = true
  cam.zoom = zoom
  cam:snapTo(TU.world.w / 2, TU.world.h / 2)
  cam:attach()
  Water.draw(cam, T.time, T.shoreCanvas)
  T:draw(cam)
  T:drawOverlay(cam)
  local W = self.world
  -- the exclusion discs, so a heap is obvious
  for i = 1, #W.relics do
    local r = W.relics[i]
    love.graphics.setColor(P.alpha(P.warn, 0.16))
    love.graphics.circle("fill", r.x, r.y, r.noPlant)
  end
  love.graphics.setColor(P.alpha(P.accent, 0.30))
  love.graphics.circle("fill", W.homeX, W.homeY, TU.relic.homeClear)
  cam:detach()

  -- labels in screen space, so they are legible at fit zoom
  local function toS(x, y)
    return (x - TU.world.w / 2) * zoom + w / 2, (y - TU.world.h / 2) * zoom + h / 2
  end
  local sx, sy = toS(W.homeX, W.homeY)
  love.graphics.setColor(P.accent)
  love.graphics.circle("line", sx, sy, 8)
  love.graphics.print("HOME", sx + 10, sy - 6)
  local counts = {}
  for i = 1, #W.relics do
    local r = W.relics[i]
    counts[r.what] = (counts[r.what] or 0) + 1
    local x, y = toS(r.x, r.y)
    local land = T:isLand(r.x, r.y)
    love.graphics.setColor(land and P.warn or P.danger)
    love.graphics.circle("fill", x, y, 3)
    if r.what ~= "road" then
      love.graphics.print(r.what, x + 5, y - 6)
    end
  end
  local line, n = {}, 0
  for kind, c in pairs(counts) do n = n + 1 line[n] = kind .. "=" .. c end
  table.sort(line)
  love.graphics.setColor(P.alpha(P.black, 0.7))
  love.graphics.rectangle("fill", 0, h - 20, w, 20)
  love.graphics.setColor(P.inkDim)
  love.graphics.print(string.format("seed %d   %d relics   %s   (red = off land)",
                      self.seed, #W.relics, table.concat(line, "  ")), 8, h - 17)
  love.graphics.setColor(1, 1, 1, 1)
end

function S:draw()
  local t0 = love.timer.getTime()
  if self.mode == "map" then self:drawMap() else self:drawGallery() end
  local w, h = love.graphics.getDimensions()
  love.graphics.setColor(P.alpha(P.black, 0.66))
  love.graphics.rectangle("fill", 0, 0, 220, 18)
  love.graphics.setColor(P.inkFaint)
  local st = love.graphics.getStats()
  love.graphics.print(string.format("relic frame %.2f ms  draws %d  hide=%s",
                      (love.timer.getTime() - t0) * 1000, st.drawcalls,
                      tostring(HIDE)), 6, 2)
  print(string.format("RELICDRAW,hide=%s,drawcalls=%d,batched=%d,ms=%.2f",
                      tostring(HIDE), st.drawcalls, st.drawcallsbatched or 0,
                      (love.timer.getTime() - t0) * 1000))
  love.graphics.setColor(1, 1, 1, 1)
end

function S:keypressed(k) if k == "escape" then love.event.quit() end end

return S
