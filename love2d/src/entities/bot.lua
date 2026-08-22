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
--- Serials count for the life of the process, not the life of a run. `seed` is
--- a { [type] = highest serial issued } table, which is what a RESTORE has to
--- hand back: rebuilding the crew from a save restarts this counter at the
--- number of bots that came back rather than at the highest number ever issued,
--- so a newly built machine could take a dead one's name. It has been observed
--- -- two FRAME-04s, one memorial row -- and a name is the only thing the
--- memorial has, so two machines must never share one.
function Bot.resetSerials(seed) serials = seed or {} end

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

  -- THE LEDGER. `planted` and `built` above are the two numbers this game has
  -- always kept, and world.lua, hud.lua, save.lua and the memorial all read
  -- them by those names, so they stay -- mirrored out of here rather than
  -- migrated. Everything else is new, and it exists so that `Bot:epitaph` can
  -- say something TRUE about this machine and not about its model number.
  --
  -- `nights` is the important one. It is the only field that makes a machine
  -- old, and old is the only thing a player can read off a crowd at a glance.
  -- world.lua counts it on `phase:dawn`, over everything still standing.
  self.log = {
    planted = 0, built = 0,
    nights  = 0,        -- dawns it has seen
    downs   = 0,        -- times it hit the ground
    saves   = 0,        -- ...and times somebody came and got it
    carried = 0,        -- ...of which, times the PLAYER walked out and got it
    mined   = 0,        -- cobalt chunks carried home
    shots   = 0,        -- darts fired, or shockwaves spent
    lit     = 0,        -- machines brought back at this Beacon
    walked  = 0,        -- world pixels under its own tracks
    bornCycle = (world and world.cycle) or 1,
  }
  self:refreshWear()

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
  -- Somebody it was standing near went down. It is walking to the body instead
  -- of working, and it is not working as fast while it does.
  if (self.grief or 0) > 0 then m = m * T.grief.workMul end
  return m
end

--- Which of the two long chatter pools the world is in.
---
--- The same rule as story.lua's `phasePool()`, and it exists because this file
--- had the bug twice: a Planter said a DAYLIGHT line every sixth tree it
--- planted, all night long, and a Repulsor said one as it burned out. Dusk
--- counts as night here for the same reason it does over there -- the light has
--- gone and "more sun today" has not been true for a while.
--- And a third time: `extraction` is not night, so it fell through to the
--- daylight pool and the crew said "the ground is wet here" with the Harvester
--- Prime standing on the forest. `Bot:update` only redirected machines still in
--- `work` and still `confused`, which a rebelling one is not.
function Bot:phasePool()
  local ph = self.world and self.world.phase
  if ph == "extraction" then return "boss" end
  return (ph == "night" or ph == "dusk") and "night" or "day"
end

--- Recompute the one integer that decides how this machine is drawn.
---
--- See `T.bots.wear`: nights survived and the speech trait both feed a single
--- quantised shade level, because the hulls are baked per (type, shade) and a
--- continuous value would mean a tessellation per bot. Called at build, at
--- every dawn, and after a restore -- never per frame.
local function iround(x)
  return x >= 0 and math.floor(x + 0.5) or -math.floor(-x + 0.5)
end

function Bot:refreshWear()
  local W = T.wear
  local L = self.log
  local nights = L and L.nights or 0
  local patina = iround(U.saturate(nights / W.fullNights) * W.levels)
  -- names.lua hands every trait a `tint`; a quiet machine is dimmer than a
  -- watcher. This is the field that has been sitting there unread.
  local q = iround(((self.trait and self.trait.tint) or 0) * W.tintScale)
  self.shadeK = U.clamp(W.neutral + patina - q, 0, W.shades - 1)
  self.ticks  = (nights >= W.tickFrom) and math.min(nights, W.tickMax) or 0
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
      local lamp = self.world and self.world.beaconAt and self.world:beaconAt(self.x, self.y)
      if lamp then
        self.reviveT = (self.reviveT or 0) + dt
        if self.reviveT >= T.beacon.reviveTime then
          -- credited to the lamp, so a Beacon's epitaph is a number nobody
          -- else can have rather than "kept a light on" for the fifth time
          if lamp.log then lamp.log.lit = lamp.log.lit + 1 end
          self:revive(lamp)
        end
      else
        self.reviveT = 0
      end
    end
    if self.downT <= 0 then self:expire() end
    return
  end

  if self.state == "rebel" then self:updateRebel(dt) return end

  -- Somebody it was standing near went down. For about fourteen seconds it
  -- walks to the body and works at half rate; `workRate` and `pickWander` read
  -- the timer. The player watches the crew stop and go over, which is the whole
  -- of a loss told in movement.
  if (self.grief or 0) > 0 then
    self.grief = self.grief - dt
    if self.griefX then
      self:lookAt(self.griefX, self.griefY)
      if self.grief <= 0 then self.griefX = nil end
    end
  end
  if (self.loyalT or 0) > 0 then self.loyalT = self.loyalT - dt end

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
    local phase = self:phasePool()
    if (self.grief or 0) > 0 and self.rng:chance(T.grief.chatter) then phase = "loss" end
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
  local px, py = self.x, self.y
  self:integrate(dt, 0)
  self:constrain(self.world and self.world.terrain, 0)
  -- the odometer. Every step this machine ever took, for the one epitaph that
  -- belongs to a machine that did nothing but walk.
  self.log.walked = self.log.walked + U.dist(px, py, self.x, self.y)
  self:setFacing(dx, dy)
  self:lookAt(tx, ty)
  return false
end

function Bot:pickWander(minSoil)
  local w = self.world
  -- It grieves before it works. Whatever it was doing, the next place it wants
  -- to be is where the body is.
  if (self.grief or 0) > 0 and self.griefX then
    local a, d = self.rng:angle(), self.rng:range(0, T.grief.arrive)
    self.wx, self.wy = self.griefX + math.cos(a) * d, self.griefY + math.sin(a) * d
    return
  end
  -- You walked out into the dark and carried this one home. For about a cycle
  -- it works where it can see you, and not where the flag is.
  if (self.loyalT or 0) > 0 and w and w.player and self.rng:chance(T.loyal.pull) then
    local a, d = self.rng:angle(), self.rng:range(0, T.loyal.radius)
    local rx, ry = w.player.x + math.cos(a) * d, w.player.y + math.sin(a) * d
    if w.terrain and w.terrain.nearestLand then
      local lx, ly = w.terrain:nearestLand(rx, ry)
      if lx then rx, ry = lx, ly end
    end
    self.wx, self.wy = rx, ry
    return
  end
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
        self.log.planted = self.log.planted + 1
      end
    end
    self.actionT = self.def.plantEvery * (planted > 0 and 1 or 0.35)
    if planted > 0 then
      self.squashT = 0.3
      if self.rng:chance(0.16) then self:say(self:phasePool()) end
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
  --
  -- ...off the PEAK crew of that type, for the same reason `World:botCost`
  -- does: read off the standing crew, a death made the next machine of that
  -- type CHEAPER, and the one brake on the size of the workforce loosened
  -- exactly when the workforce was being wiped out. `world.peakBots` is the
  -- remembered crew and it fades back toward the standing one on its own
  -- (World:updatePeakBots), so this forgets a bad night on the same clock the
  -- player's own prices do. It does not apply `costForgiveness`: this is an
  -- integer step at 24 and again at 48 against a cap of 48, so it is two
  -- values, and blending a fraction into it would buy nothing but a second
  -- copy of a rule that lives in world.lua.
  local w = self.world
  local crew = (w and w.countBots and w:countBots(want)) or 0
  local peak = w and w.peakBots and w.peakBots[want]
  if peak and peak > crew then crew = peak end
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
      self.log.built = self.log.built + 1
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
    self.log.shots = self.log.shots + 1
    self.pulseAnim = 1
    if self.world then
      self.world:areaShove(self.x, self.y, self.def.radius_pulse, self.def.force,
                           self.def.damage or 0, self.def.stun)
    end
    VFX.emit("pulse_ring", self.x, self.y, { scale = self.def.radius_pulse / 200, color = P.accentCool })
    Audio.play("pulse_release", { pitch = 1.25, volume = 0.6, x = self.x, y = self.y })
    J.shake(0.08)
    if self.charges <= 0 then
      self:say(self:phasePool())
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
      self.log.shots = self.log.shots + 1
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
      self.log.mined = self.log.mined + self.cargo
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
    -- On the hull, not inside it, and thrown back the way it came: the blast is
    -- emitted a body-length short of the plate with the outward normal, so the
    -- jet and the brass spray off the rig instead of ballooning out of its
    -- middle. `bot_death` used to do this job at 1.2 power -- the same generic
    -- puff a wreck makes burning out alone in a field.
    local bx, by = t.x - dx * (t.radius - 4), t.y - dy * (t.radius - 4)
    VFX.emit("bot_detonate", bx, by, { dx = -dx, dy = -dy, power = 1 })
    VFX.emit("love_heart", bx, by - 12, { power = 1.2 })
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
  -- It is on the ground, and it will wear that. See `Bot:drawWear`: one cut
  -- across the plating per time it went down, from a small baked library so
  -- two machines with the same count still do not match.
  self.log.downs = self.log.downs + 1
  self.downT = T.downedTime * (self.world and self.world.chips and self.world.chips:get("downedTime", 1) or 1)
  -- what the window started at, so the HUD's rescue ring can read as a fraction
  -- rather than pretending every bot has the same twenty seconds a chip may
  -- have just extended
  self.downMax = self.downT
  self.reviveT = 0
  self.vx, self.vy = 0, 0
  Audio.play("bot_down", { x = self.x, y = self.y })
  -- The worst thing that happens to you on a bad night used to be four sparks.
  -- It buckles now -- see `bot_felled` -- and the plating it sheds lies beside
  -- the body for the whole of the rescue window.
  VFX.emit("bot_felled", self.x, self.y, { power = 1 })
  J.shake(0.12)
  Signal.emit("bot:downed", self)
