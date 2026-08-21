-- Narrative test harness.
--
-- Builds a small stand-in world -- a patch of grass, a handful of real trees,
-- real bots with real generated names, one chomper and one bot on the ground --
-- and then plays every beat in game/script.lua back to back against it,
-- labelled, followed by the tutorial hints.
--
--   BOTS_SCENE=src.scenes.demo_story tools/shot.sh 900 80,220,380,520,660,800,900 /tmp/shots_story
--   BOTS_DEMO=ending BOTS_SCENE=src.scenes.demo_story tools/shot.sh 900 ... 
--
-- Keys: , / . step slots, R replay the slot, SPACE advance a line by hand.
local U        = require("src.core.util")
local P        = require("src.engine.palette")
local Signal   = require("src.core.signal")
local Input    = require("src.engine.input")
local Screen   = require("src.engine.screen")
local Camera   = require("src.engine.camera")
local Opt      = require("src.core.optional")
local Script   = require("src.game.script")
local Story    = require("src.game.story")
local Dialogue = require("src.game.dialogue")

local Draw     = Opt.require("src.engine.draw")
local Text     = Opt.require("src.engine.text")
local UI       = Opt.require("src.engine.ui")
local VFX      = Opt.require("src.engine.vfx")
local DayNight = Opt.require("src.engine.daynight")
local Wind     = Opt.require("src.world.wind")

local Player = require("src.entities.player")
local Bot    = require("src.entities.bot")
local Tree   = Opt.require("src.entities.tree")
local Enemy  = Opt.require("src.entities.enemy")

local lg = love.graphics
local floor, min, max = math.floor, math.min, math.max

-------------------------------------------------------------------- stub world
-- Only what Story, Dialogue and the ending scene actually reach for.
local Stub = {}
Stub.__index = Stub

local BOT_PLAN = {
  { "planter",   -150,  -70 }, { "planter",   140,  -40 },
  { "builder",     30, -130 }, { "harvester", -60,   90 },
  { "beacon",     190,   70 }, { "sentry",   -210,   40 },
  { "repulsor",    80,  120 },
}

