-- A corner map of the island. The play area is 3400x2400 and the camera sees a
-- tenth of it, so without this the player has no idea where anything is.
local U   = require("src.core.util")
local P   = require("src.engine.palette")
local Opt = require("src.core.optional")
local TU  = require("src.game.tuning")
local Input = require("src.engine.input")

local Draw = Opt.require("src.engine.draw")
local Text = Opt.require("src.engine.text")

local M = {
  canvas = nil, scale = 1, w = 0, h = 0,
  open = 0,          -- 0 = corner map, 1 = full-screen map
  target = 0,
}

local PAD = 18

--- Bake the terrain tiles down into a small image, once.
function M.build(world)
  local t = world.terrain
  M.world = world
  if not t or not t.tiles then return end
  local maxW = 260
  local s = maxW / t.w
  M.scale = s
  M.w, M.h = math.floor(t.w * s), math.floor(t.h * s)
  M.canvas = love.graphics.newCanvas(M.w, M.h)
  local prev = love.graphics.getCanvas()
  love.graphics.setCanvas(M.canvas)
  love.graphics.clear(0, 0, 0, 0)
  local pb, pa = love.graphics.getBlendMode()
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.setColor(1, 1, 1, 1)
  for i = 1, #t.tiles do
    local tile = t.tiles[i]
    love.graphics.draw(tile.canvas, tile.x * s, tile.y * s, 0, s, s)
  end
  love.graphics.setBlendMode(pb, pa)
  love.graphics.setCanvas(prev)
end

function M.update(dt)
  if Input.pressed("map") then M.target = M.target > 0.5 and 0 or 1 end
  M.open = U.damp(M.open, M.target, 14, dt)
end

function M.isOpen() return M.target > 0.5 end

local function dot(x, y, r, c, a)
  love.graphics.setColor(c[1], c[2], c[3], a or 1)
  love.graphics.circle("fill", x, y, r)
end

function M.draw(world, cam)
  if not M.canvas then return end
  local sw, sh = love.graphics.getDimensions()
  local g = love.graphics

  -- Corner placement, growing toward the centre when opened. The workforce
  -- roster used to occupy this corner and the map was shoved 168 px up the
  -- screen to dodge it; the corner is the map's now, so it sits where a corner
  -- map belongs -- one safe inset in from both edges, above the build bar.
  local k = U.ease.inOutCubic(M.open)
  local corner = math.min(1, (sh - 250) / 400)      -- shrink on a short viewport
  corner = math.max(0.62, corner)
  local scale = U.lerp(corner, math.min(sw * 0.62 / M.w, sh * 0.68 / M.h), k)
  local w, h = M.w * scale, M.h * scale
  local cx = U.lerp(sw - PAD - M.w * corner, (sw - w) / 2, k)
  local cy = U.lerp(sh - PAD - 22 - M.h * corner, (sh - h) / 2, k)
  local a = U.lerp(0.62, 0.97, k)

  if k > 0.02 then
    g.setColor(P.black[1], P.black[2], P.black[3], 0.55 * k)
    g.rectangle("fill", 0, 0, sw, sh)
  end

  -- A soft pool under the plate rather than a hard bright rectangle sitting on
  -- the world: closed, the map should read as a quiet inset, not a window.
  if Draw.softShadow then
    Draw.softShadow(cx + w * 0.5, cy + h * 0.5, w * 0.75, h * 0.9, 0.5)
  end
  g.setColor(P.ramp.water[1][1], P.ramp.water[1][2], P.ramp.water[1][3], a * 0.85)
  if Draw.roundRect then Draw.roundRect("fill", cx - 5, cy - 5, w + 10, h + 10, 7)
  else g.rectangle("fill", cx - 5, cy - 5, w + 10, h + 10, 7) end

  g.setColor(1, 1, 1, a)
  g.draw(M.canvas, cx, cy, 0, scale, scale)

  local s = M.scale * scale
  local function px(x, y) return cx + x * s, cy + y * s end

  -- trees read as a mass, not as individuals
  local trees = world.trees
  local step = math.max(1, math.floor(#trees / 700))
  g.setColor(P.ramp.leaf[4][1], P.ramp.leaf[4][2], P.ramp.leaf[4][3], 0.55 * a)
  for i = 1, #trees, step do
    local t = trees[i]
    if t.alive then
      local x, y = px(t.x, t.y)
      g.circle("fill", x, y, 1.6 * scale)
    end
  end

  for i = 1, #world.cobalts do
    local c = world.cobalts[i]
    if c.alive and c.node then
      local x, y = px(c.x, c.y)
      dot(x, y, 1.8 * scale, P.ramp.cobalt[3], 0.85 * a)
    end
  end

  for i = 1, #world.bots do
    local b = world.bots[i]
    if b.alive and b.state ~= "dead" then
      local x, y = px(b.x, b.y)
      dot(x, y, 2 * scale, b.state == "down" and P.eyeDown or P.eye, 0.95 * a)
    end
  end

  for i = 1, #world.enemies do
    local e = world.enemies[i]
    if e.alive then
      local x, y = px(e.x, e.y)
      dot(x, y, 2.2 * scale, P.ramp.blight[4], 0.95 * a)
    end
  end

  -- home rig
  local hx, hy = px(world.homeX, world.homeY)
  g.setColor(P.accent[1], P.accent[2], P.accent[3], 0.9 * a)
  g.circle("line", hx, hy, 4 * scale)

  -- the player, always legible
  local p = world.player
  local ppx, ppy = px(p.x, p.y)
  dot(ppx, ppy, 3.4 * scale, P.white, a)
  g.setColor(P.accent[1], P.accent[2], P.accent[3], 0.9 * a)
  g.circle("line", ppx, ppy, 5.4 * scale + math.sin(world.time * 3) * 1.2)

  -- what the camera can see
  local vx, vy, vw, vh = cam:viewRect(0)
  g.setColor(P.ink[1], P.ink[2], P.ink[3], 0.32 * a)
  g.setLineWidth(1)
  g.rectangle("line", cx + vx * s, cy + vy * s, vw * s, vh * s)

  -- a hairline edge, so the plate has a defined boundary at low alpha
  g.setColor(P.ink[1], P.ink[2], P.ink[3], 0.16 * a)
  g.setLineWidth(1)
  if Draw.roundRect then Draw.roundRect("line", cx - 4.5, cy - 4.5, w + 9, h + 9, 7)
  else g.rectangle("line", cx - 4.5, cy - 4.5, w + 9, h + 9) end

  if k > 0.35 and Text.display then
    Text.display("THE ISLAND", cx, cy - 34 * scale, 22 * scale,
                 { color = P.ink, alpha = k, tracking = 0.28 })
  elseif Text.display and k < 0.3 then
    -- What opens it. Nothing else on the screen says so, so it is worth a line
    -- of type -- but only while the player is still learning the island, not
    -- for the whole run.
    local age = world.time or 0
    local hint = (0.5 - k) * 1.2 * U.saturate((90 - age) / 20)
    if hint > 0.01 then
      Text.display(Input.glyph("map") .. "  MAP", cx + w, cy + h + 8, 10,
                   { color = P.inkDim, alpha = hint, tracking = 0.24,
                     align = "right", shadow = 1 })
    end
  end
  g.setColor(1, 1, 1, 1)
end

return M
