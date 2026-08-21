-- Harvester Prime: the extraction rig that came for the last of the air.
-- Its maximum health is the size of the workforce you built. Three phases.
local Class  = require("src.core.class")
local U      = require("src.core.util")
local Entity = require("src.entities.entity")
local P      = require("src.engine.palette")
local J      = require("src.engine.juice")
local Signal = require("src.core.signal")
local Opt    = require("src.core.optional")
local T      = require("src.game.tuning").boss

local Draw  = Opt.require("src.engine.draw")
local VFX   = Opt.require("src.engine.vfx")
local Audio = Opt.require("src.engine.audio")

local Boss = Class("Boss", Entity)

function Boss:init(x, y, world, botCount)
  Boss.super.init(self, x, y)
  self.kind   = "boss"
  self.world  = world
  self.radius = 62
  self.maxHp  = math.floor(math.max(T.hpFloor, botCount * T.hpPerBot))
  self.hp     = self.maxHp
  self.phase  = 1
  self.state  = "arrive"
  self.stateT = 0
  self.legPhase = 0
  self.beamAngle = 0
  self.beamT = 0
  self.slamT = T.slamEvery
  self.droneT = T.droneEvery
  self.plates = 6
  self.coreOpen = 0
  self.rng = U.rng((world and world.seed or 1) * 104729 + 4242)
  self.hover = 0
  Signal.emit("boss:spawned", self)
end

function Boss:hpFrac() return self.hp / self.maxHp end

function Boss:update(dt)
  self:updateCommon(dt)
  self.stateT = self.stateT + dt
  self.hover = self.hover + dt * 1.3
  local w = self.world
  local p = w and w.player

  if self.state == "arrive" then
    if self.stateT > 2.2 then self.state = "hunt" self.stateT = 0 end
    return
  end

  -- Phase transitions, but never two inside `phaseGap` seconds: the beam sweep
  -- and the ground slam each need a moment on screen or they never happen.
  local f = self:hpFrac()
  self.sincePhase = (self.sincePhase or T.phaseGap) + dt
  if self.sincePhase >= T.phaseGap then
    if self.phase == 1 and f <= T.phase2At then self:enterPhase(2)
    elseif self.phase == 2 and f <= T.phase3At then self:enterPhase(3) end
  end

  if self.state == "beam" then self:updateBeam(dt) return end
  if self.state == "slam" then self:updateSlam(dt) return end

  -- hunt: walk at the player
  if p then
    local dx, dy, d = U.norm(p.x - self.x, p.y - self.y)
    local sp = T.speed * (1 + (1 - f) * 0.35)
    self.vx = U.damp(self.vx, dx * sp, 3, dt)
    self.vy = U.damp(self.vy, dy * sp, 3, dt)
    self:integrate(dt, 0)
    self:setFacing(dx, dy)
    self.legPhase = self.legPhase + dt * 3.2
    if d < self.radius + p.radius then
      p:damage(T.contactDmg, self.x, self.y)
    end
  end

  self.beamT = self.beamT - dt
  self.slamT = self.slamT - dt
  self.droneT = self.droneT - dt

  if self.phase >= 1 and self.beamT <= 0 then
    self.state, self.stateT = "beam", 0
    self.beamAngle = p and math.atan2(p.y - self.y, p.x - self.x) or 0
    Audio.play("boss_beam")
    VFX.emit("beam_charge", self.x, self.y, { power = 1 })
  elseif self.phase >= 2 and self.slamT <= 0 then
    self.state, self.stateT = "slam", 0
  end

  if self.phase >= 1 and self.droneT <= 0 and w and w:enemyCount() < 34 then
    self.droneT = T.droneEvery * (self.phase >= 2 and 0.7 or 1)
    if w then
      for i = 1, 1 + self.phase do
        local a = self.rng:angle()
        w:spawnEnemyAt(self.x + math.cos(a) * 90, self.y + math.sin(a) * 90,
                       self.phase >= 2 and "skitter" or "chomper")
      end
    end
    VFX.emit("rift_open", self.x, self.y, { power = 0.6 })
  end
