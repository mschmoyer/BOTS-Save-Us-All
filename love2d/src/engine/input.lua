-- Device-agnostic action layer. Gameplay code asks for actions, never keys.
-- Auto-detects keyboard/mouse, gamepads (with DualSense glyph support) and touch,
-- and re-glyphs the UI live when the player switches device.
local U = require("src.core.util")
local Signal = require("src.core.signal")

local Input = {}

Input.scheme  = "kb"        -- "kb" | "pad" | "touch"
Input.brand   = "generic"   -- "ps" | "xbox" | "switch" | "generic"
Input.joystick = nil
Input.touchModule = nil     -- set by engine.touch when it loads
Input.rumbleEnabled = true
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
  ps     = { a = "\195\151", b = "O", x = "[]", y = "/\\",
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

local rumbleL, rumbleR, rumbleT = 0, 0, 0

------------------------------------------------------------------ device detect
local function brandFor(js)
  local name = (js:getName() or ""):lower()
  local gid = (js:getGUID() or ""):lower()
  if name:find("dualsense") or name:find("dualshock") or name:find("playstation")
     or name:find("wireless controller") or name:find("ps5") or name:find("ps4") then
    return "ps"
  end
  if name:find("nintendo") or name:find("switch") or name:find("joy%-con") then return "switch" end
  if name:find("xbox") or name:find("xinput") or gid:find("xinput") then return "xbox" end
  return "generic"
end

function Input.adoptJoystick(js)
  if not js or not js:isGamepad() then return end
  Input.joystick = js
  Input.brand = brandFor(js)
  Input.setScheme("pad")
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
  local os = love.system and love.system.getOS() or ""
  if os == "iOS" or os == "Android" then Input.setScheme("touch") end
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

  -- rumble decay
  if rumbleT > 0 then
    rumbleT = rumbleT - dt
    if rumbleT <= 0 and js and js.setVibration then js:setVibration(0, 0) end
  end
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
function Input.rumble(strength, dur, weak)
  if not Input.rumbleEnabled then return end
  local js = Input.joystick
  if not js or not js.setVibration then return end
  local s = U.saturate(strength)
  js:setVibration(weak and weak or s * 0.6, s)
  rumbleT = math.max(rumbleT, dur or 0.15)
end

--------------------------------------------------------------------- glyphs
--- Human-readable button label for an action, in the active scheme's language.
function Input.glyph(action)
  local b = BIND[action]
  if not b then return "?" end
  if Input.scheme == "pad" then
    if b.trigger then return GLYPH[Input.brand][b.trigger] or "?" end
    if b.pad and b.pad[1] then return GLYPH[Input.brand][b.pad[1]] or b.pad[1]:upper() end
    return "-"
  end
  if Input.scheme == "touch" then return "TAP" end
  local k = b.keys and b.keys[1]
  if not k then
    if b.mouse then return b.mouse[1] == 1 and "LMB" or "RMB" end
    return "-"
  end
  return KEYNAME[k] or k:upper()
end

function Input.schemeName()
  if Input.scheme == "pad" then
    return Input.brand == "ps" and "DualSense" or "Gamepad"
  end
  return Input.scheme == "touch" and "Touch" or "Keyboard"
end

--------------------------------------------------------------- love callbacks
function Input.joystickadded(js) if not Input.joystick then Input.adoptJoystick(js) end end
function Input.joystickremoved(js) if Input.joystick == js then Input.joystick = nil Input.setScheme("kb") end end
function Input.gamepadpressed(js, _) Input.adoptJoystick(js) end
function Input.touchpressed() if Input.scheme ~= "touch" then Input.setScheme("touch") end end

return Input
