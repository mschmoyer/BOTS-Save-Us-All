-- VFX proving ground.
--   1  grid     every effect in the library, labelled, looping
--   2  stress   fill the pool and report ms/frame
--   3  ambient  day pollen | night fireflies | rain, side by side
--   4  decals   every decal kind, plus live acid puddles
-- Keys 1-4 jump phases, SPACE re-fires, Q cycles quality.
-- BOTS_PHASE=n locks a phase (used by the screenshot harness).
local U      = require("src.core.util")
local P      = require("src.engine.palette")
local VFX    = require("src.engine.vfx")
local Decals = require("src.engine.decals")

local S = {}

local floor, sin, cos, random, pi = math.floor, math.sin, math.cos, math.random, math.pi
local TAU = U.TAU

--------------------------------------------------------------- showcase table
-- name, display scale, emitter-area scale, mode: "burst" | "stream", directional
local SHOW = {
  -- ambient
  { "pollen",          1.00, 0.16, "stream" },
  { "fireflies",       1.00, 0.16, "stream" },
  { "leaf_litter",     1.00, 0.22, "stream" },
  { "ash",             1.00, 0.18, "stream" },
  { "rain",            1.00, 0.16, "stream", life = 0.34 },
  { "rain_splash",     1.00, 1.00, "burst" },
  { "mist",            0.26, 0.14, "stream" },
  -- player
  { "footstep",        1.00, 1.00, "burst", dir = true },
  { "dash_burst",      0.85, 0.85, "burst", dir = true },
  { "dash_trail",      1.00, 1.00, "sweep" },
  { "land",            0.90, 0.90, "burst" },
  { "hurt_spray",      0.90, 0.90, "burst", dir = true },
  { "heal",            0.95, 0.95, "burst" },
  -- combat
  { "shove_arc",       0.72, 0.72, "burst", dir = true },
  { "impact",          0.85, 0.85, "burst" },
  { "pulse_ring",      0.30, 0.30, "burst" },
  { "hit_spark",       1.00, 1.00, "burst", dir = true },
  { "crit",            0.58, 0.58, "burst" },
  -- growth
  { "plant_burst",     0.85, 0.85, "burst" },
  { "grow_up",         0.80, 0.80, "burst" },
  { "heal_ground",     0.38, 0.38, "burst" },
  -- economy
  { "cobalt_shimmer",  1.00, 1.00, "stream" },
  { "cobalt_pickup",   0.72, 0.72, "burst" },
  { "deposit_pop",     0.90, 0.90, "burst" },
  -- bots
  { "bot_boot",        0.90, 0.90, "burst" },
  { "bot_spark",       1.00, 1.00, "stream" },
  { "bot_death",       0.80, 0.80, "burst" },
  { "love_heart",      0.95, 0.95, "burst" },
  { "confused_bubble", 0.95, 0.95, "burst" },
  -- blight
  { "blight_spore",    1.00, 1.00, "stream" },
  { "blight_death",    0.80, 0.80, "burst" },
  { "acid_splash",     0.85, 0.85, "burst" },
  { "rift_open",       0.30, 0.30, "burst" },
  { "rift_ambient",    0.45, 0.45, "stream" },
  -- boss
  { "beam_charge",     0.32, 0.32, "stream" },
  { "slam_dust",       0.26, 0.26, "burst" },
  { "armour_break",    0.55, 0.55, "burst" },
  { "core_expose",     0.32, 0.32, "burst" },
}

local COLS, ROWS = 8, 5
local CELL_PERIOD = 0.9

-- Phase 5 is a reference sheet for the generated atlas; it is reachable with
-- the 5 key or BOTS_PHASE=5 but stays out of the automatic cycle.
local PHASES = { "grid", "stress", "ambient", "decals", "shapes" }
local PHASE_DUR = { 3.4, 2.0, 1.9, 6.0, 1e9 }
local AUTO_PHASES = 4

local STRESS_TARGET = 8000
local STRESS_MIX = { "plant_burst", "impact", "bot_death", "blight_death",
                     "rift_open", "crit", "slam_dust", "core_expose",
                     "armour_break", "cobalt_pickup", "hurt_spray", "grow_up" }

