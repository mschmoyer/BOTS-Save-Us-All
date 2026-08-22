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

--- Configuration comes from the environment natively, and from command-line
--- arguments in the browser build (where there is no environment). The web
--- shell forwards a `?dev=...` query string into `Module.arguments`.
local ARGV = {}
do
  local a = _G.arg
  if type(a) == "table" then
    for i = 1, #a do
      local k, v = tostring(a[i]):match("^%-%-([%w_]+)=(.*)$")
      if k then ARGV[k:upper()] = v end
    end
  end
end

local function cfg(name)
  local v = os.getenv(name)
  if v ~= nil and v ~= "" then return v end
  v = ARGV[name]
  if v ~= nil and v ~= "" then return v end
  return nil
end
_G.BOTS_CFG = cfg

------------------------------------------------------------------ headless mode
-- Driven entirely by environment variables so tools/shot.sh can script it.
local H = {
  on      = cfg("BOTS_HEADLESS") ~= nil,
  frames  = tonumber(cfg("BOTS_FRAMES") or "") or 420,
  shots   = {},
  script  = cfg("BOTS_SCRIPT"),
  frame   = 0,
  pending = 0,
}
do
  local s = cfg("BOTS_SHOTS")
  if s then for n in s:gmatch("%d+") do H.shots[tonumber(n)] = true end end
  if not next(H.shots) then H.shots[H.frames] = true end
  -- Software rendering costs over a second a frame, so a long capture only draws
  -- the frames it is about to photograph, plus a short run-up so anything that
  -- animates inside draw has settled.
  H.drawOn = {}
  for f in pairs(H.shots) do
    for k = math.max(1, f - 4), f do H.drawOn[k] = true end
  end
  H.drawAll = cfg("BOTS_DRAW_ALL") ~= nil
end
Boot.headless = H

--------------------------------------------------------------- boot budgets
-- THE SHAPE OF THE BOOT, and why it is two speeds.
--
-- Synthesizing the sound bank is ~2.7 s here and the better part of half a
-- minute in the browser's interpreter. It cannot all happen before the first
-- frame, and it cannot all happen quietly behind the game either -- a title
-- theme missing notes for its first ten seconds is the game's first impression.
--
-- So the boot has a BURST and then a STREAM.
--
--   BURST -- the web shell's panel is still over the canvas, so nothing on
--     screen is worth a frame. We draw one frame in BURST_DRAW (enough to warm
--     the shaders and have a picture ready behind the fade) and give the rest
--     to the bank. It ends when the *warm set* is built: the menu cues and the
--     five title instruments, ~0.39 s of the 2.7 s. BURST_MAX is a hard stop,
--     because a device slow enough to hit it is a device the player should be
--     looking at a game on regardless.
--
--   STREAM -- the rest of the bank, behind a running game, priced so it may
--     hold the frame at STREAM_TARGET and no worse. Whatever the frame already
--     cost comes off the budget first, so a busy night gets a trickle and an
--     idle title screen gets most of a frame. Anything not built when it is
--     asked for is silent and jumps the queue (see Audio.play).
local BURN        = tonumber(cfg("BOTS_AUDIO_BURN") or "") or 0.05
local BURST_MAX   = tonumber(cfg("BOTS_BURST_MAX") or "") or 12
local BURST_DRAW  = 6
local STREAM_TARGET = 1 / 30
local STREAM_MIN, STREAM_MAX = 0.002, 0.050
-- The headless harness builds the whole bank up front, so captures and balance
-- traces are reproducible and no cue can be missing from one. BOTS_AUDIO_STREAM
-- puts it on the streaming path anyway, which is how the streaming path itself
-- is tested without a human at a keyboard.
local STREAM = (cfg("BOTS_AUDIO_STREAM") ~= nil) or not H.on

-------------------------------------------------------------- boot reporting
-- The web build has a stretch before LOVE exists at all -- fetching and
-- compiling the runtime, unpacking the game data -- and the shell draws a real
-- boot panel over it. Everything after it used to happen inside one main-loop
-- tick with no way for the page to say so. These two calls are the game talking
-- back to the panel.
--
-- This comment used to claim that stretch was "thirteen seconds decoding a
-- base64 wasm blob". It was not. Decoding the blobs is ~150 ms; the thirteen
-- seconds was a render-blocking webfont stylesheet timing out, and it is fixed
-- in the shell. The hosted build now reaches its first frame in well under a
-- second of pre-LOVE time. See docs/PERFORMANCE_SPEC.md.
--
-- The channel is `print`. The shell already routes stdout through Module.print
-- (see tools/web_shell.html), it costs one string per update, it cannot fail,
-- and it needs no polling or window-title abuse. Lines are only emitted in the
-- page -- a native run and the headless harness stay silent.
local bootLog = false          -- set in love.load, once cfg() is available
local lastPct, lastLabel = -1, nil

