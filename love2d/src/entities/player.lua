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
local TU       = require("src.game.tuning")
local T        = TU.player
local TI       = TU.idle
local TN       = TU.notice
local TH       = TU.helmet
local TR       = TU.rescue

local Draw  = Opt.require("src.engine.draw")
local VFX   = Opt.require("src.engine.vfx")
local Audio = Opt.require("src.engine.audio")

local Player = Class("Player", Entity)

-- Light options, hoisted. `Lighting.addLight` reads the table and copies what
-- it needs into its parallel arrays -- it never keeps a reference -- so a
-- constant options table is a constant, and building one per light per frame
-- was pure garbage. Same idiom as `demo_light.lua`'s OPT_ tables.
local OPT_LAMP = { flicker = 0.05 }

-- The general idle pool, and the three "anything but the last one" variants of
-- it. Hoisted because they are constants and `beginGesture` runs every few
-- seconds for the whole run.
local IDLE_ALL          = { "shoulder", "sky", "suit" }
local IDLE_NOT_SHOULDER = { "sky", "suit" }
local IDLE_NOT_SKY      = { "shoulder", "suit" }
local IDLE_NOT_SUIT     = { "shoulder", "sky" }

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
  self.pulseCd     = 0
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

  -- What he does when nobody is asking him to do anything. See `updateIdle`.
  self.idleT     = 0
  self.idleNext  = TI.delay
  self.gesture   = nil                 -- id of the gesture running, or nil
  self.gestureT  = 0
  self.lastGest  = nil
  self.gestSide  = 1
  self.swayT     = 0
  -- Pose channels. Each one is a damped scalar a gesture writes a target into
  -- and the body reads; nothing snaps, so a gesture cut short by the player
  -- picking up the controller unwinds instead of popping.
  self.pzRoll, self.pzChest, self.pzHead, self.pzLean = 0, 0, 0, 0
  -- Where his head is pointed, which is not always where he is aiming.
  self.gazeX, self.gazeY = 0, 1
  self.headTurn  = 0
  self.noticeT   = 0
  self.noticeCd  = 0
  self.noticeX, self.noticeY = 0, 0
  -- Bodies he has already looked at, so he does not look twice. Weak keys: a
  -- bot that expires must not be held alive by the fact he saw it fall.
  self.seenDown  = setmetatable({}, { __mode = "k" })
  self.fumbleT   = 0
  self.idleRng   = U.rng(math.floor(x * 7 + y * 13) + 91)
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
  return m
end

------------------------------------------------------------------------ update
--- `realDt` is the wall clock, and it is here for one reason: the idle.
---
--- game.lua freezes the simulation while anybody is talking -- `world:update(
--- talking and 0 or dt, realDt)` -- so during every cutscene this function ran
--- with dt = 0 and the idle clock could not advance. That is the whole reason
--- the prologue was a parked sprite, and dropping the `canAct()` gate in
--- `updateIdle` (the obvious fix, and the one this was diagnosed as) does
--- nothing on its own: measured before and after, the player region changed by
--- the same 3,950 pixels either way. Ambient motion is not simulation, so it
--- gets the real clock, exactly as `World:update` already does for the x-ray
--- when the sim is stopped. With dt > 0 the two are the same number.
function Player:update(dt, camera, realDt)
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
    -- The agent aims where it is looking, not where it is walking. Backing away
    -- from the rig while shoving used to point the cone at the treeline, which
    -- made every headless balance trace read as if the player did no damage.
    ax, ay = self.agent.aimX or self.faceX, self.agent.aimY or self.faceY
  else
    ax, ay = Input.aimVector(self.x, self.y, self.faceX, self.faceY, camera)
  end
  self.aimX, self.aimY = ax, ay

  self:updateBlaster(dt, canAct)

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
  -- Hands full. You cannot swing a blade with a machine over your shoulder, and
  -- that is the whole of what a rescue costs: for the length of the walk you
  -- are a man with no weapons and one dash.
  if canAct and self:wants("shove") and self.shoveCd <= 0 and not self.charging
     and not (TR.handsFull and self.carrying) then
    self:shove()
  end

  ------------------------------------------------------------------ pulse
  self.pulseCd = math.max(0, self.pulseCd - dt)
  local wantPulse = (self.agent and (auto and auto.pulse)
                    or ((not self.agent) and Input.down("pulse")))
                    and not (TR.handsFull and self.carrying)
  if canAct and wantPulse and self.pulseCd <= 0 and self:cobalt() >= self:pulseCost() then
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
  if canAct and self.world then self:updateCarry(dt) end
  if auto and auto.build and self.world then
    self.world:spawnBot(self.x + self.faceX * 30, self.y + self.faceY * 30, auto.build)
  end

  ------------------------------------------------------------------ cosmetic
  local sp = U.len(self.vx, self.vy) / T.maxSpeed
  self.lean = U.damp(self.lean, U.clamp(self.vx / T.maxSpeed, -1, 1) * 0.22, 9, dt)
  self.squash = U.damp(self.squash, 1, 10, dt)
  self.bob = self.bob + dt * (2 + sp * 5)
  -- idle first: it is what decides where he is looking, and the gaze that
  -- reads it is resolved in the same frame rather than the next one.
  self:updateIdle(realDt or dt, mx, my)
  self:updateNotice(dt)
