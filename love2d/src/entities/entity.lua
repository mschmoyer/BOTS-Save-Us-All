-- Shared base for everything that lives in the world and gets drawn in the
-- depth-sorted entity pass.
local Class = require("src.core.class")
local U = require("src.core.util")

local Entity = Class("Entity")

function Entity:init(x, y)
  self.x, self.y = x or 0, y or 0
  self.vx, self.vy = 0, 0
  self.radius = 12
  self.alive = true
  self.kind = "entity"
  self.faceX, self.faceY = 0, 1
  self.z = 0                -- extra depth bias; sort key is y + z
  self.hp, self.maxHp = 1, 1
  self.flash = 0            -- white hit flash, seconds
  self.bob = U.hash2(math.floor(self.x), math.floor(self.y), 3) * 6.2831
  self.age = 0
end

function Entity:sortKey() return self.y + self.z end

function Entity:setFacing(dx, dy)
  if dx * dx + dy * dy > 1e-6 then
    self.faceX, self.faceY = U.norm(dx, dy)
  end
end

function Entity:facingAngle() return math.atan2(self.faceY, self.faceX) end

--- Integrate velocity with exponential friction. Returns distance moved.
function Entity:integrate(dt, friction)
  local px, py = self.x, self.y
  self.x = self.x + self.vx * dt
  self.y = self.y + self.vy * dt
  if friction and friction > 0 then
    local k = math.exp(-friction * dt)
    self.vx, self.vy = self.vx * k, self.vy * k
  end
  return U.dist(px, py, self.x, self.y)
end

function Entity:push(dx, dy, force)
  local nx, ny = U.norm(dx, dy)
  self.vx = self.vx + nx * force
  self.vy = self.vy + ny * force
end

function Entity:damage(n, srcX, srcY, opts)
  if not self.alive or self.invuln and self.invuln > 0 then return false end
  -- Already on the ground: further hits must not re-run onDeath, which would
  -- reset the rescue timer (bots) or the reboot and its cobalt fine (player).
  if self.state == "down" then return false end
  self.hp = self.hp - (n or 1)
  self.flash = 0.12
  if self.onDamage then self:onDamage(n, srcX, srcY, opts) end
  if self.hp <= 0 then
    self.hp = 0
    if self.onDeath then self:onDeath(opts) else self.alive = false end
  end
  return true
end

function Entity:updateCommon(dt)
  self.age = self.age + dt
  if self.flash > 0 then self.flash = math.max(0, self.flash - dt * 6) end
  if self.invuln and self.invuln > 0 then self.invuln = self.invuln - dt end
end

--- Keep entities inside the island (terrain may be nil during isolated tests).
function Entity:constrain(terrain, bounceLoss)
  if not terrain or not terrain.isLand then return end
  if not terrain:isLand(self.x, self.y) then
    local lx, ly = terrain:nearestLand(self.x, self.y)
    if lx then
      self.x, self.y = lx, ly
      if bounceLoss then self.vx, self.vy = self.vx * bounceLoss, self.vy * bounceLoss end
    end
  end
end

return Entity
