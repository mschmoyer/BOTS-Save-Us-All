-- The game scene: owns the camera, the render pipeline and the phase flow.
local U        = require("src.core.util")
local Signal   = require("src.core.signal")
local Timer    = require("src.core.timer")
local P        = require("src.engine.palette")
local J        = require("src.engine.juice")
local Input    = require("src.engine.input")
local Camera   = require("src.engine.camera")
local Screen   = require("src.engine.screen")
local Opt      = require("src.core.optional")
local TU       = require("src.game.tuning")
local World    = require("src.world.world")

local Draw     = Opt.require("src.engine.draw")
local Text     = Opt.require("src.engine.text")
local VFX      = Opt.require("src.engine.vfx")
local Audio    = Opt.require("src.engine.audio")
local Music    = Opt.require("src.engine.music")
local DayNight = Opt.require("src.engine.daynight")
local Lighting = Opt.require("src.engine.lighting")
local Post     = Opt.require("src.engine.postfx")
local HUD      = Opt.require("src.game.hud")
local BuildMenu = Opt.require("src.game.buildmenu")
local Story    = Opt.require("src.game.story")
local Minimap  = require("src.game.minimap")
local Dialogue = Opt.require("src.game.dialogue")
local Touch    = require("src.engine.touch")
local Settings = require("src.game.settings")
local Warmup   = require("src.game.warmup")
local Save     = require("src.game.save")

--- Config comes from the environment natively and from --flag=value arguments
--- in the browser build, where there is no environment.
local cfg = _G.BOTS_CFG or function(n)
  local v = os.getenv(n)
  return (v ~= nil and v ~= "") and v or nil
end

local Game = {}

--- `enter` must return in a frame. Everything expensive happens in `build`,
--- which is a coroutine the loading screen pumps -- see src/game/warmup.lua for
--- why this is not optional.
function Game:enter(opts)
  opts = opts or {}
  local w, h = love.graphics.getDimensions()
  self.camera = Camera.new(w, h)
  -- A continued run has to warm the island it was saved on, so the seed comes
  -- off the save before anything else gets a say.
  -- BOTS_CONTINUE=1 resumes the saved run headlessly, which is the only way to
  -- exercise the round trip without a menu.
  self.saved = (opts.continueRun or cfg("BOTS_CONTINUE")) and Save.read() or nil
  self.seed = (self.saved and self.saved.seed)
           or opts.seed or tonumber(cfg("BOTS_SEED") or "") or math.random(1, 999999)
  self.load = { p = 0, label = Warmup.label(), t = 0, fade = 0 }
  Warmup.start(self.seed)
  self.builder = coroutine.wrap(function() self:buildRun(opts) end)

  -- Headless captures and the balance traces want the world to exist the
  -- instant the scene does: a loading screen that eats forty frames moves
  -- every timestamped row in the CSV.
  if cfg("BOTS_AUTOPLAY") or cfg("BOTS_SYNCLOAD") then
    while self.builder do
      if self.builder() == nil then self.builder = nil end
    end
    self.load = nil
  end
end

