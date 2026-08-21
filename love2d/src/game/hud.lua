-- Minimal functional HUD. Replaced by the UI pass; exists so the game is playable.
local U   = require("src.core.util")
local P   = require("src.engine.palette")
local Opt = require("src.core.optional")
local TU  = require("src.game.tuning")
local Input = require("src.engine.input")
local Draw = Opt.require("src.engine.draw")
local Text = Opt.require("src.engine.text")

local HUD = {}

function HUD.init(world) HUD.world = world end
function HUD.update(dt, world) end

function HUD.draw(w, cam)
  local sw, sh = love.graphics.getDimensions()
  local g = love.graphics

  -- oxygen bar
  local bw, bh = sw * 0.4, 10
  local bx, by = (sw - bw) / 2, 26
  g.setColor(P.black[1], P.black[2], P.black[3], 0.45)
  g.rectangle("fill", bx, by, bw, bh, 5)
  g.setColor(P.o2)
  g.rectangle("fill", bx, by, bw * U.saturate(w.o2 / TU.o2.target), bh, 5)
  g.setColor(P.ink)
  g.print(string.format("OXYGEN %.1f%%", w.o2), bx, by + 16)

  -- cobalt + trees
  g.setColor(P.ramp.cobalt[4])
  g.print("COBALT " .. w.cobalt, 24, 24)
  g.setColor(P.ramp.leaf[4])
  g.print("TREES " .. w.treeCount, 24, 42)
  g.setColor(P.ink)
  g.print(string.format("CYCLE %d  %s  %ds", w.cycle, string.upper(w.phase),
          math.max(0, w.phaseDur - w.phaseT)), 24, 60)

  -- hearts
  local p = w.player
  for i = 1, p.maxHp do
    g.setColor(i <= p.hp and P.danger or P.inkFaint)
    g.circle("fill", 30 + (i - 1) * 18, 92, 6)
  end

  -- build bar
  local n = #TU.bots.order
  local cw = 108
  local total = n * cw
  local x0 = (sw - total) / 2
  for i = 1, n do
    local id = TU.bots.order[i]
    local def = TU.bots[id]
    local x = x0 + (i - 1) * cw
    local afford = w.cobalt >= def.cost
    g.setColor(P.black[1], P.black[2], P.black[3], 0.5)
    g.rectangle("fill", x, sh - 68, cw - 8, 54, 6)
    g.setColor(afford and P.ink or P.inkFaint)
    g.print(i .. "  " .. def.label, x + 8, sh - 60)
    g.setColor(afford and P.ramp.cobalt[4] or P.inkFaint)
    g.print(def.cost, x + 8, sh - 42)
  end
  g.setColor(1, 1, 1, 1)
end

return HUD
