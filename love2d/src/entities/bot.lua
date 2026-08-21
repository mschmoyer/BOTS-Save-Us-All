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

local Text  = require("src.engine.text")
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
  self.bootT       = T.bootTime
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
-- Seconds a face keeps moving after a line is spoken. Cosmetic, not a rule:
-- it only decides how long the mouth answers the bubble that is already up.
local TALK_TIME = 1.5

function Bot:speed()
  local m = 1
  if self.world and self.world.chips then m = self.world.chips:get("botSpeed", 1) end
  return self.def.speed * m
end

function Bot:workRate()
  local m = 1
  if self.world and self.world.rallyX then
    m = m * (1 + TU.rally.workBonus * self.world:rallyPull(self.x, self.y))
  end
  if self.world and self.world.chips then m = self.world.chips:get("botWork", 1) end
  if self.world and self.world.beaconBoostAt then
    m = m * (1 + self.world:beaconBoostAt(self.x, self.y))
  end
  return m
end

function Bot:say(phase)
  if not self.world or not self.world.speak then return end
  -- how long the face keeps answering the voice, so the vocoder mouth and the
  -- eye have something to move to while the bubble is up
  self.speakT = TALK_TIME
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
  if self.speakT then self.speakT = math.max(0, self.speakT - dt) end

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
    local planted = 0
    do
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
  -- A Builder pays in what it found rather than out of the bank, so the
  -- player's own escalating price never touched it -- which made it the way
  -- around the only brake on the size of the workforce. It walks the same
  -- curve now, in carry rather than cobalt.
  local crew = (self.world and self.world.countBots and self.world:countBots(want)) or 0
  local buildCost = (self.def.buildCost or 2)
                    * math.max(1, math.ceil(wantDef.cost / T.planter.cost))
                    * (1 + math.floor(crew / 24))
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
  -- The reach telegraph runs whether or not anything is in range: knowing the
  -- footprint matters most while you are still deciding where to stand.
  self.reachT = (self.reachT or self.rng:range(0, self.def.reachEvery)) - dt
  if self.reachT <= 0 then
    self.reachT = self.def.reachEvery
    VFX.emit("repulsor_reach", self.x, self.y,
             { scale = self.def.radius_pulse / 200 })
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
-- The first pillar is "the bots are people", and for a long time the world did
-- not keep that promise: every chassis was the same grey rounded rectangle with
-- a lozenge eye, so a crew of forty read as one repeated prop. Three things fix
-- it, and all three are here: one *shape* per role, taken straight off the
-- build-bar glyph the player already learned; one hard rim so a machine has an
-- edge against grass; and the portrait's own vocabulary -- recessed eye plate,
-- antenna with a lit tip, a mouth that answers the voice -- carried down onto
-- the thirty-pixel version of the same character.
local metalRamp = P.ramp.metal
local function metal(t, a) return P.shade(metalRamp, t, a) end
-- The lit edge. `metal`'s own top stop, so the crew's rim is cool white and the
-- player's is `accentCool` blue: at a glance, across a busy frame, that one
-- difference is how you find yourself among your own machines.
local RIM = metalRamp[4]

-- Nameplates. Not balance numbers: how near you have to be before a bot tells
-- you who it is, and how large it says so, in world units.
local PLATE = {
  near = 165,     -- fully legible inside this
  fade = 105,     -- and coming up across this band outside it
  size = 7.5,     -- display-face cap height
  lift = 1.15,    -- radii of clearance above the chassis
}
local PLATE_OPTS = { align = "center", tracking = 0.05 }

function Bot:drawShadow()
  if self.state == "dead" then return end
  local r = self.radius
  local boot = self.state == "boot" and U.saturate(1 - self.bootT / T.bootTime) or 1
  Draw.softShadow(self.x, self.y + 3, r * (1.05 + (1 - boot) * 0.5), r * 0.45, 0.30)
  -- the contact patch: small, dark, and directly under the feet. Without it a
  -- bot is a sticker on the grass rather than a thing standing in it.
  Draw.softShadow(self.x, self.y + r * 0.42, r * 0.55, r * 0.20, 0.48)
end

function Bot:eyeColor()
  if self.state == "down" then return P.eyeDown end
  if self.mood == "love" then return P.love end
  if self.mood == "confused" then return P.warn end
  return P.botEye
end

