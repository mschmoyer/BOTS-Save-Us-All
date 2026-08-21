-- Placeholder title; replaced by the UI pass.
local P = require("src.engine.palette")
local Screen = require("src.engine.screen")
local Input = require("src.engine.input")
local S = { t = 0 }
function S:enter() self.t = 0 end
function S:update(dt)
  self.t = self.t + dt
  if self.t > 0.4 and (Input.pressed("confirm") or Input.pressed("dash")) then
    Screen.transition(0.5, function() Screen.switch(require("src.scenes.game")) end)
  end
end
function S:draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(P.black)
  love.graphics.setColor(P.ink)
  love.graphics.printf("BOTS: SAVE US ALL", 0, h / 2 - 40, w, "center")
  love.graphics.setColor(P.accent)
  love.graphics.printf("REFOREST", 0, h / 2 - 14, w, "center")
  love.graphics.setColor(P.inkDim)
  love.graphics.printf("PRESS " .. Input.glyph("confirm"), 0, h / 2 + 40, w, "center")
  love.graphics.setColor(1, 1, 1, 1)
end
return S
