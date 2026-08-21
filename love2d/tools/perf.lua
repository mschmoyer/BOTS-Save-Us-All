-- Frame profiler for the Reforest build.
--
-- Not part of the game and not shipped: `tools/` is excluded from the .love the
-- web build packages, so nothing in here can reach a player.
--
-- HOW IT WORKS
--   Every interesting pass is a function on a module, so the profiler
--   monkey-patches those functions once at scene entry and accumulates, per
--   frame, (a) wall time spent inside them and (b) the number of GPU draw calls
--   they issued (`love.graphics.getStats`, which is exact and identical on any
--   backend -- unlike wall time under llvmpipe or SwiftShader).
--
--   Per-tree entry points (drawShadow/draw/drawCanopyLight) are called hundreds
--   of times a frame, so they get a cheap accumulating wrapper and their own
--   call counter; the harness prints its own overhead so you can subtract it.
--
-- USAGE
--   BOTS_SCENE=tools.perfscene BOTS_PERF_FRAMES=240 tools/perf.sh
local Perf = {}

local getTime = love.timer.getTime
local getStats = love.graphics.getStats

local ORDER = {
  "sim", "terrain", "water", "decals",
  "treeShadow", "treeDraw", "treeRim",
  "entities", "vfxUpdate", "vfxDraw", "lights", "post", "hud", "worldDraw",
  "frame",
}

local acc, calls, dcalls = {}, {}, {}
local sum, sumCalls, sumDc = {}, {}, {}
local frames = 0
local statsA, statsB = {}, {}
local countDraws = true

for i = 1, #ORDER do
  local k = ORDER[i]
  acc[k], calls[k], dcalls[k] = 0, 0, 0
  sum[k], sumCalls[k], sumDc[k] = 0, 0, 0
end

--- Wrap `tbl[name]` so that time and draw calls land in bucket `key`.
local function wrap(tbl, name, key)
  local fn = tbl and tbl[name]
  if type(fn) ~= "function" then return false end
  tbl[name] = function(...)
    local d0 = 0
    if countDraws then getStats(statsA) d0 = statsA.drawcalls end
    local t0 = getTime()
    local a, b, c = fn(...)
    acc[key] = acc[key] + (getTime() - t0)
    calls[key] = calls[key] + 1
    if countDraws then getStats(statsB) dcalls[key] = dcalls[key] + (statsB.drawcalls - d0) end
    return a, b, c
  end
  return true
end
Perf.wrap = wrap

--- Blank out every GPU-submitting entry point so a run measures Lua and LOVE
--- binding cost only. Absolute GPU time under llvmpipe/SwiftShader is
--- meaningless; the Lua half is not, and in the browser it is interpreted Lua
--- (love.js has no JIT), so it is the half that scales worst.
local function nullGpu()
  local g = love.graphics
  local noop = function() end
  for _, n in ipairs({ "draw", "circle", "ellipse", "polygon", "rectangle", "line",
                       "print", "printf", "points", "arc", "clear", "drawInstanced",
                       "drawLayer" }) do
    if g[n] then g[n] = noop end
  end
  -- Shader:send goes through the userdata metatable
  local ok, sh = pcall(g.newShader, "vec4 effect(vec4 c, Image t, vec2 u, vec2 s){return c;}")
  if ok and sh then
    local mt = debug.getmetatable(sh)
    if mt and mt.__index then
      mt.__index.send = noop
      mt.__index.sendColor = noop
    end
  end
  local okb, b = pcall(g.newSpriteBatch, g.newCanvas(4, 4), 8)
  if okb and b then
    local mt = debug.getmetatable(b)
    if mt and mt.__index then mt.__index.add = noop mt.__index.set = noop end
  end
end

local installed = false
local missing = {}

