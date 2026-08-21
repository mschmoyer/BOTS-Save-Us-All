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
              foot = 4.20, world = 0.10 }
local NAME_MAX = 5
local PROMPTS = { { "confirm", "BEGIN AGAIN" } }

-- The island, from a long way off, and the column of air still going up out of
-- it. The screen used to be pure black under the type -- correct as a mood and
-- wrong as a picture: at 16:9 the bottom four hundred pixels read as a page
-- that had not finished loading. Everything here is near-black on purpose. It
-- is a floor for the type to stand on, not a scene.
local SIL = { built = false, ridge = {}, trees = {} }

local function buildSil(w, h)
  if SIL.built and SIL.w == w and SIL.h == h then return end
  SIL.built, SIL.w, SIL.h = true, w, h
  local rng = U.rng(90210)
  local base = h * 0.86
  for i = 0, 48 do
    local u = i / 48
    -- one long swell with a smaller one riding on it: an island, not a hill
    local y = base - math.sin(u * 3.1 + 0.6) * h * 0.055
                   - math.sin(u * 7.7 + 2.2) * h * 0.016
    SIL.ridge[i + 1] = { x = u * w, y = y }
  end
  for i = 1, 26 do
    local u = rng:next()
    local x = u * w
    local seg = math.min(48, math.floor(u * 48) + 1)
    local y = SIL.ridge[seg].y
    SIL.trees[i] = { x = x, y = y, h = rng:range(h * 0.018, h * 0.052),
                     lean = rng:range(-0.16, 0.16), n = rng:int(3, 5),
                     seed = rng:int(1, 9999) }
  end
end

--- Bare trees. Nothing on this island has leaves any more.
local function drawSil(w, h, a)
  if a <= 0.01 then return end
  buildSil(w, h)
  local r = SIL.ridge
  -- A silhouette needs something to be a silhouette *against*: black land on a
  -- black sky is nothing at all. The horizon carries a dim wash of the colour
  -- the rig took, and the island and its dead trees are cut out of it.
  local hy = h * 0.86
  UI.vgrad(0, hy - h * 0.30, w, h * 0.30, P.black, P.o2, 0, 0.085 * a)
  UI.vgrad(0, hy - h * 0.30, w, h * 0.30, P.black, P.ramp.rift[3], 0, 0.05 * a)

  Draw.setColor(P.black, a)
  -- a strip of quads, because a 50-point concave polygon is not triangulable
  for i = 1, #r - 1 do
    lg.polygon("fill", r[i].x, r[i].y, r[i + 1].x, r[i + 1].y,
                       r[i + 1].x, h, r[i].x, h)
  end
  -- the rim of the ridge, catching what light is left
  Draw.setColor(UI.mix(P.black, P.o2, 0.42), 0.55 * a)
  lg.setLineWidth(1.5)
  for i = 1, #r - 1 do lg.line(r[i].x, r[i].y, r[i + 1].x, r[i + 1].y) end

  Draw.setColor(P.black, a)
  for i = 1, #SIL.trees do
    local t = SIL.trees[i]
    local tx = t.x + t.lean * t.h
    lg.setLineWidth(2)
    lg.line(t.x, t.y, tx, t.y - t.h)
    for j = 1, t.n do
      local k = j / (t.n + 1)
      local bx, by = U.lerp(t.x, tx, k), U.lerp(t.y, t.y - t.h, k)
      local side = (j % 2 == 0) and 1 or -1
      lg.setLineWidth(1.4)
      lg.line(bx, by, bx + side * t.h * 0.30, by - t.h * 0.22)
    end
  end
end

