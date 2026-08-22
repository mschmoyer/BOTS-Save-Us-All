-- Device-agnostic action layer. Gameplay code asks for actions, never keys.
-- Auto-detects keyboard/mouse, gamepads (with DualSense glyph support) and touch,
-- and re-glyphs the UI live when the player switches device.
--
-- It also owns the rumble MIXER (see "feedback", below). Everything that fires
-- it lives in game/haptics.lua, which subscribes to the signal bus; the shapes
-- it fires live in game/tuning.lua. This file knows how to play a pattern and
-- nothing about which moment in the game deserves one.
local U = require("src.core.util")
local Signal = require("src.core.signal")
local TU = require("src.game.tuning")

local Input = {}

Input.scheme  = "kb"        -- "kb" | "pad" | "touch"
Input.brand   = "generic"   -- "ps" | "xbox" | "switch" | "generic"
Input.model   = nil         -- "dualsense" | "ds4" | "ds3" | "xbox360" | ...
Input.joystick = nil
Input.touchModule = nil     -- set by engine.touch when it loads
Input.rumbleEnabled = true  -- the player's consent (settings `rumble`)
Input.rumbleScale = 1       -- the player's intensity (settings `rumbleAmount`)
Input.rumbleSupported = nil -- what the device claims (isVibrationSupported)
Input.rumbleWorks = nil     -- what it actually did: nil = untested, false = no motors
Input.deadzone = 0.22

----------------------------------------------------------------------- bindings
-- Each action lists keyboard keys, mouse buttons and gamepad buttons.
local BIND = {
  dash    = { keys = { "space" },        pad = { "a" } },
  shove   = { keys = { "e" }, mouse = { 1 }, pad = { "x" } },
  pulse   = { keys = { "q" }, mouse = { 2 }, pad = { "rightshoulder" }, trigger = "triggerright" },
  plant   = { keys = { "f" },            pad = { "y" } },
  radial  = { keys = { "tab" },          pad = { "leftshoulder" } },
  confirm = { keys = { "return", "space", "kpenter" }, pad = { "a" } },
  back    = { keys = { "escape", "backspace" }, pad = { "b" } },
  pause   = { keys = { "escape", "p" },  pad = { "start" } },
  map     = { keys = { "m" },            pad = { "back" } },
  cycleL  = { keys = { "," },            pad = { "dpleft" } },
  cycleR  = { keys = { "." },            pad = { "dpright" } },
  commit  = { keys = { "r" },            pad = { "dpup" } },
  rally   = { keys = { "g" }, mouse = { 3 }, pad = { "dpdown" } },
  photo   = { keys = { "f2" } },
}
for i = 1, 6 do BIND["build" .. i] = { keys = { tostring(i) } } end

Input.bind = BIND

--------------------------------------------------------------------- glyph maps
local GLYPH = {
  ps     = { a = "X", b = "O", x = "[]", y = "/\\",
             leftshoulder = "L1", rightshoulder = "R1", triggerleft = "L2",
             triggerright = "R2", start = "OPTIONS", back = "CREATE",
             dpleft = "D-PAD L", dpright = "D-PAD R" },
  xbox   = { a = "A", b = "B", x = "X", y = "Y",
             leftshoulder = "LB", rightshoulder = "RB", triggerleft = "LT",
             triggerright = "RT", start = "MENU", back = "VIEW",
             dpleft = "D-PAD L", dpright = "D-PAD R" },
  switch = { a = "B", b = "A", x = "Y", y = "X",
             leftshoulder = "L", rightshoulder = "R", triggerleft = "ZL",
             triggerright = "ZR", start = "+", back = "-",
             dpleft = "D-PAD L", dpright = "D-PAD R" },
}
GLYPH.generic = GLYPH.xbox

