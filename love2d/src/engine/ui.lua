-- The widget layer.
--
-- One focus model for four devices. Mouse, keyboard, gamepad and touch all
-- drive the same `context`: widgets register a rect each frame, the context
-- resolves navigation geometrically at the end of the frame, and every widget
-- keeps its own animation state keyed by id -- so a caller never has to hold a
-- `hoverAmount` or a `pressT` anywhere.
--
-- Style rules this file enforces so the screens do not have to:
--   * 8 px grid (UI.u), 24 px safe inset (UI.pad)
--   * a fixed display type scale (UI.ts)
--   * one accent colour per context (ctx.accent)
--   * nothing snaps: hover, focus, press and value are all damped
--   * focus is drawn as machined corner brackets, matching the typeface brief
--
-- Allocation: after the first frame the kit allocates nothing. Colours come
-- from a ring of scratch tables (UI.c / UI.mix / UI.rgba) and item records are
-- recycled, which is what lets the HUD build on top of it.
local U     = require("src.core.util")
local P     = require("src.engine.palette")
local Draw  = require("src.engine.draw")
local Text  = require("src.engine.text")
local Input = require("src.engine.input")
local Opt   = require("src.core.optional")
local Audio = Opt.require("src.engine.audio")

local lg = love.graphics
local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local cos, sin = math.cos, math.sin

local UI = {}

----------------------------------------------------------------------- tokens
UI.u    = 8                       -- grid unit; every offset in the game is a multiple
UI.pad  = 24                      -- screen safe inset (3u)
UI.r    = 6                       -- default corner radius
UI.tap  = 44                      -- minimum touch target

--- Display-face size ramp. Named, so screens never invent a size.
UI.ts = {
  micro = 10, tiny = 12, small = 14, label = 17,
  h4 = 21, h3 = 27, h2 = 36, h1 = 50, mega = 74, giant = 108,
}

