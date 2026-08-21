-- The cover.
--
-- Everything on this screen is generated: a five-layer vector dawn (sky ramp,
-- stars, aurora, sun, three parallax ridges with a swaying treeline), the logo
-- struck in the display face, and a left-anchored menu column locked to the
-- logo's optical width.
--
-- It is deliberately *not* symmetrical. The type column sits on the left sixth,
-- the sun sits on the right third, and the two hold the frame between them.
--
-- The entrance is sequenced rather than faded: sky, then ridges, then the logo
-- assembling out of wide tracking, then the rule, then the menu rows, then the
-- footer. Nothing on this screen arrives at the same time as anything else.
--
-- Self-contained: no terrain, no tree module, no world. Only Draw, VFX and the
-- palette.
local U        = require("src.core.util")
local P        = require("src.engine.palette")
local Draw     = require("src.engine.draw")
local Text     = require("src.engine.text")
local UI       = require("src.engine.ui")
local Input    = require("src.engine.input")
local Screen   = require("src.engine.screen")
local Settings = require("src.game.settings")
local Opt      = require("src.core.optional")
local VFX      = Opt.require("src.engine.vfx")
local Music    = Opt.require("src.engine.music")

local lg = love.graphics
local floor, min, max = math.floor, math.min, math.max
local cos, sin, pi = math.cos, math.sin, math.pi  -- backdrop maths
local TAU = U.TAU

local S = {}
S.updateWhenCovered = true      -- keep breathing behind Options

--------------------------------------------------------------------- timing
-- Seconds from `enter`. Read these top to bottom and you have the entrance.
local SEQ = {
  sky   = 0.00, skyDur  = 1.40,
  ridge = 0.30, ridgeStep = 0.14, ridgeDur = 0.85,
  logo  = 0.70, logoDur = 0.90,
  say   = 1.05,
  tag   = 1.34,
  menu  = 1.62, menuStep = 0.085, menuDur = 0.44,
  foot  = 2.24,
}

--------------------------------------------------------------- backdrop model
local BG = { built = false, w = 0, h = 0 }

--- A ridge line, as a flat {x, y, x, y, ...} list. Drawn as a quad strip so it
--- can carry a gradient and never needs a concave polygon fill.
local function buildRidge(seed, baseY, amp, w, step, tilt)
  local pts = {}
  local n = 0
  for x = -step, w + step * 2, step do
    local t = x / w
    local nz = U.fbm(x * 0.0018, seed * 3.7, 4, 2.1, 0.52, seed)
    local ny = baseY - (nz - 0.5) * amp - t * (tilt or 0)
    n = n + 1 pts[n] = x
    n = n + 1 pts[n] = ny
  end
  return pts
end

