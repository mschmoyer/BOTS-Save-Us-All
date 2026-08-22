-- Dawn.
--
-- Two things happen here, in this order, and the order is the whole point.
--
--   1. The night is counted. Trees planted, trees lost, Blight killed, and the
--      oxygen delta -- and then, in its own column with air around it and a beat
--      between each one, the name of every bot that did not come back. The names
--      are set in the display face at heading size. They are not a statistic.
--
--   2. Only then do the three chips arrive, staggered, from below.
--
-- Cards lift and tilt toward the pointer, rares carry a travelling foil, and the
-- one you pick flies down to where the HUD keeps its feed before the phase turns
-- over. Colour on a card encodes rarity and only rarity; the family is encoded
-- as a shape, so the two never fight.
local U        = require("src.core.util")
local P        = require("src.engine.palette")
local Draw     = require("src.engine.draw")
local Text     = require("src.engine.text")
local UI       = require("src.engine.ui")
local Input    = require("src.engine.input")
local Screen   = require("src.engine.screen")
local J        = require("src.engine.juice")
local Opt      = require("src.core.optional")
local Audio    = Opt.require("src.engine.audio")
local HUD      = Opt.require("src.game.hud")
local BuildMenu = Opt.require("src.game.buildmenu")
local TU       = require("src.game.tuning")

local lg = love.graphics
local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local pi = math.pi

local S = {}

--------------------------------------------------------------------- the radio
-- Every word the interface says lives in game/script.lua.
local STR = require("src.game.script").dawn
--- How wide the log's own little column is. Two micro rows, label left and
--- number right, which is how every other pair of numbers in this game is set.
local RADIO_W = 168

--------------------------------------------------------------------- timing
local SEQ = {
  head  = 0.00,
  stats = 0.26, statStep = 0.07,
  names = 0.62, nameStep = 0.26,
  cards = 1.12, cardStep = 0.12, cardDur = 0.62,
  foot  = 1.70,
}
local FLY = 0.55                 -- seconds the chosen card spends in flight

--------------------------------------------------------------------- rarity
local RARITY_TINT = { P.ramp.metal[3], P.accentCool, P.ramp.ember[4] }
local RARITY_WORD = { "COMMON", "UNCOMMON", "RARE" }

--------------------------------------------------------------- family emblems
--- Shape carries the family, so the card's one colour can carry rarity alone.
local function emblem(family, x, y, r, color, alpha)
  Draw.setColor(UI.c(color, alpha))
  lg.setLineWidth(max(1.8, r * 0.11))
  if family == "GROWTH" then
    lg.line(x, y + r * 0.9, x, y - r * 0.15)
    Draw.blob(x - r * 0.42, y - r * 0.30, r * 0.46, 10, 3, 0.18, 0.82, "fill")
    Draw.blob(x + r * 0.44, y - r * 0.10, r * 0.38, 10, 9, 0.18, 0.82, "fill")
    Draw.blob(x, y - r * 0.62, r * 0.42, 11, 17, 0.18, 0.86, "fill")
  elseif family == "COMBAT" then
    for i = -1, 1 do
      Draw.chevron(x + i * r * 0.52, y + abs(i) * r * 0.16, r * 0.5, -pi * 0.5, 3, 0.8)
    end
    lg.line(x - r * 0.7, y + r * 0.72, x + r * 0.7, y + r * 0.72)
  elseif family == "LOGISTICS" then
    Draw.hexagon(x, y, r * 0.72, 0, "line")
    lg.line(x - r * 0.95, y + r * 0.5, x - r * 0.4, y + r * 0.16)
    lg.line(x + r * 0.95, y + r * 0.5, x + r * 0.4, y + r * 0.16)
    lg.circle("fill", x, y - r * 0.06, r * 0.2, 12)
  elseif family == "BOTS" then
    Draw.roundRect("line", x - r * 0.68, y - r * 0.38, r * 1.36, r * 1.0, r * 0.22)
    lg.line(x, y - r * 0.38, x, y - r * 0.86)
    lg.circle("fill", x, y - r * 0.94, r * 0.16, 10)
    lg.circle("fill", x - r * 0.26, y + r * 0.12, r * 0.13, 10)
    lg.circle("fill", x + r * 0.26, y + r * 0.12, r * 0.13, 10)
  else -- PLAYER
    lg.circle("line", x, y - r * 0.46, r * 0.32, 18)
    Draw.chevron(x, y + r * 0.62, r * 0.62, -pi * 0.5, 3, 0.9)
    lg.line(x - r * 0.62, y + r * 0.06, x + r * 0.62, y + r * 0.06)
  end
