-- Every robot in the game. Six types share one chassis: boot-up, an eye that
-- looks at what it cares about, idle chatter, a downed state you can rescue,
-- and a death that is supposed to cost you something.
local Class   = require("src.core.class")
local U       = require("src.core.util")
local Entity  = require("src.entities.entity")
local P       = require("src.engine.palette")
local J       = require("src.engine.juice")
local Signal  = require("src.core.signal")
local Names   = require("src.game.names")
local Opt     = require("src.core.optional")
local TU      = require("src.game.tuning")
local T       = TU.bots

local Draw  = Opt.require("src.engine.draw")
local VFX   = Opt.require("src.engine.vfx")
local Audio = Opt.require("src.engine.audio")

local Bot = Class("Bot", Entity)

local serials = {}
function Bot.resetSerials() serials = {} end

function Bot:init(x, y, botType, world, rng)
  Bot.super.init(self, x, y)
  local def = T[botType]
  assert(def, "unknown bot type: " .. tostring(botType))

  self.kind    = "bot"
  self.type    = botType
  self.def     = def
  self.world   = world
  self.rng     = rng or U.rng(math.floor(x * 31 + y * 17 + love.timer.getTime() * 1000))
  self.radius  = def.radius
  self.maxHp   = def.hp
  self.hp      = def.hp
  self.static  = def.speed == 0

  serials[botType] = (serials[botType] or 0) + 1
  self.serial  = serials[botType]
  self.name    = Names.name(def.prefix, self.serial)
  self.trait   = Names.trait(self.rng)

  self.state       = "boot"           -- boot | work | down | dead | rebel
  self.stateT      = 0
  self.bootT       = T.bootTime * ((world and world.chips and world.chips:has("quickBoot")) and 0.12 or 1)
  self.mood        = "normal"         -- normal | confused | love
  self.eyeX, self.eyeY = 0, 1
  self.actionT     = self.rng:range(0.3, 1.4)
  self.wanderT     = 0
  self.wx, self.wy = x, y
  self.chatterT    = self.rng:range(T.chatterEvery[1], T.chatterEvery[2])
  self.carried     = false
  self.downT       = 0
  self.tilt        = 0
  self.spin        = 0
  self.charges     = def.charges
  self.carry       = def.carryStart or 0
  self.cargo       = 0
  self.aimAngle    = self.rng:angle()
  self.pulseT      = 0
  self.blink       = self.rng:range(0, 4)
  self.planted     = 0        -- what this one actually did, for its epitaph
  self.built       = 0

  Audio.play("bot_boot", { pitch = 1 + (self.rng:next() - 0.5) * 0.12, x = x, y = y })
  VFX.emit("bot_boot", x, y, { power = 1 })
  Signal.emit("bot:spawned", self)
end

------------------------------------------------------------------------ helpers
function Bot:speed()
  local m = 1
  if self.world and self.world.chips then m = self.world.chips:get("botSpeed", 1) end
  if self.chorus then m = m * 1.2 end
  return self.def.speed * m
end

function Bot:workRate()
  local m = 1
  if self.world and self.world.rallyX then
    m = m * (1 + TU.rally.workBonus * self.world:rallyPull(self.x, self.y))
  end
  if self.world and self.world.chips then m = self.world.chips:get("botWork", 1) end
  if self.chorus then m = m * 1.2 end
  if self.world and self.world.beaconBoostAt then
    m = m * (1 + self.world:beaconBoostAt(self.x, self.y))
  end
  return m
end

function Bot:say(phase)
  if not self.world or not self.world.speak then return end
  self.world:speak(self, Names.line(phase, self.rng, self.world.treeCount or 0, self.trait))
end

function Bot:lookAt(x, y)
  local dx, dy = U.norm(x - self.x, y - self.y)
  self.eyeX = U.damp(self.eyeX, dx, 9, 1 / 60)
  self.eyeY = U.damp(self.eyeY, dy, 9, 1 / 60)
