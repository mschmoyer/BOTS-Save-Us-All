-- The cutscene runtime.
--
-- A sequence is a flat list of steps. Dialogue.play() takes it over, sets
-- world.cutscene, eases in the letterbox, and runs the steps one at a time
-- until the list is done or the player skips.
--
-- Step kinds
--   line       who / text / tone / pace / auto      typed out, player-advanced
--   wait       dur                                  silence (always skippable)
--   camera     x,y | entity | zoom | dur | release  pans the game camera
--   fx         effect | shake | flash | x,y|entity  VFX + screen feel
--   sound      name | volume | pitch                one-shot through engine.audio
--   music      state | intensity                    music state change
--   flag       name | value                         sets world.flags[name]
--   fn         fn(ctx, world)                       arbitrary callback
--   letterbox  amount | dur                         open/close the bars by hand
--
-- Rules this file guarantees:
--   * world.cutscene is cleared on EVERY exit path (finish, skip, abort).
--   * skipping still runs every `flag`, `fn` and `music` step that was left,
--     so world state can never diverge between a watched and a skipped scene.
--   * the player is never locked out for more than a moment: any step can be
--     advanced with `confirm`, and `back` skips the whole sequence.
--
-- Portraits are procedural: there is no art in this project, so the human and
-- every bot chassis are drawn here as small vector figures with an idle bob,
-- a blink, and a mouth/eye that responds to the tone of the line being said.
local U      = require("src.core.util")
local P      = require("src.engine.palette")
local Signal = require("src.core.signal")
local Input  = require("src.engine.input")
local Opt    = require("src.core.optional")

local Draw  = Opt.require("src.engine.draw")
local Text  = Opt.require("src.engine.text")
local VFX   = Opt.require("src.engine.vfx")
local Audio = Opt.require("src.engine.audio")
local Music = Opt.require("src.engine.music")
local J     = Opt.require("src.engine.juice")

local lg = love.graphics
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local Dialogue = {}

------------------------------------------------------------------------ tuning
local T = {
  cps          = 40,      -- characters per second at pace 1
  pauseComma   = 0.13,    -- extra seconds bought by , ; :
  pauseStop    = 0.27,    -- extra seconds bought by . ! ?
  pauseEllipsis= 0.34,
  minLineHold  = 0.16,    -- input is ignored for this long after a line starts
  barFrac      = 0.105,   -- letterbox bar height as a fraction of the screen
  barIn        = 0.55,
  barOut       = 0.40,
  panelMaxW    = 1180,
  colMaxW      = 660,     -- measured line length: ~62 characters of body copy
  bodySize     = 21,
  nameSize     = 17,
  camRate      = 2.8,
}
Dialogue.tuning = T

----------------------------------------------------------------------- state
local A = nil            -- the active handle, or nil

Dialogue.bar = 0         -- current letterbox amount, 0..1
local barTarget = 0
local barRate   = 1 / T.barIn

--------------------------------------------------------------------- tone table
-- brow: positive tilts the inner brow up (sad / soft). eye: openness.
-- mouth: -1 frown .. 1 smile. gain: how much the mouth moves while speaking.
local TONE = {
  flat   = { brow =  0.00, eye = 1.00, mouth =  0.00, gain = 1.00 },
  soft   = { brow =  0.20, eye = 0.88, mouth =  0.10, gain = 0.75 },
  bright = { brow = -0.10, eye = 1.12, mouth =  0.34, gain = 1.15 },
  urgent = { brow = -0.34, eye = 1.20, mouth =  0.22, gain = 1.35 },
  sad    = { brow =  0.36, eye = 0.78, mouth = -0.24, gain = 0.60 },
  tired  = { brow =  0.26, eye = 0.70, mouth = -0.10, gain = 0.60 },
  small  = { brow =  0.14, eye = 0.62, mouth = -0.04, gain = 0.45 },
}
Dialogue.tones = TONE

local function toneOf(name) return TONE[name or "flat"] or TONE.flat end

------------------------------------------------------------------- text layout
local HANG = { ["."] = 1, [","] = 1, [";"] = 1, [":"] = 1, ["!"] = 1, ["?"] = 1, ["'"] = 1 }
local LEAD = { ["'"] = 1, ['"'] = 1 }

local function bodyW(s, size)
  local w = Text.bodyMeasure(s, size)
  return w or 0
end

--- Strip trailing punctuation that is allowed to hang past the measure.
local function unhung(s)
  local i = #s
  while i > 0 and HANG[s:sub(i, i)] do i = i - 1 end
  return s:sub(1, i)
end