--- A silhouette tree: trunk, three canopy blobs, a seed for the blob wobble.
local function buildTrees(rng, ridge, count, scale, w)
  local out = {}
  for i = 1, count do
    local x = rng:range(-40, w + 40)
    -- sample the ridge height at x
    local step = ridge.step
    local idx = U.clamp(floor((x + step) / step) * 2 + 1, 1, #ridge.pts - 1)
    local y = ridge.pts[idx + 1] or ridge.base
    out[i] = {
      x = x, y = y + 2,
      h = rng:range(26, 48) * scale,
      r = rng:range(21, 33) * scale,
      seed = rng:int(1, 9999),
      phase = rng:range(0, TAU),
      lean = rng:range(-0.10, 0.10),
      amp = rng:range(0.6, 1.5),
    }
  end
  table.sort(out, function(a, b) return a.y < b.y end)
  return out
end

local function build(w, h)
  if BG.built and BG.w == w and BG.h == h then return end
  BG.built, BG.w, BG.h = true, w, h
  local rng = U.rng(20190101)

  BG.horizon = floor(h * 0.575)
  BG.sunX = floor(w * 0.705)
  BG.sunY = BG.horizon - floor(h * 0.052)
  BG.sunR = floor(min(w, h) * 0.058)

  -- stars, thinning toward the horizon
  BG.stars = {}
  for i = 1, 150 do
    local y = rng:range(0, BG.horizon * 0.92)
    local keep = 1 - (y / BG.horizon) ^ 0.7
    if rng:chance(keep * 0.95 + 0.05) then
      BG.stars[#BG.stars + 1] = {
        x = rng:range(0, w), y = y,
        r = rng:range(0.5, 1.7), ph = rng:range(0, TAU),
        sp = rng:range(0.7, 2.4),
      }
    end
  end

  -- Clouds. One flat lozenge each read as a placeholder ellipse against a
  -- painted sky, so each cloud is now a short run of lobes with its own
  -- silhouette, lit along the top edge from wherever the sun is standing.
  BG.clouds = {}
  for i = 1, 9 do
    local cw, ch = rng:range(140, 430), rng:range(9, 26)
    BG.clouds[i] = {
      x = rng:range(-200, w + 200),
      y = rng:range(BG.horizon * 0.28, BG.horizon * 0.94),
      w = cw, h = ch,
      sp = rng:range(2.5, 9), a = rng:range(0.10, 0.30),
      seed = rng:int(1, 9999),
    }
  end

  -- three parallax ridges, far to near
  local step = 26
  BG.ridges = {}
  -- Aerial perspective: the far ridge is the haziest and the near one is nearly
  -- a silhouette, and each sits low enough that the land is three readable
  -- bands rather than one black slab.
  local specs = {
    { base = BG.horizon + h * 0.045, amp = h * 0.090, shade = 0.34, tilt = -h * 0.030 },
    { base = BG.horizon + h * 0.135, amp = h * 0.115, shade = 0.56, tilt =  h * 0.045 },
    { base = BG.horizon + h * 0.250, amp = h * 0.140, shade = 0.78, tilt = -h * 0.055 },
  }
  for i = 1, 3 do
    local sp = specs[i]
    local r = { base = sp.base, shade = sp.shade, step = step }
    r.pts = buildRidge(i * 11 + 3, sp.base, sp.amp, w, step, sp.tilt)
    BG.ridges[i] = r
  end

  BG.trees = {
    buildTrees(rng, BG.ridges[2], 30, 0.60, w),
    buildTrees(rng, BG.ridges[3], 22, 1.00, w),
  }

  -- foreground grass, on the very bottom edge
  BG.grass = {}
  for i = 1, 320 do
    BG.grass[i] = {
      x = rng:range(-20, w + 20),
      y = h - rng:range(0, h * 0.085),
      len = rng:range(14, 46), lean = rng:range(-0.55, 0.55),
      ph = rng:range(0, TAU),
    }
  end
end

------------------------------------------------------------------ backdrop draw
local function drawSky(t, a)
  local w, h = BG.w, BG.h
  local hz = BG.horizon
  -- night above, ember at the horizon: three bands so the ramp never posterises
  UI.vgrad(0, 0, w, hz * 0.52, P.ramp.rift[1], P.tod.night.fog, a, a)
  UI.vgrad(0, hz * 0.52, w, hz * 0.30, P.tod.night.fog, P.tod.dusk.fog, a, a * 0.92)
  UI.vgrad(0, hz * 0.82, w, hz * 0.18 + 2, P.tod.dusk.fog, P.ramp.ember[3], a * 0.92, a)
  -- the ground plane the ridges stand on. Nothing may ever show the clear
  -- colour between the horizon and the first crest.
  UI.vgrad(0, hz, w, h - hz, P.ramp.ember[3], P.tod.dusk.fog, a, a * 0.75)
end

local function drawStars(t, a)
  local st = BG.stars
  for i = 1, #st do
    local s = st[i]
    local tw = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * s.sp + s.ph))
    Draw.setColor(UI.c(P.ink, tw * a * 0.75))
    lg.circle("fill", s.x, s.y, s.r, 6)
  end
end

