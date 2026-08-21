-- The Blight. Eight behaviours over one chassis; they want the trees, not you.
--
-- Six of them used to be four variations on "a thing that walks at a tree", and
-- the player's answer to every one of them was the same button. Each behaviour
-- here is meant to be a different *problem*: the Chomper is a clock you can beat
-- by getting there, the Skitter is a thing you cannot chase and have to meet,
-- the Spitter gives ground so you have to close, the Siphon takes the tree it is
-- sitting on so it has to be answered, the Bulwark is armour, the Warden is a
-- target-priority puzzle, the Maw is a hole that has to be shut, and the Scar is
-- not a fight at all -- it is the day's chore, and it has a deadline.
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
local DayNight = Opt.require("src.engine.daynight")
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
  self.creep   = def.creepStart          -- Scars only; nil everywhere else
  self.wardedT = 0
  Signal.emit("enemy:spawned", self)
end

function Enemy:slowFactor()
  local s = 1
  if self.world and self.world.beaconSlowAt then s = s * (1 - self.world:beaconSlowAt(self.x, self.y)) end
  if self.acidSlow and self.acidSlow > 0 then s = s * 0.6 end
  -- A Warden's field is pushed onto its kin rather than pulled by them: one
  -- spatial query per Warden every fifth of a second, instead of one per enemy
  -- per frame in the hottest loop in the entity sweep.
  if self.wardedT > 0 and self.warden then s = s * (1 + self.warden.def.wardHaste) end
  return s
end

--- One chew registration per Blight, ever, and one place that owns it.
---
--- Before this the Chomper, the Bulwark and `onDeath` each kept their own
--- bookkeeping and none of them agreed. The Bulwark latched onto the first tree
--- it slammed and never released it, so `not self.chewing` was false forever
--- after and every later tree it stood over took no damage at all -- one kill
--- per Bulwark for the whole run, and nothing to show for the rest of it. And
--- `onDeath` released both `target` and `chewing`, which on the common frame
--- where they were the same tree decremented somebody *else's* registration off
--- it. The tree owns the timer and `World:fellTree` is the single sanctioned
--- way a tree dies to the Blight; this owns the handle into it.
function Enemy:engage(t)
  if self.chewing == t then return end
  self:release()
  if t and t.alive and t.startChew and t:startChew(self) then
    self.chewing = t
    t.markedBy = self
    -- Emitted where teeth actually meet wood rather than at target selection,
    -- which is what makes it worth listening to: this is the Blight *winning*,
    -- somewhere, right now. The Director reinforces it from cycle 4.
    Signal.emit("enemy:targeted", self, t)
  end
end

function Enemy:release()
  local t = self.chewing
  self.chewing = nil
  if t and t.stopChew then t:stopChew() end
end

function Enemy:update(dt)
  self:updateCommon(dt)
  if self.wardedT > 0 then
    self.wardedT = self.wardedT - dt
    if self.wardedT <= 0 then self.warden = nil end
  end
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

--- The one thing on the island the Blight is afraid of. Used by the behaviours
--- that back away rather than close, so "give ground" means something specific
--- instead of drifting off the target it is meant to be shooting at.
function Enemy:nearestThreat(r)
  local w = self.world
  local p = w and w.player
  if p and p.alive and U.dist(self.x, self.y, p.x, p.y) < r then return p end
  return nil
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
    if self.target then self.target.markedBy = self end
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
    -- The chew timer used to live here as well as on the tree, reading the same
    -- constant and the same chip and racing it every frame. There is one timer
    -- now and the tree owns it; a Chomper registers, holds station, and lets go
    -- when the wood it was standing over is gone.
    if self.chewing ~= t then
      self:engage(t)
      Audio.play("chomp", { x = self.x, y = self.y })
    end
    self.chewT = self.chewT + dt
    if self.rng:chance(dt * 2.5) then
      Audio.play("chomp", { pitch = self.rng:range(0.9, 1.15), volume = 0.5, x = self.x, y = self.y })
      VFX.emit("leaf_litter", t.x, t.y - t.radius, { count = 2 })
    end
  else
    self:release()
    self.chewT = 0
  end
end

