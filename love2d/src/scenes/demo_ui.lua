-- UI proving ground.
--
--   BOTS_SCENE=src.scenes.demo_ui tools/shot.sh 600 60,160,260,360,460,560 /tmp/shots_ui
--
-- Six stages, 100 frames each, so the capture frames above land in the middle
-- of one stage apiece:
--
--   1  title           the cover, driving itself
--   2  hud             the in-game HUD over a stand-in island
--   3  build wheel     the same island with the radial menu held open
--   4  draft           a real three-chip draft over a populated dawn report
--   5  pause           the pause menu over the island
--   6  options         the options panel
--   7  boss / defeat    the extraction readouts, and the losing screen
--
-- The island underneath stages 2-5 is a stand-in built here, not the real world:
-- this file is a UI harness, and it must not depend on terrain, trees or the
-- simulation to tell us whether the interface reads.
--
-- Stages that are real Scenes are pushed onto the Screen stack so they run
-- exactly as they do in the game -- same `enter`, same top-of-stack guards.
local U        = require("src.core.util")
local P        = require("src.engine.palette")
local Draw     = require("src.engine.draw")
local UI       = require("src.engine.ui")
local Input    = require("src.engine.input")
local Screen   = require("src.engine.screen")
local TU       = require("src.game.tuning")
local Chips    = require("src.game.chips")
local HUD      = require("src.game.hud")
local BuildMenu = require("src.game.buildmenu")
local Opt      = require("src.core.optional")
local VFX      = Opt.require("src.engine.vfx")

local lg = love.graphics
local floor, min, max = math.floor, math.min, math.max
local sin = math.sin
local TAU = U.TAU

local S = {}
S.updateWhenCovered = true          -- the harness keeps the clock while a scene is up

local STAGE_FRAMES = 100

------------------------------------------------------------------ stub world
-- Only the fields the HUD, the build menu, the pause screen and the draft
-- actually read. Anything they touch that a real World has, this has.
local W = nil
local ISLAND = { built = false }

local BOT_NAMES = { "SEED-07", "FRAME-02", "PYLON-11", "THORN-04", "SCRAP-09",
                    "LAMP-01", "SEED-12", "SEED-19", "THORN-08", "SCRAP-03" }

