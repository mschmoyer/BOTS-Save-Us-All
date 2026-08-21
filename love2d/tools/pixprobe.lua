-- TEMPORARY deterministic capture probe for item F5.
--
-- The autoplay capture is NOT a valid pixel A/B: two runs of identical code
-- differ on 96% of pixels by +/-1 because the grade reads the wall clock.
-- This scene is the game with the clock nailed to the frame counter, so two
-- runs of the same code are byte-identical and a real difference shows up as
-- a real difference.
local Game = require("src.scenes.game")

local S = setmetatable({}, { __index = Game })
local frame = 0
local FIXED = 1 / 60

love.timer.getTime = function() return frame * FIXED end
love.timer.getDelta = function() return FIXED end
love.timer.getFPS = function() return 60 end

function S:update(dt, realDt)
  frame = frame + 1
  return Game.update(self, FIXED, FIXED)
end

return S
