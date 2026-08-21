-- Trees. The centrepiece of the game: the player's whole power fantasy is
-- watching these fill the screen, so this file gets to be long.
--
-- HOW IT WORKS
-- ------------
-- 1. SKELETON. Every (species, variant) pair owns one recursively generated
--    branch skeleton, produced once from a deterministic PRNG. Nodes store
--    *relative* angles/lengths/widths plus a `birth` growth threshold and the
--    leaf-blob cluster hanging off the tip. Nothing is regenerated per frame.
--
-- 2. MESH LIBRARY. For a given growth bucket the skeleton is laid out (segment
--    lengths and widths scaled by each node's extension factor at that growth)
--    and baked into three `love.graphics.Mesh` objects: a full-detail canopy
--    mesh, a cheap LOD mesh, and a simplified shadow mesh. These are SHARED by
--    every tree with the same (species, variant, bucket) - 900 trees on screen
--    use ~250 meshes between them, so memory and build cost are bounded.
--    Because the mesh is normalised to a unit-tall adult, a tree renders as one
--    `love.graphics.draw(mesh, x, y, lean, size, size)`.
--
-- 3. GROWTH. Buckets quantise the *topology* (which twigs exist), but overall
--    size is a continuous function of `growth`, applied as the draw scale. New
--    segments are born at zero length and smoothstep outward, so bucket changes
--    are invisible; the tree genuinely unfolds. Crossing a stage boundary kicks
--    a squash-and-stretch spring.
--
-- 4. WIND / LIGHT / SHADOW happen in the vertex shader. Each vertex carries
--    (heightFactor, canopyLag, blobId, rimWeight) and its offset from its own
--    blob centre. Height drives the bend, lag makes canopies trail the trunk,
--    the blob offset doubles as a fake normal for sun shading and as the
--    direction leaves collapse when the tree is chewed. Sun parameters are one
--    global uniform; each tree costs a single vec4 upload.
--
-- API
--   local Tree = require("src.entities.tree")
--   Tree.prewarm()                       -- optional: build the mesh library up front
--   Tree.setView(x, y, w, h)             -- cull/update rect, once per frame
--   local tr = Tree.new(x, y, seed, opts)
--   tr:update(dt)
--   tr:drawShadow(sunAngle, sunLength, ambient)
--   tr:draw(sunDirX, sunDirY)
--   tr:drawCanopyLight()
--   tr:startChew(who) / tr:stopChew(who) / tr:kill(cause) / tr:hit(dx, dy, power)
local U     = require("src.core.util")
local P     = require("src.engine.palette")
local Class = require("src.core.class")
local Wind  = require("src.world.wind")
local DayNight = require("src.engine.daynight")
local VFX   = require("src.core.optional").require("src.engine.vfx")
-- demos and the title screen own their own atmosphere; they can switch this off
local T     = require("src.game.tuning").tree

local sin, cos, floor, sqrt, abs, min, max, exp =
      math.sin, math.cos, math.floor, math.sqrt, math.abs, math.min, math.max, math.exp
local TAU = U.TAU

-------------------------------------------------------------------- tuning
-- PROPOSED additions to tuning.lua (`T.tree`). Held here so tuning.lua stays
-- owned by its author; every number the tree system uses is in this block.
local TUNE = {
  buckets       = 10,     -- growth buckets in the mesh library
  variants      = 5,      -- skeletons per species
  detailSegs    = 14,     -- ring vertices per canopy blob, full detail
  lodSegs       = 7,      -- ... and for the cheap far-away mesh
  shadowSegs    = 8,

  seedSize      = 0.15,   -- draw scale at growth 0
  sizeCurve     = 0.70,   -- exponent of the size ramp - fast early, slow late
  elderScale    = 1.22,   -- elders get visibly bigger and heavier
  elderTrunk    = 1.30,

  popAmount     = 0.15,   -- stage-change squash & stretch
  popFreq       = 17,
  popDecay      = 9.0,

  bend          = 3.4,    -- multiplier on T.tree.windSway for top displacement
  bendYoung     = 1.65,   -- saplings whip
  bendElder     = 0.55,   -- elders barely move
  canopyLag     = 0.16,   -- seconds the canopy trails the trunk
  flutter       = 0.22,   -- per-tree desync of the shared wind field
  flutterRate   = 2.7,

  hitFreq       = 12.0,   -- shove/impact recoil spring
  hitDecay      = 4.4,
  hitScale      = 0.34,

  sunContrast   = 0.72,   -- how hard the sun shades the blob "normals"
  rimPower      = 1.00,
  rimAlpha      = 0.42,
  rimElder      = 1.55,   -- elders take a golden rim
  shadowAlpha   = 0.60,
  shadowSquash  = 0.34,   -- vertical flattening of the projected canopy
  airDepth      = 0.34,   -- peak aerial-perspective blend at the top of the view

  chewSag       = 0.13,   -- radians of lean a fully chewed tree droops
  chewRecover   = 0.22,   -- damage healed per second once the chomper leaves
  toppleTime    = 1.15,
  toppleAngle   = 1.42,
  deadFade      = 2.6,    -- seconds the felled canopy takes to vanish
  stumpR        = 0.075,

  leafPool      = 8,      -- pooled particles per tree, allocated on first use
  leafLife      = { 1.7, 3.6 },
  leafFall      = 26,
  leafDrift     = 54,
  leafSize      = 3.1,
  ambientLeaf   = 0.055,  -- chance/sec of an idle leaf on a mature tree
  ambientMote   = 5.5,    -- seconds between pollen/firefly puffs, per tree
  gustLeaf      = 2.6,    -- ... scaled by gust strength
  chewLeaf      = 9.0,

  lodPixels     = 52,     -- on-screen height under which the cheap mesh is used
  rimPixels     = 96,     -- ... above which the additive rim pass is worth it
  shadowPixels  = 24,     -- ... under which shadows are skipped entirely
  cullPad       = 90,
}

---------------------------------------------------------------- the species
-- Five silhouettes. `weight` is the spawn share.
--   depth      recursion depth (3-5)
--   kids       children per depth
--   spread     half-angle the children fan out over
--   curl       systematic asymmetry - gives gnarled trees their hook
--   droop      downward bias on child angles
--   lenTaper   child length as a fraction of parent
--   at         where along the parent children attach (min, max)
--   leafFrom   depth at which leaf clusters start
--   blobR      cluster radius as a fraction of the parent branch length
--   conic      children shrink with attachment height (conifer ladder)
local SPECIES = {
  {
    key = "broadleaf", label = "Broadleaf",
    height = 132, heightVar = 0.19, weight = 30,
    trunk = 0.082, trunkR = 0.050, root = 1.0,
    depth = 4, kids = { 2, 3, 2, 2 }, spread = 0.62, curl = 0.05, droop = -0.03,
    lenTaper = 0.74, widTaper = 0.60, at = { 0.62, 0.99 },
    leafFrom = 4, clusters = 3, blobR = 0.80, blobSpread = 0.60, crown = 0.42,
    ramp = P.ramp.leaf, hue = { 1.00, 1.00, 1.00 },
    bark = P.ramp.bark, barkShade = 1.55,
    flex = 1.00, o2 = 1.00,
    growSpread = 0.66, growSpan = 0.30, growJitter = 0.06,
  },
  {
    key = "conifer", label = "Conifer",
    height = 196, heightVar = 0.16, weight = 22,
    trunk = 0.078, trunkR = 0.034, root = 1.0,
    depth = 3, kids = { 6, 3, 1 }, spread = 1.00, curl = 0.0, droop = 0.42,
    lenTaper = 0.54, widTaper = 0.42, at = { 0.22, 0.95 },
    conic = true, leader = true, leaderTaper = 0.80,
    leafFrom = 2, clusters = 1, blobR = 1.15, blobSpread = 0.30, crown = 0,
    blobSq = 0.56,
    ramp = P.ramp.leaf, hue = { 0.76, 1.00, 1.10 },
    bark = P.ramp.bark, barkShade = 1.15,
    flex = 0.60, o2 = 1.15,
    growSpread = 0.58, growSpan = 0.26, growJitter = 0.05,
  },
  {
    key = "scrub", label = "Scrub",
    height = 66, heightVar = 0.24, weight = 20,
    trunk = 0.110, trunkR = 0.068, root = 0.42,
    depth = 3, kids = { 4, 2, 2 }, spread = 1.02, curl = 0.0, droop = 0.12,
    lenTaper = 0.84, widTaper = 0.64, at = { 0.10, 0.58 },
    leafFrom = 3, clusters = 3, blobR = 0.92, blobSpread = 0.66, crown = 0.34,
    blobSq = 0.88,
    ramp = P.ramp.moss, hue = { 1.06, 1.00, 0.88 },
    bark = P.ramp.bark, barkShade = 1.8,
    flex = 1.35, o2 = 0.55,
    growSpread = 0.50, growSpan = 0.30, growJitter = 0.08,
  },
  {
    key = "gnarl", label = "Gnarl",
    height = 152, heightVar = 0.15, weight = 16,
    trunk = 0.145, trunkR = 0.086, root = 1.0,
    depth = 4, kids = { 2, 2, 3, 2 }, spread = 0.98, curl = 0.34, droop = -0.05,
    lenTaper = 0.73, widTaper = 0.70, at = { 0.40, 0.98 },
    leafFrom = 4, clusters = 3, blobR = 0.72, blobSpread = 0.76, crown = 0.46,
    blobSq = 0.92,
    ramp = P.ramp.leafHi, hue = { 1.12, 0.96, 0.74 },
    bark = P.ramp.bark, barkShade = 1.35,
    flex = 0.55, o2 = 1.45,
    growSpread = 0.72, growSpan = 0.34, growJitter = 0.07,
  },
  {
    key = "slender", label = "Slender",
    height = 162, heightVar = 0.14, weight = 12,
    trunk = 0.038, trunkR = 0.028, root = 1.0,
    depth = 3, kids = { 3, 2, 2 }, spread = 0.40, curl = 0.09, droop = -0.16,
    lenTaper = 0.66, widTaper = 0.54, at = { 0.54, 0.99 },
    leafFrom = 3, clusters = 3, blobR = 0.62, blobSpread = 0.50, crown = 0.24,
    blobSq = 1.06,
    ramp = P.ramp.leafHi, hue = { 0.94, 1.04, 0.98 },
    bark = P.ramp.rock, barkShade = 2.7,
    flex = 1.55, o2 = 0.85,
    growSpread = 0.56, growSpan = 0.28, growJitter = 0.06,
  },
}

local Tree = Class("Tree")
Tree.species      = SPECIES
Tree.speciesCount = #SPECIES
Tree.tune         = TUNE

local totalWeight = 0
for i = 1, #SPECIES do totalWeight = totalWeight + SPECIES[i].weight end

local STAGES = { "seed", "sapling", "young", "mature", "elder", "dying", "dead" }
Tree.stages = STAGES

------------------------------------------------------------------- shaders
-- Wind, sun shading, leaf loss and the shadow projection all live on the GPU
-- so the CPU only ever uploads one vec4 per tree.
local SHARED_VS = [[
#ifdef VERTEX
attribute vec4 TreeData;   // x: height 0..1  y: canopy lag  z: blob id  w: rim weight
attribute vec2 BlobOff;    // offset from this vertex's blob/segment centre
#endif
uniform vec4 uT;           // x: sway  y: lagged sway  z: leaf loss  w: unused
]]

local TREE_SHADER = SHARED_VS .. [[
uniform vec4 uSun;         // xy: direction to the sun  z: contrast  w: rim power
uniform vec4 uRim;         // rim colour, a = intensity
uniform vec4 uDeath;       // rgb: dead tint  a: desaturation amount
uniform vec4 uAir;         // rgb: atmosphere colour  a: how much of it depth buys
varying vec3 vShade;
varying float vRim;
#ifdef VERTEX
vec4 position(mat4 tpm, vec4 vp) {
  float h = TreeData.x;
  float sway = mix(uT.x, uT.y, TreeData.y);
  float b = sway * h * h;
  vp.x += b;
  vp.y += abs(b) * h * 0.22;                       // bending shortens the tree
  float loss = clamp((uT.z - TreeData.z) * 3.0, 0.0, 1.0);
  vp.xy -= BlobOff * loss;                          // chewed foliage folds away
  float nl = length(BlobOff);
  float l = nl > 0.00001 ? dot(BlobOff / nl, uSun.xy) : 0.0;
  vShade = vec3(1.0 + l * uSun.z);
  vRim = smoothstep(0.30, 0.98, l) * TreeData.w * uSun.w;
  return tpm * vp;
}
#endif
#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
  vec3 c = color.rgb * vShade + uRim.rgb * (vRim * uRim.a);
  float g = dot(c, vec3(0.34, 0.50, 0.16));
  c = mix(c, vec3(g) * uDeath.rgb, uDeath.a);
  // Aerial perspective. uT.w is this tree's depth up the screen; without it a
  // forest of 900 identical greens has no near and no far and reads as carpet.
  // Depth desaturates toward the atmosphere and lifts the darks, exactly as air
  // does, so the far canopy sits behind the near one.
  float air = uT.w * uAir.a;
  float gl = dot(c, vec3(0.2126, 0.7152, 0.0722));
  c = mix(c, uAir.rgb * (0.45 + 1.10 * gl), air);
  return vec4(c, color.a);
}
#endif
]]

