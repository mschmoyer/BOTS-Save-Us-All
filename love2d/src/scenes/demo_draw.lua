-- Specimen sheet for engine/draw.lua and the ROOTSTOCK display face.
-- Page 1: typography.  Page 2: every drawing primitive, labelled.
-- Run: BOTS_SCENE=src.scenes.demo_draw tools/shot.sh 120 60,120 /tmp/shots_draw
local U    = require("src.core.util")
local P    = require("src.engine.palette")
local Draw = require("src.engine.draw")
local Text = require("src.engine.text")
local TF   = require("src.assets.typeface")

local S = { t = 0, odo = { v = 0 } }

local ALPHA1 = "ABCDEFGHIJKLM"
local ALPHA2 = "NOPQRSTUVWXYZ"
local ALPHA  = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local DIGITS = "0123456789"
local PUNCT  = ". , : ; ! ? ' \" - \226\128\147 / % + = ( ) [ ] * # < > @ &"

local COPY = [[
The last human alive cannot fight. She builds small machines that can, and by
the end of the night she will care whether they come back. Every bot carries a
name, a trait and a boot-up chirp; every tree carries a seed that decides how it
grows. Nothing in this world was drawn by hand -- terrain, canopies, sound and
this very typeface are generated at runtime, which is both a hard constraint and
the whole visual identity.]]

function S:update(dt)
  self.t = self.t + dt
  Text.odometer(self.odo, 148230, dt, 1.6)
end

------------------------------------------------------------------ chrome
local function backdrop()
  local w, h = love.graphics.getDimensions()
  Draw.linearGradient(0, 0, w, h, P.ramp.rock[1], P.black, math.pi * 0.5)
  Draw.noiseSpeckle(0, 0, w, h, 4242, 0.0016, P.ink, 0.05, 1)
end

local function rule(x, y, w, color, alpha)
  Draw.setColor(color or P.inkFaint, alpha or 0.5)
  love.graphics.setLineWidth(1)
  love.graphics.line(x, y, x + w, y)
end

local function tag(str, x, y, color)
  Text.display(str, x, y, 11, { color = color or P.inkFaint, tracking = 0.30, weight = 0.10 })
end

