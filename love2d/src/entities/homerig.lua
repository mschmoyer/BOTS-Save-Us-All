-- The Home Rig: the wreck the last human works out of. It is the respawn point,
-- the harvesters' drop-off, and the one landmark on the island that never moves.
local Class  = require("src.core.class")
local U      = require("src.core.util")
local Entity = require("src.entities.entity")
local P      = require("src.engine.palette")
local Opt    = require("src.core.optional")

local Draw = Opt.require("src.engine.draw")
local VFX  = Opt.require("src.engine.vfx")
local Text = require("src.engine.text")
local TU   = require("src.game.tuning")

local Rig = Class("HomeRig", Entity)

------------------------------------------------------------------- the radio
-- TODO: this belongs in game/script.lua's S.hud; parked here to avoid a
-- concurrent edit.
-- Every word the interface says lives in game/script.lua.
local STR = require("src.game.script").dawn

--- The readout is set in the bot nameplate's type, because it is the same kind
--- of object: a machine, near you, saying what it is. Shared and mutated in
--- place like bot.lua's -- read, do not keep.
local PLATE_OPTS = { align = "center", tracking = 0.05 }

-- Light options, hoisted. `Lighting.addLight` reads the table and copies what
-- it needs into its parallel arrays -- it never keeps a reference -- so a
-- constant options table is a constant, and building one per light per frame
-- was pure garbage. Same idiom as `demo_light.lua`'s OPT_ tables.
local OPT_RIGLAMP = { flicker = 0.04 }

function Rig:init(x, y, world)
  Rig.super.init(self, x, y)
  self.kind   = "rig"
  self.world  = world
  self.radius = 46
  self.z      = -6
  self.spin   = 0
  self.smokeT = 0
  -- The radio. Its own clock, because the ending stops it and nothing else on
  -- the rig stops with it.
  self.radio  = true
  self.radioT = 0
  self.plate  = STR.signals .. "  " .. tostring(TU.radio.signals)
  self.rng    = U.rng(math.floor(x * 5 + y * 11))
  -- a handful of static struts, generated once so the wreck is never symmetrical
  self.struts = {}
  for i = 1, 5 do
    self.struts[i] = { a = self.rng:angle(), len = self.rng:range(0.7, 1.25),
                       w = self.rng:range(0.09, 0.16) }
  end
end

--- Where the radio lamp is pointing, as a brightness. A slow turn raised to a
--- power, so most of a revolution is the back of the lamp and the pass is
--- short: a rotating beacon reads as a rotating beacon and a sine wave reads as
--- a pulse, and a pulse is a thing that is trying to tell you something.
function Rig:radioSweep()
  if not self.radio then return 0 end
  local face = 0.5 + 0.5 * math.cos(self.radioT * (math.pi * 2) / TU.radio.sweep)
  return TU.radio.floor + (1 - TU.radio.floor) * face ^ TU.radio.peak
end

--- The one hook the ending needs.
---
--- scenes/ending.lua's suit-off beat already calls `ctx.onSuitOff`; this is the
--- other half of the same line ("Or the radio."). It kills the lamp -- the
--- bead goes to hull metal, the glow and the light it was putting on the mast
--- go with it -- and freezes the readout, which has read the same number for
--- the whole run and now stops being a live instrument at all. Idempotent, and
--- there is no way back on by design.
function Rig:radioOff()
  self.radio = false
end

function Rig:update(dt)
  self:updateCommon(dt)
  self.spin = self.spin + dt * 0.55
  if self.radio then self.radioT = self.radioT + dt end
  -- No steam plume: `mist` is the island-scale ambient bank and emitting it from
  -- a fixed point stacked nine-second, three-hundred-pixel clouds into a
  -- permanent grey smear. The mast light is the rig's silhouette cue.
end

function Rig:drawShadow()
  Draw.softShadow(self.x, self.y + 8, self.radius * 1.25, self.radius * 0.5, 0.4)
end

--- The hull's shades, cached on the ramp position. `P.shade` returns a fresh
--- table per call and the rig asks for six fixed ones every frame; the call
--- sites all pass literals, so this holds six entries. Shared: read, do not
--- keep or edit.
local METAL_C = {}
local function metal(t)
  local c = METAL_C[t]
  if not c then c = P.shade(P.ramp.metal, t) METAL_C[t] = c end
  return c
end