end

------------------------------------------------------------------------ update
function Bot:update(dt)
  self:updateCommon(dt)
  self.stateT = self.stateT + dt
  self.blink = self.blink + dt

  if self.state == "boot" then
    self.bootT = self.bootT - dt
    if self.bootT <= 0 then
      self.state = "work"
      self.stateT = 0
      if self.world and self.world.player then self:lookAt(self.world.player.x, self.world.player.y) end
    end
    return
  end

  if self.state == "down" then
    self.downT = self.downT - dt
    self.spin = self.spin + dt * 0.6
    if not self.carried then
      if self.rng:chance(dt * 3) then VFX.emit("bot_spark", self.x, self.y) end
      if self.world and self.world.beaconAt and self.world:beaconAt(self.x, self.y) then
        self.reviveT = (self.reviveT or 0) + dt
        if self.reviveT >= T.beacon.reviveTime then self:revive() end
      else
        self.reviveT = 0
      end
    end
    if self.downT <= 0 then self:expire() end
    return
  end

  if self.state == "rebel" then self:updateRebel(dt) return end

  -- chatter, but never over a cutscene or the ending: the human saying "the air
  -- is back" under a bubble reading "this one is crooked" is the exact failure
  -- the old codebase was full of
  local w = self.world
  if w and (w.cutscene or w.phase == "ending") then
    self.chatterT = math.max(self.chatterT, 4)
  end
  self.chatterT = self.chatterT - dt
  if self.chatterT <= 0 then
    self.chatterT = self.rng:range(T.chatterEvery[1], T.chatterEvery[2])
    local phase = (self.world and self.world.phase == "night") and "night" or "day"
    if self.mood == "confused" then phase = "boss" end
    self:say(phase)
  end

  if self.mood == "confused" then
    -- orders stopped making sense: drift on the last heading, look around
    self:moveToward(self.wx, self.wy, dt, 0.35)
    if self.rng:chance(dt * 0.6) then
      self.wx = self.x + self.rng:range(-120, 120)
      self.wy = self.y + self.rng:range(-120, 120)
    end
    return
  end

  local fn = self["update_" .. self.type]
  if fn then fn(self, dt) end
end

function Bot:moveToward(tx, ty, dt, mul)
  local sp = self:speed() * (mul or 1)
  if sp <= 0 then return true end
  local dx, dy, d = U.norm(tx - self.x, ty - self.y)
  if d < 6 then return true end
  self.vx = U.damp(self.vx, dx * sp, 8, dt)
  self.vy = U.damp(self.vy, dy * sp, 8, dt)
  self:integrate(dt, 0)
  self:constrain(self.world and self.world.terrain, 0)
  self:setFacing(dx, dy)
  self:lookAt(tx, ty)
  return false
end

function Bot:pickWander(minSoil)
  local w = self.world
  -- The standing order: when the player has planted a flag, look for ground
  -- near it instead of near yourself. This is how the wood gets a direction.
  if w and w.rallyX then
    local pull = w:rallyPull(self.x, self.y)
    if pull > 0 and self.rng:chance(TU.rally.pull) then
      local a, d = self.rng:angle(), self.rng:range(0, TU.rally.radius)
      local rx, ry = w.rallyX + math.cos(a) * d, w.rallyY + math.sin(a) * d
      if w.terrain and w.terrain.nearestLand then
        local lx, ly = w.terrain:nearestLand(rx, ry)
        if lx then rx, ry = lx, ly end
      end
      self.wx, self.wy = rx, ry
      return
    end
  end
  if w and w.terrain and w.terrain.randomLandPoint then
    local x, y = w.terrain:randomLandPoint(self.rng, {
      minSoil = minSoil, near = { x = self.x, y = self.y, r = 420 },
    })
    if x then self.wx, self.wy = x, y return end
  end
  local a, d = self.rng:angle(), self.rng:range(120, 380)
  self.wx, self.wy = self.x + math.cos(a) * d, self.y + math.sin(a) * d