--- 0..1 while it is standing up for the first time.
function Bot:bootP()
  if self.state ~= "boot" then return 1 end
  return U.saturate(1 - self.bootT / T.bootTime)
end

function Bot:draw()
  if self.state == "dead" or self.carried then return end
  local g = love.graphics
  local r = self.radius
  local boot = self:bootP()
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
  if boot < 1 then
    -- Standing up. It arrives folded flat against the ground -- squat, wide,
    -- tipped over -- and unfolds, overshooting a little as it locks out. The
    -- transform pivots on y = 0, which is the ground, so it genuinely rises
    -- out of the island instead of growing out of thin air.
    local sm = boot * boot * (3 - 2 * boot)
    local over = math.sin(sm * math.pi) * 0.13
    g.scale((1 + (1 - sm) * 0.6) * (1 - over), math.max(0.05, sm) * (1 + over))
    g.rotate((1 - sm) * 0.24 * ((self.serial % 2 == 0) and 1 or -1))
  else
    g.scale(2 - pop, pop)
  end

  local fn = self["body_" .. self.type]
  if fn then fn(self, r) else self:body_planter(r) end

  g.pop()

  if self.state == "boot" then
    Draw.ring(self.x, self.y, r * 2 * (1 - boot) + r, 2, 0, U.TAU, P.accent, 0.5)
    Draw.glow(self.x, self.y, r * 2.2 * (1 - boot) + r * 0.6, P.accent, 0.35 * (1 - boot), 2)
  end
  if self.flash > 0 then
    Draw.setColor(P.white, self.flash * 0.8)
    g.circle("fill", self.x, self.y - r * 0.3, r * 1.05)
  end
  if self.state == "down" and self.reviveT and self.reviveT > 0 then
    local p = U.saturate(self.reviveT / T.beacon.reviveTime)
    Draw.ring(self.x, self.y, r * 1.8, 3, -math.pi / 2, -math.pi / 2 + p * U.TAU, P.love, 0.7)
  end
  self:drawName()
end

--- The antenna every one of them wears. It is the single detail that makes the
--- dialogue portraits read as little people rather than as appliances, and it
--- costs four primitives to put the same thing on the thirty-pixel version.
function Bot:drawAntenna(x, y, len, r)
  local sway = math.sin(self.age * 1.15 + self.bob) * len * 0.22
  Draw.setColor(metal(2.6))
  Draw.capsule("fill", x, y, x + sway, y - len, r * 0.055)
  local c = self:eyeColor()
  Draw.setColor(c, 0.95)
  love.graphics.circle("fill", x + sway, y - len, r * 0.13)
  Draw.glow(x + sway, y - len, r * 0.7, c, 0.3, 2)
end

--- The eye plate: a dark recess, a lit eye that looks where the bot is looking,
--- and -- while it is talking -- the three-bar vocoder mouth off the portrait.
function Bot:drawEye(x, y, w, h)
  local c = self:eyeColor()
  local down = self.state == "down"
  Draw.setColor(metal(1.0))
  Draw.roundRect("fill", x - w * 0.5, y - h * 0.5, w, h, h * 0.42)
  Draw.setColor(RIM, 0.30)
  Draw.capsule("fill", x - w * 0.32, y - h * 0.44, x + w * 0.32, y - h * 0.44, h * 0.055)

  local a = 1
  local boot = self:bootP()
  if boot < 1 then
    -- the eye comes on last, and it stutters getting there
    if boot < 0.45 then return end
    a = (math.floor(boot * 40) % 2 == 0) and 1 or 0.2
  elseif (self.blink % 4.6) > 4.5 and not down then
    return
  end

  local speak = U.saturate((self.speakT or 0) / TALK_TIME)
  local ex = U.clamp(self.eyeX, -1, 1) * w * 0.19
  local ey = U.clamp(self.eyeY, -1, 1) * h * 0.19
  local ew = w * 0.56 * (1 + speak * 0.12)
  Draw.setColor(c, (down and 0.45 or 1) * a)
  Draw.roundRect("fill", x - ew * 0.5 + ex, y - h * 0.24 + ey, ew, h * 0.48, h * 0.22)
  -- wide and soft rather than small and hot: the scene is multiplied by the
  -- light buffer, so a tight core simply goes out after dusk, while a halo this
  -- size still carries the colour once the sun is off the island
  Draw.glow(x + ex, y + ey, w * (1.5 + speak * 0.5), c,
            (down and 0.20 or (0.32 + speak * 0.24)) * a)

  if speak > 0.02 and not down then
    for i = -1, 1 do
      local bh = h * (0.16 + math.abs(math.sin(self.age * 17 + i * 1.9)) * 0.4 * speak)
      Draw.setColor(c, 0.3 + speak * 0.5)
      Draw.roundRect("fill", x + i * w * 0.17 - w * 0.045, y + h * 0.66 - bh * 0.5,
                     w * 0.09, bh, w * 0.045)
    end
  end
