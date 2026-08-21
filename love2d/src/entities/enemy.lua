-- The Blight. Six behaviours over one chassis; they want the trees, not you.
local Class   = require("src.core.class")
local U       = require("src.core.util")
local Entity  = require("src.entities.entity")
local P       = require("src.engine.palette")
local J       = require("src.engine.juice")
local Signal  = require("src.core.signal")
local Opt     = require("src.core.optional")
local TU      = require("src.game.tuning")
local T       = TU.enemy

local Draw  = Opt.require("src.engine.draw")
local VFX   = Opt.require("src.engine.vfx")
local Audio = Opt.require("src.engine.audio")

local Enemy = Class("Enemy", Entity)

function Enemy:init(x, y, kind, world, rng)
  Enemy.super.init(self, x, y)
  local def = T[kind]
  assert(def, "unknown enemy: " .. tostring(kind))
  self.kind    = "enemy"
  self.type    = kind
  self.def     = def
  self.world   = world
  -- Never the wall clock. A seeded world has to replay identically or the
  -- headless balance traces compare two different runs and say nothing.
  self.rng     = rng or U.rng(math.floor(x * 13 + y * 7) + 1)
  self.radius  = def.radius
  self.maxHp   = def.hp
  self.hp      = def.hp
  self.stun    = 0
  self.target  = nil
  self.chewT   = 0
  self.fireT   = self.rng:range(0.5, 2.0)
  self.wob     = self.rng:angle()
  self.legPhase = self.rng:angle()
  self.hoverT  = self.rng:angle()
  self.fleeing = false
  self.armour  = def.armoured and 2 or 0
  self.spawnT  = 0.5
  self.shovesLeft = def.shovesToClose
  Signal.emit("enemy:spawned", self)
end

function Enemy:slowFactor()
  local s = 1
  if self.world and self.world.beaconSlowAt then s = s * (1 - self.world:beaconSlowAt(self.x, self.y)) end
  if self.acidSlow and self.acidSlow > 0 then s = s * 0.6 end
  return s
end

function Enemy:update(dt)
  self:updateCommon(dt)
  if self.spawnT > 0 then
    self.spawnT = self.spawnT - dt
    self:integrate(dt, 6)
    return
  end
  if self.stun > 0 then
    self.stun = self.stun - dt
    self:integrate(dt, 5)
    self:constrain(self.world and self.world.terrain, 0.4)
    if self.rng:chance(dt * 4) then VFX.emit("blight_spore", self.x, self.y) end
    return
  end
  if self.fleeing then
    self.vx = U.damp(self.vx, self.fleeX * self.def.speed * 1.8, 4, dt)
    self.vy = U.damp(self.vy, self.fleeY * self.def.speed * 1.8, 4, dt)
    self:integrate(dt, 0)
    self.fadeT = (self.fadeT or 1) - dt / T.fleeOnDawn
    if self.fadeT <= 0 then self.alive = false end
    return
  end
  local fn = self["update_" .. self.type]
  if fn then fn(self, dt) end
  self.legPhase = self.legPhase + dt * (4 + U.len(self.vx, self.vy) * 0.05)
  if self.acidSlow then self.acidSlow = math.max(0, self.acidSlow - dt) end
end

function Enemy:seek(tx, ty, dt, mul)
  local sp = self.def.speed * (mul or 1) * self:slowFactor()
  local dx, dy, d = U.norm(tx - self.x, ty - self.y)
  -- a little lateral wobble stops the swarm marching in perfect lines
  self.wob = self.wob + dt * 2.2
  local px, py = -dy, dx
  local w = math.sin(self.wob) * 0.28
  self.vx = U.damp(self.vx, (dx + px * w) * sp, 7, dt)
  self.vy = U.damp(self.vy, (dy + py * w) * sp, 7, dt)
  self:integrate(dt, 0)
  self:constrain(self.world and self.world.terrain, 0)
  self:setFacing(dx, dy)
  return d
end

