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
local Opt   = require("src.core.optional")
local Story = Opt.require("src.game.story")

local Save = {}

Save.FILE    = "run.lua"
-- 2: the crew carry their own tallies, the fallen are records again rather
-- than tostring'd table addresses, and the story's memory of the run is in
-- here too. A version the reader does not know is simply not offered.
Save.VERSION = 3

-- Everything wide is a flat numeric array read at a fixed stride, so adding a
-- fact means appending to the row, bumping the stride here, and bumping
-- VERSION. Nothing reads these arrays without going through the constants.
--   TREE  x, y, seed, growth, elder
--   BOT   x, y, hp, serial, planted, built,
--         nights, downs, saves, carried, mined, shots, bornCycle
--   NODE  x, y, left
--   LOST  cycle, planted, built,
--         nights, downs, saves, carried, mined, shots, bornCycle
-- The per-bot ledger rides BOT and LOST at the same offsets on purpose, so a
-- machine's facts read the same whether it came home or not. It is what the
-- memorial is made of: "you carried it home twice" and "stood through five
-- nights" are not derivable from anything else in the file, and a resumed run
-- that dropped them memorialised six cycles of work as a generic.
Save.TREE_STRIDE = 5
Save.BOT_STRIDE  = 13
Save.NODE_STRIDE = 3
Save.LOST_STRIDE = 10

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
  local botTraits = {}
  local lostNames, lostTypes, lostTraits, lostFacts = {}, {}, {}, {}

  -- A trait is a table out of names.lua, so only its id crosses the file --
  -- `tostring` on the table itself is exactly the bug this format had.
  local function traitId(t) return (type(t) == "table" and t.id) or "" end

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
      -- what this one has actually done, which is its epitaph if it does not
      -- make it to the end. It used to be dropped on the way through a save,
      -- so a bot that had planted forty trees was memorialised as "was here".
      bots[n + 5] = b.planted or 0
      bots[n + 6] = b.built or 0
      -- ...and the rest of the ledger, in BOT_STRIDE order. See the comment on
      -- the strides: these seven are the difference between a memorial that
      -- says what a machine did and one that says how long it lasted.
      local L = b.log or {}
      bots[n + 7]  = L.nights or 0
      bots[n + 8]  = L.downs or 0
      bots[n + 9]  = L.saves or 0
      bots[n + 10] = L.carried or 0
      bots[n + 11] = L.mined or 0
      bots[n + 12] = L.shots or 0
      bots[n + 13] = L.bornCycle or 1
      botTypes[#botTypes + 1] = b.type
      botNames[#botNames + 1] = b.name or ""
      -- the personality, or a resumed crew is six new strangers wearing the
      -- old crew's names
      botTraits[#botTraits + 1] = traitId(b.trait)
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

  -- The fallen are RECORDS, not names (see the bot:lost handler in
  -- world.lua). Handing the array straight to a string serialiser wrote
  -- "table: 0x7f21fcb071a8" fifteen times and the memorial printed it.
  local lost = w.allLostNames or {}
  for i = 1, #lost do
    local r = lost[i]
    local isRec = type(r) == "table"
    lostNames[i]  = isRec and (r.name or "") or tostring(r)
    lostTypes[i]  = isRec and (r.type or "") or ""
    lostTraits[i] = isRec and traitId(r.trait) or ""
    local n = #lostFacts
    lostFacts[n + 1] = isRec and (r.cycle or 0) or 0
    lostFacts[n + 2] = isRec and (r.planted or 0) or 0
    lostFacts[n + 3] = isRec and (r.built or 0) or 0
    -- the same seven, at the same offsets as BOT
    lostFacts[n + 4]  = isRec and (r.nights or 0) or 0
    lostFacts[n + 5]  = isRec and (r.downs or 0) or 0
    lostFacts[n + 6]  = isRec and (r.saves or 0) or 0
    lostFacts[n + 7]  = isRec and (r.carried or 0) or 0
    lostFacts[n + 8]  = isRec and (r.mined or 0) or 0
    lostFacts[n + 9]  = isRec and (r.shots or 0) or 0
    lostFacts[n + 10] = isRec and (r.bornCycle or r.cycle or 0) or 0
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
    botTraits = botTraits,
    nodes    = nodes,
    chips    = chips,
    lostNames  = lostNames,
    lostTypes  = lostTypes,
    lostTraits = lostTraits,
    lostFacts  = lostFacts,
    story    = Save.storySnapshot(),
    rallyX   = w.rallyX,
    rallyY   = w.rallyY,
    stats    = { st.planted or 0, st.lost or 0, st.botsLost or 0,
                 st.botsBuilt or 0, st.killed or 0, st.cobaltMined or 0,
                 st.rescued or 0 },
  }
end

-------------------------------------------------------------------- the story
-- What the director has to remember across a save, and nothing more.
--
-- A resumed run used to have no story at all: game.lua only called
-- Story.begin on a new one, so Story.world stayed nil and every beat, hint,
-- reaction and epitaph in the rest of the run was silently dropped. Calling
-- it on a resume is half the fix; this is the other half, because a director
-- that takes over a cycle-6 island with a blank memory replays the prologue's
-- successors -- the first-bot scene, the first-loss scene, WALK over the head
-- of a player who has been walking for ten minutes.
--
-- Sorted, so two saves of the same state are the same bytes.
local function sortedKeys(t)
  local out = {}
  if type(t) ~= "table" then return out end
  for k, v in pairs(t) do
    if v and type(k) == "string" then out[#out + 1] = k end
  end
  table.sort(out)
  return out
end

function Save.storySnapshot()
  if type(Story) ~= "table" or type(Story.fired) ~= "table" then return nil end
  local tut = Story.tut or {}
  local epNames, epTexts = {}, {}
  for _, name in ipairs(sortedKeys(Story.epitaphs)) do
    epNames[#epNames + 1] = name
    epTexts[#epTexts + 1] = tostring(Story.epitaphs[name])
  end
  local shown, shownN = {}, {}
  for _, id in ipairs(sortedKeys(tut.shown)) do
    shown[#shown + 1] = id
    shownN[#shownN + 1] = tut.shown[id]
  end
  return {
    fired    = sortedKeys(Story.fired),   -- beats that must never play again
    did      = sortedKeys(Story.did),     -- verbs the player has performed
    tutDone  = sortedKeys(tut.doneIds),   -- hints they no longer need
    tutShown = shown, tutShownN = shownN, -- and how often each was offered
    epNames  = epNames, epTexts = epTexts,
  }
end

--- Put that memory back, after Story.begin has taken over the restored world.
--- Returns a small summary so the caller can print what came back.
function Save.restoreStory(d, world)
  local sd = d and d.story
  if type(Story) ~= "table" or type(Story.fired) ~= "table" or type(sd) ~= "table" then
    return { beats = 0, epitaphs = 0, hints = 0 }
  end
  local function mark(dst, list)
    if type(dst) ~= "table" or type(list) ~= "table" then return 0 end
    for i = 1, #list do dst[list[i]] = true end
    return #list
  end
  local beats = mark(Story.fired, sd.fired)
  mark(Story.did, sd.did)
  local tut = Story.tut or {}
  local hints = mark(tut.doneIds, sd.tutDone)
  if type(tut.shown) == "table" and type(sd.tutShown) == "table" then
    for i = 1, #sd.tutShown do tut.shown[sd.tutShown[i]] = sd.tutShownN[i] or 1 end
  end
  local eps = 0
  if type(sd.epNames) == "table" and type(Story.epitaphs) == "table" then
    for i = 1, #sd.epNames do
      local t = sd.epTexts and sd.epTexts[i]
      if t then Story.epitaphs[sd.epNames[i]] = t eps = eps + 1 end
    end
  end
  -- The one beat with no second chance. "question" is armed by phase:day at
  -- cycle 5+, and a save is written between the cycle turning and that signal
  -- -- so resuming into the back half skipped it, and if the resume is into
  -- the last cycle the next phase:day is the extraction and it is gone.
  if world and (world.cycle or 1) >= 5 and not Story.fired.question and Story.queue then
    Story.queue("question", {})
  end
  return { beats = beats, epitaphs = eps, hints = hints }
end

--------------------------------------------------------------------- the file
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
    "  lostNames = " .. strs(d.lostNames) .. ",",
    "  lostTypes = " .. strs(d.lostTypes) .. ",",
    "  lostTraits = " .. strs(d.lostTraits) .. ",",
    "  lostFacts = " .. flat(d.lostFacts) .. ",",
    "  botTypes = " .. strs(d.botTypes) .. ",",
    "  botNames = " .. strs(d.botNames) .. ",",
    "  botTraits = " .. strs(d.botTraits) .. ",",
    "  bots = " .. flat(d.bots) .. ",",
    "  nodes = " .. flat(d.nodes) .. ",",
    "  trees = " .. flat(d.trees) .. ",",
  }
  if d.rallyX and d.rallyY then
    o[#o + 1] = "  rallyX = " .. num(d.rallyX) .. ", rallyY = " .. num(d.rallyY) .. ","
  end
  local sd = d.story
  if sd then
    o[#o + 1] = "  story = {"
    o[#o + 1] = "    fired = " .. strs(sd.fired) .. ","
    o[#o + 1] = "    did = " .. strs(sd.did) .. ","
    o[#o + 1] = "    tutDone = " .. strs(sd.tutDone) .. ","
    o[#o + 1] = "    tutShown = " .. strs(sd.tutShown) .. ","
    o[#o + 1] = "    tutShownN = " .. flat(sd.tutShownN) .. ","
    o[#o + 1] = "    epNames = " .. strs(sd.epNames) .. ","
    o[#o + 1] = "    epTexts = " .. strs(sd.epTexts) .. ","
    o[#o + 1] = "  },"
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
                       d.cycle or 1, math.floor(#d.trees / Save.TREE_STRIDE),
                       math.floor(#d.bots / Save.BOT_STRIDE))
end

function Save.clear()
  Save.cached = false
  if love and love.filesystem and love.filesystem.getInfo(Save.FILE) then
    pcall(love.filesystem.remove, Save.FILE)
  end
end

return Save
