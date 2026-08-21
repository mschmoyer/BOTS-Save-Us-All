-- Warm-up: build the expensive, seed-dependent half of a run *before* the run
-- starts.
--
-- The island's field generation and the tree mesh library are together about a
-- second of pure Lua under LuaJIT, and closer to twenty in the browser build,
-- which has no JIT. Doing that work inside the scene switch freezes the page
-- on a fully closed iris -- a black screen with no explanation, which is
-- exactly how it got reported. So it happens in two places instead: in small
-- slices while the title screen idles, which is free time the player spends
-- reading the menu, and behind a progress bar for whatever is left when they
-- actually press Begin. Linger on the title and the run starts instantly.
local Terrain = require("src.world.terrain")
local Tree    = require("src.entities.tree")

local Warmup = { seed = nil, terrain = nil, stage = "idle", p = 0 }

--- The seed the next run will use. Picked here rather than in the game scene
--- so the title can warm the right island.
function Warmup.seedFor()
  local cfg = _G.BOTS_CFG or function(n)
    local v = os.getenv(n)
    return (v ~= nil and v ~= "") and v or nil
  end
  return tonumber(cfg("BOTS_SEED") or "") or math.random(1, 999999)
end

--- Idempotent for a seed already in flight, so both the title and the game
--- scene can call it and the second call joins the work in progress.
function Warmup.start(seed)
  if Warmup.seed == seed and Warmup.stage ~= "idle" then return end
  Warmup.seed    = seed
  Warmup.terrain = Terrain.newDeferred(seed)
  Warmup.stage   = "terrain"
  Warmup.p       = 0
  Warmup.spent   = { fields = 0, canvas = 0, trees = 0 }
end

--- Advance by at most `budget` seconds of work. Returns progress 0..1.
--- The inner slices are deliberately shorter than the budget so a caller that
--- wants to stay at 60 fps (the title) can ask for 4 ms and get 4 ms.
function Warmup.pump(budget)
  if Warmup.stage == "idle" or Warmup.stage == "done" then return Warmup.p end
  local t0 = love.timer.getTime()
  local sp = Warmup.spent
  repeat
    local s0 = love.timer.getTime()
    if Warmup.stage == "terrain" then
      local p = Warmup.terrain:bakeStep(0.003)
      -- the terrain coroutine spends its first 34% on the CPU fields and the
      -- rest on canvases; the two run at wildly different speeds in the
      -- browser and it matters which one is the wait
      local bucket = (p < 0.34) and "fields" or "canvas"
      sp[bucket] = sp[bucket] + (love.timer.getTime() - s0)
      Warmup.p = p * 0.74
      if p >= 1 then Warmup.stage = "trees" end
    else
      local p = Tree.prewarmStep(0.003)
      sp.trees = sp.trees + (love.timer.getTime() - s0)
      Warmup.p = 0.74 + p * 0.26
      if p >= 1 then Warmup.stage = "done"; Warmup.p = 1 end
    end
  until Warmup.stage == "done" or love.timer.getTime() - t0 >= (budget or 0.004)
  return Warmup.p
end

--- Where the wait actually went, in milliseconds.
function Warmup.report()
  local sp = Warmup.spent or {}
  return string.format("fields=%.0f canvas=%.0f trees=%.0f",
                       (sp.fields or 0) * 1000, (sp.canvas or 0) * 1000,
                       (sp.trees or 0) * 1000)
end

function Warmup.ready(seed)
  return Warmup.stage == "done" and Warmup.seed == seed
end

--- Hand the finished terrain over and forget it, so the next run rebuilds.
function Warmup.claim(seed)
  if not Warmup.ready(seed) then return nil end
  local t = Warmup.terrain
  Warmup.terrain, Warmup.seed, Warmup.stage, Warmup.p = nil, nil, "idle", 0
  return t
end

function Warmup.label()
  if Warmup.stage == "terrain" then return "shaping the island" end
  if Warmup.stage == "trees"   then return "growing the seed bank" end
  return "ready"
end

return Warmup
