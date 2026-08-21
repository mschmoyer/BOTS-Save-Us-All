-- The island and everything on it: entity ownership, spatial queries, the
-- economy, the cycle clock, and the draw orchestration.
local Class    = require("src.core.class")
local U        = require("src.core.util")
local Signal   = require("src.core.signal")
local Timer    = require("src.core.timer")
local Spatial  = require("src.core.spatial")
local P        = require("src.engine.palette")
local J        = require("src.engine.juice")
local Opt      = require("src.core.optional")
local TU       = require("src.game.tuning")
local Chips    = require("src.game.chips")
local Director = require("src.game.director")

local Player     = require("src.entities.player")
local Bot        = require("src.entities.bot")
local Enemy      = require("src.entities.enemy")
local CobaltE    = require("src.entities.cobalt")
local Projectile = require("src.entities.projectile")
local Boss       = require("src.entities.boss")
local HomeRig    = require("src.entities.homerig")

local Terrain  = Opt.require("src.world.terrain")
local Tree     = Opt.require("src.entities.tree")
local Wind     = Opt.require("src.world.wind")
local VFX      = Opt.require("src.engine.vfx")
local Decals   = Opt.require("src.engine.decals")
local Audio    = Opt.require("src.engine.audio")
local Music    = Opt.require("src.engine.music")
local Draw     = Opt.require("src.engine.draw")
local DayNight = Opt.require("src.engine.daynight")
local Lighting = Opt.require("src.engine.lighting")
local Water    = Opt.require("src.world.water")
local Weather  = require("src.world.weather")

local World = Class("World")

------------------------------------------------------------------------- setup
function World:init(seed, opts)
  opts = opts or {}
  self.seed = seed or 1337
  self.rng = U.rng(self.seed)
  self.time = 0
  self.opts = opts

  self.terrain = Terrain.new and Terrain.new(self.seed) or nil
  if self.terrain and self.terrain.bake then self.terrain:bake() end
  if Decals.init then Decals.init(TU.world.w, TU.world.h) end
  self.decals = Decals

  self.trees, self.bots, self.enemies = {}, {}, {}
  self.cobalts, self.projectiles = {}, {}
  self.speeches = {}
  self.drawList = {}

  self.hTree   = Spatial.new(140)
  self.hBot    = Spatial.new(140)
  self.hEnemy  = Spatial.new(140)
  self.hCobalt = Spatial.new(160)

  self.cobalt      = TU.cobalt.startingCobalt
  self.treeCount   = 0
  self.o2          = 0
  self.o2Debt      = 0
  self.chips       = Chips.new(self)
  self.director    = Director.new(self)

  self.cycle       = 1
  self.phase       = "day"
  self.phaseT      = 0
  self.phaseDur    = TU.cycle.dayLen[1]
  self.cutscene    = false
  self.stats       = { planted = 0, lost = 0, botsLost = 0, botsBuilt = 0, killed = 0,
                       cobaltMined = 0, rescued = 0 }
  self.allLostNames = {}       -- never cleared: the ending reads the whole run
  self.dawnReport  = nil

  if Tree.prewarm then pcall(Tree.prewarm) end
  if Water.load then pcall(Water.load) end

  self.centerX, self.centerY = TU.world.w / 2, TU.world.h / 2
  self:placeHome()
  self:seedCobalt()

  Signal.emit("world:ready", self)
end

function World:placeHome()
  local x, y = self.centerX, self.centerY
  if self.terrain and self.terrain.randomLandPoint then
    local hx, hy = self.terrain:randomLandPoint(self.rng, { minSoil = 0.4, centerBias = 0.75 })
    if hx then x, y = hx, hy end
  end
  self.homeX, self.homeY = x, y
  self.rig = HomeRig.new(x, y, self)
  self.player = Player.new(x, y + 64, self)
end

function World:seedCobalt()
  for _ = 1, TU.cobalt.nodesAtStart do self:spawnCobaltNode() end
end

function World:spawnCobaltNode()
  if #self.cobalts >= TU.cobalt.nodeMax + 40 then return end
  local x, y = self.centerX, self.centerY
  if self.terrain and self.terrain.randomLandPoint then
    local px, py = self.terrain:randomLandPoint(self.rng, {
      awayFrom = { x = self.homeX, y = self.homeY, r = TU.world.homeRadius },
    })
    if px then x, y = px, py end
  else
    x, y = self.rng:range(200, TU.world.w - 200), self.rng:range(200, TU.world.h - 200)
  end
  local c = CobaltE.new(x, y, self, self.rng, true)
  c.left = math.floor(TU.cobalt.nodeYield * self.chips:get("nodeYield", 1))
  self:addEntity(self.cobalts, self.hCobalt, c)
  return c
end

