-- Placeholder dawn draft; replaced by the UI pass.
local P = require("src.engine.palette")
local Screen = require("src.engine.screen")
local Input = require("src.engine.input")
local U = require("src.core.util")
local S = {}
function S:enter(world, report)
  self.world, self.report = world, report
  self.offers = world.chips:draft(world.rng, 3, world.cycle)
  self.sel = 1
end
function S:update(dt)
  if Input.pressed("cycleL") then self.sel = math.max(1, self.sel - 1) end
  if Input.pressed("cycleR") then self.sel = math.min(#self.offers, self.sel + 1) end
  for i = 1, 3 do if Input.pressed("build" .. i) then self.sel = math.min(i, #self.offers) end end
  if Input.pressed("confirm") then
    self.world.chips:add(self.offers[self.sel])
    self.world:setPhase("day")
    Screen.pop()
  end
end
function S:drawOverlay()
  local w, h = love.graphics.getDimensions()
  love.graphics.setColor(P.black[1], P.black[2], P.black[3], 0.75)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(P.ink)
  love.graphics.printf("DAWN", 0, 60, w, "center")
  for i, c in ipairs(self.offers) do
    local x = w / 2 - 340 + (i - 1) * 230
    love.graphics.setColor(i == self.sel and P.accent or P.inkFaint)
    love.graphics.rectangle("line", x, h / 2 - 110, 210, 220, 8)
    love.graphics.setColor(P.ink)
    love.graphics.printf(c.name, x + 10, h / 2 - 90, 190, "center")
    love.graphics.printf(c.desc, x + 10, h / 2 - 50, 190, "center")
  end
  love.graphics.setColor(1, 1, 1, 1)
end
return S
