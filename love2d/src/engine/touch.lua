-- The iPhone control layer.
--
-- Design brief: a player must be able to *play* this game with two thumbs on a
-- 6-inch pane of glass. That means three things, and this module is only ever
-- allowed to be as complicated as those three things demand:
--
--   1. A floating left stick. It spawns wherever the left thumb lands, follows
--      the thumb once it runs past the ring, and has a dead zone plus a small
--      "grip" so a resting thumb's micro-jitter never nudges the player.
--   2. A right-hand action cluster arranged on the thumb's natural arc -- a
--      diamond of four verbs around a centre the thumb can pivot to without
--      lifting, plus BUILD held outboard where the radial has room to open.
--      Every target is >= 44 pt of real glass with generous invisible padding.
--   3. Aim. Drag the right thumb on empty space to aim explicitly; otherwise
--      the game aims for you at the nearest threat inside a cone of travel.
--
-- Multi-touch is the whole difficulty. Every finger is a *slot* with an id and
-- a role, decided once at touch-down and never re-assigned: a second finger can
-- never steal the stick, an action press can never eat the aim drag, and
-- releasing one finger cannot cancel another's role. Move + shove + aim at the
-- same instant is the normal case, not the edge case.
--
-- The module hooks love.touchpressed/moved/released itself (see install() at the
-- bottom) so no scene has to remember to forward events. Gameplay code only
-- ever sees actions, through engine/input.lua's `touchModule` hook.
--
-- Layout is resolution-independent: everything is a fraction of the short screen
-- edge, so the same numbers hold for a letterboxed browser canvas and a native
-- retina buffer. Nothing in update or draw allocates.
local U        = require("src.core.util")
local P        = require("src.engine.palette")
local Draw     = require("src.engine.draw")
local Text     = require("src.engine.text")
local Input    = require("src.engine.input")
local Settings = require("src.game.settings")
local TU       = require("src.game.tuning")

local lg = love.graphics
local cos, sin, atan2, sqrt = math.cos, math.sin, math.atan2, math.sqrt
local min, max, abs, floor  = math.min, math.max, math.abs, math.floor
local pi, TAU               = math.pi, U.TAU

local Touch = {}

----------------------------------------------------------------------- config
-- Fractions of S = min(screenW, screenH) unless the name says otherwise.
-- This is the single place the touch layout is defined (spec section 10).
local CFG = {
  maxTouches   = 10,

  -- floating stick
  stickRing    = 0.112,   -- ring radius: full deflection
  stickNub     = 0.046,
  stickDead    = 0.155,   -- fraction of the ring ignored at the centre
  stickGrip    = 0.011,   -- absolute jitter floor before anything moves at all
  stickCurve   = 1.25,    -- >1 = finer control near the centre
  stickFollow  = 26,      -- damp rate at which the ring chases a runaway thumb
  stickZoneX   = 0.52,    -- fraction of screen width owned by the stick
  stickZoneTop = 0.10,    -- keeps the HUD strip tappable

  -- action cluster
  btn          = 0.070,   -- visual button radius
  btnHitPad    = 1.46,    -- invisible hit radius multiplier
  btnSlop      = 2.30,    -- drag this far off a button before it cancels
  clusterR     = 0.118,   -- diamond radius around the cluster centre
  clusterInX   = 0.190,   -- cluster centre inset from the safe right edge
  clusterInY   = 0.205,   -- ... and from the safe bottom edge
  buildOut     = 2.00,    -- BUILD sits this many cluster radii out, up-and-inboard

  -- build radial
  radialInner  = 0.072,
  radialOuter  = 0.235,
  radialGap    = 0.030,   -- wedge separation, radians
  radialHold   = 0.15,    -- hold this long (or drag) to open
  radialDrag   = 0.030,   -- ... or drag this far, whichever comes first

  -- aim
  aimDead      = 0.028,   -- drag before an aim touch commits
  aimRange     = 430,     -- world units for auto-aim
  aimCone      = 1.05,    -- half-angle of the travel cone, radians
  aimStick     = 0.55,    -- how strongly a locked target is preferred

  -- feel
  fade         = 7.0,     -- opacity damp rate
  press        = 26.0,    -- press-scale damp rate
  latch        = 0.085,   -- min time a tapped action reports down
  ripple       = 0.36,
  hapticTap    = 0.011,
  hapticSlide  = 0.006,
  hapticFire   = 0.020,

  safeMin      = 0.020,   -- fallback inset when the OS will not tell us
  safeNotch    = 0.055,   -- assumed notch inset on iOS when the API is absent
}
Touch.cfg = CFG

--------------------------------------------------------------------- public state
Touch.active      = false   -- true once touch is the player's device
Touch.opacity     = 0       -- current drawn opacity (damped)
Touch.enabled     = true
Touch.autoAimId   = nil     -- the entity auto-aim last locked (debug/HUD)

local manualOpacity = 1
local visFade       = 0

