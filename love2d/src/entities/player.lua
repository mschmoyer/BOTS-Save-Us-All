-- The last human. Fragile, fast, and unable to win a fight on their own.
-- Verbs: move, dash, shove, pulse, hand-plant, carry a downed bot.
local Class    = require("src.core.class")
local U        = require("src.core.util")
local Entity   = require("src.entities.entity")
local Input    = require("src.engine.input")
local J        = require("src.engine.juice")
local P        = require("src.engine.palette")
local Signal   = require("src.core.signal")
local Opt      = require("src.core.optional")
local T        = require("src.game.tuning").player

local Draw  = Opt.require("src.engine.draw")
local VFX   = Opt.require("src.engine.vfx")
local Audio = Opt.require("src.engine.audio")

local Player = Class("Player", Entity)

function Player:init(x, y, world)
  Player.super.init(self, x, y)
  self.kind    = "player"
  self.world   = world
  self.radius  = T.radius
  self.maxHp   = T.hearts
  self.hp      = T.hearts
  self.invuln  = 0

  self.state       = "alive"          -- "alive" | "down"
  self.downTimer   = 0
  self.dashTimer   = 0
  self.dashCd      = 0
  self.shoveCd     = 0
  self.shoveAnim   = 0
  self.plantCd     = 0
  self.charging    = false
  self.chargeT     = 0
  self.carrying    = nil               -- a downed bot

  self.walkPhase   = 0
  self.lean        = 0
  self.squash      = 1
  self.aimX, self.aimY = 0, 1
  self.suit        = true              -- removed in the ending
  self.trail       = {}
  for i = 1, T.dash.trail do self.trail[i] = { x = x, y = y, a = 0, ang = 0 } end
  self.trailHead   = 1
end

------------------------------------------------------------------------ helpers
--- One place to ask "did the player (or the autoplay agent) request this?".
function Player:wants(action)
  if self.agent then return self.autoAct and self.autoAct[action] == true end
  return Input.pressed(action)
end

function Player:canAct()
  return self.state == "alive" and not (self.world and self.world.cutscene)
end

function Player:speedMul()
  local m = 1
  if self.carrying then m = m * T.carry.speedMul end
  if self.charging then m = m * 0.45 end
  if self.world and self.world.chips then m = m * (self.world.chips:get("moveSpeed", 1)) end
  if self.lastLightOn then m = m * 1.35 end
  return m
end