--- Two slow ribbons of light in the upper third. The one thing on the screen
--- that says "this world is not normal".
local function drawAurora(t, a)
  if a <= 0.01 then return end
  local w, h = BG.w, BG.h
  local bm, am = lg.getBlendMode()
  lg.setBlendMode("add", "alphamultiply")
  for band = 1, 2 do
    local col = band == 1 and P.accent or P.accentCool
    local ph = t * (0.09 + band * 0.035) + band * 2.2
    local yb = h * (0.15 + band * 0.075)
    local amp = h * (0.045 + band * 0.012)
    local segs = 30
    local px, pTop, pMid, pBot, pFade
    for i = 0, segs do
      local x = w * i / segs
      local u = i / segs
      local yy = yb + sin(u * 5.2 + ph * 3.1) * amp + sin(u * 2.1 - ph * 1.7) * amp * 0.6
      local hh = h * 0.09 * (0.4 + 0.6 * (0.5 + 0.5 * sin(u * 3.3 + ph * 2.3)))
      local fade = (1 - (2 * u - 1) ^ 2) ^ 1.3 * a * 0.16
      local top, bot = yy - hh, yy + hh * 0.45
      if px then
        -- upper half fades in, lower half fades out: a curtain, not a slab
        Draw.quad(px, pTop, x, top, x, yy, px, pMid,
                  UI.c(col, 0), UI.c(col, 0), UI.c(col, fade), UI.c(col, pFade))
        Draw.quad(px, pMid, x, yy, x, bot, px, pBot,
                  UI.c(col, pFade), UI.c(col, fade), UI.c(col, 0), UI.c(col, 0))
      end
      px, pTop, pMid, pBot, pFade = x, top, yy, bot, fade
    end
  end
  lg.setBlendMode(bm, am)
end

local function drawSun(t, a)
  local x, y, r = BG.sunX, BG.sunY + sin(t * 0.14) * 4, BG.sunR
  Draw.glow(x, y, r * 7.5, P.ramp.ember[3], 0.30 * a, 4)
  Draw.glow(x, y, r * 2.6, P.ramp.ember[4], 0.55 * a, 3)
  Draw.setColor(UI.mix(P.ramp.ember[4], P.white, 0.45, a))
  lg.circle("fill", x, y, r, 48)
  -- the horizon streak: the sun smeared along the haze. Soft in both axes, or
  -- it reads as a drawn rule across the middle of the picture.
  local bm, am = lg.getBlendMode()
  lg.setBlendMode("add", "alphamultiply")
  local hz, sp = BG.horizon, BG.h * 0.035
  local c = P.ramp.ember[4]
  for i = 1, 2 do
    local x0 = (i == 1) and (x - BG.w) or x
    local k1 = (i == 1) and 0 or 0.22 * a
    local k2 = (i == 1) and 0.22 * a or 0
    Draw.quad(x0, hz - sp, x0 + BG.w, hz - sp, x0 + BG.w, hz, x0, hz,
              UI.c(c, 0), UI.c(c, 0), UI.c(c, k2), UI.c(c, k1))
    Draw.quad(x0, hz, x0 + BG.w, hz, x0 + BG.w, hz + sp, x0, hz + sp,
              UI.c(c, k1), UI.c(c, k2), UI.c(c, 0), UI.c(c, 0))
  end
  lg.setBlendMode(bm, am)
end

local function drawClouds(t, a)
  local w = BG.w
  for i = 1, #BG.clouds do
    local c = BG.clouds[i]
    local x = (c.x + t * c.sp) % (w + 520) - 260
    local lit = U.saturate(1 - math.abs(x - BG.sunX) / (w * 0.45))
    local col = UI.mix(P.tod.dusk.fog, P.ramp.ember[4], lit * 0.7, c.a * a)
    Draw.setColor(col)
    -- One irregular silhouette, not a row of ellipses: overlapping lobes at
    -- cloud alpha stack into a visible chain of discs, and a single flat
    -- lozenge reads as a placeholder. A blob is one fill and one outline.
    Draw.blob(x, c.y, c.w * 0.5, 13, c.seed, 0.34, c.h / c.w, "fill")
    -- the top edge, catching the light: warmer, tighter, and lifted a little
    Draw.setColor(UI.mix(P.tod.dusk.fog, P.ramp.ember[4], lit * 0.9, c.a * a * 0.6))
    Draw.blob(x + c.w * 0.04, c.y - c.h * 0.30, c.w * 0.40, 11, c.seed + 7, 0.30,
              c.h / c.w * 0.9, "fill")
  end