---------------------------------------------------------------------- actions
-- Diamond order is deliberate. A right thumb resting at the bottom-right of the
-- cluster reaches DOWN first, then RIGHT; LEFT and UP cost a small pivot. So:
-- dash (constant) is down, shove (the fight) is right, pulse (a deliberate hold)
-- is up where its charge ring has air, and plant (calm, considered) is left.
local ACT = {
  { id = "dash",  label = "DASH",  ang = 0.5 * pi,  color = P.accentCool },
  { id = "shove", label = "SHOVE", ang = 0,         color = P.warn },
  { id = "pulse", label = "PULSE", ang = 1.5 * pi,  color = P.ramp.cobalt[4], hold = true },
  { id = "plant", label = "PLANT", ang = pi,        color = P.ramp.leaf[3] },
  { id = "build", label = "BUILD", ang = 1.25 * pi, color = P.accent, outboard = true, modal = true },
}
local ACT_N = #ACT
local BY_ID = {}
for i = 1, ACT_N do BY_ID[ACT[i].id] = ACT[i] end

for i = 1, ACT_N do
  local b = ACT[i]
  b.x, b.y, b.r, b.hitR = 0, 0, 0, 0
  b.press, b.sc, b.ripple = 0, 1, 0
  b.slot, b.holdT = nil, 0
end
Touch.buttons = ACT

--- Latched actions: a tap that lasts less than a polled frame still has to be
--- seen by input.lua, so every momentary press reports down for `CFG.latch`.
local latch = {}
for i = 1, ACT_N do latch[ACT[i].id] = 0 end
for i = 1, #TU.bots.order do latch["build" .. i] = 0 end

------------------------------------------------------------------------ layout
local L = {
  w = 0, h = 0, s = 0, scale = 1, side = "right",
  sl = 0, st = 0, sr = 0, sb = 0,          -- safe-area insets
  cx = 0, cy = 0,                          -- cluster centre
  stickX = 0, stickTop = 0,                -- stick zone bounds
  dirty = true,
}
local safeManual = false

--- Explicit safe-area insets, in pixels. Call from the platform layer (or the
--- web shell, via a viewport-fit=cover env() readback) to beat the guess below.
function Touch.setSafeArea(l, t, r, b)
  L.sl, L.st, L.sr, L.sb = l or 0, t or 0, r or 0, b or 0
  safeManual = true
  L.dirty = true
end

function Touch.getSafeArea() return L.sl, L.st, L.sr, L.sb end

local function readSafeArea(w, h, s)
  if safeManual then return end
  local l, t, r, b
  if love.window and love.window.getSafeArea then
    local ok, x, y, sw, sh = pcall(love.window.getSafeArea)
    if ok and type(x) == "number" and sw and sh and sw > 0 and sh > 0 then
      l, t, r, b = x, y, w - (x + sw), h - (y + sh)
    end
  end
  if not l or (l <= 0 and t <= 0 and r <= 0 and b <= 0) then
    -- No API, or a device that reports none: guess. Portrait puts the notch and
    -- the home indicator top/bottom, landscape puts the notch on one edge and
    -- the indicator along the bottom.
    local osn = love.system and love.system.getOS() or ""
    local notch = (osn == "iOS") and (s * CFG.safeNotch) or (s * CFG.safeMin)
    local pad = s * CFG.safeMin
    if h > w then l, t, r, b = pad, notch, pad, notch * 0.6
    else l, t, r, b = notch, pad, notch, notch * 0.6 end
  end
  L.sl, L.st, L.sr, L.sb = max(l, 0), max(t, 0), max(r, 0), max(b, 0)
end

--- Recompute every hit target. Only runs when something structural changed.
local function layout()
  local w, h = lg.getDimensions()
  local scale = Settings.get("touchScale")
  local side  = Settings.get("touchSide")
  local s = min(w, h)
  if not L.dirty and w == L.w and h == L.h and scale == L.scale and side == L.side then return end
  L.w, L.h, L.s, L.scale, L.side, L.dirty = w, h, s, scale, side, false

  readSafeArea(w, h, s)

  local mirror = (side == "left") and -1 or 1
  local btnR = s * CFG.btn * scale
  local ringR = s * CFG.clusterR * scale

  -- cluster centre, mirrored for left-handed players
  local inX = s * CFG.clusterInX * scale
  local inY = s * CFG.clusterInY * scale
  local cx = (mirror > 0) and (w - L.sr - inX) or (L.sl + inX)
  local cy = h - L.sb - inY
  -- never let the diamond leave the safe box
  cx = U.clamp(cx, L.sl + ringR + btnR, w - L.sr - ringR - btnR)
  cy = U.clamp(cy, L.st + ringR + btnR, h - L.sb - ringR - btnR)
  L.cx, L.cy = cx, cy

  for i = 1, ACT_N do
    local b = ACT[i]
    local a = b.ang
    local rad = b.outboard and (ringR * CFG.buildOut) or ringR
    if mirror < 0 then a = pi - a end   -- mirror the whole arrangement in x
    b.r = btnR * (b.outboard and 0.88 or 1)
    b.hitR = b.r * CFG.btnHitPad
    b.x = U.clamp(cx + cos(a) * rad, L.sl + b.r, w - L.sr - b.r)
    b.y = U.clamp(cy + sin(a) * rad, L.st + b.r, h - L.sb - b.r)
  end

  -- the stick owns the opposite half, minus the HUD strip
  if mirror > 0 then
    L.stickX0, L.stickX1 = 0, w * CFG.stickZoneX
  else
    L.stickX0, L.stickX1 = w * (1 - CFG.stickZoneX), w
  end
  L.stickTop = L.st + s * CFG.stickZoneTop
  L.ringR = s * CFG.stickRing * scale
  L.nubR  = s * CFG.stickNub * scale