--- A Skitter used to be a Chomper that walked at bots instead of trees, which
--- meant the player's answer to both was the same button held in the same place.
--- It commits now: it closes, it plants itself for a third of a second, and then
--- it throws itself the last two hundred pixels far too fast to be met head-on
--- -- and whatever happens it backs straight off afterwards to reset.
---
--- What that asks of the player is the opposite of a Chomper. Chasing one is a
--- waste of a night. You stand between it and the workforce, you leave a
--- Repulsor on the ground it keeps coming back through, or you catch it in the
--- wind-up, which is the one moment in its whole loop that it is standing still.
function Enemy:update_skitter(dt)
  local w = self.world
  local D = self.def

  if (self.backoffT or 0) > 0 then
    self.backoffT = self.backoffT - dt
    local t = self.target
    -- Away from whatever it just bit. With no target left it keeps whatever
    -- heading it already had rather than drawing a fresh angle every frame: the
    -- Blight shares the world's RNG stream, so a draw taken here moves where the
    -- forest seeds itself, and a headless trace stops comparing like with like.
    local ax, ay = self.faceX ~= 0 and -self.faceX or 1, -self.faceY
    if t then ax, ay = self.x - t.x, self.y - t.y end
    local nx, ny = U.norm(ax, ay)
    local sp = D.speed * D.backoffSpeed * self:slowFactor()
    self.vx = U.damp(self.vx, nx * sp, 6, dt)
    self.vy = U.damp(self.vy, ny * sp, 6, dt)
    self:integrate(dt, 0)
    self:constrain(w and w.terrain, 0)
    return
  end

  if not self.target or not self.target.alive or self.target.state == "dead" then
    self.target = w and (w:nearestBot(self.x, self.y, 1400) or w.player)
    self.windT, self.lungeT = nil, nil
  end
  local t = self.target
  if not t then return end

  -- the tell: legs braced, body low, going nowhere
  if self.windT then
    self.windT = self.windT - dt
    self:integrate(dt, 11)
    self:setFacing(t.x - self.x, t.y - self.y)
    if self.windT <= 0 then
      self.windT = nil
      self.lungeT = D.lungeTime
      local nx, ny = U.norm(t.x - self.x, t.y - self.y)
      self.vx, self.vy = nx * D.lungeSpeed, ny * D.lungeSpeed
      Audio.play("dash", { pitch = 1.55, volume = 0.45, x = self.x, y = self.y })
      VFX.emit("dash_trail", self.x, self.y)
    end
    return
  end

  if self.lungeT then
    self.lungeT = self.lungeT - dt
    self:integrate(dt, 1.4)
    self:constrain(w and w.terrain, 0.5)
    local d = U.dist(self.x, self.y, t.x, t.y)
    if d < (t.radius or 12) + self.radius then
      if type(t.damage) == "function" then t:damage(D.damage, self.x, self.y) end
      self:push(self.x - t.x, self.y - t.y, 300)
      self.lungeT, self.backoffT = nil, D.backoff
    elseif self.lungeT <= 0 then
      -- a miss costs it half a retreat, which is the window you were given
      self.lungeT, self.backoffT = nil, D.backoff * 0.5
    end
    return
  end

  local d = self:seek(t.x, t.y, dt, 1)
  if d < D.lungeRange then self.windT = D.lungeWind end
end

function Enemy:update_spitter(dt)
  local w = self.world
  local D = self.def
  local t = self.target
  if not t or not t.alive then
    self.target = w and (w:nearestBot(self.x, self.y, D.range * 1.6)
                         or w:nearestTree(self.x, self.y, D.range * 1.6))
    t = self.target
  end
  if not t then return end
  local d = U.dist(self.x, self.y, t.x, t.y)
  if d > D.range * 0.8 then
    self:seek(t.x, t.y, dt)
  else
    -- It gives ground. A Spitter that stood still while the player strolled into
    -- shove range was a slow Chomper with a projectile: the interesting thing
    -- about artillery is that closing on it has to cost you something, so it
    -- walks backwards out of the near half of its own range and you have to
    -- spend the dash.
    local near = self:nearestThreat(D.range * D.kite)
    if near then
      local nx, ny = U.norm(self.x - near.x, self.y - near.y)
      local sp = D.speed * self:slowFactor()
      self.vx = U.damp(self.vx, nx * sp, 5, dt)
      self.vy = U.damp(self.vy, ny * sp, 5, dt)
      self:integrate(dt, 0)
      self:constrain(w and w.terrain, 0)
    else
      self.vx, self.vy = self.vx * 0.85, self.vy * 0.85
      self:integrate(dt, 3)
    end
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

