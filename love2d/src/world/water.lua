-- The sea. One shader-quad covering the view, sampling the signed shore-distance
-- field that terrain.lua bakes, so every wave knows how far it is from land.
--
--   Water.draw(camera, time, terrain.shoreCanvas)   -- camera transform applied
--   Water.setTint(colour, strength)                 -- day/night grade hook
--
-- The shader is deliberately WebGL1 / GLSL-ES-1.0 safe: constant loop bounds, no
-- derivatives, no textureLod, mod() instead of %, every literal a float.

local U = require("src.core.util")
local P = require("src.engine.palette")
local TW = require("src.game.tuning").world

local Water = {
  tint = { P.white[1], P.white[2], P.white[3] },
  tintK = 0,
  quality = 1,
}

local SHADER = [==[
extern Image shore;       // r: encoded signed shore distance  g: land mask  b: elevation
extern vec4  uView;       // world rect being drawn
extern vec2  uWorld;      // world size the shore field covers
extern float uTime;
extern float uSdMax;
extern vec3  uTint;
extern float uTintK;
extern vec3  cDeep;
extern vec3  cMid;
extern vec3  cShallow;
extern vec3  cFoam;
extern vec3  cSky;

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

// Byte-identical to crinkle() in terrain.lua's ground shader: the sea, the foam
// and the sand must all agree on where the shoreline is.
float crinkle(vec2 w) {
  return (fbm4(w * 0.0125 + 5.0) - 0.5) * 24.0
       + (fbm3(w * 0.0480 + 17.3) - 0.5) * 17.0
       + (vn(w * 0.1400 + 91.0) - 0.5) * 9.0;
}

// x: signed distance to the shoreline, positive on land.
// y: how hard the sea works this stretch of coast, 0..1, baked into the alpha
//    of the shore field by terrain.lua's SHORE_GLSL out of the coast's own
//    facing against the prevailing swell and how much open water lies off it.
//    It rides in a channel of a texel this function was fetching anyway, so
//    everything the surf does with it is free.
vec2 shoreInfo(vec2 w) {
  vec2 uv = clamp(w / uWorld, vec2(0.0), vec2(1.0));
  vec4 S = Texel(shore, uv);
  float se = S.r * 2.0 - 1.0;
  float d = se * abs(se) * uSdMax;
  // outside the map there is only open ocean. Without this the clamped edge
  // texel smears its value along the whole row.
  vec2 od = max(vec2(0.0) - w, w - uWorld);
  d = d - length(max(od, vec2(0.0))) * 1.6;
  d = d + crinkle(w) * (1.0 - smoothstep(80.0, 260.0, abs(d)));
  return vec2(max(d, -uSdMax), S.a);
}

vec4 effect(vec4 vcol, Image tx, vec2 tc, vec2 sc) {
  vec2 w = uView.xy + tc * uView.zw;

  // two scrolling swell layers, different scale and drift direction
  float n1 = fbm4(w * 0.0082 + vec2(uTime * 0.052, uTime * 0.030));
  float n2 = fbm3(w * 0.0231 - vec2(uTime * 0.088, -uTime * 0.041));
  float n3 = fbm3(w * 0.00105 + 13.0);     // ocean-scale colour variation

  vec2 si = shoreInfo(w);
  float sd = si.x;

  // refraction wobble: strongest in the shallows where you can see the bottom
  float shoreMask = smoothstep(-300.0, 0.0, sd);
  float wob = (n1 - 0.5) * 26.0 + (n2 - 0.5) * 12.0;
  float sdw = sd + wob * (0.30 + 1.05 * shoreMask);

  float dep = clamp(-sdw / 330.0, 0.0, 1.0);

  // deep -> shallow ramp
  vec3 col = mix(cShallow, cMid, smoothstep(0.02, 0.42, dep));
  col = mix(col, cDeep, smoothstep(0.38, 1.0, dep));
  col *= 0.94 + 0.12 * n3;
  // sandy bottom showing through the last few metres: warms and lifts the very
  // shallowest water so the ring is a gradient into the beach, not a flat stripe
  float bottom = 1.0 - smoothstep(0.0, 0.16, dep);
  col = mix(col, mix(col, cFoam, 0.34) * 1.06, bottom * 0.55);

  // swell shading: gentle, and it fades out in the deep so the open sea reads
  // as one calm mass instead of camouflage. Isotropic fbm alone gives blotches;
  // a long directional swell riding on top is what makes it read as water.
  float calm = 1.0 - smoothstep(0.30, 0.82, dep);
  float roll = sin(dot(w, vec2(0.0068, 0.0031)) + uTime * 0.30 + n1 * 3.4);
  float swell = ((n1 - 0.5) + (n2 - 0.5) * 0.45) * 0.62 + roll * 0.16;
  // multiplicative, so the near-black deep does not turn into camouflage
  col *= 1.0 + swell * 0.26 * (0.18 + 0.82 * calm);
  float crest = smoothstep(0.56, 0.94, n1 + (n2 - 0.5) * 0.35);
  col = mix(col, cSky, crest * 0.05 * calm);

  // How hard the sea works this stretch of coast. Narrowing the lip was never
  // going to fix it: a strong even line and a thin even line are the same
  // drawing. `expo` comes off the baked shore field -- the coast's facing
  // against the swell, and how much open water lies off it -- and a slow field
  // running along the shore breaks it further, so the surf arrives in lengths
  // with gaps between them and is allowed to stop entirely in a lee.
  float ex = clamp(si.y * (0.55 + 0.90 * n3) + (n1 - 0.5) * 0.55, 0.0, 1.0);

  // foam bands parallel to the coast, riding on the swell
  float nearShore = 1.0 - smoothstep(0.0, 190.0, -sdw);
  float band = sin(sdw * 0.072 + uTime * 1.25 + n2 * 5.0 + n1 * 2.2);
  float bands = smoothstep(0.34, 0.94, band) * nearShore * nearShore;

  // The breaking lip. Width, brightness and existence are all `ex`: on a
  // headland it is wide and violent, in the lee of one it is not there.
  float lipW = 4.0 + 12.0 * ex;
  float edge = 1.0 - smoothstep(0.0, lipW, -sdw);
  float surge = 0.55 + 0.45 * sin(uTime * 1.05 + n1 * 6.2 + n3 * 4.4);
  float lip = edge * edge * surge * smoothstep(0.08, 0.44, ex);

  // ...and what a bay gets instead of a wave: old foam that has drifted in and
  // is lying on the water in patches, with no edge to it at all.
  float pool = smoothstep(0.42, 0.78, n2 * 0.70 + n1 * 0.52)
             * nearShore * (1.0 - ex) * (1.0 - smoothstep(0.0, 34.0, -sdw) * 0.45);

  float foam = clamp(bands * (0.16 + 0.34 * ex) + lip * 0.86 + pool * 0.42, 0.0, 1.0);
  foam *= step(0.0, -sdw + 2.0);
  // the foam is bright but it is still water: hold it under the clipping point
  // so the whole shore band does not fuse into one blown-out white halo, and
  // hold the quiet water further under it still
  col = mix(col, cFoam * 0.90, foam * (0.40 + 0.36 * ex));

  // sparkle: two slowly drifting noise fields multiplied and hard-thresholded,
  // so only a scattering of crests catches the sun
  vec2 sp = w * 0.075;
  float s1 = vn(sp + vec2(uTime * 0.09, -uTime * 0.05));
  float s2 = vn(sp * 1.73 - vec2(uTime * 0.07, uTime * 0.11));
  float spark = smoothstep(0.92, 1.0, s1 * s2 * 2.30);
  spark *= smoothstep(0.55, 0.86, n1) * (1.0 - foam * 0.85) * calm;
  col += cFoam * spark * 0.22;

  // hide the land under a fully transparent-to-the-ground colour: the terrain
  // canvases are drawn on top, this only shows through their antialiased edge
  col = mix(col, cShallow * 0.85, smoothstep(-4.0, 6.0, sdw) * 0.6);

  // The tint is a straight multiply, so a dark night sky used to take the whole
  // sea to black and the island lost its silhouette. Keep a floor under it, and
  // hand the darkness back some moon glitter so night water is still water.
  float tintL = dot(uTint, vec3(0.2126, 0.7152, 0.0722));
  col = mix(col, col * (uTint * 1.12 + 0.13), uTintK);
  float dark = 1.0 - smoothstep(0.12, 0.46, tintL);
  float glint = smoothstep(0.86, 1.0, s1 * s2 * 2.30) * smoothstep(0.48, 0.90, n1);
  col += cFoam * glint * dark * uTintK * 0.55 * calm;
  col = clamp(col, 0.0, 1.0);
  return vec4(col, 1.0) * vcol;
}
]==]