end

--------------------------------------------------------------------- touch slots
-- Fixed pool: a slot is a finger. `role` is decided at touch-down and is
-- immutable for the life of the touch. That single rule is what makes the
-- multi-touch behaviour predictable.
local slots = {}
for i = 1, CFG.maxTouches do
  slots[i] = { id = nil, x = 0, y = 0, sx = 0, sy = 0, t = 0, drag = 0, role = "idle", btn = nil }
end
Touch.slots = slots

local stick = { slot = nil, cx = 0, cy = 0, x = 0, y = 0, mag = 0, dx = 0, dy = 0, fade = 0 }
local aim   = { slot = nil, ox = 0, oy = 0, x = 0, y = 0, active = false, dx = 1, dy = 0, fade = 0 }
Touch.stick, Touch.aimState = stick, aim

local radial = {
  open = false, btn = nil, cx = 0, cy = 0, sel = 0, t = 0, fade = 0,
  n = #TU.bots.order, last = 1,
}
Touch.radial = radial

local function findSlot(id)
  for i = 1, CFG.maxTouches do
    if slots[i].id == id then return slots[i] end
  end
  return nil
end

local function freeSlot()
  for i = 1, CFG.maxTouches do
    if slots[i].id == nil then return slots[i] end
  end
  return nil
end

function Touch.touchCount()
  local n = 0
  for i = 1, CFG.maxTouches do if slots[i].id ~= nil then n = n + 1 end end
  return n
end

------------------------------------------------------------------------ haptics
local function buzz(dur)
  if not Settings.get("rumble") then return end
  if love.system and love.system.vibrate then pcall(love.system.vibrate, dur) end
end

------------------------------------------------------------------- integration
-- Optional hooks the game scene installs. All are pure reads; touch.lua never
-- reaches into the world.
local originFn, threatList, cobaltFn

--- Tell the aim assist where the player is and what counts as a threat.
--- `originFn()` returns world x, y. `list` is an array of entities with .x/.y
--- (and optionally .dead / .hp), read but never modified.
function Touch.setAimContext(fn, list) originFn, threatList = fn, list end

--- Tell the build radial how much cobalt is in the bank, so wedges can grey out.
function Touch.setCobaltSource(fn) cobaltFn = fn end

--------------------------------------------------------------------- activation
function Touch.activate()
  if Touch.active then return end
  Touch.active = true
  Input.touchModule = Touch
  Input.setScheme("touch")
  L.dirty = true
end

function Touch.setEnabled(on)
  Touch.enabled = on and true or false
  if not Touch.enabled then Touch.releaseAll() end
end

--- Visual master fade, for cutscenes and menus. 0 hides the layer completely.
function Touch.setOpacity(a) manualOpacity = U.saturate(a or 1) end
function Touch.getOpacity() return Touch.opacity end

function Touch.releaseAll()
  for i = 1, CFG.maxTouches do
    local sl = slots[i]
    sl.id, sl.role, sl.btn = nil, "idle", nil
  end
  for i = 1, ACT_N do
    ACT[i].slot, ACT[i].holdT = nil, 0
  end
  stick.slot, stick.mag, stick.dx, stick.dy = nil, 0, 0, 0
  aim.slot, aim.active = nil, false
  radial.open, radial.btn, radial.sel = false, nil, 0
end

------------------------------------------------------------------- hit testing
--- Nearest free button whose padded target contains the point.
local function hitButton(x, y)
  local best, bestD = nil, nil
  for i = 1, ACT_N do
    local b = ACT[i]
    if b.slot == nil then
      local dx, dy = x - b.x, y - b.y
      local d2 = dx * dx + dy * dy
      if d2 <= b.hitR * b.hitR and (not bestD or d2 < bestD) then best, bestD = b, d2 end
    end
  end
  return best
end

local function inStickZone(x, y)
  return x >= L.stickX0 and x <= L.stickX1 and y >= L.stickTop
end

---------------------------------------------------------------------- pressing
local function pressButton(b, sl)
  b.slot = sl
  b.holdT = 0
  b.ripple = 1
  sl.role, sl.btn = "btn", b
  if b.modal then
    radial.btn, radial.open, radial.t, radial.sel = b, false, 0, 0
  else
    latch[b.id] = max(latch[b.id], CFG.latch)
  end
  buzz(CFG.hapticTap)
end

local function openRadial(b)
  if radial.open then return end
  radial.open = true
  radial.cx, radial.cy = b.x, b.y
  radial.sel = 0
  buzz(CFG.hapticFire)