--- The Siphon took eleven of the Director's budget and eighteen percent of its
--- roster weight to add to a global oxygen *debt* that was clamped to a tenth of
--- the reading and bled itself off in half a minute of daylight. The correct
--- play against one was to walk past it. It takes the tree now -- the actual
--- tree, the one it is sitting on, permanently, through the same timer and the
--- same telegraph a Chomper uses -- so the needle dipping is the warning that
--- something is feeding rather than the whole of the damage, and a Siphon is a
--- thing you run at.
---
--- It never lets go on its own, it cannot be knocked off a perch (a shove moves
--- it and it comes straight back), and while it is feeding it has its tendril
--- down and takes double: committing to a meal is the risk it is taking.
function Enemy:update_siphon(dt)
  local w = self.world
  local D = self.def
  self.hoverT = self.hoverT + dt * 1.6

  local t = self.perchTree
  if t and (not t.alive or t.stage == "dead") then t = nil end
  if not t then
    self:release()
    self.feeding = false
    -- an unclaimed tree first, so a flight of Siphons spreads over the wood
    -- rather than all queueing for one trunk
    t = w and (w:nearestTree(self.x, self.y, D.perchRange, true)
               or w:nearestTree(self.x, self.y, D.perchRange))
    self.perchTree = t
  end
  if not t then
    -- nothing left standing within reach: drift home and wait to be shot
    if w then self:seek(w.centerX, w.centerY, dt, 0.5) end
    return
  end

  local d = self:seek(t.x, t.y - D.perchHeight, dt, 0.9)
  local close = d < D.perchRadius
  if close and not self.feeding then
    self.feeding = true
    self:engage(t)
    Audio.play("siphon_latch", { x = self.x, y = self.y })
  elseif not close and self.feeding then
    self.feeding = false
    self:release()
  end
  if self.feeding and w then
    w:drainO2(TU.o2.siphonDrain, dt)
    -- The drone. Now that a Siphon takes the tree instead of the meter, this is
    -- very often the only warning the player gets that a grove on the far side
    -- of the island is being taken apart -- so it is load-bearing, not dressing.
    Audio.siphonFeeding(self.x, self.y)
    if self.rng:chance(dt * 5) then VFX.emit("blight_spore", self.x, self.y + 10) end
  end
end

--- Armour, and a grudge against the things that shoot back. The search radius is
--- the whole of what makes it a threat rather than a courier: at 2400 it could
--- see every Beacon on the island and walked straight past every tree between
--- here and there, so a night that bought Bulwarks bought the forest a night off.
--- It looks for something to break locally and takes the wood if there is nothing.
function Enemy:update_bulwark(dt)
  local w = self.world
  if not self.target or not self.target.alive or self.target.state == "dead" then
    self.target = w and (w:nearestBot(self.x, self.y, self.def.instSearch, function(b)
      return b.type == "beacon" or b.type == "sentry" or b.type == "repulsor"
    end) or w:nearestTree(self.x, self.y, 2400))
  end
  local t = self.target
  if not t then return end
  local d = self:seek(t.x, t.y, dt)
  if d >= t.radius + self.radius + 4 then self:release() end
  if d < t.radius + self.radius + 4 then
    self.slamT = (self.slamT or 0) + dt
    if self.slamT > 1.1 then
      self.slamT = 0
      if type(t.damage) == "function" then t:damage(self.def.damage, self.x, self.y) end
      -- One registration, and `engage` owns it. The old guard was `not
      -- self.chewing`, which held the first tree this Bulwark ever slammed for
      -- the rest of its life: after that one fell it stood over every later tree
      -- doing nothing but dust and screen shake.
      self:engage(t)
      VFX.emit("slam_dust", self.x, self.y)
      J.shake(0.1)
    end
  end
end

--- A Maw does not walk off at sunrise -- it is a hole in the ground. It closes
--- its throat when the sun comes up and waits, which is what turns it from a
--- night that ends into a thing standing in your island that you have to go and
--- deal with in daylight. Every night it survives it opens faster, so leaving it
--- is a decision that gets more expensive rather than one you can simply make.
function Enemy:update_maw(dt)
  local w = self.world
  local day = w and (w.phase == "day" or w.phase == "dawn")
  self.pulse = (self.pulse or 0) + dt * (day and 0.7 or 2)

  if day then
    if not self.dormant then
      self.dormant = true
      Audio.play("rift_close", { volume = 0.7, x = self.x, y = self.y })
    end
    if self.rng:chance(dt * 2) then VFX.emit("rift_ambient", self.x, self.y) end
    return
  end
  if self.dormant then
    self.dormant = false
    self.wakes = (self.wakes or 0) + 1
    self.spawnEvery = math.max(self.def.wakeFloor,
                               (self.spawnEvery or self.def.spawnEvery) * self.def.wakeStep)
    Audio.play("rift_open", { x = self.x, y = self.y })
    VFX.emit("rift_open", self.x, self.y, { power = 1 })
    J.shake(0.3)
  end

  self.spawnEvery = self.spawnEvery or self.def.spawnEvery
  self.fireT = self.fireT - dt
  if self.fireT <= 0 then
    self.fireT = self.spawnEvery
    if w then
      local a = self.rng:angle()
      w:spawnEnemyAt(self.x + math.cos(a) * 40, self.y + math.sin(a) * 40, "chomper")
      VFX.emit("rift_open", self.x, self.y, { power = 0.4 })
    end
  end
  if self.rng:chance(dt * 8) then VFX.emit("rift_ambient", self.x, self.y) end