end

--- How full it is, for the two bots that carry anything.
function Bot:load()
  if self.type == "harvester" then return self.cargo or 0, self.def.capacity or 0 end
  if self.type == "builder"   then return self.carry or 0, self.def.carryMax or 0 end
  return 0, 0
end

--- The carrying tell. A pip row that fills, and -- the part that actually reads
--- at play scale -- a cobalt glow on the machine itself, so "that one is
--- bringing something home" is answerable from across the clearing.
function Bot:drawLoad(r, y, w)
  local n, cap = self:load()
  if cap <= 0 then return end
  local hot = P.shade(P.ramp.cobalt, 3.4)
  for i = 1, cap do
    local lit = i <= n
    local px = -w * 0.5 + (i - 0.5) * (w / cap)
    Draw.setColor(lit and hot or metal(1.2), lit and 1 or 0.5)
    Draw.diamond(px, y, r * 0.085, r * 0.12, "fill")
  end
  if n > 0 then
    Draw.glow(0, y, r * (0.8 + 0.7 * n / cap), hot, 0.30 + 0.35 * n / cap, 2)
  end
end

--- Who this is. The whole game is a bet that you will care which of them came
--- back, and until now their names only existed in a toast and on a memorial.
--- Anything near you introduces itself; anything on the ground says its name
--- whether you are near or not, because that is the one you have to decide
--- about. Suppressed while it is talking so the bubble owns that space.
function Bot:drawName()
  if self.state == "boot" or (self.speakT or 0) > 0 then return end
  local a
  if self.state == "down" then
    a = 0.95
  else
    local p = self.world and self.world.player
    if not p then return end
    local d = U.dist(self.x, self.y, p.x, p.y)
    a = U.saturate((PLATE.near + PLATE.fade - d) / PLATE.fade) * 0.78
  end
  if a < 0.03 then return end

  local size = PLATE.size
  local y = self.y - self.radius * (1.6 + PLATE.lift) - size
  local tw = Text.width(self.name, size, PLATE_OPTS)
  Draw.setColor(P.black, 0.45 * a)
  Draw.roundRect("fill", self.x - tw * 0.5 - 3.5, y - 2.5, tw + 7, size + 5.5, (size + 5.5) * 0.5)
  PLATE_OPTS.color = self.state == "down" and P.eyeDown or P.inkDim
  PLATE_OPTS.alpha = a
  Text.display(self.name, self.x, y, size, PLATE_OPTS)
end

------------------------------------------------------------------ the six shapes
-- Short-and-boxy, tall-with-a-jib, triangle, diamond, wide-on-wheels, thin lamp.
-- Six classes of outline: you can name any of them from the shape alone.

function Bot:body_planter(r)
  Draw.setColor(metal(1.4))
  Draw.roundRect("fill", -r * 0.92, r * 0.10, r * 1.84, r * 0.64, r * 0.28)   -- treads
  Draw.setColor(metal(1.0))
  for i = -1, 1 do
    Draw.roundRect("fill", i * r * 0.48 - r * 0.06, r * 0.16, r * 0.12, r * 0.52, r * 0.05)
  end
  Draw.setColor(metal(2.4))
  Draw.roundRect("fill", -r * 0.70, -r * 0.66, r * 1.40, r * 1.00, r * 0.32)  -- chassis
  Draw.setColor(RIM, 0.55)
  Draw.capsule("fill", -r * 0.44, -r * 0.60, r * 0.44, -r * 0.60, r * 0.07)
  -- the seedling it is carrying, swaying: a stalk and two leaves. Nothing else
  -- on the island has a plant growing out of its head.
  local sway = math.sin(self.age * 1.6 + self.bob) * r * 0.11
  -- dark stalk, bright leaves: a Planter is very often standing under a canopy,
  -- and a mid-green sprout against mid-green foliage is no sprout at all
  Draw.setColor(P.shade(P.ramp.leaf, 1.2))
  Draw.capsule("fill", 0, -r * 0.62, sway, -r * 1.30, r * 0.09)
  Draw.setColor(P.shade(P.ramp.leaf, 1.2))
  Draw.blob(sway - r * 0.28, -r * 1.24, r * 0.30, 7, 3, 0.2, 0.62)
  Draw.blob(sway + r * 0.27, -r * 1.40, r * 0.27, 7, 8, 0.2, 0.62)
  Draw.setColor(P.shade(P.ramp.leafHi, 4))
  Draw.blob(sway - r * 0.28, -r * 1.25, r * 0.24, 7, 3, 0.2, 0.60)
  Draw.blob(sway + r * 0.27, -r * 1.41, r * 0.21, 7, 8, 0.2, 0.60)
  self:drawAntenna(-r * 0.60, -r * 0.56, r * 0.60, r)
  self:drawEye(0, -r * 0.20, r * 0.98, r * 0.50)