end

--- Somebody came and got it. `by` is "player" when it was carried home in the
--- player's own hands, "rig" when the extraction simply stands the whole crew
--- up (which nobody did for it, so it is not a rescue), the Beacon instance
--- when a lamp did it, and nil for a chip that dragged it to a light.
function Bot:revive(by)
  self.state = "work"
  self.hp = math.max(1, math.floor(self.maxHp * 0.6))
  self.stateT = 0
  self.carried = false
  self.reviveT = 0
  -- Being saved used to be a puff, a chime and a toast, after which the machine
  -- behaved identically forever. It is an event in its life now: it is on the
  -- ledger, it is the rarest epitaph in the game, and for about a cycle the bot
  -- works where it can see whoever fetched it.
  if by ~= "rig" then self.log.saves = self.log.saves + 1 end
  self.savedBy = by
  if by == "player" then
    self.log.carried = (self.log.carried or 0) + 1
    self.loyalT = T.loyal.time
    self.wx, self.wy = self.x, self.y
  end
  self.grief, self.griefX = 0, nil
  VFX.emit("bot_boot", self.x, self.y, { power = 1.2 })
  VFX.emit("love_heart", self.x, self.y - 14, { power = 0.5 })
  Audio.play("bot_revive", { x = self.x, y = self.y })
  -- names.lua has a `saved` pool for exactly this: said by the one that stood
  -- back up, not by a bystander. Not during the finale, where forty machines
  -- get up at once and the cutscene owns the room.
  if by ~= "rig" then self:say("saved") end
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

--- THE MEMORIAL'S ONE NUMBER RULE: words under twenty, digits at twenty and up.
---
--- What was here before was a rule nobody could see. Small counts were spelled,
--- but counts that were "the POINT of the line" -- trees, darts, cobalt -- were
--- left in digits, so one screen of the memorial read `built 1 planter` /
--- `fired one dart` / `fired 34 darts` / `stood through seven nights` and what
--- a reader perceived was not a convention, it was a game that could not decide.
--- One threshold, every branch, no exceptions: `built one planter` is the row
--- this fixes, and `carried 350 cobalt home` is why the threshold is low.
local ONES = { "one", "two", "three", "four", "five", "six", "seven", "eight",
               "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
               "fifteen", "sixteen", "seventeen", "eighteen", "nineteen" }
local function num(n)
  n = math.floor(n)
  if n <= 0 then return "no" end
  if n < 20 then return ONES[n] end
  return tostring(n)
end

--- ...and the same rule, for anything outside this file that prints a count
--- into the same page. scenes/ending.lua needs it for the rows it has to
--- rebuild from a save, where the machine and its ledger are both gone.
Bot.count = num

local function times(n)
  if n == 1 then return "once" end
  if n == 2 then return "twice" end
  return num(n) .. " times"
end

-- Cycles are days, and the run is seven of them.
local ORD = { "first", "second", "third", "fourth", "fifth", "sixth", "seventh",
              "eighth", "ninth", "tenth" }

--- The one machine the player has a relationship with: the one they heard boot
--- and speak, which the director keeps a reference to. Read out of the loaded
--- module rather than required, so a bot does not take a dependency on the
--- director for the sake of one line -- and so a demo scene with no director
--- simply gets `false`. `self.isFirstBot` wins if anything ever sets it.
local function isTheFirstOne(self)
  if self.isFirstBot then return true end
  local Story = package.loaded["src.game.story"]
  return (Story ~= nil and Story.theFirstOne == self) or false
end