-- The face buttons on a PlayStation pad are drawn symbols, and ROOTSTOCK is a
-- hand-vectored ASCII face with no U+00D7 in it -- so the multiplication sign
-- this table used to carry for Cross fell through engine/text.lua's missing-
-- glyph path and every DualSense player was told to press "?" to dash. "X" is
-- what the button is called and what is printed on it; the other three are
-- built out of characters the face actually has.
--
-- Per-model overrides on top of the brand: the share/create button is the only
-- control whose *label* differs across three generations of the same pad, and
-- naming it wrong is the exact failure this whole table exists to avoid.
local MODEL_GLYPH = {
  dualsense = { back = "CREATE", start = "OPTIONS" },
  ds4       = { back = "SHARE",  start = "OPTIONS" },
  ds3       = { back = "SELECT", start = "START" },
  xboxone   = { back = "VIEW",   start = "MENU" },
  xbox360   = { back = "BACK",   start = "START" },
}

-- USB vendor/product ids, which is the only identification that does not change
-- with the driver, the OS or the connection. SDL reports the same DualSense as
-- "Wireless Controller" over Bluetooth, "DualSense Wireless Controller" over
-- USB and "PS5 Controller" through some mapping databases.
local VENDOR = { [0x054c] = "ps", [0x045e] = "xbox", [0x057e] = "switch",
                 [0x28de] = "generic" }
local PRODUCT = {
  [0x054c] = { [0x0ce6] = "dualsense", [0x0df2] = "dualsense",   -- DualSense / Edge
               [0x05c4] = "ds4", [0x09cc] = "ds4", [0x0ba0] = "ds4",
               [0x0268] = "ds3" },
  [0x045e] = { [0x028e] = "xbox360", [0x028f] = "xbox360", [0x02a1] = "xbox360",
               [0x02d1] = "xboxone", [0x02dd] = "xboxone", [0x02ea] = "xboxone",
               [0x02e0] = "xboxone", [0x02fd] = "xboxone", [0x0b12] = "xboxone",
               [0x0b13] = "xboxone", [0x0b20] = "xboxone" },
}

local KEYNAME = {
  space = "SPACE", escape = "ESC", tab = "TAB", ["return"] = "ENTER",
  backspace = "BKSP", lshift = "SHIFT", kpenter = "ENTER",
}

----------------------------------------------------------------------- state
local state, prev = {}, {}
local function ensure(a) if state[a] == nil then state[a] = false prev[a] = false end end
for a in pairs(BIND) do ensure(a) end

Input.moveX, Input.moveY = 0, 0
Input.aimX, Input.aimY = 1, 0
Input.aimIsExplicit = false
Input.mouseX, Input.mouseY = 0, 0
Input.pulseCharge = 0


------------------------------------------------------------------ device detect
--- Vendor and product ids, preferring the numbers to the string.
--- `Joystick:getDeviceInfo` arrived in LOVE 11.3; the SDL GUID carries the same
--- two words at fixed offsets (little-endian, bytes 8..11 and 16..19) and is
--- the fallback for anything older or for a pad behind a mapping layer.
local function deviceIds(js)
  if js.getDeviceInfo then
    local ok, vid, pid = pcall(js.getDeviceInfo, js)
    if ok and type(vid) == "number" and vid ~= 0 then return vid, pid or 0 end
  end
  local gid = js.getGUID and js:getGUID() or nil
  if type(gid) == "string" and #gid >= 20 then
    local function word(i)
      local lo = tonumber(gid:sub(i, i + 1), 16)
      local hi = tonumber(gid:sub(i + 2, i + 3), 16)
      if not lo or not hi then return 0 end
      return hi * 256 + lo
    end
    return word(9), word(17)
  end
  return 0, 0
end

