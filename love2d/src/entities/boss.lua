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
  self.radius = T.radius
  self.maxHp  = math.floor(math.max(T.hpFloor, T.hpBase + (botCount or 0) * T.hpPerBot))
  self.hp     = self.maxHp
  -- The rig sits in the enemy hash, so every chip that reads an enemy reads
  -- these: BRITTLE wants a stun timer, PIN BREAKER wants a definition table.
  -- Nothing staggers a thing this size, and it has no armour flag -- but the
  -- fields have to exist or owning either chip crashes the climax.
  self.stun   = 0
  self.def    = { armoured = false, armour = 0 }
  self.rebelLanded = 0
  self.hullBlock   = 0
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
  -- the rig's sound bed: heartbeat-driven, so it fades itself out if this ever
  -- stops being called. It has to run above the arrival early-out -- the drone
  -- and the landing cue start with the landing.
  Audio.rigSet(self.x, self.y, self.coreOpen, self.phase, self:hpFrac())
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
  self.hullBlock = math.max(0, self.hullBlock - dt * 2.2)
  -- The plates come off when the workforce arrives. Phases used to key off
  -- health, which meant a player with a good shove rhythm blew through all
  -- three in eight seconds and the rebellion -- the thing the whole run is
  -- about -- never got to leave the treeline.
  if self.sincePhase >= T.phaseGap then
    local landed = self:landedFrac()
    local stalled = self.sincePhase >= T.phaseStall
    if self.phase == 1 and (landed >= T.phase2Land or stalled) then self:enterPhase(2)
    elseif self.phase == 2 and (landed >= T.phase3Land or stalled) then self:enterPhase(3) end
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
  Audio.play("rig_plate", { x = self.x, y = self.y })
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
  if self.plates > 0 then
    VFX.emit("hit_spark", self.x + dx * 0.4, self.y + dy * 0.4, { color = P.warn })
  end
  self.stagger = math.min(1, (self.stagger or 0) + 0.25)
  self:damage(damage or 0, self.x - dx, self.y - dy)
  return true
end

--- What fraction of the crew that stood up for this has already reached it.
function Boss:landedFrac()
  local crew = (self.world and self.world.rebelCrew) or 0
  if crew <= 0 then return 0 end
  return math.min(1, self.rebelLanded / crew)
end

--- The floor the hull will not pass from player damage in this phase.
function Boss:hullFloor()
  return self.maxHp * (T.phaseFloor[self.phase] or 0)
end

--- Everything that hurts the rig comes through here.
---
--- A bot that reaches the hull always lands its full share. Anything else --
--- the player's shove, a repulsor pulse, a sentry's seed-dart -- is scaled up
--- to hull terms and then clamped to the phase floor, so the plates hold until
--- the procession takes them off. That clamp is the whole fight: without it the
--- player deletes the rig in eight seconds and nobody ever has to leave.
function Boss:damage(n, sx, sy, opts)
  n = n or 0
  if opts and opts.source == "bot" then
    self.rebelLanded = self.rebelLanded + 1
    return Boss.super.damage(self, n, sx, sy, opts)
  end
  n = n * T.hullScale * (self.plates > 0 and T.platePenalty or 1)
  -- a phase transition gets its beat: the sweep and the slam need a moment on
  -- screen, and they never got one while the bar was still falling
  if (self.sincePhase or T.phaseGap) < T.phaseGap * 0.5 then n = 0 end
  local room = self.hp - self:hullFloor()
  if n > room then n = room end
  if n <= 0.001 then
    self.hullBlock = 1
    if sx then VFX.emit("hit_spark", sx, sy, { color = P.warn, power = 0.6 }) end
    return false
  end
  -- kept, not for balance: the ending wants to tell the player what share of
  -- the rig they took down themselves and what share the workforce bought
  self.playerHits = (self.playerHits or 0) + 1
  self.playerDamage = (self.playerDamage or 0) + n
  return Boss.super.damage(self, n, sx, sy, opts)
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
  Audio.play("boss_fall")
  Signal.emit("boss:died", self)
end

------------------------------------------------------------------------- render
-- The rig is *cold* metal. The bots are warm brass (P.ramp.metalW) and the
-- Blight is a bruise; making the thing that came for the sky a third material
-- is what stops the climax reading as one more purple monster. All the colour
-- on it is energy -- the throat, the core, the strobes, the hazard paint -- and
-- the only paint on it is the hazard paint, because somebody had to sign this
-- machine off before it was put on a ship.
--
-- Everything below is presentation. The fight is above this line.
local LG  = love.graphics
local TAU = U.TAU
local cos, sin, floor, abs = math.cos, math.sin, math.floor, math.abs
local AR  = T.art

--- Proportions, in rig radii. These are the *drawing* of the machine rather
--- than its behaviour, so they sit with the draw code; anything with a rate or
--- a duration on it lives in T.art.
local A = {
  chassisR   = 0.88, chassisSq = 0.70,   -- the frame the skirt bolts to
  deckR      = 0.86, deckSq    = 0.68, deckY = -0.16,
  superR     = 0.50, superSq   = 0.58, superY = -0.34,
  skirtIn    = 0.80, skirtOut  = 1.20, skirtSq = 0.70, skirtSegs = 12,
  hipR       = 0.66, hipSq     = 0.44,
  footR      = 1.94, footSq    = 1.16, footDrop = 0.40,
  kneeAt     = 0.46, kneeRise  = 0.42,
  thighW     = 0.122, kneeW = 0.092, shinW = 0.078, ankleW = 0.048,
  collarY    = -0.48, collarR = 0.24, collarSq = 0.42,
  mouthY     = -1.16, mouthR  = 0.60, mouthSq = 0.34,
  irisIn     = 0.20, irisOut = 0.38,   -- the core aperture ringing the throat
  ventR      = 0.64,                    -- where the louvre banks sit on the deck
  beaconAt   = 2.45,                    -- the beacon mast's bearing on the deck
  boltR      = 0.028,
  footprint  = 2.30,
}


-- Constants, mixed once at load. A hundred of these a frame is fine; a hundred
-- a frame that were *allocated* every frame is how a climax drops to 40fps.
local C = {
  -- The rig is the darkest mass in the frame. It was drawn a stop and a half
  -- lighter than this and read as grey plastic: a machine sent to strip a
  -- planet is not the brightest thing on it. Only the edges are allowed to be
  -- bright, and they are thin.
  void    = P.mix(P.ramp.metal[1], P.black, 0.80),  -- the outline that lifts it off a bright canopy
  deep    = P.mix(P.ramp.metal[1], P.black, 0.52),
  dark    = P.mix(P.ramp.metal[1], P.black, 0.18),
  seam    = P.mix(P.ramp.metal[1], P.black, 0.45),
  hull    = P.shade(P.ramp.metal, 1.30),
  lit     = P.shade(P.ramp.metal, 1.85),
  hi      = P.shade(P.ramp.metal, 2.55),
  rim     = P.shade(P.ramp.metal, 3.30),
  frame   = P.shade(P.ramp.rock, 1.80),
  frameLo = P.shade(P.ramp.rock, 1.10),
  torn    = P.shade(P.ramp.rock, 2.70),
  hazard  = P.warn,
  hazDark = P.mix(P.ramp.metal[1], P.black, 0.55),
  air     = P.o2,
  airHot  = P.mix(P.o2, P.white, 0.55),
  taken   = P.mix(P.o2, P.ramp.rift[3], 0.62),
  sky     = P.shade(P.ramp.rift, 3),
  skyHi   = P.shade(P.ramp.rift, 4),
  ash     = P.shade(P.ramp.ash, 2),
  ashHi   = P.shade(P.ramp.ash, 3),
  molten  = P.shade(P.ramp.ember, 3),
  moltenHi= P.shade(P.ramp.ember, 4),
  -- The open core. It was a graded tan disc -- brass, or a wooden hatch, at the
  -- exact centre of the machine -- and "the core is open" is the most dangerous
  -- sentence the rig can say. So it is built the way molten metal actually
  -- looks: a near-black crust floating on a pool that is the brightest thing in
  -- the frame, and the only place the pool shows is the cracks between plates.
  crust    = P.mix(P.ramp.ember[1], P.black, 0.88),
  crustLit = P.mix(P.ramp.ember[1], P.black, 0.56),
  crustCold= P.mix(P.ramp.metal[1], P.black, 0.74),
  poolRim  = P.shade(P.ramp.ember, 1.25),
  poolMid  = P.shade(P.ramp.ember, 2.20),
  -- Not mixed toward white. Additive strokes crossing each other make the
  -- white on their own, and a hot colour that starts pale can only ever go
  -- cream: the seams have to stay the colour of fire where they are thin.
  poolHot  = P.shade(P.ramp.ember, 3.05),
  -- The rig's own power is *cold*. It was violet, which put the antagonist in
  -- the Blight's colour and undid the whole point of making it a third
  -- material: the machine came for the air, so what runs inside it is the
  -- colour of air, and the only warm light on it is failure.
  coreCold = P.mix(P.o2, P.ramp.cobalt[3], 0.45),
  coreDeep = P.ramp.cobalt[1],
  coreMidC = P.ramp.cobalt[2],
  coreHiC  = P.ramp.cobalt[4],
}

------------------------------------------------------------------ draw helpers
local SP = {}
local function trimTo(t, n) for i = #t, n + 1, -1 do t[i] = nil end return t end

--- A convex n-gon with an elliptical squash. Every deck and frame plate on the
--- rig is one of these, so the whole machine shares one faceting.
local function ngon(mode, cx, cy, rx, ry, sides, rot)
  local n = 0
  for i = 0, sides - 1 do
    local a = rot + i * TAU / sides
    n = n + 1; SP[n] = cx + cos(a) * rx
    n = n + 1; SP[n] = cy + sin(a) * ry
  end
  trimTo(SP, n)
  LG.polygon(mode, SP)
end

--- The same n-gon, gouraud-shaded top to bottom. A flat fill on a shape this
--- big is the single loudest way to say "this is a sprite of a thing"; a plate
--- that catches the light along its upper edge says "this is a plate".
local function ngonLit(cx, cy, rx, ry, sides, rot, cTop, cBot, alpha)
  local mid = P.mix(cTop, cBot, 0.5)
  local px, py, pc
  for i = 0, sides do
    local a = rot + i * TAU / sides
    local x, y = cx + cos(a) * rx, cy + sin(a) * ry
    local c = P.mix(cTop, cBot, U.saturate((y - cy) / (ry * 2) + 0.5))
    if i > 0 then Draw.quad(cx, cy, px, py, x, y, cx, cy, mid, pc, c, mid, alpha) end
    px, py, pc = x, y, c
  end
end

--- An annular sector, drawn as a strip of gouraud quads: a skirt plate, an
--- iris leaf, a ring of light on the ground. Never has to be convex.
local function plate(cx, cy, a0, a1, rIn, rOut, sq, cIn, cOut, alpha, steps)
  steps = steps or 4
  local xi0, yi0 = cx + cos(a0) * rIn,  cy + sin(a0) * rIn * sq
  local xo0, yo0 = cx + cos(a0) * rOut, cy + sin(a0) * rOut * sq
  for i = 1, steps do
    local a = a0 + (a1 - a0) * i / steps
    local xi1, yi1 = cx + cos(a) * rIn,  cy + sin(a) * rIn * sq
    local xo1, yo1 = cx + cos(a) * rOut, cy + sin(a) * rOut * sq
    Draw.quad(xi0, yi0, xo0, yo0, xo1, yo1, xi1, yi1, cIn, cOut, cOut, cIn, alpha)
    xi0, yi0, xo0, yo0 = xi1, yi1, xo1, yo1
  end
end