end

--------------------------------------------------------------------- lifecycle
function S:enter(world, report)
  self.world = world
  self.report = report or {}
  self.t = 0
  self.chosen = nil
  self.flyT = 0
  self.done = false
  self.ctx = UI.context({ accent = P.ramp.ember[4] })
  self.ctx.wrap = false

  self.offers = (world and world.chips)
                and world.chips:draft(world.rng, 3, world.cycle or 1) or {}
  self.ctx.focusId = "card2"

  local names = self.report.names or {}
  self.names = names
  self.nameSpoken = 0

  -- Composed once, here, because it is the one thing on this screen that has
  -- to be identical every dawn except for the digit.
  self.dayStr = string.format(STR.day,
                              TU.radio.dayZero + (self.report.cycle or 1))
end

--- The HUD is the day's instrument panel, and dawn is not the day: it leaves
--- entirely while this screen is up and comes back with the phase that needs
--- it. See the note on the fade in `update`.
function S:leave()
  HUD.alpha = 1
  BuildMenu.barAlpha = 1
end

--- Take the gameplay layer off the screen.
---
--- It used to be dimmed to 0.10 and left there, which on a dark dawn wash is
--- not "gone", it is "faint": the build bar, the whole resource stack, SIPHONS
--- FEEDING under the oxygen arc and two DID NOT COME BACK toasts were all still
--- readable *underneath the tally*, and those toasts name the same bots this
--- screen sets in the display face a few hundred pixels to the right of them.
--- The prologue already takes the chrome away like this; the draft never did.
local CHROME_FADE = 9        -- 1/s
local function chromeOut(v, dt)
  v = U.damp(v, 0, CHROME_FADE, dt)
  return v < 0.02 and 0 or v
end

local function confirm(self, i)
  if self.chosen then return end
  local chip = self.offers[i]
  if not chip then return end
  self.chosen = i
  self.flyT = 0
  if Audio.play then Audio.play("card_pick") end
  J.punch(0.02)
  J.flashScreen(0.06, P.ramp.ember[4][1], P.ramp.ember[4][2], P.ramp.ember[4][3])
end