--- Returns brand ("ps"/"xbox"/"switch"/"generic") and model, or nil for a model
--- we have nothing specific to say about.
local function brandFor(js)
  local name = (js:getName() or ""):lower()
  local gid = (js:getGUID() or ""):lower()
  local vid, pid = deviceIds(js)
  local brand, model = VENDOR[vid], (PRODUCT[vid] or {})[pid]
  if brand and brand ~= "generic" then return brand, model end

  if name:find("dualsense") or name:find("ps5") then return "ps", "dualsense" end
  if name:find("dualshock 4") or name:find("dualshock4") or name:find("ps4") then return "ps", "ds4" end
  if name:find("dualshock") or name:find("playstation")
     or name:find("wireless controller") then return "ps", nil end
  if name:find("nintendo") or name:find("switch") or name:find("joy%-con") then return "switch", nil end
  if name:find("xbox one") or name:find("xbox series") or name:find("xbox wireless") then
    return "xbox", "xboxone"
  end
  if name:find("xbox 360") then return "xbox", "xbox360" end
  if name:find("xbox") or name:find("xinput") or gid:find("xinput") then return "xbox", nil end
  return "generic", nil
end

function Input.adoptJoystick(js)
  if not js or not js:isGamepad() then return end
  -- love.gamepadpressed lands here on every single button press, so the
  -- already-adopted case must be free: no re-identification, and above all no
  -- resetting of what we have learned about the device's motors.
  if Input.joystick == js then Input.setScheme("pad") return end
  if Input.joystick then Input.rumbleStop() end
  Input.joystick = js
  Input.brand, Input.model = brandFor(js)
  -- Ask once. LOVE 11.x answers out of SDL_JoystickHasRumble, which is honest
  -- about a pad with no motors -- but it is only ever used to *avoid* pointless
  -- driver writes: the first real setVibration is what decides (see rumbleSend),
  -- because a false negative here would silence a controller that works.
  Input.rumbleSupported = nil
  if js.isVibrationSupported then
    local ok, v = pcall(js.isVibrationSupported, js)
    if ok then Input.rumbleSupported = v and true or false end
  end
  Input.rumbleWorks = nil
  Input.setScheme("pad")
end

--- A gamepad that is not there. `BOTS_FAKEPAD=ps|xbox|switch` installs one, so
--- the capture harness can photograph a DualSense's prompts and exercise the
--- whole rumble path -- pattern, mixer and driver call -- on a machine that has
--- no controller plugged into it. Every send is counted on `Input.fakePad`.
local FAKE_NAME = { ps = "DualSense Wireless Controller",
                    xbox = "Xbox Series X Controller",
                    switch = "Nintendo Switch Pro Controller",
                    generic = "Generic USB Gamepad" }
local FAKE_GUID = { ps = "030000004c050000e60c000011810000",
                    xbox = "030000005e040000120b000005050000",
                    switch = "0300000007e0500000920000110000000",
                    generic = "03000000000000000000000000000000" }

function Input.makeFakePad(kind)
  kind = FAKE_NAME[kind] and kind or "generic"
  local pad = { kind = kind, sends = 0, lastLo = 0, lastHi = 0, log = {} }
  function pad:isGamepad() return true end
  function pad:isConnected() return true end
  function pad:getName() return FAKE_NAME[self.kind] end
  function pad:getGUID() return FAKE_GUID[self.kind] end
  function pad:isGamepadDown() return false end
  function pad:getGamepadAxis() return 0 end
  function pad:isVibrationSupported() return true end
  function pad:setVibration(l, r)
    self.sends = self.sends + 1
    self.lastLo, self.lastHi = l or 0, r or 0
    return true
  end
  return pad
end

function Input.setScheme(s)
  if Input.scheme == s then return end
  Input.scheme = s
  Signal.emit("input:scheme", s)
end

