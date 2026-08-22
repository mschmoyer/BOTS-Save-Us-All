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
local Names    = require("src.game.names")
local Save     = require("src.game.save")
local Director = require("src.game.director")
local Warmup   = require("src.game.warmup")

local Player     = require("src.entities.player")
local Bot        = require("src.entities.bot")
local Enemy      = require("src.entities.enemy")
local CobaltE    = require("src.entities.cobalt")
local Projectile = require("src.entities.projectile")
local Boss       = require("src.entities.boss")
local HomeRig    = require("src.entities.homerig")
local Relic      = require("src.entities.relic")

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

  -- The loading screen bakes the terrain itself, a slice at a time, and hands
  -- the finished object in. Without one (headless captures, demo scenes) we
  -- still build it here, synchronously.
  self.terrain = opts.terrain or (Terrain.new and Terrain.new(self.seed) or nil)
  if self.terrain and self.terrain.bake and not self.terrain.baked then
    self.terrain:bake()
  end
  Warmup.mark(opts.terrain and "terrain(given)" or "terrain(built)")
  if Decals.init then Decals.init(TU.world.w, TU.world.h) end
  Warmup.mark("decals")
  self.decals = Decals

  self.trees, self.bots, self.enemies = {}, {}, {}
  self.cobalts, self.projectiles = {}, {}
  self.speeches = {}
  self.drawList = {}
  -- Everything that moves, in the order the draw passes want it. The four
  -- lists are created here and compacted in place forever after, so this array
  -- of them is built once instead of twice a frame -- `World:draw` and
  -- `World:emitLights` each made their own, and a table a frame is a table a
  -- frame.
  -- Relics are static, non-interactive world objects (src/entities/relic.lua).
  -- They ride the mobile lists purely for the draw and shadow passes and the
  -- view cull those already do; they are never swept, never tick, and emit no
  -- light, so nothing else in this file has to know about them.
  self.relics = {}
  self.mobileLists = { self.bots, self.enemies, self.cobalts, self.projectiles,
                       self.relics }
  -- the same trees as `self.trees`, in depth order, and the slice of that the
  -- camera can see: see World:addTree
  self.treesZ, self.visTrees = {}, {}

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
  -- The largest crew of each type this run has fielded. It, and not the crew
  -- standing right now, is what the price of the next one is read off; see
  -- World:botCost for why.
  self.peakBots    = {}
  self.dawnReport  = nil

  if Tree.prewarm and not opts.noPrewarm then pcall(Tree.prewarm) end
  Warmup.mark("trees")
  if Water.load then pcall(Water.load) end
  Warmup.mark("water")

  -- how much forest this particular island can hold, which is what 100% means
  self.fullForest = TU.o2.fullForest
  if self.terrain and self.terrain.landArea then
    self.fullForest = U.clamp(self.terrain.landArea * TU.o2.forestPerArea,
                              TU.o2.forestMin, TU.o2.forestMax)
  end

  self.rallyX, self.rallyY = nil, nil
  self.centerX, self.centerY = TU.world.w / 2, TU.world.h / 2

  self:placeHome()
  Relic.populate(self)
  if opts.restore then
    self:restore(opts.restore)
  else
    -- Serials are module state on Bot and count for the life of the process,
    -- not the life of a run: a second run started in the same session named
    -- its first planter SEED-13, and at a hundred of a type the %02d wrapped
    -- round to SEED-00. A restore does NOT reset them -- it takes the serials
    -- off the save instead, and the crew that came back keeps its names.
    if Bot.resetSerials then Bot.resetSerials() end
    self:seedCobalt()
  end
  Warmup.mark("home")
  -- A restored forest has to be in the visible list before anything draws:
  -- `World:draw` reads the list rather than sweeping `self.trees`, and the
  -- loading screen and the ending both paint a world nobody has updated yet.
  self:refreshVisibleTrees()

  Signal._world = self
  Signal.emit("world:ready", self)
  Warmup.mark("ready")
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

--- Update a list, compacting out anything that died. An entity's update may
--- append to the same list (a builder building, a maw spawning), so anything
--- added past the original end is slid down into the gap the dead left behind -
--- otherwise the array keeps a hole and the next sweep indexes nil.
--- `done` decides when an entity may be removed. Trees outlive `alive` so their
--- topple, fade and stump can play; everything else goes the moment it dies.
local function stillHere(e)
  if e.isDone then return not e:isDone() end
  return e.alive
end

local function sweep(list, hash, dt)
  local n = #list
  local w = 1
  for i = 1, n do
    local e = list[i]
    if stillHere(e) then
      if e.update then e:update(dt) end
    end
    if stillHere(e) then
      if hash then hash:update(e) end
      list[w] = e w = w + 1
    else
      if hash then hash:remove(e) end
    end
  end
  local total = #list
  for i = n + 1, total do
    list[w] = list[i]
    w = w + 1
  end
  for i = w, total do list[i] = nil end
end

--- Depth key. Entities may supply `sortKey`; anything else sorts on its feet.
--- It lives up here with the entity bookkeeping rather than down in the draw
--- section because the forest's keys are now assigned once when a tree is
--- planted and never touched again - see World:addTree.
local function depthOf(e)
  if e.sortKey then return e:sortKey() end
  local z = e.z
  return e.y + (type(z) == "number" and z or 0)
end