end

---------------------------------------------------------------- type behaviours
function Bot:update_planter(dt)
  self.actionT = self.actionT - dt * self:workRate()
  if self:moveToward(self.wx, self.wy, dt) then self:pickWander(0.45) end
  if self.actionT <= 0 then
    local n = (self.world and self.world.chips and self.world.chips:has("secondShift")) and 2 or 1
    local planted = 0
    for _ = 1, n do
      if self.world and self.world:plantTree(
           self.x + self.rng:range(-14, 14), self.y + self.rng:range(6, 22), self) then
        planted = planted + 1
        self.planted = self.planted + 1
      end
    end
    self.actionT = self.def.plantEvery * (planted > 0 and 1 or 0.35)
    if planted > 0 then
      self.squashT = 0.3
      if self.rng:chance(0.16) then self:say("day") end
    end
  end
end

function Bot:update_builder(dt)
  self.actionT = self.actionT - dt * self:workRate()
  if self:moveToward(self.wx, self.wy, dt) then self:pickWander(0.3) end
  -- top up from cobalt underfoot
  if self.world and self.world.consumeCobaltNear and self.carry < self.def.carryMax then
    if self.world:consumeCobaltNear(self.x, self.y, 30) then
      self.carry = self.carry + 1
      VFX.emit("cobalt_pickup", self.x, self.y)
    end
  end
  -- COPY WORK makes a Builder build whatever you last built rather than only
  -- Planters, and a dearer machine costs it more of what it found.
  local want    = (self.world and self.world.copyType) or "planter"
  local wantDef = T[want] or T.planter
  local buildCost = (self.def.buildCost or 2)
                    * math.max(1, math.ceil(wantDef.cost / T.planter.cost))
  if self.actionT <= 0 and self.carry >= buildCost then
    -- Out of its own carry, and nothing out of the player's bank: the cobalt
    -- it walked over is the cobalt the machine is made of.
    if self.world and self.world:spawnBot(self.x + self.rng:range(-20, 20),
                                          self.y + self.rng:range(10, 26), want, true) then
      self.carry = self.carry - buildCost
      self.built = self.built + 1
      self.actionT = self.def.buildEvery / (self.world.chips and self.world.chips:get("buildRate", 1) or 1)
      self.squashT = 0.4
      Audio.play("build_done", { x = self.x, y = self.y })
    else
      self.actionT = 1.5
    end
  end
end

function Bot:update_repulsor(dt)
  -- It holds its charges until something is actually in range. pulseT started
  -- at zero, so a Repulsor fired the instant it booted whether or not anything
  -- was near it and was gone four and a half seconds later -- a twelve-cobalt
  -- firework you could not learn anything from. Now it is a mine you place in
  -- front of a wave, which is what its own card says it is.
  local w = self.world
  local armed = false
  if w and w.hEnemy then
    local r = self.def.radius_pulse
    w.hEnemy:each(self.x, self.y, r, function(e)
      if e.alive and not e.fleeing and U.dist2(e.x, e.y, self.x, self.y) <= r * r then
        armed = true
      end
    end)
  end
  if not armed then
    self.pulseT = math.min(self.pulseT, self.def.pulseEvery)
    return
  end
  self.pulseT = self.pulseT - dt
  if self.pulseT <= 0 then
    self.pulseT = self.def.pulseEvery
    self.charges = self.charges - 1
    self.pulseAnim = 1
    if self.world then
      self.world:areaShove(self.x, self.y, self.def.radius_pulse, self.def.force,
                           self.def.damage or 0, self.def.stun)
    end
    VFX.emit("pulse_ring", self.x, self.y, { scale = self.def.radius_pulse / 200, color = P.accentCool })
    Audio.play("pulse_release", { pitch = 1.25, volume = 0.6, x = self.x, y = self.y })
    J.shake(0.08)
    if self.charges <= 0 then
      self:say("day")
      self:expire(true)
    end
  end
  if self.world and self.world.player then self:lookAt(self.world.player.x, self.world.player.y) end