------------------------------------------------------------------------ update
function Player:update(dt, camera)
  self:updateCommon(dt)

  if self.state == "down" then
    self.downTimer = self.downTimer - dt
    if self.downTimer <= 0 then self:reboot() end
    return
  end

  local canAct = self:canAct()
  local mx, my = 0, 0
  local auto
  if canAct then
    if self.agent then
      local ax, ay, act = self.agent:decide(self, dt)
      mx, my, auto = ax, ay, act
    else
      mx, my = Input.moveVector()
    end
  end
  self.autoAct = auto

  -- aim resolves from mouse / right stick / touch, falling back to facing
  local ax, ay
  if self.agent then
    ax, ay = self.faceX, self.faceY
  else
    ax, ay = Input.aimVector(self.x, self.y, self.faceX, self.faceY, camera)
  end
  self.aimX, self.aimY = ax, ay

  ------------------------------------------------------------------ dash
  self.dashCd = math.max(0, self.dashCd - dt)
  if self.dashTimer > 0 then
    self.dashTimer = self.dashTimer - dt
    self.invuln = math.max(self.invuln, T.dash.iframes * (self.dashTimer / T.dash.dur))
    self:pushTrail()
    if self.dashTimer <= 0 then
      self.vx, self.vy = self.vx * 0.42, self.vy * 0.42
      self.squash = 1.16
    end
  elseif canAct and self:wants("dash") and self.dashCd <= 0 then
    self:dash(mx, my)
  end

  ------------------------------------------------------------------ movement
  local speedMul = self:speedMul()
  if self.dashTimer <= 0 then
    if mx ~= 0 or my ~= 0 then
      -- extra authority when reversing makes direction changes feel crisp
      local dot = (mx * self.vx + my * self.vy)
      local assist = dot < 0 and (1 + T.turnAssist) or 1
      self.vx = self.vx + mx * T.accel * assist * dt
      self.vy = self.vy + my * T.accel * assist * dt
      self:setFacing(mx, my)
      self.walkPhase = self.walkPhase + dt * (6 + U.len(self.vx, self.vy) * 0.02)
    else
      self.walkPhase = self.walkPhase + dt * 1.2
    end
    self.vx, self.vy = U.limit(self.vx, self.vy, T.maxSpeed * speedMul)
    local k = math.exp(-T.friction * dt)
    if mx == 0 and my == 0 then self.vx, self.vy = self.vx * k, self.vy * k end
  end

  local moved = self:integrate(dt, 0)
  self:constrain(self.world and self.world.terrain, 0.2)

  -- Standing on a deposit works it loose. Shoving is faster and is the skilled
  -- option, but nobody should have to be told that walking into cobalt works.
  self.mineT = (self.mineT or 0) - dt
  if self.world and self.mineT <= 0 then
    if self.world:consumeCobaltNear(self.x, self.y, self.radius + T.carry.pickupRange, true) then
      self.mineT = T.mineEvery
      self.squash = 0.94
    end
  end

  -- footfalls
  self.footAccum = (self.footAccum or 0) + moved
  if self.footAccum > 34 and self.dashTimer <= 0 then
    self.footAccum = 0
    VFX.emit("footstep", self.x, self.y + self.radius * 0.6,
             { dx = -self.vx, dy = -self.vy, power = U.len(self.vx, self.vy) / T.maxSpeed })
  end

  ------------------------------------------------------------------ shove
  self.shoveCd = math.max(0, self.shoveCd - dt)
  self.shoveAnim = math.max(0, self.shoveAnim - dt * 5)
  if canAct and self:wants("shove") and self.shoveCd <= 0 and not self.charging then
    self:shove()
  end

  ------------------------------------------------------------------ pulse
  local wantPulse = self.agent and (auto and auto.pulse)
                    or ((not self.agent) and Input.down("pulse"))
  if canAct and wantPulse and self:cobalt() >= self:pulseCost() then
    if not self.charging then
      self.charging = true
      self.chargeT = 0
      Audio.play("pulse_charge")
    end
    self.chargeT = self.chargeT + dt
    if self.chargeT >= T.pulse.charge then self:pulse() end
  elseif self.charging then
    if self.chargeT >= T.pulse.charge * 0.55 then self:pulse() else self:cancelCharge() end
  end

  ------------------------------------------------------------------ plant
  self.plantCd = math.max(0, self.plantCd - dt)
  -- The plant key doubles as pick-up. If there is someone to carry, carrying
  -- always wins: nobody means to plant a tree over a bot that is still beeping.
  local rescuee = (canAct and self.world and not self.carrying)
                  and self.world:nearestDownedBot(self.x, self.y, T.carry.pickupRange) or nil
  -- The plant key is also pick-up and put-down. Carrying or standing over
  -- someone always wins: nobody means to plant a tree over a bot that is still
  -- beeping, or to pay three cobalt for putting one down.
  if canAct and self:wants("plant") and self.plantCd <= 0 and not rescuee
     and not self.carrying then
    self:handPlant()
  end

  ------------------------------------------------------------------ carry
  if canAct and self.world and not self.agent then self:updateCarry(dt) end
  if auto and auto.build and self.world then
    self.world:spawnBot(self.x + self.faceX * 30, self.y + self.faceY * 30, auto.build)
  end

  ------------------------------------------------------------------ cosmetic
  -- LAST LIGHT: on your final heart the world slows and you get quicker
  if self:chips() and self:chips():has("lastLight") then
    local low = self.hp <= 1 and self.state == "alive"
    if low ~= self.lastLightOn then
      self.lastLightOn = low
      J.dilate(low and 0.72 or 1, low and 999 or 0.4)
    end
  end

  local sp = U.len(self.vx, self.vy) / T.maxSpeed
  self.lean = U.damp(self.lean, U.clamp(self.vx / T.maxSpeed, -1, 1) * 0.22, 9, dt)
  self.squash = U.damp(self.squash, 1, 10, dt)
  self.bob = self.bob + dt * (2 + sp * 5)
end

