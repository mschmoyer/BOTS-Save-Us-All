-- TEMPORARY probe for PERFORMANCE.md item 7 / spec F5: per-frame allocation.
-- Same shape as tools/perfscene.lua, but the accumulator is
-- collectgarbage("count") rather than wall time, and the collector is stopped
-- for the measured window so nothing is handed back mid-frame.
--   BOTS_SCENE=tools.allocscene tools/alloc.sh
local Game = require("src.scenes.game")

local cfg = _G.BOTS_CFG or function(n)
  local v = os.getenv(n)
  return (v ~= nil and v ~= "") and v or nil
end

local kb = function() return collectgarbage("count") end

local ORDER, acc, calls = {}, {}, {}
local sum, sumCalls = {}, {}
local frames = 0
local warm = 0

local function bucket(k)
  if acc[k] == nil then
    ORDER[#ORDER + 1] = k
    acc[k], calls[k], sum[k], sumCalls[k] = 0, 0, 0, 0
  end
end

local missing = {}
local function wrap(mod, name, key)
  local ok, tbl = pcall(require, mod)
  if not ok or type(tbl) ~= "table" or type(tbl[name]) ~= "function" then
    missing[#missing + 1] = mod .. "." .. name
    return
  end
  bucket(key)
  local fn = tbl[name]
  tbl[name] = function(...)
    local a0 = kb()
    local r1, r2, r3 = fn(...)
    acc[key] = acc[key] + (kb() - a0)
    calls[key] = calls[key] + 1
    return r1, r2, r3
  end
end

local S = setmetatable({}, { __index = Game })
S.reported = false

function S:enter(...)
  if cfg("BOTS_ALLOC_JIT") == nil then
    local ok, jit = pcall(require, "jit")
    if ok and jit and jit.off then jit.off() jit.flush() end
  end

  -- containers first, so a nested bucket is visibly a part of its parent
  wrap("src.world.world", "update", "WORLD:update")
  wrap("src.world.world", "draw", "WORLD:draw")

  wrap("src.world.weather", "update", "  u.weather")
  wrap("src.world.world", "updateOxygen", "  u.oxygen")
  wrap("src.world.world", "updateSpread", "  u.spread")
  wrap("src.world.world", "threat", "  u.threat")
  wrap("src.world.world", "refreshVisibleTrees", "  u.refreshVis")
  wrap("src.world.world", "updateRebellion", "  u.rebellion")
  wrap("src.world.world", "updateReinforcements", "  u.reinforce")
  wrap("src.engine.vfx", "update", "  u.vfx")
  wrap("src.engine.decals", "update", "  u.decals")
  wrap("src.world.wind", "update", "  u.wind")
  wrap("src.game.director", "update", "  u.director")
  wrap("src.entities.tree", "update", "  u.tree*")
  wrap("src.entities.bot", "update", "  u.bot*")
  wrap("src.entities.enemy", "update", "  u.enemy*")
  wrap("src.entities.player", "update", "  u.player")
  wrap("src.entities.homerig", "update", "  u.rig")
  wrap("src.entities.cobalt", "update", "  u.cobalt*")
  wrap("src.entities.projectile", "update", "  u.proj*")

  wrap("src.world.terrain", "draw", "  d.terrain")
  wrap("src.world.terrain", "drawOverlay", "  d.terrainOv")
  wrap("src.world.water", "draw", "  d.water")
  wrap("src.engine.decals", "draw", "  d.decals")
  wrap("src.entities.tree", "draw", "  d.tree*")
  wrap("src.entities.tree", "drawShadow", "  d.treeShadow*")
  wrap("src.engine.vfx", "draw", "  d.vfx")
  wrap("src.world.world", "drawRally", "  d.rally")
  wrap("src.world.world", "drawSpeech", "  d.speech")
  wrap("src.entities.bot", "draw", "  d.bot*")
  wrap("src.entities.bot", "drawShadow", "  d.botShadow*")
  wrap("src.entities.enemy", "draw", "  d.enemy*")
  wrap("src.entities.cobalt", "draw", "  d.cobalt*")
  wrap("src.entities.player", "draw", "  d.player")
  wrap("src.entities.homerig", "draw", "  d.rig")

  -- outside the world entirely
  wrap("src.world.world", "emitLights", "OUT emitLights")
  wrap("src.engine.lighting", "finish", "OUT lighting")
  wrap("src.engine.postfx", "render", "OUT postfx")
  wrap("src.game.hud", "draw", "OUT hud")
  wrap("src.engine.daynight", "update", "OUT daynight")
  wrap("src.core.timer", "update", "OUT timer")
  wrap("src.engine.audio", "update", "OUT audio")
  wrap("src.engine.music", "update", "OUT music")

  if cfg("BOTS_ALLOC_T2") then
    wrap("src.core.spatial", "each", "T2 spatial.each")
    wrap("src.core.spatial", "nearest", "T2 spatial.nearest")
    wrap("src.core.spatial", "query", "T2 spatial.query")
    wrap("src.world.world", "nearestTree", "T2 w.nearestTree")
    wrap("src.world.world", "nearestBot", "T2 w.nearestBot")
    wrap("src.world.world", "nearestDownedBot", "T2 w.nearestDownedBot")
    wrap("src.world.world", "nearestEnemy", "T2 w.nearestEnemy")
    wrap("src.world.world", "nearestCobalt", "T2 w.nearestCobalt")
    wrap("src.world.world", "beaconAt", "T2 w.beaconAt")
    wrap("src.world.world", "beaconBoostAt", "T2 w.beaconBoostAt")
    wrap("src.world.world", "beaconSlowAt", "T2 w.beaconSlowAt")
    wrap("src.world.world", "blightedAt", "T2 w.blightedAt")
    wrap("src.engine.palette", "shade", "T2 P.shade")
    wrap("src.engine.palette", "mix", "T2 P.mix")
    wrap("src.engine.palette", "alpha", "T2 P.alpha")
    wrap("src.engine.palette", "scale", "T2 P.scale")
    wrap("src.engine.palette", "lighten", "T2 P.lighten")
    wrap("src.engine.palette", "darken", "T2 P.darken")
    wrap("src.engine.palette", "hsv", "T2 P.hsv")
    wrap("src.engine.draw", "setColor", "T2 Draw.setColor")
    wrap("src.engine.draw", "glow", "T2 Draw.glow")
    wrap("src.engine.lighting", "addLight", "T2 L.addLight")
    wrap("src.engine.lighting", "addCone", "T2 L.addCone")
  end

  bucket("FRAME.update")
  bucket("FRAME.draw")

  local r = Game.enter(self, ...)
  self.tag = cfg("BOTS_ALLOC_TAG") or "run"
  self.stopAt = tonumber(cfg("BOTS_ALLOC_FRAMES") or "") or 180
  self.warmup = tonumber(cfg("BOTS_ALLOC_WARM") or "") or 60
  if #missing > 0 then print("ALLOC,missing," .. table.concat(missing, " ")) end
  return r
end

function S:update(dt, realDt)
  if warm == self.warmup then collectgarbage("collect") collectgarbage("stop") end
  for i = 1, #ORDER do acc[ORDER[i]], calls[ORDER[i]] = 0, 0 end
  local a0 = kb()
  local r = Game.update(self, dt, realDt)
  acc["FRAME.update"] = kb() - a0
  calls["FRAME.update"] = 1
  return r
end

function S:draw()
  local a0 = kb()
  Game.draw(self)
  acc["FRAME.draw"] = kb() - a0
  calls["FRAME.draw"] = 1

  warm = warm + 1
  if warm > self.warmup then
    frames = frames + 1
    for i = 1, #ORDER do
      local k = ORDER[i]
      sum[k] = sum[k] + acc[k]
      sumCalls[k] = sumCalls[k] + calls[k]
    end
  end
  if not self.reported and frames >= self.stopAt then
    self.reported = true
    local w = self.world
    print("ALLOCHDR,tag,bucket,kb_per_frame,calls_per_frame")
    for i = 1, #ORDER do
      local k = ORDER[i]
      print(string.format("ALLOC,%s,%s,%.3f,%.1f", self.tag, k,
        sum[k] / frames, sumCalls[k] / frames))
    end
    print(string.format("ALLOCSUM,%s,frames=%d,trees=%d,bots=%d,blight=%d,phase=%s,gc=%.0fKB",
      self.tag, frames, w.treeCount, #w.bots, #w.enemies, tostring(w.phase),
      collectgarbage("count")))
    collectgarbage("restart")
    if cfg("BOTS_ALLOC_QUIT") then love.event.quit() end
  end
end

return S