end

function Bot:update_sentry(dt)
  self.actionT = self.actionT - dt * self:workRate()
  local chips = self.world and self.world.chips
  local range = self.def.range * (chips and chips:get("sentryRange", 1) or 1)
  local target = self.world and self.world:nearestEnemy(self.x, self.y, range)
  if target then
    self:lookAt(target.x, target.y)
    self.aimAngle = U.dampAngle(self.aimAngle, math.atan2(target.y - self.y, target.x - self.x), 10, dt)
    if self.actionT <= 0 then
      self.actionT = self.def.fireEvery / (chips and chips:get("sentryRate", 1) or 1)
      -- lead the target so darts actually connect
      local d = U.dist(self.x, self.y, target.x, target.y)
      local tt = d / self.def.dartSpeed
      local ax = math.atan2(target.y + target.vy * tt - self.y, target.x + target.vx * tt - self.x)
      ax = ax + self.rng:range(-self.def.spread, self.def.spread)
      self.world:spawnDart(self.x, self.y - 10, ax, self.def.dartSpeed, self.def.damage, self)
      self.recoil = 1
      Audio.play("spit", { pitch = 1.5, volume = 0.5, x = self.x, y = self.y })
    end
  else
    self.aimAngle = self.aimAngle + dt * 0.35
    self.eyeX, self.eyeY = math.cos(self.aimAngle), math.sin(self.aimAngle)
  end
  self.recoil = math.max(0, (self.recoil or 0) - dt * 6)
end

function Bot:update_harvester(dt)
  local cap = self.def.capacity + (self.world.chips and self.world.chips:get("harvestBonus", 0) or 0) * 3
  if self.cargo >= cap then
    local w = self.world
    local tx, ty = w.player.x, w.player.y
    if w.homeX and U.dist2(self.x, self.y, w.homeX, w.homeY) < U.dist2(self.x, self.y, tx, ty) then
      tx, ty = w.homeX, w.homeY
    end
    if U.dist(self.x, self.y, tx, ty) < self.def.depositRange then
      self.world:addCobalt(self.cargo * TU.cobalt.chunkValue, self.x, self.y)
      self.cargo = 0
      Audio.play("deposit_pop", { x = self.x, y = self.y })
      VFX.emit("deposit_pop", self.x, self.y)
    else
      self:moveToward(tx, ty, dt)
    end
    return
  end
  local node = self.world and self.world:nearestCobalt(self.x, self.y, self.def.seekRange)
  local tithe = self.world.chips and self.world.chips:has("tithe")
  if node then
    if self:moveToward(node.x, node.y, dt) or U.dist(self.x, self.y, node.x, node.y) < 26 then
      if self.world:consumeCobaltNear(self.x, self.y, 30) then
        self.cargo = self.cargo + 1
                     + (self.world.chips and self.world.chips:get("harvestBonus", 0) or 0)
        VFX.emit("cobalt_pickup", self.x, self.y)
      end
    end
  else
    if self:moveToward(self.wx, self.wy, dt) then self:pickWander() end
  end
end

function Bot:update_beacon(dt)
  self.glowPhase = (self.glowPhase or 0) + dt * 1.1
  if self.world and self.world.player then self:lookAt(self.world.player.x, self.world.player.y) end
end

---------------------------------------------------------------- the rebellion
function Bot:rebel(target)
  if self.state ~= "work" then return end
  self.state = "rebel"
  self.mood = "love"
  self.target = target
  self.stateT = 0
  -- nothing stops them now; the run they make is the whole point of the game
  self.invuln = 900
  VFX.emit("love_heart", self.x, self.y - 20, { power = 1 })
  self:say("rebel")
