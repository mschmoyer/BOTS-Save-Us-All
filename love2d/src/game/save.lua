-- The saved run.
--
-- A run is thirteen minutes and forty-eight names long, and until now closing
-- the tab threw all of it away. This writes one file, `run.lua`, next to the
-- preferences, and the title screen offers to pick it back up.
--
-- WHEN IT SAVES: at dawn, once the draft is done and the cycle has turned.
-- Nowhere else. That is not laziness -- it is the only moment in the loop where
-- the world is quiet. Mid-night there are waves in flight, projectiles, a
-- director part-way through a budget and bots half-way through an errand, and
-- serialising all of that faithfully is a much larger promise than "you can
-- close the tab". At dawn the field is clear, so a save is exactly the island,
-- the crew, the chips and the tally. The pause menu says which cycle you would
-- come back to, so the deal is visible rather than assumed.
--
-- WHAT IT DOES NOT STORE: anything derivable. A tree is fully determined by
-- (x, y, seed) plus how grown it is, so that is the four numbers per tree; its
-- species, skeleton, height, lean, colour jitter and O2 weight all fall back
-- out of the same RNG. Oxygen is recomputed from the forest. The island is
-- rebuilt from the world seed.
local Save = {}

Save.FILE    = "run.lua"
Save.VERSION = 1

--- Compile with no access to globals at all: the chunk can only build a table.
local function loadLiteral(src)
  if type(src) ~= "string" or #src > 4 * 1024 * 1024 then return nil end
  local chunk
  if setfenv then
    chunk = loadstring(src, "run")
    if chunk then setfenv(chunk, {}) end
  else
    chunk = load(src, "run", "t", {})
  end
  if not chunk then return nil end
  local ok, res = pcall(chunk)
  if not ok or type(res) ~= "table" then return nil end
  return res
end

local function num(v)
  v = tonumber(v) or 0
  if v ~= v or v == math.huge or v == -math.huge then return "0" end
  if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
  return string.format("%.4g", v)
end

--- Flat numeric arrays rather than a table per entity: nine hundred trees as
--- nine hundred table literals is a real cost in the browser's interpreter,
--- and this file is parsed on the loading screen.
local function flat(t)
  local out = {}
  for i = 1, #t do out[i] = num(t[i]) end
  return "{" .. table.concat(out, ",") .. "}"
end

local function strs(t)
  local out = {}
  for i = 1, #t do out[i] = string.format("%q", tostring(t[i])) end
  return "{" .. table.concat(out, ",") .. "}"
end

---------------------------------------------------------------------- writing
--- Snapshot `world` into a table of plain values.
function Save.snapshot(world)
  local w = world
  local trees, bots, nodes, botNames, botTypes, chips = {}, {}, {}, {}, {}, {}

  for i = 1, #w.trees do
    local t = w.trees[i]
    if t.alive and t.stage ~= "dead" then
      local n = #trees
      trees[n + 1] = t.x
      trees[n + 2] = t.y
      trees[n + 3] = t.seed
      trees[n + 4] = t.growth
      trees[n + 5] = t.elder and 1 or 0
    end
  end

  for i = 1, #w.bots do
    local b = w.bots[i]
    if b.alive and b.state ~= "dead" then
      local n = #bots
      bots[n + 1] = b.x
      bots[n + 2] = b.y
      bots[n + 3] = b.hp
      bots[n + 4] = b.serial or 0
      botTypes[#botTypes + 1] = b.type
      botNames[#botNames + 1] = b.name or ""
    end
  end

  for i = 1, #w.cobalts do
    local c = w.cobalts[i]
    if c.alive and c.node then
      local n = #nodes
      nodes[n + 1] = c.x
      nodes[n + 2] = c.y
      nodes[n + 3] = c.left or 0
    end
  end

  local list = w.chips and w.chips.list or {}
  for i = 1, #list do chips[i] = list[i].id end

  local st = w.stats or {}
  return {
    version  = Save.VERSION,
    seed     = w.seed,
    cycle    = w.cycle,
    time     = w.time,
    cobalt   = w.cobalt,
    o2       = w.o2,
    trees    = trees,
    bots     = bots,
    botTypes = botTypes,
    botNames = botNames,
    nodes    = nodes,
    chips    = chips,
    lost     = w.allLostNames or {},
    rallyX   = w.rallyX,
    rallyY   = w.rallyY,
    stats    = { st.planted or 0, st.lost or 0, st.botsLost or 0,
                 st.botsBuilt or 0, st.killed or 0, st.cobaltMined or 0,
                 st.rescued or 0 },
  }
end

local function serialize(d)
  local o = {
    "-- BOTS: SAVE US ALL -- REFOREST",
    "-- a run in progress; safe to delete",
    "return {",
    "  version = " .. num(d.version) .. ",",
    "  seed = " .. num(d.seed) .. ",",
    "  cycle = " .. num(d.cycle) .. ",",
    "  time = " .. num(d.time) .. ",",
    "  cobalt = " .. num(d.cobalt) .. ",",
    "  o2 = " .. num(d.o2) .. ",",
    "  stats = " .. flat(d.stats) .. ",",
    "  chips = " .. strs(d.chips) .. ",",
    "  lost = " .. strs(d.lost) .. ",",
    "  botTypes = " .. strs(d.botTypes) .. ",",
    "  botNames = " .. strs(d.botNames) .. ",",
    "  bots = " .. flat(d.bots) .. ",",
    "  nodes = " .. flat(d.nodes) .. ",",
    "  trees = " .. flat(d.trees) .. ",",
  }
  if d.rallyX and d.rallyY then
    o[#o + 1] = "  rallyX = " .. num(d.rallyX) .. ", rallyY = " .. num(d.rallyY) .. ","
  end
  o[#o + 1] = "}"
  o[#o + 1] = ""
  return table.concat(o, "\n")
end

--- Write the run. Returns true, or false and a reason.
function Save.write(world)
  if not (love and love.filesystem and world) then return false, "no filesystem" end
  local ok, res = pcall(function()
    return love.filesystem.write(Save.FILE, serialize(Save.snapshot(world)))
  end)
  if not ok then
    print("save failed: " .. tostring(res))
    return false, tostring(res)
  end
  Save.cached = nil
  return true
end

---------------------------------------------------------------------- reading
--- The saved run, or nil. Cached, because the title screen asks every frame.
function Save.read()
  if Save.cached ~= nil then return Save.cached or nil end
  Save.cached = false
  if not (love and love.filesystem) then return nil end
  if not love.filesystem.getInfo(Save.FILE) then return nil end
  local ok, src = pcall(love.filesystem.read, Save.FILE)
  if not ok or type(src) ~= "string" then return nil end
  local d = loadLiteral(src)
  if type(d) ~= "table" or d.version ~= Save.VERSION or not d.seed then return nil end
  if type(d.trees) ~= "table" or type(d.bots) ~= "table" then return nil end
  Save.cached = d
  return d
end

function Save.exists() return Save.read() ~= nil end

--- What the menu row says: "CYCLE 3 - 214 TREES, 31 CREW".
function Save.describe()
  local d = Save.read()
  if not d then return nil end
  return string.format("CYCLE %d  %d TREES  %d CREW",
                       d.cycle or 1, math.floor(#d.trees / 5), math.floor(#d.bots / 4))
end

function Save.clear()
  Save.cached = false
  if love and love.filesystem and love.filesystem.getInfo(Save.FILE) then
    pcall(love.filesystem.remove, Save.FILE)
  end
end

return Save