------------------------------------------------------------------- behaviours
function Enemy:update_chomper(dt)
  local w = self.world
  if not self.target or not self.target.alive then
    -- A short search radius is what makes a Chomper dangerous: once the trees
    -- nearby are already spoken for it comes for your bots, and then for you.
    local reach = (self.def.treeSearch or 480)
                  * (w and w.chips and w.chips:get("blightFocus", 1) or 1)
    -- Trees first, and hard: an unclaimed one nearby, then any tree at all a
    -- little further out. Only a Chomper that genuinely cannot find a tree
    -- turns on your bots, which keeps the pressure where the design wants it
    -- without letting a big swarm strip the workforce in a single night.
    self.target = w and w:nearestTree(self.x, self.y, reach, true)
    if not self.target and w then
      self.target = w:nearestTree(self.x, self.y, reach * 2.4)
                    or w:nearestBot(self.x, self.y, 520) or w.player
    end
    if self.target then
      self.target.markedBy = self
      Signal.emit("enemy:targeted", self, self.target)
    end
    self.chewT = 0
  end
  local t = self.target
  if not t then
    if w and w.player then self:seek(w.player.x, w.player.y, dt, 0.7) end
    return
  end
  -- it went for a bot or the player instead: bite, do not chew
  if t.kind ~= "tree" and not t.startChew then
    local d = self:seek(t.x, t.y, dt)
    if d < (t.radius or 12) + self.radius then
      if type(t.damage) == "function" then t:damage(self.def.damage, self.x, self.y) end
      self:push(self.x - t.x, self.y - t.y, 240)
      self.stun = 0.5
    end
    return
  end
  local d = self:seek(t.x, t.y, dt)
  if d < t.radius + self.radius + 6 then
    self.vx, self.vy = self.vx * 0.6, self.vy * 0.6
    if self.chewT == 0 then
      if t.startChew then t:startChew(self) end
      Audio.play("chomp", { x = self.x, y = self.y })
    end
    self.chewT = self.chewT + dt
    if self.rng:chance(dt * 2.5) then
      Audio.play("chomp", { pitch = self.rng:range(0.9, 1.15), volume = 0.5, x = self.x, y = self.y })
      VFX.emit("leaf_litter", t.x, t.y - t.radius, { count = 2 })
    end
    local chew = TU.tree.chewTime * (w.chips and w.chips:get("chewTime", 1) or 1)
    if self.chewT >= chew then
      if w then w:fellTree(t, self) end
      self.target = nil
      self.chewT = 0
    end
  else
    if self.chewT > 0 and t.stopChew then t:stopChew() end
    self.chewT = 0
  end
end

function Enemy:update_skitter(dt)
  local w = self.world
  if not self.target or not self.target.alive or self.target.state == "dead" then
    self.target = w and (w:nearestBot(self.x, self.y, 1400) or w.player)
  end
  local t = self.target
  if not t then return end
  local d = self:seek(t.x, t.y, dt, 1)
  if d < t.radius + self.radius then
    if type(t.damage) == "function" then t:damage(self.def.damage, self.x, self.y) end
    self:push(self.x - t.x, self.y - t.y, 260)
    self.stun = 0.35
  end
end

function Enemy:update_spitter(dt)
  local w = self.world
  local t = self.target
  if not t or not t.alive then
    self.target = w and (w:nearestBot(self.x, self.y, self.def.range * 1.6)
                         or w:nearestTree(self.x, self.y, self.def.range * 1.6))
    t = self.target
  end
  if not t then return end
  local d = U.dist(self.x, self.y, t.x, t.y)
  if d > self.def.range * 0.8 then
    self:seek(t.x, t.y, dt)
  else
    self.vx, self.vy = self.vx * 0.85, self.vy * 0.85
    self:integrate(dt, 3)
    self:setFacing(t.x - self.x, t.y - self.y)
  end
  self.fireT = self.fireT - dt
  if self.fireT <= 0 and d < self.def.range then
    self.fireT = self.def.fireEvery
    if w then w:spawnAcid(self.x, self.y - 8, t.x, t.y, self.def.projSpeed, self) end
    Audio.play("spit", { x = self.x, y = self.y })
    self.spitAnim = 1
  end
  self.spitAnim = math.max(0, (self.spitAnim or 0) - dt * 4)
end

function Enemy:update_siphon(dt)
  local w = self.world
  self.hoverT = self.hoverT + dt * 1.6
  if not self.perch or self.rng:chance(dt * 0.12) then
    local t = w and w:nearestTree(self.x, self.y, 2400)
    self.perch = t and { x = t.x, y = t.y } or nil
  end
  local p = self.perch
  if p then
    local d = self:seek(p.x, p.y - 30, dt, 0.9)
    self.feeding = d < 60
  else
    self.feeding = false
  end
  if self.feeding and w then
    w:drainO2(TU.o2.siphonDrain, dt)
    if self.rng:chance(dt * 5) then VFX.emit("blight_spore", self.x, self.y + 10) end
  end
