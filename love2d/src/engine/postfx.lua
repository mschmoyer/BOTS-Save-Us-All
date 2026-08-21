-- The post-processing chain.
--
--   scene -> bright pass (soft knee)
--         -> downsample 1/2 and 1/4
--         -> two-pass separable gaussian at each level
--         -> upsample + combine          (wide, cinematic bloom, not a halo)
--         -> grade (exposure, gain toward the time-of-day tint, filmic
--                   tonemap, lift into the shadows, contrast, saturation)
--         -> FXAA-lite                   (optional)
--         -> shockwave distortion -> chromatic aberration -> vignette -> grain
--         -> screen
--
-- Every stage is independently toggleable through `Post.settings`, and
-- `Post.settings.scale` renders the whole chain at a fraction of the window
-- resolution for weak devices.
--
-- All GLSL here is WebGL1 / GLSL ES 1.0 safe: constant loop bounds, no
-- textureLod/textureGrad, no switch, mod() instead of %, and uniform arrays are
-- only ever indexed by a loop counter.
local U = require("src.core.util")
local P = require("src.engine.palette")

local Post = {}

------------------------------------------------------------------- settings
Post.settings = {
  bloom    = true,
  ca       = true,
  grain    = true,
  vignette = true,
  distort  = true,
  fxaa     = false,
  scale    = 1,      -- 0.5 renders the whole chain at half resolution
}

Post.tuning = {
  threshold   = 0.80,   -- bright-pass knee centre
  knee        = 0.22,
  brightGain  = 1.0,
  bloomAmount = 0.55,   -- multiplied by the day/night bloom response
  wide        = 0.60,   -- how much of the 1/4 level survives into the mix
  caAmount    = 0.0022,
  vigStrength = 0.52,
  vigSoft     = 0.28,
  grainAmount = 0.024,
  shockPx     = 16,     -- peak displacement of a shockwave ring, in pixels
  shockThick  = 34,
  tintAmount  = 0.34,
  tonemap     = 0.9,
}

Post.stats = { passes = 0, ms = 0 }

------------------------------------------------------------------ grade state
local gTint = { 1, 1, 1 }
local gLift = { 0, 0, 0 }
local gExposure, gContrast, gSaturation = 1, 1, 1
local gBloom = 1

--------------------------------------------------------------------- canvases
local scene, grade, aa
local half1, half2, quarter1, quarter2
local W, H, SW, SH = 0, 0, 0, 0
local prevCanvas
local fmt = "rgba8"

------------------------------------------------------------------ shockwaves
local SHOCKS = 4
local shock = {}          -- live state
local shockSend = {}      -- persistent vec4 tables handed to the shader
for i = 1, SHOCKS do
  shock[i] = { x = 0, y = 0, r0 = 0, r1 = 0, t = 0, life = 0, strength = 0 }
  shockSend[i] = { 0, 0, 0, 0 }
end

--------------------------------------------------------------------- scratch
local sendDir = { 0, 0 }
local sendSize = { 0, 0 }
local sendTexel = { 0, 0 }

--------------------------------------------------------------------- shaders
local S = {}

local SRC_BRIGHT = [[
extern float threshold;
extern float knee;
extern float gain;
vec4 effect(vec4 vc, Image tex, vec2 tc, vec2 sc) {
  vec3 c = Texel(tex, tc).rgb;
  float br = max(c.r, max(c.g, c.b));
  // quadratic soft knee: nothing pops on as it crosses the threshold
  float soft = clamp(br - threshold + knee, 0.0, 2.0 * knee);
  soft = soft * soft / (4.0 * knee + 0.0001);
  float w = max(soft, br - threshold) / max(br, 0.0001);
  return vec4(c * w * gain, 1.0);
}
]]

