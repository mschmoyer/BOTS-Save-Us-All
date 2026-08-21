-- The HUD.
--
-- Read in one glance while being chased. Everything lives on the rim of the
-- screen; the middle third is never touched. The layout is an 8 px grid with a
-- 24 px safe inset, and every readout has exactly one job:
--
--   top left     cobalt (odometer) and forest count -- what you have
--   top centre   the OXYGEN arc -- the campaign, drawn as sky rather than a bar
--   top right    the cycle dial -- where you are in the run and how long is left
--   bottom left  hearts, and the event feed stacking up above them
--   bottom mid   the build bar (drawn by game/buildmenu.lua)
--   bottom right the workforce, by bot type
--   the edges    the dusk telegraph and the threat bleed
--
-- Allocation: zero tables per frame. Colours come from ui.lua's scratch ring,
-- numerals are memoised strings, the toast feed is a fixed pool, and every
-- Text call reuses one of a handful of option tables.
local U      = require("src.core.util")
local P      = require("src.engine.palette")
local Signal = require("src.core.signal")
local Opt    = require("src.core.optional")
local TU     = require("src.game.tuning")
local Input  = require("src.engine.input")
local UI     = require("src.engine.ui")
local Draw   = require("src.engine.draw")
local Text   = require("src.engine.text")
local J      = require("src.engine.juice")
local Audio  = Opt.require("src.engine.audio")

local lg = love.graphics
local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local cos, sin, pi = math.cos, math.sin, math.pi
local TAU = U.TAU

local HUD = {}

------------------------------------------------------------------ numerals
-- Memoised integer -> string. tostring() allocates; the HUD calls it about
-- twenty times a frame and the values barely move.
local ITOS = {}
local function itos(n)
  n = floor(n)
  local s = ITOS[n]
  if s == nil then
    s = tostring(n)
    if n > -100 and n < 100000 then ITOS[n] = s end
  end
  return s
end

local DEC1 = {}
local function dec1(v)
  local k = floor(v * 10 + 0.5)
  local s = DEC1[k]
  if s == nil then
    s = string.format("%.1f", k / 10)
    if k >= 0 and k <= 2000 then DEC1[k] = s end
  end
  return s
end

------------------------------------------------------------------- constants
local PAD   = UI.pad
local PHASE_LABEL = { day = "DAY", dusk = "DUSK", night = "NIGHT",
                      dawn = "DAWN", extraction = "EXTRACTION", ending = "ENDING" }
local O2_MILESTONES = { 10, 25, 50, 75, 90, 100 }

local function phaseColor(phase)
  if phase == "dusk" then return P.warn end
  if phase == "night" then return P.ramp.rift[4] end
  if phase == "dawn" then return P.ramp.ember[4] end
  if phase == "extraction" then return P.danger end
  return P.accent
end

--------------------------------------------------------------------- state
HUD.world     = nil
HUD.time      = 0
HUD.cob       = { v = 0 }
HUD.trees     = { v = 0 }
HUD.cobFlash  = 0
HUD.cobShake  = 0
HUD.treeFlash = 0
HUD.hurtFlash = 0
HUD.o2Pulse   = 0
HUD.o2Shown   = 0
HUD.o2Mile    = 0
HUD.duskK     = 0        -- 0..1 telegraph strength
HUD.sideX, HUD.sideY = 0, -1
HUD.threat    = 0
HUD.tick      = 0        -- last whole second of the dusk countdown
HUD.tickPunch = 0
HUD.alpha     = 1
HUD.hidden    = false

-- workforce tallies, recounted on a slow timer rather than every frame
local ROSTER = {}
for i = 1, #TU.bots.order do ROSTER[i] = 0 end
local rosterT = 0
local heartAnim = {}
for i = 1, 8 do heartAnim[i] = 0 end

-------------------------------------------------------------------- toasts
local TOAST_MAX = 6
local toasts = {}
for i = 1, TOAST_MAX do
  toasts[i] = { text = "", sub = nil, color = P.ink, t = 0, dur = 0, live = false, y = 0, yTo = 0 }
end

--- Push an event onto the feed. Oldest falls off the bottom of the pool.
function HUD.toast(text, color, sub, dur)
  local slot
  for i = 1, TOAST_MAX do
    if not toasts[i].live then slot = toasts[i] break end
  end
  if not slot then
    -- retire the oldest
    local oldest, ot = toasts[1], -1
    for i = 1, TOAST_MAX do
      if toasts[i].t > ot then ot = toasts[i].t oldest = toasts[i] end
    end
    slot = oldest
  end
  slot.text  = text
  slot.sub   = sub
  slot.color = color or P.ink
  slot.t     = 0
  slot.dur   = dur or 4.4
  slot.live  = true
  slot.y     = nil            -- nil = spawn at its resting place with a slide-in
  return slot
end

------------------------------------------------------------------ hit targets
-- Published for engine/touch.lua. Rebuilt only on resize, never per frame.
local hits = {
  oxygen  = { x = 0, y = 0, w = 0, h = 0 },
  cycle   = { x = 0, y = 0, w = 0, h = 0 },
  cobalt  = { x = 0, y = 0, w = 0, h = 0 },
  hearts  = { x = 0, y = 0, w = 0, h = 0 },
  roster  = { x = 0, y = 0, w = 0, h = 0 },
  build   = { x = 0, y = 0, w = 0, h = 0 },
}
function HUD.hitTargets() return hits end