end

--- A ridge, drawn as a strip of quads so it can carry a vertical gradient.
--- The haze band above the crest is what sells the depth: each layer sits in a
--- little pool of the layer behind it.
local function drawRidge(r, t, a, k)
  local pts = r.pts
  local h = BG.h
  local drop0 = (1 - k) * 40
  UI.vgrad(0, r.base - h * 0.10 + drop0, BG.w, h * 0.115,
           P.tod.dusk.fog, P.ramp.ember[3], 0, 0.20 * a * (1 - r.shade))
  local top = UI.mix(P.tod.dusk.fog, P.black, r.shade)
  local bot = UI.mix(P.tod.dusk.fog, P.black, min(1, r.shade + 0.16))
  local t1, t2, t3 = top[1], top[2], top[3]
  local b1, b2, b3 = bot[1], bot[2], bot[3]
  local drop = drop0
  for i = 1, #pts - 3, 2 do
    local x0, y0 = pts[i], pts[i + 1] + drop
    local x1, y1 = pts[i + 2], pts[i + 3] + drop
    Draw.quad(x0, y0, x1, y1, x1, h, x0, h,
              UI.rgba(t1, t2, t3, a), UI.rgba(t1, t2, t3, a),
              UI.rgba(b1, b2, b3, a), UI.rgba(b1, b2, b3, a))
  end
  -- rim light on the sun side of the crest
  for i = 1, #pts - 3, 2 do
    local x0, y0 = pts[i], pts[i + 1] + drop
    local x1, y1 = pts[i + 2], pts[i + 3] + drop
    local lit = U.saturate(1 - math.abs((x0 + x1) * 0.5 - BG.sunX) / (BG.w * 0.42))
    if lit > 0.01 and y1 < y0 then
      Draw.setColor(UI.mix(P.ramp.ember[4], P.ink, 0.2, lit * 0.55 * a))
      lg.setLineWidth(1.6)
      lg.line(x0, y0, x1, y1)
    end
  end
end

local function drawTreeRow(list, t, a, k, shade, rim)
  local drop = (1 - k) * 40
  for i = 1, #list do
    local tr = list[i]
    local sway = sin(t * 0.55 + tr.phase) * 0.045 * tr.amp
                 + sin(t * 1.31 + tr.phase * 1.7) * 0.018 * tr.amp
    local lean = tr.lean + sway
    local bx, by = tr.x, tr.y + drop
    local tx, ty = bx + lean * tr.h, by - tr.h
    local col = UI.mix(P.tod.dusk.fog, P.black, shade)
    local c1, c2, c3 = col[1], col[2], col[3]
    -- trunk
    Draw.setColor(UI.rgba(c1, c2, c3, a))
    lg.setLineWidth(max(1.5, tr.r * 0.15))
    lg.line(bx, by, tx, ty)
    -- canopy: three blobs stacked into a silhouette
    Draw.setColor(UI.rgba(c1, c2, c3, a))
    Draw.blob(tx, ty, tr.r, 11, tr.seed, 0.2, 0.86, "fill")
    Draw.blob(tx - tr.r * 0.62, ty + tr.r * 0.34, tr.r * 0.62, 9, tr.seed + 7, 0.24, 0.9, "fill")
    Draw.blob(tx + tr.r * 0.6, ty + tr.r * 0.28, tr.r * 0.66, 9, tr.seed + 13, 0.24, 0.9, "fill")
    if rim then
      -- rim light: the same canopy blob, nudged toward the sun, in warm ink.
      -- Only the sliver that pokes out reads, which is exactly the effect.
      local lit = U.saturate(1 - math.abs(tx - BG.sunX) / (BG.w * 0.62))
      if lit > 0.02 then
        local side = tx < BG.sunX and 1 or -1
        Draw.setColor(UI.mix(P.ramp.ember[4], P.tod.dusk.fog, 0.35,
                             lit * lit * 0.30 * a))
        Draw.blob(tx + side * 2.2, ty - 1.6, tr.r, 11, tr.seed, 0.2, 0.86, "fill")
        Draw.setColor(UI.rgba(c1, c2, c3, a))
        Draw.blob(tx, ty, tr.r, 11, tr.seed, 0.2, 0.86, "fill")
      end
    end
  end