------------------------------------------------------------------------ actions
function Player:dash(mx, my)
  local dx, dy = mx, my
  if dx == 0 and dy == 0 then dx, dy = self.faceX, self.faceY end
  dx, dy = U.norm(dx, dy)
  self.vx, self.vy = dx * T.dash.speed, dy * T.dash.speed
  self.dashTimer = T.dash.dur
  self.dashCd = T.dash.cooldown * self:chip("dashCd", 1)
  self.squash = 0.78
  self:setFacing(dx, dy)
  J.dilate(T.dash.dilation, T.dash.dilationDur)
  J.shake(0.1)
  VFX.emit("dash_burst", self.x, self.y, { dx = -dx, dy = -dy })
  Audio.play("dash")
  Input.rumble(0.25, 0.09)
  Signal.emit("player:dash", self)
  if self.world and self.world.chips and self.world.chips:has("kickstart") then
    self.world:areaShove(self.x, self.y, 120, 380, 0, 0.3)
    VFX.emit("pulse_ring", self.x, self.y, { scale = 0.5 })
  end
end

function Player:pushTrail()
  local t = self.trail[self.trailHead]
  t.x, t.y, t.a, t.ang = self.x, self.y, 1, self:facingAngle()
  self.trailHead = self.trailHead % #self.trail + 1
end

function Player:shove()
  self.shoveCd = T.shove.cooldown
  self.shoveAnim = 1
  local ang = math.atan2(self.aimY, self.aimX)
  local arc = T.shove.arc * (self.world and self.world.chips and self.world.chips:get("shoveArc", 1) or 1)
  local range = T.shove.range * (self.world and self.world.chips and self.world.chips:get("shoveRange", 1) or 1)
  Audio.play("shove_swing")
  VFX.emit("shove_arc", self.x, self.y, { angle = ang, spread = arc, scale = range / T.shove.range })
  local hits = 0
  if self.world then
    hits = self.world:coneShove(self.x, self.y, ang, arc * 0.5, range,
                               T.shove.force, T.shove.damage, T.shove.stun)
  end
  if hits > 0 then
    J.stop(T.shove.hitstop)
    J.shake(T.shove.trauma)
    J.punch(0.02)
    Audio.play("shove_hit", { pitch = 1 + (hits - 1) * 0.05 })
    Input.rumble(0.5, 0.14)
  end
  Signal.emit("player:shove", self, hits)
end

function Player:cancelCharge()
  self.charging = false
  self.chargeT = 0
  Audio.stop("pulse_charge")
end

function Player:chips() return self.world and self.world.chips or nil end
function Player:chip(k, d) local c = self:chips() return c and c:get(k, d) or d end

function Player:pulseCost()
  return math.max(2, T.pulse.cost + self:chip("pulseCost", 0))
end

function Player:pulse()
  self.charging = false
  self.chargeT = 0
  Audio.stop("pulse_charge")
  if not self:spend(self:pulseCost()) then return end
  local radius = T.pulse.radius * self:chip("pulseRadius", 1)
  Audio.play("pulse_release")
  VFX.emit("pulse_ring", self.x, self.y, { scale = radius / 200 })
  if self.world then
    self.world:areaShove(self.x, self.y, radius, T.pulse.force, T.pulse.damage, T.pulse.stun)
    if self.world.post then
      self.world.post.addShockwave(self.x, self.y, radius, 0.9, 0.55)
    end
  end
  J.stop(T.pulse.hitstop)
  J.shake(T.pulse.trauma)
  J.punch(0.05)
  J.flashScreen(0.16, P.accent[1], P.accent[2], P.accent[3])
  Input.rumble(0.9, 0.3)
  Signal.emit("player:pulse", self)
end

function Player:handPlant()
  if not self.world then return end
  local free = self.world.chips and self.world.chips:has("seedBank")
  local cost = free and 0 or T.plant.cost
  if self:cobalt() < cost then
    Audio.play("ui_back")
    Signal.emit("ui:denied", "cobalt")
    return
  end
  local px = self.x + self.faceX * 26
  local py = self.y + self.faceY * 26
  if self.world:plantTree(px, py, "player") then
    self:spend(cost)
    self.plantCd = T.plant.cooldown
    self.squash = 0.9
  else
    Audio.play("ui_back")
    Signal.emit("ui:denied", "space")
  end
end