local L = {   -- resolved layout, rebuilt on resize
  sw = 0, sh = 0,
  o2x = 0, o2y = 0, o2w = 0, o2R = 0, o2cx = 0, o2cy = 0, o2a0 = 0, o2a1 = 0,
  dialX = 0, dialY = 0, dialR = 0,
  feedX = 0, feedY = 0,
}

local function layout(sw, sh)
  if L.sw == sw and L.sh == sh then return end
  L.sw, L.sh = sw, sh

  -- oxygen: a shallow arc struck from far below the screen, so it reads as
  -- horizon rather than as a widget.
  local w = U.clamp(sw * 0.40, 320, 620)
  w = floor(w / UI.u) * UI.u
  L.o2w = w
  L.o2x = floor((sw - w) * 0.5)
  L.o2y = PAD + 14
  local R = w * 2.35
  L.o2R = R
  L.o2cx = sw * 0.5
  L.o2cy = L.o2y + R
  local half = math.asin(U.clamp(w * 0.5 / R, 0, 1))
  L.o2a0 = -pi * 0.5 - half
  L.o2a1 = -pi * 0.5 + half

  L.dialR = 34
  L.dialX = sw - PAD - L.dialR
  L.dialY = PAD + L.dialR + 4

  L.feedX = PAD
  L.feedY = sh - PAD - 82

  hits.oxygen.x, hits.oxygen.y = L.o2x, PAD
  hits.oxygen.w, hits.oxygen.h = w, 64
  hits.cycle.x, hits.cycle.y = L.dialX - L.dialR - 8, L.dialY - L.dialR - 8
  hits.cycle.w, hits.cycle.h = (L.dialR + 8) * 2, (L.dialR + 8) * 2
  hits.cobalt.x, hits.cobalt.y, hits.cobalt.w, hits.cobalt.h = PAD, PAD, 200, 108
  hits.hearts.x, hits.hearts.y = PAD, sh - PAD - 48
  hits.hearts.w, hits.hearts.h = 200, 48
  hits.roster.x, hits.roster.y = sw - PAD - 300, sh - PAD - 56
  hits.roster.w, hits.roster.h = 300, 56
  hits.build.x, hits.build.y = sw * 0.5 - 336, sh - PAD - 76
  hits.build.w, hits.build.h = 672, 76
end

--------------------------------------------------------------------- signals
local bound = false
function HUD.init(world)
  HUD.world = world
  HUD.time = 0
  HUD.cob.v = world and world.cobalt or 0
  HUD.trees.v = world and world.treeCount or 0
  HUD.o2Shown = world and world.o2 or 0
  HUD.o2Mile = 0
  HUD.duskK, HUD.threat = 0, 0
  for i = 1, TOAST_MAX do toasts[i].live = false end

  -- The world draws bot speech in world space through Draw.speechBubble.
  -- The shape vocabulary does not own one, so the HUD supplies the styling.
  local Dr = Opt.require("src.engine.draw")
  if Dr and rawget(Dr, "speechBubble") == nil then
    Dr.speechBubble = function(x, y, text, alpha) HUD.speechBubble(x, y, text, alpha) end
  end

  if bound then return end
  bound = true

  Signal.on("cobalt:gained", function(n)
    HUD.cobFlash = min(1, HUD.cobFlash + 0.5 + min(n, 8) * 0.06)
  end)
  Signal.on("cobalt:spent", function() HUD.cobFlash = max(HUD.cobFlash, 0.28) end)
  Signal.on("ui:denied", function() HUD.cobShake = 1 end)
  Signal.on("player:hurt", function() HUD.hurtFlash = 1 end)

  Signal.on("bot:built", function(b)
    HUD.toast(b.name, P.accentCool, "ONLINE")
  end)
  Signal.on("bot:lost", function(b, peaceful)
    if peaceful then return end
    HUD.toast(b.name, P.danger, "LOST", 6.0)
  end)
  Signal.on("bot:revived", function(b) HUD.toast(b.name, P.accent, "BACK ON ITS FEET") end)
  Signal.on("chip:added", function(c) HUD.toast(c.name, P.ramp.ember[4], c.f, 5.5) end)
  Signal.on("director:dawn", function() HUD.toast("NIGHT SURVIVED", P.accent, nil, 5) end)
  Signal.on("phase:dusk", function(cycle, sx, sy)
    HUD.sideX, HUD.sideY = sx or 0, sy or -1
    HUD.toast("DUSK", P.warn, "THE RIFT IS OPENING", 5)
  end)

  Signal.on("tree:planted", function()
    HUD.treeFlash = 1
    local w = HUD.world
    if not w then return end
    local n = w.treeCount
    if n == 10 or n == 25 or n == 50 or n == 100 or n == 200 or n == 400 then
      HUD.toast(itos(n) .. " TREES", P.accent, "THE FOREST REMEMBERS", 5)
      Audio.play("o2_milestone", { volume = 0.6 })
    end
  end)
