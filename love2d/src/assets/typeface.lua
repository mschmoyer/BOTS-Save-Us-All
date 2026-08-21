-- ROOTSTOCK -- the display typeface for BOTS: Save Us All.
--
-- A hand-vectored, all-caps geometric display face. Every glyph is a set of
-- stroke polylines living in a normalised em box:
--
--     y = 0   cap line          x = 0   pen origin
--     y = 1   baseline          x grows to the right
--
-- Round shapes deliberately break those lines by `OV` (overshoot) so that O
-- and C read the same height as H and E. Nothing here knows about pixels: the
-- typography engine (engine/text.lua) scales, tessellates and caches.
--
-- DESIGN BRIEF -- "engineered but humane":
--   * geometric skeleton, single-storey, monolinear
--   * condensed: cap width ~0.60 of cap height
--   * flat, squared terminals (butt caps, cut on the normal of the stroke)
--   * generous counters -- the bowls of B P R are pushed wide and shallow
--   * ONE recurring detail: every acute vertex is CLIPPED FLAT, and every
--     corner where a diagonal meets a stem is CHAMFERED at 45 degrees.
--     It shows up on A K M N V W X Y Z and on 4 and 7, it stops the miter
--     joins from spiking, and it is the thing that makes the face look
--     machined rather than drawn.
--   * digits are tabular -- every one of them has the same advance.
local U = require("src.core.util")

local cos, sin, pi, abs, ceil, floor = math.cos, math.sin, math.pi, math.abs, math.ceil, math.floor
local TAU = U.TAU

local T = {}

T.name          = "ROOTSTOCK"
T.capHeight     = 1.0        -- glyph geometry is expressed in cap heights
T.xHeightRatio  = 0.72       -- nominal: used when mixing small caps
T.overshoot     = 0.02
T.weight        = 0.105      -- default stroke weight, in cap heights
T.spaceAdvance  = 0.36
T.descender     = 0.14       -- how far Q's tail and the comma drop below baseline

----------------------------------------------------------------- construction
local function d2r(d) return d * pi / 180 end

--- Flat point list along an elliptical arc.
local function arc(cx, cy, rx, ry, a0, a1, steps)
  steps = steps or math.max(4, ceil(abs(a1 - a0) / (pi / 16)))
  local out, n = {}, 0
  for i = 0, steps do
    local a = a0 + (a1 - a0) * i / steps
    n = n + 1; out[n] = cx + cos(a) * rx
    n = n + 1; out[n] = cy + sin(a) * ry
  end
  return out
end

--- Closed ellipse. One extra segment of overlap hides the butt-cap seam.
local function ring(cx, cy, rx, ry, steps, rot)
  steps = steps or 40
  local out, n = {}, 0
  for i = 0, steps + 1 do
    local a = (rot or 0) + i / steps * TAU
    n = n + 1; out[n] = cx + cos(a) * rx
    n = n + 1; out[n] = cy + sin(a) * ry
  end
  return out
end

--- Concatenate numbers and flat point lists into one polyline.
local function cat(...)
  local out, n = {}, 0
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "table" then
      for j = 1, #v do n = n + 1; out[n] = v[j] end
    else
      n = n + 1; out[n] = v
    end
  end
  return out
end

--- Catmull-Rom through the given points: used for S 2 3 5 6 9 ? & @, the
--- shapes a circular arc cannot describe without a kink.
local function spline(p, sub)
  sub = sub or 5
  local count = #p / 2
  local out, m = {}, 0
  local function at(i)
    if i < 1 then i = 1 elseif i > count then i = count end
    return p[i * 2 - 1], p[i * 2]
  end
  for i = 1, count - 1 do
    local x0, y0 = at(i - 1)
    local x1, y1 = at(i)
    local x2, y2 = at(i + 1)
    local x3, y3 = at(i + 2)
    local last = (i == count - 1) and sub or sub - 1
    for k = 0, last do
      local t = k / sub
      local t2 = t * t
      local t3 = t2 * t
      local a = -0.5 * t3 + t2 - 0.5 * t
      local b = 1.5 * t3 - 2.5 * t2 + 1
      local c = -1.5 * t3 + 2 * t2 + 0.5 * t
      local d = 0.5 * t3 - 0.5 * t2
      m = m + 1; out[m] = a * x0 + b * x1 + c * x2 + d * x3
      m = m + 1; out[m] = a * y0 + b * y1 + c * y2 + d * y3
    end
  end
  return out
