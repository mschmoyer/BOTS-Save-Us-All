local P = require("src.engine.palette")
local Screen = require("src.engine.screen")
local Input = require("src.engine.input")
local S = {}
function S:enter(game) self.game = game end
S.updateWhenCovered = false
function S:update(dt)
  if Input.pressed("pause") or Input.pressed("back") then Screen.pop() end
end
function S:drawOverlay()
  local w, h = love.graphics.getDimensions()
  love.graphics.setColor(P.black[1], P.black[2], P.black[3], 0.6)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(P.ink)
  love.graphics.printf("PAUSED", 0, h / 2 - 10, w, "center")
  love.graphics.setColor(1, 1, 1, 1)
end
return S
