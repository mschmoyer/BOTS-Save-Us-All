-- Minimal single-inheritance class system.
--   local Foo = Class("Foo")
--   function Foo:init(x) self.x = x end
--   local Bar = Class("Bar", Foo)
--   function Bar:init(x) Bar.super.init(self, x) end
local function Class(name, parent)
  local c = {}
  c.__name = name
  c.__index = c
  c.super = parent
  if parent then setmetatable(c, { __index = parent }) end

  c.new = function(...)
    local o = setmetatable({}, c)
    if o.init then o:init(...) end
    return o
  end

  setmetatable(c, {
    __index = parent,
    __call = function(_, ...) return c.new(...) end,
  })
  return c
end
return Class