end

--- The Warden. It has no attack, it never touches a tree, and on its own it is
--- nine hit points floating slowly backwards. What it does is make everything
--- else wrong: its kin inside the field shrug off more than half of every hit
--- and move a fifth faster, so the pack you have been clearing the same way for
--- five nights stops dying at the rate you have learned to expect.
---
--- That is the whole of the card: it does not make the night bigger, it moves
--- the answer. The front of a wave is no longer the thing to hit. You have to
--- get past it -- and it hangs at the back and backs off when you come, so
--- getting past it costs a dash, a pulse or a Sentry sited well behind the line.
function Enemy:update_warden(dt)
  local w = self.world
  local D = self.def
  self.hoverT = self.hoverT + dt * 1.3
  -- the flare that fires when its field eats a hit, decayed here rather than in
  -- `draw`: the headless harness renders only the frames it photographs, and a
  -- visual that decays in draw would still be lit twenty seconds later
  self.shielded = math.max(0, (self.shielded or 0) - dt * 2.6)

  -- push the field onto the pack, rather than every enemy pulling on it
  self.wardT = (self.wardT or 0) - dt
  if self.wardT <= 0 and w and w.hEnemy then
    self.wardT = D.wardTick
    local hold = D.wardTick * 1.6
    w.hEnemy:each(self.x, self.y, D.wardRadius, function(e)
      if e ~= self and e.alive and e.kind == "enemy" and not e.fleeing then
        e.wardedT = hold
        e.warden = self
      end
    end)
  end

  -- keep station behind whatever is doing the work, and give ground to the player
  local shy = self:nearestThreat(D.shy)
  if shy then
    local nx, ny = U.norm(self.x - shy.x, self.y - shy.y)
    local sp = D.speed * 1.25 * self:slowFactor()
    self.vx = U.damp(self.vx, nx * sp, 5, dt)
    self.vy = U.damp(self.vy, ny * sp, 5, dt)
    self:integrate(dt, 0)
    self:constrain(w and w.terrain, 0)
    return
  end
  if not self.flock or not self.flock.alive or self.flock.fleeing then
    self.flock = w and w:nearestEnemy(self.x, self.y, D.flockRange, function(e)
      return e ~= self and e.type ~= "warden" and e.type ~= "scar"
    end)
  end
  local f = self.flock
  if not f then
    if w then self:seek(w.centerX, w.centerY, dt, 0.6) end
    return
  end
  local d = U.dist(self.x, self.y, f.x, f.y)
  if d > D.standOff then self:seek(f.x, f.y, dt, 1)
  else
    self.vx, self.vy = self.vx * 0.9, self.vy * 0.9
    self:integrate(dt, 3)
    self:setFacing(f.x - self.x, f.y - self.y)
  end
end

