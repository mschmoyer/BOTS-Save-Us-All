-- Offline synthesis library. Everything the game plays is generated here at load
-- time into float buffers and handed to love.sound.newSoundData.
--
-- A *buffer* is a plain table: { rate, n, ch, L = {..}, R = {..} or nil }.
-- Samples are floats, nominally -1..1, 1-based. Nothing here touches love.audio,
-- so the whole module is safe under SDL_AUDIODRIVER=dummy and in love.js.
--
-- Sounds are *data*: describe one with a spec table and call Synth.render(spec).

local U = require("src.core.util")

local Synth = {}

local sin, cos, exp, floor, abs, max, min, sqrt, pi, random =
      math.sin, math.cos, math.exp, math.floor, math.abs, math.max, math.min,
      math.sqrt, math.pi, math.random
local TAU = pi * 2

--- Default working rate. 22050 is plenty for this palette and halves both the
--- generation cost and the memory the web build has to hold.
Synth.rate = 22050

-------------------------------------------------------------------- music maths
local NOTE = { c = 0, d = 2, e = 4, f = 5, g = 7, a = 9, b = 11 }

--- MIDI note number -> Hz (A4 = 69 = 440 Hz).
function Synth.noteToHz(n) return 440 * 2 ^ ((n - 69) / 12) end

--- "c4", "f#3", "eb5" -> MIDI note number.
function Synth.nameToNote(s)
  local letter, acc, oct = s:lower():match("^([a-g])([#b]?)(%-?%d+)$")
  if not letter then return 60 end
  local n = NOTE[letter] + (tonumber(oct) + 1) * 12
  if acc == "#" then n = n + 1 elseif acc == "b" then n = n - 1 end
  return n
end

function Synth.semitoneRatio(s) return 2 ^ (s / 12) end

--- Scale degrees as semitone offsets from the tonic.
Synth.scales = {
  ionian           = { 0, 2, 4, 5, 7, 9, 11 },
  dorian           = { 0, 2, 3, 5, 7, 9, 10 },
  phrygian         = { 0, 1, 3, 5, 7, 8, 10 },
  lydian           = { 0, 2, 4, 6, 7, 9, 11 },
  mixolydian       = { 0, 2, 4, 5, 7, 9, 10 },
  aeolian          = { 0, 2, 3, 5, 7, 8, 10 },
  locrian          = { 0, 1, 3, 5, 6, 8, 10 },
  phrygianDominant = { 0, 1, 4, 5, 7, 8, 10 },
  pentaMajor       = { 0, 2, 4, 7, 9 },
  pentaMinor       = { 0, 3, 5, 7, 10 },
  hirajoshi        = { 0, 2, 3, 7, 8 },
}

--- Degree (1-based, may run past the octave or below 1) -> semitone offset.
function Synth.degree(scale, d)
  local n = #scale
  local i = d - 1
  local octv = floor(i / n)
  return scale[i - octv * n + 1] + octv * 12
end

--------------------------------------------------------------------- envelopes
-- An envelope spec is a number, a function(t) or a table:
--   { a=, d=, s=, r= }                 ADSR (s is a level, r starts at dur-r)
--   { type="exp",  tau=, peak=, floor= }
--   { type="perc", a=, d=, curve= }    attack then exponential-ish decay
--   { type="bp",   points={{t,v},...} } breakpoint, linearly interpolated
--   { type="ar",   a=, r= }            triangle-ish swell

--- Compile an envelope spec into a plain function(t) for a sound of length `dur`.
function Synth.env(spec, dur)
  if spec == nil then return function() return 1 end end
  if type(spec) == "number" then return function() return spec end end
  if type(spec) == "function" then return function(t) return spec(t, dur) end end

  local kind = spec.type
  if kind == nil and (spec.a or spec.d or spec.s or spec.r) then kind = "adsr" end

  if kind == "exp" then
    local tau, peak, fl = spec.tau or 0.2, spec.peak or 1, spec.floor or 0
    local atk = spec.a or 0.001
    return function(t)
      local v = fl + (peak - fl) * exp(-t / tau)
      if t < atk then v = v * (t / atk) end
      return v
    end
  elseif kind == "perc" then
    local atk, dec, curve = spec.a or 0.002, spec.d or 0.25, spec.curve or 2.5
    return function(t)
      if t < atk then return t / atk end
      local x = (t - atk) / dec
      if x >= 1 then return 0 end
      return (1 - x) ^ curve
    end
  elseif kind == "ar" then
    local atk, rel = spec.a or 0.05, spec.r or 0.3
    return function(t)
      if t < atk then return t / atk end
      local x = (t - atk) / rel
      if x >= 1 then return 0 end
      return 1 - x * x
    end
  elseif kind == "bp" then
    local pts = spec.points
    local np = #pts
    return function(t)
      if t <= pts[1][1] then return pts[1][2] end
      for i = 1, np - 1 do
        local a, b = pts[i], pts[i + 1]
        if t < b[1] then
          local f = (t - a[1]) / max(1e-9, b[1] - a[1])
          return a[2] + (b[2] - a[2]) * f
        end
      end
      return pts[np][2]
    end
  end

  -- ADSR
  local A  = spec.a or 0.01
  local D  = spec.d or 0.1
  local S  = spec.s or 0.6
  local R  = spec.r or 0.2
  local pk = spec.peak or 1
  local rel = max(A + D, dur - R)
  return function(t)
    if t < A then return pk * (t / max(1e-9, A)) end
    if t < A + D then
      local f = (t - A) / max(1e-9, D)
      return pk * (1 + (S - 1) * f)
    end
    if t < rel then return pk * S end
    local f = (t - rel) / max(1e-9, R)
    if f >= 1 then return 0 end
    local v = pk * S * (1 - f)
    return v * v / max(1e-9, pk * S)
  end