--- The column, still going. It did not stop when the run did.
---
--- Soft across its width, not three stacked trapezoids: a hard-sided shaft
--- with banding steps in it reads as a UI element rather than as light. The
--- seam between the two halves falls on the bright centre line, where it
--- cannot be seen.
local function drawColumn(w, h, a)
  if a <= 0.01 then return end
  -- between the two type columns, not behind the names: the last thing this
  -- screen should do is put a light source under a list of the dead
  local x = w * 0.60
  local base = h * 0.855
  local top = -h * 0.05
  local c = P.ramp.rift[3]
  local bm, am = lg.getBlendMode()
  lg.setBlendMode("add", "alphamultiply")
  for side = -1, 1, 2 do
    Draw.quad(x, base, x + 26 * side, base, x + 92 * side, top, x, top,
              c, c, c, c, 0)
    Draw.quad(x, base, x + 26 * side, base, x + 92 * side, top, x, top,
              UI.c(c, 0.10 * a), UI.c(c, 0), UI.c(c, 0), UI.c(c, 0.05 * a))
  end
  -- the hot line up the middle
  Draw.setColor(UI.mix(c, P.white, 0.5), 0.07 * a)
  lg.setLineWidth(3)
  lg.line(x, base, x, top)
  lg.setLineWidth(1)
  lg.setBlendMode(bm, am)
end

function S:enter(world)
  self.world = world
  self.t = 0
  -- One flat list of names and epitaphs, built once: the draw pass must not
  -- walk the run. Bots that die charging the rig go through bot:sacrificed, not
  -- bot:lost, so reading world.allLostNames alone leaves out exactly the ones
  -- this screen is about - the rebellion happened, and it failed.
  self.names, self.epitaphs = {}, {}
  local function push(name, epi)
    if not name then return end
    self.names[#self.names + 1] = name
    self.epitaphs[#self.names] = epi
  end
  local Story = package.loaded["src.game.story"]
  local all = world and world.allLostNames
  if all then
    for i = 1, #all do
      local rec = all[i]
      if type(rec) == "table" then
        push(rec.name, Story and Story.epitaphs and Story.epitaphs[rec.name])
      else
        push(tostring(rec))
      end
    end
  end
  if Story and Story.sacrificed then
    for i = 1, #Story.sacrificed do
      local rec = Story.sacrificed[i]
      push(rec.name, Story.epitaphs and Story.epitaphs[rec.name])
    end
  end
  -- the victory cue over THE AIR IS GONE is a category error
  if Music.setState then Music.setState("night", { intensity = 0.15 }) end
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
  local wk = UI.stagger(t, 1, SEQ.world, 0, 2.6)
  drawColumn(w, h, wk)
  drawSil(w, h, wk)
  UI.vignette(0.6 * bk)

  local x0 = floor(max(UI.pad * 3, w * 0.08) / UI.u) * UI.u
  local colW = min(560, w - x0 * 2)
  -- The whole composition is one block, centred vertically: at 0.22h it sat in
  -- the top third with four hundred pixels of nothing under it, which reads as
  -- unfinished rather than as quiet.
  local y = floor(max(UI.pad * 3, (h * 0.82 - 340) * 0.5) / UI.u) * UI.u

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
        local ny = y + 26 + (i - 1) * 56
        local nw = Text.measure(self.names[i], UI.ts.h3, nil)
        Draw.setColor(UI.c(P.danger, 0.45 * k))
        lg.setLineWidth(2)
        lg.line(nx - nw - 16 - 24 * k, ny + UI.ts.h3 * 0.56, nx - nw - 16,
                ny + UI.ts.h3 * 0.56)
        UI.text(self.names[i], nx, ny + (1 - k) * 8, UI.ts.h3,
                UI.mix(P.ink, P.danger, 0.22), "right", k, 0.08)
        -- what it did, under the name: on the screen where the run ended, the
        -- count is not the point and a bare name is not either
        local epi = self.epitaphs[i]
        if epi then
          UI.caption(epi, nx, ny + UI.ts.h3 * 0.96 + (1 - k) * 8, UI.ts.micro,
                     UI.c(P.inkDim, 0.75 * k), "right", nil, 1)
        end
      end
    end
    if n > shown then
      local k = UI.stagger(t, shown + 1, SEQ.names, SEQ.nameStep, 0.6)
      UI.caption("AND " .. tostring(n - shown) .. " MORE", nx, y + 26 + shown * 56,
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
