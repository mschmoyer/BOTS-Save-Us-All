-- Cobalt: deposits you break and loose chunks that fly to whoever earned them.
local Class  = require("src.core.class")
local U      = require("src.core.util")
local Entity = require("src.entities.entity")
local P      = require("src.engine.palette")
local Opt    = require("src.core.optional")
local T      = require("src.game.tuning").cobalt

local Draw  = Opt.require("src.engine.draw")
local VFX   = Opt.require("src.engine.vfx")
local Audio = Opt.require("src.engine.audio")

local Cobalt = Class("Cobalt", Entity)

-- Light options, hoisted. `Lighting.addLight` reads the table and copies what
-- it needs into its parallel arrays -- it never keeps a reference -- so a
-- constant options table is a constant, and building one per light per frame
-- was pure garbage. Same idiom as `demo_light.lua`'s OPT_ table.
local OPT_SHIMMER = { flicker = 0.06 }

-- The crystal's three fixed facet colours, resolved once. `P.shade` blends two
-- ramp stops into a *fresh table* on every call, and a deposit draws five
-- shards of four facets each: twenty tables per deposit per frame, which
-- measured 1.8 KB a frame for a single node and was the second-largest
-- allocator in `World:draw`. The fourth facet is the one that moves with the
-- shimmer, so it is resolved once per deposit just above the shard loop
-- instead of once per shard.
local FACET_BASE = P.shade(P.ramp.cobalt, 1.15)
local FACET_BODY = P.shade(P.ramp.cobalt, 1.9)
local FACET_TIP  = P.shade(P.ramp.cobalt, 4)

function Cobalt:init(x, y, world, rng, isNode)
  Cobalt.super.init(self, x, y)
  self.kind   = "cobalt"
  self.world  = world
  self.rng    = rng or U.rng(math.floor(x * 7 + y * 3))
  self.node   = isNode ~= false
  self.radius = self.node and 20 or 9
  self.left   = self.node and T.nodeYield or T.chunkValue
  self.shards = {}
  local n = self.node and 5 or 3
  for i = 1, n do
    self.shards[i] = {
      a  = self.rng:angle(),
      d  = self.rng:range(0.15, 0.85) * self.radius,
      s  = self.rng:range(0.35, 1.0) * self.radius * 0.62,
      rot = self.rng:angle(),
      ph = self.rng:angle(),
    }
  end
  self.seekT  = 0
  self.homing = nil
end

function Cobalt:update(dt)
  self:updateCommon(dt)
  if (self.mineT or 0) > 0 then self.mineT = self.mineT - dt end
  -- only for deposits the player can actually see: an island's worth of
  -- off-screen shimmer is a particle budget spent on nothing
  local cam = self.world and self.world.camera
  if self.node and (not cam or cam:visible(self.x, self.y, self.radius * 3)) then
    self:ambient(dt)
  end
  if self.homing then
    local t = self.homing
    local dx, dy, d = U.norm(t.x - self.x, t.y - self.y)
    local sp = T.driftSpeed * U.remapc(self.seekT, 0, 0.4, 0.35, 1)
    self.seekT = self.seekT + dt
    self.x = self.x + dx * sp * dt
    self.y = self.y + dy * sp * dt
    if d < 18 then
      if self.world then self.world:bankCobalt(self.left, self.x, self.y) end
      self.alive = false
    end
    return
  end
  if not self.node then
    self:integrate(dt, 4)
    -- loose chunks magnetise to the player
    local p = self.world and self.world.player
    if p and p.state == "alive" and self.age > 0.35 then
      local range = T.magnetRange * (self.world.chips and self.world.chips:get("magnet", 1) or 1)
      if U.dist2(self.x, self.y, p.x, p.y) < range * range then self.homing = p end
    end
  end
end

--- Break one chunk off a deposit. Returns true if something came loose.
function Cobalt:mine(byWhom)
  if self.left <= 0 then return false end
  if (self.mineT or 0) > 0 then return false end
  self.mineT = T.mineEvery
  self.left = self.left - 1
  self.hitAnim = 1
  VFX.emit("cobalt_pickup", self.x, self.y)
  if self.left <= 0 then
    self.alive = false
    VFX.emit("deposit_pop", self.x, self.y)
    if self.world then self.world:scheduleNodeRespawn() end
  end
  return true
end

function Cobalt:drawShadow()
  if not self.node then return end
  Draw.softShadow(self.x, self.y + 2, self.radius * 0.9, self.radius * 0.36, 0.3)
end

function Cobalt:draw()
  local g = love.graphics
  local pop = self.hitAnim and (1 + self.hitAnim * 0.25) or 1
  if self.hitAnim then
    self.hitAnim = self.hitAnim - love.timer.getDelta() * 4
    if self.hitAnim <= 0 then self.hitAnim = nil end
  end
  local shimmer = 0.5 + math.sin(self.age * 2.2 + self.bob) * 0.5
  local facetLit = P.shade(P.ramp.cobalt, 2.9 + shimmer * 0.5)
  g.push()
  g.translate(self.x, self.y + (self.node and 0 or math.sin(self.age * 4 + self.bob) * 2))
  g.scale(pop)
  for i = 1, #self.shards do
    local s = self.shards[i]
    if self.node and i > math.max(1, self.left) then break end
    local x, y = math.cos(s.a) * s.d, math.sin(s.a) * s.d * 0.6
    -- A cut crystal, not a lozenge. These sat next to smooth vector trees as
    -- four-vertex polygons with one flat fill each, and read as pixel art
    -- pasted into a different game. Same silhouette, but given a shadowed
    -- flank, a lit flank and a rim, so it turns in the light.
    Draw.setColor(FACET_BASE)
    Draw.diamond(x, y + s.s * 0.42, s.s * 1.02, s.s * 0.62, "fill")
    Draw.setColor(FACET_BODY)
    Draw.diamond(x, y, s.s, s.s * 1.5, "fill")
    -- lit half: a slimmer diamond pushed to the key side, so the body splits
    -- into two facets down the vertical axis instead of reading as one slab
    Draw.setColor(facetLit)
    Draw.diamond(x + s.s * 0.30, y - s.s * 0.04, s.s * 0.70, s.s * 1.40, "fill")
    Draw.setColor(FACET_TIP, 0.50 + shimmer * 0.40)
    Draw.diamond(x - s.s * 0.16, y - s.s * 0.30, s.s * 0.34, s.s * 0.60, "fill")
    -- a thin bright edge along the top facets: the one line that stops it
    -- dissolving into grass at play scale
    Draw.setColor(P.ramp.cobalt[4], 0.30 + shimmer * 0.30)
    g.setLineWidth(1.2)
    g.line(x - s.s, y, x, y - s.s * 1.5, x + s.s, y)
  end
  g.pop()
  Draw.glow(self.x, self.y, self.radius * (1.7 + shimmer * 0.4), P.ramp.cobalt[3], 0.28)
end

--- The ambient shimmer. VFX.stream wants the per-frame dt, and a node is
--- static, so this is the whole of it.
function Cobalt:ambient(dt)
  if not self.node or self.left <= 0 then return end
  VFX.stream("cobalt_shimmer", self.x, self.y - self.radius * 0.35, dt,
             { rate = 0.35 + 0.65 * math.min(1, self.left / 12) })
end

function Cobalt:emitLight(Lighting)
  Lighting.addLight(self.x, self.y, self.radius * 3.2, P.ramp.cobalt[3], 0.3, OPT_SHIMMER)
end

return Cobalt