end

------------------------------------------------------------------------ update
function HUD.update(dt, world)
  world = world or HUD.world
  HUD.world = world
  if dt <= 0 then dt = 1 / 1000 end
  HUD.time = HUD.time + dt
  if not world then return end

  local sw, sh = lg.getDimensions()
  layout(sw, sh)

  Text.odometer(HUD.cob, world.cobalt or 0, dt, 9)
  Text.odometer(HUD.trees, world.treeCount or 0, dt, 7)
  HUD.o2Shown = U.damp(HUD.o2Shown, world.o2 or 0, 5, dt)

  HUD.cobFlash  = max(0, HUD.cobFlash - dt * 2.4)
  HUD.cobShake  = max(0, HUD.cobShake - dt * 3.6)
  HUD.treeFlash = max(0, HUD.treeFlash - dt * 2.2)
  HUD.hurtFlash = max(0, HUD.hurtFlash - dt * 1.8)
  HUD.o2Pulse   = max(0, HUD.o2Pulse - dt * 0.9)
  HUD.tickPunch = max(0, HUD.tickPunch - dt * 5)

  -- oxygen milestones are the campaign's only applause
  local o2 = world.o2 or 0
  for i = 1, #O2_MILESTONES do
    local m = O2_MILESTONES[i]
    if o2 >= m and HUD.o2Mile < m then
      HUD.o2Mile = m
      HUD.o2Pulse = 1
      HUD.toast("OXYGEN " .. itos(m) .. "%", P.o2, "ATMOSPHERE RISING", 5.5)
      Audio.play("o2_milestone")
      J.flashScreen(0.05, P.o2[1], P.o2[2], P.o2[3])
    end
  end

  -- threat + dusk telegraph
  local th = (world.threat and world:threat()) or 0
  HUD.threat = U.damp(HUD.threat, th, 2.2, dt)
  local wantDusk = 0
  if world.phase == "dusk" then
    wantDusk = 0.35 + 0.65 * U.saturate(world.phaseDur > 0 and world.phaseT / world.phaseDur or 0)
    if world.director and world.director.sideVector then
      HUD.sideX, HUD.sideY = world.director:sideVector()
    end
  elseif world.phase == "night" then
    wantDusk = 0.16 + 0.34 * HUD.threat
  end
  HUD.duskK = U.damp(HUD.duskK, wantDusk, 3.2, dt)

  -- dusk clock: a punch on every whole second so the countdown has a pulse
  if world.phase == "dusk" then
    local left = max(0, (world.phaseDur or 0) - (world.phaseT or 0))
    local whole = math.ceil(left)
    if whole ~= HUD.tick then
      HUD.tick = whole
      HUD.tickPunch = 1
    end
  else
    HUD.tick = -1
  end

  -- workforce census, four times a second
  rosterT = rosterT - dt
  if rosterT <= 0 then
    rosterT = 0.25
    for i = 1, #ROSTER do ROSTER[i] = 0 end
    local bots = world.bots
    if bots then
      for i = 1, #bots do
        local b = bots[i]
        if b.alive and b.state ~= "dead" then
          for k = 1, #TU.bots.order do
            if TU.bots.order[k] == b.type then ROSTER[k] = ROSTER[k] + 1 break end
          end
        end
      end
    end
  end

  -- toast feed: settle each live toast into its slot
  local idx = 0
  for i = 1, TOAST_MAX do
    local t = toasts[i]
    if t.live then
      t.t = t.t + dt
      if t.t >= t.dur then t.live = false end
    end
  end
  for i = 1, TOAST_MAX do
    local t = toasts[i]
    if t.live then
      t.yTo = -idx * 34
      if t.y == nil then t.y = t.yTo + 22 end
      t.y = U.damp(t.y, t.yTo, 14, dt)
      idx = idx + 1
    else
      t.y = nil
    end
  end
end