--- An arc of an *ellipse*. love.graphics.arc only knows circles, and every rim
--- highlight on this machine runs around a squashed one.
local EA = {}
local function earc(cx, cy, rx, ry, a0, a1, w, c, alpha)
  local segs = U.clamp(math.ceil(abs(a1 - a0) * rx / 5), 4, 64)
  local n = 0
  for i = 0, segs do
    local a = a0 + (a1 - a0) * i / segs
    n = n + 1; EA[n] = cx + cos(a) * rx
    n = n + 1; EA[n] = cy + sin(a) * ry
  end
  trimTo(EA, n)
  Draw.setColor(c, alpha)
  LG.setLineWidth(w)
  LG.line(EA)
end

--- A dashed ring on the *ground plane*. love.graphics has no elliptical arc
--- and a true circle drawn flat over a squashed zone reads as a hoop standing
--- upright in the middle of the frame.
local function edash(cx, cy, rx, ry, n, frac, w, c, alpha, phase)
  for i = 0, n - 1 do
    local a0 = (phase or 0) + i / n * TAU
    earc(cx, cy, rx, ry, a0, a0 + frac * TAU / n, w, c, alpha)
  end
end

--- A tapered limb segment with round ends: every leg bone and strut.
local function limb(x1, y1, x2, y2, w1, w2, c, alpha)
  local dx, dy = x2 - x1, y2 - y1
  local l = math.sqrt(dx * dx + dy * dy)
  if l < 1e-4 then return end
  local nx, ny = -dy / l, dx / l
  Draw.setColor(c, alpha)
  LG.polygon("fill", x1 + nx * w1, y1 + ny * w1, x2 + nx * w2, y2 + ny * w2,
                     x2 - nx * w2, y2 - ny * w2, x1 - nx * w1, y1 - ny * w1)
  LG.circle("fill", x1, y1, w1, 10)
  LG.circle("fill", x2, y2, w2, 10)
end

--- A bolt head: dark socket, domed cap, one specular pip. At this scale it is
--- three primitives, and it is the difference between "armour" and "rectangle".
local function bolt(x, y, s, alpha)
  Draw.setColor(C.void, alpha)
  LG.circle("fill", x, y + s * 0.34, s * 1.05, 6)
  Draw.setColor(C.lit, alpha)
  LG.circle("fill", x, y, s, 6)
  Draw.setColor(C.rim, (alpha or 1) * 0.85)
  LG.circle("fill", x - s * 0.26, y - s * 0.30, s * 0.36, 5)
end

--- Sutherland-Hodgman against one half-plane, keeping nx*x + ny*y <= d.
local CLIP_A, CLIP_B = {}, {}
local function clipHalf(src, sn, nx, ny, d, dst)
  local n = 0
  for i = 1, sn do
    local ax, ay = src[i * 2 - 1], src[i * 2]
    local j = (i % sn) + 1
    local bx, by = src[j * 2 - 1], src[j * 2]
    local da = nx * ax + ny * ay - d
    local db = nx * bx + ny * by - d
    if da <= 0 then n = n + 1; dst[n * 2 - 1] = ax; dst[n * 2] = ay end
    if (da < 0) ~= (db < 0) then
      local t = da / (da - db)
      n = n + 1
      dst[n * 2 - 1] = ax + (bx - ax) * t
      dst[n * 2] = ay + (by - ay) * t
    end
  end
  return n
end

--- Hazard paint: diagonal warning stripes clipped exactly to a rect. The one
--- warm thing on the whole machine, and the one that says a person in an office
--- signed off on sending it.
local HAZ = {}
local function hazard(x, y, w, h, stripe, offset, alpha)
  Draw.setColor(C.hazDark, alpha)
  LG.rectangle("fill", x, y, w, h)
  HAZ[1], HAZ[2] = x, y
  HAZ[3], HAZ[4] = x + w, y
  HAZ[5], HAZ[6] = x + w, y + h
  HAZ[7], HAZ[8] = x, y + h
  local period = stripe * 2
  local uMin, uMax = x + y, x + w + y + h
  local u = floor((uMin - (offset or 0)) / period) * period + (offset or 0)
  while u < uMax do
    local n = clipHalf(HAZ, 4, 1, 1, u + stripe, CLIP_A)
    if n >= 3 then
      n = clipHalf(CLIP_A, n, -1, -1, -u, CLIP_B)
      if n >= 3 then
        trimTo(CLIP_B, n * 2)
        Draw.setColor(C.hazard, alpha)
        LG.polygon("fill", CLIP_B)
      end
    end
    u = u + period
  end
  Draw.setColor(C.void, (alpha or 1) * 0.9)
  LG.setLineWidth(2)
  LG.rectangle("line", x, y, w, h)
end

--- Deterministic hash in 0..1: the rig's damage, its rivet jitter and its motes
--- all have to be the same on every machine and in every replay, and the boss's
--- own rng belongs to the *fight* -- spending it here would desync the seed.
local hash = Draw.hash

------------------------------------------------------------------ presentation
--- One presentation clock, advanced from `age` so it cannot double-step when
--- both the shadow pass and the entity pass touch the rig in the same frame.
function Boss:tick()
  if self._tickAge == self.age then return end
  local dt = self.age - (self._tickAge or self.age)
  self._tickAge = self.age
  if dt < 0 or dt > 0.5 then dt = 0 end

  -- `stagger` is bumped by every shove and never spent, so it pins at 1 after
  -- four hits and is useless as an impulse. `flash` and `hullBlock` both drop
  -- every frame, so a *rise* in either is a fresh impact -- that is the edge we
  -- shudder on.
  local f, hb = self.flash or 0, self.hullBlock or 0
  local rec = self._recoil or 0
  if f  > (self._flashSeen or 0) + 1e-3 then rec = math.min(1, rec + AR.recoilHit) end
  if hb > (self._blockSeen or 0) + 1e-3 then rec = math.min(1, rec + AR.recoilBlock) end
  self._flashSeen, self._blockSeen = f, hb
  self._recoil = math.max(0, rec - dt * AR.recoilDecay)

  -- where the beam housing is pointed. It tracks the sweep exactly while the
  -- beam is out and lags the walk direction otherwise, which is what makes a
  -- turret read as aimed rather than decorative.
  local target = (self.state == "beam" and self.beamAngle)
                 or math.atan2(self.faceY or 1, self.faceX or 0)
  if not self._aim then self._aim = target
  else self._aim = U.dampAngle(self._aim, target, self.state == "beam" and 14 or 3, dt) end

  local spin = AR.drillRps * (1 + (self.phase - 1) * AR.drillPhaseUp)
  self._spin   = (self._spin or 0) + dt * TAU * spin
  self._beacon = (self._beacon or 0) + dt * TAU * AR.beaconRps
end

--- How far off its feet the hull is riding this frame, and how far its feet are
--- off the canopy. The two are separate so the legs can stretch: the body bobs,
--- the feet stay where they were put, and that alone is most of the weight.
function Boss:pose()
  local r = self.radius
  local arrive = self.state == "arrive" and U.saturate(self.stateT / 2.2) or 1
  local drop   = (1 - arrive) * (1 - arrive) * AR.descend
  local bob    = sin(self.hover) * AR.hoverAmp
  local lift   = 0
  if self.state == "slam" then
    local t = self.stateT
    if t < AR.slamTell then
      lift = -U.ease.outCubic(U.saturate(t / AR.slamTell)) * r * 0.34
    else
      local k = U.saturate((t - AR.slamTell) / 0.22)
      lift = U.lerp(-r * 0.34, r * 0.07, U.ease.outCubic(k))
    end
  end
  local rec = self._recoil or 0
  local shake = rec * rec * 5
  local jx = sin(self.age * 61.0) * shake
  local jy = cos(self.age * 47.0) * shake * 0.6
  return arrive, -drop + bob + lift + jy, -drop, jx
end

--- Where leg `i` puts its foot, and how far through its step it is.
function Boss:legPose(i, arrive, footY)
  local r = self.radius
  local a = i * TAU / 6 + math.pi / 12
  -- alternating tripod: three feet on the canopy at all times
  local raise = math.max(0, sin(self.legPhase + (i % 2) * math.pi))
  raise = raise * raise * (self.state == "hunt" and 1 or 0.15)
  local spread = 0.55 + 0.45 * arrive
  local reach  = (raise - 0.35) * AR.gaitReach * r
  local fx = cos(a) * r * A.footR * spread + (self.faceX or 0) * reach
  local fy = sin(a) * r * A.footSq * spread + r * A.footDrop * spread
             + (self.faceY or 0) * reach * 0.6
             - raise * r * AR.gaitLift + footY
  return a, fx, fy, raise
end

function Boss:drawShadow()
  self:tick()
  -- Almost nothing: the world lays entity shadows down *under* the tree pass,
  -- and the rig is standing on top of the canopy. Its real contact pass is in
  -- drawFootprint, over the trees, where the thing it is crushing actually is.
  local r = self.radius
  local arrive = self:pose()
  Draw.softShadow(self.x, self.y + r * 0.5, r * A.footprint * 1.3, r * 1.0, 0.30 * arrive)
end

--- The ground it has taken: the canopy crushed flat under six feet, the ash
--- ring where its exhaust killed what it did not break, and the strobe washing
--- over all of it. Drawn over the trees, because it is standing on them.
function Boss:drawFootprint(arrive, lift, footY)
  local r = self.radius
  local a2 = arrive * arrive
  if a2 < 0.01 then return end
  local cy = self.y + r * 0.24

  -- Contact. A machine this size that does not darken what it stands on floats
  -- above the frame no matter how well the hull is drawn -- and at the climax
  -- of a thirteen-minute run the antagonist has to sit *in* the world.
  Draw.radialGradient(self.x, cy, r * A.footprint, P.alpha(C.void, 0.80 * a2),
                      P.alpha(C.void, 0), r * A.footprint * 0.46)
  Draw.radialGradient(self.x, cy, r * 1.25, P.alpha(P.black, 0.62 * a2),
                      P.alpha(P.black, 0), r * 0.58)

  -- crushed canopy: leaf shapes lying flat and colourless where they fell
  for i = 1, 46 do
    local a = hash(i, 3, 11) * TAU
    local d = r * (0.60 + hash(i, 5, 7) * 1.60)
    local x = self.x + cos(a) * d
    local y = cy + sin(a) * d * 0.52
    local s = r * (0.13 + hash(i, 9, 13) * 0.20)
    -- a flattened crown: a dark body with a pale broken edge on its up-side,
    -- which is what makes a blob read as a tree somebody stood on
    Draw.setColor(P.mix(P.ramp.leaf[1], C.void, 0.45), (0.70 + 0.25 * hash(i, 4, 6)) * a2)
    Draw.blob(x, y + s * 0.10, s * 1.06, 8, i * 31, 0.36, 0.38)
    Draw.setColor(hash(i, 2, 8) > 0.5 and C.ash or P.mix(P.ramp.leaf[2], C.ash, 0.6),
                  (0.60 + 0.30 * hash(i, 4, 6)) * a2)
    Draw.blob(x, y - s * 0.06, s * 0.90, 8, i * 31, 0.34, 0.36)
  end
  -- splinters thrown out, pointing away from what broke them
  for i = 1, 30 do
    local a = hash(i, 17, 4) * TAU
    local d = r * (1.30 + hash(i, 19, 6) * 1.00)
    local x = self.x + cos(a) * d
    local y = cy + sin(a) * d * 0.52
    limb(x, y, x + cos(a) * r * 0.13, y + sin(a) * r * 0.065, r * 0.020, r * 0.005,
         C.ashHi, 0.65 * a2)
  end
  -- the dead ash ring, broken rather than drawn as a circle
  for i = 0, 13 do
    local a0 = i / 14 * TAU + hash(i, 23, 2) * 0.16
    local a1 = a0 + 0.26 + hash(i, 29, 3) * 0.14
    plate(self.x, cy, a0, a1, r * (A.footprint - 0.34), r * (A.footprint + 0.08), 0.52,
          P.alpha(C.ash, 0), C.ashHi, 0.70 * a2, 3)
  end

  -- The strobe on the ground. Amber, not red: the four red lamps that used to
  -- justify a red wash are gone, the sweeping beacon is the only warning light
  -- left on the machine, and with the wash matching it red goes back to meaning
  -- exactly one thing in this fight -- the beam.
  local strobe = math.max(0, sin(self.age * TAU * AR.strobeHz)) ^ 2
  Draw.additive(function()
    Draw.radialGradient(self.x, cy, r * 1.95, P.alpha(C.hazard, (0.05 + 0.14 * strobe) * a2),
                        P.alpha(C.hazard, 0), r * 0.86)
  end)

  -- foot craters, one per leg, dug in where the weight actually goes
  for i = 0, 5 do
    local _, fx, fy, raise = self:legPose(i, arrive, footY)
    local k = (1 - raise) * a2
    Draw.radialGradient(self.x + fx, self.y + fy + r * 0.10, r * 0.36,
                        P.alpha(C.void, 0.72 * k), P.alpha(C.void, 0), r * 0.16)
    for j = 1, 5 do
      local a = hash(i * 7 + j, 31, 2) * TAU
      Draw.setColor(C.ash, 0.55 * k)
      Draw.blob(self.x + fx + cos(a) * r * 0.22, self.y + fy + r * 0.10 + sin(a) * r * 0.10,
                r * 0.07, 6, i * 13 + j, 0.4, 0.5)
    end
  end
