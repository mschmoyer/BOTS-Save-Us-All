-- Dawn draft upgrades.
--
-- Six chips over a run, three offered at each dawn. That is six decisions, so
-- every card in here has to be one. A card earns its slot by changing a *rule*
-- -- where the wood grows, what a bot does, what a night is shaped like, what a
-- corpse is worth -- and not by putting a percentage on a number the player
-- cannot see. The pool was forty-six scalars once; it is twenty-six rules now,
-- and the cards that went are listed at the bottom of this comment so nobody
-- puts them back by accident.
--
-- A chip is data with, at most, four moving parts:
--
--   mod   = { key = value }        numbers behaviour code asks for by name via
--                                  `chips:get(key, default)`. How a second chip
--                                  touching the same key combines is declared
--                                  in STACK below -- never inferred from the
--                                  value, which is what made OLD GROWTH plus
--                                  TALL ORDER worth 3.35 in one draft order and
--                                  2.70 in the other.
--   onAdd = function(chips, world) one shot, the moment it is drafted.
--   tick  = function(chips, world, dt) with `every = seconds`; runs on *world*
--                                  time, so a fast headless capture and a real
--                                  session agree. Only owned chips tick.
--   on    = { ["signal"] = fn }    fn(chips, world, ...) while owned.
--
-- The last three are how a card changes a rule without a hook in somebody
-- else's file. Reach for them first; ask for a hook only when the rule lives
-- inside a function that has to behave differently halfway through.
--
-- Cut, and why: every card whose whole effect was a multiplier on an invisible
-- number (MYCELIUM, FAST ROOT, CANOPY, RAIN MEMORY, HARD HAT, BRIGHT EYES,
-- QUICK BOOT, SENTINEL, LAMP OIL, SECOND SHIFT, CHORUS, FIELD MEDIC, SWARM
-- LOGIC, KINETIC CUFFS, LONG ARM, OVERCHARGE, RECOIL, BRITTLE, DEEP DEPOSITS,
-- LODESTONE, TITHE, LONG LEGS, AFTERIMAGE, STEADY HAND, GREEN THUMB); the three
-- auto-takes (SURPLUS, and the pure-upside halves of OLD GROWTH and TALL
-- ORDER); the two never-takes (HELD BREATH, LAST LIGHT); SALVAGE, which paid
-- least exactly when bots started dying; HARD BARK, whose code deleted the
-- Spitter's only permanent effect; and VEIN SENSE, which nothing ever drew.
local Class   = require("src.core.class")
local U       = require("src.core.util")
local Signal  = require("src.core.signal")
local TU      = require("src.game.tuning")
local CobaltE = require("src.entities.cobalt")

local Chips = Class("Chips")

local F = { GROWTH = "GROWTH", COMBAT = "COMBAT", LOGISTICS = "LOGISTICS",
            BOTS = "BOTS", PLAYER = "PLAYER" }
Chips.families = F

--- How a modifier combines when a second chip writes the same key. Declared,
--- not guessed. "mul" is the default because most keys are ratios; anything
--- that is a count, a cap or an absolute lives here explicitly.
local STACK = {
  botHp       = "add",     -- health points, not a ratio
  fellYield   = "add",     -- cobalt per tree
  frontierMax = "min",     -- a cap: the tightest rule wins
}
local STACK_DEFAULT = "mul"

------------------------------------------------------------------- the rule kit
-- Small helpers the cards below share. Nothing in here knows about any one
-- card; if two cards want the same trick it belongs up here.

local cos, sin, floor, min, max = math.cos, math.sin, math.floor, math.min, math.max

--- Nearest walkable point, if the island has an opinion.
local function onLand(w, x, y)
  if w.terrain and w.terrain.nearestLand then
    local lx, ly = w.terrain:nearestLand(x, y)
    if lx then return lx, ly end
  end
  return x, y
end