end

--- Rotate a glyph's strokes 180 degrees about (cx, cy): 6 -> 9, ( -> ).
local function rot180(strokes, cx, cy)
  local out = {}
  for i = 1, #strokes do
    local s, t = strokes[i], {}
    for j = 1, #s, 2 do
      t[j]     = 2 * cx - s[j]
      t[j + 1] = 2 * cy - s[j + 1]
    end
    out[i] = t
  end
  return out
end

--- Mirror horizontally about x = cx: ( -> ), < -> >.
local function mirrorX(strokes, cx)
  local out = {}
  for i = 1, #strokes do
    local s, t = strokes[i], {}
    for j = 1, #s, 2 do
      t[j]     = 2 * cx - s[j]
      t[j + 1] = s[j + 1]
    end
    out[i] = t
  end
  return out
end

------------------------------------------------------------------- the design
-- Design frame. Glyphs are drawn between DL and DR and then shifted right by
-- SHIFT so that the left sidebearing equals half the default letter gap.
local DL, DR = 0.06, 0.56          -- left / right stroke-centre limits
local MX     = (DL + DR) * 0.5     -- 0.31, the optical centre
local SHIFT  = 0.045
local CB     = 0.475               -- crossbar height (above centre: optical)
local OV     = T.overshoot
local RX     = (DR - DL) * 0.5     -- 0.25, radius of the round caps
local RY     = 0.5 + OV

local glyphs = {}

--- Register a glyph. `adv` is in the *final* (post-shift) frame.
local function G(ch, adv, strokes, dots)
  glyphs[ch] = { adv = adv, s = strokes or {}, d = dots }
end

----------------------------------------------------------------------- A - Z

-- A: clipped apex. The flat top is the seed of the whole face's identity.
G("A", 0.70, {
  { 0.045, 1, 0.275, 0, 0.345, 0, 0.575, 1 },
  { 0.1186, 0.68, 0.5014, 0.68 },
})

-- B: two bowls, the lower one wider -- classic, and it stops B reading as 8.
G("B", 0.71, {
  { DL, 0, DL, 1 },
  cat(DL, 0, 0.28, 0, arc(0.28, 0.2375, 0.24, 0.2375, -pi / 2, pi / 2, 10), DL, CB),
  cat(arc(0.28, 0.7375, 0.28, 0.2625, -pi / 2, pi / 2, 11), DL, 1),
})

G("C", 0.67, { arc(MX, 0.5, RX, RY, d2r(58), d2r(302), 26) })

G("D", 0.71, {
  { DL, 0, DL, 1 },
  cat(DL, 0, 0.26, 0, arc(0.26, 0.5, 0.30, 0.5, -pi / 2, pi / 2, 14), DL, 1),
})

G("E", 0.70, {
  { DR, 0, DL, 0, DL, 1, DR, 1 },
  { DL, CB, 0.48, CB },
})

G("F", 0.68, {
  { DR, 0, DL, 0, DL, 1 },
  { DL, CB, 0.46, CB },
})

-- G: the bar enters at exactly half height, the arc closes on it at 90 degrees.
G("G", 0.71, cat({ cat(arc(MX, 0.5, RX, RY, d2r(58), d2r(360), 30), 0.33, 0.5) }))

G("H", 0.71, {
  { DL, 0, DL, 1 }, { DR, 0, DR, 1 }, { DL, CB, DR, CB },
})

G("I", 0.30, { { 0.105, 0, 0.105, 1 } })

G("J", 0.60, { cat(0.44, 0, 0.44, 0.72, arc(0.235, 0.72, 0.205, 0.30, 0, pi, 12)) })