local RIM_SHADER = SHARED_VS .. [[
uniform vec4 uSun;
uniform vec4 uRim;
varying float vRim;
#ifdef VERTEX
vec4 position(mat4 tpm, vec4 vp) {
  float h = TreeData.x;
  float sway = mix(uT.x, uT.y, TreeData.y);
  float b = sway * h * h;
  vp.x += b;
  vp.y += abs(b) * h * 0.22;
  float loss = clamp((uT.z - TreeData.z) * 3.0, 0.0, 1.0);
  vp.xy -= BlobOff * loss;
  float nl = length(BlobOff);
  float l = nl > 0.00001 ? dot(BlobOff / nl, uSun.xy) : 0.0;
  vRim = smoothstep(0.42, 1.0, l) * TreeData.w * uSun.w;
  return tpm * vp;
}
#endif
#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
  return vec4(uRim.rgb * (vRim * uRim.a * color.a), 1.0);
}
#endif
]]

local SHADOW_SHADER = SHARED_VS .. [[
uniform vec4 uProj;        // xy: shadow direction  z: length (x tree height)  w: squash
uniform vec4 uShadow;      // shadow colour, a = strength
#ifdef VERTEX
vec4 position(mat4 tpm, vec4 vp) {
  float h = TreeData.x;
  float sway = mix(uT.x, uT.y, TreeData.y);
  float b = sway * h * h;
  vp.x += b;
  float loss = clamp((uT.z - TreeData.z) * 3.0, 0.0, 1.0);
  vp.xy -= BlobOff * loss;
  vec2 p = vec2(vp.x + h * uProj.x * uProj.z,
                vp.y * uProj.w + h * uProj.y * uProj.z);
  return tpm * vec4(p, vp.z, vp.w);
}
#endif
#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
  return vec4(uShadow.rgb, uShadow.a * color.a);
}
#endif
]]

local FORMAT = {
  { "VertexPosition", "float", 2 },
  { "VertexColor",    "float", 4 },
  { "TreeData",       "float", 4 },
  { "BlobOff",        "float", 2 },
}

local shTree, shRim, shShadow
local shadersOK = false

