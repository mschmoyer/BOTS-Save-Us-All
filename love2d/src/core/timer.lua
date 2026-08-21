-- Tweens, delays and repeats. One global instance drives UI and game timing;
-- entities may own their own so they can be cancelled wholesale.
local U = require("src.core.util")
local Class = require("src.core.class")

local Timer = Class("Timer")

function Timer:init()
  self.items = {}
  self.tags = {}
end

local function add(self, item, tag)
  if tag then
    -- a tagged item replaces any earlier one with the same tag
    local prev = self.tags[tag]
    if prev then prev.dead = true end
    self.tags[tag] = item
  end
  self.items[#self.items + 1] = item
  return item
end

--- Call `fn` after `delay` seconds.
function Timer:after(delay, fn, tag)
  return add(self, { kind = "after", t = 0, d = delay, fn = fn }, tag)
end

--- Call `fn` every `period` seconds, `count` times (nil = forever).
function Timer:every(period, fn, count, tag)
  return add(self, { kind = "every", t = 0, d = period, fn = fn, left = count }, tag)
end

--- Call `fn(progress)` every frame for `dur` seconds, then `done()`.
function Timer:during(dur, fn, done, tag)
  return add(self, { kind = "during", t = 0, d = dur, fn = fn, done = done }, tag)
end

--- Tween fields of `subject` toward `target` over `dur` using easing `ease`.
function Timer:tween(dur, subject, target, ease, done, tag)
  local from = {}
  for k in pairs(target) do from[k] = subject[k] end
  return add(self, {
    kind = "tween", t = 0, d = dur, subject = subject, target = target,
    from = from, ease = (type(ease) == "function" and ease) or U.ease[ease or "outCubic"],
    done = done,
  }, tag)
end

function Timer:cancel(item) if item then item.dead = true end end

function Timer:cancelTag(tag)
  local it = self.tags[tag]
  if it then it.dead = true self.tags[tag] = nil end
end

function Timer:clear() self.items = {} self.tags = {} end

function Timer:update(dt)
  local items = self.items
  local n = #items
  local w = 1
  for i = 1, n do
    local it = items[i]
    local keep = not it.dead
    if keep then
      it.t = it.t + dt
      local k = it.kind
      if k == "after" then
        if it.t >= it.d then it.fn() keep = false end
      elseif k == "every" then
        while it.t >= it.d do
          it.t = it.t - it.d
          it.fn()
          if it.left then
            it.left = it.left - 1
            if it.left <= 0 then keep = false break end
          end
        end
      elseif k == "during" then
        local p = U.saturate(it.d > 0 and it.t / it.d or 1)
        it.fn(p, dt)
        if it.t >= it.d then if it.done then it.done() end keep = false end
      elseif k == "tween" then
        local p = it.d > 0 and U.saturate(it.t / it.d) or 1
        local e = it.ease(p)
        for key, to in pairs(it.target) do
          it.subject[key] = U.lerp(it.from[key], to, e)
        end
        if p >= 1 then if it.done then it.done() end keep = false end
      end
    end
    if keep then items[w] = it w = w + 1 end
  end
  for i = w, n do items[i] = nil end
end

Timer.global = Timer.new()

return Timer