-- K: the arm and the leg do not meet at a point -- a short vertical joins
-- them. Same "no sharp vertices" law as the clipped apex of A.
G("K", 0.71, {
  { DL, 0, DL, 1 },
  { DR, 0, 0.15, 0.435, 0.15, 0.565, 0.575, 1 },
})

G("L", 0.64, { { DL, 0, DL, 1, 0.54, 1 } })

-- M: chamfered shoulders, clipped vertex. Widest letter after W.
G("M", 0.83, {
  { 0.045, 1, 0.045, 0.085, 0.115, 0, 0.325, 0.60, 0.395, 0.60, 0.605, 0, 0.675, 0.085, 0.675, 1 },
})

-- N: chamfers top-left and bottom-right; the diagonal keeps full cap height.
G("N", 0.71, {
  { DL, 1, DL, 0.075, 0.135, 0, 0.485, 1, DR, 0.925, DR, 0 },
})

G("O", 0.69, { ring(MX, 0.5, RX, RY, 44) })

G("P", 0.68, {
  { DL, 0, DL, 1 },
  cat(DL, 0, 0.30, 0, arc(0.30, 0.28, 0.26, 0.28, -pi / 2, pi / 2, 11), DL, 0.56),
})

G("Q", 0.69, {
  ring(MX, 0.5, RX, RY, 44),
  { 0.365, 0.66, 0.60, 1.03 },
})

G("R", 0.71, {
  { DL, 0, DL, 1 },
  cat(DL, 0, 0.29, 0, arc(0.29, 0.26, 0.25, 0.26, -pi / 2, pi / 2, 11), DL, 0.52),
  { 0.265, 0.52, 0.575, 1 },
})

G("S", 0.68, { spline({
  0.525, 0.145,
  0.445, 0.015,
  0.275, -OV,
  0.125, 0.075,
  0.093, 0.235,
  0.185, 0.375,
  0.335, 0.465,
  0.470, 0.585,
  0.505, 0.755,
  0.435, 0.945,
  0.265, 1 + OV,
  0.100, 0.925,
  0.062, 0.815,
}, 4) })

G("T", 0.66, { { 0.03, 0, 0.59, 0 }, { MX, 0, MX, 1 } })

G("U", 0.70, {
  cat(DL, 0, DL, 0.70, arc(MX, 0.70, RX, 0.32, pi, 0, 16), DR, 0),
})

G("V", 0.69, { { 0.045, 0, 0.275, 0.99, 0.345, 0.99, 0.575, 0 } })

G("W", 0.93, {
  { 0.03, 0, 0.155, 0.99, 0.215, 0.99, 0.335, 0.245, 0.385, 0.245,
    0.505, 0.99, 0.565, 0.99, 0.69, 0 },
})

G("X", 0.70, { { 0.05, 0, 0.57, 1 }, { 0.57, 0, 0.05, 1 } })

G("Y", 0.68, {
  { 0.045, 0, 0.285, 0.50, 0.335, 0.50, 0.575, 0 },
  { 0.31, 0.50, 0.31, 1 },
})

-- Z: chamfered at both acute corners, full width top and bottom.
G("Z", 0.70, {
  { DL, 0, 0.485, 0, DR, 0.075, 0.135, 0.925, DL, 1, DR, 1 },
})

------------------------------------------------------------------ digits 0-9
-- Tabular: identical advance, so a HUD counter never shimmers.
local DIGIT = 0.71

-- 0 is narrower than O and that is how you tell them apart.
G("0", DIGIT, { ring(MX, 0.5, 0.215, RY, 40) })

G("1", DIGIT, {
  { 0.135, 0.205, 0.315, 0.02, 0.315, 1 },
  { 0.145, 1, 0.485, 1 },
})

G("2", DIGIT, { cat(spline({
  0.075, 0.245,
  0.115, 0.09,
  0.255, -OV,
  0.415, 0.045,
  0.505, 0.185,
  0.475, 0.355,
  0.335, 0.505,
}, 4), 0.075, 1, DR, 1) })