function S:update(dt, realDt)
  realDt = realDt or dt
  self.t = self.t + realDt
  HUD.alpha = chromeOut(HUD.alpha, realDt)
  BuildMenu.barAlpha = chromeOut(BuildMenu.barAlpha, realDt)
  if Screen.current() ~= self then return end

  -- a chime per name, one after another: the tally reads itself out loud
  local shown = U.clamp(floor((self.t - SEQ.names) / SEQ.nameStep), 0, #self.names)
  if shown > self.nameSpoken and self.nameSpoken < #self.names then
    self.nameSpoken = shown
    if Audio.play then Audio.play("bot_down", { volume = 0.35 }) end
  end

  if self.chosen then
    self.flyT = self.flyT + realDt
    if not self.done and self.flyT >= FLY then
      self.done = true
      local w = self.world
      if w then
        w.chips:add(self.offers[self.chosen])
        w:setPhase("day")
      end
      Screen.pop()
    end
    return
  end

  if self.pending then
    local i = self.pending
    self.pending = nil
    confirm(self, i)
    return
  end
  for i = 1, min(3, #self.offers) do
    if Input.pressed("build" .. i) then confirm(self, i) return end
  end
  self.ctx:beginFrame(realDt)
end

------------------------------------------------------------------- the tally
--- Two hues carry meaning here and the rest is ink: green is the forest, red is
--- what it cost. Oxygen keeps its own cyan because it is cyan everywhere.
local function statColor(key, v)
  if key == "LOST" then return v > 0 and P.danger or P.inkDim end
  if key == "PLANTED" or key == "FOREST" then return P.accent end
  return P.ink
end

--- Two type scales: the full one, and a compressed one for a phone-landscape
--- viewport, where a 74 px heading and 36 px numerals leave no room at all for
--- the three cards that are the point of the screen.
function S:sizes()
  local h = lg.getHeight()
  if h < 680 then return UI.ts.h1, UI.ts.h3, UI.ts.h3, 38, 80 end
  return UI.ts.mega, UI.ts.h2, UI.ts.h2, 50, 98
end

function S:drawTally(x, y, w, a)
  local r = self.report
  local t = self.t
  local head, stat = self:sizes()

  -- heading
  local hk = UI.stagger(t, 1, SEQ.head, 0, 0.55, U.ease.outExpo)
  UI.text("DAWN", x + (1 - hk) * -16, y, head, UI.c(P.ink, a * hk), "left",
          a * hk, U.lerp(0.34, 0.04, hk))
  UI.caption("CYCLE " .. tostring(r.cycle or 1) .. " SURVIVED", x, y + head + 12,
             UI.ts.micro, UI.c(P.ramp.ember[4], 0.95 * a * hk), "left")

  -- The numbers, one cell each, all left-aligned on the same grid so the
  -- numerals stack in a column the eye can run down -- but under two rules,
  -- because PLANTED and FOREST are not the same kind of number and printing
  -- them side by side, unexplained, with different values, was this screen
  -- asking the player to work out which of the two the HUD had been counting
  -- at them all night. Left: what this cycle did. Right: what is standing now,
  -- which is FOREST, which is the number in the corner of the HUD.
  local sy = y + head + 44
  local cellW = floor(w / 5 / UI.u) * UI.u
  UI.rule(x, sy, cellW * 3 - UI.u * 2, P.ink, 0.14 * a, P.ramp.ember[4])
  UI.rule(x + cellW * 3, sy, w - cellW * 3, P.ink, 0.14 * a, P.accent)
  local gk = UI.stagger(t, 1, SEQ.stats, 0, 0.42)
  UI.caption("THIS CYCLE", x, sy + 8, UI.ts.micro,
             UI.c(P.ramp.ember[4], 0.85 * a * gk), "left")
  UI.caption("STANDING NOW", x + cellW * 3, sy + 8, UI.ts.micro,
             UI.c(P.accent, 0.85 * a * gk), "left")

  local cells = {
    { "PLANTED", tostring(floor(r.planted or 0)) },
    { "LOST",    tostring(floor(r.lost or 0)) },
    { "BLIGHT",  tostring(floor(r.killed or 0)) },
    { "FOREST",  tostring(floor(r.trees or 0)) },
  }
  local cellY = sy + 32
  for i = 1, 4 do
    local k = UI.stagger(t, i, SEQ.stats, SEQ.statStep, 0.42)
    local key, val = cells[i][1], cells[i][2]
    UI.stat(x + (i - 1) * cellW, cellY + (1 - k) * 8, key, val, stat,
            statColor(key, tonumber(val) or 0), "left", a * k)
  end

  -- oxygen gets the fifth cell and the delta, because it is the campaign
  local k5 = UI.stagger(t, 5, SEQ.stats, SEQ.statStep, 0.42)
  local d = r.o2Delta or 0
  local sign = d >= 0 and "+" or "-"
  UI.stat(x + 4 * cellW, cellY + (1 - k5) * 8, "OXYGEN",
          Text.format(r.o2 or 0, { decimals = 1, suffix = "%" }), stat,
          P.o2, "left", a * k5,
          sign .. Text.format(abs(d), { decimals = 1 }),
          d >= 0 and P.accent or P.danger)
end

--- The radio log.
---
--- Seven dawns in a run, and nothing else in this game gets seven repetitions,
--- so this is the only place in it where anything can actually accumulate. It
--- accumulates by not changing: the wording is the same on the seventh dawn as
--- on the first, and only the day advances.
---
--- Everything about it is deliberately inert. Smallest type on the screen, the
--- faintest ink in the palette, no stagger, no chime, no colour change, no
--- flourish on the last cycle -- it is instrument furniture, in the register of
--- a panel light nobody looks at, and it is drawn before the heading so it is
--- read once and then stopped being read. Nothing in the game ever remarks on
--- it. That is the entire design: the ending switches the radio off, and what
--- the player is supposed to feel there is that they stopped reading this.
---
--- It also carries the run's only honest date. The prologue says the sky has
--- been that colour for eleven days and the HUD then counts cycles, so the
--- eleven never became twelve anywhere; 11 + cycle does that, once a dawn.
function S:drawRadio(x, y, w, a)
  UI.caption(STR.radio, x, y, UI.ts.micro, UI.c(P.inkFaint, 0.6 * a), "left")
  UI.caption(STR.noAnswer, x, y + 14, UI.ts.micro,
             UI.c(P.inkFaint, 0.85 * a), "left")
  UI.caption(self.dayStr or "", x + w, y + 14, UI.ts.micro,
             UI.c(P.inkFaint, 0.85 * a), "right")
end

--- The names. This block is deliberately the quietest and the slowest thing on
--- the screen, and it is the only place the display face is used at heading size
--- for anything that is not a number or a title.
function S:drawNames(x, y, w, a)
  local t = self.t
  local names = self.names
  local n = #names
  local k0 = UI.stagger(t, 1, SEQ.names - 0.16, 0, 0.4)
  if k0 <= 0.002 then return end

  if n == 0 then
    UI.caption("EVERY BOT CAME BACK", x + w, y, UI.ts.micro,
               UI.c(P.accent, 0.9 * a * k0), "right")
    UI.text("ALL ACCOUNTED FOR", x + w, y + 18, UI.ts.h3, UI.c(P.accent, a * k0),
            "right", a * k0, 0.08)
    return
  end

  UI.caption("DID NOT COME BACK", x + w, y, UI.ts.micro,
             UI.c(P.danger, 0.95 * a * k0), "right")
  local shown = min(n, 5)
  local _, _, size, step = self:sizes()
  for i = 1, shown do
    local k = UI.stagger(t, i, SEQ.names, SEQ.nameStep, 0.5, U.ease.outExpo)
    if k > 0.002 then
      local ny = y + 26 + (i - 1) * step
      local aa = a * k
      -- a short rule that draws itself out to the left of each name
      local nw = Text.measure(names[i], size, nil)
      Draw.setColor(UI.c(P.danger, 0.5 * aa))
      lg.setLineWidth(2)
      lg.line(x + w - nw - 18 - 26 * k, ny + size * 0.56,
              x + w - nw - 18, ny + size * 0.56)
      UI.text(names[i], x + w, ny + (1 - k) * 8, size,
              UI.mix(P.ink, P.danger, 0.22), "right", aa, 0.08)
    end
  end
  if n > shown then
    local k = UI.stagger(t, shown + 1, SEQ.names, SEQ.nameStep, 0.5)
    UI.caption("AND " .. tostring(n - shown) .. " MORE", x + w, y + 26 + shown * step,
               UI.ts.micro, UI.c(P.danger, 0.7 * a * k), "right")
  end
end

--------------------------------------------------------------------- the cards
local CARD_W, CARD_H = 300, 392

--- Draws one card in local space, centred on the origin. The caller owns the
--- transform, which is what makes the lift, the tilt and the flight possible.
function S:drawCard(chip, k, focused, a, foilTime, phase)
  local tint = RARITY_TINT[chip.r] or RARITY_TINT[1]
  UI.o.maxWidth = CARD_W - 52

  UI.card(CARD_W, CARD_H, {
    tint = tint, hover = k, alpha = a, radius = 10,
    foil = chip.r >= 3 and (0.55 + 0.45 * k) or (chip.r == 2 and 0.2 * k or 0),
    time = foilTime, phase = phase,
  })

  local x0 = -CARD_W * 0.5
  local y0 = -CARD_H * 0.5

  -- family + rarity, the two pieces of metadata, at opposite corners
  UI.caption(chip.f, x0 + 22, y0 + 22, UI.ts.micro, UI.c(P.inkDim, 0.85 * a), "left")
  UI.pips(x0 + CARD_W - 22 - (chip.r * 12 - 4), y0 + 22, chip.r, chip.r, 4, 4, tint)

  -- the emblem: the family, as a shape
  emblem(chip.f, 0, y0 + 122, 44, tint, (0.55 + 0.45 * k) * a)
  Draw.glow(0, y0 + 122, 96, tint, (0.10 + 0.18 * k) * a, 3)

  -- name
  UI.text(chip.name, 0, y0 + 206, UI.ts.h3, UI.c(P.ink, a), "center", a, 0.06, UI.o)
  UI.rule(x0 + 40, y0 + 246, CARD_W - 80, tint, (0.28 + 0.4 * k) * a)

  -- what it does
  UI.body(chip.desc, x0 + 26, y0 + 262, UI.bs.base,
          UI.c(P.inkDim, (0.85 + 0.15 * k) * a), CARD_W - 52, "center")

  -- footer band
  UI.caption(RARITY_WORD[chip.r] or "", 0, y0 + CARD_H - 34, UI.ts.micro,
             UI.c(tint, (0.7 + 0.3 * k) * a), "center")
  if focused then
    UI.brackets(x0 + 8, y0 + 8, CARD_W - 16, CARD_H - 16, 20, tint, 0.9 * a, 2.5, 0)
  end
end

--- The shortcut, on the card it belongs to. It used to be a whisper in the
--- bottom-left corner ("OR PRESS 1 2 3") at 0.55 alpha, three hundred pixels
--- away from the thing it was talking about.
function S:drawCardKey(i, x, y, k, a)
  if Input.scheme ~= "kb" then return end
  local s = 26
  Draw.setColor(UI.c(P.black, 0.7 * a))
  Draw.roundRect("fill", x - s * 0.5, y, s, s - 4, 4)
  lg.setLineWidth(1)
  Draw.setColor(UI.c(P.ink, (0.2 + 0.4 * k) * a))
  Draw.roundRect("line", x - s * 0.5 + 0.5, y + 0.5, s - 1, s - 5, 4)
  UI.text(tostring(i), x, y + 5, UI.ts.small,
          UI.c(P.ink, (0.7 + 0.3 * k) * a), "center", a, 0.02)
end

--------------------------------------------------------------------- drawing
local PROMPTS = { { "confirm", "TAKE IT" } }

function S:draw()
  local w, h = lg.getDimensions()
  local ctx = self.ctx
  local top = (Screen.current() == self)
  local t = self.t
  local prevLW = lg.getLineWidth()
  local a = U.saturate(t * 3.5)

  -- the world stays visible underneath; dawn washes it warm
  UI.scrim(0.72 * a, P.black)
  UI.vgrad(0, 0, w, h * 0.55, P.ramp.ember[2], P.black, 0.13 * a, 0)
  UI.vignette(0.6 * a)

  local fx = floor(max(UI.pad * 3, w * 0.07) / UI.u) * UI.u
  local fw = w - fx * 2
  local headY = floor(h * 0.075 / UI.u) * UI.u

  self:drawRadio(fx, max(UI.u, headY - 34), RADIO_W, a)
  self:drawTally(fx, headY, floor(fw * 0.58 / UI.u) * UI.u, a)
  self:drawNames(fx + fw - floor(fw * 0.30), headY + 4, floor(fw * 0.30), a)

  -- Cards, sized to the room that is actually left between the tally and the
  -- footer. Fixed 392 px cards left a dead band across the middle of a 16:9
  -- frame and ran into the tally on a phone-landscape one; this fills the first
  -- and fits the second.
  local n = #self.offers
  local head, _, _, _, statBlock = self:sizes()
  local topY = headY + head + 44 + statBlock
  local botY = h - UI.pad - 64
  local gap = 40
  local fit = U.clamp((botY - topY) / CARD_H, 0.52, 1.18)
  fit = min(fit, (w - fx * 2) / (n * CARD_W + (n - 1) * gap))
  gap = gap * fit
  local cw2 = CARD_W * fit
  local total = n * cw2 + (n - 1) * gap
  local cy = floor((topY + botY) * 0.5)
  local x0 = w * 0.5 - total * 0.5 + cw2 * 0.5
  local flyK = self.chosen and U.ease.inOutCubic(U.saturate(self.flyT / FLY)) or 0
  local tx, ty = UI.pad + 60, h - UI.pad - 74      -- where the HUD keeps its feed

  for i = 1, n do
    local chip = self.offers[i]
    local cx = x0 + (i - 1) * (cw2 + gap)
    local k = UI.stagger(t, i, SEQ.cards, SEQ.cardStep, SEQ.cardDur, U.ease.outBack)
    local ka = UI.stagger(t, i, SEQ.cards, SEQ.cardStep, SEQ.cardDur * 0.6)

    local focused, hot, activated, st
    if not self.chosen and k > 0.5 then
      focused, hot, activated, st = ctx:interact("card" .. i,
        cx - cw2 * 0.5, cy - CARD_H * fit * 0.5, cw2, CARD_H * fit, true)
      if activated then self.pending = i end
    else
      st = ctx:state("card" .. i)
    end

    local lift = max(st.focus, st.hover)
    local px, py = cx, cy - (1 - k) * 90 - lift * 18
    local scale = fit * (0.90 + 0.10 * k) * (1 + lift * 0.035)
    local rot = (1 - k) * (i - 2) * 0.09
    local alpha = a * ka

    if self.chosen == i then
      -- the chosen card flies to the feed and shrinks into it
      px = U.lerp(cx, tx, flyK)
      py = U.lerp(cy - lift * 18, ty, flyK)
      scale = U.lerp(scale, 0.16, flyK)
      rot = U.lerp(rot, -0.22, flyK)
      alpha = a * (1 - U.ease.inQuad(flyK) * 0.85)
    elseif self.chosen then
      alpha = a * (1 - U.ease.outQuad(U.saturate(self.flyT / (FLY * 0.5))))
      py = py + U.ease.inQuad(U.saturate(self.flyT / FLY)) * 40
    end

    if alpha > 0.004 then
      -- tilt toward the pointer, so a hovered card feels physically nudged
      if lift > 0.01 and not self.chosen then
        rot = rot + U.clamp((ctx.mx - cx) / cw2, -1, 1) * 0.035 * lift
      end
      lg.push()
      lg.translate(px, py)
      lg.rotate(rot)
      lg.scale(scale)
      self:drawCard(chip, lift, focused and not self.chosen, alpha, t, i * 0.37)
      lg.pop()
      if not self.chosen then
        self:drawCardKey(i, cx, cy + CARD_H * 0.5 * scale + 12, lift, alpha)
      end
    end
  end

  -- footer
  local fk = UI.stagger(t, 1, SEQ.foot, 0, 0.5)
  if fk > 0.002 and not self.chosen then
    local fy = h - UI.pad - 26
    -- left, not centre: the centre of this baseline is directly under the middle
    -- card's number chip, and two prompts stacked in a column read as one
    UI.promptRow(fx, fy, PROMPTS, UI.ts.micro, P.inkDim, 0.85 * a * fk, "left")
    UI.caption("ONE CHIP. THE OTHER TWO ARE GONE.", w - UI.pad * 3, fy + 4,
               UI.ts.micro, UI.c(P.inkDim, 0.7 * a * fk), "right")
  end

  if top and not self.chosen then ctx:endFrame() end
  lg.setLineWidth(prevLW)
  lg.setColor(1, 1, 1, 1)
end

return S