--------------------------------------------------------------------- glyphs
--- The bot vocabulary, drawn small. Shared with the build bar and the radial
--- menu so a Sentry is the same silhouette everywhere in the game.
function HUD.botGlyph(botType, x, y, r, color, alpha)
  alpha = alpha or 1
  local c = color or P.ramp.metal[3]
  lg.setLineWidth(max(1.4, r * 0.16))
  Draw.setColor(UI.c(c, alpha))
  if botType == "planter" then
    Draw.roundRect("line", x - r * 0.62, y - r * 0.5, r * 1.24, r * 1.1, r * 0.26)
    lg.line(x, y - r * 0.5, x, y - r * 1.05)
    Draw.setColor(UI.c(P.accent, alpha))
    lg.circle("fill", x, y - r * 1.15, r * 0.24, 10)
  elseif botType == "builder" then
    Draw.roundRect("line", x - r * 0.7, y - r * 0.62, r * 1.4, r * 1.24, r * 0.2)
    lg.line(x - r * 0.34, y - r * 0.1, x + r * 0.34, y - r * 0.1)
    lg.line(x, y - r * 0.1, x, y + r * 0.44)
  elseif botType == "repulsor" then
    lg.line(x - r * 0.44, y + r * 0.72, x, y - r * 0.5)
    lg.line(x + r * 0.44, y + r * 0.72, x, y - r * 0.5)
    Draw.setColor(UI.c(c, alpha * 0.55))
    lg.circle("line", x, y - r * 0.34, r * 0.82, 18)
  elseif botType == "sentry" then
    Draw.diamond(x, y + r * 0.1, r * 0.64, r * 0.78, "line")
    lg.line(x, y - r * 0.66, x, y - r * 1.12)
    Draw.setColor(UI.c(P.acid, alpha))
    lg.circle("fill", x, y - r * 1.2, r * 0.2, 8)
  elseif botType == "harvester" then
    Draw.roundRect("line", x - r * 0.72, y - r * 0.34, r * 1.44, r * 0.86, r * 0.2)
    lg.circle("line", x - r * 0.4, y + r * 0.66, r * 0.26, 10)
    lg.circle("line", x + r * 0.4, y + r * 0.66, r * 0.26, 10)
  else -- beacon
    lg.line(x - r * 0.5, y + r * 0.8, x - r * 0.22, y - r * 0.2)
    lg.line(x + r * 0.5, y + r * 0.8, x + r * 0.22, y - r * 0.2)
    Draw.setColor(UI.c(P.eye, alpha))
    lg.circle("fill", x, y - r * 0.52, r * 0.34, 12)
    Draw.glow(x, y - r * 0.52, r * 1.7, P.eye, 0.35 * alpha, 2)
  end
end

--- A cobalt shard.
local function cobaltGlyph(x, y, r, alpha, hot)
  Draw.setColor(UI.c(P.ramp.cobalt[2], alpha))
  Draw.diamond(x, y, r * 0.78, r, "fill")
  Draw.setColor(UI.mix(P.ramp.cobalt[3], P.ramp.cobalt[4], hot or 0, alpha))
  Draw.diamond(x, y - r * 0.06, r * 0.5, r * 0.66, "fill")
  if hot and hot > 0.01 then Draw.glow(x, y, r * 3.4, P.ramp.cobalt[4], 0.5 * hot, 2) end
end

--- A little canopy.
local function treeGlyph(x, y, r, alpha, hot)
  Draw.setColor(UI.c(P.ramp.bark[2], alpha))
  lg.setLineWidth(max(1.4, r * 0.2))
  lg.line(x, y + r * 0.9, x, y - r * 0.1)
  Draw.setColor(UI.mix(P.ramp.leaf[3], P.ramp.leafHi[4], hot or 0, alpha))
  Draw.blob(x, y - r * 0.42, r * 0.86, 12, 7, 0.16, 0.88, "fill")
end

--------------------------------------------------------------------- scrims
--- The HUD has to be readable over a noon meadow and over a purple rift, so it
--- seats itself on a little darkness. Bands on the two edges that carry
--- readouts, plus a touch more weight in the four corners where the densest
--- clusters live. Deliberately short of anything that reads as a panel.
-- One soft ellipse per cluster (never a rectangle -- a rectangle of shadow has
-- an edge, and an edge reads as a panel), plus two very light edge bands to tie
-- them together.
local function drawScrims(a)
  local sw, sh = L.sw, L.sh
  UI.vgrad(0, 0, sw, 120, P.black, P.black, 0.18 * a, 0)
  UI.vgrad(0, sh - 130, sw, 130, P.black, P.black, 0, 0.22 * a)
  Draw.softShadow(PAD + 40, PAD + 52, 265, 165, 0.62 * a)         -- cobalt / forest
  Draw.softShadow(sw * 0.5, L.o2y + 36, 350, 130, 0.48 * a)       -- oxygen
  Draw.softShadow(L.dialX, L.dialY + 6, 265, 155, 0.62 * a)       -- cycle dial
  Draw.softShadow(PAD + 70, sh - PAD - 78, 320, 220, 0.58 * a)    -- hearts + feed
  Draw.softShadow(sw - PAD - 140, sh - PAD - 28, 280, 130, 0.58 * a) -- workforce
  Draw.softShadow(sw * 0.5, sh - PAD - 34, 450, 120, 0.46 * a)    -- build bar
end