G("3", DIGIT, { spline({
  0.085, 0.155,
  0.185, 0.015,
  0.355, -OV,
  0.485, 0.10,
  0.465, 0.29,
  0.315, 0.435,
  0.455, 0.53,
  0.515, 0.70,
  0.465, 0.90,
  0.305, 1 + OV,
  0.125, 0.955,
  0.065, 0.855,
}, 4) })

-- 4: clipped apex, same flat as A.
G("4", DIGIT, {
  { 0.415, 0, 0.355, 0, 0.055, 0.715, 0.575, 0.715 },
  { 0.415, 0, 0.415, 1 },
})

G("5", DIGIT, { cat(0.52, 0, 0.10, 0, 0.093, 0.345, spline({
  0.093, 0.345,
  0.245, 0.315,
  0.405, 0.375,
  0.495, 0.525,
  0.485, 0.735,
  0.395, 0.925,
  0.235, 1 + OV,
  0.085, 0.935,
  0.055, 0.845,
}, 4)) })

local six = {
  ring(MX, 0.735, 0.235, 0.285, 32),
  spline({ 0.075, 0.775, 0.078, 0.505, 0.115, 0.245, 0.215, 0.065, 0.355, -OV, 0.495, 0.055 }, 5),
}
G("6", DIGIT, six)

G("7", DIGIT, {
  { DL, 0, 0.485, 0, DR, 0.075, 0.205, 1 },
})

G("8", DIGIT, {
  ring(MX, 0.24, 0.19, 0.26, 32),
  ring(MX, 0.76, 0.225, 0.26, 32),
})

G("9", DIGIT, rot180(six, MX, 0.5))

--------------------------------------------------------------- punctuation
G(".", 0.32, nil, { 0.115, 0.945 })
G(",", 0.32, { { 0.165, 0.90, 0.09, 1.115 } })
G(":", 0.32, nil, { 0.115, 0.30, 0.115, 0.945 })
G(";", 0.32, { { 0.165, 0.90, 0.09, 1.115 } }, { 0.115, 0.30 })
G("!", 0.32, { { 0.115, 0, 0.115, 0.665 } }, { 0.115, 0.945 })
G("?", 0.60, { spline({
  0.055, 0.215,
  0.115, 0.045,
  0.275, -OV,
  0.425, 0.075,
  0.455, 0.255,
  0.355, 0.395,
  0.265, 0.495,
  0.265, 0.665,
}, 4) }, { 0.265, 0.945 })
G("'", 0.28, { { 0.11, 0, 0.11, 0.245 } })
G('"', 0.44, { { 0.10, 0, 0.10, 0.245 }, { 0.245, 0, 0.245, 0.245 } })
G("-", 0.46, { { 0.075, 0.50, 0.325, 0.50 } })
G("\226\128\147", 0.62, { { 0.055, 0.50, 0.515, 0.50 } })   -- en dash
G("_", 0.71, { { 0.03, 1.10, 0.59, 1.10 } })
G("/", 0.56, { { 0.055, 1.06, 0.435, -0.06 } })
G("\\", 0.56, { { 0.055, -0.06, 0.435, 1.06 } })
G("%", 0.90, {
  ring(0.155, 0.195, 0.10, 0.175, 20),
  ring(0.545, 0.805, 0.10, 0.175, 20),
  { 0.045, 1.02, 0.655, -0.02 },
})
G("+", 0.71, { { 0.09, 0.50, 0.53, 0.50 }, { MX, 0.28, MX, 0.72 } })
G("=", 0.71, { { 0.09, 0.375, 0.53, 0.375 }, { 0.09, 0.625, 0.53, 0.625 } })
G("<", 0.62, { { 0.475, 0.155, 0.095, 0.50, 0.475, 0.845 } })
G(">", 0.62, mirrorX({ { 0.475, 0.155, 0.095, 0.50, 0.475, 0.845 } }, MX))
G("*", 0.58, {
  { MX, 0.055, MX, 0.365 },
  { MX - 0.134, 0.132, MX + 0.134, 0.288 },
  { MX - 0.134, 0.288, MX + 0.134, 0.132 },
})
G("#", 0.74, {
  { 0.235, 0.03, 0.155, 0.97 },
  { 0.455, 0.03, 0.375, 0.97 },
  { 0.065, 0.335, 0.545, 0.335 },
  { 0.045, 0.665, 0.525, 0.665 },
})
local paren = { arc(0.415, 0.5, 0.295, 0.63, d2r(139), d2r(221), 14) }
G("(", 0.42, paren)
G(")", 0.42, mirrorX(paren, 0.245))
G("[", 0.42, { { 0.325, -0.13, 0.115, -0.13, 0.115, 1.13, 0.325, 1.13 } })
G("]", 0.42, mirrorX({ { 0.325, -0.13, 0.115, -0.13, 0.115, 1.13, 0.325, 1.13 } }, 0.22))
G("@", 0.92, {
  arc(MX, 0.5, 0.30, 0.53, d2r(22), d2r(-286), 34),
  ring(0.345, 0.555, 0.115, 0.15, 20),
  spline({ 0.46, 0.415, 0.46, 0.60, 0.50, 0.685, 0.575, 0.70 }, 4),
})
G("&", 0.80, {
  spline({
    0.505, 0.215,
    0.455, 0.065,
    0.325, -OV,
    0.205, 0.075,
    0.215, 0.225,
    0.345, 0.385,
    0.175, 0.545,
    0.105, 0.735,
    0.175, 0.945,
    0.345, 1 + OV,
    0.495, 0.925,
    0.555, 0.815,
  }, 4),
  { 0.295, 0.335, 0.615, 0.755 },
})

