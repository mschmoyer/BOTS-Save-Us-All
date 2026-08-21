-- Warm-up: build the expensive, seed-dependent half of a run *before* the run
-- starts, and keep building the rest of it while the run is already going.
--
-- Measured in the browser build, with prints, because none of this is
-- guessable from the desktop numbers:
--
--     fields = 6.3 s     the island's CPU noise fields
--     canvas = 1.9 s     the ground tile canvases
--     trees  = 26.4 s    the tree mesh library -- a thousand GPU buffers
--
-- Under LuaJIT the three together are about a second, which is why this used
-- to sit inside the scene switch. In the browser it froze the page on a closed
-- iris for half a minute and got reported, correctly, as "I click Begin and it
-- is just black".
--
-- The 26 s turned out to be an artefact of *how* it was sliced. Measured in
-- one uninterrupted burst the same library takes 1.5 s: in the browser build
-- every frame boundary crossed between two newMesh calls costs a pipeline
-- stall, and 3 ms slices meant hundreds of them. So the two halves want
-- opposite treatment:
--
--   * the CPU fields slice freely, and the title screen grinds them down 4 ms
--     at a time while the player reads the menu -- free time, no stalls;
--   * everything that touches the GPU -- the ground canvases, the mesh
--     library -- waits for the loading screen and runs in coarse slices, big
--     enough to amortise the stalls, small enough that the bar still moves.
--
-- The mesh library is baked at build time now (see the note above BAKE_DIR in
-- entities/tree). That takes the tessellation out of `trees` but not the 750
-- newMesh calls the stalls attach to: measured in the browser, one
-- uninterrupted burst goes 2,872 ms to 1,274 ms, so the slicing advice above
-- still holds. `Warmup.report` says how many cells came out of the file, so a
-- bake that was quietly rejected cannot be mistaken for a bake that did not
-- help.
local Terrain = require("src.world.terrain")
local Tree    = require("src.entities.tree")

local Warmup = { seed = nil, terrain = nil, stage = "idle", p = 0, trees = 0 }

local TERRAIN_SHARE = 0.74

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
  Warmup.cpuDone = false
  Warmup.spent   = { fields = 0, canvas = 0, trees = 0 }
end

--- Advance by at most `budget` seconds of work. Returns progress 0..1.
--- The inner slices are deliberately shorter than the budget so a caller that
--- wants to stay at 60 fps (the title, and the game once it is running) can
--- ask for 3 ms and get 3 ms.
--- `cpuOnly` stops at the boundary between the island's fields and its
--- canvases: that is as far as a screen with a frame rate to keep can go.
function Warmup.pump(budget, cpuOnly)
  if Warmup.stage == "idle" or Warmup.stage == "done" then return Warmup.p end
  if cpuOnly and Warmup.cpuDone then return Warmup.p end
  budget = budget or 0.004
  local slice = budget < 0.02 and budget or budget * 0.5
  local t0 = love.timer.getTime()
  local sp = Warmup.spent
  repeat
    local s0 = love.timer.getTime()
    if Warmup.stage == "terrain" then
      local p = Warmup.terrain:bakeStep(slice)
      -- the terrain coroutine spends its first third on the CPU fields and the
      -- rest on canvases; the two run at wildly different speeds in the
      -- browser and it matters which one is the wait
      local bucket = (p < 0.34) and "fields" or "canvas"
      sp[bucket] = sp[bucket] + (love.timer.getTime() - s0)
      -- `baked`, not `p >= 1`. The bake coroutine's last act is to yield 1.0
      -- and only *then* finish, so a slice that ends on that yield reports
      -- complete while the terrain still has a step to run. Natively a slice
      -- swallowed both and this never showed; in the browser each yield is
      -- its own slice, the stage advanced early, and the island was quietly
      -- rebuilt from scratch inside World -- seven seconds, twice the work,
      -- and no symptom but the wait.
      local done = Warmup.terrain.baked
      Warmup.p = (done and 1 or math.min(p, 0.999)) * TERRAIN_SHARE
      if p >= 0.34 then Warmup.cpuDone = true end
      if done then Warmup.stage = "trees" end
      if cpuOnly and Warmup.cpuDone then return Warmup.p end
    else
      Warmup.trees = Tree.prewarmStep(slice)
      sp.trees = sp.trees + (love.timer.getTime() - s0)
      Warmup.p = TERRAIN_SHARE + Warmup.trees * (1 - TERRAIN_SHARE)
      if Warmup.trees >= 1 then Warmup.stage = "done"; Warmup.p = 1 end
    end
  until Warmup.stage == "done" or love.timer.getTime() - t0 >= (budget or 0.004)
  return Warmup.p
end

function Warmup.done() return Warmup.stage == "done" end

--- Hand the finished terrain over and forget it, so the next run rebuilds it.
function Warmup.claim(seed)
  if Warmup.seed ~= seed or not Warmup.terrain or not Warmup.terrain.baked then
    return nil
  end
  local t = Warmup.terrain
  Warmup.terrain = nil
  return t
end

function Warmup.label()
  if Warmup.stage == "terrain" then return "shaping the island" end
  if Warmup.stage == "trees"   then return "growing the seed bank" end
  return "ready"
end

--- A stopwatch for the load path. Nothing about where a browser spends
--- sixteen seconds is guessable from the desktop numbers, so the loading
--- screen keeps its own breakdown and prints it once.
Warmup.marks = {}
function Warmup.mark(name)
  local t = love.timer.getTime()
  Warmup.marks[#Warmup.marks + 1] =
    string.format("%s=%.0f", name, (t - (Warmup.markT or t)) * 1000)
  Warmup.markT = t
end

function Warmup.marksReport()
  local s = table.concat(Warmup.marks, " ")
  Warmup.marks, Warmup.markT = {}, nil
  return s
end

--- Where the wait actually went, in milliseconds.
--- The tree figure carries how many of the 250 library cells came out of the
--- baked file rather than the tessellator, because "trees=90" means two
--- completely different things depending on the answer -- and a bake that was
--- quietly rejected in the browser looks exactly like a bake that was never
--- built until this line says 0/250.
function Warmup.report()
  local sp = Warmup.spent or {}
  local baked, cells = 0, 0
  if Tree.libraryOrigin then baked, cells = Tree.libraryOrigin() end
  return string.format("fields=%.0f canvas=%.0f trees=%.0f[%d/%d baked]",
                       (sp.fields or 0) * 1000, (sp.canvas or 0) * 1000,
                       (sp.trees or 0) * 1000, baked, cells)
end

return Warmup