--------------------------------------------------------------------- state
local opts = {}          -- one reusable options table; VFX never retains it
local fireAt = {}        -- next fire time per showcase row
local perf = { hist = {}, n = 0, i = 0, upd = 0, drw = 0, worst = 0 }
local PERF_N = 90

local function resetPerf()
  perf.n, perf.i, perf.worst = 0, 0, 0
  for k = 1, PERF_N do perf.hist[k] = 0 end
end

local function pushPerf(ms)
  perf.i = perf.i % PERF_N + 1
  perf.hist[perf.i] = ms
  if perf.n < PERF_N then perf.n = perf.n + 1 end
  if ms > perf.worst then perf.worst = ms end
end

local function avgPerf()
  if perf.n == 0 then return 0 end
  local s = 0
  for k = 1, perf.n do s = s + perf.hist[k] end
  return s / perf.n
end

--------------------------------------------------------------------- helpers
local function cellRect(i, w, h)
  local top = 68
  local cw = w / COLS
  local chh = (h - top - 26) / ROWS
  local col = (i - 1) % COLS
  local row = floor((i - 1) / COLS)
  return col * cw, top + row * chh, cw, chh
end

local function fireCell(entry, x, y, t)
  for k in pairs(opts) do opts[k] = nil end
  opts.scale = entry[2]
  opts.area  = entry[3]
  if entry.life then opts.lifeMul = entry.life end
  if entry.dir then
    local a = t * 0.9 + (entry[1]:byte(1) or 0) * 0.3
    opts.dx, opts.dy = cos(a), sin(a)
  end
  VFX.emit(entry[1], x, y, opts)
end

