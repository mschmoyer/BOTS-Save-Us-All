-- BOTS: Save Us All - Reforest
-- Entry point, main loop, and the headless capture harness used for automated
-- visual review (see tools/shot.sh).

local U       = require("src.core.util")
local Signal  = require("src.core.signal")
local Timer   = require("src.core.timer")
local P       = require("src.engine.palette")
local Input   = require("src.engine.input")
local J       = require("src.engine.juice")
local Screen  = require("src.engine.screen")
local Settings = require("src.game.settings")
local Touch   = require("src.engine.touch")
local Audio   = require("src.engine.audio")
local Music   = require("src.engine.music")
local Post    = require("src.engine.postfx")

local Boot = {}

------------------------------------------------------------------ headless mode
-- Driven entirely by environment variables so tools/shot.sh can script it.
local H = {
  on      = (os.getenv("BOTS_HEADLESS") or "") ~= "",
  frames  = tonumber(os.getenv("BOTS_FRAMES") or "") or 420,
  shots   = {},
  script  = os.getenv("BOTS_SCRIPT"),
  frame   = 0,
  pending = 0,
}
do
  local s = os.getenv("BOTS_SHOTS")
  if s then for n in s:gmatch("%d+") do H.shots[tonumber(n)] = true end end
  if not next(H.shots) then H.shots[H.frames] = true end
end
Boot.headless = H

--- Push the saved options into the render modules. Called on boot and whenever
--- the options screen changes something.
function Boot.applyQuality()
  local ps = Post.settings
  if ps then
    ps.bloom    = Settings.get("fxBloom", true)
    ps.grain    = Settings.get("fxGrain", true)
    ps.ca       = Settings.get("fxAberration", true)
    ps.vignette = Settings.get("fxVignette", true)
    ps.distort  = Settings.get("fxDistortion", true)
  end
  local q = Settings.get("quality", "high")
  local level = (q == "low" and 0) or (q == "medium" and 1) or 2
  local ok, Lighting = pcall(require, "src.engine.lighting")
  if ok and Lighting.setQuality then Lighting.setQuality(level) end
  local okv, VFX = pcall(require, "src.engine.vfx")
  if okv and VFX.setQuality then VFX.setQuality(level) end
end