function Perf.install(opts)
  if installed then return end
  installed = true
  -- The browser build has no JIT: love.js is PUC Lua 5.1 compiled to wasm.
  -- Turning LuaJIT's compiler off leaves its interpreter, which is the closest
  -- native proxy for how the Lua half of a frame actually costs in a browser.
  if opts and opts.noJit then
    local ok, jit = pcall(require, "jit")
    if ok and jit and jit.off then jit.off(true, true) jit.flush() print("PERF,jit,off") end
  end
  countDraws = not (opts and opts.noDrawCounts)
  if opts and opts.nullGpu then nullGpu() countDraws = false end

  local function need(mod, name, key)
    local ok, m = pcall(require, mod)
    if not ok or not wrap(m, name, key) then missing[#missing + 1] = mod .. "." .. name end
  end

  need("src.world.world",     "update",          "sim")
  need("src.world.world",     "draw",            "worldDraw")
  need("src.world.terrain",   "draw",            "terrain")
  need("src.world.terrain",   "drawOverlay",     "terrain")
  need("src.world.water",     "draw",            "water")
  need("src.engine.decals",   "draw",            "decals")
  need("src.entities.tree",   "drawShadow",      "treeShadow")
  need("src.entities.tree",   "draw",            "treeDraw")
  need("src.entities.tree",   "drawCanopyLight", "treeRim")
  need("src.engine.vfx",      "update",          "vfxUpdate")
  need("src.engine.vfx",      "draw",            "vfxDraw")
  need("src.engine.lighting", "finish",          "lights")
  need("src.engine.postfx",   "render",          "post")
  need("src.game.hud",        "draw",            "hud")
  -- every mobile entity that draws itself, as one "entities" bucket
  for _, m in ipairs({ "src.entities.bot", "src.entities.enemy", "src.entities.player",
                       "src.entities.cobalt", "src.entities.projectile",
                       "src.entities.homerig", "src.entities.boss" }) do
    local ok, M = pcall(require, m)
    if ok then wrap(M, "draw", "entities") wrap(M, "drawShadow", "entities") end
  end
  if #missing > 0 then print("PERF,missing," .. table.concat(missing, " ")) end

  -- Ablations. Removing one pass and re-running is the only reliable way to
  -- attribute *fill* cost: a software rasteriser defers work, so the wall time
  -- inside a pass lands on whichever later call happens to force the flush.
  local ab = opts and opts.ablate
  if ab and ab ~= "" then
    local noop = function() end
    local set = {}
    for k in string.gmatch(ab, "[^,]+") do set[k] = true end
    local Tree = require("src.entities.tree")
    if set.rim    then Tree.drawCanopyLight = noop end
    if set.shadow then Tree.drawShadow = noop end
    if set.trees  then Tree.draw = noop Tree.drawShadow = noop Tree.drawCanopyLight = noop end
    if set.leaves then Tree.drawLeaves = noop end
    if set.post   then require("src.engine.postfx").render = noop end
    if set.bloom  then require("src.engine.postfx").settings.bloom = false end
    if set.lights then require("src.engine.lighting").finish = noop end
    if set.hud    then require("src.game.hud").draw = noop end
    if set.vfx    then require("src.engine.vfx").draw = noop end
    if set.decals then require("src.engine.decals").draw = noop end
    if set.water  then require("src.world.water").draw = noop end
    if set.terrain then local T = require("src.world.terrain") T.draw = noop T.drawOverlay = noop end
    if set.boss then require("src.entities.boss").draw = noop end
    if set.entities then
      for _, m in ipairs({ "src.entities.bot", "src.entities.enemy", "src.entities.player",
                           "src.entities.cobalt", "src.entities.projectile",
                           "src.entities.homerig", "src.entities.boss" }) do
        local ok, M = pcall(require, m)
        if ok then M.draw = noop M.drawShadow = noop end
      end
    end
    print("PERF,ablate," .. ab)
  end
end

------------------------------------------------------------------ frame hooks
local frameT0 = 0
local warm = 0
Perf.warmup = 60

function Perf.beginFrame()
  for i = 1, #ORDER do
    local k = ORDER[i]
    acc[k], calls[k], dcalls[k] = 0, 0, 0
  end
  frameT0 = getTime()
end

function Perf.endFrame()
  acc.frame = getTime() - frameT0
  calls.frame = 1
  -- LOVE resets the stats counters at present(), so this is the whole frame
  getStats(statsB)
  dcalls.frame = statsB.drawcalls
  Perf.lastCanvasSwitches = statsB.canvasswitches
  Perf.lastShaderSwitches = statsB.shaderswitches
  Perf.lastBatched = statsB.drawcallsbatched
  warm = warm + 1
  if warm <= Perf.warmup then return end
  frames = frames + 1
  for i = 1, #ORDER do
    local k = ORDER[i]
    sum[k] = sum[k] + acc[k]
    sumCalls[k] = sumCalls[k] + calls[k]
    sumDc[k] = sumDc[k] + dcalls[k]
  end
end

function Perf.frames() return frames end

--- CSV to stdout: one header, one row per bucket, one TOTALS row.
--- `sim` and `worldDraw` are containers; the rows under them are their parts.
local TOP = { "sim", "worldDraw", "lights", "post", "hud" }
local INWORLD = { "terrain", "water", "decals", "treeShadow", "treeDraw",
                  "treeRim", "entities", "vfxDraw" }
function Perf.report(tag, extra)
  if frames == 0 then print("PERF,no frames") return end
  local function row(k, ms, pct, c, d)
    print(string.format("PERF,%s,%s,%.3f,%.1f,%.1f,%.1f", tag, k, ms, pct, c, d))
  end
  local total = sum.frame
  local function ms(k) return sum[k] / frames * 1000 end
  local function pct(k) return total > 0 and (sum[k] / total * 100) or 0 end
  print("PERFHDR,tag,pass,ms_per_frame,pct_of_frame,calls_per_frame,drawcalls_per_frame")
  row("FRAME", ms("frame"), 100, 1, sumDc.frame / frames)
  local topSum = 0
  for i = 1, #TOP do
    local k = TOP[i]
    topSum = topSum + sum[k]
    row(k, ms(k), pct(k), sumCalls[k] / frames, sumDc[k] / frames)
  end
  row("  sim.vfxUpdate", ms("vfxUpdate"), pct("vfxUpdate"), sumCalls.vfxUpdate / frames, 0)
  local wSum = 0
  for i = 1, #INWORLD do
    local k = INWORLD[i]
    wSum = wSum + sum[k]
    row("  world." .. k, ms(k), pct(k), sumCalls[k] / frames, sumDc[k] / frames)
  end
  row("  world.sortEtc", (sum.worldDraw - wSum) / frames * 1000,
      total > 0 and ((sum.worldDraw - wSum) / total * 100) or 0, 0, 0)
  row("OTHER", (total - topSum) / frames * 1000,
      total > 0 and ((total - topSum) / total * 100) or 0, 0, 0)
  print(string.format("PERFSUM,%s,frames=%d,ms=%.3f,fps=%.1f,drawcalls=%.0f%s", tag, frames,
    total / frames * 1000, frames / total, sumDc.frame / frames,
    extra and ("," .. extra) or ""))
end

return Perf