end

function Bot:updateRebel(dt)
  local t = self.target
  if not t or not t.alive then self.state = "work" self.mood = "normal" return end
  local sp = math.max(150, self:speed() * 2.1)
  local dx, dy, d = U.norm(t.x - self.x, t.y - self.y)
  self.vx, self.vy = dx * sp, dy * sp
  self:integrate(dt, 0)
  self:lookAt(t.x, t.y)
  if self.rng:chance(dt * 6) then VFX.emit("love_heart", self.x, self.y - 16, { power = 0.4 }) end
  if d < t.radius + self.radius then
    t:damage(self.world and self.world.rebelDamage or 1, self.x, self.y, { source = "bot" })
    VFX.emit("bot_death", self.x, self.y, { power = 1.2 })
    VFX.emit("love_heart", self.x, self.y, { power = 1.5 })
    -- Not bot_down at a higher pitch: that cue tells the player a Chomper
    -- popped, and it ducks the music 0.28 for 1.1s -- forty of those land
    -- during the finale, holding the score down for the whole of it.
    Audio.play("bot_sacrifice", { x = self.x, y = self.y })
    J.shake(0.2) J.stop(0.04)
    self.alive = false
    self.state = "dead"
    Signal.emit("bot:sacrificed", self)
  end
end

------------------------------------------------------------------------ damage
function Bot:onDamage(n, sx, sy)
  Audio.play("bot_hurt", { x = self.x, y = self.y })
  VFX.emit("hit_spark", self.x, self.y, { dx = self.x - (sx or self.x), dy = self.y - (sy or self.y) })
  if not self.static and sx then self:push(self.x - sx, self.y - sy, 90) end
  if self.rng:chance(0.35) then self:say("hurt") end
end

function Bot:onDeath()
  if self.world and self.world.chips and self.world.chips:has("warranty") and not self.warrantyUsed then
    self.warrantyUsed = true
    self.hp = math.max(1, math.floor(self.maxHp * 0.5))
    self.invuln = 1.2
    VFX.emit("bot_boot", self.x, self.y, { power = 1.2 })
    Audio.play("bot_revive")
    return
  end
  self.state = "down"
  self.downT = T.downedTime * (self.world and self.world.chips and self.world.chips:get("downedTime", 1) or 1)
  -- what the window started at, so the HUD's rescue ring can read as a fraction
  -- rather than pretending every bot has the same twenty seconds a chip may
  -- have just extended
  self.downMax = self.downT
  self.reviveT = 0
  self.vx, self.vy = 0, 0
  Audio.play("bot_down", { x = self.x, y = self.y })
  VFX.emit("bot_spark", self.x, self.y, { power = 1.4 })
  J.shake(0.12)
  Signal.emit("bot:downed", self)
end

function Bot:revive()
  self.state = "work"
  self.hp = math.max(1, math.floor(self.maxHp * 0.6))
  self.stateT = 0
  self.carried = false
  self.reviveT = 0
  VFX.emit("bot_boot", self.x, self.y, { power = 1.2 })
  VFX.emit("love_heart", self.x, self.y - 14, { power = 0.5 })
  Audio.play("bot_revive", { x = self.x, y = self.y })
  Signal.emit("bot:revived", self)
end

--- Ran out of time while downed, or powered down on purpose.
function Bot:expire(peaceful)
  self.alive = false
  self.state = "dead"
  if peaceful then
    VFX.emit("bot_boot", self.x, self.y, { power = 0.5 })
    Audio.play("bot_down", { pitch = 1.3, volume = 0.5, x = self.x, y = self.y })
  else
    VFX.emit("bot_death", self.x, self.y, { power = 1 })
    Audio.play("enemy_die", { pitch = 0.8, x = self.x, y = self.y })
    if self.world and self.world.decals then self.world.decals.add("scorch", self.x, self.y) end
  end
  Signal.emit("bot:lost", self, peaceful)