------------------------------------------------------------------- page one
function S:drawType()
  local w, h = love.graphics.getDimensions()
  local M = 56

  tag("ROOTSTOCK", M, 40, P.accent)
  tag("A HAND-VECTORED DISPLAY FACE  /  ALL CAPS  /  " .. #TF.charset() .. " GLYPHS", M + 132, 40)
  tag("SPECIMEN 01", w - M - 78, 40, P.inkFaint)
  rule(M, 62, w - M * 2)

  -- headline lockup ------------------------------------------------------
  Text.display("REFOREST", M, 84, 116, {
    color = P.ink, tracking = 0.055, weight = 0.115,
    glow = { color = P.accent, alpha = 0.30, radius = 9, layers = 3 },
    shadow = { dx = 0, dy = 5, color = P.black, alpha = 0.6 },
  })
  local hw = Text.measure("REFOREST", 116, { tracking = 0.055, weight = 0.115 })
  Draw.setColor(P.accent, 0.9)
  Draw.roundRect("fill", M + hw + 22, 84, 8, 116, 4)
  Text.display("BOTS: SAVE US ALL", M + hw + 44, 90, 30,
               { color = P.accentCool, tracking = 0.10, weight = 0.10 })
  Text.display("SURVIVE 7 CYCLES. GROW A FOREST.", M + hw + 44, 140, 15,
               { color = P.inkDim, tracking = 0.22, weight = 0.095 })
  Text.display("0", M + hw + 44, 168, 32, { color = P.inkFaint, alpha = 0.0 })

  rule(M, 232, w - M * 2, P.inkFaint, 0.3)

  -- size ladder ----------------------------------------------------------
  tag("SIZE", M, 248)
  Text.display(ALPHA1, M, 264, 54, { color = P.ink, tracking = 0.045 })
  Text.display(ALPHA2, M, 330, 54, { color = P.ink, tracking = 0.045 })
  Text.display(ALPHA, M, 400, 26, { color = P.ink, tracking = 0.05 })
  Text.display(ALPHA, M, 436, 17, { color = P.ink, tracking = 0.06 })
  Text.display(ALPHA, M, 462, 12, { color = P.inkDim, tracking = 0.075 })
  Text.display(DIGITS .. "  " .. DIGITS, M, 484, 12, { color = P.inkDim, tracking = 0.075 })

  -- numerals & punctuation ----------------------------------------------
  local cx = 640
  tag("TABULAR NUMERALS", cx, 248)
  Text.display(DIGITS, cx, 264, 48, { color = P.ink, tracking = 0.04 })
  tag("PUNCTUATION", cx, 330)
  Text.display(PUNCT, cx, 346, 22, { color = P.ink, tracking = 0.03 })
  Text.display("ABCDEFGHIJKLMNOPQRSTUVWXYZ", cx, 386, 22, { color = P.ink, tracking = 0.03 })

  -- weight ladder --------------------------------------------------------
  tag("WEIGHT", cx, 424)
  local wl = { 0.065, 0.09, 0.115, 0.15 }
  for i, ww in ipairs(wl) do
    Text.display("GROWTH", cx + (i - 1) * 148, 440, 30, { weight = ww, tracking = 0.04, color = P.ink })
    Text.display(string.format("%.3F", ww), cx + (i - 1) * 148, 478, 10,
                 { color = P.inkFaint, tracking = 0.16 })
  end

  rule(M, 512, w - M * 2, P.inkFaint, 0.3)

  -- overshoot proof ------------------------------------------------------
  tag("OVERSHOOT", M, 528)
  local ox, oy, os = M, 548, 92
  Draw.setColor(P.danger, 0.5)
  love.graphics.setLineWidth(1)
  love.graphics.line(ox - 6, oy, ox + 300, oy)
  love.graphics.line(ox - 6, oy + os, ox + 300, oy + os)
  Text.display("HOSE", ox, oy, os, { color = P.ink, tracking = 0.05 })
  Text.display("ROUND SHAPES BREAK THE LINE BY 2%", ox, oy + os + 14, 10,
               { color = P.inkFaint, tracking = 0.16 })

  -- italic + condense ----------------------------------------------------
  tag("SHEAR / AUTO-CONDENSE", 400, 528)
  Text.display("EXTRACTION", 400, 548, 34, { color = P.warn, italic = 0.16, tracking = 0.04 })
  Text.display("HARVESTER PRIME", 400, 596, 34,
               { color = P.ink, tracking = 0.04, maxWidth = 218 })
  Draw.setColor(P.inkFaint, 0.35)
  love.graphics.setLineWidth(1)
  love.graphics.line(618, 590, 618, 634)

  -- HUD numerals ---------------------------------------------------------
  tag("HUD", 660, 528)
  Text.number(self.odo.v, 660, 546, 40, { color = P.o2, comma = true, tracking = 0.03 })
  Text.display("O2", 660, 594, 14, { color = P.inkDim, tracking = 0.24 })
  Text.number(87.4, 700, 590, 20, { color = P.accent, decimals = 1, suffix = "%", tracking = 0.03 })

  tag("TYPE-ON", 900, 528)
  local prog = U.saturate((self.t % 4) / 2.4)
  local shown, nextCh, frac = Text.reveal("YOU'VE TAUGHT US LOVE. SAVE THE HUMAN.", prog)
  local sw = Text.display(shown, 900, 546, 19, { color = P.love, tracking = 0.05 })
  if nextCh then
    Text.display(nextCh, 900 + sw, 546, 19, { color = P.love, alpha = frac, tracking = 0.05 })
  end

  -- body copy ------------------------------------------------------------
  tag("BODY COPY  /  LOVE BUILT-IN", 900, 588)
  Text.body(COPY, 900, 606, 15, { width = w - 900 - M, color = P.inkDim, lineHeight = 1.5 })

  -- footer ---------------------------------------------------------------
  rule(M, h - 62, w - M * 2, P.inkFaint, 0.3)
  tag("CAP 1.000   OVERSHOOT 0.020   DEFAULT WEIGHT 0.105   TRACKING 0.035", M, h - 48)
  tag("PAGE 1 OF 2  --  TYPOGRAPHY", w - M - 190, h - 48, P.accent)
end

------------------------------------------------------------------- page two
local CELLS = {}
local function cell(name, fn) CELLS[#CELLS + 1] = { name = name, fn = fn } end

cell("ROUNDRECT FILL", function(x, y, w, h, t)
  Draw.setColor(P.ramp.metal[2])
  Draw.roundRect("fill", x, y, w, h, 14)
  Draw.setColor(P.ramp.metal[4], 0.9)
  Draw.roundRect("line", x + 6, y + 6, w - 12, h - 12, 9)
end)

cell("ROUNDRECT PER-CORNER", function(x, y, w, h)
  Draw.setColor(P.accent, 0.85)
  love.graphics.setLineWidth(2)
  Draw.roundRect("line", x, y, w, h, { 26, 4, 26, 4 })
  Draw.setColor(P.accent, 0.16)
  Draw.roundRect("fill", x + 10, y + 10, w - 20, h - 20, { 18, 2, 18, 2 })
end)

cell("CAPSULE", function(x, y, w, h, t)
  local a = t * 0.7
  local cx, cy = x + w / 2, y + h / 2
  Draw.setColor(P.ramp.cobalt[2])
  Draw.capsule("fill", cx - math.cos(a) * 34, cy - math.sin(a) * 20,
                       cx + math.cos(a) * 34, cy + math.sin(a) * 20, 17)
  Draw.setColor(P.ramp.cobalt[4], 0.8)
  love.graphics.setLineWidth(1.5)
  Draw.capsule("line", cx - math.cos(a) * 34, cy - math.sin(a) * 20,
                       cx + math.cos(a) * 34, cy + math.sin(a) * 20, 17)
end)

cell("BLOB  (SEEDED)", function(x, y, w, h, t)
  local cx, cy = x + w / 2, y + h / 2
  for i = 1, 3 do
    local sd = 100 + i * 37
    Draw.setColor(P.ramp.leaf[i + 1], 0.92)
    Draw.blob(cx + (i - 2) * 24, cy + (i - 2) * 6, 34 - i * 3, 20, sd, 0.24, 0.9, "fill", t * 0.15)
  end
  Draw.setColor(P.ramp.leafHi[4], 0.7)
  love.graphics.setLineWidth(1.5)
  Draw.blob(cx - 24, cy - 6, 31, 20, 137, 0.24, 0.9, "line", t * 0.15)
end)

cell("SOFT SHADOW", function(x, y, w, h)
  local cx, cy = x + w / 2, y + h / 2
  Draw.setColor(P.ramp.sand[3], 0.4)
  love.graphics.rectangle("fill", x, cy - 4, w, h / 2 + 4)
  Draw.softShadow(cx, cy + 26, 52, 17, 0.5)
  Draw.setColor(P.ramp.metal[3])
  love.graphics.circle("fill", cx, cy + 4, 24)
  Draw.setColor(P.ramp.metal[4])
  love.graphics.circle("fill", cx - 6, cy - 4, 9)
end)

cell("GLOW  (ADDITIVE)", function(x, y, w, h, t)
  local cx, cy = x + w / 2, y + h / 2
  Draw.glow(cx, cy, 52 + math.sin(t * 2) * 5, P.accent, 0.85, 3)
  Draw.setColor(P.white, 0.95)
  love.graphics.circle("fill", cx, cy, 6)
end)

cell("RADIAL GRADIENT", function(x, y, w, h)
  Draw.radialGradient(x + w / 2, y + h / 2, math.min(w, h) * 0.48,
                      P.ramp.rift[3], P.ramp.rift[1])
end)

cell("LINEAR GRADIENT", function(x, y, w, h, t)
  Draw.linearGradient(x, y, w, h, P.ramp.water[4], P.ramp.water[1], 0.6 + math.sin(t * 0.5) * 0.5)
end)

cell("RING  /  DIAL", function(x, y, w, h, t)
  local cx, cy = x + w / 2, y + h / 2
  local r = math.min(w, h) * 0.38
  Draw.ring(cx, cy, r, 9, 0, math.pi * 2, P.ramp.metal[1], 0)
  local p = (t * 0.28) % 1
  Draw.ring(cx, cy, r, 9, -math.pi / 2, -math.pi / 2 + p * math.pi * 2, P.warn, 4)
  Text.display(Text.format(p * 100), cx, cy - 8, 16,
               { color = P.ink, align = "center", tracking = 0.02 })
end)

cell("DASHED CIRCLE", function(x, y, w, h, t)
  local cx, cy = x + w / 2, y + h / 2
  Draw.dashedCircle(cx, cy, 46, 11, 9, t * 26, 2.5, P.accentCool)
  Draw.dashedCircle(cx, cy, 30, 6, 8, -t * 18, 1.5, P.inkFaint)
end)

cell("DASHED LINE", function(x, y, w, h, t)
  for i = 0, 3 do
    Draw.dashedLine(x + 10, y + 22 + i * 22, x + w - 10, y + 22 + i * 22,
                    14 - i * 2, 8, t * 30 * (i + 1), 3 - i * 0.5,
                    P.shade(P.ramp.cobalt, 2 + i * 0.6))
  end
end)

cell("POLYLINE  ROUND", function(x, y, w, h, t)
  local pts = {}
  for i = 0, 9 do
    pts[#pts + 1] = x + 12 + i * (w - 24) / 9
    pts[#pts + 1] = y + h / 2 + math.sin(i * 0.9 + t) * 28
  end
  Draw.polylineRound(pts, 7, P.ramp.ember[3])
  Draw.polylineRound(pts, 2, P.ramp.ember[4])
end)

cell("CHEVRON", function(x, y, w, h, t)
  local cx, cy = x + w / 2, y + h / 2
  for i = 1, 3 do
    Draw.setColor(P.accent, 1 - (i - 1) * 0.28)
    Draw.chevron(cx - 30 + i * 22 + math.sin(t * 3) * 4, cy, 22, 0, 5)
  end
end)

cell("STAR", function(x, y, w, h, t)
  local cx, cy = x + w / 2, y + h / 2
  Draw.setColor(P.warn)
  Draw.star(cx, cy, 42, 17, 5, -math.pi / 2 + t * 0.4, "fill")
  Draw.setColor(P.ink, 0.5)
  love.graphics.setLineWidth(1)
  Draw.star(cx, cy, 42, 17, 5, -math.pi / 2 + t * 0.4, "line")
end)

cell("HEXAGON", function(x, y, w, h, t)
  local cx, cy = x + w / 2, y + h / 2
  Draw.setColor(P.ramp.metal[2])
  Draw.hexagon(cx, cy, 44, t * 0.2, "fill")
  Draw.setColor(P.accentCool, 0.9)
  love.graphics.setLineWidth(2)
  Draw.hexagon(cx, cy, 44, t * 0.2, "line")
  Draw.setColor(P.accentCool, 0.35)
  Draw.hexagon(cx, cy, 26, t * 0.2, "line")
end)

cell("DIAMOND", function(x, y, w, h, t)
  local cx, cy = x + w / 2, y + h / 2
  Draw.setColor(P.ramp.cobalt[3])
  Draw.diamond(cx, cy, 30, 44, "fill")
  Draw.setColor(P.ramp.cobalt[4], 0.9)
  love.graphics.setLineWidth(1.5)
  Draw.diamond(cx, cy, 40, 56, "line")
end)

cell("ARROW", function(x, y, w, h, t)
  local cx, cy = x + w / 2, y + h / 2
  Draw.setColor(P.acid, 0.9)
  Draw.arrow(x + 16, cy + 30, x + w - 16, cy - 24, 3, 20, 11)
  Draw.setColor(P.inkDim, 0.7)
  Draw.arrow(x + 16, cy + 40, x + 16 + (w - 32) * (0.5 + 0.5 * math.sin(t)), cy + 40, 2)
end)

cell("BEAM  (TAPERED)", function(x, y, w, h, t)
  local cy = y + h / 2
  Draw.beam(x + 12, cy + 26, x + w - 12, cy - 18 + math.sin(t * 1.4) * 14, 26, P.ramp.rift[3], 1.1)
  Draw.setColor(P.ramp.rift[4], 0.9)
  love.graphics.circle("fill", x + 12, cy + 26, 5)
end)

cell("SCANLINES", function(x, y, w, h, t)
  Draw.setColor(P.ramp.water[2], 0.55)
  Draw.roundRect("fill", x, y, w, h, 8)
  Draw.scanlineRect(x, y, w, h, 5, P.o2, 0.30, t * 12, 2)
  Draw.setColor(P.o2, 0.6)
  love.graphics.setLineWidth(1)
  Draw.roundRect("line", x, y, w, h, 8)
end)

cell("NOISE SPECKLE", function(x, y, w, h)
  Draw.setColor(P.ramp.soil[2])
  love.graphics.rectangle("fill", x, y, w, h)
  Draw.noiseSpeckle(x, y, w, h, 9, 0.03, P.ramp.sand[4], 0.6, 2)
  Draw.noiseSpeckle(x, y, w, h, 21, 0.02, P.ramp.soil[1], 0.7, 2)
end)

cell("CROSS HATCH", function(x, y, w, h)
  Draw.setColor(P.ramp.blight[1])
  Draw.roundRect("fill", x, y, w, h, 6)
  Draw.crossHatch(x, y, w, h, 9, -math.pi * 0.25, 1, P.ramp.blight[3], 0.55, true)
end)

cell("STIPPLE", function(x, y, w, h)
  Draw.setColor(P.ramp.moss[1])
  love.graphics.rectangle("fill", x, y, w, h)
  Draw.stipple(x, y, w, h, 7, 3, P.ramp.moss[4], 0.5, 2)
  Draw.stipple(x, y, w / 2, h, 5, 8, P.ramp.leafHi[4], 0.45, 1)
end)

cell("QUAD  (GOURAUD)", function(x, y, w, h, t)
  local s = math.sin(t) * 12
  Draw.quad(x + 8, y + 10 + s, x + w - 8, y + 6, x + w - 14, y + h - 8, x + 14, y + h - 12 - s,
            P.ramp.ember[4], P.ramp.blight[3], P.ramp.cobalt[2], P.ramp.leaf[3])
end)

cell("WITHBLEND  ADD", function(x, y, w, h, t)
  local cx, cy = x + w / 2, y + h / 2
  Draw.withBlend("add", function()
    for i = 0, 2 do
      local a = t * 0.8 + i * math.pi * 2 / 3
      Draw.setColor(P.shade(P.ramp.cobalt, 3), 0.55)
      love.graphics.circle("fill", cx + math.cos(a) * 20, cy + math.sin(a) * 20, 32)
    end
  end)
end)

function S:drawPrims()
  local w, h = love.graphics.getDimensions()
  local M = 44
  tag("ENGINE / DRAW", M, 40, P.accent)
  tag("THE SHAPE VOCABULARY  /  " .. #CELLS .. " PRIMITIVES  /  CACHED MESHES, ZERO PER-FRAME ALLOCATION", M + 132, 40)
  tag("SPECIMEN 02", w - M - 78, 40)
  rule(M, 62, w - M * 2)

  local cols, rows = 6, 4
  local gw = (w - M * 2) / cols
  local gh = (h - 130) / rows
  for i = 1, #CELLS do
    local c = CELLS[i]
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    local x = M + col * gw
    local y = 86 + row * gh
    local pad = 10
    local bx, by, bw, bh = x + pad, y + pad, gw - pad * 2, gh - pad * 2 - 20

    Draw.setColor(P.ink, 0.045)
    Draw.roundRect("fill", bx, by, bw, bh, 6)

    love.graphics.push()
    love.graphics.setScissor(math.floor(bx), math.floor(by), math.ceil(bw), math.ceil(bh))
    c.fn(bx, by, bw, bh, self.t)
    love.graphics.setScissor()
    love.graphics.pop()
    Draw.reset()

    Draw.setColor(P.ink, 0.10)
    love.graphics.setLineWidth(1)
    Draw.roundRect("line", bx, by, bw, bh, 6)
    Text.display(c.name, bx, by + bh + 8, 10,
                 { color = P.inkDim, tracking = 0.14, weight = 0.105 })
  end

  rule(M, h - 40, w - M * 2, P.inkFaint, 0.3)
  tag("PAGE 2 OF 2  --  PRIMITIVES", w - M - 200, h - 30, P.accent)
end

------------------------------------------------------------------------ draw
function S:draw()
  love.graphics.clear(P.black)
  backdrop()
  if self.t < 1.4 then self:drawType() else self:drawPrims() end
  Draw.reset()
end

function S:keypressed(k)
  if k == "escape" then love.event.quit() end
end

return S