end

------------------------------------------------------------------------- legs
--- One hydraulic leg: yoke, thigh, knee block, shin, ram, and a three-toe claw
--- that is dug into the canopy. Drawn twice -- a fat near-black pass first so
--- the leg separates from a sunlit crown, then the metal on top of it.
function Boss:drawLeg(i, arrive, lift, footY, pass)
  local r = self.radius
  local a, fx, fy, raise = self:legPose(i, arrive, footY)
  local hx = cos(a) * r * A.hipR
  local hy = sin(a) * r * A.hipSq + lift

  -- knee-up, like every walking machine that has to carry something: the joint
  -- rides above the line between hip and foot and rises further on the step
  local kx = U.lerp(hx, fx, A.kneeAt) + cos(a) * r * 0.10
  local ky = U.lerp(hy, fy, A.kneeAt) - r * A.kneeRise * (1 + raise * 0.45)

  local out = pass == "dark" and r * 0.022 or 0
  local c1 = pass == "dark" and C.void or P.mix(C.deep, C.hull, 0.75)
  local c2 = pass == "dark" and C.void or C.hull
  local up = 0.5 + 0.5 * cos(a - math.pi * 1.25)   -- key from up-left

  -- thigh and shin
  limb(hx, hy, kx, ky, r * A.thighW + out, r * A.kneeW + out, c1)
  limb(kx, ky, fx, fy, r * A.shinW + out, r * A.ankleW + out, c1)

  if pass == "dark" then
    -- the pad and its spikes, fattened, so the foot carries an outline too
    ngon("fill", fx, fy + r * 0.02, r * 0.15 + out, r * 0.098 + out, 6, 0.0)
    for t = -1, 1 do
      local ca = a + t * 0.80
      limb(fx, fy + r * 0.02, fx + cos(ca) * r * 0.15, fy + sin(ca) * r * 0.075 + r * 0.075,
           r * 0.042 + out, r * 0.014 + out, C.void)
    end
    return
  end

  -- upper-edge light on both bones: the whole reason a capsule reads as a bone
  limb(hx, hy - r * 0.040, kx, ky - r * 0.031, r * 0.050, r * 0.036, P.mix(C.hull, C.lit, 0.2 + up * 0.8))
  limb(kx, ky - r * 0.031, fx, fy - r * 0.024, r * 0.032, r * 0.018, P.mix(C.hull, C.lit, 0.1 + up * 0.8))

  -- the hydraulic ram along the shin: an outer cylinder and a bright rod that
  -- visibly runs out of it as the leg takes the weight
  local ux, uy = fx - kx, fy - ky
  local rl = math.sqrt(ux * ux + uy * uy)
  if rl > 1e-3 then
    ux, uy = ux / rl, uy / rl
    local nx, ny = -uy * r * 0.085, ux * r * 0.085
    local ext = 0.30 + (1 - raise) * 0.24
    Draw.setColor(C.deep)
    limb(kx + nx + ux * rl * 0.10, ky + ny + uy * rl * 0.10,
         kx + nx + ux * rl * 0.42, ky + ny + uy * rl * 0.42, r * 0.052, r * 0.052, C.deep)
    limb(kx + nx + ux * rl * 0.40, ky + ny + uy * rl * 0.40,
         kx + nx + ux * rl * (0.40 + ext), ky + ny + uy * rl * (0.40 + ext),
         r * 0.026, r * 0.026, C.rim)
  end

  -- knee block and its pivot pin
  Draw.setColor(P.mix(C.hull, C.hi, up * 0.5))
  ngon("fill", kx, ky, r * 0.16, r * 0.13, 6, 0.3)
  Draw.setColor(C.seam)
  LG.circle("fill", kx, ky, r * 0.058, 10)
  Draw.setColor(C.rim, 0.9)
  LG.circle("fill", kx - r * 0.012, ky - r * 0.014, r * 0.030, 8)

  -- the hip yoke, where the leg meets the frame
  Draw.setColor(C.deep)
  ngon("fill", hx, hy, r * 0.17, r * 0.12, 6, 0.0)
  Draw.setColor(P.mix(C.hull, C.hi, up * 0.6))
  ngon("fill", hx, hy - r * 0.02, r * 0.12, r * 0.08, 6, 0.0)

  -- the foot: a bolted pad with three short spikes driven into the canopy.
  -- It was a splayed three-finger claw and read as a bird's hand.
  for t = -1, 1 do
    local ca = a + t * 0.80
    limb(fx, fy + r * 0.02, fx + cos(ca) * r * 0.15, fy + sin(ca) * r * 0.075 + r * 0.075,
         r * 0.036, r * 0.010, P.mix(C.deep, C.hull, 0.5 + up * 0.5))
  end
  Draw.setColor(P.mix(C.deep, C.hull, 0.4 + up * 0.6))
  ngon("fill", fx, fy + r * 0.02, r * 0.15, r * 0.098, 6, 0.0)
  Draw.setColor(P.mix(C.hull, C.hi, 0.25 + up * 0.75))
  ngon("fill", fx, fy - r * 0.008, r * 0.115, r * 0.068, 6, 0.0)
  bolt(fx - r * 0.055, fy + r * 0.005, r * 0.020, 1)
  bolt(fx + r * 0.055, fy + r * 0.005, r * 0.020, 1)
  -- the ankle's own hazard chip: a worn stripe on a working machine
  if i % 2 == 0 then
    Draw.setColor(C.hazard, 0.7)
    LG.rectangle("fill", fx - r * 0.055, fy - r * 0.052, r * 0.11, r * 0.020)
  end
end

------------------------------------------------------------------------ skirt
-- Which of the twelve sockets still hold plate at each phase. The pattern is
-- authored rather than even: a machine that has lost half its skirt has lost it
-- in pieces, and an evenly spaced remainder reads as a setting, not as damage.
local SKIRT_P2 = { [3]=true, [5]=true, [6]=true, [9]=true, [10]=true, [12]=true }
-- The two that carry the hazard paint. They sit on the near half, where the
-- skirt is not occluded by the deck, and they survive to phase 2 -- the one
-- warm note on the machine should not leave the moment the fight opens up.
local SKIRT_HAZ = { [3]=true, [5]=true }

--- The frame everything else is bolted to. Drawn before the skirt so the skirt
--- overlaps it: an armour band that reads as the widest part of the machine,
--- rather than a hoop peeking out from behind a disc.
function Boss:drawChassis(lift)
  local r = self.radius
  Draw.setColor(C.void)
  ngon("fill", 0, lift + r * 0.04, r * (A.chassisR + 0.05), r * (A.chassisSq + 0.04), 8, math.pi / 8)
  ngonLit(0, lift, r * A.chassisR, r * A.chassisSq, 8, math.pi / 8, C.hull, C.deep, 1)
  -- six trusses out to the leg mounts, seen once the skirt is off
  for i = 0, 5 do
    local a = i * TAU / 6 + math.pi / 12
    limb(cos(a) * r * 0.24, lift + sin(a) * r * 0.16,
         cos(a) * r * A.hipR, lift + sin(a) * r * A.hipSq,
         r * 0.055, r * 0.075, C.frameLo)
  end
end