--- Loose cobalt on the ground, worth `value`, thrown a little way. Loose chunks
--- magnetise to the player, so this is money you have to walk to.
local function dropChunk(w, x, y, value, kick)
  local c = CobaltE.new(x, y, w, w.rng, false)
  if value then c.left = max(1, floor(value)) end
  if kick and kick > 0 then
    local a = w.rng:angle()
    c:push(cos(a), sin(a), kick)
  end
  w:addEntity(w.cobalts, w.hCobalt, c)
  return c
end

--- Every bot that is standing and answering.
local function eachBot(w, fn)
  local list = w.bots
  for i = 1, #list do
    local b = list[i]
    if b.alive and b.state ~= "dead" then fn(b) end
  end
end

--- Somewhere to be sent: the standing order if there is one, home if not.
local function orderPoint(w)
  if w.rallyX then return w.rallyX, w.rallyY end
  return w.homeX, w.homeY
end

--------------------------------------------------------------------- FURROW
-- A Planter picks its next patch of ground near itself, or near the flag if
-- there is one -- either way it wanders. Furrowed, it walks a straight line at
-- the flag and keeps walking once it is past, so the wood it lays down is a
-- corridor you aimed rather than a blot around wherever the crew happened to
-- be. It also plants that line at more than twice its usual cadence, and it
-- does nothing whatever until you plant a flag.
local FURROW_STEP  = { 90, 150 }
local FURROW_SPILL = 38          -- lateral jitter, so it is a furrow not a wire
local FURROW_EVERY = 7.0         -- ceiling on the plant timer while walking it

local function furrowWander(b)
  local w = b.world
  if not (w and w.rallyX) then return false end
  local dx, dy, d = U.norm(w.rallyX - b.x, w.rallyY - b.y)
  if d > 90 then
    b.furrowX, b.furrowY = dx, dy
  else
    -- past the flag: hold the heading and keep drawing the line outward
    dx, dy = b.furrowX or dx, b.furrowY or dy
  end
  local px, py = -dy, dx
  local j = b.rng:range(-FURROW_SPILL, FURROW_SPILL)
  local step = b.rng:range(FURROW_STEP[1], FURROW_STEP[2])
  b.wx, b.wy = onLand(w, b.x + dx * step + px * j, b.y + dy * step + py * j)
  b.actionT = min(b.actionT or FURROW_EVERY, FURROW_EVERY)
  return true
end

local function furrowFit(b)
  if b.type ~= "planter" or b.furrowed then return end
  b.furrowed = true
  local base = b.pickWander
  b.pickWander = function(self, minSoil)
    if furrowWander(self) then return end
    return base(self, minSoil)
  end
end

--------------------------------------------------------------- DEAD RECKONING
--- The nearest thing that could put a downed bot back together: a lit Beacon,
--- or the Home Rig, which always can.
local CRAWL_REACH = 1300
local function nearestLight(w, b)
  local bx, by = b.x, b.y
  local beacon = w.hBot:nearest(bx, by, CRAWL_REACH, function(o)
    return o.type == "beacon" and o.state == "work" and o.alive
  end)
  local lx, ly, ld
  if beacon then lx, ly, ld = beacon.x, beacon.y, U.dist(bx, by, beacon.x, beacon.y) end
  if w.homeX then
    local hd = U.dist(bx, by, w.homeX, w.homeY)
    if hd < CRAWL_REACH and (not ld or hd < ld) then
      return w.homeX, w.homeY, true
    end
  end
  return lx, ly, false
end