--------------------------------------------------------------------- enter
function S:enter()
  VFX.init()
  self.w, self.h = love.graphics.getDimensions()
  Decals.init(self.w, self.h, { res = 1.0, halfLife = 240 })
  self.fontS = love.graphics.newFont(11)
  self.fontM = love.graphics.newFont(15)
  self.fontL = love.graphics.newFont(26)
  self.t = 0
  self.phaseT = 0
  self.phase = 1
  self.locked = tonumber(os.getenv("BOTS_PHASE") or "")
  if self.locked then self.phase = U.clamp(self.locked, 1, #PHASES) end
  self:startPhase()
end

function S:startPhase()
  VFX.clear()
  Decals.clear()
  VFX.setWind(0, 0)
  self.phaseT = 0
  resetPerf()
  for i = 1, #SHOW do fireAt[i] = 0 end   -- all cells fire in lockstep
  local name = PHASES[self.phase]
  if name == "ambient" then self:warmAmbient()
  elseif name == "grid" then self:warmGrid()
  elseif name == "decals" then self:seedDecals() end
end

--- Let the grid's continuous emitters build up before the first frame is shown.
function S:warmGrid()
  local step = 1 / 30
  local w, h = self.w, self.h
  for _ = 1, 120 do
    for i = 1, #SHOW do
      local e = SHOW[i]
      if e[4] == "stream" then
        local x, y, cw, chh = cellRect(i, w, h)
        for k in pairs(opts) do opts[k] = nil end
        opts.scale, opts.area = e[2], e[3]
        VFX.stream(e[1], x + cw * 0.5, y + chh * 0.55, step, opts)
      end
    end
    VFX.update(step)
  end
end

--- Run the ambient emitters forward so the screenshot sees a settled field.
function S:warmAmbient()
  local step = 1 / 30
  for _ = 1, 210 do
    self:ambientEmit(step, true)
    VFX.update(step)
  end
end

function S:seedDecals()
  local w, h = self.w, self.h
  local kinds = { "scorch", "blight_stain", "acid_stain", "stump", "splat", "crater" }
  local top, cw = 150, w / 6
  for i, k in ipairs(kinds) do
    local cx = (i - 0.5) * cw
    Decals.add(k, cx, top + 90, { r = 44, angle = 0 })
    for j = 1, 5 do
      Decals.add(k, cx + (random() - 0.5) * cw * 0.8,
                 top + 230 + random() * 150, { r = 12 + random() * 26,
                 angle = random() * TAU, alpha = 0.55 + random() * 0.45 })
    end
  end
  -- a footprint trail wandering across the sand
  local fx, fy, fa = 60, h - 150, -0.35
  for i = 1, 46 do
    fa = fa + sin(i * 0.31) * 0.09
    fx = fx + cos(fa) * 32
    fy = fy + sin(fa) * 32
    Decals.add("footprint", fx, fy, { r = 8, angle = fa, alpha = 0.9 })
  end
  -- live, gameplay-visible acid
  for i = 1, 5 do
    Decals.add("acid", w * 0.16 + i * w * 0.17, h - 300 + sin(i) * 40,
               { r = 30 + i * 6, life = 900 })
  end
  Decals.update(0.001)
end

--------------------------------------------------------------------- update
function S:ambientEmit(dt, warming)
  local w, h = self.w, self.h
  local third = w / 3
  VFX.setWind(34 + sin(self.phaseT * 0.5) * 26, -6)
  for k in pairs(opts) do opts[k] = nil end
  opts.area = 0.72
  VFX.stream("pollen", third * 0.5, h * 0.55, dt, opts)
  VFX.stream("leaf_litter", third * 0.5, h * 0.55, dt, opts)
  VFX.stream("fireflies", third * 1.5, h * 0.55, dt, opts)
  VFX.stream("mist", third * 1.5, h * 0.72, dt, opts)
  opts.area = 0.9
  VFX.stream("rain", third * 2.5, 90, dt, opts)
  if not warming then
    opts.area = 0.6
    VFX.stream("ash", third * 2.5, h * 0.5, dt, opts)
  end
end

function S:update(dt)
  self.t = self.t + dt
  self.phaseT = self.phaseT + dt
  local w, h = self.w, self.h
  local name = PHASES[self.phase]

  if name == "grid" then
    for i = 1, #SHOW do
      local e = SHOW[i]
      local x, y, cw, chh = cellRect(i, w, h)
      local cx, cy = x + cw * 0.5, y + chh * 0.55
      if e[4] == "stream" then
        for k in pairs(opts) do opts[k] = nil end
        opts.scale, opts.area = e[2], e[3]
        VFX.stream(e[1], cx, cy, dt, opts)
      elseif e[4] == "sweep" then
        local a = self.t * 5
        for k in pairs(opts) do opts[k] = nil end
        opts.scale = e[2]
        opts.dx, opts.dy = -sin(a), cos(a)
        VFX.stream(e[1], cx + cos(a) * cw * 0.22, cy + sin(a) * chh * 0.22, dt, opts)
      elseif self.phaseT >= fireAt[i] then
        fireAt[i] = self.phaseT + CELL_PERIOD
        fireCell(e, cx, cy, self.t)
      end
    end

  elseif name == "stress" then
    local guard = 0
    while VFX.count() < STRESS_TARGET and guard < 220 do
      guard = guard + 1
      local fx = STRESS_MIX[random(#STRESS_MIX)]
      for k in pairs(opts) do opts[k] = nil end
      opts.scale = 0.5 + random() * 0.8
      VFX.emit(fx, random() * w, random() * h, opts)
    end
    -- a permanent ambient bed underneath so the count stays pinned
    for k in pairs(opts) do opts[k] = nil end
    opts.area = 1.6
    VFX.stream("pollen", w * 0.5, h * 0.5, dt, opts)

  elseif name == "ambient" then
    self:ambientEmit(dt, false)
  end

  local t0 = love.timer.getTime()
  VFX.update(dt)
  pushPerf((love.timer.getTime() - t0) * 1000)
  perf.upd = avgPerf()
  Decals.update(dt)

  if not self.locked and self.phaseT >= PHASE_DUR[self.phase] then
    self.phase = self.phase % AUTO_PHASES + 1
    self:startPhase()
  end
end

--------------------------------------------------------------------- draw
local function bar(x, y, w, h, c, a)
  love.graphics.setColor(c[1], c[2], c[3], a)
  love.graphics.rectangle("fill", x, y, w, h, 3, 3)
end

function S:drawGrid()
  local w, h = self.w, self.h
  local g = love.graphics
  for i = 1, #SHOW do
    local x, y, cw, chh = cellRect(i, w, h)
    local st = P.mix(P.ramp.rock[1], P.ramp.rock[2], 0.42)
    bar(x + 3, y + 3, cw - 6, chh - 6, st, 1)
    g.setColor(P.ramp.rock[2][1], P.ramp.rock[2][2], P.ramp.rock[2][3], 0.7)
    g.setLineWidth(1)
    g.rectangle("line", x + 3.5, y + 3.5, cw - 7, chh - 7, 3, 3)
  end
  VFX.drawAll()
  g.setFont(self.fontS)
  for i = 1, #SHOW do
    local x, y, cw, chh = cellRect(i, w, h)
    local e = SHOW[i]
    g.setColor(P.black[1], P.black[2], P.black[3], 0.6)
    g.rectangle("fill", x + 4, y + chh - 21, cw - 8, 16)
    g.setColor(e[4] == "burst" and P.ink or P.accent)
    g.printf(e[1], x + 4, y + chh - 20, cw - 8, "center")
  end
end

function S:drawStress()
  local w, h = self.w, self.h
  VFX.drawAll()
  local g = love.graphics
  local n = VFX.count()
  local ms = perf.upd
  g.setFont(self.fontL)
  g.setColor(P.black[1], P.black[2], P.black[3], 0.72)
  g.rectangle("fill", w * 0.5 - 260, h * 0.5 - 92, 520, 184, 6, 6)
  g.setColor(n >= STRESS_TARGET and P.accent or P.warn)
  g.printf(U.comma(n) .. " particles", w * 0.5 - 240, h * 0.5 - 74, 480, "center")
  g.setFont(self.fontM)
  g.setColor(P.ink)
  g.printf(string.format("update total %.2f ms/frame  (sim %.2f  |  batch %.2f)",
           ms, VFX.stats.simMs, VFX.stats.buildMs),
           w * 0.5 - 240, h * 0.5 - 30, 480, "center")
  g.printf(string.format("worst frame: %.2f ms      budget at 60 fps: 16.67 ms", perf.worst),
           w * 0.5 - 240, h * 0.5 - 6, 480, "center")
  g.printf(string.format("scene draw: %.2f ms    peak: %s    quality: %d",
           perf.drw, U.comma(VFX.stats.peak), VFX.getQuality()),
           w * 0.5 - 240, h * 0.5 + 18, 480, "center")
  local frac = U.saturate(ms / 16.67)
  bar(w * 0.5 - 240, h * 0.5 + 52, 480, 12, P.ramp.rock[2], 0.8)
  bar(w * 0.5 - 240, h * 0.5 + 52, 480 * frac, 12,
      frac < 0.5 and P.accent or P.danger, 0.95)
end

function S:drawAmbient()
  local w, h = self.w, self.h
  local g = love.graphics
  local third = w / 3
  local skies = { P.tod.day, P.tod.night, P.tod.dusk }
  local labels = { "DAY  -  pollen + leaf litter", "NIGHT  -  fireflies + mist",
                   "STORM  -  rain + splashes + ash" }
  for i = 1, 3 do
    local s = skies[i]
    local top = P.mix(s.fog, P.black, 0.55)
    local bot = P.mix(s.fog, P.black, 0.86)
    local steps = 22
    for k = 0, steps - 1 do
      local c = P.mix(top, bot, k / (steps - 1))
      g.setColor(c[1], c[2], c[3], 1)
      g.rectangle("fill", (i - 1) * third, k * h / steps, third, h / steps + 1)
    end
    g.setColor(P.ramp.moss[1])
    g.rectangle("fill", (i - 1) * third, h * 0.82, third, h * 0.18)
  end
  VFX.drawAll()
  g.setFont(self.fontM)
  for i = 1, 3 do
    g.setColor(P.black[1], P.black[2], P.black[3], 0.55)
    g.rectangle("fill", (i - 1) * third + 12, h - 44, third - 24, 26, 4, 4)
    g.setColor(P.ink)
    g.printf(labels[i], (i - 1) * third, h - 40, third, "center")
  end
end

function S:drawDecals()
  local w, h = self.w, self.h
  local g = love.graphics
  -- a dry ground to stain
  local steps = 90
  for k = 0, steps - 1 do
    local c = P.mix(P.ramp.sand[2], P.ramp.soil[1], k / (steps - 1))
    g.setColor(c[1], c[2], c[3], 1)
    g.rectangle("fill", 0, k * h / steps, w, h / steps + 1)
  end
  Decals.draw(nil)
  VFX.drawAll()
  g.setFont(self.fontS)
  local kinds = { "scorch", "blight_stain", "acid_stain", "stump", "splat", "crater" }
  local cw = w / 6
  for i, k in ipairs(kinds) do
    g.setColor(P.black[1], P.black[2], P.black[3], 0.55)
    g.rectangle("fill", (i - 1) * cw + 10, 128, cw - 20, 16)
    g.setColor(P.ink)
    g.printf(k, (i - 1) * cw, 129, cw, "center")
  end
  g.setFont(self.fontM)
  g.setColor(P.acid)
  g.printf("live acid puddles - queryable by gameplay", 0, h - 250, w, "center")
  g.setColor(P.inkDim)
  g.printf("footprint trail", 0, h - 120, w * 0.5, "center")
  local n, ln = Decals.count()
  g.setColor(P.inkDim)
  g.printf(U.comma(n) .. " stamped decals in one canvas   |   " .. ln .. " live",
           0, h - 46, w, "center")
end

local SHAPE_ORDER = { "dot", "disc", "streak", "spark", "shard", "leaf",
                      "smoke", "heart", "annulus", "mote", "bubble", "drop",
                      "flare", "plus", "blob", "halo" }

function S:drawShapes()
  local w, h = self.w, self.h
  local g = love.graphics
  local cols, cw = 8, w / 8
  local chh = (h - 90) / 4
  g.setFont(self.fontM)
  for i, name in ipairs(SHAPE_ORDER) do
    local col = (i - 1) % cols
    local row = floor((i - 1) / cols)
    local x = col * cw + cw * 0.5
    local y = 80 + row * chh + chh * 0.42
    local q = VFX.quads[VFX.quadIndex[name]]
    local sc = math.min(cw, chh) * 0.62 / 64
    g.setBlendMode("alpha", "alphamultiply")
    g.setColor(P.ink)
    g.draw(VFX.tex, q, x - cw * 0.22, y, 0, sc, sc, 32, 32)
    g.setBlendMode("add", "alphamultiply")
    g.setColor(P.accent)
    g.draw(VFX.tex, q, x + cw * 0.22, y, 0, sc, sc, 32, 32)
    g.setBlendMode("alpha", "alphamultiply")
    g.setColor(P.inkDim)
    g.printf(name, col * cw, 80 + row * chh + chh * 0.86, cw, "center")
  end
  g.setColor(1, 1, 1, 1)
end

function S:draw()
  local w, h = self.w, self.h
  local g = love.graphics
  g.clear(P.black)
  local t0 = love.timer.getTime()

  local name = PHASES[self.phase]
  if name == "grid" then self:drawGrid()
  elseif name == "stress" then self:drawStress()
  elseif name == "ambient" then self:drawAmbient()
  elseif name == "shapes" then self:drawShapes()
  else self:drawDecals() end

  perf.drw = (love.timer.getTime() - t0) * 1000

  -- header
  g.setColor(P.black[1], P.black[2], P.black[3], 0.7)
  g.rectangle("fill", 0, 0, w, 52)
  g.setFont(self.fontL)
  g.setColor(P.accent)
  g.print("VFX", 22, 12)
  g.setFont(self.fontM)
  g.setColor(P.ink)
  g.print(string.upper(name), 82, 20)
  g.setColor(P.inkDim)
  g.printf(string.format("%d effects   %s particles   %.2f ms update   %.2f ms draw   Q%d",
           #SHOW, U.comma(VFX.count()), perf.upd, perf.drw, VFX.getQuality()),
           w - 700, 20, 678, "right")
  g.setColor(1, 1, 1, 1)
end

--------------------------------------------------------------------- input
function S:keypressed(k)
  if k == "1" or k == "2" or k == "3" or k == "4" or k == "5" then
    self.phase = tonumber(k)
    self.locked = self.phase
    self:startPhase()
  elseif k == "space" then
    self:startPhase()
  elseif k == "q" then
    VFX.setQuality((VFX.getQuality() + 1) % 3)
  elseif k == "escape" then
    love.event.quit()
  end
end

function S:resize(w, h)
  self.w, self.h = w, h
  Decals.init(w, h, { res = 1.0, halfLife = 240 })
end

return S