end

--------------------------------------------------------------------- behaviour
-- He speaks eight times in fifteen minutes. Everything else he feels arrives
-- through this section, and none of it is a performance: no sighs, no slumps,
-- nothing that tells the player how to take him. A tired competent man standing
-- in a field, and the one thing he keeps checking that never says anything.
--
-- All of it is cosmetic. The aim vector, the shove cone, the blaster and the
-- carry never read a single value written here, which is why it is allowed to
-- happen while the player is busy doing something else.

--- Hold-shaped envelope: up over `edge` of the gesture, flat, down over `edge`.
local function hold(k, edge)
  return U.saturate(math.min(k, 1 - k) / (edge or 0.25))
end

--- He notices the dead.
---
--- A machine goes down inside `range` and he turns his head to it for a second
--- and a bit, and then goes back to what he was doing. It costs nothing, it
--- interrupts nothing, and it is meant to be caught out of the corner of the
--- eye rather than watched.
function Player:updateNotice(dt)
  self.noticeCd = math.max(0, self.noticeCd - dt)
  if self.noticeT > 0 then self.noticeT = math.max(0, self.noticeT - dt) end

  local w = self.world
  if w and w.bots and self.state == "alive" and not w.cutscene then
    local list, best, bestD = w.bots, nil, TN.range * TN.range
    for i = 1, #list do
      local b = list[i]
      if b.alive and b.state == "down" then
        if not self.seenDown[b] then
          local dx, dy = b.x - self.x, b.y - self.y
          local d2 = dx * dx + dy * dy
          if d2 < bestD then best, bestD = b, d2 end
        end
      elseif self.seenDown[b] and b.state ~= "dead" then
        -- back on its feet: the next time it falls is a new thing to see
        self.seenDown[b] = nil
      end
    end
    if best then
      -- Marked seen whether or not he is free to look, so a body that fell
      -- while he was mid-dash is not stared at ten seconds later.
      self.seenDown[best] = true
      if self.noticeCd <= 0 then
        self.noticeT  = TN.dur
        self.noticeCd = TN.cooldown
        self.noticeX, self.noticeY = best.x, best.y
      end
    end
  end

  -- Gaze. Default is wherever he is aiming; a body he has just noticed wins,
  -- and the radio wins over that (`updateIdle` sets `gazeAtX`).
  local tx, ty, turn = self.aimX, self.aimY, 0
  if self.noticeT > 0 then
    local dx, dy = U.norm(self.noticeX - self.x, self.noticeY - self.y)
    if dx ~= 0 or dy ~= 0 then
      tx, ty = dx, dy
      turn = hold(1 - self.noticeT / TN.dur, 0.22)
    end
  end
  if self.gazeAtX then
    local dx, dy = U.norm(self.gazeAtX - self.x, self.gazeAtY - self.y)
    if dx ~= 0 or dy ~= 0 then tx, ty, turn = dx, dy, math.max(turn, self.gazeAtK or 1) end
  end
  self.gazeX = U.damp(self.gazeX, tx, TN.gaze, dt)
  self.gazeY = U.damp(self.gazeY, ty, TN.gaze, dt)
  self.headTurn = U.damp(self.headTurn, turn, TN.gaze, dt)
end