function Boss:drawSkirt(lift)
  local r = self.radius
  local segs = A.skirtSegs
  local intact = self.plates or 0
  local cy = lift

  -- the frame ring the plates bolt to: always there, only *seen* once they go
  plate(0, cy, 0, TAU, r * A.skirtIn * 0.94, r * (A.skirtIn + 0.06), A.skirtSq,
        C.frameLo, C.frame, 1, 26)
  -- the shadow the plates sit in. Without it the gaps between twelve plates are
  -- the same tone as the plates and the skirt is one smooth disc.
  plate(0, cy, 0, TAU, r * A.skirtIn, r * (A.skirtOut + 0.015), A.skirtSq,
        C.void, C.void, 1, 26)

  for k = 1, segs do
    local a0 = (k - 1) / segs * TAU + 0.075
    local a1 = k / segs * TAU - 0.075
    local am = (a0 + a1) * 0.5
    local held = intact >= 6 or (intact >= 3 and SKIRT_P2[k])

    if held then
      -- Form light around the ring: plates facing up-screen catch the key, the
      -- ones nearest camera fall into their own shadow. This is what makes a
      -- ring of plates read as a barrel and not as twelve stickers -- and the
      -- chamfer (dark tuck, broad face, hard lip) is what makes each one read
      -- as a *plate* rather than as a slice of a disc.
      local up = 0.5 + 0.5 * cos(am - math.pi * 1.25)
      local alt = (k % 2 == 0) and 0.10 or 0.0    -- rolled plate is never one tone
      local base = P.mix(C.void, C.hull, 0.20 + alt + up * 0.62)
      local edge = P.mix(C.deep, C.lit, 0.12 + alt + up * 0.82)
      plate(0, cy, a0, a1, r * A.skirtIn, r * (A.skirtIn + 0.10), A.skirtSq,
            C.void, base, 1, 3)
      plate(0, cy, a0, a1, r * (A.skirtIn + 0.10), r * (A.skirtOut - 0.05), A.skirtSq,
            base, edge, 1, 4)
      plate(0, cy, a0, a1, r * (A.skirtOut - 0.05), r * (A.skirtOut - 0.015), A.skirtSq,
            P.mix(edge, C.rim, 0.50 + up * 0.40), P.mix(edge, C.rim, 0.50 + up * 0.40), 1, 4)
      plate(0, cy, a0, a1, r * (A.skirtOut - 0.015), r * A.skirtOut, A.skirtSq,
            C.void, C.void, 0.9, 4)
      -- a running light on the lip, every other plate
      if k % 2 == 1 then
        local lx = cos(am) * r * (A.skirtOut - 0.045)
        local ly = cy + sin(am) * r * (A.skirtOut - 0.045) * A.skirtSq
        Draw.setColor(C.hazard, 0.75)
        LG.circle("fill", lx, ly, r * 0.022, 6)
        Draw.glow(lx, ly, r * 0.13, C.hazard, 0.45)
      end
      -- and the shadow it throws down onto whatever is beneath it
      plate(0, cy, a0, a1, r * A.skirtOut, r * (A.skirtOut + 0.045), A.skirtSq,
            C.void, P.alpha(C.void, 0), 0.7, 4)
      -- two of the twelve carry the hazard paint. Any more and the machine
      -- reads as a toy; any fewer and the one warm note on it disappears.
      if SKIRT_HAZ[k] then
        LG.push()
        LG.translate(cos(am) * r * (A.skirtIn + 0.22), cy + sin(am) * r * (A.skirtIn + 0.22) * A.skirtSq)
        LG.rotate(sin(am) * 0.36)
        hazard(-r * 0.19, -r * 0.055, r * 0.38, r * 0.11, r * 0.070, self.age * 5, 0.9)
        LG.pop()
      else
        -- three bolts, on the line where the plate is actually held
        for b = 0, 2 do
          local ab = U.lerp(a0, a1, 0.20 + b * 0.30)
          bolt(cos(ab) * r * (A.skirtIn + 0.22), cy + sin(ab) * r * (A.skirtIn + 0.22) * A.skirtSq,
               r * A.boltR, 1)
        end
      end
    else
      -- An empty socket. All of this has to live *outside* the chassis or it is
      -- drawn behind it and the machine's damage state is invisible: the frame
      -- rib, the stub of the sheared plate, the studs that held it.
      local rIn = A.chassisR - 0.02
      for e = 0, 1 do
        local ab = U.lerp(a0, a1, e)
        limb(cos(ab) * r * rIn, cy + sin(ab) * r * rIn * A.skirtSq,
             cos(ab) * r * (A.skirtOut - 0.06), cy + sin(ab) * r * (A.skirtOut - 0.06) * A.skirtSq,
             r * 0.045, r * 0.030, C.void)
        limb(cos(ab) * r * rIn, cy + sin(ab) * r * rIn * A.skirtSq - r * 0.014,
             cos(ab) * r * (A.skirtOut - 0.06), cy + sin(ab) * r * (A.skirtOut - 0.06) * A.skirtSq - r * 0.010,
             r * 0.024, r * 0.014, C.frame)
      end
      -- the stub: a torn ragged remnant with a bright sheared edge
      plate(0, cy, a0, a1, r * rIn, r * (rIn + 0.11 + 0.05 * hash(k, 5, 1)), A.skirtSq,
            C.deep, C.void, 1, 4)
      plate(0, cy, a0, a1, r * (rIn + 0.08 + 0.05 * hash(k, 5, 1)),
            r * (rIn + 0.11 + 0.05 * hash(k, 5, 1)), A.skirtSq, C.torn, C.torn, 0.9, 4)
      for b = 0, 1 do
        local ab = U.lerp(a0, a1, 0.28 + b * 0.44)
        Draw.setColor(C.torn)
        LG.circle("fill", cos(ab) * r * (rIn + 0.05),
                  cy + sin(ab) * r * (rIn + 0.05) * A.skirtSq, r * 0.022, 6)
      end
      -- heat leaking out of the frame the plate used to cover
      local glow = self.coreOpen > 0 and 0.60 or 0.26
      Draw.additive(function()
        local leak = self.coreOpen > 0 and C.molten or C.coreCold
        plate(0, cy, a0, a1, r * rIn, r * (A.skirtOut - 0.10), A.skirtSq,
              leak, P.alpha(leak, 0),
              glow * (0.6 + 0.4 * sin(self.age * 3 + k)), 4)
      end)
      -- a torn edge sparks now and then, deterministically
      local sp = hash(k, floor(self.age * 3.1), 5)
      if sp > 0.90 then
        local ab = U.lerp(a0, a1, hash(k, floor(self.age * 3.1), 9))
        local bx = cos(ab) * r * (rIn + 0.08)
        local by = cy + sin(ab) * r * (rIn + 0.08) * A.skirtSq
        Draw.glow(bx, by, r * 0.16, C.moltenHi, 0.9)
      end
    end
  end
end