------------------------------------------------------------------- the oxygen
local function drawOxygen(w, a)
  local t = U.saturate(HUD.o2Shown / TU.o2.target)
  local a0, a1 = L.o2a0, L.o2a1
  local cx, cy, R = L.o2cx, L.o2cy, L.o2R
  local pulse = U.ease.outQuint(U.saturate(HUD.o2Pulse))

  -- the atmosphere itself: a low, wide bloom above the arc that thickens as
  -- the air comes back. This is the diegetic half of the meter.
  local apexY = cy - R
  Draw.glow(cx, apexY + 26, L.o2w * (0.34 + 0.3 * t), P.o2,
            (0.05 + 0.16 * t + 0.5 * pulse) * a, 3)

  -- track
  Draw.ring(cx, cy, R, 3, a0, a1, UI.c(P.ink, 0.12 * a))
  -- fill
  local ae = a0 + (a1 - a0) * t
  if t > 0.004 then
    Draw.ring(cx, cy, R, 4 + pulse * 3, a0, ae, UI.c(P.o2, (0.85 + 0.15 * pulse) * a), 3)
  end

  -- milestone ticks, labelled at the quarters
  for i = 1, #O2_MILESTONES do
    local m = O2_MILESTONES[i]
    local mt = m / TU.o2.target
    local ang = a0 + (a1 - a0) * mt
    local px, py = cx + cos(ang) * R, cy + sin(ang) * R
    local nx, ny = cos(ang), sin(ang)
    local passed = t >= mt
    Draw.setColor(UI.c(passed and P.o2 or P.ink, (passed and 0.75 or 0.2) * a))
    lg.setLineWidth(passed and 2 or 1)
    lg.line(px - nx * 5, py - ny * 5, px - nx * 12, py - ny * 12)
  end

  -- the leading spark
  local ex, ey = cx + cos(ae) * R, cy + sin(ae) * R
  if t > 0.004 then
    Draw.glow(ex, ey, 16 + pulse * 26, P.o2, (0.6 + pulse) * a, 3)
    Draw.setColor(UI.c(P.white, (0.85 + 0.15 * sin(HUD.time * 6)) * a))
    lg.circle("fill", ex, ey, 2.6, 10)
  end

  -- The arc is the picture; this is its caption. One baseline, three parts:
  -- what it is, what it reads, and what it is aiming at. Nothing sits on top of
  -- the arc, which is why the numeral hangs below it rather than inside it.
  local ny2 = L.o2y + 30
  local numSize = UI.ts.h2 * (1 + pulse * 0.12)
  local base = ny2 + numSize * 0.36
  local nw = UI.text(dec1(HUD.o2Shown), cx - 6, ny2, numSize,
                     UI.mix(P.ink, P.o2, 0.35 + 0.65 * pulse), "right", a, 0.02)
  UI.text("%", cx - 2, base, UI.ts.small, UI.c(P.o2, 0.7 * a), "left", a, 0.05)
  UI.caption("OXYGEN", cx - 6 - nw - 14, base + 2, UI.ts.micro,
             UI.c(P.inkDim, 0.8 * a), "right")
  UI.caption("TARGET " .. itos(TU.o2.target), cx + 34, base + 2, UI.ts.micro,
             UI.c(P.inkDim, 0.62 * a), "left")
end

-------------------------------------------------------------------- the dial
local function drawCycleDial(w, a)
  local cx, cy, R = L.dialX, L.dialY, L.dialR
  local phase = w.phase or "day"
  local pc = phaseColor(phase)
  local extracting = phase == "extraction"
  local p, left
  if extracting then
    -- the rig's own clock: how much of the sky it has left to take
    p = 1 - U.saturate((w.o2 or 0) / TU.o2.target)
    left = nil
  else
    p = U.saturate(w.phaseDur and w.phaseDur > 0 and (w.phaseT / w.phaseDur) or 0)
    left = max(0, (w.phaseDur or 0) - (w.phaseT or 0))
  end
  local urgent = extracting or (phase == "dusk")
                 or (phase ~= "night" and left and left < 10 and w.phaseDur and w.phaseDur > 0)

  -- cycle pips: seven segments of the run, arranged as a broken outer ring
  local n = TU.cycle.count
  local gap = 0.1
  for i = 1, n do
    local s0 = -pi * 0.5 + (i - 1) / n * TAU + gap * 0.5
    local s1 = -pi * 0.5 + i / n * TAU - gap * 0.5
    local done = i < (w.cycle or 1)
    local cur  = i == (w.cycle or 1)
    local col = cur and pc or (done and P.accent or P.ink)
    Draw.ring(cx, cy, R + 7, cur and 3 or 2, s0, s1,
              UI.c(col, ((cur and 0.95) or (done and 0.5) or 0.13) * a))
  end

  -- phase ring: drains, so it always reads as time running out
  Draw.setColor(UI.c(P.black, 0.5 * a))
  lg.circle("fill", cx, cy, R, 40)
  Draw.ring(cx, cy, R - 3, 3, -pi * 0.5, -pi * 0.5 + TAU, UI.c(P.ink, 0.09 * a))
  local sweep = TAU * (1 - p)
  if sweep > 0.01 then
    local puls = urgent and (0.75 + 0.25 * sin(HUD.time * 7)) or 1
    Draw.ring(cx, cy, R - 3, 3, -pi * 0.5, -pi * 0.5 + sweep, UI.c(pc, 0.95 * puls * a),
              urgent and 3 or 0)
  end

  -- seconds remaining, punched on each tick. During the extraction there is no
  -- countdown to show, so the dial reads the sky the rig is taking instead.
  local punch = U.ease.outQuad(HUD.tickPunch)
  local secSize = UI.ts.h3 * (1 + punch * (urgent and 0.24 or 0.08))
  local centre = left and itos(math.ceil(left)) or (itos(math.floor(w.o2 or 0)) .. "%")
  if extracting then secSize = UI.ts.h4 end
  UI.text(centre, cx, cy - secSize * 0.5 + 1, secSize,
          UI.mix(P.ink, pc, urgent and 1 or 0.25), "center", a, 0.0)

  -- phase name + cycle, to the left of the dial, right-aligned to it
  local tx = cx - R - 16
  UI.text(PHASE_LABEL[phase] or "--", tx, cy - 17, UI.ts.h4,
          UI.mix(P.ink, pc, urgent and 0.8 or 0.15), "right", a, 0.14)
  UI.caption(extracting and "THE SKY THEY HAVE TAKEN"
             or ("CYCLE " .. itos(w.cycle or 1) .. " OF " .. itos(TU.cycle.count)),
             tx, cy + 6, UI.ts.micro, UI.c(P.inkDim, 0.8 * a), "right")

  if urgent then
    UI.brackets(cx - R - 10, cy - R - 10, (R + 10) * 2, (R + 10) * 2, 12, pc,
                (0.5 + 0.5 * sin(HUD.time * 7)) * a, 2, 0)
  end
