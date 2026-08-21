local P = require("src.engine.palette")
local Lighting = require("src.engine.lighting")
local S = {}
function S:enter()
  local w,h = love.graphics.getDimensions()
  Lighting.init(w,h); Lighting.setQuality(2)
  Lighting.setAmbient(P.white, 0.05)
  Lighting.setLightGain(0.2)
end
function S:draw()
  local g = love.graphics
  g.clear(0.25,0.25,0.25,1)
  Lighting.beginFrame(nil)
  Lighting.addCone(400, 450, 350, P.white, 1.0, 0, math.rad(24), 0)
  Lighting.addCone(1100, 450, 350, P.white, 1.0, math.rad(200), math.rad(50), 0)
  Lighting.addLight(750, 750, 250, P.white, 1.0)
  Lighting.finish()
  g.setColor(1,1,1,1)
  Lighting.debugDraw(0, 0, 0.4)
end
return S