end

--- Compile a frequency spec into function(t). Accepts a number, a function, a
--- breakpoint env, or { from=, to=, tau= } for a glide.
function Synth.freqFn(spec, dur)
  if type(spec) == "number" then return function() return spec end end
  if type(spec) == "function" then return spec end
  if type(spec) == "table" and spec.from then
    local a, b, tau = spec.from, spec.to or spec.from, spec.tau or (dur * 0.35)
    local curve = spec.curve or "exp"
    if curve == "lin" then
      return function(t) return a + (b - a) * min(1, t / max(1e-9, tau)) end
    end
    return function(t) return b + (a - b) * exp(-t / tau) end
  end
  return Synth.env(spec, dur)
end

----------------------------------------------------------------------- buffers
local Buf = {}
Buf.__index = Buf
Synth.Buf = Buf

function Synth.buffer(dur, ch, rate)
  rate = rate or Synth.rate
  local n = floor(dur * rate + 0.5)
  if n < 1 then n = 1 end
  local L = {}
  for i = 1, n do L[i] = 0 end
  local b = setmetatable({ rate = rate, n = n, ch = ch or 1, L = L }, Buf)
  if b.ch == 2 then
    local R = {}
    for i = 1, n do R[i] = 0 end
    b.R = R
  end
  return b
end

function Buf:dur() return self.n / self.rate end

function Buf:copy()
  local b = Synth.buffer(self.n / self.rate, self.ch, self.rate)
  local sL, dL = self.L, b.L
  for i = 1, self.n do dL[i] = sL[i] end
  if self.R then
    local sR, dR = self.R, b.R
    for i = 1, self.n do dR[i] = sR[i] end
  end
  return b
end

--- Promote a mono buffer to stereo (both channels identical).
function Buf:stereo()
  if self.ch == 2 then return self end
  local R = {}
  local L = self.L
  for i = 1, self.n do R[i] = L[i] end
  self.R, self.ch = R, 2
  return self
end

--- Sum `src` into this buffer starting `atSec` seconds in, scaled by `gain`.
function Buf:mixIn(src, atSec, gain, pan)
  gain = gain or 1
  local off = floor((atSec or 0) * self.rate + 0.5)
  local gL, gR = gain, gain
  if pan and self.ch == 2 then
    local p = U.clamp(pan, -1, 1)
    gL = gain * sqrt(0.5 * (1 - p))
    gR = gain * sqrt(0.5 * (1 + p))
  end
  local dL, sL = self.L, src.L
  local dR, sR = self.R, src.R or src.L
  local lim = min(src.n, self.n - off)
  for i = 1, lim do
    local j = i + off
    if j >= 1 then
      dL[j] = dL[j] + sL[i] * gL
      if dR then dR[j] = dR[j] + sR[i] * gR end
    end
  end
  return self
end

function Buf:gain(g)
  local L, R = self.L, self.R
  for i = 1, self.n do L[i] = L[i] * g end
  if R then for i = 1, self.n do R[i] = R[i] * g end end
  return self
end

function Buf:peak()
  local p = 0
  local L, R = self.L, self.R
  for i = 1, self.n do local v = abs(L[i]) if v > p then p = v end end
  if R then for i = 1, self.n do local v = abs(R[i]) if v > p then p = v end end end
  return p
end

function Buf:rms()
  local s = 0
  local L, R = self.L, self.R
  for i = 1, self.n do s = s + L[i] * L[i] end
  if R then
    for i = 1, self.n do s = s + R[i] * R[i] end
    return sqrt(s / (self.n * 2))
  end
  return sqrt(s / self.n)
end

function Buf:normalize(target)
  local p = self:peak()
  if p > 1e-6 then self:gain((target or 0.9) / p) end
  return self
end

--- Remove any DC offset. Cheap insurance: DC eats headroom and clicks on start.
function Buf:dcBlock()
  local function run(ch)
    local s = 0
    for i = 1, self.n do s = s + ch[i] end
    local m = s / self.n
    if abs(m) > 1e-6 then for i = 1, self.n do ch[i] = ch[i] - m end end
  end
  run(self.L)
  if self.R then run(self.R) end
  return self
end

function Buf:fade(inSec, outSec)
  inSec, outSec = inSec or 0.002, outSec or 0.01
  local ni = floor(inSec * self.rate)
  local no = floor(outSec * self.rate)
  local L, R = self.L, self.R
  for i = 1, min(ni, self.n) do
    local g = i / ni
    L[i] = L[i] * g
    if R then R[i] = R[i] * g end
  end
  for i = 0, min(no, self.n) - 1 do
    local j = self.n - i
    local g = i / no
    L[j] = L[j] * g
    if R then R[j] = R[j] * g end
  end
  return self