end

--- One line about what this bot actually did, for its death toast and for the
--- memorial. A number the player watched happen carries more than any chatter.
function Bot:epitaph()
  if (self.planted or 0) > 0 then
    return self.planted == 1 and "planted one tree" or ("planted " .. self.planted .. " trees")
  end
  if (self.built or 0) > 0 then
    return "built " .. self.built .. (self.built == 1 and " planter" or " planters")
  end
  if self.type == "repulsor" then
    local used = self.def.charges - (self.charges or 0)
    return used > 0 and ("held the line " .. used .. " times") or "never got to fire"
  end
  if self.type == "beacon" then return "kept a light on" end
  if self.type == "sentry" then return "stood watch" end
  if self.type == "harvester" then return "carried what it found" end
  return "was here"
end

------------------------------------------------------------------------- render
local function metal(t) return P.shade(P.ramp.metal, t) end

function Bot:drawShadow()
  if self.state == "dead" then return end
  Draw.softShadow(self.x, self.y + 3, self.radius * 1.05, self.radius * 0.45, 0.3)
end

function Bot:eyeColor()
  if self.state == "down" then return P.eyeDown end
  if self.mood == "love" then return P.love end
  if self.mood == "confused" then return P.warn end
  return P.eye
end

function Bot:draw()
  if self.state == "dead" or self.carried then return end
  local g = love.graphics
  local r = self.radius
  local boot = self.state == "boot" and U.saturate(1 - self.bootT / T.bootTime) or 1
  local pop = 1
  if self.squashT and self.squashT > 0 then
    self.squashT = self.squashT - love.timer.getDelta()
    pop = 1 + math.sin(U.saturate(self.squashT / 0.4) * math.pi) * 0.16
  end

  g.push()
  g.translate(self.x, self.y)
  if self.state == "down" then g.rotate(1.1 + math.sin(self.spin) * 0.06) end
  local bobY = self.static and 0 or math.sin(self.bob + self.age * 3.4) * 1.2
  g.translate(0, bobY)
  g.scale(boot * (2 - pop), boot * pop)

  local fn = self["body_" .. self.type]
  if fn then fn(self, r) else self:body_planter(r) end

  g.pop()

  if self.state == "boot" then
    Draw.ring(self.x, self.y, r * 2 * (1 - boot) + r, 2, 0, U.TAU, P.accent, 0.5)
  end
  if self.flash > 0 then
    Draw.setColor(P.white, self.flash * 0.8)
    g.circle("fill", self.x, self.y - r * 0.3, r * 1.05)
  end
  if self.state == "down" and self.reviveT and self.reviveT > 0 then
    local p = U.saturate(self.reviveT / T.beacon.reviveTime)
    Draw.ring(self.x, self.y, r * 1.8, 3, -math.pi / 2, -math.pi / 2 + p * U.TAU, P.love, 0.7)
  end
end

--- Draws the eye plate common to every chassis.
function Bot:drawEye(x, y, w, h)
  local c = self:eyeColor()
  local blinking = (self.blink % 4.6) > 4.5 and self.state ~= "down"
  Draw.setColor(P.shade(P.ramp.metal, 1.1))
  Draw.roundRect("fill", x - w * 0.5, y - h * 0.5, w, h, h * 0.4)
  if not blinking then
    local ex = U.clamp(self.eyeX, -1, 1) * w * 0.18
    local ey = U.clamp(self.eyeY, -1, 1) * h * 0.18
    Draw.setColor(c, self.state == "down" and 0.45 or 1)
    Draw.roundRect("fill", x - w * 0.26 + ex, y - h * 0.22 + ey, w * 0.52, h * 0.44, h * 0.2)
    Draw.glow(x + ex, y + ey, w * 0.7, c, self.state == "down" and 0.2 or 0.5)
  end
end