end

function Enemy:update_bulwark(dt)
  local w = self.world
  if not self.target or not self.target.alive or self.target.state == "dead" then
    self.target = w and (w:nearestBot(self.x, self.y, 2400, function(b)
      return b.type == "beacon" or b.type == "sentry" or b.type == "repulsor"
    end) or w:nearestTree(self.x, self.y, 2400))
  end
  local t = self.target
  if not t then return end
  local d = self:seek(t.x, t.y, dt)
  if d >= t.radius + self.radius + 4 and self.chewing then
    if self.chewing.stopChew then self.chewing:stopChew() end
    self.chewing = nil
  end
  if d < t.radius + self.radius + 4 then
    self.slamT = (self.slamT or 0) + dt
    if self.slamT > 1.1 then
      self.slamT = 0
      if type(t.damage) == "function" then t:damage(self.def.damage, self.x, self.y) end
      -- one registration only: slamming re-registered every 1.1 s and never
      -- released, so the tree kept taking chew damage with nothing near it
      if t.startChew and not self.chewing then
        t:startChew(self)
        self.chewing = t
      end
      VFX.emit("slam_dust", self.x, self.y)
      J.shake(0.1)
    end
  end
end

function Enemy:update_maw(dt)
  self.spawnEvery = self.spawnEvery or self.def.spawnEvery
  self.fireT = self.fireT - dt
  self.pulse = (self.pulse or 0) + dt * 2
  if self.fireT <= 0 then
    self.fireT = self.def.spawnEvery
    if self.world then
      local a = self.rng:angle()
      self.world:spawnEnemyAt(self.x + math.cos(a) * 40, self.y + math.sin(a) * 40, "chomper")
      VFX.emit("rift_open", self.x, self.y, { power = 0.4 })
    end
  end
  if self.rng:chance(dt * 8) then VFX.emit("rift_ambient", self.x, self.y) end
end

------------------------------------------------------------------------ combat
--- Shoves are resisted by armour; that is what makes Bulwarks a puzzle.
function Enemy:shove(dx, dy, force, damage, stun)
  if self.def.armoured then
    if self.type == "maw" then
      self.shovesLeft = (self.shovesLeft or 6) - 1
      VFX.emit("impact", self.x, self.y, { power = 1 })
      if self.shovesLeft <= 0 then self:damage(999, dx, dy) end
      return true
    end
    -- Armour reduces the hit; it no longer cancels it. A Pulse should always be
    -- a legitimate answer to a Bulwark, just an inefficient one.
    self.flash = 0.12
    VFX.emit("hit_spark", self.x, self.y, { color = P.warn })
    if damage and damage > 0 then
      self:damage(math.max(1, damage * (1 - (self.def.armour or 0.5))), self.x - dx, self.y - dy)
    end
    return false
  end
  self:push(dx, dy, force)
  self.stun = math.max(self.stun, stun or 0)
  if damage and damage > 0 then self:damage(damage, self.x - dx, self.y - dy) end
  return true
end

function Enemy:onDamage(n, sx, sy)
  Audio.play("enemy_hurt", { pitch = 1 + (self.rng:next() - .5) * .2, x = self.x, y = self.y })
  VFX.emit("hit_spark", self.x, self.y, { dx = self.x - (sx or self.x), dy = self.y - (sy or self.y) })
end

function Enemy:onDeath()
  self.alive = false
  if self.chewing and self.chewing.stopChew then self.chewing:stopChew() self.chewing = nil end
  if self.target and self.target.stopChew then self.target:stopChew() end
  VFX.emit("blight_death", self.x, self.y, { power = self.radius / 14 })
  Audio.play("enemy_die", { x = self.x, y = self.y })
  J.shake(0.06)
  if self.world and self.world.chips and self.world.chips:has("thornburst") then
    self.world:spawnSporeCloud(self.x, self.y)
  end
  Signal.emit("enemy:killed", self)
end

function Enemy:flee()
  if self.fleeing then return end
  self.fleeing = true
  self.fadeT = 1
  if self.target and self.target.stopChew then self.target:stopChew() end
  local w = self.world
  local cx, cy = w and w.centerX or self.x, w and w.centerY or self.y
  self.fleeX, self.fleeY = U.norm(self.x - cx, self.y - cy)
