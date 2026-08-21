-- Math, easing, noise and table helpers. No love.* calls: safe to require anywhere.
local U = {}

local sqrt, sin, cos, abs, floor, max, min, pi =
      math.sqrt, math.sin, math.cos, math.abs, math.floor, math.max, math.min, math.pi
U.TAU = pi * 2

----------------------------------------------------------------------- numbers
function U.clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end
function U.saturate(v) return v < 0 and 0 or (v > 1 and 1 or v) end
function U.lerp(a, b, t) return a + (b - a) * t end
function U.sign(v) return v > 0 and 1 or (v < 0 and -1 or 0) end
function U.round(v) return floor(v + 0.5) end

--- Frame-rate independent lerp. `rate` is the fraction closed per second.
function U.damp(a, b, rate, dt) return U.lerp(a, b, 1 - math.exp(-rate * dt)) end

--- Move `a` toward `b` by at most `step`.
function U.approach(a, b, step)
  if a < b then return min(a + step, b) end
  return max(a - step, b)
end

function U.remap(v, a, b, c, d) return c + (d - c) * ((v - a) / (b - a)) end
function U.remapc(v, a, b, c, d) return c + (d - c) * U.saturate((v - a) / (b - a)) end

function U.smoothstep(a, b, v)
  local t = U.saturate((v - a) / (b - a))
  return t * t * (3 - 2 * t)
end

function U.smootherstep(a, b, v)
  local t = U.saturate((v - a) / (b - a))
  return t * t * t * (t * (t * 6 - 15) + 10)
end

--- Shortest signed delta between two angles.
function U.angleDelta(a, b)
  local d = (b - a) % U.TAU
  if d > pi then d = d - U.TAU end
  return d
end

function U.lerpAngle(a, b, t) return a + U.angleDelta(a, b) * t end
function U.dampAngle(a, b, rate, dt) return a + U.angleDelta(a, b) * (1 - math.exp(-rate * dt)) end

------------------------------------------------------------------------ vector
function U.len(x, y) return sqrt(x * x + y * y) end
function U.len2(x, y) return x * x + y * y end
function U.dist(x1, y1, x2, y2) return sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2) end
function U.dist2(x1, y1, x2, y2) return (x2 - x1) ^ 2 + (y2 - y1) ^ 2 end

function U.norm(x, y)
  local l = sqrt(x * x + y * y)
  if l < 1e-9 then return 0, 0, 0 end
  return x / l, y / l, l
end

--- Clamp a vector's magnitude.
function U.limit(x, y, maxLen)
  local l = sqrt(x * x + y * y)
  if l > maxLen and l > 1e-9 then return x / l * maxLen, y / l * maxLen end
  return x, y
end

function U.rotate(x, y, a)
  local c, s = cos(a), sin(a)
  return x * c - y * s, x * s + y * c
end

----------------------------------------------------------------------- easings
local E = {}
U.ease = E
function E.linear(t) return t end
function E.inQuad(t) return t * t end
function E.outQuad(t) return 1 - (1 - t) ^ 2 end
function E.inOutQuad(t) return t < .5 and 2 * t * t or 1 - (-2 * t + 2) ^ 2 / 2 end
function E.inCubic(t) return t ^ 3 end
function E.outCubic(t) return 1 - (1 - t) ^ 3 end
function E.inOutCubic(t) return t < .5 and 4 * t ^ 3 or 1 - (-2 * t + 2) ^ 3 / 2 end
function E.inQuart(t) return t ^ 4 end
function E.outQuart(t) return 1 - (1 - t) ^ 4 end
function E.inOutQuart(t) return t < .5 and 8 * t ^ 4 or 1 - (-2 * t + 2) ^ 4 / 2 end
function E.outQuint(t) return 1 - (1 - t) ^ 5 end
function E.inExpo(t) return t == 0 and 0 or 2 ^ (10 * t - 10) end
function E.outExpo(t) return t == 1 and 1 or 1 - 2 ^ (-10 * t) end
function E.inOutExpo(t)
  if t == 0 then return 0 elseif t == 1 then return 1 end
  return t < .5 and 2 ^ (20 * t - 10) / 2 or (2 - 2 ^ (-20 * t + 10)) / 2
end
function E.outSine(t) return sin(t * pi / 2) end
function E.inSine(t) return 1 - cos(t * pi / 2) end
function E.inOutSine(t) return -(cos(pi * t) - 1) / 2 end
function E.outBack(t, s)
  s = s or 1.70158
  return 1 + (s + 1) * (t - 1) ^ 3 + s * (t - 1) ^ 2
end
function E.inBack(t, s) s = s or 1.70158 return (s + 1) * t ^ 3 - s * t ^ 2 end
function E.outElastic(t)
  if t == 0 or t == 1 then return t end
  return 2 ^ (-10 * t) * sin((t * 10 - 0.75) * (U.TAU / 3)) + 1