--- The key is stashed when the list is built, not recomputed inside the
--- comparator. table.sort calls its comparator O(n log n) times, so a
--- five-hundred entity frame was making about nine thousand dynamic dispatches
--- through depthOf -- 1.3 to 1.8 ms of interpreted Lua, every frame, to answer
--- five hundred questions.
local function addDraw(list, e)
  e._dz = depthOf(e)
  list[#list + 1] = e
end
local function bySortKey(a, b) return a._dz < b._dz end

--- Plant a tree into the world's bookkeeping.
---
--- A tree is the one thing on this island that never moves, so its depth key is
--- fixed for its whole life and a list held in depth order stays in depth order
--- for free. `treesZ` is that list. It costs one binary-search insert per
--- planting - a few a second at the busiest - and it buys the removal of the
--- ~450-entry `table.sort` through a Lua comparator that `World:draw` was
--- running every single frame to re-discover an order that had not changed.
---
--- `self.trees` deliberately keeps its own insertion order: the update sweep,
--- the spread cursor and the save file all read it, and the spread cursor draws
--- from the shared RNG, so reordering it would quietly move the whole run.
function World:addTree(t)
  self:addEntity(self.trees, self.hTree, t)
  t._dz = depthOf(t)
  local z = self.treesZ
  local lo, hi = 1, #z
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if z[mid]._dz <= t._dz then lo = mid + 1 else hi = mid - 1 end
  end
  table.insert(z, lo, t)
  self.treeCount = self.treeCount + 1
  return t
end

--- Refresh the depth-ordered list of trees the camera can see, and compact the
--- dead out of `treesZ` on the same walk. Called straight after the tree sweep,
--- because `Tree:update` has just computed `onScreen` for its own culling and
--- both draw passes want exactly that answer: the old code re-derived it with
--- two more full walks of the 722-tree array inside `World:draw`.
---
--- Nothing in this loop can call back into the world, so nothing can append to
--- either list while it is being compacted. If that ever stops being true it
--- needs the same slide-down `sweep` does, for the same reason.
---
--- The live branch is written to ask `t.alive` first and stop there. Asking
--- `t:isDone()` of every tree instead is a metatable lookup and a call per tree
--- per frame: at 825 trees that alone measured around 0.5 ms, which ate most of
--- the 0.73 ms the two removed draw sweeps and the sort give back. A dead tree
--- still gets the call, and there are never many of those at once.
function World:refreshVisibleTrees()
  local z, vis = self.treesZ, self.visTrees
  local n, w, v = #z, 0, 0
  for i = 1, n do
    local t = z[i]
    if t.alive then
      w = w + 1
      z[w] = t
      if t.onScreen then v = v + 1 vis[v] = t end
    elseif not (t.isDone and t:isDone()) then
      w = w + 1
      z[w] = t
    end
  end
  for i = w + 1, n do z[i] = nil end
  for i = v + 1, #vis do vis[i] = nil end
end

------------------------------------------------------------------------ queries
--- The query filters live up here, one shared function each, rather than being
--- built fresh at every call.
---
--- A filter closure is not free: LOVE's Lua boxes every upvalue as its own heap
--- object, so `function(b) ... filter ... end` is a function plus a box per
--- captured local. The spatial queries below run about a hundred times a frame
--- between the bots, the enemies and the spread cursor, and rebuilding their
--- filters was the second-largest allocator in the game after `Spatial:nearest`
--- built one of its own.
---
--- What a filter needs to know goes in the slots below. A query that hands a
--- *caller-supplied* filter through -- `nearestBot`, `nearestEnemy` -- saves the
--- slot it borrows and puts it back afterwards, because that filter may query
--- the world itself (a bot's "is this one mine?" test asking for the nearest
--- tree) and the inner query would otherwise walk off with the outer one's
--- state. Two stores against a hundred closures a frame. The counting filters
--- do not need that: nothing they touch can re-enter a query, and their reader
--- is the statement after the walk.
local qUnmarked          -- nearestTree: skip trees another bot has claimed
local qFilter            -- the caller's own extra test, if it passed one
local qX, qY             -- the query point, where the test needs it
local qSelf              -- an entity to exclude from its own neighbourhood
local qCount             -- counting filters accumulate here

local function fTree(t)
  if not t.alive or t.stage == "dead" then return false end
  if qUnmarked and t.markedBy and t.markedBy.alive then return false end
  return true
end

local function fBot(b)
  if b.state == "dead" or b.state == "down" or not b.alive then return false end
  if qFilter and not qFilter(b) then return false end
  return true
end

local function fBotDowned(b)
  return b.alive and b.state == "down" and not b.carried
end

local function fEnemy(e)
  if not e.alive or e.fleeing then return false end
  if qFilter and not qFilter(e) then return false end
  return true
end

local function fCobaltNode(c) return c.alive and c.node end
local function fAlive(e) return e.alive end
local function fBeacon(b) return b.type == "beacon" and b.state == "work" end
local function fEnemyHittable(e) return e.alive and not e.fleeing end

--- Blight creep is a radius per scar, so this one has to know where it is being
--- asked about.
local function fScarCreep(e)
  return e.alive and e.type == "scar" and U.dist(e.x, e.y, qX, qY) < (e.creep or 0)
end

--- Neighbour counting: `qSelf` is the tree asking, and never counts itself.
local function fCountNeighbours(o)
  if o ~= qSelf and o.alive then qCount = qCount + 1 end
end

local function fCountAlive(e)
  if e.alive then qCount = qCount + 1 end
end

function World:nearestTree(x, y, r, unmarkedOnly)
  local prev = qUnmarked
  qUnmarked = unmarkedOnly
  local t, d = self.hTree:nearest(x, y, r, fTree)
  qUnmarked = prev
  return t, d
end

function World:nearestBot(x, y, r, filter)
  local prev = qFilter
  qFilter = filter
  local b, d = self.hBot:nearest(x, y, r, fBot)
  qFilter = prev
  return b, d
end

function World:nearestDownedBot(x, y, r)
  return self.hBot:nearest(x, y, r, fBotDowned)
end

function World:nearestEnemy(x, y, r, filter)
  local prev = qFilter
  qFilter = filter
  local e, d = self.hEnemy:nearest(x, y, r, fEnemy)
  qFilter = prev
  return e, d
end

function World:nearestCobalt(x, y, r)
  return self.hCobalt:nearest(x, y, r, fCobaltNode)
end

function World:enemyCount() return #self.enemies end
--- The crew. Extraction reinforcements are deliberately not in it: they are
--- not yours, they do not count against the cap, and the HUD's "n of 48" would
--- otherwise climb past its own maximum while you watched.
function World:botCount()
  local n = 0
  for i = 1, #self.bots do
    local b = self.bots[i]
    if b.alive and b.state ~= "dead" and not b.reinforcement then n = n + 1 end
  end
  return n
end

--- Beacon field helpers, used by bots and enemies.
function World:beaconAt(x, y)
  local b = self.hBot:nearest(x, y, TU.bots.beacon.radius_field * self.chips:get("beaconRadius", 1),
    fBeacon)
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
  local c = self.hCobalt:nearest(x, y, r, fCobaltNode)
  if not c or not c:mine() then return false end
  if dropLoose then
    local loose = CobaltE.new(c.x, c.y, self, self.rng, false)
    loose:push(c.x - x, c.y - y, 140)
    self:addEntity(self.cobalts, self.hCobalt, loose)
  end
  return true
end

----------------------------------------------------------------------- actions
--- Is this ground inside a Blight Scar's creep? Nothing roots in it.
function World:blightedAt(x, y)
  local r = TU.enemy.scar and TU.enemy.scar.creepMax or 0
  if r <= 0 then return false end
  local px, py = qX, qY
  qX, qY = x, y
  local e = self.hEnemy:nearest(x, y, r, fScarCreep)
  qX, qY = px, py
  return e ~= nil
end

function World:plantTree(x, y, by)
  if self.treeCount >= TU.tree.maxTrees then return false end
  -- A Scar does not only eat the wood around it, it *denies the ground*. That
  -- is what makes clearing one a decision about where the forest goes rather
  -- than an errand with a deadline, and it is the job PIONEER exists to undo.
  if self:blightedAt(x, y) and not self.chips:has("pioneer") then return false end
  if self.terrain and self.terrain.isLand and not self.terrain:isLand(x, y) then return false end
  -- Bare rock and blight scars stay bare, which is where the forest gets its
  -- shape. Pioneer is the chip that lets you take the dead ground back.
  if self.terrain and self.terrain.biomeAt then
    local biome = self.terrain:biomeAt(x, y)
    if TU.tree.barrenBiomes[biome] and not self.chips:has("pioneer") then
      return false
    end
  end
  local gap = TU.tree.spreadReject * 0.74
  if self.hTree:nearest(x, y, gap, fAlive) then return false end
  -- Nothing roots on top of a relic, so the wood grows around the wreck, the
  -- road and the pad instead of swallowing them, and they are still standing in
  -- their clearings when the ending pulls the camera back over the canopy.
  if Relic.blocksPlantingAt(self, x, y) then return false end

  local t = Tree.new and Tree.new(x, y, self.rng:int(1, 100000)) or nil
  if not t then return false end
  t.world = self
  t.canElder = true
  self:addTree(t)
  self.stats.planted = self.stats.planted + 1

  VFX.emit("plant_burst", x, y)
  Audio.play("plant", { x = x, y = y, volume = (by == "player") and 1 or 0.6 })
  self:updateForestChime()
  Signal.emit("tree:planted", t, by)
  return true
end

--- The plant chime climbs a pentatonic ladder with the forest. It has to be able
--- to come back down, or a bad night leaves the sound lying about the world.
--- Traits live in names.lua as tables; a save carries the id. Rebuilt into the
--- same table the live game uses, so a restored record is shaped like one that
--- was made this session.
local traitById
local function traitOf(id)
  if not id or id == "" then return nil end
  if not traitById then
    traitById = {}
    for i = 1, #Names.traits do traitById[Names.traits[i].id] = Names.traits[i] end
  end
  return traitById[id]
end

--- Rebuild a saved run in place. Called from init, so nothing has ticked yet
--- and no signal has a listener: this writes state, it does not play the run
--- forward. See src/game/save.lua for what is stored and why so little of it.
function World:restore(d)
  local Tree_  = Tree
  local trees  = d.trees or {}
  for i = 1, #trees, Save.TREE_STRIDE do
    local x, y, seed, growth, elder = trees[i], trees[i + 1], trees[i + 2],
                                      trees[i + 3], trees[i + 4]
    local t = Tree_.new and Tree_.new(x, y, seed) or nil
    if t then
      t.world    = self
      t.canElder = true
      t.growth   = U.saturate(growth or 0)
      if elder == 1 then t.elder = true end
      if t.refreshMesh  then t:refreshMesh() end
      if t.refreshStage then t:refreshStage(true) end
      self:addTree(t)
    end
  end

  local chips = d.chips or {}
  for i = 1, #chips do self.chips:add(chips[i]) end

  local bots, types, names = d.bots or {}, d.botTypes or {}, d.botNames or {}
  local traits = d.botTraits or {}
  local BS = Save.BOT_STRIDE
  -- The highest serial ever issued per type, gathered as the crew is rebuilt.
  -- Bot's serial counter is module state and a restore restarts it at the
  -- number of bots that came back, so without this a newly built machine takes
  -- a dead one's name -- observed as two FRAME-04s collapsing into one row on a
  -- memorial that dedupes by name. See Bot.resetSerials.
  local topSerial = {}
  for i = 1, #bots, BS do
    local k = (i - 1) / BS + 1
    local botType = types[k]
    if botType and TU.bots[botType] then
      local b = Bot.new(bots[i], bots[i + 1], botType, self, self.rng)
      b.maxHp  = b.maxHp + self.chips:get("botHp", 0)
      b.hp     = math.min(bots[i + 2] or b.maxHp, b.maxHp)
      b.serial = bots[i + 3] or b.serial
      if b.serial > (topSerial[botType] or 0) then topSerial[botType] = b.serial end
      -- their own tally, not the world's: this is what Bot:epitaph reads, and
      -- dropping it here memorialised six cycles of work as "was here"
      b.planted = bots[i + 4] or 0
      b.built   = bots[i + 5] or 0
      b.log.planted, b.log.built = b.planted, b.built
      -- The rest of the ledger rides the same row, once save.lua's BOT stride
      -- grows to carry it (the comment there says exactly how). Read only when
      -- the stride is actually wide enough -- at stride 6 these slots are the
      -- NEXT machine's position, and a bot that inherited its neighbour's x as
      -- a night count would be worse than one that forgot.
      if BS >= 13 then
        local L = b.log
        L.nights    = bots[i + 6] or 0
        L.downs     = bots[i + 7] or 0
        L.saves     = bots[i + 8] or 0
        L.carried   = bots[i + 9] or 0
        L.mined     = bots[i + 10] or 0
        L.shots     = bots[i + 11] or 0
        L.bornCycle = bots[i + 12] or self.cycle
      end
      if names[k] and names[k] ~= "" then b.name = names[k] end
      b.trait = traitOf(traits[k]) or b.trait
      -- the trait feeds the wear shade, and the ledger above feeds the patina,
      -- so a restored veteran has to look like one before its first frame
      b:refreshWear()
      -- they were already standing when you left; do not boot them all again
      b.state, b.stateT, b.bootT = "work", 0, 0
      self:addEntity(self.bots, self.hBot, b)
    end
  end
  -- The dead count too. A machine that died before the save is still holding
  -- its name on the memorial, and the memorial dedupes by name, so the counter
  -- has to clear the highest serial ever ISSUED and not the highest still
  -- standing. Names are written "%s-%02d", so a serial past ninety-nine comes
  -- back wrapped and this is a floor rather than an exact recovery -- which is
  -- still strictly better than restarting at the size of the surviving crew.
  local prefixOf = {}
  for i = 1, #TU.bots.order do
    local kind = TU.bots.order[i]
    prefixOf[TU.bots[kind].prefix] = kind
  end
  for i = 1, #(d.lostNames or {}) do
    local pre, num = string.match(d.lostNames[i] or "", "^(%u+)%-(%d+)$")
    local kind = pre and prefixOf[pre]
    if kind then
      num = tonumber(num) or 0
      if num > (topSerial[kind] or 0) then topSerial[kind] = num end
    end
  end
  if Bot.resetSerials and next(topSerial) then Bot.resetSerials(topSerial) end

  local nodes = d.nodes or {}
  for i = 1, #nodes, Save.NODE_STRIDE do
    local c = CobaltE.new(nodes[i], nodes[i + 1], self, self.rng, true)
    c.left = nodes[i + 2] or c.left
    self:addEntity(self.cobalts, self.hCobalt, c)
  end
  -- an island that was mined out still gets its refills
  if #self.cobalts == 0 then self:seedCobalt() end

  -- What the crew used to be, which is what the next one costs. Without this a
  -- resumed run forgives every loss the saved run took, so closing the tab
  -- after a bad night would be the cheapest way to undo it. Written in
  -- TU.bots.order, one number per type; absent (an older file, or a type added
  -- since) falls back to the crew that came back, which forgives nothing that
  -- is still standing and nothing the file can prove.
  local pk = d.peakBots or {}
  for i = 1, #TU.bots.order do
    local kind = TU.bots.order[i]
    local v = tonumber(pk[i]) or 0
    local owned = self:countBots(kind)
    self.peakBots[kind] = (v > owned) and v or owned
  end

  -- The graves. Replayed through `Relic.addHusk` rather than reconstructed, so
  -- the minimum gap, the cap and the retirement queue all apply exactly as they
  -- did in the run that wrote them, and the hashed angle and flip come back off
  -- the same floored coordinates. Written oldest-first, so laying them in order
  -- leaves the queue retiring in the order it would have. Without this a
  -- resumed run kept every name in the memorial and lost every body: the island
  -- forgot its dead and the planters planted over the ground they died on.
  local hu = d.husks or {}
  local HS = Save.HUSK_STRIDE
  if Relic.addHusk then
    for i = 1, #hu - (HS - 1), HS do
      local kind = TU.bots.order[hu[i + 2] or 1] or TU.bots.order[1]
      Relic.addHusk(self, hu[i], hu[i + 1], kind)
    end
  end

  self.cycle  = math.max(1, math.floor(d.cycle or 1))
  self.cobalt = math.max(0, math.floor(d.cobalt or 0))
  self.time   = d.time or 0
  self.o2     = d.o2 or 0
  -- The memorial reads records ({name, type, cycle, trait, planted, built}),
  -- so they go out as parallel arrays and come back as records. They used to
  -- go out through a string serialiser, which wrote each one as its own
  -- address and printed "table: 0x7f21fcb071a8" on the ending screen.
  self.allLostNames = {}
  local lNames = d.lostNames or {}
  local lTypes, lTraits, lFacts = d.lostTypes or {}, d.lostTraits or {}, d.lostFacts or {}
  local LS = Save.LOST_STRIDE
  for i = 1, #lNames do
    local f = (i - 1) * LS
    local rec = { name = lNames[i], type = lTypes[i],
                  trait = traitOf(lTraits[i]),
                  cycle = lFacts[f + 1] or 0,
                  planted = lFacts[f + 2] or 0,
                  built = lFacts[f + 3] or 0 }
    -- ...and the rest of the ledger, when the LOST stride carries it. Same
    -- gate and same reason as the BOT stride above.
    if LS >= 10 then
      rec.nights    = lFacts[f + 4] or 0
      rec.downs     = lFacts[f + 5] or 0
      rec.saves     = lFacts[f + 6] or 0
      rec.carried   = lFacts[f + 7] or 0
      rec.mined     = lFacts[f + 8] or 0
      rec.shots     = lFacts[f + 9] or 0
      rec.bornCycle = lFacts[f + 10] or rec.cycle
    end
    self.allLostNames[i] = rec
  end
  self.rallyX, self.rallyY = d.rallyX, d.rallyY

  local st = d.stats or {}
  self.stats.planted    = st[1] or 0
  self.stats.lost       = st[2] or 0
  self.stats.botsLost   = st[3] or 0
  self.stats.botsBuilt  = st[4] or 0
  self.stats.killed     = st[5] or 0
  self.stats.cobaltMined = st[6] or 0
  self.stats.rescued    = st[7] or 0

  self.phaseDur = self:phaseLength("day", self.cycle)
  self.restored = true
end

function World:updateForestChime()
  Audio.setForestProgress(U.saturate(self.treeCount / 620))
end

function World:fellTree(t, by)
  if not t.alive then return end
  if t.kill then t:kill("chewed") else t.alive = false end
  self.treeCount = math.max(0, self.treeCount - 1)
  self.stats.lost = self.stats.lost + 1
  Audio.play("tree_fall", { x = t.x, y = t.y })
  self:updateForestChime()
  local yield = self.chips:get("fellYield", 0)
  if yield > 0 then self:addCobalt(yield, t.x, t.y) end
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

--- The largest crew of this type the run has fielded. Raised here as well as
--- inside botCost, so the memory is a fact about the run rather than a fact
--- about who last happened to ask the price.
function World:notePeak(botType)
  local owned = self:countBots(botType)
  local p = self.peakBots
  if owned > (p[botType] or 0) then p[botType] = owned end
  return owned
end

--- The remembered crew fades back toward the crew actually standing.
---
--- Without this the peak is a wall. Lose twenty Planters on a bad cycle 3 and
--- every replacement is priced as the twenty-first for the rest of the run,
--- which turns one bad night into a dead run -- punished rather than bereaved,
--- and a worse game than the one that rewarded attrition. With it the loss is
--- expensive exactly while you are rebuilding from it, and a cycle or so later
--- it is forgotten. `TU.bots.costMemory` is the half-life; 0 disables the fade.
---
--- Half a second of cadence and one pass over the crew: countBots per type
--- every frame is six passes over the same array for nothing.
function World:updatePeakBots(dt)
  local hl = TU.bots.costMemory or 0
  if hl <= 0 then return end
  self.peakT = (self.peakT or 0) + dt
  if self.peakT < 0.5 then return end
  local elapsed = self.peakT
  self.peakT = 0
  local order = TU.bots.order
  local live = self.peakLive
  if not live then live = {} self.peakLive = live end
  for i = 1, #order do live[order[i]] = 0 end
  for i = 1, #self.bots do
    local b = self.bots[i]
    if b.alive and b.state ~= "dead" and live[b.type] then
      live[b.type] = live[b.type] + 1
    end
  end
  local keep = 0.5 ^ (elapsed / hl)
  local p = self.peakBots
  for i = 1, #order do
    local k = order[i]
    local pk, owned = p[k], live[k]
    if pk then
      if pk <= owned then p[k] = owned
      else
        local gap = (pk - owned) * keep
        -- snap the last twentieth of a machine away, so the price of a crew
        -- that has been whole for a while is an integer's worth again
        p[k] = (gap < 0.05) and owned or (owned + gap)
      end
    end
  end
end

--- The price of the next bot of this type, with escalation and chips applied.
---
--- The escalation is priced off the PEAK crew of this type, not the standing
--- one. Off the standing one a death made the replacement CHEAPER: the only
--- material consequence of losing a machine had the wrong sign, and a run that
--- lost half its Planters was handed a discount on rebuilding them. Off the
--- peak, the machine you lost is a machine you have to buy twice.
---
--- `TU.bots.costForgiveness` writes off part of the gap at once and
--- `TU.bots.costMemory` fades the rest; at costForgiveness = 1 this is exactly
--- the old behaviour, which is the one-line way back.
function World:botCost(botType)
  local def = TU.bots[botType]
  if not def then return 0 end
  local owned = self:countBots(botType)
  local peak = self.peakBots[botType] or 0
  if owned > peak then peak = owned self.peakBots[botType] = owned end
  -- Forgiveness is how much of the (peak - standing) gap is WRITTEN OFF, so it
  -- subtracts. This read `* costForgiveness` and shipped with the value 0,
  -- which collapsed the basis back to the standing count -- i.e. the whole
  -- change was inert and a death still discounted its own replacement.
  local basis = owned + (peak - owned) * (1 - (TU.bots.costForgiveness or 0))
  local growth = def.costGrowth or TU.bots.costGrowth
  local mul = math.min(1 + basis * growth, TU.bots.costGrowthMax)
  return math.ceil(def.cost * mul * self.chips:get("botCost", 1))
end

--- `offRoster` is for the extraction's reinforcements: they arrive after the
--- rig has landed, when nothing may be built, and they are not part of the
--- crew -- so they skip the extraction block, the crew cap and the ledger.
function World:spawnBot(x, y, botType, free, offRoster)
  local def = TU.bots[botType]
  if not def then return false end
  -- Once the rig arrives there is no more building. The workforce you have is
  -- the workforce that decides the fight, which is the whole point of it.
  if self.phase == "extraction" and not free and not offRoster then
    Audio.play("ui_back")
    Signal.emit("ui:denied", "extraction")
    return false
  end
  if self.terrain and self.terrain.isLand and not self.terrain:isLand(x, y) then
    if self.terrain.nearestLand then
      local lx, ly = self.terrain:nearestLand(x, y)
      if lx then x, y = lx, ly else return false end
    else return false end
  end
  -- The Rig can only run so many of them. This is checked before the price so
  -- a full crew never silently takes the player's cobalt.
  if not offRoster and self:botCount() >= (TU.bots.maxCrew or 999) then
    if not free then
      Audio.play("ui_back")
      Signal.emit("ui:denied", "crew")
    end
    return false
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
  -- Not crew: a machine that was working somewhere else on the island when the
  -- rebellion started and walked in for the rig. It matters on the memorial --
  -- these arrive seconds before they die, so without knowing what they are the
  -- epitaph can only report their age, and a dozen rows reading "lasted one
  -- second" is a bug however true each one is. See Bot:epitaph.
  b.offRoster = offRoster or nil
  self:addEntity(self.bots, self.hBot, b)
  if not offRoster then
    self.stats.botsBuilt = self.stats.botsBuilt + 1
    self:notePeak(botType)
  end
  if self.phase == "extraction" and self.boss and self.boss.alive and self.botsRebelled then
    b:rebel(self.boss)
  end
  Signal.emit("bot:built", b, free)
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
    if t.alive and t.stage == "sapling" then self:fellTree(t, "acid") end
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
    if self.chips:has("brittle") and (e.stun or 0) > 0 then dmg = dmg * 2 end
    local moved
    if pin and e.def and e.def.armoured and e.type ~= "maw" then
      e:push(e.x - x, e.y - y, force * 0.6)
      e.stun = math.max(e.stun or 0, stun * 0.6)
      e:damage(dmg, x, y)
      moved = true
    else
      moved = e:shove(e.x - x, e.y - y, force, dmg, stun)
    end
    if moved then hits = hits + 1 end
  end)
  -- The shove used to mine deposits too, which made "hold E" the right answer to
  -- every situation in the game. Mining is standing on a deposit now: stationary,
  -- committed, and a job a Harvester can do for you while you fight.
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
  local e = self.hEnemy:nearest(x, y, r, fEnemyHittable)
  if not e then return false end
  local dmg = damage
  if self.chips:has("brittle") and (e.stun or 0) > 0 then dmg = dmg * 2 end
  -- A Sentry firing seeds at the extraction rig should chip it, not shred it:
  -- a handful of them were deleting the whole health bar in five seconds.
  if e.kind == "boss" then dmg = dmg * TU.boss.dartResist end
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
        -- Saplings burn away; anything grown survives, scorched. The forest has
        -- to still be standing at the ending or the ending means nothing.
        if t.burn > 1.8 and (t.growth or 1) < 0.98 then self:fellTree(t, "beam") end
        if t.hit then t:hit(math.cos(angle), math.sin(angle), 0.4) end
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
  -- A Beacon revives in the field; the Home Rig always can. Carrying someone
  -- home is meant to be a real option, not one that needs prior planning.
  local atRig = self.homeX and U.dist(b.x, b.y, self.homeX, self.homeY) < TU.world.homeRadius
  if atRig or self:beaconAt(b.x, b.y) then
    -- "player", not a bare revive: this is the one rescue the player made with
    -- their own hands, and it is the only one that buys the machine a loyalty
    -- timer and the rarest epitaph in the game.
    b:revive("player")
    self.stats.rescued = self.stats.rescued + 1
  end