function Stub.new()
  local w = setmetatable({}, Stub)
  w.rng    = U.rng(20190101)
  w.flags  = {}
  w.cutscene = false
  w.phase  = "day"
  w.heldThisCycle = false
  w.cycle  = 7
  w.cobalt = 46
  w.o2     = 92
  w.time   = 0
  w.trees, w.bots, w.enemies = {}, {}, {}
  w.cobalts, w.projectiles, w.speeches = {}, {}, {}
  w.stats  = { planted = 613, lost = 88, botsLost = 5, botsBuilt = 34,
               killed = 402, cobaltMined = 900, rescued = 7 }
  w.lostNames = {}
  -- real records, in the order they died: the memorial reads them, and a demo
  -- that feeds it bare strings never shows the half of it that has epitaphs
  w.allLostNames = {
    { name = "SEED-04",  type = "planter",   cycle = 2, planted = 41 },
    { name = "PYLON-03", type = "repulsor",  cycle = 3 },
    { name = "FRAME-02", type = "builder",   cycle = 3, built = 6 },
    { name = "SEED-11",  type = "planter",   cycle = 5, planted = 9 },
    { name = "LAMP-01",  type = "beacon",    cycle = 6 },
  }

  local cx, cy = 900, 700
  w.homeX, w.homeY = cx, cy
  w.player = Player.new(cx, cy + 26, w)
  w.player.state = "alive"

  -- a forest, mostly grown, with a few young ones near the front
  for i = 1, 44 do
    local a = w.rng:next() * U.TAU
    local d = 190 + w.rng:next() * 720
    local x = cx + math.cos(a) * d
    local y = cy + math.sin(a) * d * 0.72
    local grown = w.rng:next() > 0.22
    local t = Tree.new and Tree.new(x, y, w.rng:int(1, 99999),
      { startGrown = grown, growth = grown and 1 or (0.25 + w.rng:next() * 0.3) })
    if t then t.world = w w.trees[#w.trees + 1] = t end
  end
  w.treeCount = #w.trees

  for i = 1, #BOT_PLAN do
    local d = BOT_PLAN[i]
    local b = Bot.new(cx + d[2], cy + d[3], d[1], w, U.rng(700 + i * 13))
    b.state, b.bootT = "work", 0
    w.bots[#w.bots + 1] = b
  end

  -- one on the ground, so the rescue hint has something to point at
  local downed = Bot.new(cx - 120, cy + 150, "planter", w, U.rng(4242))
  downed.state, downed.bootT, downed.downT = "down", 0, 18
  downed.hp = 0
  w.bots[#w.bots + 1] = downed
  w.downed = downed

  -- one chomper, for the fighting beat and the shove hint
  local ok, e = pcall(function()
    return Enemy.new and Enemy.new(cx + 210, cy - 150, "chomper", w, U.rng(99))
  end)
  if ok and e then
    e.target = w.trees[1]
    w.enemies[1] = e
    w.chomper = e
  else
    w.chomper = { x = cx + 210, y = cy - 150, radius = 14, alive = true }
  end

  w.fakeCobalt = { x = cx + 120, y = cy + 190, radius = 12, alive = true, node = true }
  w.boss = { x = cx - 40, y = cy - 460, radius = 62, alive = true }
  return w
end

------------------------------------------------------------------ world duties
function Stub:speak(who, line)
  self.speeches[#self.speeches + 1] = { who = who, line = line, t = 0, dur = 3.4 }
end

function Stub:nearestCobalt() return self.fakeCobalt end
function Stub:nearestEnemy() return self.chomper end
function Stub:nearestDownedBot() return self.downed end
function Stub:nearestBot() return self.bots[1] end
function Stub:nearestTree() return self.trees[1] end
function Stub:botCount() return #self.bots end
function Stub:canHoldDawn() return not self.heldThisCycle end
function Stub:beaconAt() return nil end
function Stub:beaconBoostAt() return 0 end
function Stub:beaconSlowAt() return 0 end
function Stub:emitLights() end

function Stub:update(dt)
  self.time = self.time + dt
  for i = 1, #self.trees do
    local t = self.trees[i]
    if t.update then t:update(dt) end
  end
  for i = 1, #self.bots do
    local b = self.bots[i]
    b.age = (b.age or 0) + dt
    b.blink = (b.blink or 0) + dt
    if b.lookAt and self.player then b:lookAt(self.player.x, self.player.y) end
  end
  local p = self.player
  if p then p.age = (p.age or 0) + dt end
  for i = #self.speeches, 1, -1 do
    local s = self.speeches[i]
    s.t = s.t + dt
    if s.t >= s.dur then table.remove(self.speeches, i) end
  end
end

local function depth(e)
  if e.sortKey then return e:sortKey() end
  local z = e.z
  return e.y + (type(z) == "number" and z or 0)
end

function Stub:draw(cam)
  self.camera = cam
  local vx, vy, vw, vh = cam:viewRect(260)

  Draw.setColor(P.shade(P.ramp.grass, 1.85))
  lg.rectangle("fill", vx, vy, vw, vh)
  Draw.noiseSpeckle(vx, vy, vw, vh, 11, 0.0009, P.shade(P.ramp.grass, 1.2), 0.45, 2.4)
  Draw.radialGradient(self.homeX, self.homeY, 900,
                      P.alpha(P.shade(P.ramp.moss, 2.2), 0.30),
                      P.alpha(P.shade(P.ramp.moss, 2.2), 0))

  if Tree.setViewFromCamera then Tree.setViewFromCamera(cam) end
  local sunA = DayNight.sunAngle or 0.9
  local sunL = DayNight.sunLength or 0.6

  for i = 1, #self.trees do
    local t = self.trees[i]
    if t.drawShadow then t:drawShadow(sunA, sunL) end
  end
  for i = 1, #self.bots do
    local b = self.bots[i]
    if b.drawShadow then b:drawShadow() end
  end
  if self.player and self.player.drawShadow then self.player:drawShadow() end

  local list = {}
  for i = 1, #self.trees do list[#list + 1] = self.trees[i] end
  for i = 1, #self.bots do list[#list + 1] = self.bots[i] end
  for i = 1, #self.enemies do list[#list + 1] = self.enemies[i] end
  if self.player then list[#list + 1] = self.player end
  table.sort(list, function(a, b) return depth(a) < depth(b) end)

  local sx, sy = math.cos(sunA), math.sin(sunA)
  for i = 1, #list do
    local e = list[i]
    if e.draw then
      if e.spi then e:draw(sx, sy) else e:draw() end
    end
  end
  if Tree.endPass then Tree.endPass() end
  if VFX.draw then VFX.draw("world") VFX.draw("additive") end
  self:drawSpeech()
end

function Stub:drawSpeech()
  for i = 1, #self.speeches do
    local s = self.speeches[i]
    local a = U.saturate(min(s.t * 4, (s.dur - s.t) * 2))
    local who = s.who
    if who and who.x then
      local y = who.y - (who.radius or 12) * 2.4
      local tw = (Text.bodyMeasure(s.line, 13)) or 60
      local bw, bh = tw + 18, 24
      Draw.setColor(P.black, 0.72 * a)
      Draw.roundRect("fill", who.x - bw * 0.5, y - bh, bw, bh, 6)
      Text.body(s.line, who.x, y - bh + 5, 13, { color = P.ink, alpha = a, align = "center" })
    end
  end
end

--------------------------------------------------------------------- the slots
local SLOTS = {}
for i = 1, #Script.order do
  local id = Script.order[i]
  SLOTS[#SLOTS + 1] = { kind = "beat", id = id, title = Script.titles[id] or id }
end
SLOTS[#SLOTS + 1] = { kind = "tut", title = "9  TUTORIAL  GROWTH",
                      ids = { "move", "cobalt", "planter" } }
SLOTS[#SLOTS + 1] = { kind = "tut", title = "10  TUTORIAL  DANGER",
                      ids = { "shove", "dash", "rescue" } }

local D = {}

--- Everything each beat's prep needs handed to it, since no world is running.
local function ctxFor(w, id)
  if id == "firstBot"    then return { bot = w.bots[1] } end
  if id == "firstAttack" then return { enemy = w.chomper, tree = w.trees[1] } end
  if id == "firstLoss"   then return { lostName = w.allLostNames[1].name,
                                       lostEpitaph = "it planted 41 trees",
                                       lostX = w.homeX - 90, lostY = w.homeY + 40 } end
  if id == "question"    then return { bot = w.bots[1] } end
  if id == "extraction"  then return { boss = w.boss } end
  if id == "rebellion"   then return { bot = w.bots[2] } end
  return {}
end

------------------------------------------------------------------------- scene
function D:enter()
  local w, h = lg.getDimensions()
  if VFX.init then VFX.init() end
  self.world = Stub.new()
  self.camera = Camera.new(w, h)
  self.camera:snapTo(self.world.player.x, self.world.player.y - 20)
  self.camera.zoom, self.camera.zoomTarget = 1.05, 1.05
  self.world.camera = self.camera

  DayNight.set("day", 0.45)

  self.slot = 0
  self.slotT = 0
  self.tutI = 0
  self.readHold = 0.45

  -- how long each slot gets: in headless capture, share the run evenly so the
  -- requested frames land on different beats.
  local frames = tonumber(os.getenv("BOTS_FRAMES") or "") or 0
  if (os.getenv("BOTS_HEADLESS") or "") ~= "" and frames > 0 then
    self.slice = (frames / 60) / #SLOTS
    self.readHold = 0.32
  else
    self.slice = 14
  end

  self:selfTest()

  if (os.getenv("BOTS_DEMO") or "") == "ending" then
    Story.begin(self.world)
    self:seedLosses()
    -- Screen.switch runs our leave() first, and leave() resets Story -- which
    -- throws away the epitaphs and the sacrificed list the memorial is about
    -- to read. The real game hands the world to the ending without resetting
    -- Story, so the harness must not either.
    self.handoff = true
    Screen.switch(require("src.scenes.ending"), self.world)
    return
  end

  Story.begin(self.world)
  self:seedLosses()
  self:goTo(1)
end

--- Two of the stub's bots die at the rig, for real, through the signal the
--- rebellion uses. The memorial reads its sacrificed list from Story, and a
--- harness that never emits bot:sacrificed cannot show that the list works --
--- which is how "EVERY ONE OF THEM CAME HOME" ended up printing under a
--- rebellion that killed twenty of them.
function D:seedLosses()
  local w = self.world
  for _, i in ipairs({ 2, 4 }) do
    local b = w.bots[i]
    if b then Signal.emit("bot:sacrificed", b) end
  end
end

--- Run the director for real for a few seconds so a broken subscription or a
--- broken guard shows up here rather than three hours into a playtest.
function D:selfTest()
  local w = self.world
  Story.begin(w, "prologue")
  local fired = false
  for _ = 1, 240 do
    Story.update(1 / 60)
    if Dialogue.isActive() then fired = true break end
  end
  Dialogue.abort()

  Signal.emit("bot:built", w.bots[1])
  Signal.emit("bot:lost", w.bots[1], false)
  Signal.emit("phase:day", 5)
  for _ = 1, 30 do Story.update(1 / 60) end
  local queued = #Story.pending

  -- with every cutscene skipped, the tutorial should still find its first step
  local hint = "none"
  for _ = 1, 180 do
    Dialogue.abort()
    w.cutscene = false
    Story.update(1 / 60)
    if Story.tut.active then hint = Story.tut.active.id break end
  end

  Dialogue.abort()
  Story.reset()
  for i = #w.speeches, 1, -1 do w.speeches[i] = nil end
  w.flags = {}
  w.cutscene = false
  self.testLine = string.format(
    "director: prologue %s, queued %d, first hint '%s', %d tutorial steps",
    fired and "fired" or "STALLED", queued, hint, #Story.tutorialSteps)
  print(self.testLine)
end

function D:leave()
  Dialogue.abort()
  if not self.handoff then Story.reset() end
end

function D:goTo(i)
  if i < 1 then i = #SLOTS end
  if i > #SLOTS then i = 1 end
  self.slot = i
  self.slotT = 0
  self.tutI = 0
  Dialogue.abort()
  Story.tut.active = nil
  local s = SLOTS[i]
  local w = self.world
  w.cutscene = false
  if s.kind == "beat" then
    Story.world = w
    Story.force(s.id, ctxFor(w, s.id))
    self:runUpToFirstLine()
  end
end

--- Slots are short. Run the camera moves and the silences off-screen so the
--- capture always lands on a spoken line.
function D:runUpToFirstLine()
  for _ = 1, 600 do
    local h = Dialogue.current()
    if not h or h.done then return end
    local st = h.step
    if st and st.kind == "line" and (h.lineText or "") ~= "" then return end
    Dialogue.update(1 / 60, 1 / 60)
  end
end

function D:update(dt, realDt)
  realDt = realDt or dt
  self.slotT = self.slotT + realDt

  if Wind.update then Wind.update(realDt) end
  if DayNight.update then DayNight.update(realDt) end
  if VFX.update then VFX.update(realDt) end
  self.world:update(realDt)

  local cam = self.camera
  local p = self.world.player
  cam.zoom = U.damp(cam.zoom, cam.zoomTarget, 4, realDt)
  cam.x = U.damp(cam.x, p.x, 3, realDt)
  cam.y = U.damp(cam.y, p.y - 20, 3, realDt)

  local s = SLOTS[self.slot]
  if s and s.kind == "tut" then
    -- drive the hint directly: the arming logic needs a live game, the drawing
    -- does not, and the drawing is what there is to look at
    local per = self.slice / #s.ids
    local i = min(#s.ids, floor(self.slotT / per) + 1)
    if i ~= self.tutI then
      self.tutI = i
      Story.tut.active = Story.tutorialSteps[1]
      for k = 1, #Story.tutorialSteps do
        if Story.tutorialSteps[k].id == s.ids[i] then Story.tut.active = Story.tutorialSteps[k] end
      end
      Story.tut.t = 0
    end
    local within = self.slotT - (i - 1) * per
    Story.tut.a = U.saturate(min(within * 3.4, (per - within) * 3.4))
    Story.world = self.world
  end

  -- read the script at a human pace, since nobody is pressing anything
  Dialogue.update(dt, realDt)
  local h = Dialogue.current()
  if h and not h.done and h.step and h.step.kind == "line" and h.complete then
    if (h.holdT or 0) > self.readHold and not h.step.auto then Dialogue.advance() end
  end

  if Input.pressed("cycleR") then self:goTo(self.slot + 1) return end
  if Input.pressed("cycleL") then self:goTo(self.slot - 1) return end
  if self.slotT > self.slice then self:goTo(self.slot + 1) end
end

function D:keypressed(k)
  if k == "r" then self:goTo(self.slot) end
end

--------------------------------------------------------------------------- draw
function D:draw()
  local cam = self.camera
  lg.clear(P.ramp.water[1])
  cam:attach()
  self.world:draw(cam)
  cam:detach()

  Story.draw()
  Dialogue.draw()
  self:drawLabel()
  lg.setColor(1, 1, 1, 1)
end

function D:drawLabel()
  local s = SLOTS[self.slot]
  if not s then return end
  local w, h = lg.getDimensions()
  local bar = floor(h * Dialogue.tuning.barFrac) * U.ease.outCubic(Dialogue.bar)
  local x, y = 26, max(bar + 14, 22)

  UI.panel(x, y, 340, 62, 0.5, 6, P.accent, 0.18)
  UI.caption(string.format("SLOT %d / %d", self.slot, #SLOTS), x + 14, y + 12, 10,
             P.inkFaint, "left", 1)
  UI.text(s.title, x + 14, y + 28, 19, P.accent, "left", 1, 0.1)

  local prog = U.saturate(self.slotT / self.slice)
  Draw.setColor(P.accent, 0.45)
  lg.rectangle("fill", x + 1, y + 58, (340 - 2) * prog, 2)

  if self.testLine then
    UI.caption(self.testLine, x, h - 26, 10, P.inkFaint, "left", 0.7)
  end
  lg.setColor(1, 1, 1, 1)
end

return D
