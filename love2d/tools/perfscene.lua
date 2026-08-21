-- The game scene with the frame profiler bolted on. `BOTS_SCENE=tools.perfscene`.
local Game = require("src.scenes.game")
local Perf = require("tools.perf")

local cfg = _G.BOTS_CFG or function(n)
  local v = os.getenv(n)
  return (v ~= nil and v ~= "") and v or nil
end

local S = setmetatable({}, { __index = Game })
S.reported = false

function S:enter(...)
  Perf.warmup = tonumber(cfg("BOTS_PERF_WARM") or "") or 60
  Perf.install({ noDrawCounts = cfg("BOTS_PERF_NODC") ~= nil,
                 nullGpu = cfg("BOTS_PERF_NULLGPU") ~= nil,
                 keepSend = cfg("BOTS_PERF_KEEPSEND") ~= nil,
                 ablate = cfg("BOTS_PERF_ABLATE"),
                 noJit = cfg("BOTS_PERF_NOJIT") ~= nil,
                 fill = cfg("BOTS_PERF_FILL") ~= nil })
  local r = Game.enter(self, ...)
  self.tag = cfg("BOTS_PERF_TAG") or "run"
  self.stopAt = tonumber(cfg("BOTS_PERF_FRAMES") or "") or 240
  return r
end

function S:update(dt, realDt)
  Perf.beginFrame()
  return Game.update(self, dt, realDt)
end

function S:draw()
  Game.draw(self)
  Perf.endFrame()
  if not self.reported and Perf.frames() >= self.stopAt then
    self.reported = true
    local w = self.world
    -- item F6: how often the sprite-atlas page had to be re-baked over the run,
    -- and what the driver actually gave us for it. Both are zero/absent when
    -- the atlas is off, which is the default.
    local Tree = require("src.entities.tree")
    if Tree.atlasStats then
      local a = Tree.atlasStats()
      print(string.format("PERFATLAS,%s,on=%s,ready=%s,fmt=%s,page=%dx%d,shadowpage=%dx%d,cell=%dx%d,px=%g,rebuilds=%d,lastbuild_ms=%.1f",
        self.tag, tostring(a.on), tostring(a.ready), tostring(a.format),
        a.page or 0, a.pageH or 0, a.spage or 0, a.spageH or 0,
        a.cell or 0, a.cellH or 0, a.pixels or 0, a.rebuilds or 0, a.buildMs or 0))
    end
    Perf.report(self.tag, string.format("trees=%d,bots=%d,blight=%d,parts=%d,phase=%s,cs=%d,ss=%d,batched=%d",
      w.treeCount, #w.bots, #w.enemies,
      (require("src.engine.vfx").count and require("src.engine.vfx").count()) or 0,
      tostring(w.phase), Perf.lastCanvasSwitches or 0, Perf.lastShaderSwitches or 0,
      Perf.lastBatched or 0))
    if cfg("BOTS_PERF_QUIT") then love.event.quit() end
  end
end

return S
