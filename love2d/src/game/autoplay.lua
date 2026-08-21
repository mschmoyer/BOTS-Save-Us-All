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
  act.carry = false

  -- Somebody is on the ground. Carrying them home outranks everything except
  -- the rig -- it is the one thing in the game that undoes a loss, and a
  -- stand-in that never does it makes a bad night look permanent.
  if p.carrying then
    local b = p.carrying
    local home = U.dist(p.x, p.y, w.homeX, w.homeY)
    self.gx, self.gy = w.homeX, w.homeY
    -- inside the rig's revive radius, not merely near it
    if home < TU.world.homeRadius * 0.7 then act.carry = true end
    local dx, dy = U.norm(self.gx - p.x, self.gy - p.y)
    self.aimX, self.aimY = dx, dy
    return dx, dy, act
  end
  local down = w:nearestDownedBot(p.x, p.y, 900)
  if down and not (w.boss and w.boss.alive) then
    local d = U.dist(p.x, p.y, down.x, down.y)
    self.gx, self.gy = down.x, down.y
    self.aimX, self.aimY = U.norm(down.x - p.x, down.y - p.y)
    if d < TU.player.carry.pickupRange * 0.8 then
      act.carry = true
      return 0, 0, act
    end
    local dx, dy = U.norm(down.x - p.x, down.y - p.y)
    if d > 300 and self.rng:chance(dt * 1.5) then act.dash = true end
    return dx, dy, act
  end

  -- the rig outranks everything: it is draining the sky while we stand here
  local threat = (w.boss and w.boss.alive) and w.boss or w:nearestEnemy(p.x, p.y, 420)
  -- stand off big things rather than walking into them; the shove out-ranges
  -- their body, and standing inside the rig is how you get flattened
  local standOff = threat and (threat.radius or 12) > 40 and 118 or 26
  if threat then
    local d = U.dist(p.x, p.y, threat.x, threat.y)
    self.gx, self.gy = threat.x, threat.y
    if d < TU.player.shove.range + (threat.radius or 12) then act.shove = true end
    if d > 240 and self.rng:chance(dt * 1.5) then act.dash = true end
    -- spend on the pulse when it can reach several things, or the rig
    if w.cobalt > 20 and d < TU.player.pulse.radius * 0.8 then act.pulse = true end
  else
    -- economy: walk deposits down, shoving to knock chunks loose
    if not self.goal or not self.goal.alive or self.goalT <= 0 then
      self.goal = w:nearestCobalt(p.x, p.y, 2600)
      self.goalT = 9
    end
    local g = self.goal
    if g and g.alive then
      self.gx, self.gy = g.x, g.y
      -- mining is standing on it, not hitting it: walking circles around a
      -- deposit is how the stand-in used to earn nothing all day
      if U.dist(p.x, p.y, g.x, g.y) < 34 then
        self.aimX, self.aimY = U.norm(g.x - p.x, g.y - p.y)
        return 0, 0, act
      end
    else
      self.gx, self.gy = w.homeX, w.homeY
    end

    -- spend whenever we can afford the next thing in the plan
    local nextBot = BUILD_PLAN[((self.buildIdx - 1) % #BUILD_PLAN) + 1]
    if w.cobalt >= w:botCost(nextBot) + 6 then
      act.build = nextBot
      self.buildIdx = self.buildIdx + 1
    end
  end

  -- move the standing order onto whatever ground is being worked next, the way
  -- a player pushing a frontier would
  self.rallyT = (self.rallyT or 0) - dt
  if self.rallyT <= 0 and self.gx then
    self.rallyT = 22
    act.rally = true
    self.rallyX, self.rallyY = self.gx, self.gy
  end

  -- Aim is separate from movement, the way a stick or a mouse is: the agent
  -- keeps the cone on whatever it is fighting even while it gives ground.
  if threat then
    self.aimX, self.aimY = U.norm(threat.x - p.x, threat.y - p.y)
  elseif self.gx then
    self.aimX, self.aimY = U.norm(self.gx - p.x, self.gy - p.y)
  end

  local mx, my = 0, 0
  if self.gx then
    local dx, dy, d = U.norm(self.gx - p.x, self.gy - p.y)
    if d > standOff then mx, my = dx, dy
    elseif d < standOff * 0.7 then mx, my = -dx, -dy end
  end
  return mx, my, act
end

return A