end

--- Siphons do not remove oxygen directly - they add a debt against the forest's
--- reading, so killing them restores what they took.
function World:drainO2(rate, dt)
  self.o2Debt = math.min(self.o2DebtCap or TU.o2.debtCap, (self.o2Debt or 0) + rate * dt)
end

local SPEECH_MAX = 3
function World:speak(who, line)
  -- one rule, everywhere: nobody talks over a cutscene
  if self.cutscene then return end
  -- A forest of forty bots all talking is noise. Keep a few, prefer the ones
  -- nearest the player, and never let the same bot double up.
  for i = #self.speeches, 1, -1 do
    local sp = self.speeches[i]
    if sp.who == who then table.remove(self.speeches, i)
    elseif sp.line == line then return end   -- never two bots on the same sentence
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
  -- a stable variant per bot, so each one keeps its own voice all run.
  -- The mechanic gets a bubble too now (his one acknowledgement of a rescue),
  -- and he has no serial: `who.serial % 7` on the player was an arithmetic-on-
  -- nil crash waiting for the first machine anyone carried home. He is also not
  -- a bot, so he does not get the bot voice. The rest of this path is clean for
  -- a non-bot speaker: `drawSpeech` wants `alive` (Entity sets it) and `radius`
  -- (Player has it), and the furthest-speaker eviction above can never drop him
  -- because he is the one at distance zero from himself.
  local serial = who.serial or 0
  Audio.play(who.kind == "player" and "ui_move" or "bot_chatter",
             { volume = 0.35, pitch = who.serial and (0.9 + (serial % 7) * 0.04) or 1,
               variation = serial, x = who.x, y = who.y })
