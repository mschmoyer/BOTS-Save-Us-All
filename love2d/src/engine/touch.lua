-- The iPhone control layer.
--
-- Design brief: a player must be able to *play* this game with two thumbs on a
-- 6-inch pane of glass held in landscape. Landscape is the whole constraint.
-- The phone is gripped at the two bottom corners; the arcs a thumb sweeps out
-- from those corners are the only ground on the screen that is simultaneously
-- reachable and already hidden by a hand. Everything follows from that:
--
--   1. A floating left stick, in the mirrored arc. It spawns wherever the left
--      thumb lands, follows the thumb once it runs past the ring, has a dead
--      zone plus a small "grip" so a resting thumb's micro-jitter never nudges
--      the player -- and, until the player has actually used it, a *resting
--      ghost* sits at the thumb's home position saying so. A first touch screen
--      that shows five action buttons and no movement affordance teaches the
--      wrong game.
--   2. A right-hand cluster on two arcs. The near arc carries the three verbs
--      you press without thinking -- shove, dash, and the contextual
--      plant/carry -- one small pivot apart. The far arc carries the two
--      deliberate ones: the pulse you hold, and BUILD, whose radial needs open
--      screen to bloom into. Nothing is a diamond around a centre any more;
--      a diamond puts two buttons on the same baseline and their captions run
--      into each other. Every target is >= 44 pt of glass and carries its
--      caption *inside* its own disc, where nothing can clip it.
--   3. Utility above the thumbs. RALLY and MENU are not panic verbs, so they
--      live on the right rail under the minimap, out of the sweep, where
--      reaching for them is a deliberate act and a fumble cannot fire them.
--   4. Aim. Drag the right thumb on empty space to aim explicitly; otherwise
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
-- Layout is resolution-independent -- everything is a fraction of the short
-- screen edge -- and it lives in `game/tuning.lua`, not here. Nothing in update
-- or draw allocates.
local U        = require("src.core.util")
local P        = require("src.engine.palette")
local Draw     = require("src.engine.draw")
local Text     = require("src.engine.text")
local Input    = require("src.engine.input")
local Settings = require("src.game.settings")
local TU       = require("src.game.tuning")
local J        = require("src.engine.juice")
local Opt      = require("src.core.optional")
-- Read-only: the bot silhouettes (so a Sentry is the same shape in the radial
-- as on the desktop bar) and the HUD's published hit targets. hud.lua never
-- requires this file back -- it reaches the touch layer through package.loaded
-- -- so this is a one-way edge.
local HUD      = Opt.require("src.game.hud")

local lg = love.graphics
local cos, sin, atan2, sqrt = math.cos, math.sin, math.atan2, math.sqrt
local min, max, abs, floor  = math.min, math.max, math.abs, math.floor
local rad                   = math.rad
local pi, TAU               = math.pi, U.TAU

local Touch = {}

----------------------------------------------------------------------- config
-- Fractions of S = min(screenW, screenH) unless the name says otherwise.
-- This is the touch layout (spec section 10); it is defined in tuning.lua and
-- only read here, so no geometry in this file is a magic number.
local CFG = TU.touch
Touch.cfg = CFG

--------------------------------------------------------------------- public state
Touch.active      = false   -- true once touch is the player's device
Touch.opacity     = 0       -- current drawn opacity (damped)
Touch.enabled     = true
Touch.autoAimId   = nil     -- the entity auto-aim last locked (debug/HUD)
Touch.gate        = 1       -- 0 while the layer is hidden; presses are refused

local manualOpacity = 1
local visFade       = 0

