-- Procedural island: heightfield, biomes, and a baked multi-layer ground image.
--
--   local Terrain = require("src.world.terrain")
--   local t = Terrain.new(seed)      -- generates the fields (synchronous, ~0.35 s)
--   t:bake()                         -- renders the static layers to tile canvases
--   t:update(dt) / t:draw(cam) / t:drawOverlay(cam)
--
-- Generation layers, in order:
--   domain-warped radial mask  ->  continental land value  ->  elevation (fbm + ridged
--   spines)  ->  moisture  ->  signed distance to the shoreline  ->  blight scars  ->
--   biome classification  ->  fertility.
--
-- The fields live on a `cell`-spaced grid and are uploaded as two RGBA8 textures. The
-- bake shader samples those (bilinear, so the fields are smooth), adds per-pixel noise
-- detail, lights the ground from a fixed sun and resolves the biome colour ramps. Vector
-- marks (tufts, pebbles, flowers, reeds, chips) are then stamped on top at full
-- resolution -- thousands of them, free once baked.
--
-- NOTE: util.lua's hash2/valueNoise/fbm/ridge are numerically broken (the mixing step
-- overflows double precision and every sample collapses to ~0). Until that is fixed
-- upstream this file carries its own drop-in noise, `N`, with an identical API.

local U     = require("src.core.util")
local P     = require("src.engine.palette")
local Class = require("src.core.class")
local TW    = require("src.game.tuning").world

local floor, ceil, sqrt, sin, cos, atan2, abs, min, max =
      math.floor, math.ceil, math.sqrt, math.sin, math.cos, math.atan2,
      math.abs, math.min, math.max

------------------------------------------------------------------------- noise
-- Sine-hash value noise. Same shape as U.valueNoise/U.fbm/U.ridge, but the mixing
-- stays inside double precision so it actually produces noise.
local N = {}

local function hash2(x, y, s)
  local v = sin(x * 127.1 + y * 311.7 + (s or 0) * 74.7) * 43758.5453
  return v - floor(v)
end

function N.value(x, y, s)
  local xi, yi = floor(x), floor(y)
  local xf, yf = x - xi, y - yi
  local u = xf * xf * (3 - 2 * xf)
  local v = yf * yf * (3 - 2 * yf)
  local a, b = hash2(xi, yi, s), hash2(xi + 1, yi, s)
  local c, d = hash2(xi, yi + 1, s), hash2(xi + 1, yi + 1, s)
  return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
end

function N.fbm(x, y, oct, s)
  local sum, amp, f, nrm = 0, 1, 1, 0
  for _ = 1, (oct or 4) do
    sum = sum + N.value(x * f, y * f, s) * amp
    nrm = nrm + amp
    amp = amp * 0.5
    f = f * 2.03
  end
  return sum / nrm
end

function N.ridge(x, y, oct, s)
  local sum, amp, f, nrm = 0, 1, 1, 0
  for _ = 1, (oct or 4) do
    local n = 1 - abs(N.value(x * f, y * f, s) * 2 - 1)
    sum = sum + n * n * amp
    nrm = nrm + amp
    amp = amp * 0.5
    f = f * 2.07
  end
  return sum / nrm
end

--------------------------------------------------------------------- constants
local CELL       = 8         -- field sampling resolution, world units
local TILE_W     = 850       -- ground tile canvases: 4 x 3 covers 3400 x 2400 exactly
local TILE_H     = 800
local SD_MAX     = 420       -- signed shore distance encoded into 8 bits over +-SD_MAX
local BEACH_W    = 52        -- sand band width, world units
local WET_W      = 20        -- darker wet-sand band nearest the water
local RELIEF     = 62        -- world units of vertical relief for elevation 0..1
local SUN        = { -0.632, -0.775 }   -- 2D direction toward the sun (up and left)
local SUN_Z      = 0.52
local NORMAL_DIV = 4         -- normal canvas is 1/4 world resolution
local SHORE_W    = 512       -- shore/distance field canvas
local SHORE_H    = 362

local BIOME = { "beach", "meadow", "rock", "marsh", "scar" }
local B_WATER, B_BEACH, B_MEADOW, B_ROCK, B_MARSH, B_SCAR = 0, 1, 2, 3, 4, 5