function Input.load()
  if love.joystick then
    for _, js in ipairs(love.joystick.getJoysticks()) do
      if js:isGamepad() then Input.adoptJoystick(js) break end
    end
  end
  local fake = _G.BOTS_CFG and _G.BOTS_CFG("BOTS_FAKEPAD")
  if fake and not Input.joystick then
    Input.fakePad = Input.makeFakePad(fake)
    Input.adoptJoystick(Input.fakePad)
  end
  -- The haptics module subscribes to the signal bus the moment it loads, and
  -- love.load calls this twice; Haptics.load is idempotent for that reason.
  local ok, H = pcall(require, "src.game.haptics")
  if ok then Input.haptics = H H.load() end
  local os = love.system and love.system.getOS() or ""
  if os == "iOS" or os == "Android" then Input.setScheme("touch") end
  -- BOTS_INPUT=touch|pad|kb forces a scheme. A desktop capture cannot fake a
  -- finger, and the touch layout is the one thing in this game that can only
  -- be judged by looking at it on a phone-shaped frame.
  local forced = _G.BOTS_CFG and _G.BOTS_CFG("BOTS_INPUT")
  if forced == "touch" or forced == "pad" or forced == "kb" then
    Input.setScheme(forced)
  end
end

------------------------------------------------------------------------ polling
local function padAxis(js, name)
  local v = js:getGamepadAxis(name) or 0
  if math.abs(v) < Input.deadzone then return 0 end
  -- rescale past the deadzone so slow walking is still possible
  return U.sign(v) * (math.abs(v) - Input.deadzone) / (1 - Input.deadzone)
end

function Input.update(dt)
  for a, v in pairs(state) do prev[a] = v end

  local js = Input.joystick
  if js and not js:isConnected() then Input.joystick = nil js = nil end

  local mx, my = 0, 0
  local anyPad, anyKey = false, false

  -- keyboard movement
  local kb = love.keyboard
  if kb.isDown("a") or kb.isDown("left")  then mx = mx - 1 anyKey = true end
  if kb.isDown("d") or kb.isDown("right") then mx = mx + 1 anyKey = true end
  if kb.isDown("w") or kb.isDown("up")    then my = my - 1 anyKey = true end
  if kb.isDown("s") or kb.isDown("down")  then my = my + 1 anyKey = true end
  if mx ~= 0 and my ~= 0 then mx, my = mx * 0.7071, my * 0.7071 end

  -- gamepad movement overrides when pushed
  if js then
    local ax, ay = padAxis(js, "leftx"), padAxis(js, "lefty")
    if ax ~= 0 or ay ~= 0 then
      mx, my = U.limit(ax, ay, 1)
      anyPad = true
    end
  end

  -- touch stick
  local touch = Input.touchModule
  if touch and touch.active then
    local tx, ty = touch:moveVector()
    if tx ~= 0 or ty ~= 0 then mx, my = tx, ty end
  end

  Input.moveX, Input.moveY = mx, my

  -- aim: right stick > mouse > movement direction
  Input.aimIsExplicit = false
  if js then
    local ax, ay = padAxis(js, "rightx"), padAxis(js, "righty")
    if ax ~= 0 or ay ~= 0 then
      Input.aimX, Input.aimY = U.norm(ax, ay)
      Input.aimIsExplicit = true
      anyPad = true
    end
  end
  if touch and touch.active then
    local ax, ay = touch:aimVector()
    if ax ~= 0 or ay ~= 0 then Input.aimX, Input.aimY = ax, ay Input.aimIsExplicit = true end
  end

  -- buttons
  for a, b in pairs(BIND) do
    local down = false
    if b.keys then
      for _, k in ipairs(b.keys) do if kb.isDown(k) then down = true anyKey = true break end end
    end
    if not down and b.mouse and Input.scheme ~= "touch" then
      for _, m in ipairs(b.mouse) do if love.mouse.isDown(m) then down = true anyKey = true break end end
    end
    if not down and js then
      if b.pad then
        for _, p in ipairs(b.pad) do if js:isGamepadDown(p) then down = true anyPad = true break end end
      end
      if not down and b.trigger and js:getGamepadAxis(b.trigger) > 0.45 then
        down = true anyPad = true
      end
    end
    if not down and touch and touch.active and touch:isDown(a) then down = true end
    state[a] = down
  end

  if anyPad then Input.setScheme("pad")
  elseif anyKey and Input.scheme ~= "touch" then Input.setScheme("kb") end

  Input.rumbleUpdate(dt)
end