end

------------------------------------------------------------------ oscillators
-- All generators ADD into the buffer so layers stack naturally.

local function polyblep(t, dt)
  if t < dt then
    t = t / dt
    return t + t - t * t - 1
  elseif t > 1 - dt then
    t = (t - 1) / dt
    return t * t + t + t + 1
  end
  return 0
end

--- opts: wave, freq, amp, env, phase, duty, detune (cents), fm (buffer of Hz).
function Buf:osc(opts)
  local wave  = opts.wave or "sine"
  local dur   = self.n / self.rate
  local fFn   = Synth.freqFn(opts.freq or 220, dur)
  -- amp is a scalar; env is the shape. Passing a table as `amp` treats it as env.
  local envSpec = opts.env
  local amp = 1
  if type(opts.amp) == "table" or type(opts.amp) == "function" then
    envSpec = envSpec or opts.amp
  elseif type(opts.amp) == "number" then
    amp = opts.amp
  end
  local aFn = Synth.env(envSpec or 1, dur)
  local detune = opts.detune and 2 ^ (opts.detune / 1200) or 1
  local duty  = opts.duty or 0.5
  local rate  = self.rate
  local inv   = 1 / rate
  local ph    = opts.phase or 0
  local L     = self.L
  local pan   = opts.pan
  local R     = (self.ch == 2) and self.R or nil
  local gL, gR = 1, 1
  if pan and R then
    local p = U.clamp(pan, -1, 1)
    gL, gR = sqrt(0.5 * (1 - p)), sqrt(0.5 * (1 + p))
  end

  -- pink noise state (Paul Kellet's economy filter)
  local b0, b1, b2 = 0, 0, 0
  local nseed = opts.seed or 0
  local last = 0

  -- Fast paths: a constant frequency or a flat envelope skips a closure call
  -- per sample, which matters when a pad stacks six partials.
  local constF = (type(opts.freq) == "number") and (opts.freq * detune) or nil
  local constA = (envSpec == nil or envSpec == 1) and amp or nil

  for i = 1, self.n do
    local t = (i - 1) * inv
    local f = constF or (fFn(t) * detune)
    local a = constA or (aFn(t) * amp)
    local dt = f * inv
    local v
    if wave == "sine" then
      v = sin(ph * TAU)
    elseif wave == "tri" then
      -- quarter-phase offset so a triangle starts at zero (no start click)
      local x = ph + 0.25
      if x >= 1 then x = x - 1 end
      v = 1 - 4 * abs(x - 0.5)
    elseif wave == "saw" then
      v = 2 * ph - 1 - polyblep(ph, dt)
    elseif wave == "square" then
      v = (ph < duty) and 1 or -1
      v = v + polyblep(ph, dt)
      local p2 = ph + (1 - duty)
      if p2 >= 1 then p2 = p2 - 1 end
      v = v - polyblep(p2, dt)
    elseif wave == "noise" then
      v = random() * 2 - 1
    elseif wave == "pink" then
      local w = random() * 2 - 1
      b0 = 0.99765 * b0 + w * 0.0990460
      b1 = 0.96300 * b1 + w * 0.2965164
      b2 = 0.57000 * b2 + w * 1.0526913
      v = (b0 + b1 + b2 + w * 0.1848) * 0.32
    elseif wave == "brown" then
      last = last + (random() * 2 - 1) * 0.08
      if last > 1 then last = 1 elseif last < -1 then last = -1 end
      v = last
    else
      v = sin(ph * TAU)
    end
    v = v * a
    L[i] = L[i] + v * gL
    if R then R[i] = R[i] + v * gR end
    ph = ph + dt
    if ph >= 1 then ph = ph - floor(ph) end
    nseed = nseed
  end
  return self
end

--- Two-operator FM. opts: freq, ratio, index (number or env), env, amp, feedback.
function Buf:fm(opts)
  local dur  = self.n / self.rate
  local fFn  = Synth.freqFn(opts.freq or 220, dur)
  local iFn  = Synth.env(opts.index or 2, dur)
  local aFn  = Synth.env(opts.env or 1, dur)
  local amp  = opts.amp or 1
  local ratio = opts.ratio or 1
  local rate = self.rate
  local inv  = 1 / rate
  local pc, pm = opts.phase or 0, 0
  local fb = opts.feedback or 0
  local prev = 0
  local L = self.L
  local R = (self.ch == 2) and self.R or nil
  for i = 1, self.n do
    local t = (i - 1) * inv
    local f = fFn(t)
    local m = sin((pm + prev * fb) * TAU)
    local v = sin((pc + m * iFn(t)) * TAU) * aFn(t) * amp
    prev = m
    L[i] = L[i] + v
    if R then R[i] = R[i] + v end
    pc = pc + f * inv
    pm = pm + f * ratio * inv
    if pc >= 1 then pc = pc - floor(pc) end
    if pm >= 1 then pm = pm - floor(pm) end
  end
  return self
end

--- Karplus-Strong plucked string. opts: freq, amp, damp (0..1), decay, excite.
function Buf:pluck(opts)
  local f = type(opts.freq) == "number" and opts.freq or 220
  local rate = self.rate
  local len = max(2, floor(rate / f + 0.5))
  local d = {}
  local excite = opts.excite or "noise"
  for i = 1, len do
    if excite == "saw" then d[i] = (i / len) * 2 - 1
    else d[i] = random() * 2 - 1 end
  end
  -- low-pass the excitation a little so it is not all fizz
  local prev = 0
  local soft = opts.soft or 0.35
  for i = 1, len do
    prev = prev + (d[i] - prev) * (1 - soft)
    d[i] = prev
  end
  local damp = opts.damp or 0.5
  local decay = opts.decay or 0.996
  local amp = opts.amp or 0.6
  local dur = self.n / self.rate
  local aFn = Synth.env(opts.env or 1, dur)
  local L, R = self.L, (self.ch == 2) and self.R or nil
  local idx = 1
  local y = 0
  local inv = 1 / rate
  for i = 1, self.n do
    local nxt = idx % len + 1
    local s = (d[idx] * (1 - damp) + d[nxt] * damp) * decay
    y = y + (s - y) * 0.85
    d[idx] = y
    idx = nxt
    local v = s * amp * aFn((i - 1) * inv)
    L[i] = L[i] + v
    if R then R[i] = R[i] + v end
  end
  return self
end

--- Additive organ/choir style stack. opts: freq, partials={{mul,amp,detuneCents}}
function Buf:additive(opts)
  local parts = opts.partials or { { 1, 1 } }
  for k = 1, #parts do
    local p = parts[k]
    self:osc({
      wave = p[4] or opts.wave or "sine",
      freq = type(opts.freq) == "number" and opts.freq * p[1] or opts.freq,
      env = opts.env, amp = (opts.amp or 1) * p[2],
      detune = p[3], phase = opts.phase and (opts.phase + k * 0.13) or (k * 0.13),
      pan = opts.pan,
    })
  end
  return self
end

------------------------------------------------------------------- processing
--- One-pole filter. type "lp" or "hp"; cutoff may be an env spec.
function Buf:onepole(opts)
  local dur = self.n / self.rate
  local cFn = Synth.freqFn(opts.cutoff or 1000, dur)
  local hp = (opts.type == "hp")
  local inv = 1 / self.rate
  -- Coefficients are refreshed every STRIDE samples: transcendentals dominate
  -- the cost and a 1.4 kHz modulation rate is far more than any sweep needs.
  local STRIDE = 16
  local function run(ch)
    local z, a = 0, 0
    for i = 1, self.n do
      if (i - 1) % STRIDE == 0 then
        local fc = U.clamp(cFn((i - 1) * inv), 10, self.rate * 0.45)
        a = 1 - exp(-TAU * fc * inv)
      end
      z = z + (ch[i] - z) * a
      ch[i] = hp and (ch[i] - z) or z
    end
  end
  run(self.L)
  if self.R then run(self.R) end
  return self
end

--- Topology-preserving state-variable filter (Simper/Cytomic). Unconditionally
--- stable at any cutoff, unlike the classic Chamberlin form, which self-
--- oscillates above ~fs/6 and quietly turns every bright sweep into a drone.
--- type "lp"|"hp"|"bp"|"notch", q = resonance.
function Buf:svf(opts)
  local dur = self.n / self.rate
  local cFn = Synth.freqFn(opts.cutoff or 1200, dur)
  local q = max(0.4, opts.q or 0.9)
  local mode = opts.type or "lp"
  local m = (mode == "lp" and 1) or (mode == "hp" and 2) or (mode == "bp" and 3) or 4
  local inv = 1 / self.rate
  local drive = opts.drive or 1
  local k = 1 / q
  -- Coefficients refresh every STRIDE samples: tan() dominates the cost and a
  -- 1.4 kHz modulation rate is far finer than any sweep in the game needs.
  local STRIDE = 16
  local nyq = self.rate * 0.49
  -- constant cutoff: solve the coefficients once
  local c1, c2, c3
  if type(opts.cutoff) == "number" then
    local g = math.tan(pi * U.clamp(opts.cutoff, 15, nyq) * inv)
    c1 = 1 / (1 + g * (g + k)); c2 = g * c1; c3 = g * c2
  end
  local function run(ch)
    local ic1, ic2 = 0, 0
    local a1, a2, a3 = c1 or 0, c2 or 0, c3 or 0
    for i = 1, self.n do
      if c1 == nil and (i - 1) % STRIDE == 0 then
        local fc = U.clamp(cFn((i - 1) * inv), 15, nyq)
        local g = math.tan(pi * fc * inv)
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
      end
      local x = ch[i] * drive
      local v3 = x - ic2
      local v1 = a1 * ic1 + a2 * v3
      local v2 = ic2 + a2 * ic1 + a3 * v3
      ic1 = 2 * v1 - ic1
      ic2 = 2 * v2 - ic2
      local out
      if m == 1 then out = v2
      elseif m == 2 then out = x - k * v1 - v2
      elseif m == 3 then out = v1
      else out = x - k * v1 end
      if out ~= out then out = 0 ic1 = 0 ic2 = 0 end
      ch[i] = out
    end
  end
  run(self.L)
  if self.R then run(self.R) end
  return self
end

--- Parallel bank of tuned 2-pole resonators -- the material of a sound.
--- opts: modes = { {hz, q, amp, decay}, ... }, mix (0..1, 1 = wet only), gain.
---
--- This is how a sound gets a *material* instead of a waveform. Excite the bank
--- with a click and you get struck metal; excite it with noise and you get the
--- body of the thing that is making the noise. The mode ratios are the identity:
--- brass bar ratios for the bots, low wide-Q ratios for the wet Blight, tight
--- high modes for glass UI. Nothing else in this library can do that.
function Buf:resonate(opts)
  local modes = opts.modes or { { 400, 12, 1 } }
  local mix = opts.mix
  if mix == nil then mix = 1 end
  local gain = opts.gain or 1
  local rate = self.rate
  local nyq = rate * 0.48
  local function run(ch)
    local n = self.n
    local wet = {}
    for i = 1, n do wet[i] = 0 end
    for k = 1, #modes do
      local md = modes[k]
      local f = min(md[1], nyq)
      local q = max(0.5, md[2] or 10)
      local a = md[3] or 1
      -- RBJ constant-peak-gain bandpass
      local w = TAU * f / rate
      local alpha = sin(w) / (2 * q)
      local cw = cos(w)
      local b0, b1, b2 = alpha, 0, -alpha
      local a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
      b0, b1, b2 = b0 / a0, b1 / a0, b2 / a0
      a1, a2 = a1 / a0, a2 / a0
      local x1, x2, y1, y2 = 0, 0, 0, 0
      for i = 1, n do
        local x = ch[i]
        local y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        if y ~= y then y = 0 y1 = 0 y2 = 0 end
        x2 = x1 x1 = x
        y2 = y1 y1 = y
        wet[i] = wet[i] + y * a
      end
    end
    for i = 1, n do ch[i] = ch[i] * (1 - mix) + wet[i] * mix * gain end
  end
  run(self.L)
  if self.R then run(self.R) end
  return self
end

--- One-pole shelving EQ. type "low"|"high", `db` is the shelf gain.
--- Cheap tone control: lift the air on the UI, pull the mud out of the bass.
function Buf:shelf(opts)
  local kind = opts.type or "high"
  local db = opts.db or 0
  local g = 10 ^ (db / 20)
  local fc = U.clamp(opts.freq or 3000, 20, self.rate * 0.45)
  local a = 1 - exp(-TAU * fc / self.rate)
  local function run(ch)
    local z = 0
    for i = 1, self.n do
      z = z + (ch[i] - z) * a
      local lowPart = z
      local highPart = ch[i] - z
      if kind == "high" then ch[i] = lowPart + highPart * g
      else ch[i] = lowPart * g + highPart end
    end
  end
  run(self.L)
  if self.R then run(self.R) end
  return self
end

--- Look-ahead peak limiter. Keeps transients intact instead of squashing the
--- whole buffer down to fit one sample, which is what plain normalising does.
function Buf:limit(ceiling, lookSec)
  ceiling = ceiling or 0.95
  local look = max(1, floor((lookSec or 0.003) * self.rate))
  local n = self.n
  local L, R = self.L, self.R
  -- nothing over the ceiling: the whole stage is a no-op, and most of the bank
  -- lands here, so check before allocating anything
  local pk = 0
  for i = 1, n do
    local v = abs(L[i])
    if v > pk then pk = v end
    if R then local vr = abs(R[i]) if vr > pk then pk = vr end end
  end
  if pk <= ceiling then return self end

  -- required gain per sample, then a running minimum over the look-ahead window
  -- via a monotonic wedge: O(n) rather than O(n * window), which matters because
  -- every sound in the bank passes through here at load time
  local need = {}
  for i = 1, n do
    local v = abs(L[i])
    if R then local vr = abs(R[i]) if vr > v then v = vr end end
    need[i] = (v > ceiling) and (ceiling / v) or 1
  end
  local g = {}
  local dq, head, tail = {}, 1, 0        -- indices, values increasing
  local fill = min(n, look)
  for j = 1, fill do
    while tail >= head and need[dq[tail]] >= need[j] do tail = tail - 1 end
    tail = tail + 1
    dq[tail] = j
  end
  for i = 1, n do
    local j = i + look
    if j <= n then
      while tail >= head and need[dq[tail]] >= need[j] do tail = tail - 1 end
      tail = tail + 1
      dq[tail] = j
    end
    while dq[head] < i do head = head + 1 end
    g[i] = need[dq[head]]
  end
  local cur = 1
  local atk = 1 - exp(-1 / max(1, look))
  local rel = 1 - exp(-1 / max(1, look * 8))
  for i = 1, n do
    local t = g[i]
    cur = cur + (t - cur) * ((t < cur) and atk or rel)
    L[i] = L[i] * cur
    if R then R[i] = R[i] * cur end
  end
  return self
end

--- Loudness-match: scale so the loudest `win`-second window reaches `target`
--- RMS, then limit to `ceiling`. Peak-normalising makes a click quiet and a
--- drone loud; this makes two sounds sit at the same *perceived* level, which
--- is the only reason a bank of forty sounds can share one mix.
function Buf:loudness(target, win, ceiling)
  target = target or 0.16
  local w = max(64, floor((win or 0.3) * self.rate))
  local L, R = self.L, self.R
  local n = self.n
  local best = 0
  if n <= w then
    best = self:rms()
  else
    local s = 0
    for i = 1, w do
      s = s + L[i] * L[i]
      if R then s = s + R[i] * R[i] end
    end
    local scale = R and (w * 2) or w
    best = sqrt(s / scale)
    for i = w + 1, n do
      s = s + L[i] * L[i] - L[i - w] * L[i - w]
      if R then s = s + R[i] * R[i] - R[i - w] * R[i - w] end
      local v = sqrt(max(0, s) / scale)
      if v > best then best = v end
    end
  end
  if best > 1e-7 then self:gain(target / best) end
  -- 1.5 ms of look-ahead, not 4: a longer window pulls the gain down *before*
  -- the transient it is catching, which is exactly how a click becomes a bump
  return self:limit(ceiling or 0.96, 0.0015)
end

--- Turn a decaying buffer into a seamless loop by crossfading its tail over its
--- head and trimming. Without this a "looping" source ticks or breathes once per
--- period, which is exactly the tell that a drone was faked.
function Buf:loopify(xfade)
  local xf = max(2, floor((xfade or 0.25) * self.rate))
  if xf * 2 >= self.n then return self end
  local n = self.n - xf
  local function run(ch)
    for i = 1, xf do
      local f = (i - 1) / (xf - 1)
      -- equal-power so the sum keeps its level through the splice
      local a = cos(f * pi * 0.5)
      local b = sin(f * pi * 0.5)
      ch[i] = ch[i] * b + ch[n + i] * a
    end
    for i = n + 1, self.n do ch[i] = nil end
  end
  run(self.L)
  if self.R then run(self.R) end
  self.n = n
  return self
end

--- Soft saturation. drive > 1 pushes into the knee.
function Buf:softclip(drive, mix)
  drive = drive or 2
  mix = mix or 1
  local k = 1 / math.tanh(drive)
  local function run(ch)
    for i = 1, self.n do
      local x = ch[i]
      local y = math.tanh(x * drive) * k
      ch[i] = x + (y - x) * mix
    end
  end
  run(self.L)
  if self.R then run(self.R) end
  return self
end

--- Quantise amplitude and/or decimate the sample rate.
function Buf:bitcrush(bits, rateDiv)
  bits = bits or 6
  rateDiv = max(1, floor(rateDiv or 1))
  local steps = 2 ^ bits
  local function run(ch)
    local held = 0
    for i = 1, self.n do
      if (i - 1) % rateDiv == 0 then
        held = floor(ch[i] * steps + 0.5) / steps
      end
      ch[i] = held
    end
  end
  run(self.L)
  if self.R then run(self.R) end
  return self
end

--- Delay with feedback. time in seconds, fb 0..0.95, mix 0..1.
function Buf:delay(opts)
  local time = opts.time or 0.16
  local fb = U.clamp(opts.fb or 0.35, 0, 0.95)
  local mix = opts.mix or 0.3
  local dlen = max(1, floor(time * self.rate))
  local function run(ch, spread)
    local line = {}
    local dl = max(1, floor(dlen * (spread or 1)))
    for i = 1, dl do line[i] = 0 end
    local p = 1
    for i = 1, self.n do
      local d = line[p]
      local x = ch[i]
      line[p] = x + d * fb
      p = p % dl + 1
      ch[i] = x + d * mix
    end
  end
  run(self.L, 1)
  if self.R then run(self.R, opts.spread or 1.31) end
  return self
end

-- Freeverb-ish constants, expressed at 44100 and scaled to our rate.
local COMB = { 1116, 1188, 1277, 1356 }
local ALLP = { 556, 441 }

--- Schroeder reverb: 4 parallel combs into 2 series allpasses.
function Buf:reverb(opts)
  opts = opts or {}
  local room = U.clamp(opts.room or 0.72, 0.1, 0.98)
  local damp = U.clamp(opts.damp or 0.35, 0, 0.95)
  local mix  = U.clamp(opts.mix or 0.25, 0, 1)
  local scale = self.rate / 44100
  local pre = floor((opts.pre or 0.012) * self.rate)

  local function run(ch, off)
    local n = self.n
    local wet = {}
    for i = 1, n do wet[i] = 0 end
    for c = 1, #COMB do
      local dl = max(4, floor(COMB[c] * scale) + off)
      local line = {}
      for i = 1, dl do line[i] = 0 end
      local p, store = 1, 0
      for i = 1, n do
        local out = line[p]
        store = out * (1 - damp) + store * damp
        local j = i - pre
        line[p] = ((j >= 1) and ch[j] or 0) + store * room
        p = p % dl + 1
        wet[i] = wet[i] + out * 0.25
      end
    end
    for a = 1, #ALLP do
      local dl = max(4, floor(ALLP[a] * scale) + off)
      local line = {}
      for i = 1, dl do line[i] = 0 end
      local p = 1
      local g = 0.5
      for i = 1, n do
        local bufout = line[p]
        local input = wet[i]
        line[p] = input + bufout * g
        p = p % dl + 1
        wet[i] = bufout - input * g
      end
    end
    for i = 1, n do ch[i] = ch[i] * (1 - mix * 0.4) + wet[i] * mix * 1.6 end
  end

  run(self.L, 0)
  if self.R then run(self.R, 23) end
  return self
end

--- Chorus: a short modulated delay, mixed back in.
function Buf:chorus(opts)
  opts = opts or {}
  local rateHz = opts.rate or 0.7
  local depth = (opts.depth or 0.004) * self.rate
  local base = (opts.base or 0.012) * self.rate
  local mix = opts.mix or 0.4
  local inv = 1 / self.rate
  local function run(ch, phase)
    local dl = floor(base + depth + 4)
    local line = {}
    for i = 1, dl do line[i] = 0 end
    local p = 1
    for i = 1, self.n do
      local t = (i - 1) * inv
      local d = base + depth * sin((t * rateHz + phase) * TAU)
      local rp = p - d
      while rp < 1 do rp = rp + dl end
      local i0 = floor(rp)
      local f = rp - i0
      local a = line[(i0 - 1) % dl + 1]
      local b = line[i0 % dl + 1]
      local v = a + (b - a) * f
      line[p] = ch[i]
      p = p % dl + 1
      ch[i] = ch[i] * (1 - mix * 0.5) + v * mix
    end
  end
  run(self.L, 0)
  if self.R then run(self.R, 0.5) end
  return self
end

--- Haas-style widener. Promotes to stereo, then decorrelates the channels.
function Buf:widen(amount)
  self:stereo()
  amount = amount or 0.5
  local d = max(1, floor(0.008 * amount * self.rate))
  local R = self.R
  for i = self.n, 1, -1 do
    R[i] = (i > d) and R[i - d] or 0
  end
  -- gentle mid/side tilt so the centre stays solid
  local L = self.L
  for i = 1, self.n do
    local m = (L[i] + R[i]) * 0.5
    local s = (L[i] - R[i]) * 0.5 * (1 + amount)
    L[i] = m + s
    R[i] = m - s
  end
  return self
end

--- Resample by a pitch ratio (>1 = higher and shorter). Linear interpolation.
function Buf:resample(ratio)
  if abs(ratio - 1) < 1e-6 then return self end
  local n2 = max(1, floor(self.n / ratio))
  local function run(ch)
    local out = {}
    for i = 1, n2 do
      local sp = (i - 1) * ratio + 1
      local i0 = floor(sp)
      local f = sp - i0
      local a = ch[min(i0, self.n)] or 0
      local b = ch[min(i0 + 1, self.n)] or 0
      out[i] = a + (b - a) * f
    end
    return out
  end
  self.L = run(self.L)
  if self.R then self.R = run(self.R) end
  self.n = n2
  return self
end

function Buf:pitchShift(semitones) return self:resample(2 ^ (semitones / 12)) end

--- Reverse, for risers and swells built from decaying material.
function Buf:reverse()
  local function run(ch)
    local i, j = 1, self.n
    while i < j do ch[i], ch[j] = ch[j], ch[i] i = i + 1 j = j - 1 end
  end
  run(self.L)
  if self.R then run(self.R) end
  return self
end

--- Trim trailing near-silence (keeps a small tail) so buffers stay small.
function Buf:trim(threshold, tail)
  threshold = threshold or 0.0008
  local last = 1
  local L, R = self.L, self.R
  for i = self.n, 1, -1 do
    if abs(L[i]) > threshold or (R and abs(R[i]) > threshold) then last = i break end
  end
  local keep = min(self.n, last + floor((tail or 0.01) * self.rate))
  if keep < self.n then
    for i = keep + 1, self.n do L[i] = nil if R then R[i] = nil end end
    self.n = keep
  end
  return self
end

--------------------------------------------------------------- RMS envelope
--- Coarse amplitude envelope, used by the mixer's meters (see engine/audio).
function Buf:envelope(hz)
  hz = hz or 60
  local step = max(1, floor(self.rate / hz))
  local out = {}
  local L, R = self.L, self.R
  local k = 0
  for i = 1, self.n, step do
    local s, c = 0, 0
    for j = i, min(i + step - 1, self.n) do
      local v = L[j]
      s = s + v * v
      if R then s = s + R[j] * R[j] c = c + 1 end
      c = c + 1
    end
    k = k + 1
    out[k] = sqrt(s / max(1, c))
  end
  out.hz = hz
  out.n = k
  return out
end

------------------------------------------------------------------- SoundData
--- Convert to a love SoundData (16-bit). Safe to call with no audio device.
function Buf:toSoundData()
  local sd = love.sound.newSoundData(self.n, self.rate, 16, self.ch)
  local L, R = self.L, self.R
  if self.ch == 2 then
    local k = 0
    for i = 1, self.n do
      local l, r = L[i], R[i]
      if l > 1 then l = 1 elseif l < -1 then l = -1 end
      if r > 1 then r = 1 elseif r < -1 then r = -1 end
      sd:setSample(k, l) k = k + 1
      sd:setSample(k, r) k = k + 1
    end
  else
    for i = 1, self.n do
      local v = L[i]
      if v > 1 then v = 1 elseif v < -1 then v = -1 end
      sd:setSample(i - 1, v)
    end
  end
  return sd
end

--- Raw little-endian 16-bit PCM, for writing WAVs in the verification harness.
function Buf:toPCM()
  local parts = {}
  local L, R = self.L, self.R
  local k = 0
  local function push(v)
    if v > 1 then v = 1 elseif v < -1 then v = -1 end
    local s = floor(v * 32767 + 0.5)
    if s < 0 then s = s + 65536 end
    k = k + 1
    parts[k] = string.char(s % 256, floor(s / 256) % 256)
  end
  for i = 1, self.n do
    push(L[i])
    if R then push(R[i]) end
  end
  return table.concat(parts)
end

--------------------------------------------------------------- the spec engine
-- A sound is a table. Layers generate, fx process, then the tail is tidied.
--
--   Synth.render{
--     dur = 0.4, ch = 1,
--     layers = { { osc = "sine", freq = { from = 900, to = 220, tau = 0.05 },
--                  env = { type = "perc", d = 0.3 }, amp = 0.6 } },
--     fx     = { { "svf", type = "lp", cutoff = 3000, q = 1.4 },
--                { "reverb", mix = 0.18 } },
--     normalize = 0.85, fadeOut = 0.02,
--   }

local FX = {
  onepole   = function(b, o) return b:onepole(o) end,
  svf       = function(b, o) return b:svf(o) end,
  lowpass   = function(b, o) o.type = "lp" return b:svf(o) end,
  highpass  = function(b, o) o.type = "hp" return b:svf(o) end,
  bandpass  = function(b, o) o.type = "bp" return b:svf(o) end,
  softclip  = function(b, o) return b:softclip(o.drive, o.mix) end,
  resonate  = function(b, o) return b:resonate(o) end,
  shelf     = function(b, o) return b:shelf(o) end,
  limit     = function(b, o) return b:limit(o.ceiling, o.look) end,
  loudness  = function(b, o) return b:loudness(o.rms, o.win, o.ceiling) end,
  loopify   = function(b, o) return b:loopify(o.xfade) end,
  bitcrush  = function(b, o) return b:bitcrush(o.bits, o.rateDiv) end,
  delay     = function(b, o) return b:delay(o) end,
  reverb    = function(b, o) return b:reverb(o) end,
  chorus    = function(b, o) return b:chorus(o) end,
  widen     = function(b, o) return b:widen(o.amount) end,
  gain      = function(b, o) return b:gain(o.amount or o.gain or 1) end,
  fade      = function(b, o) return b:fade(o.inT, o.outT) end,
  reverse   = function(b, o) return b:reverse() end,
  pitch     = function(b, o) return b:pitchShift(o.semitones or 0) end,
  normalize = function(b, o) return b:normalize(o.peak or 0.9) end,
  dcBlock   = function(b) return b:dcBlock() end,
}
Synth.fx = FX

function Synth.render(spec)
  local rate = spec.rate or Synth.rate
  local b = Synth.buffer(spec.dur or 0.5, spec.ch or 1, rate)
  local layers = spec.layers or {}
  for i = 1, #layers do
    local l = layers[i]
    local kind = l.osc or "sine"
    if kind == "fm" then
      b:fm(l)
    elseif kind == "pluck" then
      b:pluck(l)
    elseif kind == "additive" then
      b:additive(l)
    elseif kind == "sub" then
      -- a sub-buffer with its own fx, mixed in at an offset
      local child = Synth.render(l.spec)
      b:mixIn(child, l.at or 0, l.amp or 1, l.pan)
    else
      l.wave = kind
      b:osc(l)
    end
  end
  local fx = spec.fx or {}
  for i = 1, #fx do
    local e = fx[i]
    local f = FX[e[1]]
    if f then f(b, e) end
  end
  b:dcBlock()
  if spec.trim ~= false then b:trim(0.0006, spec.tail or 0.015) end
  if spec.loop then
    -- a loop must not be faded or trimmed at its edges, only spliced
    b:loopify(spec.xfade or 0.3)
    if spec.loudness then b:loudness(spec.loudness, spec.loudWin, spec.ceiling)
    elseif spec.normalize ~= false then b:normalize(spec.normalize or 0.88) end
    b:dcBlock()
    return b
  end
  if spec.loudness then
    -- perceived-loudness match, the only way a bank of forty sounds shares a mix
    b:loudness(spec.loudness, spec.loudWin, spec.ceiling)
  elseif spec.normalize ~= false then
    b:normalize(spec.normalize or 0.88)
  end
  b:fade(spec.fadeIn or 0.0015, spec.fadeOut or 0.006)
  return b
end

--- Render straight to a SoundData.
function Synth.renderSound(spec) return Synth.render(spec):toSoundData() end

return Synth