end

----------------------------------------------------------------- resources
local function drawResources(w, a)
  local x, y = PAD, PAD
  local shake = HUD.cobShake > 0 and sin(HUD.cobShake * 46) * HUD.cobShake * 5 or 0
  local flash = U.ease.outQuad(HUD.cobFlash)

  -- cobalt
  cobaltGlyph(x + 11 + shake, y + 20, 11, a, flash)
  local cobColor = UI.mix(P.ramp.cobalt[4], P.white, flash * 0.7)
  if HUD.cobShake > 0.02 then cobColor = UI.mix(P.ramp.cobalt[4], P.danger, HUD.cobShake) end
  UI.text(itos(HUD.cob.v), x + 30 + shake, y + 4, UI.ts.h2 * (1 + flash * 0.06),
          cobColor, "left", a, 0.02)
  UI.caption("COBALT", x + 30 + shake, y + 40, UI.ts.micro, UI.c(P.inkDim, 0.85 * a), "left")

  -- forest
  local ty = y + 60
  local tflash = U.ease.outQuad(HUD.treeFlash)
  treeGlyph(x + 11, ty + 16, 11, a, tflash)
  UI.text(itos(HUD.trees.v), x + 30, ty + 2, UI.ts.h3 * (1 + tflash * 0.06),
          UI.mix(P.accent, P.white, tflash * 0.6), "left", a, 0.02)
  UI.caption("FOREST", x + 30, ty + 30, UI.ts.micro, UI.c(P.inkDim, 0.85 * a), "left")

  -- a hairline that ties the two together
  UI.rule(x, y + 52, 108, P.ink, 0.1 * a)
end

------------------------------------------------------------------- hearts
local function drawHearts(w, a)
  local p = w.player
  if not p then return end
  local x, y = PAD, L.sh - PAD - 26
  local hurt = U.ease.outQuad(HUD.hurtFlash)
  local shake = hurt > 0 and sin(HUD.time * 60) * hurt * 3 or 0
  local n = p.maxHp or 3
  for i = 1, n do
    local hx = x + (i - 1) * 26 + shake
    local full = i <= (p.hp or 0)
    heartAnim[i] = U.damp(heartAnim[i] or 0, full and 1 or 0, 12, 1 / 60)
    local k = heartAnim[i]
    -- shield chevron
    lg.setLineWidth(2.5)
    Draw.setColor(UI.c(P.ink, (0.12 + 0.1 * k) * a))
    Draw.chevron(hx + 9, y + 4, 11, -pi * 0.5, 3, 0.85)
    Draw.setColor(UI.mix(P.inkFaint, P.danger, k, (0.35 + 0.65 * k) * a))
    Draw.chevron(hx + 9, y, 11, -pi * 0.5, 3, 0.85)
    if full then
      Draw.setColor(UI.mix(P.danger, P.white, hurt * 0.8, (0.55 + 0.45 * k) * a))
      Draw.chevron(hx + 9, y + 6, 7, -pi * 0.5, 3, 0.85)
      if hurt > 0.01 and i == (p.hp or 0) + 1 then
        Draw.glow(hx + 9, y + 2, 26, P.danger, hurt * 0.8, 2)
      end
    end
  end
  UI.caption("INTEGRITY", x, y + 20, UI.ts.micro, UI.c(P.inkDim, 0.7 * a), "left")

  -- reboot timer, if the player is down
  if p.state == "down" then
    local left = max(0, (p.downTimer or 0))
    UI.text("REBOOT " .. itos(math.ceil(left)), x, y - 30, UI.ts.label,
            UI.c(P.warn, a), "left", a, 0.12)
  end
end

------------------------------------------------------------------- workforce
local function drawRoster(w, a)
  local order = TU.bots.order
  local n = #order
  local cellW = 46
  local x0 = L.sw - PAD - n * cellW
  local y = L.sh - PAD - 34
  UI.caption("WORKFORCE", L.sw - PAD, y - 16, UI.ts.micro, UI.c(P.inkDim, 0.8 * a), "right")
  local total = 0
  for i = 1, n do total = total + ROSTER[i] end
  for i = 1, n do
    local cx = x0 + (i - 1) * cellW + cellW * 0.5
    local count = ROSTER[i]
    local live = count > 0
    HUD.botGlyph(order[i], cx, y + 8, 11, live and P.ramp.metal[3] or P.inkFaint,
                 (live and 0.95 or 0.28) * a)
    UI.text(itos(count), cx, y + 22, UI.ts.small,
            UI.c(live and P.ink or P.inkFaint, (live and 1 or 0.3) * a), "center", a, 0.02)
  end
  UI.rule(x0, y - 8, n * cellW, P.ink, 0.09 * a)
  if total > 0 then
    UI.caption(itos(total) .. " ONLINE", x0, y - 16, UI.ts.micro,
               UI.c(P.accentCool, 0.8 * a), "left")
  end
