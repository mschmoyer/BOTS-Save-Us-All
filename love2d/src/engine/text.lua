-- The typography engine.
--
-- Two faces live here:
--   * the DISPLAY face -- assets/typeface.lua, hand-vectored, stroked live.
--     Used for the logo, headers, HUD numerals, card titles, tallies.
--   * BODY copy -- LOVE's built-in font at tuned sizes, cached per size.
--
-- Display text is laid out once per (string, size, weight, tracking, width
-- scale, shear) and the resulting pixel-space polylines are kept in a
-- two-generation cache, so redrawing the same HUD label every frame costs a
-- handful of love.graphics.line calls and zero allocations.
--
-- Why stroked lines and not a mesh: LOVE's "smooth" line style anti-aliases
-- for free, and the window is created with msaa = 0. A tessellated mesh would
-- be one draw call but visibly jagged, which is the wrong trade for type.
local U  = require("src.core.util")
local P  = require("src.engine.palette")
local TF = require("src.assets.typeface")

local lg = love.graphics
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

local ok_utf8, utf8lib = pcall(require, "utf8")

local Text = {}
Text.face = TF

------------------------------------------------------------------- defaults
Text.defaults = {
  weight   = TF.weight,   -- stroke weight, in cap heights
  tracking = 0.035,       -- extra letter space, in cap heights
  align    = "left",
}

-- Where a drop shadow stops being an edge and starts being a shadow. See the
-- note in Text.display.
local SOFT_MIN    = 22      -- px: type at or above this gets a soft shadow
local SOFT_BLUR   = 0.11   -- spread, in cap heights
local SOFT_LAYERS = 4       -- widening strokes the spread is dealt over

--- The pairs that actually need it. Values are in cap heights and negative
--- (they pull the pair together). Kerning a stroke face is mostly about
--- diagonals meeting flats and about punctuation tucking under an overhang.
Text.kerningPairs = {
  AV = -0.05, AW = -0.05, AY = -0.05, AT = -0.045,
  VA = -0.05, WA = -0.05, YA = -0.05, TA = -0.045,
  LT = -0.045, LV = -0.045, LW = -0.045, LY = -0.05,
  PA = -0.04, FA = -0.04,
  ["P."] = -0.075, ["F."] = -0.07, ["T."] = -0.075, ["V."] = -0.065,
  ["W."] = -0.055, ["Y."] = -0.075, ["7."] = -0.06, ["L."] = -0.03,
  ["P,"] = -0.075, ["F,"] = -0.07, ["T,"] = -0.075, ["Y,"] = -0.075,
  ["r."] = 0,
  OA = -0.02, AO = -0.02, OV = -0.02, VO = -0.02,
  ["-1"] = -0.02,
}

local function kern(a, b)
  local k = Text.kerningPairs[a .. b]
  return k or 0
end

--------------------------------------------------------------- char iteration
-- Returns an iterator over characters as strings. UTF-8 aware when LOVE's
-- utf8 library is present, byte-wise otherwise (the face is ASCII anyway).
local function chars(str)
  if ok_utf8 and utf8lib and utf8lib.codes then
    local it, s, i = utf8lib.codes(str)
    return function()
      local pos, code = it(s, i)
      if not pos then return nil end
      i = pos
      return utf8lib.char(code)
    end
  end
  local i = 0
  return function()
    i = i + 1
    if i > #str then return nil end
    return str:sub(i, i)
  end
end
Text.chars = chars

--------------------------------------------------------------------- caching
local CACHE_MAX = 240
local cur, old, curN = {}, {}, 0

local function cacheGet(key)
  local e = cur[key]
  if e then return e end
  e = old[key]
  if e then
    cur[key] = e
    curN = curN + 1
    return e
  end
  return nil
end

local function cachePut(key, e)
  cur[key] = e
  curN = curN + 1
  if curN > CACHE_MAX then
    old = cur
    cur = {}
    curN = 0
  end
  return e
end

function Text.clearCache()
  cur, old, curN = {}, {}, 0
end

------------------------------------------------------------------ raw advance
--- Advance width of a string in cap heights, before any scaling.
function Text.advanceEm(str, tracking)
  tracking = tracking or Text.defaults.tracking
  local pen, prev, n = 0, nil, 0
  for ch in chars(str) do
    if prev then pen = pen + tracking + kern(prev, ch) end
    pen = pen + TF.advance(ch)
    prev = ch
    n = n + 1
  end
  return pen, n
end

