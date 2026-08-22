-- Score visualiser.
--
-- demo_audio proves the mixer is alive; this proves the *music* is. It walks the
-- whole run -- title, day, dusk, night, boss, draft, ending -- and draws what the
-- sequencer is thinking: the four-bar theme as a piano roll with a playhead, the
-- harmony under it, which layers are armed (a layer only enters on a bar line),
-- and the last notes fired by each instrument.
--
-- The thing to watch is the piano roll. Every phrase, the same notes land on the
-- same steps. That is the difference between a tune and a random walk, and it is
-- the reason the ending can play the first half of this and leave the second half
-- empty and have that mean something.

local U     = require("src.core.util")
local P     = require("src.engine.palette")
local Audio = require("src.engine.audio")
local Music = require("src.engine.music_procedural")

local S = {}
local g = love.graphics
local floor, max, min = math.floor, math.max, math.min

local FONT, FONT_S, FONT_L, FONT_XL

-- A tour of the whole run, in the order a player meets it.
local TOUR = {
  { t = 0.0,  state = "title",  cycle = 1, it = 0.05, o2 = 0.10 },
  { t = 8.0,  state = "day",    cycle = 1, it = 0.15, o2 = 0.25 },
  { t = 18.0, state = "dusk",   cycle = 3, it = 0.50, o2 = 0.45 },
  { t = 25.0, state = "night",  cycle = 3, it = 0.80, o2 = 0.50 },
  { t = 35.0, state = "draft",  cycle = 5, it = 0.10, o2 = 0.70 },
  { t = 42.0, state = "day",    cycle = 7, it = 0.30, o2 = 0.80 },
  { t = 50.0, state = "boss",   cycle = 7, it = 1.00, o2 = 0.85 },
  { t = 62.0, state = "ending", cycle = 7, it = 0.00, o2 = 1.00 },
}
local LOOP = 74

local LCOL = { pad = P.ramp.rift[3], bass = P.ramp.cobalt[3], arp = P.ramp.leaf[3],
               bell = P.warn, perc = P.danger, choir = P.love }

local function panel(x, y, w, h, title)
  g.setColor(P.alpha(P.ramp.metal[1], 0.55))
  g.rectangle("fill", x, y, w, h, 6, 6)
  g.setColor(P.alpha(P.ramp.metal[2], 0.7))
  g.setLineWidth(1)
  g.rectangle("line", x, y, w, h, 6, 6)
  if title then
    g.setFont(FONT_S)
    g.setColor(P.inkFaint)
    g.print(string.upper(title), x + 10, y + 7)
  end
end

function S:enter()
  FONT, FONT_S = g.newFont(14), g.newFont(11)
  FONT_L, FONT_XL = g.newFont(19), g.newFont(34)
  Audio.load()
  Music.load()
  self.t = 0
  self.next = 1
  self.fired = {}          -- phraseStep -> age, for the piano-roll playhead glow
  self.applied = nil
end

function S:leave() Audio.stopAll() end

function S:update(dt)
  self.t = self.t + dt
  if self.t >= LOOP then self.t = 0 self.next = 1 end
  while self.next <= #TOUR and TOUR[self.next].t <= self.t do
    local e = TOUR[self.next]
    Music.setCycle(e.cycle)
    Music.setState(e.state, { cycle = e.cycle })
    Music.setIntensity(e.it)
    Music.setO2(e.o2)
    self.applied = e
    self.next = self.next + 1
  end
  Audio.update(dt, 0, 0)
  Music.update(dt)
  for k, v in pairs(self.fired) do
    self.fired[k] = v - dt
    if self.fired[k] <= 0 then self.fired[k] = nil end
  end
  local d = Music.debug()
  if d.phraseStep then self.fired[d.phraseStep] = 0.5 end
end