local function put(sh, name, ...)
  if sh:hasUniform(name) then sh:send(name, ...) end
end

function Water.load()
  if Water.shader then return Water.shader end
  Water.shader = love.graphics.newShader(SHADER)
  local white = love.image.newImageData(1, 1, "rgba8", string.char(255, 255, 255, 255))
  Water.white = love.graphics.newImage(white)
  local R = P.ramp.water
  local s = Water.shader
  put(s, "uWorld", { TW.w, TW.h })
  put(s, "uSdMax", 420)
  put(s, "cDeep", { R[1][1], R[1][2], R[1][3] })
  put(s, "cMid", { R[2][1], R[2][2], R[2][3] })
  put(s, "cShallow", { R[3][1], R[3][2], R[3][3] })
  put(s, "cFoam", { R[4][1], R[4][2], R[4][3] })
  put(s, "cSky", { P.tod.day.fog[1], P.tod.day.fog[2], P.tod.day.fog[3] })
  put(s, "uTint", Water.tint)
  put(s, "uTintK", Water.tintK)
  return s
end

--- Grade the sea. `colour` is a palette entry, `strength` 0..1.
function Water.setTint(colour, strength)
  Water.tint[1] = colour[1]
  Water.tint[2] = colour[2]
  Water.tint[3] = colour[3]
  Water.tintK = U.saturate(strength or 0)
  if Water.shader then
    put(Water.shader, "uTint", Water.tint)
    put(Water.shader, "uTintK", Water.tintK)
  end
end

--- Change the horizon/crest reflection colour (the sky the sea is reflecting).
function Water.setSky(colour)
  put(Water.load(), "cSky", { colour[1], colour[2], colour[3] })
end

--- Draw the sea over the visible world rect. Call with the camera transform
--- applied, before the terrain. `field` is `terrain.shoreCanvas`.
function Water.draw(camera, time, field)
  if not field then return end
  local s = Water.load()
  local vx, vy, vw, vh
  if camera then
    vx, vy, vw, vh = camera:viewRect(64)
  else
    vx, vy, vw, vh = -400, -400, TW.w + 800, TW.h + 800
  end
  put(s, "shore", field)
  put(s, "uView", { vx, vy, vw, vh })
  put(s, "uTime", time or 0)

  local prevB, prevA = love.graphics.getBlendMode()
  love.graphics.setBlendMode("alpha")
  love.graphics.setShader(s)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(Water.white, vx, vy, 0, vw, vh)
  love.graphics.setShader()
  love.graphics.setBlendMode(prevB, prevA)
end

return Water