--------------------------------------------------------------------- layout
-- Builds the pixel-space geometry for one line of display text.
local function build(str, size, weight, tracking, xScale, shear)
  local e = { s = {}, d = nil, w = 0, lw = weight * size, dr = weight * size * 0.5 }
  local pen, prev = 0, nil
  local sx = size * xScale
  local ns = 0
  for ch in chars(str) do
    local g = TF.glyphs[ch]
    if g == nil then g = TF.glyphs["?"] end
    if prev then pen = pen + tracking + kern(prev, ch) end
    if g and #g.s > 0 then
      for i = 1, #g.s do
        local src = g.s[i]
        local dst = {}
        for j = 1, #src, 2 do
          local gx, gy = pen + src[j], src[j + 1]
          dst[j]     = gx * sx + (1 - gy) * shear * size
          dst[j + 1] = gy * size
        end
        ns = ns + 1
        e.s[ns] = dst
      end
    end
    if g and g.d then
      e.d = e.d or {}
      for j = 1, #g.d, 2 do
        local gx, gy = pen + g.d[j], g.d[j + 1]
        e.d[#e.d + 1] = gx * sx + (1 - gy) * shear * size
        e.d[#e.d + 1] = gy * size
      end
    end
    pen = pen + (g and g.adv or TF.spaceAdvance)
    prev = ch
  end
  e.w = pen * sx
  return e
end

local function entryFor(str, size, opts)
  local d = Text.defaults
  local weight   = (opts and opts.weight)   or d.weight
  local tracking = (opts and opts.tracking) or d.tracking
  local shear    = (opts and opts.italic)   or 0
  local xScale   = (opts and opts.xScale)   or 1

  -- auto-condense: give back tracking first, then narrow the glyphs.
  local maxW = opts and opts.maxWidth
  if maxW then
    local emW = Text.advanceEm(str, tracking)
    if emW * size * xScale > maxW then
      local minTrack = -0.02
      local em0 = Text.advanceEm(str, minTrack)
      if em0 * size * xScale <= maxW then
        -- solve for the tracking that exactly fits
        local _, n = Text.advanceEm(str, 0)
        if n > 1 then
          local base = Text.advanceEm(str, 0)
          tracking = (maxW / (size * xScale) - base) / (n - 1)
        end
      else
        tracking = minTrack
        xScale = xScale * (maxW / (em0 * size * xScale))
      end
    end
  end

  local key = str .. "\1" .. floor(size * 8 + 0.5) .. "\1" .. floor(weight * 1000 + 0.5)
              .. "\1" .. floor(tracking * 1000 + 0.5) .. "\1" .. floor(xScale * 1000 + 0.5)
              .. "\1" .. floor(shear * 1000 + 0.5)
  local e = cacheGet(key)
  if e then return e end
  return cachePut(key, build(str, size, weight, tracking, xScale, shear))
end
Text.entryFor = entryFor

local function alignOffset(align, w, boxW)
  if align == "center" then
    return boxW and (boxW - w) * 0.5 or -w * 0.5
  elseif align == "right" then
    return boxW and (boxW - w) or -w
  end
  return 0
end

------------------------------------------------------------------- rendering
local function strokeEntry(e, width)
  local s = e.s
  for i = 1, #s do
    lg.line(s[i])
  end
  if e.d then
    local r = width * 0.5
    local segs = U.clamp(ceil(r * 1.6), 4, 16)
    local d = e.d
    for i = 1, #d, 2 do
      lg.circle("fill", d[i], d[i + 1], r, segs)
    end
  end
end

--- Draw a line of display type. Returns the rendered width in pixels.
---
--- opts:
---   color, alpha, weight, tracking, align, width (box width for align),
---   maxWidth (auto-condense), italic (shear), xScale,
---   shadow  = number offset | { dx, dy, color, alpha, blur }
---   glow    = number radius | { color, alpha, radius, layers }
---   baseline = true  (y is the baseline instead of the cap line)
---   snap    = true   (round the origin to whole pixels: crisper small text)
function Text.display(str, x, y, size, opts)
  if str == nil then return 0 end
  str = tostring(str)
  size = size or 24
  local e = entryFor(str, size, opts)
  local align = (opts and opts.align) or Text.defaults.align
  local boxW  = opts and opts.width
  local ox = alignOffset(align, e.w, boxW)
  local oy = (opts and opts.baseline) and -size or 0
  local px, py = x + ox, y + oy
  if opts and opts.snap then px, py = floor(px + 0.5), floor(py + 0.5) end

  local color = (opts and opts.color) or P.ink
  local alpha = (opts and opts.alpha) or 1

  local prevJoin  = lg.getLineJoin()
  local prevStyle = lg.getLineStyle()
  local prevW     = lg.getLineWidth()
  lg.setLineJoin("miter")
  lg.setLineStyle("smooth")

  lg.push()
  lg.translate(px, py)

  -- glow first, underneath everything
  local glow = opts and opts.glow
  if glow then
    local gc, ga, gr, gl
    if type(glow) == "number" then
      gc, ga, gr, gl = color, 0.5, glow, 3
    else
      gc = glow.color or color
      ga = glow.alpha or 0.5
      gr = glow.radius or size * 0.28
      gl = glow.layers or 3
    end
    local bm, am = lg.getBlendMode()
    lg.setBlendMode("add", "alphamultiply")
    for i = gl, 1, -1 do
      local t = i / gl
      lg.setColor(gc[1], gc[2], gc[3], (gc[4] or 1) * ga * alpha / gl * 0.9)
      lg.setLineWidth(e.lw + gr * 2 * t)
      strokeEntry(e, e.lw + gr * 2 * t)
    end
    lg.setBlendMode(bm, am)
  end

  -- Drop shadow.
  --
  -- Two shadows live under this one option, and the size of the type decides
  -- which. A caption is one stroke wide and needs a *hard* 1 px edge under it
  -- or it vanishes over a sunlit canopy -- that is the whole reason HUD
  -- captions pass a shadow at all. Display type at heading size and up needs
  -- the opposite: an un-blurred black copy of a 108 px logo is a second logo
  -- sitting behind the first, and it is the first thing anyone sees on the
  -- title. Above SOFT_MIN the shadow is spread over a few widening strokes,
  -- which is as close to a blur as a stroked face gets without a canvas: the
  -- outermost pass carries a third of the density and the core carries all of
  -- it. `shadow.blur` overrides the spread in pixels; 0 forces the hard edge.
  local sh = opts and opts.shadow
  if sh then
    local dx, dy, sc, sa, blur
    if type(sh) == "number" then
      dx, dy, sc, sa = sh, sh, P.black, 0.55
    else
      dx = sh.dx or sh[1] or 0
      dy = sh.dy or sh[2] or size * 0.06
      sc = sh.color or P.black
      sa = sh.alpha or 0.55
      blur = sh.blur
    end
    if blur == nil then blur = size >= SOFT_MIN and size * SOFT_BLUR or 0 end
    lg.push()
    lg.translate(dx, dy)
    if blur > 0.5 then
      -- Per-layer alpha solved so the layers stack back to `sa` in the core
      -- rather than to a black slab: 1 - (1 - sa)^(1/n).
      local n = SOFT_LAYERS
      local la = 1 - (1 - U.clamp(sa, 0, 0.99)) ^ (1 / n)
      for i = n, 1, -1 do
        local wdt = e.lw + blur * 2 * (i / n)
        lg.setColor(sc[1], sc[2], sc[3], (sc[4] or 1) * la * alpha)
        lg.setLineWidth(wdt)
        strokeEntry(e, wdt)
      end
    else
      lg.setColor(sc[1], sc[2], sc[3], (sc[4] or 1) * sa * alpha)
      lg.setLineWidth(e.lw)
      strokeEntry(e, e.lw)
    end
    lg.pop()
  end

  lg.setColor(color[1], color[2], color[3], (color[4] or 1) * alpha)
  lg.setLineWidth(e.lw)
  strokeEntry(e, e.lw)

  lg.pop()
  lg.setLineJoin(prevJoin)
  lg.setLineStyle(prevStyle)
  lg.setLineWidth(prevW)
  lg.setColor(1, 1, 1, 1)
  return e.w
end

--- Width and cap height of a display string, in pixels.
function Text.measure(str, size, opts)
  if str == nil or str == "" then return 0, size or 0 end
  local e = entryFor(tostring(str), size or 24, opts)
  return e.w, size or 24
end

function Text.width(str, size, opts)
  local w = Text.measure(str, size, opts)
  return w
end

--- Greedy word wrap for the display face. Returns a table of lines.
function Text.wrap(str, size, width, opts)
  local lines, line = {}, nil
  for word in tostring(str):gmatch("%S+") do
    local try = line and (line .. " " .. word) or word
    if line and Text.measure(try, size, opts) > width then
      lines[#lines + 1] = line
      line = word
    else
      line = try
    end
  end
  if line then lines[#lines + 1] = line end
  return lines
end

local blockOpts = {}

--- Draw wrapped display type. Returns the total height used.
function Text.displayBlock(str, x, y, size, width, opts)
  local lines = type(str) == "table" and str or Text.wrap(str, size, width, opts)
  local lh = (opts and opts.lineHeight) or 1.42
  for k in pairs(blockOpts) do blockOpts[k] = nil end
  if opts then for k, v in pairs(opts) do blockOpts[k] = v end end
  blockOpts.width = width
  blockOpts.maxWidth = nil
  for i = 1, #lines do
    Text.display(lines[i], x, y + (i - 1) * size * lh, size, blockOpts)
  end
  return #lines * size * lh
end

------------------------------------------------------------------- numerals
--- Tabular numerals. opts.pad zero-pads, opts.comma groups thousands,
--- opts.decimals fixes the fraction, opts.prefix / opts.suffix bracket it.
function Text.format(n, opts)
  local dec = (opts and opts.decimals) or 0
  local s
  if dec > 0 then
    -- lowercase f. The browser build's Lua rejects "%F" -- it is the third
    -- time that has reached a build, so: never %F, anywhere, ever.
    s = string.format("%." .. dec .. "f", n)
  else
    s = tostring(floor(n + 0.5))
  end
  if opts and opts.comma then
    local sign, body = s:match("^(%-?)(.*)$")
    local intPart, rest = body:match("^(%d*)(.*)$")
    local k
    repeat intPart, k = intPart:gsub("^(%d+)(%d%d%d)", "%1,%2") until k == 0
    s = sign .. intPart .. rest
  end
  if opts and opts.pad then
    local sign, body = s:match("^(%-?)(.*)$")
    while #body < opts.pad do body = "0" .. body end
    s = sign .. body
  end
  if opts and opts.prefix then s = opts.prefix .. s end
  if opts and opts.suffix then s = s .. opts.suffix end
  return s
end

function Text.number(n, x, y, size, opts)
  return Text.display(Text.format(n, opts), x, y, size, opts)
end

--- Odometer roll. `state` is a table you own: { v = <displayed value> }.
--- Call every frame; returns the value to draw. The roll is critically
--- damped, so it never overshoots a score.
function Text.odometer(state, target, dt, rate)
  state.v = state.v or target
  state.target = target
  local r = rate or 7
  state.v = U.damp(state.v, target, r, dt)
  if math.abs(state.v - target) < 0.5 then state.v = target end
  return state.v
end

------------------------------------------------------------------- reveal
--- Typed-out dialogue. `progress` runs 0..1 over the whole string.
--- Returns the fully visible prefix and the fractional alpha of the character
--- currently being typed (draw it separately at that alpha for a soft type-on).
function Text.reveal(str, progress)
  local n = 0
  for _ in chars(str) do n = n + 1 end
  local exact = U.saturate(progress) * n
  local whole = floor(exact)
  local frac = exact - whole
  local i, out, nextCh = 0, {}, nil
  for ch in chars(str) do
    i = i + 1
    if i <= whole then
      out[#out + 1] = ch
    elseif i == whole + 1 then
      nextCh = ch
      break
    end
  end
  return table.concat(out), nextCh, frac
end

--- Character-count variant, for typewriter timing driven by dt.
function Text.revealChars(str, count)
  local n = 0
  for _ in chars(str) do n = n + 1 end
  if n == 0 then return "", nil, 0 end
  return Text.reveal(str, count / n)
end

--------------------------------------------------------------------- body
local fonts = {}

--- LOVE's built-in font at `size`, cached.
function Text.font(size)
  size = floor(size + 0.5)
  local f = fonts[size]
  if not f then
    f = lg.newFont(size)
    f:setFilter("linear", "linear", 4)
    fonts[size] = f
  end
  return f
end

--- Body copy. opts: color, alpha, align, width, lineHeight.
--- Returns the height drawn.
function Text.body(str, x, y, size, opts)
  size = size or 16
  local f = Text.font(size)
  local lh = (opts and opts.lineHeight) or 1.38
  f:setLineHeight(lh)
  local prev = lg.getFont()
  lg.setFont(f)
  local c = (opts and opts.color) or P.inkDim
  local a = (opts and opts.alpha) or 1
  lg.setColor(c[1], c[2], c[3], (c[4] or 1) * a)
  local h
  if opts and opts.width then
    local align = opts.align or "left"
    lg.printf(str, x, y, opts.width, align)
    local _, lines = f:getWrap(str, opts.width)
    h = #lines * f:getHeight() * lh
  else
    if opts and opts.align == "center" then
      x = x - f:getWidth(str) * 0.5
    elseif opts and opts.align == "right" then
      x = x - f:getWidth(str)
    end
    lg.print(str, x, y)
    h = f:getHeight() * lh
  end
  lg.setColor(1, 1, 1, 1)
  if prev then lg.setFont(prev) end
  return h
end

function Text.bodyMeasure(str, size, width)
  local f = Text.font(size or 16)
  if width then
    local w, lines = f:getWrap(str, width)
    return w, #lines * f:getHeight()
  end
  return f:getWidth(str), f:getHeight()
end

return Text