--- Report boot progress. `frac` is 0..1 across everything that has to happen
--- before the game can draw; `label` is what the panel prints.
function Boot.stage(frac, label)
  if not bootLog then return end
  local pct = math.floor(U.saturate(frac) * 100 + 0.5)
  if pct == lastPct and label == lastLabel then return end
  lastPct, lastLabel = pct, label
  print(string.format("BOOT|%d|%s", pct, label or ""))
end

--- The game can draw. The panel fades from here.
function Boot.ready()
  if Boot.reported then return end
  Boot.reported = true
  if not bootLog then return end
  print("BOOT|100|first frame")
  print("BOOTREADY")
end

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
  -- BOTS_QUALITY forces a detail level for a capture: the render scale that
  -- comes with "low" is the only way to exercise the scene-canvas path
  -- headlessly, and it is not reachable from the options screen without a human.
  local q = cfg("BOTS_QUALITY") or Settings.get("quality", "high")
  local level = (q == "low" and 0) or (q == "medium" and 1) or 2
  local ok, Lighting = pcall(require, "src.engine.lighting")
  if ok and Lighting.setQuality then Lighting.setQuality(level) end
  local okv, VFX = pcall(require, "src.engine.vfx")
  if okv and VFX.setQuality then VFX.setQuality(level) end
  local okp, PostM = pcall(require, "src.engine.postfx")
  if okp and PostM.setScale then
    PostM.setScale(level == 0 and 0.7 or (level == 1 and 0.85 or 1))
  end
end

--- On a first run only, pick a detail level the machine can actually hold.
---
--- `highdpi` is on, so a retina display renders three or four times the
--- fragments a 1x one does -- and this game asks for twenty-odd screens of
--- blended canopy overdraw before it asks for anything else. A first-time
--- player on a 3x phone or a 5K monitor should not have to find the options
--- screen to discover why it is uneven. A saved choice is never overridden.
function Boot.autoQuality()
  if Settings.wasLoadedFromDisk and Settings.wasLoadedFromDisk() then return end
  if not (love.graphics and love.graphics.getPixelDimensions) then return end
  local pw, ph = love.graphics.getPixelDimensions()
  local mpix = (pw * ph) / 1000000
  if mpix >= 3.2 then Settings.set("quality", "low")
  elseif mpix >= 2.2 then Settings.set("quality", "medium") end
end