--- Standing still.
---
--- Under everything is a weight shift that never stops. On top of it, a gesture
--- every few seconds: near the Home Rig it is always the radio, and anywhere
--- else it is one of three small mechanical things a man does with his own body
--- while he waits.
function Player:updateIdle(dt, mx, my)
  self.swayT = self.swayT + dt
  self.gazeAtX, self.gazeAtY, self.gazeAtK = nil, nil, nil

  local still = (mx == 0 and my == 0)
                and self.dashTimer <= 0 and not self.charging and not self.carrying
                and self.shoveAnim <= 0.02
                and U.len(self.vx, self.vy) < TI.stillSpeed
                -- NOT `canAct()`, which is false during any cutscene. He is the
                -- SUBJECT of the cutscenes -- the prologue is the longest
                -- uninterrupted look at him in the game before the ending -- and
                -- gating stillness on it meant `idleT` reset every frame, so
                -- `settle` stayed 0 and even the ambient weight shift was off.
                -- Measured over the prologue: 5.3 seconds and three spoken
                -- lines with ONE pixel in the whole 90x140 player region
                -- differing by more than 10/255. He was a parked sprite.
                and self.state == "alive"

  if still then
    self.idleT = self.idleT + dt
    if not self.gesture and self.idleT >= self.idleNext then self:beginGesture() end
  else
    self.idleT = 0
    self.idleNext = TI.delay
    self.gesture = nil
  end

  local roll, chest, head, lean = 0, 0, 0, 0
  local g = self.gesture
  if g then
    self.gestureT = self.gestureT + dt
    local k = self.gestureT / (TI.dur[g] or 1.6)
    if k >= 1 then
      self.gesture = nil
      self.idleT = 0
      self.idleNext = self:rand(TI.gap[1], TI.gap[2])
    elseif g == "shoulder" then
      -- a hand up to the back of the neck and down again, once
      roll = math.sin(k * math.pi) ^ 0.7
    elseif g == "sky" then
      -- looking up. There is nothing up there and he knows it.
      head = hold(k, 0.28)
    elseif g == "suit" then
      -- a hand across to the chest, over the readout, which dips while he reads
      chest = hold(k, 0.22)
      roll = -chest
    elseif g == "radio" then
      -- the rig. He turns to it, leans in, and it says nothing.
      local rig = self.world and self.world.rig
      if rig then
        self.gazeAtX, self.gazeAtY = rig.x, rig.y
        self.gazeAtK = hold(k, 0.18)
        lean = self.gazeAtK * TI.leanIn * ((rig.x < self.x) and -1 or 1)
      end
    end
  end

  local d = TI.damp
  self.pzRoll  = U.damp(self.pzRoll,  roll,  d, dt)
  self.pzChest = U.damp(self.pzChest, chest, d, dt)
  self.pzHead  = U.damp(self.pzHead,  head,  d, dt)
  self.pzLean  = U.damp(self.pzLean,  lean,  d, dt)
end

--- His own stream, never the world's. Which shoulder he rolls must not be able
--- to move where a deposit spawns, or two balance traces of the same seed stop
--- being the same run.
function Player:rand(a, b)
  return self.idleRng:range(a, b)
end