-- 5 linearly-sampled taps == a 9-tap gaussian, at half the bandwidth.
local SRC_BLUR = [[
extern vec2 dir;
vec4 effect(vec4 vc, Image tex, vec2 tc, vec2 sc) {
  vec3 c  = Texel(tex, tc).rgb * 0.2270270270;
  c += Texel(tex, tc + dir * 1.3846153846).rgb * 0.3162162162;
  c += Texel(tex, tc - dir * 1.3846153846).rgb * 0.3162162162;
  c += Texel(tex, tc + dir * 3.2307692308).rgb * 0.0702702703;
  c += Texel(tex, tc - dir * 3.2307692308).rgb * 0.0702702703;
  return vec4(c, 1.0);
}
]]

local SRC_GRADE = [[
extern Image bloomTex;
extern float bloomAmount;
extern vec3  tint;
extern vec3  lift;
extern float exposure;
extern float contrast;
extern float saturation;
extern float tintAmount;
extern float tonemapAmount;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

vec3 aces(vec3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

vec4 effect(vec4 vc, Image tex, vec2 tc, vec2 sc) {
  vec3 c = Texel(tex, tc).rgb;
  c += Texel(bloomTex, tc).rgb * bloomAmount;

  c *= exposure;

  // gain toward the time-of-day tint, normalised so the tint shifts hue
  // rather than dimming the frame
  float tl = max(dot(tint, LUMA), 0.001);
  c *= mix(vec3(1.0), tint / tl, tintAmount);

  c = mix(c, aces(c), tonemapAmount);

  // lift: the sky's colour bleeds into the shadows, strongest where it is dark
  c += lift * (1.0 - c);

  c = (c - 0.5) * contrast + 0.5;

  float l = dot(c, LUMA);
  c = mix(vec3(l), c, saturation);

  return vec4(max(c, 0.0), 1.0);
}
]]

local SRC_SCREEN = [[
extern vec2  texSize;
extern vec4  shock[4];      // x, y (px), radius (px), strength
extern float shockThick;
extern float shockPx;
extern float caAmount;
extern float vigStrength;
extern float vigSoft;
extern float grainAmount;
extern float time;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 effect(vec4 vc, Image tex, vec2 tc, vec2 sc) {
  vec2 px = tc * texSize;
  vec2 uv = tc;
  float ring = 0.0;

  // ---- shockwave distortion (constant loop bound, uniform array read by the
  //      loop counter only: both WebGL1-legal)
  for (int i = 0; i < 4; i++) {
    vec4 s = shock[i];
    if (s.w > 0.0) {
      vec2 d = px - s.xy;
      float dist = max(length(d), 0.0001);
      float band = 1.0 - clamp(abs(dist - s.z) / shockThick, 0.0, 1.0);
      band = band * band;
      ring += band * s.w;
      uv += (d / dist) * (band * s.w * shockPx) / texSize;
    }
  }

  // ---- chromatic aberration, scaling with distance from centre
  vec2 off = uv - 0.5;
  float amt = caAmount * dot(off, off) * 4.0 + ring * 0.0035;
  vec3 c;
  c.r = Texel(tex, uv + off * amt).r;
  c.g = Texel(tex, uv).g;
  c.b = Texel(tex, uv - off * amt).b;

  // the ring itself gets a little heat so a pulse reads even on a bright frame
  c += ring * 0.06;

  // ---- vignette
  float d2 = length(off) * 1.42;
  c *= 1.0 - vigStrength * smoothstep(vigSoft, 1.05, d2);

  // ---- film grain: animated, weighted into the shadows where film shows it
  float n = hash(px + vec2(time * 71.3, time * 53.7));
  float n2 = hash(px.yx * 1.31 + vec2(time * 37.1, time * 91.7));
  float l = dot(c, LUMA);
  c += (n + n2 - 1.0) * grainAmount * (0.35 + 0.65 * (1.0 - l));

  return vec4(max(c, 0.0), 1.0);
}
]]

local SRC_FXAA = [[
extern vec2 texel;
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
vec4 effect(vec4 vc, Image tex, vec2 tc, vec2 sc) {
  vec3 c  = Texel(tex, tc).rgb;
  vec3 nw = Texel(tex, tc + vec2(-texel.x, -texel.y)).rgb;
  vec3 ne = Texel(tex, tc + vec2( texel.x, -texel.y)).rgb;
  vec3 sw = Texel(tex, tc + vec2(-texel.x,  texel.y)).rgb;
  vec3 se = Texel(tex, tc + vec2( texel.x,  texel.y)).rgb;
  float lc = dot(c, LUMA);
  float a = dot(nw, LUMA), b = dot(ne, LUMA), d = dot(sw, LUMA), e = dot(se, LUMA);
  float lo = min(lc, min(min(a, b), min(d, e)));
  float hi = max(lc, max(max(a, b), max(d, e)));
  float edge = smoothstep(0.05, 0.22, hi - lo);
  vec3 avg = (nw + ne + sw + se) * 0.25;
  return vec4(mix(c, mix(c, avg, 0.6), edge), 1.0);
}
]]

----------------------------------------------------------------------- helpers
local function snd(sh, name, a, b, c, d)
  if sh:hasUniform(name) then sh:send(name, a, b, c, d) end
end

local function newCanvas(w, h)
  local c = love.graphics.newCanvas(math.max(1, math.floor(w)),
                                    math.max(1, math.floor(h)), { format = fmt })
  c:setFilter("linear", "linear")
  c:setWrap("clamp", "clamp")
  return c
end

local function releaseAll()
  local all = { scene, grade, aa, half1, half2, quarter1, quarter2 }
  for i = 1, #all do if all[i] then all[i]:release() end end
  scene, grade, aa, half1, half2, quarter1, quarter2 = nil, nil, nil, nil, nil, nil, nil
end

local function allocate(w, h)
  W, H = math.max(1, math.floor(w)), math.max(1, math.floor(h))
  local s = U.clamp(Post.settings.scale or 1, 0.25, 1)
  SW, SH = math.max(1, math.floor(W * s)), math.max(1, math.floor(H * s))
  releaseAll()
  scene    = newCanvas(SW, SH)
  grade    = newCanvas(SW, SH)
  aa       = newCanvas(SW, SH)
  half1    = newCanvas(SW / 2, SH / 2)
  half2    = newCanvas(SW / 2, SH / 2)
  quarter1 = newCanvas(SW / 4, SH / 4)
  quarter2 = newCanvas(SW / 4, SH / 4)
end

--------------------------------------------------------------------- lifecycle
function Post.init(w, h)
  w = w or love.graphics.getWidth()
  h = h or love.graphics.getHeight()
  local fmts = love.graphics.getCanvasFormats()
  fmt = (fmts and fmts.rgba16f) and "rgba16f" or "rgba8"
  Post.hdr = (fmt == "rgba16f")
  if not S.bright then
    S.bright = love.graphics.newShader(SRC_BRIGHT)
    S.blur   = love.graphics.newShader(SRC_BLUR)
    S.grade  = love.graphics.newShader(SRC_GRADE)
    S.screen = love.graphics.newShader(SRC_SCREEN)
    S.fxaa   = love.graphics.newShader(SRC_FXAA)
  end
  allocate(w, h)
  gTint[1], gTint[2], gTint[3] = 1, 1, 1
  return Post
end

function Post.resize(w, h) allocate(w, h) end

--- Re-allocate after changing `Post.settings.scale`.
function Post.setScale(s)
  Post.settings.scale = U.clamp(s or 1, 0.25, 1)
  if W > 0 then allocate(W, H) end
end

function Post.dimensions() return SW, SH end

------------------------------------------------------------------------ grade
--- tint/lift are palette colours; exposure/contrast/saturation are scalars.
function Post.setGrade(tint, exposure, contrast, saturation, lift)
  if tint then gTint[1], gTint[2], gTint[3] = tint[1], tint[2], tint[3] end
  if lift then gLift[1], gLift[2], gLift[3] = lift[1], lift[2], lift[3] end
  gExposure   = exposure or 1
  gContrast   = contrast or 1
  gSaturation = saturation or 1
end

function Post.setBloom(amount) gBloom = amount or 1 end

------------------------------------------------------------------- shockwaves
--- A screen-space distortion ring. `x, y` are **screen** pixels.
function Post.addShockwave(x, y, radius, strength, life)
  local slot, best = 1, -1
  for i = 1, SHOCKS do
    local s = shock[i]
    if s.life <= 0 then slot = i break end
    local age = s.t / math.max(s.life, 0.0001)
    if age > best then best, slot = age, i end
  end
  local s = shock[slot]
  s.x, s.y = x, y
  s.r0, s.r1 = (radius or 200) * 0.06, radius or 200
  s.t, s.life = 0, life or 0.5
  s.strength = strength or 1
end

function Post.clearShockwaves()
  for i = 1, SHOCKS do shock[i].life = 0 end
end

function Post.update(dt)
  for i = 1, SHOCKS do
    local s = shock[i]
    if s.life > 0 then
      s.t = s.t + dt
      if s.t >= s.life then s.life = 0 end
    end
  end
end

--------------------------------------------------------------------- the scene
--- Bind the scene target. Everything the world draws goes here.
function Post.beginScene(r, g, b)
  if not scene then Post.init() end
  prevCanvas = love.graphics.getCanvas()
  love.graphics.setCanvas(scene)
  local c = P.black
  love.graphics.clear(r or c[1], g or c[2], b or c[3], 1)
end

function Post.endScene()
  love.graphics.setCanvas(prevCanvas)
  prevCanvas = nil
end

function Post.getSceneCanvas() return scene end

------------------------------------------------------------------- the chain
local function blur(src, dst, pass, spread)
  local sw, sh = src:getDimensions()
  love.graphics.setCanvas(dst)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setShader(S.blur)
  if pass == "h" then
    sendDir[1], sendDir[2] = spread / sw, 0
  else
    sendDir[1], sendDir[2] = 0, spread / sh
  end
  S.blur:send("dir", sendDir)
  love.graphics.draw(src, 0, 0, 0, dst:getWidth() / sw, dst:getHeight() / sh)
  Post.stats.passes = Post.stats.passes + 1
end

--- Run the chain and draw the result to whatever is currently bound (normally
--- the screen). Safe to call with a nil `opts`.
function Post.render(opts)
  if not scene then return end
  local g = love.graphics
  local set = Post.settings
  local T = Post.tuning
  local t0 = love.timer and love.timer.getTime() or 0
  Post.stats.passes = 0

  local pbm, pam = g.getBlendMode()
  local pr, pg, pb, pa = g.getColor()
  local target = g.getCanvas()

  local doBloom   = set.bloom   and (opts == nil or opts.bloom   ~= false)
  local doCA      = set.ca      and (opts == nil or opts.ca      ~= false)
  local doGrain   = set.grain   and (opts == nil or opts.grain   ~= false)
  local doVig     = set.vignette and (opts == nil or opts.vignette ~= false)
  local doDistort = set.distort and (opts == nil or opts.distort ~= false)
  local doFxaa    = set.fxaa    and (opts == nil or opts.fxaa    ~= false)

  g.push()
  g.origin()
  g.setBlendMode("alpha", "premultiplied")
  g.setColor(1, 1, 1, 1)

  ------------------------------------------------------------------ bloom
  if doBloom then
    -- bright pass, straight into the 1/2 buffer
    g.setCanvas(half1)
    g.clear(0, 0, 0, 1)
    g.setShader(S.bright)
    snd(S.bright, "threshold", T.threshold)
    snd(S.bright, "knee", math.max(T.knee, 0.001))
    snd(S.bright, "gain", T.brightGain)
    g.draw(scene, 0, 0, 0, 0.5, 0.5)
    Post.stats.passes = Post.stats.passes + 1

    -- 1/2 level: H then V
    blur(half1, half2, "h", 1.0)
    blur(half2, half1, "v", 1.0)

    -- 1/4 level: downsample, then two full H/V iterations for a wide tail
    blur(half1, quarter1, "h", 1.0)
    blur(quarter1, quarter2, "v", 1.0)
    blur(quarter2, quarter1, "h", 1.6)
    blur(quarter1, quarter2, "v", 1.6)

    -- combine: the wide level is added back on top of the tight one
    g.setCanvas(half1)
    g.setShader()
    g.setBlendMode("add", "premultiplied")
    g.setColor(T.wide, T.wide, T.wide, 1)
    g.draw(quarter2, 0, 0, 0, half1:getWidth() / quarter2:getWidth(),
                              half1:getHeight() / quarter2:getHeight())
    g.setBlendMode("alpha", "premultiplied")
    g.setColor(1, 1, 1, 1)
    Post.stats.passes = Post.stats.passes + 1
  else
    g.setCanvas(half1)
    g.clear(0, 0, 0, 1)
  end

  ------------------------------------------------------------------ grade
  g.setCanvas(grade)
  g.clear(0, 0, 0, 1)
  g.setShader(S.grade)
  snd(S.grade, "bloomTex", half1)
  snd(S.grade, "bloomAmount", doBloom and (T.bloomAmount * gBloom) or 0)
  snd(S.grade, "tint", gTint)
  snd(S.grade, "lift", gLift)
  snd(S.grade, "exposure", gExposure)
  snd(S.grade, "contrast", gContrast)
  snd(S.grade, "saturation", gSaturation)
  snd(S.grade, "tintAmount", T.tintAmount)
  snd(S.grade, "tonemapAmount", T.tonemap)
  g.draw(scene, 0, 0)
  Post.stats.passes = Post.stats.passes + 1

  local src = grade

  ------------------------------------------------------------------ fxaa
  if doFxaa then
    g.setCanvas(aa)
    g.clear(0, 0, 0, 1)
    g.setShader(S.fxaa)
    sendTexel[1], sendTexel[2] = 1 / SW, 1 / SH
    snd(S.fxaa, "texel", sendTexel)
    g.draw(src, 0, 0)
    src = aa
    Post.stats.passes = Post.stats.passes + 1
  end

  --------------------------------------------- distort -> ca -> vignette -> grain
  for i = 1, SHOCKS do
    local s = shock[i]
    local o = shockSend[i]
    if s.life > 0 and doDistort then
      local k = U.saturate(s.t / s.life)
      o[1], o[2] = s.x * (SW / W), s.y * (SH / H)
      o[3] = U.lerp(s.r0, s.r1, U.ease.outCubic(k)) * (SW / W)
      o[4] = s.strength * (1 - k) * (1 - k)
    else
      o[1], o[2], o[3], o[4] = 0, 0, 0, 0
    end
  end

  g.setCanvas(target)
  g.setShader(S.screen)
  sendSize[1], sendSize[2] = SW, SH
  snd(S.screen, "texSize", sendSize)
  S.screen:send("shock", shockSend[1], shockSend[2], shockSend[3], shockSend[4])
  snd(S.screen, "shockThick", T.shockThick * (SW / W))
  snd(S.screen, "shockPx", T.shockPx * (SW / W))
  snd(S.screen, "caAmount", doCA and T.caAmount or 0)
  snd(S.screen, "vigStrength", doVig and T.vigStrength or 0)
  snd(S.screen, "vigSoft", T.vigSoft)
  snd(S.screen, "grainAmount", doGrain and T.grainAmount or 0)
  snd(S.screen, "time", (love.timer and love.timer.getTime() or 0) % 128)
  g.draw(src, 0, 0, 0, W / SW, H / SH)
  Post.stats.passes = Post.stats.passes + 1

  ------------------------------------------------------------------ restore
  g.setShader()
  g.pop()
  g.setBlendMode(pbm, pam)
  g.setColor(pr, pg, pb, pa)
  Post.stats.ms = ((love.timer and love.timer.getTime() or 0) - t0) * 1000
end

return Post