end

function Boss:enterPhase(n)
  self.phase = n
  self.sincePhase = 0
  self.state, self.stateT = "hunt", 0
  J.shake(0.8) J.stop(0.12)
  J.flashScreen(0.25, P.ramp.blight[4][1], P.ramp.blight[4][2], P.ramp.blight[4][3])
  Audio.play("boss_hurt", { pitch = 0.7 })
  if n == 2 then
    VFX.emit("armour_break", self.x, self.y, { power = 1.5 })
    self.plates = 3
  elseif n == 3 then
    VFX.emit("core_expose", self.x, self.y, { power = 2 })
    self.plates = 0
    self.coreOpen = 1
  end
  Signal.emit("boss:phase", n)
end

function Boss:updateBeam(dt)
  local t = self.stateT
  local p = self.world and self.world.player
  if t < T.beamCharge then
    if p then
      self.beamAngle = U.dampAngle(self.beamAngle, math.atan2(p.y - self.y, p.x - self.x), 3, dt)
    end
    self.beamCharging = U.saturate(t / T.beamCharge)
    return
  end
  self.beamCharging = nil
  local swept = t - T.beamCharge
  if swept > T.beamSweep then
    self.state, self.stateT = "hunt", 0
    self.beamT = 7 - self.phase
    return
  end
  self.beamAngle = self.beamAngle + dt * 0.9 * (self.beamDir or 1)
  self.beamLen = 900
  -- the beam burns whatever it crosses
  if self.world then
    self.world:beamSweep(self.x, self.y, self.beamAngle, self.beamLen, dt)
  end
  if self.rng:chance(dt * 20) then
    VFX.emit("blight_spore", self.x + math.cos(self.beamAngle) * self.rng:range(60, 700),
                             self.y + math.sin(self.beamAngle) * self.rng:range(60, 700))
  end
end

function Boss:updateSlam(dt)
  local t = self.stateT
  self.vx, self.vy = self.vx * 0.85, self.vy * 0.85
  self:integrate(dt, 4)
  if t > 0.85 and not self.slammed then
    self.slammed = true
    J.shake(0.85) J.stop(0.1) J.punch(0.05)
    VFX.emit("slam_dust", self.x, self.y, { power = 2 })
    Audio.play("boss_step", { pitch = 0.7 })
    if self.world then
      self.world:areaShove(self.x, self.y, 300, 900, 0, 0.9, true)
      local p = self.world.player
      if p and U.dist(p.x, p.y, self.x, self.y) < 300 then p:damage(1, self.x, self.y) end
      if self.world.post then self.world.post.addShockwave(self.x, self.y, 320, 1.2, 0.6) end
    end
  end
  if t > 1.5 then
    self.state, self.stateT = "hunt", 0
    self.slammed = false
    self.slamT = T.slamEvery
  end
end

--- The player's shove and a sentry dart both route through here. Armour plates
--- soak most of it early; once the core is exposed you can really hurt it.
function Boss:shove(dx, dy, force, damage, stun)
  local dmg = damage or 0
  if self.plates > 0 then
    dmg = dmg * 0.5
    VFX.emit("hit_spark", self.x + dx * 0.4, self.y + dy * 0.4, { color = P.warn })
    if dmg < 1 then
      self.flash = 0.1
      Audio.play("shove_hit", { pitch = 0.6, x = self.x, y = self.y })
      return true
    end
  end
  self.stagger = math.min(1, (self.stagger or 0) + 0.25)
  self:damage(math.max(1, math.floor(dmg)), self.x - dx, self.y - dy)
  return true
end

function Boss:onDamage(n, sx, sy)
  Audio.play("boss_hurt", { x = self.x, y = self.y })
  VFX.emit("impact", self.x + (sx and (sx - self.x) * 0.6 or 0),
                     self.y + (sy and (sy - self.y) * 0.6 or 0), { power = 1.2 })
  J.shake(0.14)
  Signal.emit("boss:hurt", self.hp, self.maxHp)
end