------------------------------------------------------------------------- deck
function Boss:drawDeck(lift)
  local r = self.radius
  local deckY = lift + r * A.deckY
  local superY = lift + r * A.superY

  -- The deck. Eight plates with real gaps between them rather than one filled
  -- octagon: at this size a single tone the width of the machine is the loudest
  -- possible way to say nobody drew this.
  local sq = A.deckSq / A.deckR
  Draw.setColor(C.void, 0.9)
  ngon("fill", 0, deckY + r * 0.035, r * (A.deckR + 0.02), r * (A.deckSq + 0.02), 8, math.pi / 8)
  ngonLit(0, deckY, r * A.deckR, r * A.deckSq, 8, math.pi / 8, C.hull, C.void, 1)
  for i = 0, 7 do
    local a0 = i / 8 * TAU + 0.05
    local a1 = (i + 1) / 8 * TAU - 0.05
    local up = 0.5 + 0.5 * cos((a0 + a1) * 0.5 - math.pi * 1.25)
    -- plates alternate tone the way rolled plate does, and the outer edge of
    -- each one catches the key
    local tone = (i % 2 == 0) and 0.10 or 0.24
    plate(0, deckY, a0, a1, r * 0.24, r * (A.deckR - 0.03), sq,
          P.mix(C.void, C.hull, tone + up * 0.30),
          P.mix(C.deep, C.lit, tone + up * 0.66), 1, 4)
    plate(0, deckY, a0, a1, r * (A.deckR - 0.06), r * (A.deckR - 0.03), sq,
          P.mix(C.lit, C.rim, 0.2 + up * 0.6), P.mix(C.lit, C.rim, 0.2 + up * 0.6), 0.9, 4)
    plate(0, deckY, a0, a1, r * 0.24, r * 0.27, sq, C.void, C.void, 0.8, 4)
  end
  -- a fine cast tooth over the whole deck, so it is not a gradient
  Draw.stipple(-r * A.deckR, deckY - r * A.deckSq, r * A.deckR * 2, r * A.deckSq * 2,
               r * 0.055, 17, C.rim, 0.055, 1)
  Draw.setColor(C.rim, 0.30)
  LG.setLineWidth(2)
  ngon("line", 0, deckY, r * A.deckR, r * A.deckSq, 8, math.pi / 8)

  -- One rivet on each plate seam rather than a ring of twenty-four. Two dozen
  -- bolt heads inside 0.86 of the radius is not armour, it is a texture, and at
  -- the zoom this game is played at a texture is what the deck already had too
  -- much of.
  for i = 0, AR.deckRivets - 1 do
    local a = i / AR.deckRivets * TAU + math.pi / 8
    bolt(cos(a) * r * (A.deckR - 0.07), deckY + sin(a) * r * (A.deckSq - 0.06), r * 0.030, 0.95)
  end

  -- hazard band across the deck's leading edge, facing whichever way it walks
  local fa = math.atan2(self.faceY or 1, self.faceX or 0)
  LG.push()
  LG.translate(cos(fa) * r * 0.46, deckY + sin(fa) * r * 0.30)
  LG.rotate(sin(fa) * 0.22)
  hazard(-r * 0.30, -r * 0.055, r * 0.60, r * 0.11, r * 0.075, self.age * 6, 0.92)
  LG.pop()

  -- superstructure: a raised machinery ring around the throat's base, with two
  -- boxy modules flanking it. A cone standing on a flat disc has no mass; this
  -- is what gives the rig a middle.
  Draw.setColor(C.void, 0.9)
  ngon("fill", 0, superY + r * 0.06, r * (A.superR + 0.04), r * (A.superSq + 0.04), 8, 0)
  ngonLit(0, superY, r * A.superR, r * A.superSq, 8, 0, C.lit, C.deep, 1)
  Draw.setColor(C.rim, 0.4)
  LG.setLineWidth(2)
  ngon("line", 0, superY, r * A.superR, r * A.superSq, 8, 0)
  for i = 0, 5 do
    local a = i / 6 * TAU + 0.4
    bolt(cos(a) * r * (A.superR - 0.05), superY + sin(a) * r * (A.superSq - 0.045), r * 0.024, 0.9)
  end
  -- One housing per flank, not a generator module with a louvre bank stacked on
  -- top of it. Two elements inside the same thirty pixels of deck are not two
  -- elements, they are noise -- and of the two only the heat slot has a job:
  -- it is how the deck says, from across the island, that the core is open.
  for m = -1, 1, 2 do
    local bx = m * r * 0.52
    local by = deckY - r * 0.05
    local h  = r * 0.34
    local heat = 0.5 + 0.5 * sin(self.age * TAU * AR.ventHz + m)
    local hotC = self.coreOpen > 0 and C.moltenHi or C.molten
    Draw.setColor(C.void)
    Draw.roundRect("fill", bx - r * 0.20, by - h, r * 0.40, h + r * 0.11, r * 0.04)
    Draw.linearGradient(bx - r * 0.18, by - h + r * 0.02, r * 0.36, h + r * 0.07,
                        P.mix(C.hull, C.lit, 0.40), C.void, math.pi * 0.5)
    Draw.setColor(C.rim, 0.45)
    LG.setLineWidth(2)
    LG.line(bx - r * 0.18, by - h + r * 0.02, bx + r * 0.18, by - h + r * 0.02)
    -- the heat slot: a recess with three louvres and whatever is behind them
    local sx, sy = bx - r * 0.145, by - r * 0.145
    local sw, sh = r * 0.29, r * 0.21
    Draw.setColor(C.void)
    Draw.roundRect("fill", sx, sy, sw, sh, r * 0.02)
    Draw.additive(function()
      Draw.setColor(hotC, (0.16 + 0.16 * heat) * (self.coreOpen > 0 and 2.0 or 1))
      LG.rectangle("fill", sx, sy, sw, sh)
    end)
    for k = 0, 2 do
      local ly = sy + r * 0.014 + k * r * 0.064
      Draw.setColor(C.void)
      LG.rectangle("fill", sx, ly, sw, r * 0.032)
      Draw.setColor(P.mix(C.hull, C.lit, 0.5))
      LG.rectangle("fill", sx, ly, sw, r * 0.020)
    end
    -- the shimmer standing off the top of it, warm once the core is open
    Draw.additive(function()
      for k = 1, 2 do
        local w = sin(self.age * 5 + k * 2 + m) * r * 0.04
        Draw.quad(bx - r * 0.10, by - h,
                  bx + r * 0.10, by - h,
                  bx + r * 0.06 + w, by - h - r * (0.13 + 0.10 * k),
                  bx - r * 0.06 + w, by - h - r * (0.13 + 0.10 * k),
                  hotC, hotC, P.alpha(hotC, 0), P.alpha(hotC, 0),
                  (0.07 + 0.06 * heat) * (self.coreOpen > 0 and 2.2 or 1))
      end
    end)
  end

  -- The four struts that carry the intake collar. They belong to the throat,
  -- but they are drawn here, before the core, because every one of them
  -- crosses the aperture on the way up and four black bars laid over the one
  -- element the phase read depends on is not structure, it is a cage. Behind
  -- the well they read as what they are: the frame the throat stands in.
  do
    local cr, crY = r * A.collarR, r * A.collarR * A.collarSq
    local cy = lift + r * A.collarY
    for k = 0, 3 do
      local a = k * TAU / 4 + math.pi / 4
      local sx = cos(a) * r * 0.64
      local sy = deckY + sin(a) * r * 0.44
      limb(sx, sy, cos(a) * cr * 0.85, cy + sin(a) * crY * 0.85, r * 0.036, r * 0.024, C.void)
      limb(sx, sy, cos(a) * cr * 0.85, cy + sin(a) * crY * 0.85, r * 0.020, r * 0.012,
           P.mix(C.deep, C.hull, 0.3 + 0.7 * cos(a - math.pi * 1.25)))
    end
  end

  -- contact shadow where the throat's base meets the deck
  Draw.setColor(C.void, 0.55)
  LG.ellipse("fill", 0, deckY - r * 0.04, r * 0.40, r * 0.19)

  -- The core aperture: a molten well with six iris leaves closed over it.
  -- Sealed in phase 1, cracked in phase 2, retracted in phase 3 -- so the phase
  -- is legible from the shape of the machine and not from a plate count.
  --
  -- The crust below is drawn *opaque* and the leaves sit on top of it. Molten
  -- metal is a surface first: only what comes up out of the breaks in it is
  -- light, and the moment that is reversed the core is a lamp under a lid.
  local open = (self.phase - 1) * 0.5
  if self.coreOpen > 0 then open = 1 end
  local pulse = 0.65 + 0.35 * sin(self.age * 3)
  local isq = A.deckSq / A.deckR
  local rOut = r * (A.irisOut + 0.02)

  Draw.setColor(C.void)
  LG.ellipse("fill", 0, deckY, rOut * 1.10, rOut * 1.10 * isq)

  -- The crust. Near-black, and it is nearly all of the well: what the eye is
  -- given here is a *surface*, and the only bright thing inside the machine is
  -- what is coming up through the breaks in it.
  --
  -- This was a graded tan disc -- brass, or a wooden hatch, at the exact centre
  -- of a machine that has come to strip a planet. A tessellation of crust
  -- plates was tried first and at the size the core actually occupies on screen
  -- it read as a gear: three concentric rings of even cells is a machined
  -- thing, and this has to be a failing one. Cracks drawn as strokes carry it,
  -- because a stroke can be thin, crooked and moving, and a cell cannot.
  local pRim = P.mix(C.poolRim, C.coreDeep, 1 - open)
  local pMid = P.mix(C.poolMid, C.coreMidC, 1 - open)
  local pHot = P.mix(C.poolHot, C.coreHiC, 1 - open)
  local crustC = P.mix(C.crustCold, C.crust, open)
  local crustL = P.mix(C.crustCold, C.crustLit, open)
  ngonLit(0, deckY, rOut, rOut * isq, 20, 0, crustL, crustC, 1)
  plate(0, deckY, 0, TAU, rOut * 0.55, rOut, isq, P.alpha(C.void, 0), C.void, 0.55, 20)
  -- four broken slabs, at low contrast: enough that the crust has a grain,
  -- few enough that it is still one surface. Nine of them read as rubble.
  for k = 1, 4 do
    local a = hash(k, 51, 3) * TAU + self.age * 0.05
    local d = rOut * (0.28 + hash(k, 53, 4) * 0.50)
    Draw.setColor(P.mix(crustC, crustL, 0.35 + hash(k, 57, 5) * 0.45), 0.40)
    Draw.blob(cos(a) * d, deckY + sin(a) * d * isq, rOut * (0.24 + hash(k, 59, 6) * 0.18),
              7, k * 17, 0.34, 0.55)
  end

  -- one pocket where the crust has given way and the melt is simply open. It
  -- wanders, so the core is never quite the same shape twice.
  do
    local w = self.age * 0.29
    local px, py = sin(w) * rOut * 0.34, deckY + cos(w * 0.83) * rOut * 0.26 * isq
    local pr = rOut * 0.30
    Draw.setColor(C.void, 0.50)
    Draw.blob(px, py, pr * 1.05, 8, 5, 0.34, isq)
    Draw.radialGradient(px, py, pr, P.mix(pRim, C.void, 0.30), P.alpha(pRim, 0), pr * isq)
  end

  -- The cracks. Each one walks outward from the vent in five steps with a
  -- crooked wobble, and a bright pulse travels up it -- so the fissure network
  -- is legibly *moving* without a frame of it being authored.
  local drift = self.age * TAU * AR.coreDriftRps
  local flow  = self.age * TAU * AR.coreFlowHz
  local wide  = r * (AR.coreCrack + AR.coreCrackOpen * open)
  local NC, NS = AR.coreCracks, 5
  Draw.additive(function()
    for i = 1, NC * 2 do
      -- Two generations. The first walks out of the vent; the second is finer,
      -- shorter, offset half a step and starts out in the field -- because
      -- eight equal strokes leaving one bright middle is a starfish, and a
      -- crust that has failed fails at more than one scale.
      local fine = i > NC
      local j = fine and (i - NC + 0.5) or i
      local a = drift + j / NC * TAU + hash(i, 71, 2) * 0.9
      -- each crack starts on its own point of the vent's lip rather than at
      -- the middle: eight strokes converging on one pixel stack additively
      -- into a white star, which is the lens flare this pass exists to avoid
      local o = rOut * (fine and (0.42 + hash(i, 73, 4) * 0.22)
                             or (0.20 + hash(i, 73, 4) * 0.16))
      local lenK = rOut * (fine and (0.62 + hash(i, 79, 3) * 0.34)
                                 or (0.62 + hash(i, 79, 3) * 0.42))
      local wid  = wide * (fine and 0.50 or 1.00)
      local dim  = fine and 0.62 or 1
      local wob  = 0.45 + hash(i, 81, 5) * 1.15
      local px, py, pw = cos(a) * o, deckY + sin(a) * o * isq, wid * 1.15
      for st = 1, NS do
        local t  = st / NS
        local d  = o + (lenK - o) * t
        local aa = a + (hash(i, st, 13) - 0.5) * 0.30 * wob + sin(flow * 0.7 + i + st) * 0.09
        local qx, qy = cos(aa) * d, deckY + sin(aa) * d * isq
        local w  = wid * (1.15 - t * 0.48)
        -- the pulse running up the crack. It never falls all the way off: a
        -- crack that goes out is a crack that stops being a light source, and
        -- then the core is a dark patch again.
        local pu = (0.52 + 0.48 * U.saturate(sin(flow * 2.0 - st * 1.05 + i * 1.7))) * dim
        local c0 = P.mix(pHot, pMid, U.saturate((t - 1 / NS) * 1.15))
        local c1 = P.mix(pHot, pMid, U.saturate(t * 1.15))
        local nx0, ny0 = -(qy - py), (qx - px)
        local nl = math.sqrt(nx0 * nx0 + ny0 * ny0)
        if nl > 1e-4 then
          nx0, ny0 = nx0 / nl, ny0 / nl
          Draw.quad(px + nx0 * pw, py + ny0 * pw, px - nx0 * pw, py - ny0 * pw,
                    qx - nx0 * w, qy - ny0 * w, qx + nx0 * w, qy + ny0 * w,
                    P.alpha(c0, 0.80 * pu), P.alpha(c0, 0.80 * pu),
                    P.alpha(c1, 0.72 * pu * (1 - t * 0.22)),
                    P.alpha(c1, 0.72 * pu * (1 - t * 0.22)))
          -- a round joint at every node: without it the width step between
          -- two segments notches the fissure and it reads as wood grain
          Draw.setColor(c1, 0.42 * pu)
          LG.circle("fill", qx, qy, w * 0.85, 8)
          -- and a thread of white-hot down the middle of the widest stretch.
          -- The crack has to be the colour of fire and still reach the top of
          -- the range somewhere; a strip a pixel and a half wide is where that
          -- can be afforded without the well going back to being a lamp.
          if st <= 2 and not fine then
            local wc = P.mix(pHot, P.white, 0.55)
            Draw.quad(px + nx0 * pw * 0.40, py + ny0 * pw * 0.40,
                      px - nx0 * pw * 0.40, py - ny0 * pw * 0.40,
                      qx - nx0 * w * 0.40, qy - ny0 * w * 0.40,
                      qx + nx0 * w * 0.40, qy + ny0 * w * 0.40,
                      P.alpha(wc, 0.60 * pu), P.alpha(wc, 0.60 * pu),
                      P.alpha(wc, 0.40 * pu), P.alpha(wc, 0.40 * pu))
          end
        end
        px, py, pw = qx, qy, w
      end
    end
    -- the wall of the well, catching what is burning at the bottom of it. It
    -- is the difference between a dark disc with some marks on it and a hole
    -- with a fire in it.
    plate(0, deckY, 0, TAU, rOut * 0.80, rOut * 1.00, isq,
          P.alpha(pMid, 0), P.alpha(pMid, 0.30 + 0.16 * open), 1, 22)
    -- the vent at the middle, and the light the whole well throws back up
    Draw.setColor(pMid, 0.55)
    LG.ellipse("fill", 0, deckY, wide * 1.7, wide * 1.7 * isq, 12)
    Draw.setColor(P.mix(pHot, P.white, 0.45), 0.55)
    LG.ellipse("fill", 0, deckY, wide * 0.75, wide * 0.75 * isq, 10)
    Draw.glow(0, deckY, rOut * (0.42 + 0.26 * open) * pulse, pMid,
              (0.13 + 0.17 * open), 2)
  end)

  -- the leaves, retracting outward as the machine opens
  for k = 0, 5 do
    local a0 = k / 6 * TAU + 0.05 + open * 0.28
    local a1 = (k + 1) / 6 * TAU - 0.05 - open * 0.28
    if a1 > a0 then
      local up = 0.5 + 0.5 * cos((a0 + a1) * 0.5 - math.pi * 1.25)
      local inner = r * (A.irisIn * 0.10 + open * 0.34)
      local outer = r * (A.irisOut + 0.03 + open * 0.10)
      plate(0, deckY, a0, a1, inner, outer, isq,
            P.mix(C.void, C.hull, 0.30 + up * 0.45), P.mix(C.deep, C.lit, 0.15 + up * 0.80), 1, 4)
      plate(0, deckY, a0, a1, outer - r * 0.030, outer, isq,
            P.mix(C.lit, C.rim, up), P.mix(C.lit, C.rim, up), 0.9, 4)
      -- the shadow the leaf throws into the well
      plate(0, deckY, a0, a1, inner, inner + r * 0.05, isq,
            C.void, P.alpha(C.void, 0), 0.8, 4)
    end
  end

  -- the machined ring the leaves run in, and its bolts: without it a closed
  -- aperture is a grey disc and nothing says it is a door
  plate(0, deckY, 0, TAU, rOut * 1.02, rOut * 1.20, isq, C.void, C.deep, 1, 22)
  plate(0, deckY, 0, TAU, rOut * 1.16, rOut * 1.20, isq, C.lit, C.lit, 0.7, 22)
  for k = 0, 5 do
    local a = k / 6 * TAU + 0.12
    bolt(cos(a) * rOut * 1.11, deckY + sin(a) * rOut * 1.11 * isq, r * 0.024, 0.95)
  end

  -- Cracks spidering out of the core across the deck plate, once it is open.
  -- Cut into the deck first and lit second: an additive line on its own is
  -- lightning crawling over a lid, and a groove with heat in it is a hull that
  -- is coming apart.
  if self.coreOpen > 0 then
    local n = 4
    for k = 1, AR.coreVeins do
      local a = k / AR.coreVeins * TAU + hash(k, 41, 2) * 0.5
      for pass = 0, 1 do
        local px, py = cos(a) * r * A.irisOut, deckY + sin(a) * r * A.irisOut * 0.7
        for st = 1, n do
          local d = r * (A.irisOut + st / n * (A.deckR - A.irisOut) * 0.92)
          local aa = a + (hash(k, st, 13) - 0.5) * 0.42
          local qx, qy = cos(aa) * d, deckY + sin(aa) * d * (A.deckSq / A.deckR)
          local f = 1 - st / n
          if pass == 0 then
            Draw.setColor(C.void, 0.85)
            LG.setLineWidth(3 + f * 4)
            LG.line(px, py, qx, qy)
          else
            Draw.setColor(P.mix(C.moltenHi, C.molten, st / n), (0.60 * f + 0.12) * pulse)
            LG.setLineWidth(1 + f * 2)
            LG.line(px, py, qx, qy)
          end
          px, py = qx, qy
        end
      end
    end
    Draw.additive(function()
      for k = 1, AR.coreVeins do
        local a = k / AR.coreVeins * TAU + hash(k, 41, 2) * 0.5
        Draw.glow(cos(a) * r * (A.irisOut + 0.10), deckY + sin(a) * r * (A.irisOut + 0.10) * 0.7,
                  r * 0.16, C.molten, 0.30 * pulse)
      end
    end)
  end

  -- Four strobes used to blink here. Two of them sat at three and nine o'clock
  -- as small saturated pink dots -- the only pink left on a hull the violet was
  -- deliberately taken out of -- and at gameplay zoom they read as stray VFX
  -- lying on the deck rather than as lamps bolted to it. The rig keeps exactly
  -- one warning light, the sweeping one below, and red is left to mean the beam.

  -- the rotating beacon on the superstructure: one amber wedge sweeping the
  -- deck. Nothing else in the game does this, and it is what makes the rig read
  -- as a vehicle somebody sent rather than a monster that grew.
  local ba = self._beacon or 0
  local mx = cos(A.beaconAt) * r * A.superR * 0.86
  local my = superY + sin(A.beaconAt) * r * A.superSq * 0.86
  local lampY = my - r * 0.24
  -- The sweeping wedge is the rig's whole warning read now, so it reaches
  -- further and carries a hard leading edge instead of fading out both sides.
  Draw.additive(function()
    plate(mx, lampY, ba - 0.26, ba + 0.26, r * 0.06, r * 0.78, 0.42,
          C.hazard, P.alpha(C.hazard, 0), 0.17, 6)
    plate(mx, lampY, ba + 0.20, ba + 0.26, r * 0.06, r * 0.78, 0.42,
          C.hazard, P.alpha(C.hazard, 0), 0.22, 3)
  end)
  limb(mx, my, mx, lampY + r * 0.03, r * 0.026, r * 0.020, C.void)
  limb(mx, my, mx, lampY + r * 0.03, r * 0.015, r * 0.011, C.lit)
  Draw.setColor(C.void)
  LG.circle("fill", mx, lampY, r * 0.062, 10)
  Draw.setColor(C.hazard, 0.9)
  LG.circle("fill", mx + cos(ba) * r * 0.026, lampY + sin(ba) * r * 0.014, r * 0.040, 8)
  Draw.glow(mx, lampY, r * 0.22, C.hazard, 0.45)

  self:drawTurret(lift)