function Player:updateCarry(dt)
  if self.carrying then
    local b = self.carrying
    b.x, b.y = self.x - self.faceX * 4, self.y - 26
    -- carrying is ended deliberately, on its own key, so a shove never fumbles
    if Input.pressed("plant") then self.world:dropCarried(self) end
    return
  end
  local bot = self.world:nearestDownedBot(self.x, self.y, T.carry.pickupRange)
  if bot and Input.pressed("plant") then
    self.carrying = bot
    bot.carried = true
    Audio.play("bot_revive", { pitch = 0.85 })
    Signal.emit("player:carry", bot)
  end
end

------------------------------------------------------------------------ economy
function Player:cobalt() return self.world and self.world.cobalt or 0 end
function Player:spend(n)
  if not self.world then return false end
  return self.world:spendCobalt(n)
end

------------------------------------------------------------------------- damage
function Player:onDamage(n, sx, sy)
  self.invuln = T.invuln * self:chip("invuln", 1)
  if sx then self:push(self.x - sx, self.y - sy, T.knockback) end
  J.shake(0.55) J.stop(0.07)
  J.flashScreen(0.3, P.danger[1], P.danger[2], P.danger[3])
  Input.rumble(0.85, 0.25)
  Audio.play("player_hurt")
  VFX.emit("hurt_spray", self.x, self.y, { dx = self.x - (sx or self.x), dy = self.y - (sy or self.y) })
  Signal.emit("player:hurt", self.hp)
end

function Player:onDeath()
  self.state = "down"
  self.downTimer = T.reboot
  self.vx, self.vy = 0, 0
  self.charging = false
  if self.carrying then self.world:dropCarried(self) end
  if self.world then self.world:loseCobaltFraction(T.rebootCostPct) end
  J.shake(0.9)
  J.dilate(0.35, 1.1)
  Audio.play("player_down")
  Signal.emit("player:down", self)
end

function Player:reboot()
  local hx, hy = self.world and self.world.homeX or self.x, self.world and self.world.homeY or self.y
  self.x, self.y = hx, hy
  self.state = "alive"
  self.hp = self.maxHp
  self.invuln = T.invuln * 1.6
  VFX.emit("bot_boot", self.x, self.y, { power = 1.4 })
  Audio.play("bot_boot", { pitch = 0.8 })
  Signal.emit("player:reboot", self)
end

------------------------------------------------------------------------- render
local function suitColor(t) return P.shade(P.ramp.metalW, t) end

function Player:drawShadow()
  Draw.softShadow(self.x, self.y + 4, self.radius * 1.15, self.radius * 0.52, 0.34)
end

