-- Player-owned preferences and the best-run record.
--
-- Serialized to the LOVE save directory as a Lua literal (`settings.lua`) and
-- read back through a sandboxed chunk. The file on disk is *never* trusted:
-- every key is checked against SCHEMA on load, wrong types are dropped, numbers
-- are clamped and enums are membership-tested. A corrupt or hostile file can
-- therefore only ever cost the player their preferences, never a crash.
--
-- Nothing here touches gameplay tuning -- that lives in game/tuning.lua. These
-- are the knobs a *person* turns.
local U = require("src.core.util")

local Settings = {}

--------------------------------------------------------------------- defaults
Settings.defaults = {
  -- audio buses (linear gain, 0..1)
  volMaster   = 0.90,
  volMusic    = 0.75,
  volSfx      = 1.00,
  volAmbience = 0.65,

  -- post chain toggles (engine/postfx.lua reads these)
  fxBloom      = true,
  fxGrain      = true,
  fxAberration = true,
  fxVignette   = true,
  fxDistortion = true,

  -- accessibility: 0 = off, 1 = full strength
  shakeAmount = 1.00,
  flashAmount = 1.00,
  rumble      = true,

  -- touch layout
  touchSide    = "right",   -- which side the action cluster lives on
  touchScale   = 1.00,      -- 0.8 .. 1.35, personal thumb size
  touchOpacity = 0.92,
  touchLabels  = true,      -- word labels under the glyphs
  touchAimAssist = true,

  -- renderer
  quality = "high",         -- "low" | "medium" | "high"

  -- best run so far, for the title screen
  bestCycles = 0,
  bestTrees  = 0,
  bestO2     = 0.0,
  runs       = 0,
}

--- Per-key validation. `t` is the Lua type; numbers get a range, strings an
--- explicit set of legal values. A key absent from here is not loadable.
local SCHEMA = {
  volMaster   = { t = "number", min = 0, max = 1 },
  volMusic    = { t = "number", min = 0, max = 1 },
  volSfx      = { t = "number", min = 0, max = 1 },
  volAmbience = { t = "number", min = 0, max = 1 },

  fxBloom      = { t = "boolean" },
  fxGrain      = { t = "boolean" },
  fxAberration = { t = "boolean" },
  fxVignette   = { t = "boolean" },
  fxDistortion = { t = "boolean" },

  shakeAmount = { t = "number", min = 0, max = 1 },
  flashAmount = { t = "number", min = 0, max = 1 },
  rumble      = { t = "boolean" },

  touchSide      = { t = "string", oneOf = { right = true, left = true } },
  touchScale     = { t = "number", min = 0.75, max = 1.4 },
  touchOpacity   = { t = "number", min = 0.2, max = 1 },
  touchLabels    = { t = "boolean" },
  touchAimAssist = { t = "boolean" },

  quality = { t = "string", oneOf = { low = true, medium = true, high = true } },

  bestCycles = { t = "number", min = 0, max = 99 },
  bestTrees  = { t = "number", min = 0, max = 100000 },
  bestO2     = { t = "number", min = 0, max = 1000 },
  runs       = { t = "number", min = 0, max = 1000000 },
}
Settings.schema = SCHEMA

Settings.FILE = "settings.lua"

------------------------------------------------------------------------ state
local values = {}
local loaded, dirty = false, false

for k, v in pairs(Settings.defaults) do values[k] = v end

--------------------------------------------------------------------- coercion
--- Force a raw value onto the schema. Returns nil when it cannot be trusted.
local function coerce(key, raw)
  local s = SCHEMA[key]
  if not s then return nil end
  if type(raw) ~= s.t then return nil end
  if s.t == "number" then
    if raw ~= raw then return nil end                     -- NaN
    if raw == math.huge or raw == -math.huge then return nil end
    return U.clamp(raw, s.min, s.max)
  end
  if s.t == "string" then
    if s.oneOf and not s.oneOf[raw] then return nil end
    if #raw > 64 then return nil end
    return raw
  end
  return raw
end
Settings.coerce = coerce

------------------------------------------------------------------------ access
function Settings.get(key, default)
  if not loaded then Settings.load() end
  local v = values[key]
  if v == nil then
    if default ~= nil then return default end
    return Settings.defaults[key]
  end
  return v
end

--- Write a value. Rejected silently if it fails validation, so UI code can hand
--- us whatever a slider produced.
function Settings.set(key, value)
  if not loaded then Settings.load() end
  local v = coerce(key, value)
  if v == nil then return false end
  if values[key] == v then return true end
  values[key] = v
  dirty = true
  return true