------------------------------------------------------------------- catalogue
-- rarity: 1 common, 2 uncommon, 3 rare. Rarity is swinginess, not strength: a
-- rare is a build you play around, not a common with a bigger number on it.
local C = {
  ------------------------------------------------------------------- commons
  { id = "scrapfall", f = F.COMBAT, r = 1, name = "SCRAPFALL",
    desc = "The Blight leaves cobalt where it falls.",
    -- A night is pure loss otherwise: things you own get eaten and nothing
    -- comes back. This makes standing and fighting an income, which is a
    -- different answer to a wave than herding it away from the trees.
    on = { ["enemy:killed"] = function(chips, w, e)
      if not e or e.kind ~= "enemy" then return end
      local cost = (e.def and e.def.cost) or 4
      local n = cost >= 14 and 3 or 1
      for _ = 1, n do
        dropChunk(w, e.x + w.rng:range(-8, 8), e.y + w.rng:range(-8, 8), nil, 110)
      end
    end },
  },

  { id = "deadfall", f = F.GROWTH, r = 1, name = "DEADFALL",
    desc = "A tree the Blight fells takes its feller down with it.",
    -- Changes what an outlying grove is for. Undefended trees stop being pure
    -- loss and start being a cost the swarm pays to come inland.
    on = { ["tree:lost"] = function(chips, w, t, by)
      if by == "acid" or by == "beam" then return end
      w:areaShove(t.x, t.y, 96, 420, 3, 0.7)
    end },
  },

  { id = "deepRoots", f = F.GROWTH, r = 1, name = "DEEP ROOTS",
    desc = "Trees take twice as long to chew down.",
    -- The night's tempo, not its arithmetic: twelve seconds on a tree is long
    -- enough to cross a grove and do something about it, six is not.
    mod = { chewTime = 2.0 } },

  { id = "pinBreaker", f = F.COMBAT, r = 1, name = "PIN BREAKER",
    desc = "Your shove can move armoured Blight.",
    -- A capability: the Bulwark stops being a thing only a Sentry can answer.
    flag = true },

  { id = "kickstart", f = F.PLAYER, r = 1, name = "KICKSTART",
    desc = "Dashing releases a shockwave.",
    -- Turns the movement verb into an offensive one; you stop dashing away.
    flag = true },

  { id = "mutualAid", f = F.BOTS, r = 1, name = "MUTUAL AID",
    desc = "Bots go to their own. One standing over a downed friend brings it back.",
    -- The rescue decision, answered by the crew instead of by you -- but only
    -- where the crew is dense. A lone outpost still needs your legs.
    every = 0.25,
    on = { ["bot:downed"] = function(chips, w, b)
      -- somebody nearby drops what they are doing and walks over
      local helper = w.hBot:nearest(b.x, b.y, 700, function(o)
        return o.alive and o.state == "work" and not o.static and o ~= b
      end)
      if helper then helper.wx, helper.wy = b.x, b.y end
    end },
    tick = function(chips, w, dt)
      local list = w.bots
      for i = 1, #list do
        local b = list[i]
        if b.alive and b.state == "down" and not b.carried then
          local mate = w.hBot:nearest(b.x, b.y, 34, function(o)
            return o.alive and o.state == "work" and not o.static
          end)
          if mate then
            b.aidT = (b.aidT or 0) + dt
            if b.aidT >= 3.0 then
              b.aidT = 0
              b:revive()
              w.stats.rescued = w.stats.rescued + 1
            end
          else
            b.aidT = 0
          end
        end
      end
    end },

  { id = "reclamation", f = F.LOGISTICS, r = 1, name = "RECLAMATION",
    desc = "A bot that dies leaves the price of its replacement on the ground.",
    -- The old SALVAGE refunded half of the *base* cost, so it paid five cobalt
    -- for a sixty-cobalt Planter and paid least exactly when bots started
    -- dying. This pays the escalated price, and it pays it where the bot died,
    -- which is a place you have to go.
    on = { ["bot:lost"] = function(chips, w, b, peaceful)
      if peaceful or not b then return end
      local cost = w:botCost(b.type)
      if cost <= 0 then return end
      local n = U.clamp(floor(cost / 8) + 1, 1, 6)
      local per = max(1, floor(cost / n))
      for _ = 1, n do
        dropChunk(w, b.x + w.rng:range(-14, 14), b.y + w.rng:range(-14, 14), per, 130)
      end
    end },
  },

  { id = "pioneer", f = F.GROWTH, r = 1, name = "PIONEER",
    desc = "Trees can root in blight scars, and heal them.",
    -- Opens ground the island otherwise keeps shut, which changes where the
    -- flag is worth planting.
    flag = true },

  ----------------------------------------------------------------- uncommons
  { id = "furrow", f = F.GROWTH, r = 2, name = "FURROW",
    desc = "Planters walk the line to the flag, planting it as they go.",
    -- Dead until you give an order, and then it is the only card that lets you
    -- draw the shape of the wood by hand.
    onAdd = function(chips, w) eachBot(w, furrowFit) end,
    on = { ["bot:spawned"] = function(chips, w, b) furrowFit(b) end },
  },

  { id = "muster", f = F.BOTS, r = 2, name = "MUSTER",
    desc = "At dusk, every bot that can walk goes to the flag.",
    -- The flag stops being only a work order and becomes a muster point, so
    -- the ground you point at is the ground your crew survives the night on --
    -- and every other grove is on its own until morning.
    on = { ["phase:dusk"] = function(chips, w)
      local tx, ty = orderPoint(w)
      if not tx then return end
      eachBot(w, function(b)
        if b.static or b.state ~= "work" then return end
        local a, d = w.rng:angle(), w.rng:range(0, 150)
        b.wx, b.wy = onLand(w, tx + cos(a) * d, ty + sin(a) * d)
      end)
    end },
  },

  { id = "seedBank", f = F.GROWTH, r = 2, name = "SEED BANK",
    desc = "Hand-planting is free.",
    -- Makes the player a Planter. It is the one card that pays you for walking
    -- the empty half of the island yourself.
    flag = true },

  { id = "deadReckoning", f = F.BOTS, r = 2, name = "DEAD RECKONING",
    desc = "The downed do not wait. They drag themselves to the nearest light.",
    -- The other answer to the rescue decision, and the opposite build to
    -- MUTUAL AID: this one is paid for in Beacons, and it rewards spacing them
    -- out over the island rather than stacking them where you already stand.
    every = 0,
    tick = function(chips, w, dt)
      local speed = 30
      local list = w.bots
      for i = 1, #list do
        local b = list[i]
        if b.alive and b.state == "down" and not b.carried then
          local tx, ty, atRig = nearestLight(w, b)
          if tx then
            local dx, dy, d = U.norm(tx - b.x, ty - b.y)
            if atRig and d < TU.world.homeRadius * 0.7 then
              b:revive()
              w.stats.rescued = w.stats.rescued + 1
            elseif d > 10 then
              b.x, b.y = b.x + dx * speed * dt, b.y + dy * speed * dt
              b.crawling = true
            end
          end
        end
      end
    end },

  { id = "richSeam", f = F.LOGISTICS, r = 2, name = "RICH SEAM",
    desc = "Four more deposits out there, and they come back twice as fast.",
    -- (The four extra nodes are applied by world.lua's chip:added handler.)
    mod = { nodeRespawn = 0.5 } },

  { id = "clearCut", f = F.LOGISTICS, r = 2, name = "CLEAR CUT",
    desc = "Felling a tree yields 4 cobalt. The Blight can smell it from further away.",
    mod = { fellYield = 4, blightFocus = 1.8 } },

  { id = "thornburst", f = F.COMBAT, r = 2, name = "THORNBURST",
    desc = "Killed Blight leaves a spore cloud that damages its kin.",
    flag = true },

  { id = "scrapDoctrine", f = F.BOTS, r = 2, name = "SCRAP DOCTRINE",
    desc = "Bots cost 35% less. Every one of them is made of tin.",
    mod = { botCost = 0.65, botHp = -2 } },

  { id = "monoculture", f = F.GROWTH, r = 2, name = "MONOCULTURE",
    desc = "Trees grow 60% faster, and only the outermost of them will seed at all.",
    mod = { growRate = 1.6, frontierMax = 2 } },

  --------------------------------------------------------------------- rares
  { id = "oldGrowth", f = F.GROWTH, r = 3, name = "OLD GROWTH",
    desc = "Trees reach their elder years three times sooner. An elder seeds no more.",
    -- Was the one card that decided whether a run could reach its win
    -- condition, and it cost nothing. It costs the forest's compounding now:
    -- your wood converts into oxygen instead of into more wood, and if you take
    -- it early the frontier stops advancing while you still need it to.
    mod = { elderRate = 3.0 },
    every = 1.0,
    tick = function(chips, w, dt)
      local trees = w.trees
      for i = 1, #trees do
        local t = trees[i]
        if t.alive and t.stage == "elder" then t.nextSpread = math.huge end
      end
    end },

  { id = "tallOrder", f = F.GROWTH, r = 3, name = "TALL ORDER",
    desc = "Elders count double. Saplings count for nothing at all.",
    -- The other half of the elder build. On its own it is a bet that the wood
    -- you already have will get old before the deadline; with OLD GROWTH it is
    -- a race to the rig with a crew you did not spend the time to build.
    mod = { elderWeight = 2.0, saplingWeight = 0 } },

  { id = "oneFront", f = F.COMBAT, r = 3, name = "ONE FRONT",
    desc = "The Blight comes from one quarter of the island. Twice as much of it comes.",
    -- Every other night you find out where the pressure is and react. This one
    -- tells you at dawn and never changes its mind, so Sentries and Beacons
    -- stop being reactive purchases and start being a wall you are building.
    mod = { budget = 2.0 },
    onAdd = function(chips, w)
      w.frontSide = (w.director and w.director.side) or w.rng:int(0, 3)
    end,
    every = 0.2,
    tick = function(chips, w, dt)
      if w.director and w.frontSide then w.director.side = w.frontSide end
    end },

  { id = "deepWinter", f = F.COMBAT, r = 3, name = "DEEP WINTER",
    desc = "Nights are a quarter shorter. Twice as much comes out of them.",
    mod = { nightLen = 0.75, budget = 2.0 } },

  { id = "bramble", f = F.COMBAT, r = 3, name = "BRAMBLE",
    desc = "The wood fights back. Anything chewing a tree bleeds for it.",
    -- A Chomper needs six seconds on a mature tree and dies at about five, so
    -- a defended forest stops needing to be defended and the night becomes
    -- about your bots and your saplings instead. That is a different game, and
    -- it is what a rare is for.
    every = 1.8,
    tick = function(chips, w, dt)
      local list = w.enemies
      for i = 1, #list do
        local e = list[i]
        if e.alive and not e.fleeing and (e.chewT or 0) > 0.25 then
          local t = e.target
          e:damage(1, t and t.x or e.x, t and t.y or e.y)
        end
      end
    end },

  { id = "copyWork", f = F.BOTS, r = 3, name = "COPY WORK",
    desc = "Builders build whatever you built last, not just Planters.",
    -- Turns the Builder from a Planter dispenser into a workforce that copies
    -- your intent, at half the escalated price of the thing it copies. Two
    -- Builders and a Sentry is a build order now.
    on = { ["bot:built"] = function(chips, w, b, free)
      if not b or free then return end
      -- Until world.lua passes `free` through, a builder's own output is
      -- indistinguishable from yours; ignoring Planters keeps it stable.
      if b.type == "builder" then return end
      if free == nil and b.type == "planter" then return end
      w.copyType = b.type
    end },
  },

  { id = "warranty", f = F.BOTS, r = 3, name = "WARRANTY",
    desc = "Every bot survives its first death.",
    flag = true },

  { id = "groundbreak", f = F.PLAYER, r = 3, name = "GROUNDBREAK",
    desc = "Your pulse plants a ring of saplings where it lands.",
    -- Your panic button is now your fastest planter, and it costs eight cobalt
    -- a go. Where you spend the charge stops being only about the swarm.
    on = { ["player:pulse"] = function(chips, w, p)
      local r = TU.player.pulse.radius * 0.58
      local a0 = w.rng:angle()
      for i = 0, 4 do
        local a = a0 + i * (U.TAU / 5)
        w:plantTree(p.x + cos(a) * r, p.y + sin(a) * r, "player")
      end
    end },
  },

  { id = "glassLungs", f = F.PLAYER, r = 3, name = "GLASS LUNGS",
    desc = "Everything you do is 25% faster. One hit puts you down.",
    mod = { moveSpeed = 1.25, dashCd = 0.75 } },
}

Chips.catalogue = C
local byId = {}
for _, c in ipairs(C) do byId[c.id] = c end
Chips.byId = byId

------------------------------------------------------------------ signal wiring
-- One dispatcher per signal the catalogue listens for, installed once for the
-- process and routed through the world that is actually running. Registering
-- per-chip handlers at draft time leaks them into the next run, which held the
-- whole of a finished world alive and fired its rules inside the new one.
local ROUTES = {}
for _, c in ipairs(C) do
  if c.on then
    for name, fn in pairs(c.on) do
      local list = ROUTES[name]
      if not list then list = {} ROUTES[name] = list end
      list[#list + 1] = { id = c.id, fn = fn }
    end
  end
end

local wired = false
local function wireSignals()
  if wired then return end
  wired = true
  for name, list in pairs(ROUTES) do
    Signal.on(name, function(a, b, c, d)
      local w = Signal._world
      local ch = w and w.chips
      if not ch then return end
      for i = 1, #list do
        local r = list[i]
        if (ch.owned[r.id] or 0) > 0 then r.fn(ch, w, a, b, c, d) end
      end
    end)
  end
end

--------------------------------------------------------------------- instance
function Chips:init(world)
  self.world = world
  self.owned = {}
  self.mods = {}
  self.list = {}
  self.acc = {}
  wireSignals()

  -- Rules that need a frame need it on *world* time: Timer.global runs on the
  -- wall clock, which a fast headless capture leaves eight times behind. One
  -- wrapper per world, and it dies with the world.
  if world and type(world.update) == "function" and rawget(world, "update") == nil then
    local base = world.update
    world.update = function(w, dt)
      base(w, dt)
      local ch = w.chips
      if ch and ch.tick then ch:tick(dt) end
    end
  end
end

function Chips:add(chip)
  if type(chip) == "string" then chip = byId[chip] end
  if not chip then return end
  self.owned[chip.id] = (self.owned[chip.id] or 0) + 1
  self.list[#self.list + 1] = chip
  if chip.mod then
    for k, v in pairs(chip.mod) do
      local cur = self.mods[k]
      if cur == nil then
        self.mods[k] = v
      else
        local how = STACK[k] or STACK_DEFAULT
        if how == "add" then self.mods[k] = cur + v
        elseif how == "min" then self.mods[k] = min(cur, v)
        elseif how == "max" then self.mods[k] = max(cur, v)
        else self.mods[k] = cur * v end
      end
    end
  end
  if chip.onAdd and self.world then chip.onAdd(self, self.world) end
  chip._world = self.world
  Signal.emit("chip:added", chip)
end

function Chips:has(id) return (self.owned[id] or 0) > 0 end
function Chips:get(key, default)
  local v = self.mods[key]
  if v == nil then return default end
  return v
end
function Chips:count() return #self.list end

--- Owned rules that want a frame. Driven from the world's own update, so it is
--- world time and it stops when the world does.
function Chips:tick(dt)
  local w = self.world
  if not w or w.phase == "ending" then return end
  local list = self.list
  for i = 1, #list do
    local c = list[i]
    if c.tick then
      local every = c.every or 0
      if every <= 0 then
        c.tick(self, w, dt)
      else
        local a = (self.acc[c.id] or 0) + dt
        if a >= every then
          self.acc[c.id] = 0
          c.tick(self, w, a)
        else
          self.acc[c.id] = a
        end
      end
    end
  end
end

--- Three distinct offers, weighted by rarity and biased away from what you have.
function Chips:draft(rng, n, cycle)
  n = n or 3
  local pool = {}
  for _, c in ipairs(C) do
    if not self:has(c.id) then
      local weight = (c.r == 1 and 6 or (c.r == 2 and 3 or 1))
      weight = weight + (cycle or 1) * (c.r - 1) * 0.6      -- rares get likelier late
      for _ = 1, max(1, floor(weight)) do pool[#pool + 1] = c end
    end
  end
  local out, seen = {}, {}
  local guard = 0
  while #out < n and guard < 400 do
    guard = guard + 1
    local c = rng:pick(pool)
    if c and not seen[c.id] then seen[c.id] = true out[#out + 1] = c end
  end
  return out
end

return Chips
