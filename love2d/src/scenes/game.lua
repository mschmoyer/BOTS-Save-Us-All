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

local Game = {}

function Game:enter(opts)
  opts = opts or {}
  local w, h = love.graphics.getDimensions()
  self.camera = Camera.new(w, h)
  self.world = World.new(opts.seed or math.random(1, 999999), opts)
  self.world.camera = self.camera
  self.world.post = Post
  self.camera:setBounds(0, 0, TU.world.w, TU.world.h)
  self.camera:snapTo(self.world.player.x, self.world.player.y)

  if Post.init then Post.init(w, h) end
  if Lighting.init then Lighting.init(w, h) end
  if HUD.init then HUD.init(self.world) end
  Minimap.build(self.world)
  if BuildMenu.init then BuildMenu.init(self.world) end

  self.buildSel = 1
  self.showPerf = false

  if (os.getenv("BOTS_AUTOPLAY") or "") ~= "" then
    self.world.player.agent = require("src.game.autoplay").new(self.world)
    self.showPerf = true
    J.enabled = false
  end
  self.speed = tonumber(os.getenv("BOTS_SPEED") or "") or 1
  self.telemetryT = 0

  Touch.setAimContext(function()
    local p = self.world.player
    return p.x, p.y
  end, self.world.enemies)
  Touch.setCobaltSource(function() return self.world.cobalt end)

  -- Dev jump: start a session near a late beat so the finale can be iterated on
  -- without playing thirteen minutes of it first.
  local jump = os.getenv("BOTS_JUMP")
  if jump and jump ~= "" then self:devJump(jump) end

  DayNight.set("day", 0)
  Music.setState("day")
  if Story.begin then Story.begin(self.world, "prologue") end

  self:bindSignals()
end

--- Populate the world as if a run had already been played.
function Game:devJump(what)
  local _ = what
  local w = self.world
  local rng = w.rng
  -- the extraction only makes sense with a full sky behind it
  local defaultTrees = (what == "extraction") and 900 or 260
  local trees = tonumber(os.getenv("BOTS_JUMP_TREES") or "") or defaultTrees
  local bots = tonumber(os.getenv("BOTS_JUMP_BOTS") or "") or 34
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
  Signal.on("world:failed", function()
    Timer.global:after(1.6, function()
      Screen.transition(0.9, function()
        Screen.switch(require("src.scenes.defeat"), self.world)
      end)
    end)
  end, self)
  Signal.on("boss:died", function()
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
  local world = self.world
  dt = dt * (self.speed or 1)

  if Input.pressed("pause") and not Screen.busy() then
    Screen.push(require("src.scenes.pause"), self)
    return
  end

  for i = 1, #TU.bots.order do
    if Input.pressed("build" .. i) then self:build(TU.bots.order[i]) end
  end
  if Input.pressed("commit") then world:holdDawn() end
  if BuildMenu.update then BuildMenu.update(dt, self.camera) end
  Minimap.update(realDt)

  world:update(dt)

  local p = world.player
  self.camera:follow(p.x, p.y, p.vx, p.vy, realDt)
  self.camera.zoomTarget = TU.camera.zoom * (world.phase == "extraction" and 0.94 or 1)

  if self.world.player.agent then
    -- headless autoplay has nobody to press a key, so cutscenes are skipped
    if Dialogue.isActive and Dialogue.isActive() then Dialogue.abort() end
    self.world.cutscene = false
    self:telemetry(dt)
  end

  DayNight.update(realDt)
  self:syncDayNight()
  if Story.update then Story.update(dt) end
  if Dialogue.update then Dialogue.update(dt, realDt) end
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
    print("TRACE,t,cycle,phase,pt,pd,trees,mature,elders,bots,blight,o2,cobalt,nodes,cut,planted,lost,botsLost")
  end
  local nodes = 0
  for i = 1, #w.cobalts do if w.cobalts[i].node then nodes = nodes + 1 end end
  print(string.format("TRACE,%.0f,%d,%s,%.0f,%.0f,%d,%d,%d,%d,%d,%.2f,%d,%d,%s,%d,%d,%d",
    w.time, w.cycle, w.phase, w.phaseT, w.phaseDur, w.treeCount, w.matureTrees or 0,
    w.elderTrees or 0, w:botCount(), #w.enemies, w.o2, w.cobalt, nodes,
    tostring(w.cutscene), w.stats.planted, w.stats.lost, w.stats.botsLost))
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
  DayNight.o2Influence(w.o2 / TU.o2.target)
end

function Game:build(botType)
  local w = self.world
  local p = w.player
  if not p or p.state ~= "alive" or w.cutscene then return end
  w:spawnBot(p.x + p.faceX * 30, p.y + p.faceY * 30, botType)
end

-------------------------------------------------------------------------- draw
function Game:draw()
  local world = self.world
  local cam = self.camera

  if Post.setGrade then
    Post.setGrade(DayNight.skyTint, DayNight.exposure, DayNight.contrast,
                  DayNight.saturation, DayNight.lift)
    Post.setBloom(DayNight.bloom)
    Post.setFog(DayNight.fogColor, DayNight.fogStrength)
  end

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

  if Post.endScene then Post.endScene() end
  if Post.render then Post.render() end
  require("src.world.weather").drawOverlay()

  if HUD.draw then HUD.draw(world, cam) end
  if BuildMenu.draw then BuildMenu.draw(cam) end
  Minimap.draw(world, cam)
  if Story.draw then Story.draw() end
  if Dialogue.draw then Dialogue.draw() end
  if Touch.active then Touch.draw() end

  if self.showPerf then self:drawPerf() end
end

function Game:drawPerf()
  local w = self.world
  local lines = string.format(
    "fps %d  ms %.1f\ntrees %d  bots %d  blight %d\nparticles %d\nphase %s %.0f/%.0f  cycle %d\nO2 %.1f%%  cobalt %d",
    love.timer.getFPS(), love.timer.getAverageDelta() * 1000,
    w.treeCount, #w.bots, #w.enemies, (VFX.count and VFX.count()) or 0,
    w.phase, w.phaseT, w.phaseDur, w.cycle, w.o2, w.cobalt)
  love.graphics.setColor(0, 0, 0, 0.5)
  love.graphics.rectangle("fill", 8, 8, 260, 92)
  love.graphics.setColor(1, 1, 1, 0.9)
  love.graphics.print(lines, 14, 12)
  love.graphics.setColor(1, 1, 1, 1)
end

function Game:keypressed(k)
  if k == "f3" then self.showPerf = not self.showPerf end
  if k == "f5" then
    Screen.transition(0.4, function() Screen.switch(require("src.scenes.game")) end)
  end
end

return Game