end

------------------------------------------------------------------------- render
local function bl(t) return P.shade(P.ramp.blight, t) end

function Enemy:drawShadow()
  if self.def.float then
    Draw.softShadow(self.x, self.y + 26, self.radius * 0.8, self.radius * 0.3, 0.2)
  else
    Draw.softShadow(self.x, self.y + 3, self.radius * 1.05, self.radius * 0.45, 0.32)
  end
end

function Enemy:draw()
  local g = love.graphics
  local r = self.radius
  local a = self.fleeing and U.saturate(self.fadeT) or 1
  local spawn = self.spawnT > 0 and U.saturate(1 - self.spawnT / 0.5) or 1

  g.push()
  g.translate(self.x, self.y)
  if self.def.float then g.translate(0, -22 + math.sin(self.hoverT) * 4) end
  g.scale(spawn, spawn * (2 - spawn))

  local fn = self["body_" .. self.type]
  if fn then fn(self, r, a) else self:body_chomper(r, a) end

  g.pop()

  if self.stun > 0 then
    Draw.setColor(P.warn, 0.5 * math.min(1, self.stun))
    Draw.dashedCircle(self.x, self.y - r * 1.6, r * 0.6, 5, 4, self.age * 40, 1.5)
  end
  if self.flash > 0 then
    Draw.setColor(P.white, self.flash * 0.9)
    g.circle("fill", self.x, self.y - (self.def.float and 22 or 0), r * 1.02)
  end
  -- health pips for anything that takes more than a couple of hits
  if self.maxHp > 4 and self.hp < self.maxHp then
    local w = r * 1.8
    Draw.setColor(P.black, 0.4)
    Draw.roundRect("fill", self.x - w / 2, self.y - r * 2.1, w, 4, 2)
    Draw.setColor(P.danger, 0.9)
    Draw.roundRect("fill", self.x - w / 2, self.y - r * 2.1, w * (self.hp / self.maxHp), 4, 2)
  end
end

function Enemy:body_chomper(r, a)
  local step = math.sin(self.legPhase) * r * 0.22
  Draw.setColor(bl(1.3), a)
  for i = -1, 1, 2 do
    Draw.capsule("fill", i * r * 0.5, r * 0.1, i * r * 0.72, r * 0.75 + step * i, r * 0.14)
  end
  Draw.setColor(bl(2.2), a)
  Draw.blob(0, 0, r, 9, self.serial or 3, 0.16, 0.86)
  -- jaw opens while chewing
  local open = self.chewT > 0 and (0.5 + math.sin(self.age * 16) * 0.5) or 0
  Draw.setColor(bl(1.1), a)
  local fa = math.atan2(self.faceY, self.faceX)
  local jx, jy = math.cos(fa) * r * 0.6, math.sin(fa) * r * 0.6
  Draw.setColor(P.black, a * 0.75)
  Draw.blob(jx, jy, r * (0.34 + open * 0.2), 6, 11, 0.2, 1)
  Draw.setColor(bl(3.4), a * 0.95)
  love.graphics.circle("fill", -math.sin(fa) * r * 0.3 + jx * 0.3, math.cos(fa) * r * 0.3 + jy * 0.3, r * 0.14)
  love.graphics.circle("fill", math.sin(fa) * r * 0.3 + jx * 0.3, -math.cos(fa) * r * 0.3 + jy * 0.3, r * 0.14)
end

function Enemy:body_skitter(r, a)
  local step = math.sin(self.legPhase * 2) * r * 0.3
  Draw.setColor(bl(1.6), a)
  for i = 0, 5 do
    local ang = i * U.TAU / 6 + self.age * 0.4
    Draw.capsule("fill", 0, 0, math.cos(ang) * r * 1.35, math.sin(ang) * r * 1.0 + step * ((i % 2) * 2 - 1), r * 0.08)
  end
  Draw.setColor(bl(2.6), a)
  Draw.blob(0, 0, r * 0.85, 7, (self.serial or 5) + 2, 0.2, 0.9)
  Draw.setColor(P.acid, a)
  love.graphics.circle("fill", self.faceX * r * 0.3, self.faceY * r * 0.3, r * 0.2)
end