end
function E.outBounce(t)
  local n, d = 7.5625, 2.75
  if t < 1 / d then return n * t * t
  elseif t < 2 / d then t = t - 1.5 / d return n * t * t + .75
  elseif t < 2.5 / d then t = t - 2.25 / d return n * t * t + .9375
  else t = t - 2.625 / d return n * t * t + .984375 end
end
--- Overshoot-and-settle curve: 0 -> 1 with a springy tail.
function E.spring(t, freq, decay)
  freq, decay = freq or 9, decay or 6
  return 1 - math.exp(-decay * t) * cos(freq * t)
end

------------------------------------------------------------------------- noise
-- Deterministic hash-based value noise. Cheap, tileable enough, no love dep.
local function hash2(x, y, seed)
  local h = x * 374761393 + y * 668265263 + (seed or 0) * 1442695040888963407
  h = (h % 4294967296)
  h = (h * (h * h * 15731 + 789221) + 1376312589) % 4294967296
  return h / 4294967296
end
U.hash2 = hash2

function U.valueNoise(x, y, seed)
  local xi, yi = floor(x), floor(y)
  local xf, yf = x - xi, y - yi
  local u = xf * xf * (3 - 2 * xf)
  local v = yf * yf * (3 - 2 * yf)
  local a = hash2(xi, yi, seed)
  local b = hash2(xi + 1, yi, seed)
  local c = hash2(xi, yi + 1, seed)
  local d = hash2(xi + 1, yi + 1, seed)
  return U.lerp(U.lerp(a, b, u), U.lerp(c, d, u), v)
end

--- Fractal brownian motion over valueNoise. Returns 0..1.
function U.fbm(x, y, octaves, lacunarity, gain, seed)
  octaves = octaves or 4; lacunarity = lacunarity or 2.0; gain = gain or 0.5
  local sum, amp, freq, norm = 0, 1, 1, 0
  for _ = 1, octaves do
    sum = sum + U.valueNoise(x * freq, y * freq, seed) * amp
    norm = norm + amp
    amp = amp * gain
    freq = freq * lacunarity
  end
  return sum / norm
end

--- Ridged variant - good for cliffs and blight veins.
function U.ridge(x, y, octaves, seed)
  local sum, amp, freq, norm = 0, 1, 1, 0
  for _ = 1, (octaves or 4) do
    local n = 1 - abs(U.valueNoise(x * freq, y * freq, seed) * 2 - 1)
    sum = sum + n * n * amp
    norm = norm + amp
    amp = amp * 0.5
    freq = freq * 2
  end
  return sum / norm
end

--------------------------------------------------------------------- randomness
--- Small deterministic PRNG (xorshift). Reproducible across platforms.
local Rng = {}
Rng.__index = Rng
function U.rng(seed)
  return setmetatable({ s = (seed or 12345) % 2147483647 }, Rng)
end
function Rng:next()
  local s = self.s
  s = (s * 1103515245 + 12345) % 2147483648
  self.s = s
  return s / 2147483648
end
function Rng:range(a, b)
  if not a then return self:next() end
  if not b then return self:next() * a end
  return a + self:next() * (b - a)
end
function Rng:int(a, b) return floor(self:range(a, b + 1)) end
function Rng:pick(t) return t[floor(self:next() * #t) + 1] end
function Rng:chance(p) return self:next() < p end
function Rng:sign() return self:next() < 0.5 and -1 or 1 end
function Rng:angle() return self:next() * U.TAU end
--- Uniform point in a disc.
function Rng:inDisc(r)
  local a, d = self:angle(), sqrt(self:next()) * r
  return cos(a) * d, sin(a) * d
end
--- Gaussian-ish via sum of uniforms.
function Rng:gauss()
  return (self:next() + self:next() + self:next() - 1.5) * 1.1547
end

--------------------------------------------------------------------- collections
function U.shuffle(t, rng)
  local r = rng or U.rng(7)
  for i = #t, 2, -1 do
    local j = r:int(1, i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

function U.removeSwap(t, i)
  local n = #t
  t[i] = t[n]
  t[n] = nil
end

function U.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

--- Human-readable large numbers: 1234 -> "1,234"
function U.comma(n)
  local s = tostring(floor(n))
  local out, k = s, nil
  repeat out, k = out:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
  return out
end

function U.timeStr(sec)
  sec = max(0, floor(sec))
  return string.format("%d:%02d", floor(sec / 60), sec % 60)
end

--------------------------------------------------------------------- geometry
--- Squared distance from point to segment; used by shove arcs and pathing.
function U.pointSegDist2(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  if l2 < 1e-9 then return U.dist2(px, py, ax, ay) end
  local t = U.saturate(((px - ax) * dx + (py - ay) * dy) / l2)
  return U.dist2(px, py, ax + t * dx, ay + t * dy)
end

--- Is the point inside a cone at (cx,cy) facing `dir` with half-angle `half`?
function U.inCone(px, py, cx, cy, dir, half, radius)
  local dx, dy = px - cx, py - cy
  if dx * dx + dy * dy > radius * radius then return false end
  return abs(U.angleDelta(dir, math.atan2(dy, dx))) <= half
end

return U