end

--------------------------------------------------------------------- the clock
local PHASE_ORDER = { day = "dusk", dusk = "night", night = "dawn", dawn = "day" }

function World:phaseLength(phase, cycle)
  cycle = math.min(cycle, TU.cycle.count)
  if phase == "day" then return TU.cycle.dayLen[cycle] end
  if phase == "dusk" then return TU.cycle.duskLen end
  if phase == "night" then
    return TU.cycle.nightLen[cycle] * self.chips:get("nightLen", 1)
  end
  return 0
end

function World:setPhase(phase)
  local prev = self.phase
  -- Dawn does not tick: it waits for the player to finish the draft, and the
  -- draft returning to day is what actually advances the cycle.
  if phase == "day" and prev == "dawn" then
    self.cycle = self.cycle + 1
    self.heldThisCycle = false
    if self.cycle > TU.cycle.count or self.o2 >= TU.o2.target - 0.5 then
      self:beginExtraction()
      return
    end
    -- The one quiet moment in the loop: the draft is done, the field is clear,
    -- the cycle has turned. Whoever is listening writes the run here.
    Signal.emit("run:checkpoint", self)
  end
  self.phase = phase
  self.phaseT = 0
  self.phaseDur = self:phaseLength(phase, self.cycle)

  if phase == "dusk" then
    Audio.play("wave_start")
    Music.setState("dusk")
    Signal.emit("phase:dusk", self.cycle, self.director:sideVector())
  elseif phase == "night" then
    self.director:beginNight(self.cycle, self.phaseDur, self.holdBudget)
    self.holdBudget = nil
    Music.setState("night")
    Signal.emit("phase:night", self.cycle)
  elseif phase == "dawn" then
    -- End the night here rather than waiting for the director's own timer to
    -- notice: endNight is what sets the dawn quota, and the fleeing pass below
    -- spends it. Called from two places a frame apart, the quota was still
    -- zero when the only code that could claim it ran.
    self.director:endNight()
    -- The fleeing pass gets first claim on the quota -- a Chomper with its
    -- teeth in a trunk becoming a Scar where it stood is the best-reading
    -- version -- and the director spends the rest on the ground the night took.
    for i = 1, #self.enemies do self.enemies[i]:flee() end
    if self.director.rootRemaining then self.director:rootRemaining() end
    Audio.play("dawn")
    Music.setCycle(self.cycle)
    Music.setState("draft")
    self:buildDawnReport()
    Signal.emit("phase:dawn", self.cycle, self.dawnReport)
  elseif phase == "day" then
    Music.setState("day")
    Signal.emit("phase:day", self.cycle)
  end
end

