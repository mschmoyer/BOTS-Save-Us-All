-- HAPTICS -- what the controller is allowed to say, and when.
--
-- This module is entirely a LISTENER. It subscribes to core/signal.lua and
-- fires named patterns from game/tuning.lua through engine/input.lua's rumble
-- mixer. It never reaches into an entity, a scene or the world, and nothing
-- reaches into it: every moment it answers is a signal the game was already
-- emitting for the HUD, the audio and the story to hear. Adding a new one is a
-- `Signal.on` here and a shape in `T.haptics.pat` there, and no gameplay file
-- is touched.
--
-- WHAT THE HARDWARE IS. LOVE 11.x exposes gamepads through SDL2, and SDL's
-- rumble interface is two motors and a duration:
--
--     Joystick:setVibration(low, high, seconds)
--
-- That is the whole instrument, on every pad, DualSense included. The
-- DualSense's voice-coil actuators (its "fine" haptics) and its adaptive
-- trigger resistance live behind raw HID output reports that LOVE has no API
-- for -- there is no love.joystick call that reaches them, and no LOVE 11.x
-- build that adds one. Anything claiming otherwise in this game would be a
-- lie, so what is designed here is designed for two motors.
--
-- HOW THE BUDGET IS SPENT. A night in this game is sixty enemy deaths a
-- minute. The temptation is to answer each one; the result is a controller
-- that buzzes continuously, which is both unpleasant and *self-defeating* --
-- once the hand has tuned the buzz out, dawn has nothing left to say. So the
-- loudest design decision in this file is the list of things that are silent:
--
--   enemy:killed        60+/min at night          silent
--   enemy:spawned       constant                  silent
--   cobalt:gained/spent every pickup, every buy   silent
--   bot:spawned         paired with bot:built     silent (bot:built answers)
--   bots:reinforce      one a second in the finale silent
--   tree:planted by a bot                          silent -- see below
--   bot:lost peacefully a retirement, not a death  silent
--   music:*, dialogue:*, bot:epitaph, run:checkpoint, world:rally moves
--
-- `tree:planted` is the game's verb and it fires for three different actors:
-- the player's hand-plant, a Planter doing its job, and a forest seeding
-- itself. Only the first is the player's own action, so only the first is felt,
-- and even that is one soft tick on the light motor. Forty Planters working a
-- forest would otherwise be a permanent hum.
--
-- WHAT THE BROWSER CAN AND CANNOT DO, since the browser is the ship target.
-- The web build runs LOVE compiled to WebAssembly, and SDL's Emscripten
-- joystick backend reads `navigator.getGamepads()` for state and implements no
-- rumble entry point at all -- there is no `vibrationActuator` and no
-- `playEffect` anywhere in the love.js glue or the wasm. `setVibration` in the
-- browser is therefore a no-op, and no amount of Lua changes that.
--
-- The *page*, however, can reach the pad: Chromium exposes
-- `Gamepad.prototype.vibrationActuator` and `GamepadHapticActuator.playEffect`.
-- So the web build announces each voice on stdout, which the shell already
-- routes through `Module.print` (see engine/input.lua's rumbleBridge), as
--
--     HAPTIC|<low>|<high>|<milliseconds>
--
-- and a page that wants haptics forwards it. tools/web_shell.html does not do
-- that yet; the whole of the missing half is this, inside its `print` handler:
--
--     if (text.lastIndexOf('HAPTIC|', 0) === 0) {
--       var p = text.split('|'), pads = navigator.getGamepads ? navigator.getGamepads() : [];
--       for (var i = 0; i < pads.length; i++) {
--         var a = pads[i] && pads[i].vibrationActuator;
--         if (a && a.playEffect) a.playEffect('dual-rumble', {
--           duration: +p[3], strongMagnitude: +p[1], weakMagnitude: +p[2] });
--       }
--       return;
--     }
--
-- `playEffect` cancels whatever is playing and takes one magnitude pair, so the
-- bridge sends a pattern's peak and length rather than the per-frame envelope,
-- only for rank 2 and up, and only when a pad is actually present. An iframe
-- with no `allow="gamepad"` has no pads at all, so it costs nothing there.
--
-- player:dash, player:shove, player:pulse and player:hurt are deliberately NOT
-- subscribed here: entities/player.lua already calls Input.rumble directly for
-- those four, and subscribing would double every one of them. They arrive at
-- the mixer as the `legacy` pattern and are ranked and ducked with everything
-- else, which is how they were brought under this design without editing them.
local Signal   = require("src.core.signal")
local Settings = require("src.game.settings")
local TU       = require("src.game.tuning")

local Haptics = {}
local Input                         -- resolved on load; engine/input requires us

Haptics.enabled = true

------------------------------------------------------------------- the setting
-- `rumbleAmount` is not in settings.lua's own defaults table, so it is
-- registered here -- schema first, exactly as if it had been declared there.
-- game/settings.lua drives its whole load, save and validation path off
-- `Settings.schema`, so a key added before the first load is persisted,
-- range-checked and restored like any other. `rumble` stays what it always was
-- (the on/off consent engine/touch.lua also reads) and is kept in step with the
-- slider, so zero means off in one place rather than two.
local function registerSetting()
  if Settings.schema.rumbleAmount then return end
  Settings.schema.rumbleAmount = { t = "number", min = 0, max = 1 }
  Settings.defaults.rumbleAmount = 1.0
  -- If the file was already read (love.load loads settings before it loads
  -- input), the loader skipped a key that did not exist yet. Re-read for it --
  -- but never over the top of an unsaved change.
  if Settings.wasLoadedFromDisk and Settings.wasLoadedFromDisk()
     and not Settings.isDirty() then
    Settings.load()
  end
end

--- Push the player's choice into the mixer. Called on load, and by the options
--- screen the moment the slider moves.
function Haptics.applySettings()
  if not Input then return end
  local amt = Settings.get("rumbleAmount", 1)
  Input.rumbleScale = amt
  Input.rumbleEnabled = Settings.get("rumble") and amt > 0
  if not Input.rumbleEnabled and Input.rumbleStop then Input.rumbleStop() end
end

--- Write both keys together: the slider is the truth, `rumble` follows it.
function Haptics.setAmount(v)
  if v < 0 then v = 0 elseif v > 1 then v = 1 end
  Settings.set("rumbleAmount", v)
  Settings.set("rumble", v > 0)
  Haptics.applySettings()
end

function Haptics.amount() return Settings.get("rumbleAmount", 1) end

--------------------------------------------------------------------- firing
local function fire(name, scale)
  if not Haptics.enabled or not Input then return end
  Input.rumblePattern(name, scale)
end
Haptics.fire = fire

--- One representative pattern, for the options slider: it uses both motors in
--- sequence, so the player can hear the difference between two notches.
function Haptics.preview() fire("botBuilt") end

------------------------------------------------------------------ the wiring
-- Read down this list and you are reading the design: rank 5 at the top, the
-- texture at the bottom, and nothing in between that fires more than a couple
-- of times a second.
local bossHp

local function bind()
  local on = function(sig, fn) Signal.on(sig, fn, Haptics) end

  ---------------------------------------------------------------- rank 5
  on("phase:dawn",       function() fire("dawn") end)
  on("phase:extraction", function() fire("extraction") end)
  on("world:failed",     function() fire("failed") end)
  on("boss:died",        function() fire("won") end)

  ---------------------------------------------------------------- rank 4
  -- Dusk, not night: the sun going down is the moment the player reacts to,
  -- and phase:night follows it by seconds. Answering both would be one event
  -- felt twice.
  on("phase:dusk",   function() fire("night") end)
  on("boss:phase",   function() fire("bossPhase") end)
  on("bots:rebel",   function() fire("rebel") end)
  on("player:down",  function() fire("playerDown") end)
  on("chip:added",   function() fire("chip") end)
  on("world:heldDawn", function() fire("heldDawn") end)
  on("o2:milestone", function() fire("o2") end)

  ---------------------------------------------------------------- rank 3
  on("bot:downed",   function() fire("botDown") end)
  -- A bot powered down on purpose at the cap is not a loss and gets nothing.
  on("bot:lost",     function(_, peaceful) if not peaceful then fire("botLost") end end)
  on("tree:lost",    function() fire("treeLost") end)
  -- The Blight taking ground for good -- at dawn, or a Scar seeding another.
  on("blight:rooted", function() fire("blight") end)
  on("director:wave", function() fire("wave") end)
  on("player:reboot", function() fire("playerUp") end)
  -- Scaled by the share of the bar that came off, so chip damage stays a tick
  -- and a fully charged Pulse into the hull is felt. The pattern's own 0.16 s
  -- gap is what keeps the finale from becoming one continuous buzz.
  on("boss:hurt", function(hp, maxHp)
    local prev = bossHp or maxHp or hp
    bossHp = hp
    local d = (prev - hp) / math.max(1, maxHp or 1)
    if d <= 0 then return end
    fire("bossHurt", 0.35 + math.min(1, d * 9) * 0.65)
  end)
  on("boss:spawned", function(b) bossHp = b and b.hp or nil end)

  ---------------------------------------------------------------- rank 2
  on("bot:built",    function() fire("botBuilt") end)
  on("bot:revived",  function() fire("botRevived") end)
  on("bots:cohort",  function() fire("cohort") end)
  on("blight:cleared", function() fire("scarCleared") end)
  on("ui:denied",    function() fire("denied") end)
  -- Only a rally that actually moved; a refused one already emitted ui:denied.
  on("world:rally",  function(x, _, moved) if x and moved ~= false then fire("rally") end end)

  ---------------------------------------------------------------- rank 1
  -- The hand-plant only. `by` is "player" for the player, a Bot for a Planter
  -- and a Tree for natural spread.
  on("tree:planted", function(_, by) if by == "player" then fire("plant") end end)
  -- One bot on the rig's hull. Forty of these arrive in the finale, each one
  -- deliberately under the threshold of notice; the mixer sums them.
  on("bot:sacrificed", function() fire("sacrifice") end)

  ---------------------------------------------------------------- housekeeping
  -- Nothing should be left spinning when the player puts the pad down.
  on("input:scheme", function(s) if s ~= "pad" and Input.rumbleStop then Input.rumbleStop() end end)
end

------------------------------------------------------------------- lifecycle
--- Idempotent: love.load calls Input.load twice, and a demo scene may load the
--- game scene on top of an already-running one.
function Haptics.load()
  if not Input then Input = require("src.engine.input") end
  registerSetting()
  Haptics.applySettings()
  if Haptics.bound then return Haptics end
  Haptics.bound = true
  bind()
  return Haptics
end

--- Drop every subscription. Only a test harness needs this; the game keeps
--- them for its whole life.
function Haptics.unload()
  Signal.clearOwner(Haptics)
  Haptics.bound = false
  if Input and Input.rumbleStop then Input.rumbleStop() end
end

return Haptics