--- The Scar. Six hundred and fifty-eight seconds of every run -- fifty-one
--- percent of it -- had no opposition in it whatsoever: the enemy count was zero
--- in every daylight sample of every trace, and the only decision daylight
--- contained was the twelve seconds of HOLD THE DAWN at the end of it.
---
--- This is the day's opposition and it is deliberately not a fight. It does not
--- move, it does not chase, and it cannot hurt the player. It sits in the ground
--- where the Blight was standing when the sun came up and eats the wood inside
--- its reach, one tree at a time, on a clock slow enough to watch. Its reach
--- grows all day, which is what makes *when* you deal with it the decision: a
--- fresh one is a hundred pixels of trouble and five shoves, an ignored one is
--- three hundred pixels of trouble that has already seeded a second scar. And at
--- dusk the Director uses it as a way in, so a scar you left standing is a night
--- that does not begin at the shore -- it begins in your wood, with you at the
--- other end of the island.
---
--- The cost of clearing it is travel and attention, not danger: it is the thing
--- you go and do instead of mining, planting, or pushing the standing order out.
function Enemy:update_scar(dt)
  local w = self.world
  local D = self.def
  self.creep = math.min(D.creepMax, (self.creep or D.creepStart) + D.creepGrow * dt)
  local frac = U.saturate((self.creep - D.creepStart) / math.max(1, D.creepMax - D.creepStart))
  self.pulse = (self.pulse or 0) + dt * 1.3
  if self.rng:chance(dt * 3) then
    local a, r = self.rng:angle(), self.rng:range(0, self.creep * 0.8)
    VFX.emit("blight_spore", self.x + math.cos(a) * r, self.y + math.sin(a) * r * 0.55)
  end

  -- rot: teeth in exactly one tree at a time, with a gap between meals that
  -- shortens as the thing grows into the grove
  local t = self.chewing
  if t and (not t.alive or U.dist(self.x, self.y, t.x, t.y) > self.creep + t.radius) then
    self:release()
    t = nil
  end
  if not t then
    self.rotT = (self.rotT or D.rotEvery) - dt
    if self.rotT <= 0 then
      local pick = w and w:nearestTree(self.x, self.y, self.creep)
      self.rotT = D.rotEvery * (1 - D.rotRamp * frac)
      if pick then
        self:engage(pick)
        Audio.play("chomp", { pitch = 0.65, volume = 0.55, x = pick.x, y = pick.y })
      else
        self.rotT = D.rotEvery * 0.5    -- nothing in reach; try again sooner
      end
    end
  end

  -- and when it has finished growing, it seeds the next one
  if frac >= 1 then
    self.spreadT = (self.spreadT or D.spreadEvery) - dt
    if self.spreadT <= 0 then
      self.spreadT = D.spreadEvery
      if w and Enemy.countOf(w, "scar") < D.maxAlive then
        local a = self.rng:angle()
        local nx = self.x + math.cos(a) * self.creep * 0.95
        local ny = self.y + math.sin(a) * self.creep * 0.95
        w:spawnEnemyAt(nx, ny, "scar")
        Audio.play("rift_open", { pitch = 1.3, volume = 0.55, x = nx, y = ny })
        Signal.emit("blight:rooted", self, true)
      end
    end
  end
end

--- How many of a type are standing. Used for the caps that stop the two
--- behaviours that reproduce -- Scars and Maws -- from running away with a run.
function Enemy.countOf(world, kind)
  local n = 0
  local list = world and world.enemies
  if not list then return 0 end
  for i = 1, #list do
    local e = list[i]
    if e.alive and not e.fleeing and e.type == kind then n = n + 1 end
  end
  return n
end

------------------------------------------------------------------------ combat
--- Shoves are resisted by armour; that is what makes Bulwarks a puzzle.
function Enemy:shove(dx, dy, force, damage, stun)
  if self.def.armoured then
    -- Anything dug into the ground is closed by working at it rather than by
    -- being killed: the Maw and the Scar both. This used to test `self.type ==
    -- "maw"` by name, which meant a second dug-in behaviour had no way to exist.
    if self.def.shovesToClose then
      self.shovesLeft = (self.shovesLeft or self.def.shovesToClose) - 1
      VFX.emit("impact", self.x, self.y, { power = 1 })
      Audio.play("shove_hit", { pitch = 0.75, x = self.x, y = self.y })
      if self.shovesLeft <= 0 then self:damage(9999, dx, dy) end
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

--- Every point of damage the Blight takes passes through here, because two
--- things now change what a hit is worth: a Warden's field, and the moment a
--- Siphon has its tendril down. Both are meant to be legible as "hit this one
--- now" or "hit that one first" rather than as arithmetic, so both flash.
function Enemy:damage(n, sx, sy, opts)
  n = n or 1
  if self.feeding and self.def.feedVuln then n = n * self.def.feedVuln end
  -- Armour was only ever applied inside `Enemy:shove`; a seed-dart calls
  -- `World:hitEnemyAt` which calls `damage` directly, so the whole armour system
  -- was invisible to the one thing that fires all night. It stayed invisible for
  -- the Bulwark, whose numbers are somebody else's balance point, but the two
  -- behaviours that are *dug in* have to resist it or a Sentry sited nearby
  -- deletes them in three seconds and the decision they exist to pose -- go and
  -- deal with this, or leave it and pay at dusk -- never gets asked. The floor
  -- of one point mirrors the shove path: a Sentry is always a legitimate answer
  -- to a Maw or a Scar, just a slow one, and walking over is always the fast one.
  if self.def.shovesToClose and self.def.armour then
    n = math.max(1, n * (1 - self.def.armour))
  end
  local ward = self.wardedT > 0 and self.warden or nil
  if ward and ward.alive and self.type ~= "warden" then
    n = n * (1 - ward.def.wardCut)
    ward.shielded = 0.35
    VFX.emit("hit_spark", self.x, self.y, { color = P.ramp.blight[4] })
  end
  return Enemy.super.damage(self, n, sx, sy, opts)