------------------------------------------------------------- post-processing
-- Shift the whole design right so the left sidebearing is half a letter gap,
-- and stamp each glyph with its ink bounds (the text engine uses them for
-- optical alignment and for tight bounding boxes).
for _, g in pairs(glyphs) do
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, #g.s do
    local s = g.s[i]
    for j = 1, #s, 2 do
      s[j] = s[j] + SHIFT
      if s[j] < x0 then x0 = s[j] end
      if s[j] > x1 then x1 = s[j] end
      if s[j + 1] < y0 then y0 = s[j + 1] end
      if s[j + 1] > y1 then y1 = s[j + 1] end
    end
  end
  if g.d then
    for j = 1, #g.d, 2 do
      g.d[j] = g.d[j] + SHIFT
      if g.d[j] < x0 then x0 = g.d[j] end
      if g.d[j] > x1 then x1 = g.d[j] end
      if g.d[j + 1] < y0 then y0 = g.d[j + 1] end
      if g.d[j + 1] > y1 then y1 = g.d[j + 1] end
    end
  end
  if x0 > x1 then x0, y0, x1, y1 = 0, 0, 0, 0 end
  g.x0, g.y0, g.x1, g.y1 = x0, y0, x1, y1
end

glyphs[" "] = { adv = T.spaceAdvance, s = {}, x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
glyphs["\t"] = { adv = T.spaceAdvance * 4, s = {}, x0 = 0, y0 = 0, x1 = 0, y1 = 0 }

-- Lowercase maps to uppercase: this is an all-caps face.
for b = 97, 122 do
  glyphs[string.char(b)] = glyphs[string.char(b - 32)]
end
-- A few friendly aliases so callers never have to think about it.
glyphs["\226\128\148"] = glyphs["\226\128\147"]   -- em dash -> en dash
glyphs["\226\128\153"] = glyphs["'"]              -- curly apostrophe
glyphs["\226\128\156"] = glyphs['"']
glyphs["\226\128\157"] = glyphs['"']

T.glyphs = glyphs

--- The glyph table for a character, or nil.
function T.glyph(ch) return glyphs[ch] end

--- Advance width of a character, in cap heights. Unknown -> a word space.
function T.advance(ch)
  local g = glyphs[ch]
  return g and g.adv or T.spaceAdvance
end

--- Does the face have this character?
function T.has(ch) return glyphs[ch] ~= nil end

--- Every character the face can draw, sorted -- used by the specimen sheet.
function T.charset()
  local out = {}
  for k in pairs(glyphs) do
    if #k == 1 and k:byte() >= 33 and k:byte() <= 90 then out[#out + 1] = k end
  end
  table.sort(out)
  return out
end

return T
