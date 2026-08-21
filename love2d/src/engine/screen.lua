-- Scene stack with transitions. Scenes are plain tables with optional
-- enter/leave/update/draw/drawOverlay/keypressed/resize methods.
local U = require("src.core.util")
local Signal = require("src.core.signal")
local P = require("src.engine.palette")

local Screen = {
  stack = {},
  trans = nil,     -- { t, dur, phase = "out"|"in", fn, kind }
}

function Screen.current() return Screen.stack[#Screen.stack] end

local function call(scene, name, ...)
  if scene and scene[name] then return scene[name](scene, ...) end
end

function Screen.push(scene, ...)
  local cur = Screen.current()
  call(cur, "pause")
  Screen.stack[#Screen.stack + 1] = scene
  call(scene, "enter", ...)
  Signal.emit("screen:push", scene)
end

function Screen.pop(...)
  local cur = table.remove(Screen.stack)
  call(cur, "leave", ...)
  call(Screen.current(), "resume", ...)
  Signal.emit("screen:pop", cur)
end

function Screen.switch(scene, ...)
  local args = { ... }
  while #Screen.stack > 0 do
    local s = table.remove(Screen.stack)
    call(s, "leave")
  end
  Screen.stack[1] = scene
  call(scene, "enter", unpack(args))
  Signal.emit("screen:switch", scene)
end

--- Fade out, run `fn`, fade in. `kind` selects the wipe style.
function Screen.transition(dur, fn, kind)
  if Screen.trans then return end
  Screen.trans = { t = 0, dur = dur or 0.45, phase = "out", fn = fn, kind = kind or "iris" }
end

function Screen.busy() return Screen.trans ~= nil end

function Screen.update(dt, realDt)
  local tr = Screen.trans
  if tr then
    tr.t = tr.t + realDt
    if tr.phase == "out" and tr.t >= tr.dur then
      tr.phase = "in"
      tr.t = 0
      if tr.fn then tr.fn() end
    elseif tr.phase == "in" and tr.t >= tr.dur then
      Screen.trans = nil
    end
  end
  -- update every scene that asks to keep ticking underneath (e.g. the world
  -- keeps breathing behind the pause menu)
  for i = 1, #Screen.stack do
    local s = Screen.stack[i]
    if i == #Screen.stack or s.updateWhenCovered then call(s, "update", dt, realDt) end
  end
end

function Screen.draw()
  for i = 1, #Screen.stack do
    local s = Screen.stack[i]
    if i == #Screen.stack or s.drawWhenCovered ~= false then call(s, "draw") end
  end
  for i = 1, #Screen.stack do call(Screen.stack[i], "drawOverlay") end
  Screen.drawTransition()
end

function Screen.drawTransition()
  local tr = Screen.trans
  if not tr then return end
  local p = U.saturate(tr.t / tr.dur)
  local a = (tr.phase == "out") and p or (1 - p)
  local w, h = love.graphics.getDimensions()
  local g = love.graphics

  if tr.kind == "iris" then
    -- a soft circular iris that closes on the centre, with a coloured rim
    local maxR = U.len(w, h) * 0.62
    local r = maxR * (1 - U.ease.inOutCubic(a))
    g.setColor(P.black[1], P.black[2], P.black[3], 1)
    local segs = 96
    -- draw the inverse of a circle as a fan of quads to avoid stencil cost
    local cx, cy = w / 2, h / 2
    local outer = maxR + 200
    for i = 0, segs - 1 do
      local a0 = i / segs * U.TAU
      local a1 = (i + 1) / segs * U.TAU
      g.polygon("fill",
        cx + math.cos(a0) * r, cy + math.sin(a0) * r,
        cx + math.cos(a1) * r, cy + math.sin(a1) * r,
        cx + math.cos(a1) * outer, cy + math.sin(a1) * outer,
        cx + math.cos(a0) * outer, cy + math.sin(a0) * outer)
    end
    if a > 0.02 and a < 0.99 then
      g.setColor(P.accent[1], P.accent[2], P.accent[3], 0.35 * (1 - a))
      g.setLineWidth(2)
      g.circle("line", cx, cy, r)
    end
  else
    g.setColor(P.black[1], P.black[2], P.black[3], U.ease.inOutQuad(a))
    g.rectangle("fill", 0, 0, w, h)
  end
  g.setColor(1, 1, 1, 1)
end

-- forward love callbacks to the top scene
for _, name in ipairs({ "keypressed", "keyreleased", "mousepressed", "mousereleased",
                        "mousemoved", "wheelmoved", "textinput", "touchpressed",
                        "touchreleased", "touchmoved", "gamepadpressed", "resize" }) do
  Screen[name] = function(...) return call(Screen.current(), name, ...) end
end

return Screen
