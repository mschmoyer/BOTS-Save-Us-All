-- Wave author. Spends a per-night budget on enemy cards along a pacing curve
-- so nights have shape: a probe, a lull, a real push, and a final surge.
local Class = require("src.core.class")
local U     = require("src.core.util")
local Signal = require("src.core.signal")
local TU    = require("src.game.tuning")

local Director = Class("Director")

-- pressure curve sampled across the night: peaks at ~40% and ~85%
local CURVE = { 0.25, 0.5, 0.85, 1.0, 0.55, 0.4, 0.7, 0.95, 1.0, 0.6 }

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
  self.mawSpawned = false
end

function Director:beginNight(cycle, duration)
  self.cycle = cycle
  -- The night's pressure scales with the forest, so a big wood is a big target.
  -- A fixed budget against an exponential forest is a threat that shrinks.
  local trees = self.world and self.world.treeCount or 0
  self.budget = TU.cycle.budget[math.min(cycle, #TU.cycle.budget)]
                + trees * TU.cycle.budgetPerTree
  self.budget = self.budget * (self.world.chips and self.world.chips:get("budget", 1) or 1)
  self.maxAlive = math.floor(TU.cycle.maxAlive[math.min(cycle, #TU.cycle.maxAlive)]
                             + trees * TU.cycle.maxAlivePerTree)
  self.spent = 0
  self.t = 0
  self.dur = duration
  self.active = true
  self.nextT = 0.6
  self.side = self.rng:int(0, 3)
  self.mawSpawned = false
  Signal.emit("director:night", cycle, self.budget, self.side)
end

function Director:endNight()
  self.active = false
  Signal.emit("director:dawn", self.cycle)
end

--- Which enemy types are unlocked and affordable right now.
function Director:pickCard(left)
  local opts = {}
  for name, def in pairs(TU.enemy) do
    if type(def) == "table" and def.from and def.from <= self.cycle and def.cost <= left then
      if name ~= "maw" or (not self.mawSpawned and self.t / self.dur > 0.3) then
        -- siphons attack the win condition directly; they deserve to show up
        local weight = 1
        if name == "chomper" then weight = 4 end
        if name == "skitter" then weight = 2.5 end
        if name == "maw" then weight = 0.5 end
        if name == "siphon" then weight = 2 end
        for _ = 1, math.max(1, math.floor(weight * 2)) do opts[#opts + 1] = name end
      end
    end
  end
  if #opts == 0 then return nil end
  return self.rng:pick(opts)
end

function Director:update(dt)
  if not self.active then return end
  self.t = self.t + dt
  local p = U.saturate(self.t / self.dur)

  if p >= 1 then self:endNight() return end

  local w = self.world
  if w:enemyCount() >= self.maxAlive then return end

  self.nextT = self.nextT - dt
  if self.nextT > 0 then return end

  local idx = math.min(#CURVE, math.floor(p * #CURVE) + 1)
  local pressure = CURVE[idx]
  local left = self.budget - self.spent
  if left <= 0 then return end

  local card = self:pickCard(left)
  if not card then return end
  local def = TU.enemy[card]

  -- spawn a small clutch rather than a trickle; groups read better and are
  -- more interesting to fight than a conveyor belt.
  local count = card == "maw" and 1 or math.max(1, math.floor(pressure * 3 + self.rng:range(0, 1.5)))
  count = math.min(count, math.floor(left / def.cost))
  if count < 1 then return end

  local ex, ey = self:edgePoint()
  for i = 1, count do
    local a = self.rng:angle()
    local d = self.rng:range(0, 70)
    w:spawnEnemyAt(ex + math.cos(a) * d, ey + math.sin(a) * d, card)
    self.spent = self.spent + def.cost
  end
  if card == "maw" then self.mawSpawned = true end

  self.nextT = U.lerp(4.2, 1.1, pressure) * self.rng:range(0.8, 1.25)
  Signal.emit("director:wave", card, count, ex, ey)
end

--- A point just outside the play area on the current rift side, so the player
--- can learn where pressure comes from and position for it.
function Director:edgePoint()
  local W = TU.world
  local pad = TU.enemy.spawnEdgePad
  local s = self.side
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

function Director:remaining() return math.max(0, self.budget - self.spent) end
function Director:progress() return U.saturate(self.t / self.dur) end

return Director
