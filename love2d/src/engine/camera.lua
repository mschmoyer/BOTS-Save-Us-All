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
  self.freeBounds = false
  self.offX, self.offY = 0, 0
  self.rot = 0
end

function Camera:resize(w, h) self.w, self.h = w, h end

--- The rectangle the *centre of the view* is kept inside, give or take
--- `T.edgePad`. This is the island's box, not the world's: the world rect is
--- mostly ocean, and clamping to it let a player standing on a beach fill half
--- the screen with flat water. game.lua pads it by `T.landPad` so a shore still
--- shows its surf and a band of sea.
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

--- Pull the view back inside `bounds`.
---
--- Cutscene framing is deliberately outside this. `attach` and `focus` fold
--- offX/offY in, and Dialogue drives them as `cam.x - target`, so a beat can
--- frame the rig standing in open water and the clamp on `self.x` follows the
--- player harmlessly underneath it. A scene that stages its own camera and
--- wants no clamp at all sets `freeBounds`.
function Camera:clampToBounds()
  local b = self.bounds
  if not b or self.freeBounds then return end
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

--- Where the camera is actually looking. `attach` folds offX/offY into the
--- transform, and cutscene framing moves the camera *entirely* through those
--- offsets - so every projection and every cull test has to account for them or
--- the world gets culled against a rectangle the camera is not looking at. That
--- is what rendered most story beats over open ocean.
function Camera:focus()
  return self.x - (self.offX or 0), self.y - (self.offY or 0)
end

function Camera:toWorld(sx, sy)
  local z = self.zoom
  local cx, cy = self:focus()
  return (sx - self.w / 2) / z + cx, (sy - self.h / 2) / z + cy
end

function Camera:toScreen(wx, wy)
  local z = self.zoom
  local cx, cy = self:focus()
  return (wx - cx) * z + self.w / 2, (wy - cy) * z + self.h / 2
end

--- World-space rectangle currently visible, expanded by `pad`. Used for culling.
function Camera:viewRect(pad)
  pad = pad or 0
  local cx, cy = self:focus()
  local hw, hh = self.w / (2 * self.zoom) + pad, self.h / (2 * self.zoom) + pad
  return cx - hw, cy - hh, hw * 2, hh * 2
end

function Camera:visible(x, y, r)
  local vx, vy, vw, vh = self:viewRect(r or 0)
  return x >= vx and y >= vy and x <= vx + vw and y <= vy + vh
end

return Camera