function Player:draw()
  if self.state == "down" then self:drawDown() return end
  local g = love.graphics

  -- A ring on the ground and a rim on the body. Once the island is a forest the
  -- player is a 30 px figure among nine hundred canopies; without these you
  -- genuinely cannot find yourself.
  local pulse = 0.55 + math.sin(self.age * 2.4) * 0.12
  Draw.setColor(P.accent, 0.16 * pulse)
  g.setLineWidth(2)
  g.ellipse("line", self.x, self.y + self.radius * 0.55, self.radius * 1.5, self.radius * 0.6)
  g.setLineWidth(1)
  Draw.glow(self.x, self.y, self.radius * 2.6, P.accent, 0.1)
  local flicker = (self.invuln > 0 and math.floor(self.invuln * 22) % 2 == 0) and 0.45 or 1

  -- dash afterimages
  for i = 1, #self.trail do
    local t = self.trail[i]
    if t.a > 0.01 then
      t.a = t.a - love.timer.getDelta() * 5
      Draw.setColor(P.accent, t.a * 0.22)
      g.circle("fill", t.x, t.y, self.radius * (0.7 + t.a * 0.4))
    end
  end

  g.push()
  g.translate(self.x, self.y)
  local bobY = math.sin(self.bob) * 1.3
  g.translate(0, bobY)
  g.shear(self.lean * 0.4, 0)
  g.scale(1 / self.squash, self.squash)

  local ang = math.atan2(self.aimY, self.aimX)
  local r = self.radius

  -- legs: a simple two-beat cycle that reads at this size
  local step = math.sin(self.walkPhase) * math.min(1, U.len(self.vx, self.vy) / 160)
  Draw.setColor(suitColor(1.6), flicker)
  Draw.capsule("fill", -r * 0.36, r * 0.35 + step * 3, -r * 0.36, r * 0.78 + step * 3, r * 0.2)
  Draw.capsule("fill",  r * 0.36, r * 0.35 - step * 3,  r * 0.36, r * 0.78 - step * 3, r * 0.2)

  -- backpack
  Draw.setColor(suitColor(1.4), flicker)
  Draw.roundRect("fill", -r * 0.62, -r * 0.1, r * 1.24, r * 0.92, r * 0.3)

  -- torso
  Draw.setColor(suitColor(self.suit and 2.5 or 2.1), flicker)
  Draw.roundRect("fill", -r * 0.56, -r * 0.55, r * 1.12, r * 1.24, r * 0.42)
  Draw.setColor(suitColor(3.2), flicker * 0.9)
  Draw.roundRect("fill", -r * 0.44, -r * 0.5, r * 0.88, r * 0.42, r * 0.22)

  -- shove arm sweep
  if self.shoveAnim > 0 then
    local sweep = ang + (1 - self.shoveAnim) * 1.5 - 0.75
    Draw.setColor(P.accent, self.shoveAnim * 0.85)
    Draw.capsule("fill", 0, 0, math.cos(sweep) * r * 2.1, math.sin(sweep) * r * 2.1, r * 0.24)
  end

  -- helmet, with a cool rim on the light side so the silhouette separates
  Draw.setColor(suitColor(self.suit and 3.0 or 2.2), flicker)
  love.graphics.circle("fill", 0, -r * 0.72, r * 0.62)
  Draw.setColor(P.accentCool, 0.5 * flicker)
  love.graphics.setLineWidth(1.6)
  love.graphics.arc("line", "open", 0, -r * 0.72, r * 0.62, math.pi * 0.85, math.pi * 1.75)
  love.graphics.setLineWidth(1)
  if self.suit then
    -- visor faces the aim direction
    Draw.setColor(P.accentCool, 0.9 * flicker)
    local vx, vy = math.cos(ang) * r * 0.2, math.sin(ang) * r * 0.2 - r * 0.72
    Draw.blob(vx, vy, r * 0.34, 7, 12, 0.12, 0.7)
    Draw.setColor(P.ink, 0.5 * flicker)
    love.graphics.circle("fill", vx + r * 0.1, vy - r * 0.08, r * 0.09)
  end

  g.pop()

  -- charge ring
  if self.charging then
    local p = U.saturate(self.chargeT / T.pulse.charge)
    Draw.ring(self.x, self.y, r * 2.4 + (1 - p) * 22, 3, -math.pi / 2, -math.pi / 2 + p * U.TAU,
              P.accent, 0.6)
    Draw.glow(self.x, self.y, r * (1.4 + p * 2.2), P.accent, p * 0.6)
  end

  -- dash cooldown dial
  if self.dashCd > 0 then
    local p = 1 - self.dashCd / T.dash.cooldown
    Draw.ring(self.x, self.y + r * 1.5, r * 0.9, 2, -math.pi / 2, -math.pi / 2 + p * U.TAU,
              P.inkFaint, 0.4)
  end

  -- carried bot rides on the shoulder
  if self.carrying and self.carrying.drawCarried then self.carrying:drawCarried() end
end

function Player:drawDown()
  local g = love.graphics
  local r = self.radius
  Draw.setColor(suitColor(1.5), 0.9)
  g.push() g.translate(self.x, self.y) g.rotate(1.2)
  Draw.roundRect("fill", -r * 0.6, -r * 0.5, r * 1.2, r * 1.1, r * 0.4)
  g.pop()
  local p = 1 - self.downTimer / T.reboot
  Draw.ring(self.x, self.y, r * 2.2, 3, -math.pi / 2, -math.pi / 2 + p * U.TAU, P.danger, 0.5)
end

--- The player's lamp, registered with the lighting system each frame.
function Player:emitLight(Lighting)
  local warm = P.mix(P.eye, P.white, 0.25)
  Lighting.addLight(self.x, self.y, T.lamp.radius, warm, T.lamp.warm, { flicker = 0.05 })
  if self.charging then
    Lighting.addLight(self.x, self.y, 120 * (0.4 + self.chargeT), P.accent, 1.2)
  end
end

return Player
