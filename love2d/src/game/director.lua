-- Wave author. Spends a per-night budget on enemy cards along a pacing curve so
-- nights have shape: a probe, a lull, a real push, and a final surge.
--
-- It used to author exactly one night and play it seven times. The composition
-- was a hard-coded weight per type with no cycle term in it, the pacing curve
-- was the same ten numbers every night, and every wave walked in from the same
-- edge -- so night six was night three with a bigger number in front of it, and
-- the middle of the run was a treadmill. Four things changed, and none of them
-- is "more budget":
--
--   * The mix is a function of the cycle. The Chomper's share falls from all of
--     night one to about a tenth of night seven while the armoured, the ranged
--     and the support rise, so the same budget buys a different problem.
--   * The pacing curve is blended from an early shape and a late one. Early
--     nights breathe. Late nights barely do.
--   * Waves stop coming from one place. From cycle five the rift has two fronts;
--     from cycle four the Blight reinforces wherever it is currently eating; and
--     any Scar left standing through the day is a way in, so a night can begin
--     inside the wood instead of at the shore.
--   * Wardens and Maws arrive escorted, because a card whose whole point is to
--     change your target priority is not a card if it walks in alone.
local Class = require("src.core.class")
local U     = require("src.core.util")
local Signal = require("src.core.signal")
local TU    = require("src.game.tuning")

local Director = Class("Director")