end

--- Which wedge is the thumb over? 0 = none (cancel).
local function radialPick(x, y)
  local dx, dy = x - radial.cx, y - radial.cy
  local d = sqrt(dx * dx + dy * dy)
  if d < L.s * CFG.radialInner * L.scale then return 0 end
  local a = (atan2(dy, dx) + pi * 0.5) % TAU     -- wedge 1 starts straight up
  local step = TAU / radial.n
  return floor(a / step) + 1
end

local function closeRadial(commit)
  if not radial.open then return end
  radial.open = false
  if commit and radial.sel > 0 and radial.sel <= radial.n then
    radial.last = radial.sel
    latch["build" .. radial.sel] = max(latch["build" .. radial.sel], CFG.latch * 1.5)
    buzz(CFG.hapticFire)
  end
  radial.sel = 0
end

local function releaseButton(b, commit)
  if b.modal then
    if radial.open then
      closeRadial(commit)
    elseif commit then
      -- a quick tap re-places whatever you built last: one thumb, no menu
      latch["build" .. radial.last] = max(latch["build" .. radial.last], CFG.latch * 1.5)
      buzz(CFG.hapticFire)
    end
  end
  b.slot, b.holdT = nil, 0
end

------------------------------------------------------------- love touch events
-- Named on* so nothing accidentally double-forwards; install() below wires the
-- real love callbacks to these exactly once.
function Touch.onPressed(id, x, y)
  Touch.activate()
  if not Touch.enabled then return end
  layout()
  local sl = freeSlot()
  if not sl then return end
  sl.id, sl.x, sl.y, sl.sx, sl.sy, sl.t, sl.drag = id, x, y, x, y, 0, 0
  sl.role, sl.btn = "idle", nil

  local b = hitButton(x, y)
  if b then
    pressButton(b, sl)
    return
  end

  if stick.slot == nil and inStickZone(x, y) then
    sl.role = "stick"
    stick.slot = sl
    stick.cx, stick.cy, stick.x, stick.y = x, y, x, y
    stick.mag, stick.dx, stick.dy = 0, 0, 0
    return
  end

  if aim.slot == nil and not inStickZone(x, y) then
    sl.role = "aim"
    aim.slot = sl
    aim.ox, aim.oy, aim.x, aim.y = x, y, x, y
    aim.active = false
    return
  end
  -- anything else is tracked but inert: a palm, a third finger, a stray tap.
end

function Touch.onMoved(id, x, y)
  local sl = findSlot(id)
  if not sl then return end
  local dx, dy = x - sl.sx, y - sl.sy
  sl.x, sl.y = x, y
  sl.drag = max(sl.drag, sqrt(dx * dx + dy * dy))

  if sl.role == "stick" then
    stick.x, stick.y = x, y
  elseif sl.role == "aim" then
    aim.x, aim.y = x, y
  elseif sl.role == "btn" and sl.btn then
    local b = sl.btn
    if b.modal then
      if not radial.open and sl.drag > L.s * CFG.radialDrag then openRadial(b) end
      if radial.open then
        local pick = radialPick(x, y)
        if pick ~= radial.sel then
          radial.sel = pick
          if pick > 0 then buzz(CFG.hapticSlide) end
        end
      end
    else
      -- sliding far off a non-modal button cancels it, the way iOS buttons do
      local ddx, ddy = x - b.x, y - b.y
      if ddx * ddx + ddy * ddy > (b.r * CFG.btnSlop) ^ 2 then
        releaseButton(b, false)
        sl.role, sl.btn = "idle", nil
      end
    end
  end
end

function Touch.onReleased(id, x, y)
  local sl = findSlot(id)
  if not sl then return end
  if x then sl.x, sl.y = x, y end

  if sl.role == "stick" and stick.slot == sl then
    stick.slot = nil
    stick.mag, stick.dx, stick.dy = 0, 0, 0
  elseif sl.role == "aim" and aim.slot == sl then
    aim.slot, aim.active = nil, false
  elseif sl.role == "btn" and sl.btn then
    releaseButton(sl.btn, true)
  end
  sl.id, sl.role, sl.btn = nil, "idle", nil
end

------------------------------------------------------------------------ update
local function updateStick(dt)
  if stick.slot then
    stick.fade = U.damp(stick.fade, 1, 16, dt)
    local dx, dy = stick.x - stick.cx, stick.y - stick.cy
    local d = sqrt(dx * dx + dy * dy)
    local ring = L.ringR
    if d > ring then
      -- the ring chases the thumb instead of clamping dead: the stick never
      -- "runs out" mid-sprint, and re-centring is invisible.
      local ux, uy = dx / d, dy / d
      local tx, ty = stick.x - ux * ring, stick.y - uy * ring
      stick.cx = U.damp(stick.cx, tx, CFG.stickFollow, dt)
      stick.cy = U.damp(stick.cy, ty, CFG.stickFollow, dt)
      dx, dy = stick.x - stick.cx, stick.y - stick.cy
      d = sqrt(dx * dx + dy * dy)
    end
    local grip = L.s * CFG.stickGrip
    local dead = ring * CFG.stickDead
    if d <= max(dead, grip) then
      stick.mag, stick.dx, stick.dy = 0, 0, 0
    else
      local m = U.saturate((d - dead) / (ring - dead))
      m = m ^ CFG.stickCurve
      stick.mag = m
      stick.dx, stick.dy = dx / d, dy / d
    end
  else
    stick.fade = U.damp(stick.fade, 0, 9, dt)
    stick.mag = U.damp(stick.mag, 0, 30, dt)
    if stick.mag < 0.02 then stick.mag = 0 end
  end