function Bot:body_planter(r)
  Draw.setColor(metal(1.5))
  Draw.roundRect("fill", -r * 0.9, r * 0.15, r * 1.8, r * 0.62, r * 0.28)   -- treads
  Draw.setColor(metal(2.4))
  Draw.roundRect("fill", -r * 0.72, -r * 0.62, r * 1.44, r * 1.0, r * 0.34) -- chassis
  Draw.setColor(P.shade(P.ramp.leaf, 2.4))
  Draw.roundRect("fill", -r * 0.4, -r * 1.05, r * 0.8, r * 0.5, r * 0.18)   -- seed hopper
  Draw.setColor(metal(3.1))
  Draw.capsule("fill", r * 0.5, -r * 0.2, r * 0.95, r * 0.35, r * 0.13)     -- planting arm
  self:drawEye(0, -r * 0.22, r * 1.0, r * 0.5)
end

function Bot:body_builder(r)
  Draw.setColor(metal(1.4))
  Draw.roundRect("fill", -r * 0.95, r * 0.2, r * 1.9, r * 0.6, r * 0.26)
  Draw.setColor(metal(2.3))
  Draw.roundRect("fill", -r * 0.8, -r * 0.85, r * 1.6, r * 1.25, r * 0.3)
  Draw.setColor(metal(3.0))
  Draw.capsule("fill", -r * 0.1, -r * 0.9, r * 0.1, -r * 1.5, r * 0.12)     -- gantry
  Draw.capsule("fill", r * 0.1, -r * 1.5, r * 0.85, -r * 1.2, r * 0.1)
  -- carried cobalt shows as little cubes
  for i = 1, math.min(self.carry, 4) do
    Draw.setColor(P.shade(P.ramp.cobalt, 3))
    Draw.roundRect("fill", -r * 0.62 + (i - 1) * r * 0.34, -r * 0.5, r * 0.26, r * 0.26, r * 0.06)
  end
  self:drawEye(0, -r * 0.08, r * 1.05, r * 0.46)
end

function Bot:body_repulsor(r)
  local pa = self.pulseAnim or 0
  if pa > 0 then self.pulseAnim = math.max(0, pa - love.timer.getDelta() * 3) end
  Draw.setColor(metal(1.6))
  for i = 0, 2 do
    local a = i * U.TAU / 3 + math.pi / 2
    Draw.capsule("fill", 0, 0, math.cos(a) * r * 1.0, math.sin(a) * r * 0.62 + r * 0.3, r * 0.15)
  end
  Draw.setColor(metal(2.5))
  Draw.roundRect("fill", -r * 0.5, -r * 0.9, r * 1.0, r * 1.1, r * 0.3)
  Draw.setColor(P.accentCool, 0.5 + pa * 0.5)
  Draw.ring(0, -r * 1.05, r * 0.62 + pa * r * 0.5, 3, 0, U.TAU, P.accentCool, 0.6 + pa * 0.4)
  -- remaining charges as pips
  for i = 1, self.def.charges do
    Draw.setColor(i <= (self.charges or 0) and P.accentCool or P.inkFaint,
                  i <= (self.charges or 0) and 0.9 or 0.25)
    love.graphics.circle("fill", -r * 0.75 + (i - 1) * (r * 1.5 / 9), r * 0.72, r * 0.07)
  end
  self:drawEye(0, -r * 0.42, r * 0.72, r * 0.36)
end