---------------------------------------------------------------------- actions
-- `ring` and `seat` index into the arcs defined in tuning: near arc first (the
-- constant verbs), far arc second (the deliberate ones), rail last (the orders
-- nobody gives in a panic). (`slot`, on the same tables, is the finger that is
-- currently holding the button down -- a different thing entirely.)
--
-- Near-arc order is the whole ergonomic argument. DASH sits at the middle of
-- the sweep because it is the verb a player presses without deciding to; SHOVE
-- and the contextual PLANT/CARRY flank it one small pivot away on either side,
-- so "drop the bot you are carrying and dash" is a thumb roll rather than a
-- reach across the cluster.
local ACT = {
  { id = "shove", label = "SHOVE", ring = "in",   seat = 1, color = P.warn },
  { id = "dash",  label = "DASH",  ring = "in",   seat = 2, color = P.accentCool },
  { id = "plant", label = "PLANT", ring = "in",   seat = 3, color = P.ramp.leaf[3],
    context = true },
  { id = "pulse", label = "PULSE", ring = "out",  seat = 1, color = P.ramp.cobalt[4],
    hold = true },
  { id = "build", label = "BUILD", ring = "out",  seat = 2, color = P.accent,
    modal = true },
  { id = "rally", label = "ORDER", ring = "rail", seat = 1, color = P.accent },
  { id = "pause", label = "MENU",  ring = "rail", seat = 2, color = P.inkDim },
}
local ACT_N = #ACT
local BY_ID = {}
for i = 1, ACT_N do BY_ID[ACT[i].id] = ACT[i] end

for i = 1, ACT_N do
  local b = ACT[i]
  b.x, b.y, b.r, b.hitR = 0, 0, 0, 0
  b.press, b.sc, b.ripple = 0, 1, 0
  b.slot, b.holdT = nil, 0
  b.on = true                     -- rail buttons switch off where they have no room
end
Touch.buttons = ACT

--- The contextual verb. `plant` is already three things on the keyboard --
--- plant a sapling, pick a downed bot up, put it down again -- and which one it
--- is depends only on where you are standing. On a phone the button has to say
--- so: there is no key cap to read and no manual to have read.
local CONTEXT = {
  plant = { label = "PLANT", color = P.ramp.leaf[3] },
  carry = { label = "CARRY", color = P.eyeDown },
  drop  = { label = "DROP",  color = P.accent },
}
local context = "plant"
local contextPin = nil          -- set only by the capture harness, see BOTS_TOUCH

--- Called by the HUD each frame (it is the module that already holds the world).
--- "plant" | "carry" | "drop".
function Touch.setContext(kind)
  if contextPin then return end
  if CONTEXT[kind] then context = kind end
end
function Touch.getContext() return context end

--- Latched actions: a tap that lasts less than a polled frame still has to be
--- seen by input.lua, so every momentary press reports down for `CFG.latch`.
local latch = {}
for i = 1, ACT_N do latch[ACT[i].id] = 0 end
for i = 1, #TU.bots.order do latch["build" .. i] = 0 end
latch.map     = 0
latch.commit  = 0
latch.confirm = 0