end

local function updateAim(dt)
  if aim.slot then
    aim.fade = U.damp(aim.fade, 1, 16, dt)
    local dx, dy = aim.x - aim.ox, aim.y - aim.oy
    local d = sqrt(dx * dx + dy * dy)
    if d > L.s * CFG.aimDead then
      aim.active = true
      aim.dx, aim.dy = dx / d, dy / d
    end
  else
    aim.fade = U.damp(aim.fade, 0, 8, dt)
    aim.active = false
  end
end

--- Nearest threat inside the cone of travel. Falls back to the widest cone the
--- player is actually facing when they are standing still.
local function updateAutoAim()
  Touch.autoAimId = nil
  if aim.active then return end
  if not (originFn and threatList) then return end
  if not Settings.get("touchAimAssist") then return end
  local ok, px, py = pcall(originFn)
  if not ok or type(px) ~= "number" or type(py) ~= "number" then return end

  local fx, fy = aim.dx, aim.dy
  if stick.mag > 0.08 then fx, fy = stick.dx, stick.dy end
  local range2 = CFG.aimRange * CFG.aimRange
  local bestD2, bx, by = nil, nil, nil
  for i = 1, #threatList do
    local e = threatList[i]
    if e and not e.dead and e.x and e.y then
      local dx, dy = e.x - px, e.y - py
      local d2 = dx * dx + dy * dy
      if d2 < range2 and d2 > 1 then
        local d = sqrt(d2)
        local dot = (dx / d) * fx + (dy / d) * fy
        -- weight by how far off the travel axis the target sits
        if dot >= cos(CFG.aimCone) then
          local score = d2 * (1 - CFG.aimStick * U.saturate(dot))
          if not bestD2 or score < bestD2 then
            bestD2, bx, by = score, dx / d, dy / d
            Touch.autoAimId = e
          end
        end
      end
    end
  end
  if bx then aim.dx, aim.dy = bx, by end
end

local osChecked = false

function Touch.update(dt)
  if not osChecked then
    osChecked = true
    local osn = love.system and love.system.getOS() or ""
    if osn == "iOS" or osn == "Android" then Touch.activate() end
  end
  layout()

  local visible = Touch.active and Touch.enabled and Input.scheme == "touch"
  visFade = U.damp(visFade, visible and 1 or 0, CFG.fade, dt)
  Touch.opacity = visFade * manualOpacity * Settings.get("touchOpacity")

  for i = 1, CFG.maxTouches do
    local sl = slots[i]
    if sl.id ~= nil then sl.t = sl.t + dt end
  end

  updateStick(dt)
  updateAim(dt)
  updateAutoAim()

  -- buttons: press scale, hold timers, ripple, radial arming
  for i = 1, ACT_N do
    local b = ACT[i]
    local down = b.slot ~= nil
    b.press = U.damp(b.press, down and 1 or 0, CFG.press, dt)
    b.sc = U.damp(b.sc, down and 0.90 or 1, CFG.press, dt)
    if b.ripple > 0 then b.ripple = max(0, b.ripple - dt / CFG.ripple) end
    if down then
      b.holdT = b.holdT + dt
      if b.modal and not radial.open and b.holdT >= CFG.radialHold then openRadial(b) end
    end
  end

  radial.fade = U.damp(radial.fade, radial.open and 1 or 0, 18, dt)
  if radial.open then radial.t = radial.t + dt end

  for k, v in pairs(latch) do
    if v > 0 then latch[k] = max(0, v - dt) end
  end
end

------------------------------------------------------------- input.lua contract
-- These four are what engine/input.lua calls. They tolerate being invoked as
-- either `Touch.fn()` or `touch:fn()`.
function Touch.moveVector()
  if not Touch.active or not Touch.enabled then return 0, 0 end
  if stick.mag <= 0 then return 0, 0 end
  return stick.dx * stick.mag, stick.dy * stick.mag
end

function Touch.aimVector()
  if not Touch.active or not Touch.enabled then return 0, 0 end
  if aim.active then return aim.dx, aim.dy end
  if Touch.autoAimId then return aim.dx, aim.dy end
  return 0, 0
end

function Touch.isDown(a, b)
  local action = (b ~= nil) and b or a
  if type(action) ~= "string" then return false end
  if not Touch.active or not Touch.enabled then return false end
  if (latch[action] or 0) > 0 then return true end
  local btn = BY_ID[action]
  if btn then return btn.slot ~= nil and not btn.modal end
  return false