function Rig:draw()
  local g = love.graphics
  local r = self.radius

  g.push()
  g.translate(self.x, self.y)

  Draw.setColor(metal(1.2))
  for i = 1, #self.struts do
    local s = self.struts[i]
    Draw.capsule("fill", 0, 0, math.cos(s.a) * r * s.len,
                 math.sin(s.a) * r * s.len * 0.6 + r * 0.3, r * s.w)
  end

  -- hull: a squat hexagonal shell, listing slightly where it came down
  g.push()
  g.rotate(0.09)
  Draw.setColor(metal(1.7))
  Draw.hexagon(0, r * 0.1, r * 0.94, 0.0)
  Draw.setColor(metal(2.5))
  Draw.hexagon(0, -r * 0.04, r * 0.78, 0.0)
  Draw.setColor(metal(3.1))
  Draw.hexagon(0, -r * 0.1, r * 0.5, 0.0)
  g.pop()

  Draw.setColor(metal(1.4))
  Draw.roundRect("fill", -r * 0.86, -r * 0.62, r * 1.72, r * 0.3, r * 0.12)

  -- mast light: what you look for from across the island
  Draw.setColor(metal(2.2))
  Draw.capsule("fill", r * 0.28, -r * 0.4, r * 0.42, -r * 1.5, r * 0.09)
  local pulse = 0.6 + math.sin(self.spin * 2.4) * 0.4
  Draw.setColor(P.accent, 0.55 + pulse * 0.45)
  g.circle("fill", r * 0.42, -r * 1.58, r * 0.13)
  Draw.glow(r * 0.42, -r * 1.58, r * (1.4 + pulse * 0.8), P.accent, 0.5)

  -- The radio mast. A second, thinner spar on the other side of the hull, and
  -- the one amber light on the island: everything else the player builds is
  -- green, blue or white, so the eye files this as a different machine doing a
  -- different job without anyone having to say so. It turns, it never changes
  -- during a run, and nothing in the game ever remarks on it.
  local rk = self:radioSweep()
  Draw.setColor(metal(1.8))
  Draw.capsule("fill", -r * 0.30, -r * 0.30, -r * 0.40, -r * 1.16, r * 0.06)
  Draw.setColor(metal(1.4))
  Draw.capsule("fill", -r * 0.40, -r * 0.86, -r * 0.66, -r * 0.74, r * 0.045)
  if self.radio then
    Draw.setColor(P.radioLamp, 0.45 + rk * 0.55)
    g.circle("fill", -r * 0.40, -r * 1.22, r * 0.10)
    Draw.glow(-r * 0.40, -r * 1.22, r * (0.7 + rk * 1.5), P.radioLamp,
              0.20 + rk * 0.42, 3)
  else
    Draw.setColor(metal(2.0))
    g.circle("fill", -r * 0.40, -r * 1.22, r * 0.10)
  end

  -- deposit ring, so it reads as a place things are brought to
  Draw.setColor(P.ramp.cobalt[3], 0.22)
  Draw.dashedCircle(0, r * 0.35, r * 1.35, 10, 9, self.spin * 12, 1.5)

  g.pop()

  self:drawRadioPlate()
end

--- What the radio has heard, printed on the rig for anyone standing next to
--- it. It is a number, it is zero, and it is zero for the whole run -- there is
--- no interaction, no toast when you walk past and no moment where it moves.
--- The wording never changes either, which is the same rule the dawn screen's
--- radio row runs under and for the same reason: it has to be furniture long
--- enough that the player stops reading it.
function Rig:drawRadioPlate()
  local p = self.world and self.world.player
  if not p then return end
  local R = TU.radio
  local d = U.dist(self.x, self.y, p.x, p.y)
  local a = U.saturate((R.plateNear + R.plateFade - d) / R.plateFade) * R.plateAlpha
  if a < 0.03 then return end

  local size = R.plateSize
  local y = self.y - self.radius * 2.05 - size
  local tw = Text.width(self.plate, size, PLATE_OPTS)
  Draw.setColor(P.black, 0.45 * a)
  Draw.roundRect("fill", self.x - tw * 0.5 - 3.5, y - 2.5, tw + 7,
                 size + 5.5, (size + 5.5) * 0.5)
  PLATE_OPTS.color = P.inkDim
  PLATE_OPTS.alpha = a
  Text.display(self.plate, self.x, y, size, PLATE_OPTS)
end

function Rig:emitLight(Lighting)
  local pulse = 0.6 + math.sin(self.spin * 2.4) * 0.4
  Lighting.addLight(self.x + self.radius * 0.42, self.y - self.radius * 1.58,
                    260, P.accent, 0.75 + pulse * 0.35, OPT_RIGLAMP)
  Lighting.addLight(self.x, self.y, 150, P.eye, 0.35)
  -- The radio lamp puts its own light on the mast, or it does not, which is the
  -- only way the ending's `radioOff()` shows at any distance.
  local rk = self:radioSweep()
  if rk > 0.02 then
    Lighting.addLight(self.x - self.radius * 0.40, self.y - self.radius * 1.22,
                      TU.radio.lampRange, P.radioLamp, 0.18 + rk * 0.5)
  end
end

return Rig