end

local function drawGrass(t, a)
  local h = BG.h
  UI.vgrad(0, h * 0.80, BG.w, h * 0.20, P.black, P.black, 0, 0.55 * a)
  Draw.setColor(UI.mix(P.tod.dusk.fog, P.black, 0.94, a))
  lg.setLineWidth(1.8)
  for i = 1, #BG.grass do
    local g = BG.grass[i]
    local sw = sin(t * 1.1 + g.ph) * 0.2 + g.lean
    lg.line(g.x, g.y, g.x + sw * g.len, g.y - g.len)
  end
end

--- Volumetric-ish shafts falling out of the sun, additive and very faint.
---
--- These used to start at the sun's centre, sixteen pixels wide and at full
--- strength, which stamped a hard-edged trapezoid across the middle of the disc
--- -- the one thing on the title screen that read as a bug rather than a sky.
--- They now leave from the limb and are soft across their width as well as
--- along their length, which is what a shaft of light actually is.
local function drawShafts(t, a)
  if a <= 0.01 then return end
  local bm, am = lg.getBlendMode()
  lg.setBlendMode("add", "alphamultiply")
  local x, y, r = BG.sunX, BG.sunY, BG.sunR
  local c = P.ramp.ember[4]
  for i = 1, 5 do
    local ang = pi * 0.5 + (i - 3) * 0.10 + sin(t * 0.11 + i) * 0.02
    local len = BG.h * 0.34
    local ca, sa = cos(ang), sin(ang)
    -- leave from the limb of the disc, not from its centre
    local x0, y0 = x + ca * r * 0.82, y + sa * r * 0.82
    local ex, ey = x + ca * len, y + sa * len
    local nx, ny = -sa, ca
    local k = (0.055 - math.abs(i - 3) * 0.013) * a
    -- two quads per shaft, mirrored about the axis, each fading to nothing at
    -- its outer edge: the seam falls on the bright centre line where it cannot
    -- be seen, instead of on the silhouette where it could
    local w0, w1 = r * 0.16, 16 + i * 6
    for side = -1, 1, 2 do
      Draw.quad(x0, y0, x0 + nx * w0 * side, y0 + ny * w0 * side,
                ex + nx * w1 * side, ey + ny * w1 * side, ex, ey,
                UI.c(c, k), UI.c(c, 0), UI.c(c, 0), UI.c(c, k * 0.25))
    end
  end
  lg.setBlendMode(bm, am)
end

------------------------------------------------------------------------ menu
local MENU = {}
local PROMPTS     = { { "confirm", "SELECT" }, { "back", "QUIT" } }
local PROMPTS_WEB = { { "confirm", "SELECT" } }
local VFX_FIRE   = { area = 1.7, rate = 0.55 }
local VFX_POLLEN = { area = 1.5, rate = 0.5 }

-- One reused option table: the menu is redrawn every frame and must not churn.
local BOPT = { size = UI.ts.h3 }