end

function Bot:body_builder(r)
  Draw.setColor(metal(1.3))
  Draw.roundRect("fill", -r * 0.96, r * 0.16, r * 1.92, r * 0.62, r * 0.26)
  Draw.setColor(metal(2.2))
  Draw.roundRect("fill", -r * 0.76, -r * 0.84, r * 1.52, r * 1.18, r * 0.26)
  Draw.setColor(RIM, 0.5)
  Draw.capsule("fill", -r * 0.50, -r * 0.78, r * 0.50, -r * 0.78, r * 0.07)
  -- the jib: mast, boom, and a block swinging on a line. The only thing in the
  -- crew that reaches out sideways, and the tallest outline of the six.
  Draw.setColor(metal(3.0))
  Draw.capsule("fill", -r * 0.18, -r * 0.82, -r * 0.18, -r * 1.84, r * 0.105)
  Draw.capsule("fill", -r * 0.24, -r * 1.78, r * 0.96, -r * 1.50, r * 0.09)
  local hang = r * (0.40 + math.sin(self.age * 1.5 + self.bob) * 0.12)
  Draw.setColor(metal(2.0))
  Draw.capsule("fill", r * 0.92, -r * 1.48, r * 0.92, -r * 1.48 + hang, r * 0.035)
  Draw.setColor(P.shade(P.ramp.cobalt, 3))
  Draw.diamond(r * 0.92, -r * 1.48 + hang + r * 0.17, r * 0.15, r * 0.20, "fill")
  self:drawLoad(r, r * 0.02, r * 1.02)
  self:drawAntenna(-r * 0.62, -r * 0.76, r * 0.54, r)
  self:drawEye(0, -r * 0.36, r * 1.02, r * 0.46)
end

function Bot:body_repulsor(r)
  local pa = self.pulseAnim or 0
  if pa > 0 then self.pulseAnim = math.max(0, pa - love.timer.getDelta() * 3) end
  -- three splayed feet and a body that tapers to a point. The build-bar glyph
  -- is a triangle under a ring, and a triangle is a shape no other bot makes.
  Draw.setColor(metal(1.4))
  for i = 0, 2 do
    local a = i * U.TAU / 3 + math.pi / 2
    Draw.capsule("fill", math.cos(a) * r * 0.20, -r * 0.30,
                 math.cos(a) * r * 1.00, math.sin(a) * r * 0.52 + r * 0.40, r * 0.14)
  end
  Draw.setColor(metal(2.3))
  love.graphics.polygon("fill", 0, -r * 1.02, r * 0.86, r * 0.34, -r * 0.86, r * 0.34)
  Draw.setColor(RIM, 0.5)
  Draw.capsule("fill", -r * 0.04, -r * 0.96, -r * 0.74, r * 0.26, r * 0.065)
  -- The emitter, which is the whole point of it. The glow behind it used to run
  -- to three quarters alpha over a disc two and a half times the pylon's own
  -- radius: at night it was a ball of light with the machine invisible inside
  -- it, and now that a Repulsor also lights the ground it covers and paints its
  -- own reach, the emitter does not have to shout as well. The ring is the
  -- reading; the glow is the hint under it.
  Draw.ring(0, -r * 1.12, r * 0.46 + pa * r * 0.6, r * 0.13, 0, U.TAU,
            P.alpha(P.accentCool, 0.6 + pa * 0.4), 0.4)
  Draw.glow(0, -r * 1.12, r * (0.78 + pa * 1.1), P.accentCool, 0.13 + pa * 0.26, 2)
  -- charges left, as pips along the base
  local n = self.def.charges
  for i = 1, n do
    local lit = i <= (self.charges or 0)
    Draw.setColor(lit and P.accentCool or P.inkFaint, lit and 0.9 or 0.25)
    love.graphics.circle("fill", -r * 0.5 + (i - 1) * (r / math.max(1, n - 1)), r * 0.5, r * 0.08)
  end
  self:drawAntenna(-r * 0.40, -r * 0.34, r * 0.52, r)
  self:drawEye(0, r * 0.06, r * 0.92, r * 0.34)