--------------------------------------------------------------------- love.load
function love.load()
  love.graphics.setDefaultFilter("linear", "linear", 4)
  love.graphics.setLineStyle("smooth")
  math.randomseed(H.on and 20190101 or os.time())
  math.random(); math.random()

  Settings.load()
  Settings.applyJuice(J)
  Settings.applyInput(Input)
  Boot.applyQuality()

  Input.load()
  Touch.load()

  -- every sound and every note in the game is synthesized here, once
  local t0 = love.timer.getTime()
  local okAudio, audioErr = xpcall(function()
    Audio.load()
    Music.load()
    Audio.setBusVolume("master", Settings.get("volMaster", 0.9))
    Audio.setBusVolume("sfx",    Settings.get("volSfx", 1.0))
    Audio.setBusVolume("music",  Settings.get("volMusic", 0.75))
    Audio.setBusVolume("ui",     Settings.get("volSfx", 1.0))
  end, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
  Boot.audioTime = love.timer.getTime() - t0
  if not okAudio then print("AUDIO FAILED: " .. tostring(audioErr)) end

  local ok, err = pcall(function()
    local sceneName = os.getenv("BOTS_SCENE")
    if sceneName == nil or sceneName == "" then sceneName = "src.scenes.title" end
    Screen.push(require(sceneName))
  end)
  if not ok then
    Boot.fatal = err
    print("BOOT ERROR: " .. tostring(err))
  end
end

------------------------------------------------------------------- love.update
function love.update(realDt)
  realDt = math.min(realDt, 1 / 30)
  local dt = J.update(realDt)
  Input.update(realDt)
  Touch.update(realDt)
  Post.update(realDt)
  Timer.global:update(realDt)
  Screen.update(dt, realDt)
end

--------------------------------------------------------------------- love.draw
function love.draw()
  if Boot.fatal then
    love.graphics.clear(P.black)
    love.graphics.setColor(P.danger)
    love.graphics.printf("BOOT ERROR\n\n" .. tostring(Boot.fatal), 40, 40,
                         love.graphics.getWidth() - 80)
    love.graphics.setColor(1, 1, 1)
    return
  end
  Screen.draw()

  if J.flash > 0.001 then
    local c = J.flashColor
    love.graphics.setColor(c[1], c[2], c[3], U.saturate(J.flash))
    love.graphics.rectangle("fill", 0, 0, love.graphics.getDimensions())
    love.graphics.setColor(1, 1, 1, 1)
  end
end

---------------------------------------------------------------- love callbacks
function love.resize(w, h) Screen.resize(w, h) end
function love.keypressed(k, sc, rep)
  if k == "f11" then
    love.window.setFullscreen(not love.window.getFullscreen())
    return
  end
  Screen.keypressed(k, sc, rep)
end
function love.keyreleased(k, sc) Screen.keyreleased(k, sc) end
function love.mousepressed(x, y, b, t) Screen.mousepressed(x, y, b, t) end
function love.mousereleased(x, y, b, t) Screen.mousereleased(x, y, b, t) end
function love.mousemoved(x, y, dx, dy) Screen.mousemoved(x, y, dx, dy) end
function love.wheelmoved(x, y) Screen.wheelmoved(x, y) end
function love.textinput(t) Screen.textinput(t) end
function love.touchpressed(id, x, y, dx, dy, p) Input.touchpressed() Screen.touchpressed(id, x, y, dx, dy, p) end
function love.touchreleased(id, x, y, dx, dy, p) Screen.touchreleased(id, x, y, dx, dy, p) end
function love.touchmoved(id, x, y, dx, dy, p) Screen.touchmoved(id, x, y, dx, dy, p) end
function love.joystickadded(js) Input.joystickadded(js) end
function love.joystickremoved(js) Input.joystickremoved(js) end
function love.gamepadpressed(js, b) Input.gamepadpressed(js, b) Screen.gamepadpressed(js, b) end

------------------------------------------------------------------- error screen
function love.errorhandler(msg)
  msg = tostring(msg)
  local trace = debug.traceback("", 2)
  print(msg) print(trace)
  if not love.window or not love.graphics or not love.event then return end
  if not love.graphics.isActive() and not love.graphics.getCanvas() then return end
  love.graphics.reset()
  love.graphics.setColor(1, 1, 1, 1)
  local function draw()
    love.graphics.clear(0.02, 0.03, 0.05)
    love.graphics.setColor(1, 0.33, 0.44)
    love.graphics.print("SOMETHING BROKE", 44, 40)
    love.graphics.setColor(0.9, 0.95, 0.94)
    love.graphics.printf(msg, 44, 78, love.graphics.getWidth() - 88)
    love.graphics.setColor(0.55, 0.66, 0.7)
    love.graphics.printf(trace, 44, 150, love.graphics.getWidth() - 88)
    love.graphics.present()
  end
  if H.on then draw() return 1 end
  return function()
    love.event.pump()
    for e, a in love.event.poll() do
      if e == "quit" then return 1 end
      if e == "keypressed" and a == "escape" then return 1 end
    end
    draw()
    love.timer.sleep(0.05)
  end
end

----------------------------------------------------------------------- love.run
function love.run()
  love.load()
  if love.timer then love.timer.step() end
  local dt = 0

  return function()
    if love.event then
      love.event.pump()
      for name, a, b, c, d, e, f in love.event.poll() do
        if name == "quit" then
          if not love.quit or not love.quit() then return a or 0 end
        end
        love.handlers[name](a, b, c, d, e, f)
      end
    end

    if H.on then
      dt = 1 / 60
      H.frame = H.frame + 1
    else
      if love.timer then dt = love.timer.step() end
    end

    love.update(dt)

    if love.graphics and love.graphics.isActive() then
      love.graphics.origin()
      love.graphics.clear(love.graphics.getBackgroundColor())
      love.draw()

      if H.on and H.shots[H.frame] then
        local n = H.frame
        H.pending = H.pending + 1
        love.graphics.captureScreenshot(function(img)
          img:encode("png", string.format("shot_%05d.png", n))
          H.pending = H.pending - 1
        end)
      end

      love.graphics.present()
    end

    if H.on and H.frame >= H.frames and H.pending <= 0 then return 0 end
    if not H.on and love.timer then love.timer.sleep(0.001) end
  end
end

return Boot
