-- Streamed-score harness: plots the mix across one full cycle.
--
-- Read three things off the plot. The curves cross near 0.71, not 0.5 -- that is
-- equal power, and why the fade does not sag. Both ends are flat, which is
-- smootherstep and not a linear ramp. And day -> dusk and night -> boss move
-- nothing: those share a track.
--
--   BOTS_SCENE=src.scenes.demo_track tools/shot.sh 3400 1250,2350,3350 /tmp/track

local U     = require("src.core.util")
local P     = require("src.engine.palette")
local Audio = require("src.engine.audio")
local Music = require("src.engine.music")

local S = {}
local g = love.graphics
local floor, max = math.floor, math.max

local FONT, FONT_S, FONT_L

-- One cycle at the real phase lengths.
local TOUR = {
  { t = 0.0,  state = "title"  },
  { t = 4.0,  state = "day"    },
  { t = 8.0,  state = "dusk"   },   -- fall starts, 12 s
  { t = 20.0, state = "night"  },   -- ...lands here
  { t = 26.0, state = "draft"  },   -- dawn: 9 s climb
  { t = 38.0, state = "day"    },
  { t = 44.0, state = "boss"   },   -- hard cut, not a blend
  { t = 50.0, state = "ending" },
}
local LOOP = 56
local HIST = 560            -- samples across the plot
local COL = { P.ramp.leaf[3], P.ramp.cobalt[3], P.warn, P.love }

function S:enter()
  FONT, FONT_S, FONT_L = g.newFont(15), g.newFont(11), g.newFont(22)
  Music.load()
  self.t, self.next = 0, 1
  self.hist, self.paths = {}, {}
  self.log = {}
  self.sampleT = 0
end

function S:leave() Music.stop(0.2) end

function S:update(dt)
  self.t = self.t + dt
  if self.t > LOOP then
    self.t, self.next = 0, 1
    for _, h in pairs(self.hist) do for i = #h, 1, -1 do h[i] = nil end end
    for i = #self.log, 1, -1 do self.log[i] = nil end
  end

  local e = TOUR[self.next]
  if e and self.t >= e.t then
    Music.setState(e.state)
    table.insert(self.log, 1, string.format("%5.1fs  %s", self.t, e.state))
    for i = #self.log, 8, -1 do self.log[i] = nil end
    self.next = self.next + 1
  end
  Music.update(dt)

  -- fixed grid, so the plot's x is time and not frames
  self.sampleT = self.sampleT + dt
  local step = LOOP / HIST
  while self.sampleT >= step do
    self.sampleT = self.sampleT - step
    local d = Music.debug()
    for path, level in pairs(d.levels) do
      if not self.hist[path] then
        self.hist[path] = {}
        self.paths[#self.paths + 1] = path
        table.sort(self.paths)
      end
      local h = self.hist[path]
      h[#h + 1] = level
    end
    local nh = self.hist["*night"]
    if not nh then nh = {} self.hist["*night"] = nh end
    nh[#nh + 1] = d.night or 0
  end
end

local function plot(samples, x, y, w, h, col, width)
  if not samples or #samples < 2 then return end
  local pts = {}
  local step = w / (HIST - 1)
  for i = 1, #samples do
    pts[#pts + 1] = x + (i - 1) * step
    pts[#pts + 1] = y + h - U.saturate(samples[i]) * h
  end
  g.setColor(col)
  g.setLineWidth(width or 2)
  g.line(pts)
end

function S:draw()
  local w, h = g.getDimensions()
  g.clear(P.ramp.metal[1])
  local d = Music.debug()

  g.setFont(FONT_L)
  g.setColor(P.ink)
  g.print("STREAMED SCORE", 40, 30)
  g.setFont(FONT)
  g.setColor(P.inkFaint)
  g.print(string.format("state %-7s  slot %-6s  night %.3f -> %.0f  %s  bus %.2f  %4.1fs",
                        tostring(d.state), tostring(d.track), d.night or 0, d.nightTo or 0,
                        d.blending and "blend" or "cut",
                        Audio.busGain and Audio.busGain("music") or 1, self.t), 40, 62)

  -- meters
  local y = 104
  g.setFont(FONT_S)
  for i, path in ipairs(self.paths) do
    local level = d.levels[path] or 0
    g.setColor(P.inkFaint)
    g.print(path, 40, y - 15)
    g.setColor(P.alpha(P.ramp.metal[2], 0.8))
    g.rectangle("fill", 40, y, w - 80, 14, 3, 3)
    g.setColor(COL[(i - 1) % #COL + 1])
    g.rectangle("fill", 40, y, (w - 80) * U.saturate(level), 14, 3, 3)
    g.setColor(P.ink)
    g.print(string.format("%.3f", level), w - 78, y + 1)
    y = y + 44
  end

  -- the plot
  local px, py, pw, ph = 40, y + 24, w - 80, h - y - 150
  g.setColor(P.alpha(P.ramp.metal[2], 0.5))
  g.rectangle("fill", px, py, pw, ph, 4, 4)
  g.setColor(P.alpha(P.ramp.metal[3] or P.inkFaint, 0.5))
  g.setLineWidth(1)
  for _, frac in ipairs({ 0, 0.5, 0.7071, 1 }) do
    local ly = py + ph - frac * ph
    g.line(px, ly, px + pw, ly)
    g.setFont(FONT_S)
    g.print(string.format("%.2f", frac), px + pw + 6, ly - 7)
  end
  -- phase marks
  for _, e in ipairs(TOUR) do
    local lx = px + pw * (e.t / LOOP)
    g.setColor(P.alpha(P.inkFaint, 0.35))
    g.line(lx, py, lx, py + ph)
    g.setColor(P.alpha(P.inkFaint, 0.8))
    g.print(e.state, lx + 3, py + 4)
  end

  plot(self.hist["*night"], px, py, pw, ph, P.alpha(P.ink, 0.35), 1)
  for i, path in ipairs(self.paths) do
    plot(self.hist[path], px, py, pw, ph, COL[(i - 1) % #COL + 1], 2)
  end

  g.setFont(FONT)
  for i, line in ipairs(self.log) do
    g.setColor(P.alpha(P.ink, max(0.25, 1 - (i - 1) * 0.12)))
    g.print(line, 40, h - 36 - (i - 1) * 20)
  end
end

function S:keypressed(k)
  if k == "escape" then love.event.quit() end
  for _, e in ipairs(TOUR) do
    if k == string.sub(e.state, 1, 1) then Music.setState(e.state) return end
  end
end

return S