end

--- Charge progress of the pulse button, 0..1. Purely cosmetic.
function Touch.chargeAmount()
  local b = BY_ID.pulse
  if not b or not b.slot then return 0 end
  return U.saturate(b.holdT / TU.player.pulse.charge)
end

--------------------------------------------------------------------- drawing
local function disc(x, y, r, color, alpha, kind)
  Draw.setColor(color, alpha)
  lg.draw(Draw.ramp(kind or "disc"), x, y, 0, r, r)
end

local function ringStroke(x, y, r, width, color, alpha, segs)
  Draw.setColor(color, alpha)
  lg.setLineWidth(width)
  lg.circle("line", x, y, r, segs or 48)
end

local function arcStroke(x, y, r, width, a0, a1, color, alpha)
  Draw.setColor(color, alpha)
  lg.setLineWidth(width)
  lg.arc("line", "open", x, y, r, a0, a1, U.clamp(floor(abs(a1 - a0) * r / 4), 6, 96))
end

------------------------------------------------------------------------ glyphs
-- Drawn, not typeset: five little diagrams of what the verb does.
local function glyphDash(x, y, s, c, a)
  Draw.setColor(c, a)
  lg.setLineWidth(max(2, s * 0.17))
  lg.setLineJoin("bevel")
  for i = 0, 2 do
    local ox = (i - 1) * s * 0.44
    Draw.chevron(x + ox + s * 0.30, y, s * 0.52, 0, max(2, s * 0.17), 0.66)
  end
end

local function glyphShove(x, y, s, c, a)
  -- the 100 degree arc, with a push arrow through it
  local arc = TU.player.shove.arc * 0.5
  arcStroke(x - s * 0.30, y, s * 0.86, max(2, s * 0.16), -arc, arc, c, a)
  Draw.setColor(c, a)
  lg.setLineWidth(max(2, s * 0.16))
  Draw.arrow(x - s * 0.62, y, x + s * 0.16, y, max(2, s * 0.16), s * 0.34, s * 0.22)
end

local function glyphPulse(x, y, s, c, a)
  for i = 1, 3 do
    ringStroke(x, y, s * (0.26 + i * 0.24), max(1.6, s * 0.12 / i), c, a * (1 - (i - 1) * 0.22), 40)
  end
  disc(x, y, s * 0.18, c, a)
end

local function glyphPlant(x, y, s, c, a)
  Draw.setColor(c, a)
  lg.setLineWidth(max(2, s * 0.15))
  lg.line(x, y + s * 0.72, x, y - s * 0.30)
  Draw.setColor(c, a * 0.95)
  Draw.blob(x - s * 0.40, y - s * 0.20, s * 0.40, 12, 3, 0.22, 0.78, "fill", 0.4)
  Draw.blob(x + s * 0.40, y - s * 0.44, s * 0.36, 12, 9, 0.22, 0.78, "fill", -0.4)
end

local function glyphBuild(x, y, s, c, a)
  Draw.setColor(c, a)
  lg.setLineWidth(max(2, s * 0.15))
  Draw.hexagon(x, y, s * 0.82, 0, "line")
  Draw.setColor(c, a * 0.55)
  Draw.hexagon(x, y, s * 0.40, 0, "fill")
end

local GLYPH = { dash = glyphDash, shove = glyphShove, pulse = glyphPulse,
                plant = glyphPlant, build = glyphBuild }

------------------------------------------------------------------- stick draw
local function drawStick(alpha)
  local a = alpha * stick.fade
  if a < 0.01 then return end
  local x, y, r = stick.cx, stick.cy, L.ringR

  -- seat: a dark well so the ring reads on grass as well as on water
  disc(x, y, r * 1.18, P.black, 0.22 * a, "smooth")
  ringStroke(x, y, r, max(1.5, r * 0.022), P.ink, 0.20 * a, 56)
  ringStroke(x, y, r * CFG.stickDead, max(1, r * 0.016), P.ink, 0.10 * a, 32)

  -- the push: an arc of light on the ring in the direction of travel
  if stick.mag > 0.01 then
    local ang = atan2(stick.dy, stick.dx)
    local sweep = 0.42 + stick.mag * 0.32
    arcStroke(x, y, r, max(2.5, r * 0.055), ang - sweep, ang + sweep,
              P.accent, (0.20 + 0.55 * stick.mag) * a)
  end

  -- aim pip: where the game currently thinks you are pointing
  if (aim.active or Touch.autoAimId) and (aim.dx ~= 0 or aim.dy ~= 0) then
    local px, py = x + aim.dx * r * 1.32, y + aim.dy * r * 1.32
    Draw.setColor(P.warn, 0.55 * a)
    Draw.chevron(px, py, r * 0.16, atan2(aim.dy, aim.dx), max(2, r * 0.03), 0.8)
  end

  -- nub
  local nx = x + stick.dx * stick.mag * (r - L.nubR * 0.55)
  local ny = y + stick.dy * stick.mag * (r - L.nubR * 0.55)
  disc(nx, ny + L.nubR * 0.16, L.nubR * 1.05, P.black, 0.30 * a, "shadow")
  disc(nx, ny, L.nubR, P.black, 0.42 * a)
  disc(nx, ny, L.nubR * 0.86, P.ink, (0.16 + 0.18 * stick.mag) * a, "smooth")
  ringStroke(nx, ny, L.nubR, max(1.8, L.nubR * 0.10), P.ink, (0.45 + 0.35 * stick.mag) * a, 40)