local function rebuildMenu()
  for i = #MENU, 1, -1 do MENU[i] = nil end
  -- No CONTINUE row: runs are not resumable yet, and a menu item that does not
  -- do what it says is worse than one that is missing. The best-run strip in the
  -- corner is where a returning player is told the game remembers them.
  MENU[#MENU + 1] = { id = "begin", label = "BEGIN",
                      sub = "Seven cycles. One island. No help coming." }
  MENU[#MENU + 1] = { id = "options", label = "OPTIONS" }
  -- There is no quitting a browser tab from inside it, and a row that does
  -- nothing when you press it is the cheapest thing a menu can do.
  if not S.web then MENU[#MENU + 1] = { id = "quit", label = "QUIT" } end
end

--------------------------------------------------------------------- lifecycle
function S:enter()
  -- The web shell passes --BOTS_WEB=1; love.system.getOS() is not reliable
  -- under love.js, so the page tells the game where it is running rather than
  -- the game trying to guess.
  S.web = (_G.BOTS_CFG and _G.BOTS_CFG("BOTS_WEB")) ~= nil
     or (love.system and love.system.getOS() == "Web")
  self.t = 0
  self.ctx = UI.context({ accent = P.accent })
  self.leaving = false
  self.parX, self.parY = 0, 0
  Settings.load()
  Settings.applyJuice(require("src.engine.juice"))
  Settings.applyInput(Input)
  rebuildMenu()
  build(lg.getDimensions())
  if VFX.init then VFX.init() end
  if Music.setState then Music.setState("title") end
end

function S:resume()
  rebuildMenu()          -- a finished run may have added CONTINUE while we were away
end

function S:resize(w, h)
  BG.built = false
  build(w, h)
end

local function choose(self, id)
  if self.leaving then return end
  if id == "options" then
    Screen.push(require("src.scenes.options"))
  elseif id == "quit" then
    self.leaving = true
    Screen.transition(0.4, function() love.event.quit() end, "fade")
  else
    self.leaving = true
    local continued = (id == "continue")
    Screen.transition(0.65, function()
      Screen.switch(require("src.scenes.game"), { continueRun = continued })
    end, "iris")
  end
end

-- The widget pass runs once, inside `draw`: an immediate-mode context wants a
-- single registration per frame, and drawing is the only place the rows are
-- laid out. `update` opens the frame and consumes whatever the last one chose.
function S:update(dt, realDt)
  realDt = realDt or dt
  self.t = self.t + realDt
  build(lg.getDimensions())
  if VFX.update then VFX.update(realDt) end
  if Music.update then Music.update(realDt) end

  local top = (Screen.current() == self)
  self.top = top
  if not top then return end

  if self.pending then
    local id = self.pending
    self.pending = nil
    choose(self, id)
    return
  end

  -- a whisper of parallax, so the cover is never quite still
  local mx, my = love.mouse.getPosition()
  self.parX = U.damp(self.parX, (mx / BG.w - 0.5) * 14, 4, realDt)
  self.parY = U.damp(self.parY, (my / BG.h - 0.5) * 8, 4, realDt)

  self.ctx:beginFrame(realDt)
end

------------------------------------------------------------------------ layout
--- One pass that both registers and draws the menu column. `interactive` is
--- false during the pure-draw call so the context is only fed once a frame.
function S:layout(interactive)
  local w, h = BG.w, BG.h
  local t = self.t
  local x0 = floor(max(UI.pad * 2, w * 0.065) / UI.u) * UI.u
  local logoSize = min(UI.ts.giant, floor(w * 0.075 / 2) * 2)
  local logoY = floor(h * 0.225 / UI.u) * UI.u

  UI.o.tracking = 0.02
  local logoW = max(Text.measure("BOTS", logoSize, UI.o), 320)
  UI.o.tracking = nil
  local colW = max(logoW, 336)

  local rowH = 64
  local gap = UI.u
  -- The browser build runs at whatever aspect the window is, and a phone in
  -- landscape is nearly 2.2:1. Anchor the column to the bottom of the screen so
  -- it can never grow down through the prompt row, and let it ride up under the
  -- logo when there is room.
  local menuH = #MENU * (rowH + gap) - gap
  local bottomLimit = h - UI.pad * 2 - 46 - menuH
  local menuY = min(logoY + logoSize + 160, bottomLimit)
  menuY = max(menuY, logoY + logoSize + 40)
  -- if it still does not fit, tighten the rows rather than overlap
  if menuY + menuH > h - UI.pad * 2 - 40 then
    rowH = max(40, floor((h - UI.pad * 2 - 40 - menuY - (#MENU - 1) * gap) / #MENU))
    menuH = #MENU * (rowH + gap) - gap
  end

  if interactive then
    local ctx = self.ctx
    -- a wash under the column: the rows cross the brightest band of the sky and
    -- a plate at 34% black is not enough on its own
    local mh = #MENU * (rowH + gap)
    Draw.softShadow(x0 + colW * 0.40, menuY + mh * 0.5 - gap * 0.5,
                    colW * 1.30, mh * 1.05, 0.72)
    Draw.softShadow(x0 + colW * 0.45, menuY + mh * 0.5 - gap * 0.5,
                    colW * 0.80, mh * 0.72, 0.55)
    for i = 1, #MENU do
      local m = MENU[i]
      local k = UI.stagger(t, i, SEQ.menu, SEQ.menuStep, SEQ.menuDur)
      BOPT.sub, BOPT.badge = m.sub, m.badge
      BOPT.alpha = k
      BOPT.slide = (1 - k) * -20
      local act = UI.button(ctx, m.id, x0, menuY + (i - 1) * (rowH + gap),
                            colW, rowH, m.label, BOPT)
      if act then self.pending = m.id end
    end
    return
  end

  return x0, logoY, logoSize, logoW, colW, menuY, rowH, gap
end

--------------------------------------------------------------------- drawing
function S:drawBackdrop()
  local t = self.t
  local skyK = U.ease.outQuad(U.saturate((t - SEQ.sky) / SEQ.skyDur))
  local w, h = BG.w, BG.h

  lg.clear(P.black[1], P.black[2], P.black[3], 1)

  lg.push()
  lg.translate(-self.parX * 0.35, -self.parY * 0.35)
  drawSky(t, skyK)
  drawStars(t, skyK * U.saturate((t - 0.2) / 1.4))
  drawAurora(t, skyK)
  drawSun(t, skyK)
  drawClouds(t, skyK)
  drawShafts(t, skyK * 0.9)
  lg.pop()

  for i = 1, 3 do
    local k = UI.stagger(t, i, SEQ.ridge, SEQ.ridgeStep, SEQ.ridgeDur, U.ease.outQuint)
    if k > 0.001 then
      lg.push()
      lg.translate(-self.parX * (0.5 + i * 0.35), -self.parY * (0.2 + i * 0.2))
      drawRidge(BG.ridges[i], t, k, k)
      if i == 2 then drawTreeRow(BG.trees[1], t, k, k, 0.72, false) end
      if i == 3 then drawTreeRow(BG.trees[2], t, k, k, 0.88, true) end
      lg.pop()
    end
  end

  local gk = UI.stagger(t, 4, SEQ.ridge, SEQ.ridgeStep, SEQ.ridgeDur, U.ease.outQuint)
  if gk > 0.001 then
    lg.push()
    lg.translate(-self.parX * 1.6, -self.parY * 0.8)
    drawGrass(t, gk)
    lg.pop()
  end

  -- fireflies over the near treeline, pollen in the sun
  if VFX.stream and skyK > 0.5 then
    VFX.stream("fireflies", w * 0.5, h * 0.80, 1 / 60, VFX_FIRE)
    VFX.stream("pollen", BG.sunX, BG.horizon + h * 0.06, 1 / 60, VFX_POLLEN)
  end
  if VFX.drawAll then VFX.drawAll() end

  -- The type column needs a floor to sit on: a broad wash from the left edge,
  -- plus a second, tighter one weighted to the rows themselves so the menu
  -- plates never sit half on sky and half on shadow.
  UI.hgrad(0, 0, w * 0.55, h, P.black, P.black, 0.60 * skyK, 0)
  UI.hgrad(0, h * 0.18, w * 0.46, h * 0.72, P.black, P.black, 0.34 * skyK, 0)
  UI.vignette(0.5 * skyK)
end

function S:drawLogo()
  local t = self.t
  local x0, logoY, logoSize, logoW, colW = self:layout(false)

  -- BOTS: assembles by pulling its tracking in from wide
  local k = UI.stagger(t, 1, SEQ.logo, 0, SEQ.logoDur, U.ease.outExpo)
  if k > 0.001 then
    local tr = U.lerp(0.42, 0.02, k)
    local a = U.saturate(k * 1.6)
    UI.o.glow = logoSize * 0.035 * k       -- wide strokes spike at the miters
    UI.o.shadow = logoSize * 0.045
    UI.text("BOTS", x0, logoY + (1 - k) * 10, logoSize, P.ink, "left", a, tr, UI.o)
  end

  -- SAVE US ALL: condensed to exactly the logo's width, so the column locks
  local k2 = UI.stagger(t, 1, SEQ.say, 0, 0.6, U.ease.outExpo)
  if k2 > 0.001 then
    local y = logoY + logoSize + 22
    UI.o.maxWidth = logoW
    UI.text("SAVE US ALL", x0 + (1 - k2) * -12, y, UI.ts.h2, P.inkDim, "left",
            U.saturate(k2 * 1.4), 0.3, UI.o)
  end

  -- the tag: accent rule, then the subtitle
  local k3 = UI.stagger(t, 1, SEQ.tag, 0, 0.5)
  if k3 > 0.001 then
    local y = logoY + logoSize + 84
    local rw = colW * k3
    Draw.setColor(UI.c(P.accent, 0.9 * k3))
    lg.setLineWidth(2)
    lg.line(x0, y, x0 + rw, y)
    if k3 > 0.45 then
      local a = U.saturate((k3 - 0.45) / 0.5)
      UI.caption("REFOREST", x0, y + 14, UI.ts.label, UI.c(P.accent, a), "left")
    end
  end
end

local BEST_LABEL = { "CYCLES", "FOREST", "OXYGEN" }

function S:drawFooter()
  local t = self.t
  local w, h = BG.w, BG.h
  local k = UI.stagger(t, 1, SEQ.foot, 0, 0.6)
  if k <= 0.002 then return end
  local a = k
  local x0 = floor(max(UI.pad * 2, w * 0.065) / UI.u) * UI.u
  local footY = h - UI.pad - 32

  -- device prompts, under the menu column
  -- A wash under the footer baseline. The right end of it crosses the lit
  -- horizon, where inkFaint measured 1.8:1 -- unreadable, and this is the line
  -- that tells a returning player the game remembered their best run.
  Draw.softShadow(w * 0.5, footY + 22, w * 0.62, 74, 0.45 * a)

  UI.promptRow(x0, footY, S.web and PROMPTS_WEB or PROMPTS, UI.ts.micro, P.inkDim,
               0.8 * a, "left")
  UI.caption(Input.schemeName():upper() .. " DETECTED", x0, footY + 26, UI.ts.micro,
             UI.c(P.inkDim, 0.8 * a), "left", nil, 1)

  -- best run, right-anchored, one cell per number so the numerals line up
  local cycles, trees, o2, runs = Settings.best()
  if runs <= 0 then
    UI.caption("NO RUN RECORDED", w - UI.pad, footY + 26, UI.ts.micro,
               UI.c(P.inkDim, 0.7 * a), "right", nil, 1)
    return
  end
  local cellW = 112
  local bx = w - UI.pad - cellW * 3
  UI.caption("BEST RUN", w - UI.pad, footY - 30, UI.ts.micro,
             UI.c(P.inkDim, 0.9 * a), "right", nil, 1)
  UI.rule(bx, footY - 14, cellW * 3, P.ink, 0.12 * a, P.accent)
  local vals = { tostring(floor(cycles)), tostring(floor(trees)),
                 Text.format(o2, { decimals = 1, suffix = "%" }) }
  for i = 1, 3 do
    local kk = UI.stagger(t, i, SEQ.foot + 0.12, 0.07, 0.4)
    UI.stat(bx + (i - 1) * cellW, footY - 2, BEST_LABEL[i], vals[i], UI.ts.h4,
            i == 3 and P.o2 or P.ink, "left", a * kk)
  end
end

function S:draw()
  local prevLW = lg.getLineWidth()
  self:drawBackdrop()
  self:drawLogo()
  self:layout(true)          -- registers and draws the menu in one pass
  self:drawFooter()
  if self.top then self.ctx:endFrame() end
  lg.setLineWidth(prevLW)
  lg.setColor(1, 1, 1, 1)
end

function S:keypressed(k)
  if k == "escape" and not S.web then
    self.ctx:setFocus("quit")
  end
end

return S
