-- Audio demo + live visualiser.
--
-- Runs a scripted tour of the sound bank and the adaptive score while drawing
-- what the mixer and the sequencer are actually doing: per-bus RMS meters with
-- scrolling history, the sequencer's bar/beat/chord/layer state, and a log of
-- everything that has been triggered.
--
-- It doubles as the offline verification harness. With BOTS_AUDIO_RENDER=1 it
-- renders a set of sounds and the first N seconds of each music state to WAV
-- files (BOTS_AUDIO_OUT, default /tmp/bots_audio) and quits, so the output can
-- be measured numerically instead of taken on faith.

local U      = require("src.core.util")
local P      = require("src.engine.palette")
local Synth  = require("src.engine.synth")
local Audio  = require("src.engine.audio")
local Music  = require("src.engine.music")

local S = {}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local FONT, FONT_S, FONT_L, FONT_XL

---------------------------------------------------------------------- script
-- A scripted tour. Every entry is { time, fn }. It loops.
local LOOP = 13.0

local function beat(t, fn) return { t = t, fn = fn } end

local SCRIPT = {
  beat(0.00, function(s)
    Music.setCycle(1)
    Music.setState("title")
    Music.setIntensity(0.05); Music.setO2(0.1)
    Audio.setForestProgress(0.04)
    Audio.play("ui_move")
  end),
  beat(0.35, function() Audio.play("ui_move") end),
  beat(0.55, function() Audio.play("ui_select") end),
  beat(0.85, function() Audio.play("bot_boot", { variation = "planter", pan = -0.3 }) end),
  beat(1.20, function() Audio.play("plant", { pan = 0.2 }) end),
  beat(1.45, function() Audio.play("pickup") end),
  beat(1.60, function() Audio.play("pickup_streak", { progress = 0.1 }) end),
  beat(1.75, function() Audio.play("pickup_streak", { progress = 0.3 }) end),
  beat(1.90, function() Audio.play("pickup_streak", { progress = 0.5 }) end),

  beat(2.10, function(s)
    Music.setState("day", { cycle = 2 })
    Music.setIntensity(0.15); Music.setO2(0.3)
    Audio.play("build_start", { pan = -0.4 })
  end),
  beat(2.45, function() Audio.play("bot_boot", { variation = "beacon", pan = 0.4 }) end),
  beat(2.60, function() Audio.setForestProgress(0.35) Audio.play("plant") end),
  beat(2.80, function() Audio.play("build_done", { pan = -0.4 }) end),
  beat(2.95, function() Audio.play("bot_chatter", { pan = 0.5 }) end),
  beat(3.10, function() Audio.setForestProgress(0.55) Audio.play("plant", { pan = -0.2 }) end),
  beat(3.25, function() Audio.play("dash") end),
  beat(3.35, function() Audio.play("o2_milestone") end),

  beat(3.60, function(s)
    Music.setState("dusk", { cycle = 2 })
    Music.setIntensity(0.5)
    Audio.play("wave_start")
    Audio.duck(0.55, 2.2)
  end),
  beat(4.20, function() Audio.play("rift_open", { pan = 0.5 }) end),

  beat(4.80, function(s)
    Music.setState("night", { cycle = 3 })
    Music.setIntensity(0.75); Music.setO2(0.45)
  end),
  beat(4.95, function() Audio.play("enemy_step", { pan = -0.5 }) end),
  beat(5.10, function() Audio.play("shove_swing") Audio.play("chomp", { pan = 0.4 }) end),
  beat(5.25, function() Audio.play("shove_hit") Audio.duck(0.3, 0.4) end),
  beat(5.45, function() Audio.play("enemy_hurt", { pan = 0.3 }) end),
  beat(5.60, function() Audio.play("pulse_charge") end),
  beat(6.50, function() Audio.play("pulse_release") Audio.duck(0.45, 0.7) end),
  beat(6.80, function() Audio.play("enemy_die", { pan = -0.4 }) end),
  beat(7.00, function() Audio.play("player_hurt") end),
  beat(7.30, function() Audio.play("bot_down", { pan = -0.25 }) end),
  beat(7.70, function() Audio.play("tree_fall", { pan = 0.35 }) end),
  beat(8.00, function() Audio.play("spit", { pan = 0.6 }) end),
  beat(8.15, function() S.siphon = Audio.play("siphon_drain", { volume = 0.8 }) end),

  beat(8.60, function(s)
    Music.setState("boss", { cycle = 5 })
    Music.setIntensity(1.0)
    Audio.play("boss_step")
  end),
  beat(9.00, function() Audio.play("boss_beam") end),
  beat(9.40, function() Audio.play("boss_step") Audio.duck(0.4, 0.5) end),
  beat(9.80, function() Audio.play("boss_hurt") end),
  beat(10.1, function() Audio.play("bot_revive", { pan = -0.3 }) end),
  beat(10.4, function() Audio.play("rift_close", { pan = 0.4 }) end),
  beat(10.6, function() if S.siphon then Audio.stop(S.siphon) S.siphon = nil end end),

  beat(10.9, function(s)
    Music.setState("draft", { cycle = 6 })
    Music.setIntensity(0.1); Music.setO2(0.8)
    Audio.play("card_hover")
  end),
  beat(11.2, function() Audio.play("card_hover") end),
  beat(11.4, function() Audio.play("card_pick") end),
  beat(11.7, function() Audio.play("dawn") end),

  beat(12.2, function(s)
    Music.setCycle(7)
    Music.setState("ending", { cycle = 7 })
    Music.setIntensity(0); Music.setO2(1.0)
    Audio.setForestProgress(1.0)
  end),
  beat(12.5, function() Audio.play("plant") end),
  beat(12.8, function() Audio.play("ui_back") end),
}

