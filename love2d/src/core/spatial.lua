-- Uniform-grid spatial hash. Entities register once and re-bucket only when they
-- cross a cell boundary, so queries stay cheap with a thousand movers.
local Class = require("src.core.class")
local U = require("src.core.util")

local Spatial = Class("Spatial")
local floor = math.floor

function Spatial:init(cellSize)
  self.cell = cellSize or 128
  self.buckets = {}
  self.scratch = {}
end

local function key(cx, cy) return cx * 73856093 + cy * 19349663 end

function Spatial:cellOf(x, y)
  local c = self.cell
  return floor(x / c), floor(y / c)
end

function Spatial:insert(e)
  local cx, cy = self:cellOf(e.x, e.y)
  local k = key(cx, cy)
  local b = self.buckets[k]
  if not b then b = {} self.buckets[k] = b end
  b[#b + 1] = e
  e._cellKey, e._cx, e._cy = k, cx, cy
end

function Spatial:remove(e)
  local b = self.buckets[e._cellKey]
  if not b then return end
  for i = 1, #b do
    if b[i] == e then U.removeSwap(b, i) break end
  end
  e._cellKey = nil
end

--- Call after moving an entity; only re-buckets if it changed cell.
function Spatial:update(e)
  local cx, cy = self:cellOf(e.x, e.y)
  if cx ~= e._cx or cy ~= e._cy then
    self:remove(e)
    self:insert(e)
  end
end

function Spatial:clear()
  for k in pairs(self.buckets) do self.buckets[k] = nil end
end

--- Visit every entity whose cell overlaps the query circle. `fn(e)` may return
--- true to stop early. No allocation.
function Spatial:each(x, y, r, fn)
  local c = self.cell
  local x0, y0 = floor((x - r) / c), floor((y - r) / c)
  local x1, y1 = floor((x + r) / c), floor((y + r) / c)
  for cy = y0, y1 do
    for cx = x0, x1 do
      local b = self.buckets[key(cx, cy)]
      if b then
        for i = #b, 1, -1 do
          local e = b[i]
          if e and fn(e) then return end
        end
      end
    end
  end
end

--- Nearest entity satisfying `filter` within `r`. Returns entity, distance.
function Spatial:nearest(x, y, r, filter)
  local best, bestD2 = nil, r * r
  self:each(x, y, r, function(e)
    if filter and not filter(e) then return end
    local d2 = U.dist2(x, y, e.x, e.y)
    if d2 < bestD2 then best, bestD2 = e, d2 end
  end)
  return best, best and math.sqrt(bestD2) or nil
end

--- Collect into a reusable table. The table is owned by the Spatial; copy if you keep it.
function Spatial:query(x, y, r, filter)
  local out = self.scratch
  for i = #out, 1, -1 do out[i] = nil end
  local r2 = r * r
  self:each(x, y, r, function(e)
    if filter and not filter(e) then return end
    if U.dist2(x, y, e.x, e.y) <= r2 then out[#out + 1] = e end
  end)
  return out
end

return Spatial
