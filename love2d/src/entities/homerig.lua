-- The Home Rig: the wreck the last human works out of. It is the respawn point,
-- the harvesters' drop-off, and the one landmark on the island that never moves.
local Class  = require("src.core.class")
local U      = require("src.core.util")
local Entity = require("src.entities.entity")
local P      = require("src.engine.palette")
local Opt    = require("src.core.optional")

local Draw = Opt.require("src.engine.draw")
local VFX  = Opt.require("src.engine.vfx")

local Rig = Class("HomeRig", Entity)

function Rig:init(x, y, world)
  Rig.super.init(self, x, y)
  self.kind   = "rig"
  self.world  = world
  self.radius = 46
  self.z      = -6
  self.spin   = 0
  self.smokeT = 0
  self.rng    = U.rng(math.floor(x * 5 + y * 11))
  -- a handful of static struts, generated once so the wreck is never symmetrical
  self.struts = {}
  for i = 1, 5 do
    self.struts[i] = { a = self.rng:angle(), len = self.rng:range(0.7, 1.25),
                       w = self.rng:range(0.09, 0.16) }
  end
end

function Rig:update(dt)
  self:updateCommon(dt)
  self.spin = self.spin + dt * 0.55
  self.smokeT = self.smokeT - dt
  if self.smokeT <= 0 then
    self.smokeT = self.rng:range(0.5, 1.4)
    VFX.emit("mist", self.x + self.rng:range(-8, 8), self.y - self.radius * 0.8,
             { count = 1, power = 0.4 })
  end
end

function Rig:drawShadow()
  Draw.softShadow(self.x, self.y + 8, self.radius * 1.25, self.radius * 0.5, 0.4)
end

local function metal(t) return P.shade(P.ramp.metal, t) end

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

  -- deposit ring, so it reads as a place things are brought to
  Draw.setColor(P.ramp.cobalt[3], 0.22)
  Draw.dashedCircle(0, r * 0.35, r * 1.35, 10, 9, self.spin * 12, 1.5)

  g.pop()
end

function Rig:emitLight(Lighting)
  local pulse = 0.6 + math.sin(self.spin * 2.4) * 0.4
  Lighting.addLight(self.x + self.radius * 0.42, self.y - self.radius * 1.58,
                    260, P.accent, 0.75 + pulse * 0.35, { flicker = 0.04 })
  Lighting.addLight(self.x, self.y, 150, P.eye, 0.35)
end

return Rig