---------------------------------------------------------------------- WAV out
local function wav(path, buf)
  local pcm = buf:toPCM()
  local ch = buf.ch
  local rate = buf.rate
  local byteRate = rate * ch * 2
  local function le(v, n)
    local t = {}
    for i = 1, n do t[i] = string.char(v % 256) v = floor(v / 256) end
    return table.concat(t)
  end
  local header = "RIFF" .. le(36 + #pcm, 4) .. "WAVEfmt " .. le(16, 4) .. le(1, 2) ..
                 le(ch, 2) .. le(rate, 4) .. le(byteRate, 4) .. le(ch * 2, 2) .. le(16, 2) ..
                 "data" .. le(#pcm, 4)
  local f = io.open(path, "wb")
  if not f then print("WAV: cannot open " .. path) return false end
  f:write(header) f:write(pcm) f:close()
  print(string.format("WAV %s  %.2fs %dHz %dch peak=%.3f rms=%.4f",
        path, buf.n / buf.rate, buf.rate, buf.ch, buf:peak(), buf:rms()))
  return true
end

--- SoundData -> float buffer, so the offline mixer renders exactly the samples
--- the live game plays rather than a re-synthesis of them.
local sdCache = {}
local function sdBuf(entry, vi)
  local key = tostring(entry) .. ":" .. vi
  local c = sdCache[key]
  if c then return c end
  local sd = entry.data[vi]
  local n = sd:getSampleCount()
  local ch = sd:getChannelCount()
  local b = Synth.buffer(n / sd:getSampleRate(), ch, sd:getSampleRate())
  if ch == 2 then
    for i = 1, n do
      b.L[i] = sd:getSample((i - 1) * 2)
      b.R[i] = sd:getSample((i - 1) * 2 + 1)
    end
  else
    for i = 1, n do b.L[i] = sd:getSample(i - 1) end
  end
  sdCache[key] = b
  return b
end

--- Render `secs` of a music state offline by capturing the sequencer's note
--- events and mixing the real one-shot buffers into a stereo master.
local function renderMusic(state, secs, opts)
  local events = {}
  local realPlay = Audio.playMusic
  local clock = 0
  Audio.playMusic = function(inst, st, o)
    local entry = Audio.music[inst]
    if not entry then return nil end
    local nv = #entry.data
    local vi, ratio
    if nv == 12 then
      local oct = floor(st / 12)
      vi = st - oct * 12 + 1
      ratio = 2 ^ oct
    else
      vi = 1 + (#events % nv)
      ratio = 2 ^ (st / 12)
    end
    events[#events + 1] = { inst = inst, vi = vi, ratio = ratio * ((o and o.pitch) or 1),
                            t = clock, vol = (o and o.volume or 1) * (entry.def.gain or 0.7),
                            pan = (o and o.pan) or 0 }
    return { dead = false }
  end

  -- reset the sequencer and drive it at a fixed step
  Music.M.playing = false
  Music.M.step, Music.M.bar, Music.M.chordIndex, Music.M.barsSinceChord = 0, 0, 1, 0
  Music.M.beat, Music.M.clock = 0, 0
  for _, l in ipairs(Music.layerNames) do Music.M.gains[l] = 0 end
  Music.setState(state, opts)
  -- pre-roll the crossfades so the excerpt is the music in steady state
  for _, l in ipairs(Music.layerNames) do Music.M.gains[l] = Music.M.targets[l] end

  local dt = 1 / 60
  while clock < secs do
    Music.update(dt)
    clock = clock + dt
  end
  Audio.playMusic = realPlay

  local out = Synth.buffer(secs + 3.0, 2, Audio.rate)
  for i = 1, #events do
    local e = events[i]
    local entry = Audio.music[e.inst]
    local src = sdBuf(entry, e.vi)
    local b = src:copy():resample(e.ratio)
    if b.rate ~= out.rate then
      -- the bank mixes 11025 and 22050 material; line them up
      b:resample(b.rate / out.rate)
      b.rate = out.rate
    end
    out:mixIn(b, e.t, e.vol * 0.55, e.pan)
  end
  out:dcBlock()
  local pk = out:peak()
  print(string.format("music '%s' notes=%d peak(pre)=%.3f", state, #events, pk))
  if pk > 0.98 then out:gain(0.98 / pk) end
  return out
end

--- Every variant of every sound in the bank, so variant diversity can be
--- measured rather than asserted.
local function renderEveryVariant(dir)
  os.execute("mkdir -p '" .. dir .. "/all'")
  for _, name in ipairs(Audio.names()) do
    local d = Audio.defs[name]
    for v = 1, d.variants do
      local spec = d.build(v, d.variants, U.rng(1000 + v * 7))
      spec.rate = d.rate or Audio.rate
      wav(string.format("%s/all/%s__v%02d.wav", dir, name, v), Synth.render(spec))
    end
  end
  for _, name in ipairs(Audio.musicDefs) do
    local m = Audio.musicDefs[name]
    for _, st in ipairs({ 0, 7 }) do
      local spec = m.build(Synth.noteToHz(48 + st))
      spec.rate = m.rate or Audio.rate
      wav(string.format("%s/all/mus_%s__st%02d.wav", dir, name, st), Synth.render(spec))
    end
  end
  for name, p in pairs(Audio.percDefs) do
    for v = 1, 3 do
      local spec = p.spec(U.rng(500 + v))
      spec.rate = p.rate or Audio.rate
      wav(string.format("%s/all/perc_%s__v%02d.wav", dir, name, v), Synth.render(spec))
    end
  end
end

--- Voice-pool stress: 40 bots, 30 enemies and a boss all making noise at once
--- while the score runs, driven at a fixed step through the real mixer. Reports
--- how the pool actually behaves rather than how we hope it behaves.
local function stressTest(secs)
  local rn = U.rng(4242)
  Audio.stopAll()
  Music.setState("night", { cycle = 4 })
  Music.setIntensity(0.9); Music.setO2(0.5)
  local dt = 1 / 60
  local t = 0
  local peakVoices, sumVoices, frames = 0, 0, 0
  local perBus = { sfx = 0, music = 0, ui = 0 }
  local rejected, played = 0, 0
  local hist = {}
  while t < secs do
    -- 40 bots: chatter and the occasional boot / hurt
    for i = 1, 40 do
      if rn:chance(0.006) then
        if Audio.play("bot_chatter", { x = rn:range(-900, 900), y = 0 }) then played = played + 1
        else rejected = rejected + 1 end
      end
    end
    -- 30 enemies: footsteps at a walking cadence, plus chewing and dying
    for i = 1, 30 do
      if rn:chance(0.05) then
        if Audio.play("enemy_step", { x = rn:range(-1200, 1200), y = 0 }) then played = played + 1
        else rejected = rejected + 1 end
      end
      if rn:chance(0.004) then Audio.play("chomp", { x = rn:range(-900, 900), y = 0 }) end
      if rn:chance(0.002) then Audio.play("enemy_die", { x = rn:range(-900, 900), y = 0 }) end
    end
    -- the player and the boss
    if rn:chance(0.02) then Audio.play("shove_hit") Audio.duck(0.3, 0.35) end
    if rn:chance(0.01) then Audio.play("plant") end
    if rn:chance(0.008) then Audio.play("boss_step") end
    if rn:chance(0.004) then Audio.play("bot_down") end
    if rn:chance(0.01) then Audio.play("ui_move", { bus = "ui" }) end
    Audio.update(dt, 0, 0)
    Music.update(dt)
    local n = Audio.voiceCount()
    peakVoices = max(peakVoices, n)
    sumVoices = sumVoices + n
    frames = frames + 1
    for b in pairs(perBus) do perBus[b] = max(perBus[b], Audio.meter(b).voices) end
    hist[#hist + 1] = Audio.meter("master").rms
    t = t + dt
  end
  local sum, mx = 0, 0
  for i = 1, #hist do sum = sum + hist[i] mx = max(mx, hist[i]) end
  print(string.format(
    "STRESS %.0fs: voices avg %.1f peak %d/%d | max per bus sfx %d music %d ui %d | " ..
    "plays %d rejected %d (%.1f%%) | master rms avg %.3f peak %.3f",
    secs, sumVoices / max(1, frames), peakVoices, Audio.maxVoices,
    perBus.sfx, perBus.music, perBus.ui, played, rejected,
    100 * rejected / max(1, played + rejected), sum / max(1, #hist), mx))
  Audio.stopAll()
end

local function renderAll()
  local dir = os.getenv("BOTS_AUDIO_OUT") or "/tmp/bots_audio"
  os.execute("mkdir -p '" .. dir .. "'")
  local secs = tonumber(os.getenv("BOTS_AUDIO_SECS") or "") or 20

  -- individual sounds, re-rendered through the exact same spec path
  local picks = { "plant", "wave_start", "bot_down", "shove_hit", "card_pick", "dawn",
                  "siphon_drain", "bot_boot", "pulse_release", "ui_select" }
  for _, name in ipairs(picks) do
    local d = Audio.defs[name]
    if d then
      local v = (name == "plant") and 9 or 1
      local spec = d.build(min(v, d.variants), d.variants, U.rng(11))
      spec.rate = d.rate or Audio.rate
      wav(dir .. "/sfx_" .. name .. ".wav", Synth.render(spec))
    end
  end

  -- the plant ladder as one file: the forest growing in, in fourteen steps
  local ladder = Synth.buffer(14 * 0.42 + 1.4, 1, Audio.rate)
  for v = 1, 14 do
    local d = Audio.defs.plant
    local spec = d.build(v, 14, U.rng(3))
    spec.rate = d.rate or Audio.rate
    ladder:mixIn(Synth.render(spec), (v - 1) * 0.42, 0.7)
  end
  ladder:dcBlock():normalize(0.92)
  wav(dir .. "/sfx_plant_ladder.wav", ladder)

  -- each music state
  local states = { { "title", { cycle = 1 } }, { "day", { cycle = 1 } }, { "day7", { cycle = 7 } },
                   { "dusk", { cycle = 3 } }, { "night", { cycle = 4 } },
                   { "boss", { cycle = 6 } }, { "draft", { cycle = 5 } },
                   { "ending", { cycle = 7 } } }
  for _, st in ipairs(states) do
    local name = st[1]
    local real = (name == "day7") and "day" or name
    Music.setIntensity(name == "night" and 0.7 or (name == "boss" and 1.0 or
                       (name == "dusk" and 0.45 or 0.15)))
    Music.setO2(name == "ending" and 1.0 or (name == "night" and 0.5 or 0.3))
    wav(dir .. "/music_" .. name .. ".wav", renderMusic(real, secs, st[2]))
  end

  if (os.getenv("BOTS_AUDIO_ALL") or "") ~= "" then renderEveryVariant(dir) end
  if (os.getenv("BOTS_AUDIO_STRESS") or "") ~= "" then
    stressTest(tonumber(os.getenv("BOTS_AUDIO_STRESS")) or 20)
  end
  print("RENDER DONE -> " .. dir)
end

------------------------------------------------------------------------ scene
function S:enter()
  FONT    = love.graphics.newFont(14)
  FONT_S  = love.graphics.newFont(11)
  FONT_L  = love.graphics.newFont(19)
  FONT_XL = love.graphics.newFont(34)

  self.t = 0
  self.next = 1
  self.flash = {}
  self.loadTime = Audio.load()
  Music.load()
  print(string.format("Audio.load() %.3f s | %d sounds, %d variants, %.2f MB",
        self.loadTime, Audio.stats.sounds, Audio.stats.variants, Audio.stats.bytes / 1048576))
  if (os.getenv("BOTS_AUDIO_COST") or "") ~= "" then
    local rows = {}
    for k, v in pairs(Audio.stats.cost) do rows[#rows + 1] = { k, v } end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    for i = 1, min(#rows, 20) do
      print(string.format("  cost %-18s %6.0f ms", rows[i][1], rows[i][2] * 1000))
    end
  end

  if (os.getenv("BOTS_AUDIO_RENDER") or "") ~= "" then
    renderAll()
    if love.event then love.event.quit() end
    self.rendered = true
  end
end

function S:leave() Audio.stopAll() end

function S:update(dt)
  if self.rendered then return end
  local prev = self.t
  self.t = self.t + dt
  if self.t >= LOOP then
    self.t = self.t - LOOP
    prev = -1
    self.next = 1
  end
  while self.next <= #SCRIPT and SCRIPT[self.next].t <= self.t do
    local ev = SCRIPT[self.next]
    ev.fn(self)
    self.next = self.next + 1
  end

  Audio.update(dt, 0, 0)
  Music.update(dt)

  for i = #Audio.recent, 1, -1 do Audio.recent[i].t = Audio.recent[i].t + dt end
end

--------------------------------------------------------------------- drawing
local g = love.graphics

local function panel(x, y, w, h, title)
  g.setColor(P.alpha(P.ramp.metal[1], 0.55))
  g.rectangle("fill", x, y, w, h, 6, 6)
  g.setColor(P.alpha(P.ramp.metal[2], 0.7))
  g.setLineWidth(1)
  g.rectangle("line", x, y, w, h, 6, 6)
  if title then
    g.setFont(FONT_S)
    g.setColor(P.inkFaint)
    g.print(string.upper(title), x + 10, y + 7)
  end
end

local function meterBar(x, y, w, h, v, col)
  g.setColor(P.alpha(P.black, 0.55))
  g.rectangle("fill", x, y, w, h, 3, 3)
  g.setColor(col)
  g.rectangle("fill", x, y, w * U.saturate(v), h, 3, 3)
end

--- Scrolling RMS history, drawn mirrored so it reads as a waveform envelope.
local function drawScope(x, y, w, h, m, col)
  local n = #m.hist
  local mid = y + h / 2
  -- a filled strip of quads: love's polygon fill needs convex input
  g.setColor(P.alpha(col, 0.22))
  for i = 1, n - 1 do
    local i1 = (m.head + i - 1) % n + 1
    local i2 = (m.head + i) % n + 1
    local v1 = U.saturate(m.hist[i1] * 2.2) * (h / 2 - 1)
    local v2 = U.saturate(m.hist[i2] * 2.2) * (h / 2 - 1)
    local x1 = x + (i - 1) / (n - 1) * w
    local x2 = x + i / (n - 1) * w
    g.polygon("fill", x1, mid - v1, x2, mid - v2, x2, mid + v2, x1, mid + v1)
  end
  g.setColor(P.alpha(col, 0.85))
  g.setLineWidth(1)
  for i = 1, n - 1 do
    local i1 = (m.head + i - 1) % n + 1
    local i2 = (m.head + i) % n + 1
    local v1 = U.saturate(m.hist[i1] * 2.2) * (h / 2 - 1)
    local v2 = U.saturate(m.hist[i2] * 2.2) * (h / 2 - 1)
    local x1 = x + (i - 1) / (n - 1) * w
    local x2 = x + i / (n - 1) * w
    g.line(x1, mid - v1, x2, mid - v2)
    g.line(x1, mid + v1, x2, mid + v2)
  end
  g.setColor(P.alpha(P.inkFaint, 0.3))
  g.line(x, mid, x + w, mid)
end

local BUS_COLOR = {
  master = P.accent, sfx = P.accentCool, music = P.love, ui = P.warn,
}

function S:draw()
  local W, H = g.getDimensions()
  g.clear(P.black)

  if self.rendered then
    g.setFont(FONT_L) g.setColor(P.ink)
    g.print("rendered audio to disk", 40, 40)
    return
  end

  ------------------------------------------------------------------- header
  g.setFont(FONT_XL)
  g.setColor(P.ink)
  g.print("AUDIO", 32, 22)
  g.setFont(FONT_S)
  g.setColor(P.inkFaint)
  g.print("synth -> buses -> sequencer", 148, 40)

  g.setFont(FONT)
  local st = Audio.stats
  local info = string.format(
    "load %.0f ms   %d sounds / %d variants   %.2f MB   voices %d/%d   duck %.2f",
    self.loadTime * 1000, st.sounds, st.variants, st.bytes / 1048576,
    Audio.voiceCount(), Audio.maxVoices, Audio.duckAmount())
  g.setColor(P.inkDim)
  g.print(info, W - g.getFont():getWidth(info) - 32, 34)

  g.setColor(P.alpha(P.ramp.metal[2], 0.8))
  g.rectangle("fill", 32, 72, W - 64, 1)

  -------------------------------------------------------------- bus meters
  local bx, by, bw = 32, 92, 470
  panel(bx, by, bw, 336, "buses")
  local yy = by + 30
  for _, bus in ipairs({ "master", "sfx", "music", "ui" }) do
    local m = Audio.meter(bus)
    local col = BUS_COLOR[bus]
    g.setFont(FONT)
    g.setColor(P.ink)
    g.print(string.upper(bus), bx + 12, yy)
    g.setFont(FONT_S)
    g.setColor(P.inkFaint)
    g.print(string.format("%d voice%s   vol %.2f   rms %.3f   peak %.3f",
            m.voices, m.voices == 1 and "" or "s", Audio.busGain(bus), m.rms, m.peak),
            bx + 78, yy + 3)
    drawScope(bx + 12, yy + 20, bw - 24, 38, m, col)
    meterBar(bx + 12, yy + 60, bw - 24, 6, m.rms * 2.4, col)
    -- peak tick
    g.setColor(P.ink)
    local px = bx + 12 + (bw - 24) * U.saturate(m.peak * 2.4)
    g.rectangle("fill", px - 1, yy + 59, 2, 8)
    yy = yy + 78
  end

  ------------------------------------------------------------- forest / o2
  local d = Music.debug()
  panel(bx, by + 348, bw, 128, "world drivers")
  local wy = by + 378
  local drivers = {
    { "forest (plant chime)", Audio.getForestProgress(), P.ramp.leaf[4] },
    { "O2 (arp layer)", d.o2, P.o2 },
    { "intensity (threat)", d.intensity, P.danger },
  }
  for i, dr in ipairs(drivers) do
    g.setFont(FONT_S) g.setColor(P.inkDim)
    g.print(dr[1], bx + 12, wy + (i - 1) * 30)
    meterBar(bx + 210, wy + (i - 1) * 30 + 1, bw - 268, 10, dr[2], dr[3])
    g.setColor(P.inkFaint)
    g.print(string.format("%.2f", dr[2]), bx + bw - 44, wy + (i - 1) * 30)
  end

  --------------------------------------------------------------- sequencer
  local sx, sy, sw = 528, 92, 546
  panel(sx, sy, sw, 584, "sequencer")

  g.setFont(FONT_XL)
  g.setColor(P.accent)
  g.print(string.upper(d.state), sx + 14, sy + 24)
  g.setFont(FONT)
  g.setColor(P.inkDim)
  g.print(string.format("%s  %s   cycle %d", d.root, d.mode, d.cycle), sx + 14, sy + 66)
  g.setColor(P.ink)
  local bpmStr = string.format("%.0f BPM", d.bpm)
  g.setFont(FONT_L)
  g.print(bpmStr, sx + sw - 14 - g.getFont():getWidth(bpmStr), sy + 30)
  g.setFont(FONT_S)
  g.setColor(P.inkFaint)
  local barStr = string.format("bar %d   beat %d   step %02d", d.bar, d.beat, d.step)
  g.print(barStr, sx + sw - 14 - g.getFont():getWidth(barStr), sy + 58)

  -- chord row
  local cy = sy + 96
  g.setFont(FONT)
  for i, deg in ipairs(d.prog) do
    local cw = (sw - 28) / #d.prog
    local cx = sx + 14 + (i - 1) * cw
    local on = (i == d.chordIndex)
    g.setColor(on and P.alpha(P.accent, 0.22) or P.alpha(P.ramp.metal[1], 0.6))
    g.rectangle("fill", cx + 2, cy, cw - 4, 40, 4, 4)
    g.setColor(on and P.accent or P.inkFaint)
    local nm = on and d.chord or ("°" .. deg)
    g.print(nm, cx + cw / 2 - g.getFont():getWidth(nm) / 2, cy + 11)
  end

  -- 16-step grid
  local gy = cy + 54
  g.setFont(FONT_S)
  g.setColor(P.inkFaint)
  g.print("16TH GRID", sx + 14, gy - 16)
  for i = 0, 15 do
    local cw = (sw - 28) / 16
    local cx = sx + 14 + i * cw
    local on = (i == d.step - 1)
    local strong = (i % 4 == 0)
    g.setColor(on and P.accent or P.alpha(strong and P.ramp.metal[3] or P.ramp.metal[1], 0.8))
    g.rectangle("fill", cx + 1, gy, cw - 2, on and 16 or 10, 2, 2)
  end

  -- layers
  local ly = gy + 42
  g.setFont(FONT_S) g.setColor(P.inkFaint) g.print("LAYERS", sx + 14, ly - 16)
  local LCOL = { pad = P.ramp.rift[3], bass = P.ramp.cobalt[3], arp = P.ramp.leaf[4],
                 bell = P.warn, perc = P.danger, choir = P.love }
  for i, l in ipairs(d.layers) do
    local y = ly + (i - 1) * 34
    g.setFont(FONT)
    g.setColor(P.ink)
    g.print(l, sx + 14, y)
    meterBar(sx + 80, y + 3, sw - 150, 12, d.gains[l], LCOL[l] or P.ink)
    -- target tick
    g.setColor(P.alpha(P.ink, 0.8))
    local tx = sx + 80 + (sw - 150) * U.saturate(d.targets[l])
    g.rectangle("fill", tx - 1, y + 1, 2, 16)
    g.setFont(FONT_S)
    g.setColor(P.inkFaint)
    g.print(string.format("%.2f", d.gains[l]), sx + sw - 52, y + 3)
  end

  -- recent notes
  local ny = ly + 6 * 34 + 12
  g.setFont(FONT_S) g.setColor(P.inkFaint) g.print("NOTES", sx + 14, ny)
  local nx = sx + 60
  for i, n in ipairs(d.notes) do
    local a = U.saturate(1 - n.t / 1.6)
    g.setColor(P.alpha(LCOL[n.inst] or P.ink, 0.25 + 0.75 * a))
    local s = string.format("%s%+d", n.inst:sub(1, 2), n.semis)
    g.print(s, nx, ny)
    nx = nx + g.getFont():getWidth(s) + 10
  end

  ------------------------------------------------------------ recent sounds
  local rx, ry, rw = 1100, 92, W - 1100 - 32
  panel(rx, ry, rw, 584, "triggered")
  g.setFont(FONT)
  for i, r in ipairs(Audio.recent) do
    local y = ry + 30 + (i - 1) * 32
    local a = U.saturate(1 - r.t / 2.4)
    g.setColor(P.alpha(P.accent, 0.14 * a))
    g.rectangle("fill", rx + 8, y - 3, rw - 16, 26, 3, 3)
    g.setColor(P.alpha(P.ink, 0.35 + 0.65 * a))
    g.print(r.name, rx + 14, y)
    g.setFont(FONT_S)
    g.setColor(P.alpha(P.inkFaint, 0.4 + 0.6 * a))
    local s = string.format("%.2f", r.vol)
    g.print(s, rx + rw - 20 - g.getFont():getWidth(s), y + 3)
    meterBar(rx + rw - 150, y + 6, 90, 6, r.vol, P.accentCool)
    g.setFont(FONT)
  end

  -- script position
  g.setFont(FONT_S)
  g.setColor(P.inkFaint)
  g.print(string.format("script %.2f / %.1f s", self.t, LOOP), rx + 14, ry + 560)
  meterBar(rx + 120, ry + 562, rw - 140, 6, self.t / LOOP, P.accent)

  ------------------------------------------------------------- sound bank
  local kx, ky, kw = 32, 692, W - 64
  panel(kx, ky, kw, H - ky - 24, "bank")
  local names = Audio.names()
  local cols = 10
  local cw = (kw - 24) / cols
  g.setFont(FONT_S)
  for i, name in ipairs(names) do
    local c = (i - 1) % cols
    local r = floor((i - 1) / cols)
    local x = kx + 12 + c * cw
    local y = ky + 30 + r * 22
    local hot = 0
    for _, rec in ipairs(Audio.recent) do
      if rec.name == name then hot = max(hot, U.saturate(1 - rec.t / 0.9)) end
    end
    if hot > 0 then
      g.setColor(P.alpha(P.accent, 0.3 * hot))
      g.rectangle("fill", x - 4, y - 3, cw - 8, 18, 3, 3)
    end
    g.setColor(P.mix(P.inkFaint, P.accent, hot))
    g.print(name, x, y)
  end
end

function S:keypressed(k)
  if k == "escape" then love.event.quit() end
  local map = { ["1"] = "title", ["2"] = "day", ["3"] = "dusk", ["4"] = "night",
                ["5"] = "boss", ["6"] = "draft", ["7"] = "ending" }
  if map[k] then Music.setState(map[k]) return end
  if k == "space" then Audio.play("plant") end
  if k == "return" then Audio.play("card_pick") end
end

return S
