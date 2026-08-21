-- Smooth-follow camera with velocity lookahead, deadzone, bounds and juice shake.
local U = require("src.core.util")
local Class = require("src.core.class")
local J = require("src.engine.juice")
local T = require("src.game.tuning").camera

local Camera = Class("Camera")

function Camera:init(w, h)
  self.x, self.y = 0, 0
  self.tx, self.ty = 0, 0
  self.zoom, self.zoomTarget = T.zoom, T.zoom
  self.w, self.h = w or 1600, h or 900
  self.bounds = nil
  self.offX, self.offY = 0, 0
  self.rot = 0
end

function Camera:resize(w, h) self.w, self.h = w, h end
function Camera:setBounds(x, y, w, h) self.bounds = { x = x, y = y, w = w, h = h } end

function Camera:snapTo(x, y) self.x, self.y, self.tx, self.ty = x, y, x, y end

--- Follow a point, projecting ahead along its velocity so the player sees where
--- they are going rather than where they have been.
function Camera:follow(x, y, vx, vy, dt)
  local lx = U.clamp((vx or 0) * T.lookahead, -T.lookaheadMax, T.lookaheadMax)
  local ly = U.clamp((vy or 0) * T.lookahead, -T.lookaheadMax, T.lookaheadMax)
  self.tx, self.ty = x + lx, y + ly

  local dx, dy = self.tx - self.x, self.ty - self.y
  local d = U.len(dx, dy)
  if d > T.deadzone then
    local rate = T.followRate * (1 + U.saturate((d - T.deadzone) / 500) * 1.6)
    self.x = U.damp(self.x, self.tx, rate, dt)
    self.y = U.damp(self.y, self.ty, rate, dt)
  end

  self.zoom = U.damp(self.zoom, self.zoomTarget, 5, dt) * (1 + J.zoomPunch)
  self:clampToBounds()
end

function Camera:clampToBounds()
  local b = self.bounds
  if not b then return end
  local hw, hh = self.w / (2 * self.zoom), self.h / (2 * self.zoom)
  if b.w > hw * 2 then
    self.x = U.clamp(self.x, b.x + hw - T.edgePad, b.x + b.w - hw + T.edgePad)
  else
    self.x = b.x + b.w / 2
  end
  if b.h > hh * 2 then
    self.y = U.clamp(self.y, b.y + hh - T.edgePad, b.y + b.h - hh + T.edgePad)
  else
    self.y = b.y + b.h / 2
  end
end

function Camera:attach()
  love.graphics.push()
  love.graphics.translate(self.w / 2, self.h / 2)
  love.graphics.rotate(self.rot + J.shakeR)
  love.graphics.scale(self.zoom)
  love.graphics.translate(-self.x + J.shakeX / self.zoom + self.offX,
                          -self.y + J.shakeY / self.zoom + self.offY)
end

function Camera:detach() love.graphics.pop() end

function Camera:toWorld(sx, sy)
  local z = self.zoom
  return (sx - self.w / 2) / z + self.x, (sy - self.h / 2) / z + self.y
end

function Camera:toScreen(wx, wy)
  local z = self.zoom
  return (wx - self.x) * z + self.w / 2, (wy - self.y) * z + self.h / 2
end

--- World-space rectangle currently visible, expanded by `pad`. Used for culling.
function Camera:viewRect(pad)
  pad = pad or 0
  local hw, hh = self.w / (2 * self.zoom) + pad, self.h / (2 * self.zoom) + pad
  return self.x - hw, self.y - hh, hw * 2, hh * 2
end

function Camera:visible(x, y, r)
  local vx, vy, vw, vh = self:viewRect(r or 0)
  return x >= vx and y >= vy and x <= vx + vw and y <= vy + vh
end

return Camera