------------------------------------------------------------------------ shaders
local GROUND_GLSL = [==[
extern Image fieldA;      // r: elevation  g,b: height gradient  a: signed shore distance
extern Image fieldB;      // r: moisture   g: fertility  b: scar  a: slope
extern vec4  uTile;       // tile world rect
extern vec2  uFScale;     // world 0..1 -> field uv scale
extern vec2  uFBias;      // ... and bias (half texel)
extern vec2  uWorld;      // world size
extern float uSdMax;
extern float uBeach;
extern float uWet;
extern vec2  uSun;
extern float uSunZ;
extern vec3  cSand[4];
extern vec3  cGrass[4];
extern vec3  cMoss[4];
extern vec3  cRock[4];
extern vec3  cSoil[4];
extern vec3  cBlight[4];
extern vec3  cAsh[4];
extern vec3  cWater[4];
extern vec3  cFlora;

float hsh(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float vn(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hsh(i);
  float b = hsh(i + vec2(1.0, 0.0));
  float c = hsh(i + vec2(0.0, 1.0));
  float d = hsh(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm4(vec2 p) {
  float s = 0.0;
  float a = 0.5;
  float n = 0.0;
  for (int i = 0; i < 4; i++) { s += vn(p) * a; n += a; a *= 0.5; p *= 2.03; }
  return s / n;
}

float fbm3(vec2 p) {
  float s = 0.0;
  float a = 0.5;
  float n = 0.0;
  for (int i = 0; i < 3; i++) { s += vn(p) * a; n += a; a *= 0.5; p *= 2.05; }
  return s / n;
}

float rdg3(vec2 p) {
  float s = 0.0;
  float a = 0.5;
  float n = 0.0;
  for (int i = 0; i < 3; i++) {
    float v = 1.0 - abs(vn(p) * 2.0 - 1.0);
    s += v * v * a; n += a; a *= 0.5; p *= 2.07;
  }
  return s / n;
}

vec3 ramp(vec3 a, vec3 b, vec3 c, vec3 d, float t) {
  vec3 r = mix(a, b, clamp(t, 0.0, 1.0));
  r = mix(r, c, clamp(t - 1.0, 0.0, 1.0));
  r = mix(r, d, clamp(t - 2.0, 0.0, 1.0));
  return r;
}

vec2 fuv(vec2 w) { return clamp(w / uWorld, vec2(0.0), vec2(1.0)) * uFScale + uFBias; }

float rockMask(float slope, float elev) {
  return clamp(smoothstep(0.38, 0.60, slope) + smoothstep(0.56, 0.78, elev), 0.0, 1.0);
}

// The pixel-scale coastline crinkle. water.lua carries a byte-identical copy so
// the sea, the foam and the sand all agree on where the shoreline is.

vec4 effect(vec4 vcol, Image tx, vec2 tc, vec2 sc) {
  vec2 w = uTile.xy + tc * uTile.zw;

  vec4 A = Texel(fieldA, fuv(w));
  vec4 B = Texel(fieldB, fuv(w));

  float elev  = A.r;
  vec2  grad  = A.gb * 2.0 - 1.0;
  float se    = A.a * 2.0 - 1.0;
  float sd    = se * abs(se) * uSdMax;
  float moist = B.r;
  float fert  = B.g;
  float scar  = B.b;
  float slope = B.a;

  // ---- per-pixel detail ------------------------------------------------
  float d1 = fbm4(w * 0.0125 + 5.0);        // ~80 px blotches
  float d2 = fbm3(w * 0.0480 + 17.3);       // ~21 px texture
  float d3 = vn(w * 0.1400 + 91.0);         // ~7 px grain
  float drift = fbm3(w * 0.00135 + 3.7);    // very large scale colour drift

  // crinkle the coastline so it is never a smooth interpolated curve
  // (must match CRINKLE in water.lua)
  float sdw = sd + (d1 - 0.5) * 24.0 + (d2 - 0.5) * 17.0 + (d3 - 0.5) * 9.0;
  float alpha = smoothstep(-1.2, 1.2, sdw);
  if (alpha <= 0.002) { return vec4(0.0); }

  // ---- micro relief ----------------------------------------------------
  float e = 3.0;
  float mx = vn((w + vec2(e, 0.0)) * 0.075) - vn((w - vec2(e, 0.0)) * 0.075);
  float my = vn((w + vec2(0.0, e)) * 0.075) - vn((w - vec2(0.0, e)) * 0.075);
  vec3 nrm = normalize(vec3(-grad.x - mx * 0.32, -grad.y - my * 0.32, 1.0));
  vec3 L   = normalize(vec3(uSun, uSunZ));
  float lam = dot(nrm, L);
  float lit = clamp(0.88 + (lam - uSunZ) * 1.25, 0.52, 1.34);

  // ---- meadow ----------------------------------------------------------
  float marshHint = smoothstep(0.48, 0.70, moist) * (1.0 - smoothstep(0.22, 0.44, elev));
  float lush = clamp(fert * 0.72 + moist * 0.42 + (d1 - 0.5) * 0.80, 0.0, 1.0);
  vec3 gA = ramp(cGrass[0], cGrass[1], cGrass[2], cGrass[3],
                 0.55 + lush * 1.70 + (d2 - 0.5) * 0.70 + (d3 - 0.5) * 0.26);
  vec3 gB = ramp(cMoss[0], cMoss[1], cMoss[2], cMoss[3],
                 0.40 + lush * 1.60 + (d2 - 0.5) * 0.60);
  // large slow drift between a warm sunlit sward and cool deep moss, so the
  // island has regions rather than one uniform green
  vec3 col = mix(gA, gB, smoothstep(0.36, 0.64, drift));
  // Macro value composition. Without this the meadow is one flat field of green
  // with confetti on it: no shapes, nowhere for the eye to land. Broad sunlit
  // rises and damp hollows give the ground a read from across the screen.
  float macroV = fbm3(w * 0.00058 + 311.0);
  col *= 0.78 + 0.46 * smoothstep(0.24, 0.80, macroV);
  col *= 0.93 + 0.16 * fbm3(w * 0.00072 + 47.0);
  // sun-bleached dry grass, in broad regions where the moisture runs out
  float dry = smoothstep(0.60, 0.26, moist)
            * smoothstep(0.34, 0.66, fbm3(w * 0.00095 + 123.0)) * (1.0 - marshHint);
  vec3 dryC = mix(ramp(cGrass[0], cGrass[1], cGrass[2], cGrass[3], 1.9 + (d2 - 0.5) * 0.6),
                  ramp(cSand[0], cSand[1], cSand[2], cSand[3], 2.1 + (d1 - 0.5) * 0.7), 0.62);
  col = mix(col, dryC * 0.86, dry * 0.72);

  // dry dirt patches gnawing into the grass
  float dirt = smoothstep(0.575, 0.760, fbm3(w * 0.0068 + 61.0) + (d2 - 0.5) * 0.20);
  dirt *= (1.0 - fert * 0.55) * (1.0 - smoothstep(0.45, 0.72, moist));
  vec3 soilC = ramp(cSoil[0], cSoil[1], cSoil[2], cSoil[3], 0.9 + d2 * 1.5 + d3 * 0.4);
  col = mix(col, soilC, dirt * 0.85);

  // ---- marsh -----------------------------------------------------------
  float marshT = marshHint;
  vec3 marshC = mix(ramp(cMoss[0], cMoss[1], cMoss[2], cMoss[3], 0.35 + d2 * 1.5),
                    ramp(cWater[0], cWater[1], cWater[2], cWater[3], 1.05), 0.30);
  float puddle = smoothstep(0.58, 0.72, fbm3(w * 0.0105 + 91.0)) * marshT;
  marshC = mix(marshC, ramp(cWater[0], cWater[1], cWater[2], cWater[3], 1.55 + d3 * 0.6), puddle);
  col = mix(col, marshC, marshT);

  // ---- beach -----------------------------------------------------------
  // wide sandy bays in some places, almost none on the rocky headlands
  float bayW = fbm3(w * 0.00088 + 211.0);
  float beachW = uBeach * (0.22 + 2.10 * bayW * (0.55 + 0.75 * d1))
               * (1.0 - smoothstep(0.34, 0.62, slope) * 0.85);
  float beachT = 1.0 - smoothstep(0.0, beachW, sdw);
  beachT = smoothstep(0.05, 0.55, beachT);
  vec3 sandC = ramp(cSand[0], cSand[1], cSand[2], cSand[3],
                    1.25 + d2 * 1.35 + (d3 - 0.5) * 0.45 + smoothstep(0.0, beachW, sdw) * 0.5);
  float wetT = 1.0 - smoothstep(0.0, uWet * (0.7 + 0.7 * d2), sdw);
  sandC = mix(sandC, ramp(cSand[0], cSand[1], cSand[2], cSand[3], 0.15 + d3 * 0.3) * 0.92,
              wetT * 0.85);
  // a thin bright tide line where the wet band ends
  float tide = smoothstep(0.35, 0.0, abs(sdw - uWet * (0.7 + 0.7 * d2)) / 6.0);
  sandC = mix(sandC, cSand[3], tide * 0.30);
  col = mix(col, sandC, beachT);

  // ---- rock ------------------------------------------------------------
  float rk = rockMask(slope, elev);
  float rockT = smoothstep(0.42, 0.66, rk + (d2 - 0.5) * 0.34 + (d1 - 0.5) * 0.30);
  rockT *= 0.30 + 0.70 * smoothstep(0.0, beachW * 1.1, sdw);   // sand wins at the tideline
  // Faceted stone. A continuous fracture field, however many octaves it has,
  // renders as combed brushstrokes -- grey fur on the headland. Quantising it
  // into discrete bedding planes is what turns it into flat-vector rock with
  // planes you can read the light on.
  float strata = rdg3(w * 0.0225 + vec2(0.0, elev * 14.0));
  float joints = rdg3(w * 0.0700 + 7.0);
  float band   = strata * 5.0 + joints * 0.9 + (d3 - 0.5) * 0.30;
  float terr   = floor(band) * 0.2;
  vec3 rockC = ramp(cRock[0], cRock[1], cRock[2], cRock[3],
                    0.20 + terr * 2.20 + elev * 0.72);
  // a lit lip along the top of each plane and a dark seam beneath it
  float bf = fract(band);
  rockC *= 1.0 + smoothstep(0.18, 0.0, bf) * 0.36 - smoothstep(0.82, 1.0, bf) * 0.32;

  // sun-side rim and down-sun drop shadow, sampled from the neighbouring field
  vec4 As = Texel(fieldA, fuv(w + uSun * 30.0));
  vec4 Bs = Texel(fieldB, fuv(w + uSun * 30.0));
  float rkN = rockMask(Bs.a, As.r);
  float rkNs = smoothstep(0.40, 0.60, rkN);
  float shadow = clamp(rkNs - rockT, 0.0, 1.0);
  float rim    = clamp(rockT - rkNs, 0.0, 1.0);
  rockC = mix(rockC, cRock[3], smoothstep(0.22, 0.90, rim) * 0.55);
  col = mix(col, rockC, rockT);
  col *= 1.0 - shadow * 0.42 * (1.0 - rockT * 0.5);

  // contact shadow where the ground drops steeply, regardless of biome
  col *= 1.0 - smoothstep(0.35, 0.85, slope) * 0.16;
  // and a gentle bowl shadow in the low basins, for depth
  col *= 1.0 - (1.0 - smoothstep(0.02, 0.26, elev)) * 0.10 * (1.0 - beachT);

  // ---- blight scar -----------------------------------------------------
  // `scar` is a smooth low-frequency field. Sampled straight it dissolves into
  // the grass as an airbrushed gradient over hundreds of pixels -- the single
  // ugliest thing on screen. Bite its edge with the same pixel-scale noise the
  // coastline uses, so the blight *eats* into living ground on a crinkled front.
  float scarN = scar + (d1 - 0.5) * 0.34 + (d2 - 0.5) * 0.20 + (d3 - 0.5) * 0.09;
  float scarT = smoothstep(0.30, 0.50, scarN) * (1.0 - beachT * 0.75);
  float scarEdge = smoothstep(0.15, 0.33, scarN) * (1.0 - smoothstep(0.29, 0.45, scarN));
  if (scarT > 0.002 || scarEdge > 0.002) {
    // Dead ground is *ash over cinder*, and carries the whole value structure.
    // The violet is a stain down in the fissures; it is never the local colour
    // of the dirt, because poisoned earth is not a sweet.
    float plates = rdg3(w * 0.0335 + 131.0);        // cracked-earth crazing
    float coarse = fbm3(w * 0.0074 + 57.0);
    vec3 dead = ramp(cAsh[0], cAsh[1], cAsh[2], cAsh[3],
                     0.40 + coarse * 1.75 + (d2 - 0.5) * 0.95 + (d3 - 0.5) * 0.35);
    dead = mix(dead, ramp(cSoil[0], cSoil[1], cSoil[2], cSoil[3], 0.45 + d2 * 1.2), 0.34);
    float fis = smoothstep(0.50, 0.80, plates);     // fissures between the plates
    dead *= 1.0 - fis * 0.50;
    dead += cAsh[3] * smoothstep(0.85, 0.99, plates) * 0.16;  // dust on the lips
    float core = smoothstep(0.40, 0.88, scarN);
    dead = mix(dead, mix(dead, cBlight[1], 0.72), fis * core);
    dead += cBlight[3] * smoothstep(0.93, 0.999, plates) * core * 0.34;
    col = mix(col, dead, scarT);
    // a narrow rot rim: grass going grey-violet a few metres before it dies,
    // tight enough to read as an edge rather than as a wash
    vec3 rot = mix(col * 0.70, cBlight[1], 0.45);
    col = mix(col, rot, scarEdge * 0.85);
  }

  // ---- macro value composition -----------------------------------------
  // highlands read bright and warm, lowlands sink and cool: this is what makes
  // the island legible as topography from a distance
  col *= 0.82 + 0.42 * elev;
  col = mix(col, col * vec3(1.06, 1.02, 0.94), smoothstep(0.35, 0.85, elev) * 0.6);
  col = mix(col, col * vec3(0.93, 0.98, 1.07), (1.0 - smoothstep(0.05, 0.34, elev)) * 0.5);

  // ---- light and shoreline shading -------------------------------------
  col *= lit;

  // the water darkens the very edge of the land
  col *= mix(1.0, 0.74, 1.0 - smoothstep(0.0, 9.0, sdw));

  // depth-cue: a touch of the flora colour bleeding out of dense growth
  col += cFlora * lush * fert * 0.045;

  col = clamp(col, 0.0, 1.0);
  return vec4(col * alpha, alpha) * vcol;
}
]==]

-- Encodes the lit-ground normal so the lighting pass can use it later.
local NORMAL_GLSL = [==[
extern Image fieldA;
extern vec2  uFScale;
extern vec2  uFBias;
extern vec2  uWorld;

float hsh(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vn(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hsh(i), hsh(i + vec2(1.0, 0.0)), u.x),
             mix(hsh(i + vec2(0.0, 1.0)), hsh(i + vec2(1.0, 1.0)), u.x), u.y);
}
vec2 fuv(vec2 w) { return clamp(w / uWorld, vec2(0.0), vec2(1.0)) * uFScale + uFBias; }

vec4 effect(vec4 vcol, Image tx, vec2 tc, vec2 sc) {
  vec2 w = tc * uWorld;
  vec4 A = Texel(fieldA, fuv(w));
  vec2 grad = A.gb * 2.0 - 1.0;
  float e = 3.0;
  float mx = vn((w + vec2(e, 0.0)) * 0.075) - vn((w - vec2(e, 0.0)) * 0.075);
  float my = vn((w + vec2(0.0, e)) * 0.075) - vn((w - vec2(0.0, e)) * 0.075);
  vec3 nrm = normalize(vec3(-grad.x - mx * 0.32, -grad.y - my * 0.32, 1.0));
  float land = step(0.5, A.a);
  return vec4(nrm * 0.5 + 0.5, land);
}
]==]

-- Packs the signed shore distance into a standalone canvas for the water shader.
local SHORE_GLSL = [==[
extern Image fieldA;
extern vec2  uFScale;
extern vec2  uFBias;
vec4 effect(vec4 vcol, Image tx, vec2 tc, vec2 sc) {
  vec4 A = Texel(fieldA, clamp(tc, vec2(0.0), vec2(1.0)) * uFScale + uFBias);
  return vec4(A.a, step(0.5, A.a), A.r, 1.0);
}
]==]

-- Animated lapping foam that runs up onto the sand. Drawn above the ground.
local FOAM_GLSL = [==[
extern Image shore;
extern vec4  uView;      // world rect being drawn
extern vec2  uWorld;
extern float uTime;
extern float uSdMax;
extern vec3  cFoam;
extern vec3  cWet;

float hsh(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vn(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hsh(i), hsh(i + vec2(1.0, 0.0)), u.x),
             mix(hsh(i + vec2(0.0, 1.0)), hsh(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm3(vec2 p) {
  float s = 0.0; float a = 0.5; float n = 0.0;
  for (int i = 0; i < 3; i++) { s += vn(p) * a; n += a; a *= 0.5; p *= 2.05; }
  return s / n;
}
float fbm4(vec2 p) {
  float s = 0.0; float a = 0.5; float n = 0.0;
  for (int i = 0; i < 4; i++) { s += vn(p) * a; n += a; a *= 0.5; p *= 2.03; }
  return s / n;
}
float crinkle(vec2 w) {
  return (fbm4(w * 0.0125 + 5.0) - 0.5) * 24.0
       + (fbm3(w * 0.0480 + 17.3) - 0.5) * 17.0
       + (vn(w * 0.1400 + 91.0) - 0.5) * 9.0;
}

vec4 effect(vec4 vcol, Image tx, vec2 tc, vec2 sc) {
  vec2 w = uView.xy + tc * uView.zw;
  vec2 uv = clamp(w / uWorld, vec2(0.0), vec2(1.0));
  float se = Texel(shore, uv).r * 2.0 - 1.0;
  float sd = se * abs(se) * uSdMax;
  // outside the map there is only open ocean, never a smeared edge texel
  vec2 od = max(vec2(0.0) - w, w - uWorld);
  sd = sd - length(max(od, vec2(0.0))) * 1.6;
  if (sd < -70.0 || sd > 110.0) { return vec4(0.0); }
  sd = sd + crinkle(w);
  if (sd < -2.0 || sd > 46.0) { return vec4(0.0); }

  float wob = fbm3(w * 0.017 + vec2(uTime * 0.09, -uTime * 0.05));
  float surge = 0.5 + 0.5 * sin(uTime * 0.62 + fbm3(w * 0.004) * 5.5);
  float reach = 6.0 + 30.0 * surge * (0.55 + 0.9 * wob);

  float run = 1.0 - smoothstep(0.0, reach, sd);
  float lip = smoothstep(0.55, 1.0, run) * smoothstep(1.0, 0.80, run);
  float wet = run * run;

  vec3 col = mix(cWet, cFoam, clamp(lip * 2.2 + smoothstep(0.85, 1.0, run) * 0.5, 0.0, 1.0));
  float a = wet * 0.34 + lip * 0.75;
  a *= smoothstep(-2.0, 3.0, sd);
  return vec4(col * a, a) * vcol;
}
]==]

--------------------------------------------------------------------- the class
local Terrain = Class("Terrain")

local function noyield() end

function Terrain:init(seed, opts)
  self.seed = seed or 20190101
  self.w, self.h = TW.w, TW.h
  self.cell = CELL
  self.gw = floor(self.w / CELL) + 1
  self.gh = floor(self.h / CELL) + 1
  self.time = 0
  self.baked = false
  self.generated = false
  self.progress = 0
  self._yield = noyield
  self.deferred = (opts and opts.defer) or false
  if not self.deferred then self:_generate() end
end

--- Generate nothing up front: bakeStep() will do the fields and the canvases,
--- a slice at a time, so a loading screen can drive the whole thing.
function Terrain.newDeferred(seed) return Terrain.new(seed, { defer = true }) end

function Terrain:bounds() return 0, 0, self.w, self.h end

---------------------------------------------------------------------- generate
function Terrain:_generate()
  local t0 = love.timer and love.timer.getTime() or os.clock()
  local yield = self._yield
  local gw, gh, cell = self.gw, self.gh, self.cell
  local n = gw * gh
  local sb = (self.seed % 977) * 3

  local s1, s2, s3, s4 = sb + 1, sb + 2, sb + 3, sb + 4
  local s5, s6, s7, s8 = sb + 5, sb + 6, sb + 7, sb + 8
  local s9 = sb + 9

  local elev, moist, land = {}, {}, {}
  local scar, heal = {}, {}
  local cx, cy = self.w * 0.5, self.h * 0.5
  local rx, ry = self.w * 0.5, self.h * 0.5

  for gy = 0, gh - 1 do
    if gy % 24 == 0 then yield(gy / gh * 0.80) end
    local wy = gy * cell
    local base = gy * gw
    for gx = 0, gw - 1 do
      local wx = gx * cell
      local i = base + gx + 1

      -- two-scale domain warp: bays and peninsulas instead of a circle
      local w1 = N.fbm(wx * 0.00052 + 4.1, wy * 0.00052 - 2.3, 3, s1)
      local w2 = N.fbm(wx * 0.00052 - 7.7, wy * 0.00052 + 5.9, 3, s1 + 40)
      local v1 = N.fbm(wx * 0.00205 + 19.0, wy * 0.00205 + 3.0, 3, s1 + 80)
      local v2 = N.fbm(wx * 0.00205 - 11.0, wy * 0.00205 - 8.0, 3, s1 + 120)
      local qx = wx + (w1 - 0.5) * 1280 + (v1 - 0.5) * 300
      local qy = wy + (w2 - 0.5) * 1080 + (v2 - 0.5) * 250

      local dx, dy = (qx - cx) / rx, (qy - cy) / ry
      local r = sqrt(dx * dx + dy * dy)
      local ang = atan2(dy, dx)
      -- periodic in angle, so the falloff radius itself grows lobes
      local lobe = 0.46 + 0.40 * N.fbm(cos(ang) * 3.4 + 11.0, sin(ang) * 3.4 + 6.0, 4, s2)
      local mask = U.smoothstep(lobe + 0.30, lobe - 0.16, r)

      local cont = N.fbm(wx * 0.00090 + 11.0, wy * 0.00090 + 7.0, 5, s3)
      local det  = N.fbm(wx * 0.00390 - 3.0, wy * 0.00390 + 2.0, 4, s4)
      local lv = mask * 1.30 + (cont - 0.5) * 1.34 + (det - 0.5) * 0.26 - 0.598

      -- two scales of bay bitten out of the silhouette: broad gulfs and inlets
      local bay1 = N.fbm(qx * 0.00062 + 301.0, qy * 0.00062 - 143.0, 3, s9)
      local bay2 = N.fbm(wx * 0.00140 - 77.0, wy * 0.00140 + 211.0, 3, s9 + 30)
      lv = lv - U.smoothstep(0.47, 0.86, bay1) * 1.10 * U.smoothstep(0.08, 0.86, r)
              - U.smoothstep(0.60, 0.92, bay2) * 0.70 * U.smoothstep(0.26, 1.00, r)

      -- offshore islets and skerries in the shallow ring
      local isl = N.fbm(wx * 0.0031 + 41.0, wy * 0.0031 + 17.0, 3, s5)
      lv = lv + U.smoothstep(0.62, 0.90, isl) * U.smoothstep(1.42, 0.78, r) * 0.72

      land[i] = lv

      if lv > 0 then
        local ln = U.saturate(lv / 0.62)
        local hills = N.fbm(wx * 0.0030 + 21.0, wy * 0.0030 - 9.0, 5, s6)
        local basin = N.fbm(wx * 0.0013 + 63.0, wy * 0.0013 - 27.0, 3, s6 + 60)
        local spine = N.ridge(wx * 0.0018 - 13.0, wy * 0.0018 + 31.0, 4, s7)
        -- broad plains, a few genuine highlands, a couple of low basins
        local e = ln ^ 1.25 * (0.26 + 0.42 * hills) + (basin - 0.5) * 0.20
        e = e + spine * spine * U.smoothstep(0.42, 0.95, ln) * 0.68
        e = U.saturate(e)
        elev[i] = e
        local mo = N.fbm(wx * 0.0021 + 77.0, wy * 0.0021 + 53.0, 4, s8)
        -- water collects low and drains off the highlands
        moist[i] = U.saturate(mo * 0.80 + (1 - e) * 0.40 - 0.11)
      else
        elev[i] = 0
        moist[i] = 1
      end
      scar[i] = 0
      heal[i] = 0
    end
  end

  self.elev, self.moist, self.landv, self.scar, self.heal = elev, moist, land, scar, heal

  yield(0.82)
  self:_distanceField()
  yield(0.86)
  self:_scars()
  yield(0.92)
  self:_classify()
  yield(0.97)
  self:_buildFields()
  self.generated = true

  self.genTime = (love.timer and love.timer.getTime() or os.clock()) - t0
end

--- Two-pass chamfer distance transform, run once from water and once from land,
--- combined into a signed distance (positive on land) in world units.
function Terrain:_distanceField()
  local gw, gh, cell = self.gw, self.gh, self.cell
  local land = self.landv
  local INF = 1e7
  local A, B = {}, {}   -- A: distance to nearest water, B: distance to nearest land
  for i = 1, gw * gh do
    if land[i] > 0 then A[i] = INF; B[i] = 0 else A[i] = 0; B[i] = INF end
  end

  local D1, D2 = 1.0, 1.41421356
  local function pass(D)
    for gy = 0, gh - 1 do
      local row = gy * gw
      for gx = 0, gw - 1 do
        local i = row + gx + 1
        local v = D[i]
        if v > 0 then
          if gx > 0 then local c = D[i - 1] + D1 if c < v then v = c end end
          if gy > 0 then
            local up = i - gw
            local c = D[up] + D1 if c < v then v = c end
            if gx > 0 then c = D[up - 1] + D2 if c < v then v = c end end
            if gx < gw - 1 then c = D[up + 1] + D2 if c < v then v = c end end
          end
          D[i] = v
        end
      end
    end
    for gy = gh - 1, 0, -1 do
      local row = gy * gw
      for gx = gw - 1, 0, -1 do
        local i = row + gx + 1
        local v = D[i]
        if v > 0 then
          if gx < gw - 1 then local c = D[i + 1] + D1 if c < v then v = c end end
          if gy < gh - 1 then
            local dn = i + gw
            local c = D[dn] + D1 if c < v then v = c end
            if gx > 0 then c = D[dn - 1] + D2 if c < v then v = c end end
            if gx < gw - 1 then c = D[dn + 1] + D2 if c < v then v = c end end
          end
          D[i] = v
        end
      end
    end
  end
  pass(A); pass(B)

  local sd = {}
  for i = 1, gw * gh do
    if land[i] > 0 then sd[i] = A[i] * cell else sd[i] = -B[i] * cell end
  end
  self.sd = sd
end

--- A few dead regions, placed on real land, away from the coast and each other.
function Terrain:_scars()
  local rng = U.rng(self.seed * 7919 + 17)
  local gw, gh, cell = self.gw, self.gh, self.cell
  local sd, scar = self.sd, self.scar
  local sN = (self.seed % 811) + 300

  local centres, tries = {}, 0
  local want = 3 + floor(rng:next() * 2)
  while #centres < want and tries < 900 do
    tries = tries + 1
    local gx = rng:int(4, gw - 5)
    local gy = rng:int(4, gh - 5)
    local i = gy * gw + gx + 1
    if sd[i] > 190 then
      local wx, wy = gx * cell, gy * cell
      local ok = true
      for _, c in ipairs(centres) do
        if U.dist(wx, wy, c.x, c.y) < 620 then ok = false break end
      end
      if ok then
        centres[#centres + 1] = { x = wx, y = wy, r = rng:range(175, 305),
                                  ang = rng:angle(), ecc = rng:range(1.35, 2.30) }
      end
    end
  end
  self.scarCentres = centres

  for _, c in ipairs(centres) do
    local ca, sa = cos(-c.ang), sin(-c.ang)
    local reach = c.r * c.ecc * 1.9
    local g0x = max(0, floor((c.x - reach) / cell))
    local g1x = min(gw - 1, ceil((c.x + reach) / cell))
    local g0y = max(0, floor((c.y - reach) / cell))
    local g1y = min(gh - 1, ceil((c.y + reach) / cell))
    for gy = g0y, g1y do
      for gx = g0x, g1x do
        local i = gy * gw + gx + 1
        local wx, wy = gx * cell, gy * cell
        -- warp the sample before measuring, so the blight has an eaten edge
        local ox = (N.fbm(wx * 0.0026 + 5.0, wy * 0.0026 - 3.0, 3, sN) - 0.5) * c.r * 1.45
        local oy = (N.fbm(wx * 0.0026 + 55.0, wy * 0.0026 + 31.0, 3, sN + 7) - 0.5) * c.r * 1.45
        local px, py = wx + ox - c.x, wy + oy - c.y
        local ex = (px * ca - py * sa) / (c.r * c.ecc)
        local ey = (px * sa + py * ca) / c.r
        local d = sqrt(ex * ex + ey * ey)
        local fine = N.fbm(wx * 0.0090 - 21.0, wy * 0.0090 + 13.0, 3, sN + 19)
        local v = U.smoothstep(1.00, 0.30, d + (fine - 0.5) * 0.34)
        if v > scar[i] then scar[i] = v end
      end
    end
  end
end

function Terrain:_classify()
  local gw, gh, cell = self.gw, self.gh, self.cell
  local elev, moist, sd, scar = self.elev, self.moist, self.sd, self.scar
  local biome, fert, slope = {}, {}, {}
  local gradx, grady = {}, {}
  local sN = (self.seed % 733) + 120
  local kslope = RELIEF / (2 * cell)

  local landIdx, fertIdx = {}, {}

  for gy = 0, gh - 1 do
    local row = gy * gw
    for gx = 0, gw - 1 do
      local i = row + gx + 1
      local xm = (gx > 0) and (i - 1) or i
      local xp = (gx < gw - 1) and (i + 1) or i
      local ym = (gy > 0) and (i - gw) or i
      local yp = (gy < gh - 1) and (i + gw) or i
      local gxv = (elev[xp] - elev[xm]) * kslope
      local gyv = (elev[yp] - elev[ym]) * kslope
      gradx[i], grady[i] = gxv, gyv
      local sl = min(1, sqrt(gxv * gxv + gyv * gyv))
      slope[i] = sl

      local d = sd[i]
      if d <= 0 then
        biome[i] = B_WATER
        fert[i] = 0
      else
        local wx, wy = gx * cell, gy * cell
        local bw = BEACH_W * (0.60 + 0.85 * N.fbm(wx * 0.0115, wy * 0.0115, 3, sN))
        local sc = scar[i]
        local e, m = elev[i], moist[i]
        local b
        if d < bw then
          b = B_BEACH
          fert[i] = 0.10 + 0.10 * m
        elseif sc > 0.42 then
          b = B_SCAR
          fert[i] = 0.02
        elseif sl > 0.52 or e > 0.66 then
          b = B_ROCK
          fert[i] = 0.06 + 0.12 * m * (1 - sl)
        elseif m > 0.60 and e < 0.26 then
          b = B_MARSH
          fert[i] = 0.44 + 0.28 * m
        else
          b = B_MEADOW
          fert[i] = U.saturate(0.44 + 0.54 * m - 0.40 * sl - 0.30 * max(0, e - 0.36))
        end
        fert[i] = fert[i] * (1 - sc * 0.95)
        biome[i] = b
        if d > 26 then
          landIdx[#landIdx + 1] = i
          if fert[i] > 0.45 then fertIdx[#fertIdx + 1] = i end
        end
      end
    end
  end

  self.biome, self.fert, self.slope = biome, fert, slope
  self.gradx, self.grady = gradx, grady
  self.landIdx, self.fertIdx = landIdx, fertIdx
  self.landArea = #landIdx * cell * cell
end

--- Pack the fields into two RGBA8 textures for the bake shader.
function Terrain:_buildFields()
  local gw, gh = self.gw, self.gh
  local elev, sd, moist, fert, scar, slope = self.elev, self.sd, self.moist,
                                             self.fert, self.scar, self.slope
  local gradx, grady = self.gradx, self.grady
  local ch = string.char
  local a, b = {}, {}
  local ka, kb = 0, 0
  for i = 1, gw * gh do
    local gx = U.clamp(gradx[i], -1, 1) * 0.5 + 0.5
    local gy = U.clamp(grady[i], -1, 1) * 0.5 + 0.5
    -- signed-sqrt encoding: 8 bits, but almost all of the precision lands
    -- where it matters (within a few units of the waterline)
    local t = U.clamp(sd[i] / SD_MAX, -1, 1)
    local dd = (t < 0 and -sqrt(-t) or sqrt(t)) * 0.5 + 0.5
    ka = ka + 1
    a[ka] = ch(floor(elev[i] * 255 + 0.5), floor(gx * 255 + 0.5),
               floor(gy * 255 + 0.5), floor(dd * 255 + 0.5))
    kb = kb + 1
    b[kb] = ch(floor(U.saturate(moist[i]) * 255 + 0.5), floor(U.saturate(fert[i]) * 255 + 0.5),
               floor(U.saturate(scar[i] - self.heal[i]) * 255 + 0.5),
               floor(U.saturate(slope[i]) * 255 + 0.5))
  end
  local idA = love.image.newImageData(gw, gh, "rgba8", table.concat(a))
  local idB = love.image.newImageData(gw, gh, "rgba8", table.concat(b))
  self.fieldA = love.graphics.newImage(idA)
  self.fieldB = love.graphics.newImage(idB)
  self.fieldA:setFilter("linear", "linear")
  self.fieldB:setFilter("linear", "linear")
  self.fieldA:setWrap("clamp", "clamp")
  self.fieldB:setWrap("clamp", "clamp")
  self._fScale = { (gw - 1) / gw, (gh - 1) / gh }
  self._fBias  = { 0.5 / gw, 0.5 / gh }
end

------------------------------------------------------------------------ queries
function Terrain:_sample(field, x, y)
  local cell, gw, gh = self.cell, self.gw, self.gh
  local fx = U.clamp(x / cell, 0, gw - 1.001)
  local fy = U.clamp(y / cell, 0, gh - 1.001)
  local ix, iy = floor(fx), floor(fy)
  local tx, ty = fx - ix, fy - iy
  local i = iy * gw + ix + 1
  local a, b = field[i], field[i + 1]
  local c, d = field[i + gw], field[i + gw + 1]
  local top = a + (b - a) * tx
  local bot = c + (d - c) * tx
  return top + (bot - top) * ty
end

function Terrain:_idx(x, y)
  local gx = U.clamp(floor(x / self.cell + 0.5), 0, self.gw - 1)
  local gy = U.clamp(floor(y / self.cell + 0.5), 0, self.gh - 1)
  return gy * self.gw + gx + 1
end

function Terrain:heightAt(x, y) return U.saturate(self:_sample(self.elev, x, y)) end
function Terrain:soilAt(x, y)
  local i = self:_idx(x, y)
  return U.saturate(self:_sample(self.fert, x, y) * (1 - U.saturate(self.scar[i] - self.heal[i]) * 0.9))
end
function Terrain:shoreDistAt(x, y) return self:_sample(self.sd, x, y) end
function Terrain:slopeAt(x, y) return U.saturate(self:_sample(self.slope, x, y)) end
function Terrain:isLand(x, y)
  if x < 0 or y < 0 or x > self.w or y > self.h then return false end
  return self:_sample(self.sd, x, y) > 0
end

function Terrain:biomeAt(x, y)
  local i = self:_idx(x, y)
  local b = self.biome[i]
  if b == B_WATER then return "water" end
  if b == B_SCAR and self.heal[i] > 0.55 then return "meadow" end
  return BIOME[b]
end

--- Pick a land point. opts.minSoil, opts.minShore, opts.biome,
--- opts.awayFrom = {x=, y=, r=}, opts.tries.
function Terrain:randomLandPoint(rng, opts)
  opts = opts or {}
  rng = rng or U.rng(self.seed)
  local pool = (opts.minSoil and opts.minSoil > 0.45 and #self.fertIdx > 64)
               and self.fertIdx or self.landIdx
  local cell, gw = self.cell, self.gw
  local tries = opts.tries or 90
  local bestX, bestY, bestS = nil, nil, -1
  local away = opts.awayFrom
  for _ = 1, tries do
    local i = pool[rng:int(1, #pool)]
    local gx = (i - 1) % gw
    local gy = floor((i - 1) / gw)
    local x = gx * cell + (rng:next() - 0.5) * cell
    local y = gy * cell + (rng:next() - 0.5) * cell
    local ok = true
    if opts.minShore and self.sd[i] < opts.minShore then ok = false end
    if ok and opts.biome and BIOME[self.biome[i]] ~= opts.biome then ok = false end
    if ok and away and U.dist(x, y, away.x, away.y) < (away.r or 0) then ok = false end
    local s = self.fert[i] * (1 - U.saturate(self.scar[i] - self.heal[i]))
    if ok and opts.minSoil and s < opts.minSoil then
      if s > bestS then bestX, bestY, bestS = x, y, s end
      ok = false
    end
    if ok then return x, y end
    if s > bestS then bestX, bestY, bestS = x, y, s end
  end
  if bestX then return bestX, bestY end
  local i = pool[1] or 1
  return ((i - 1) % gw) * cell, floor((i - 1) / gw) * cell
end

--- Nearest point on land. Walks up the distance field, then falls back to a
--- coarse ring search.
function Terrain:nearestLand(x, y)
  x = U.clamp(x, 0, self.w)
  y = U.clamp(y, 0, self.h)
  if self:isLand(x, y) then return x, y end
  local cell = self.cell
  for _ = 1, 40 do
    local d = self:_sample(self.sd, x, y)
    if d > 1 then return x, y end
    local e = cell
    local gx = (self:_sample(self.sd, x + e, y) - self:_sample(self.sd, x - e, y))
    local gy = (self:_sample(self.sd, x, y + e) - self:_sample(self.sd, x, y - e))
    local nx, ny, l = U.norm(gx, gy)
    if l < 1e-6 then break end
    local step = max(cell, -d * 0.55)
    x = U.clamp(x + nx * step, 0, self.w)
    y = U.clamp(y + ny * step, 0, self.h)
  end
  local best, bx, by = 1e18, self.w * 0.5, self.h * 0.5
  local gw = self.gw
  for k = 1, #self.landIdx, 7 do
    local i = self.landIdx[k]
    local px = ((i - 1) % gw) * cell
    local py = floor((i - 1) / gw) * cell
    local d2 = U.dist2(x, y, px, py)
    if d2 < best then best, bx, by = d2, px, py end
  end
  return bx, by
end

--------------------------------------------------------------------------- bake
--- Uniforms the GLSL compiler optimised away are not errors.
local function put(sh, name, ...)
  if sh:hasUniform(name) then sh:send(name, ...) end
end

local function rampVecs(r)
  local o = {}
  for i = 1, 4 do o[i] = { r[i][1], r[i][2], r[i][3] } end
  return o
end

function Terrain:_makeShaders()
  if self._ground then return end
  self._ground = love.graphics.newShader(GROUND_GLSL)
  self._normalSh = love.graphics.newShader(NORMAL_GLSL)
  self._shoreSh = love.graphics.newShader(SHORE_GLSL)
  self._foamSh = love.graphics.newShader(FOAM_GLSL)

  local white = love.image.newImageData(1, 1, "rgba8", string.char(255, 255, 255, 255))
  self._white = love.graphics.newImage(white)

  local g = self._ground
  put(g, "fieldA", self.fieldA)
  put(g, "fieldB", self.fieldB)
  put(g, "uFScale", self._fScale)
  put(g, "uFBias", self._fBias)
  put(g, "uWorld", { self.w, self.h })
  put(g, "uSdMax", SD_MAX)
  put(g, "uBeach", BEACH_W)
  put(g, "uWet", WET_W)
  put(g, "uSun", { SUN[1], SUN[2] })
  put(g, "uSunZ", SUN_Z)
    local R = P.ramp
  local function sendRamp(name, ramp)
    local v = rampVecs(ramp)
    put(g, name, v[1], v[2], v[3], v[4])
  end
  sendRamp("cSand", R.sand)
  sendRamp("cGrass", R.grass)
  sendRamp("cMoss", R.moss)
  sendRamp("cRock", R.rock)
  sendRamp("cSoil", R.soil)
  sendRamp("cBlight", R.blight)
  sendRamp("cAsh", R.ash)
  sendRamp("cWater", R.water)
  put(g, "cFlora", { R.leaf[2][1], R.leaf[2][2], R.leaf[2][3] })

  local nsh = self._normalSh
  put(nsh, "fieldA", self.fieldA)
  put(nsh, "uFScale", self._fScale)
  put(nsh, "uFBias", self._fBias)
  put(nsh, "uWorld", { self.w, self.h })
  put(nsh, "uSdMax", SD_MAX)

  put(self._shoreSh, "fieldA", self.fieldA)
  put(self._shoreSh, "uFScale", self._fScale)
  put(self._shoreSh, "uFBias", self._fBias)

  local f = self._foamSh
  put(f, "uWorld", { self.w, self.h })
  put(f, "uSdMax", SD_MAX)
  put(f, "cFoam", { R.water[4][1], R.water[4][2], R.water[4][3] })
  put(f, "cWet", { R.water[3][1], R.water[3][2], R.water[3][3] })
end

function Terrain:_bakeCoroutine()
  return coroutine.wrap(function()
    local p0 = 0
    if not self.generated then
      p0 = 0.34
      self._yield = function(p) coroutine.yield(p * p0) end
      self:_generate()
      self._yield = noyield
    end
    local ps = 1 - p0
    local function emit(p) coroutine.yield(p0 + ps * p) end
    self:_makeShaders()

    local cols = ceil(self.w / TILE_W)
    local rows = ceil(self.h / TILE_H)
    self.tiles = {}
    self.tileCols, self.tileRows = cols, rows
    local total = cols * rows
    local done = 0

    local prevBlend, prevAlpha = love.graphics.getBlendMode()

    for ty = 0, rows - 1 do
      for tx = 0, cols - 1 do
        local wx, wy = tx * TILE_W, ty * TILE_H
        local canvas = love.graphics.newCanvas(TILE_W, TILE_H)
        canvas:setFilter("linear", "linear")
        local tile = { canvas = canvas, x = wx, y = wy, w = TILE_W, h = TILE_H }
        self.tiles[#self.tiles + 1] = tile

        love.graphics.setCanvas(canvas)
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.setBlendMode("replace")
        love.graphics.setShader(self._ground)
        put(self._ground, "uTile", { wx, wy, TILE_W, TILE_H })
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(self._white, 0, 0, 0, TILE_W, TILE_H)
        love.graphics.setShader()
        love.graphics.setBlendMode("alpha")
        love.graphics.setCanvas()
        done = done + 1
        emit(done / (total * 2 + 2) * 0.9)

        -- vector marks, in four passes so a slow machine can breathe
        for part = 0, 3 do
          love.graphics.setCanvas(canvas)
          self:_scatterMarks(tile, part, 4)
          love.graphics.setCanvas()
          emit((done + (part + 1) / 4) / (total * 2 + 2) * 0.9)
        end
        done = done + 1
      end
    end

    love.graphics.setBlendMode(prevBlend, prevAlpha)

    -- normal buffer for the lighting pass
    local nw = floor(self.w / NORMAL_DIV)
    local nh = floor(self.h / NORMAL_DIV)
    self.normalCanvas = love.graphics.newCanvas(nw, nh)
    self.normalCanvas:setFilter("linear", "linear")
    love.graphics.setCanvas(self.normalCanvas)
    love.graphics.clear(0.5, 0.5, 1, 0)
    love.graphics.setShader(self._normalSh)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(self._white, 0, 0, 0, nw, nh)
    love.graphics.setShader()
    love.graphics.setCanvas()
    emit(0.95)

    -- signed shore distance field for the water shader
    self.shoreCanvas = love.graphics.newCanvas(SHORE_W, SHORE_H)
    self.shoreCanvas:setFilter("linear", "linear")
    love.graphics.setCanvas(self.shoreCanvas)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setShader(self._shoreSh)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(self._white, 0, 0, 0, SHORE_W, SHORE_H)
    love.graphics.setShader()
    love.graphics.setCanvas()
    put(self._foamSh, "shore", self.shoreCanvas)
    emit(1.0)
  end)
end

--- Advance the bake by at most `budget` seconds. Returns progress 0..1.
function Terrain:bakeStep(budget)
  if self.baked then return 1 end
  if not self._co then
    self._co = self:_bakeCoroutine()
    self._bakeT0 = love.timer.getTime()
  end
  local t0 = love.timer.getTime()
  repeat
    local p = self._co()
    if p == nil then
      self.baked = true
      self._co = nil
      self.progress = 1
      self.bakeTime = love.timer.getTime() - self._bakeT0
      return 1
    end
    self.progress = p
  until love.timer.getTime() - t0 >= (budget or 0.008)
  return self.progress
end

--- Bake everything now. Returns the wall time it took.
function Terrain:bake()
  while self:bakeStep(1e9) < 1 do end
  return self.bakeTime
end

function Terrain:memoryEstimate()
  local mb = 0
  if self.tiles then mb = mb + #self.tiles * TILE_W * TILE_H * 4 end
  if self.normalCanvas then
    mb = mb + self.normalCanvas:getWidth() * self.normalCanvas:getHeight() * 4
  end
  if self.shoreCanvas then mb = mb + SHORE_W * SHORE_H * 4 end
  mb = mb + self.gw * self.gh * 4 * 2
  return mb / 1048576
end

--------------------------------------------------------------------- the marks
-- Thousands of tiny baked decorations. Immediate-mode draws: LOVE batches them
-- and they cost nothing once they are in the canvas.
local function tuft(x, y, hgt, lean, wide, cBase, cTip)
  for k = -1, 1 do
    local bx = x + k * wide
    local tipx = bx + lean + k * wide * 1.6
    local tipy = y - hgt * (1 - abs(k) * 0.28)
    love.graphics.setColor(cBase)
    love.graphics.polygon("fill", bx - 0.9, y, bx + 0.9, y, tipx, tipy)
    love.graphics.setColor(cTip)
    love.graphics.polygon("fill", tipx, tipy, bx + lean * 0.5, y - hgt * 0.45,
                          tipx + 0.7, tipy + 1.2)
  end
end

function Terrain:_scatterMarks(tile, part, parts)
  local R = P.ramp
  local rng = U.rng(self.seed * 131 + (tile.x * 7 + tile.y) * 977 + part * 31)
  local cell = self.cell
  local per = floor(TILE_W * TILE_H / 112 / parts)   -- ~6000 candidates per tile
  local x0, y0 = tile.x, tile.y

  local grassShadow = R.grass[1]
  local sandShadow  = P.mix(R.sand[1], R.soil[1], 0.35)

  for _ = 1, per do
    local wx = x0 + rng:next() * TILE_W
    local wy = y0 + rng:next() * TILE_H
    if wx <= self.w and wy <= self.h then
      local i = self:_idx(wx, wy)
      local d = self.sd[i]
      if d > 18 then
        local b = self.biome[i]
        local lx, ly = wx - x0, wy - y0
        local fert = self.fert[i]
        local sc = U.saturate(self.scar[i] - self.heal[i])
        local shade = 0.75 + 0.5 * rng:next()

        if b == B_MEADOW or (b == B_MARSH and rng:chance(0.35)) then
          -- Uniform scatter reads as television static. Gate the density on a
          -- slow field so ground cover grows in drifts and leaves bare clearings.
          local clump = N.fbm(wx * 0.0038 + 811.0, wy * 0.0038 - 411.0, 3,
                              self.seed % 307 + 11)
          clump = U.saturate((clump - 0.34) * 2.6)
          local roll = rng:next()
          if roll < 0.62 and rng:next() > 0.22 + clump * 0.92 then roll = 0.995 end
          -- flowers grow in drifts, not evenly sprinkled
          local bloom = N.fbm(wx * 0.0055 + 301.0, wy * 0.0055 - 77.0, 3, self.seed % 401 + 60)
          if roll >= 0.62 and roll < 0.80 and bloom < 0.56 then roll = 0.30 end
          if roll < 0.62 then
            local hgt = (5 + rng:next() * 8) * (0.55 + fert * 0.75)
            local base = P.shade(R.grass, 1.0 + rng:next() * 0.7, 0.85)
            local tip  = P.shade(R.grass, 2.6 + rng:next() * 1.2 + fert, 0.9)
            love.graphics.setColor(P.alpha(grassShadow, 0.30))
            love.graphics.ellipse("fill", lx + 1.2, ly + 1.0, 2.4, 1.1, 6)
            tuft(lx, ly, hgt, (rng:next() - 0.5) * 5, 1.1 + rng:next() * 0.9, base, tip)
          elseif roll < 0.80 then
            -- flower speck
            local pick = rng:next()
            local fc = (pick < 0.40 and P.love) or (pick < 0.80 and P.warn) or P.accent
            love.graphics.setColor(P.alpha(P.darken(fc, 0.45), 0.40))
            love.graphics.circle("fill", lx + 0.7, ly + 0.7, 1.1 + rng:next() * 0.7, 5)
            love.graphics.setColor(P.alpha(fc, 0.52 + rng:next() * 0.20))
            love.graphics.circle("fill", lx, ly, 0.9 + rng:next() * 0.9, 5)
          elseif roll < 0.93 then
            -- pebble with a sun-side highlight
            local r = 1.6 + rng:next() * 3.2
            love.graphics.setColor(P.alpha(P.darken(R.rock[1], 0.2), 0.4))
            love.graphics.ellipse("fill", lx + 1.4, ly + 1.2, r, r * 0.72, 6)
            love.graphics.setColor(P.shade(R.rock, 1.4 + rng:next() * 1.2, 0.9))
            love.graphics.ellipse("fill", lx, ly, r, r * 0.78, 6)
            love.graphics.setColor(P.alpha(R.rock[4], 0.5))
            love.graphics.ellipse("fill", lx - r * 0.3, ly - r * 0.3, r * 0.42, r * 0.3, 5)
          else
            -- bare earth showing through, low and wide
            love.graphics.setColor(P.alpha(P.shade(R.soil, 1.4 + rng:next() * 0.8), 0.07 + rng:next() * 0.09))
            love.graphics.ellipse("fill", lx, ly, 9 + rng:next() * 22, 4 + rng:next() * 9, 10)
          end

        elseif b == B_MARSH then
          if rng:chance(0.55) then
            local hgt = 9 + rng:next() * 16
            local lean = (rng:next() - 0.5) * 7
            love.graphics.setColor(P.shade(R.moss, 1.0 + rng:next() * 0.8, 0.8))
            love.graphics.polygon("fill", lx - 1, ly, lx + 1, ly, lx + lean, ly - hgt)
            love.graphics.setColor(P.shade(R.moss, 2.7 + rng:next(), 0.75))
            love.graphics.polygon("fill", lx + lean, ly - hgt, lx + lean * 0.6, ly - hgt * 0.55,
                                  lx + lean + 0.9, ly - hgt + 1.6)
          else
            local r = 3 + rng:next() * 6
            love.graphics.setColor(P.alpha(P.shade(R.moss, 2.2 + rng:next()), 0.55))
            love.graphics.ellipse("fill", lx, ly, r, r * 0.7, 8)
            love.graphics.setColor(P.alpha(R.moss[4], 0.3))
            love.graphics.ellipse("fill", lx - r * 0.2, ly - r * 0.25, r * 0.45, r * 0.3, 6)
          end

        elseif b == B_BEACH then
          local roll = rng:next()
          if roll < 0.45 then
            local r = 1.2 + rng:next() * 2.6
            love.graphics.setColor(P.alpha(sandShadow, 0.32))
            love.graphics.ellipse("fill", lx + 1.0, ly + 0.9, r, r * 0.7, 6)
            love.graphics.setColor(P.shade(R.sand, 1.2 + rng:next() * 1.6, 0.9))
            love.graphics.ellipse("fill", lx, ly, r, r * 0.75, 6)
          elseif roll < 0.62 then
            -- driftwood / shell fleck
            love.graphics.setColor(P.alpha(P.shade(R.bark, 1.6 + rng:next()), 0.55))
            local a = rng:angle()
            local l = 3 + rng:next() * 9
            love.graphics.setLineWidth(1)
            love.graphics.line(lx, ly, lx + cos(a) * l, ly + sin(a) * l)
          else
            -- ripple ridges in the sand, following the shore
            local gx = self.gradx[i] or 0
            local gy = self.grady[i] or 0
            local a = atan2(gy, gx) + 1.5707963
            local l = 6 + rng:next() * 16
            love.graphics.setColor(P.alpha(R.sand[4], 0.10 + rng:next() * 0.10))
            love.graphics.setLineWidth(1)
            love.graphics.line(lx - cos(a) * l, ly - sin(a) * l, lx + cos(a) * l, ly + sin(a) * l)
          end

        elseif b == B_ROCK then
          if rng:chance(0.55) then
            local r = 2 + rng:next() * 6
            local n = 5
            local pts = {}
            local a0 = rng:angle()
            for k = 0, n - 1 do
              local a = a0 + k / n * U.TAU
              local rr = r * (0.65 + rng:next() * 0.6)
              pts[#pts + 1] = lx + cos(a) * rr
              pts[#pts + 1] = ly + sin(a) * rr * 0.8
            end
            love.graphics.setColor(P.alpha(R.rock[1], 0.45))
            love.graphics.polygon("fill", (function()
              local o = {}
              for k = 1, #pts, 2 do o[k] = pts[k] + 1.6 o[k + 1] = pts[k + 1] + 1.4 end
              return unpack(o)
            end)())
            love.graphics.setColor(P.shade(R.rock, 1.5 + rng:next() * 1.4, 0.95))
            love.graphics.polygon("fill", unpack(pts))
            love.graphics.setColor(P.alpha(R.rock[4], 0.30))
            love.graphics.polygon("fill", lx - r * 0.2, ly - r * 0.5,
                                  lx + r * 0.5, ly - r * 0.2, lx - r * 0.4, ly)
          else
            -- lichen
            love.graphics.setColor(P.alpha(P.shade(R.moss, 2.2 + rng:next()), 0.22))
            love.graphics.circle("fill", lx, ly, 2 + rng:next() * 5, 7)
          end

        elseif b == B_SCAR and sc > 0.2 then
          -- Two crossed strokes per mark read as a scattering of little letters,
          -- not as debris. One stroke, combed by a slow flow field so the litter
          -- lies the way the wind left it, reads as a dead place instead.
          local roll = rng:next()
          if roll < 0.30 then
            local flow = N.fbm(wx * 0.0021 + 17.0, wy * 0.0021 - 9.0, 2, 71) * U.TAU
            local a = flow + rng:gauss() * 0.34
            local l = 5 + rng:next() * 11
            local dx, dy = cos(a) * l, sin(a) * l * 0.7
            love.graphics.setLineWidth(1)
            love.graphics.setColor(P.alpha(P.darken(R.ash[1], 0.25), 0.34 * sc))
            love.graphics.line(lx - dx * 0.5 + 1, ly - dy * 0.5 + 1,
                               lx + dx * 0.5 + 1, ly + dy * 0.5 + 1)
            love.graphics.setColor(P.alpha(P.shade(R.ash, 2.6 + rng:next() * 1.2), 0.42 * sc))
            love.graphics.line(lx - dx * 0.5, ly - dy * 0.5, lx + dx * 0.5, ly + dy * 0.5)
          elseif roll < 0.72 then
            -- soot: a soft dark fleck that breaks up the ash without adding hue
            love.graphics.setColor(P.alpha(R.ash[1], 0.13 * sc * shade))
            love.graphics.ellipse("fill", lx, ly, 2 + rng:next() * 7, 1.4 + rng:next() * 4, 8)
          elseif roll < 0.94 then
            -- pale grit catching the light on the raised lips of the crazing
            love.graphics.setColor(P.alpha(R.ash[3], 0.20 * sc * shade))
            love.graphics.circle("fill", lx, ly, 0.8 + rng:next() * 1.9, 5)
          else
            -- the only violet allowed at mark scale: a rare live spore bead
            love.graphics.setColor(P.alpha(R.blight[3], 0.30 * sc * shade))
            love.graphics.circle("fill", lx, ly, 0.9 + rng:next() * 1.4, 5)
          end
        end
      end
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setLineWidth(1)
end

------------------------------------------------------------------------ healing
--- Reclaim a scarred patch: lightens the baked ground back toward meadow and
--- lifts the fertility/biome fields. `amount` 0..1 of full reclamation.
function Terrain:healAt(x, y, radius, amount)
  if not self.baked then return end
  amount = amount or 0.35
  local R = P.ramp
  local cell, gw = self.cell, self.gw
  local touched = false

  -- fields
  local g0x = max(0, floor((x - radius) / cell))
  local g1x = min(gw - 1, ceil((x + radius) / cell))
  local g0y = max(0, floor((y - radius) / cell))
  local g1y = min(self.gh - 1, ceil((y + radius) / cell))
  for gy = g0y, g1y do
    for gx = g0x, g1x do
      local i = gy * gw + gx + 1
      local d = U.dist(gx * cell, gy * cell, x, y)
      if d < radius and self.scar[i] > 0 then
        local k = (1 - d / radius) * amount
        local nh = min(1, self.heal[i] + k)
        if nh > self.heal[i] then
          self.heal[i] = nh
          self.fert[i] = U.saturate(self.fert[i] + k * 0.55)
          touched = true
          if self.heal[i] > 0.55 and self.biome[i] == B_SCAR then
            self.biome[i] = B_MEADOW
          end
        end
      end
    end
  end
  if not touched then return end

  -- baked canvases
  local rng = U.rng(floor(x * 13 + y * 7))
  local prevB, prevA = love.graphics.getBlendMode()
  love.graphics.setBlendMode("alpha")
  for _, tile in ipairs(self.tiles) do
    if x + radius > tile.x and x - radius < tile.x + tile.w
       and y + radius > tile.y and y - radius < tile.y + tile.h then
      love.graphics.setCanvas(tile.canvas)
      local lx, ly = x - tile.x, y - tile.y
      -- soft green wash, brightest at the centre
      local steps = 9
      for k = steps, 1, -1 do
        local f = k / steps
        local a = amount * 0.16 * (1 - f) ^ 1.3
        love.graphics.setColor(P.alpha(P.shade(R.grass, 1.6 + (1 - f) * 1.4), a))
        love.graphics.circle("fill", lx, ly, radius * f, 28)
      end
      -- new growth marks
      local nMarks = floor(radius * radius * 0.010 * amount)
      for _ = 1, nMarks do
        local a, dd = rng:angle(), sqrt(rng:next()) * radius
        local px, py = lx + cos(a) * dd, ly + sin(a) * dd
        local wx, wy = px + tile.x, py + tile.y
        if self:isLand(wx, wy) then
          local hgt = 4 + rng:next() * 7
          tuft(px, py, hgt, (rng:next() - 0.5) * 4, 1.0,
               P.shade(R.grass, 1.2 + rng:next() * 0.6, 0.8),
               P.shade(R.grass, 2.8 + rng:next(), 0.85))
        end
      end
      love.graphics.setCanvas()
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode(prevB, prevA)
end

--------------------------------------------------------------------------- draw
function Terrain:update(dt) self.time = self.time + dt end

--- Ground. Call with the camera transform already applied.
function Terrain:draw(camera)
  if not self.tiles then return end
  local vx, vy, vw, vh = 0, 0, self.w, self.h
  if camera then vx, vy, vw, vh = camera:viewRect(48) end
  local prevB, prevA = love.graphics.getBlendMode()
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.setColor(1, 1, 1, 1)
  local drawn = 0
  for k = 1, #self.tiles do
    local t = self.tiles[k]
    if t.x < vx + vw and t.x + t.w > vx and t.y < vy + vh and t.y + t.h > vy then
      love.graphics.draw(t.canvas, t.x, t.y)
      drawn = drawn + 1
    end
  end
  self.tilesDrawn = drawn
  love.graphics.setBlendMode(prevB, prevA)
end

--- Shore foam that laps onto the sand. Above the ground, below the entities.
function Terrain:drawOverlay(camera)
  if not self.shoreCanvas then return end
  local vx, vy, vw, vh = 0, 0, self.w, self.h
  if camera then vx, vy, vw, vh = camera:viewRect(24) end
  local prevB, prevA = love.graphics.getBlendMode()
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.setShader(self._foamSh)
  put(self._foamSh, "uView", { vx, vy, vw, vh })
  put(self._foamSh, "uTime", self.time)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(self._white, vx, vy, 0, vw, vh)
  love.graphics.setShader()
  love.graphics.setBlendMode(prevB, prevA)
end

Terrain.BIOMES = BIOME
Terrain.TILE_W, Terrain.TILE_H = TILE_W, TILE_H
Terrain.SD_MAX = SD_MAX
Terrain.noise = N

return Terrain