--------------------------------------------------------------------- queries
function Input.down(a) return state[a] == true end
function Input.pressed(a) return state[a] and not prev[a] end
function Input.released(a) return (not state[a]) and prev[a] end

--- Consume a press so two systems cannot both react to it.
function Input.consume(a) prev[a] = true state[a] = true end

function Input.moveVector() return Input.moveX, Input.moveY end

--- Aim direction, resolved for the active scheme.
--- `fx, fy` is a fallback (usually the entity's facing) and `wx, wy` its world position.
function Input.aimVector(wx, wy, fx, fy, camera)
  if Input.scheme == "kb" and camera then
    local mxs, mys = love.mouse.getPosition()
    local wxm, wym = camera:toWorld(mxs, mys)
    local dx, dy, l = U.norm(wxm - wx, wym - wy)
    if l > 6 then return dx, dy, true end
  elseif Input.aimIsExplicit then
    return Input.aimX, Input.aimY, true
  end
  return fx or 1, fy or 0, false
end

--------------------------------------------------------------------- feedback
-- THE RUMBLE MIXER.
--
-- What the hardware actually is: two motors and a duration. LOVE 11.x hands
-- them to SDL_JoystickRumble as `Joystick:setVibration(low, high, seconds)` --
-- a heavy low-frequency mass on the left, a light high-frequency one on the
-- right. A DualSense's voice-coil actuators and its adaptive triggers are
-- reachable only through raw HID feature reports, which LOVE does not expose;
-- what a DualSense gives us here is the same two numbers an Xbox pad gives us,
-- emulated by its actuators. Nothing in this file pretends otherwise.
--
-- What was here before was one call straight to the driver plus a countdown.
-- Two things followed from that, and both are audible in the hand:
--
--   * calls stomped each other. A 90 ms dash tick landing during the 300 ms
--     pulse rumble *replaced* it at a quarter of the amplitude, and then the
--     dash's own timer stopped the motors early. Big moments were routinely
--     cut in half by small ones.
--   * every amplitude was a step. A rumble that starts, holds and stops is the
--     one shape the instrument has fewest of; a rise, a landing and a release
--     are what make two motors sound like more than two motors.
--
-- So: voices, envelopes and a mix.
--
--   * a VOICE is one firing of a named pattern from game/tuning.lua, walking
--     its stages and interpolating between them;
--   * voices SUM, clamped, so forty bots detonating on the rig one after
--     another become a texture rather than forty identical taps;
--   * a voice DUCKS anything ranked below it, so dawn is not chewed up by the
--     hand-plant ticks landing inside it;
--   * the driver is only written to when the mix has actually moved (`mix.eps`)
--     or has gone stale. An idle controller costs nothing at all, and the two-
--     second dawn swell costs 33 writes in 144 frames rather than 144. A sharp
--     attack still takes a write per frame, because that is what an attack is.
local HP = TU.haptics
local MIX = HP.mix

local voices, nvoices = {}, 0
local lastFire = {}
local clock = 0
local outLo, outHi, outAt = 0, 0, -1
local spawnBudget = MIX.budget
local webAt = -1
local logOn = nil            -- resolved on first use; BOTS_HAPTIC_LOG=1
Input.rumbleSends = 0

local function stagesDur(st)
  local d = 0
  for i = 1, #st do d = d + (st[i][3] or 0) end
  return d
end

--- Amplitudes at time `t` into a pattern. Every stage ramps linearly from the
--- previous stage's pair (silence, before the first) to its own.
local function stagesAt(st, t)
  local pl, ph, acc = 0, 0, 0
  for i = 1, #st do
    local g = st[i]
    local d = g[3] or 0
    if t <= acc + d then
      local k = d > 0 and (t - acc) / d or 1
      return pl + (g[1] - pl) * k, ph + (g[2] - ph) * k
    end
    acc = acc + d
    pl, ph = g[1], g[2]
  end
  return 0, 0
end

local function stagesPeak(st)
  local lo, hi = 0, 0
  for i = 1, #st do
    if st[i][1] > lo then lo = st[i][1] end
    if st[i][2] > hi then hi = st[i][2] end
  end
  return lo, hi
end

--- Everything that fires, whether or not a controller is listening.
--- `BOTS_HAPTIC_LOG=1` prints one line per voice:
---   HAP|<seconds>|<name>|<pri>|<peakLow>|<peakHigh>|<duration>
--- and keeps a per-pattern tally on `Input.hapticCounts`. There is no gamepad
--- on a capture machine, so this is the only way the *design* -- what fires,
--- how often, and what stays quiet -- can be checked at all.
local function hapticLog(name, pri, lo, hi, dur)
  if logOn == nil then
    logOn = (_G.BOTS_CFG and _G.BOTS_CFG("BOTS_HAPTIC_LOG")) ~= nil
    Input.hapticCounts = {}
  end
  if not logOn then return end
  local c = Input.hapticCounts
  c[name] = (c[name] or 0) + 1
  print(string.format("HAP|%.3f|%s|%d|%.3f|%.3f|%.3f", clock, name, pri, lo, hi, dur))
end

--- The browser has NO rumble path: SDL's Emscripten joystick backend samples
--- `navigator.getGamepads()` for state and implements no rumble entry point at
--- all, so `setVibration` there is a no-op that returns false. The page,
--- however, can reach `gamepad.vibrationActuator.playEffect("dual-rumble", ...)`
--- directly -- so in the web build the mix is announced on stdout, which the
--- shell already routes through `Module.print`, and a page that wants haptics
--- forwards it. `playEffect` cancels whatever is playing and takes a single
--- magnitude pair, so this sends one line per *voice* with the pattern's peak
--- and total length, not the per-frame envelope, and only for voices worth
--- interrupting another for.
local webOn = nil
local function rumbleBridge(name, pri, lo, hi, dur)
  if webOn == nil then
    webOn = (_G.BOTS_CFG and (_G.BOTS_CFG("BOTS_WEB") or _G.BOTS_CFG("BOTS_HAPTIC_BRIDGE"))) ~= nil
  end
  if not webOn or pri < HP.web.minPri then return end
  -- Nothing to say when there is no pad on the page: a keyboard or touch
  -- player must not pay a single line for a feature they cannot feel.
  if not Input.joystick then return end
  if clock - webAt < HP.web.gap then return end
  webAt = clock
  print(string.format("HAPTIC|%.3f|%.3f|%d", lo, hi, math.floor(dur * 1000 + 0.5)))
end

--- Free a voice slot for something of rank `pri` by dropping the lowest-ranked,
--- oldest voice playing. Refuses when everything in the mix outranks the caller,
--- which is how a big moment stays whole during a storm of small ones.
local function makeRoom(pri)
  if nvoices < MIX.maxVoices then return true end
  local worst, wi = nil, nil
  for i = 1, nvoices do
    local v = voices[i]
    if not worst or v.pri < worst.pri or (v.pri == worst.pri and v.t > worst.t) then
      worst, wi = v, i
    end
  end
  if not worst or worst.pri > pri then return false end
  voices[wi] = voices[nvoices]
  voices[nvoices] = nil
  nvoices = nvoices - 1
  return true
end

--- Play one named pattern. `scale` (default 1) is the only per-firing freedom
--- game/haptics.lua has -- a boss hit scales with the damage, everything else
--- is exactly the shape tuning authored.
function Input.rumblePattern(name, scale)
  local pat = HP.pat[name]
  if not pat then return false end
  if not Input.rumbleEnabled or Input.rumbleScale <= 0 then return false end
  scale = scale or 1
  if scale <= 0.01 then return false end
  if scale > 1 then scale = 1 end

  -- the same pattern may not retrigger inside its own gap
  local gap = pat.gap or 0
  if gap > 0 and clock - (lastFire[name] or -1e9) < gap then return false end

  -- ...nor stack past `mix.maxSame`, which is what stops a cohort of eight
  -- landing as one slab
  if MIX.maxSame then
    local same = 0
    for i = 1, nvoices do if voices[i].name == name then same = same + 1 end end
    if same >= MIX.maxSame then return false end
  end

  -- triage: during a storm, only rank `budgetPri` and up still gets through
  local pri = pat.pri or 1
  if spawnBudget < 1 and pri < (MIX.budgetPri or 3) then return false end

  if not makeRoom(pri) then return false end

  spawnBudget = spawnBudget - 1
  lastFire[name] = clock
  local dur = stagesDur(pat.s)
  nvoices = nvoices + 1
  voices[nvoices] = { name = name, pri = pri, s = pat.s, t = 0, dur = dur, k = scale }

  local pl, ph = stagesPeak(pat.s)
  hapticLog(name, pri, pl * scale, ph * scale, dur)
  rumbleBridge(name, pri, pl * scale * Input.rumbleScale, ph * scale * Input.rumbleScale, dur)
  return true
end

--- The pre-existing call shape, kept exactly as entities/player.lua uses it:
--- `Input.rumble(strength, duration, weakOverride)`, low motor at 0.6 of
--- strength unless overridden, high motor at strength. It is a voice now, so a
--- dash tick can no longer truncate the Pulse it lands inside.
function Input.rumble(strength, dur, weak)
  if not Input.rumbleEnabled or Input.rumbleScale <= 0 then return end
  local s = U.saturate(strength or 0)
  local lo = U.saturate(weak or s * 0.6)
  local d = math.max(0.02, dur or 0.15)
  -- Those four calls are not one event: a dash tick is 0.25 and being hit is
  -- 0.85. Ranking them by their own strength is what lets a hit cut through the
  -- extraction while a dash politely ducks under it, without touching the file
  -- they are called from.
  local pri = (s >= 0.7 and 4) or (s >= 0.4 and 3) or 2
  if not makeRoom(pri) then return end
  nvoices = nvoices + 1
  voices[nvoices] = { name = "legacy", pri = pri, t = 0, dur = d, k = 1,
                      s = { { lo, s, 0 }, { lo * 0.5, s * 0.5, d * 0.7 }, { 0, 0, d * 0.3 } } }
  hapticLog("legacy", pri, lo, s, d)
  rumbleBridge("legacy", pri, lo * Input.rumbleScale, s * Input.rumbleScale, d)
end

--- Silence, immediately: a device change, rumble switched off, a scene that
--- must not leave a motor running behind it.
function Input.rumbleStop()
  for i = 1, nvoices do voices[i] = nil end
  nvoices = 0
  outLo, outHi = 0, 0
  local js = Input.joystick
  if js and js.setVibration and Input.rumbleWorks ~= false then
    pcall(js.setVibration, js, 0, 0)
  end
end

--- Write the mix to the device, but only when it has moved or gone stale.
--- The duration handed over is longer than the refresh interval on purpose: if
--- a frame is lost the motors decay on their own rather than sticking on.
local function rumbleSend(lo, hi, force)
  local js = Input.joystick
  if not js or not js.setVibration then return end
  if Input.rumbleWorks == false then return end
  if not force
     and math.abs(lo - outLo) < MIX.eps and math.abs(hi - outHi) < MIX.eps
     and clock - outAt < MIX.refresh then
    return
  end
  outLo, outHi, outAt = lo, hi, clock
  local ok, res = pcall(js.setVibration, js, lo, hi, MIX.hold)
  Input.rumbleSends = Input.rumbleSends + 1
  -- Decide once, from the device rather than from the query: latch off only
  -- when the call failed AND the device says it has no motors, so a pad whose
  -- capability query lies is still driven.
  if Input.rumbleWorks == nil then
    if ok and res ~= false then Input.rumbleWorks = true
    elseif Input.rumbleSupported == false then Input.rumbleWorks = false end
  end
end

--- Advance every voice and mix them. Called once per frame from Input.update
--- with *real* time, so hitstop and the balance harness's time dilation cannot
--- stretch or skip a rumble.
function Input.rumbleUpdate(dt)
  clock = clock + dt
  spawnBudget = math.min(MIX.budget, spawnBudget + MIX.budget * dt)

  if nvoices == 0 then
    if outLo ~= 0 or outHi ~= 0 then rumbleSend(0, 0, true) end
    return
  end

  -- highest rank playing; everything below it is ducked one step
  local top = 0
  for i = 1, nvoices do if voices[i].pri > top then top = voices[i].pri end end

  local lo, hi = 0, 0
  local w = 1
  while w <= nvoices do
    local v = voices[w]
    v.t = v.t + dt
    if v.t >= v.dur then
      -- compact by sliding the tail down: the same append-while-iterating trap
      -- the entity sweep and the timer both fell into lives here too
      voices[w] = voices[nvoices]
      voices[nvoices] = nil
      nvoices = nvoices - 1
    else
      local a, b = stagesAt(v.s, v.t)
      local duck = (v.pri >= top) and 1 or MIX.duck
      lo = lo + a * v.k * duck
      hi = hi + b * v.k * duck
      w = w + 1
    end
  end

  local g = Input.rumbleEnabled and U.saturate(Input.rumbleScale) or 0
  lo = U.saturate(lo) * g
  hi = U.saturate(hi) * g
  rumbleSend(lo, hi)
end

--- What the mix is right now, for a test harness or an options-screen preview.
function Input.rumbleState() return outLo, outHi, nvoices end

--------------------------------------------------------------------- glyphs
--- Human-readable button label for an action, in the active scheme's language.
function Input.glyph(action)
  local b = BIND[action]
  if not b then return "?" end
  if Input.scheme == "pad" then
    local G = GLYPH[Input.brand] or GLYPH.generic
    local M = Input.model and MODEL_GLYPH[Input.model]
    local key = b.trigger or (b.pad and b.pad[1])
    if not key then return "-" end
    return (M and M[key]) or G[key] or key:upper()
  end
  -- Touch used to answer "TAP" for everything, which is true of every button on
  -- the glass and therefore tells the player nothing: "TAP SEND THEM SOMEWHERE"
  -- does not say which of six round buttons to tap. The touch layer names its
  -- own controls, including the contextual one.
  if Input.scheme == "touch" then
    local t = Input.touchModule
    if t and t.glyphFor then
      local ok, g = pcall(t.glyphFor, action)
      if ok and type(g) == "string" then return g end
    end
    return "TAP"
  end
  local k = b.keys and b.keys[1]
  if not k then
    if b.mouse then return b.mouse[1] == 1 and "LMB" or "RMB" end
    return "-"
  end
  return KEYNAME[k] or k:upper()
end

local MODEL_NAME = {
  dualsense = "DualSense", ds4 = "DualShock 4", ds3 = "DualShock 3",
  xboxone = "Xbox Controller", xbox360 = "Xbox 360 Controller",
}
local BRAND_NAME = { ps = "PlayStation Pad", xbox = "Xbox Controller",
                     switch = "Switch Pro Controller" }

--- What the options screen prints as the active device. It used to answer
--- "DualSense" for every PlayStation pad ever made, including a DualShock 3.
function Input.schemeName()
  if Input.scheme == "pad" then
    return (Input.model and MODEL_NAME[Input.model])
        or BRAND_NAME[Input.brand] or "Gamepad"
  end
  return Input.scheme == "touch" and "Touch" or "Keyboard"
end

--------------------------------------------------------------- love callbacks
function Input.joystickadded(js) if not Input.joystick then Input.adoptJoystick(js) end end
function Input.joystickremoved(js)
  if Input.joystick == js then
    Input.rumbleStop()
    Input.joystick, Input.model, Input.rumbleWorks = nil, nil, nil
    Input.setScheme("kb")
  end
end
function Input.gamepadpressed(js, _) Input.adoptJoystick(js) end
function Input.touchpressed() if Input.scheme ~= "touch" then Input.setScheme("touch") end end

return Input