function Bot:body_sentry(r)
  local rec = (self.recoil or 0) * r * 0.35
  Draw.setColor(metal(1.5))
  for i = 0, 2 do
    local a = i * U.TAU / 3 + math.pi / 6
    Draw.capsule("fill", 0, 0, math.cos(a) * r * 0.85, math.sin(a) * r * 0.55 + r * 0.45, r * 0.13)
  end
  Draw.setColor(metal(2.4))
  love.graphics.circle("fill", 0, -r * 0.45, r * 0.6)
  local ca, sa = math.cos(self.aimAngle), math.sin(self.aimAngle)
  Draw.setColor(metal(3.0))
  Draw.capsule("fill", -ca * rec, -r * 0.45 - sa * rec,
               ca * (r * 1.15) - ca * rec, -r * 0.45 + sa * (r * 1.15) - sa * rec, r * 0.15)
  Draw.setColor(P.shade(P.ramp.leaf, 3), 0.9)
  love.graphics.circle("fill", ca * r * 1.2, -r * 0.45 + sa * r * 1.2, r * 0.12)
  self:drawEye(0, -r * 0.5, r * 0.62, r * 0.34)
end

function Bot:body_harvester(r)
  Draw.setColor(metal(1.5))
  Draw.roundRect("fill", -r * 0.95, r * 0.1, r * 1.9, r * 0.55, r * 0.24)
  Draw.setColor(metal(2.3))
  Draw.roundRect("fill", -r * 0.7, -r * 0.55, r * 1.4, r * 0.85, r * 0.26)
  Draw.setColor(metal(2.9))
  local sc = self.faceY > 0 and 1 or -1
  Draw.capsule("fill", -r * 0.55, r * 0.35 * sc, r * 0.55, r * 0.35 * sc, r * 0.14)   -- scoop
  -- cargo basket fills up visibly
  local n = math.min(self.cargo, self.def.capacity)
  for i = 1, n do
    Draw.setColor(P.shade(P.ramp.cobalt, 2.6 + (i % 2) * 0.6))
    love.graphics.circle("fill", -r * 0.4 + ((i - 1) % 3) * r * 0.4,
                         -r * 0.75 - math.floor((i - 1) / 3) * r * 0.3, r * 0.16)
  end
  self:drawEye(0, -r * 0.15, r * 0.9, r * 0.4)
end

function Bot:body_beacon(r)
  local pulse = 0.75 + math.sin((self.glowPhase or 0)) * 0.25
  Draw.setColor(metal(1.6))
  Draw.roundRect("fill", -r * 0.62, r * 0.25, r * 1.24, r * 0.5, r * 0.22)
  Draw.setColor(metal(2.2))
  Draw.capsule("fill", 0, r * 0.3, 0, -r * 1.1, r * 0.17)
  Draw.setColor(metal(2.8))
  Draw.roundRect("fill", -r * 0.42, -r * 1.72, r * 0.84, r * 0.72, r * 0.2)
  Draw.setColor(P.eye, 0.55 + pulse * 0.45)
  Draw.roundRect("fill", -r * 0.3, -r * 1.62, r * 0.6, r * 0.52, r * 0.16)
  Draw.glow(0, -r * 1.36, r * 2.6 * pulse, P.eye, 0.55)
  self:drawEye(0, -r * 0.35, r * 0.6, r * 0.3)
end

--- Drawn by the player while being carried.
function Bot:drawCarried()
  local g = love.graphics
  g.push()
  g.translate(self.x, self.y)
  g.rotate(0.5)
  g.scale(0.85)
  local fn = self["body_" .. self.type]
  if fn then fn(self, self.radius) end
  g.pop()
end

function Bot:emitLight(Lighting)
  if self.state == "dead" then return end
  if self.type == "beacon" and self.state == "work" then
    local pulse = 0.85 + math.sin((self.glowPhase or 0)) * 0.15
    Lighting.addLight(self.x, self.y - self.radius * 1.4, self.def.radius_field, P.eye,
                      1.15 * pulse, { flicker = 0.03 })
  else
    local k = self.world and self.world.chips and self.world.chips:get("botLight", 1) or 1
    Lighting.addLight(self.x, self.y - self.radius * 0.3, self.radius * 3.4 * k, self:eyeColor(),
                      (self.state == "down" and 0.18 or 0.34) * k)
  end
end

return Bot
