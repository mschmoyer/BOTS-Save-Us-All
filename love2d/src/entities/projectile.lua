-- Seed-darts (friendly) and acid (hostile). One small pooled class.
local Class  = require("src.core.class")
local U      = require("src.core.util")
local Entity = require("src.entities.entity")
local P      = require("src.engine.palette")
local Opt    = require("src.core.optional")

local Draw  = Opt.require("src.engine.draw")
local VFX   = Opt.require("src.engine.vfx")
local Audio = Opt.require("src.engine.audio")

local Projectile = Class("Projectile", Entity)

function Projectile:init(x, y, kind, world)
  Projectile.super.init(self, x, y)
  self.kind = "projectile"
  self.type = kind          -- "dart" | "acid"
  self.world = world
  self.radius = kind == "dart" and 4 or 7
  self.life = 3
  self.trailX, self.trailY = x, y
end

function Projectile:setDart(angle, speed, damage, owner)
  self.vx, self.vy = math.cos(angle) * speed, math.sin(angle) * speed
  self.damage, self.owner = damage, owner
  self.angle = angle
end

--- Acid lobs on an arc; `h` fakes height so it can land on a spot.
function Projectile:setAcid(tx, ty, speed, owner)
  local d = U.dist(self.x, self.y, tx, ty)
  local t = math.max(0.25, d / speed)
  self.vx, self.vy = (tx - self.x) / t, (ty - self.y) / t
  self.life = t
  self.flightT, self.flightDur = 0, t
  self.h, self.owner = 0, owner
  self.arc = math.min(90, d * 0.35)
end

function Projectile:update(dt)
  self:updateCommon(dt)
  self.trailX, self.trailY = self.x, self.y
  self.x = self.x + self.vx * dt
  self.y = self.y + self.vy * dt
  self.life = self.life - dt

  if self.type == "acid" then
    self.flightT = self.flightT + dt
    local p = U.saturate(self.flightT / self.flightDur)
    self.h = math.sin(p * math.pi) * self.arc
    if p >= 1 then self:splash() end
    return
  end

  if self.life <= 0 then self.alive = false return end
  local w = self.world
  if not w then return end
  local hit = w:hitEnemyAt(self.x, self.y, self.radius + 8, self.damage, self.vx, self.vy)
  if hit then
    VFX.emit("hit_spark", self.x, self.y, { dx = self.vx, dy = self.vy })
    self.alive = false
  elseif not w.terrain or w.terrain.isLand == nil or w.terrain:isLand(self.x, self.y) == false then
    self.alive = false
  end
end

function Projectile:splash()
  self.alive = false
  local w = self.world
  VFX.emit("acid_splash", self.x, self.y)
  Audio.play("spit", { pitch = 0.7, x = self.x, y = self.y })
  if w then w:acidSplash(self.x, self.y) end
end

function Projectile:drawShadow()
  if self.type == "acid" then
    Draw.softShadow(self.x, self.y, 7, 3.2, 0.3)
  end
end

--- Who fired it, in the night's colour language: yellow is the player, blue is
--- the crew, red is the Blight. A dart was leaf-green whoever threw it, which
--- says nothing at a glance about whether the thing flying past you is help.
function Projectile:lightColor()
  if self.type ~= "dart" then return P.lightHostile end
  local o = self.owner
  if o and o.kind == "player" then return P.lightPlayer end
  return P.lightFriend
end

--- Shots carry their own light. Nothing in flight lit anything before, so a
--- night firefight was muzzle flashes and impacts with nothing in between.
function Projectile:emitLight(Lighting)
  if not self.alive then return end
  local c = self:lightColor()
  local y = self.y - (self.h or 0)
  Lighting.addLight(self.x, y, self.type == "dart" and 96 or 120, c,
                    self.type == "dart" and 0.85 or 0.7, nil)
end

function Projectile:draw()
  if self.type == "dart" then
    local c = self:lightColor()
    Draw.setColor(c, 0.95)
    Draw.capsule("fill", self.trailX, self.trailY, self.x, self.y, 2.4)
    Draw.setColor(P.lighten(c, 0.55), 0.9)
    love.graphics.circle("fill", self.x, self.y, 2.6)
    Draw.glow(self.x, self.y, 22, c, 0.45)
  else
    local y = self.y - self.h
    Draw.setColor(P.acid, 0.9)
    Draw.blob(self.x, y, self.radius, 7, 17, 0.25, 1.1)
    Draw.glow(self.x, y, 22, P.acid, 0.35)
  end
end

return Projectile