local function initShaders()
  if shTree ~= nil or shadersOK then return end
  local ok1, a = pcall(love.graphics.newShader, TREE_SHADER)
  local ok2, b = pcall(love.graphics.newShader, SHADOW_SHADER)
  local ok3, c = pcall(love.graphics.newShader, RIM_SHADER)
  if ok1 and ok2 and ok3 then
    shTree, shShadow, shRim = a, b, c
    shadersOK = true
  else
    shTree, shShadow, shRim = false, false, false
    shadersOK = false
    print("tree.lua: shader compile failed, falling back to flat drawing\n" ..
          tostring(a) .. "\n" .. tostring(b))
  end
end
Tree.shadersAvailable = function() return shadersOK end

--------------------------------------------------------------- skeletons
-- Generated once per (species, variant) and reused by every bucket, so the
-- topology can never change as a tree grows.
local skelCache = {}

local function genNode(r, sp, depth, atFrac, parentBirth, isLeader)
  local birth = depth / (sp.depth + 1) * sp.growSpread
              + r:next() * sp.growJitter
              + ((sp.conic and not isLeader) and atFrac * 0.22 or 0)
  -- a branch can never appear before the branch it hangs off
  birth = min(max(birth, parentBirth + 0.055), 0.93)

  local n = { depth = depth, birth = birth, kids = nil, blobs = nil }

  if depth < sp.depth then
    local k = sp.kids[depth + 1] or 2
    n.kids = {}
    -- Species with a central leader keep growing one dominant shoot straight up
    -- and hang whorls of side branches off it. That is what makes a conifer a
    -- spire instead of a bush.
    local lead = sp.leader and isLeader
    local nw = lead and (k - 1) or k
    for i = 1, k do
      local leaderKid = lead and (i == 1)
      local wi = leaderKid and 0 or (lead and (i - 1) or i)
      local f = (nw <= 1) and 0 or ((wi - 1) / (nw - 1) * 2 - 1)

      local at
      if leaderKid then
        at = 0.985
      elseif sp.conic then
        at = U.lerp(sp.at[1], sp.at[2], (wi - 0.5) / max(nw, 1)) + r:gauss() * 0.03
      else
        at = U.lerp(sp.at[1], sp.at[2], r:next())
      end
      at = U.clamp(at, 0.05, 0.995)

      local kid = genNode(r, sp, depth + 1, at, birth, leaderKid)
      kid.at = at
      if leaderKid then
        kid.ang  = r:gauss() * 0.05 + sp.curl * 0.2
        kid.lenF = (sp.leaderTaper or 0.82) * (0.94 + r:next() * 0.12)
        kid.widF = (sp.widTaper + 1) * 0.5
      else
        local side = sp.conic and ((wi % 2 == 0) and 1 or -1) or f
        if side == 0 then side = (r:next() < 0.5) and -0.22 or 0.22 end
        local sgn = side >= 0 and 1 or -1
        kid.ang = side * sp.spread * (0.68 + r:next() * 0.64)
                + r:gauss() * 0.13 + sp.curl * (depth + 1) * 0.5 + sgn * sp.droop
        if sp.conic then
          kid.lenF = sp.lenTaper * (1.55 - at * 1.10) * (0.86 + r:next() * 0.28)
          kid.widF = sp.widTaper * (1.30 - at * 0.50)
        else
          kid.lenF = sp.lenTaper * (0.80 + r:next() * 0.42)
          kid.widF = sp.widTaper * (0.88 + r:next() * 0.26)
        end
      end
      n.kids[i] = kid
    end
  end

  do
    n.blobs = {}
    local nb = sp.clusters
    for i = 1, nb do
      local a = r:angle()
      local d = sqrt(r:next()) * sp.blobSpread
      n.blobs[i] = {
        ox = cos(a) * d, oy = sin(a) * d * 0.80 - 0.12,
        r  = sp.blobR * (0.72 + r:next() * 0.56),
        layer = (nb == 1) and floor(r:next() * 3)
                or ((i == 1 and 0) or (i == nb and 2) or 1),
        p1 = r:angle(), p2 = r:angle(), p3 = r:angle(),
        tone = r:next(),
        id = r:next(),
        sq = (0.80 + r:next() * 0.26) * (sp.blobSq or 1),
      }
    end
  end
  return n
end

--- Two or three big soft blobs in the middle of the crown, behind everything
--- else. Without them a canopy built only from branch tips reads as a ring.
local function genCrown(r, sp)
  if not sp.crown or sp.crown <= 0 then return nil end
  local out = {}
  for i = 1, 3 do
    out[i] = {
      ox = r:gauss() * 0.26, oy = r:gauss() * 0.16,
      r  = sp.crown * (0.80 + r:next() * 0.42),
      layer = 0,
      p1 = r:angle(), p2 = r:angle(), p3 = r:angle(),
      tone = r:next() * 0.6,
      id = 1.6,                    -- crown never sheds: it is the tree's mass
      sq = 0.74 + r:next() * 0.22,
    }
  end
  return out
end

local function getSkeleton(spi, variant)
  local key = spi * 64 + variant
  local sk = skelCache[key]
  if sk then return sk end
  local sp = SPECIES[spi]
  local r = U.rng(9176 + spi * 7919 + variant * 104729)
  local root = genNode(r, sp, 0, 0, -1, true)
  root.birth = 0
  root.ang, root.at, root.lenF, root.widF = 0, 0, 1, 1
  local crown = genCrown(r, sp)
  sk = { sp = sp, root = root, crown = crown, spi = spi, variant = variant }

  -- measure the adult so every mesh can be normalised to a unit-tall tree
  local maxY, maxR = 0.001, 0.001
  local function walk(node, x, y, ang, len, wid)
    local l = len
    local x1, y1 = x + cos(ang) * l, y + sin(ang) * l
    if -y1 > maxY then maxY = -y1 end
    if abs(x1) > maxR then maxR = abs(x1) end
    if node.blobs and node.depth >= sp.leafFrom then
      for i = 1, #node.blobs do
        local b = node.blobs[i]
        local bx = x1 + b.ox * len
        local by = y1 + b.oy * len
        local br = b.r * len
        if -(by - br) > maxY then maxY = -(by - br) end
        if abs(bx) + br > maxR then maxR = abs(bx) + br end
      end
    end
    if node.kids then
      for i = 1, #node.kids do
        local k = node.kids[i]
        walk(k, x + (x1 - x) * k.at, y + (y1 - y) * k.at, ang + k.ang, len * k.lenF, wid * k.widF)
      end
    end
  end
  walk(root, 0, 0, -math.pi / 2, sp.root, sp.trunk)
  sk.normY = maxY
  sk.aspect = maxR / maxY
  skelCache[key] = sk
  return sk
end

------------------------------------------------------------ mesh building
local function rampAt(ramp, t)
  t = U.clamp(t, 1, 4)
  local i = floor(t)
  local f = t - i
  local a, b = ramp[i], ramp[min(i + 1, 4)]
  return U.lerp(a[1], b[1], f), U.lerp(a[2], b[2], f), U.lerp(a[3], b[3], f)
end

-- build context; reused between builds to keep the churn down
local B = { V = nil, I = nil }

