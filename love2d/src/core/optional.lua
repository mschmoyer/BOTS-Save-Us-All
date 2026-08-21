-- Tolerant require used only for cross-module wiring during development, so a
-- system can be built and tested before its collaborators exist.
-- `Optional.strict = true` (set by the real game scene) makes missing modules a
-- hard error instead of a silent no-op.
local Optional = { strict = false, missing = {} }

local stubMeta
local function stub()
  return setmetatable({}, stubMeta)
end
stubMeta = {
  __index = function(t, k)
    local v = stub()
    rawset(t, k, v)
    return v
  end,
  __call = function() return nil end,
  __newindex = function(t, k, v) rawset(t, k, v) end,
}

function Optional.require(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  if Optional.strict then error("missing required module: " .. name .. "\n" .. tostring(mod), 2) end
  Optional.missing[name] = tostring(mod)
  return stub()
end

return Optional