--------------------------------------------------------------------- love.load
function love.load()
  bootLog = (cfg("BOTS_WEB") ~= nil or cfg("BOTS_BOOTLOG") ~= nil) and not H.on
  -- Where the run and the preferences actually land. In the browser this has
  -- to sit inside the directory love.js mounts IndexedDB over, or every save
  -- is written to memory and thrown away on reload -- which is exactly what
  -- was happening. Printed because it is not guessable from here.
  if bootLog and love.filesystem.getSaveDirectory then
    print("SAVEDIR|" .. tostring(love.filesystem.getSaveDirectory()))
  end
  Boot.stage(0.02, "engine linked")
  love.graphics.setDefaultFilter("linear", "linear", 4)
  love.graphics.setLineStyle("smooth")
  math.randomseed(H.on and 20190101 or os.time())
  math.random(); math.random()

  Settings.load()
  Boot.autoQuality()
  Settings.applyJuice(J)
  Settings.applyInput(Input)
  Boot.applyQuality()

  Input.load()
  Touch.load()

  Boot.stage(0.06, "systems online")
  Input.load()
  Touch.load()
  Boot.stage(0.12, "input mapped")

  -- THE SOUND BANK. Every sound and every note in the game is synthesized, and
  -- it is by a long way the most expensive thing that happens before the first
  -- frame: ~3 s here, ~21 s in the browser's interpreter. It used to all happen
  -- on this line.
  --
  -- Now the bank is only *registered* here (a few milliseconds) and built in
  -- slices from love.run, cheapest-and-soonest first. The headless harness
  -- still builds the lot up front so captures and balance traces are
  -- reproducible and every cue is guaranteed present.
  local t0 = love.timer.getTime()
  local okAudio, audioErr = xpcall(function()
    if STREAM then Audio.prepare() else Audio.load() end
    Music.load()
    Audio.setBusVolume("master", Settings.get("volMaster", 0.9))
    Audio.setBusVolume("sfx",    Settings.get("volSfx", 1.0))
    Audio.setBusVolume("music",  Settings.get("volMusic", 0.75))
    Audio.setBusVolume("ui",     Settings.get("volUi", 0.85))
  end, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
  Boot.audioTime = love.timer.getTime() - t0
  if not okAudio then print("AUDIO FAILED: " .. tostring(audioErr)) end
  Boot.stage(0.22, "sound bank registered")

  -- A short, bounded head start so the menu cues and the title bed are usually
  -- there before anything can ask for them. Bounded is the point: this is the
  -- only synthesis left on the critical path, and it can never grow.
  if STREAM then
    Audio.stream(BURN)
    Boot.stage(0.30, "voices warming")
  end

  local ok, err = pcall(function()
    local sceneName = cfg("BOTS_SCENE")
    if sceneName == nil or sceneName == "" then sceneName = "src.scenes.title" end
    Screen.push(require(sceneName))
  end)
  if not ok then
    Boot.fatal = err
    print("BOOT ERROR: " .. tostring(err))
  end
  Boot.stage(0.36, "island awake")
  Boot.burstUntil = (love.timer and love.timer.getTime() or 0) + BURST_MAX
  Boot.bursting = STREAM and not Audio.warmDone()
end

--------------------------------------------------------------- audio streaming
--- Build the sound bank. Called from love.run after the frame has been
--- presented, so the picture never waits on it. Two speeds; see the note above
--- BURN for why.
function Boot.streamAudio(frameCost)
  if not STREAM or Boot.fatal or Audio.complete then return end
  if Boot.bursting then
    Audio.stream(0.25)
    if Audio.warmDone() or (love.timer and love.timer.getTime() or 0) > Boot.burstUntil then
      Boot.bursting = false
    else
      -- 36% is where love.load left the bar; the warm set carries it the rest
      -- of the way, and Boot.ready puts it on 100 when there is a picture.
      Boot.stage(0.36 + 0.60 * Audio.warmProgress(), "synthesizing voices")
    end
    return
  end
  local b = STREAM_TARGET - (frameCost or 0)
  if b < STREAM_MIN then b = STREAM_MIN elseif b > STREAM_MAX then b = STREAM_MAX end
  Audio.stream(b)
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

  -- The sound bank is still building behind the game. One hairline at the very
  -- bottom edge, in the boot panel's own accent, so a player who started before
  -- it finished can see that the machine is still warming up rather than
  -- wonder why something was quiet. It leaves the moment the queue drains.
  if not H.on and Audio.prepared and not Audio.complete then  -- boot hairline
    local w, h = love.graphics.getDimensions()
    local a, f = P.accent, P.inkFaint
    love.graphics.setColor(f[1], f[2], f[3], 0.16)
    love.graphics.rectangle("fill", 0, h - 2, w, 2)
    love.graphics.setColor(a[1], a[2], a[3], 0.45)
    love.graphics.rectangle("fill", 0, h - 2, w * Audio.streamProgress(), 2)
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
    local tFrame = love.timer and love.timer.getTime() or 0
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

    local wantDraw = (not H.on) or H.drawAll or H.drawOn[H.frame]
    -- Bursting: the boot panel is still over the canvas. Draw occasionally --
    -- enough to compile the shaders and have a picture ready behind the fade --
    -- and give the rest of the frame to the sound bank.
    if Boot.bursting then
      Boot.burstFrame = (Boot.burstFrame or 0) + 1
      wantDraw = wantDraw and (Boot.burstFrame % BURST_DRAW == 1)
    end
    if wantDraw and love.graphics and love.graphics.isActive() then
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
      -- The picture exists and the bank is warm. The web shell's boot panel is
      -- sitting on top of the canvas waiting for exactly this; it fades from
      -- here, over the title screen's own entrance.
      if not Boot.bursting then Boot.ready() end
      Boot.drew = true
    end

    if H.on and H.frame >= H.frames and H.pending <= 0 then return 0 end
    Boot.streamAudio(love.timer and (love.timer.getTime() - tFrame) or 0)
    -- The burst ended inside a frame that had already decided not to draw, so
    -- the panel is waiting on a picture that exists from the last burst frame.
    if Boot.drew and not Boot.bursting then Boot.ready() end
    if not H.on and love.timer then love.timer.sleep(0.001) end
  end
end

return Boot