end

function Settings.toggle(key)
  local v = Settings.get(key)
  if type(v) ~= "boolean" then return false end
  return Settings.set(key, not v)
end

function Settings.reset()
  for k, v in pairs(Settings.defaults) do values[k] = v end
  dirty = true
end

function Settings.isDirty() return dirty end

--------------------------------------------------------------------- best run
--- Record the outcome of a finished run. Every field keeps its high-water mark
--- so a bad run can never erase a good one.
function Settings.recordRun(cycles, trees, o2)
  if not loaded then Settings.load() end
  values.runs = U.clamp((values.runs or 0) + 1, 0, 1000000)
  if type(cycles) == "number" and cycles > (values.bestCycles or 0) then
    values.bestCycles = U.clamp(cycles, 0, 99)
  end
  if type(trees) == "number" and trees > (values.bestTrees or 0) then
    values.bestTrees = U.clamp(trees, 0, 100000)
  end
  if type(o2) == "number" and o2 > (values.bestO2 or 0) then
    values.bestO2 = U.clamp(o2, 0, 1000)
  end
  dirty = true
  Settings.save()
end

--- The numbers the title screen shows. Returns cycles, trees, o2, runs.
function Settings.best()
  if not loaded then Settings.load() end
  return values.bestCycles or 0, values.bestTrees or 0, values.bestO2 or 0, values.runs or 0
end

function Settings.hasRun()
  local _, _, _, runs = Settings.best()
  return runs > 0
end

------------------------------------------------------------------ serialization
local function litNumber(v)
  if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
  return string.format("%.6g", v)
end

--- Emit the table as a Lua literal. Keys are written in sorted order so the
--- file diffs cleanly and a save with no changes is byte-identical.
local function serialize()
  local keys = {}
  for k in pairs(SCHEMA) do keys[#keys + 1] = k end
  table.sort(keys)
  local out = { "-- BOTS: SAVE US ALL -- REFOREST", "-- preferences; safe to delete", "return {" }
  for i = 1, #keys do
    local k = keys[i]
    local v = values[k]
    local lit
    if type(v) == "number" then lit = litNumber(v)
    elseif type(v) == "boolean" then lit = tostring(v)
    elseif type(v) == "string" then lit = string.format("%q", v)
    end
    if lit then out[#out + 1] = string.format("  %s = %s,", k, lit) end
  end
  out[#out + 1] = "}"
  out[#out + 1] = ""
  return table.concat(out, "\n")
end
Settings.serialize = serialize

--- Compile `src` with no access to globals at all. LuaJIT/5.1 uses setfenv;
--- 5.2+ takes an env argument. Either way the chunk can only build a table.
local function loadLiteral(src)
  if type(src) ~= "string" or #src > 65536 then return nil end
  local chunk, err
  if setfenv then
    chunk, err = loadstring(src, "settings")
    if chunk then setfenv(chunk, {}) end
  else
    chunk, err = load(src, "settings", "t", {})
  end
  if not chunk then return nil, err end
  local ok, res = pcall(chunk)
  if not ok or type(res) ~= "table" then return nil, res end
  return res
end

--------------------------------------------------------------------- load/save
function Settings.load()
  loaded = true
  for k, v in pairs(Settings.defaults) do values[k] = v end
  dirty = false
  if not (love and love.filesystem) then return false end
  if not love.filesystem.getInfo(Settings.FILE) then return false end

  local ok, src = pcall(love.filesystem.read, Settings.FILE)
  if not ok or type(src) ~= "string" then return false end

  local tbl = loadLiteral(src)
  if type(tbl) ~= "table" then return false end

  for k in pairs(SCHEMA) do
    local v = coerce(k, tbl[k])
    if v ~= nil then values[k] = v end
  end
  return true
end

function Settings.save()
  if not (love and love.filesystem) then return false end
  local ok = pcall(love.filesystem.write, Settings.FILE, serialize())
  if ok then dirty = false end
  return ok
end

--- Save only if something actually changed. Cheap enough to call on scene exit.
function Settings.saveIfDirty()
  if not dirty then return false end
  return Settings.save()
end

--------------------------------------------------------------- convenience
--- Push the accessibility settings into engine/juice.lua. Safe to call any time.
function Settings.applyJuice(J)
  if not J then return end
  J.shakeAmount = Settings.get("shakeAmount")
  J.flashAmount = Settings.get("flashAmount")
end

--- Push rumble/haptic consent into engine/input.lua.
function Settings.applyInput(Input)
  if not Input then return end
  Input.rumbleEnabled = Settings.get("rumble")
end

return Settings