end

--------------------------------------------------------------------- feed
local function drawFeed(a)
  local x, baseY = L.feedX, L.feedY
  for i = 1, TOAST_MAX do
    local t = toasts[i]
    if t.live and t.y then
      local k = U.saturate(min(t.t * 5, (t.dur - t.t) * 2.2))
      local slide = (1 - U.ease.outCubic(U.saturate(t.t * 4))) * -18
      local y = baseY + t.y
      local aa = a * k
      -- accent tick
      Draw.setColor(UI.c(t.color, 0.9 * aa))
      Draw.roundRect("fill", x + slide, y + 4, 3, 20, 1.5)
      UI.text(t.text, x + 12 + slide, y + 4, UI.ts.label, UI.c(P.ink, aa), "left", aa, 0.06)
      if t.sub then
        local tw = Text.measure(t.text, UI.ts.label, nil)
        UI.caption(t.sub, x + 12 + slide + tw + 10, y + 9, UI.ts.micro,
                   UI.c(t.color, 0.85 * aa), "left")
      end
    end
  end
end

--------------------------------------------------------- dusk telegraph & threat
--- The Blight's approach vector, drawn on the screen edge it will arrive from.
local function drawTelegraph(w, a)
  local k = HUD.duskK
  if k < 0.01 then return end
  local sw, sh = L.sw, L.sh
  local sx, sy = HUD.sideX, HUD.sideY
  local depth = 120 * (0.5 + 0.5 * k)
  local pulse = 0.55 + 0.45 * sin(HUD.time * (w.phase == "dusk" and 5.5 or 2.2))
  local aa = a * k * pulse
  local col = w.phase == "dusk" and P.warn or P.ramp.blight[4]

  -- the bleed on that edge
  if sy < -0.5 then
    UI.vgrad(0, 0, sw, depth, col, col, 0.3 * aa, 0)
  elseif sy > 0.5 then
    UI.vgrad(0, sh - depth, sw, depth, col, col, 0, 0.3 * aa)
  elseif sx < -0.5 then
    UI.hgrad(0, 0, depth, sh, col, col, 0.3 * aa, 0)
  else
    UI.hgrad(sw - depth, 0, depth, sh, col, col, 0, 0.3 * aa)
  end

  -- chevrons marching inward from that edge
  local cx, cy, ang
  if sy < -0.5 then cx, cy, ang = sw * 0.5, 0, pi * 0.5
  elseif sy > 0.5 then cx, cy, ang = sw * 0.5, sh, -pi * 0.5
  elseif sx < -0.5 then cx, cy, ang = 0, sh * 0.5, 0
  else cx, cy, ang = sw, sh * 0.5, pi end
  local nx, ny = cos(ang), sin(ang)
  local tx, ty = -ny, nx
  local march = (HUD.time * 46) % 34
  for i = 0, 2 do
    local d = 30 + i * 34 + march
    local fade = (1 - i / 3) * aa
    for s = -1, 1, 2 do
      local px = cx + nx * d + tx * s * 44
      local py = cy + ny * d + ty * s * 44
      lg.setLineWidth(3)
      Draw.setColor(UI.c(col, fade * 0.75))
      Draw.chevron(px, py, 11, ang, 3, 0.8)
    end
  end
  -- the word, set into the edge
  local lx = cx + nx * 26 + tx * 0
  local ly = cy + ny * 26 + ty * 0
  local label = w.phase == "dusk" and "BREACH" or "PRESSURE"
  if abs(nx) > 0.5 then
    lg.push()
    lg.translate(lx, ly)
    lg.rotate(nx > 0 and pi * 0.5 or -pi * 0.5)
    UI.text(label, 0, -UI.ts.tiny * 0.5, UI.ts.tiny, UI.c(col, aa), "center", aa, 0.28)
    lg.pop()
  else
    UI.text(label, lx, ly - (ny > 0 and UI.ts.tiny or 0), UI.ts.tiny,
            UI.c(col, aa), "center", aa, 0.28)
  end
end

--- Threat bleeds in from every edge, quietly, so the screen itself tightens.
local function drawThreat(a)
  local k = HUD.threat
  if k < 0.02 then return end
  local sw, sh = L.sw, L.sh
  local d = 150
  local aa = 0.20 * k * a
  UI.vgrad(0, 0, sw, d, P.ramp.blight[2], P.ramp.blight[2], aa * 0.7, 0)
  UI.vgrad(0, sh - d, sw, d, P.ramp.blight[2], P.ramp.blight[2], 0, aa)
  UI.hgrad(0, 0, d, sh, P.ramp.blight[2], P.ramp.blight[2], aa * 0.8, 0)
  UI.hgrad(sw - d, 0, d, sh, P.ramp.blight[2], P.ramp.blight[2], 0, aa * 0.8)
