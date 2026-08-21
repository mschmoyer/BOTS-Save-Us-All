-- Placeholder scene: proves the engine boots. Replaced by the title screen.
local P = require("src.engine.palette")
local Input = require("src.engine.input")
local S = { t = 0 }

function S:update(dt) self.t = self.t + dt end

function S:draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(P.black)
  love.graphics.setColor(P.accent)
  love.graphics.circle("fill", w / 2, h / 2, 60 + math.sin(self.t * 2) * 8)
  love.graphics.setColor(P.ink)
  love.graphics.print("REFOREST engine online  |  scheme: " .. Input.schemeName(), 30, 30)
end

return S