--- The theme as a piano roll: four bars across, scale degrees up.
local function drawRoll(x, y, w, h, d)
  local theme = Music.theme
  local steps = Music.phraseSteps
  local lo, hi = 99, -99
  for i = 1, #theme do lo = min(lo, theme[i][2]) hi = max(hi, theme[i][2]) end
  local rows = hi - lo + 1
  local rh = h / rows
  local sw = w / steps

  -- bar lines and the 16th grid
  for i = 0, steps do
    local bx = x + i * sw
    local bar = (i % 16 == 0)
    g.setColor(P.alpha(P.ramp.metal[bar and 3 or 1], bar and 0.8 or 0.5))
    g.rectangle("fill", bx, y, bar and 2 or 1, h)
  end
  -- the answer half, marked: this is what the ending leaves empty
  g.setColor(P.alpha(P.ramp.rift[2], 0.25))
  g.rectangle("fill", x + w * 0.5, y, w * 0.5, h)

  local playing = d.phraseStep or 0
  for i = 1, #theme do
    local t = theme[i]
    local nx = x + t[1] * sw
    local nw = max(3, min(t[3], steps - t[1]) * sw - 2)
    local ny = y + (hi - t[2]) * rh
    local muted = (d.state == "ending" and t[1] >= 32)
                  or (d.state == "night" and t[4] < 0.8)
    local hot = (playing >= t[1] and playing < t[1] + t[3]) and 1 or 0
    local col = muted and P.ramp.metal[2] or P.warn
    g.setColor(P.alpha(col, muted and 0.22 or (0.4 + 0.6 * hot)))
    g.rectangle("fill", nx + 1, ny + 2, nw, rh - 4, 3, 3)
    if not muted then
      g.setColor(P.alpha(P.ink, 0.25 + 0.6 * hot))
      g.setFont(FONT_S)
      g.print(tostring(t[2]), nx + 5, ny + rh / 2 - 8)
    end
  end
  -- playhead
  g.setColor(P.accent)
  g.rectangle("fill", x + playing * sw, y - 4, 2, h + 8)
end