end

--- The player took a hit: a red iris that snaps in and eases out.
local function drawHurt(a)
  local k = U.ease.outQuad(HUD.hurtFlash)
  if k < 0.01 then return end
  local sw, sh = L.sw, L.sh
  local d = 260 * (0.6 + 0.4 * k)
  UI.vgrad(0, 0, sw, d, P.danger, P.danger, 0.3 * k * a, 0)
  UI.vgrad(0, sh - d, sw, d, P.danger, P.danger, 0, 0.3 * k * a)
  UI.hgrad(0, 0, d * 0.8, sh, P.danger, P.danger, 0.26 * k * a, 0)
  UI.hgrad(sw - d * 0.8, 0, d * 0.8, sh, P.danger, P.danger, 0, 0.26 * k * a)
end

--------------------------------------------------------------------- speech
--- Bot chatter, drawn in world space by world:drawSpeech.
function HUD.speechBubble(x, y, text, alpha)
  alpha = alpha or 1
  if alpha <= 0.01 then return end
  local size = 13
  local w = Text.measure(text, size, nil)
  local bw, bh = w + 22, size + 16
  local bx, by = x - bw * 0.5, y - bh
  Draw.setColor(UI.c(P.black, 0.72 * alpha))
  Draw.roundRect("fill", bx, by, bw, bh, 5)
  Draw.setColor(UI.c(P.ink, 0.16 * alpha))
  lg.setLineWidth(1)
  Draw.roundRect("line", bx + 0.5, by + 0.5, bw - 1, bh - 1, 5)
  -- tail
  Draw.setColor(UI.c(P.black, 0.72 * alpha))
  lg.polygon("fill", x - 5, by + bh - 1, x + 5, by + bh - 1, x, by + bh + 7)
  UI.text(text, x, by + 8, size, UI.c(P.ink, 0.95 * alpha), "center", alpha, 0.05)
end

----------------------------------------------------------------------- draw
--------------------------------------------------------------------- boss bar
-- The most affecting readout in the game: during the rebellion this drops one
-- notch per bot, and the player can watch what each of them bought.
local bossShown = 0
local function drawBossBar(w, a)
  local boss = w.boss
  local want = (boss and boss.alive and w.phase == "extraction") and 1 or 0
  bossShown = U.damp(bossShown, want, 6, love.timer.getDelta())
  if bossShown < 0.01 then return end
  local sw, sh = lg.getDimensions()
  local aa = a * bossShown
  -- bottom centre, above the build bar: it must not fight the oxygen readout,
  -- and during the rebellion this is where the player is looking anyway
  local bw = min(sw * 0.52, 760)
  local bh = 13
  local bx, by = (sw - bw) * 0.5, sh - 132

  local frac = boss and (boss.hp / boss.maxHp) or 0
  HUD._bossFrac = U.damp(HUD._bossFrac or frac, frac, 9, love.timer.getDelta())

  Draw.setColor(P.black, 0.55 * aa)
  Draw.roundRect("fill", bx - 3, by - 3, bw + 6, bh + 6, 5)
  Draw.setColor(P.ramp.rift[1], 0.9 * aa)
  Draw.roundRect("fill", bx, by, bw, bh, 3)

  -- the ghost tail lags the real value, so a burst of damage reads as a lurch
  Draw.setColor(P.warn, 0.35 * aa)
  Draw.roundRect("fill", bx, by, bw * HUD._bossFrac, bh, 3)
  Draw.setColor(P.danger, 0.95 * aa)
  Draw.roundRect("fill", bx, by, bw * frac, bh, 3)

  -- one notch per bot of health: the rebellion is legible as a countdown
  if boss then
    local notches = min(boss.maxHp, 60)
    Draw.setColor(P.black, 0.35 * aa)
    for i = 1, notches - 1 do
      local x = bx + bw * (i / notches)
      lg.rectangle("fill", x, by, 1, bh)
    end
  end

  Text.display("HARVESTER PRIME", bx, by - 21, UI.ts.label, {
    color = P.danger, alpha = 0.85 * aa, tracking = 0.3 })
  if boss then
    Text.display(tostring(math.ceil(boss.hp)), bx, by - 21, UI.ts.label, {
      color = P.ink, alpha = 0.8 * aa, tracking = 0.16, align = "right", width = bw })
  end
end

function HUD.draw(w, cam)
  w = w or HUD.world
  if not w or HUD.hidden then return end
  local sw, sh = lg.getDimensions()
  layout(sw, sh)
  local a = HUD.alpha
  if a <= 0.004 then return end

  local prevLW = lg.getLineWidth()
  lg.setLineStyle("smooth")

  drawScrims(a)
  drawThreat(a)
  drawTelegraph(w, a)
  drawHurt(a)

  drawResources(w, a)
  drawOxygen(w, a)
  drawCycleDial(w, a)
  drawHearts(w, a)
  drawRoster(w, a)
  drawBossBar(w, a)
  drawFeed(a)

  lg.setLineWidth(prevLW)
  lg.setColor(1, 1, 1, 1)
end

return HUD