--- Body-copy ramp (LOVE's built-in face).
UI.bs = { micro = 11, small = 13, base = 15, lead = 18 }

------------------------------------------------------------------- scratch rgba
-- A ring of colour tables. Every helper returns one of these, so drawing a
-- tinted, faded, mixed colour costs nothing per frame. Never hold on to one.
local SCN = 48
local SC = {}
for i = 1, SCN do SC[i] = { 0, 0, 0, 1 } end
local SCI = 0
local function scratch()
  SCI = SCI % SCN + 1
  return SC[SCI]
end

--- `c` at alpha `a` (default: the colour's own alpha).
function UI.c(c, a)
  local t = scratch()
  t[1], t[2], t[3] = c[1], c[2], c[3]
  t[4] = a == nil and (c[4] or 1) or a
  return t
end

function UI.rgba(r, g, b, a)
  local t = scratch()
  t[1], t[2], t[3], t[4] = r, g, b, a or 1
  return t
end

--- Linear blend of two palette colours.
function UI.mix(a, b, k, alpha)
  local t = scratch()
  t[1] = a[1] + (b[1] - a[1]) * k
  t[2] = a[2] + (b[2] - a[2]) * k
  t[3] = a[3] + (b[3] - a[3]) * k
  t[4] = alpha == nil and ((a[4] or 1) + ((b[4] or 1) - (a[4] or 1)) * k) or alpha
  return t
end

function UI.lighten(c, k, a) return UI.mix(c, P.white, k, a) end
function UI.darken(c, k, a)  return UI.mix(c, P.black, k, a) end

------------------------------------------------------------------ shared opts
-- Reused option tables for Text: mutate, pass, forget. Text reads them
-- synchronously, so this is safe and it keeps the per-frame allocation at zero.
local TO  = { color = nil, align = "left", size = nil, snap = true }
local TO2 = { color = nil, align = "left", tracking = 0.14, snap = true }
local TOB = { color = nil, align = "left", width = nil }

--- Display type. `o` fields: color, alpha, align, width, tracking, weight,
--- maxWidth, glow, shadow, snap. Returns rendered width.
function UI.text(str, x, y, size, color, align, alpha, tracking, opts)
  local o = opts or TO
  o.color    = color or P.ink
  o.align    = align or "left"
  o.alpha    = alpha
  o.tracking = tracking
  o.snap     = true
  local w = Text.display(str, x, y, size, o)
  o.glow, o.shadow, o.width, o.maxWidth, o.weight = nil, nil, nil, nil, nil
  return w
end

--- Wide-tracked micro label: the game's caption voice.
function UI.caption(str, x, y, size, color, align, alpha)
  TO2.color = color or P.inkFaint
  TO2.align = align or "left"
  TO2.alpha = alpha
  TO2.tracking = 0.2
  return Text.display(str, x, y, size or UI.ts.micro, TO2)
end

--- Body copy. Returns height drawn.
function UI.body(str, x, y, size, color, width, align, alpha)
  TOB.color = color or P.inkDim
  TOB.width = width
  TOB.align = align
  TOB.alpha = alpha
  return Text.body(str, x, y, size or UI.bs.base, TOB)
end

----------------------------------------------------------------------- shapes
--- Vertical gradient rect with no allocation (Draw.linearGradient builds four
--- colour tables per call, which is fine once and wrong sixty times a second).
function UI.vgrad(x, y, w, h, c1, c2, a1, a2)
  local top = UI.c(c1, a1)
  local t1, t2, t3, t4 = top[1], top[2], top[3], top[4]
  local bot = UI.c(c2, a2)
  Draw.quad(x, y, x + w, y, x + w, y + h, x, y + h,
            UI.rgba(t1, t2, t3, t4), UI.rgba(t1, t2, t3, t4), bot, UI.c(c2, a2))
end

function UI.hgrad(x, y, w, h, c1, c2, a1, a2)
  local l = UI.c(c1, a1)
  local l1, l2, l3, l4 = l[1], l[2], l[3], l[4]
  Draw.quad(x, y, x + w, y, x + w, y + h, x, y + h,
            UI.rgba(l1, l2, l3, l4), UI.c(c2, a2), UI.c(c2, a2), UI.rgba(l1, l2, l3, l4))
end

--- The kit's surface: a dark pane with a hairline edge and a top sheen.
function UI.panel(x, y, w, h, alpha, radius, edge, edgeAlpha)
  alpha = alpha or 0.62
  radius = radius or UI.r
  Draw.setColor(UI.c(P.black, alpha))
  Draw.roundRect("fill", x, y, w, h, radius)
  UI.vgrad(x + radius * 0.5, y + 1, w - radius, min(h * 0.5, 42),
           P.ink, P.ink, 0.035 * (alpha > 0.2 and 1 or 0), 0)
  lg.setLineWidth(1)
  Draw.setColor(UI.c(edge or P.ink, edgeAlpha or 0.13))
  Draw.roundRect("line", x + 0.5, y + 0.5, w - 1, h - 1, radius)
end

--- Machined corner brackets. The focus ring, and the frame around anything
--- that wants to look like instrumentation.
function UI.brackets(x, y, w, h, len, color, alpha, width, inset)
  inset = inset or 0
  x, y, w, h = x - inset, y - inset, w + inset * 2, h + inset * 2
  len = min(len, min(w, h) * 0.45)
  Draw.setColor(UI.c(color, alpha))
  lg.setLineWidth(width or 2)
  local corners = 4
  for i = 1, corners do
    local cx = (i == 1 or i == 4) and x or x + w
    local cy = (i <= 2) and y or y + h
    local sx = (i == 1 or i == 4) and 1 or -1
    local sy = (i <= 2) and 1 or -1
    lg.line(cx, cy + sy * len, cx, cy)
    lg.line(cx, cy, cx + sx * len, cy)
  end
end

--- A thin rule with a bright nub at one end. Used to break sections.
function UI.rule(x, y, w, color, alpha, nub)
  Draw.setColor(UI.c(color or P.ink, alpha or 0.14))
  lg.setLineWidth(1)
  lg.line(x, y + 0.5, x + w, y + 0.5)
  if nub then
    Draw.setColor(UI.c(nub, 0.9))
    lg.setLineWidth(2)
    lg.line(x, y + 0.5, x + min(28, w * 0.3), y + 0.5)
  end
end

--- Horizontal meter. `t` 0..1. Draws track, fill, a leading tick and optional
--- milestone ticks. The shape vocabulary the HUD and Options both use.
function UI.meter(x, y, w, h, t, color, trackAlpha, glow)
  t = U.saturate(t)
  Draw.setColor(UI.c(P.black, trackAlpha or 0.5))
  Draw.roundRect("fill", x, y, w, h, h * 0.5)
  local fw = w * t
  if fw > h * 0.6 then
    Draw.setColor(UI.c(color, 0.9))
    Draw.roundRect("fill", x, y, fw, h, h * 0.5)
    if glow then
      Draw.glow(x + fw, y + h * 0.5, h * 2.6, color, 0.5 * glow, 3)
    end
  end
end

--- Rarity / status pip row.
function UI.pips(x, y, n, filled, r, gap, color, dim)
  for i = 1, n do
    local px = x + (i - 1) * (r * 2 + gap)
    Draw.setColor(UI.c(i <= filled and color or (dim or P.inkFaint), i <= filled and 1 or 0.35))
    lg.circle("fill", px + r, y + r, r, 10)
  end
end

-- Captions are drawn at 0.2 tracking, so anything that measures one has to ask
-- for the same tracking or it comes back short and the next thing collides.
local TRK = { tracking = 0.2 }
function UI.captionWidth(str, size) return Text.measure(str, size, TRK) end

--- A key/button prompt: the glyph in a chip, then the label.
--- Returns the total width consumed.
function UI.prompt(x, y, action, label, size, color, alpha, align)
  size = size or UI.ts.tiny
  color = color or P.inkDim
  alpha = alpha or 1
  local g = Input.glyph(action)
  local gw = Text.measure(g, size, nil)
  local boxW = max(gw + 14, size + 14)
  local boxH = size + 12
  local lw = label and Text.measure(label, size, TRK) or 0
  local total = boxW + (label and (lw + 10) or 0)
  if align == "right" then x = x - total elseif align == "center" then x = x - total * 0.5 end

  Draw.setColor(UI.c(P.ink, 0.09 * alpha))
  Draw.roundRect("fill", x, y - 6, boxW, boxH, 3)
  Draw.setColor(UI.c(color, 0.34 * alpha))
  lg.setLineWidth(1)
  Draw.roundRect("line", x + 0.5, y - 5.5, boxW - 1, boxH - 1, 3)
  UI.text(g, x + boxW * 0.5, y, size, color, "center", alpha)
  if label then UI.caption(label, x + boxW + 10, y, size, color, "left", alpha * 0.9) end
  return total
end

------------------------------------------------------------------------ context
local Ctx = {}
Ctx.__index = Ctx

local NAV_DELAY, NAV_REPEAT = 0.36, 0.11

function UI.context(opts)
  local c = setmetatable({}, Ctx)
  c.st       = {}
  c.items    = {}
  c.n        = 0
  c.time     = 0
  c.dt       = 1 / 60
  c.focusId  = nil
  c.accent   = (opts and opts.accent) or P.accent
  c.navX, c.navY = 0, 0
  c.navHeld  = 0
  c.mx, c.my = 0, 0
  c.pmx, c.pmy = -1, -1
  c.mouseMoved = false
  c.mDown, c.mPressed, c.mReleased = false, false, false
  c.confirmPressed, c.backPressed = false, false
  c.sound    = (opts and opts.sound) ~= false
  c.wrap     = (opts and opts.wrap) ~= false
  c.enabled  = true
  return c
end

function Ctx:state(id)
  local s = self.st[id]
  if not s then
    s = { hover = 0, focus = 0, press = 0, glow = 0, v = 0, t = 0, born = self.time }
    self.st[id] = s
  end
  return s
end

local function rawNav()
  local x, y = Input.moveVector()
  local js = Input.joystick
  if js then
    if js:isGamepadDown("dpleft")  then x = -1 end
    if js:isGamepadDown("dpright") then x = 1 end
    if js:isGamepadDown("dpup")    then y = -1 end
    if js:isGamepadDown("dpdown")  then y = 1 end
  end
  if abs(x) < 0.5 then x = 0 else x = U.sign(x) end
  if abs(y) < 0.5 then y = 0 else y = U.sign(y) end
  return x, y
end

function Ctx:beginFrame(dt)
  dt = dt or (1 / 60)
  self.dt = dt
  self.time = self.time + dt

  -- pointer
  local mx, my = love.mouse.getPosition()
  self.mouseMoved = (abs(mx - self.pmx) + abs(my - self.pmy)) > 1.5
  self.pmx, self.pmy = mx, my
  self.mx, self.my = mx, my
  local down = love.mouse.isDown(1)
  self.mPressed  = down and not self.mDown
  self.mReleased = (not down) and self.mDown
  self.mDown = down

  -- directional nav with hold-to-repeat
  local nx, ny = rawNav()
  if nx == 0 and ny == 0 then
    self.navHeld = 0
    self.navX, self.navY = 0, 0
    self.navLastX, self.navLastY = 0, 0
  else
    local fire = false
    if self.navHeld <= 0 then
      fire = true
      self.navNext = NAV_DELAY
    else
      self.navNext = (self.navNext or NAV_DELAY) - dt
      if self.navNext <= 0 then fire = true self.navNext = NAV_REPEAT end
    end
    if nx ~= self.navLastX or ny ~= self.navLastY then
      fire = true
      self.navNext = NAV_DELAY
    end
    self.navHeld = self.navHeld + dt
    self.navLastX, self.navLastY = nx, ny
    self.navX = fire and nx or 0
    self.navY = fire and ny or 0
  end

  self.confirmPressed = Input.pressed("confirm")
  self.backPressed    = Input.pressed("back")
  self.n = 0
  self.focusChanged = false
end

--- Register a rect. Returns the item record (recycled).
function Ctx:item(id, x, y, w, h, enabled)
  local n = self.n + 1
  self.n = n
  local it = self.items[n]
  if not it then it = {} self.items[n] = it end
  it.id, it.x, it.y, it.w, it.h = id, x, y, w, h
  it.enabled = enabled ~= false
  if it.enabled and (self.focusId == nil) then self.focusId = id end
  return it
end

function Ctx:hit(x, y, w, h)
  local mx, my = self.mx, self.my
  return mx >= x and mx <= x + w and my >= y and my <= y + h
end

function Ctx:focused(id) return self.focusId == id end

function Ctx:setFocus(id, quiet)
  if self.focusId == id then return end
  self.focusId = id
  self.focusChanged = true
  if self.sound and not quiet then Audio.play("ui_move") end
end

--- Consume the horizontal nav step (sliders, steppers, tab strips).
function Ctx:takeNavX()
  local v = self.navX
  self.navX = 0
  return v
end

function Ctx:takeNavY()
  local v = self.navY
  self.navY = 0
  return v
end

--- Standard per-widget interaction. Returns focused, hovered, activated.
function Ctx:interact(id, x, y, w, h, enabled)
  local it = self:item(id, x, y, w, h, enabled)
  local hot = it.enabled and self:hit(x, y, w, h)
  if hot and self.mouseMoved then self:setFocus(id) end
  local focused = self.focusId == id
  local activated = false
  if it.enabled then
    if hot and self.mPressed then
      self:setFocus(id, true)
      focused = true
      activated = true
    elseif focused and self.confirmPressed then
      activated = true
      self.confirmPressed = false
    end
  end
  local s = self:state(id)
  local rate = 16
  s.hover = U.damp(s.hover, hot and 1 or 0, rate, self.dt)
  s.focus = U.damp(s.focus, focused and 1 or 0, rate, self.dt)
  s.press = max(0, s.press - self.dt * 4.5)
  s.t = s.t + self.dt
  if activated then
    s.press = 1
    if self.sound then Audio.play("ui_select") end
  end
  return focused, hot, activated, s
end

--- Resolve leftover nav into a focus move, geometrically.
function Ctx:endFrame()
  local dx, dy = self.navX, self.navY
  self.navX, self.navY = 0, 0
  if (dx == 0 and dy == 0) or self.n == 0 then return end

  local cur
  for i = 1, self.n do
    if self.items[i].id == self.focusId then cur = self.items[i] break end
  end
  if not cur then
    for i = 1, self.n do
      if self.items[i].enabled then self:setFocus(self.items[i].id) return end
    end
    return
  end

  local cx, cy = cur.x + cur.w * 0.5, cur.y + cur.h * 0.5
  local bestId, bestScore = nil, math.huge
  for i = 1, self.n do
    local it = self.items[i]
    if it.enabled and it.id ~= cur.id then
      local ix, iy = it.x + it.w * 0.5, it.y + it.h * 0.5
      local vx, vy = ix - cx, iy - cy
      local along  = vx * dx + vy * dy
      local across = abs(vx * dy - vy * dx)
      if along > 1 then
        local score = along + across * 2.6
        if score < bestScore then bestScore, bestId = score, it.id end
      end
    end
  end
  if not bestId and self.wrap then
    -- wrap around: pick the furthest item in the opposite direction
    local worst = -math.huge
    for i = 1, self.n do
      local it = self.items[i]
      if it.enabled and it.id ~= cur.id then
        local ix, iy = it.x + it.w * 0.5, it.y + it.h * 0.5
        local along = (ix - cx) * -dx + (iy - cy) * -dy
        local across = abs((ix - cx) * dy - (iy - cy) * dx)
        if along > 1 and along - across * 2.6 > worst then
          worst = along - across * 2.6
          bestId = it.id
        end
      end
    end
  end
  if bestId then self:setFocus(bestId) end
end

------------------------------------------------------------------- focus ring
--- The one focus affordance in the game: brackets that breathe and a soft
--- backlight. Drawn by the widgets, exposed for anything bespoke.
function UI.focusRing(x, y, w, h, k, color, time, radius)
  if k <= 0.002 then return end
  local e = U.ease.outBack(U.saturate(k))
  local grow = (1 - e) * 14
  local pulse = 0.72 + 0.28 * sin((time or 0) * 4.4)
  Draw.setColor(UI.c(color, 0.055 * k))
  Draw.roundRect("fill", x - 4, y - 4, w + 8, h + 8, (radius or UI.r) + 3)
  UI.brackets(x - grow, y - grow, w + grow * 2, h + grow * 2,
              min(16, h * 0.5), color, k * pulse, 2, 3)
end

--------------------------------------------------------------------- button
--- A menu row. opts: { align, size, sub, icon, danger, disabled, accent,
--- badge, alpha, slide }.
---
--- `alpha` scales every colour the row draws, which is what lets a menu stagger
--- its rows in without any of them losing focusability on the way.
function UI.button(ctx, id, x, y, w, h, label, opts)
  opts = opts or UI.EMPTY
  local enabled = not opts.disabled
  local a = opts.alpha or 1
  local focused, hot, activated, s = ctx:interact(id, x, y, w, h, enabled)
  local acc = opts.accent or ctx.accent
  if opts.danger then acc = P.danger end
  if a <= 0.004 then return activated, s end
  x = x + (opts.slide or 0)

  local f = s.focus
  local pressK = U.ease.outQuad(s.press)
  local slide = f * 6 - pressK * 3

  -- plate
  Draw.setColor(UI.c(P.black, (0.34 + f * 0.2) * a))
  Draw.roundRect("fill", x, y, w, h, UI.r)
  if f > 0.002 then
    UI.hgrad(x, y, w * 0.85, h, acc, acc, 0.14 * f * a, 0)
  end
  lg.setLineWidth(1)
  Draw.setColor(UI.c(enabled and P.ink or P.inkFaint, (0.1 + f * 0.16) * a))
  Draw.roundRect("line", x + 0.5, y + 0.5, w - 1, h - 1, UI.r)

  -- accent spine
  local spineH = (h - 16) * (0.35 + 0.65 * f)
  Draw.setColor(UI.c(acc, (enabled and (0.35 + 0.65 * f) or 0.15) * a))
  Draw.roundRect("fill", x + 3, y + (h - spineH) * 0.5, 3, spineH, 1.5)

  -- label
  local size = opts.size or UI.ts.h4
  local lc = enabled and (focused and P.ink or P.inkDim) or P.inkFaint
  local ly = y + (h - size) * 0.5 - (opts.sub and size * 0.42 or 0)
  UI.text(label, x + 20 + slide, ly, size, lc, "left", (enabled and 1 or 0.45) * a, 0.06)
  if opts.sub then
    UI.body(opts.sub, x + 21 + slide, ly + size + 7, UI.bs.small,
            UI.c(P.inkFaint, (enabled and (0.55 + f * 0.4) or 0.3) * a))
  end
  if opts.badge then
    UI.caption(opts.badge, x + w - 18, y + (h - UI.ts.micro) * 0.5, UI.ts.micro,
               acc, "right", 0.8 * a)
  end

  UI.focusRing(x, y, w, h, f * a, acc, ctx.time, UI.r)
  return activated, s
end

--------------------------------------------------------------------- slider
--- Returns value, changed. `opts`: { min, max, step, format, suffix, percent }
function UI.slider(ctx, id, x, y, w, h, label, value, opts)
  opts = opts or UI.EMPTY
  local lo = opts.min or 0
  local hi = opts.max or 1
  local step = opts.step or (hi - lo) / 20
  local focused, hot, _, s = ctx:interact(id, x, y, w, h, not opts.disabled)
  local acc = opts.accent or ctx.accent
  local changed = false

  local labelW = opts.labelW or floor(w * 0.42)
  local tx = x + labelW
  local tw = w - labelW - 68
  local ty = y + h * 0.5

  -- keyboard / pad
  if focused then
    local nx = ctx:takeNavX()
    if nx ~= 0 then
      value = U.clamp(value + nx * step, lo, hi)
      changed = true
    end
  end
  -- drag
  if hot and ctx.mDown then
    ctx:setFocus(id, true)
    local t = U.saturate((ctx.mx - tx) / tw)
    local nv = lo + t * (hi - lo)
    if step > 0 then nv = lo + floor((nv - lo) / step + 0.5) * step end
    nv = U.clamp(nv, lo, hi)
    if abs(nv - value) > 1e-6 then value = nv changed = true end
  end
  if changed and ctx.sound then Audio.play("ui_move", { volume = 0.5 }) end

  local t = (value - lo) / (hi - lo)
  s.v = U.damp(s.v, t, 22, ctx.dt)
  local f = s.focus

  if f > 0.002 then
    Draw.setColor(UI.c(P.black, 0.3 * f))
    Draw.roundRect("fill", x - 8, y, w + 16, h, UI.r)
  end
  UI.text(label, x + 8, ty - UI.ts.label * 0.5, UI.ts.label,
          focused and P.ink or P.inkDim, "left", opts.disabled and 0.4 or 1, 0.06)

  -- track
  local th = 5
  Draw.setColor(UI.c(P.ink, 0.1))
  Draw.roundRect("fill", tx, ty - th * 0.5, tw, th, th * 0.5)
  -- notches on the 8px grid of the value range
  local notches = opts.notches or 4
  for i = 1, notches - 1 do
    local nx2 = tx + tw * i / notches
    Draw.setColor(UI.c(P.ink, 0.12))
    lg.rectangle("fill", nx2, ty - 1, 1, 2)
  end
  local fw = tw * s.v
  if fw > 1 then
    Draw.setColor(UI.c(acc, 0.55 + f * 0.45))
    Draw.roundRect("fill", tx, ty - th * 0.5, fw, th, th * 0.5)
  end
  -- knob
  local kx = tx + fw
  local kh = 18 + f * 4
  Draw.setColor(UI.c(P.black, 0.7))
  Draw.roundRect("fill", kx - 4, ty - kh * 0.5, 8, kh, 3)
  Draw.setColor(UI.c(acc, 0.85 + f * 0.15))
  Draw.roundRect("fill", kx - 3, ty - kh * 0.5 + 1, 6, kh - 2, 2.5)
  if f > 0.01 then Draw.glow(kx, ty, 22 * f, acc, 0.35 * f, 2) end

  -- readout, tabular
  local shown
  if opts.percent ~= false then
    shown = Text.format(t * 100, { decimals = 0, suffix = "%" })
  else
    shown = Text.format(value, { decimals = opts.decimals or 0, suffix = opts.suffix })
  end
  UI.text(shown, x + w - 4, ty - UI.ts.small * 0.5, UI.ts.small,
          focused and acc or P.inkDim, "right", 1, 0.05)

  UI.focusRing(x - 8, y, w + 16, h, f, acc, ctx.time, UI.r)
  return value, changed
end

--------------------------------------------------------------------- toggle
function UI.toggle(ctx, id, x, y, w, h, label, value, opts)
  opts = opts or UI.EMPTY
  local focused, hot, activated, s = ctx:interact(id, x, y, w, h, not opts.disabled)
  local acc = opts.accent or ctx.accent
  local changed = false
  if focused then
    local nx = ctx:takeNavX()
    if nx ~= 0 then
      local nv = nx > 0
      if nv ~= value then value = nv changed = true end
    end
  end
  if activated then value = not value changed = true end

  s.v = U.damp(s.v, value and 1 or 0, 20, ctx.dt)
  local f = s.focus
  if f > 0.002 then
    Draw.setColor(UI.c(P.black, 0.3 * f))
    Draw.roundRect("fill", x - 8, y, w + 16, h, UI.r)
  end
  local ty = y + h * 0.5
  UI.text(label, x + 8, ty - UI.ts.label * 0.5, UI.ts.label,
          focused and P.ink or P.inkDim, "left", opts.disabled and 0.4 or 1, 0.06)

  -- pill
  local pw, ph = 46, 22
  local px = x + w - pw - 4
  Draw.setColor(UI.c(P.black, 0.55))
  Draw.roundRect("fill", px, ty - ph * 0.5, pw, ph, ph * 0.5)
  Draw.setColor(UI.mix(P.inkFaint, acc, s.v, 0.2 + s.v * 0.55))
  Draw.roundRect("fill", px, ty - ph * 0.5, pw, ph, ph * 0.5)
  lg.setLineWidth(1)
  Draw.setColor(UI.c(P.ink, 0.14 + f * 0.16))
  Draw.roundRect("line", px + 0.5, ty - ph * 0.5 + 0.5, pw - 1, ph - 1, ph * 0.5)
  local kx = px + 11 + s.v * (pw - 22)
  Draw.setColor(UI.mix(P.inkDim, P.ink, s.v))
  lg.circle("fill", kx, ty, 8, 16)
  if s.v > 0.02 then Draw.glow(kx, ty, 20 * s.v, acc, 0.4 * s.v, 2) end
  UI.caption(value and "ON" or "OFF", px - 12, ty - UI.ts.micro * 0.5, UI.ts.micro,
             value and acc or P.inkFaint, "right", 0.85)

  UI.focusRing(x - 8, y, w + 16, h, f, acc, ctx.time, UI.r)
  return value, changed
end

--------------------------------------------------------------------- stepper
--- Cycles through `options` (array of strings). Returns index, changed.
function UI.stepper(ctx, id, x, y, w, h, label, index, options, opts)
  opts = opts or UI.EMPTY
  local focused, hot, activated, s = ctx:interact(id, x, y, w, h, not opts.disabled)
  local acc = opts.accent or ctx.accent
  local changed = false
  local n = #options
  if focused then
    local nx = ctx:takeNavX()
    if nx ~= 0 then index = ((index - 1 + nx) % n) + 1 changed = true end
  end
  if activated then index = (index % n) + 1 changed = true end
  if changed and ctx.sound then Audio.play("ui_move", { volume = 0.6 }) end

  local f = s.focus
  if f > 0.002 then
    Draw.setColor(UI.c(P.black, 0.3 * f))
    Draw.roundRect("fill", x - 8, y, w + 16, h, UI.r)
  end
  local ty = y + h * 0.5
  UI.text(label, x + 8, ty - UI.ts.label * 0.5, UI.ts.label,
          focused and P.ink or P.inkDim, "left", opts.disabled and 0.4 or 1, 0.06)
  local vx = x + w - 4
  UI.text(options[index], vx - 18, ty - UI.ts.label * 0.5, UI.ts.label,
          focused and acc or P.inkDim, "right", 1, 0.06)
  local vw = Text.measure(options[index], UI.ts.label, nil)
  Draw.setColor(UI.c(focused and acc or P.inkFaint, 0.5 + f * 0.5))
  lg.setLineWidth(2)
  Draw.chevron(vx - 24 - vw - 12, ty, 5, math.pi, 2, 0.8)
  Draw.chevron(vx - 6, ty, 5, 0, 2, 0.8)

  UI.focusRing(x - 8, y, w + 16, h, f, acc, ctx.time, UI.r)
  return index, changed
end

--------------------------------------------------------------------- tab strip
--- Horizontal tabs with a sliding underline. Returns index, changed.
function UI.tabs(ctx, id, x, y, w, h, labels, index, opts)
  opts = opts or UI.EMPTY
  local acc = opts.accent or ctx.accent
  local n = #labels
  local tw = w / n
  local changed = false
  local s = ctx:state(id .. "#strip")

  for i = 1, n do
    local tx = x + (i - 1) * tw
    local tid = id .. "#" .. i
    local focused, hot, activated, ts = ctx:interact(tid, tx, y, tw, h, true)
    -- focus *is* selection: sweeping the strip with a stick changes the page,
    -- rather than making the player confirm every tab they pass through.
    if (activated or (focused and not opts.manual)) and i ~= index then
      index = i changed = true
    end
    local on = (i == index)
    local k = max(ts.focus, on and 1 or 0)
    UI.text(labels[i], tx + tw * 0.5, y + (h - UI.ts.small) * 0.5, UI.ts.small,
            on and P.ink or (focused and P.inkDim or P.inkFaint), "center", 1, 0.2)
    if ts.focus > 0.002 and not on then
      Draw.setColor(UI.c(P.ink, 0.05 * ts.focus))
      Draw.roundRect("fill", tx + 2, y, tw - 4, h, 4)
    end
    if focused then
      UI.brackets(tx + 4, y + 2, tw - 8, h - 4, 9, acc, ts.focus * 0.85, 2, 0)
    end
  end

  s.v = s.v == 0 and index or U.damp(s.v, index, 18, ctx.dt)
  local ux = x + (s.v - 1) * tw
  Draw.setColor(UI.c(P.ink, 0.1))
  lg.rectangle("fill", x, y + h - 1, w, 1)
  Draw.setColor(UI.c(acc, 0.95))
  Draw.roundRect("fill", ux + tw * 0.22, y + h - 2, tw * 0.56, 2, 1)
  Draw.glow(ux + tw * 0.5, y + h - 1, 34, acc, 0.22, 2)
  return index, changed
end

--------------------------------------------------------------------- list
--- Scrollable region. `drawItem(i, x, y, w, h, focused)` is called for the
--- visible rows only. Returns the focused row index.
function UI.list(ctx, id, x, y, w, h, count, itemH, drawItem, opts)
  opts = opts or UI.EMPTY
  local s = ctx:state(id)
  s.scroll = s.scroll or 0
  s.scrollTo = s.scrollTo or 0

  local total = count * itemH
  local viewH = h

  -- find the focused row so we can keep it on screen
  local focusRow = nil
  for i = 1, count do
    if ctx.focusId == id .. "#" .. i then focusRow = i break end
  end
  if focusRow then
    local top = (focusRow - 1) * itemH
    local bot = top + itemH
    if top < s.scrollTo then s.scrollTo = top end
    if bot > s.scrollTo + viewH then s.scrollTo = bot - viewH end
  end
  s.scrollTo = U.clamp(s.scrollTo, 0, max(0, total - viewH))
  s.scroll = U.damp(s.scroll, s.scrollTo, 15, ctx.dt)

  local sx, sy, sw, sh = lg.getScissor()
  lg.setScissor(x, y, w, h)
  local first = max(1, floor(s.scroll / itemH))
  local last  = min(count, first + math.ceil(viewH / itemH) + 1)
  for i = first, last do
    local iy = y + (i - 1) * itemH - s.scroll
    local focused = ctx:interact(id .. "#" .. i, x, iy, w, itemH - 2, true)
    drawItem(i, x, iy, w, itemH - 2, focused, ctx:state(id .. "#" .. i))
  end
  if sx then lg.setScissor(sx, sy, sw, sh) else lg.setScissor() end

  if total > viewH then
    local bh = max(24, viewH * viewH / total)
    local by = y + (viewH - bh) * (s.scroll / (total - viewH))
    Draw.setColor(UI.c(P.ink, 0.07))
    Draw.roundRect("fill", x + w + 6, y, 3, viewH, 1.5)
    Draw.setColor(UI.c(ctx.accent, 0.5))
    Draw.roundRect("fill", x + w + 6, by, 3, bh, 1.5)
  end
  return focusRow
end

--------------------------------------------------------------------- card
--- The card primitive: a raised panel with a tint, a hairline frame, an
--- optional foil sheen and a lift/tilt driven by `k` (0..1 hover) and `sel`.
--- Everything about the transform is applied by the caller pushing first;
--- this draws in local space with the card centred on (0,0).
function UI.card(w, h, opts)
  opts = opts or UI.EMPTY
  local tint  = opts.tint or P.metal
  local k     = opts.hover or 0
  local a     = opts.alpha or 1
  local r     = opts.radius or 10
  local x, y  = -w * 0.5, -h * 0.5

  -- drop shadow, deeper as it lifts
  Draw.softShadow(0, h * 0.5 + 10 + k * 8, w * 0.52, 18 + k * 10, 0.42 * a)

  -- body
  Draw.setColor(UI.c(P.black, 0.9 * a))
  Draw.roundRect("fill", x, y, w, h, r)
  UI.vgrad(x + 1, y + 1, w - 2, h - 2, tint, P.black, (0.16 + 0.12 * k) * a, 0.0)
  UI.vgrad(x + 1, y + h * 0.55, w - 2, h * 0.45 - 1, P.black, tint, 0, 0.07 * a)

  -- foil sheen: a diagonal band that travels when hovered
  if opts.foil and opts.foil > 0 then
    local sx, sy, sw2, sh2 = lg.getScissor()
    lg.setScissor(opts.sx or 0, opts.sy or 0, opts.sw or lg.getWidth(), opts.sh or lg.getHeight())
    local t = (opts.time or 0) * 0.45 + (opts.phase or 0)
    local p = ((t % 1) * 2 - 0.5) * w * 1.6
    lg.push()
    lg.translate(x + p, 0)
    lg.shear(-0.5, 0)
    local bw = w * 0.16
    local bm, am = lg.getBlendMode()
    lg.setBlendMode("add", "alphamultiply")
    UI.hgrad(-bw, y, bw, h, tint, P.white, 0, 0.16 * opts.foil * a)
    UI.hgrad(0, y, bw, h, P.white, tint, 0.16 * opts.foil * a, 0)
    lg.setBlendMode(bm, am)
    lg.pop()
    if sx then lg.setScissor(sx, sy, sw2, sh2) else lg.setScissor() end
  end

  -- frame
  lg.setLineWidth(1)
  Draw.setColor(UI.c(tint, (0.3 + 0.55 * k) * a))
  Draw.roundRect("line", x + 0.5, y + 0.5, w - 1, h - 1, r)
  if k > 0.01 then
    Draw.setColor(UI.c(tint, 0.22 * k * a))
    Draw.roundRect("line", x - 2.5, y - 2.5, w + 5, h + 5, r + 2)
  end
end


------------------------------------------------------------------ scratch opts
--- A display-text option table screens may fill in and hand to `UI.text` for
--- the rarer effects (glow, shadow, maxWidth, weight). `UI.text` clears those
--- fields again on the way out, so it is always safe to reuse.
UI.o = { snap = true }

------------------------------------------------------------------- full screen
--- Flat wash over everything. The first move of every menu that sits on top of
--- the world.
function UI.scrim(alpha, color)
  Draw.setColor(UI.c(color or P.black, alpha or 0.6))
  lg.rectangle("fill", 0, 0, lg.getDimensions())
end

--- Four edge gradients that read as one soft vignette. Cheaper and calmer than
--- a radial, and it never bands on a flat backdrop.
function UI.vignette(strength, color, depth)
  strength = strength or 0.5
  if strength <= 0.002 then return end
  local w, h = lg.getDimensions()
  local c = color or P.black
  local dv = depth or (h * 0.42)
  local dh = depth or (w * 0.30)
  UI.vgrad(0, 0, w, dv, c, c, strength * 0.62, 0)
  UI.vgrad(0, h - dv, w, dv, c, c, 0, strength)
  UI.hgrad(0, 0, dh, h, c, c, strength * 0.75, 0)
  UI.hgrad(w - dh, 0, dh, h, c, c, 0, strength * 0.75)
end

--- The out-of-focus cue used behind the pause menu: soft dark bands plus a
--- speckle, which reads as depth without needing a blur pass.
function UI.defocus(k, time, color)
  if k <= 0.002 then return end
  local w, h = lg.getDimensions()
  local c = color or P.ramp.rift[1]
  UI.scrim(0.58 * k, P.black)
  UI.vgrad(0, 0, w, h, c, P.black, 0.30 * k, 0.46 * k)
  -- three slow bokeh discs: the only thing on screen still moving
  for i = 1, 3 do
    local t = (time or 0) * (0.05 + i * 0.017) + i * 2.1
    local bx = w * (0.2 + 0.6 * (0.5 + 0.5 * cos(t)))
    local by = h * (0.25 + 0.5 * (0.5 + 0.5 * sin(t * 0.83 + i)))
    Draw.glow(bx, by, 120 + i * 46, P.ramp.rift[3], 0.05 * k, 3)
  end
  Draw.noiseSpeckle(0, 0, w, h, 11, 0.00016, P.ink, 0.05 * k, 1.4)
  UI.vignette(0.55 * k)
end

--------------------------------------------------------------------- timing
--- Entrance timing. Returns the eased 0..1 progress of element `i` (1-based) in
--- a sequence that starts at `start`, steps by `step` and each runs for `dur`.
function UI.stagger(time, i, start, step, dur, ease)
  local t = U.saturate(((time or 0) - (start or 0) - (i - 1) * (step or 0.08))
                       / (dur or 0.4))
  return (ease or U.ease.outCubic)(t)
end

--------------------------------------------------------------------- readouts
--- Caption over numeral: the game's one way of showing a number with a name.
--- `align` positions both parts. Returns the numeral's rendered width.
function UI.stat(x, y, label, value, size, color, align, alpha, sub, subColor)
  size = size or UI.ts.h2
  alpha = alpha or 1
  UI.caption(label, x, y, UI.ts.micro, UI.c(P.inkFaint, 0.85 * alpha), align)
  local vw = UI.text(value, x, y + 16, size, color or P.ink, align, alpha, 0.02)
  if sub then
    local sx = x
    if align == "right" then sx = x - vw - 8
    elseif align == "center" then sx = x + vw * 0.5 + 8
    else sx = x + vw + 8 end
    UI.caption(sub, sx, y + 16 + size - UI.ts.tiny - 1, UI.ts.tiny,
               UI.c(subColor or P.inkDim, 0.9 * alpha),
               align == "right" and "right" or "left")
  end
  return vw
end

--- A header: an accent tick, the word, and a rule running out to `w`.
function UI.header(x, y, w, label, size, accent, alpha, ruleAlpha)
  size = size or UI.ts.h4
  alpha = alpha or 1
  Draw.setColor(UI.c(accent or P.accent, 0.95 * alpha))
  Draw.roundRect("fill", x, y + 1, 3, size - 2, 1.5)
  local tw = UI.text(label, x + 12, y, size, UI.c(P.ink, alpha), "left", alpha, 0.16)
  local rx = x + 12 + tw + 14
  if w and x + w > rx then
    UI.rule(rx, y + size * 0.5, x + w - rx, P.ink, (ruleAlpha or 0.12) * alpha)
  end
  return tw
end

--- A row of button prompts. `list` is an array the caller owns and reuses:
--- { { action, label }, ... }. Returns the width consumed.
function UI.promptRow(x, y, list, size, color, alpha, align, gap)
  size = size or UI.ts.micro
  gap = gap or 22
  local total = 0
  for i = 1, #list do
    local it = list[i]
    local g = Input.glyph(it[1])
    local gw = max(Text.measure(g, size, nil) + 14, size + 14)
    total = total + gw + (it[2] and (UI.captionWidth(it[2], size) + 10) or 0)
    if i < #list then total = total + gap end
  end
  local px = x
  if align == "right" then px = x - total elseif align == "center" then px = x - total * 0.5 end
  for i = 1, #list do
    local it = list[i]
    px = px + UI.prompt(px, y, it[1], it[2], size, color, alpha) + gap
  end
  return total
end

UI.EMPTY = {}

return UI
