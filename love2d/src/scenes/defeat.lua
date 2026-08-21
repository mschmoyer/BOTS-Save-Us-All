-- The rig finished the job.
--
-- Short, quiet, and not a punishment screen -- but not a shrug either. The run
-- ended because the sky emptied, and the thing the player will actually want to
-- know is what it cost. So this screen is built the same way dawn is: the
-- headline, the two numbers, and then the names, one per beat, in the display
-- face, right-aligned against a rule.
--
-- Type comes from UI.ts and prompts from UI.promptRow, so the last screen of a
-- lost run is set in the same voice as the first screen of the game.
local U      = require("src.core.util")
local P      = require("src.engine.palette")
local UI     = require("src.engine.ui")
local Draw   = require("src.engine.draw")
local Screen = require("src.engine.screen")
local Input  = require("src.engine.input")
local Opt    = require("src.core.optional")
local Text   = Opt.require("src.engine.text")
local Music  = Opt.require("src.engine.music")

local lg = love.graphics
local floor, min, max = math.floor, math.min, math.max

local S = {}

local SEQ = { head = 0.40, sub = 1.30, stats = 2.20, names = 2.90, nameStep = 0.34,
              foot = 4.20 }
local NAME_MAX = 5
local PROMPTS = { { "confirm", "BEGIN AGAIN" } }

function S:enter(world)
  self.world = world
  self.t = 0
  -- one flat list of names, built once: the draw pass must not walk the run
  self.names = {}
  local all = world and world.allLostNames
  if all then
    for i = 1, #all do
      local rec = all[i]
      self.names[i] = (type(rec) == "table" and rec.name) or tostring(rec)
    end
  end
  if Music.setState then Music.setState("ending") end
end

function S:update(dt)
  self.t = self.t + dt
  if self.t > SEQ.foot and (Input.pressed("confirm") or Input.pressed("back")) then
    Screen.transition(0.8, function() Screen.switch(require("src.scenes.title")) end)
  end
end

function S:draw()
  local w, h = lg.getDimensions()
  local t = self.t
  local prevLW = lg.getLineWidth()
  lg.clear(P.black[1], P.black[2], P.black[3], 1)

  -- the sky the rig took, as the faintest possible wash: the screen is not
  -- quite empty, and what is left of it is the colour of the thing they stole
  local bk = U.saturate(t * 0.5)
  UI.vgrad(0, 0, w, h * 0.6, P.o2, P.black, 0.035 * bk, 0)
  UI.vignette(0.6 * bk)

  local x0 = floor(max(UI.pad * 3, w * 0.08) / UI.u) * UI.u
  local colW = min(560, w - x0 * 2)
  -- The whole composition is one block, centred vertically: at 0.22h it sat in
  -- the top third with four hundred pixels of nothing under it, which reads as
  -- unfinished rather than as quiet.
  local y = floor(max(UI.pad * 3, (h - 330) * 0.42) / UI.u) * UI.u

  -- headline
  local hk = UI.stagger(t, 1, SEQ.head, 0, 0.9, U.ease.outExpo)
  if hk > 0.002 then
    UI.text("THE AIR IS GONE", x0, y, UI.ts.h1, UI.c(P.ink, hk), "left", hk,
            U.lerp(0.30, 0.06, hk))
  end
  local sk = UI.stagger(t, 1, SEQ.sub, 0, 0.9)
  if sk > 0.002 then
    Draw.setColor(UI.c(P.o2, 0.7 * sk))
    lg.setLineWidth(2)
    lg.line(x0, y + UI.ts.h1 + 22, x0 + colW * sk, y + UI.ts.h1 + 22)
    UI.body("They took what you grew.", x0, y + UI.ts.h1 + 36, UI.bs.lead,
            UI.c(P.inkDim, 0.9 * sk))
  end

  -- the two numbers that describe the run
  local st = self.world and self.world.stats
  local ky = y + UI.ts.h1 + 96
  if st then
    local k1 = UI.stagger(t, 1, SEQ.stats, 0.1, 0.5)
    local k2 = UI.stagger(t, 2, SEQ.stats, 0.1, 0.5)
    UI.stat(x0, ky, "TREES PLANTED", tostring(floor(st.planted or 0)),
            UI.ts.h2, P.accent, "left", k1)
    UI.stat(x0 + 260, ky, "NEVER CAME BACK", tostring(#self.names),
            UI.ts.h2, #self.names > 0 and P.danger or P.inkDim, "left", k2)
  end

  -- and then the names, right-aligned in their own column, one per beat
  local n = #self.names
  if n > 0 then
    local nx = w - x0
    local nk = UI.stagger(t, 1, SEQ.names - 0.2, 0, 0.5)
    if nk > 0.002 then
      UI.caption("THEY WERE CALLED", nx, y, UI.ts.micro,
                 UI.c(P.danger, 0.9 * nk), "right", nil, 1)
    end
    local shown = min(n, NAME_MAX)
    for i = 1, shown do
      local k = UI.stagger(t, i, SEQ.names, SEQ.nameStep, 0.6, U.ease.outExpo)
      if k > 0.002 then
        local ny = y + 26 + (i - 1) * 46
        local nw = Text.measure(self.names[i], UI.ts.h3, nil)
        Draw.setColor(UI.c(P.danger, 0.45 * k))
        lg.setLineWidth(2)
        lg.line(nx - nw - 16 - 24 * k, ny + UI.ts.h3 * 0.56, nx - nw - 16,
                ny + UI.ts.h3 * 0.56)
        UI.text(self.names[i], nx, ny + (1 - k) * 8, UI.ts.h3,
                UI.mix(P.ink, P.danger, 0.22), "right", k, 0.08)
      end
    end
    if n > shown then
      local k = UI.stagger(t, shown + 1, SEQ.names, SEQ.nameStep, 0.6)
      UI.caption("AND " .. tostring(n - shown) .. " MORE", nx, y + 26 + shown * 46,
                 UI.ts.micro, UI.c(P.danger, 0.65 * k), "right", nil, 1)
    end
  end

  -- the one line that is not a statistic
  local fk = UI.stagger(t, 1, SEQ.foot - 0.6, 0, 1.0)
  if fk > 0.002 then
    UI.text("THE ISLAND IS STILL THERE", x0, ky + 116, UI.ts.h4,
            UI.c(P.accent, 0.85 * fk), "left", fk, 0.18)
  end
  local pk = UI.stagger(t, 1, SEQ.foot, 0, 0.8)
  if pk > 0.002 then
    UI.promptRow(x0, ky + 158, PROMPTS, UI.ts.micro, P.inkDim,
                 (0.7 + 0.3 * math.sin(t * 2.2)) * pk, "left")
  end

  lg.setLineWidth(prevLW)
  lg.setColor(1, 1, 1, 1)
end

return S