end

function Enemy:onDamage(n, sx, sy)
  Audio.play("enemy_hurt", { pitch = 1 + (self.rng:next() - .5) * .2, x = self.x, y = self.y })
  VFX.emit("hit_spark", self.x, self.y, { dx = self.x - (sx or self.x), dy = self.y - (sy or self.y) })
end

function Enemy:onDeath()
  self.alive = false
  -- One release, through the one handle. `onDeath` used to stop the chew on
  -- `chewing` *and* on `target`, which on the ordinary frame where they were the
  -- same tree took a second registration off it -- somebody else's.
  self:release()
  self.feeding = false
  local w = self.world
  if self.type == "scar" then
    -- Clearing one pays, because the day has to be worth spending on something
    -- other than cobalt for the choice between them to be a choice.
    Audio.play("rift_close", { x = self.x, y = self.y })
    VFX.emit("heal_ground", self.x, self.y, { power = 1.2 })
    if w then
      if self.def.bounty > 0 then w:addCobalt(self.def.bounty, self.x, self.y) end
      if w.terrain and w.terrain.healAt then w.terrain:healAt(self.x, self.y, self.creep or 120, 0.5) end
    end
    Signal.emit("blight:cleared", self)
  end
  VFX.emit("blight_death", self.x, self.y, { power = self.radius / 14 })
  Audio.play("enemy_die", { x = self.x, y = self.y })
  J.shake(0.06)
  if w and w.chips and w.chips:has("thornburst") then
    w:spawnSporeCloud(self.x, self.y)
  end
  Signal.emit("enemy:killed", self)
end

--- Dawn. Everything walks back off the island -- which is exactly why half of
--- every run had nothing in it. The Blight leaves something behind now.
---
--- A Maw is a hole in the ground and does not walk anywhere; it goes dormant
--- where it is. And anything that still had its teeth in the wood when the sun
--- came up digs in where it stood and becomes a Scar, up to a quota the Director
--- authors per cycle -- so a night you cleared leaves you nothing to do in the
--- morning and a night that overran you leaves you a morning's work.
---
--- The extraction is the one exception: when the rig lands the ground troops
--- withdraw, all of them, because that fight is between the workforce and the
--- thing that came for the air and nothing else may be standing in it.
function Enemy:flee()
  if self.fleeing then return end
  local w = self.world
  local final = w and (w.phase == "extraction" or w.phase == "ending")
  if not final then
    if self.def.holdsGround or self.type == "scar" then return end
    local held = (self.chewing ~= nil) or self.feeding
    if held and w and w.director and w.director.claimScar and w.director:claimScar() then
      self:release()
      local s = w:spawnEnemyAt(self.x, self.y, "scar")
      Audio.play("rift_open", { pitch = 0.85, volume = 0.8, x = self.x, y = self.y })
      VFX.emit("rift_open", self.x, self.y, { power = 0.7 })
      Signal.emit("blight:rooted", s, false)
    end
  end
  self.fleeing = true
  self.fadeT = 1
  self:release()
  self.feeding = false
  local cx, cy = w and w.centerX or self.x, w and w.centerY or self.y
  self.fleeX, self.fleeY = U.norm(self.x - cx, self.y - cy)
end

------------------------------------------------------------------------- render
local function bl(t) return P.shade(P.ramp.blight, t) end

-- What the Blight's own light looks like, per behaviour. The bodies are
-- deliberately near-neutral -- the palette calls the blight a bruise rather
-- than a sweet -- and at night that reads as correct and plays as invisible:
-- a chomper walking into a lamp-lit clearing was a dark smudge on dark ground.
-- One soft glow at the eyes, at night only, in the colour that thing already
-- has on its face. It costs nothing in daylight and it never repaints the body.
local LIGHT = TU.enemy.light

local EYE = {
  chomper = P.shade(P.ramp.blight, 3.6),
  skitter = P.acid,
  spitter = P.acid,
  siphon  = P.shade(P.ramp.blight, 3.4),
  bulwark = P.shade(P.ramp.blight, 3.2),
  warden  = P.ramp.blight[4],
  maw     = P.shade(P.ramp.rift, 3),
  scar    = P.shade(P.ramp.rift, 3.2),
}