------------------------------------------------------------------------ layout
local L = {
  w = 0, h = 0, s = 0, scale = 1, side = "right",
  sl = 0, st = 0, sr = 0, sb = 0,          -- safe-area insets
  px = 0, py = 0,                          -- the thumb pivot
  stickX0 = 0, stickX1 = 0, stickTop = 0,
  homeX = 0, homeY = 0, anchor = -1, safeW = -1, safeH = -1,
  ringR = 0, nubR = 0,
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

--- The insets anything on this screen should actually respect: the OS's, but
--- never less than an absolute floor. A browser that swears there is no notch
--- is still drawing a rounded display corner and a camera housing over the
--- outermost band, and on a native build there is no shell to pad the canvas.
--- The HUD reads this too, so the two layers agree about where the glass ends.
--- Keep the read insets current even if nothing has laid out yet: the HUD asks
--- for these to place its own readouts and it may ask first.
local ensureSafe
function Touch.safeInsets()
  ensureSafe()
  local f = CFG.safeFloor
  return max(L.sl, f), max(L.st, f), max(L.sr, f), max(L.sb, f)
end

local function readSafeArea(w, h, s)
  if safeManual then return end
  L.safeW, L.safeH = w, h
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

ensureSafe = function()
  local w, h = lg.getDimensions()
  if L.safeW == w and L.safeH == h then return end
  readSafeArea(w, h, min(min(w, h), max(w, h) * CFG.aspectRef))
end

--- Recompute every hit target. Only runs when something structural changed.
local function layout()
  local w, h = lg.getDimensions()
  local scale = Settings.get("touchScale")
  local side  = Settings.get("touchSide")
  local s = min(min(w, h), max(w, h) * CFG.aspectRef)
  if not L.dirty and w == L.w and h == L.h and scale == L.scale and side == L.side then return end
  L.w, L.h, L.s, L.scale, L.side, L.dirty = w, h, s, scale, side, false

  ensureSafe()
  local sl, st, sr, sb = Touch.safeInsets()

  local mirror = (side == "left") and -1 or 1

  -- the thumb pivot: the grip corner itself, one small inset in from the glass
  local pxI = s * CFG.pivotX * scale
  local pyI = s * CFG.pivotY * scale
  local px = (mirror > 0) and (w - sr - pxI) or (sl + pxI)
  local py = h - sb - pyI
  L.px, L.py = px, py

  local rIn, rOut = s * CFG.arcIn * scale, s * CFG.arcOut * scale
  local bIn, bOut = s * CFG.btnIn * scale, s * CFG.btnOut * scale
  local bRail = s * CFG.btnRail * scale

  -- The rail hangs off the bottom of the minimap plate, which the HUD owns and
  -- publishes. Without it (a demo scene, a stub world) it falls back to a
  -- sensible fraction of the way down the right edge.
  local railX, railY, railStep
  local tl = HUD.touchLayout and HUD.touchLayout()
  if tl and tl.on and type(tl.mapW) == "number" and tl.mapW > 0 then
    railX = (mirror > 0) and (tl.mapX - s * CFG.railDrop * scale - bRail)
                          or (tl.mapX + tl.mapW + s * CFG.railDrop * scale + bRail)
    railY = tl.mapY + bRail
  else
    railX = (mirror > 0) and (w - sr - bRail - s * CFG.railDrop * scale)
                          or (sl + bRail + s * CFG.railDrop * scale)
    railY = st + s * CFG.railFallback * scale
  end
  railStep = bRail * 2 + s * CFG.railGap * scale

  for i = 1, ACT_N do
    local b = ACT[i]
    local a, R, r
    if b.ring == "in" then
      a, R, r = rad(CFG.innerAng[b.seat]), rIn, bIn
    elseif b.ring == "out" then
      a, R, r = rad(CFG.outerAng[b.seat]), rOut, bOut
    else
      a, R, r = nil, nil, bRail
    end
    b.r = r
    b.hitR = r * CFG.btnHitPad
    if a then
      if mirror < 0 then a = pi - a end
      b.x = U.clamp(px + cos(a) * R, sl + r, w - sr - r)
      b.y = U.clamp(py + sin(a) * R, st + r, h - sb - r)
      b.on = true
    else
      -- the rail stacks down the map's inboard edge
      b.x = U.clamp(railX, sl + r, w - sr - r)
      b.y = railY + railStep * (b.seat - 1)
      b.on = true
    end
  end

  -- Whatever the screen shape, a rail button that has ended up inside the
  -- thumb's sweep is worse than no rail button: it is an accidental pause in a
  -- fight. Any that cannot keep clear of the arc simply switch off.
  for i = 1, ACT_N do
    local b = ACT[i]
    if b.ring == "rail" then
      b.y = U.clamp(b.y, st + b.r, h - sb - b.r)
      for k = 1, ACT_N do
        local o = ACT[k]
        if o.ring ~= "rail" then
          local dx, dy = b.x - o.x, b.y - o.y
          local reach = (b.r + o.r) * CFG.btnHitPad
          if dx * dx + dy * dy < reach * reach then b.on = false end
        end
      end
    end
  end

  -- the stick owns the opposite half, below the readouts
  if mirror > 0 then
    L.stickX0, L.stickX1 = 0, w * CFG.stickZoneX
  else
    L.stickX0, L.stickX1 = w * (1 - CFG.stickZoneX), w
  end
  L.stickTop = st + s * CFG.stickZoneTop
  L.ringR = s * CFG.stickRing * scale
  L.nubR  = s * CFG.stickNub * scale
  -- the ghost's resting place: where a left thumb actually sits
  L.homeX = (mirror > 0) and (sl + s * CFG.homeX * scale) or (w - sr - s * CFG.homeX * scale)
  L.homeY = h - sb - s * CFG.homeY * scale
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

-- How much of the movement lesson is still owed. Counts down only while the
-- stick is actually being pushed, so a player who has not found it yet keeps
-- being told, and one who has is never told again.
local taught = 0

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

--- The bounding box of the thumb cluster, in screen pixels, or nil when the
--- layer is not up. The HUD asks so that the one panel it puts in the freed
--- bottom band -- the dawn offer -- can be kept out from under a button.
function Touch.clusterBounds()
  if not Touch.active then return nil end
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, ACT_N do
    local b = ACT[i]
    if b.ring ~= "rail" and b.on and b.r > 0 then
      if b.x - b.r < x0 then x0 = b.x - b.r end
      if b.y - b.r < y0 then y0 = b.y - b.r end
      if b.x + b.r > x1 then x1 = b.x + b.r end
      if b.y + b.r > y1 then y1 = b.y + b.r end
    end
  end
  if x0 == math.huge then return nil end
  return x0, y0, x1, y1
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

--- What a bot actually costs right now.
---
--- `def.cost` is the sticker price and the world stopped charging it long ago:
--- every bot of a type already standing raises the next one's price. This wheel
--- is the *only* build UI a phone has, so it must quote the same figure the bar
--- quotes and the world charges -- and show the sticker price struck through
--- beside it, which is the only way the rule ever gets taught.
local function priceOf(id, def)
  local BM = package.loaded["src.game.buildmenu"]
  if BM and BM.cost then
    local ok, v = pcall(BM.cost, id)
    if ok and type(v) == "number" and v > 0 then return v end
  end
  return def.cost
end

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
    if b.slot == nil and b.on then
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

local function inRect(x, y, r)
  return r and r.w and r.w > 0
     and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

--- Readouts that are also buttons. The map plate opens the map; the HOLD THE
--- DAWN offer takes the trade. Both are already drawn, both already say what
--- they do, and on a phone a thing that looks tappable and is not is a bug.
--- Returns the action to latch, or nil.
local function hitHud(x, y)
  local tl = HUD.touchLayout and HUD.touchLayout()
  if not (tl and tl.on) then return nil end
  if tl.mapOpen then return "map" end          -- an open map closes on any tap
  if tl.hold and tl.holdOn and inRect(x, y, tl.hold) then return "commit" end
  if tl.map and inRect(x, y, tl.map) then return "map" end
  return nil
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
  -- The wheel grows out of the button, but the button lives in the grip corner
  -- and the wheel is 270 px across: opened where it was pressed, a third of it
  -- was off the bottom of the phone. So it is pulled back inside the safe box
  -- and the tether -- already drawn -- explains the offset.
  local r1 = L.s * CFG.radialOuter * L.scale * CFG.radialMargin
  local sl, st, sr, sb = Touch.safeInsets()
  radial.cx = U.clamp(b.x, min(sl + r1, L.w * 0.5), max(L.w - sr - r1, L.w * 0.5))
  radial.cy = U.clamp(b.y, min(st + r1, L.h * 0.5), max(L.h - sb - r1, L.h * 0.5))
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
  -- A cutscene owns the whole screen, so the whole screen is the button. There
  -- is no SPACE bar on a phone and the control layer has faded out under the
  -- letterbox with the rest of the chrome: without this the prologue is a
  -- dead end, which is a poor way to open a game.
  if HUD.cinematic then
    local ok, on = pcall(HUD.cinematic)
    if ok and on then
      latch.confirm = max(latch.confirm, CFG.latch * 1.5)
      buzz(CFG.hapticTap)
      return
    end
  end
  -- ...and a layer that has stepped out of the way for a menu takes nothing at
  -- all: a shove fired through the dawn draft is the bug invisible buttons are
  -- for.
  if (Touch.gate or 1) < CFG.gateMin then return end
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

  local hud = hitHud(x, y)
  if hud then
    latch[hud] = max(latch[hud] or 0, CFG.latch * 1.5)
    sl.role = "hud"
    buzz(CFG.hapticTap)
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
      taught = min(1, taught + dt / CFG.hintMove)
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

-- Capture harness only. Nothing in this game's touch layer can be judged from
-- source, and the headless runner has no finger: BOTS_TOUCH=radial holds the
-- build wheel open, BOTS_TOUCH=carry|drop pins the contextual button so the
-- three faces it wears can be photographed. Read once, never in a shipped run.
local demo = nil
local demoRead = false
local function demoMode()
  if not demoRead then
    demoRead = true
    demo = _G.BOTS_CFG and _G.BOTS_CFG("BOTS_TOUCH") or nil
    if demo == "" then demo = nil end
  end
  return demo
end

local function applyDemo()
  local d = demoMode()
  if not d then return end
  if d == "carry" or d == "drop" or d == "plant" then
    contextPin, context = d, d
  elseif d == "radial" then
    local b = BY_ID.build
    if not radial.open then
      local sl = slots[1]
      sl.id, sl.role, sl.btn = "demo", "btn", b
      b.slot, b.holdT = sl, 1
      openRadial(b)
    end
    local sl = radial.btn and radial.btn.slot
    if sl then
      sl.x = radial.cx - L.s * CFG.radialOuter * 0.62
      sl.y = radial.cy - L.s * CFG.radialOuter * 0.62
      radial.sel = radialPick(sl.x, sl.y)
    end
  end
end

function Touch.update(dt)
  if not osChecked then
    osChecked = true
    local osn = love.system and love.system.getOS() or ""
    if osn == "iOS" or osn == "Android" then Touch.activate() end
  end
  -- The HUD owns the rail's anchor, so a moved map plate is a structural change
  -- the same way a resize is. Compared rather than assumed: layout() is cheap
  -- but it is not free, and this runs sixty times a second.
  local tl = HUD.touchLayout and HUD.touchLayout()
  local anchor = (tl and tl.on) and (tl.mapX + tl.mapY * 4096 + tl.mapW * 16) or -1
  if anchor ~= L.anchor then L.anchor, L.dirty = anchor, true end
  layout()

  local visible = Touch.active and Touch.enabled and Input.scheme == "touch"
  visFade = U.damp(visFade, visible and 1 or 0, CFG.fade, dt)
  -- The controls belong to the same layer as the readouts and leave with them:
  -- five lit buttons standing over a cutscene's letterbox, or over the dawn
  -- draft, is the phone version of the bug where the HUD drew under the bars.
  local chrome = 1
  if HUD.chromeAlpha then
    local ok, v = pcall(HUD.chromeAlpha)
    if ok and type(v) == "number" then chrome = v end
  end
  Touch.opacity = visFade * manualOpacity * Settings.get("touchOpacity") * chrome
  -- ...and a layer that has stepped out of the way does not take presses. A
  -- shove fired through a pause menu, or through the dawn draft, is the exact
  -- bug a screen full of invisible buttons is for.
  Touch.gate = manualOpacity * chrome

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

  applyDemo()
  radial.fade = U.damp(radial.fade, radial.open and 1 or 0, 18, dt)
  if radial.open then
    radial.t = radial.t + dt
    -- the wheel holds time at a quarter, exactly as the desktop wheel does:
    -- a build menu that fully pauses kills the tension, one that does not
    -- punishes the slower hands a phone forces on you
    J.dilate(CFG.radialDilate, 0.16)
  end

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

--- What to print in a prompt for an action, in this layer's language.
---
--- Every touch prompt in the game used to read "TAP", which was true and
--- useless: with six things on the glass, "TAP SEND THEM SOMEWHERE" does not
--- say which of them. A verb that has a button is named by that button's own
--- caption -- including the contextual one, so a rescue hint reads CARRY the
--- moment you are standing over somebody. Anything without a button really is
--- just a tap, on the panel that is offering it.
function Touch.glyphFor(action)
  if action == "map" then return "MAP" end
  local b = BY_ID[action]
  if not b then return "TAP" end
  if b.context then return CONTEXT[context].label end
  return b.label
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
-- Drawn, not typeset: little diagrams of what the verb does.
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

--- A bot being lifted, or set down. The arrow is the whole message.
local function glyphCarry(x, y, s, c, a, down)
  lg.setLineWidth(max(2, s * 0.16))
  Draw.setColor(c, a)
  Draw.roundRect("line", x - s * 0.62, y - s * 0.10, s * 1.24, s * 0.86, s * 0.24)
  lg.line(x - s * 0.24, y + s * 0.30, x - s * 0.24, y + s * 0.36)
  lg.line(x + s * 0.24, y + s * 0.30, x + s * 0.24, y + s * 0.36)
  Draw.setColor(c, a)
  Draw.chevron(x, y - s * 0.72, s * 0.52, down and (pi * 0.5) or (-pi * 0.5),
               max(2, s * 0.17), 0.8)
end

local function glyphBuild(x, y, s, c, a)
  Draw.setColor(c, a)
  lg.setLineWidth(max(2, s * 0.15))
  Draw.hexagon(x, y, s * 0.82, 0, "line")
  Draw.setColor(c, a * 0.55)
  Draw.hexagon(x, y, s * 0.40, 0, "fill")
end

--- The standing order: a flag on a pole, with the ground it claims under it.
local function glyphRally(x, y, s, c, a)
  Draw.setColor(c, a)
  lg.setLineWidth(max(1.8, s * 0.15))
  lg.line(x - s * 0.34, y + s * 0.78, x - s * 0.34, y - s * 0.80)
  lg.polygon("fill", x - s * 0.34, y - s * 0.80, x + s * 0.62, y - s * 0.44,
             x - s * 0.34, y - s * 0.08)
  Draw.setColor(c, a * 0.55)
  lg.setLineWidth(max(1.5, s * 0.12))
  lg.arc("line", "open", x - s * 0.34, y + s * 0.78, s * 0.72, -pi * 0.85, -pi * 0.15, 12)
end

--- Two bars. Nothing else has ever meant anything else.
local function glyphPause(x, y, s, c, a)
  Draw.setColor(c, a)
  Draw.roundRect("fill", x - s * 0.52, y - s * 0.66, s * 0.34, s * 1.32, s * 0.12)
  Draw.roundRect("fill", x + s * 0.18, y - s * 0.66, s * 0.34, s * 1.32, s * 0.12)
end

local GLYPH = { dash = glyphDash, shove = glyphShove, pulse = glyphPulse,
                plant = glyphPlant, build = glyphBuild, rally = glyphRally,
                pause = glyphPause }

------------------------------------------------------------------- stick draw
--- The well the stick sits in: shared by the live stick and by the ghost that
--- teaches it, so the thing the player is taught and the thing they get are
--- visibly the same object.
local function stickPlate(x, y, r, a, mag, dx, dy)
  disc(x, y, r * 1.18, P.black, 0.22 * a, "smooth")
  ringStroke(x, y, r, max(1.5, r * 0.022), P.ink, 0.20 * a, 56)
  ringStroke(x, y, r * CFG.stickDead, max(1, r * 0.016), P.ink, 0.10 * a, 32)
  if mag > 0.01 then
    local ang = atan2(dy, dx)
    local sweep = 0.42 + mag * 0.32
    arcStroke(x, y, r, max(2.5, r * 0.055), ang - sweep, ang + sweep,
              P.accent, (0.20 + 0.55 * mag) * a)
  end
end

local function stickNub(x, y, r, nub, a, mag, dx, dy)
  local nx = x + dx * mag * (r - nub * 0.55)
  local ny = y + dy * mag * (r - nub * 0.55)
  disc(nx, ny + nub * 0.16, nub * 1.05, P.black, 0.30 * a, "shadow")
  disc(nx, ny, nub, P.black, 0.42 * a)
  disc(nx, ny, nub * 0.86, P.ink, (0.16 + 0.18 * mag) * a, "smooth")
  ringStroke(nx, ny, nub, max(1.8, nub * 0.10), P.ink, (0.45 + 0.35 * mag) * a, 40)
end

local function drawStick(alpha)
  local a = alpha * stick.fade
  if a < 0.01 then return end
  local x, y, r = stick.cx, stick.cy, L.ringR

  stickPlate(x, y, r, a, stick.mag, stick.dx, stick.dy)

  -- aim pip: where the game currently thinks you are pointing
  if (aim.active or Touch.autoAimId) and (aim.dx ~= 0 or aim.dy ~= 0) then
    local px, py = x + aim.dx * r * 1.32, y + aim.dy * r * 1.32
    Draw.setColor(P.warn, 0.55 * a)
    Draw.chevron(px, py, r * 0.16, atan2(aim.dy, aim.dx), max(2, r * 0.03), 0.8)
  end

  stickNub(x, y, r, L.nubR, a, stick.mag, stick.dx, stick.dy)
end

--- The lesson. Until the player has actually walked with the stick, the stick
--- is drawn where their thumb will find it, breathing, with the one line of
--- type this layer is allowed. It retires itself and never comes back.
local function drawStickGhost(alpha, time)
  local k = (1 - taught) * (1 - stick.fade)
  if k < 0.02 then return end
  local breath = 0.72 + 0.28 * sin(time * CFG.ghostPulse * TAU)
  local a = alpha * CFG.ghostA * k * breath
  if a < 0.01 then return end
  local x, y, r = L.homeX, L.homeY, L.ringR

  -- The ghost has to carry over a sunlit canopy, which the live stick never
  -- has to: the live stick has a thumb on it and the player already knows what
  -- it is. So it gets its own ground and a live rim rather than the plate's
  -- quiet grey, and it breathes.
  disc(x, y, r * 1.34, P.black, 0.34 * a, "smooth")
  stickPlate(x, y, r, a, 0, 0, 0)
  ringStroke(x, y, r, max(2, r * 0.038), P.accent, 0.55 * a, 56)
  stickNub(x, y, r, L.nubR, a, 0, 0, 0)

  -- four little chevrons around the well: it moves, and it moves any way
  for i = 0, 3 do
    local ang = i * pi * 0.5
    Draw.setColor(P.accent, 0.75 * a)
    Draw.chevron(x + cos(ang) * r * 1.32, y + sin(ang) * r * 1.32,
                 r * 0.17, ang, max(2, r * 0.042), 0.8)
  end
  Text.display("DRAG TO MOVE", x, y + r * 1.52, max(10, r * 0.22),
               { color = P.ink, alpha = min(1, 1.35 * a), align = "center",
                 tracking = 0.26, weight = 0.12, shadow = 2, snap = true })
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
  if a < 0.01 or not b.on then return end
  local r = b.r * b.sc
  local hot = b.press
  local col, label = b.color, b.label
  if b.context then
    local c = CONTEXT[context]
    col, label = c.color, c.label
  end

  -- contact shadow keeps the layer sitting *above* the world, not in it
  Draw.softShadow(b.x, b.y + b.r * 0.20, b.r * 1.02, b.r * 0.52, 0.30 * a)

  disc(b.x, b.y, r, P.black, (0.44 + 0.14 * hot) * a)
  disc(b.x, b.y, r * 0.94, col, (0.08 + 0.30 * hot) * a, "smooth")
  ringStroke(b.x, b.y, r, max(1.8, r * 0.045), col, (0.46 + 0.52 * hot) * a, 52)
  ringStroke(b.x, b.y, r * 0.86, max(1, r * 0.016), P.ink, 0.10 * a, 44)

  -- press ripple
  if b.ripple > 0 then
    local t = 1 - b.ripple
    ringStroke(b.x, b.y, r * (1 + t * 0.85), max(1.5, r * 0.05 * b.ripple),
               col, 0.55 * b.ripple * a, 48)
  end

  -- hold-to-charge dial (pulse), drawn as a filling ring from the top
  if b.hold and b.slot then
    local c = Touch.chargeAmount()
    arcStroke(b.x, b.y, r * 1.12, max(2.5, r * 0.075), -pi * 0.5, -pi * 0.5 + TAU * c,
              P.ink, 0.9 * a)
    if c >= 1 then
      disc(b.x, b.y, r * 1.5, col, 0.35 * a, "glow")
    end
  end

  -- Glyph above centre, caption below it -- both *inside* the disc. Captions
  -- hung underneath a button clip on the bottom row and collide with their
  -- neighbours on the diagonal, and this screen has neither the height nor the
  -- width to spare for either.
  local labelled = Settings.get("touchLabels") and a > 0.35
  local gs = r * (labelled and 0.40 or 0.46)
  local gy = b.y + r * (labelled and CFG.glyphOff or 0)
  local gf = GLYPH[b.context and "plant" or b.id]
  if b.context and context ~= "plant" then
    glyphCarry(b.x, gy, gs, col, (0.86 + 0.14 * hot) * a, context == "drop")
  elseif gf then
    gf(b.x, gy, gs, col, (0.86 + 0.14 * hot) * a)
  end
  lg.setLineJoin("miter")

  if labelled then
    Text.display(label, b.x, b.y + r * CFG.labelOff, max(8, r * CFG.labelSize),
                 { color = col, alpha = (0.70 + 0.25 * hot) * a, align = "center",
                   tracking = 0.14, weight = 0.11, snap = true })
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
  Draw.setColor(P.black, 0.34 * a)
  lg.rectangle("fill", 0, 0, L.w, L.h)
  disc(cx, cy, r1 * 1.9, P.black, 0.35 * a, "smooth")

  for i = 1, n do
    local id = TU.bots.order[i]
    local def = TU.bots[id]
    local a0 = -pi * 0.5 + (i - 1) * step + CFG.radialGap
    local a1 = -pi * 0.5 + i * step - CFG.radialGap
    local mid = (a0 + a1) * 0.5
    local on = (radial.sel == i)
    local cost = priceOf(id, def)
    local afford = (cobalt == nil) or (cobalt >= cost)
    local push = on and r1 * 0.045 or 0
    local wx, wy = cx + cos(mid) * push, cy + sin(mid) * push

    Draw.setColor(P.black, (on and 0.66 or 0.50) * a)
    wedge(wx, wy, r0, r1 + push, a0, a1)
    Draw.setColor(P.accent, (on and 0.30 or 0.07) * a * (afford and 1 or 0.4))
    wedge(wx, wy, r0, r1 + push, a0, a1)
    if on then
      arcStroke(wx, wy, r1 + push, max(2, r1 * 0.018), a0, a1, P.accent, 0.95 * a)
    end

    local lx = cx + cos(mid) * (r0 + r1) * 0.5
    local ly = cy + sin(mid) * (r0 + r1) * 0.5
    local col = afford and (on and P.ink or P.inkDim) or P.inkFaint
    -- the silhouette first: on a phone this wheel is the *only* build UI, and
    -- six words in a ring teach nothing the six shapes do not teach better
    if HUD.botGlyph then
      HUD.botGlyph(id, lx, ly - r1 * 0.20, r1 * CFG.radialGlyph * (on and 1.12 or 1),
                   afford and P.ramp.metal[3] or P.inkFaint, (afford and 1 or 0.45) * a)
    end
    Text.display(def.label, lx, ly + r1 * 0.09, r1 * (on and 0.098 or 0.088),
                 { color = col, alpha = a, align = "center", tracking = 0.10,
                   weight = 0.11, snap = true })
    local py2 = ly + r1 * 0.21
    if cost > def.cost then
      local bs = r1 * 0.072
      local base = tostring(def.cost)
      local bw = Text.measure(base, bs) or 0
      Text.display(base, lx - r1 * 0.055, py2 + bs * 0.16, bs,
                   { color = P.inkFaint, alpha = a * 0.85, align = "right",
                     tracking = 0.06, weight = 0.11, snap = true })
      Draw.setColor(P.inkFaint, a * 0.85)
      lg.setLineWidth(1)
      local sy = py2 + bs * 0.68
      lg.line(lx - r1 * 0.055 - bw - 1, sy, lx - r1 * 0.05, sy)
      Text.display(tostring(cost), lx - r1 * 0.03, py2, r1 * 0.088,
                   { color = afford and P.ramp.cobalt[4] or P.danger, alpha = a * 0.9,
                     align = "left", tracking = 0.06, weight = 0.11, snap = true })
    else
      Text.display(tostring(cost), lx, py2, r1 * 0.088,
                   { color = afford and P.ramp.cobalt[4] or P.danger, alpha = a * 0.9,
                     align = "center", tracking = 0.06, weight = 0.11, snap = true })
    end
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
  local time = love.timer and love.timer.getTime() or 0

  drawStickGhost(a, time)
  drawStick(a)
  drawAim(a)
  -- While the wheel is open it is the only thing on the glass that matters, and
  -- five half-lit buttons showing through six semi-transparent wedges is not a
  -- modal menu, it is a mess. They step out of the way and come back.
  local rest = a * (1 - radial.fade * 0.88)
  for i = 1, ACT_N do
    local b = ACT[i]
    if not b.modal then drawButton(b, rest) end
  end
  drawRadial(a)
  -- ...and the BUILD button goes entirely: the wheel's hub *is* the button now,
  -- and it says CANCEL or PLACE, which the button's own caption cannot.
  drawButton(BY_ID.build, a * (1 - radial.fade))

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
  -- BOTS_INPUT=touch brings the layer up without a finger, so the phone layout
  -- can be captured and looked at on a desktop or in the headless harness.
  if _G.BOTS_CFG and _G.BOTS_CFG("BOTS_INPUT") == "touch" then Touch.activate() end
  L.dirty = true
  taught = 0
end

Input.touchModule = Touch
Touch.install()

return Touch