function World:scheduleNodeRespawn()
  local t = TU.cobalt.nodeRespawn * self.chips:get("nodeRespawn", 1)
  Timer.global:after(t, function()
    if self.alive ~= false then self:spawnCobaltNode() end
  end)
end

---------------------------------------------------------------- entity plumbing
function World:addEntity(list, hash, e)
  list[#list + 1] = e
  if hash then hash:insert(e) end
  return e
end

local function sweep(list, hash, dt)
  local n = #list
  local w = 1
  for i = 1, n do
    local e = list[i]
    if e.alive then
      if e.update then e:update(dt) end
    end
    if e.alive then
      if hash then hash:update(e) end
      list[w] = e w = w + 1
    else
      if hash then hash:remove(e) end
    end
  end
  for i = w, n do list[i] = nil end
end

------------------------------------------------------------------------ queries
function World:nearestTree(x, y, r, unmarkedOnly)
  return self.hTree:nearest(x, y, r, function(t)
    if not t.alive or t.stage == "dead" then return false end
    if unmarkedOnly and t.markedBy and t.markedBy.alive then return false end
    return true
  end)
end

function World:nearestBot(x, y, r, filter)
  return self.hBot:nearest(x, y, r, function(b)
    if b.state == "dead" or b.state == "down" or not b.alive then return false end
    if filter and not filter(b) then return false end
    return true
  end)
end

function World:nearestDownedBot(x, y, r)
  return self.hBot:nearest(x, y, r, function(b)
    return b.alive and b.state == "down" and not b.carried
  end)
end

function World:nearestEnemy(x, y, r, filter)
  return self.hEnemy:nearest(x, y, r, function(e)
    if not e.alive or e.fleeing then return false end
    if filter and not filter(e) then return false end
    return true
  end)
end

function World:nearestCobalt(x, y, r)
  return self.hCobalt:nearest(x, y, r, function(c) return c.alive and c.node end)
end

function World:enemyCount() return #self.enemies end
function World:botCount()
  local n = 0
  for i = 1, #self.bots do
    local b = self.bots[i]
    if b.alive and b.state ~= "dead" then n = n + 1 end
  end
  return n
end

--- Beacon field helpers, used by bots and enemies.
function World:beaconAt(x, y)
  local b = self.hBot:nearest(x, y, TU.bots.beacon.radius_field * self.chips:get("beaconRadius", 1),
    function(bb) return bb.type == "beacon" and bb.state == "work" end)
  return b
end

function World:beaconBoostAt(x, y)
  return self:beaconAt(x, y) and TU.bots.beacon.growthBonus or 0
end

function World:beaconSlowAt(x, y)
  return self:beaconAt(x, y) and TU.bots.beacon.slow or 0
end

--------------------------------------------------------------------- economy
function World:spendCobalt(n)
  if n <= 0 then return true end
  if self.cobalt < n then return false end
  self.cobalt = self.cobalt - n
  Signal.emit("cobalt:spent", n, self.cobalt)
  return true
end

function World:addCobalt(n, x, y)
  self.cobalt = self.cobalt + n
  self.stats.cobaltMined = self.stats.cobaltMined + n
  Signal.emit("cobalt:gained", n, self.cobalt, x, y)
end

function World:bankCobalt(n, x, y)
  self:addCobalt(n, x, y)
  self.pickupStreak = (self.pickupStreak or 0) + 1
  self.pickupStreakT = 1.4
  Audio.play(self.pickupStreak > 2 and "pickup_streak" or "pickup",
             { pitch = 1 + math.min(self.pickupStreak, 8) * 0.045, x = x, y = y })
end

function World:loseCobaltFraction(f)
  local lost = math.floor(self.cobalt * f)
  self.cobalt = self.cobalt - lost
  Signal.emit("cobalt:lost", lost)
end

--- Take one chunk from a deposit near a point. Used by builders and harvesters
--- (which keep the chunk themselves) and by the player, who gets a loose chunk
--- that flies back to them.
function World:consumeCobaltNear(x, y, r, dropLoose)
  local c = self.hCobalt:nearest(x, y, r, function(cc) return cc.alive and cc.node end)
  if not c or not c:mine() then return false end
  if dropLoose then
    local loose = CobaltE.new(c.x, c.y, self, self.rng, false)
    loose:push(c.x - x, c.y - y, 140)
    self:addEntity(self.cobalts, self.hCobalt, loose)
  end
  return true
end

----------------------------------------------------------------------- actions
function World:plantTree(x, y, by)
  if self.treeCount >= TU.tree.maxTrees then return false end
  if self.terrain and self.terrain.isLand and not self.terrain:isLand(x, y) then return false end
  if self.terrain and self.terrain.biomeAt and not self.chips:has("pioneer") then
    if self.terrain:biomeAt(x, y) == "scar" then return false end
  end
  local gap = TU.tree.spreadReject * 0.74
  if self.hTree:nearest(x, y, gap, function(t) return t.alive end) then return false end

  local oldGrowth = self.chips:has("oldGrowth")
  local t = Tree.new and Tree.new(x, y, self.rng:int(1, 100000), {
    startGrown = (by == "player" and self.chips:has("greenThumb")) and 0.5 or nil,
  }) or nil
  if not t then return false end
  t.world = self
  t.canElder = oldGrowth
  self:addEntity(self.trees, self.hTree, t)
  self.treeCount = self.treeCount + 1
  self.stats.planted = self.stats.planted + 1

  VFX.emit("plant_burst", x, y)
  Audio.play("plant", { x = x, y = y })
  Audio.setForestProgress(U.saturate(self.treeCount / 420))
  Signal.emit("tree:planted", t, by)
  return true
end

function World:fellTree(t, by)
  if not t.alive then return end
  if t.kill then t:kill("chewed") else t.alive = false end
  self.treeCount = math.max(0, self.treeCount - 1)
  self.stats.lost = self.stats.lost + 1
  Audio.play("tree_fall", { x = t.x, y = t.y })
  VFX.emit("leaf_litter", t.x, t.y, { count = 14, power = 1.4 })
  if self.decals and self.decals.add then self.decals.add("stump", t.x, t.y) end
  J.shake(0.16)
  Signal.emit("tree:lost", t, by)
end

--- How many of a type are standing right now.
function World:countBots(botType)
  local n = 0
  for i = 1, #self.bots do
    local b = self.bots[i]
    if b.alive and b.state ~= "dead" and b.type == botType then n = n + 1 end
  end
  return n
end

--- The price of the next bot of this type, with escalation and chips applied.
function World:botCost(botType)
  local def = TU.bots[botType]
  if not def then return 0 end
  local owned = self:countBots(botType)
  local mul = math.min(1 + owned * TU.bots.costGrowth, TU.bots.costGrowthMax)
  return math.ceil(def.cost * mul * self.chips:get("botCost", 1))
end

function World:spawnBot(x, y, botType, free)
  local def = TU.bots[botType]
  if not def then return false end
  if self.terrain and self.terrain.isLand and not self.terrain:isLand(x, y) then
    if self.terrain.nearestLand then
      local lx, ly = self.terrain:nearestLand(x, y)
      if lx then x, y = lx, ly else return false end
    else return false end
  end
  if not free then
    local cost = self:botCost(botType)
    if not self:spendCobalt(cost) then
      Audio.play("ui_back")
      Signal.emit("ui:denied", "cobalt")
      return false
    end
  end
  local b = Bot.new(x, y, botType, self, self.rng)
  b.maxHp = b.maxHp + self.chips:get("botHp", 0)
  b.hp = b.maxHp
  self:addEntity(self.bots, self.hBot, b)
  self.stats.botsBuilt = self.stats.botsBuilt + 1
  if self.phase == "extraction" and self.boss and self.boss.alive and self.botsRebelled then
    b:rebel(self.boss)
  end
  Signal.emit("bot:built", b)
  return b
end

function World:spawnEnemyAt(x, y, kind)
  if self.terrain and self.terrain.nearestLand then
    local lx, ly = self.terrain:nearestLand(x, y)
    if lx then x, y = lx, ly end
  end
  local e = Enemy.new(x, y, kind, self, self.rng)
  self:addEntity(self.enemies, self.hEnemy, e)
  return e
end

function World:spawnDart(x, y, angle, speed, damage, owner)
  local p = Projectile.new(x, y, "dart", self)
  p:setDart(angle, speed, damage, owner)
  self.projectiles[#self.projectiles + 1] = p
end

function World:spawnAcid(x, y, tx, ty, speed, owner)
  local p = Projectile.new(x, y, "acid", self)
  p:setAcid(tx, ty, speed, owner)
  self.projectiles[#self.projectiles + 1] = p
end

function World:acidSplash(x, y)
  if self.decals and self.decals.add then self.decals.add("acid", x, y) end
  local r = 46
  self.hTree:each(x, y, r, function(t)
    if t.alive and t.stage == "sapling" and not self.chips:has("hardBark") then
      self:fellTree(t, "acid")
    end
  end)
  self.hBot:each(x, y, r, function(b)
    if b.alive and b.state ~= "down" and U.dist(b.x, b.y, x, y) < r then b:damage(1, x, y) end
  end)
  local p = self.player
  if p and U.dist(p.x, p.y, x, y) < r then p:damage(1, x, y) end
end

function World:spawnSporeCloud(x, y)
  VFX.emit("blight_spore", x, y, { count = 18, power = 1.4 })
  Timer.global:every(0.25, function()
    self.hEnemy:each(x, y, 90, function(e)
      if e.alive and U.dist(e.x, e.y, x, y) < 90 then e:damage(1, x, y) end
    end)
  end, 6)
end

--- Cone shove. Returns how many things it moved, so the caller can juice it.
function World:coneShove(x, y, angle, half, range, force, damage, stun)
  local hits = 0
  local pin = self.chips:has("pinBreaker")
  self.hEnemy:each(x, y, range, function(e)
    if not e.alive or e.fleeing then return end
    if not U.inCone(e.x, e.y, x, y, angle, half, range + e.radius) then return end
    local dmg = damage
    if self.chips:has("brittle") and e.stun > 0 then dmg = dmg * 2 end
    local moved
    if pin and e.def.armoured and e.type ~= "maw" then
      e:push(e.x - x, e.y - y, force * 0.6)
      e.stun = math.max(e.stun, stun * 0.6)
      e:damage(dmg, x, y)
      moved = true
    else
      moved = e:shove(e.x - x, e.y - y, force, dmg, stun)
    end
    if moved then hits = hits + 1 end
  end)
  -- shoving also knocks cobalt loose from deposits: the verb does double duty
  self.hCobalt:each(x, y, range, function(c)
    if c.alive and c.node and U.inCone(c.x, c.y, x, y, angle, half, range + c.radius) then
      if c:mine() then
        local loose = CobaltE.new(c.x, c.y, self, self.rng, false)
        loose:push(c.x - x, c.y - y, 180)
        self:addEntity(self.cobalts, self.hCobalt, loose)
        hits = hits + 1
      end
    end
  end)
  if hits > 0 and self.chips:has("recoil") then self:addCobalt(1, x, y) end
  return hits
end

function World:areaShove(x, y, radius, force, damage, stun, includeBots)
  local hits = 0
  self.hEnemy:each(x, y, radius, function(e)
    if not e.alive or e.fleeing then return end
    if U.dist2(e.x, e.y, x, y) > radius * radius then return end
    if e:shove(e.x - x, e.y - y, force, damage, stun) then hits = hits + 1 end
  end)
  if includeBots then
    self.hBot:each(x, y, radius, function(b)
      if b.alive and not b.static and U.dist2(b.x, b.y, x, y) <= radius * radius then
        b:push(b.x - x, b.y - y, force * 0.5)
      end
    end)
  end
  return hits
end

function World:hitEnemyAt(x, y, r, damage, vx, vy)
  local e = self.hEnemy:nearest(x, y, r, function(ee) return ee.alive and not ee.fleeing end)
  if not e then return false end
  local dmg = damage
  if self.chips:has("brittle") and e.stun > 0 then dmg = dmg * 2 end
  e:damage(dmg, x - (vx or 0) * 0.01, y - (vy or 0) * 0.01)
  return true
end

function World:beamSweep(x, y, angle, len, dt)
  local ex, ey = x + math.cos(angle) * len, y + math.sin(angle) * len
  local step = 90
  self.beamFrame = (self.beamFrame or 0) + 1
  local frame = self.beamFrame
  for d = 60, len, step do
    local px, py = x + math.cos(angle) * d, y + math.sin(angle) * d
    self.hTree:each(px, py, 46, function(t)
      -- overlapping samples must not burn the same tree several times a frame
      if t.alive and t.burnFrame ~= frame
         and U.pointSegDist2(t.x, t.y, x, y, ex, ey) < 34 * 34 then
        t.burnFrame = frame
        t.burn = (t.burn or 0) + dt
        if t.burn > 1.8 then self:fellTree(t, "beam") end
      end
    end)
    self.hBot:each(px, py, 40, function(b)
      if b.alive and b.state ~= "down" and U.pointSegDist2(b.x, b.y, x, y, ex, ey) < 40 * 40 then
        b.burn = (b.burn or 0) + dt
        if b.burn > 0.5 then b.burn = 0 b:damage(1, x, y) end
      end
    end)
  end
  local p = self.player
  if p and p.state == "alive" and U.pointSegDist2(p.x, p.y, x, y, ex, ey) < 34 * 34 then
    p:damage(1, x, y)
  end
end

function World:dropCarried(player)
  local b = player.carrying
  if not b then return end
  player.carrying = nil
  b.carried = false
  b.x, b.y = player.x, player.y + 18
  if self:beaconAt(b.x, b.y) then
    b:revive()
    self.stats.rescued = self.stats.rescued + 1
  end
end

--- Siphons do not remove oxygen directly - they add a debt against the forest's
--- reading, so killing them restores what they took.
function World:drainO2(rate, dt)
  self.o2Debt = math.min(TU.o2.debtCap, (self.o2Debt or 0) + rate * dt)
end

local SPEECH_MAX = 3
function World:speak(who, line)
  -- A forest of forty bots all talking is noise. Keep a few, prefer the ones
  -- nearest the player, and never let the same bot double up.
  for i = #self.speeches, 1, -1 do
    if self.speeches[i].who == who then table.remove(self.speeches, i) end
  end
  if #self.speeches >= SPEECH_MAX then
    local p = self.player
    local worst, worstD = nil, -1
    for i = 1, #self.speeches do
      local s = self.speeches[i]
      local d = p and U.dist2(s.who.x, s.who.y, p.x, p.y) or 0
      if d > worstD then worst, worstD = i, d end
    end
    local mine = p and U.dist2(who.x, who.y, p.x, p.y) or 0
    if worstD <= mine then return end
    table.remove(self.speeches, worst)
  end
  self.speeches[#self.speeches + 1] = { who = who, line = line, t = 0, dur = 3.2 }
  Audio.play("bot_chatter", { volume = 0.35, pitch = 0.9 + (who.serial % 7) * 0.04,
                              x = who.x, y = who.y })
end

--------------------------------------------------------------------- the clock
local PHASE_ORDER = { day = "dusk", dusk = "night", night = "dawn", dawn = "day" }

function World:phaseLength(phase, cycle)
  cycle = math.min(cycle, TU.cycle.count)
  if phase == "day" then return TU.cycle.dayLen[cycle] end
  if phase == "dusk" then return TU.cycle.duskLen end
  if phase == "night" then return TU.cycle.nightLen[cycle] end
  return 0
end

function World:setPhase(phase)
  local prev = self.phase
  -- Dawn does not tick: it waits for the player to finish the draft, and the
  -- draft returning to day is what actually advances the cycle.
  if phase == "day" and prev == "dawn" then
    self.cycle = self.cycle + 1
    if self.cycle > TU.cycle.count or self.o2 >= TU.o2.target - 0.5 then
      self:beginExtraction()
      return
    end
  end
  self.phase = phase
  self.phaseT = 0
  self.phaseDur = self:phaseLength(phase, self.cycle)

  if phase == "dusk" then
    Audio.play("wave_start")
    Music.setState("dusk")
    Signal.emit("phase:dusk", self.cycle, self.director:sideVector())
  elseif phase == "night" then
    self.director:beginNight(self.cycle, self.phaseDur)
    Music.setState("night")
    Signal.emit("phase:night", self.cycle)
  elseif phase == "dawn" then
    for i = 1, #self.enemies do self.enemies[i]:flee() end
    Audio.play("dawn")
    Music.setState("draft")
    self:buildDawnReport()
    Signal.emit("phase:dawn", self.cycle, self.dawnReport)
  elseif phase == "day" then
    Music.setState("day")
    Signal.emit("phase:day", self.cycle)
  end
end

function World:advancePhase()
  self:setPhase(PHASE_ORDER[self.phase])
end

function World:buildDawnReport()
  local r = {
    cycle = self.cycle,
    planted = self.stats.planted - (self.lastStats and self.lastStats.planted or 0),
    lost = self.stats.lost - (self.lastStats and self.lastStats.lost or 0),
    botsLost = self.stats.botsLost - (self.lastStats and self.lastStats.botsLost or 0),
    killed = self.stats.killed - (self.lastStats and self.lastStats.killed or 0),
    o2 = self.o2,
    o2Delta = self.o2 - (self.lastO2 or 0),
    names = self.lostNames or {},
    trees = self.treeCount,
  }
  self.lastStats = {}
  for k, v in pairs(self.stats) do self.lastStats[k] = v end
  self.lastO2 = self.o2
  self.lostNames = {}
  self.dawnReport = r
  if self.chips:has("surplus") then self:addCobalt(math.floor(self.treeCount / 4)) end
  return r
end

function World:beginExtraction()
  self.phase = "extraction"
  self.phaseT = 0
  self.extractionStage = "arrive"
  Music.setState("boss")
  local x, y = self.homeX + self.rng:range(-500, 500), self.homeY + self.rng:range(-500, 500)
  if self.terrain and self.terrain.nearestLand then
    local lx, ly = self.terrain:nearestLand(x, y)
    if lx then x, y = lx, ly end
  end
  self.boss = Boss.new(x, y, self, self:botCount())
  -- the boss lives in the enemy hash so shoves, pulses and sentry darts find it
  self.hEnemy:insert(self.boss)
  for i = 1, #self.bots do
    local b = self.bots[i]
    if b.state == "work" then b.mood = "confused" end
  end
  Audio.play("rift_open")
  J.shake(1)
  Signal.emit("phase:extraction", self.boss)

  Timer.global:after(TU.boss.rebelDelay, function()
    if not self.boss or not self.boss.alive then return end
    self.botsRebelled = true
    for i = 1, #self.bots do
      local b = self.bots[i]
      if b.state == "work" or b.mood == "confused" then b:rebel(self.boss) end
    end
    Signal.emit("bots:rebel")
  end)
end

------------------------------------------------------------------------ update
function World:update(dt)
  self.time = self.time + dt
  if Wind.update then Wind.update(dt) end
  Weather.update(dt, self)
  self.raining = Weather.isRaining()
  if self.terrain and self.terrain.update then self.terrain:update(dt) end

  if self.phase ~= "extraction" and self.phase ~= "ending" and not self.cutscene then
    self.phaseT = self.phaseT + dt
    if self.phaseDur > 0 and self.phaseT >= self.phaseDur then self:advancePhase() end
  end

  if self.phase == "night" then self.director:update(dt) end

  self:updateOxygen(dt)

  if self.rig then self.rig:update(dt) end
  if self.player then self.player:update(dt, self.camera) end
  sweep(self.trees, self.hTree, dt)
  sweep(self.bots, self.hBot, dt)
  sweep(self.enemies, self.hEnemy, dt)
  sweep(self.cobalts, self.hCobalt, dt)
  sweep(self.projectiles, nil, dt)
  if self.boss then
    if self.boss.alive then
      self.boss:update(dt)
      self.hEnemy:update(self.boss)
    elseif self.boss._unhashed ~= true then
      self.boss._unhashed = true
      self.hEnemy:remove(self.boss)
    end
  end

  -- recount trees after the sweep so the HUD never lies
  local n = 0
  for i = 1, #self.trees do if self.trees[i].alive then n = n + 1 end end
  self.treeCount = n

  self:updateSpread(dt)

  -- chorus chip: bots near friends work faster
  if self.chips:has("chorus") then
    for i = 1, #self.bots do
      local b = self.bots[i]
      local c = 0
      self.hBot:each(b.x, b.y, 120, function(o) if o ~= b and o.alive then c = c + 1 end end)
      b.chorus = c >= 2
    end
  end

  -- speech bubbles
  for i = #self.speeches, 1, -1 do
    local s = self.speeches[i]
    s.t = s.t + dt
    if s.t >= s.dur or not s.who.alive then table.remove(self.speeches, i) end
  end

  if self.pickupStreakT then
    self.pickupStreakT = self.pickupStreakT - dt
    if self.pickupStreakT <= 0 then self.pickupStreak = 0 self.pickupStreakT = nil end
  end

  -- keep enough cobalt on the island that the economy is a route-planning
  -- problem rather than a scarcity lottery
  self.nodeTopUp = (self.nodeTopUp or 0) - dt
  if self.nodeTopUp <= 0 then
    self.nodeTopUp = 3
    local nodes = 0
    for i = 1, #self.cobalts do if self.cobalts[i].node then nodes = nodes + 1 end end
    if nodes < TU.cobalt.nodeFloor then self:spawnCobaltNode() end
  end

  if Decals.update then Decals.update(dt) end
  if VFX.update then VFX.update(dt) end
  if Music.setIntensity then Music.setIntensity(self:threat()) end
  if Music.setO2 then Music.setO2(self.o2 / TU.o2.target) end
end

--- Oxygen reads the standing forest. Saplings count a little, elders count
--- double, and siphons apply a debt that bleeds off once they are driven away.
local O2W = TU.o2.weight
function World:updateOxygen(dt)
  local mature, elders, points = 0, 0, 0
  for i = 1, #self.trees do
    local t = self.trees[i]
    if t.alive and t.stage ~= "dead" and t.stage ~= "dying" then
      local s = t.stage
      if s == "elder" then elders = elders + 1 points = points + O2W.elder
      elseif s == "mature" then mature = mature + 1 points = points + O2W.mature
      elseif s == "young" then points = points + O2W.young
      else points = points + O2W.sapling end
    end
  end
  self.matureTrees, self.elderTrees, self.forestPoints = mature, elders, points

  self.o2Debt = math.max(0, (self.o2Debt or 0) - TU.o2.debtRecover * dt)

  local ideal = TU.o2.target * U.saturate(points / TU.o2.fullForest) - self.o2Debt
  ideal = U.clamp(ideal, 0, TU.o2.target)
  local rate = ideal > self.o2 and TU.o2.rise or TU.o2.fall
  self.o2 = U.damp(self.o2, ideal, rate, dt)
  self.o2Ideal = ideal

  local step = math.floor(self.o2 / 25)
  if step > (self.o2Step or 0) and step > 0 then
    self.o2Step = step
    Audio.play("o2_milestone")
    Signal.emit("o2:milestone", step * 25)
  end

  -- Filling the sky is the win condition, not surviving a fixed number of
  -- nights: the moment the air is breathable, they come to take it.
  if self.o2 >= TU.o2.target - 0.3 and self.phase ~= "extraction"
     and self.phase ~= "ending" then
    self:beginExtraction()
  end
end

--- Forests compound: mature trees drop seedlings nearby. Amortised over frames
--- so a thousand trees cost nothing, and driven by absolute world time so the
--- rate is identical however the slice lands.
function World:updateSpread(dt)
  local trees = self.trees
  local n = #trees
  if n == 0 then return end
  local budget = math.min(n, 48)
  local i = self.spreadCursor or 1
  local rng = self.rng
  local rainMul = Weather.growthBonus(self.chips:has("rainMemory"))
  local chipMul = self.chips:get("spreadRate", 1)
  local growMul = self.chips:get("growRate", 1)

  for _ = 1, budget do
    i = i + 1
    if i > n then i = 1 end
    local t = trees[i]
    if t and t.alive then
      -- growth speed: beacons, rain and chips all feed the same multiplier
      local m = growMul * rainMul * (1 + self:beaconBoostAt(t.x, t.y))
      if self.chips:has("canopy") then
        local near = 0
        self.hTree:each(t.x, t.y, 90, function(o) if o ~= t and o.alive then near = near + 1 end end)
        if near >= 3 then m = m * 1.35 end
      end
      t.growthMul = m

      if t.stage == "mature" or t.stage == "elder" then
        if not t.nextSpread then
          t.nextSpread = self.time + rng:range(TU.tree.spreadEvery[1], TU.tree.spreadEvery[2])
        elseif self.time >= t.nextSpread then
          local a = rng:angle()
          local d = rng:range(TU.tree.spreadRange[1], TU.tree.spreadRange[2])
          local ok = self:plantTree(t.x + math.cos(a) * d, t.y + math.sin(a) * d, t)
          local period = rng:range(TU.tree.spreadEvery[1], TU.tree.spreadEvery[2])
          if not ok then period = period * 0.35 end
          t.nextSpread = self.time + period / (chipMul * rainMul)
        end
      end
    end
  end
  self.spreadCursor = i
end

--- 0..1 sense of danger, used to drive the music and the grade.
function World:threat()
  local n = #self.enemies
  local close = 0
  local p = self.player
  if p then
    self.hEnemy:each(p.x, p.y, 420, function(e) if e.alive then close = close + 1 end end)
  end
  return U.saturate(n / 22 * 0.6 + close / 8 * 0.4)
end

-------------------------------------------------------------------------- draw
local function addDraw(list, e) list[#list + 1] = e end

--- Depth key. Entities may supply `sortKey`; anything else sorts on its feet.
local function depthOf(e)
  if e.sortKey then return e:sortKey() end
  local z = e.z
  return e.y + (type(z) == "number" and z or 0)
end
local function bySortKey(a, b) return depthOf(a) < depthOf(b) end

function World:draw(camera)
  self.camera = camera
  local g = love.graphics

  if Tree.setViewFromCamera then Tree.setViewFromCamera(camera) end

  -- sea first, then the island on top of it, then the foam that laps the shore
  if Water.draw and self.terrain then
    Water.setTint(DayNight.fogColor, (DayNight.fogStrength or 0) * 0.8)
    Water.setSky(DayNight.skyTint)
    Water.draw(camera, self.time, self.terrain.shoreCanvas)
  end
  if self.terrain and self.terrain.draw then self.terrain:draw(camera) end
  if self.terrain and self.terrain.drawOverlay then self.terrain:drawOverlay(camera) end
  if Decals.draw then Decals.draw(camera) end

  -- shadow pass: everything's contact shadow lands on the ground, under all art
  local sunA = DayNight.sunAngle or 0.9
  local sunL = DayNight.sunLength or 0.6
  for i = 1, #self.trees do
    local t = self.trees[i]
    if t.alive and camera:visible(t.x, t.y, 220) and t.drawShadow then t:drawShadow(sunA, sunL) end
  end
  if Tree.endPass then Tree.endPass() end
  local lists = { self.bots, self.enemies, self.cobalts, self.projectiles }
  for l = 1, #lists do
    local list = lists[l]
    for i = 1, #list do
      local e = list[i]
      if e.alive and e.drawShadow and camera:visible(e.x, e.y, 120) then e:drawShadow() end
    end
  end
  if self.rig then self.rig:drawShadow() end
  if self.player then self.player:drawShadow() end
  if self.boss and self.boss.alive then self.boss:drawShadow() end

  if VFX.draw then VFX.draw("ground") end

  -- depth-sorted entity pass
  local dl = self.drawList
  for i = #dl, 1, -1 do dl[i] = nil end
  for i = 1, #self.trees do
    local t = self.trees[i]
    if t.alive and camera:visible(t.x, t.y, 240) then t.isTree = true addDraw(dl, t) end
  end
  for l = 1, #lists do
    local list = lists[l]
    for i = 1, #list do
      local e = list[i]
      if e.alive and camera:visible(e.x, e.y, 140) then addDraw(dl, e) end
    end
  end
  if self.rig then addDraw(dl, self.rig) end
  if self.player then addDraw(dl, self.player) end
  if self.boss and self.boss.alive then addDraw(dl, self.boss) end
  table.sort(dl, bySortKey)

  local sx, sy = math.cos(sunA), math.sin(sunA)
  for i = 1, #dl do
    local e = dl[i]
    if e.isTree then e:draw(sx, sy) else e:draw() end
  end
  if Tree.endPass then Tree.endPass() end

  if VFX.draw then VFX.draw("world") end
  if VFX.draw then VFX.draw("additive") end

  self:drawSpeech()
end

--- A small speech bubble above a bot. Self-contained so the world never depends
--- on the HUD being loaded.
local bubbleFont
function World:drawBubble(x, y, text, a)
  if a <= 0.01 then return end
  bubbleFont = bubbleFont or love.graphics.newFont(12)
  local g = love.graphics
  local prevFont = g.getFont()
  g.setFont(bubbleFont)
  local tw = bubbleFont:getWidth(text)
  local th = bubbleFont:getHeight()
  local padX, padY = 9, 5
  local w, h = tw + padX * 2, th + padY * 2
  local bx, by = x - w / 2, y - h

  g.setColor(P.black[1], P.black[2], P.black[3], 0.72 * a)
  if Draw.roundRect then Draw.roundRect("fill", bx, by, w, h, 6)
  else g.rectangle("fill", bx, by, w, h, 6) end
  g.polygon("fill", x - 5, by + h - 1, x + 5, by + h - 1, x, by + h + 6)

  g.setColor(P.inkDim[1], P.inkDim[2], P.inkDim[3], 0.25 * a)
  if Draw.roundRect then Draw.roundRect("line", bx, by, w, h, 6)
  else g.rectangle("line", bx, by, w, h, 6) end

  g.setColor(P.ink[1], P.ink[2], P.ink[3], 0.95 * a)
  g.print(text, bx + padX, by + padY)
  g.setColor(1, 1, 1, 1)
  g.setFont(prevFont)
end

function World:drawSpeech()
  for i = 1, #self.speeches do
    local s = self.speeches[i]
    local a = U.saturate(math.min(s.t * 4, (s.dur - s.t) * 2))
    local who = s.who
    if who.alive and self.camera:visible(who.x, who.y, 60) then
      local rise = U.smoothstep(0, 0.35, s.t) * 6
      self:drawBubble(who.x, who.y - (who.radius or 12) * 2.4 - rise, s.line, a)
    end
  end
end

--- Register every light in the world with the lighting system.
function World:emitLights(Light)
  if self.player and self.player.emitLight then self.player:emitLight(Light) end
  if self.rig then self.rig:emitLight(Light) end
  local cam = self.camera
  local lists = { self.bots, self.enemies, self.cobalts }
  for l = 1, #lists do
    local list = lists[l]
    for i = 1, #list do
      local e = list[i]
      if e.alive and e.emitLight and (not cam or cam:visible(e.x, e.y, 300)) then
        e:emitLight(Light)
      end
    end
  end
  if self.boss and self.boss.alive and self.boss.emitLight then self.boss:emitLight(Light) end
end

------------------------------------------------------------------------ signals
Signal.on("bot:lost", function(bot, peaceful)
  local w = bot.world
  if not w or peaceful then return end
  w.stats.botsLost = w.stats.botsLost + 1
  w.lostNames = w.lostNames or {}
  w.lostNames[#w.lostNames + 1] = bot.name
  w.allLostNames = w.allLostNames or {}
  w.allLostNames[#w.allLostNames + 1] = { name = bot.name, type = bot.type,
                                          cycle = w.cycle, trait = bot.trait }
  if w.chips:has("salvage") then
    w:addCobalt(math.floor(bot.def.cost * 0.5), bot.x, bot.y)
  end
end)

-- Old Growth retro-fits the forest you already have; that is what makes it a
-- late-draft prize rather than a slow burn.
Signal.on("chip:added", function(chip)
  if chip.id ~= "oldGrowth" then return end
  local w = chip._world
  if not w then return end
  for i = 1, #w.trees do w.trees[i].canElder = true end
end)

Signal.on("enemy:killed", function(e)
  local w = e.world
  if w then w.stats.killed = w.stats.killed + 1 end
end)

return World