end

function Bot:body_sentry(r)
  local rec = (self.recoil or 0) * r * 0.35
  Draw.setColor(metal(1.5))
  for i = 0, 2 do
    local a = i * U.TAU / 3 + math.pi / 6
    Draw.capsule("fill", 0, -r * 0.10,
                 math.cos(a) * r * 0.86, math.sin(a) * r * 0.56 + r * 0.48, r * 0.13)
  end
  -- a diamond head, exactly the glyph on the build bar
  Draw.setColor(metal(2.4))
  Draw.diamond(0, -r * 0.56, r * 0.74, r * 0.92, "fill")
  Draw.setColor(RIM, 0.55)
  love.graphics.setLineWidth(r * 0.11)
  love.graphics.line(-r * 0.72, -r * 0.54, 0, -r * 1.46)
  love.graphics.setLineWidth(1)
  local ca, sa = math.cos(self.aimAngle), math.sin(self.aimAngle)
  Draw.setColor(metal(3.0))
  Draw.capsule("fill", -ca * rec, -r * 0.56 - sa * rec,
               ca * r * 1.30 - ca * rec, -r * 0.56 + sa * r * 1.30 - sa * rec, r * 0.15)
  Draw.setColor(P.shade(P.ramp.leaf, 3.2), 0.95)
  love.graphics.circle("fill", ca * r * 1.36, -r * 0.56 + sa * r * 1.36, r * 0.14)
  Draw.glow(ca * r * 1.36, -r * 0.56 + sa * r * 1.36, r * 0.75, P.shade(P.ramp.leaf, 3.6), 0.3, 2)
  self:drawAntenna(r * 0.26, -r * 1.14, r * 0.48, r)
  self:drawEye(0, -r * 0.56, r * 0.70, r * 0.34)
end

function Bot:body_harvester(r)
  -- the only round feet in the crew, and they turn while it works
  local roll = self.age * 3.2 + self.bob
  for i = -1, 1, 2 do
    local wx = i * r * 0.68
    Draw.setColor(metal(1.1))
    love.graphics.circle("fill", wx, r * 0.42, r * 0.40)
    Draw.setColor(metal(2.6), 0.9)
    love.graphics.setLineWidth(r * 0.09)
    love.graphics.circle("line", wx, r * 0.42, r * 0.30)
    love.graphics.setLineWidth(1)
    Draw.setColor(metal(2.8))
    love.graphics.circle("fill", wx, r * 0.42, r * 0.13)
    Draw.setColor(metal(3.2), 0.8)
    Draw.capsule("fill", wx - math.cos(roll) * r * 0.29, r * 0.42 - math.sin(roll) * r * 0.29,
                 wx + math.cos(roll) * r * 0.29, r * 0.42 + math.sin(roll) * r * 0.29, r * 0.045)
  end
  -- a low, wide hull: the flattest outline of the six
  Draw.setColor(metal(2.3))
  Draw.roundRect("fill", -r * 1.02, -r * 0.54, r * 2.04, r * 0.94, r * 0.24)
  Draw.setColor(RIM, 0.55)
  Draw.capsule("fill", -r * 0.78, -r * 0.48, r * 0.78, -r * 0.48, r * 0.07)
  -- scoop, always on the leading edge
  local sc = self.faceY > 0 and 1 or -1
  Draw.setColor(metal(2.9))
  Draw.capsule("fill", -r * 0.72, r * 0.34 * sc, r * 0.72, r * 0.34 * sc, r * 0.13)
  -- what it has actually picked up, in a basket on the roof
  local n = math.min(self.cargo or 0, self.def.capacity)
  for i = 1, n do
    Draw.setColor(P.shade(P.ramp.cobalt, 2.6 + (i % 2) * 0.6))
    love.graphics.circle("fill", -r * 0.42 + ((i - 1) % 3) * r * 0.42,
                         -r * 0.76 - math.floor((i - 1) / 3) * r * 0.30, r * 0.16)
  end
  self:drawLoad(r, r * 0.12, r * 1.30)
  self:drawAntenna(-r * 0.86, -r * 0.48, r * 0.56, r)
  self:drawEye(0, -r * 0.16, r * 0.90, r * 0.40)
