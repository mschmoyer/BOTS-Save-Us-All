-- Temporary: verify the display face renders every letter at several sizes.
local P = require("src.engine.palette")
local Text = require("src.engine.text")
local S = {}
function S:update(dt) end
function S:draw()
  love.graphics.clear(P.black)
  Text.display("ABCDEFGHIJKLM", 40, 40, 56, { color = P.ink })
  Text.display("NOPQRSTUVWXYZ", 40, 110, 56, { color = P.ink })
  Text.display("SAVE US ALL", 40, 190, 84, { color = P.accent })
  Text.display("QUIT UUU JJJ", 40, 290, 84, { color = P.accentCool })
  Text.display("SAVE US ALL", 40, 400, 30, { color = P.ink })
  Text.display("QUIT UUU JJJ", 40, 445, 18, { color = P.ink })
  Text.display("BUILDER REPULSOR", 40, 490, 44, { color = P.warn })
end
return S
