-- A scripted stand-in player used by the headless capture harness, so automated
-- review can see cycle 4 of a real session instead of the first ten seconds.
-- Enabled with BOTS_AUTOPLAY=1. Never runs in a normal session.
local U  = require("src.core.util")
local TU = require("src.game.tuning")

local A = {}
A.__index = A

function A.new(world)
  return setmetatable({
    world = world, rng = U.rng(31337), t = 0,
    goal = nil, goalT = 0, want = "cobalt", buildIdx = 1,
  }, A)
end

local BUILD_PLAN = { "planter", "planter", "harvester", "planter", "builder",
                     "beacon", "planter", "sentry", "planter", "repulsor" }

--- Returns mx, my, and a table of actions the player should take this frame.
function A:decide(p, dt)
  local w = self.world
  self.t = self.t + dt
  self.goalT = self.goalT - dt
  local act = self.act or {}
  self.act = act
  act.dash, act.shove, act.plant, act.build = false, false, false, nil

  -- defend: anything chewing a tree near us outranks economy
  local threat = w:nearestEnemy(p.x, p.y, 420)
  if threat then
    local d = U.dist(p.x, p.y, threat.x, threat.y)
    self.gx, self.gy = threat.x, threat.y
    if d < TU.player.shove.range * 0.85 then act.shove = true end
    if d > 240 and self.rng:chance(dt * 1.5) then act.dash = true end
  else
    -- economy: walk deposits down, shoving to knock chunks loose
    if not self.goal or not self.goal.alive or self.goalT <= 0 then
      self.goal = w:nearestCobalt(p.x, p.y, 2600)
      self.goalT = 9
    end
    local g = self.goal
    if g and g.alive then
      self.gx, self.gy = g.x, g.y
      if U.dist(p.x, p.y, g.x, g.y) < 60 then act.shove = true end
    else
      self.gx, self.gy = w.homeX, w.homeY
    end

    -- spend whenever we can afford the next thing in the plan
    local nextBot = BUILD_PLAN[((self.buildIdx - 1) % #BUILD_PLAN) + 1]
    local def = TU.bots[nextBot]
    if w.cobalt >= def.cost + 6 then
      act.build = nextBot
      self.buildIdx = self.buildIdx + 1
    end
  end

  local mx, my = 0, 0
  if self.gx then
    local dx, dy, d = U.norm(self.gx - p.x, self.gy - p.y)
    if d > 24 then mx, my = dx, dy end
  end
  return mx, my, act
end

return A
