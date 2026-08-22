-- Every line a bot says in a scripted beat, against every ambient pool.
-- names.lua's header rule: no ambient line may be a line a bot says in a beat.
--
-- Three checks, two of them hard gates:
--
--   COLLISION  a pool line is byte-identical (lowercased) to a BOT's scripted
--              line. Hearing a cutscene's line from a passing harvester an hour
--              early spends the cutscene. Hard fail.
--   DUPLICATE  the same sentence in two pools -- one string reading as two
--              unrelated situations. Hard fail. This used to scan N.chatter
--              only, so it reported a clean pass while "again" sat in both
--              chatter.hurt and trait.quiet.day and the player could not tell
--              whether a machine had just been hit or just planted a tree.
--   NEAR       a pool line that is mostly a scripted line, the HUMAN's included.
--              Advisory: human lines are capitalised full sentences and the
--              pools are lowercase fragments, so nothing here can be an exact
--              match and a threshold is a judgement call, not a rule. This is
--              how failed's "it is taking it back" lived next to the human's
--              "It is taking the air back." for a whole pass. Warns, never fails.
package.path = "./?.lua;" .. package.path
local Script = require("src.game.script")
local N      = require("src.game.names")
local TU     = require("src.game.tuning")

local BOT_WHO   = { botA = true, botB = true }
local HUMAN_WHO = { human = true }

-- Benign shared templates. "%d" is the count substitution and is meant to be in
-- the dawn pool and in the counter's; it is a format, not a sentence.
local DUP_OK = { ["%d"] = true }

local scripted, human, order = {}, {}, {}
for id, beat in pairs(Script.beats) do
  for _, st in ipairs(beat.steps or {}) do
    if st.kind == "line" and type(st.text) == "string" and st.text ~= "" then
      if BOT_WHO[st.who] then
        local t = st.text:lower()
        if not scripted[t] then scripted[t] = id; order[#order+1] = t end
      elseif HUMAN_WHO[st.who] then
        human[#human+1] = { text = st.text, beat = id }
      end
    end
  end
end
if Script.credits and Script.credits.quiet then
  local t = Script.credits.quiet:lower()
  if not scripted[t] then scripted[t] = "ending/quiet"; order[#order+1] = t end
end

------------------------------------------------------------------ near-misses
--- Words, lowercased, punctuation gone. "It is taking the air back." and
--- "it is taking it back" have to arrive here as comparable token lists.
local function words(s)
  local out = {}
  for w in s:lower():gmatch("[%a%d']+") do out[#out+1] = w end
  return out
end

--- Length of the longest common subsequence of two word lists. Subsequence and
--- not substring: the whole point is to see through an inserted word or two.
local function lcs(a, b)
  local prev = {}
  for j = 0, #b do prev[j] = 0 end
  for i = 1, #a do
    local cur = { [0] = 0 }
    for j = 1, #b do
      if a[i] == b[j] then cur[j] = prev[j - 1] + 1
      else cur[j] = math.max(prev[j], cur[j - 1]) end
    end
    prev = cur
  end
  return prev[#b]
end

-- Tuned against the pools as they stand: 0.70 catches the "taking it back" shape
-- and leaves the ordinary overlap of a small shared vocabulary alone. Short
-- lines are exempt -- at three words "i am up" matches half the script.
local NEAR_RATIO, NEAR_MIN = 0.70, 4
local nears = 0
local scriptedList = {}
for _, t in ipairs(order) do scriptedList[#scriptedList+1] = { text = t, beat = scripted[t], who = "bot" } end
for _, h in ipairs(human) do scriptedList[#scriptedList+1] = { text = h.text, beat = h.beat, who = "human" } end
for i = 1, #scriptedList do scriptedList[i].w = words(scriptedList[i].text) end

local function near(label, line)
  local lw = words(line)
  if #lw < NEAR_MIN then return end
  for i = 1, #scriptedList do
    local s = scriptedList[i]
    local m = lcs(lw, s.w)
    if m >= NEAR_MIN and m / #lw >= NEAR_RATIO then
      print(("NEAR       %-22s %q\n           ~ %s %q  (beat: %s)")
            :format(label, line, s.who, s.text, s.beat))
      nears = nears + 1
      return
    end
  end
end

--------------------------------------------------------------------- the scans
local fail = 0
local function scan(label, pool)
  for _, line in ipairs(pool) do
    local t = line:lower()
    if scripted[t] then
      print(("COLLISION  %-22s %-14s %q  (beat: %s)")
            :format(label, "", line, scripted[t])); fail = fail + 1
    end
    near(label, line)
  end
end

-- ...and no exact duplicate across two pools, which is the same bug wearing a
-- different hat: one sentence reading as two different situations.
local seen, dupes = {}, 0
local function dup(label, pool)
  for _, line in ipairs(pool) do
    if DUP_OK[line] then                                                  -- skip
    elseif seen[line] then
      print(("DUPLICATE  %q  in %s and %s"):format(line, seen[line], label))
      dupes = dupes + 1
    else seen[line] = label end
  end
end

--- Every pool in the file, shared and private, in one list, so a check added
--- to one of them cannot quietly skip the other half. The trait pools not being
--- in the duplicate pass is the exact hole this closes.
local all = {}
for name, pool in pairs(N.chatter) do all[#all+1] = { "chatter." .. name, pool } end
for tid, byPhase in pairs(N.traitLines) do
  for ph, pool in pairs(byPhase) do all[#all+1] = { "trait." .. tid .. "." .. ph, pool } end
end
table.sort(all, function(a, b) return a[1] < b[1] end)
for _, e in ipairs(all) do scan(e[1], e[2]) dup(e[1], e[2]) end

------------------------------------------------------------- the spelled seven
-- `lastnight` contains "we counted seven", which is the only line in names.lua
-- that states a tuning constant in words. tuning.lua is free to move
-- T.cycle.count and nothing else in the codebase would notice this going wrong.
local NUMWORD = { one = 1, two = 2, three = 3, four = 4, five = 5, six = 6,
                  seven = 7, eight = 8, nine = 9, ten = 10, eleven = 11,
                  twelve = 12 }
local counted, stale = 0, 0
for _, line in ipairs(N.chatter.lastnight or {}) do
  for w in line:lower():gmatch("%a+") do
    local n = NUMWORD[w]
    -- "one more night" is a quantity, not a cycle count; only the line that
    -- says it counted them is claiming to know how many there were.
    if n and line:find("count") then
      counted = counted + 1
      if n ~= TU.cycle.count then
        print(("STALE      chatter.lastnight %q says %d, T.cycle.count is %d")
              :format(line, n, TU.cycle.count))
        stale = stale + 1
      end
    end
  end
end

print(("checked %d scripted bot lines + %d human lines against %d pools: "
       .. "%d collisions, %d cross-pool duplicates, %d near-misses (advisory), "
       .. "%d/%d cycle-count claim(s) stale")
      :format(#order, #human, #all, fail, dupes, nears, stale, counted))
os.exit(fail == 0 and dupes == 0 and stale == 0 and 0 or 1)