end

--------------------------------------------------------------------- aim draw
local function drawAim(alpha)
  local a = alpha * aim.fade
  if a < 0.01 then return end
  local r = L.s * 0.026
  ringStroke(aim.ox, aim.oy, r, max(1.5, r * 0.16), P.warn, 0.35 * a, 28)
  if aim.active then
    Draw.setColor(P.warn, 0.55 * a)
    Draw.dashedLine(aim.ox, aim.oy, aim.x, aim.y, L.s * 0.018, L.s * 0.014, 0,
                    max(1.5, L.s * 0.004))
    local hx, hy = aim.x, aim.y
    disc(hx, hy, r * 0.9, P.warn, 0.30 * a, "smooth")
    Draw.setColor(P.warn, 0.85 * a)
    Draw.chevron(hx + aim.dx * r * 1.5, hy + aim.dy * r * 1.5, r * 0.9,
                 atan2(aim.dy, aim.dx), max(2, r * 0.18), 0.75)
  end
end

------------------------------------------------------------------ button draw
local function drawButton(b, alpha)
  local a = alpha
  if a < 0.01 then return end
  local r = b.r * b.sc
  local hot = b.press

  -- contact shadow keeps the layer sitting *above* the world, not in it
  Draw.softShadow(b.x, b.y + b.r * 0.20, b.r * 1.02, b.r * 0.52, 0.30 * a)

  disc(b.x, b.y, r, P.black, (0.38 + 0.14 * hot) * a)
  disc(b.x, b.y, r * 0.94, b.color, (0.07 + 0.30 * hot) * a, "smooth")
  ringStroke(b.x, b.y, r, max(1.8, r * 0.045), b.color, (0.42 + 0.55 * hot) * a, 52)
  ringStroke(b.x, b.y, r * 0.86, max(1, r * 0.016), P.ink, 0.10 * a, 44)

  -- press ripple
  if b.ripple > 0 then
    local t = 1 - b.ripple
    ringStroke(b.x, b.y, r * (1 + t * 0.85), max(1.5, r * 0.05 * b.ripple),
               b.color, 0.55 * b.ripple * a, 48)
  end

  -- hold-to-charge dial (pulse), drawn as a filling ring from the top
  if b.hold and b.slot then
    local c = Touch.chargeAmount()
    arcStroke(b.x, b.y, r * 1.12, max(2.5, r * 0.075), -pi * 0.5, -pi * 0.5 + TAU * c,
              P.ink, 0.9 * a)
    if c >= 1 then
      disc(b.x, b.y, r * 1.5, b.color, 0.35 * a, "glow")
    end
  end

  local gs = r * 0.44
  local gf = GLYPH[b.id]
  if gf then gf(b.x, b.y, gs, b.color, (0.80 + 0.20 * hot) * a) end
  lg.setLineJoin("miter")

  if Settings.get("touchLabels") and a > 0.35 then
    Text.display(b.label, b.x, b.y + r * 0.99, max(8, r * 0.235),
                 { color = b.color, alpha = 0.55 * a, align = "center",
                   tracking = 0.18, weight = 0.11, snap = true })
  end
end

------------------------------------------------------------------ radial draw
local WEDGE = {}

--- Filled annulus sector, built into a scratch table.
local function wedge(cx, cy, r0, r1, a0, a1)
  local n = 0
  local segs = U.clamp(floor((a1 - a0) * r1 / 5), 4, 40)
  for i = 0, segs do
    local a = a0 + (a1 - a0) * i / segs
    n = n + 1; WEDGE[n] = cx + cos(a) * r1
    n = n + 1; WEDGE[n] = cy + sin(a) * r1
  end
  for i = segs, 0, -1 do
    local a = a0 + (a1 - a0) * i / segs
    n = n + 1; WEDGE[n] = cx + cos(a) * r0
    n = n + 1; WEDGE[n] = cy + sin(a) * r0
  end
  Draw.trim(WEDGE, n)
  lg.polygon("fill", WEDGE)
end