--- Plant the standing order. One flag; moving it is free and instant.
--- Can the standing order be moved right now? The HUD asks so it can grey the
--- prompt out rather than letting the player press a key that does nothing.
function World:rallyReady()
  return (self.rallyCd or 0) <= 0
end

function World:setRally(x, y)
  if (self.rallyCd or 0) > 0 then
    Audio.play("ui_back")
    Signal.emit("ui:denied", "rally")
    return false
  end
  if self.terrain and self.terrain.isLand and not self.terrain:isLand(x, y) then
    if not self.terrain.nearestLand then return false end
    local lx, ly = self.terrain:nearestLand(x, y)
    if not lx then return false end
    x, y = lx, ly
  end
  local moved = self.rallyX ~= nil
  self.rallyX, self.rallyY, self.rallyT = x, y, 0
  -- Moving it is a commitment: the ground you point at is ground you are not
  -- defending, and that is only true if you cannot take it back immediately.
  self.rallyCd = moved and TU.rally.cooldown or 0
  Audio.play(moved and "ui_move" or "build_done", { x = x, y = y })
  VFX.emit("plant_burst", x, y, { power = 0.6 })
  Signal.emit("world:rally", x, y, moved)
  return true
end

function World:clearRally()
  self.rallyX, self.rallyY = nil, nil
  Signal.emit("world:rally", nil, nil, false)
end

--- Is this point inside the standing order, and how strongly?
function World:rallyPull(x, y)
  if not self.rallyX then return 0 end
  local d = U.dist(x, y, self.rallyX, self.rallyY)
  return U.saturate(1 - d / (TU.rally.radius * 2.2))
end

--- Trade a harder night for half a minute more daylight. Offered once a cycle,
--- only while dusk is running.
function World:holdDawn()
  if self.phase ~= "dusk" or self.heldThisCycle then return false end
  self.heldThisCycle = true
  self.holdBudget = TU.cycle.holdBudget
  -- straight back into daylight, briefly; dusk will come round again
  self.phase = "day"
  self.phaseT = 0
  self.phaseDur = TU.cycle.holdExtra
  Music.setState("day")
  Audio.play("o2_milestone", { pitch = 0.8 })
  Signal.emit("world:heldDawn", self.cycle)
  return true
end

function World:canHoldDawn()
  return self.phase == "dusk" and not self.heldThisCycle
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
  return r
end

--- The procession. Cohorts leave on world time so the sacrifice has a rhythm the
--- player can feel, and every bot gets to make its run.
function World:updateRebellion(dt)
  if not self.boss or not self.boss.alive then return end
  if not self.rebelT then return end
  self:updateReinforcements(dt)
  self.rebelT = self.rebelT - dt
  if self.rebelT > 0 then return end
  self.rebelT = TU.boss.rebelEvery

  -- Nobody else leaves once the rig is nearly down, and a reserve never leaves
  -- at all: the ending needs somebody to still be standing there.
  if self.boss.hp <= self.boss.maxHp * TU.boss.rebelStopAt then return end
  if (self.rebelSent or 0) >= (self.rebelSendable or 0) then return end

  if not self.botsRebelled then
    self.botsRebelled = true
    Signal.emit("bots:rebel")
  end
  -- A wave is a share of the crew, not a fixed five: twelve bots and sixty bots
  -- both take about ten waves to go, so the procession is the same length of
  -- thing to sit through either way.
  local size = math.max(TU.boss.rebelCohort,
                        math.ceil((self.rebelSendable or 0) / TU.boss.rebelWaves))
  size = math.min(size, (self.rebelSendable or 0) - (self.rebelSent or 0))
  local sent = 0
  for i = 1, #self.bots do
    local b = self.bots[i]
    if b.alive and b.state == "work" and sent < size then
      b:rebel(self.boss)
      sent = sent + 1
    end
  end
  if sent > 0 then
    self.rebelSent = (self.rebelSent or 0) + sent
    Signal.emit("bots:cohort", sent)
    -- one voice per bot in the wave, staggered onto chord tones, so a cohort
    -- of four is a chord rather than four copies of the same chirp
    if Audio.rebelCohort then Audio.rebelCohort(sent) end
  end
end