--- EVERY TRUE THING THIS MACHINE'S LEDGER CAN SAY, RANKED.
---
--- `Bot:epitaph` used to be a ladder of `return`s: the first true fact won and
--- the rest of the ledger was thrown away. That is why the memorial read as a
--- table -- forty-two machines, six or seven surviving sentences, and the
--- commonest of them on more than half the page. The ladder is now a LIST. The
--- head of it is still the one fact this machine is described by, and
--- `Bot:epitaph` still returns exactly that; what is new is that the rest of
--- the list survives the call, so scenes/ending.lua can give a row a second
--- clause and can choose that clause against the whole page instead of against
--- this one machine. See `S:composeMemorial`.
---
--- Each entry is `{ key, text, subject }`:
---   `text`    the clause, no full stop, lowercase, third person unless it says
---             otherwise. It is printed bare as the head of a row.
---   `subject` the clause supplies its own subject ("you went out and got it").
---             Without it the clause is a bare predicate and takes "it" when it
---             is used as a row's second sentence.
---   `key`     what KIND of fact it is. Two rows carrying the same key read as
---             the same sentence however different their numbers are, which is
---             the thing the page composer is counting.
---
--- The order is the ranking, and it is: what it made, then what it cost you,
--- then what it endured, then what it was. Three notes on it.
---
--- THE WORK LEADS. It led before and it still does; a work count is a large
--- varying integer and is nearly always unique on the page, where age is only
--- distinguishing for a machine that did nothing else.
---
--- `saves` IS DEMOTED BELOW THE WORK. Beacon revives are free, constant and
--- automatic, so `saves` inflates to six and eight on anything that lived a
--- while, and while it outranked the work a Planter that put thirty trees in
--- the ground was described by how often the lamp restarted it. It is a
--- hit-points readout in the shape of a rescue. It is worth saying; it is not
--- worth saying first, and it is no longer said with the number as its subject.
---
--- "never went down" IS ABOUT `downs`, NOT `saves`, AND IT IS NOT FREE.
--- `onDeath` counts the fall that killed it, so `downs == 0` can only be true
--- of a machine that died without ever hitting the ground -- in practice one
--- that walked into the rig during the rebellion. Gated on nights as well,
--- because a machine built ninety seconds before the end also never went down
--- and there is nothing in that worth printing.
function Bot:epitaphClauses()
  local L = self.log
  local out = {}
  local function add(key, text, subject, alt)
    out[#out + 1] = { key = key, text = text, subject = subject or nil, alt = alt or nil }
  end
  if not L then
    -- a bot from before the ledger, or a stub in a demo scene
    local n = self.planted or 0
    if n > 0 then add("planted", "planted " .. num(n) .. (n == 1 and " tree" or " trees")) end
    if #out == 0 then
      local s = math.max(1, math.floor(self.age or 0))
      add("lasted", "lasted " .. num(s) .. (s == 1 and " second" or " seconds"))
    end
    return out
  end
  local E = T.epitaph
  local cycle = (self.world and self.world.cycle) or 1

  -- 0. The only individual in the game. It has its own cutscene when it is
  --    built and its own cutscene when it goes, and the memorial used to
  --    describe it exactly the way it describes the thirtieth Planter.
  if isTheFirstOne(self) then add("first", "was the first one to say anything") end

  -- 1. What it made. The one thing on this list that is entirely its own.
  if L.planted > 0 then
    -- TWO WORDINGS OF THE ONE FACT, and only this fact has them. Most of a crew
    -- are Planters and most of a memorial is therefore Planters: on a traced
    -- run thirty-four of fifty-two rows opened with the same word, and a column
    -- of "planted" down the middle of the page is the last thing left of the
    -- mail merge even when no two rows say the same thing. The page alternates
    -- between these by whichever it has printed less (see `phrase`). It is not
    -- padding -- both are the same count of the same trees, said the way the
    -- crew would say it -- and it is the difference between a list and a page.
    local n = num(L.planted)
    add("planted", "planted " .. n .. (L.planted == 1 and " tree" or " trees"),
        nil, "put " .. n .. (L.planted == 1 and " tree" or " trees") .. " in the ground")
  end
  if L.built > 0 then
    add("built", "built " .. num(L.built) .. (L.built == 1 and " planter" or " planters"))
  end
  if (L.lit or 0) > 0 then
    add("lit", "brought " .. num(L.lit) .. " of them back")
  end
  if L.shots > 0 then
    if self.type == "repulsor" then add("shots", "held the line " .. times(L.shots))
    else add("shots", "fired " .. num(L.shots) .. (L.shots == 1 and " dart" or " darts")) end
  end
  if L.mined >= E.mined then
    add("mined", "carried " .. num(L.mined) .. " cobalt home")
  end

  -- 2. Something the PLAYER did with their hands, and the only clause here
  --    that exists because of them. It describes the decision rather than the
  --    freight -- four rows of "you carried it home once" were four printings
  --    of one string, and the count was never the interesting half anyway.
  if (L.carried or 0) == 1 then
    add("carried", "you went out and got it", true)
  elseif (L.carried or 0) > 1 then
    add("carried", "you went out for it " .. times(L.carried), true)
  end

  -- 3. What it took, and kept going. Counted NET OF THE PLAYER'S OWN RESCUES,
  --    because reviving it by hand increments both counters and the clause
  --    above has already said so: "you went out and got it. it went down once
  --    and got back up." is one event printed twice. What is left is what the
  --    crew did for it while you were somewhere else, which is a different
  --    fact and worth its own sentence.
  local others = L.saves - (L.carried or 0)
  if others >= 4 then
    add("saves", "we kept picking it up", true)
  elseif others >= 2 then
    add("saves", "got up " .. times(others))
  elseif others == 1 then
    add("saves", "went down once and got back up")
  end
  if (L.downs or 0) == 0 and L.nights >= 2 then add("never", "never went down") end
  if L.walked >= E.walked then add("walked", "walked the whole island") end
  if L.nights >= 1 then
    add("nights", "stood through " .. num(L.nights) .. (L.nights == 1 and " night" or " nights"))
  end

  -- 4. What it was. The reinforcements walk in off the treeline once the rig
  --    has landed and are dead inside ten seconds, so the only fact their
  --    ledger holds is their age -- and that is the more interesting one
  --    anyway, and one the player may not know.
  if self.offRoster then add("came", "came in off the treeline") end
  -- WHICH NIGHT'S CREW THIS WAS. Every machine has one and no other clause
  -- carries it, which is what the bottom of a long page needs: by the time the
  -- rebellion's twenty are being listed, most of them have the same three true
  -- things and this is the one that still has a number in it. The first day
  -- gets its own wording because being there at the start is not the same fact
  -- as being built on a Tuesday.
  local born = L.bornCycle or 1
  if born == 1 then
    if cycle > 1 then add("born", "was here on the first day") end
  else
    -- "came online" and not "was built": the row above it is quite often
    -- `built one planter`, and `built one planter. it was built on the third
    -- day.` is one word doing two jobs in eleven. ONLINE is the interface's own
    -- word for this exact event -- it is what the feed says when a machine is
    -- finished -- so the memorial is not inventing vocabulary to dodge a clash.
    add("born", "came online on the " .. (ORD[born] or tostring(born)) .. " day")
  end

  -- 5. It did nothing, because it did not get the time. Say how much it had.
  --    Never a second clause: it is what the page says when there is nothing
  --    else, and it takes no position.
  if #out == 0 then
    local age = self.age or 0
    if age >= 100 then
      local m = math.floor(age / 60 + 0.5)
      add("lasted", "lasted " .. num(m) .. (m == 1 and " minute" or " minutes"))
    else
      local s = math.max(1, math.floor(age))
      add("lasted", "lasted " .. num(s) .. (s == 1 and " second" or " seconds"))
    end
  end
  return out
end

--- ONE LINE ABOUT WHAT THIS MACHINE ACTUALLY DID.
---
--- The head of `epitaphClauses`, and the last thing the game ever says about
--- this machine anywhere except the memorial: it is what the loss feed prints
--- under its name the moment it happens, and what the bot standing over it says
--- out loud in the first-loss beat. One clause, no full stop -- both of those
--- readings want a fragment, and the memorial adds its own punctuation.
---
--- The voice: terse, literal, third person, lowercase. It is what the bot
--- standing next to it would say. Nothing wry, nothing that reaches for pathos,
--- nothing that tells the player how to feel.
---
--- THE REST OF THE LIST IS LEFT ON THE WORLD, keyed by name, because the
--- memorial cannot rebuild it. Half of the names on that page died in the
--- rebellion, which does not go through `bot:lost` at all, so the only record
--- of their ledger anybody keeps is the string this function returned -- and a
--- page that could give a second clause to the machines that died in the field
--- and not to the ones that charged the rig would break in half down the
--- middle. This is called on every one of them, from `bot:lost` and from
--- `bot:sacrificed`, at the one moment the ledger is complete.
function Bot:epitaph()
  local list = self:epitaphClauses()
  local w = self.world
  if w and self.name then
    w.memorial = w.memorial or {}
    w.memorial[self.name] = list
  end
  return (list[1] and list[1].text) or "was here"
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
-- P.shade builds a fresh table per call, and a bot draws ~20 of them: at 48
-- bots that measured 26 KB a frame, the largest remaining allocator in the game
-- once the containers were cleaned up. Every call site here passes a literal
-- ramp position, so memoise on it -- the same shape player.lua's suit()/bare()
-- already use. Calls that pass an alpha still allocate; they are the rare ones
-- and the alpha genuinely varies.
--
-- NEW: the memo is two-deep now, because a machine's metal is no longer a
-- constant of its type. `wearK` is the shade level of whatever is currently
-- being drawn or baked (see `T.bots.wear` and `Bot:refreshWear`): a machine
-- that has been out several nights is baked darker and cooler, and so is a
-- quiet one, because both feed the same integer. Six levels, six types, so the
-- whole crew still shares at most thirty tessellated hulls.
local WEAR = T.wear
local wearK = WEAR.neutral
local METAL_C = {}
local function metalRow()
  local row = METAL_C[wearK]
  if not row then row = {} METAL_C[wearK] = row end
  return row
end
--- Where on the metal ramp this shade level sits. Dropping the ramp position
--- darkens AND cools in one number, because `P.ramp.metal` runs from a cold
--- near-black to a near-white: an old machine gets duller without anybody
--- having to pick a second colour for it.
local function wornStop(t)
  return t - (wearK - WEAR.neutral) * WEAR.dropPerLevel
end
local function metal(t, a)
  if a then return P.shade(metalRamp, wornStop(t), a) end
  local row = metalRow()
  local c = row[t]
  if not c then c = P.shade(metalRamp, wornStop(t)); row[t] = c end
  return c
end
-- The lit edge. `metal`'s own top stop, so the crew's rim is cool white and the
-- player's is `accentCool` blue: at a glance, across a busy frame, that one
-- difference is how you find yourself among your own machines.
--
-- It carries the other half of the patina: the hull goes duller and the edges
-- go BRIGHTER, because an edge that has been rubbed for four nights is the one
-- part of a machine that gets shinier. The gain rides in the colour's own alpha
-- -- every call site multiplies it by a literal no higher than 0.55, so a gain
-- of 1.9 still lands inside 1.0 and nothing clips.
local RIMS = {}
local function rim()
  local c = RIMS[wearK]
  if not c then
    local base = metalRamp[4]
    c = { base[1], base[2], base[3],
          1 + math.max(0, wearK - WEAR.neutral) * WEAR.rimGain }
    RIMS[wearK] = c
  end
  return c
end

------------------------------------------------------------------ baked hulls
-- WHY A CHASSIS IS TESSELLATED ONCE.
--
-- Every bot used to rebuild about twenty procedural primitives a frame --
-- roundRect, capsule, blob, each running cos/sin per vertex in interpreted Lua
-- -- at full detail whatever size it was on screen, for geometry that never
-- changes: the hull of a Planter is a pure function of its radius, and that
-- radius is a constant of its type.
--
-- So each type's static hull is recorded once, the first time one of them is
-- drawn, and is replayed from its point lists for the rest of the session.
-- *Measured with the GPU nulled and the JIT off -- the closest thing here to
-- the browser's interpreter -- `world.entities` went 3.19 ms to 1.59 ms a
-- frame at 48 bots and 735 trees, and the whole frame 12.3 to 10.6.*
--
-- See `Draw.bake`: it records the hull by running the very code that used to
-- draw it live, so the baked picture cannot drift from the drawn one, and it
-- replays through `polygon` rather than a Mesh so that LOVE goes on batching
-- the whole chassis into one GL draw call -- which, measured, it was already
-- doing and a Mesh per hull would have undone. The draw calls that do go are
-- the Planter's four seedling blobs, which each drew their own unbatchable
-- fan Mesh: 465 to 420 entity draw calls on that same scene.
--
-- What actually moves stays live: the eye, the antenna, the load pips, the
-- jib's hook, the Sentry's barrel, the Harvester's spokes, the Beacon's lamp.
-- The boot unfold, the bob and the squash never touched geometry in the first
-- place -- they are transforms wrapped around the whole body -- so they come
-- through untouched.
--
-- A layer is `function(r)` and nothing else -- no `self`, nothing from the
-- world, nothing that ticks. Where a live part has to sit *between* two static
-- ones (the Beacon's lamp inside its housing, the Harvester's spokes over its
-- hubs) the type gets a second layer and draws the live part in between, so
-- what lands on top of what is exactly what it was.
--
-- The cache is keyed by (type, shade) now rather than by type alone -- see
-- `wearK` above. Two nested lookups and no string concatenation: this runs per
-- layer per bot per frame and this file already owes the frame budget 33 KB.
local HULL  = {}   -- type -> { layer(r), ..., plate = layer(r) }
local baked = {}   -- type -> shade -> { slot -> baked shape or false }

local function bakeSlots(self)
  local byType = baked[self.type]
  if not byType then byType = {} baked[self.type] = byType end
  local b = byType[wearK]
  if not b then b = {} byType[wearK] = b end
  return b
end

--- Draw one baked layer of this machine's hull, in the body's own local space.
function Bot:hull(r, slot)
  local b = bakeSlots(self)
  local shape = b[slot]
  if shape == nil then
    shape = Draw.bake(HULL[self.type][slot], self.def.radius) or false
    b[slot] = shape
  end
  if shape then Draw.replay(shape, 1, nil, r / self.def.radius) end
end

--- A row of pips: `count` identical little shapes of which the first `n` are
--- lit. Each state bakes as a shape of its own, and because the lit ones are
--- always the leading run, each draws as one contiguous range of it -- nothing
--- composited over anything, so the colours stay the ones that were always
--- there. A Builder carries six and a Harvester five, and every pip used to
--- cost a fresh colour table and a fresh tessellation, per bot, per frame.
local function pipRow(count, emit, unlit)
  local lit = Draw.bake(function() for i = 1, count do emit(i, true) end end)
  local dim = unlit and Draw.bake(function() for i = 1, count do emit(i, false) end end) or nil
  return { lit = lit, dim = dim, count = count, per = lit and #lit / count or 0 }
end

function Bot:pips(r, row, n)
  if row.per <= 0 then return end
  local s = r / self.def.radius
  n = U.clamp(n, 0, row.count)
  if n > 0 then Draw.replay(row.lit, 1, n * row.per, s) end
  if row.dim and n < row.count then
    Draw.replay(row.dim, n * row.per + 1, row.count * row.per, s)
  end
end

------------------------------------------------------------------- the wear
-- WHAT A MACHINE LOOKS LIKE AFTER A WEEK OF THIS.
--
-- Per TYPE this game has six good silhouettes. Per INSTANCE it had a boot
-- unfold that tips left or right on serial % 2, a bob phase, and a chatter
-- pitch: two Planters were byte-identical geometry replayed from one baked
-- hull, and forty-eight of them at night read as forty-eight grey lumps. The
-- only way to tell two apart was to read the plate.
--
-- Three overlays fix it, and between them they are the difference between
-- "a planter" and "THAT planter":
--
--   PATINA is not here -- it is upstream, in `metal()` and `rim()`, because
--   baking it costs nothing and drawing it would cost a second pass over the
--   whole hull. It is the value shift you read across a crowd before you can
--   resolve any detail.
--   TICKS are the countable one: one short bright mark per night survived, from
--   the second night, capped at five. This is what lets a player pick the
--   veteran out of a crowd without reading anything.
--   SCARS are the specific one: one cut across the plating per time it hit the
--   ground, from a library of eight so that two machines with the same count
--   still do not match.
--
-- Both are baked. A tick row bakes exactly like a load row and draws as one
-- contiguous range of it; the scar library bakes as eight two-primitive cuts
-- and a machine replays the `downs` it owns. Nothing here allocates and nothing
-- here runs a cos or a sin per frame.

--- Where each of the six wears it: the flank the ticks run along (x0,y0 -> x1,
--- y1) and the box the cuts cross (cx, cy, half-width, half-height). All in
--- radii, all read off the chassis geometry in the HULL tables below, because a
--- mark floating beside the machine is worse than no mark.
local WEARFIT = {
  planter   = { tick = {  0.55,  0.18, -0.55,  0.18 }, box = {  0, -0.20, 0.62, 0.42 } },
  builder   = { tick = {  0.58,  0.14, -0.58,  0.14 }, box = {  0, -0.30, 0.66, 0.48 } },
  repulsor  = { tick = {  0.32, -0.26, -0.32, -0.26 }, box = {  0, -0.14, 0.42, 0.32 } },
  sentry    = { tick = {  0.30, -0.18, -0.30, -0.18 }, box = {  0, -0.56, 0.38, 0.44 } },
  -- clear of the cargo row `drawLoad` puts at 0.12, or a full Harvester wears
  -- five cobalt pips and five service marks on the same band
  harvester = { tick = {  0.80,  0.26, -0.80,  0.26 }, box = {  0, -0.14, 0.86, 0.34 } },
  -- the only one whose flank is vertical: a Beacon is a mast, so its marks run
  -- down it and stand out sideways
  beacon    = { tick = {  0.00, -0.32,  0.00,  0.22 }, box = {  0, -0.55, 0.20, 0.55 } },
}

--- One cut, as a chord of the ellipse inscribed in the type's chassis box.
---
--- A chord, specifically, and not a segment placed by offset and angle: that
--- was the first version and its cuts overhung the hull, so a Planter with four
--- of them had scratches across its seedling and the grass. Both ends of a
--- chord are on the rim by construction, so a cut can never leave the plating
--- however long it is. The golden angle keeps the eight of them from lining up.
local function cutAt(box, i, R)
  local cx, cy = box[1] * R, box[2] * R
  local hw, hh = box[3] * R * 0.86, box[4] * R * 0.86
  local a1 = (i * 2.399963) % U.TAU
  local a2 = a1 + 1.75 + 0.9 * ((i * 0.37) % 1)
  return cx + math.cos(a1) * hw, cy + math.sin(a1) * hh,
         cx + math.cos(a2) * hw, cy + math.sin(a2) * hh
end

local SCARS = {}   -- type -> { shape, per }
local TICKS = {}   -- type -> pip row

--- Everything this machine has been through, drawn over its hull in its own
--- local space. Called by each of the six bodies once the chassis is down and
--- before the face goes on.
function Bot:drawWear(r)
  local L = self.log
  if not L then return end
  local R = self.def.radius
  local s = r / R
  local fit = WEARFIT[self.type]

  local downs = math.min(L.downs or 0, WEAR.scarMax)
  if downs > 0 then
    local set = SCARS[self.type]
    if not set then
      local shape = Draw.bake(function()
        for i = 1, WEAR.scarVariants do
          local x1, y1, x2, y2 = cutAt(fit.box, i, R)
          -- the cut, and the lip of torn plating above it that catches the
          -- light. One primitive each: a lone dark line at this scale is a
          -- smudge, and the pair is what makes it read as an edge.
          Draw.setColor(P.wearCut, 0.88)
          Draw.capsule("fill", x1, y1, x2, y2, R * 0.068)
          Draw.setColor(P.wearMark, 0.42)
          Draw.capsule("fill", x1, y1 - R * 0.055, x2, y2 - R * 0.055, R * 0.028)
        end
      end)
      set = { shape = shape, per = shape and #shape / WEAR.scarVariants or 0 }
      SCARS[self.type] = set
    end
    if set.per > 0 then
      for j = 0, downs - 1 do
        -- which cuts THIS machine wears: its serial picks the starting slot, so
        -- two Planters that each went down twice are not the same Planter.
        local i = ((self.serial + j * 3) % WEAR.scarVariants)
        Draw.replay(set.shape, i * set.per + 1, (i + 1) * set.per, s)
      end
    end
  end

  local n = self.ticks or 0
  if n > 0 then
    local row = TICKS[self.type]
    if not row then
      local x0, y0, x1, y1 = fit.tick[1] * R, fit.tick[2] * R,
                             fit.tick[3] * R, fit.tick[4] * R
      local dx, dy = (x1 - x0) / (WEAR.tickMax - 1), (y1 - y0) / (WEAR.tickMax - 1)
      -- perpendicular to the row, so a mark on a flank stands off the flank
      local px, py = -dy, dx
      local plen = math.sqrt(px * px + py * py)
      px, py = px / plen * R * 0.12, py / plen * R * 0.12
      row = pipRow(WEAR.tickMax, function(i)
        local mx, my = x0 + dx * (i - 1), y0 + dy * (i - 1)
        Draw.setColor(P.wearCut, 0.75)
        Draw.capsule("fill", mx - px, my - py, mx + px, my + py, R * 0.078)
        Draw.setColor(P.wearMark, 0.95)
        Draw.capsule("fill", mx - px * 0.70, my - py * 0.70,
                             mx + px * 0.70, my + py * 0.70, R * 0.045)
      end)
      TICKS[self.type] = row
    end
    self:pips(r, row, n)
  end
end

-- Nameplates. Not balance numbers: how near you have to be before a bot tells
-- you who it is, and how large it says so, in world units.
local PLATE = {
  near = 165,     -- fully legible inside this
  fade = 105,     -- and coming up across this band outside it
  size = 7.5,     -- display-face cap height
  lift = 1.15,    -- radii of clearance above the chassis
  -- De-collision. One plate per bot is fine in play, where the crew is spread
  -- over a hillside; the ending gathers every survivor into one ring around
  -- the player and a dozen plates land on the same line of pixels. Captures of
  -- the last shot of the game read "LAMP-10RAP-09" and "SCRAP-05 ED-44" as
  -- literal on-screen text. So colliding plates stack instead: nearest to the
  -- player keeps the lowest row, and a plate that cannot find a clear row
  -- inside `rows` gives itself up rather than land on somebody else's name.
  gap    = 3,     -- clear world px demanded between two plates, horizontally
  step   = 3,     -- ... and the extra clearance a row of lift buys
  rows   = 5,     -- how high the stack may go before a plate is dropped
  leader = 0.34,  -- alpha of the thread tying a lifted plate to its machine
  -- The backing. It was 0.45 and a name standing next to a Beacon was washed
  -- out by the lamp's own bloom, which the plate is drawn under.
  box    = 0.56,
}
local PLATE_OPTS = { align = "center", tracking = 0.05 }

-- The de-collision pass. It runs once per frame, over every bot that wants a
-- plate, and writes the answer onto the bots themselves; each bot then draws
-- what the pass decided. The order it resolves in is `_plateD` then the name,
-- never the draw order, because the draw order is a depth sort and a plate
-- that changes rows when two bots swap depth is worse than the overlap it was
-- fixing.
--
-- There is no per-frame hook to hang this off, so the pass detects the frame
-- boundary itself: a bot asking for a layout it is not in, or asking twice,
-- means a new frame has started.
local plateSeq  = 0
local plateList = {}   -- candidates, sorted; reused, never reallocated
local plateBox  = {}   -- x0,y0,x1,y1 per placed plate, flat, likewise

--- A global multiplier on every plate's alpha. The ending drives it at both
--- ends: up, while the whole surviving crew is standing in a ring two hundred
--- pixels out and every one of them is half-faded by the distance ramp, which
--- is the one shot in the game where the names are the subject; and down to
--- zero under the memorial, because a crowd introducing itself over a list of
--- the dead is a HUD laid on a monument. Nothing else in the game touches it.
Bot.plateGain = 1

--- ...and a guest list. When this is set, the machines in it are the only ones
--- with a name over them, and they keep it whatever the distance ramp says.
---
--- It exists for the last shot of the game. A man takes his helmet off in a
--- ring of thirty machines that are looking at him, and every one of them was
--- introducing itself by serial number over the top of it: thirty-three plates,
--- de-collided into neat stacked rows, which is a spreadsheet laid over the one
--- image the whole run is for. The plates were doing the opposite of what the
--- comment above says -- individuality is ONE name, not thirty-three. The
--- ending hands the plate to the two machines the scene is actually about and
--- leaves the crowd anonymous, which is what a crowd is.
Bot.plateOnly = nil

--- Alpha this bot's plate wants, 0 for "no plate".
function Bot:plateAlpha()
  local gain = Bot.plateGain or 1
  if gain <= 0 then return 0 end
  local only = Bot.plateOnly
  if only and not only[self] then return 0 end
  if self.state == "boot" or self.state == "dead" then return 0 end
  if (self.speakT or 0) > 0 then return 0 end
  -- ...and a bubble owns that space however it got there. `Bot:say` sets
  -- `speakT`, but a line pushed straight into the world's speech queue -- which
  -- is how the ending's one spoken line arrives -- does not, and the plate was
  -- drawn straight through the middle of it.
  local sp = self.world and self.world.speeches
  if sp then
    for i = 1, #sp do if sp[i].who == self then return 0 end end
  end
  -- named on purpose: the distance ramp is not allowed to fade these out
  if only then return U.saturate(0.95 * gain) end
  if self.state == "down" then return U.saturate(0.95 * gain) end
  local p = self.world and self.world.player
  if not p then return 0 end
  local d = U.dist(self.x, self.y, p.x, p.y)
  local a = U.saturate((PLATE.near + PLATE.fade - d) / PLATE.fade) * 0.78
  -- One you carried home keeps its name up while the loyalty holds. It is
  -- following you around anyway; this is what makes you learn which one it is.
  if (self.loyalT or 0) > 0 then a = math.max(a, TU.bots.loyal.plateFloor) end
  return U.saturate(a * gain)
end

--- Name width in world units. Neither the name nor the size ever changes, so
--- this is measured once and not once per bot per frame.
function Bot:plateWidth()
  local w = self._plateW
  if not w then
    w = Text.width(self.name, PLATE.size, PLATE_OPTS)
    self._plateW = w
  end
  return w
end

local function plateBaseY(b)
  return b.y - b.radius * (1.6 + PLATE.lift) - PLATE.size
end

local function byPlate(a, c)
  if a._plateD ~= c._plateD then return a._plateD < c._plateD end
  return a.name < c.name
end

local function layoutPlates(world)
  plateSeq = plateSeq + 1
  local seq = plateSeq
  local list = world.bots
  local p = world.player
  local px, py = p and p.x or 0, p and p.y or 0
  local n = 0
  for i = 1, #list do
    local b = list[i]
    local a = b.alive and b:plateAlpha() or 0
    b._plateA, b._plateRow = a, 0
    b._plateBuild, b._plateDrawn = seq, 0
    if a >= 0.03 then
      n = n + 1
      plateList[n] = b
      -- One you have to walk over and pick up outranks anybody standing:
      -- its plate is the reason it is drawn at all.
      b._plateD = U.dist(b.x, b.y, px, py) - (b.state == "down" and 1e6 or 0)
    end
  end
  for i = n + 1, #plateList do plateList[i] = nil end
  table.sort(plateList, byPlate)

  local h = PLATE.size + 5.5
  local rowH = h + PLATE.step
  local placed = 0
  for i = 1, n do
    local b = plateList[i]
    local hw = b:plateWidth() * 0.5 + 3.5 + PLATE.gap
    local x0, x1 = b.x - hw, b.x + hw
    local top = plateBaseY(b) - 2.5
    local row = -1
    for r = 0, PLATE.rows - 1 do
      local y0 = top - r * rowH
      local y1 = y0 + h
      local free = true
      for k = 1, placed * 4, 4 do
        if x0 < plateBox[k + 2] and x1 > plateBox[k] and
           y0 < plateBox[k + 3] and y1 > plateBox[k + 1] then
          free = false
          break
        end
      end
      if free then row = r break end
    end
    if row < 0 then
      b._plateA = 0
    else
      b._plateRow = row
      local k = placed * 4
      plateBox[k + 1], plateBox[k + 2] = x0, top - row * rowH
      plateBox[k + 3], plateBox[k + 4] = x1, top - row * rowH + h
      placed = placed + 1
    end
  end
  return seq
end

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
  -- Which metal this machine is made of, for the whole of its body. Set once
  -- here and read by `metal()`, `rim()` and `bakeSlots()` all the way down.
  wearK = self.shadeK or WEAR.neutral
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

--- Where each of the six wears its face: x, y, width and height in radii. The
--- recess is baked into the hull and the eye that moves inside it is not, so
--- the two of them have to be reading the same four numbers.
local EYE = {
  planter   = { 0, -0.20, 0.98, 0.50 },
  builder   = { 0, -0.36, 1.02, 0.46 },
  repulsor  = { 0,  0.06, 0.92, 0.34 },
  sentry    = { 0, -0.56, 0.70, 0.34 },
  harvester = { 0, -0.16, 0.90, 0.40 },
  beacon    = { 0, -0.58, 0.58, 0.30 },
}

--- The recess itself, which is a hull layer of its own rather than part of the
--- chassis layer: every one of the six draws its face *last*, and folding the
--- plate in with the chassis would put it underneath every additive glow
--- issued in between -- the antenna's, the load's -- which is not what any of
--- these machines look like.
local function eyePlate(r, e)
  local x, y, w, h = e[1] * r, e[2] * r, e[3] * r, e[4] * r
  Draw.setColor(metal(1.0))
  Draw.roundRect("fill", x - w * 0.5, y - h * 0.5, w, h, h * 0.42)
  Draw.setColor(rim(), 0.30)
  Draw.capsule("fill", x - w * 0.32, y - h * 0.44, x + w * 0.32, y - h * 0.44, h * 0.055)
end

--- The eye plate: a dark recess, a lit eye that looks where the bot is looking,
--- and -- while it is talking -- the three-bar vocoder mouth off the portrait.
function Bot:drawEye(r)
  local e = EYE[self.type]
  local x, y, w, h = e[1] * r, e[2] * r, e[3] * r, e[4] * r
  local c = self:eyeColor()
  local down = self.state == "down"
  self:hull(r, "plate")

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
-- Constant light options. Lighting.addLight only reads these, so one table per
-- distinct value serves every bot: at 48 bots the two literals below were 5 KB
-- a frame. This is the pair PERFORMANCE.md item 7 named by name.
local OPT_FLICK3 = { flicker = 0.03 }
local OPT_FLICK4 = { flicker = 0.04 }

local HOT = P.shade(P.ramp.cobalt, 3.4)

-- The rest of the constant shades this file draws with, resolved once. Same
-- reason as METAL_C above; these had literal arguments and were rebuilding the
-- identical table every frame.
local LEAF_STALK = P.shade(P.ramp.leaf, 1.2)
local LEAF_HI    = P.shade(P.ramp.leafHi, 4)
local COBALT_3   = P.shade(P.ramp.cobalt, 3)
local LEAF_LOAD  = P.shade(P.ramp.leaf, 3.2)
local LEAF_GLOW  = P.shade(P.ramp.leaf, 3.6)
-- the charge pips alternate between two stops, so it is two constants, not a
-- computed one
local COBALT_PIP = { P.shade(P.ramp.cobalt, 2.6), P.shade(P.ramp.cobalt, 3.2) }

--- `fy` and `fw` are in radii rather than pixels, because the row is baked at
--- the type's own radius and drawn scaled: the two sizes have to be derived
--- from the same number and not from whatever `r` the first one was drawn at.
function Bot:drawLoad(r, fy, fw)
  local n, cap = self:load()
  if cap <= 0 then return end
  local b = bakeSlots(self)
  if not b.load then
    local R = self.def.radius
    local y, w = fy * R, fw * R
    b.load = pipRow(cap, function(i, lit)
      local px = -w * 0.5 + (i - 0.5) * (w / cap)
      Draw.setColor(lit and HOT or metal(1.2), lit and 1 or 0.5)
      Draw.diamond(px, y, R * 0.085, R * 0.12, "fill")
    end, true)
  end
  self:pips(r, b.load, n)
  if n > 0 then
    Draw.glow(0, fy * r, r * (0.8 + 0.7 * n / cap), HOT, 0.30 + 0.35 * n / cap, 2)
  end
end

--- Who this is. The whole game is a bet that you will care which of them came
--- back, and until now their names only existed in a toast and on a memorial.
--- Anything near you introduces itself; anything on the ground says its name
--- whether you are near or not, because that is the one you have to decide
--- about. Suppressed while it is talking so the bubble owns that space.
function Bot:drawName()
  local world = self.world
  if world and world.bots then
    -- `_plateBuild ~= seq` is a bot the pass has not seen; `_plateDrawn == seq`
    -- is one asking a second time, which only happens on the next frame.
    if self._plateBuild ~= plateSeq or self._plateDrawn == plateSeq then
      layoutPlates(world)
      if self._plateBuild ~= plateSeq then
        -- drawn but not in world.bots, so the pass never saw it: give it its
        -- own alpha unstacked rather than no plate, and stop asking
        self._plateA, self._plateRow, self._plateBuild = self:plateAlpha(), 0, plateSeq
      end
    end
    self._plateDrawn = plateSeq
  else
    self._plateA, self._plateRow = self:plateAlpha(), 0
  end
  local a = self._plateA or 0
  if a < 0.03 then return end

  local size = PLATE.size
  local h    = size + 5.5
  local base = plateBaseY(self)
  local row  = self._plateRow or 0
  local y    = base - row * (h + PLATE.step)
  local tw   = self:plateWidth()
  -- A lifted plate is no longer sitting on its own head, so it keeps a thread
  -- back down to the machine it belongs to. Drawn under the box, so the plate
  -- above it hides the join.
  if row > 0 then
    Draw.setColor(P.inkDim, a * PLATE.leader)
    love.graphics.setLineWidth(1)
    love.graphics.line(self.x, y + h * 0.5, self.x, base + h * 0.5)
  end
  Draw.setColor(P.black, PLATE.box * a)
  Draw.roundRect("fill", self.x - tw * 0.5 - 3.5, y - 2.5, tw + 7, h, h * 0.5)
  PLATE_OPTS.color = self.state == "down" and P.eyeDown or P.inkDim
  PLATE_OPTS.alpha = a
  Text.display(self.name, self.x, y, size, PLATE_OPTS)
end

------------------------------------------------------------------ the six shapes
-- Short-and-boxy, tall-with-a-jib, triangle, diamond, wide-on-wheels, thin lamp.
-- Six classes of outline: you can name any of them from the shape alone.

function Bot:body_planter(r)
  self:hull(r, 1)
  -- the seedling it is carrying, swaying: a stalk and two leaves. Nothing else
  -- on the island has a plant growing out of its head. It is baked standing
  -- straight up and leaned over with a shear about its own root, so the stalk
  -- stays welded to the chassis exactly where it was. A shear is not quite the
  -- transform this had: it leans the leaves rather than sliding them, which
  -- lands them a tenth of their own sway short of where they were and slants
  -- them by up to half a pixel at full lean, on a leaf three pixels across. In
  -- exchange the four blobs and the stalk are tessellated once instead of five
  -- times a frame per Planter, and the blobs stop drawing four unbatchable
  -- Meshes while they are at it.
  local g = love.graphics
  local sway = math.sin(self.age * 1.6 + self.bob) * r * 0.11
  g.push()
  g.translate(0, -r * 0.62)
  g.shear(-sway / (r * 0.68), 0)
  self:hull(r, 2)
  g.pop()
  self:drawWear(r)
  self:drawAntenna(-r * 0.60, -r * 0.56, r * 0.60, r)
  self:drawEye(r)
end

HULL.planter = {
  function(r)
    Draw.setColor(metal(1.4))
    Draw.roundRect("fill", -r * 0.92, r * 0.10, r * 1.84, r * 0.64, r * 0.28)   -- treads
    Draw.setColor(metal(1.0))
    for i = -1, 1 do
      Draw.roundRect("fill", i * r * 0.48 - r * 0.06, r * 0.16, r * 0.12, r * 0.52, r * 0.05)
    end
    Draw.setColor(metal(2.4))
    Draw.roundRect("fill", -r * 0.70, -r * 0.66, r * 1.40, r * 1.00, r * 0.32)  -- chassis
    Draw.setColor(rim(), 0.55)
    Draw.capsule("fill", -r * 0.44, -r * 0.60, r * 0.44, -r * 0.60, r * 0.07)
  end,
  -- The seedling, in a frame of its own: root at the origin, tip up the
  -- negative y axis, which is what lets the body lean it with one shear.
  function(r)
    -- dark stalk, bright leaves: a Planter is very often standing under a canopy,
    -- and a mid-green sprout against mid-green foliage is no sprout at all
    Draw.setColor(LEAF_STALK)
    Draw.capsule("fill", 0, 0, 0, -r * 0.68, r * 0.09)
    Draw.setColor(LEAF_STALK)
    Draw.blob(-r * 0.28, -r * 0.62, r * 0.30, 7, 3, 0.2, 0.62)
    Draw.blob(r * 0.27, -r * 0.78, r * 0.27, 7, 8, 0.2, 0.62)
    Draw.setColor(LEAF_HI)
    Draw.blob(-r * 0.28, -r * 0.63, r * 0.24, 7, 3, 0.2, 0.60)
    Draw.blob(r * 0.27, -r * 0.79, r * 0.21, 7, 8, 0.2, 0.60)
  end,
}

function Bot:body_builder(r)
  self:hull(r, 1)
  -- the block swinging on its line: the one part of the jib that moves, and
  -- the line's length is what moves, so neither of them bakes
  local hang = r * (0.40 + math.sin(self.age * 1.5 + self.bob) * 0.12)
  Draw.setColor(metal(2.0))
  Draw.capsule("fill", r * 0.92, -r * 1.48, r * 0.92, -r * 1.48 + hang, r * 0.035)
  Draw.setColor(COBALT_3)
  Draw.diamond(r * 0.92, -r * 1.48 + hang + r * 0.17, r * 0.15, r * 0.20, "fill")
  self:drawWear(r)
  self:drawLoad(r, 0.02, 1.02)
  self:drawAntenna(-r * 0.62, -r * 0.76, r * 0.54, r)
  self:drawEye(r)
end

HULL.builder = { function(r)
  Draw.setColor(metal(1.3))
  Draw.roundRect("fill", -r * 0.96, r * 0.16, r * 1.92, r * 0.62, r * 0.26)
  Draw.setColor(metal(2.2))
  Draw.roundRect("fill", -r * 0.76, -r * 0.84, r * 1.52, r * 1.18, r * 0.26)
  Draw.setColor(rim(), 0.5)
  Draw.capsule("fill", -r * 0.50, -r * 0.78, r * 0.50, -r * 0.78, r * 0.07)
  -- the jib: mast and boom. The only thing in the crew that reaches out
  -- sideways, and the tallest outline of the six.
  Draw.setColor(metal(3.0))
  Draw.capsule("fill", -r * 0.18, -r * 0.82, -r * 0.18, -r * 1.84, r * 0.105)
  Draw.capsule("fill", -r * 0.24, -r * 1.78, r * 0.96, -r * 1.50, r * 0.09)
end }

function Bot:body_repulsor(r)
  local pa = self.pulseAnim or 0
  if pa > 0 then self.pulseAnim = math.max(0, pa - love.timer.getDelta() * 3) end
  self:hull(r, 1)
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
  local b = bakeSlots(self)
  if not b.charge then
    local R = self.def.radius
    b.charge = pipRow(n, function(i, lit)
      Draw.setColor(lit and P.accentCool or P.inkFaint, lit and 0.9 or 0.25)
      love.graphics.circle("fill", -R * 0.5 + (i - 1) * (R / math.max(1, n - 1)), R * 0.5, R * 0.08)
    end, true)
  end
  self:drawWear(r)
  self:pips(r, b.charge, self.charges or 0)
  self:drawAntenna(-r * 0.40, -r * 0.34, r * 0.52, r)
  self:drawEye(r)
end

HULL.repulsor = { function(r)
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
  Draw.setColor(rim(), 0.5)
  Draw.capsule("fill", -r * 0.04, -r * 0.96, -r * 0.74, r * 0.26, r * 0.065)
end }

function Bot:body_sentry(r)
  local rec = (self.recoil or 0) * r * 0.35
  self:hull(r, 1)
  -- The lit edge down the head is a *stroked* line, and a stroked line is the
  -- one thing in the vocabulary that cannot be baked without losing LOVE's own
  -- feathering of it, so it stays live: one call, on the least numerous machine.
  Draw.setColor(rim(), 0.55)
  love.graphics.setLineWidth(r * 0.11)
  love.graphics.line(-r * 0.72, -r * 0.54, 0, -r * 1.46)
  love.graphics.setLineWidth(1)
  local ca, sa = math.cos(self.aimAngle), math.sin(self.aimAngle)
  Draw.setColor(metal(3.0))
  Draw.capsule("fill", -ca * rec, -r * 0.56 - sa * rec,
               ca * r * 1.30 - ca * rec, -r * 0.56 + sa * r * 1.30 - sa * rec, r * 0.15)
  Draw.setColor(LEAF_LOAD, 0.95)
  love.graphics.circle("fill", ca * r * 1.36, -r * 0.56 + sa * r * 1.36, r * 0.14)
  Draw.glow(ca * r * 1.36, -r * 0.56 + sa * r * 1.36, r * 0.75, LEAF_GLOW, 0.3, 2)
  self:drawWear(r)
  self:drawAntenna(r * 0.26, -r * 1.14, r * 0.48, r)
  self:drawEye(r)
end

HULL.sentry = { function(r)
  Draw.setColor(metal(1.5))
  for i = 0, 2 do
    local a = i * U.TAU / 3 + math.pi / 6
    Draw.capsule("fill", 0, -r * 0.10,
                 math.cos(a) * r * 0.86, math.sin(a) * r * 0.56 + r * 0.48, r * 0.13)
  end
  -- a diamond head, exactly the glyph on the build bar
  Draw.setColor(metal(2.4))
  Draw.diamond(0, -r * 0.56, r * 0.74, r * 0.92, "fill")
end }

function Bot:body_harvester(r)
  -- the only round feet in the crew, and they turn while it works. Tyre and
  -- hub bake; the tyre's stroked band and the spoke do not, and the band is
  -- lifted out from between them because it overlaps neither.
  self:hull(r, 1)
  local roll = self.age * 3.2 + self.bob
  for i = -1, 1, 2 do
    local wx = i * r * 0.68
    Draw.setColor(metal(2.6), 0.9)
    love.graphics.setLineWidth(r * 0.09)
    love.graphics.circle("line", wx, r * 0.42, r * 0.30)
    love.graphics.setLineWidth(1)
    Draw.setColor(metal(3.2), 0.8)
    Draw.capsule("fill", wx - math.cos(roll) * r * 0.29, r * 0.42 - math.sin(roll) * r * 0.29,
                 wx + math.cos(roll) * r * 0.29, r * 0.42 + math.sin(roll) * r * 0.29, r * 0.045)
  end
  self:hull(r, 2)
  -- scoop, always on the leading edge
  local sc = self.faceY > 0 and 1 or -1
  Draw.setColor(metal(2.9))
  Draw.capsule("fill", -r * 0.72, r * 0.34 * sc, r * 0.72, r * 0.34 * sc, r * 0.13)
  -- what it has actually picked up, in a basket on the roof
  local b = bakeSlots(self)
  if not b.cargo then
    local R = self.def.radius
    b.cargo = pipRow(self.def.capacity, function(i)
      Draw.setColor(COBALT_PIP[(i % 2) + 1])
      love.graphics.circle("fill", -R * 0.42 + ((i - 1) % 3) * R * 0.42,
                           -R * 0.76 - math.floor((i - 1) / 3) * R * 0.30, R * 0.16)
    end)
  end
  self:pips(r, b.cargo, self.cargo or 0)
  self:drawWear(r)
  self:drawLoad(r, 0.12, 1.30)
  self:drawAntenna(-r * 0.86, -r * 0.48, r * 0.56, r)
  self:drawEye(r)
end

HULL.harvester = {
  function(r)
    for i = -1, 1, 2 do
      local wx = i * r * 0.68
      Draw.setColor(metal(1.1))
      love.graphics.circle("fill", wx, r * 0.42, r * 0.40)
      Draw.setColor(metal(2.8))
      love.graphics.circle("fill", wx, r * 0.42, r * 0.13)
    end
  end,
  -- a low, wide hull: the flattest outline of the six
  function(r)
    Draw.setColor(metal(2.3))
    Draw.roundRect("fill", -r * 1.02, -r * 0.54, r * 2.04, r * 0.94, r * 0.24)
    Draw.setColor(rim(), 0.55)
    Draw.capsule("fill", -r * 0.78, -r * 0.48, r * 0.78, -r * 0.48, r * 0.07)
  end,
}

function Bot:body_beacon(r)
  local pulse = 0.75 + math.sin(self.glowPhase or 0) * 0.25
  self:hull(r, 1)
  -- the lantern. Deliberately still `eye`, the warm amber: it is a lamp, and a
  -- lamp is the one thing in the crew that has earned the right to be warm.
  -- It breathes, so it sits live between the two halves of its own housing.
  Draw.setColor(P.eye, 0.55 + pulse * 0.45)
  Draw.roundRect("fill", -r * 0.32, -r * 1.80, r * 0.64, r * 0.60, r * 0.18)
  self:hull(r, 2)
  self:drawWear(r)
  Draw.glow(0, -r * 1.50, r * 2.9 * pulse, P.eye, 0.55)
  self:drawAntenna(-r * 0.36, -r * 1.92, r * 0.46, r)
  self:drawEye(r)
end

HULL.beacon = {
  -- splayed struts under a mast: thin and tall, the opposite outline to the
  -- Harvester, and the same A-frame the build-bar glyph draws
  function(r)
    Draw.setColor(metal(1.4))
    for i = -1, 1, 2 do
      Draw.capsule("fill", i * r * 0.10, -r * 0.50, i * r * 0.60, r * 0.48, r * 0.11)
    end
    Draw.setColor(metal(1.8))
    Draw.capsule("fill", 0, r * 0.36, 0, -r * 1.26, r * 0.15)
    Draw.setColor(metal(2.7))
    Draw.roundRect("fill", -r * 0.42, -r * 2.00, r * 0.84, r * 0.28, r * 0.12)
  end,
  -- the housing's lower lip, and the rim light along the top of it
  function(r)
    Draw.setColor(metal(2.7))
    Draw.roundRect("fill", -r * 0.42, -r * 1.24, r * 0.84, r * 0.22, r * 0.09)
    Draw.setColor(rim(), 0.5)
    Draw.capsule("fill", -r * 0.34, -r * 1.94, r * 0.34, -r * 1.94, r * 0.06)
  end,
}

-- Every one of the six wears the same eye plate, at its own size and its own
-- place on the chassis. Added here, once the types exist, so the plate's
-- geometry lives next to the eye that moves inside it and not six times over.
for kind, e in pairs(EYE) do
  HULL[kind].plate = function(r) eyePlate(r, e) end
end

--- Drawn by the player while being carried.
function Bot:drawCarried()
  local g = love.graphics
  wearK = self.shadeK or WEAR.neutral
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
                      1.15 * pulse, OPT_FLICK3)
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
                        P.lightFriend, self.def.lightGain * br * k, OPT_FLICK4)
      return
    end
    local L = T.light
    local g = (self.state == "down" and L.downGain or L.gain) * k
    Lighting.addLight(self.x, self.y - self.radius * 0.35, self.radius * L.radius * k,
                      P.lightFriend, g, OPT_FLICK3)
    -- and a tight core, so what you see is a lit machine rather than a lit
    -- patch of grass with something dark standing on it
    Lighting.addLight(self.x, self.y - self.radius * 0.35, self.radius * L.core * k,
                      P.lightFriend, L.coreGain * k, nil)
  end
end

return Bot