end

function Bot:body_beacon(r)
  local pulse = 0.75 + math.sin(self.glowPhase or 0) * 0.25
  -- splayed struts under a mast: thin and tall, the opposite outline to the
  -- Harvester, and the same A-frame the build-bar glyph draws
  Draw.setColor(metal(1.4))
  for i = -1, 1, 2 do
    Draw.capsule("fill", i * r * 0.10, -r * 0.50, i * r * 0.60, r * 0.48, r * 0.11)
  end
  Draw.setColor(metal(1.8))
  Draw.capsule("fill", 0, r * 0.36, 0, -r * 1.26, r * 0.15)
  -- the lantern. Deliberately still `eye`, the warm amber: it is a lamp, and a
  -- lamp is the one thing in the crew that has earned the right to be warm.
  Draw.setColor(metal(2.7))
  Draw.roundRect("fill", -r * 0.42, -r * 2.00, r * 0.84, r * 0.28, r * 0.12)
  Draw.setColor(P.eye, 0.55 + pulse * 0.45)
  Draw.roundRect("fill", -r * 0.32, -r * 1.80, r * 0.64, r * 0.60, r * 0.18)
  Draw.setColor(metal(2.7))
  Draw.roundRect("fill", -r * 0.42, -r * 1.24, r * 0.84, r * 0.22, r * 0.09)
  Draw.setColor(RIM, 0.5)
  Draw.capsule("fill", -r * 0.34, -r * 1.94, r * 0.34, -r * 1.94, r * 0.06)
  Draw.glow(0, -r * 1.50, r * 2.9 * pulse, P.eye, 0.55)
  self:drawAntenna(-r * 0.36, -r * 1.92, r * 0.46, r)
  self:drawEye(0, -r * 0.58, r * 0.58, r * 0.30)
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
    -- A Beacon is a lamp you planted, so it burns in the player's own yellow
    -- rather than the crew's blue: standing inside one should feel like
    -- standing inside your own light.
    local pulse = 0.85 + math.sin((self.glowPhase or 0)) * 0.15
    Lighting.addLight(self.x, self.y - self.radius * 1.4, self.def.radius_field, P.lightPlayer,
                      1.15 * pulse, { flicker = 0.03 })
  else
    -- A bot's eye is drawn into the scene, and the scene is multiplied by this
    -- very buffer -- so after dusk the *only* thing that keeps a machine's face
    -- lit is the light it puts back. It used to put back barely any, and a night
    -- crew of thirty read as thirty grey lumps. Now they read as what they are:
    -- your lights, spread across the dark, each one somebody.
    -- Blue, always, whatever the eye is doing. A downed bot's eye goes red and
    -- a smitten one goes pink, and if the *light* followed the eye then the two
    -- states that most need reading as "one of ours, in trouble" would light
    -- the ground in the enemy's colour. Mood belongs on the face; the lamp is
    -- the crew's colour and nothing rotates it.
    local k = self.world and self.world.chips and self.world.chips:get("botLight", 1) or 1
    if self.type == "repulsor" and self.state == "work" then
      -- A Repulsor is a pylon holding a charge. It lights the ground it covers
      -- so you can see the mine you placed, and breathes so you can see it is
      -- still armed.
      local br = 0.82 + 0.18 * math.sin(self.age * 2.4)
      Lighting.addLight(self.x, self.y - self.radius * 0.4, self.def.lightRadius * k,
                        P.lightFriend, self.def.lightGain * br * k, { flicker = 0.04 })
      return
    end
    Lighting.addLight(self.x, self.y - self.radius * 0.35, self.radius * 4.8 * k, P.lightFriend,
                      (self.state == "down" and 0.26 or 0.48) * k, { flicker = 0.03 })
  end
end

return Bot