--- The Blight puts light back into the scene.
---
--- Everything else on the island already did -- bots, the rig, cobalt, the
--- player -- and the lighting buffer the scene is multiplied by is the only
--- thing keeping anything visible after dusk. Enemies had no emitLight at all,
--- so at night the thing attacking you was a dark shape on dark ground and the
--- minimap ended up doing all the work.
---
--- All of it is red. Per-type colours were prettier and told you nothing you
--- could act on at a glance; one hostile colour, against the crew's blue and
--- the player's yellow, means a night reads as three kinds of light and you
--- never have to look anything up. See P.lightHostile.
function Enemy:emitLight(Lighting)
  if not self.alive or self.fleeing then return end
  local T = TU.enemy[self.type] or {}
  local r = self.radius or 14
  local c = P.lightHostile
  local dark = U.saturate(1 - (DayNight.ambientStrength or 1))
  -- daylight needs none of this, and paying for it in the day is 40 lights the
  -- lighting pass would rather spend on the forest
  if dark < 0.12 then return end
  local oy = T.float and -22 or -r * 0.25
  local k = LIGHT.gain * (0.35 + 0.65 * dark)
  local flick = 0.85 + 0.15 * math.sin(self.age * 3.1 + (self.seed or 0))
  -- A Maw and a Scar are landmarks: they do not move, they deny ground, and
  -- what you need at night is to know where they are from across the island.
  local wide = (self.type == "maw" or self.type == "scar") and LIGHT.rooted or 1
  Lighting.addLight(self.x, self.y + oy, r * LIGHT.radius * wide, c,
                    k * flick, { flicker = 0.05 })
  -- a hot little core so the body reads as lit rather than as a glow behind it
  Lighting.addLight(self.x, self.y + oy, r * LIGHT.core, c, k * LIGHT.coreGain, nil)
end

function Enemy:drawShadow()
  -- A Scar's reach is the whole of its threat and it is invisible unless it is
  -- drawn, so it goes down here with the other ground marks, before any art:
  -- a stain the size of the ground it has taken and a rule around the edge of
  -- it, so "is that tree inside it" is a question the player can answer.
  if self.type == "scar" then
    local cr = self.creep or self.def.creepStart
    local p = 0.94 + math.sin(self.pulse or 0) * 0.06
    Draw.softShadow(self.x, self.y, cr * p, cr * p * 0.62, 0.55,
                    P.shade(P.ramp.blight, 1.2))
    Draw.setColor(P.ramp.rift[3], 0.42 + 0.12 * math.sin((self.pulse or 0) * 1.7))
    Draw.dashedCircle(self.x, self.y, cr * p, 11, 8, (self.age or 0) * 12, 3)
    Draw.setColor(P.ramp.rift[4], 0.14)
    Draw.dashedCircle(self.x, self.y, cr * p * 0.72, 7, 12, -(self.age or 0) * 8, 2)
    Draw.softShadow(self.x, self.y + 2, self.radius * 1.15, self.radius * 0.5, 0.42)
    return
  end
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

  -- its own eyeshine, once the sun is off the island
  local dark = U.saturate(1 - (DayNight.ambientStrength or 1))
  if dark > 0.2 and not self.fleeing then
    local c = EYE[self.type] or EYE.chomper
    local oy = self.def.float and -22 or -r * 0.25
    Draw.glow(self.x, self.y + oy, r * (1.0 + dark * 0.5),
              c, (0.20 + 0.30 * dark) * a * (0.85 + 0.15 * math.sin(self.age * 3.1)), 2)
  end

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

--- The pips over anything that is closed by working at it, rather than killed.
--- The Maw has had them since it existed; the Scar needs the same readout for
--- the same reason, so one function draws both and the player learns it once.
function Enemy:drawClosePips(r, a)
  local n = self.def.shovesToClose
  if not n then return end
  local w = r * 1.8
  for i = 1, n do
    local lit = i <= (self.shovesLeft or 0)
    Draw.setColor(lit and P.ramp.rift[4] or P.inkFaint, (lit and 0.9 or 0.2) * a)
    love.graphics.circle("fill", -w * 0.5 + (i - 1) * (w / math.max(1, n - 1)),
                         -r * 1.7, r * 0.1)
  end
end

function Enemy:body_maw(r, a)
  local p = 0.85 + math.sin(self.pulse or 0) * 0.15
  -- Shut in daylight: the throat closes to a seam and the glow goes out of it,
  -- so a dormant Maw reads as a thing that is waiting rather than a thing that
  -- is broken.
  local open = self.dormant and 0.34 or 1
  Draw.setColor(P.shade(P.ramp.rift, 1.4), a)
  Draw.blob(0, 0, r * 1.25 * p, 12, 31, 0.22, 0.7)
  Draw.setColor(P.black, a)
  Draw.blob(0, 0, r * 0.8 * p * open, 10, 33, 0.24, 0.7)
  Draw.setColor(P.shade(P.ramp.rift, 3.6), a * 0.9)
  Draw.ring(0, 0, r * 1.1 * p, 3, 0, U.TAU, P.shade(P.ramp.rift, 3.6), 0.8)
  Draw.glow(0, 0, r * 3.2, P.ramp.rift[3], 0.5 * a * open)
  self:drawClosePips(r, a)