function S:draw()
  local W, H = g.getDimensions()
  g.clear(P.black)
  local d = Music.debug()

  g.setFont(FONT_XL) g.setColor(P.ink) g.print("SCORE", 32, 22)
  g.setFont(FONT_S) g.setColor(P.inkFaint)
  g.print("one theme, seven states", 152, 40)

  g.setFont(FONT)
  local info = string.format("%s  %s   cycle %d   %.0f BPM   bar %d   chord %s   voices %d",
    string.upper(d.state), d.mode, d.cycle, d.bpm, d.bar, d.chord, Audio.voiceCount())
  g.setColor(P.inkDim)
  g.print(info, W - g.getFont():getWidth(info) - 32, 34)
  g.setColor(P.alpha(P.ramp.metal[2], 0.8))
  g.rectangle("fill", 32, 72, W - 64, 1)

  ------------------------------------------------------------------ the roll
  local rx, ry, rw, rh = 32, 96, W - 64, floor(H * 0.38)
  panel(rx, ry, rw, rh, "the theme  ·  four bars  ·  call | answer")
  drawRoll(rx + 20, ry + 40, rw - 40, rh - 70, d)
  g.setFont(FONT_S) g.setColor(P.inkFaint)
  g.print("CALL", rx + 24, ry + rh - 24)
  g.print(d.state == "ending" and "ANSWER — withheld" or "ANSWER",
          rx + 24 + (rw - 40) * 0.5, ry + rh - 24)

  ------------------------------------------------------------------- layers
  local lx, ly, lw = 32, ry + rh + 16, (W - 80) * 0.46
  local lh = H - 64 - ly
  panel(lx, ly, lw, lh, "layers  ·  filled = armed, tick = target")
  for i, l in ipairs(d.layers) do
    local y = ly + 40 + (i - 1) * 34
    g.setFont(FONT) g.setColor(P.ink) g.print(l, lx + 14, y)
    local bx, bw = lx + 84, lw - 156
    g.setColor(P.alpha(P.black, 0.55))
    g.rectangle("fill", bx, y + 3, bw, 12, 3, 3)
    g.setColor(LCOL[l] or P.ink)
    g.rectangle("fill", bx, y + 3, bw * U.saturate(d.gains[l]), 12, 3, 3)
    g.setColor(P.alpha(P.ink, 0.8))
    g.rectangle("fill", bx + bw * U.saturate(d.targets[l]) - 1, y + 1, 2, 16)
    g.setFont(FONT_S) g.setColor(P.inkFaint)
    g.print(string.format("%.2f", d.gains[l]), lx + lw - 52, y + 3)
  end

  ------------------------------------------------------------------ harmony
  local hx = lx + lw + 16
  local hw = W - 32 - hx
  panel(hx, ly, hw, lh, "harmony and drivers")
  local cy = ly + 40
  g.setFont(FONT)
  for i, deg in ipairs(d.prog) do
    local cw = (hw - 28) / #d.prog
    local cx = hx + 14 + (i - 1) * cw
    local on = (i == d.chordIndex)
    g.setColor(on and P.alpha(P.accent, 0.22) or P.alpha(P.ramp.metal[1], 0.6))
    g.rectangle("fill", cx + 2, cy, cw - 4, 42, 4, 4)
    g.setColor(on and P.accent or P.inkFaint)
    local nm = on and d.chord or ("d" .. deg)
    g.print(nm, cx + cw / 2 - g.getFont():getWidth(nm) / 2, cy + 12)
  end
  local drivers = { { "intensity", d.intensity, P.danger }, { "O2", d.o2, P.o2 },
                    { "music duck", Audio.duckAmount(), P.warn },
                    { "dialogue duck", Audio.dialogueDuck(), P.love } }
  for i, dr in ipairs(drivers) do
    local y = cy + 62 + (i - 1) * 30
    g.setFont(FONT_S) g.setColor(P.inkDim) g.print(dr[1], hx + 14, y)
    g.setColor(P.alpha(P.black, 0.55))
    g.rectangle("fill", hx + 120, y - 1, hw - 190, 11, 3, 3)
    g.setColor(dr[3])
    g.rectangle("fill", hx + 120, y - 1, (hw - 190) * U.saturate(dr[2]), 11, 3, 3)
    g.setColor(P.inkFaint)
    g.print(string.format("%.2f", dr[2]), hx + hw - 46, y)
  end

  -- bus meters, so the score can be read against what the mixer is doing
  local my = ly + 40 + 6 * 34 + 10
  g.setFont(FONT_S) g.setColor(P.inkFaint) g.print("BUSES", lx + 14, my)
  for i, bus in ipairs({ "master", "music", "sfx", "ui" }) do
    local m = Audio.meter(bus)
    local y = my + 18 + (i - 1) * 22
    g.setFont(FONT_S) g.setColor(P.inkDim) g.print(bus, lx + 14, y)
    g.setColor(P.alpha(P.black, 0.55))
    g.rectangle("fill", lx + 84, y - 1, lw - 156, 10, 3, 3)
    g.setColor(bus == "music" and P.love or P.accentCool)
    g.rectangle("fill", lx + 84, y - 1, (lw - 156) * U.saturate(m.rms * 2.4), 10, 3, 3)
    g.setColor(P.inkFaint)
    g.print(string.format("%.3f  %dv", m.rms, m.voices), lx + lw - 74, y)
  end

  -------------------------------------------------------------- recent notes
  local ny = ly + lh - 34
  g.setFont(FONT_S) g.setColor(P.inkFaint) g.print("NOTES", hx + 14, ny)
  local nx = hx + 62
  for _, n in ipairs(d.notes) do
    local a = U.saturate(1 - n.t / 1.6)
    g.setColor(P.alpha(LCOL[n.inst] or P.ink, 0.25 + 0.75 * a))
    local str = string.format("%s%+d", n.inst:sub(1, 2), n.semis)
    g.print(str, nx, ny)
    nx = nx + g.getFont():getWidth(str) + 9
  end

  ------------------------------------------------------------------ timeline
  local ty = H - 40
  g.setFont(FONT_S)
  g.setColor(P.alpha(P.ramp.metal[1], 0.8))
  g.rectangle("fill", 32, ty, W - 64, 14, 3, 3)
  for _, e in ipairs(TOUR) do
    local x = 32 + (W - 64) * (e.t / LOOP)
    local on = (self.applied == e)
    g.setColor(on and P.accent or P.alpha(P.inkFaint, 0.7))
    g.rectangle("fill", x, ty - 2, on and 2 or 1, 18)
    g.print(e.state, x + 4, ty - 18)
  end
  g.setColor(P.accent)
  g.rectangle("fill", 32 + (W - 64) * (self.t / LOOP), ty - 4, 2, 22)
end

function S:keypressed(k)
  if k == "escape" then love.event.quit() end
  local map = { ["1"] = "title", ["2"] = "day", ["3"] = "dusk", ["4"] = "night",
                ["5"] = "boss", ["6"] = "draft", ["7"] = "ending" }
  if map[k] then Music.setState(map[k]) self.applied = nil end
end

return S