function Game:buildRun(opts)
  local w, h = love.graphics.getDimensions()
  local step = function(p, label) coroutine.yield(p, label) end

  local clock = love.timer.getTime()
  local t0, marks = clock, {}
  local lap = function(n) marks[#marks + 1] = string.format("%s=%.0f", n,
    (love.timer.getTime() - clock) * 1000); clock = love.timer.getTime() end

  -- most of the wait; the island's fields are usually already ground down by
  -- the title screen, and what is left is coarse GPU work
  while Warmup.pump(0.10) < 1 do step(Warmup.p * 0.82, Warmup.label()) end
  lap("warm[" .. Warmup.report() .. "]")
  step(0.82, "raising the island")

  local wopts = { terrain = Warmup.claim(self.seed), noPrewarm = true,
                  restore = self.saved }
  for k, v in pairs(opts) do if wopts[k] == nil then wopts[k] = v end end
  self.world = World.new(self.seed, wopts)
  lap("world")
  self.world.camera = self.camera
  self.world.post = Post
  self:setCameraBounds()
  self.camera:snapTo(self.world.player.x, self.world.player.y)
  step(0.90, "waking the crew")

  if Post.init then Post.init(w, h) end
  Warmup.mark("post")
  if Lighting.init then Lighting.init(w, h) end
  Warmup.mark("light")
  step(0.94, "lighting the sky")
  if HUD.init then HUD.init(self.world) end
  Warmup.mark("hud")
  Minimap.build(self.world)
  Warmup.mark("minimap")
  if BuildMenu.init then BuildMenu.init(self.world) end
  step(0.97, "checking the manifest")

  self.buildSel = 1
  self.showPerf = cfg("BOTS_PERF") ~= nil

    if cfg("BOTS_AUTOPLAY") then
    self.world.player.agent = require("src.game.autoplay").new(self.world)
    J.enabled = false
    self.storyCapture = cfg("BOTS_STORY") ~= nil
  end
  self.speed = tonumber(cfg("BOTS_SPEED") or "") or 1
  self.telemetryT = 0

  Touch.setAimContext(function()
    local p = self.world.player
    return p.x, p.y
  end, self.world.enemies)
  Touch.setCobaltSource(function() return self.world.cobalt end)

  -- Dev jump: start a session near a late beat so the finale can be iterated on
  -- without playing thirteen minutes of it first.
  -- BOTS_TUNE=tree.frontierMax=7;cycle.budgetPerTree=0.31 -- override numeric
  -- tuning for one headless run. Balance work on this game means running the
  -- same seed a dozen times with one number moved; editing tuning.lua between
  -- runs loses the comparison and risks leaving the edit in.
  local tune = cfg("BOTS_TUNE")
  if tune and tune ~= "" then
    for pair in string.gmatch(tune, "[^;,]+") do
      local path, val = string.match(pair, "^%s*([%w_.]+)%s*=%s*([-%d.]+)%s*$")
      if path and val then
        local node = TU
        local last
        for key in string.gmatch(path, "[^.]+") do
          if last then node = node[last] end
          last = key
        end
        if node and last and node[last] ~= nil then
          node[last] = tonumber(val)
          print(string.format("TUNE,%s,%s", path, val))
        end
      end
    end
  end

  -- BOTS_CHIPS=brittle,pinBreaker: hand the run a specific loadout, so a chip
  -- interaction can be reproduced instead of drafted for.
  local chips = cfg("BOTS_CHIPS")
  if chips and chips ~= "" then
    for id in string.gmatch(chips, "[^,]+") do self.world.chips:add(id) end
  end
  local jump = cfg("BOTS_JUMP")
  if jump and jump ~= "" then self:devJump(jump) end

  DayNight.set("day", 0)
  -- Prime the oxygen grade before the first frame is drawn. syncDayNight runs
  -- in update(), which is one frame later than the first draw on some paths,
  -- and one frame of a restored world in front of a 0% meter is a flash.
  self:syncDayNight()
  Music.setState("day")
  Warmup.mark("music")
  -- The director always takes over the world -- a resumed run only skips the
  -- opening beat (nil rather than "prologue"): you have met the mechanic
  -- already, and you met her before you closed the tab. Gating the whole call
  -- on a new run left Story.world nil for the rest of a continued run, which
  -- silently deleted every beat, every hint, every reaction and every epitaph
  -- the memorial was going to read.
  if Story.begin then
    Story.begin(self.world, (not self.saved) and "prologue" or nil)
    if self.saved then
      local r = Save.restoreStory(self.saved, self.world)
      print(string.format("RESUME|cycle=%d beats=%d epitaphs=%d hints=%d fallen=%d",
                          self.world.cycle, r.beats, r.epitaphs, r.hints,
                          #(self.world.allLostNames or {})))
    end
  end

  self:bindSignals()
  Warmup.mark("story")
  lap("scene")
  print(string.format("LOAD|%s|%s|total=%.0f", table.concat(marks, " "),
                      Warmup.marksReport(), (love.timer.getTime() - t0) * 1000))
  step(1.0, "ready")
end

--- Fence the camera in around the island rather than around the world.
---
--- The world rectangle is 3400x2400 and the island inside it is a good deal
--- smaller, so a player at the shore used to get 45-55% of the screen filled
--- with flat, empty ocean. The terrain knows where the land actually is; pad
--- that box by `landPad` so a beach still reads as a beach -- wet sand, surf,
--- a band of sea -- and clamp the result to the world so the view never leaves
--- the baked terrain either. Camera:clampToBounds centres on the box by itself
--- when the box is narrower than the viewport, which small islands are.
function Game:setCameraBounds()
  local t = self.world and self.world.terrain
  local x, y, w, h = 0, 0, TU.world.w, TU.world.h
  if t and t.landBounds then x, y, w, h = t:landBounds() end
  local pad = TU.camera.landPad
  local x0 = U.clamp(x - pad, 0, TU.world.w)
  local y0 = U.clamp(y - pad, 0, TU.world.h)
  local x1 = U.clamp(x + w + pad, x0, TU.world.w)
  local y1 = U.clamp(y + h + pad, y0, TU.world.h)
  self.camera:setBounds(x0, y0, x1 - x0, y1 - y0)
end

--- Populate the world as if a run had already been played.
function Game:devJump(what)
  local _ = what
  local w = self.world
  local rng = w.rng
  -- the extraction only makes sense with a full sky behind it
  local defaultTrees = (what == "extraction") and 900 or 260
  local trees = tonumber(cfg("BOTS_JUMP_TREES") or "") or defaultTrees
  local bots = tonumber(cfg("BOTS_JUMP_BOTS") or "") or 34
  for _ = 1, trees * 6 do
    if w.treeCount >= trees then break end
    if w.terrain then
      local x, y = w.terrain:randomLandPoint(rng, {})
      if x then w:plantTree(x, y, "dev") end
    end
  end
  for i = 1, #w.trees do
    local t = w.trees[i]
    t.growth = 1
    if t.refreshMesh then t:refreshMesh() end
    if t.refreshStage then t:refreshStage(true) end
  end
  for i = 1, bots do
    local x, y = w.homeX + rng:range(-320, 320), w.homeY + rng:range(-320, 320)
    w:spawnBot(x, y, TU.bots.order[(i % #TU.bots.order) + 1], true)
  end
  for i = 1, #w.bots do
    local b = w.bots[i]
    if b.state == "boot" then b.bootT = 0 b.state = "work" b.stateT = 0 end
  end
  w.cobalt = 120
  -- the meter is normally full when the rig arrives; the jump has to match or
  -- the extraction clock starts already expired
  w.o2 = 100
  w.o2Step = 4
  if what == "extraction" then
    w.cycle = 5
    w:beginExtraction()
  elseif what == "night" then
    w:setPhase("night")
  end
end

function Game:bindSignals()
  Signal.clearOwner(self)
  -- Autosave, at the only moment the world is quiet enough to mean it. Not
  -- during a headless capture: a balance trace has no business writing a run.
  Signal.on("run:checkpoint", function(world)
    if world.player and world.player.agent and not cfg("BOTS_SAVE") then return end
    local ok = Save.write(world)
    print(string.format("CHECKPOINT|cycle=%d trees=%d bots=%d ok=%s",
                        world.cycle, world.treeCount, #world.bots, tostring(ok)))
  end, self)
  -- The score listens for the finale itself: the rig landing, each cohort
  -- leaving, the two phase breaks and the fall. It is inert until this is
  -- called, and it owns its own bindings.
  if Music.bindSignals then Music.bindSignals() end
  Signal.on("phase:dawn", function(cycle, report)
    if self.world.player.agent then
      -- headless autoplay: take a chip and carry on, so captures reach cycle 5
      Timer.global:after(0.6, function()
        local offers = self.world.chips:draft(self.world.rng, 3, self.world.cycle)
        if offers[1] then self.world.chips:add(offers[1]) end
        self.world:setPhase("day")
      end)
      return
    end
    -- the draft sits on top of the world, which keeps breathing behind it
    Timer.global:after(1.1, function()
      Screen.push(require("src.scenes.draft"), self.world, report)
    end)
  end, self)
  -- The standing order has no tutorial step of its own; it is introduced the
  -- first time the player owns something that could take an order.
  Signal.on("bot:built", function(b)
    if self.rallyTold or not b or b.type ~= "planter" then return end
    self.rallyTold = true
    -- wait for a quiet moment: an order the player cannot give yet, delivered
    -- over the prologue, is just noise
    local function tell()
      local ph = self.world.phase
      -- ...and never during the finale. Once the rig is down there is nowhere
      -- to send anybody, and this is the one screen in the game with no room
      -- left on it: the boss's name and health own the bottom band.
      if ph == "extraction" or ph == "ending" then return end
      if self.world.cutscene then Timer.global:after(1.5, tell) return end
      if HUD.toast then
        HUD.toast(Input.glyph("rally") .. "   SEND THEM SOMEWHERE",
                  nil, "plant a flag; they will work toward it", 7)
      end
    end
    Timer.global:after(4.0, tell)
  end, self)

  -- A run that is over is not a run to come back to. Both endings clear the
  -- checkpoint, so CONTINUE never offers an island that has already fallen or
  -- already been saved.
  Signal.on("world:failed", function()
    Save.clear()
    Timer.global:after(1.6, function()
      Screen.transition(0.9, function()
        Screen.switch(require("src.scenes.defeat"), self.world)
      end)
    end)
  end, self)
  Signal.on("boss:died", function()
    Save.clear()
    Timer.global:after(1.4, function()
      Screen.transition(0.9, function()
        Screen.switch(require("src.scenes.ending"), self.world)
      end)
    end)
  end, self)
end

function Game:leave() Signal.clearOwner(self) end

function Game:resize(w, h)
  self.camera:resize(w, h)
  if Post.resize then Post.resize(w, h) end
  if Lighting.resize then Lighting.resize(w, h) end
end

------------------------------------------------------------------------ update
function Game:update(dt, realDt)
  if self.builder then return self:updateLoading(realDt or dt) end
  local world = self.world
  dt = dt * (self.speed or 1)

  if self.load and self.load.fade > 0 then
    self.load.fade = self.load.fade - (realDt or dt) * 2.2
    if self.load.fade <= 0 then self.load = nil end
  end


  if Input.pressed("pause") and not Screen.busy() then
    Screen.push(require("src.scenes.pause"), self)
    return
  end

  for i = 1, #TU.bots.order do
    if Input.pressed("build" .. i) then self:build(TU.bots.order[i]) end
  end
  if Input.pressed("commit") then world:holdDawn() end
  local agent = world.player and world.player.agent
  if agent and world.player.autoAct and world.player.autoAct.rally then
    world.player.autoAct.rally = false
    world:setRally(agent.rallyX or world.player.x, agent.rallyY or world.player.y)
  elseif Input.pressed("rally") then
    self:placeRally()
  end
  if BuildMenu.update then BuildMenu.update(dt, self.camera) end
  Minimap.update(realDt)

  -- Hold the simulation while somebody is talking. The dialogue is not
  -- skippable on its first read and the world used to run underneath it, so a
  -- cutscene was a window in which the Blight ate your crew while you read.
  -- Only the simulation stops: weather, particles and the camera carry on
  -- inside World:update, so it reads as a held breath rather than a hang.
  -- Dialogue.isActive only, deliberately: `world.cutscene` is set from five
  -- places and cleared from seven, and it used to gate nothing heavier than
  -- the phase clock. Hanging the whole simulation on it means one missed clear
  -- is a game frozen forever, which is a worse bug than the one being fixed.
  -- The dialogue system owns its own flag and clears it on the way out.
  local talking = Dialogue.isActive and Dialogue.isActive()
  world:update(talking and 0 or dt, realDt or dt)

  local p = world.player
  self.camera:follow(p.x, p.y, p.vx, p.vy, realDt)
  self.camera.zoomTarget = TU.camera.zoom * (world.phase == "extraction" and 0.94 or 1)

  if self.world.player.agent then
    -- Headless autoplay has nobody to press a key. By default cutscenes are
    -- skipped so balance traces are not blocked; BOTS_STORY=1 instead advances
    -- them on a beat, which is how the cutscenes get captured in context.
    if Dialogue.isActive and Dialogue.isActive() then
      if self.storyCapture then
        self.advanceT = (self.advanceT or 0) - realDt
        if self.advanceT <= 0 then self.advanceT = 1.6 Dialogue.advance() end
      else
        Dialogue.abort()
        self.world.cutscene = false
      end
    elseif not self.storyCapture then
      self.world.cutscene = false
    end
    self:telemetry(dt)
  end

  DayNight.update(realDt)
  self:syncDayNight()
  if Story.update then Story.update(dt) end
  if Dialogue.update then Dialogue.update(dt, realDt) end
  -- and hand the camera back when nobody is staging it. Dialogue pans by
  -- setting camera.offX/offY and had no one calling its release, so every
  -- cutscene left its pan behind: the camera went on following the player
  -- perfectly, several hundred units off to one side, for the rest of the run.
  if not (Dialogue.isActive and Dialogue.isActive()) then
    Dialogue.releaseCamera(self.camera, realDt)
  end
  if HUD.update then HUD.update(dt, world) end
  if Audio.update then Audio.update(realDt, p.x, p.y) end
  if Music.update then Music.update(realDt) end
end

--- Autoplay only: a CSV trace of the run, so balance can be read from data
--- instead of guessed from screenshots.
function Game:telemetry(dt)
  self.telemetryT = self.telemetryT - dt
  if self.telemetryT > 0 then return end
  self.telemetryT = 5
  local w = self.world
  if not self.telemetryHeader then
    self.telemetryHeader = true
    print(string.format("FOREST,fullForest=%.0f,landArea=%.0f",
      w.fullForest or 0, (w.terrain and w.terrain.landArea) or 0))
    print("TRACE,t,cycle,phase,pt,pd,trees,mature,elders,bots,blight,o2,cobalt,nodes,boss,planted,lost,botsLost,points")
  end
  local nodes = 0
  for i = 1, #w.cobalts do if w.cobalts[i].node then nodes = nodes + 1 end end
  print(string.format("TRACE,%.0f,%d,%s,%.0f,%.0f,%d,%d,%d,%d,%d,%.2f,%d,%d,%s,%d,%d,%d",
    w.time, w.cycle, w.phase, w.phaseT, w.phaseDur, w.treeCount, w.matureTrees or 0,
    w.elderTrees or 0, w:botCount(), #w.enemies, w.o2, w.cobalt, nodes,
    w.boss and string.format("%d/%d p%d L%d/%d h%d d%d r%d/%s", w.boss.hp, w.boss.maxHp,
      w.boss.phase, w.boss.rebelLanded or 0, w.rebelCrew or 0,
      w.boss.playerHits or 0, w.boss.playerDamage or 0,
      (function() local n = 0 for i = 1, #w.bots do
         if w.bots[i].state == "rebel" then n = n + 1 end end return n end)(),
      tostring(w.botsRebelled)) or "-",
    w.stats.planted, w.stats.lost, w.stats.botsLost) .. "," ..
    string.format("%.0f", w.forestPoints or 0))

end

--- Map the world's phase clock onto the visual day/night cycle.
function Game:syncDayNight()
  local w = self.world
  local p = U.saturate(w.phaseDur > 0 and w.phaseT / w.phaseDur or 0)
  if w.phase == "extraction" or w.phase == "ending" then
    DayNight.set("night", 0.5)
  else
    DayNight.set(w.phase, p)
  end
  -- o2Influence takes a *percentage*, and this used to hand it the 0..1
  -- fraction -- so the whole oxygen grade ran at DN.o2 <= 0.01 for the entire
  -- campaign and the sky never cleaned up at all. It went unnoticed because
  -- the ramp it drove was only a few percent wide at either end; it is not any
  -- more, so the units matter now.
  DayNight.o2Influence(100 * w.o2 / TU.o2.target)
end

--- Plant the standing order. Mouse players place it where they are pointing;
--- everyone else plants it where they stand, which is also where they had to
--- walk to - the flag is a decision about where you are willing to be.
function Game:placeRally()
  local w = self.world
  local p = w.player
  if not p or w.cutscene then return end
  local x, y = p.x, p.y
  if Input.scheme == "kb" then
    local mx, my = love.mouse.getPosition()
    local wx, wy = self.camera:toWorld(mx, my)
    if U.dist(wx, wy, p.x, p.y) < 1400 then x, y = wx, wy end
  end
  if w.rallyX and U.dist(x, y, w.rallyX, w.rallyY) < 60 then
    w:clearRally()
  else
    w:setRally(x, y)
  end
end

function Game:build(botType)
  local w = self.world
  local p = w.player
  if not p or p.state ~= "alive" or w.cutscene then return end
  w:spawnBot(p.x + p.faceX * 30, p.y + p.faceY * 30, botType)
end

-------------------------------------------------------------------------- draw
function Game:draw()
  if self.builder then return self:drawLoading() end
  local world = self.world
  local cam = self.camera

  -- one call so no part of the grade (split-tone in particular) can be forgotten
  if DayNight.apply then DayNight.apply(Post, Lighting) end

  if Post.beginScene then Post.beginScene() end

  love.graphics.clear(P.ramp.water[1])
  cam:attach()
  world:draw(cam)
  cam:detach()

  if Lighting.beginFrame then
    Lighting.beginFrame(cam)
    Lighting.setAmbient(DayNight.ambient, DayNight.ambientStrength)
    Lighting.addSunShadowParams(DayNight.sunAngle, DayNight.sunLength)
    Lighting.setLightGain(DayNight.lightGain)
    world:emitLights(Lighting)
    Lighting.finish()
  end

  -- Weather sits inside the scene so the grade applies to it; drawn over the
  -- finished frame it was a flat black rectangle that bypassed the whole chain.
  require("src.world.weather").drawOverlay()

  if Post.endScene then Post.endScene() end
  if Post.render then Post.render() end

  -- Everything from here down is screen chrome, and all of it leaves together:
  -- a cutscene closes the letterbox over the top, and readouts sliced in half
  -- by a cinematic bar are the loudest possible way to say "this is a game".
  local chrome = (HUD.chromeAlpha and HUD.chromeAlpha()) or 1
  if self.photoHide and self.photoHide > 0 then
    self.photoHide = self.photoHide - 1
  else
    if HUD.draw then HUD.draw(world, cam) end
    if BuildMenu.draw then BuildMenu.draw(cam, chrome) end
  end
  Minimap.draw(world, cam, chrome)
  if Story.draw then Story.draw() end
  if Dialogue.draw then Dialogue.draw() end
  if Touch.active then Touch.draw() end

  if self.showPerf then self:drawPerf() end
  if os.getenv("BOTS_DRAWCALLS") then
    local st = love.graphics.getStats()
    _G.__dcN = (_G.__dcN or 0) + 1
    _G.__dcSum = (_G.__dcSum or 0) + st.drawcalls
    if _G.__dcN % 60 == 0 then
      print(string.format("DRAWCALLS|avg=%.0f last=%d", _G.__dcSum / _G.__dcN, st.drawcalls))
    end
  end
  if self.load and self.load.fade > 0 then
    self:drawLoading(U.ease.inQuad(self.load.fade))
  end
end

------------------------------------------------------------------- the loading
--- Pump the build. The budget is generous on purpose: the bar is the only
--- thing on screen, so almost the whole frame can go to work, and a browser
--- that spends twenty seconds here should spend as few of them as possible.
--- The 26 ms floor still leaves the sweep and the counter moving.
function Game:updateLoading(dt)
  local L = self.load
  L.t = L.t + dt
  local t0 = love.timer.getTime()
  repeat
    local p, label = self.builder()
    if p == nil then
      self.builder = nil
      L.p, L.fade = 1, 1
      return
    end
    if p > L.p then L.p = p end
    L.label = label or L.label
  until love.timer.getTime() - t0 >= 0.026
end

--- The island, drawn as the survey it is: a scan sweeping a contour band while
--- the fields it is reading are actually being computed underneath.
function Game:drawLoading(alpha)
  alpha = alpha or 1
  local lg = love.graphics
  local w, h = lg.getDimensions()
  local L = self.load or { p = 0, t = 0, label = "" }
  local cx, cy = w * 0.5, h * 0.5

  local deep, near = P.ramp.water[1], P.black
  lg.clear(near[1], near[2], near[3], 1)
  local mesh = self._loadBG
  if not mesh then
    mesh = lg.newMesh({
      { 0, 0, 0, 0, deep[1], deep[2], deep[3], 1 },
      { 1, 0, 1, 0, deep[1], deep[2], deep[3], 1 },
      { 1, 1, 1, 1, near[1], near[2], near[3], 1 },
      { 0, 1, 0, 1, near[1], near[2], near[3], 1 },
    }, "fan", "static")
    self._loadBG = mesh
  end
  lg.setColor(1, 1, 1, alpha)
  lg.draw(mesh, 0, 0, 0, w, h)

  -- contour rings: a topographic read-out of a shape not yet resolved
  local R = math.min(w, h) * 0.28
  lg.setLineStyle("smooth")
  for i = 1, 7 do
    local f = i / 7
    local ring = R * (0.28 + f * 0.86)
    local wob = 1 + 0.05 * math.sin(L.t * 0.5 + i * 1.7)
    local band = U.saturate(1 - math.abs((L.t * 0.32 + f) % 1 - 0.5) * 3)
    local c = P.ramp.cobalt[2]
    lg.setLineWidth(1 + band * 1.4)
    lg.setColor(c[1], c[2], c[3], (0.10 + band * 0.30) * alpha)
    lg.circle("line", cx, cy - R * 0.06, ring * wob, 48)
  end

  -- the island resolving inside them, one arc per percent
  local seg = math.max(1, math.floor(L.p * 64))
  local acc = P.accent
  lg.setLineWidth(2)
  for i = 0, seg - 1 do
    local a0 = i / 64 * math.pi * 2 - math.pi * 0.5
    local rr = R * (0.62 + 0.16 * math.sin(a0 * 3 + self.seed % 17))
    lg.setColor(acc[1], acc[2], acc[3], 0.55 * alpha)
    lg.arc("line", "open", cx, cy - R * 0.06, rr, a0, a0 + math.pi * 2 / 72, 6)
  end

  -- the bar
  local bw = math.min(360, w * 0.46)
  local bx, by = cx - bw * 0.5, cy + R * 1.06
  local f = P.inkFaint
  lg.setColor(f[1], f[2], f[3], 0.22 * alpha)
  lg.rectangle("fill", bx, by, bw, 2)
  lg.setColor(acc[1], acc[2], acc[3], 0.92 * alpha)
  lg.rectangle("fill", bx, by, bw * L.p, 2)
  local sweep = (L.t * 0.55) % 1
  lg.setColor(P.white[1], P.white[2], P.white[3], 0.16 * alpha)
  lg.rectangle("fill", bx + bw * sweep - 30, by, 30, 2)

  if Text.display then
    Text.display("PREPARING THE ISLAND", cx, by - 46, 15,
      { align = "center", color = P.inkDim, tracking = 0.34, alpha = 0.85 * alpha })
    Text.display(string.format("%d%%", math.floor(L.p * 100)), cx, by + 16, 13,
      { align = "center", color = P.accent, tracking = 0.20, alpha = 0.75 * alpha })
  end
  if Text.body then
    Text.body(L.label or "", cx, by + 38, 13,
      { align = "center", color = P.inkFaint, alpha = 0.8 * alpha })
  end
  lg.setColor(1, 1, 1, 1)
end

--- Photo mode. Hides every overlay for one frame and writes a clean capture to
--- the save directory, because people will want to show this to someone.
function Game:photo()
  self.photoHide = 2
  local name = string.format("reforest_%s.png", tostring(math.floor(self.world.time * 10)))
  love.graphics.captureScreenshot(function(img)
    img:encode("png", name)
  end)
  if HUD.toast then HUD.toast("SAVED " .. name, nil, "photo mode") end
end

--- Developer readout. Deliberately not in the top-left: that is where the HUD
--- keeps the resource stack, and this used to sit on top of the cobalt figure in
--- every capture. Debug text is the one place raw love.graphics.print is allowed.
function Game:drawPerf()
  local w = self.world
  local sw, sh = love.graphics.getDimensions()
  local lines = string.format(
    "fps %d  ms %.1f\ntrees %d  bots %d  blight %d\nparticles %d\nphase %s %.0f/%.0f  cycle %d\nO2 %.1f%%  cobalt %d",
    love.timer.getFPS(), love.timer.getAverageDelta() * 1000,
    w.treeCount, #w.bots, #w.enemies, (VFX.count and VFX.count()) or 0,
    w.phase, w.phaseT, w.phaseDur, w.cycle, w.o2, w.cobalt)
  local x, y = sw * 0.5 - 130, 130
  love.graphics.setColor(P.black[1], P.black[2], P.black[3], 0.5)
  love.graphics.rectangle("fill", x, y, 260, 92, 4)
  love.graphics.setColor(P.ink[1], P.ink[2], P.ink[3], 0.85)
  love.graphics.print(lines, x + 6, y + 4)
  love.graphics.setColor(1, 1, 1, 1)
end

function Game:keypressed(k)
  if k == "f3" then self.showPerf = not self.showPerf end
  if k == "f2" then self:photo() end
  if k == "f5" then
    Screen.transition(0.4, function() Screen.switch(require("src.scenes.game")) end)
  end
end

return Game