end

function Enemy:body_warden(r, a)
  local br = 0.9 + math.sin(self.hoverT * 0.8) * 0.1
  -- The field, drawn as the field: whoever is inside this circle is the reason
  -- your shove stopped working, and that has to be visible from across a grove.
  local wr = self.def.wardRadius
  Draw.setColor(P.ramp.blight[4], (0.16 + (self.shielded or 0)) * a)
  Draw.dashedCircle(0, 22, wr, 16, 22, self.age * 26, 2)
  Draw.glow(0, 0, r * 3.4, P.ramp.blight[3], (0.30 + (self.shielded or 0) * 0.8) * a)

  Draw.setColor(bl(1.5), a * 0.92)
  Draw.blob(0, 0, r * 1.1 * br, 11, (self.serial or 13) + 17, 0.14, 1.0)
  -- a slack cage of ribs around a lit centre; it is a lamp, not an animal
  Draw.setColor(bl(0.9), a * 0.8)
  love.graphics.setLineWidth(2)
  for i = 0, 4 do
    local ang = i * U.TAU / 5 + self.age * 0.5
    love.graphics.line(math.cos(ang) * r * 0.3, math.sin(ang) * r * 0.3 - r * 0.4,
                       math.cos(ang) * r * 1.15, math.sin(ang) * r * 0.85 + r * 0.5)
  end
  love.graphics.setLineWidth(1)
  Draw.setColor(P.ramp.blight[4], a * (0.75 + 0.25 * math.sin(self.age * 2.3)))
  love.graphics.circle("fill", 0, 0, r * 0.34 * br)
end

function Enemy:body_scar(r, a)
  local p = 0.9 + math.sin(self.pulse or 0) * 0.1
  local frac = U.saturate(((self.creep or self.def.creepStart) - self.def.creepStart)
                          / math.max(1, self.def.creepMax - self.def.creepStart))
  -- A low crust of matter with a lit fissure through it. It grows with the
  -- creep, so how far gone a scar is reads off its silhouette and not only off
  -- the ring on the ground.
  local s = 1 + frac * 0.45
  Draw.setColor(bl(1.0), a)
  Draw.blob(0, r * 0.2, r * 1.15 * s, 11, (self.serial or 17) + 23, 0.26, 0.55)
  Draw.setColor(P.shade(P.ramp.ash, 2.0), a * 0.85)
  Draw.blob(0, r * 0.1, r * 0.82 * s, 9, (self.serial or 17) + 29, 0.3, 0.6)
  Draw.setColor(P.shade(P.ramp.rift, 1.2), a)
  Draw.blob(0, 0, r * 0.5 * s * p, 8, 37, 0.34, 0.5)
  Draw.setColor(P.ramp.rift[3], a * (0.55 + 0.25 * math.sin((self.pulse or 0) * 2.1)))
  Draw.capsule("fill", -r * 0.42 * s, 0, r * 0.42 * s, -r * 0.1, r * 0.09 * p)
  Draw.glow(0, 0, r * 2.6 * s, P.ramp.rift[3], 0.30 * a)
  -- and the tendril it has in whatever it is eating, so the tree it is taking
  -- is never a guess
  local t = self.chewing
  if t and t.alive then
    Draw.setColor(P.acid, a * 0.45)
    love.graphics.setLineWidth(2)
    love.graphics.line(0, 0, t.x - self.x, t.y - self.y)
    love.graphics.setLineWidth(1)
  end
  self:drawClosePips(r, a)
end

function Enemy:emitLight(Lighting)
  if self.type == "maw" then
    Lighting.addLight(self.x, self.y, 260, P.ramp.rift[3],
                      self.dormant and 0.35 or 1.1, { flicker = 0.12 })
  elseif self.type == "scar" then
    Lighting.addLight(self.x, self.y, (self.creep or 120) * 0.8, P.ramp.rift[3], 0.55,
                      { flicker = 0.09 })
  elseif self.type == "warden" then
    Lighting.addLight(self.x, self.y - 22, self.def.wardRadius * 0.8, P.ramp.blight[4], 0.7)
  elseif self.type == "siphon" then
    Lighting.addLight(self.x, self.y - 22, 120, P.ramp.blight[4], 0.5)
  elseif self.type == "spitter" then
    Lighting.addLight(self.x, self.y, 70, P.acid, 0.3)
  end
end

return Enemy