local function drawRadial(alpha)
  local a = alpha * radial.fade
  if a < 0.01 then return end
  local cx, cy = radial.cx, radial.cy
  local r0 = L.s * CFG.radialInner * L.scale
  local r1 = L.s * CFG.radialOuter * L.scale * (0.86 + 0.14 * radial.fade)
  local n = radial.n
  local step = TAU / n
  local cobalt = nil
  if cobaltFn then
    local ok, v = pcall(cobaltFn)
    if ok and type(v) == "number" then cobalt = v end
  end

  -- scrim: the world dims so the menu is unambiguously modal
  Draw.setColor(P.black, 0.30 * a)
  lg.rectangle("fill", 0, 0, L.w, L.h)
  disc(cx, cy, r1 * 1.9, P.black, 0.35 * a, "smooth")

  for i = 1, n do
    local id = TU.bots.order[i]
    local def = TU.bots[id]
    local a0 = -pi * 0.5 + (i - 1) * step + CFG.radialGap
    local a1 = -pi * 0.5 + i * step - CFG.radialGap
    local mid = (a0 + a1) * 0.5
    local on = (radial.sel == i)
    local afford = (cobalt == nil) or (cobalt >= def.cost)
    local push = on and r1 * 0.045 or 0
    local wx, wy = cx + cos(mid) * push, cy + sin(mid) * push

    Draw.setColor(P.black, (on and 0.62 or 0.44) * a)
    wedge(wx, wy, r0, r1 + push, a0, a1)
    Draw.setColor(P.accent, (on and 0.30 or 0.07) * a * (afford and 1 or 0.4))
    wedge(wx, wy, r0, r1 + push, a0, a1)
    if on then
      arcStroke(wx, wy, r1 + push, max(2, r1 * 0.018), a0, a1, P.accent, 0.95 * a)
    end

    local lx = cx + cos(mid) * (r0 + r1) * 0.5
    local ly = cy + sin(mid) * (r0 + r1) * 0.5
    local col = afford and (on and P.ink or P.inkDim) or P.inkFaint
    Text.display(def.label, lx, ly - r1 * 0.13, r1 * (on and 0.115 or 0.10),
                 { color = col, alpha = a, align = "center", tracking = 0.10,
                   weight = 0.11, snap = true })
    Text.display(tostring(def.cost), lx, ly + r1 * 0.045, r1 * 0.10,
                 { color = afford and P.ramp.cobalt[4] or P.danger, alpha = a * 0.9,
                   align = "center", tracking = 0.06, weight = 0.11, snap = true })
  end

  -- hub
  disc(cx, cy, r0 * 0.96, P.black, 0.72 * a)
  ringStroke(cx, cy, r0 * 0.96, max(1.5, r0 * 0.05), P.accent, 0.5 * a, 44)
  local hub = (radial.sel > 0) and "PLACE" or "CANCEL"
  Text.display(hub, cx, cy - r0 * 0.11, r0 * 0.24,
               { color = radial.sel > 0 and P.accent or P.inkFaint, alpha = a,
                 align = "center", tracking = 0.16, weight = 0.11, snap = true })

  -- the thumb's own tether, so the gesture is legible while it happens
  if radial.btn and radial.btn.slot then
    local sl = radial.btn.slot
    Draw.setColor(P.accent, 0.35 * a)
    Draw.dashedLine(cx, cy, sl.x, sl.y, L.s * 0.016, L.s * 0.012, 0, max(1.5, L.s * 0.003))
  end
end

--------------------------------------------------------------------- draw
function Touch.draw()
  if not Touch.active then return end
  local a = Touch.opacity
  if a < 0.01 then return end

  local bm, am = lg.getBlendMode()
  lg.setBlendMode("alpha", "alphamultiply")
  local lw, lj = lg.getLineWidth(), lg.getLineJoin()
  lg.setLineJoin("miter")

  drawStick(a)
  drawAim(a)
  for i = 1, ACT_N do
    local b = ACT[i]
    if not b.modal then drawButton(b, a) end
  end
  drawRadial(a)
  -- the modal button draws last: it is the anchor the radial grew out of
  drawButton(BY_ID.build, a * (1 - radial.fade * 0.55))

  lg.setLineWidth(lw)
  lg.setLineJoin(lj)
  lg.setBlendMode(bm, am)
  lg.setColor(1, 1, 1, 1)
end

--------------------------------------------------------------------- install
-- Own the love callbacks directly. Chaining rather than replacing means
-- main.lua's forwarding to Input/Screen still happens, and no scene has to know
-- this module exists.
local installed = false
function Touch.install()
  if installed or not love then return end
  installed = true
  local prevP, prevM, prevR = love.touchpressed, love.touchmoved, love.touchreleased
  love.touchpressed = function(id, x, y, dx, dy, p)
    Touch.onPressed(id, x, y)
    if prevP then return prevP(id, x, y, dx, dy, p) end
  end
  love.touchmoved = function(id, x, y, dx, dy, p)
    Touch.onMoved(id, x, y)
    if prevM then return prevM(id, x, y, dx, dy, p) end
  end
  love.touchreleased = function(id, x, y, dx, dy, p)
    Touch.onReleased(id, x, y)
    if prevR then return prevR(id, x, y, dx, dy, p) end
  end
end

--- Auto-show: touch devices get the layer before the first frame; everyone else
--- gets it the instant a finger lands.
function Touch.load()
  Touch.install()
  local osn = love.system and love.system.getOS() or ""
  if osn == "iOS" or osn == "Android" then Touch.activate() end
  L.dirty = true
end

Input.touchModule = Touch
Touch.install()

return Touch