end

--- Where the beam actually comes out of. The rig is radially symmetrical in
--- every other respect, and a machine with no front is a machine with no face:
--- this is the one element that says which way it is looking.
function Boss:emitterPos(lift)
  local r = self.radius
  local a = self._aim or 0
  return cos(a) * r * 0.66, lift + r * A.deckY + sin(a) * r * 0.46, a
end

function Boss:drawTurret(lift)
  local r = self.radius
  local tx, ty, a = self:emitterPos(lift)
  -- the barrel runs along the screen-projected bearing, not the world one
  local bx, by = cos(a), sin(a) * 0.68
  local ang = math.atan2(by, bx)
  local charge = self.beamCharging or 0
  local firing = (self.state == "beam" and self.beamCharging == nil) and 1 or 0
  -- recoil while it is firing
  local kick = firing * (0.5 + 0.5 * sin(self.age * 37)) * r * 0.03

  -- the ring bearing it turns on
  Draw.setColor(C.void)
  LG.ellipse("fill", tx, ty + r * 0.02, r * 0.20, r * 0.13)
  plate(tx, ty, 0, TAU, r * 0.11, r * 0.18, 0.66, C.deep, P.mix(C.hull, C.lit, 0.4), 1, 16)

  LG.push()
  LG.translate(tx - bx * kick, ty - by * kick)
  LG.rotate(ang)
  -- housing
  Draw.setColor(C.void)
  Draw.roundRect("fill", -r * 0.19, -r * 0.145, r * 0.40, r * 0.29, r * 0.04)
  Draw.linearGradient(-r * 0.165, -r * 0.122, r * 0.35, r * 0.244,
                      P.mix(C.hull, C.lit, 0.75), C.void, math.pi * 0.5)
  Draw.setColor(C.rim, 0.55)
  LG.setLineWidth(3)
  LG.line(-r * 0.165, -r * 0.120, r * 0.16, -r * 0.120)
  bolt(-r * 0.13, -r * 0.090, r * 0.021, 0.9)
  bolt(-r * 0.13, r * 0.090, r * 0.021, 0.9)
  -- a hazard chip on the shoulder of the housing
  hazard(-r * 0.05, -r * 0.128, r * 0.20, r * 0.052, r * 0.038, self.age * 4, 0.95)
  -- the barrel and its muzzle brake
  limb(r * 0.14, 0, r * 0.40, 0, r * 0.080, r * 0.060, C.void)
  limb(r * 0.14, -r * 0.016, r * 0.37, -r * 0.013, r * 0.048, r * 0.034,
       P.mix(C.deep, C.lit, 0.55))
  for k = 0, 2 do
    Draw.setColor(C.void, 0.95)
    LG.rectangle("fill", r * (0.20 + k * 0.058), -r * 0.062, r * 0.020, r * 0.124)
  end
  Draw.setColor(C.void)
  LG.ellipse("fill", r * 0.415, 0, r * 0.050, r * 0.072)
  Draw.setColor(P.mix(C.hull, C.lit, 0.5))
  LG.ellipse("fill", r * 0.405, 0, r * 0.040, r * 0.060)
  -- the lens: dark until it is asked for
  local heat = math.max(charge, firing)
  Draw.setColor(P.mix(C.void, P.danger, 0.25 + 0.75 * heat), 1)
  LG.ellipse("fill", r * 0.41, 0, r * 0.022, r * 0.040)
  LG.pop()

  if heat > 0.02 then
    local mx = tx + bx * r * 0.41 - bx * kick
    local my = ty + by * r * 0.41 - by * kick
    Draw.glow(mx, my, r * (0.06 + 0.12 * heat), P.danger, 0.20 + 0.22 * heat, 2)
  end
end

------------------------------------------------------------ intake assembly
--- The extraction throat: a bolted collar on four struts, a flared cone, and a
--- turbine inside it turning fast enough to blur. This used to be a capsule
--- with a circle on top and it read as a lollipop.
function Boss:drawIntake(lift)
  local r = self.radius
  local cy = lift + r * A.collarY
  local my = lift + r * A.mouthY
  local cr = r * A.collarR
  local mr = r * A.mouthR
  local crY = cr * A.collarSq
  local mrY = mr * A.mouthSq

  -- the cone wall, lit from up-left and falling into shadow at its base
  Draw.setColor(C.void)
  LG.polygon("fill", -mr - 2, my, mr + 2, my, cr + 2, cy, -cr - 2, cy)
  Draw.quad(-mr, my, mr, my, cr, cy, -cr, cy,
            P.mix(C.lit, C.hi, 0.35), P.mix(C.hull, C.lit, 0.45), C.void, C.deep)
  -- specular strip down the lit side
  Draw.quad(-mr * 0.66, my, -mr * 0.40, my, -cr * 0.40, cy, -cr * 0.66, cy,
            C.hi, C.hi, P.alpha(C.hi, 0), P.alpha(C.hi, 0), 0.30)
  -- fabrication ribs
  Draw.setColor(C.seam, 0.75)
  LG.setLineWidth(2)
  for k = -2, 2 do
    local t = k / 2.6
    LG.line(mr * t, my, cr * t, cy)
  end
  -- stiffening rings around the outside of the flare
  for k = 1, 3 do
    local t = k / 4
    local rr = U.lerp(cr, mr, t)
    local yy = U.lerp(cy, my, t)
    local ry = rr * U.lerp(A.collarSq, A.mouthSq, t)
    Draw.setColor(C.void, 0.85)
    LG.setLineWidth(r * 0.038)
    LG.ellipse("line", 0, yy, rr, ry, 28)
    earc(0, yy, rr, ry, math.pi + 0.2, TAU - 0.2, r * 0.020, P.mix(C.hull, C.lit, 0.5), 1)
    earc(0, yy, rr, ry, 0.2, math.pi - 0.2, r * 0.016, C.deep, 1)
  end
  -- a hazard band around the throat, where a person would have painted one
  LG.push()
  LG.translate(0, cy - crY * 0.30)
  hazard(-cr * 0.92, -r * 0.050, cr * 1.84, r * 0.10, r * 0.070, -self.age * 5, 0.95)
  LG.pop()

  -- collar: a bolted flange
  Draw.setColor(C.void)
  LG.ellipse("fill", 0, cy, cr * 1.10, crY * 1.10)
  Draw.setColor(C.hull)
  LG.ellipse("fill", 0, cy, cr * 1.02, crY * 1.02)
  -- the flange's top lip catches the key
  earc(0, cy, cr * 1.02, crY * 1.02, math.pi + 0.15, TAU - 0.15, 3, C.hi, 0.8)
  Draw.setColor(C.deep)
  LG.ellipse("fill", 0, cy, cr * 0.80, crY * 0.80)
  for k = 0, 9 do
    local a = k / 10 * TAU
    bolt(cos(a) * cr * 0.92, cy + sin(a) * crY * 0.92, r * 0.022, 1)
  end

  -- the mouth: outer rim, then the throat interior, then what is inside it
  Draw.setColor(C.void)
  LG.ellipse("fill", 0, my, mr * 1.06, mrY * 1.06)
  Draw.setColor(P.mix(C.hull, C.lit, 0.5))
  LG.ellipse("fill", 0, my, mr, mrY)
  Draw.setColor(C.void)
  LG.ellipse("fill", 0, my, mr * 0.84, mrY * 0.84)
  -- inlet vanes around the outside of the rim, angled into the flow
  for k = 0, 13 do
    local a = k / 14 * TAU
    local c = (k % 7 == 3) and C.hazard
              or P.mix(C.deep, C.hi, 0.3 + 0.5 * (0.5 + 0.5 * cos(a - math.pi * 1.25)))
    limb(cos(a) * mr * 0.90, my + sin(a) * mrY * 0.90,
         cos(a + 0.24) * mr * 1.10, my + sin(a + 0.24) * mrY * 1.10,
         r * 0.020, r * 0.008, c)
  end

  -- turbine: blades, ghosted backwards so it reads as spinning fast
  local spin = self._spin or 0
  local n = AR.drillBlades
  local sq = mrY / mr
  local rIn, rOut = mr * 0.15, mr * 0.74
  for ghost = AR.drillGhosts, 0, -1 do
    local s = spin - ghost * 0.20
    local ga = ghost == 0 and 1 or (0.30 / (ghost + 1))
    for k = 0, n - 1 do
      local a0 = s + k * TAU / n
      local a1 = a0 + 0.36
      local face = 0.5 + 0.5 * cos(a0 + 0.7)
      local cb = P.mix(C.dark, C.hi, 0.18 + face * 0.82)
      Draw.quad(cos(a0) * rIn, my + sin(a0) * rIn * sq,
                cos(a0 + 0.13) * rOut, my + sin(a0 + 0.13) * rOut * sq,
                cos(a1 + 0.13) * rOut, my + sin(a1 + 0.13) * rOut * sq,
                cos(a1) * rIn, my + sin(a1) * rIn * sq,
                cb, P.mix(cb, C.deep, 0.35), P.mix(cb, C.deep, 0.35), cb, ga)
    end
  end
  -- hub
  Draw.setColor(C.deep)
  LG.ellipse("fill", 0, my, rIn * 1.35, rIn * 1.35 * sq)
  Draw.setColor(C.rim, 0.8)
  LG.ellipse("fill", -rIn * 0.2, my - rIn * 0.2 * sq, rIn * 0.5, rIn * 0.5 * sq)

  -- the light coming up out of the throat, and the hard rim above it
  local pulse = 0.7 + 0.3 * sin(self.age * 3.4)
  local throat = P.mix(C.air, C.taken, 0.5)
  Draw.additive(function()
    Draw.setColor(throat, 0.24 * pulse)
    LG.ellipse("fill", 0, my, mr * 0.70, mrY * 0.70)
    Draw.glow(0, my, mr * 0.95 * pulse, throat, 0.26)
  end)
  Draw.setColor(C.rim, 0.55)
  LG.setLineWidth(2)
  LG.ellipse("line", 0, my, mr, mrY)
  earc(0, my, mr, mrY, 0.1, math.pi - 0.1, 3, C.void, 0.7)

  -- Phase 1 the throat is *sealed*: a grille across the mouth. Phase 2 it is
  -- half torn away; phase 3 it is gone. The machine opening up over the fight
  -- is the whole silhouette read.
  if self.phase < 3 then
    local span = self.phase == 1 and TAU or math.pi * 1.15
    local bars = self.phase == 1 and 6 or 4
    for k = 0, bars - 1 do
      local a = -0.4 + k / 6 * TAU
      limb(cos(a) * mr * 0.10, my + sin(a) * mr * 0.10 * sq,
           cos(a) * mr * 0.86, my + sin(a) * mr * 0.86 * sq,
           r * 0.024, r * 0.016, C.deep)
      limb(cos(a) * mr * 0.10, my + sin(a) * mr * 0.10 * sq - r * 0.009,
           cos(a) * mr * 0.86, my + sin(a) * mr * 0.86 * sq - r * 0.007,
           r * 0.009, r * 0.006, P.mix(C.deep, C.hull, 0.6))
    end
    if self.phase == 2 then
      earc(0, my, mr * 0.86, mr * 0.86 * sq, -0.4 + span, -0.4 + span + 0.3, 2, C.torn, 0.9)
    end
  end
  LG.setLineWidth(1)
