-- Cobalt: deposits you break and loose chunks that fly to whoever earned them.
local Class  = require("src.core.class")
local U      = require("src.core.util")
local Entity = require("src.entities.entity")
local P      = require("src.engine.palette")
local Opt    = require("src.core.optional")
local T      = require("src.game.tuning").cobalt

local Draw  = Opt.require("src.engine.draw")
local VFX   = Opt.require("src.engine.vfx")
local Audio = Opt.require("src.engine.audio")

local Cobalt = Class("Cobalt", Entity)

function Cobalt:init(x, y, world, rng, isNode)
  Cobalt.super.init(self, x, y)
  self.kind   = "cobalt"
  self.world  = world
  self.rng    = rng or U.rng(math.floor(x * 7 + y * 3))
  self.node   = isNode ~= false
  self.radius = self.node and 20 or 9
  self.left   = self.node and T.nodeYield or T.chunkValue
  self.shards = {}
  local n = self.node and 5 or 3
  for i = 1, n do
    self.shards[i] = {
      a  = self.rng:angle(),
      d  = self.rng:range(0.15, 0.85) * self.radius,
      s  = self.rng:range(0.35, 1.0) * self.radius * 0.62,
      rot = self.rng:angle(),
      ph = self.rng:angle(),
    }
  end
  self.seekT  = 0
  self.homing = nil
end

function Cobalt:update(dt)
  self:updateCommon(dt)
  if (self.mineT or 0) > 0 then self.mineT = self.mineT - dt end
  if self.homing then
    local t = self.homing
    local dx, dy, d = U.norm(t.x - self.x, t.y - self.y)
    local sp = T.driftSpeed * U.remapc(self.seekT, 0, 0.4, 0.35, 1)
    self.seekT = self.seekT + dt
    self.x = self.x + dx * sp * dt
    self.y = self.y + dy * sp * dt
    if d < 18 then
      if self.world then self.world:bankCobalt(self.left, self.x, self.y) end
      self.alive = false
    end
    return
  end
  if not self.node then
    self:integrate(dt, 4)
    -- loose chunks magnetise to the player
    local p = self.world and self.world.player
    if p and p.state == "alive" and self.age > 0.35 then
      local range = T.magnetRange * (self.world.chips and self.world.chips:get("magnet", 1) or 1)
      if U.dist2(self.x, self.y, p.x, p.y) < range * range then self.homing = p end
    end
  end
end

--- Break one chunk off a deposit. Returns true if something came loose.
function Cobalt:mine(byWhom)
  if self.left <= 0 then return false end
  if (self.mineT or 0) > 0 then return false end
  self.mineT = T.mineEvery
  self.left = self.left - 1
  self.hitAnim = 1
  VFX.emit("cobalt_pickup", self.x, self.y)
  if self.left <= 0 then
    self.alive = false
    VFX.emit("deposit_pop", self.x, self.y)
    if self.world then self.world:scheduleNodeRespawn() end
  end
  return true
end

function Cobalt:drawShadow()
  if not self.node then return end
  Draw.softShadow(self.x, self.y + 2, self.radius * 0.9, self.radius * 0.36, 0.3)
end

function Cobalt:draw()
  local g = love.graphics
  local pop = self.hitAnim and (1 + self.hitAnim * 0.25) or 1
  if self.hitAnim then
    self.hitAnim = self.hitAnim - love.timer.getDelta() * 4
    if self.hitAnim <= 0 then self.hitAnim = nil end
  end
  local shimmer = 0.5 + math.sin(self.age * 2.2 + self.bob) * 0.5
  g.push()
  g.translate(self.x, self.y + (self.node and 0 or math.sin(self.age * 4 + self.bob) * 2))
  g.scale(pop)
  for i = 1, #self.shards do
    local s = self.shards[i]
    if self.node and i > math.max(1, self.left) then break end
    local x, y = math.cos(s.a) * s.d, math.sin(s.a) * s.d * 0.6
    Draw.setColor(P.shade(P.ramp.cobalt, 1.6))
    Draw.diamond(x, y + s.s * 0.35, s.s * 0.95, s.s * 0.6, "fill")
    Draw.setColor(P.shade(P.ramp.cobalt, 2.6 + shimmer * 0.6))
    Draw.diamond(x, y, s.s, s.s * 1.5, "fill")
    Draw.setColor(P.shade(P.ramp.cobalt, 4), 0.55 + shimmer * 0.45)
    Draw.diamond(x - s.s * 0.16, y - s.s * 0.3, s.s * 0.34, s.s * 0.6, "fill")
  end
  g.pop()
  Draw.glow(self.x, self.y, self.radius * (1.7 + shimmer * 0.4), P.ramp.cobalt[3], 0.28)
end

function Cobalt:emitLight(Lighting)
  Lighting.addLight(self.x, self.y, self.radius * 3.2, P.ramp.cobalt[3], 0.3, { flicker = 0.06 })
end

return Cobalt
