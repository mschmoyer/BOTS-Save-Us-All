-- The HUD.
--
-- Read in one glance while being chased. Everything lives on the rim of the
-- screen; the middle third is never touched. The layout is an 8 px grid with a
-- 24 px safe inset, and every readout has exactly one job:
--
--   top left     cobalt, forest and workforce -- what you have
--   top centre   the OXYGEN arc -- the campaign, drawn as sky rather than a bar,
--                with the reason it is moving written under it
--   top right    the cycle dial -- where you are in the run and how long is left
--   bottom left  hearts, and the event feed stacking up above them
--   bottom mid   the build bar (drawn by game/buildmenu.lua)
--   bottom right belongs to the minimap, and nothing else
--   the edges    the dusk telegraph
--
-- On touch the same readouts are dealt again for a phone held in landscape,
-- where the two bottom corners are under thumbs and the hands that carry them.
-- Everything a player has to *read* moves into the top band: the whole "what you
-- have" story -- cobalt, forest, crew, integrity -- becomes one left column with
-- the event feed growing downward out of it instead of upward out of the floor,
-- the right rail carries the clock and the map, the build bar is gone (the
-- radial is touch's way in), and HOLD THE DAWN takes the freed bottom-centre
-- band as a panel big enough to tap. See `TU.hud.touch`.
--
-- Bot chatter is drawn here too, not in the world: in world space it was
-- graded, bloomed, and free to sit on top of the hearts. As a HUD layer it is
-- crisp, it knows where every readout is, and it refuses to cover one.
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
local Script = require("src.game.script")
-- Read-only, for the letterbox: the chrome hides under the bars rather than
-- being sliced by them.
local Dialogue = require("src.game.dialogue")

local lg = love.graphics
local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local cos, sin, pi, atan2 = math.cos, math.sin, math.pi, math.atan2
local TAU = U.TAU

local HUD = {}

--------------------------------------------------------------- the touch layer
-- Reached lazily, never required: engine/touch.lua requires *this* file (for
-- the bot silhouettes and the tappable readouts below) and a cycle between the
-- input layer and the interface layer would be a genuinely bad edge to own.
local Touch
local function touchMod()
  if Touch == nil then Touch = package.loaded["src.engine.touch"] or false end
  return Touch or nil
end
local function touchMode() return Input.scheme == "touch" end

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

-- "x3" badges on a coalesced feed row, memoised for the same reason.
local XTOS = {}
local function xtos(n)
  local s = XTOS[n]
  if s == nil then s = "x" .. tostring(n) XTOS[n] = s end
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
-- The quarters, and only the quarters. The world already owns milestone
-- detection and plays the chime; the HUD used to keep a second, finer list and
-- fire a second chime on top of it.
local O2_MILESTONES = { 25, 50, 75, 100 }

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
-- 1 normally, 0 behind a cutscene's letterbox. Kept apart from HUD.alpha so the
-- pause and draft screens, which own that, never fight the bars.
HUD.chrome    = 1
HUD.holdK     = 0        -- 0..1 presence of the HOLD THE DAWN offer
HUD.botCount  = 0
HUD.o2Rate    = 0        -- smoothed %/s, signed
HUD.o2Cause   = nil      -- why it is moving, when it is moving down
HUD.o2Lag     = 0        -- a slow copy of the reading, for the trend sign
HUD.o2Mark    = 0        -- the sky as it stood when the night began
HUD.lastPhase = nil

local heartAnim = {}
for i = 1, 8 do heartAnim[i] = 0 end
local botT = 0

-------------------------------------------------------------------- toasts
-- The feed is ranked, because a Builder finishing its ninth Planter and a bot
-- you named dying are not the same event and must not look the same.
--
--   1  chatter   -- something came online. Short, small, coalesces.
--   2  progress  -- a milestone, a chip, a night survived.
--   3  loss      -- a bot did not come back. Bigger, slower, longer, and it
--                   cannot be pushed out of the pool by chatter.
local TOAST_MAX = 5
local RANK_CHATTER, RANK_PROGRESS, RANK_LOSS = 1, 2, 3
local toasts = {}
for i = 1, TOAST_MAX do
  toasts[i] = { text = "", sub = nil, color = P.ink, t = 0, dur = 0, live = false,
                y = 0, yTo = 0, rank = 2, count = 1, h = 32, seq = 0 }
end
local ORDER = { 1, 2, 3, 4, 5 }
local toastSeq = 0

--- Push an event onto the feed.
---
--- Repeat chatter with the same sub folds into the row that is already there
--- and bumps a counter, so a builder streak is one line rather than six. When
--- the pool is full the lowest-ranked, oldest row is the one that goes.
function HUD.toast(text, color, sub, dur, rank)
  rank = rank or RANK_PROGRESS
  if rank <= RANK_CHATTER then
    for i = 1, TOAST_MAX do
      local t = toasts[i]
      if t.live and t.rank == rank and t.sub == sub then
        t.text  = text
        t.count = t.count + 1
        t.t     = 0
        toastSeq = toastSeq + 1
        t.seq   = toastSeq
        return t
      end
    end
  end

  local slot
  for i = 1, TOAST_MAX do
    if not toasts[i].live then slot = toasts[i] break end
  end
  if not slot then
    local worst, wr, wt = nil, math.huge, -1
    for i = 1, TOAST_MAX do
      local t = toasts[i]
      if t.rank < wr or (t.rank == wr and t.t > wt) then worst, wr, wt = t, t.rank, t.t end
    end
    -- a loss never evicts a loss that is still being read
    if wr >= rank and rank >= RANK_LOSS then return end
    slot = worst
  end
  slot.text  = text
  slot.sub   = sub
  slot.color = color or P.ink
  slot.t     = 0
  slot.rank  = rank
  slot.count = 1
  slot.h     = rank >= RANK_LOSS and 44 or 30
  slot.dur   = dur or (rank >= RANK_LOSS and 7.5 or (rank <= RANK_CHATTER and 3.0 or 4.6))
  slot.live  = true
  slot.y     = nil            -- nil = spawn at its resting place with a slide-in
  toastSeq   = toastSeq + 1
  slot.seq   = toastSeq
  return slot
end
HUD.RANK_CHATTER, HUD.RANK_PROGRESS, HUD.RANK_LOSS =
  RANK_CHATTER, RANK_PROGRESS, RANK_LOSS

--------------------------------------------------------------------- speech
-- Bot chatter, queued from the world each frame and drawn as part of the HUD.
-- A fixed pool: the world caps itself at three lines, this holds six for the
-- frames where a cutscene has not yet flushed the old ones.
local SPEECH_MAX = 6
local speech = {}
for i = 1, SPEECH_MAX do
  speech[i] = { x = 0, y = 0, text = "", a = 0, bx = 0, by = 0, bw = 0, bh = 0 }
end
local speechN = 0
-- placed rectangles for this frame, so bubbles can be told about each other
local PLACED = {}
for i = 1, SPEECH_MAX do PLACED[i] = { x = 0, y = 0, w = 0, h = 0 } end

function HUD.clearSpeech() speechN = 0 end

--- Called by the world (through the method this file installs on World) with a
--- world-space anchor. Stored, not drawn: placement needs to know about every
--- other bubble and about the whole HUD, and only the draw pass does.
function HUD.queueSpeech(x, y, text, a)
  if speechN >= SPEECH_MAX or not text then return end
  speechN = speechN + 1
  local s = speech[speechN]
  s.x, s.y, s.text, s.a = x, y, text, a or 1
end

------------------------------------------------------------------ hit targets
--- Published for engine/touch.lua. Rebuilt only on resize, never per frame.
local hits = {
  oxygen  = { x = 0, y = 0, w = 0, h = 0 },
  cycle   = { x = 0, y = 0, w = 0, h = 0 },
  cobalt  = { x = 0, y = 0, w = 0, h = 0 },
  hearts  = { x = 0, y = 0, w = 0, h = 0 },
  build   = { x = 0, y = 0, w = 0, h = 0 },
}
function HUD.hitTargets() return hits end

--- The phone layout, published whole.
---
--- Two other modules need to agree with this file about where things are on a
--- touch screen and neither can work it out for itself: game/minimap.lua has to
--- put the plate where the rail expects it, and engine/touch.lua has to know
--- which readouts are also buttons (the map plate opens the map; the HOLD THE
--- DAWN panel takes the trade) and where its own utility rail may hang.
--- One table, filled on resize, read by both.
local TL = {
  on = false, mapOpen = false, holdOn = false,
  mapX = 0, mapY = 0, mapW = 0, mapH = 0,
  map  = { x = 0, y = 0, w = 0, h = 0 },
  hold = { x = 0, y = 0, w = 0, h = 0 },
}
function HUD.touchLayout() return TL end

local L = {   -- resolved layout, rebuilt on resize
  sw = 0, sh = 0, tm = nil, key = -1,
  il = 0, it = 0, ir = 0, ib = 0,          -- safe insets actually used
  o2x = 0, o2y = 0, o2w = 0, o2R = 0, o2cx = 0, o2cy = 0, o2a0 = 0, o2a1 = 0,
  dialX = 0, dialY = 0, dialR = 0,
  feedX = 0, feedY = 0, feedDir = -1, feedLimit = 0, resH = 0,
  resX = 0, resY = 0, heartX = 0, heartY = 0, bossY = 0,
}

--- Where the HUD lives, as rectangles, so bot chatter can be told to stay out of
--- them. Rebuilt on resize only.
local ZONES = {}
for i = 1, 6 do ZONES[i] = { x = 0, y = 0, w = 0, h = 0 } end
local function zone(i, x, y, w, h)
  local z = ZONES[i]
  z.x, z.y, z.w, z.h = x, y, w, h
end

local function setRect(r, x, y, w, h) r.x, r.y, r.w, r.h = x, y, w, h end

local function layout(sw, sh, tm)
  local TT = TU.hud.touch

  -- The inset the whole layer respects. On a phone it is the OS safe area --
  -- floored, because a browser that swears there is no notch is still drawing a
  -- rounded display corner over the outermost band -- plus a grid pad inside it.
  -- It is part of the cache key: a platform layer may hand the touch module a
  -- real safe area some frames after boot, and the layout has to follow it.
  local il, it, ir, ib = PAD, PAD, PAD, PAD
  if tm then
    local T = touchMod()
    if T and T.safeInsets then il, it, ir, ib = T.safeInsets() end
    il, it, ir, ib = il + TT.pad, it + TT.pad, ir + TT.pad, ib + TT.pad
  end
  local key = il + it * 8 + ir * 64 + ib * 512
  if L.sw == sw and L.sh == sh and L.tm == tm and L.key == key then return end
  L.sw, L.sh, L.tm, L.key = sw, sh, tm, key
  L.il, L.it, L.ir, L.ib = il, it, ir, ib

  -- oxygen: a shallow arc struck from far below the screen, so it reads as
  -- horizon rather than as a widget. On a short viewport it narrows rather
  -- than reaching for the corners.
  local w = U.clamp(sw * 0.36, 300, tm and TT.o2Max or 560)
  w = floor(w / UI.u) * UI.u
  L.o2w = w
  L.o2x = floor((sw - w) * 0.5)
  L.o2y = it + 12
  local R = w * 2.35
  L.o2R = R
  L.o2cx = sw * 0.5
  L.o2cy = L.o2y + R
  local half = math.asin(U.clamp(w * 0.5 / R, 0, 1))
  L.o2a0 = -pi * 0.5 - half
  L.o2a1 = -pi * 0.5 + half

  L.dialR = tm and TT.dialR or 34
  L.dialX = sw - ir - L.dialR
  L.dialY = it + L.dialR + 4

  L.resH  = 124                       -- cobalt row + forest/bots row
  L.resX, L.resY = il, it

  if tm then
    -- The left column: what you have, then what is left of you, then what just
    -- happened -- top to bottom, out of both thumbs' way, out of the notch.
    L.heartX = il
    L.heartY = it + L.resH + TT.heartGap + 14
    L.feedX  = il
    L.feedY  = L.heartY + TT.heartH + TT.feedGap
    L.feedDir, L.feedLimit = 1, sh * TT.feedMax

    -- The right rail: the clock, then the map, then (touch.lua's business) the
    -- two orders nobody gives in a panic.
    L.mapW = TT.mapW
    L.mapH = floor(L.mapW * TU.world.h / TU.world.w)
    L.mapX = sw - ir - L.mapW
    L.mapY = L.dialY + L.dialR + TT.mapGap

    -- HOLD THE DAWN drops into the band the build bar used to eat. It is one of
    -- two real decisions in a run, it is offered for twelve seconds, and on a
    -- phone the only honest way to offer it is a panel big enough to hit.
    L.holdW, L.holdH = min(TT.holdW, floor(sw * 0.32)), TT.holdH
    L.holdX = floor((sw - L.holdW) * 0.5)
    L.holdY = sh - ib - TT.holdUp - L.holdH
    -- Centred, but never under a thumb: on a short viewport the cluster's
    -- inboard button reaches past the middle of the screen, and a panel you
    -- have to tap cannot share pixels with a panic button.
    local T = touchMod()
    if T and T.clusterBounds then
      local cx0, _, cx1 = T.clusterBounds()
      if cx0 then
        if (cx0 + cx1) * 0.5 > sw * 0.5 then
          L.holdX = U.clamp(L.holdX, il, max(il, cx0 - TT.holdGap - L.holdW))
        else
          L.holdX = U.clamp(L.holdX, min(cx1 + TT.holdGap, sw - ir - L.holdW),
                            max(il, sw - ir - L.holdW))
        end
      end
    end
    L.bossY = sh - ib - TT.bossUp
  else
    L.heartX, L.heartY = il, sh - ib - 26
    L.feedX, L.feedY = il, sh - ib - 76
    L.feedDir, L.feedLimit = -1, 0
    L.mapW, L.mapH, L.mapX, L.mapY = 0, 0, 0, 0
    -- the dawn offer hangs off the bottom of the cycle dial, right-aligned to
    -- the same edge, because it is a decision about that clock
    local HT = TU.hud.hold
    L.holdW, L.holdH = HT.w, HT.h
    L.holdX = sw - ir - HT.w
    L.holdY = L.dialY + L.dialR + HT.gap
    L.bossY = sh - 108
  end

  hits.oxygen.x, hits.oxygen.y = L.o2x, it
  hits.oxygen.w, hits.oxygen.h = w, 78
  hits.cycle.x, hits.cycle.y = L.dialX - L.dialR - 8, L.dialY - L.dialR - 8
  hits.cycle.w, hits.cycle.h = (L.dialR + 8) * 2, (L.dialR + 8) * 2
  hits.cobalt.x, hits.cobalt.y, hits.cobalt.w, hits.cobalt.h = il, it, 216, L.resH
  hits.hearts.x, hits.hearts.y = L.heartX, L.heartY - 22
  hits.hearts.w, hits.hearts.h = 200, 48
  hits.build.x, hits.build.y = sw * 0.5 - 300, sh - ib - 66
  hits.build.w, hits.build.h = 600, 66

  TL.on = tm and true or false
  TL.mapX, TL.mapY, TL.mapW, TL.mapH = L.mapX, L.mapY, L.mapW, L.mapH
  -- generous slop on both: a 168 px plate and a 74 px panel are finger targets
  setRect(TL.map, L.mapX - 10, L.mapY - 10, L.mapW + 20, L.mapH + 20)
  setRect(TL.hold, L.holdX - 8, L.holdY - 8, L.holdW + 16, L.holdH + 16)

  if tm then
    zone(1, 0, 0, il + TT.colW, L.feedY - 6)                 -- the whole left column
    zone(2, L.o2x - 40, 0, w + 80, L.o2y + 96)               -- oxygen
    zone(3, L.mapX - 24, 0, sw - L.mapX + 24, L.mapY + L.mapH + 90)  -- clock, map, rail
    zone(4, 0, L.feedY - 6, il + TT.colW, L.feedLimit - L.feedY + 12) -- the feed
    zone(5, L.holdX - 20, L.bossY - 40, L.holdW + 40, sh - L.bossY + 40) -- offers
    -- The thumbs' ground: the action cluster's quadrant and the floor. Chatter
    -- placed here is chatter under a hand -- or, worse, under a button.
    zone(6, sw * 0.56, sh * 0.48, sw * 0.44, sh * 0.52)
  else
    zone(1, 0, 0, il + 232, it + L.resH + 12)                -- resources
    zone(2, L.o2x - 44, 0, w + 88, L.o2y + 106)              -- oxygen
    zone(3, L.dialX - L.dialR - 190, 0, L.dialR * 2 + 214,
            L.holdY + L.holdH + 12)                          -- cycle dial + dawn offer
    zone(4, 0, sh - 246, 340, 246)                           -- feed + hearts
    zone(5, sw * 0.5 - 340, sh - 158, 680, 158)              -- build bar + boss bar
    zone(6, sw - 320, sh - 292, 320, 292)                    -- the minimap's corner
  end
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
  HUD.o2Rate, HUD.o2Cause, HUD.o2Lag = 0, nil, HUD.o2Shown
  HUD.o2Mark, HUD.lastPhase = HUD.o2Shown, nil
  for i = 1, TOAST_MAX do toasts[i].live = false end
  HUD.clearSpeech()

  -- Take the speech layer off the world.
  --
  -- World:drawBubble runs inside the camera transform and inside the post
  -- chain, so chatter was bloomed, colour-graded, scaled by the zoom and
  -- perfectly happy to sit on top of the hearts. Replacing the method on the
  -- class -- the world file itself is untouched -- turns every call into a
  -- queue push that this file renders in screen space, after post, knowing
  -- where every readout is.
  -- package.loaded, not require: the UI demos hand this module a stub world and
  -- must not drag the whole simulation in behind it just to install a hook.
  local Wo = package.loaded["src.world.world"]
  if Wo and rawget(Wo, "_hudSpeech") == nil then
    Wo._hudSpeech = true
    Wo.drawBubble = function(_, x, y, text, a) HUD.queueSpeech(x, y, text, a) end
  end

  if bound then return end
  bound = true

  Signal.on("cobalt:gained", function(n)
    HUD.cobFlash = min(1, HUD.cobFlash + 0.5 + min(n, 8) * 0.06)
  end)
  Signal.on("cobalt:spent", function() HUD.cobFlash = max(HUD.cobFlash, 0.28) end)
  Signal.on("ui:denied", function() HUD.cobShake = 1 end)
  Signal.on("player:hurt", function() HUD.hurtFlash = 1 end)

  -- Chatter. A Builder finishes a Planter every fourteen seconds and there can
  -- be a dozen Builders, so this rank exists to be folded into one line.
  Signal.on("bot:built", function(b)
    HUD.toast(b.name, P.accent, "ONLINE", nil, RANK_CHATTER)
  end)
  -- A loss is the one moment this game is built to make land, and it used to
  -- print the same form letter under every name: three deaths in a row read
  -- SEED-16 / SEED-20 / SEED-24 with DID NOT COME BACK under each, which is a
  -- mail merge. Bot:epitaph() already knows what this one actually did -- it is
  -- what the memorial prints beside the name at the end of the run -- so it is
  -- what the feed prints too. The form letter survives only as a fallback.
  Signal.on("bot:lost", function(b, peaceful)
    if peaceful then return end
    local why
    if b.epitaph then
      local ok, line = pcall(b.epitaph, b)
      if ok and type(line) == "string" then why = line:upper() end
    end
    HUD.toast(b.name, P.danger, why or "DID NOT COME BACK", nil, RANK_LOSS)
  end)
  Signal.on("bot:revived", function(b)
    HUD.toast(b.name, P.accent, "BACK ON ITS FEET", nil, RANK_PROGRESS)
  end)
  -- The offer under the cycle dial disappears the instant it is taken, so the
  -- feed is what confirms the trade actually happened.
  Signal.on("world:heldDawn", function()
    HUD.toast(Script.hud.holdTaken, P.warn, Script.hud.holdAfter, 5)
  end)
  Signal.on("chip:added", function(c) HUD.toast(c.name, P.ramp.ember[4], c.f, 5.5) end)
  Signal.on("director:dawn", function() HUD.toast("NIGHT SURVIVED", P.accent, nil, 5) end)
  Signal.on("phase:dusk", function(cycle, sx, sy)
    HUD.sideX, HUD.sideY = sx or 0, sy or -1
    HUD.toast("DUSK", P.warn, "THE RIFT IS OPENING", 5)
  end)

  -- The world detects milestones and plays the chime. The HUD only reacts.
  Signal.on("o2:milestone", function(m)
    HUD.o2Pulse = 1
    HUD.toast("OXYGEN " .. itos(m) .. "%", P.o2, "ATMOSPHERE RISING", 5.5)
    J.flashScreen(0.05, P.o2[1], P.o2[2], P.o2[3])
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
  -- the world refills this during its draw pass, every frame, from scratch
  speechN = 0
  if not world then return end

  local sw, sh = lg.getDimensions()
  layout(sw, sh, touchMode())

  Text.odometer(HUD.cob, world.cobalt or 0, dt, 9)
  Text.odometer(HUD.trees, world.treeCount or 0, dt, 7)
  HUD.o2Shown = U.damp(HUD.o2Shown, world.o2 or 0, 5, dt)

  -- Under the bars, not sliced by them. Driven straight off the letterbox
  -- rather than damped on its own clock, so the readouts leave with the bars
  -- and come back as the bars retract instead of popping in behind them.
  HUD.chrome = U.saturate(1 - (Dialogue.bar or 0) * TU.hud.chromeHide)

  -- the dawn offer, in and out on its own ease
  local canHold = (world.canHoldDawn and world:canHoldDawn()) == true
  HUD.holdK = U.damp(HUD.holdK, canHold and 1 or 0, TU.hud.hold.rate, dt)
  if HUD.holdK < 0.002 then HUD.holdK = 0 end

  ------------------------------------------------------------------ the phone
  -- Everything the touch layer cannot work out for itself, published once a
  -- frame: which readouts are live targets, and what the one contextual button
  -- is currently for. `plant` has been three verbs since the first build --
  -- plant a sapling, pick a downed bot up, put it down again -- and it picks
  -- between them by where you are standing. A key cap can stay silent about
  -- that. A button on glass cannot.
  if TL.on then
    local mm = package.loaded["src.game.minimap"]
    TL.mapOpen = (mm and mm.isOpen and mm.isOpen()) and true or false
    TL.holdOn  = HUD.holdK > 0.4
    local T = touchMod()
    if T and T.setContext then
      local p = world.player
      local kind = "plant"
      if p and p.carrying then
        kind = "drop"
      elseif p and world.nearestDownedBot
             and world:nearestDownedBot(p.x, p.y, TU.player.carry.pickupRange) then
        kind = "carry"
      end
      T.setContext(kind)
    end
  end

  HUD.cobFlash  = max(0, HUD.cobFlash - dt * 2.4)
  HUD.cobShake  = max(0, HUD.cobShake - dt * 3.6)
  HUD.treeFlash = max(0, HUD.treeFlash - dt * 2.2)
  HUD.hurtFlash = max(0, HUD.hurtFlash - dt * 1.8)
  HUD.o2Pulse   = max(0, HUD.o2Pulse - dt * 0.9)
  HUD.tickPunch = max(0, HUD.tickPunch - dt * 5)

  -- The oxygen trend, and the reason for it. A meter that falls without saying
  -- why is just a punishment; the world already knows the answer, so ask it.
  local o2 = world.o2 or 0
  local prevLag = HUD.o2Lag
  HUD.o2Lag = U.damp(HUD.o2Lag, o2, 0.9, dt)
  HUD.o2Rate = U.damp(HUD.o2Rate, (HUD.o2Lag - prevLag) / dt, 3, dt)

  -- Where the sky stood when the trouble started. A lagged copy of the reading
  -- showed two percent of arc, which is nothing; a decaying high-water mark
  -- vanished under a slow drain. Anchoring to the start of the night is the
  -- only version that answers the question a player actually asks, which is
  -- "how much has tonight cost me".
  local ph = world.phase
  if ph ~= HUD.lastPhase then
    HUD.lastPhase = ph
    -- morning wipes the ledger: last night's losses are last night's
    if ph == "day" then HUD.o2Mark = HUD.o2Shown end
  end
  if HUD.o2Shown > HUD.o2Mark then HUD.o2Mark = HUD.o2Shown end
  local debt = world.o2Debt or 0
  local drain = world.bossDrain or 0
  if drain > 0.05 then
    HUD.o2Cause = "THE RIG IS TAKING IT"
  elseif debt > 0.4 then
    HUD.o2Cause = "SIPHONS FEEDING"
  elseif HUD.o2Rate < -0.06 then
    HUD.o2Cause = "THE CANOPY IS THINNING"
  else
    HUD.o2Cause = nil
  end

  -- the workforce, as one number: it is also the boss's health bar later
  if world.botCount then
    HUD.botCount = world:botCount()
  else
    botT = botT - dt
    if botT <= 0 then
      botT = 0.25
      local n, bots = 0, world.bots
      if bots then
        for i = 1, #bots do
          local b = bots[i]
          if b.alive and b.state ~= "dead" then n = n + 1 end
        end
      end
      HUD.botCount = n
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

  -- toast feed: settle each live toast into its slot. Rows are not all the same
  -- height any more, so the stack accumulates rather than multiplying an index.
  for i = 1, TOAST_MAX do
    local t = toasts[i]
    if t.live then
      t.t = t.t + dt
      if t.t >= t.dur then t.live = false end
    end
  end
  -- newest nearest the anchor, whatever order the pool recycled in
  local n = 0
  for i = 1, TOAST_MAX do
    if toasts[i].live then
      n = n + 1
      local j = n
      while j > 1 and toasts[ORDER[j - 1]].seq < toasts[i].seq do
        ORDER[j] = ORDER[j - 1]
        j = j - 1
      end
      ORDER[j] = i
    end
  end
  -- The feed grows away from its anchor: upward out of the floor on a desktop,
  -- downward out of the left column on a phone, where the floor is a thumb.
  local stack = 0
  local down = L.feedDir > 0
  for k = 1, n do
    local t = toasts[ORDER[k]]
    if down then
      t.yTo = stack
      stack = stack + t.h
    else
      stack = stack + t.h
      t.yTo = -stack
    end
    if t.y == nil then t.y = t.yTo + (down and -22 or 22) end
    t.y = U.damp(t.y, t.yTo, 14, dt)
  end
  for i = 1, TOAST_MAX do
    if not toasts[i].live then toasts[i].y = nil end
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

--- A bot in general -- a head with two lit eyes. Deliberately not any of the
--- six silhouettes: this counts all of them, and borrowing the Planter's shape
--- to mean "bots" would say the wrong thing.
local function crewGlyph(x, y, r, alpha)
  lg.setLineWidth(max(1.4, r * 0.18))
  Draw.setColor(UI.c(P.ramp.metal[3], alpha))
  Draw.roundRect("line", x - r * 0.72, y - r * 0.56, r * 1.44, r * 1.12, r * 0.3)
  lg.line(x, y - r * 0.56, x, y - r * 1.0)
  Draw.setColor(UI.c(P.eye, alpha))
  lg.circle("fill", x - r * 0.26, y, r * 0.18, 8)
  lg.circle("fill", x + r * 0.26, y, r * 0.18, 8)
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
  local il, it, ib = L.il, L.it, L.ib
  -- Measured, not guessed: over a sunlit canopy the old weights left caption
  -- type at 1.7:1 against its own background. These are roughly doubled, and
  -- the per-cluster pools are drawn twice -- once wide and soft to lift the
  -- whole corner, once tight and dark under the type itself.
  UI.vgrad(0, 0, sw, it + 108, P.black, P.black, 0.30 * a, 0)
  Draw.softShadow(il + 60, it + 32, 300, 190, 0.62 * a)            -- resources, wide
  Draw.softShadow(il + 52, it + 26, 190, 120, 0.62 * a)            -- resources, tight
  Draw.softShadow(sw * 0.5, L.o2y + 44, 380, 150, 0.50 * a)        -- oxygen, wide
  Draw.softShadow(sw * 0.5, L.o2y + 36, 200, 70, 0.55 * a)         -- oxygen, tight
  Draw.softShadow(L.dialX - 30, L.dialY + 4, 250, 150, 0.60 * a)   -- cycle dial
  Draw.softShadow(L.dialX, L.dialY, 90, 90, 0.55 * a)
  if L.tm then
    -- The bottom band is the thumbs' now, so there is nothing down there to
    -- seat. The left column carries on down instead, under the hearts and the
    -- feed, and the bottom-centre gets a small pool only for the offer panel.
    Draw.softShadow(il + 80, L.heartY + 6, 300, 150, 0.52 * a)     -- integrity
    Draw.softShadow(il + 90, L.feedY + 60, 320, 200, 0.44 * a)     -- the feed
    Draw.softShadow(sw * 0.5, L.bossY + 4, 430, 110, 0.34 * a)     -- boss / offer
  else
    UI.vgrad(0, sh - 146, sw, 146, P.black, P.black, 0, 0.34 * a)
    Draw.softShadow(il + 80, sh - ib - 92, 340, 250, 0.60 * a)     -- hearts + feed
    Draw.softShadow(sw * 0.5, sh - ib - 30, 430, 120, 0.46 * a)    -- build bar
  end
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
  Draw.ring(cx, cy, R, 3, a0, a1, UI.c(P.ink, 0.14 * a))

  -- The ghost tail: where the reading was a few seconds ago. When the arc is
  -- being eaten, the stretch between the ghost and the live edge is drawn in
  -- danger red, so a night that costs you sky *looks* like a night that cost
  -- you sky rather than a number quietly getting smaller.
  local ae = a0 + (a1 - a0) * t
  local mark = U.saturate(HUD.o2Mark / TU.o2.target)
  local losing = mark - t > 0.0015

  -- fill
  if t > 0.004 then
    Draw.ring(cx, cy, R, 4 + pulse * 3, a0, ae, UI.c(P.o2, (0.85 + 0.15 * pulse) * a), 3)
  end
  -- ...then the stretch of sky this night has taken, over the top of it, so
  -- the spark's own bloom cannot swallow it
  if losing then
    local al = a0 + (a1 - a0) * mark
    Draw.ring(cx, cy, R, 6, ae, al, UI.c(P.danger, 0.8 * a), 4)
    local gx, gy = cx + cos(al) * R, cy + sin(al) * R
    Draw.setColor(UI.c(P.danger, 0.9 * a))
    lg.setLineWidth(2)
    lg.line(gx - cos(al) * 4, gy - sin(al) * 4, gx + cos(al) * 9, gy + sin(al) * 9)
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
    local sc = losing and P.danger or P.o2
    Draw.glow(ex, ey, 16 + pulse * 26, sc, (0.6 + pulse) * a, 3)
    Draw.setColor(UI.c(P.white, (0.85 + 0.15 * sin(HUD.time * 6)) * a))
    lg.circle("fill", ex, ey, 2.6, 10)
  end

  -- The arc is the picture; this is its caption. The number, the word, and --
  -- only when the air is actually going -- the reason. "TARGET 100" used to
  -- live on the right of this line at 1.7:1 over a canopy; the end of the arc
  -- is the target and always was.
  local ny2 = L.o2y + 28
  local numSize = UI.ts.h2 * (1 + pulse * 0.12)
  local base = ny2 + numSize * 0.36
  local nw = UI.text(dec1(HUD.o2Shown), cx - 6, ny2, numSize,
                     UI.mix(P.ink, P.o2, 0.35 + 0.65 * pulse), "right", a, 0.02)
  UI.text("%", cx - 2, base, UI.ts.small, UI.c(P.o2, 0.85 * a), "left", a, 0.05)
  UI.caption("OXYGEN", cx - 6 - nw - 14, base + 2, UI.ts.micro,
             UI.c(P.ink, 0.72 * a), "right", nil, 1)

  -- The trend, under the numeral, on its own centred line. A chevron for the
  -- direction and a reason for the fall -- no rate figure: the size of the red
  -- stretch on the arc already says how fast, and a second number here just
  -- competed with the first one.
  local cause = HUD.o2Cause
  local ty = ny2 + numSize + 8
  if cause then
    local lw = UI.captionWidth(cause, UI.ts.micro)
    local puls = 0.72 + 0.28 * sin(HUD.time * 4)
    -- danger's own value is mid-grey; over a sunlit canopy the pure hue only
    -- managed 3.2:1, so the warning line is pulled toward white and given a
    -- 2 px shadow. It still reads unambiguously as red.
    Draw.setColor(UI.c(P.danger, 0.95 * puls * a))
    Draw.chevron(cx - lw * 0.5 - 12, ty + 4, 6, pi * 0.5, 2, 0.85)
    UI.caption(cause, cx + 6, ty, UI.ts.micro, UI.mix(P.danger, P.white, 0.42, a),
               "center", nil, 2)
  elseif HUD.o2Rate > 0.06 then
    local lw = UI.captionWidth("RISING", UI.ts.micro)
    Draw.setColor(UI.c(P.accent, 0.8 * a))
    Draw.chevron(cx - lw * 0.5 - 12, ty + 4, 6, -pi * 0.5, 2, 0.85)
    UI.caption("RISING", cx + 6, ty, UI.ts.micro, UI.c(P.accent, 0.8 * a), "center", nil, 1)
  end
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
             tx, cy + 6, UI.ts.micro, UI.c(P.ink, 0.68 * a), "right", nil, 1)
  -- Urgency used to be said four ways at once here: the ring colour, the
  -- pulsing sweep, the punched numeral and a set of flashing corner brackets
  -- the size of the dial. The brackets were the loudest and carried the least,
  -- so they are gone.
end

--------------------------------------------------------- hold the dawn
-- The only standing offer in the game, and one of only two decisions a player
-- makes in a run. It hangs under the cycle dial for the whole of dusk -- a
-- decision about the clock, drawn beside the clock -- and it says what the
-- trade costs as well as what it buys. Nothing new is invented for it: a
-- label, a rule, a key prompt and a caption, which is what every other prompt
-- in this game is made of.
--
-- The two strings are composed once. This file allocates nothing per frame and
-- the numbers in them never move.
local holdBuy, holdCost
local function drawHoldOffer(w, a)
  local k = HUD.holdK
  if k < 0.01 then return end
  if not holdBuy then
    holdBuy  = string.format(Script.hud.holdBuy, TU.cycle.holdExtra)
    holdCost = string.format(Script.hud.holdCost,
                             floor((TU.cycle.holdBudget - 1) * 100 + 0.5))
  end

  local e = U.ease.outCubic(k)
  local aa = a * e
  local bw, bh = L.holdW, L.holdH
  local x = L.holdX
  local rise = TU.hud.hold.rise
  local y = L.holdY + (1 - e) * (L.tm and rise or rise)
  -- a slow breath on the edge while the offer is open, so it reads as
  -- something being held out rather than as one more readout
  local pulse = 0.5 + 0.5 * sin(HUD.time * 2.4)

  UI.seat(x, y, bw, bh, 0.40 * aa)
  UI.panel(x, y, bw, bh, 0.70 * aa, 6, P.warn, (0.20 + 0.18 * pulse) * aa)

  if L.tm then
    -- On a phone this is not a prompt beside a key cap, it is the button. It
    -- takes the bottom-centre band the build bar used to eat, it is centred so
    -- neither thumb has a claim on it, and it says TAP because that is the
    -- whole instruction.
    local cx = x + bw * 0.5
    UI.text(Script.hud.holdLabel, cx, y + 10, UI.ts.small, P.warn, "center", aa, 0.14)
    UI.rule(x + 16, y + 30, bw - 32, P.warn, 0.16 * aa)
    UI.prompt(cx, y + 40, "commit", holdBuy, UI.ts.micro, P.ink, aa, "center")
    UI.caption(holdCost, cx, y + 58, UI.ts.micro,
               UI.c(P.inkDim, 0.9 * aa), "center", nil, 1)
    -- and it reads as a target: a live edge that breathes with the offer
    Draw.setColor(UI.c(P.warn, (0.10 + 0.16 * pulse) * aa))
    lg.setLineWidth(2)
    Draw.roundRect("line", x - 3.5, y - 3.5, bw + 7, bh + 7, 8)
    return
  end

  local rx = x + bw - 14              -- the inner edge everything hangs off
  UI.text(Script.hud.holdLabel, rx, y + 12, UI.ts.small, P.warn, "right", aa, 0.12)
  UI.rule(x + 14, y + 32, bw - 28, P.warn, 0.16 * aa)
  UI.prompt(rx, y + 44, "commit", holdBuy, UI.ts.micro, P.ink, aa, "right")
  UI.caption(holdCost, rx, y + 64, UI.ts.micro,
             UI.c(P.inkDim, 0.9 * aa), "right", nil, 1)
end

----------------------------------------------------------------- resources
--- What you have: what you can spend, what you have grown, and how many of
--- them there are. The last of those used to be a six-cell roster parked in the
--- bottom-right corner on top of the map; as a single number it belongs here,
--- next to the other two counts, and it is the number that becomes the boss's
--- health bar in the last three minutes anyway.
local function drawResources(w, a)
  local x, y = L.resX, L.resY
  local shake = HUD.cobShake > 0 and sin(HUD.cobShake * 46) * HUD.cobShake * 5 or 0
  local flash = U.ease.outQuad(HUD.cobFlash)

  -- cobalt
  cobaltGlyph(x + 11 + shake, y + 20, 11, a, flash)
  local cobColor = UI.mix(P.ramp.cobalt[4], P.white, flash * 0.7)
  if HUD.cobShake > 0.02 then cobColor = UI.mix(P.ramp.cobalt[4], P.danger, HUD.cobShake) end
  UI.text(itos(HUD.cob.v), x + 30 + shake, y + 4, UI.ts.h2 * (1 + flash * 0.06),
          cobColor, "left", a, 0.02)
  UI.caption("COBALT", x + 30 + shake, y + 40, UI.ts.micro,
             UI.c(P.ink, 0.72 * a), "left", nil, 1)

  -- a hairline that ties the row above to the pair below
  UI.rule(x, y + 56, 188, P.ink, 0.14 * a)

  -- forest | bots, one row, so the block stays three lines tall
  local ty = y + 64
  local tflash = U.ease.outQuad(HUD.treeFlash)
  treeGlyph(x + 10, ty + 14, 10, a, tflash)
  UI.text(itos(HUD.trees.v), x + 28, ty + 1, UI.ts.h3 * (1 + tflash * 0.06),
          UI.mix(P.accent, P.white, tflash * 0.6), "left", a, 0.02)
  UI.caption("FOREST", x + 28, ty + 30, UI.ts.micro,
             UI.c(P.ink, 0.72 * a), "left", nil, 1)

  local bx = x + 112
  crewGlyph(bx + 10, ty + 14, 10, 0.9 * a)
  UI.text(itos(HUD.botCount), bx + 28, ty + 1, UI.ts.h3,
          UI.c(P.ink, a), "left", a, 0.02)
  UI.caption("BOTS", bx + 28, ty + 30, UI.ts.micro,
             UI.c(P.ink, 0.72 * a), "left", nil, 1)
end

------------------------------------------------------------------- hearts
local function drawHearts(w, a)
  local p = w.player
  if not p then return end
  local x, y = L.heartX, L.heartY
  local hurt = U.ease.outQuad(HUD.hurtFlash)
  local shake = hurt > 0 and sin(HUD.time * 60) * hurt * 3 or 0
  local n = p.maxHp or 3
  for i = 1, n do
    local hx = x + (i - 1) * 26 + shake
    local full = i <= (p.hp or 0)
    heartAnim[i] = U.damp(heartAnim[i] or 0, full and 1 or 0, 12, 1 / 60)
    local k = heartAnim[i]
    -- drop shadow, then the socket. An empty socket has to be as legible as a
    -- full one or the player cannot tell three hearts from two.
    lg.setLineWidth(2.5)
    Draw.setColor(UI.c(P.black, 0.55 * a))
    Draw.chevron(hx + 9, y + 4, 11, -pi * 0.5, 3, 0.85)
    Draw.setColor(UI.mix(P.inkFaint, P.danger, k, (0.72 + 0.28 * k) * a))
    Draw.chevron(hx + 9, y, 11, -pi * 0.5, 3, 0.85)
    if k > 0.02 then
      Draw.setColor(UI.mix(P.danger, P.white, hurt * 0.8, (0.55 + 0.45 * k) * a))
      Draw.chevron(hx + 9, y + 6, 7 * k, -pi * 0.5, 3, 0.85)
    end
    if hurt > 0.01 and i == (p.hp or 0) + 1 then
      Draw.glow(hx + 9, y + 2, 26, P.danger, hurt * 0.8, 2)
    end
  end
  UI.caption("INTEGRITY", x, y + 20, UI.ts.micro, UI.c(P.ink, 0.7 * a), "left", nil, 1)

  -- Reboot timer, if the player is down. It hangs above the hearts on a desktop
  -- and below them on a phone, where above is the resources block.
  if p.state == "down" then
    local left = max(0, (p.downTimer or 0))
    UI.text("REBOOT " .. itos(math.ceil(left)), x, L.tm and (y + 34) or (y - 30),
            UI.ts.label, UI.c(P.warn, a), "left", a, 0.12)
  end
end

--------------------------------------------------------------------- feed
--- Three weights, and they are not interchangeable.
---
--- Chatter is one small line with a count. A loss is set at heading size with
--- the name on its own baseline, a thick tick, a slow arrival and eight seconds
--- to be read -- because the name of a bot that did not come back is the point
--- of the game and it used to look exactly like a Builder saying hello.
local function drawFeed(a)
  local x, baseY = L.feedX, L.feedY
  local limit = L.feedLimit
  for i = 1, TOAST_MAX do
    local t = toasts[i]
    -- On a phone the column has a floor: below it is the stick's landing
    -- ground, and a toast a thumb is sitting on is not a toast.
    if t.live and t.y and (limit <= 0 or baseY + t.y + t.h <= limit) then
      local loss = t.rank >= RANK_LOSS
      local inK  = U.ease.outCubic(U.saturate(t.t / (loss and 0.55 or 0.2)))
      local k    = U.saturate(min(inK, (t.dur - t.t) * (loss and 1.4 or 2.2)))
      local slide = (1 - inK) * (loss and -30 or -18)
      local y = baseY + t.y
      local aa = a * k

      if loss then
        Draw.softShadow(x + 130, y + 20, 190, 34, 0.5 * aa)
        Draw.setColor(UI.c(t.color, 0.95 * aa))
        Draw.roundRect("fill", x + slide, y + 2, 4, 36, 2)
        Draw.glow(x + slide + 2, y + 20, 40, t.color, 0.28 * aa, 2)
        UI.text(t.text, x + 14 + slide, y + 2, UI.ts.h4,
                UI.mix(P.ink, P.danger, 0.25), "left", aa, 0.08)
        UI.caption(t.sub or "", x + 15 + slide, y + 28, UI.ts.micro,
                   UI.mix(t.color, P.white, 0.3, 0.95 * aa), "left", nil, 2)
      else
        Draw.setColor(UI.c(t.color, 0.9 * aa))
        Draw.roundRect("fill", x + slide, y + 4, 3, 18, 1.5)
        local tw = UI.text(t.text, x + 12 + slide, y + 3, UI.ts.label,
                           UI.c(P.ink, aa), "left", aa, 0.06)
        local sx = x + 12 + slide + tw + 10
        if t.count > 1 then
          local xs = xtos(t.count)
          local cw = UI.captionWidth(xs, UI.ts.micro) + 10
          Draw.setColor(UI.c(t.color, 0.22 * aa))
          Draw.roundRect("fill", sx - 2, y + 5, cw, 15, 3)
          UI.caption(xs, sx + cw * 0.5 - 2, y + 8, UI.ts.micro,
                     UI.c(t.color, aa), "center")
          sx = sx + cw + 6
        end
        if t.sub then
          UI.caption(t.sub, sx, y + 8, UI.ts.micro, UI.c(t.color, 0.9 * aa), "left", nil, 1)
        end
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
  -- The top and bottom edges are where the oxygen arc and the build bar live,
  -- so the chevrons flank them rather than marching straight through them. The
  -- direction still reads; the readout underneath survives.
  local spread = (abs(ny) > 0.5) and (L.o2w * 0.5 + 64) or 44
  local march = (HUD.time * 46) % 34
  for i = 0, 2 do
    local d = 30 + i * 34 + march
    local fade = (1 - i / 3) * aa
    for s = -1, 1, 2 do
      local px = cx + nx * d + tx * s * spread
      local py = cy + ny * d + ty * s * spread
      lg.setLineWidth(3)
      Draw.setColor(UI.c(col, fade * 0.75))
      Draw.chevron(px, py, 11, ang, 3, 0.8)
    end
  end
  -- the word, set into the edge beside the left-hand cluster
  local lx = cx + nx * 26 + tx * (abs(ny) > 0.5 and -spread or 0)
  local ly = cy + ny * 26 + ty * (abs(ny) > 0.5 and -spread or 0)
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

-- The all-edge purple threat bleed used to be drawn here, underneath the
-- directional dusk telegraph and on top of the post chain's own vignette:
-- three vignettes at once, and the only one of the three that told the player
-- anything was the directional one. Threat still drives the telegraph's
-- strength (see HUD.duskK); it no longer gets a wash of its own.

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
--- One bubble, in screen space, already placed.
local BSIZE = UI.bs.small
local function drawBubble(s, alpha)
  local bx, by, bw, bh = s.bx, s.by, s.bw, s.bh
  Draw.softShadow(bx + bw * 0.5, by + bh * 0.75, bw * 0.6, bh * 0.8, 0.34 * alpha)
  Draw.setColor(UI.c(P.black, 0.80 * alpha))
  Draw.roundRect("fill", bx, by, bw, bh, 6)
  -- the tail leans back toward whoever is talking, which is what keeps a bubble
  -- attached to its bot once it has been pushed clear of a readout
  local ax = U.clamp(s.ax, bx + 10, bx + bw - 10)
  lg.polygon("fill", ax - 5, by + bh - 1, ax + 5, by + bh - 1,
             U.clamp(s.ax, bx - 6, bx + bw + 6), by + bh + 7)
  Draw.setColor(UI.c(P.ink, 0.18 * alpha))
  lg.setLineWidth(1)
  Draw.roundRect("line", bx + 0.5, by + 0.5, bw - 1, bh - 1, 6)
  UI.body(s.text, bx + bw * 0.5, by + 5, BSIZE, UI.c(P.ink, 0.96 * alpha), nil, "center")
end

local function overlaps(ax, ay, aw, ah, bx, by, bw, bh)
  return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end

--- Place and draw the queued chatter.
---
--- Every bubble is pushed upward until it clears the HUD's own zones and every
--- bubble already placed. If it cannot be cleared without leaving the play area
--- it is dropped: an idle bot's remark is worth less than an unobstructed view
--- of the oxygen meter, and it will say something else in nine seconds.
local function drawSpeech(w, cam, a)
  if speechN == 0 or not cam or not cam.toScreen then return end
  if w.cutscene then return end
  local sw, sh = L.sw, L.sh
  local placed = 0
  for i = 1, speechN do
    local s = speech[i]
    local alpha = a * s.a
    if alpha > 0.02 then
      local tw = Text.bodyMeasure(s.text, BSIZE)
      local bw, bh = tw + 20, BSIZE + 14
      local sx, sy = cam:toScreen(s.x, s.y)
      s.ax = sx
      local bx = U.clamp(sx - bw * 0.5, 12, sw - bw - 12)
      local by = sy - bh
      -- lift clear of the furniture, then of each other
      local guard = 0
      local moved = true
      while moved and guard < 12 do
        moved = false
        guard = guard + 1
        for z = 1, #ZONES do
          local r = ZONES[z]
          if overlaps(bx, by, bw, bh + 8, r.x, r.y, r.w, r.h) then
            by = r.y - bh - 10
            moved = true
          end
        end
        for k = 1, placed do
          local o = PLACED[k]
          if overlaps(bx, by, bw, bh + 6, o.x, o.y, o.w, o.h) then
            by = o.y - bh - 8
            moved = true
          end
        end
      end
      if by > 40 and by + bh < sh - 40 then
        s.bx, s.by, s.bw, s.bh = bx, by, bw, bh
        placed = placed + 1
        local r = PLACED[placed]
        r.x, r.y, r.w, r.h = bx, by, bw, bh
        drawBubble(s, alpha)
      end
    end
  end
end

----------------------------------------------------------------------- draw
------------------------------------------------------------------- player pip
-- Drawn in screen space, after everything in the world, so a canopy can never
-- hide you from yourself. It fades up only when there is something to hide
-- behind, so open ground stays clean.
local pipFade = 0
-- Hoisted: an anonymous callback here is a table allocation every frame, in the
-- one function in the game that promises never to make one.
local coverCount, coverY = 0, 0
local function countCover(t)
  if t.alive and t.y > coverY then coverCount = coverCount + 1 end
end
local function drawPlayerPip(w, cam, a)
  local p = w.player
  if not p or not cam then return end
  local cover = 0
  if w.hTree then
    coverCount, coverY = 0, p.y - 90
    w.hTree:each(p.x, p.y - 30, 70, countCover)
    cover = coverCount
  end
  local want = (p.state == "down") and 1 or min(1, cover / 3)
  pipFade = U.damp(pipFade, want, 7, love.timer.getDelta())
  if pipFade < 0.02 then return end

  local sx, sy = cam:toScreen(p.x, p.y - p.radius * 2.6)
  local bob = sin(HUD.time * 3.2) * 3
  local col = p.state == "down" and P.danger or P.accent
  Draw.setColor(P.black, 0.35 * pipFade * a)
  Draw.chevron(sx, sy + bob + 1.5, 11, pi * 0.5, 4, 0.8)
  Draw.setColor(col, 0.9 * pipFade * a)
  Draw.chevron(sx, sy + bob, 11, pi * 0.5, 3, 0.8)
end

-------------------------------------------------------------------- bot pips
-- The same idea as the player pip, aimed at the thing the game is actually
-- about. By cycle four the island carries seven hundred mature trees and the
-- canopy is a solid roof: a capture of an extraction with thirty-four bots
-- alive did not show one of them. They have names, traits and epitaphs and at
-- the climax they walk into the rig for you, and none of it lands if the player
-- cannot see them work.
--
-- Rules, in the same visual language and with the same restraint as the player
-- pip: screen space so no canopy can eat it, and it fades up only where there
-- is genuinely something in the way, so an open meadow stays a meadow. Colour
-- is the minimap's, so the two readouts never disagree -- P.eye for a bot at
-- work, P.eyeDown for one on the ground, P.love for one that has left to take
-- the rig. Shape carries the rest: a chevron for the bots that walk, a ring for
-- the ones you bolted down, because a pylon that has never moved in its life
-- should not read as somebody approaching.
local BP = TU.hud.botPip
-- Hoisted for the same reason countCover is: this file promises zero table
-- allocations per frame, and a closure per bot per frame is forty of them.
local botCoverN, botCoverY = 0, 0
local function countBotCover(t)
  if t.alive and t.growth > 0.35 and t.y > botCoverY then
    botCoverN = botCoverN + 1
  end
end

local function botCover(w, b)
  if not w.hTree then return 0 end
  botCoverN, botCoverY = 0, b.y - BP.coverBack
  w.hTree:each(b.x, b.y - BP.coverUp, BP.coverR, countBotCover)
  return botCoverN
end

local function drawBotPip(b, cam, a)
  local f = b.pipFade or 0
  if f < 0.02 then return end
  local aa = f * a
  local sx, sy = cam:toScreen(b.x, b.y - b.radius * BP.rise)

  if b.state == "rebel" then
    -- They are all walking the same way, so the mark walks with them: an
    -- arrowhead on the heading, a short wake behind it, and a little light of
    -- its own. Thirty of these converging on the rig under a closed canopy is
    -- the procession the finale was written for, and this is the only way
    -- anyone gets to watch it happen.
    local ang = atan2(b.vy, b.vx)
    local cx, cy = cos(ang), sin(ang)
    local sz = BP.size * BP.rebelScale
    Draw.glow(sx, sy, sz * 3.6, P.love, 0.45 * aa, 2)
    for k = 1, BP.tailSteps do
      local d = BP.tail * k / BP.tailSteps
      local t = (k - 1) / BP.tailSteps
      Draw.setColor(P.love, (0.50 - 0.38 * t) * aa)
      lg.circle("fill", sx - cx * d, sy - cy * d, 2.6 - 1.6 * t, 8)
    end
    Draw.setColor(P.black, BP.haloA * aa)
    Draw.chevron(sx, sy, sz, ang, BP.halo + 1.4, 0.72)
    Draw.setColor(P.love, aa)
    Draw.chevron(sx, sy, sz, ang, 2.8, 0.72)
    return
  end

  if b.state == "down" then
    -- The worst version of this bug was being unable to find a bot you were
    -- supposed to carry, so the downed mark does not wait to be occluded and it
    -- does not sit still. The ring is the rescue clock: it empties as the bot
    -- does, and when it is gone so is the bot.
    local r = BP.ringR * BP.downRing
    local puls = 0.62 + 0.38 * sin(HUD.time * BP.downPulse + b.bob)
    Draw.setColor(P.black, BP.haloA * aa)
    lg.setLineWidth(BP.halo)
    lg.circle("line", sx, sy + 1.4, r, 18)
    Draw.setColor(P.eyeDown, 0.5 * aa)
    lg.setLineWidth(1.6)
    lg.circle("line", sx, sy, r, 18)
    local ping = (HUD.time * BP.pingRate + b.bob * 0.16) % 1
    Draw.setColor(P.eyeDown, 0.42 * (1 - ping) * aa)
    lg.setLineWidth(2)
    lg.circle("line", sx, sy, r * (1 + ping * BP.pingGrow), 20)
    local frac = U.saturate((b.downT or 0) / (b.downMax or TU.bots.downedTime))
    Draw.setColor(P.eyeDown, 0.95 * puls * aa)
    lg.setLineWidth(2.4)
    if frac > 0.004 then
      lg.arc("line", "open", sx, sy, r, -pi * 0.5, -pi * 0.5 + TAU * frac, 22)
    end
    Draw.setColor(P.black, BP.haloA * aa)
    Draw.chevron(sx, sy - r - 5, BP.size, pi * 0.5, BP.halo, 0.8)
    Draw.setColor(P.eyeDown, 0.95 * puls * aa)
    Draw.chevron(sx, sy - r - 5, BP.size, pi * 0.5, 2.2, 0.8)
    return
  end

  -- The dark pass is a centred *outline*, not the player pip's dropped shadow.
  -- At eleven pixels an offset shadow is enough to lift the mark off anything;
  -- at seven it is not, and half of these sit over a sunlit crown the same
  -- value as they are. Drawing the black first at a heavier width gives every
  -- mark its own ground to stand on, whatever it is standing on.
  if b.static then
    Draw.setColor(P.black, BP.haloA * aa)
    lg.setLineWidth(BP.halo)
    lg.circle("line", sx, sy, BP.ringR, 14)
    Draw.setColor(P.eye, 0.95 * aa)
    lg.setLineWidth(1.8)
    lg.circle("line", sx, sy, BP.ringR, 14)
  else
    -- the bob is per-bot out of phase, so a crowd shimmers instead of pulsing
    -- as one animatronic block
    local bob = sin(HUD.time * BP.bob + b.bob) * 1.7
    Draw.setColor(P.black, BP.haloA * aa)
    Draw.chevron(sx, sy + bob, BP.size, pi * 0.5, BP.halo, 0.8)
    Draw.setColor(P.eye, 0.95 * aa)
    Draw.chevron(sx, sy + bob, BP.size, pi * 0.5, 2.2, 0.8)
  end
end

local function drawBotPips(w, cam, a)
  local bots = w.bots
  if not cam or not bots then return end
  local dt = love.timer.getDelta()
  local n = #bots

  -- Two passes over the list rather than a sorted shortlist, because sorting
  -- means a table. The first pass owns the fades -- every bot gets one whether
  -- or not it is drawn, so nothing pops when the cap moves -- and draws the
  -- ones that cannot be allowed to miss out: the down and the rebelling. Only
  -- then does the working crew spend what is left of the budget.
  for i = 1, n do
    local b = bots[i]
    if b.alive and not b.carried then
      local want = 0
      if cam:visible(b.x, b.y, 70) and b.state ~= "dead" then
        if b.state == "down" or b.state == "rebel" then
          want = 1
        elseif b.state ~= "boot" then
          want = min(1, botCover(w, b) / BP.cover)
        end
      end
      b.pipFade = U.damp(b.pipFade or 0, want, BP.fade, dt)
      if b.state == "down" or b.state == "rebel" then drawBotPip(b, cam, a) end
    end
  end

  local budget = BP.max
  for i = 1, n do
    if budget <= 0 then break end
    local b = bots[i]
    if b.alive and not b.carried and b.state ~= "down" and b.state ~= "rebel"
       and (b.pipFade or 0) >= 0.02 then
      drawBotPip(b, cam, a)
      budget = budget - 1
    end
  end
end

------------------------------------------------------------------ off-screen threats
-- A tree being eaten off the edge of the screen was previously only visible on
-- the minimap. These point at it.
local function drawChewMarkers(w, cam, a)
  if not cam or w.phase == "day" and (w.enemies == nil or #w.enemies == 0) then return end
  local sw, sh = lg.getDimensions()
  local cx, cy = sw * 0.5, sh * 0.5
  local m = min(sw, sh) * 0.5 - 54
  local shown = 0
  for i = 1, #w.enemies do
    local e = w.enemies[i]
    if shown >= 4 then break end
    local urgent = e.alive and not e.fleeing and (e.chewT and e.chewT > 0 or e.type == "maw")
    if urgent and not cam:visible(e.x, e.y, -40) then
      local sx, sy = cam:toScreen(e.x, e.y)
      local dx, dy = sx - cx, sy - cy
      local len = max(1, (dx * dx + dy * dy) ^ 0.5)
      local ex, ey = cx + dx / len * m, cy + dy / len * m
      local ang = atan2(dy, dx)
      local puls = 0.55 + 0.45 * sin(HUD.time * 6 + i)
      Draw.setColor(P.danger, 0.75 * puls * a)
      Draw.chevron(ex, ey, 13, ang, 3, 0.85)
      Draw.setColor(P.danger, 0.2 * puls * a)
      lg.circle("fill", ex, ey, 17)
      shown = shown + 1
    end
  end
end

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
  -- Nothing can be built once the rig arrives, so the build bar has faded out
  -- by the time this is at full strength; the bar drops into the space it left
  -- rather than floating above an empty band.
  -- On a phone the bar is narrower: at 52% of the width its right end ran
  -- under the thumb cluster's inboard button, and a health bar you cannot see
  -- the end of is a health bar you cannot read.
  local bw = L.tm and min(sw * TU.hud.touch.bossW, 620) or min(sw * 0.52, 760)
  local bh = 13
  local bx, by = (sw - bw) * 0.5, L.bossY

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

  -- one notch per bot: the rebellion is legible as a countdown, and each notch
  -- that goes is one of them
  if boss then
    local notches = min(w.rebelCrew or 40, 60)
    Draw.setColor(P.black, 0.35 * aa)
    for i = 1, notches - 1 do
      local x = bx + bw * (i / notches)
      lg.rectangle("fill", x, by, 1, bh)
    end
    -- The plate line. Player damage stops here until the next cohort lands, so
    -- the bar stalling against a lit rule is the fight explaining itself: this
    -- is not yours to finish, and they are still walking.
    local fl = boss.hullFloor and boss:hullFloor() / boss.maxHp or 0
    if fl > 0.001 then
      local fx = bx + bw * fl
      local pulse = 0.55 + 0.45 * (boss.hullBlock or 0)
      Draw.setColor(P.warn, (0.5 + 0.5 * (boss.hullBlock or 0)) * aa)
      lg.rectangle("fill", fx - 1, by - 4, 3, bh + 8)
      Draw.setColor(P.warn, 0.18 * pulse * aa)
      lg.rectangle("fill", fx, by, bw * frac - (fx - bx), bh)
    end
  end

  -- Two table constructors per frame lived here, in the file whose contract is
  -- "zero tables per frame", and they only ran during the boss fight where the
  -- frame budget is tightest. UI.text reuses one shared options table.
  UI.text("HARVESTER PRIME", bx, by - 21, UI.ts.label, P.danger, "left", 0.85 * aa, 0.3)
  -- what the plates are, in three words, only while they are actually stopping
  -- you: a stalled bar with no explanation reads as a bug
  if boss and (boss.hullBlock or 0) > 0.05 and boss.plates > 0 then
    -- Above the bar on a desktop, below it on a phone: the phone's bar is
    -- narrower and a centred line on that baseline lands inside the rig's name.
    UI.text("ARMOUR HOLDING", bx + bw * 0.5, L.tm and (by + bh + 6) or (by - 21),
            UI.ts.micro, P.warn, "center", 0.9 * (boss.hullBlock or 0) * aa, 0.34)
  end
  if boss then
    UI.text(itos(math.ceil(boss.hp)), bx + bw, by - 21, UI.ts.label,
            P.ink, "right", 0.8 * aa, 0.16)
  end
end

--- Is a cutscene holding the screen? The chrome layer already hides under the
--- letterbox; engine/touch.lua needs the same fact for a different reason.
--- Published here because this is the file that already watches the bars.
function HUD.cinematic() return (Dialogue.bar or 0) > 0.3 end

--- What the rest of the screen furniture -- the build bar, the minimap -- should
--- be drawn at. They belong to the same layer as the readouts and have to leave
--- with them when a cutscene closes the bars over the top.
function HUD.chromeAlpha() return HUD.alpha * HUD.chrome end

--- The lowest screen y a world-anchored overlay may reach. The bottom band is
--- the build bar's, and during the extraction it is the boss's health: a
--- tutorial hint drawn across HARVESTER PRIME is worse than no hint at all.
function HUD.overlayFloor()
  local _, sh = lg.getDimensions()
  return sh - (touchMode() and TU.hud.touch.overlayFloor or TU.hud.overlayFloor)
end

function HUD.draw(w, cam)
  w = w or HUD.world
  if not w or HUD.hidden then return end
  local sw, sh = lg.getDimensions()
  layout(sw, sh, touchMode())
  -- One multiplier for the whole layer: HUD.alpha is the pause and draft
  -- screens' dimmer, HUD.chrome is the cutscene letterbox.
  local a = HUD.alpha * HUD.chrome
  if a <= 0.004 then return end

  local prevLW = lg.getLineWidth()
  lg.setLineStyle("smooth")

  drawTelegraph(w, a)
  drawHurt(a)
  drawSpeech(w, cam, a)      -- under the readouts: chatter never wins a fight
  drawScrims(a)

  drawResources(w, a)
  drawOxygen(w, a)
  drawCycleDial(w, a)
  drawHoldOffer(w, a)
  drawHearts(w, a)
  drawBotPips(w, cam, a)     -- under the player's own mark: he is never lost in the crowd
  drawPlayerPip(w, cam, a)
  drawChewMarkers(w, cam, a)
  drawBossBar(w, a)
  drawFeed(a)

  lg.setLineWidth(prevLW)
  lg.setColor(1, 1, 1, 1)
end

return HUD
