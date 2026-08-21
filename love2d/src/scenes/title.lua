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
local cos, sin, pi = math.cos, math.sin, math.pi
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
      h = rng:range(34, 62) * scale,
      r = rng:range(17, 27) * scale,
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

  BG.horizon = floor(h * 0.615)
  BG.sunX = floor(w * 0.705)
  BG.sunY = BG.horizon - floor(h * 0.045)
  BG.sunR = floor(min(w, h) * 0.062)

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

  -- clouds: flat lozenges that drift and catch the sun
  BG.clouds = {}
  for i = 1, 9 do
    BG.clouds[i] = {
      x = rng:range(-200, w + 200),
      y = rng:range(BG.horizon * 0.28, BG.horizon * 0.94),
      w = rng:range(120, 420), h = rng:range(6, 17),
      sp = rng:range(2.5, 9), a = rng:range(0.10, 0.30),
      seed = rng:int(1, 9999),
    }
  end

  -- three parallax ridges, far to near
  local step = 26
  BG.ridges = {}
  local specs = {
    { base = BG.horizon + 8,  amp = h * 0.075, shade = 0.42, tilt = -h * 0.02 },
    { base = BG.horizon + 56, amp = h * 0.105, shade = 0.66, tilt = h * 0.03 },
    { base = BG.horizon + 128, amp = h * 0.13, shade = 0.86, tilt = -h * 0.04 },
  }
  for i = 1, 3 do
    local sp = specs[i]
    local r = { base = sp.base, shade = sp.shade, step = step }
    r.pts = buildRidge(i * 11 + 3, sp.base, sp.amp, w, step, sp.tilt)
    BG.ridges[i] = r
  end

  BG.trees = {
    buildTrees(rng, BG.ridges[2], 26, 0.62, w),
    buildTrees(rng, BG.ridges[3], 20, 1.05, w),
  }

  -- foreground grass, on the very bottom edge
  BG.grass = {}
  for i = 1, 170 do
    BG.grass[i] = {
      x = rng:range(-20, w + 20),
      y = h - rng:range(0, h * 0.055),
      len = rng:range(10, 30), lean = rng:range(-0.5, 0.5),
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
    local yb = h * (0.13 + band * 0.075)
    local amp = h * (0.045 + band * 0.012)
    local segs = 26
    local prevX, prevTop, prevBot
    for i = 0, segs do
      local x = w * i / segs
      local u = i / segs
      local yy = yb + sin(u * 5.2 + ph * 3.1) * amp + sin(u * 2.1 - ph * 1.7) * amp * 0.6
      local hh = h * 0.085 * (0.4 + 0.6 * (0.5 + 0.5 * sin(u * 3.3 + ph * 2.3)))
      local fade = (1 - (2 * u - 1) ^ 2) * a * 0.16
      if prevX then
        Draw.quad(prevX, prevTop, x, yy - hh, x, yy, prevX, prevBot,
                  UI.c(col, 0), UI.c(col, 0), UI.c(col, fade), UI.c(col, fade))
      end
      prevX, prevTop, prevBot = x, yy - hh, yy
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
  -- the horizon streak: the sun smeared along the haze
  local bm, am = lg.getBlendMode()
  lg.setBlendMode("add", "alphamultiply")
  UI.hgrad(x - BG.w, BG.horizon - 5, BG.w, 10, P.ramp.ember[4], P.ramp.ember[4], 0, 0.30 * a)
  UI.hgrad(x, BG.horizon - 5, BG.w, 10, P.ramp.ember[4], P.ramp.ember[4], 0.30 * a, 0)
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
    lg.ellipse("fill", x, c.y, c.w * 0.5, c.h * 0.5, 20)
    Draw.setColor(UI.mix(P.tod.dusk.fog, P.ramp.ember[4], lit * 0.9, c.a * a * 0.55))
    lg.ellipse("fill", x + c.w * 0.14, c.y - c.h * 0.3, c.w * 0.3, c.h * 0.4, 16)
  end
end

--- A ridge, drawn as a strip of quads so it can carry a vertical gradient.
local function drawRidge(r, t, a, k)
  local pts = r.pts
  local h = BG.h
  local top = UI.mix(P.ramp.rock[1], P.black, r.shade)
  local bot = UI.mix(P.ramp.rock[1], P.black, min(1, r.shade + 0.16))
  local t1, t2, t3 = top[1], top[2], top[3]
  local b1, b2, b3 = bot[1], bot[2], bot[3]
  local drop = (1 - k) * 40
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
      Draw.setColor(UI.mix(P.ramp.ember[4], P.ink, 0.2, lit * 0.5 * a * (1 - r.shade)))
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
    local col = UI.mix(P.ramp.leaf[1], P.black, shade)
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
      local lit = U.saturate(1 - math.abs(tx - BG.sunX) / (BG.w * 0.5))
      if lit > 0.02 then
        Draw.setColor(UI.mix(P.ramp.ember[4], P.ramp.leafHi[4], 0.35, lit * 0.35 * a))
        lg.setLineWidth(1.4)
        Draw.blob(tx + tr.r * 0.1, ty - tr.r * 0.06, tr.r * 1.0, 11, tr.seed, 0.2, 0.86, "line")
      end
    end
  end
end

local function drawGrass(t, a)
  Draw.setColor(UI.mix(P.ramp.leaf[1], P.black, 0.9, a))
  lg.setLineWidth(1.6)
  for i = 1, #BG.grass do
    local g = BG.grass[i]
    local sw = sin(t * 1.1 + g.ph) * 0.2 + g.lean
    lg.line(g.x, g.y, g.x + sw * g.len, g.y - g.len)
  end
end

--- Volumetric-ish shafts falling out of the sun, additive and very faint.
local function drawShafts(t, a)
  if a <= 0.01 then return end
  local bm, am = lg.getBlendMode()
  lg.setBlendMode("add", "alphamultiply")
  local x, y = BG.sunX, BG.sunY
  for i = 1, 5 do
    local ang = pi * 0.5 + (i - 3) * 0.14 + sin(t * 0.11 + i) * 0.02
    local len = BG.h * 0.7
    local wdt = 22 + i * 7
    local ex, ey = x + cos(ang) * len, y + sin(ang) * len
    local nx, ny = -sin(ang), cos(ang)
    local k = (0.10 - math.abs(i - 3) * 0.022) * a
    Draw.quad(x - nx * 8, y - ny * 8, x + nx * 8, y + ny * 8,
              ex + nx * wdt, ey + ny * wdt, ex - nx * wdt, ey - ny * wdt,
              UI.c(P.ramp.ember[4], k), UI.c(P.ramp.ember[4], k),
              UI.c(P.ramp.ember[4], 0), UI.c(P.ramp.ember[4], 0))
  end
  lg.setBlendMode(bm, am)
end

------------------------------------------------------------------------ menu
local MENU = {}
local PROMPTS_KB  = { { "confirm", "SELECT" }, { "back", "QUIT" } }

local function rebuildMenu()
  for i = #MENU, 1, -1 do MENU[i] = nil end
  if Settings.hasRun() then
    local c = select(1, Settings.best())
    MENU[#MENU + 1] = { id = "continue", label = "CONTINUE",
                        sub = "Return to the island.", badge = "CYCLE " .. tostring(c) }
  end
  MENU[#MENU + 1] = { id = "begin", label = "BEGIN",
                      sub = "Seven cycles. One island. No help coming." }
  MENU[#MENU + 1] = { id = "options", label = "OPTIONS" }
  MENU[#MENU + 1] = { id = "quit", label = "QUIT" }
end

--------------------------------------------------------------------- lifecycle
function S:enter()
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
  -- coming back from Options: the roster may have changed, the layout has not
  rebuildMenu()
  self.ctx.focusId = self.ctx.focusId or nil
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

function S:update(dt, realDt)
  realDt = realDt or dt
  self.t = self.t + realDt
  build(lg.getDimensions())
  if VFX.update then VFX.update(realDt) end
  if Music.update then Music.update(realDt) end

  local top = (Screen.current() == self)
  local ctx = self.ctx
  ctx.enabled = top
  if not top then return end

  -- a whisper of parallax, so the cover is never quite still
  local mx, my = love.mouse.getPosition()
  local w, h = BG.w, BG.h
  self.parX = U.damp(self.parX, (mx / w - 0.5) * 14, 4, realDt)
  self.parY = U.damp(self.parY, (my / h - 0.5) * 8, 4, realDt)

  ctx:beginFrame(realDt)
  self.pending = nil
  self:layout(true)
  ctx:endFrame()
  if self.pending then choose(self, self.pending) end
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

  local menuY = logoY + logoSize + 152
  local rowH = 56
  local gap = UI.u

  if interactive then
    local ctx = self.ctx
    for i = 1, #MENU do
      local m = MENU[i]
      local k = UI.stagger(t, i, SEQ.menu, SEQ.menuStep, SEQ.menuDur)
      local y = menuY + (i - 1) * (rowH + gap)
      if k > 0.5 then
        local act = UI.button(ctx, m.id, x0, y, colW, rowH, m.label,
                              { sub = m.sub, badge = m.badge, size = UI.ts.h3,
                                danger = m.id == "quit" and false or nil })
        if act then self.pending = m.id end
      end
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
    VFX.stream("fireflies", w * 0.5, h * 0.80, 1 / 60, VFXOPT_F)
    VFX.stream("pollen", BG.sunX, BG.horizon + h * 0.06, 1 / 60, VFXOPT_P)
  end
  if VFX.drawAll then VFX.drawAll() end

  -- the type column needs a floor to sit on
  UI.hgrad(0, 0, w * 0.46, h, P.black, P.black, 0.52 * skyK, 0)
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
    UI.o.glow = logoSize * 0.16 * k
    UI.o.shadow = logoSize * 0.05
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
      UI.caption("SEVEN CYCLES", x0 + colW, y + 16, UI.ts.micro,
                 UI.c(P.inkFaint, 0.8 * a), "right")
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
  UI.promptRow(x0, footY, PROMPTS_KB, UI.ts.micro, P.inkDim, 0.8 * a, "left")
  UI.caption(Input.schemeName():upper() .. " DETECTED", x0, footY + 26, UI.ts.micro,
             UI.c(P.inkFaint, 0.55 * a), "left")

  -- best run, right-anchored, one cell per number so the numerals line up
  local cycles, trees, o2, runs = Settings.best()
  if runs <= 0 then
    UI.caption("NO RUN RECORDED", w - UI.pad, footY + 26, UI.ts.micro,
               UI.c(P.inkFaint, 0.5 * a), "right")
    return
  end
  local cellW = 112
  local bx = w - UI.pad - cellW * 3
  UI.caption("BEST RUN", w - UI.pad, footY - 30, UI.ts.micro, UI.c(P.inkFaint, 0.8 * a), "right")
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
  self:layout(true)          -- menu rows draw inside the same pass
  self:drawFooter()
  lg.setLineWidth(prevLW)
  lg.setColor(1, 1, 1, 1)
end

function S:keypressed(k)
  if k == "escape" then
    self.ctx:setFocus("quit")
  end
end

return S
