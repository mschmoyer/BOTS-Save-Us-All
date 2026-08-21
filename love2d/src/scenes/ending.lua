-- Placeholder ending; replaced by the narrative pass.
local P = require("src.engine.palette")
local S = { t = 0 }
function S:enter(world) self.world = world self.t = 0 end
function S:update(dt) self.t = self.t + dt end
function S:draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(P.black)
  love.graphics.setColor(P.ink)
  love.graphics.printf("The world is safe.", 0, h / 2 - 20, w, "center")
  if self.t > 3 then
    love.graphics.setColor(P.inkDim)
    love.graphics.printf("Just me. All alone. Forever.", 0, h / 2 + 10, w, "center")
  end
  love.graphics.setColor(1, 1, 1, 1)
end
return S
