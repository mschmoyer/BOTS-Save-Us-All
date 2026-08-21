-- Global event bus. Modules talk through this instead of reaching into each other.
local S = { _h = {} }

function S.on(name, fn, owner)
  local list = S._h[name]
  if not list then list = {} S._h[name] = list end
  list[#list + 1] = { fn = fn, owner = owner }
  return fn
end

function S.off(name, fn)
  local list = S._h[name]
  if not list then return end
  for i = #list, 1, -1 do
    if list[i].fn == fn then table.remove(list, i) end
  end
end

function S.clearOwner(owner)
  for _, list in pairs(S._h) do
    for i = #list, 1, -1 do
      if list[i].owner == owner then table.remove(list, i) end
    end
  end
end

function S.emit(name, ...)
  local list = S._h[name]
  if not list then return end
  -- iterate a copy so handlers may unsubscribe during dispatch
  local n = #list
  for i = 1, n do
    local h = list[i]
    if h then h.fn(...) end
  end
end

function S.reset() S._h = {} end

return S