function Boss:onDeath()
  self.alive = false
  self.dying = true
  J.shake(1) J.dilate(0.25, 2.2)
  Audio.play("boss_hurt", { pitch = 0.5 })
  Signal.emit("boss:died", self)
end

------------------------------------------------------------------------- render
local function bl(t) return P.shade(P.ramp.blight, t) end
local function ri(t) return P.shade(P.ramp.rift, t) end

function Boss:drawShadow()
  Draw.softShadow(self.x, self.y + 14, self.radius * 1.5, self.radius * 0.6, 0.42)
end

function Boss:draw()
  local g = love.graphics
  local r = self.radius
  local arrive = self.state == "arrive" and U.saturate(self.stateT / 2.2) or 1
  g.push()
  g.translate(self.x, self.y - 10 + math.sin(self.hover) * 4)
  g.scale(arrive, arrive)

  -- legs
  Draw.setColor(bl(1.2))
  for i = 0, 5 do
    local a = i * U.TAU / 6 + math.pi / 12
    local step = math.sin(self.legPhase + i) * r * 0.14
    Draw.capsule("fill", math.cos(a) * r * 0.4, math.sin(a) * r * 0.3,
                 math.cos(a) * r * 1.5, math.sin(a) * r * 1.0 + step + r * 0.3, r * 0.11)
  end

  -- hull
  Draw.setColor(bl(1.8))
  Draw.blob(0, 0, r * 1.06, 12, 71, 0.1, 0.82)
  Draw.setColor(bl(2.5))
  Draw.blob(0, -r * 0.1, r * 0.82, 10, 73, 0.1, 0.86)

  -- armour plates
  for i = 1, self.plates do
    local a = (i - 1) / math.max(1, self.plates) * U.TAU + self.age * 0.2
    Draw.setColor(P.shade(P.ramp.rock, 2.8))
    Draw.roundRect("fill", math.cos(a) * r * 0.68 - r * 0.2, math.sin(a) * r * 0.5 - r * 0.14,
                   r * 0.4, r * 0.28, r * 0.1)
  end

  -- core
  local corePulse = 0.7 + math.sin(self.age * 3) * 0.3
  local coreC = self.coreOpen > 0 and P.danger or ri(3)
  Draw.setColor(coreC, 0.85)
  love.graphics.circle("fill", 0, -r * 0.12, r * (0.3 + self.coreOpen * 0.1) * corePulse)
  Draw.glow(0, -r * 0.12, r * (1.2 + self.coreOpen * 0.8) * corePulse, coreC, 0.6)

  -- extraction funnel pointed at the sky
  Draw.setColor(ri(2), 0.7)
  Draw.capsule("fill", 0, -r * 0.5, 0, -r * 1.5, r * 0.22)
  Draw.setColor(ri(4), 0.5 + corePulse * 0.3)
  love.graphics.circle("fill", 0, -r * 1.55, r * 0.28)

  g.pop()

  -- beam
  if self.beamCharging then
    local a = self.beamAngle
    Draw.setColor(P.danger, 0.3 + self.beamCharging * 0.4)
    love.graphics.setLineWidth(1 + self.beamCharging * 3)
    love.graphics.line(self.x, self.y, self.x + math.cos(a) * 900, self.y + math.sin(a) * 900)
    love.graphics.setLineWidth(1)
    Draw.glow(self.x, self.y, r * 2 * self.beamCharging, P.danger, self.beamCharging)
  elseif self.state == "beam" then
    local a = self.beamAngle
    local x2, y2 = self.x + math.cos(a) * 900, self.y + math.sin(a) * 900
    Draw.beam(self.x, self.y, x2, y2, 26, P.danger, 0.7)
    Draw.beam(self.x, self.y, x2, y2, 9, P.white, 0.5)
  end
end

function Boss:emitLight(Lighting)
  Lighting.addLight(self.x, self.y - 10, 420, P.ramp.rift[3], 1.0, { flicker = 0.08 })
  if self.state == "beam" then
    Lighting.addLight(self.x, self.y, 700, P.danger, 1.4)
  end
end

return Boss