--- Greedy wrap with real hanging punctuation: a line breaks on the width of
--- its text WITHOUT the trailing period or comma, so the right edge of the
--- column is set by letters and the punctuation hangs into the margin.
local function wrapBody(str, size, width)
  local lines, line = {}, nil
  for word in tostring(str):gmatch("%S+") do
    local try = line and (line .. " " .. word) or word
    if line and bodyW(unhung(try), size) > width then
      lines[#lines + 1] = line
      line = word
    else
      line = try
    end
  end
  if line then lines[#lines + 1] = line end
  if #lines == 0 then lines[1] = "" end
  return lines
end

--- Per-character dwell for the typewriter. Punctuation buys a beat.
local function buildDelays(flat, pace)
  local base = 1 / (T.cps * (pace or 1))
  local d = {}
  local n = #flat
  for i = 1, n do
    local c = flat:sub(i, i)
    local extra = 0
    if c == "," or c == ";" or c == ":" then extra = T.pauseComma
    elseif c == "." then
      extra = (flat:sub(i + 1, i + 1) == ".") and 0.06 or T.pauseStop
      if flat:sub(i - 2, i) == "..." then extra = T.pauseEllipsis end
    elseif c == "!" or c == "?" then extra = T.pauseStop
    elseif c == "\n" then extra = T.pauseComma * 0.5
    end
    d[i] = base + extra * (pace or 1)
  end
  return d, n
end

--- Lay a line step out once, for a given column width. Cached on the step so
--- the glyphs never reflow mid-reveal -- that is what makes type-on read as
--- typing rather than as jitter.
local function layoutLine(step, text, size, width)
  local key = string.format("%d|%d|%s", floor(size * 4), floor(width), text)
  if step._lay and step._lay.key == key then return step._lay end
  local lines = wrapBody(text, size, width)
  local flatParts, starts, cum = {}, {}, 0
  for i = 1, #lines do
    starts[i] = cum
    flatParts[i] = lines[i]
    cum = cum + #lines[i] + 1        -- +1 for the break, which types as a beat
  end
  local flat = table.concat(flatParts, "\n")
  local delays, n = buildDelays(flat, step.pace)
  local total = 0
  for i = 1, n do total = total + delays[i] end
  step._lay = {
    key = key, lines = lines, starts = starts, flat = flat,
    delays = delays, count = n, dur = total, size = size, width = width,
  }
  return step._lay
end

--------------------------------------------------------------------- portraits
local function metal(t, a) return P.shade(P.ramp.metal, t, a) end

--- One bot chassis, shoulders-up, in portrait space (origin at the collar,
--- unit `u` roughly one eighth of the plate). Every type keeps its silhouette.
local function botHat(kind, u, tt, eye)
  if kind == "planter" then
    Draw.setColor(P.shade(P.ramp.leaf, 2.4))
    Draw.roundRect("fill", -1.5 * u, -6.6 * u, 3.0 * u, 1.7 * u, 0.5 * u)
    Draw.setColor(P.shade(P.ramp.leafHi, 3.2))
    local s = math.sin(tt * 1.4) * 0.18
    Draw.capsule("fill", 0, -6.7 * u, s * u, -7.9 * u, 0.16 * u)
    Draw.blob(s * u * 1.4, -8.1 * u, 0.5 * u, 9, 3, 0.22, 0.72)
  elseif kind == "builder" then
    Draw.setColor(metal(3.0))
    Draw.capsule("fill", -0.2 * u, -6.2 * u, -0.2 * u, -8.2 * u, 0.22 * u)
    Draw.capsule("fill", -0.2 * u, -8.1 * u, 2.3 * u, -7.4 * u, 0.18 * u)
    Draw.setColor(P.shade(P.ramp.cobalt, 3))
    Draw.roundRect("fill", 2.0 * u, -7.2 * u, 0.7 * u, 0.7 * u, 0.14 * u)
  elseif kind == "repulsor" then
    local k = 0.5 + math.sin(tt * 2.1) * 0.5
    Draw.ring(0, -7.1 * u, (1.5 + k * 0.35) * u, 0.22 * u, 0, U.TAU, P.accentCool, 0.4)
    Draw.glow(0, -7.1 * u, 2.4 * u, P.accentCool, 0.28)
  elseif kind == "sentry" then
    Draw.setColor(metal(3.0))
    Draw.capsule("fill", 0.6 * u, -5.0 * u, 4.2 * u, -5.6 * u, 0.30 * u)
    Draw.setColor(P.shade(P.ramp.leaf, 3), 0.9)
    lg.circle("fill", 4.3 * u, -5.6 * u, 0.26 * u)
  elseif kind == "harvester" then
    Draw.setColor(metal(3.1))
    Draw.roundRect("fill", -2.6 * u, -6.5 * u, 5.2 * u, 0.8 * u, 0.3 * u)
    Draw.setColor(P.shade(P.ramp.cobalt, 2.8))
    lg.circle("fill", -1.2 * u, -7.1 * u, 0.4 * u)
    lg.circle("fill", 0.1 * u, -7.3 * u, 0.32 * u)
  elseif kind == "beacon" then
    local k = 0.6 + math.sin(tt * 1.7) * 0.4
    Draw.setColor(metal(2.8))
    Draw.roundRect("fill", -1.2 * u, -8.4 * u, 2.4 * u, 2.0 * u, 0.5 * u)
    Draw.setColor(P.eye, 0.5 + k * 0.5)
    Draw.roundRect("fill", -0.85 * u, -8.1 * u, 1.7 * u, 1.4 * u, 0.4 * u)
    Draw.glow(0, -7.5 * u, 3.4 * u * k, P.eye, 0.34)
  end
  -- everyone gets the antenna; it is the thing that makes them read as alive
  local sway = math.sin(tt * 1.15) * 0.5 * u
  Draw.setColor(metal(2.6))
  Draw.capsule("fill", -1.9 * u, -5.3 * u, -2.3 * u + sway, -7.3 * u, 0.11 * u)
  Draw.setColor(eye, 0.9)
  lg.circle("fill", -2.3 * u + sway, -7.4 * u, 0.22 * u)
end

local function drawBotPortrait(spec, tt, tone, speak, blink)
  local u = 1
  local eye = spec.eye or P.eye
  local look = spec.look or 0

  -- collar
  Draw.setColor(metal(1.5))
  Draw.roundRect("fill", -4.6 * u, -0.6 * u, 9.2 * u, 3.0 * u, 0.9 * u)
  Draw.setColor(metal(1.9))
  Draw.roundRect("fill", -3.4 * u, -1.2 * u, 6.8 * u, 1.6 * u, 0.6 * u)

  -- head
  Draw.setColor(metal(2.5))
  Draw.roundRect("fill", -3.5 * u, -6.4 * u, 7.0 * u, 5.6 * u, 1.5 * u)
  Draw.setColor(metal(3.0), 0.55)
  Draw.roundRect("fill", -3.1 * u, -6.1 * u, 6.2 * u, 1.5 * u, 0.9 * u)

  botHat(spec.botType, u, tt, eye)

  -- eye plate
  Draw.setColor(metal(1.05))
  Draw.roundRect("fill", -2.7 * u, -4.9 * u, 5.4 * u, 2.4 * u, 0.9 * u)

  local open = U.saturate(tone.eye * (1 - blink))
  if open > 0.03 then
    local ex = look * 0.55 * u
    local eh = 1.30 * u * open
    -- a bot's tone lives entirely in the shape of the eye
    local ew = 2.5 * u * (1 + tone.mouth * 0.18)
    Draw.setColor(eye, 1)
    Draw.roundRect("fill", -ew * 0.5 + ex, -3.7 * u - eh * 0.5, ew, eh, eh * 0.45)
    Draw.glow(ex, -3.7 * u, 3.2 * u, eye, 0.42 + speak * 0.2)
    if tone.mouth < -0.1 then
      -- a downturned eye: shave the top corners with the plate colour
      Draw.setColor(metal(1.05))
      Draw.roundRect("fill", -ew * 0.5 + ex, -3.7 * u - eh * 0.5,
                     ew, eh * 0.34 * -tone.mouth * 2.4, eh * 0.2)
    end
  end

  -- vocoder mouth: three bars that answer the voice
  local amp = speak * tone.gain
  for i = -1, 1 do
    local h = (0.22 + abs(math.sin(tt * 17 + i * 1.9)) * amp * 1.1) * u
    Draw.setColor(eye, 0.30 + amp * 0.55)
    Draw.roundRect("fill", i * 0.85 * u - 0.22 * u, -1.9 * u - h * 0.5, 0.44 * u, h, 0.2 * u)
  end
end

local function drawHumanPortrait(spec, tt, tone, speak, blink)
  local u = 1
  local suit = spec.suit ~= false
  local skin = P.shade(P.ramp.sand, suit and 2.2 or 2.6)
  local look = spec.look or 0

  -- shoulders
  Draw.setColor(P.shade(P.ramp.metal, 1.6))
  Draw.roundRect("fill", -5.2 * u, -0.4 * u, 10.4 * u, 3.4 * u, 1.2 * u)
  Draw.setColor(P.shade(P.ramp.metal, 2.1))
  Draw.roundRect("fill", -3.0 * u, -1.6 * u, 6.0 * u, 2.2 * u, 0.9 * u)
  if suit then
    Draw.setColor(P.accent, 0.45)
    Draw.roundRect("fill", -2.4 * u, 0.6 * u, 1.5 * u, 0.34 * u, 0.17 * u)
    Draw.roundRect("fill", -2.4 * u, 1.3 * u, 2.6 * u, 0.34 * u, 0.17 * u)
  end

  -- neck + head
  Draw.setColor(P.darken(skin, 0.22))
  Draw.roundRect("fill", -0.9 * u, -2.6 * u, 1.8 * u, 2.0 * u, 0.5 * u)
  Draw.setColor(skin)
  Draw.blob(0, -4.6 * u, 2.5 * u, 20, 11, 0.055, 1.12)

  if suit then
    -- helmet: a dome, a visor, and the radio he has been talking into
    Draw.setColor(P.shade(P.ramp.metal, 2.6), 0.96)
    Draw.blob(0, -4.7 * u, 3.4 * u, 24, 5, 0.03, 1.06)
    Draw.setColor(P.shade(P.ramp.metal, 3.2), 0.7)
    Draw.roundRect("fill", -3.3 * u, -4.9 * u, 6.6 * u, 0.5 * u, 0.25 * u)
    Draw.setColor(P.accentCool, 0.30)
    Draw.blob(look * 0.3 * u, -5.2 * u, 2.4 * u, 18, 9, 0.08, 0.82)
    Draw.setColor(P.ink, 0.16)
    Draw.capsule("fill", -1.9 * u, -6.4 * u, 0.2 * u, -5.2 * u, 0.30 * u)
    -- eyes read faintly through the glass
    local open = U.saturate(tone.eye * (1 - blink))
    if open > 0.05 then
      Draw.setColor(P.black, 0.62)
      for s = -1, 1, 2 do
        Draw.roundRect("fill", s * 0.95 * u - 0.34 * u + look * 0.3 * u,
                       -5.35 * u - 0.24 * u * open, 0.68 * u, 0.48 * u * open, 0.22 * u)
      end
    end
    -- radio ticks while he is speaking
    local amp = speak * tone.gain
    if amp > 0.02 then
      for i = 1, 3 do
        Draw.setColor(P.accent, amp * (0.5 - i * 0.11))
        Draw.ring(2.9 * u, -5.4 * u, (0.7 + i * 0.6) * u, 0.16 * u, -0.9, 0.9, P.accent, 0)
      end
    end
  else
    -- no helmet. hair, brows, eyes, and a mouth that finally shows.
    Draw.setColor(P.shade(P.ramp.bark, 2.0))
    Draw.blob(0, -5.7 * u, 2.7 * u, 18, 21, 0.10, 0.62)
    Draw.setColor(P.shade(P.ramp.bark, 1.6))
    Draw.roundRect("fill", -2.6 * u, -6.3 * u, 5.2 * u, 1.3 * u, 0.6 * u)

    local open = U.saturate(tone.eye * (1 - blink))
    for s = -1, 1, 2 do
      local ex = s * 0.95 * u + look * 0.28 * u
      Draw.setColor(P.white, 0.82)
      Draw.roundRect("fill", ex - 0.52 * u, -4.9 * u - 0.30 * u * open,
                     1.04 * u, 0.60 * u * open, 0.28 * u)
      if open > 0.2 then
        Draw.setColor(P.shade(P.ramp.bark, 1.2))
        lg.circle("fill", ex + look * 0.14 * u, -4.9 * u, 0.26 * u * open)
      end
      -- brow
      Draw.setColor(P.shade(P.ramp.bark, 1.7))
      local inner, outer = -tone.brow * 0.55 * u, tone.brow * 0.28 * u
      Draw.capsule("fill", ex - s * 0.66 * u, -5.75 * u + outer,
                   ex + s * 0.60 * u, -5.75 * u + inner, 0.16 * u)
    end

    Draw.setColor(P.darken(skin, 0.16))
    Draw.capsule("fill", 0, -4.5 * u, -0.16 * u, -3.7 * u, 0.14 * u)

    -- mouth: rest shape from the tone, opened by the voice
    local amp = speak * tone.gain
    local mw = (1.15 + amp * 0.18) * u
    local mo = (0.10 + amp * 0.62) * u
    local curve = tone.mouth * 0.42 * u
    Draw.setColor(P.darken(skin, 0.55))
    if mo > 0.24 * u then
      Draw.blob(0, -2.9 * u, mw * 0.72, 14, 31, 0.06, mo / (mw * 0.72))
    else
      Draw.capsule("fill", -mw * 0.5, -2.9 * u - curve, 0, -2.9 * u + curve * 0.2, 0.13 * u)
      Draw.capsule("fill", 0, -2.9 * u + curve * 0.2, mw * 0.5, -2.9 * u - curve, 0.13 * u)
    end
  end
end

--- Draw a portrait figure at (cx, cy) scaled so the plate is `size` across.
--- `spec` = { kind = "human"|"bot", botType = ..., eye = <colour>, suit = bool,
---            look = -1..1, seed = n }
function Dialogue.drawFigure(spec, cx, cy, size, tt, tone, speak, blink)
  local u = size / 13
  lg.push()
  lg.translate(cx, cy + size * 0.30)
  lg.scale(u, u)
  lg.translate(0, math.sin(tt * 1.6 + (spec.seed or 0)) * 0.16)
  if spec.kind == "human" then
    drawHumanPortrait(spec, tt, tone, speak, blink)
  else
    drawBotPortrait(spec, tt, tone, speak, blink)
  end
  lg.pop()
end

--- The framed plate a portrait sits in.
local function drawPlate(spec, x, y, s, tt, tone, speak, blink, alpha)
  local r = s * 0.14
  Draw.setColor(P.black, 0.55 * alpha)
  Draw.roundRect("fill", x, y, s, s, r)
  Draw.linearGradient(x + 1, y + 1, s - 2, s - 2,
    P.alpha(P.shade(P.ramp.rock, 1.6), 0.85 * alpha),
    P.alpha(P.shade(P.ramp.rock, 1.0), 0.30 * alpha), math.pi * 0.5)
  local accent = (spec.kind == "human") and P.accent or (spec.eye or P.eye)
  Draw.radialGradient(x + s * 0.5, y + s * 0.72, s * 0.62,
    P.alpha(accent, 0.13 * alpha), P.alpha(accent, 0))

  local sx, sy, sw, sh = lg.getScissor()
  lg.setScissor(floor(x), floor(y), math.ceil(s), math.ceil(s))
  Dialogue.drawFigure(spec, x + s * 0.5, y + s * 0.60, s * 0.82, tt, tone, speak, blink)
  if sx then lg.setScissor(sx, sy, sw, sh) else lg.setScissor() end
  lg.setColor(1, 1, 1, 1)

  Draw.setColor(accent, 0.30 * alpha)
  lg.setLineWidth(1.5)
  Draw.roundRect("line", x + 0.75, y + 0.75, s - 1.5, s - 1.5, r)
  lg.setColor(1, 1, 1, 1)
end

--------------------------------------------------------------------- the handle
local Handle = {}
Handle.__index = Handle

local function resolveSpeaker(h, who)
  if type(who) == "table" then return who end
  local cast = h.cast
  local sp = cast and cast[who]
  if sp then return sp end
  return { name = tostring(who or "?"), portrait = { kind = "bot", botType = "planter" } }
end

local function valueOf(v, h)
  if type(v) == "function" then return v(h.ctx, h.world) end
  return v
end

--- Side effects that must happen whether the scene was watched or skipped.
local function applyEssential(h, s)
  local k = s.kind
  if k == "flag" then
    local w = h.world
    if w then
      w.flags = w.flags or {}
      local v = s.value
      if v == nil then v = true end
      w.flags[s.name] = v
    end
    Signal.emit("story:flag", s.name, s.value == nil and true or s.value)
  elseif k == "fn" then
    if s.fn then s.fn(h.ctx, h.world) end
  elseif k == "music" then
    if s.state and Music.setState then Music.setState(s.state) end
    if s.intensity and Music.setIntensity then Music.setIntensity(s.intensity) end
  end
end

local ESSENTIAL = { flag = true, fn = true, music = true }

function Handle:beginStep()
  local s = self.seq[self.i]
  if not s then self:finish() return end
  self.stepT = 0
  self.step = s
  local k = s.kind

  if ESSENTIAL[k] then
    applyEssential(self, s)
    self:next()
    return
  end

  if k == "line" then
    local sp = resolveSpeaker(self, s.who)
    self.speaker = sp
    self.speakerName = valueOf(s.name, self) or sp.name or ""
    self.lineText = tostring(valueOf(s.text, self) or "")
    self.tone = toneOf(s.tone or sp.tone)
    self.typed = 0
    self.typeI = 1
    self.typeAcc = 0
    self.complete = false
    self.holdT = 0
    if self.lineText == "" then
      -- a line with no words: the portrait alone holds the beat, and it
      -- releases itself so silence never asks the player for a keypress
      self.complete = true
      self.silentAuto = s.auto or 1.0
    else
      self.silentAuto = nil
    end
    if s.sound ~= false and Audio.play then
      Audio.play(sp.voice or (sp.portrait and sp.portrait.kind == "human" and "ui_move" or "bot_chatter"),
                 { volume = 0.22, pitch = sp.pitch or 1 })
    end
  elseif k == "wait" then
    self.waitDur = s.dur or 0.6
  elseif k == "camera" then
    self.cam = { x = s.x, y = s.y, entity = s.entity, zoom = s.zoom,
                 release = s.release, rate = s.rate or T.camRate }
    if s.dur and s.dur > 0 then self.waitDur = s.dur else self:next() return end
  elseif k == "fx" then
    local x, y = s.x, s.y
    local e = valueOf(s.entity, self)
    if e then x, y = e.x, e.y end
    if s.effect and VFX.emit then
      VFX.emit(s.effect, x or 0, y or 0, s.opts or { count = s.count })
    end
    if s.shake and J.shake then J.shake(s.shake) end
    if s.flash and J.flashScreen then
      local c = s.color or P.white
      J.flashScreen(s.flash, c[1], c[2], c[3])
    end
    if s.dur and s.dur > 0 then self.waitDur = s.dur else self:next() return end
  elseif k == "sound" then
    if s.name and Audio.play then
      Audio.play(s.name, { volume = s.volume, pitch = s.pitch })
    end
    if s.dur and s.dur > 0 then self.waitDur = s.dur else self:next() return end
  elseif k == "letterbox" then
    barTarget = s.amount or 1
    barRate = 1 / max(0.05, s.dur or T.barIn)
    if s.dur and s.wait then self.waitDur = s.dur else self:next() return end
  else
    self:next()
    return
  end
end

function Handle:next()
  self.i = self.i + 1
  self:beginStep()
end

--- Run every remaining step's essential side effects, then close.
function Handle:skip()
  if self.done then return end
  for i = self.i, #self.seq do
    local s = self.seq[i]
    if s and ESSENTIAL[s.kind] then applyEssential(self, s) end
  end
  self.i = #self.seq + 1
  self:finish(true)
end

function Handle:finish(skipped)
  if self.done then return end
  self.done = true
  self.step = nil
  self.cam = nil
  if self.world then self.world.cutscene = false end
  if A == self then A = nil end
  barTarget = 0
  barRate = 1 / T.barOut
  Signal.emit("dialogue:done", self.id, skipped == true)
  if self.onDone then self.onDone(skipped == true, self.ctx) end
end

--- Player asked to move on: finish the typing, or step forward.
function Handle:advance()
  local s = self.step
  if not s then return end
  if s.kind == "line" then
    if self.stepT < T.minLineHold then return end
    if not self.complete then
      self.typed = self._lay and self._lay.count or 0
      self.typeI = (self._lay and self._lay.count or 0) + 1
      self.complete = true
      return
    end
    self:next()
  else
    self:next()
  end
end

function Handle:update(dt)
  local s = self.step
  if not s then return end
  self.stepT = self.stepT + dt

  if s.kind == "line" then
    local lay = self._lay
    if lay and not self.complete then
      self.typeAcc = self.typeAcc + dt
      while self.typeI <= lay.count and self.typeAcc >= lay.delays[self.typeI] do
        self.typeAcc = self.typeAcc - lay.delays[self.typeI]
        self.typeI = self.typeI + 1
        self.typed = self.typeI - 1
      end
      if self.typeI > lay.count then self.complete = true self.typed = lay.count end
    end
    if self.complete then
      self.holdT = self.holdT + dt
      local auto = s.auto or self.silentAuto
      if auto and self.holdT >= auto then self:next() end
    end
  else
    if self.waitDur and self.stepT >= self.waitDur then
      self.waitDur = nil
      self:next()
    end
  end
end

------------------------------------------------------------------- public API
--- Start a sequence. Returns a handle (or nil if one is already running and
--- `opts.replace` was not set).
--- opts: world, cast, ctx, id, onDone, replace, camera
function Dialogue.play(sequence, opts)
  opts = opts or {}
  if A and not A.done then
    if not opts.replace then return nil end
    A:skip()
  end
  local h = setmetatable({
    seq    = sequence or {},
    i      = 1,
    stepT  = 0,
    world  = opts.world,
    cast   = opts.cast,
    ctx    = opts.ctx or {},
    id     = opts.id or "dialogue",
    onDone = opts.onDone,
    camera = opts.camera or (opts.world and opts.world.camera),
    tt     = 0,
    blinkT = 1.4,
    blink  = 0,
    done   = false,
  }, Handle)
  A = h
  if h.world then
    h.world.cutscene = true
    h.world.flags = h.world.flags or {}
  end
  barTarget = 1
  barRate = 1 / T.barIn
  Signal.emit("dialogue:start", h.id)
  h:beginStep()
  return h
end

function Dialogue.isActive() return A ~= nil and not A.done end
function Dialogue.current() return A end
function Dialogue.speaker() return A and A.speaker or nil end

function Dialogue.skip()
  if A and not A.done then A:skip() end
end

function Dialogue.advance()
  if A and not A.done then A:advance() end
end

--- Force-close without running anything else. Only for scene teardown.
function Dialogue.abort()
  if A and not A.done then A:finish(true) end
  barTarget = 0
end

function Dialogue.update(dt, realDt)
  realDt = realDt or dt
  -- letterbox eases whether or not a scene is running
  Dialogue.bar = U.approach(Dialogue.bar, barTarget, barRate * realDt)

  local h = A
  if not h or h.done then return end
  h.tt = h.tt + realDt

  -- blink: a quick close every few seconds, offset per speaker
  h.blinkT = h.blinkT - realDt
  if h.blinkT <= 0 then h.blinkT = 2.2 + (h.tt * 7 % 3) h.blink = 0.16 end
  if h.blink > 0 then h.blink = max(0, h.blink - realDt) end

  -- layout has to exist before the first update so the reveal is stable
  if h.step and h.step.kind == "line" and h.lineText then
    local L = Dialogue.layout()
    h._lay = layoutLine(h.step, h.lineText, L.body, L.colW)
  end

  if Input.pressed("confirm") or Input.pressed("shove") then h:advance() end
  if Input.pressed("back") or Input.pressed("pause") then h:skip() return end

  h:update(dt)

  -- camera work: recomputed from the live camera every frame so the game's
  -- own follow logic and this pan never fight each other.
  local cam = h.camera or (h.world and h.world.camera)
  if cam then
    local c = h.cam
    local tx, ty
    if c and not c.release then
      local e = valueOf(c.entity, h)
      tx, ty = valueOf(c.x, h), valueOf(c.y, h)
      if e then tx, ty = e.x, e.y end
    end
    local goX, goY = 0, 0
    if tx and ty then goX, goY = cam.x - tx, cam.y - ty end
    local rate = (c and c.rate) or T.camRate
    cam.offX = U.damp(cam.offX or 0, goX, rate, realDt)
    cam.offY = U.damp(cam.offY or 0, goY, rate, realDt)
    if c and c.zoom then cam.zoomTarget = c.zoom end
  end
end

--- Release the camera on the way out, so the pan does not snap back.
function Dialogue.releaseCamera(camera, dt)
  if not camera then return end
  camera.offX = U.damp(camera.offX or 0, 0, 3.2, dt)
  camera.offY = U.damp(camera.offY or 0, 0, 3.2, dt)
end

--------------------------------------------------------------------- layout
function Dialogue.layout()
  local w, h = lg.getDimensions()
  local k = U.clamp(h / 900, 0.72, 1.5)
  local bar = floor(h * T.barFrac)
  local panelW = min(w - 96 * k, T.panelMaxW * k)
  local panelH = U.clamp(h * 0.235, 150 * k, 236 * k)
  local px = floor((w - panelW) * 0.5)
  local py = floor(h - bar - panelH - 20 * k)
  local pad = 18 * k
  local plate = panelH - pad * 2
  local textX = px + pad + plate + 30 * k
  local colW = min(px + panelW - pad - textX, T.colMaxW * k)
  return {
    w = w, h = h, k = k, bar = bar,
    px = px, py = py, pw = panelW, ph = panelH, pad = pad,
    plate = plate, textX = textX, colW = colW,
    body = T.bodySize * k, name = T.nameSize * k,
  }
end

--------------------------------------------------------------------- rendering
local function drawBars(L, amount)
  if amount <= 0.001 then return end
  local e = U.ease.outCubic(amount)
  local bh = L.bar * e
  Draw.setColor(P.black, 0.96)
  lg.rectangle("fill", 0, 0, L.w, bh)
  lg.rectangle("fill", 0, L.h - bh, L.w, bh)
  Draw.setColor(P.black, 0.55 * e)
  Draw.linearGradient(0, bh, L.w, 26 * L.k, P.alpha(P.black, 0.5 * e), P.alpha(P.black, 0), math.pi * 0.5)
  Draw.linearGradient(0, L.h - bh - 26 * L.k, L.w, 26 * L.k,
                      P.alpha(P.black, 0), P.alpha(P.black, 0.5 * e), math.pi * 0.5)
  lg.setColor(1, 1, 1, 1)
end

local function drawPanel(L, h, alpha)
  local x, y, w, ph = L.px, L.py, L.pw, L.ph
  local r = 10 * L.k
  Draw.setColor(P.black, 0.30 * alpha)
  Draw.roundRect("fill", x + 3, y + 5, w, ph, r)
  Draw.linearGradient(x, y, w, ph,
    P.alpha(P.darken(P.ramp.rock[1], 0.35), 0.90 * alpha),
    P.alpha(P.darken(P.ramp.rock[1], 0.55), 0.74 * alpha), math.pi * 0.5)
  local accent = (h.speaker and h.speaker.portrait and h.speaker.portrait.kind == "human")
                 and P.accent or ((h.speaker and h.speaker.portrait and h.speaker.portrait.eye) or P.eye)
  Draw.setColor(accent, 0.22 * alpha)
  lg.setLineWidth(1)
  lg.line(x, y + 0.5, x + w, y + 0.5)
  Draw.setColor(P.black, 0.25 * alpha)
  lg.line(x, y + ph - 0.5, x + w, y + ph - 0.5)
  lg.setColor(1, 1, 1, 1)
  return accent
end

function Dialogue.draw()
  local L = Dialogue.layout()
  drawBars(L, Dialogue.bar)

  local h = A
  if not h or h.done or not h.step then return end
  local s = h.step
  if s.kind ~= "line" then return end

  local alpha = U.saturate(Dialogue.bar * 1.4)
  if alpha <= 0.01 then return end
  local accent = drawPanel(L, h, alpha)

  -- portrait
  local sp = h.speaker or {}
  local spec = sp.portrait or { kind = "bot", botType = "planter" }
  local speak = 0
  if not h.complete then
    speak = 0.55 + 0.45 * math.sin(h.tt * 21)
  else
    speak = max(0, 0.34 - h.holdT * 1.4)
  end
  drawPlate(spec, L.px + L.pad, L.py + L.pad, L.plate, h.tt, h.tone or TONE.flat,
            speak, h.blink > 0 and 1 or 0, alpha)

  -- name plate
  local nameY = L.py + L.pad + 2 * L.k
  Text.display(string.upper(h.speakerName or ""), L.textX, nameY, L.name, {
    color = accent, alpha = 0.95 * alpha, tracking = 0.14, weight = 0.115,
    maxWidth = L.colW, snap = true,
  })
  Draw.setColor(accent, 0.22 * alpha)
  lg.setLineWidth(1)
  local ruleY = floor(nameY + L.name * 1.65) + 0.5
  lg.line(L.textX, ruleY, L.textX + L.colW, ruleY)

  -- the words
  local lay = h._lay
  if lay then
    local lineH = L.body * 1.52
    local ty = ruleY + 14 * L.k
    for i = 1, #lay.lines do
      local text = lay.lines[i]
      local start = lay.starts[i]
      local vis = U.clamp(h.typed - start, 0, #text)
      local whole = floor(vis)
      if whole > 0 then
        local lead = text:sub(1, 1)
        local ox = LEAD[lead] and -bodyW(lead, L.body) * 0.55 or 0
        Text.body(text:sub(1, whole), L.textX + ox, ty + (i - 1) * lineH, L.body,
                  { color = P.ink, alpha = alpha })
        if whole < #text then
          -- the character mid-stroke, at partial alpha: type-on without jitter
          local nx = bodyW(text:sub(1, whole), L.body)
          Text.body(text:sub(whole + 1, whole + 1), L.textX + ox + nx,
                    ty + (i - 1) * lineH, L.body,
                    { color = P.ink, alpha = alpha * U.saturate(vis - whole) })
        end
      end
    end

    -- continue chevron
    if h.complete then
      local pulse = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(h.tt * 3.4))
      local cx = L.px + L.pw - L.pad - 12 * L.k
      local cy = L.py + L.ph - L.pad - 6 * L.k + math.sin(h.tt * 3.4) * 2 * L.k
      Draw.setColor(accent, pulse * 0.8 * alpha)
      lg.setLineWidth(2 * L.k)
      lg.line(cx - 6 * L.k, cy - 4 * L.k, cx, cy + 2 * L.k, cx + 6 * L.k, cy - 4 * L.k)
    end
  end
  lg.setColor(1, 1, 1, 1)
end

--------------------------------------------------------------- input plumbing
function Dialogue.keypressed(k)
  if not Dialogue.isActive() then return false end
  if k == "escape" then Dialogue.skip() return true end
  return true
end

return Dialogue