local function pushV(V, x, y, r, g, b, a, h, lag, id, rim, ox, oy)
  V[#V + 1] = { x, y, r, g, b, a, h, lag, id, rim, ox, oy }
end

--- A tapered quad for one branch segment.
local function emitSeg(V, I, x0, y0, x1, y1, w0, w1, invY, cr, cg, cb, rim)
  local dx, dy = x1 - x0, y1 - y0
  local l = sqrt(dx * dx + dy * dy)
  if l < 1e-5 then return end
  local nx, ny = -dy / l, dx / l
  local h0 = U.saturate(-y0 * invY)
  local h1 = U.saturate(-y1 * invY)
  local base = #V
  pushV(V, x0 + nx * w0, y0 + ny * w0, cr, cg, cb, 1, h0, 0, 2, rim,  nx * w0,  ny * w0)
  pushV(V, x0 - nx * w0, y0 - ny * w0, cr, cg, cb, 1, h0, 0, 2, rim, -nx * w0, -ny * w0)
  pushV(V, x1 - nx * w1, y1 - ny * w1, cr, cg, cb, 1, h1, 0, 2, rim, -nx * w1, -ny * w1)
  pushV(V, x1 + nx * w1, y1 + ny * w1, cr, cg, cb, 1, h1, 0, 2, rim,  nx * w1,  ny * w1)
  local n = #I
  I[n + 1] = base + 1; I[n + 2] = base + 2; I[n + 3] = base + 3
  I[n + 4] = base + 1; I[n + 5] = base + 3; I[n + 6] = base + 4
end

--- One organic canopy blob: a fan whose radius is modulated by three harmonics,
--- with a vertical light gradient baked in and the rim flagged for the shader.
---
--- The gradient is a *ramp walk*, not a brightness multiply: a shadowed leaf is
--- a deeper, cooler green, not the same green turned down. Multiplying is what
--- made the canopy read as flat plastic lozenges.
local function emitBlob(V, I, cx, cy, r, blob, invY, segs, cr, cg, cb, alpha, lag, rimW,
                        ramp, tone, hue)
  local base = #V
  local hC = U.saturate(-cy * invY)
  local invR = 1 / max(r, 1e-5)
  pushV(V, cx, cy, cr, cg, cb, alpha, hC, lag, blob.id, 0, 0, 0)
  for i = 0, segs - 1 do
    local a = i / segs * TAU
    -- deeper harmonics: a blob wants a lobed, clustered silhouette. At the old
    -- amplitudes every blob was a clean ellipse and the canopy read as pebbles.
    local rr = r * (0.83
                    + 0.145 * sin(a * 2 + blob.p1)
                    + 0.085 * sin(a * 3 + blob.p2)
                    + 0.050 * sin(a * 5 + blob.p3))
    local ox = cos(a) * rr
    local oy = sin(a) * rr * blob.sq
    local vr, vg, vb
    if ramp then
      local rt, gt, bt = rampAt(ramp, tone - oy * invR * 0.95)
      vr, vg, vb = rt * hue[1], gt * hue[2], bt * hue[3]
    else
      local k = 0.90 - oy * invR * 0.15
      vr, vg, vb = cr * k, cg * k, cb * k
    end
    pushV(V, cx + ox, cy + oy, vr, vg, vb, alpha,
          U.saturate(-(cy + oy) * invY), lag, blob.id, rimW, ox, oy)
  end
  local n = #I
  for i = 0, segs - 1 do
    n = n + 1; I[n] = base + 1
    n = n + 1; I[n] = base + 2 + i
    n = n + 1; I[n] = base + 2 + ((i + 1) % segs)
  end
end

--- Soft ground contact ellipse. Sits at h = 0 so the shadow shader leaves it in
--- place while everything above it is projected away from the sun.
local function emitContact(V, I, rx, ry, segs)
  local base = #V
  pushV(V, 0, 0, 1, 1, 1, 1, 0, 0, 2, 0, 0, 0)
  for i = 0, segs - 1 do
    local a = i / segs * TAU
    pushV(V, cos(a) * rx, sin(a) * ry, 1, 1, 1, 0, 0, 0, 2, 0, 0, 0)
  end
  local n = #I
  for i = 0, segs - 1 do
    n = n + 1; I[n] = base + 1
    n = n + 1; I[n] = base + 2 + i
    n = n + 1; I[n] = base + 2 + ((i + 1) % segs)
  end
end

local LAYER_LAG   = { 0.62, 0.80, 1.00 }
-- A wider tonal spread between the back, middle and front canopy layers is what
-- gives a crown depth. At 1.05/2.10/2.92 the three layers were near enough in
-- value that the canopy read as one mass.
local LAYER_SHADE = { 0.80, 2.05, 3.15 }
local LAYER_ALPHA = { 1.00, 1.00, 1.00 }
local LAYER_RIM   = { 0.12, 0.62, 1.15 }
local LAYER_PUSH  = { -0.14, 0.0, 0.09 }   -- parallax: back layer up, front layer down

--- Lay the skeleton out at growth `g` and bake it into a mesh.
--- `kind` is "full" | "lod" | "shadow".
local function buildMesh(sk, g, kind)
  local sp = sk.sp
  local sc = 1 / sk.normY      -- everything is laid out in units of adult height
  local invY = 1               -- ... so local y IS the height factor
  local V = {}
  local Ilayer = { {}, {}, {}, {} }     -- back blobs, trunk, mid blobs, front blobs
  local segs = (kind == "full" and TUNE.detailSegs)
            or (kind == "lod" and TUNE.lodSegs)
            or TUNE.shadowSegs
  local shadow = (kind == "shadow")
  local span = sp.growSpan

  local maxY, maxR, trunkW = 0.001, 0.001, sp.trunk * sc

  local function walk(node, x, y, ang, len, wid)
    -- the seedling is already poking out of the ground at growth 0
    local b0 = node.birth - (node.depth == 0 and 0.09 or 0)
    local e = U.smoothstep(b0, b0 + span, g)
    if e <= 0.004 then return end
    local ex = e ^ 0.55
    local l = len * e
    local x1, y1 = x + cos(ang) * l, y + sin(ang) * l
    local w0, w1 = wid * ex, wid * sp.widTaper * ex

    if -y1 > maxY then maxY = -y1 end
    if abs(x1) > maxR then maxR = abs(x1) end

    if shadow then
      if node.depth <= 1 then
        emitSeg(V, Ilayer[2], x, y, x1, y1, w0 * 1.15, w1 * 1.15, invY, 1, 1, 1, 0)
      end
    else
      local t = sp.barkShade - node.depth * 0.28 + (node.depth == 0 and -0.15 or 0)
      local br, bg, bb = rampAt(sp.bark, t)
      emitSeg(V, Ilayer[2], x, y, x1, y1, w0, w1, invY, br, bg, bb, 0.35)
    end

    -- A node carries foliage if it is a designed leaf node, or if it is the
    -- furthest thing that has grown so far - that is what makes a sapling a
    -- leafy little thing instead of a bare stick.
    local tip = true
    if node.kids then
      for i = 1, #node.kids do
        local kb = node.kids[i].birth
        if U.smoothstep(kb, kb + span, g) > 0.02 then tip = false break end
      end
    end
    if node.blobs and (tip or node.depth >= sp.leafFrom) then
      local designed = node.depth >= sp.leafFrom
      local rmul = designed and 1 or (0.50 + 0.17 * node.depth)
      local eb = designed and e or (0.38 + 0.62 * e)
      for i = 1, #node.blobs do
        local b = node.blobs[i]
        local layer = b.layer + 1
        if not (kind == "lod" and layer == 1 and i > 1) then
          local br_ = b.r * len * eb * rmul
          local bx = x1 + b.ox * len * eb * rmul
          local by = y1 + (b.oy + LAYER_PUSH[layer]) * len * eb * rmul
          if br_ > 0.004 then
            if -(by - br_) > maxY then maxY = -(by - br_) end
            if abs(bx) + br_ > maxR then maxR = abs(bx) + br_ end
            if shadow then
              if layer >= 2 then
                emitBlob(V, Ilayer[3], bx, by, br_ * 1.06, b, invY, segs,
                         1, 1, 1, 0.55, LAYER_LAG[layer], 0)
              end
            else
              local tone = LAYER_SHADE[layer] + (b.tone - 0.5) * 1.00
              local cr, cg, cb = rampAt(sp.ramp, tone)
              cr, cg, cb = cr * sp.hue[1], cg * sp.hue[2], cb * sp.hue[3]
              emitBlob(V, Ilayer[layer == 1 and 1 or (layer == 2 and 3 or 4)],
                       bx, by, br_, b, invY, segs, cr, cg, cb,
                       LAYER_ALPHA[layer], LAYER_LAG[layer], LAYER_RIM[layer],
                       sp.ramp, tone, sp.hue)
            end
          end
        end
      end
    end

    if node.kids then
      for i = 1, #node.kids do
        local k = node.kids[i]
        walk(k, x + (x1 - x) * k.at, y + (y1 - y) * k.at,
             ang + k.ang, len * k.lenF, wid * k.widF)
      end
    end
  end

  walk(sk.root, 0, 0, -math.pi / 2, sp.root * sc, sp.trunk * sc)

  -- crown mass, sized from whatever the tree currently reaches
  if sk.crown then
    local cg = U.smoothstep(0.06, 0.42, g)
    if cg > 0.02 then
      local cr = maxR * cg
      local cyBase = -maxY * 0.62
      for i = 1, #sk.crown do
        local b = sk.crown[i]
        local br_ = b.r * (maxR + maxY * 0.35) * 0.62 * cg
        local bx = b.ox * cr * 1.4
        local by = cyBase + b.oy * maxY * cg
        if br_ > 0.004 then
          if -(by - br_) > maxY then maxY = -(by - br_) end
          if abs(bx) + br_ > maxR then maxR = abs(bx) + br_ end
          if shadow then
            emitBlob(V, Ilayer[3], bx, by, br_ * 0.94, b, invY, segs,
                     1, 1, 1, 0.6, LAYER_LAG[1], 0)
          else
            local ctone = LAYER_SHADE[1] + b.tone * 0.8
            local cr_, cg_, cb_ = rampAt(sp.ramp, ctone)
            emitBlob(V, Ilayer[1], bx, by, br_, b, invY, segs,
                     cr_ * sp.hue[1], cg_ * sp.hue[2], cb_ * sp.hue[3],
                     1, LAYER_LAG[1], LAYER_RIM[1], sp.ramp, ctone, sp.hue)
          end
        end
      end
    end
  end

  if shadow then
    emitContact(V, Ilayer[1], maxR * 0.62 + trunkW * 2.2, (maxR * 0.62 + trunkW * 2.2) * 0.42,
                TUNE.shadowSegs + 3)
  end

  local I = {}
  local n = 0
  for li = 1, 4 do
    local src = Ilayer[li]
    for i = 1, #src do n = n + 1; I[n] = src[i] end
  end

  if #V < 3 or n < 3 then return nil, maxY, maxR end

  local mesh = love.graphics.newMesh(FORMAT, V, "triangles", "static")
  mesh:setVertexMap(I)
  return mesh, maxY, maxR
end

-------------------------------------------------------------- mesh library
local LIB = { full = {}, lod = {}, shadow = {}, meta = {} }
local libCount = 0

local function libKey(spi, variant, bucket)
  return (spi * TUNE.variants + variant) * TUNE.buckets + bucket
end

local function bucketGrowth(b) return b / (TUNE.buckets - 1) end

local function ensure(spi, variant, bucket)
  local key = libKey(spi, variant, bucket)
  local meta = LIB.meta[key]
  if meta then return key, meta end
  initShaders()
  local sk = getSkeleton(spi, variant)
  local g = bucketGrowth(bucket)
  local m1, ey, er = buildMesh(sk, g, "full")
  local m2       = buildMesh(sk, g, "lod")
  local m3       = buildMesh(sk, g, "shadow")
  LIB.full[key], LIB.lod[key], LIB.shadow[key] = m1, m2, m3
  meta = { extentY = ey, extentR = er }
  LIB.meta[key] = meta
  libCount = libCount + 1
  return key, meta
end

--- Build the whole library up front so nothing hitches mid-run.
--- Returns seconds spent and the number of (species, variant, bucket) cells.
function Tree.prewarm()
  local t0 = love.timer and love.timer.getTime() or 0
  for spi = 1, #SPECIES do
    for v = 0, TUNE.variants - 1 do
      for b = 0, TUNE.buckets - 1 do ensure(spi, v, b) end
    end
  end
  local t1 = love.timer and love.timer.getTime() or 0
  return t1 - t0, libCount
end

function Tree.libraryStats()
  local verts = 0
  for _, m in pairs(LIB.full) do if m then verts = verts + m:getVertexCount() end end
  for _, m in pairs(LIB.lod) do if m then verts = verts + m:getVertexCount() end end
  for _, m in pairs(LIB.shadow) do if m then verts = verts + m:getVertexCount() end end
  return libCount, verts
end

---------------------------------------------------------------- pass state
-- The public API is per-tree, but shader/uniform changes are expensive, so we
-- remember what is already bound and only touch the pipeline when it changes.
local cur = {
  shader = nil, sunX = nil, sunY = nil, ambient = nil,
  sunAngle = nil, sunLen = nil, mode = nil,
  rimKey = nil, deathKey = nil,
}
local uT   = { 0, 0, 0, 0 }
local uAir = { 1, 1, 1, 0 }
local uSun = { 0, 0, 0, 0 }
local uPrj = { 0, 0, 0, 0 }
local uRimC = { 0, 0, 0, 0 }
local uDth = { 0, 0, 0, 0 }
local uShd = { 0, 0, 0, 0 }

local view = { x = -1e9, y = -1e9, w = 3e9, h = 3e9 }

--- Tell the tree system what the camera can see. Trees outside it neither
--- update their particles nor draw. Call once per frame.
function Tree.setView(x, y, w, h)
  view.x, view.y, view.w, view.h = x - TUNE.cullPad, y - TUNE.cullPad,
                                   w + TUNE.cullPad * 2, h + TUNE.cullPad * 2
end

function Tree.setViewFromCamera(cam)
  local x, y, w, h = cam:viewRect(0)
  Tree.setView(x, y, w, h)
  Tree.zoom = cam.zoom or 1
  -- keep the aerial-perspective air in step with the atmosphere, so a forest at
  -- dusk recedes into the bruise and a forest at noon recedes into blue haze
  local DN = DayNight
  if DN then
    Tree.setAir(DN.fogColor, TUNE.airDepth * (0.55 + 0.90 * (DN.fogStrength or 0)))
  end
end

Tree.zoom = 1
Tree.ambient = true

--- Call after a batch of tree draws to restore the default pipeline.
function Tree.endPass()
  if cur.shader ~= nil then
    love.graphics.setShader()
    cur.shader = nil
  end
  cur.mode = nil
  love.graphics.setBlendMode("alpha")
end

local function bind(shader)
  if cur.shader ~= shader then
    love.graphics.setShader(shader or nil)
    cur.shader = shader
    cur.rimKey, cur.deathKey = nil, nil
  end
end

local RIM_WARM = P.mix(P.warn, P.ink, 0.30)
local RIM_GOLD = P.mix(P.warn, P.ramp.ember[4], 0.45)
local DEAD_TINT = P.mix(P.ramp.soil[3], P.ramp.sand[2], 0.4)
local SHADOW_COL = P.ramp.rock[1]
local STUMP_COL = P.ramp.bark[2]
local STUMP_TOP = P.ramp.bark[3]

--------------------------------------------------------------------- Tree
local function pickSpecies(r)
  local x = r:next() * totalWeight
  for i = 1, #SPECIES do
    x = x - SPECIES[i].weight
    if x <= 0 then return i end
  end
  return 1
end

function Tree:init(x, y, seed, opts)
  opts = opts or {}
  seed = seed or floor(x * 3571 + y * 6151 + 17)
  local r = U.rng(floor(seed) % 2147483647)
  r:next(); r:next()

  self.x, self.y, self.seed = x, y, seed
  self.spi = opts.species or pickSpecies(r)
  if self.spi > #SPECIES then self.spi = ((self.spi - 1) % #SPECIES) + 1 end
  local sp = SPECIES[self.spi]
  self.sp = sp
  self.speciesKey = sp.key
  self.variant = r:int(0, TUNE.variants - 1)

  self.maxHeight = sp.height * (1 + r:gauss() * sp.heightVar)
  self.lean      = r:gauss() * 0.055
  self.flex      = sp.flex * (0.82 + r:next() * 0.40)
  self.phase     = r:angle()
  self.o2Mul     = sp.o2 * (0.9 + r:next() * 0.2)

  -- Per-tree colour. The old spread was +-7% on one channel, which at forest
  -- scale is invisible: 900 trees all read as one yellow-green. Two independent
  -- axes -- a warm/cool hue rotation and a plain value offset -- are what turn a
  -- carpet back into a canopy of individuals.
  local hj = r:gauss()                 -- + warm ochre  /  - cool blue-green
  local br = U.clamp(1 + r:gauss() * 0.115, 0.78, 1.20)   -- some trees are darker
  self.tintR = U.clamp((1 + hj * 0.20) * br, 0.64, 1.32)
  self.tintG = U.clamp((1 + hj * 0.045 + r:gauss() * 0.035) * br, 0.76, 1.24)
  self.tintB = U.clamp((1 - hj * 0.20 + r:gauss() * 0.05) * br, 0.58, 1.32)

  self.growth   = opts.startGrown and 1 or (opts.growth or 0)
  self.growthMul = 1
  self.elderness = opts.elder and 1 or 0
  self.elderT    = self.elderness * T.elderTime
  self.stage     = "seed"
  self.alive     = true
  self.damage    = 0
  self.death     = 0
  self.chewers   = 0
  self.chewedBy  = nil
  self.toppling  = false
  self.toppleT   = 0
  self.toppleDir = r:sign()
  self.deadT     = 0
  self.fade      = 1

  self.popT, self.popA = 10, 0
  self.hitS, self.hitV = 0, 0
  self.swayNow, self.swayLag = 0, 0

  self.lp, self.lpn = nil, 0
  self.leafTimer = r:next() * 3

  self.bucket = -1
  self.onScreen = true
  self:refreshStage(true)
  self:refreshMesh()
  return self
end

function Tree.new(x, y, seed, opts)
  local t = setmetatable({}, Tree)
  return t:init(x, y, seed, opts)
end

------------------------------------------------------------- derived state
local function sizeAt(g)
  return TUNE.seedSize + (1 - TUNE.seedSize) * (g ^ TUNE.sizeCurve)
end

function Tree:refreshMesh()
  local b = U.clamp(floor(self.growth * (TUNE.buckets - 1) + 0.5), 0, TUNE.buckets - 1)
  if b ~= self.bucket then
    self.bucket = b
    local key, meta = ensure(self.spi, self.variant, b)
    self.key = key
    self.meta = meta
  end
  local elder = 1 + self.elderness * (TUNE.elderScale - 1)
  self.size   = self.maxHeight * sizeAt(self.growth) * elder / 1.0
  self.height = self.size * (self.meta.extentY or 1)
  self.canopyR = self.size * (self.meta.extentR or 0.4)
  self.radius = self.size * self.sp.trunkR * (1 + self.elderness * (TUNE.elderTrunk - 1))
end

function Tree:refreshStage(silent)
  local prev = self.stage
  local s
  if not self.alive then
    s = self.toppling and "dying" or "dead"
  elseif self.death > 0.55 then
    s = "dying"
  elseif self.elderness >= 1 then
    s = "elder"
  elseif self.growth >= 0.999 then
    s = "mature"
  elseif self.growth >= 0.62 then
    s = "young"
  elseif self.growth >= 0.14 then
    s = "sapling"
  else
    s = "seed"
  end
  self.stage = s

  -- oxygen: sapling -> mature -> elder
  local o
  if self.growth < 0.30 then
    o = U.lerp(0, T.o2Sapling, self.growth / 0.30)
  else
    o = U.lerp(T.o2Sapling, T.o2Mature, (self.growth - 0.30) / 0.70)
  end
  o = U.lerp(o, T.o2Elder, self.elderness)
  self.o2 = (self.alive and o or 0) * self.o2Mul * (1 - self.death * 0.85)

  if not silent and s ~= prev and s ~= "dying" and s ~= "dead" then
    self.popT, self.popA = 0, TUNE.popAmount
  end
end

------------------------------------------------------------------- update
function Tree:visible()
  local r = self.canopyR + self.height
  return self.x + r >= view.x and self.x - r <= view.x + view.w
     and self.y + r >= view.y and self.y - r <= view.y + view.h
end

function Tree:update(dt)
  local on = self:visible()
  self.onScreen = on

  if self.alive then
    if self.growth < 1 then
      self.growth = min(1, self.growth + dt / T.growTime * self.growthMul)
      self:refreshMesh()
    elseif self.elderness < 1 and self.canElder then
      self.elderT = self.elderT + dt * self.growthMul
      local e = U.saturate(self.elderT / T.elderTime)
      if e ~= self.elderness then
        self.elderness = e
        self:refreshMesh()
      end
    end

    if self.chewers > 0 then
      self.damage = self.damage + dt / T.chewTime
      if self.damage >= 1 then
        self.damage = 1
        self:kill("chewed")
      end
    elseif self.damage > 0 then
      self.damage = max(0, self.damage - dt * TUNE.chewRecover)
    end
    self.death = self.damage
  end

  if self.toppling then
    self.toppleT = self.toppleT + dt
    self.death = min(1, self.death + dt * 1.6)
    if self.toppleT > TUNE.toppleTime then
      self.stage = "dead"
      self.deadT = self.deadT + dt
      self.fade = U.saturate(1 - (self.deadT - 0.35) / TUNE.deadFade)
      if self.fade <= 0 then self.toppling = false end
    end
  elseif not self.alive then
    self.deadT = self.deadT + dt
    self.fade = U.saturate(1 - (self.deadT - 0.35) / TUNE.deadFade)
  end

  self:refreshStage()

  -- squash & stretch spring after a stage change
  if self.popA > 0 then
    self.popT = self.popT + dt
    if self.popT > 1.2 then self.popA = 0 end
  end

  -- impact recoil (shove, a bot bumping the trunk, a slam)
  if abs(self.hitS) > 1e-4 or abs(self.hitV) > 1e-4 then
    local k = TUNE.hitFreq * TUNE.hitFreq
    self.hitV = self.hitV - (self.hitS * k + self.hitV * TUNE.hitDecay * 2) * dt
    self.hitS = self.hitS + self.hitV * dt
  end

  if on then
    -- wind: the trunk rides the field now, the canopy rides it a moment ago
    local sway, str = Wind.at(self.x, self.y)
    local swayL     = Wind.at(self.x, self.y, -TUNE.canopyLag)
    local flut = sin(Wind.time * TUNE.flutterRate + self.phase) * TUNE.flutter * str
    local whip = U.lerp(TUNE.bendYoung, 1.0, U.smoothstep(0.2, 0.9, self.growth))
    whip = U.lerp(whip, TUNE.bendElder, self.elderness)
    local amp = T.windSway * TUNE.bend * self.flex * whip
    self.swayNow = (sway + flut) * amp + self.hitS
    self.swayLag = (swayL + flut * 0.7) * amp * 1.25 + self.hitS * 0.7
    self.windStr = str
    self:updateLeaves(dt, str)
  end
end

------------------------------------------------------------------ actions
function Tree:startChew(who)
  if not self.alive then return false end
  self.chewers = self.chewers + 1
  self.chewedBy = who
  return true
end

function Tree:stopChew()
  self.chewers = max(0, self.chewers - 1)
  if self.chewers == 0 then self.chewedBy = nil end
end

--- A knock: `power` around 1 is a shove, 3 is a boss slam.
function Tree:hit(dx, dy, power)
  power = power or 1
  local nx = U.norm(dx or 1, dy or 0)
  self.hitV = self.hitV + nx * power * TUNE.hitScale * (1.4 - self.elderness * 0.7)
  self:shed(2 + floor(power * 2), 1.2)
end

function Tree:kill(cause)
  if not self.alive then return end
  self.alive = false
  self.cause = cause or "unknown"
  self.toppling = true
  self.toppleT = 0
  self.chewers = 0
  self.o2 = 0
  self.stage = "dying"
  self:shed(TUNE.leafPool, 1.6)
end

--- Cut without the fall - used when a tree is replaced or the level unloads.
function Tree:remove()
  self.alive = false
  self.toppling = false
  self.fade = 0
  self.stage = "dead"
  self.o2 = 0
end

function Tree:isDone() return (not self.alive) and self.fade <= 0 end

------------------------------------------------------------------- leaves
-- A tiny pooled particle system. The pool is allocated the first time a tree
-- actually needs it, so a forest of undisturbed trees costs nothing.
local LP_STRIDE = 8   -- x, y, vx, vy, life, maxlife, rot, rotv

function Tree:shed(n, speed)
  if not self.onScreen or self.growth < 0.18 then return end
  if not self.lp then
    self.lp = {}
    for i = 1, TUNE.leafPool * LP_STRIDE do self.lp[i] = 0 end
  end
  local lp = self.lp
  local r = self.canopyR
  for _ = 1, n do
    local slot = nil
    for i = 0, TUNE.leafPool - 1 do
      if lp[i * LP_STRIDE + 5] <= 0 then slot = i break end
    end
    if not slot then return end
    local o = slot * LP_STRIDE
    local a = (Wind.time * 3.1 + self.phase + slot * 2.399) % TAU
    local d = (0.35 + ((slot * 0.37 + self.phase) % 1) * 0.65) * r
    lp[o + 1] = self.x + cos(a) * d
    lp[o + 2] = self.y - self.height * (0.55 + ((slot * 0.21 + self.phase) % 1) * 0.4)
             + sin(a) * d * 0.4
    lp[o + 3] = cos(a) * 18 * (speed or 1)
    lp[o + 4] = -6 - ((slot * 0.53) % 1) * 14
    lp[o + 6] = U.lerp(TUNE.leafLife[1], TUNE.leafLife[2], (slot * 0.61 + self.phase) % 1)
    lp[o + 5] = lp[o + 6]
    lp[o + 7] = a
    lp[o + 8] = (((slot * 0.29 + self.phase) % 1) - 0.5) * 7
    self.lpn = self.lpn + 1
  end
end

-- Ambient forest life. `pollen` and `fireflies` are fully authored in vfx.lua
-- and nothing in the game ever emitted either of them: the day had no motes and
-- the night had nothing at all to look at. A tree is the natural owner of both.
local AMB_POLLEN = { power = 1 }
local AMB_FLY    = { power = 1 }

function Tree:updateLeaves(dt, windStr)
  -- ambient motes: pollen while the sun is up, fireflies once it is down
  if Tree.ambient and self.alive and self.growth > 0.55 and self.onScreen then
    self.ambTimer = (self.ambTimer or self.phase) - dt
    if self.ambTimer <= 0 then
      self.ambTimer = TUNE.ambientMote * (0.6 + (self.phase % 1))
      local night = U.saturate(-(DayNight.sunHeight or 1) * 1.7 + 0.30)
      local r = self.canopyR
      local ax = self.x + (Wind.time * 0.7 + self.phase) % 1 * r * 2 - r
      local ay = self.y - self.height * 0.55 + ((self.phase * 3.7) % 1) * r - r * 0.5
      if night > 0.2 then
        AMB_FLY.power = night
        VFX.emit("fireflies", ax, ay, AMB_FLY)
      elseif night < 0.5 then
        AMB_POLLEN.power = 1 - night * 2
        VFX.emit("pollen", ax, ay, AMB_POLLEN)
      end
    end
  end
  -- leaf emission
  if self.alive and self.growth > 0.4 then
    local rate = TUNE.ambientLeaf + windStr * windStr * TUNE.gustLeaf * 0.02
    if self.chewers > 0 then rate = rate + TUNE.chewLeaf end
    self.leafTimer = self.leafTimer - dt * rate
    if self.leafTimer <= 0 then
      self.leafTimer = 1
      self:shed(1, 1)
    end
  end

  local lp = self.lp
  if not lp or self.lpn <= 0 then return end
  local wx = Wind.dirX * TUNE.leafDrift
  local wy = Wind.dirY * TUNE.leafDrift
  local live = 0
  for i = 0, TUNE.leafPool - 1 do
    local o = i * LP_STRIDE
    local life = lp[o + 5]
    if life > 0 then
      life = life - dt
      lp[o + 5] = life
      if life > 0 then
        live = live + 1
        local t = 1 - life / lp[o + 6]
        local sw = sin(Wind.time * 5.5 + lp[o + 7]) * 26
        lp[o + 3] = U.damp(lp[o + 3], wx * windStr + sw, 2.2, dt)
        lp[o + 4] = U.damp(lp[o + 4], wy * windStr * 0.4 + TUNE.leafFall * (0.4 + t), 1.8, dt)
        lp[o + 1] = lp[o + 1] + lp[o + 3] * dt
        lp[o + 2] = lp[o + 2] + lp[o + 4] * dt
        lp[o + 7] = lp[o + 7] + lp[o + 8] * dt
      end
    end
  end
  self.lpn = live
end

------------------------------------------------------------------ drawing
local function sendTreeUniform(shader, tr)
  uT[1] = tr.swayNow
  uT[2] = tr.swayLag
  uT[3] = tr.death * 0.85
  -- depth up the screen: 0 at the bottom edge (near), 1 at the top (far)
  uT[4] = U.saturate((view.y + view.h - tr.y) / view.h) ^ 1.6
  shader:send("uT", uT)
end

--- The colour and strength of the air trees recede into. Drive this from the
--- day/night atmosphere; `amount` 0 disables aerial perspective entirely.
function Tree.setAir(color, amount)
  uAir[1], uAir[2], uAir[3] = color[1], color[2], color[3]
  uAir[4] = amount or 0
  cur.airKey = nil
end

--- Ground shadow pass. Draw every tree's shadow before any entity so nothing
--- casts onto anything standing up.
---   sunAngle  - direction the shadows point (radians, world space)
---   sunLength - shadow length as a multiple of tree height (0.6 .. 2.5)
---   ambient   - 0..1, how much fill light there is; softens/lightens shadows
function Tree:drawShadow(sunAngle, sunLength, ambient)
  if not self.onScreen or self.fade <= 0 then return end
  if self.height * (Tree.zoom or 1) < TUNE.shadowPixels then return end
  local mesh = LIB.shadow[self.key]
  if not mesh then return end

  if shadersOK then
    if cur.sunAngle ~= sunAngle or cur.sunLen ~= sunLength or cur.ambient ~= ambient
       or cur.shader ~= shShadow then
      bind(shShadow)
      uPrj[1] = cos(sunAngle); uPrj[2] = sin(sunAngle)
      uPrj[3] = sunLength or 1.0; uPrj[4] = TUNE.shadowSquash
      shShadow:send("uProj", uPrj)
      uShd[1], uShd[2], uShd[3] = SHADOW_COL[1], SHADOW_COL[2], SHADOW_COL[3]
      uShd[4] = TUNE.shadowAlpha * (1 - (ambient or 0.3) * 0.55)
      shShadow:send("uShadow", uShd)
      cur.sunAngle, cur.sunLen, cur.ambient = sunAngle, sunLength, ambient
    else
      bind(shShadow)
    end
    sendTreeUniform(shShadow, self)
    love.graphics.setColor(1, 1, 1, self.fade)
    love.graphics.draw(mesh, self.x, self.y, self:drawRot(), self.size * self:popX(),
                       self.size * self:popY())
  else
    -- no-shader fallback: a flat contact ellipse
    bind(nil)
    love.graphics.setColor(SHADOW_COL[1], SHADOW_COL[2], SHADOW_COL[3],
                           TUNE.shadowAlpha * self.fade)
    love.graphics.ellipse("fill", self.x + cos(sunAngle) * self.height * (sunLength or 1) * 0.4,
                          self.y + sin(sunAngle) * self.height * (sunLength or 1) * 0.4,
                          self.canopyR * 0.9, self.canopyR * 0.36)
  end
end

function Tree:popX()
  if self.popA <= 0 then return 1 end
  local k = exp(-TUNE.popDecay * self.popT) * sin(TUNE.popFreq * self.popT)
  return 1 - k * self.popA * 0.55
end

function Tree:popY()
  if self.popA <= 0 then return 1 end
  local k = exp(-TUNE.popDecay * self.popT) * sin(TUNE.popFreq * self.popT)
  return 1 + k * self.popA
end

function Tree:drawRot()
  local rot = self.lean + self.damage * TUNE.chewSag * self.toppleDir
  if self.toppling then
    local p = U.saturate(self.toppleT / TUNE.toppleTime)
    local e = p * p * (1.06 - 0.06 * p)
    rot = rot + self.toppleDir * TUNE.toppleAngle * e
    if self.toppleT > TUNE.toppleTime then
      rot = rot + self.toppleDir * 0.05 * exp(-7 * (self.toppleT - TUNE.toppleTime))
                * sin((self.toppleT - TUNE.toppleTime) * 22)
    end
  end
  return rot
end

--- Trunk + canopy. `sunDirX, sunDirY` point *towards* the sun in world space.
function Tree:draw(sunDirX, sunDirY)
  if not self.onScreen then return end
  if self.fade <= 0 then self:drawStump() return end

  local zoom = Tree.zoom or 1
  local px = self.height * zoom
  local mesh = (px < TUNE.lodPixels) and LIB.lod[self.key] or LIB.full[self.key]
  if not mesh then mesh = LIB.full[self.key] end
  if not mesh then return end

  if shadersOK then
    if cur.shader ~= shTree or cur.sunX ~= sunDirX or cur.sunY ~= sunDirY or cur.mode ~= "tree" then
      bind(shTree)
      uSun[1], uSun[2] = sunDirX or 0, sunDirY or -1
      uSun[3] = TUNE.sunContrast
      uSun[4] = TUNE.rimPower
      shTree:send("uSun", uSun)
      shTree:send("uAir", uAir)
      cur.sunX, cur.sunY, cur.mode = sunDirX, sunDirY, "tree"
      cur.airKey = uAir[4]
    end
    if cur.airKey ~= uAir[4] then
      shTree:send("uAir", uAir)
      cur.airKey = uAir[4]
    end
    -- elders take a warm golden rim; everything else a cool sky rim.
    -- Both of these are the same for almost every tree in the forest, so they
    -- are only re-uploaded when they actually change.
    local eld = floor(self.elderness * 8)
    if cur.rimKey ~= eld then
      cur.rimKey = eld
      local e = eld / 8
      local rc = e > 0.05 and RIM_GOLD or RIM_WARM
      uRimC[1], uRimC[2], uRimC[3] = rc[1], rc[2], rc[3]
      uRimC[4] = TUNE.rimAlpha + e * 0.34
      shTree:send("uRim", uRimC)
    end
    local dk = floor(self.death * 16)
    if cur.deathKey ~= dk then
      cur.deathKey = dk
      uDth[1], uDth[2], uDth[3] = DEAD_TINT[1], DEAD_TINT[2], DEAD_TINT[3]
      uDth[4] = dk / 16
      shTree:send("uDeath", uDth)
    end
    sendTreeUniform(shTree, self)
  else
    bind(nil)
  end

  love.graphics.setColor(self.tintR, self.tintG, self.tintB, self.fade)
  love.graphics.draw(mesh, self.x, self.y, self:drawRot(),
                     self.size * self:popX(), self.size * self:popY())

  if not self.alive and self.toppleT > TUNE.toppleTime * 0.6 then self:drawStump() end
  if self.lpn > 0 then self:drawLeaves() end
end

--- Optional additive pass: rim light and backlight through the canopy.
function Tree:drawCanopyLight()
  if not shadersOK or not self.onScreen or self.fade <= 0 then return end
  if self.height * (Tree.zoom or 1) < TUNE.rimPixels then return end
  local mesh = LIB.full[self.key]
  if not mesh then return end
  if cur.shader ~= shRim then
    bind(shRim)
    shRim:send("uSun", uSun)
    love.graphics.setBlendMode("add", "alphamultiply")
    cur.mode = "rim"
  end
  local rc = self.elderness > 0.05 and RIM_GOLD or RIM_WARM
  uRimC[1], uRimC[2], uRimC[3] = rc[1], rc[2], rc[3]
  uRimC[4] = (0.16 + self.elderness * 0.22) * (1 - self.death)
  shRim:send("uRim", uRimC)
  sendTreeUniform(shRim, self)
  love.graphics.setColor(1, 1, 1, self.fade)
  love.graphics.draw(mesh, self.x, self.y, self:drawRot(),
                     self.size * self:popX(), self.size * self:popY())
end

function Tree:drawStump()
  if self.growth < 0.2 then return end
  bind(nil)
  local r = self.size * TUNE.stumpR * (1 + self.elderness * 0.4)
  love.graphics.setColor(STUMP_COL[1], STUMP_COL[2], STUMP_COL[3], 1)
  love.graphics.ellipse("fill", self.x, self.y - r * 0.5, r * 1.25, r * 0.95)
  love.graphics.setColor(STUMP_TOP[1], STUMP_TOP[2], STUMP_TOP[3], 1)
  love.graphics.ellipse("fill", self.x, self.y - r * 0.85, r * 1.05, r * 0.52)
end

local LEAF_COL = {}
for i = 1, #SPECIES do
  local sp = SPECIES[i]
  local r, g, b = rampAt(sp.ramp, 3.1)
  LEAF_COL[i] = { r * sp.hue[1], g * sp.hue[2], b * sp.hue[3] }
end

function Tree:drawLeaves()
  local lp = self.lp
  if not lp then return end
  bind(nil)
  local c = LEAF_COL[self.spi]
  local s = TUNE.leafSize * U.clamp(self.size * 0.9, 0.5, 2.0)
  local dead = self.death
  local g = love.graphics
  for i = 0, TUNE.leafPool - 1 do
    local o = i * LP_STRIDE
    local life = lp[o + 5]
    if life > 0 then
      local t = life / lp[o + 6]
      local a = U.saturate(t * 2.2) * 0.9
      local w = 0.55 + 0.45 * abs(cos(lp[o + 7]))
      g.setColor(U.lerp(c[1], DEAD_TINT[1], dead),
                 U.lerp(c[2], DEAD_TINT[2], dead),
                 U.lerp(c[3], DEAD_TINT[3], dead), a)
      g.ellipse("fill", lp[o + 1], lp[o + 2], s * w, s * 0.62, 6)
    end
  end
end

------------------------------------------------------------------- helpers
--- Sorting key for the renderer: trees are painter-sorted by their base.
function Tree:z() return self.y end

function Tree:describe()
  return string.format("%s/%s g=%.2f e=%.2f o2=%.2f", self.sp.label, self.stage,
                       self.growth, self.elderness, self.o2)
end

return Tree
