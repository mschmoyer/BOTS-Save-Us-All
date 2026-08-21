-- The rig finished the job. Short, quiet, and not a punishment screen.
local U      = require("src.core.util")
local P      = require("src.engine.palette")
local Screen = require("src.engine.screen")
local Input  = require("src.engine.input")
local Opt    = require("src.core.optional")
local Text   = Opt.require("src.engine.text")
local Music  = Opt.require("src.engine.music")

local S = {}

function S:enter(world)
  self.world = world
  self.t = 0
  if Music.setState then Music.setState("ending") end
end

function S:update(dt)
  self.t = self.t + dt
  if self.t > 3.5 and (Input.pressed("confirm") or Input.pressed("back")) then
    Screen.transition(0.8, function() Screen.switch(require("src.scenes.title")) end)
  end
end

local function line(str, y, size, color, alpha)
  local w = love.graphics.getWidth()
  if Text.display then
    Text.display(str, w / 2, y, size, { align = "center", color = color, alpha = alpha,
                                        tracking = 0.16 })
  else
    love.graphics.setColor(color[1], color[2], color[3], alpha)
    love.graphics.printf(str, 0, y, w, "center")
  end
end

function S:draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(P.black)

  local a1 = U.smoothstep(0.4, 2.2, self.t)
  local a2 = U.smoothstep(2.6, 4.4, self.t)
  local a3 = U.smoothstep(5.0, 6.6, self.t)

  line("THE AIR IS GONE", h * 0.36, 46, P.ink, a1)
  line("They took what you grew.", h * 0.46, 20, P.inkDim, a2)

  local st = self.world and self.world.stats
  if st and a3 > 0 then
    local trees = self.world.stats.planted
    local lost = #(self.world.allLostNames or {})
    line(string.format("%d TREES PLANTED   %d NEVER CAME BACK", trees, lost),
         h * 0.60, 15, P.inkFaint, a3)
    line("The island is still there.", h * 0.68, 17, P.accent, a3 * 0.9)
  end

  if self.t > 3.5 then
    local pulse = 0.55 + math.sin(self.t * 2.2) * 0.25
    line(Input.glyph("confirm") .. "   BEGIN AGAIN", h * 0.84, 14, P.inkDim, pulse)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return S