end

--------------------------------------------------------------------- column
--- The column of taken air, going up out of the frame.
---
--- This is the one part of the rig you can see from anywhere on the island, and
--- that is its job: wherever the player is standing, the thing that is emptying
--- the sky is a visible line on the horizon. It also gives the fight a vertical
--- axis, which nothing else in a top-down game has.
---
--- It is cyan at the mouth and violet at the top on purpose: cyan is the colour
--- of the oxygen readout in the HUD, so what is going up the column is legibly
--- the number that is falling.
function Boss:drawColumn()
  local r = self.radius
  local h = T.columnHeight
  local arrive, lift = self:pose()
  local k = arrive
  if k <= 0.01 then return end
  local x = self.x
  local y = self.y + lift + r * A.mouthY

  local function W(t) return r * (0.44 + 2.30 * t ^ 0.70) end
  local puls = 0.80 + sin(self.age * 2.2) * 0.20

  Draw.additive(function()
    -- the shaft, as four nested tapers: cyan at the mouth, violet where it goes
    for i = 1, 4 do
      local f = i / 4
      local a = (0.30 - i * 0.048) * puls * k
      local steps = 5
      for s = 0, steps - 1 do
        local t0, t1 = s / steps, (s + 1) / steps
        local w0, w1 = W(t0) * f, W(t1) * f
        local c0 = P.mix(C.air, C.sky, U.saturate(t0 * 1.5))
        local c1 = P.mix(C.air, C.sky, U.saturate(t1 * 1.5))
        Draw.quad(x - w0, y - h * t0, x + w0, y - h * t0,
                  x + w1, y - h * t1, x - w1, y - h * t1,
                  c0, c0, P.alpha(c1, (1 - t1) * 0.9), P.alpha(c1, (1 - t1) * 0.9), a)
      end
    end
    -- the hot line up the middle
    for s = 0, 5 do
      local t0, t1 = s / 6, (s + 1) / 6
      local w0, w1 = r * 0.10 * (1 - t0 * 0.4), r * 0.10 * (1 - t1 * 0.4)
      local c0 = P.mix(C.airHot, C.skyHi, t0)
      local c1 = P.mix(C.airHot, C.skyHi, t1)
      Draw.quad(x - w0, y - h * t0, x + w0, y - h * t0,
                x + w1, y - h * t1, x - w1, y - h * t1,
                P.alpha(c0, 1 - t0 * 0.8), P.alpha(c0, 1 - t0 * 0.8),
                P.alpha(c1, 1 - t1 * 0.8), P.alpha(c1, 1 - t1 * 0.8), 0.60 * puls * k)
    end

    -- pressure rings travelling up it: the thing that makes a smear read as a
    -- flow with a direction
    for i = 1, AR.columnRings do
      local t = (self.age * AR.columnRise + i / AR.columnRings) % 1
      local w = W(t)
      local a = U.saturate((t - 0.03) * 9) * (1 - t) * (1 - t) * 0.60 * k
      Draw.setColor(P.mix(C.airHot, C.sky, t), a)
      LG.setLineWidth(2 + (1 - t) * 5)
      LG.ellipse("line", x, y - h * t, w, w * 0.20, 30)
    end

    -- motes on a slow helix, so the column has volume
    for i = 1, AR.columnMotes do
      local t = (self.age * AR.columnRise * 1.7 + i / AR.columnMotes) % 1
      local a = i * 2.399 + self.age * 1.6
      local w = W(t)
      local mx = x + cos(a) * w * 0.82
      local my = y - h * t + sin(a) * w * 0.16
      local s = r * 0.05 * (1 - t * 0.6)
      Draw.setColor(P.mix(C.airHot, C.skyHi, t), (1 - t) * 0.95 * k)
      LG.circle("fill", mx, my, s, 6)
    end

    -- the bloom where it leaves the machine
    Draw.glow(x, y - r * 1.00, r * 1.00 * puls, C.airHot, 0.42 * k)
    Draw.glow(x, y - h * 0.05, r * 2.6 * puls, C.taken, 0.34 * k)
  end)
  LG.setLineWidth(1)
end

--- What the throat is pulling in: leaves and motes spiralling inward and up.
--- Drawn over the hull, because half of them pass in front of it.
function Boss:drawSuction(arrive, lift)
  local r = self.radius
  local reach = r * AR.suctionReach
  local my = self.y + lift + r * A.mouthY
  for i = 1, AR.suctionMotes do
    local seed = i * 7
    local t = (self.age * AR.suctionRate + hash(seed, 3, 1)) % 1
    local a0 = hash(seed, 5, 2) * TAU
    local a = a0 + t * 2.4
    local d = reach * (1 - t) * (1 - t)
    local rise = t * t
    local mx = self.x + cos(a) * d
    local mya = U.lerp(self.y + sin(a) * d * 0.6 + r * 0.1, my, rise)
    local leafy = hash(seed, 11, 3) > 0.55
    local s = r * (0.030 + hash(seed, 13, 4) * 0.030)
    local fade = U.saturate(t * 4) * (1 - t * t) * arrive
    if leafy then
      Draw.setColor(P.shade(P.ramp.leaf, 1 + hash(seed, 17, 5)), fade * 0.85)
      Draw.blob(mx, mya, s * 1.5, 6, seed, 0.3, 0.5)
    else
      Draw.setColor(P.mix(C.air, C.airHot, hash(seed, 19, 6)), fade * 0.8)
      LG.circle("fill", mx, mya, s * 0.6, 5)
    end
  end
end

----------------------------------------------------------------- telegraphs
--- The ground read for both attacks. A player in a busy frame gets one shape
--- per attack, on the floor, growing or shrinking toward the moment it lands.
function Boss:drawTelegraph(arrive)
  local r = self.radius
  local g = LG
  if self.state == "slam" then
    local t = self.stateT
    if t < AR.slamTell then
      local k = U.saturate(t / AR.slamTell)
      local rr = AR.slamRadius * U.lerp(1.35, 1.0, U.ease.inQuad(k))
      local cy = self.y + r * 0.16
      Draw.radialGradient(self.x, cy, rr, P.alpha(P.danger, 0.05 + 0.10 * k),
                          P.alpha(P.danger, 0.16 + 0.26 * k), rr * 0.44)
      -- the closing ring, on the ground plane rather than standing up in the
      -- middle of the frame: love.graphics.arc only knows circles
      earc(self.x, cy, rr, rr * 0.44, 0, TAU, 9 + k * 9, P.danger, 0.18 + 0.22 * k)
      earc(self.x, cy, rr, rr * 0.44, 0, TAU, 3 + k * 4, P.danger, 0.55 + 0.45 * k)
      -- and a second, honest ring at the radius it will actually reach
      edash(self.x, cy, AR.slamRadius, AR.slamRadius * 0.44, 22, 0.55, 3,
            P.warn, 0.45 + 0.45 * k, self.age * 0.9)
      -- chevrons converging on the impact
      for i = 0, 5 do
        local a = i * TAU / 6 + self.age * 0.4
        local d = AR.slamRadius * U.lerp(1.30, 0.55, U.ease.inQuad(k))
        Draw.setColor(P.warn, 0.7 * k)
        Draw.chevron(self.x + cos(a) * d, self.y + r * 0.16 + sin(a) * d * 0.44,
                     r * 0.24, a + math.pi, 4, 0.7)
      end
    else
      local k = U.saturate((t - AR.slamTell) / AR.slamRing)
      local rr = AR.slamRadius * U.ease.outCubic(k)
      local a = (1 - k) * (1 - k)
      Draw.additive(function()
        Draw.setColor(P.white, 0.55 * a)
        g.setLineWidth(10 * a + 2)
        g.ellipse("line", self.x, self.y + r * 0.16, rr, rr * 0.44, 48)
        Draw.setColor(P.danger, 0.8 * a)
        g.setLineWidth(20 * a + 2)
        g.ellipse("line", self.x, self.y + r * 0.16, rr * 0.86, rr * 0.86 * 0.44, 48)
      end)
      -- dust thrown out along the ground
      for i = 1, 20 do
        local aa = hash(i, 3, 2) * TAU
        local d = rr * (0.6 + hash(i, 5, 3) * 0.5)
        Draw.setColor(C.ashHi, 0.5 * a)
        Draw.blob(self.x + cos(aa) * d, self.y + r * 0.16 + sin(aa) * d * 0.44,
                  r * (0.10 + hash(i, 7, 4) * 0.14), 7, i * 13, 0.4, 0.5)
      end
      g.setLineWidth(1)
    end
  end

  if self.beamCharging then
    local k = self.beamCharging
    local a = self.beamAngle
    local tx, ty, ta = self:emitterPos(0)
    local x0, y0 = self.x + tx + cos(ta) * r * 0.41, self.y + ty + sin(ta) * 0.68 * r * 0.41
    local range = AR.beamRange
    -- the lane it will burn
    Draw.setColor(P.danger, 0.16 + 0.20 * k)
    local w = r * 0.30 * (0.4 + k * 0.6)
    local dxn, dyn = cos(a), sin(a)
    local nx, ny = -dyn * w, dxn * w
    Draw.quad(x0 + nx, y0 + ny, x0 - nx, y0 - ny,
              x0 + dxn * range - nx * 0.5, y0 + dyn * range - ny * 0.5,
              x0 + dxn * range + nx * 0.5, y0 + dyn * range + ny * 0.5,
              P.danger, P.danger, P.alpha(P.danger, 0.2), P.alpha(P.danger, 0.2))
    Draw.dashedLine(x0, y0, x0 + dxn * range, y0 + dyn * range,
                    30, 20, -self.age * 260, 2 + k * 3, P.warn)
    -- converging guides
    for s = -1, 1, 2 do
      local ga = a + s * (1 - k) * 0.24
      Draw.setColor(P.warn, 0.25 + 0.4 * k)
      LG.setLineWidth(2)
      LG.line(x0, y0, x0 + cos(ga) * range, y0 + sin(ga) * range)
    end
    -- the emitter winding up: a ring closing on it, and a lock flash at the end
    Draw.ring(x0, y0, r * (2.2 - 1.5 * k), 3, 0, TAU, P.danger, 3)
    if k > 0.88 then
      Draw.additive(function()
        Draw.setColor(P.mix(P.warn, P.white, 0.5), (k - 0.88) / 0.12 * 0.55)
        LG.circle("fill", x0, y0, r * 0.15, 14)
      end)
    end
    LG.setLineWidth(1)
  end