-- Every enemy type in TU.enemy, in a fixed order.
--
-- Both loops below used `pairs(TU.enemy)`, and LuaJIT randomises its string
-- hash seed per process, so a string-keyed table walks in a different order in
-- every run. One of those loops builds the weighted pool the night's wave is
-- drawn from and the other breaks the escort's cheapest-cost tie, so the same
-- seed composed different nights in different processes. With this and the
-- matching fix in world/weather.lua, three same-seed runs produce byte-identical
-- traces -- which is the difference between a balance measurement and a guess.
local ENEMY_ORDER = {}
for name, def in pairs(TU.enemy) do
  if type(def) == "table" and def.from then ENEMY_ORDER[#ENEMY_ORDER + 1] = name end
end
table.sort(ENEMY_ORDER)

function Director:init(world)
  self.world = world
  -- Seeded from the world, not a constant: otherwise every playthrough on every
  -- machine gets byte-identical waves forever.
  self.rng = U.rng((world and world.seed or 1) * 7919 + 919)
  self.active = false
  self.budget, self.spent = 0, 0
  self.t, self.dur = 0, 1
  self.nextT = 0
  self.cycle = 1
  self.side = 0
  self.sideB = nil
  self.scarsLeft = 0
  self.hotT = 0

  -- `enemy:targeted` was emitted by the Chomper and listened to by nothing at
  -- all. It fires where the Blight actually has its teeth in something now, and
  -- this is what it is for: from cycle four a share of every wave lands on the
  -- last place the Blight was winning instead of at the shore. A grove that is
  -- being eaten gets reinforced, which turns a late night from an even spread of
  -- attrition into a siege you have to break -- a different problem, for the
  -- same money.
  Signal.on("enemy:targeted", function(e, target) self:onTargeted(e, target) end, self)

  -- `tree:lost` was emitted and listened to by nothing. It is the record of
  -- where the night actually won, and that is where the Blight digs in at
  -- dawn -- see rootRemaining().
  Signal.on("tree:lost", function(t) self:onTreeLost(t) end, self)
end

--- Remember where the forest was taken tonight. A short ring, because the
--- point is where the Blight was winning *recently*, not a full ledger.
local WOUND_MAX = 48
function Director:onTreeLost(t)
  if not self.active or self.world ~= Signal._world or not t then return end
  local w = self.wounds
  if not w then w = {}; self.wounds = w end
  w.n = (w.n or 0) % WOUND_MAX + 1
  w[w.n] = { x = t.x, y = t.y }
end

--- Ignore anything that did not happen in the world this Director belongs to: a
--- Director from an abandoned run is still on the bus and has no way off it.
function Director:onTargeted(e, target)
  if not self.active or self.world ~= Signal._world then return end
  if not target or e and e.type == "scar" then return end
  self.hotX, self.hotY = target.x, target.y
  self.hotT = TU.cycle.focusDecay
end

--------------------------------------------------------------------- the night
function Director:beginNight(cycle, duration, extraBudget)
  if self.active then self:endNight() end
  self.cycle = cycle
  -- The night's pressure scales with the forest, so a big wood is a big target.
  -- A fixed budget against an exponential forest is a threat that shrinks.
  local trees = self.world and self.world.treeCount or 0
  self.budget = TU.cycle.budget[math.min(cycle, #TU.cycle.budget)]
                + trees * TU.cycle.budgetPerTree
  self.budget = self.budget * (self.world.chips and self.world.chips:get("budget", 1) or 1)
                            * (extraBudget or 1)
  self.maxAlive = math.floor(TU.cycle.maxAlive[math.min(cycle, #TU.cycle.maxAlive)]
                             + trees * TU.cycle.maxAlivePerTree)
  self.spent = 0
  self.t = 0
  self.dur = math.max(0.1, duration - TU.cycle.directorLead)
  self.active = true
  self.nextT = 0.6
  self.side = self.rng:int(0, 3)
  -- From cycle five the rift opens on a second side, roughly opposite. One line
  -- can be held with Sentries and a Beacon; two cannot, and choosing which one
  -- to leave is the decision the second front exists to create.
  if cycle >= TU.cycle.frontsFrom then
    self.sideB = (self.side + 2 + (self.rng:chance(0.35) and self.rng:sign() or 0)) % 4
  else
    self.sideB = nil
  end
  self.hotT = 0
  -- What the player left standing this morning is where tonight starts.
  self.anchors = self:liveAnchors()
  Signal.emit("director:night", cycle, self.budget, self.side, #self.anchors)
end

function Director:endNight()
  if not self.active then return end
  self.active = false
  self.anchors = nil
  -- The Blight leaves this many behind at the coming dawn. `Enemy:flee` gets
  -- first refusal -- a Chomper with its teeth in a trunk becoming a Scar on
  -- the spot is the best-reading version of it -- and rootRemaining() spends
  -- whatever is left over.
  local q = TU.cycle.scarQuota
  self.scarsLeft = q[math.min(self.cycle, #q)] or 0
  Signal.emit("director:dawn", self.cycle)
end

--- Spend the rest of the dawn quota.
---
--- This existed as a quota and an `Enemy:flee` branch that could only fire if
--- an enemy happened to have its teeth in a tree at the exact tick of dawn.
--- By dawn the Sentries have almost always cleared the field, so across four
--- seeds the quota was claimed in 4.6% of daylight samples -- a whole system,
--- authored and wired, that never once fired. A quota is a thing you spend.
---
--- Where they dig in is the point. First choice is the ground the night took:
--- a wound left by a tree that went down in the small hours, which puts the
--- morning's problem exactly where last night's loss was. Failing that, an
--- anchor the night used. The Blight does not root in ground it never reached.
function Director:rootRemaining()
  local w = self.world
  if not w or (self.scarsLeft or 0) <= 0 then return 0 end
  local cap = (TU.enemy.scar and TU.enemy.scar.maxAlive) or 6
  local spread = (TU.enemy.scar and TU.enemy.scar.rootSpread) or 260

  local sites = {}
  local wounds = self.wounds
  if wounds then
    for i = 1, WOUND_MAX do
      local p = wounds[i]
      if p then sites[#sites + 1] = p end
    end
  end
  if #sites == 0 then return 0 end

  local placed = 0
  local tries = 0
  while (self.scarsLeft or 0) > 0 and tries < 40 do
    tries = tries + 1
    if self:countLive("scar") >= cap then break end
    local p = sites[self.rng:int(1, #sites)]
    -- never two on top of each other, and never in the home clearing
    local tooClose = false
    for i = 1, #w.enemies do
      local e = w.enemies[i]
      if e.alive and e.type == "scar" and U.dist(e.x, e.y, p.x, p.y) < spread then
        tooClose = true break
      end
    end
    if U.dist(p.x, p.y, w.homeX, w.homeY) < TU.world.homeRadius then tooClose = true end
    if not tooClose then
      local s = w:spawnEnemyAt(p.x, p.y, "scar")
      if s then
        self.scarsLeft = self.scarsLeft - 1
        placed = placed + 1
        Signal.emit("blight:rooted", s, true)
      end
    end
  end
  self.wounds = nil
  if os.getenv("BOTS_TRACE_SCARS") then
    print(string.format("SCARS|cycle=%d placed=%d left=%d sites=%d live=%d",
          self.cycle, placed, self.scarsLeft or 0, #sites, self:countLive("scar")))
  end
  return placed
end

--- Anything already dug into the island that the night can use as a way in: the
--- Scars the player did not clear today, and any Maw still standing.
function Director:liveAnchors()
  local out = {}
  local w = self.world
  local list = w and w.enemies
  if not list then return out end
  for i = 1, #list do
    local e = list[i]
    if e.alive and not e.fleeing and (e.type == "scar" or e.type == "maw") then
      out[#out + 1] = e
    end
  end
  return out
end

--- Asked by `Enemy:flee` at dawn. The quota is authored per cycle rather than
--- emergent, so a bad night leaves a morning's work and not a wasteland.
function Director:claimScar()
  if not (self.world and self.world.enemies) then return false end
  if (self.scarsLeft or 0) <= 0 then return false end
  local cap = (TU.enemy.scar and TU.enemy.scar.maxAlive) or 6
  if self:countLive("scar") >= cap then return false end
  self.scarsLeft = self.scarsLeft - 1
  return true
end

------------------------------------------------------------------ composition
--- What a type is worth to the Director tonight. Base weight at the cycle it
--- unlocks, drifting every cycle after that -- which is the whole of the fix for
--- "night six is night three with a bigger number in front of it".
function Director:weightOf(name, def)
  local m = TU.cycle.mix[name]
  if not m then return 0 end
  local n = self.cycle - (def.from or 1)
  if n < 0 then return 0 end
  return m[1] * m[2] ^ n
end

--- Which enemy types are unlocked and affordable right now.
function Director:pickCard(left)
  local opts, total = {}, 0
  for oi = 1, #ENEMY_ORDER do
    local name = ENEMY_ORDER[oi]
    local def = TU.enemy[name]
    if def.from <= self.cycle and def.cost <= left then
      local ok = true
      -- One Maw at a time, and never in the opening of a night: it is a
      -- mid-night complication, not an opening move. Dormant ones from previous
      -- days count, which is what stops an ignored Maw from becoming two.
      if name == "maw" then
        ok = self.t / self.dur > 0.3 and self:countLive("maw") < TU.cycle.mawAlive
      end
      if ok then
        local wt = self:weightOf(name, def)
        if wt > 0 then
          total = total + wt
          opts[#opts + 1] = { name = name, w = wt }
        end
      end
    end
  end
  if total <= 0 then return nil end
  -- Weighted draw off the running total: the old version stamped each name into
  -- a list `floor(weight * 2)` times, which quantised every weight to a half and
  -- made a smooth per-cycle drift impossible to express.
  local r = self.rng:range(0, total)
  for i = 1, #opts do
    r = r - opts[i].w
    if r <= 0 then return opts[i].name end
  end
  return opts[#opts].name
end

function Director:countLive(kind)
  local n = 0
  local list = self.world and self.world.enemies
  if not list then return 0 end
  for i = 1, #list do
    local e = list[i]
    if e.alive and not e.fleeing and e.type == kind then n = n + 1 end
  end
  return n
end

--- The night's shape at `p`, blended from the early and the late curve. An early
--- night has a lull you can plant in; a late one has a floor under it that it
--- never comes back through.
function Director:curveAt(p)
  local A, B = TU.cycle.curveEarly, TU.cycle.curveLate
  local idx = math.min(#A, math.floor(U.saturate(p) * #A) + 1)
  local k = U.saturate((self.cycle - 1) / math.max(1, TU.cycle.count - 1))
  return U.lerp(A[idx], B[idx], k)
end

function Director:update(dt)
  if not self.active then return end
  self.t = self.t + dt
  if self.hotT > 0 then self.hotT = self.hotT - dt end
  local p = U.saturate(self.t / self.dur)

  if p >= 1 then self:endNight() return end

  local w = self.world
  if w:enemyCount() >= self.maxAlive then return end

  self.nextT = self.nextT - dt
  if self.nextT > 0 then return end

  local pressure = self:curveAt(p)
  local left = self.budget - self.spent
  if left <= 0 then return end

  local card = self:pickCard(left)
  if not card then return end
  local def = TU.enemy[card]

  -- Spawn a small clutch rather than a trickle; groups read better and are more
  -- interesting to fight than a conveyor belt. The size of the clutch is a
  -- budget, not a count, so a wave of Chompers is a pack and a wave of Bulwarks
  -- is one Bulwark -- which is what makes a late night feel heavier at the same
  -- spend rather than merely more numerous.
  local clutch = U.clamp(TU.cycle.clutchBudget / math.max(1, def.cost), 1, 5)
  local count = card == "maw" and 1
                or math.max(1, math.floor(pressure * clutch + self.rng:range(0, 1.2)))
  count = math.min(count, math.floor(left / def.cost))
  if count < 1 then return end

  local ex, ey = self:spawnPoint(p)
  for i = 1, count do
    local a = self.rng:angle()
    local d = self.rng:range(0, 70)
    w:spawnEnemyAt(ex + math.cos(a) * d, ey + math.sin(a) * d, card)
    self.spent = self.spent + def.cost
  end

  -- A Warden with nothing to protect is nine hit points floating slowly
  -- backwards, and a Maw the player can walk straight up to is a free six
  -- shoves. Both arrive with somebody in front of them from cycle six.
  if (card == "warden" or card == "maw") and self.cycle >= TU.cycle.escortFrom then
    self:spawnEscort(ex, ey, (self.budget - self.spent) * TU.cycle.escortSpend)
  end

  self.nextT = U.lerp(4.2, 1.1, pressure) * self.rng:range(0.8, 1.25)
  Signal.emit("director:wave", card, count, ex, ey)
end

--- The cheapest thing that is unlocked, as many as the purse allows. An escort
--- is a screen, not a wave: it is bought out of the night's existing budget, so
--- an escorted card costs the Blight bodies elsewhere rather than being free.
function Director:spawnEscort(x, y, purse)
  local best, bestCost
  for oi = 1, #ENEMY_ORDER do
    local name = ENEMY_ORDER[oi]
    local def = TU.enemy[name]
    if def.from <= self.cycle
       and self:weightOf(name, def) > 0 and name ~= "maw" and name ~= "warden" then
      if not bestCost or def.cost < bestCost then best, bestCost = name, def.cost end
    end
  end
  if not best then return end
  local n = math.min(4, math.floor(purse / bestCost))
  for _ = 1, n do
    local a = self.rng:angle()
    local d = self.rng:range(40, 110)
    self.world:spawnEnemyAt(x + math.cos(a) * d, y + math.sin(a) * d, best)
    self.spent = self.spent + bestCost
  end
end

--- Where the next wave arrives. Three sources, in order of how much they change
--- the night: ground the Blight already holds, ground it is currently winning,
--- and the rift's own edge.
function Director:spawnPoint(p)
  -- 1. A Scar or a dormant Maw the player left standing. This is the real cost
  --    of ignoring the day: the night does not start at the shore, it starts in
  --    the middle of your wood with you at the other end of the island.
  local an = self.anchors
  if an and #an > 0 and p < TU.cycle.anchorWindow and self.rng:chance(TU.cycle.anchorChance) then
    for i = #an, 1, -1 do
      if not an[i].alive or an[i].fleeing then table.remove(an, i) end
    end
    if #an > 0 then
      local a = self.rng:pick(an)
      return a.x, a.y
    end
  end
  -- 2. Reinforce success: from cycle four, where teeth are already in something.
  if self.cycle >= TU.cycle.focusFrom and self.hotT > 0 and self.hotX
     and self.rng:chance(TU.cycle.focusChance) then
    local a, d = self.rng:angle(), self.rng:range(180, 340)
    local x, y = self.hotX + math.cos(a) * d, self.hotY + math.sin(a) * d
    local w = self.world
    if w and w.terrain and w.terrain.nearestLand then
      local lx, ly = w.terrain:nearestLand(x, y)
      if lx then return lx, ly end
    end
    return x, y
  end
  return self:edgePoint()
end

--- A point just outside the play area on one of the current rift sides, so the
--- player can learn where pressure comes from and position for it.
function Director:edgePoint()
  local W = TU.world
  local pad = TU.enemy.spawnEdgePad
  local s = self.side
  if self.sideB and self.rng:chance(0.45) then s = self.sideB end
  -- drift the side over the night so it isn't a single lane
  if self.rng:chance(0.18) then self.side = (self.side + (self.rng:chance(0.5) and 1 or 3)) % 4 end
  local x, y
  if s == 0 then x, y = self.rng:range(pad, W.w - pad), pad
  elseif s == 1 then x, y = W.w - pad, self.rng:range(pad, W.h - pad)
  elseif s == 2 then x, y = self.rng:range(pad, W.w - pad), W.h - pad
  else x, y = pad, self.rng:range(pad, W.h - pad) end
  local w = self.world
  if w and w.terrain and w.terrain.nearestLand then
    local lx, ly = w.terrain:nearestLand(x, y)
    if lx then return lx, ly end
  end
  return x, y
end

--- Where the next wave is coming from, for the dusk telegraph.
function Director:sideVector()
  local s = self.side
  if s == 0 then return 0, -1 elseif s == 1 then return 1, 0
  elseif s == 2 then return 0, 1 else return -1, 0 end
end

--- ...and the second front, when there is one, for the same telegraph.
function Director:sideVectorB()
  local s = self.sideB
  if not s then return nil end
  if s == 0 then return 0, -1 elseif s == 1 then return 1, 0
  elseif s == 2 then return 0, 1 else return -1, 0 end
end

function Director:remaining() return math.max(0, self.budget - self.spent) end
function Director:progress() return U.saturate(self.t / self.dur) end

return Director