local function buildStub()
  local rng = U.rng(4242)
  local chips = Chips.new()
  chips:add("pioneer")
  chips:add("pinBreaker")
  chips:add("seedBank")

  local bots = {}
  local order = TU.bots.order
  for i = 1, 14 do
    local t = order[rng:int(1, #order)]
    bots[i] = { alive = true, state = "work", type = t, name = BOT_NAMES[((i - 1) % 10) + 1],
                x = rng:range(0, 1600), y = rng:range(0, 900) }
  end

  W = {
    cobalt = 143, treeCount = 128, o2 = 41.6,
    cycle = 3, phase = "dusk", phaseT = 7.4, phaseDur = 12,
    cutscene = false, bots = bots, enemies = {}, chips = chips, rng = rng,
    o2Debt = 5.2,
    stats = { planted = 214, lost = 61, botsLost = 7, killed = 380 },
    allLostNames = {
      { name = "SEED-07" }, { name = "PYLON-11" }, { name = "THORN-04" },
      { name = "LAMP-01" }, { name = "SCRAP-09" }, { name = "FRAME-02" },
      { name = "SEED-12" },
    },
    player = { hp = 2, maxHp = 3, state = "alive", x = 800, y = 470,
               vx = 0, vy = 0, faceX = 1, faceY = 0 },
    director = { sideVector = function() return 0, -1 end },
  }
  function W:threat() return 0.55 end
  function W:botCount() return #self.bots end
  function W:setPhase(p) self.phase = p self.phaseT = 0 end
  function W:spawnBot() return false end
  return W
end

-- The HUD asks the camera what it can see (the bot pips and the off-screen
-- threat markers both do). The stub answers "all of it": this demo draws the
-- readouts over a flat stand-in island in screen space, so everything is.
local CAM = {
  zoom = 1,
  toScreen = function(_, x, y) return x, y end,
  toWorld = function(_, x, y) return x, y end,
  visible = function() return true end,
  viewRect = function() return 0, 0, love.graphics.getWidth(), love.graphics.getHeight() end,
}

----------------------------------------------------------------- stand-in island
-- A top-down patch of ground with canopies, deposits and bots on it, so the HUD
-- is judged against something with the tonal range of the real game rather than
-- against a flat colour.
local function buildIsland(w, h)
  if ISLAND.built and ISLAND.w == w and ISLAND.h == h then return end
  ISLAND.built, ISLAND.w, ISLAND.h = true, w, h
  local rng = U.rng(90210)
  ISLAND.patches = {}
  for i = 1, 90 do
    ISLAND.patches[i] = { x = rng:range(-100, w + 100), y = rng:range(-100, h + 100),
                          r = rng:range(70, 260), s = rng:range(1.4, 2.7),
                          seed = rng:int(1, 9999) }
  end
  ISLAND.trees = {}
  for i = 1, 64 do
    ISLAND.trees[i] = { x = rng:range(-40, w + 40), y = rng:range(-40, h + 40),
                        r = rng:range(20, 46), seed = rng:int(1, 9999),
                        ph = rng:range(0, TAU), lit = rng:range(0.6, 1) }
  end
  table.sort(ISLAND.trees, function(a, b) return a.y < b.y end)
  ISLAND.cobalt = {}
  for i = 1, 14 do
    ISLAND.cobalt[i] = { x = rng:range(40, w - 40), y = rng:range(40, h - 40),
                         r = rng:range(7, 12), ph = rng:range(0, TAU) }
  end
end

local function drawIsland(t)
  local w, h = ISLAND.w, ISLAND.h
  Draw.setColor(P.shade(P.ramp.grass, 1.7))
  lg.rectangle("fill", 0, 0, w, h)
  for i = 1, #ISLAND.patches do
    local p = ISLAND.patches[i]
    Draw.setColor(P.shade(P.ramp.grass, p.s, 0.5))
    Draw.blob(p.x, p.y, p.r, 12, p.seed, 0.22, 0.72, "fill")
  end
  for i = 1, #ISLAND.cobalt do
    local c = ISLAND.cobalt[i]
    local k = 0.6 + 0.4 * sin(t * 2 + c.ph)
    Draw.softShadow(c.x, c.y + c.r * 0.5, c.r * 1.3, c.r * 0.5, 0.35)
    Draw.setColor(UI.c(P.ramp.cobalt[2], 1))
    Draw.diamond(c.x, c.y, c.r * 0.8, c.r * 1.2, "fill")
    Draw.setColor(UI.mix(P.ramp.cobalt[3], P.ramp.cobalt[4], k))
    Draw.diamond(c.x, c.y - c.r * 0.1, c.r * 0.45, c.r * 0.7, "fill")
    Draw.glow(c.x, c.y, c.r * 3, P.ramp.cobalt[4], 0.22 * k, 2)
  end
  for i = 1, #ISLAND.trees do
    local tr = ISLAND.trees[i]
    local sway = sin(t * 0.7 + tr.ph) * tr.r * 0.05
    Draw.softShadow(tr.x + tr.r * 0.35, tr.y + tr.r * 0.45, tr.r * 1.05, tr.r * 0.5, 0.4)
    Draw.setColor(P.shade(P.ramp.leaf, 1.6))
    Draw.blob(tr.x + sway, tr.y, tr.r, 13, tr.seed, 0.2, 0.86, "fill")
    Draw.setColor(P.shade(P.ramp.leaf, 2.6 + tr.lit * 0.6, 0.85))
    Draw.blob(tr.x + sway - tr.r * 0.2, tr.y - tr.r * 0.22, tr.r * 0.66, 11,
              tr.seed + 5, 0.2, 0.86, "fill")
    Draw.setColor(P.shade(P.ramp.leafHi, 3.4, 0.5))
    Draw.blob(tr.x + sway - tr.r * 0.32, tr.y - tr.r * 0.34, tr.r * 0.32, 9,
              tr.seed + 11, 0.2, 0.86, "fill")
  end
  -- the bots, where the stub says they are
  for i = 1, #W.bots do
    local b = W.bots[i]
    Draw.softShadow(b.x, b.y + 10, 16, 7, 0.4)
    HUD.botGlyph(b.type, b.x, b.y, 15, P.ramp.metal[3], 1)
  end
  -- the player
  local p = W.player
  Draw.softShadow(p.x, p.y + 14, 20, 8, 0.45)
  Draw.setColor(P.shade(P.ramp.metal, 2.4))
  lg.circle("fill", p.x, p.y, 15, 22)
  Draw.setColor(P.shade(P.ramp.metal, 3.6))
  lg.circle("fill", p.x, p.y - 4, 9, 18)
  Draw.setColor(UI.c(P.eye, 1))
  lg.circle("fill", p.x + 5, p.y - 5, 3, 10)
  Draw.glow(p.x, p.y, 90, P.eye, 0.16, 3)
  -- dusk grade, so the HUD is judged over something other than flat daylight
  UI.vgrad(0, 0, w, h, P.tod.dusk.fog, P.tod.night.fog, 0.14, 0.30)
end

--------------------------------------------------------------------- stages
local STAGES = {
  { name = "TITLE",   scene = "src.scenes.title", warm = 2.6 },
  { name = "HUD",     hud = true },
  { name = "WHEEL",   hud = true, radial = true },
  -- The rebellion: the boss bar, the locked-out build bar and a falling
  -- oxygen arc. Previously the only way to see any of it was to play thirteen
  -- minutes of a real run, so it was never reviewed.
  { name = "BOSS",    hud = true, boss = true },
  { name = "DRAFT",   hud = true, scene = "src.scenes.draft", warm = 1.35 },
  { name = "PAUSE",   hud = true, scene = "src.scenes.pause" },
  { name = "OPTIONS", scene = "src.scenes.options" },
  { name = "DEFEAT",  scene = "src.scenes.defeat", warm = 4.6 },
}

local REPORT = {
  cycle = 3, planted = 24, lost = 6, botsLost = 3, killed = 41,
  o2 = 41.6, o2Delta = 3.8, trees = 128,
  names = { "SEED-07", "PYLON-11", "THORN-04" },
}

--------------------------------------------------------------- input shimming
-- Stage 3 has to hold the radial open with nobody at the keyboard. The real
-- BuildMenu path is driven entirely from Input.down("radial"), so the harness
-- answers that one question and leaves every other input alone.
local realDown = Input.down
local function setRadialHeld(on)
  if on then
    Input.down = function(a)
      if a == "radial" then return true end
      return realDown(a)
    end
  else
    Input.down = realDown
  end
end

--------------------------------------------------------------------- lifecycle
function S:enter()
  -- conf.lua fixes the window at 1600x900, so BOTS_W / BOTS_H only ever changed
  -- the size of the virtual screen the window was drawn onto -- the game still
  -- laid out at 16:9 and the short-viewport case went untested. The harness
  -- asks for the mode itself.
  local ew = tonumber(os.getenv("BOTS_W") or "")
  local eh = tonumber(os.getenv("BOTS_H") or "")
  if ew and eh and (ew ~= lg.getWidth() or eh ~= lg.getHeight()) then
    love.window.setMode(ew, eh, { resizable = true, msaa = 0, vsync = 0 })
    Screen.resize(ew, eh)
    ISLAND.built = false
  end

  self.frame = 0
  self.stage = 0
  self.t = 0
  self.pushed = nil
  buildStub()
  buildIsland(lg.getDimensions())
  HUD.init(W)
  BuildMenu.init(W)
  if VFX.init then VFX.init() end
  -- a couple of feed entries, so the HUD's toast column is not empty
  HUD.toast("OXYGEN 40%", P.o2, "ATMOSPHERE RISING", 30, HUD.RANK_PROGRESS)
  HUD.toast("SEED-19", P.accent, "ONLINE", 30, HUD.RANK_CHATTER)
  HUD.toast("SEED-22", P.accent, "ONLINE", 30, HUD.RANK_CHATTER)
  HUD.toast("SEED-24", P.accent, "ONLINE", 30, HUD.RANK_CHATTER)
  HUD.toast("THORN-04", P.danger, "DID NOT COME BACK", 30, HUD.RANK_LOSS)
end

-- Screen.update's numeric `for` fixes its limit before the body runs, so the
-- stack must never be shorter after this call than it was before it. Stages
-- without a scene of their own push this instead of leaving a hole.
local NULL_SCENE = {}

function S:setStage(n)
  local prev = STAGES[self.stage]
  if prev and prev.radial then setRadialHeld(false) end
  if self.pushed then
    Screen.pop()
    self.pushed = nil
  end
  self.stage = n
  local st = STAGES[n]
  if not st then return end
  if st.radial then setRadialHeld(true) end
  if st.boss then
    W.phase, W.phaseT, W.phaseDur = "extraction", 0, 1
    W.boss = { alive = true, hp = 26, maxHp = 45 }
    W.bossDrain = 8
    W.o2 = 63
    HUD.toast("PYLON-11", P.danger, "DID NOT COME BACK", 30, HUD.RANK_LOSS)
  elseif prev and prev.boss then
    W.phase, W.phaseT, W.phaseDur = "dusk", 7.4, 12
    W.boss, W.bossDrain = nil, nil
    W.o2 = 41.6
  end

  local scene = st.scene and require(st.scene) or NULL_SCENE
  if st.scene == "src.scenes.draft" then
    Screen.push(scene, W, REPORT)
  elseif st.scene == "src.scenes.pause" then
    Screen.push(scene, { world = W })
  elseif st.scene == "src.scenes.defeat" then
    Screen.push(scene, W)
  else
    Screen.push(scene)
  end
  -- give a long entrance a head start, so the capture frame lands on the
  -- finished composition rather than halfway through it
  if st.warm then scene.t = st.warm end
  self.pushed = scene
end

function S:update(dt, realDt)
  realDt = realDt or dt
  self.t = self.t + realDt
  self.frame = self.frame + 1
  local want = min(#STAGES, floor((self.frame - 1) / STAGE_FRAMES) + 1)
  if want ~= self.stage then self:setStage(want) end

  local st = STAGES[self.stage]
  if not st then return end
  if st.hud then
    if st.boss then
      W.o2 = max(4, W.o2 - realDt * 2.2)
      W.boss.hp = max(1, W.boss.hp - realDt * 1.6)
    else
      W.phaseT = min(W.phaseDur - 0.6, W.phaseT + realDt * 0.35)
    end
    HUD.update(realDt, W)
    BuildMenu.update(realDt, CAM)
  end
  if VFX.update and not st.scene then VFX.update(realDt) end
end

function S:leave() setRadialHeld(false) end

--------------------------------------------------------------------- drawing
function S:draw()
  local st = STAGES[self.stage]
  if not st then return end
  local w, h = lg.getDimensions()
  buildIsland(w, h)

  if st.hud then
    drawIsland(self.t)
    HUD.draw(W, CAM)
    BuildMenu.draw(CAM)
  elseif not st.scene then
    lg.clear(P.black[1], P.black[2], P.black[3], 1)
  elseif st.scene == "src.scenes.options" then
    -- Options is normally opened from somewhere; give it the island to sit on
    drawIsland(self.t)
  end

  -- harness slate, bottom right, deliberately in the debug voice
  -- the harness slate, parked in the one place no screen puts anything
  lg.setColor(1, 1, 1, 0.32)
  lg.print(string.format("demo_ui  %d/%d  %s  frame %d",
                         self.stage, #STAGES, st.name, self.frame),
           12, floor(h * 0.5) - 6)
  lg.setColor(1, 1, 1, 1)
end

return S