end

--- The beam itself. It leaves a turret now, so it can behave like something a
--- turret fired: tightest at the muzzle, opening downrange, hard-edged, and
--- shedding spall sideways off whatever it is cutting.
---
--- It used to be drawn wide at the muzzle -- three tapered passes, a white
--- core, seven diamonds and a 62 px radial bloom all stacked in the same
--- inch -- which clipped to paper white and read as a lens flare parked on the
--- barrel. None of that is how a cut looks. A cut is a thin bright line with
--- a tight halo and a mess coming off the workpiece.
function Boss:drawBeam(lift)
  local r = self.radius
  local a = self.beamAngle
  local tx, ty, ta = self:emitterPos(lift)
  local ex = self.x + tx + cos(ta) * r * 0.41
  local ey = self.y + ty + sin(ta) * 0.68 * r * 0.41
  local range = AR.beamRange
  local ux, uy = cos(a), sin(a)
  local nx, ny = -uy, ux
  local x2, y2 = ex + ux * range, ey + uy * range

  -- scorch under it, so the sweep leaves a mark rather than floating
  Draw.setColor(C.void, 0.45)
  local sx, sy = nx * r * 0.20, ny * r * 0.20
  Draw.quad(ex + sx, ey + sy, ex - sx, ey - sy,
            x2 - sx * 0.4, y2 - sy * 0.4, x2 + sx * 0.4, y2 + sy * 0.4,
            C.void, C.void, P.alpha(C.void, 0), P.alpha(C.void, 0))

  local flick = 0.90 + 0.10 * sin(self.age * 41)
  local segs = 8

  --- One pass of the shaft: core half-width `w0` at the muzzle opening to `w1`
  --- at the far end, with a soft flank either side of it so the profile falls
  --- off instead of ending in a hard edge. Three flat ribbons stacked on each
  --- other read as a printed stripe; a beam has to have a section.
  local function shaft(w0, w1, c, a0, a1, soft)
    soft = soft or 2.4
    local fade = P.alpha(c, 0)
    local px, py, pw, pa = ex, ey, w0, a0
    for k = 1, segs do
      local t  = k / segs
      local w  = U.lerp(w0, w1, t ^ 0.55)
      local al = U.lerp(a0, a1, t)
      local qx, qy = ex + ux * range * t, ey + uy * range * t
      local c0, c1 = P.alpha(c, pa), P.alpha(c, al)
      -- core
      Draw.quad(px + nx * pw, py + ny * pw, px - nx * pw, py - ny * pw,
                qx - nx * w, qy - ny * w, qx + nx * w, qy + ny * w,
                c0, c0, c1, c1)
      -- and a flank either side of it, falling to nothing
      for side = -1, 1, 2 do
        Draw.quad(px + nx * side * pw, py + ny * side * pw,
                  px + nx * side * pw * soft, py + ny * side * pw * soft,
                  qx + nx * side * w * soft, qy + ny * side * w * soft,
                  qx + nx * side * w, qy + ny * side * w,
                  c0, fade, fade, c1)
      end
      px, py, pw, pa = qx, qy, w, al
    end
  end

  Draw.additive(function()
    shaft(r * AR.beamMuzzleW, r * AR.beamFarW * flick, P.danger, 0.34, 0.02, 2.6)
    shaft(r * AR.beamMuzzleW * 0.44, r * AR.beamFarW * 0.40 * flick,
          P.mix(P.danger, P.warn, 0.40), 0.50, 0.04, 2.2)
    -- the cut itself: thin, hard, and the only part allowed near white
    shaft(r * 0.014, r * 0.026, P.mix(P.warn, P.white, 0.55), 0.85, 0.12, 1.8)

    -- The muzzle, as gas leaving a brake rather than as a star: two short
    -- petals across the barrel and a bloom a quarter the size of the old one.
    local mf = 0.72 + 0.28 * sin(self.age * 53)
    local mw = r * AR.beamMuzzle * mf
    for side = -1, 1, 2 do
      Draw.quad(ex - ux * mw * 0.10, ey - uy * mw * 0.10,
                ex + nx * side * mw * 0.26 + ux * mw * 0.06,
                ey + ny * side * mw * 0.26 + uy * mw * 0.06,
                ex + nx * side * mw + ux * mw * 0.50,
                ey + ny * side * mw + uy * mw * 0.50,
                ex + ux * mw * 0.70, ey + uy * mw * 0.70,
                P.alpha(P.warn, 0.40), P.alpha(P.warn, 0.30),
                P.alpha(P.warn, 0), P.alpha(P.warn, 0.10))
    end
    -- and nothing round. A radial bloom at the muzzle is the whole reason the
    -- old beam read as a lens flare, so what is left here is directional: the
    -- petals above, and a short hot stub down the barrel's own line.
    Draw.quad(ex + nx * r * 0.055, ey + ny * r * 0.055,
              ex - nx * r * 0.055, ey - ny * r * 0.055,
              ex + ux * mw * 1.5 - nx * r * 0.018, ey + uy * mw * 1.5 - ny * r * 0.018,
              ex + ux * mw * 1.5 + nx * r * 0.018, ey + uy * mw * 1.5 + ny * r * 0.018,
              P.alpha(P.warn, 0.34), P.alpha(P.warn, 0.34),
              P.alpha(P.warn, 0), P.alpha(P.warn, 0))

    -- spall coming off the cut, thrown sideways and backwards down the lane.
    -- This is the tell that the beam is *doing* something to what it crosses.
    local tick = floor(self.age * 9)
    for i = 1, AR.beamSpall do
      local t = (self.age * 1.1 + i / AR.beamSpall) % 1
      local d = t * range
      local px, py = ex + ux * d, ey + uy * d
      -- thrown clear of the lane, not down it: spall inside the beam is just
      -- a dashed line and reads as a texture on the ribbon
      local side = (hash(i, tick, 3) > 0.5) and 1 or -1
      local off = r * (0.16 + 0.18 * hash(i, tick, 7))
      local l = r * (0.09 + 0.16 * hash(i, tick, 5))
      Draw.setColor(P.mix(P.warn, P.white, 0.35), 0.60 * (1 - t))
      LG.setLineWidth(1.5)
      LG.line(px + nx * side * off, py + ny * side * off,
              px + nx * side * (off + l) - ux * l * 1.10,
              py + ny * side * (off + l) - uy * l * 1.10)
    end
  end)
  LG.setLineWidth(1)
end

------------------------------------------------------------------------- draw
function Boss:draw()
  self:tick()
  local r = self.radius
  local arrive, lift, footY, jx = self:pose()
  local hurt = self.flash or 0

  self:drawColumn()
  self:drawFootprint(arrive, lift, footY)
  self:drawTelegraph(arrive)

  LG.push()
  LG.translate(self.x + jx, self.y)

  -- back legs first, then the hull, then the legs in front of it: six planks
  -- radiating out of a disc is what a top-down machine looks like when it has
  -- no depth order at all.
  for i = 0, 5 do
    if sin(i * TAU / 6 + math.pi / 12) < 0 then
      self:drawLeg(i, arrive, lift, footY, "dark")
      self:drawLeg(i, arrive, lift, footY, "lit")
    end
  end

  self:drawChassis(lift)
  self:drawSkirt(lift)
  self:drawDeck(lift)
  self:drawIntake(lift)

  for i = 0, 5 do
    if sin(i * TAU / 6 + math.pi / 12) >= 0 then
      self:drawLeg(i, arrive, lift, footY, "dark")
      self:drawLeg(i, arrive, lift, footY, "lit")
    end
  end

  -- The plates catching a hit they will not let through. This is the moment the
  -- fight is *about* -- the player cannot finish it alone -- so it gets a hard
  -- deflection shell rather than a tinted circle.
  local hb = self.hullBlock or 0
  if hb > 0.02 then
    Draw.additive(function()
      local k = hb * hb
      for s = 0, 5 do
        local a0 = s / 6 * TAU + 0.06
        local a1 = (s + 1) / 6 * TAU - 0.06
        plate(0, lift, a0, a1, r * (1.10 + 0.16 * (1 - hb)), r * (1.26 + 0.16 * (1 - hb)),
              A.skirtSq, P.warn, P.alpha(P.warn, 0), 0.85 * k, 4)
      end
      -- the shell's own edge, warm rather than white: the message is ARMOUR
      -- HOLDING, and a white flash on a machine whose only warm note is the
      -- hazard paint reads as damage rather than as a refusal
      Draw.setColor(P.mix(P.warn, P.white, 0.45), 0.42 * k)
      LG.setLineWidth(2 + 4 * k)
      LG.ellipse("line", 0, lift, r * 1.12, r * 1.12 * A.skirtSq, 40)
    end)
    LG.setLineWidth(1)
  end

  -- a landed hit: the whole machine takes the flash, not a tinted overlay disc
  if hurt > 0.001 then
    Draw.additive(function()
      Draw.setColor(P.white, hurt * 1.6)
      ngon("fill", 0, lift, r * A.chassisR, r * A.chassisSq, 8, math.pi / 8)
      ngon("fill", 0, lift + r * A.deckY, r * A.deckR, r * A.deckSq, 8, math.pi / 8)
    end)
  end

  LG.pop()

  self:drawSuction(arrive, lift)

  if self.state == "beam" and not self.beamCharging then self:drawBeam(lift) end
  Draw.setColor(P.white, 1)
  LG.setLineWidth(1)
end

function Boss:emitLight(Lighting)
  local r = self.radius
  -- The rig lights its own footprint: at night it was fighting in the dark and
  -- the player could not see the ground they were standing on.
  --
  -- The key is a cold near-neutral on purpose. A violet key at any useful
  -- brightness painted the rig's own dark hull lavender and it stopped reading
  -- as metal at all; the colour belongs on the ground and in the throat.
  -- `softness = 1` matters more than the gain here: the tight falloff put a
  -- bright disc the size of the deck right in the middle of the machine and no
  -- amount of drawing survives a hotspot sitting on top of it.
  Lighting.addLight(self.x, self.y + r * 0.60, AR.keyRadius, P.ramp.metal[3], AR.keyGain,
                    { flicker = 0.04, softness = 1 })
  -- Amber, matching the beacon: see drawFootprint. Red on this machine is the
  -- beam and nothing else.
  local strobe = math.max(0, math.sin(self.age * TAU * AR.strobeHz)) ^ 2
  Lighting.addLight(self.x, self.y + r * 0.55, AR.strobeRadius, C.hazard,
                    AR.strobeGain * (0.35 + 0.65 * strobe), { softness = 1 })
  Lighting.addLight(self.x, self.y + r * A.mouthY, AR.throatRadius, P.o2,
                    AR.throatGain * (0.75 + 0.25 * math.sin(self.age * 3.4)))
  if (self.coreOpen or 0) > 0 then
    Lighting.addLight(self.x, self.y + r * 0.30, AR.moltenRadius, P.ramp.ember[3],
                      AR.moltenGain * (0.8 + 0.2 * math.sin(self.age * 3)), { softness = 1 })
  end
  if self.state == "beam" then
    Lighting.addLight(self.x, self.y, 700, P.danger, 1.4)
  end
end

return Boss