--- The island answers.
---
--- The crew you brought is finite. Once it is spent the rest of the hull was
--- the player's alone, and measured, that is the last third of a bar against a
--- rig draining the sky -- a race a player does not win. From phase two a bot
--- a second walks in off the map edge and makes for the rig.
---
--- They are deliberately not crew: free, outside the cap, and not counted in
--- the ending's ledger, because the names in that ledger are the ones you
--- built and lost. These are every machine still working somewhere on the
--- island, arriving because the rebellion started.
function World:updateReinforcements(dt)
  local R = TU.boss.reinforce
  if not R or not self.boss or not self.boss.alive then return end
  if (self.boss.phase or 1) < R.fromPhase then return end
  if self.boss.hp <= 0 then return end

  self.reinforceT = (self.reinforceT or R.every) - dt
  if self.reinforceT > 0 then return end
  self.reinforceT = R.every

  -- recount rather than decrement: they die inside Bot:updateRebel, which has
  -- no idea this counter exists, and a decrement that never runs is a cap that
  -- silently closes.
  local live = 0
  for i = 1, #self.bots do
    local b = self.bots[i]
    if b.reinforcement and b.alive and b.state ~= "dead" then live = live + 1 end
  end
  if live >= R.maxAlive then return end

  -- step in from whichever edge of the *land* is nearest a random bearing, so
  -- they arrive out of the dark at the treeline rather than out of the sea
  local a = self.rng:angle()
  local cx, cy = self.centerX, self.centerY
  local far = math.max(TU.world.w, TU.world.h)
  local x, y = cx + math.cos(a) * far, cy + math.sin(a) * far
  if self.terrain and self.terrain.nearestLand then
    local lx, ly = self.terrain:nearestLand(x, y)
    if lx then
      x, y = lx + math.cos(a) * R.edgePad, ly + math.sin(a) * R.edgePad
      local nx, ny = self.terrain:nearestLand(x, y)
      if nx then x, y = nx, ny end
    end
  end

  local order = TU.bots.order
  local kind = order[self.rng:int(1, #order)]
  local b = self:spawnBot(x, y, kind, true, true)
  if not b then return end
  b.reinforcement = true
  b.state, b.stateT, b.bootT = "work", 0, 0
  b:rebel(self.boss)
  Signal.emit("bots:reinforce", b)
end

--- The rig finished what it came for.
function World:fail()
  self.failed = true
  self.phase = "ending"
  J.shake(1)
  Audio.play("player_down", { pitch = 0.6 })
  Signal.emit("world:failed", self)
end

function World:beginExtraction()
  self.phase = "extraction"
  self.phaseT = 0
  self.extractionStage = "arrive"
  Music.setState("boss")
  -- The ground troops withdraw when the rig lands: this fight is between the
  -- workforce and the thing that came for the air, and nothing else.
  for i = 1, #self.enemies do self.enemies[i]:flee() end

  local x, y = self.homeX + self.rng:range(-500, 500), self.homeY + self.rng:range(-500, 500)
  if self.terrain and self.terrain.nearestLand then
    local lx, ly = self.terrain:nearestLand(x, y)
    if lx then x, y = lx, ly end
  end
  -- the fight's clock, scaled so it is always the same length
  self.bossDrainRate = math.max(1, self.o2) / TU.boss.extractWindow
  -- The lower of the two on purpose. Clamping only the raw figure stopped the
  -- forest adding to it, but if the displayed reading was still easing upward
  -- toward a raw value it had not caught yet, it went on climbing under a line
  -- of dialogue that says the rig is taking the air back. Once the rig is on
  -- the ground the meter may only fall.
  self.extractRaw = math.min(self.o2Raw or self.o2 or 0, self.o2 or 0)
  local crew = self:botCount()
  self.boss = Boss.new(x, y, self, crew)
  self.rebelSent = 0
  -- The workforce always pays exactly the same share of the rig, however big it
  -- is. Before this, forty bots standing near the landing site deleted the whole
  -- health bar in ten seconds and none of the three authored phases ever played.
  -- Only the ones actually standing can go, and the phase gates are measured
  -- against that number: counting bots that are mid-boot or being carried would
  -- stall the fight on a cohort that is never coming.
  local able = 0
  for i = 1, #self.bots do
    local b = self.bots[i]
    if b.alive and b.state ~= "dead" then able = able + 1 end
  end
  self.rebelTotal = math.max(1, able)
  local keep = math.min(self.rebelTotal - 1,
                        math.max(TU.boss.rebelKeepMin,
                                 math.ceil(self.rebelTotal * TU.boss.rebelKeep)))
  -- rebelCrew is the number that will actually walk into it: the phase gates
  -- and the health bar's notches are both counted against that, not against
  -- the reserve who are never asked to go.
  self.rebelCrew = math.max(1, self.rebelTotal - keep)
  self.rebelSendable = self.rebelCrew
  self.rebelShare = U.clamp(TU.boss.rebelShareMin + self.rebelTotal * TU.boss.rebelSharePerBot,
                            TU.boss.rebelShareMin, TU.boss.rebelShareMax)
  self.rebelDamage = math.max(0.5, self.boss.maxHp * self.rebelShare / self.rebelCrew)
  -- the boss lives in the enemy hash so shoves, pulses and sentry darts find it
  self.hEnemy:insert(self.boss)
  for i = 1, #self.bots do
    local b = self.bots[i]
    -- everyone gets up for this, including the ones still on the ground.
    -- "rig", so it is not counted as a rescue: nobody came and got them, and
    -- forty machines whose epitaph reads "the light brought it back" is the
    -- mail merge this whole pass exists to delete.
    if b.state == "down" then b:revive("rig") end
    if b.state == "work" then
      b.mood = "confused"
      -- nothing gets to take them from you before they choose it themselves
      b.invuln = 9999
    end
  end
  Audio.play("rift_open")
  J.shake(1)
  Signal.emit("phase:extraction", self.boss)

  -- The rebellion runs on world time (World:updateRebellion), not on the global
  -- real-time timer: the headless harness runs the simulation fast, and a
  -- procession measured in wall-clock seconds would be left behind by it.
  self.rebelT = TU.boss.rebelDelay
end

------------------------------------------------------------------------ update
--- `realDt` is wall time; `dt` is *simulation* time and may be zero.
---
--- A cutscene freezes the simulation and nothing else. It used to freeze
--- nothing at all: the world went on running under the dialogue box, so a
--- conversation you could not skip was a window in which Chompers ate you and
--- your crew while you read. Passing zero to the whole update would fix that
--- and produce a photograph -- no rain, no embers, no wind in the canopy,
--- which reads as a hang rather than as a pause. So the two are separated:
--- entities, the director, the phase clock and the oxygen take `dt`; weather,
--- wind, particles and decals take `realDt` and keep breathing.
function World:update(dt, realDt)
  realDt = realDt or dt
  self.time = self.time + dt
  if (self.rallyCd or 0) > 0 then self.rallyCd = self.rallyCd - dt end
  if Wind.update then Wind.update(realDt) end
  Weather.update(realDt, self)
  self.raining = Weather.isRaining()
  if self.terrain and self.terrain.update then self.terrain:update(realDt) end

  if self.phase ~= "extraction" and self.phase ~= "ending" and not self.cutscene then
    self.phaseT = self.phaseT + dt
    if self.phaseDur > 0 and self.phaseT >= self.phaseDur then self:advancePhase() end
  end

  if self.phase == "night" then self.director:update(dt) end
  if self.phase == "extraction" then self:updateRebellion(dt) end

  self:updateOxygen(dt)

  if self.rallyX then self.rallyT = (self.rallyT or 0) + dt end
  if self.rig then self.rig:update(dt) end
  if self.player then self.player:update(dt, self.camera, realDt) end
  -- CULLING IS A SIMULATION INPUT, so it cannot be left to the draw pass.
  --
  -- `Tree:update` sets `onScreen` from the module view rect, and two things in
  -- the update path read it: the LOD scheduler right below, and
  -- `Tree:updateLeaves`, which gates every pollen and firefly emit on it. The
  -- rect was only ever written from inside `World:draw`. In a real session that
  -- is harmless -- every frame draws -- but headless only calls love.draw() on
  -- photographed frames, so until the first photograph the rect was untouched
  -- and EVERY tree reported on screen, at full LOD and full emission.
  --
  -- Two consequences, both measured. The shot list changed the run: seeds and
  -- frame counts held, `shots=5900` and `shots=10,5900` diverged from the
  -- photographed frame onward (t=362/cycle 3/187 trees against t=385/cycle
  -- 4/237). And every balance number this repo ever took from a trace was
  -- measured on a game that never culled, which is not the game that ships.
  -- Setting the rect here makes headless match the browser and makes a trace
  -- independent of where its shots fall; three shot lists now agree byte for
  -- byte. Only the cull inputs -- the air, the rim and the x-ray focus are a
  -- LOOK and stay in draw.
  if self.camera and self.camera.viewRect and Tree.setView then
    Tree.setView(self.camera:viewRect(0))
  end
  sweep(self.trees, self.hTree, dt)
  self:refreshVisibleTrees()
  -- THE X-RAY IS A CAMERA EFFECT, NOT A SIMULATION ONE, and this is the whole
  -- of the "the cutscene subject is under a tree" bug.
  --
  -- game.lua passes `dt = 0` to this function while anybody is talking, so that
  -- the Blight cannot eat the crew behind a page of dialogue. Every tree's
  -- `updateXray` damps by that zero, which means the canopy is frozen in
  -- whatever state it held at the instant the scene opened -- and a scene opens
  -- by panning the camera somewhere NEW. The hole over the speaker never got a
  -- frame to open in. Adding a focus for the subject (see `World:draw`) does
  -- nothing at all until this runs.
  --
  -- So when the simulation is stopped, tick the x-ray on the real clock. Only
  -- the visible slice, only while frozen, and `updateXray`'s own early-outs
  -- still take almost every tree out in a couple of instructions.
  if dt == 0 and realDt > 0 then
    local vis = self.visTrees
    for i = 1, #vis do
      local t = vis[i]
      if t.updateXray then t:updateXray(realDt) end
    end
  end
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

  self:updateSpread(dt)
  self:updatePeakBots(dt)

  -- speech bubbles
  for i = #self.speeches, 1, -1 do
    local s = self.speeches[i]
    s.t = s.t + realDt
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
    for _ = nodes + 1, TU.cobalt.nodeFloor + (self.extraNodes or 0) do
      self:spawnCobaltNode()
    end
  end

  if Decals.update then Decals.update(realDt) end
  if VFX.update then VFX.update(realDt) end
  if Music.setIntensity then Music.setIntensity(self:threat()) end
  if Music.setO2 then Music.setO2(self.o2 / TU.o2.target) end
end

--- Oxygen reads the standing forest. Saplings count a little, elders count
--- double, and siphons apply a debt that bleeds off once they are driven away.
local O2W = TU.o2.weight
--- Walks the whole forest, so it runs on a slice cadence rather than every
--- frame: at nine hundred trees this was the single most expensive thing in the
--- update, and the reading does not need to be resampled 60 times a second.
function World:updateOxygen(dt)
  -- The reading eases every frame; only the census that feeds it is amortised.
  -- (Running both on the census frame integrated 7*dt every four frames, so
  -- everything time-based in here ran 1.75x fast.)
  self:applyOxygen(dt)

  self.o2Frame = (self.o2Frame or 0) + 1
  if self.o2Frame < 4 and self.forestPoints then return end
  self.o2Frame = 0

  local mature, elders, points, alive = 0, 0, 0, 0
  for i = 1, #self.trees do
    local t = self.trees[i]
    if t.alive then alive = alive + 1 end
    if t.alive and t.stage ~= "dead" and t.stage ~= "dying" then
      local s = t.stage
      if s == "elder" then elders = elders + 1
        points = points + O2W.elder * self.chips:get("elderWeight", 1)
      elseif s == "mature" then mature = mature + 1 points = points + O2W.mature
      elseif s == "young" then points = points + O2W.young
      else points = points + O2W.sapling * self.chips:get("saplingWeight", 1) end
    end
  end
  self.matureTrees, self.elderTrees, self.forestPoints = mature, elders, points
  self.treeCount = alive
end

--- The cheap per-frame half: ease the reading toward whatever the last census
--- said the forest is worth, and run the win/lose checks.
function World:applyOxygen(dt)
  local points = self.forestPoints or 0
  -- Eased, not linear: a linear reading sits at 3% ninety seconds in, which
  -- tells a new player they are in for a fifty-minute grind. The curve pays the
  -- first saplings visibly and makes the last stretch the hard one.
  local frac = U.saturate(points / (self.fullForest or TU.o2.fullForest))
  local raw = TU.o2.target * frac ^ 0.78
  self.o2Raw = raw
  -- Once the rig is on the ground the meter may only fall. Saplings put in
  -- during the last cycle were still maturing while the rig drained, so for the
  -- first half-minute of the extraction the reading went *up* underneath a line
  -- of dialogue reading "it is taking the air back".
  if self.phase == "extraction" and self.extractRaw then
    raw = math.min(raw, self.extractRaw)
  end
  -- Siphon debt is capped relative to the reading, so a bad night is a real bite
  -- out of your progress but can never erase the whole run's work.
  self.o2DebtCap = math.min(TU.o2.debtCap, math.max(6, raw * 0.28))
  self.o2Debt = math.min(self.o2DebtCap,
                         math.max(0, (self.o2Debt or 0) - TU.o2.debtRecover * dt))

  if self.phase == "extraction" and self.boss and self.boss.alive then
    self.extractionT = (self.extractionT or 0) + dt
    if (self.drainPause or 0) > 0 then
      self.drainPause = self.drainPause - dt
    else
      self.bossDrain = (self.bossDrain or 0) + (self.bossDrainRate or 0.4) * dt
    end
  end
  local ideal = raw - self.o2Debt - (self.bossDrain or 0)
  ideal = U.clamp(ideal, 0, TU.o2.target)
  local rate = ideal > self.o2 and TU.o2.rise or TU.o2.fall
  self.o2 = U.damp(self.o2, ideal, rate, dt)
  self.o2Ideal = ideal
  -- The highest the sky ever got. What the rig takes back at the end is not a
  -- comment on how well the run was played, and the title screen's record is
  -- about the forest, not the fight.
  self.o2Peak = math.max(self.o2Peak or 0, self.o2)

  local step = math.floor(self.o2 / 25)
  if step > (self.o2Step or 0) and step > 0 then
    self.o2Step = step
    Audio.play("o2_milestone")
    Signal.emit("o2:milestone", step * 25)
  end

  -- Filling the sky is the win condition, not surviving a fixed number of
  -- nights: the moment the air is breathable, they come to take it.
  --
  -- ...EXCEPT DURING THE LAST DAY, where "the moment" costs the game a scene.
  -- On a fast run the air fills during cycle 7's DAY, the extraction starts
  -- there, and cycle 7 never reaches a dusk -- so `S.lastNight`, which is
  -- queued from the one `phase:dusk` handler in story.lua, is never queued at
  -- all. Measured across ten seeds: 777 and 314 have no cycle-7 dusk sample in
  -- the trace, the beat never plays, and the script runs from "i will plant
  -- more" straight to "what is that" -- 198 and 213 seconds of silence, which
  -- is the exact gap that beat was written to fill. The better the run, the
  -- likelier it was lost, because filling the sky early is what deleted it.
  --
  -- The same day also carries the `lastnight` chatter pool and the dial's
  -- THE LAST NIGHT state, so a cycle 7 without a night drops all of it. Holding
  -- the rig until that dusk costs at most one day -- and the rig arriving at
  -- nightfall is when everything else in this game arrives.
  local lastDay = (self.cycle or 1) >= TU.cycle.count
                  and (self.phase == "day" or self.phase == "dawn")
  if self.o2 >= TU.o2.target - 0.3 and self.phase ~= "extraction"
     and self.phase ~= "ending" and not lastDay then
    self:beginExtraction()
  end

  -- ...and if the rig empties the sky before you bring it down, that is the run.
  if self.phase == "extraction" and self.o2 <= 0.05 and not self.failed
     and (self.extractionT or 0) > 10 then
    self:fail()
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
        qSelf, qCount = t, 0
        self.hTree:each(t.x, t.y, 90, fCountNeighbours)
        if qCount >= 3 then m = m * 1.35 end
      end
      -- eldering rides the same multiplier, with its own chip on top
      if t.stage == "mature" or t.stage == "elder" then
        m = m * self.chips:get("elderRate", 1)
      end
      t.growthMul = m

      -- Only trees on the edge of the wood seed new ground. A tree ringed by
      -- neighbours has nowhere to put a sapling, and letting it try anyway is
      -- what turned the island into a uniform mat.
      local onFrontier = true
      if t.stage == "mature" or t.stage == "elder" then
        qSelf, qCount = t, 0
        self.hTree:each(t.x, t.y, TU.tree.frontierRadius, fCountNeighbours)
        onFrontier = qCount < self.chips:get("frontierMax", TU.tree.frontierMax)
      end
      if onFrontier and (t.stage == "mature" or t.stage == "elder") then
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
    qCount = 0
    self.hEnemy:each(p.x, p.y, 420, fCountAlive)
    close = qCount
  end
  return U.saturate(n / 22 * 0.6 + close / 8 * 0.4)
end

-------------------------------------------------------------------------- draw
function World:draw(camera)
  self.camera = camera
  local g = love.graphics

  if Tree.setViewFromCamera then Tree.setViewFromCamera(camera) end
  -- exact x-ray target: canopies clear around the player, not the camera
  if Tree.setFocus and self.player then
    Tree.setFocus(self.player.x, self.player.y, 78)
    -- ...and a second hole over anyone lying on the ground. The HUD pip says
    -- where a downed bot fell, which is most of the problem, but it does not
    -- let you see the thing you have to walk onto and pick up: under a closed
    -- canopy that last ten feet was a guess. Only the downed get one. A focus
    -- per bot would open the whole forest, which is the other way to lose it.
    local BP, opened = TU.hud.botPip, 0
    for i = 1, #self.bots do
      if opened >= BP.xrayMax then break end
      local b = self.bots[i]
      if b.alive and b.state == "down" and not b.carried
         and camera:visible(b.x, b.y, 90) then
        Tree.addFocus(b.x, b.y, BP.xrayRadius)
        opened = opened + 1
      end
    end
    -- ...and a soft one on whatever a cutscene is framing. A captured `radio`
    -- beat put the camera exactly on the speaking bot and the bot was under a
    -- closed canopy for the whole scene: the shot was correct and the subject
    -- was not in it. `Camera:focus()` is where the camera is actually looking,
    -- offsets folded in, which during a beat is the entity Dialogue is panning
    -- to -- so this needs nothing from the dialogue runtime and cannot
    -- disagree with the framing. It is damped by the pan on the way in and by
    -- `xrayRate` on the way out, so it cannot flicker, and a frame with no
    -- cutscene running does not execute any of it.
    if self.cutscene then
      local CS = TU.cutscene
      local fx, fy = camera:focus()
      Tree.addFocus(fx, fy, CS.radius, CS.focus)
    end
  end
  if VFX.setViewport then
    local vx, vy, vw, vh = camera:viewRect(0)
    VFX.setViewport(vx, vy, vw, vh, 120)
  end

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
  -- `visTrees` is the forest the camera can see, in depth order, built by the
  -- update sweep that had already worked out `onScreen` for its own culling.
  -- Both tree passes read it: this one used to walk all 722 trees to find the
  -- 442 that draw, and the entity pass below used to walk them all again.
  local vis = self.visTrees
  for i = 1, #vis do
    local t = vis[i]
    if t.drawShadow then t:drawShadow(sunA, sunL) end
  end
  if Tree.endPass then Tree.endPass() end
  local lists = self.mobileLists
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

  -- Depth-sorted entity pass. Only the things that actually move are sorted -
  -- fifty-odd entries rather than five hundred - because the forest arrives
  -- already in depth order and the two lists are merged as they are drawn. A
  -- Lua comparator called nine thousand times a frame to re-establish an order
  -- that had not changed since the last planting was the single most expensive
  -- thing left in `World:draw`.
  local dl = self.drawList
  for i = #dl, 1, -1 do dl[i] = nil end
  for l = 1, #lists do
    local list = lists[l]
    for i = 1, #list do
      local e = list[i]
      if e.alive and camera:visible(e.x, e.y, 140) then addDraw(dl, e) end
    end
  end
  if self.rig then addDraw(dl, self.rig) end
  if self.player then addDraw(dl, self.player) end
  table.sort(dl, bySortKey)

  local sx, sy = math.cos(sunA), math.sin(sunA)
  local ei, en = 1, #dl
  for ti = 1, #vis do
    local t = vis[ti]
    local tz = t._dz
    while ei <= en and dl[ei]._dz < tz do
      dl[ei]:draw() ei = ei + 1
    end
    t:draw(sx, sy)
  end
  while ei <= en do dl[ei]:draw() ei = ei + 1 end
  if Tree.endPass then Tree.endPass() end

  -- The canopy's backlight used to be a third additive pass over every crown
  -- in the forest, here. It is a term inside the tree shader now: measured, the
  -- separate pass was just over half of all the fill in the game -- and because
  -- it had no depth test and ran after the whole forest, most of what it
  -- painted was a hidden tree's rim landing on whatever stood in front of it.

  -- The rig goes last, over the canopy and over the canopy's backlight. It is
  -- standing on the trees, and it was being washed out by the additive rim
  -- pass above -- a hundred-foot machine with leaf highlights painted across
  -- its hull, at the climax of the run.
  if self.boss and self.boss.alive then self.boss:draw() end

  if VFX.draw then VFX.draw("world") end
  -- The "air" layer was never drawn in gameplay. Every effect on it has been
  -- invisible for the whole life of this build: pollen, fireflies, mist, blight
  -- spores, rift ambience and half of a Blight's death. The comment above about
  -- the additive pass sitting "under the air particles" says where it belongs.
  if VFX.draw then VFX.draw("air") end
  if VFX.draw then VFX.draw("additive") end

  self:drawRally()
  self:drawSpeech()
end

--- The standing order, drawn where the player put it.
function World:drawRally()
  if not self.rallyX then return end
  local x, y = self.rallyX, self.rallyY
  if not self.camera:visible(x, y, TU.rally.radius + 80) then return end
  local g = love.graphics
  local t = self.rallyT or 0
  local r = TU.rally.radius

  -- the field, as a slow breathing ring rather than a hard boundary
  local pulse = 0.5 + math.sin(t * 1.1) * 0.5
  Draw.setColor(P.accent, 0.055 + pulse * 0.03)
  g.circle("fill", x, y, r)
  Draw.setColor(P.accent, 0.18 + pulse * 0.1)
  Draw.dashedCircle(x, y, r, 26, 22, t * 7, 2)

  -- an expanding pulse each time it is newly planted
  if t < 1.2 then
    local k = t / 1.2
    Draw.setColor(P.accent, (1 - k) * 0.5)
    g.setLineWidth(3)
    g.circle("line", x, y, r * U.ease.outCubic(k))
    g.setLineWidth(1)
  end

  -- the flag
  local sway = math.sin(t * 2.2) * 0.09
  Draw.softShadow(x, y + 3, 13, 5, 0.34)
  Draw.setColor(P.shade(P.ramp.metal, 2.6))
  Draw.capsule("fill", x, y, x + sway * 8, y - 46, 2.4)
  Draw.setColor(P.accent, 0.92)
  g.polygon("fill", x + sway * 8, y - 46, x + sway * 8 + 22, y - 39,
                    x + sway * 8, y - 32)
  Draw.glow(x + sway * 8, y - 40, 34, P.accent, 0.35)
  Draw.setColor(P.accent, 0.5)
  g.circle("line", x, y, 9 + pulse * 2)
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
      -- ...with who is talking. `Bot:plateAlpha` returns 0 for the whole time a
      -- machine holds a speech slot, so this is the only place its name can be
      -- while it has something to say. THE HUMAN IS UNNAMED AND STAYS UNNAMED:
      -- he speaks through this queue too, and a label over his one bark would
      -- undo the thing the whole script protects.
      local name = (who.kind ~= "player") and who.name or nil
      self:drawBubble(who.x, who.y - (who.radius or 12) * 2.4 - rise, s.line, a,
                      name)
    end
  end
end

--- Register every light in the world with the lighting system.
function World:emitLights(Light)
  if self.player and self.player.emitLight then self.player:emitLight(Light) end
  if self.rig then self.rig:emitLight(Light) end
  local cam = self.camera
  local lists = self.mobileLists
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
--- NEW: the loss record carries the machine's whole ledger, not two numbers.
---
--- The memorial is the only place a name is ever read again, and a field that
--- exists only on the live bot is no use there -- `cycle` is the cycle the LOSS
--- was recorded in, so without `bornCycle` and `nights` the ending cannot say
--- how long anything lasted without inventing it. `epitaph` is the finished
--- line as `Bot:epitaph` cut it at the moment of death, which is the only
--- moment `age` and the machine's remaining charges are still true -- so
--- scenes/ending.lua can take `rec.epitaph` verbatim and fall back to the
--- fields only for a record that came back off a save.
Signal.on("bot:lost", function(bot, peaceful)
  local w = bot.world
  if not w or peaceful then return end
  local L = bot.log
  local line = bot:epitaph()
  w.stats.botsLost = w.stats.botsLost + 1
  w.lostNames = w.lostNames or {}
  w.lostNames[#w.lostNames + 1] = bot.name
  w.allLostNames = w.allLostNames or {}
  w.allLostNames[#w.allLostNames + 1] = { name = bot.name, type = bot.type,
                                          cycle = w.cycle, trait = bot.trait,
                                          planted = bot.planted or 0,
                                          built = bot.built or 0,
                                          epitaph = line,
                                          nights = L and L.nights or 0,
                                          bornCycle = L and L.bornCycle or w.cycle,
                                          downs = L and L.downs or 0,
                                          saves = L and L.saves or 0,
                                          carried = L and L.carried or 0,
                                          mined = L and L.mined or 0,
                                          shots = L and L.shots or 0,
                                          lit = L and L.lit or 0,
                                          walked = L and math.floor(L.walked) or 0,
                                          age = math.floor(bot.age or 0) }
  Signal.emit("bot:epitaph", bot.name, line)
end)

--- NEW: the one counter that makes a machine old.
---
--- Every bot still standing when the sun comes up has survived a night. That
--- single number is what `Bot:refreshWear` turns into the patina and the tick
--- marks a player can read off a crowd, and it is what `Bot:epitaph` falls back
--- to for a machine that did no work of its own. One pass over at most
--- forty-eight bots, once a cycle.
Signal.on("phase:dawn", function()
  local w = Signal._world
  if not w or not w.bots then return end
  for i = 1, #w.bots do
    local b = w.bots[i]
    if b.alive and b.state ~= "dead" and b.log then
      b.log.nights = b.log.nights + 1
      if b.refreshWear then b:refreshWear() end
    end
  end
end)

--- NEW: what a loss costs the crew.
---
--- A death used to change nothing in the world: a counter went up, two lists
--- grew, and the other machines carried on planting. One spatial query over the
--- neighbours now stops them working and sends them to the body for about
--- fourteen seconds -- see `T.bots.grief`, `Bot:workRate` and `Bot:pickWander`.
--- The player watches the crew put their work down and walk over, which is the
--- story of a loss told entirely in movement and costs one query.
---
--- Hoisted, not a closure: `Spatial:each` is called with this on every loss and
--- a five-upvalue closure per call was the single largest allocator in the game
--- before PERFORMANCE.md item 7 went through it.
local griefX, griefY = 0, 0
local function grieve(b)
  if not b.alive or b.state ~= "work" then return end
  b.grief = TU.bots.grief.time
  b.griefX, b.griefY = griefX, griefY
  -- On the ring, not on the body: `Bot:pickWander` keeps them there for the
  -- rest of the grief, but this first target is set directly and used to send
  -- every mourner to the corpse's exact coordinates. See T.bots.grief.standOff.
  local G = TU.bots.grief
  local ang = b.rng and b.rng:angle() or 0
  local dist = b.rng and b.rng:range(G.standOff, G.arrive) or G.standOff
  b.wx, b.wy = griefX + math.cos(ang) * dist, griefY + math.sin(ang) * dist
end

local function crewMourns(bot)
  local w = bot.world
  if not w or not w.hBot then return end
  if w.phase == "extraction" or w.phase == "ending" then return end
  griefX, griefY = bot.x, bot.y
  w.hBot:each(bot.x, bot.y, TU.bots.grief.radius, grieve)
end

--- Call the crew to a place, for a body that fell a while ago.
---
--- `crewMourns` runs on the death itself, and the grief it sets lasts
--- `T.bots.grief.time` -- fourteen seconds. The funeral beat cannot use that
--- window: a machine dies mid-fight, and the beat's "calm" guard then holds it
--- until the fight is over. Measured on seed 4242, the beat sat for 82 seconds
--- with zero bots within 240 units of the body for every one of them, and fired
--- through its own relief valve onto an empty clearing. The crew had mourned
--- properly, a minute earlier, and gone back to work.
---
--- So the funeral is CONVENED. The beat asks for the crew when it is otherwise
--- ready, and waits for them to walk over -- which is what the scene is.
function World:mournAt(x, y)
  if not (self.hBot and x and y) then return end
  if self.phase == "extraction" or self.phase == "ending" then return end
  griefX, griefY = x, y
  self.hBot:each(x, y, TU.bots.grief.radius, grieve)
end

Signal.on("bot:downed", crewMourns)
Signal.on("bot:lost", function(bot, peaceful)
  if not peaceful then crewMourns(bot) end
end)

--- NEW: and the body stays.
---
--- A loss used to leave nothing on the ground. The corpse is swept the frame it
--- dies, so both of the script's funeral beats -- whose delay and patience are
--- measured in minutes -- were playing over empty grass with a bot saying "yes"
--- at a patch of meadow; story.lua's own comment admits it for one of the two.
--- `Relic.addHusk` leaves a permanent, non-interactive, unlit husk at the spot:
--- see the husk note at the top of src/entities/relic.lua for why that is worth
--- more than a decal, and the `husk` block in tuning for what it costs.
---
--- Not on a peaceful shutdown. A machine that powered down at the extraction
--- walked onto the ship; only the ones that were killed are left behind.
Signal.on("bot:lost", function(bot, peaceful)
  if peaceful or not Relic.addHusk then return end
  local w = bot.world
  if not w then return end
  -- Nothing is left behind after the rig is down: the finale gathers the crew,
  -- the camera is on the boss, and a body appearing under the ending's own
  -- cutscene is a prop arriving during a curtain call.
  if w.phase == "ending" then return end
  Relic.addHusk(w, bot.x, bot.y, bot.type)
end)

-- Old Growth applies to what you plant next, not to the wood you already have:
-- retro-fitting it doubled the whole oxygen reading the moment it was drafted.
Signal.on("chip:added", function(chip)
  local w = chip._world
  if not w then return end
  if chip.id == "glassLungs" and w.player then
    w.player.maxHp = 1
    w.player.hp = 1
  elseif chip.id == "richSeam" then
    w.extraNodes = (w.extraNodes or 0) + 4
  end
end)

-- Each phase break buys the player a breath: the drill stops while the rig
-- reconfigures, so a long fight is not automatically a lost one.
Signal.on("boss:phase", function()
  local w = Signal._world
  if w then w.drainPause = TU.boss.phaseGap * 0.7 end
end)

Signal.on("enemy:killed", function(e)
  local w = e.world
  if w then w.stats.killed = w.stats.killed + 1 end
end)

return World