--- Pick the next one. Inside `rigRange` of the Home Rig it is never a choice.
function Player:beginGesture()
  local rig = self.world and self.world.rig
  local g
  if rig and U.dist(self.x, self.y, rig.x, rig.y) < TI.rigRange then
    g = "radio"
  else
    -- never the same one twice running: three gestures on a loop is a tic
    local pool = (self.lastGest == "shoulder") and IDLE_NOT_SHOULDER
              or (self.lastGest == "sky") and IDLE_NOT_SKY
              or (self.lastGest == "suit") and IDLE_NOT_SUIT
              or IDLE_ALL
    g = pool[math.floor(self:rand(1, #pool + 0.999))]
  end
  self.gesture  = g
  self.gestureT = 0
  self.lastGest = g
  self.gestSide = (self:rand(0, 1) < 0.5) and -1 or 1
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
  self.shoveAngle = ang          -- emitLight lays the blade's light along it
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
  return math.max(0, T.pulse.cost + self:chip("pulseCost", 0))
end

function Player:pulse()
  self.charging = false
  self.chargeT = 0
  Audio.stop("pulse_charge")
  if not self:spend(self:pulseCost()) then return end
  self.pulseCd = T.pulse.cooldown
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
  -- The autoplay agent asks for pick-up and put-down through the same one
  -- action a player presses; it cannot press a key. Rescuing is a third of what
  -- a good player does at night, and a stand-in that never does it makes every
  -- headless balance trace read as a much worse run than the game deserves.
  self.fumbleT = math.max(0, self.fumbleT - dt)
  local press = self.agent and (self.autoAct and self.autoAct.carry == true)
                or (not self.agent and Input.pressed("plant"))
  if self.carrying then
    local b = self.carrying
    b.x, b.y = self.x - self.faceX * 4, self.y - 26
    -- carrying is ended deliberately, on its own key, so a shove never fumbles
    if press then self:putDown() end
    return
  end
  local bot = self.world:nearestDownedBot(self.x, self.y, T.carry.pickupRange)
  if bot and press and self.fumbleT <= 0 then
    self.carrying = bot
    bot.carried = true
    Audio.play("bot_revive", { pitch = 0.85 })
    Signal.emit("player:carry", bot)
  end
end

--- Put the body down. One place, so a deliberate put-down and a fumble go
--- through the same code and the same accounting.
function Player:putDown(reason)
  local b = self.carrying
  if not b then return end
  self.world:dropCarried(self)
  if reason == "hit" then
    -- You have to stoop for them again, and the clock did not stop while you did
    self.fumbleT = TR.fumble
    if b.state ~= "work" then
      Audio.play("bot_down", { pitch = 1.12, volume = 0.55, x = b.x, y = b.y })
      Signal.emit("player:fumble", b)
    end
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
  -- A hit puts them down where you stood. Two hearts and a hundred metres of
  -- dark forest was a walk; it is a decision now.
  if TR.dropOnHit and self.carrying then self:putDown("hit") end
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
  if self.carrying then self:putDown("hit") end
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
-- The suit is cool and dark on purpose. It used to be cut from the warm brass
-- ramp, which put the last human at the same value and very nearly the same
-- hue as sunlit grass: at play scale he was a tan capsule with a beige circle
-- on top and he vanished into the ground the moment the forest got busy.
-- Dark-and-cool separates by value *and* by hue, and it leaves the only bright
-- marks on him -- visor, chest lamp, one hard rim -- reading as him.
--
-- Both look-ups are cached on the ramp position they are asked for. `P.shade`
-- blends two stops into a *fresh table* every time it is called, and the body
-- asks for a dozen of them a frame at positions that never change -- every
-- call site below passes a literal, so the cache holds a dozen entries and
-- then stops growing. The colour returned is shared: read it, never keep it or
-- edit it. An explicit alpha still takes the fresh-table path, because that is
-- the one argument a caller does vary.
local SUIT_C, BARE_C = {}, {}
local BOOT   -- the darkest thing he owns, resolved below once `suit` exists
local function suit(t, a)
  if a then return P.shade(P.ramp.suit, t, a) end
  local c = SUIT_C[t]
  if not c then c = P.shade(P.ramp.suit, t) SUIT_C[t] = c end
  return c
end
local function bare(t, a)
  if a then return P.shade(P.ramp.sand, t, a) end
  local c = BARE_C[t]
  if not c then c = P.shade(P.ramp.sand, t) BARE_C[t] = c end
  return c
end

function Player:drawShadow()
  -- Two shadows, not one. The wide soft one is the body occluding the sky; the
  -- tight dark one under the boots is the contact patch, and it is the whole
  -- difference between a man standing on the island and a decal hovering four
  -- pixels above it.
  local r = self.radius
  Draw.softShadow(self.x, self.y + 5, r * 1.30, r * 0.56, 0.30)
  Draw.softShadow(self.x, self.y + r * 0.98, r * 0.62, r * 0.24, 0.55)
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
  -- The weight shift. It never stops and it is barely a pixel; it is the whole
  -- difference between a man standing in a field and a sprite parked in one.
  local sway = math.sin(self.swayT * U.TAU / TI.swayPeriod) * TI.sway
  local settle = U.saturate(self.idleT / TI.delay)
  g.translate(sway * settle, bobY)
  -- the head turn takes the torso a little way with it
  local gang = math.atan2(self.gazeY, self.gazeX)
  local twist = self.headTurn * TN.lean * math.cos(gang)
  g.shear(self.lean * 0.4 + self.pzLean + twist, 0)
  g.scale(1 / self.squash, self.squash)

  local ang = math.atan2(self.aimY, self.aimX)
  local r = self.radius
  local sp = math.min(1, U.len(self.vx, self.vy) / 160)
  local step = math.sin(self.walkPhase) * sp

  -- legs and boots. The boots are the darkest thing he owns and they sit
  -- exactly where the contact shadow is, which is what sells the weight.
  for i = -1, 1, 2 do
    local k = step * i * 3.4
    Draw.setColor(suit(1.7), flicker)
    Draw.capsule("fill", i * r * 0.30, r * 0.36, i * r * 0.30, r * 0.96 + k, r * 0.185)
    BOOT = BOOT or P.darken(suit(1), 0.3)
    Draw.setColor(BOOT, flicker)
    Draw.capsule("fill", i * r * 0.30 - r * 0.10, r * 1.00 + k,
                        i * r * 0.30 + r * 0.16, r * 1.00 + k, r * 0.19)
  end

  -- the rig on his back: a wider, darker mass, so the torso in front of it has
  -- an edge to be read against instead of fading into the grass
  Draw.setColor(suit(1.5), flicker)
  Draw.roundRect("fill", -r * 0.62, -r * 0.80, r * 1.24, r * 1.18, r * 0.34)
  Draw.setColor(P.accent, 0.5 * flicker)
  Draw.roundRect("fill", -r * 0.40, -r * 0.62, r * 0.80, r * 0.10, r * 0.05)

  -- arms swing against the legs: two beats, opposite phase, and it is the
  -- motion rather than the shape that reads at thirty pixels
  -- One arm does the idle, and it is drawn in front of the torso rather than
  -- behind it. Behind, a hand brought across the chest to read the suit is a
  -- hand you cannot see, and a shoulder worked back is four hidden pixels.
  -- `pzRoll` positive is the shoulder; negative is the same hand on the chest.
  local gestArm = math.abs(self.pzRoll) > 0.02 and self.gestSide or nil
  Draw.setColor(suit(1.9), flicker)
  for i = -1, 1, 2 do
    if i ~= gestArm then
      local k = -step * i * 3.0
      Draw.capsule("fill", i * r * 0.50, -r * 0.44, i * r * 0.56, r * 0.28 + k, r * 0.155)
    end
  end

  -- torso, narrower than the rig, with the two chest bars the dialogue portrait
  -- wears -- so the man in the frame and the man on the island are one person
  Draw.setColor(suit(2.3), flicker)
  Draw.roundRect("fill", -r * 0.46, -r * 0.76, r * 0.92, r * 1.30, r * 0.36)
  Draw.setColor(suit(3.0), flicker * 0.95)
  Draw.roundRect("fill", -r * 0.36, -r * 0.70, r * 0.72, r * 0.44, r * 0.22)
  -- The chest readout. It dips while he is reading it, which is the only tell
  -- that the suit-check gesture is a check of anything.
  local chestA = 1 - self.pzChest * TI.chestBlink
  Draw.setColor(P.accent, 0.9 * flicker * chestA)
  Draw.roundRect("fill", -r * 0.26, -r * 0.16, r * 0.30, r * 0.10, r * 0.05)
  Draw.roundRect("fill", -r * 0.26, r * 0.04, r * 0.46, r * 0.10, r * 0.05)
  Draw.glow(-r * 0.05, r * 0.04, r * 0.7, P.accent, 0.22 * flicker * chestA, 2)

  -- ...and the idle arm, over all of it.
  if gestArm then
    local i, a = gestArm, self.pzRoll
    local hx, hy = i * r * 0.56, r * 0.28
    if a > 0 then
      -- back of the neck: the hand comes up beside the helmet, which is the one
      -- place on him where a hand is unmistakably a hand at thirty pixels
      hx = hx + (i * r * 0.80 - hx) * a
      hy = hy + (-r * 0.94 - hy) * a
    else
      -- over the chest readout, on top of the readout he is reading
      local b = -a
      hx = hx + (-i * r * 0.02 - hx) * b
      hy = hy + (r * 0.06 - hy) * b
    end
    Draw.setColor(suit(2.0), flicker)
    Draw.capsule("fill", i * r * 0.50, -r * 0.44, hx, hy, r * 0.14)
    Draw.setColor(suit(1.2), flicker)
    love.graphics.circle("fill", hx, hy, r * 0.13)
  end

  -- shove arm sweep
  if self.shoveAnim > 0 then
    local sweep = ang + (1 - self.shoveAnim) * 1.5 - 0.75
    Draw.setColor(P.accent, self.shoveAnim * 0.85)
    Draw.capsule("fill", 0, 0, math.cos(sweep) * r * 2.1, math.sin(sweep) * r * 2.1, r * 0.24)
  end

  -- neck and helmet. He is a head taller than he was; the extra height is all
  -- above the shoulders, which is what makes a silhouette read as a person
  -- rather than as a bollard.
  -- Where the head is. It rides the turn -- a machine goes down beside him and
  -- he looks at it -- and the sky gesture lifts it. Both are a couple of pixels
  -- and both are the only thing on him that moves while he is standing still.
  local hox = math.cos(gang) * r * TN.turn * self.headTurn
  local hoy = math.sin(gang) * r * TN.turn * 0.5 * self.headTurn
              - r * TI.headLift * self.pzHead
  local hcy = -r * 1.32 + hoy

  Draw.setColor(suit(1.4), flicker)
  Draw.roundRect("fill", -r * 0.15 + hox * 0.5, -r * 1.06 + hoy * 0.5,
                 r * 0.30, r * 0.34, r * 0.10)
  Draw.setColor(self.suit and suit(2.5) or bare(2.4), flicker)
  g.circle("fill", hox, hcy, r * 0.53)

  -- the rim. One light, upper-left, on the helmet and down the near edge of the
  -- torso. Hard and bright: a 40% rim is a rim you cannot see at play scale.
  Draw.setColor(P.accentCool, 0.95 * flicker)
  g.setLineWidth(r * 0.12)
  g.arc("line", "open", hox, hcy, r * 0.53, math.pi * 0.80, math.pi * 1.66)
  g.setLineWidth(1)
  Draw.capsule("fill", -r * 0.42, -r * 0.46, -r * 0.42, r * 0.30, r * 0.055)

  if self.suit then
    -- visor: bright, glowing, and it turns to whatever he is LOOKING at, which
    -- is where he is aiming except in the second after something of his falls
    -- over, when it is that instead
    local vox, voy = math.cos(gang) * r * 0.16, math.sin(gang) * r * 0.12
    local vx, vy = hox + vox, hcy + voy - r * 0.02
    -- the glass sits in a dark recess, exactly the way a bot's eye plate does:
    -- the same device on both faces, which is most of the reason the crew are
    -- allowed to read as people
    Draw.setColor(suit(1.0), flicker)
    Draw.blob(hox + vox * 0.55, hcy + voy * 0.55 + r * 0.01, r * 0.44, 9, 12, 0.07, 0.72)
    Draw.glow(vx, vy, r * 0.95, P.accentCool, 0.28 * flicker, 2)
    Draw.setColor(P.accentCool, flicker)
    Draw.blob(vx, vy, r * 0.31, 9, 12, 0.10, 0.66)
    Draw.setColor(P.white, 0.85 * flicker)
    g.circle("fill", vx - r * 0.10, vy - r * 0.09, r * 0.068)
  else
    -- NO HELMET, AND STILL A FACE.
    --
    -- The visor was the only feature this head had and it is gated on the suit,
    -- so the instant the ending sets the helmet down, his head became a bare
    -- oval with a rim arc on it -- at the one moment in the game the camera
    -- pushes in on the grounds that it is "close enough to read his face"
    -- (scenes/ending.lua). It is also the silhouette the comment above the suit
    -- palette calls out as the failure that rewrite existed to escape.
    --
    -- The portrait in game/dialogue.lua already proves the design at close
    -- range: hair, brows, eyes. At world scale it is the hair and the eyes, and
    -- the eyes take the same gaze offset the visor used, so the head still
    -- turns to whatever he is looking at -- which through the whole last scene
    -- is the machines standing around him.
    local vox, voy = math.cos(gang) * r * 0.16, math.sin(gang) * r * 0.12
    Draw.setColor(P.shade(P.ramp.bark, 2.0), flicker)
    Draw.blob(hox, hcy - r * 0.20, r * 0.47, 11, 14, 0.09, 0.50)
    for sd = -1, 1, 2 do
      Draw.setColor(P.shade(P.ramp.bark, 1.1), 0.92 * flicker)
      g.circle("fill", hox + vox + sd * r * 0.19, hcy + voy + r * 0.05, r * 0.072)
    end
  end

  g.pop()

  -- Charge ring. The glow behind it used to run to 0.6 alpha over a disc more
  -- than three times the player's radius, which at full charge put a solid
  -- bloom exactly where the character is -- so the tell for "you are about to
  -- do something" worked by hiding the person doing it. The ring carries the
  -- reading; the glow is a hint underneath it, and it sits *behind* rather
  -- than on top.
  if self.charging then
    local p = U.saturate(self.chargeT / T.pulse.charge)
    Draw.glow(self.x, self.y, r * (1.9 + p * 2.4), P.accent, p * 0.20)
    Draw.ring(self.x, self.y, r * 2.4 + (1 - p) * 22, 2.5, -math.pi / 2, -math.pi / 2 + p * U.TAU,
              P.accent, 0.75)
  end

  -- dash cooldown dial
  if self.dashCd > 0 then
    local p = 1 - self.dashCd / T.dash.cooldown
    Draw.ring(self.x, self.y + r * 1.5, r * 0.9, 2, -math.pi / 2, -math.pi / 2 + p * U.TAU,
              P.inkFaint, 0.4)
  end

  -- the sidearm firing. Short, hot and gone in a tenth of a second: it has to
  -- say "that shot came from you" without competing with the shot itself
  local bf = self.blasterFlash or 0
  if bf > 0 and self.blasterAim then
    local a = self.blasterAim
    local cx, cy = self.x + math.cos(a) * r * 1.15, self.y - 8 + math.sin(a) * r * 1.15
    Draw.setColor(P.lightPlayer, 0.75 * bf)
    love.graphics.setLineWidth(2 + 2 * bf)
    love.graphics.line(cx, cy, cx + math.cos(a) * 14 * bf, cy + math.sin(a) * 14 * bf)
    Draw.glow(cx, cy, 13 * bf, P.lightPlayer, 0.5 * bf)
  end

  -- a hairline to whatever the blaster has picked, so the auto-target is a
  -- thing you can see deciding rather than a thing that happens
  local tgt = self.blasterTarget
  if tgt and tgt.alive then
    local a = math.atan2(tgt.y - self.y, tgt.x - self.x)
    local d = U.dist(self.x, self.y, tgt.x, tgt.y)
    Draw.setColor(P.lightPlayer, 0.13)
    love.graphics.setLineWidth(1)
    love.graphics.line(self.x + math.cos(a) * r * 1.3, self.y - 8 + math.sin(a) * r * 1.3,
                       self.x + math.cos(a) * (d - (tgt.radius or 12)),
                       self.y - 8 + math.sin(a) * (d - (tgt.radius or 12)))
  end

  -- carried bot rides on the shoulder
  if self.carrying and self.carrying.drawCarried then self.carrying:drawCarried() end

  -- and the helmet, if it is off. Drawn last and in world space: it ends up in
  -- front of his boots, and it is not part of the body that leans and squashes.
  self:drawHelmet()
end

------------------------------------------------------------------- the helmet
-- At the ending the suit comes off. In the portrait that reads beautifully; in
-- the world he used to simply acquire a pale head, and a mechanic does not
-- vanish a part -- he sets it down.
--
-- The scene that plays the ending does not tick the world, so this runs off
-- wall-clock from the moment it is armed rather than off a dt. That also means
-- it needs no hook at all: `Player:draw` arms it the first frame the suit is
-- gone, so it works whether or not the ending ever calls anything.

--- Take it off and set it on the grass. Idempotent, and there is no way back.
--- `side` is -1 or 1 and picks which side of his boots it lands on.
function Player:setHelmetDown(side)
  if self.helmet then return end
  self.suit = false
  self.helmet = {
    t0   = love.timer and love.timer.getTime() or 0,
    side = (side == -1) and -1 or 1,
    x    = self.x, y = self.y,        -- where he was standing when he did it
  }
  Signal.emit("player:helmetOff", self)
  return self.helmet
end

function Player:drawHelmet()
  if not self.suit and not self.helmet then self:setHelmetDown() end
  local h = self.helmet
  if not h then return end
  local g = love.graphics
  local r = self.radius
  local now = love.timer and love.timer.getTime() or 0
  local t = now - h.t0

  -- Path. It sits on his head while he breaks the seal, then goes down and out
  -- in one movement, and it stops.
  local k = U.saturate((t - TH.seal) / TH.lower)
  local u = k * k * (3 - 2 * k)
  local x0, y0 = h.x, h.y - r * 1.32 - U.saturate(t / TH.seal) * r * 0.18
  local x1, y1 = h.x + h.side * r * TH.side, h.y + r * TH.drop
  local hx = x0 + (x1 - x0) * u
  local hy = y0 + (y1 - y0) * u - math.sin(u * math.pi) * TH.arc

  local down = (k >= 1)
  if down then
    -- it is a part, on the ground, with a part's shadow under it
    Draw.softShadow(hx, hy + r * 0.14, r * 0.60, r * 0.24, 0.5)
  end

  -- the shell, foreshortened once it is lying down
  local sq = down and 0.82 or 1
  g.push()
  g.translate(hx, hy)
  g.scale(1, sq)
  Draw.setColor(suit(2.5))
  g.circle("fill", 0, 0, r * 0.53)
  Draw.setColor(P.accentCool, down and 0.6 or 0.95)
  g.setLineWidth(r * 0.12)
  g.arc("line", "open", 0, 0, r * 0.53, math.pi * 0.80, math.pi * 1.66)
  g.setLineWidth(1)
  -- the glass. It goes out on the grass over the next few seconds, and that is
  -- the last lit thing he owns.
  local lit = down and U.saturate(1 - (t - TH.seal - TH.lower) / TH.fade) or 1
  Draw.setColor(suit(1.0))
  Draw.blob(0, r * 0.02, r * 0.42, 9, 12, 0.07, 0.72)
  if lit > 0.01 then
    Draw.setColor(P.accentCool, lit)
    Draw.blob(0, 0, r * 0.29, 9, 12, 0.10, 0.66)
  end
  g.pop()
  if lit > 0.01 then Draw.glow(hx, hy, r * 0.9, P.accentCool, 0.24 * lit, 2) end
end

function Player:drawDown()
  local g = love.graphics
  local r = self.radius
  g.push() g.translate(self.x, self.y) g.rotate(1.2)
  Draw.setColor(suit(1.8), 0.95)
  Draw.roundRect("fill", -r * 0.6, -r * 0.5, r * 1.2, r * 1.1, r * 0.4)
  Draw.setColor(suit(2.4), 0.95)
  g.circle("fill", r * 0.62, -r * 0.1, r * 0.5)
  Draw.setColor(P.accentCool, 0.35)
  Draw.capsule("fill", -r * 0.5, -r * 0.42, r * 0.5, -r * 0.42, r * 0.06)
  g.pop()
  local p = 1 - self.downTimer / T.reboot
  Draw.ring(self.x, self.y, r * 2.2, 3, -math.pi / 2, -math.pi / 2 + p * U.TAU, P.danger, 0.5)
end

--- The player's lamp, registered with the lighting system each frame.
--- The sidearm.
---
--- It picks its own target and fires on a cooldown, because the thing this
--- game asks of your hands is where to stand and what to build, and adding an
--- aim-and-click on top of that would take attention off both. Range is about
--- five body lengths, which is short on purpose: it makes stepping toward a
--- Chomper a real decision instead of a free one, and it never turns the
--- player into a substitute for a Sentry line.
function Player:updateBlaster(dt, canAct)
  local B = T.blaster
  self.fireT = math.max(0, (self.fireT or 0) - dt)
  self.blasterFlash = math.max(0, (self.blasterFlash or 0) - dt * 9)
  self.blasterTarget = nil
  if not canAct or self.state ~= "alive" then return end
  local w = self.world
  if not w or not w.nearestEnemy then return end

  local e = w:nearestEnemy(self.x, self.y, B.range, function(en)
    return en.alive and not en.fleeing
  end)
  if not e then return end
  self.blasterTarget = e
  if self.fireT > 0 then return end
  self.fireT = B.every

  -- lead it, the same way a Sentry does, or nothing fast ever gets hit
  local d = U.dist(self.x, self.y, e.x, e.y)
  local tt = d / B.speed
  local ang = math.atan2(e.y + (e.vy or 0) * tt - self.y,
                         e.x + (e.vx or 0) * tt - self.x)
  if w.rng then ang = ang + w.rng:range(-B.spread, B.spread) end
  local mx, my = math.cos(ang), math.sin(ang)
  w:spawnDart(self.x + mx * 18, self.y - 8 + my * 18, ang, B.speed, B.damage, self)
  self.blasterFlash = 1
  self.blasterAim = ang
  VFX.emit("blaster_muzzle", self.x + mx * 22, self.y - 8 + my * 22,
           { dx = mx * 90, dy = my * 90 })
  Audio.play("spit", { pitch = 1.85, volume = 0.42, x = self.x, y = self.y })
end

function Player:emitLight(Lighting)
  -- Yellow, and the only yellow that moves. The crew light the ground blue and
  -- the Blight lights it red, so the one warm pool on a night island is you --
  -- which is the whole of how you find yourself in a crowded frame.
  local warm = P.lightPlayer
  Lighting.addLight(self.x, self.y, T.lamp.radius, warm, T.lamp.warm, OPT_LAMP)
  if self.charging then
    Lighting.addLight(self.x, self.y, 120 * (0.4 + self.chargeT), P.accent, 1.2)
  end

  -- The blade. The swing threw an arc of particles and lit nothing, so at
  -- night the one thing in your hands that kills was invisible in the frame it
  -- mattered. Three lights along the cut, hot at the wrist and falling off at
  -- the tip, for as long as the swing animates -- a moving light rather than a
  -- flash, so you can see what it reached.
  local sa = self.shoveAnim or 0
  if sa > 0.02 then
    local ang = self.shoveAngle or math.atan2(self.aimY or 0, self.aimX or 1)
    local L = T.shove.light
    for i = 1, 3 do
      local d = T.shove.range * (i / 3) * (0.55 + 0.45 * sa)
      local k = (1.15 - i * 0.22) * sa
      Lighting.addLight(self.x + math.cos(ang) * d, self.y + math.sin(ang) * d,
                        L.radius * (1.1 - i * 0.12), P.lightPlayer, L.gain * k, nil)
    end
  end
end

return Player
