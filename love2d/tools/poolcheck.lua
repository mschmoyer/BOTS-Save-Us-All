-- Every line a bot says in a scripted beat, against every ambient pool.
-- names.lua's header rule: no ambient line may be a line a bot says in a beat.
package.path = "./?.lua;" .. package.path
local Script = require("src.game.script")
local N      = require("src.game.names")

local BOT_WHO = { botA = true, botB = true }
local scripted, order = {}, {}
for id, beat in pairs(Script.beats) do
  for _, st in ipairs(beat.steps or {}) do
    if st.kind == "line" and BOT_WHO[st.who] and type(st.text) == "string"
       and st.text ~= "" then
      local t = st.text:lower()
      if not scripted[t] then scripted[t] = id; order[#order+1] = t end
    end
  end
end
if Script.credits and Script.credits.quiet then
  local t = Script.credits.quiet:lower()
  if not scripted[t] then scripted[t] = "ending/quiet"; order[#order+1] = t end
end

local fail = 0
local function scan(label, pool)
  for _, line in ipairs(pool) do
    local t = line:lower()
    if scripted[t] then
      print(("COLLISION  %-22s %-14s %q  (beat: %s)")
            :format(label, "", line, scripted[t])); fail = fail + 1
    end
  end
end
local pools = 0
for name, pool in pairs(N.chatter) do pools = pools + 1 scan("chatter."..name, pool) end
for tid, byPhase in pairs(N.traitLines) do
  for ph, pool in pairs(byPhase) do pools = pools + 1 scan("trait."..tid.."."..ph, pool) end
end

-- ...and no exact duplicate across two pools, which is the same bug wearing a
-- different hat: one sentence reading as two different situations.
local seen, dupes = {}, 0
local function dup(label, pool)
  for _, line in ipairs(pool) do
    if seen[line] then print(("DUPLICATE  %q  in %s and %s"):format(line, seen[line], label)) dupes = dupes + 1
    else seen[line] = label end
  end
end
for name, pool in pairs(N.chatter) do dup("chatter."..name, pool) end

print(("checked %d scripted bot lines against %d pools: %d collisions, %d cross-pool duplicates")
      :format(#order, pools, fail, dupes))
os.exit(fail == 0 and dupes == 0 and 0 or 1)