function Enemy:body_spitter(r, a)
  local sp = self.spitAnim or 0
  Draw.setColor(bl(1.4), a)
  for i = -1, 1, 2 do
    Draw.capsule("fill", i * r * 0.45, r * 0.2, i * r * 0.66, r * 0.8, r * 0.13)
  end
  Draw.setColor(bl(2.1), a)
  Draw.blob(0, 0, r * 1.02, 8, (self.serial or 7) + 5, 0.14, 0.95)
  Draw.setColor(P.acid, a * (0.5 + sp * 0.5))
  local fa = math.atan2(self.faceY, self.faceX)
  love.graphics.circle("fill", math.cos(fa) * r * 0.7, math.sin(fa) * r * 0.7, r * (0.22 + sp * 0.18))
  Draw.setColor(bl(3.2), a)
  love.graphics.circle("fill", 0, -r * 0.3, r * 0.16)
end

function Enemy:body_siphon(r, a)
  Draw.setColor(bl(1.8), a * 0.9)
  Draw.blob(0, 0, r * 1.05, 10, (self.serial or 9) + 9, 0.1, 1.05)
  Draw.setColor(bl(3.0), a * 0.8)
  Draw.blob(0, -r * 0.15, r * 0.6, 8, 21, 0.12, 1)
  -- feeding tendril
  if self.feeding then
    Draw.setColor(P.acid, a * 0.55)
    love.graphics.setLineWidth(3)
    love.graphics.line(0, r * 0.6, math.sin(self.age * 3) * 6, r * 2.4)
    love.graphics.setLineWidth(1)
  end
  Draw.glow(0, 0, r * 2.4, P.ramp.blight[4], 0.35 * a)
end

function Enemy:body_bulwark(r, a)
  local step = math.sin(self.legPhase * 0.7) * r * 0.16
  Draw.setColor(bl(1.2), a)
  for i = -1, 1, 2 do
    Draw.capsule("fill", i * r * 0.55, r * 0.2, i * r * 0.78, r * 0.85 + step * i, r * 0.2)
  end
  Draw.setColor(bl(1.9), a)
  Draw.blob(0, 0, r, 8, (self.serial or 11) + 13, 0.1, 0.9)
  -- armour plates catch the light
  Draw.setColor(P.shade(P.ramp.rock, 2.6), a)
  Draw.roundRect("fill", -r * 0.8, -r * 0.7, r * 1.6, r * 0.8, r * 0.22)
  Draw.setColor(P.shade(P.ramp.rock, 3.4), a * 0.8)
  Draw.roundRect("fill", -r * 0.72, -r * 0.66, r * 1.44, r * 0.24, r * 0.12)
  Draw.setColor(P.ramp.blight[4], a)
  love.graphics.circle("fill", 0, r * 0.25, r * 0.18)
end

function Enemy:body_maw(r, a)
  local p = 0.85 + math.sin(self.pulse or 0) * 0.15
  Draw.setColor(P.shade(P.ramp.rift, 1.4), a)
  Draw.blob(0, 0, r * 1.25 * p, 12, 31, 0.22, 0.7)
  Draw.setColor(P.black, a)
  Draw.blob(0, 0, r * 0.8 * p, 10, 33, 0.24, 0.7)
  Draw.setColor(P.shade(P.ramp.rift, 3.6), a * 0.9)
  Draw.ring(0, 0, r * 1.1 * p, 3, 0, U.TAU, P.shade(P.ramp.rift, 3.6), 0.8)
  Draw.glow(0, 0, r * 3.2, P.ramp.rift[3], 0.5 * a)
  for i = 1, self.def.shovesToClose do
    Draw.setColor(i <= (self.shovesLeft or 0) and P.ramp.rift[4] or P.inkFaint,
                  i <= (self.shovesLeft or 0) and 0.9 or 0.2)
    love.graphics.circle("fill", -r * 0.9 + (i - 1) * (r * 1.8 / 5), -r * 1.7, r * 0.1)
  end
end

function Enemy:emitLight(Lighting)
  if self.type == "maw" then
    Lighting.addLight(self.x, self.y, 260, P.ramp.rift[3], 1.1, { flicker = 0.12 })
  elseif self.type == "siphon" then
    Lighting.addLight(self.x, self.y - 22, 120, P.ramp.blight[4], 0.5)
  elseif self.type == "spitter" then
    Lighting.addLight(self.x, self.y, 70, P.acid, 0.3)
  end
end

return Enemy
