-- The game's sound API. Everything is synthesized at load into SoundData and
-- played through a small voice-pooled mixer with buses, ducking, variation and
-- world-positional panning.
--
--   Audio.load()                      -- synthesize the bank (target < 2.5 s)
--   Audio.play(name, opts)            -- opts: volume, pan, pitch (ratio),
--                                     --       semitones, x/y, variation, loop
--   Audio.stop(name | voice)
--   Audio.update(dt, listenerX, listenerY)
--   Audio.setBusVolume("master"|"sfx"|"music"|"ui", v)
--   Audio.duck(amount, dur)
--   Audio.setForestProgress(0..1)     -- lifts the plant chime up the pentatonic
--
-- Nothing here assumes an audio device exists: every love.audio call is guarded
-- so the headless CI run (SDL_AUDIODRIVER=dummy) behaves exactly the same, and
-- the meters are driven from pre-computed RMS envelopes rather than the device.

local U      = require("src.core.util")
local Signal = require("src.core.signal")
local Synth  = require("src.engine.synth")

local Audio = {}

local floor, max, min, abs, random = math.floor, math.max, math.min, math.abs, math.random

Audio.rate = 22050

--------------------------------------------------------------------- constants
local MAX_VOICES     = 40      -- hard concurrency cap (love.js is not generous)
local MAX_PER_SOUND  = 6       -- clones kept per sound; beyond this we steal
-- Voices the score is allowed to keep no matter how loud the battle gets. Under
-- 40 bots and 30 enemies the pool used to saturate at 40/40 with 39 of them on
-- the sfx bus, so the music was evicted by footsteps: the mix turned to mud and
-- the score vanished exactly when it was carrying the most weight.
local MUSIC_RESERVE  = 11
local SFX_CEILING    = MAX_VOICES - MUSIC_RESERVE
local NEAR, FAR      = 260, 1500
local PAN_WIDTH      = 820     -- world units mapped to full pan

--------------------------------------------------------------------- state
Audio.maxVoices = MAX_VOICES
Audio.bus = { master = 0.9, sfx = 1.0, music = 0.62, ui = 0.8 }
Audio.sounds = {}
Audio.voices = {}
Audio.recent = {}              -- ring of recently triggered names, for the demo HUD
Audio.stats  = { sounds = 0, variants = 0, samples = 0, bytes = 0, loadTime = 0,
                 -- per-sound synthesis cost, so the 2.5 s load budget can be
                 -- kept honestly instead of guessed at
                 cost = {} }
Audio.enabled = true
Audio.loaded = false

local duck      = { amount = 0, decay = 0, target = 0 }
local lastPlay  = {}           -- name -> time of last trigger, for the throttle
local clock     = 0            -- seconds since load, advanced by Audio.update
local forest    = 0            -- 0..1 forest progress, drives the plant chime
local listener  = { x = 0, y = 0 }
local meters    = {}
local rng       = U.rng(0xB075)

for _, b in ipairs({ "master", "sfx", "music", "ui" }) do
  meters[b] = { rms = 0, peak = 0, hist = {}, head = 0, voices = 0 }
  for i = 1, 128 do meters[b].hist[i] = 0 end
end

--------------------------------------------------------------------- helpers
local function safe(fn, ...)
  local ok, a = pcall(fn, ...)
  if ok then return a end
  return nil
end

local function hasAudio()
  return Audio.enabled and love and love.audio and love.sound
end

--------------------------------------------------------------- sound definitions
-- Each entry: bus, gain, a builder function(v, n, rng) -> Synth spec, the number
-- of pre-rendered variants, and how much random pitch/level wobble each play gets.
-- Variation is not decoration: it is the difference between a game that sounds
-- alive and a game that sounds like a slot machine.

local D = {}    -- name -> definition

local function def(name, t)
  t.name = name
  t.bus = t.bus or "sfx"
  t.gain = t.gain or 0.8
  t.variants = t.variants or 3
  t.pitchVar = t.pitchVar or 0.03
  t.gainVar = t.gainVar or 0.12
  D[name] = t
  D[#D + 1] = name
  return t
end

--------------------------------------------------------------------- materials
-- Three material identities, expressed as resonator mode sets. Every sound in a
-- family is struck *through* its family's modes, which is what makes forty
-- procedural noises sound like they come from one world instead of forty
-- oscillators that happen to share a mixer.
--
--   BRASS  -- the bots. Struck-bar partial ratios (1 : 2.76 : 5.40 : 8.93),
--             tight Q, a hard mineral ring that decays cleanly.
--   WET    -- the Blight. Low, broad, slightly detuned modes: a body full of
--             fluid. Nothing in this family is allowed a clean partial.
--   GLASS  -- the UI. High, very tight, almost no body, and always some air.
local function brassModes(hz, spread, q)
  spread = spread or 1
  q = q or 1
  return { { hz, 26 * q, 1.0 }, { hz * (1 + 1.756 * spread), 22 * q, 0.5 },
           { hz * (1 + 4.404 * spread), 18 * q, 0.24 },
           { hz * (1 + 7.933 * spread), 13 * q, 0.10 } }
end

local function wetModes(hz)
  return { { hz, 3.4, 1.0 }, { hz * 1.61, 2.6, 0.72 }, { hz * 2.37, 2.0, 0.44 },
           { hz * 4.13, 1.3, 0.18 } }
end

local function glassModes(hz)
  return { { hz, 44, 1.0 }, { hz * 2.02, 36, 0.46 }, { hz * 3.83, 30, 0.26 },
           { hz * 6.41, 22, 0.13 } }
end

------------------------------------------------------------------- the bank
-- PLANT -- the star of the show. The player hears this four hundred times a
-- session, so it has three jobs and cannot fail any of them.
--
--   1. NEVER FATIGUE. The rung ladder is capped at ten steps of a major
--      pentatonic from C4, topping out at A5 (880 Hz). The previous ladder ran
--      2.6 octaves and finished on a 1568 Hz sine -- an ice pick, four hundred
--      times. Higher rungs also ring *shorter* and drier, so a mature forest
--      plants faster and lighter rather than louder and shriller.
--   2. BE A WHOLE SOUND. A knock with real body (a click through low brass
--      modes, 90-260 Hz), the bell in the middle, and a 25 ms air sparkle above
--      6 kHz. The 2019 pass measured 99% of its energy inside one octave band:
--      a naked sine with a wooden knock that was never audible.
--   3. NEVER REPEAT. Two takes per rung -- a hard strike and a soft one -- so
--      the same rung twice running is not the same buffer twice running.
--
-- The rung comes from Audio.setForestProgress(), so as the island fills in the
-- whole forest slowly becomes one rising chord.
local PENTA = Synth.scales.pentaMajor
local PLANT_RUNGS = 10
local PLANT_TAKES = 2
local PLANT_STEPS = PLANT_RUNGS * PLANT_TAKES
local PLANT_BASE = 60                      -- C4

local function plantSpec(v)
  local rung = floor((v - 1) / PLANT_TAKES)          -- 0..RUNGS-1
  local take = (v - 1) % PLANT_TAKES                 -- 0 = hard, 1 = soft
  local up = rung / (PLANT_RUNGS - 1)                -- 0..1 up the ladder
  local hz = Synth.noteToHz(PLANT_BASE + Synth.degree(PENTA, rung + 1))
  local hard = (take == 0)
  -- high rungs ring shorter and drier: brightness climbs, fatigue does not
  local dec  = (1.02 - 0.44 * up) * (hard and 1 or 1.16)
  local knock = (hard and 0.62 or 0.34) * (1 - 0.18 * up)
  local airAmp = (hard and 0.3 or 0.19) * (0.7 + 0.4 * up)
  local bright = hard and 2.7 or 1.75
  local bodyHz = 168 * (hard and 1 or 0.93)
  return {
    dur = 0.45 + dec * 0.95,
    layers = {
      -- 1. the knock. A 1.5 ms click struck through low brass modes: this is
      --    the trowel hitting soil, and it is where all the sub-400 Hz is.
      { osc = "sub", at = 0, amp = knock, spec = {
        dur = 0.3,
        layers = {
          { osc = "noise", env = { type = "perc", a = 0.0002, d = 0.0016, curve = 3 }, amp = 1 },
          { osc = "sine", freq = { from = bodyHz * 1.7, to = bodyHz * 0.62, tau = 0.014 },
            env = { type = "perc", a = 0.0006, d = 0.085, curve = 2.6 }, amp = 0.55 },
        },
        fx = { { "resonate", mix = 0.72, gain = 2.6,
                 modes = { { bodyHz, 9, 1 }, { bodyHz * 2.41, 11, 0.5 },
                           { bodyHz * 4.02, 8, 0.22 }, { 96, 6, 0.7 } } },
               { "svf", type = "hp", cutoff = 62, q = 0.7 } },
        normalize = 0.9, trim = false } },
      -- 2. the bell. FM for the strike, plus two struck-bar partials so it is
      --    mineral rather than a sine with a name.
      { osc = "fm", freq = hz, ratio = 3.01,
        index = { type = "exp", tau = 0.13, peak = bright },
        env = { type = "perc", a = 0.002, d = dec, curve = 1.55 }, amp = 0.5 },
      { osc = "sine", freq = hz, env = { type = "perc", a = 0.005, d = dec * 0.95, curve = 1.6 },
        amp = 0.26 },
      { osc = "sine", freq = hz * 0.5,
        env = { type = "perc", a = 0.008, d = dec * 0.8, curve = 1.9 }, amp = 0.17 },
      { osc = "sine", freq = hz * 2.756,
        env = { type = "perc", a = 0.003, d = dec * 0.3, curve = 2.6 }, amp = 0.085 },
      { osc = "sine", freq = hz * 5.404,
        env = { type = "perc", a = 0.002, d = dec * 0.14, curve = 3 }, amp = 0.035 },
      -- 3. the air. 25 ms of sparkle above 6 kHz -- the part that makes it a
      --    pleasure rather than a notification.
      { osc = "sub", at = 0.001, amp = airAmp, spec = {
        dur = 0.16,
        layers = { { osc = "noise",
                     env = { type = "perc", a = 0.0004, d = 0.028, curve = 3.2 }, amp = 1 } },
        fx = { { "svf", type = "hp", cutoff = 5200, q = 0.7 },
               { "resonate", mix = 0.45, gain = 1.6, modes = glassModes(hz * 8.2) } },
        normalize = 0.85, trim = false } },
      -- 4. soil closing over the seed
      { osc = "pink", env = { type = "perc", a = 0.004, d = 0.19, curve = 2.2 },
        amp = 0.085 },
    },
    fx = {
      { "svf", type = "lp", cutoff = { from = 10500, to = 4600 + 900 * up, tau = 0.16 }, q = 0.7 },
      { "shelf", type = "high", freq = 5200, db = 2.5 },
      { "svf", type = "hp", cutoff = 58, q = 0.7 },
      { "reverb", mix = 0.17 - 0.05 * up, room = 0.62, damp = 0.45 },
    },
    -- loudness-matched, not peak-normalised: the ladder used to swing 4.5 dB in
    -- perceived level as it climbed, which reads as the game randomly shouting.
    loudness = 0.165, loudWin = 0.22, ceiling = 0.94,
  }
end

def("plant", {
  gain = 0.85, variants = PLANT_STEPS, ladder = true, rungs = PLANT_RUNGS,
  takes = PLANT_TAKES, pitchVar = 0.011, gainVar = 0.09, limit = 5, minGap = 0.035,
  build = function(v) return plantSpec(v) end,
})

-- PICKUP -- cobalt into the hand. Glass family: a tight high mode struck for
-- 12 ms with real air over it, so it cuts through a battle without shouting.
def("pickup", {
  gain = 0.42, variants = 5, pitchVar = 0.05, limit = 4, minGap = 0.03,
  build = function(v, n, r)
    local hz = 880 * 2 ^ (r:range(-0.1, 0.1))
    local d = r:range(0.08, 0.14)
    return { dur = 0.3, layers = {
      { osc = "sine", freq = { from = hz * 0.66, to = hz, tau = 0.009 },
        env = { type = "perc", a = 0.001, d = d, curve = 2.6 }, amp = 0.45 },
      { osc = "sine", freq = hz * 3, env = { type = "perc", a = 0.001, d = d * 0.4, curve = 3 },
        amp = 0.13 },
      { osc = "sub", at = 0, amp = 0.55, spec = { dur = 0.12,
        layers = { { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.011, curve = 4 },
                     amp = 1 } },
        fx = { { "resonate", mix = 0.8, gain = 1.5, modes = glassModes(hz * 2.4) },
               { "svf", type = "hp", cutoff = 1400, q = 0.7 } },
        normalize = 0.8, trim = false } },
    }, fx = { { "svf", type = "hp", cutoff = 320, q = 0.7 },
              { "shelf", type = "high", freq = 5000, db = 3 } },
      loudness = 0.13, loudWin = 0.12 }
  end,
})

-- PICKUP_STREAK -- the same blip walking up a pentatonic run; consecutive grabs
-- climb, so a good harvesting line turns into a little melody.
def("pickup_streak", {
  gain = 0.46, variants = 10, ladder = true, rungs = 10, takes = 1, pitchVar = 0.01,
  limit = 4, minGap = 0.03,
  build = function(v)
    local hz = Synth.noteToHz(72 + Synth.degree(PENTA, v))
    return { dur = 0.36, layers = {
      { osc = "sine", freq = { from = hz * 0.75, to = hz, tau = 0.008 },
        env = { type = "perc", a = 0.001, d = 0.13, curve = 2.4 }, amp = 0.5 },
      { osc = "fm", freq = hz * 2, ratio = 2, index = { type = "exp", tau = 0.03, peak = 1.4 },
        env = { type = "perc", a = 0.001, d = 0.09, curve = 3 }, amp = 0.16 },
      { osc = "sub", at = 0, amp = 0.4, spec = { dur = 0.1,
        layers = { { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.008, curve = 4 },
                     amp = 1 } },
        fx = { { "resonate", mix = 0.8, gain = 1.4, modes = glassModes(hz * 3.1) } },
        normalize = 0.75, trim = false } },
    }, fx = { { "shelf", type = "high", freq = 5000, db = 2.5 },
              { "reverb", mix = 0.12, room = 0.5 } },
      loudness = 0.13, loudWin = 0.12 }
  end,
})

-- DEPOSIT_POP -- cobalt landing in the Home Rig: mineral, struck, with a small
-- thunk under it. Quiet enough to fire many times a second while a Harvester
-- unloads, and throttled so a full hopper is a rattle rather than a wall.
def("deposit_pop", {
  gain = 0.45, variants = 5, pitchVar = 0.07, limit = 4, minGap = 0.035,
  build = function(v, n, r)
    local hz = 1240 * r:range(0.86, 1.2)
    local body = 190 * r:range(0.9, 1.15)
    return { dur = 0.4, layers = {
      { osc = "sub", at = 0, amp = 1, spec = { dur = 0.34, layers = {
        { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.0022, curve = 3 }, amp = 1 },
      }, fx = { { "resonate", mix = 0.92, gain = 2.4,
                  modes = brassModes(hz, 0.55 * r:range(0.9, 1.1)) } },
        normalize = 0.85, trim = false } },
      { osc = "sine", freq = { from = body * 1.9, to = body * 0.6, tau = 0.02 },
        env = { type = "perc", a = 0.001, d = 0.08, curve = 3 }, amp = 0.45 },
    }, fx = { { "svf", type = "hp", cutoff = 110, q = 0.7 },
              { "shelf", type = "high", freq = 4200, db = 2 },
              { "reverb", mix = 0.15, room = 0.6 } },
      loudness = 0.15, loudWin = 0.15 }
  end,
})

-- BUILD -- a servo whirr that lifts (start) and a two-part clunk that lands
-- (done). Both run through the bots' brass modes: a Builder is made of the same
-- stuff as the thing it is building.
def("build_start", {
  gain = 0.5, variants = 4, limit = 3,
  build = function(v, n, r)
    local top = 300 * r:range(0.9, 1.12)
    local ramp = r:range(0.13, 0.2)
    return { dur = 0.55, layers = {
      { osc = "saw", freq = { from = 90, to = top, tau = ramp, curve = "lin" },
        env = { a = 0.02, d = 0.1, s = 0.6, r = 0.18 }, amp = 0.2 },
      { osc = "square", freq = { from = 180, to = top * 2, tau = ramp, curve = "lin" },
        duty = r:range(0.25, 0.4),
        env = { a = 0.02, d = 0.1, s = 0.5, r = 0.2 }, amp = 0.09 },
      { osc = "pink", env = { type = "perc", a = 0.01, d = 0.4, curve = 2 }, amp = 0.09 },
    }, fx = { { "resonate", mix = 0.3, gain = 1.2, modes = brassModes(top * 2.6, 0.5) },
              { "svf", type = "lp", cutoff = { from = 1400, to = 5200, tau = 0.2 }, q = 1.5 },
              { "reverb", mix = 0.14 } },
      loudness = 0.12, loudWin = 0.3 }
  end,
})

def("build_done", {
  gain = 0.68, variants = 4, duckMusic = 0.16, duckTime = 0.35,
  build = function(v, n, r)
    local hz = 196 * r:range(0.93, 1.08)
    local ring = 660 * r:range(0.88, 1.16)
    return { dur = 0.8, layers = {
      { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.0025, curve = 3 }, amp = 0.5 },
      { osc = "sine", freq = { from = hz * 1.6, to = hz * 0.5, tau = 0.02 },
        env = { type = "perc", a = 0.001, d = 0.15, curve = 3 }, amp = 0.6 },
      { osc = "sub", at = 0.001, amp = 0.75, spec = { dur = 0.7, layers = {
        { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.004, curve = 3 }, amp = 1 } },
        fx = { { "resonate", mix = 0.95, gain = 2.2, modes = brassModes(ring, 0.8) } },
        normalize = 0.85, trim = false } },
    }, fx = { { "svf", type = "hp", cutoff = 70, q = 0.7 },
              { "softclip", drive = 1.6, mix = 0.5 },
              { "shelf", type = "high", freq = 4600, db = 2 },
              { "reverb", mix = 0.2, room = 0.7 } },
      loudness = 0.19, loudWin = 0.2 }
  end,
})

-- BOT BOOT -- a friendly rising three-note chirp, one timbre per bot type, so
-- you learn to recognise what just woke up without looking. Every note is a
-- pulse struck through the bots' brass modes: small machines, pleased to see
-- you, made of the same metal as everything else they own.
local BOOT_KINDS = { "planter", "builder", "repulsor", "sentry", "harvester", "beacon" }
local BOOT_TUNE = {
  planter   = { base = 72, notes = { 0, 4, 7 },  wave = "square", duty = 0.5,  dur = 0.075,
                chassis = 900,  spread = 0.55 },
  builder   = { base = 64, notes = { 0, 5, 7 },  wave = "square", duty = 0.28, dur = 0.09,
                chassis = 640,  spread = 0.8 },
  repulsor  = { base = 69, notes = { 0, 7, 12 }, wave = "tri",    duty = 0.5,  dur = 0.06,
                chassis = 1350, spread = 0.35 },
  sentry    = { base = 67, notes = { 0, 3, 10 }, wave = "square", duty = 0.18, dur = 0.07,
                chassis = 1080, spread = 0.65 },
  harvester = { base = 62, notes = { 0, 2, 9 },  wave = "saw",    duty = 0.5,  dur = 0.08,
                chassis = 520,  spread = 0.95 },
  beacon    = { base = 76, notes = { 0, 7, 11 }, wave = "sine",   duty = 0.5,  dur = 0.11,
                chassis = 1700, spread = 0.3 },
}

def("bot_boot", {
  gain = 0.5, variants = 6, keyed = BOOT_KINDS, pitchVar = 0.02, limit = 4, minGap = 0.05,
  build = function(v)
    local k = BOOT_TUNE[BOOT_KINDS[v]]
    local layers = {}
    for i = 1, 3 do
      local hz = Synth.noteToHz(k.base + k.notes[i])
      layers[#layers + 1] = { osc = "sub", at = (i - 1) * k.dur * 1.35, amp = 0.9, spec = {
        dur = k.dur * 2.4,
        layers = {
          { osc = k.wave, freq = hz, duty = k.duty,
            env = { type = "perc", a = 0.003, d = k.dur * 1.7, curve = 2.2 }, amp = 0.4 },
          { osc = "sine", freq = hz * 2, env = { type = "perc", a = 0.003, d = k.dur, curve = 3 },
            amp = 0.1 },
          { osc = "noise", env = { type = "perc", a = 0.0002, d = 0.0018, curve = 3 }, amp = 0.3 },
        },
        fx = { { "resonate", mix = 0.34, gain = 1.3, modes = brassModes(k.chassis, k.spread) },
               { "svf", type = "lp", cutoff = 8200, q = 0.8 } },
        normalize = 0.8, trim = false } }
    end
    -- the unfold: a tiny servo tick under the chirp, in the chassis metal
    layers[#layers + 1] = { osc = "sub", at = 0, amp = 0.4, spec = { dur = 0.2,
      layers = { { osc = "noise", env = { type = "perc", a = 0.0005, d = 0.02, curve = 4 },
                   amp = 1 } },
      fx = { { "resonate", mix = 0.7, gain = 1.6, modes = brassModes(k.chassis * 1.7, 0.4) } },
      normalize = 0.6, trim = false } }
    return { dur = k.dur * 5.2 + 0.35, layers = layers,
             fx = { { "shelf", type = "high", freq = 5200, db = 2 },
                    { "reverb", mix = 0.16, room = 0.6 } },
             loudness = 0.15, loudWin = 0.25 }
  end,
})

-- BOT CHATTER -- wordless speech: a formant-ish two-band pulse wobbling over a
-- short contour, resonated through the speaker's own chassis so a field of bots
-- murmurs in one material. Hard-limited to four at once: forty bots talking over
-- each other is not charm, it is noise.
def("bot_chatter", {
  gain = 0.3, variants = 8, pitchVar = 0.11, gainVar = 0.22, limit = 4, minGap = 0.07,
  build = function(v, n, r)
    local base = Synth.noteToHz(58 + r:int(0, 12))
    local wob = r:range(9, 17)
    local dep = r:range(0.05, 0.14)
    local seg = r:range(0.08, 0.16)
    local up = r:chance(0.5) and 1 or -1
    local chassis = r:range(600, 1500)
    return { dur = seg * 3 + 0.24, layers = {
      { osc = "square", duty = 0.34,
        freq = function(t) return base * (1 + dep * math.sin(t * wob)) * (1 + up * 0.18 * t) end,
        env = { type = "bp", points = { { 0, 0 }, { 0.02, 1 }, { seg, 0.8 }, { seg * 2, 0.9 },
                                        { seg * 3, 0 } } }, amp = 0.3 },
      { osc = "sine", freq = function(t) return base * 2 * (1 + dep * math.sin(t * wob)) end,
        env = { type = "bp", points = { { 0, 0 }, { 0.03, 0.5 }, { seg * 3, 0 } } }, amp = 0.12 },
    }, fx = {
      { "svf", type = "bp", cutoff = r:range(700, 1500), q = 2.4 },
      { "resonate", mix = 0.28, gain = 1.2, modes = brassModes(chassis, 0.45) },
      { "svf", type = "lp", cutoff = 4200, q = 0.7 },
      { "reverb", mix = 0.14 },
    }, loudness = 0.1, loudWin = 0.2 }
  end,
})

def("bot_hurt", {
  gain = 0.6, variants = 5, limit = 4, minGap = 0.04,
  build = function(v, n, r)
    local hz = Synth.noteToHz(70 + r:int(-4, 4))
    local chassis = r:range(700, 1400)
    return { dur = 0.4, layers = {
      { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.002, curve = 3 }, amp = 0.5 },
      { osc = "square", duty = r:range(0.3, 0.48), freq = { from = hz, to = hz * 0.6, tau = 0.06 },
        env = { type = "perc", a = 0.001, d = r:range(0.12, 0.2), curve = 2.4 }, amp = 0.34 },
      { osc = "noise", env = { type = "perc", a = 0.0005, d = 0.05, curve = 3 }, amp = 0.22 },
    }, fx = {
      -- struck metal, not a broken console: the bitcrush this used to wear made
      -- the bots and the Blight the same material, which is a lie about both
      { "resonate", mix = 0.42, gain = 1.5, modes = brassModes(chassis, 0.7) },
      { "svf", type = "lp", cutoff = 6500, q = 1 },
      { "svf", type = "hp", cutoff = 130, q = 0.7 },
    }, loudness = 0.15, loudWin = 0.18 }
  end,
})

-- BOT DOWN -- the one that has to hurt. A small machine you named has stopped.
--
-- Three notes. The 2019 pass got the interval wrong (root, minor third below,
-- then a *fourth* below -- an ambiguous shape that spells nothing), fired them
-- 170 ms apart so the whole farewell was over in a third of a second, and gave
-- its three "variants" the same timbre a semitone apart.
--
-- Now: root -> minor third below -> the fifth below *that*, which spells a minor
-- triad falling away from you (D5, B4, F#4). The spacing widens as it falls --
-- 0.26 then 0.32 -- because a thing running out of power slows down. Each note
-- is struck through the bots' brass modes, the last one sags 8 cents flat and
-- rings for two seconds, and at 1.5 s a single relay clicks and the eye goes
-- out. That click is the sound of the bot being gone.
def("bot_down", {
  gain = 0.85, variants = 3, pitchVar = 0.012, gainVar = 0.08, limit = 3, minGap = 0.06,
  duckMusic = 0.28, duckTime = 1.1,
  build = function(v, n, r)
    local root = 74 + ({ 0, -1, 1 })[v]            -- D5-ish
    local notes = { root, root - 3, root - 8 }         -- minor triad, falling
    local at    = { 0, 0.26, 0.58 }
    local spread = ({ 1, 0.9, 1.12 })[v]               -- the chassis differs per bot
    local layers = {}
    for i = 1, 3 do
      local last = (i == 3)
      local hz = Synth.noteToHz(notes[i]) * (last and 0.9954 or 1)   -- the sag
      local dec = last and 1.9 or 0.62
      layers[#layers + 1] = { osc = "sub", at = at[i], amp = 1 - (i - 1) * 0.08, spec = {
        dur = dec + 0.35,
        layers = {
          { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.0022, curve = 3 }, amp = 0.7 },
          { osc = "fm", freq = hz, ratio = 2.01,
            index = { type = "exp", tau = 0.1, peak = 1.7 - (i - 1) * 0.35 },
            env = { type = "perc", a = 0.003, d = dec, curve = 1.7 }, amp = 0.34 },
          { osc = "sine", freq = hz * 0.5,
            env = { type = "perc", a = 0.01, d = dec * 0.85, curve = 2 }, amp = 0.2 },
        },
        fx = { { "resonate", mix = 0.5, gain = 1.5, modes = brassModes(hz, 0.5 * spread) },
               { "svf", type = "lp", cutoff = 7000 - i * 900, q = 0.7 } },
        normalize = 0.85, trim = false } }
    end
    -- the chassis sagging: a low body that gives the bot weight on a phone
    layers[#layers + 1] = { osc = "sine", freq = { from = 138, to = 96, tau = 0.7 },
      env = { type = "bp", points = { { 0, 0 }, { 0.01, 0.5 }, { 0.9, 0.28 }, { 2.3, 0 } } },
      amp = 0.34 }
    -- the capacitor winding down
    layers[#layers + 1] = { osc = "sine", freq = { from = 640 * spread, to = 58, tau = 0.62 },
      env = { type = "bp", points = { { 0, 0 }, { 0.06, 0.24 }, { 1.4, 0.06 }, { 1.9, 0 } } },
      amp = 0.28 }
    -- and one relay click, after the filter has already closed, as the eye goes
    -- out. It is the last thing you hear, and it is the point of the sound.
    layers[#layers + 1] = { osc = "sub", at = 1.52 + (v - 1) * 0.04, amp = 1, spec = {
      dur = 0.55,
      layers = { { osc = "noise", env = { type = "perc", a = 0.0002, d = 0.0016, curve = 3 },
                   amp = 1 } },
      fx = { { "resonate", mix = 0.9, gain = 2.6, modes = brassModes(1180 * spread, 0.5, 1.3) },
             { "reverb", mix = 0.3, room = 0.85, damp = 0.3 } },
      normalize = 0.5, trim = false } }
    return { dur = 3.1, layers = layers, fx = {
      { "svf", type = "lp", cutoff = { from = 7200, to = 2200, tau = 1.1 }, q = 0.8 },
      { "svf", type = "hp", cutoff = 62, q = 0.7 },
      { "reverb", mix = 0.34, room = 0.88, damp = 0.3 },
    }, loudness = 0.16, loudWin = 0.3, ceiling = 0.94 }
  end,
})

-- BOT REVIVE -- the opposite of bot_down, and it must sound like it: the same
-- brass chassis, the same three-note shape, but rising and opening out.
def("bot_revive", {
  gain = 0.7, variants = 3, duckMusic = 0.2, duckTime = 0.7,
  build = function(v, n, r)
    local root = 62 + r:int(-2, 2)
    local spread = r:range(0.85, 1.15)
    local layers = {}
    for i, sst in ipairs({ 0, 7, 12, 16 }) do
      local hz = Synth.noteToHz(root + sst)
      layers[#layers + 1] = { osc = "sub", at = (i - 1) * r:range(0.075, 0.1), amp = 0.85, spec = {
        dur = 0.95,
        layers = {
          { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.0018, curve = 3 }, amp = 0.4 },
          { osc = "fm", freq = hz, ratio = 2, index = { type = "exp", tau = 0.1, peak = 1.2 },
            env = { type = "perc", a = 0.006, d = 0.75, curve = 2 }, amp = 0.4 } },
        fx = { { "resonate", mix = 0.3, gain = 1.3, modes = brassModes(hz * 2, 0.6 * spread) } },
        normalize = 0.8, trim = false } }
    end
    layers[#layers + 1] = { osc = "pink", env = { type = "ar", a = 0.28, r = 0.3 }, amp = 0.1 }
    return { dur = 1.6, layers = layers, fx = {
      { "svf", type = "lp", cutoff = { from = 1200, to = 7500, tau = 0.25 }, q = 0.9 },
      { "shelf", type = "high", freq = 5200, db = 2 },
      { "reverb", mix = 0.3, room = 0.8 } },
      loudness = 0.17, loudWin = 0.3 }
  end,
})

-- PLAYER VERBS ------------------------------------------------------------
def("dash", {
  gain = 0.5, variants = 5, pitchVar = 0.06, limit = 3, minGap = 0.05,
  build = function(v, n, r)
    local top = 3000 * r:range(0.8, 1.25)
    return { dur = 0.42, layers = {
      { osc = "pink", env = { type = "bp", points = { { 0, 0 }, { 0.012, 1 }, { 0.09, 0.5 },
                                                      { 0.3, 0 } } }, amp = 0.5 },
      { osc = "sine", freq = { from = 460, to = 120, tau = r:range(0.05, 0.08) },
        env = { type = "perc", a = 0.002, d = 0.16, curve = 2.5 }, amp = 0.22 },
    }, fx = {
      { "svf", type = "bp", cutoff = { from = 900, to = top, tau = 0.08 }, q = 1.5 },
      { "svf", type = "hp", cutoff = 240, q = 0.7 },
      { "shelf", type = "high", freq = 5200, db = 2.5 },
      { "reverb", mix = 0.12 },
    }, loudness = 0.13, loudWin = 0.15 }
  end,
})

def("shove_swing", {
  gain = 0.42, variants = 5, pitchVar = 0.07, limit = 3, minGap = 0.04,
  build = function(v, n, r)
    return { dur = 0.32, layers = {
      { osc = "noise", env = { type = "bp", points = { { 0, 0 }, { r:range(0.02, 0.04), 1 },
                                                       { r:range(0.12, 0.2), 0 } } }, amp = 0.5 },
    }, fx = {
      { "svf", type = "bp", cutoff = { from = 700, to = 2600 * r:range(0.8, 1.3), tau = 0.06 },
        q = 2.2 },
      { "svf", type = "hp", cutoff = 400, q = 0.7 },
      { "shelf", type = "high", freq = 5000, db = 2 },
    }, loudness = 0.11, loudWin = 0.12 }
  end,
})

-- SHOVE_HIT -- a click and a thump, which is what impact actually is: a hard
-- transient (contact) plus a body resonance (mass). The 2019 pass had 86% of its
-- energy under 250 Hz and nothing at all above 800 -- all thud, no contact, so
-- it vanished the moment anything else was playing. The click now sits on top of
-- the limiter, not under it.
def("shove_hit", {
  gain = 0.85, variants = 5, pitchVar = 0.05, limit = 4, minGap = 0.03,
  duckMusic = 0.2, duckTime = 0.3,
  build = function(v, n, r)
    local body = 110 * r:range(0.86, 1.18)
    return { dur = 0.42, layers = {
      { osc = "sine", freq = { from = body * 2.4, to = body, tau = 0.018 },
        env = { type = "perc", a = 0.001, d = r:range(0.14, 0.2), curve = 2.6 }, amp = 0.75 },
      { osc = "tri", freq = body * 3.1, env = { type = "perc", a = 0.001, d = 0.06, curve = 3 },
        amp = 0.18 },
      -- the contact: 2 ms of broadband, kept out of the saturator so it stays a
      -- click rather than becoming part of the thump
      { osc = "sub", at = 0, amp = 0.85, spec = { dur = 0.16, layers = {
        { osc = "noise", env = { type = "perc", a = 0.0002, d = 0.0035, curve = 3 }, amp = 1 },
        { osc = "noise", env = { type = "perc", a = 0.0004, d = 0.02, curve = 5 }, amp = 0.35 } },
        fx = { { "svf", type = "hp", cutoff = 1300, q = 0.7 },
               { "resonate", mix = 0.35, gain = 1.4, modes = wetModes(760 * r:range(0.9, 1.1)) } },
        normalize = 0.9, trim = false } },
    }, fx = {
      { "softclip", drive = 2.2, mix = 0.6 },
      { "svf", type = "lp", cutoff = 8000, q = 0.9 },
      { "svf", type = "hp", cutoff = 55, q = 0.7 },
      { "reverb", mix = 0.13 },
    }, loudness = 0.21, loudWin = 0.15 }
  end,
})

def("pulse_charge", {
  gain = 0.5, variants = 3, loopable = true, pitchVar = 0.01, limit = 1,
  build = function(v, n, r)
    local top = 520 * r:range(0.96, 1.05)
    return { dur = 0.9, layers = {
      { osc = "saw", freq = { from = 70, to = top, tau = 0.85, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 0.1, 0.4 }, { 0.85, 1 }, { 0.9, 0.9 } } },
        amp = 0.22, detune = -6 },
      { osc = "saw", freq = { from = 70, to = top * 1.008, tau = 0.85, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 0.1, 0.4 }, { 0.85, 1 }, { 0.9, 0.9 } } },
        amp = 0.22, detune = 7 },
      { osc = "sine", freq = { from = 140, to = top * 2, tau = 0.85, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 0.5, 0.3 }, { 0.9, 0.8 } } }, amp = 0.16 },
      { osc = "pink", env = { type = "bp", points = { { 0, 0 }, { 0.9, 0.5 } } }, amp = 0.12 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 600, to = 5600, tau = 0.5 }, q = 2.6 },
      { "chorus", mix = 0.3, rate = r:range(1.1, 1.7) },
      { "shelf", type = "high", freq = 5000, db = 2 },
    }, trim = false, loudness = 0.14, loudWin = 0.3, fadeOut = 0.02 }
  end,
})

-- PULSE_RELEASE -- the shockwave. The transient has to be the loudest sample in
-- the file or it is a swell, not a release.
def("pulse_release", {
  gain = 0.95, variants = 4, pitchVar = 0.03, duckMusic = 0.45, duckTime = 0.7, limit = 2,
  build = function(v, n, r)
    local drop = r:range(0.07, 0.11)
    return { dur = 1.4, layers = {
      { osc = "noise", env = { type = "perc", a = 0.0002, d = 0.0035, curve = 3 }, amp = 0.9 },
      { osc = "sine", freq = { from = 1000, to = 42, tau = drop },
        env = { type = "perc", a = 0.0008, d = 0.45, curve = 2.4 }, amp = 0.8 },
      { osc = "noise", env = { type = "perc", a = 0.001, d = 0.3, curve = 3.2 }, amp = 0.3 },
      { osc = "tri", freq = { from = 320, to = 60, tau = 0.15 },
        env = { type = "perc", a = 0.002, d = 0.36, curve = 2.6 }, amp = 0.28 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 8000, to = 700, tau = 0.22 }, q = 1.1 },
      { "softclip", drive = 1.7, mix = 0.5 },
      { "svf", type = "hp", cutoff = 40, q = 0.7 },
      { "reverb", mix = 0.28, room = 0.8, damp = 0.3 },
    }, loudness = 0.22, loudWin = 0.2 }
  end,
})

def("player_hurt", {
  gain = 0.8, variants = 4, duckMusic = 0.3, duckTime = 0.5, limit = 2,
  build = function(v, n, r)
    return { dur = 0.62, layers = {
      { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.003, curve = 3 }, amp = 0.55 },
      { osc = "sine", freq = { from = 320 * r:range(0.9, 1.1), to = 80, tau = 0.05 },
        env = { type = "perc", a = 0.001, d = 0.22, curve = 2.4 }, amp = 0.6 },
      { osc = "noise", env = { type = "perc", a = 0.0006, d = r:range(0.07, 0.12), curve = 3 },
        amp = 0.35 },
      { osc = "square", duty = r:range(0.36, 0.48), freq = 62 * r:range(0.92, 1.08),
        env = { type = "perc", a = 0.002, d = 0.3, curve = 2 }, amp = 0.2 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 5000, to = 500, tau = 0.15 }, q = 1.2 },
      { "softclip", drive = 2.2, mix = 0.7 },
      { "reverb", mix = 0.16 },
    }, loudness = 0.19, loudWin = 0.2 }
  end,
})

-- PLAYER_DOWN -- the suit failing: everything drops an octave, a heartbeat-ish
-- sub thud, and the world muffles (a long lowpass sweep down to almost nothing).
def("player_down", {
  rate = 11025,
  gain = 0.9, variants = 3, duckMusic = 0.6, duckTime = 2.0, limit = 1,
  build = function(v, n, r)
    local beat = r:range(0.56, 0.68)
    return { dur = 2.7, layers = {
      { osc = "sine", freq = { from = 190, to = 44, tau = 0.5 },
        env = { type = "bp", points = { { 0, 0 }, { 0.015, 1 }, { 0.9, 0.35 }, { 2.4, 0 } } },
        amp = 0.7 },
      { osc = "sine", freq = 55, env = { type = "perc", a = 0.005, d = 0.5, curve = 2 }, amp = 0.4 },
      { osc = "sine", freq = 52, env = { type = "bp", points = { { 0, 0 }, { beat, 0 },
                                                                 { beat + 0.03, 0.7 },
                                                                 { beat + 0.35, 0 } } }, amp = 0.4 },
      { osc = "pink", env = { type = "bp", points = { { 0, 0.5 }, { 0.4, 0.2 }, { 2.4, 0 } } },
        amp = 0.2 },
      { osc = "square", duty = 0.5, freq = { from = 440 * r:range(0.9, 1.1), to = 110, tau = 0.8 },
        env = { type = "bp", points = { { 0, 0.2 }, { 1.6, 0.05 }, { 2.4, 0 } } }, amp = 0.12 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 4000, to = 260, tau = 0.7 }, q = 1 },
      { "bitcrush", bits = 7, rateDiv = 2 },
      { "reverb", mix = 0.35, room = 0.88, damp = 0.25 },
    }, loudness = 0.17, loudWin = 0.4 }
  end,
})

-- BLIGHT ------------------------------------------------------------------
-- The Blight is wet and organic. Nothing in this family is allowed a clean
-- partial, a metallic ring or a bitcrusher: the 2019 pass gave the Blight the
-- same 4-bit digital grit as the bots, which said the two were made of the same
-- stuff. They are not. Everything here is built from noise and brown noise
-- pushed through low, broad, detuned resonances -- a body full of fluid -- with
-- a slow random wobble on the formant so it never sits still.
def("enemy_step", {
  rate = 11025,
  gain = 0.26, variants = 8, pitchVar = 0.14, gainVar = 0.3, limit = 4, minGap = 0.045,
  build = function(v, n, r)
    local body = r:range(120, 200)
    return { dur = 0.24, layers = {
      { osc = "noise", env = { type = "perc", a = 0.001, d = r:range(0.03, 0.09), curve = 3 },
        amp = 0.4 },
      { osc = "brown", env = { type = "perc", a = 0.002, d = r:range(0.05, 0.11), curve = 2.4 },
        amp = 0.35 },
      { osc = "sine", freq = { from = body, to = 60, tau = 0.02 },
        env = { type = "perc", a = 0.001, d = 0.07, curve = 3 }, amp = 0.4 },
    }, fx = { { "resonate", mix = 0.5, gain = 1.4, modes = wetModes(r:range(240, 430)) },
              { "svf", type = "lp", cutoff = r:range(900, 1800), q = 1.3 } },
      loudness = 0.1, loudWin = 0.1 }
  end,
})

def("enemy_hurt", {
  gain = 0.55, variants = 6, pitchVar = 0.1, limit = 5, minGap = 0.03,
  build = function(v, n, r)
    local form = r:range(320, 620)
    local wob = r:range(14, 26)
    return { dur = 0.32, layers = {
      { osc = "saw", freq = function(t)
          return (380 * math.exp(-t / 0.05) + 90) * (1 + 0.06 * math.sin(t * wob))
        end,
        env = { type = "perc", a = 0.001, d = r:range(0.11, 0.19), curve = 2.6 }, amp = 0.4 },
      { osc = "noise", env = { type = "perc", a = 0.0006, d = 0.05, curve = 4 }, amp = 0.3 },
      { osc = "brown", env = { type = "perc", a = 0.003, d = 0.13, curve = 2.2 }, amp = 0.28 },
    }, fx = {
      { "resonate", mix = 0.62, gain = 1.5, modes = wetModes(form) },
      { "svf", type = "lp", cutoff = 3600, q = 1 },
      { "softclip", drive = 2, mix = 0.6 },
    }, loudness = 0.14, loudWin = 0.15 }
  end,
})

def("enemy_die", {
  rate = 11025,
  gain = 0.7, variants = 5, pitchVar = 0.08, limit = 4, minGap = 0.04,
  build = function(v, n, r)
    local form = r:range(260, 520)
    local pop = r:range(0.1, 0.18)
    return { dur = 0.95, layers = {
      { osc = "saw", freq = { from = r:range(260, 360), to = 40, tau = r:range(0.09, 0.16) },
        env = { type = "perc", a = 0.001, d = 0.35, curve = 2 }, amp = 0.42 },
      { osc = "noise", env = { type = "perc", a = 0.001, d = 0.3, curve = 2.5 }, amp = 0.35 },
      { osc = "brown", env = { type = "bp", points = { { 0, 0 }, { pop, 0.6 }, { 0.7, 0 } } },
        amp = 0.4 },
      -- the burst: a wet pop, not a chip-tune explosion
      { osc = "sub", at = 0, amp = 0.8, spec = { dur = 0.4, layers = {
        { osc = "noise", env = { type = "perc", a = 0.0004, d = 0.02, curve = 3 }, amp = 1 } },
        fx = { { "resonate", mix = 0.85, gain = 1.8, modes = wetModes(form * 1.7) } },
        normalize = 0.85, trim = false } },
    }, fx = {
      { "resonate", mix = 0.34, gain = 1.3, modes = wetModes(form) },
      { "svf", type = "lp", cutoff = { from = 4500, to = 400, tau = 0.25 }, q = 1.1 },
      { "softclip", drive = 1.7, mix = 0.5 },
      { "reverb", mix = 0.2 },
    }, loudness = 0.16, loudWin = 0.25 }
  end,
})

-- CHOMP -- wet, organic, upsetting: two bites with a pitch drop between them
-- and a low gulp. It should read as "your tree is dying".
def("chomp", {
  rate = 11025,
  gain = 0.6, variants = 6, pitchVar = 0.09, limit = 3, minGap = 0.09,
  build = function(v, n, r)
    local g = r:range(0.85, 1.2)
    local gap = r:range(0.08, 0.13)
    return { dur = 0.5, layers = {
      { osc = "noise", env = { type = "bp", points = { { 0, 0 }, { 0.008, 1 }, { 0.06, 0.1 },
                                                       { gap, 0.75 }, { gap + 0.1, 0 } } },
        amp = 0.5 },
      { osc = "sine", freq = { from = 260 * g, to = 70 * g, tau = 0.05 },
        env = { type = "perc", a = 0.002, d = 0.2, curve = 2.2 }, amp = 0.4 },
      { osc = "brown", env = { type = "perc", a = 0.01, d = 0.28, curve = 2 }, amp = 0.32 },
    }, fx = {
      { "resonate", mix = 0.6, gain = 1.5, modes = wetModes(r:range(300, 520)) },
      { "svf", type = "bp", cutoff = { from = 1600 * g, to = 500, tau = 0.08 }, q = 1.6 },
      { "softclip", drive = 1.6, mix = 0.5 },
    }, loudness = 0.14, loudWin = 0.2 }
  end,
})

-- TREE_FALL -- the loss sound. Fibre tearing, then a heavy body impact and a
-- settling rustle. Long, so it lands, and it ducks the score to make room.
def("tree_fall", {
  rate = 11025,
  gain = 0.85, variants = 4, pitchVar = 0.04, limit = 2, minGap = 0.12,
  duckMusic = 0.3, duckTime = 1.2,
  build = function(v, n, r)
    local hit = r:range(0.74, 0.92)
    return { dur = 2.3, layers = {
      { osc = "noise", env = { type = "bp", points = { { 0, 0 }, { 0.06, 0.55 }, { 0.5, 0.3 },
                                                       { 0.75, 0.1 } } }, amp = 0.4 },
      { osc = "saw", freq = { from = 190 * r:range(0.9, 1.1), to = 46, tau = 0.35 },
        env = { type = "bp", points = { { 0, 0 }, { 0.03, 0.5 }, { 0.8, 0.1 }, { 1.0, 0 } } },
        amp = 0.22 },
      { osc = "sub", at = hit, amp = 1, spec = { dur = 1.2, layers = {
          { osc = "sine", freq = { from = 120, to = 38, tau = 0.05 },
            env = { type = "perc", a = 0.001, d = 0.5, curve = 2 }, amp = 0.9 },
          { osc = "noise", env = { type = "perc", a = 0.002, d = 0.25, curve = 2.5 }, amp = 0.5 },
        }, fx = { { "svf", type = "lp", cutoff = 900, q = 1 } }, normalize = 0.9, trim = false } },
      { osc = "sub", at = hit + 0.18, amp = 0.5, spec = { dur = 1.1, layers = {
          { osc = "pink", env = { type = "bp", points = { { 0, 0.6 }, { 0.5, 0.2 }, { 1.0, 0 } } },
            amp = 0.4 } },
        fx = { { "svf", type = "bp", cutoff = 2600, q = 1.2 } }, normalize = 0.7, trim = false } },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 3600, to = 1400, tau = 1.0 }, q = 0.8 },
      { "reverb", mix = 0.26, room = 0.8, damp = 0.4 },
    }, loudness = 0.2, loudWin = 0.3 }
  end,
})

def("spit", {
  gain = 0.5, variants = 5, pitchVar = 0.1, limit = 4, minGap = 0.05,
  build = function(v, n, r)
    local top = r:range(1300, 1800)
    return { dur = 0.42, layers = {
      { osc = "noise", env = { type = "perc", a = 0.002, d = r:range(0.08, 0.15), curve = 3 },
        amp = 0.4 },
      { osc = "sine", freq = { from = 700 * r:range(0.85, 1.15), to = top, tau = 0.09,
                               curve = "lin" },
        env = { type = "perc", a = 0.003, d = 0.13, curve = 2 }, amp = 0.25 },
      { osc = "brown", env = { type = "perc", a = 0.004, d = 0.1, curve = 2.4 }, amp = 0.2 },
    }, fx = {
      { "resonate", mix = 0.45, gain = 1.4, modes = wetModes(r:range(500, 900)) },
      { "svf", type = "bp", cutoff = { from = 1200, to = 3200, tau = 0.1 }, q = 2.6 },
      { "delay", time = 0.07, fb = 0.2, mix = 0.2 },
    }, loudness = 0.12, loudWin = 0.15 }
  end,
})

-- SIPHON_DRAIN -- a loop you want to end. Two saws a semitone apart (beating),
-- amplitude-wobbled, through a nasal wet formant with a sub underneath.
-- Crossfade-spliced into a genuine seamless loop: the old one faded in and out
-- every two seconds, so the drone breathed at 0.5 Hz and gave itself away.
def("siphon_drain", {
  rate = 11025,
  gain = 0.4, variants = 3, loop = true, pitchVar = 0.02,
  build = function(v, n, r)
    local base = 92 + v * 3
    return { dur = 2.6, layers = {
      { osc = "saw", freq = base, amp = 0.26, detune = -14 },
      { osc = "saw", freq = base * 1.0595, amp = 0.24, detune = 11 },
      { osc = "sine", freq = base * 0.5, amp = 0.3 },
      { osc = "square", duty = 0.2, freq = base * 2,
        env = function(t) return 0.5 + 0.5 * math.sin(t * 5.5 * 6.2831853) end, amp = 0.1 },
      { osc = "brown", amp = 0.12 },
    }, fx = {
      { "resonate", mix = 0.55, gain = 1.4, modes = wetModes(620) },
      { "svf", type = "lp", cutoff = 2400, q = 0.8 },
      { "softclip", drive = 1.5, mix = 0.5 },
      { "chorus", mix = 0.25, rate = 0.23 },
    }, trim = false, loop = true, xfade = 0.6, loudness = 0.12, loudWin = 0.5 }
  end,
})

def("rift_open", {
  gain = 0.9, variants = 2, duckMusic = 0.4, duckTime = 1.8, limit = 2,
  build = function(v, n, r)
    local ring = 220 * ({ 1, 0.94 })[v]
    return { dur = 2.5, layers = {
      { osc = "noise", env = { type = "bp", points = { { 0, 0 }, { 0.4, 0.6 }, { 0.8, 1 },
                                                       { 1.6, 0.2 }, { 2.2, 0 } } }, amp = 0.4 },
      { osc = "brown", env = { type = "bp", points = { { 0, 0 }, { 0.9, 0.5 }, { 2.2, 0 } } },
        amp = 0.3 },
      { osc = "saw", freq = { from = 40, to = 150, tau = 1.0, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 0.9, 0.6 }, { 2.2, 0 } } }, amp = 0.2,
        detune = -9 },
      { osc = "saw", freq = { from = 41, to = 149, tau = 1.0, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 0.9, 0.6 }, { 2.2, 0 } } }, amp = 0.2,
        detune = 12 },
      { osc = "fm", freq = ring, ratio = 5.13, index = { type = "bp",
        points = { { 0, 0 }, { 0.8, 6 }, { 1.4, 2 }, { 2.2, 0 } } },
        env = { type = "bp", points = { { 0, 0 }, { 0.7, 0.4 }, { 2.0, 0 } } }, amp = 0.3 },
    }, fx = {
      { "resonate", mix = 0.28, gain = 1.2, modes = wetModes(340) },
      { "svf", type = "lp", cutoff = { from = 500, to = 4600, tau = 0.9 }, q = 1.6 },
      { "reverb", mix = 0.4, room = 0.9, damp = 0.2 },
      { "softclip", drive = 1.4, mix = 0.4 },
    }, loudness = 0.2, loudWin = 0.4 }
  end,
})

def("rift_close", {
  rate = 11025,
  gain = 0.85, variants = 3, duckMusic = 0.3, duckTime = 0.9, limit = 2,
  build = function(v, n, r)
    local thud = 90 * r:range(0.9, 1.12)
    local at = r:range(0.55, 0.68)
    return { dur = 1.7, layers = {
      { osc = "noise", env = { type = "bp", points = { { 0, 0.8 }, { 0.35, 0.5 }, { 0.6, 0 } } },
        amp = 0.4 },
      { osc = "saw", freq = { from = 220 * r:range(0.9, 1.1), to = 30, tau = 0.3 },
        env = { type = "bp", points = { { 0, 0.6 }, { 0.5, 0.2 }, { 0.7, 0 } } }, amp = 0.3 },
      { osc = "sub", at = at, amp = 1, spec = { dur = 1.0, layers = {
        { osc = "sine", freq = { from = thud, to = 34, tau = 0.06 },
          env = { type = "perc", a = 0.001, d = 0.45, curve = 2 }, amp = 0.9 },
        { osc = "noise", env = { type = "perc", a = 0.001, d = 0.09, curve = 4 }, amp = 0.4 },
      }, normalize = 0.9, trim = false } },
    }, fx = {
      { "resonate", mix = 0.24, gain = 1.2, modes = wetModes(300) },
      { "svf", type = "lp", cutoff = { from = 3600, to = 600, tau = 0.4 }, q = 1 },
      { "reverb", mix = 0.28, room = 0.8 },
    }, loudness = 0.19, loudWin = 0.3 }
  end,
})

-- WAVE_START -- the dusk siren, and the single most load-bearing 3 seconds in
-- the game: it has to drop the player's stomach.
--
-- The 2019 pass put 95% of its energy below 200 Hz. On a laptop, a phone, or the
-- WebAssembly build it was inaudible -- a stomach drop nobody could hear. This
-- one is built in four parts that each read on their own speaker:
--   * 0.00 INHALE   -- a reversed noise swell that pulls you toward the downbeat
--                      while a sub already sits under it, so the drop is *felt*
--                      before it is heard;
--   * 0.62 THE HIT  -- the thing the whole cue exists for. A hard transient into
--                      a 140 -> 44 Hz sub glide. There was no impact at all
--                      before, which is why nothing dropped;
--   * 0.62 THE HORN -- two detuned saws a *falling* minor second apart, in the
--                      300-900 Hz band where every speaker lives. Sour, beating,
--                      and moving down: dread, not alarm;
--   * 1.9  THE RING -- a far-off metallic wash through a huge dark room, so it
--                      reads as coming from outside the island.
def("wave_start", {
  bus = "sfx", gain = 1.0, variants = 2, pitchVar = 0.008, gainVar = 0.05,
  duckMusic = 0.6, duckTime = 2.4, limit = 1,
  build = function(v, n, r)
    local base = 560 * ({ 1, 0.965 })[v]
    local HIT = 0.62
    return { dur = 3.6, layers = {
      -- the inhale
      { osc = "pink", env = { type = "bp", points = { { 0, 0 }, { HIT - 0.02, 0.85 },
                                                      { HIT + 0.05, 0.12 }, { 2.6, 0.04 },
                                                      { 3.4, 0 } } }, amp = 0.3 },
      { osc = "sine", freq = { from = 62, to = 118, tau = HIT, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { HIT, 0.55 }, { HIT + 0.02, 0 } } },
        amp = 0.4 },
      -- the hit: transient, then the sub that falls out from under the player
      { osc = "sub", at = HIT, amp = 1, spec = { dur = 2.9, layers = {
        { osc = "noise", env = { type = "perc", a = 0.0004, d = 0.02, curve = 4 }, amp = 0.55 },
        { osc = "sine", freq = { from = 150, to = 44, tau = 0.85 },
          env = { type = "bp", points = { { 0, 0 }, { 0.005, 1 }, { 0.35, 0.62 }, { 1.7, 0.36 },
                                          { 2.7, 0 } } }, amp = 0.95 },
        { osc = "tri", freq = { from = 300, to = 88, tau = 0.85 },
          env = { type = "bp", points = { { 0, 0 }, { 0.004, 0.7 }, { 0.9, 0.2 }, { 2.2, 0 } } },
          amp = 0.3 },
      }, fx = { { "svf", type = "lp", cutoff = { from = 5200, to = 700, tau = 0.5 }, q = 0.9 } },
        normalize = 0.95, trim = false } },
      -- the horn: the part a phone speaker can actually reproduce
      { osc = "sub", at = HIT, amp = 1.25, spec = { dur = 2.8, layers = {
        { osc = "saw", freq = { from = base, to = base * 0.62, tau = 1.7, curve = "lin" },
          env = { type = "bp", points = { { 0, 0 }, { 0.02, 1 }, { 1.9, 0.72 }, { 2.7, 0 } } },
          amp = 0.34, detune = -11 },
        { osc = "saw", freq = { from = base * 0.944, to = base * 0.585, tau = 1.7, curve = "lin" },
          env = { type = "bp", points = { { 0, 0 }, { 0.025, 1 }, { 1.9, 0.72 }, { 2.7, 0 } } },
          amp = 0.34, detune = 14 },
        -- an octave up, quiet: the part a phone speaker reproduces at all
        { osc = "square", duty = 0.31,
          freq = { from = base * 2, to = base * 1.24, tau = 1.7, curve = "lin" },
          env = { type = "bp", points = { { 0, 0 }, { 0.03, 0.42 }, { 1.9, 0.3 }, { 2.6, 0 } } },
          amp = 0.2 },
      }, fx = {
        { "svf", type = "hp", cutoff = 260, q = 0.7 },
        { "svf", type = "lp", cutoff = { from = 3400, to = 1800, tau = 1.4 }, q = 0.9 },
        { "softclip", drive = 1.9, mix = 0.6 },
        { "shelf", type = "high", freq = 2400, db = 3 },
      }, normalize = 0.95, trim = false } },
      -- the ring from outside the island
      { osc = "fm", freq = 466, ratio = 7.02,
        index = { type = "bp", points = { { 0, 0 }, { HIT, 0 }, { HIT + 0.5, 3.6 },
                                          { 2.4, 1.1 }, { 3.4, 0 } } },
        env = { type = "bp", points = { { 0, 0 }, { HIT, 0 }, { HIT + 0.3, 0.26 },
                                        { 2.7, 0.07 }, { 3.4, 0 } } }, amp = 0.24 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 1400, to = 6000, tau = 0.75 }, q = 1.0 },
      { "svf", type = "hp", cutoff = 34, q = 0.7 },
      { "bitcrush", bits = 9, rateDiv = 2 },
      { "softclip", drive = 1.4, mix = 0.5 },
      { "reverb", mix = 0.4, room = 0.93, damp = 0.24 },
    }, loudness = 0.24, loudWin = 0.25, ceiling = 0.97, fadeOut = 0.03 }
  end,
})

-- DAWN -- the exhale. A warm major-add9 chord that arrives softly and resolves,
-- with a bell on the ninth. The only sound in the game with no transient.
def("dawn", {
  rate = 11025,
  bus = "sfx", gain = 0.75, variants = 2, pitchVar = 0.005, limit = 1,
  build = function(v)
    local root = 55 + (v - 1) * 2
    local layers = {}
    for i, s in ipairs({ 0, 7, 12, 16, 19, 26 }) do
      local hz = Synth.noteToHz(root + s)
      layers[#layers + 1] = { osc = "saw", freq = hz, detune = (i % 2 == 0) and 6 or -6,
        env = { type = "bp", points = { { 0, 0 }, { 0.5 + i * 0.08, 1 }, { 2.2, 0.8 }, { 3.6, 0 } } },
        amp = 0.12 }
      layers[#layers + 1] = { osc = "sine", freq = hz * 2,
        env = { type = "bp", points = { { 0, 0 }, { 0.9 + i * 0.1, 0.5 }, { 3.4, 0 } } }, amp = 0.05 }
    end
    layers[#layers + 1] = { osc = "sub", at = 0.35, amp = 0.7, spec = { dur = 2.2, layers = {
      { osc = "fm", freq = Synth.noteToHz(root + 26), ratio = 2,
        index = { type = "exp", tau = 0.12, peak = 1.4 },
        env = { type = "perc", a = 0.006, d = 1.9, curve = 2 }, amp = 0.5 } },
      normalize = 0.8, trim = false } }
    return { dur = 3.8, layers = layers, fx = {
      { "svf", type = "lp", cutoff = { from = 700, to = 3600, tau = 1.1 }, q = 0.8 },
      { "chorus", mix = 0.35, rate = 0.35, depth = 0.005 },
      { "reverb", mix = 0.38, room = 0.88, damp = 0.35 },
    }, loudness = 0.15, loudWin = 0.5, fadeIn = 0.02 }
  end,
})

-- BOSS --------------------------------------------------------------------
def("boss_step", {
  rate = 11025,
  gain = 1.0, variants = 4, pitchVar = 0.04, duckMusic = 0.3, duckTime = 0.5, limit = 2,
  build = function(v, n, r)
    local thud = 92 * r:range(0.92, 1.1)
    return { dur = 1.5, layers = {
      { osc = "sine", freq = { from = thud, to = 28, tau = 0.06 },
        env = { type = "perc", a = 0.001, d = r:range(0.5, 0.68), curve = 1.8 }, amp = 0.95 },
      { osc = "noise", env = { type = "perc", a = 0.0005, d = 0.12, curve = 3 }, amp = 0.4 },
      { osc = "tri", freq = 62 * r:range(0.92, 1.09),
        env = { type = "perc", a = 0.002, d = 0.3, curve = 2 }, amp = 0.25 },
      -- debris: the island's own gravel, thrown up and coming back down
      { osc = "sub", at = 0.02, amp = 0.45, spec = { dur = 0.95, layers = {
        { osc = "pink", env = { type = "bp", points = { { 0, 0.5 }, { 0.4, 0.15 }, { 0.9, 0 } } },
          amp = 0.4 } }, fx = { { "svf", type = "bp", cutoff = r:range(2600, 3800), q = 1.4 } },
        normalize = 0.6, trim = false } },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 2600, to = 500, tau = 0.3 }, q = 1 },
      { "softclip", drive = 2, mix = 0.6 },
      { "reverb", mix = 0.24, room = 0.85 },
    }, loudness = 0.22, loudWin = 0.25 }
  end,
})

def("boss_hurt", {
  gain = 0.9, variants = 4, pitchVar = 0.05, limit = 3, minGap = 0.05,
  build = function(v, n, r)
    local hz = 150 * r:range(0.9, 1.14)
    return { dur = 1.05, layers = {
      { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.0035, curve = 3 }, amp = 0.7 },
      { osc = "fm", freq = hz, ratio = r:range(1.6, 1.85),
        index = { type = "exp", tau = 0.08, peak = 5 },
        env = { type = "perc", a = 0.001, d = 0.55, curve = 2 }, amp = 0.55 },
      { osc = "sine", freq = { from = 220, to = 55, tau = 0.05 },
        env = { type = "perc", a = 0.001, d = 0.25, curve = 2.4 }, amp = 0.5 },
    }, fx = {
      { "resonate", mix = 0.25, gain = 1.3, modes = brassModes(hz * 4, 0.9) },
      { "softclip", drive = 2.6, mix = 0.7 },
      { "svf", type = "lp", cutoff = 7000, q = 0.9 },
      { "reverb", mix = 0.2, room = 0.8 },
    }, loudness = 0.2, loudWin = 0.2 }
  end,
})

def("boss_beam", {
  gain = 0.95, variants = 2, duckMusic = 0.35, duckTime = 1.6, limit = 1,
  build = function(v, n, r)
    local warn = 180 * ({ 1, 0.95 })[v]
    local fire = 1.35 + (v - 2) * 0.06
    return { dur = 2.7, layers = {
      { osc = "saw", freq = { from = warn, to = warn * 1.78, tau = 1.2, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 1.2, 0.7 }, { fire, 1 }, { 2.4, 0 } } },
        amp = 0.26, detune = -8 },
      { osc = "square", duty = 0.24, freq = { from = 90, to = 160, tau = 1.2, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 1.3, 0.6 }, { 2.4, 0 } } }, amp = 0.18 },
      { osc = "noise", env = { type = "bp", points = { { 0, 0 }, { fire - 0.02, 0.2 },
                                                       { fire + 0.03, 1 }, { 2.3, 0 } } },
        amp = 0.45 },
      { osc = "sine", freq = { from = 1200, to = 240, tau = 0.5 },
        env = { type = "bp", points = { { 0, 0 }, { fire, 0 }, { fire + 0.04, 0.8 },
                                        { 2.4, 0 } } }, amp = 0.4 },
    }, fx = {
      { "svf", type = "bp", cutoff = { from = 800, to = 2600, tau = 1.0 }, q = 1.8 },
      { "softclip", drive = 2, mix = 0.6 },
      { "reverb", mix = 0.3, room = 0.86 },
    }, loudness = 0.2, loudWin = 0.35 }
  end,
})

-- UI ----------------------------------------------------------------------
-- Glass and light. Everything here is a very short excitation struck through
-- high, tight modes with real air above 6 kHz, and everything here lives above
-- 800 Hz so it is never masked by the score -- which spends most of a night
-- below 200 Hz where the old card_pick and ui_back also lived.
def("ui_move", {
  bus = "ui", gain = 0.35, variants = 5, pitchVar = 0.04, minGap = 0.02,
  build = function(v, n, r)
    local hz = 1180 * r:range(0.93, 1.08)
    return { dur = 0.16, layers = {
      { osc = "sine", freq = hz, env = { type = "perc", a = 0.001, d = r:range(0.04, 0.07),
                                         curve = 3 }, amp = 0.4 },
      { osc = "sub", at = 0, amp = 0.5, spec = { dur = 0.09,
        layers = { { osc = "noise", env = { type = "perc", a = 0.0002, d = 0.005, curve = 4 },
                     amp = 1 } },
        fx = { { "resonate", mix = 0.85, gain = 1.6, modes = glassModes(hz * 2.7) } },
        normalize = 0.8, trim = false } },
    }, fx = { { "svf", type = "hp", cutoff = 600, q = 0.7 },
              { "shelf", type = "high", freq = 5000, db = 3 } },
      loudness = 0.11, loudWin = 0.08 }
  end,
})

def("ui_select", {
  bus = "ui", gain = 0.5, variants = 4, pitchVar = 0.03, minGap = 0.02,
  build = function(v, n, r)
    local hz = 660 * r:range(0.94, 1.07)
    local gap = r:range(0.045, 0.07)
    return { dur = 0.4, layers = {
      { osc = "sub", at = 0, amp = 1, spec = { dur = 0.22, layers = {
        { osc = "noise", env = { type = "perc", a = 0.0002, d = 0.004, curve = 3 }, amp = 0.8 },
        { osc = "sine", freq = hz, env = { type = "perc", a = 0.001, d = 0.09, curve = 3 },
          amp = 0.5 } },
        fx = { { "resonate", mix = 0.4, gain = 1.5, modes = glassModes(hz * 4) } },
        normalize = 0.85, trim = false } },
      { osc = "sub", at = gap, amp = 1, spec = { dur = 0.3, layers = {
        { osc = "noise", env = { type = "perc", a = 0.0002, d = 0.003, curve = 3 }, amp = 0.7 },
        { osc = "sine", freq = hz * 1.5, env = { type = "perc", a = 0.001, d = 0.16, curve = 2.6 },
          amp = 0.5 },
        { osc = "sine", freq = hz * 3, env = { type = "perc", a = 0.001, d = 0.06, curve = 3 },
          amp = 0.12 } },
        fx = { { "resonate", mix = 0.4, gain = 1.5, modes = glassModes(hz * 6) } },
        normalize = 0.85, trim = false } },
    }, fx = { { "svf", type = "hp", cutoff = 400, q = 0.7 },
              { "shelf", type = "high", freq = 5200, db = 3 },
              { "reverb", mix = 0.12 } },
      loudness = 0.15, loudWin = 0.15 }
  end,
})

def("ui_back", {
  bus = "ui", gain = 0.45, variants = 4, pitchVar = 0.03, minGap = 0.02,
  build = function(v, n, r)
    local hz = 660 * r:range(0.94, 1.07)
    local gap = r:range(0.04, 0.065)
    return { dur = 0.34, layers = {
      { osc = "sub", at = 0, amp = 1, spec = { dur = 0.2, layers = {
        { osc = "noise", env = { type = "perc", a = 0.0002, d = 0.003, curve = 3 }, amp = 0.7 },
        { osc = "sine", freq = hz, env = { type = "perc", a = 0.001, d = 0.08, curve = 3 },
          amp = 0.5 } },
        fx = { { "resonate", mix = 0.4, gain = 1.4, modes = glassModes(hz * 4) } },
        normalize = 0.85, trim = false } },
      { osc = "sub", at = gap, amp = 1, spec = { dur = 0.26, layers = {
        { osc = "noise", env = { type = "perc", a = 0.0002, d = 0.003, curve = 3 }, amp = 0.6 },
        { osc = "sine", freq = hz * 0.75, env = { type = "perc", a = 0.001, d = 0.13, curve = 2.6 },
          amp = 0.5 } },
        fx = { { "resonate", mix = 0.35, gain = 1.4, modes = glassModes(hz * 3) } },
        normalize = 0.85, trim = false } },
    }, fx = { { "svf", type = "hp", cutoff = 380, q = 0.7 },
              { "shelf", type = "high", freq = 5200, db = 2 },
              { "svf", type = "lp", cutoff = 9000, q = 0.8 } },
      loudness = 0.13, loudWin = 0.15 }
  end,
})

def("card_hover", {
  bus = "ui", gain = 0.3, variants = 5, pitchVar = 0.06, minGap = 0.03,
  build = function(v, n, r)
    return { dur = 0.28, layers = {
      { osc = "pink", env = { type = "bp", points = { { 0, 0 }, { 0.02, 1 },
                                                      { r:range(0.08, 0.15), 0 } } }, amp = 0.35 },
      { osc = "sine", freq = 1600 * r:range(0.85, 1.2),
        env = { type = "perc", a = 0.002, d = 0.07, curve = 3 }, amp = 0.12 },
    }, fx = { { "svf", type = "bp", cutoff = { from = 1800, to = 4200 * r:range(0.9, 1.15),
                                               tau = 0.06 }, q = 1.6 },
              { "shelf", type = "high", freq = 5600, db = 3 } },
      loudness = 0.1, loudWin = 0.12 }
  end,
})

-- CARD_PICK -- the thunk. The 2019 pass put 61% of its energy in 80-250 Hz,
-- which is precisely where the night and boss score live: the single most
-- rewarding UI moment in the game was masked every time it mattered. It is now
-- glass first (a bright struck face), with just enough table under it to feel
-- like a card landing rather than a chime.
def("card_pick", {
  bus = "ui", gain = 0.8, variants = 4, pitchVar = 0.02, duckMusic = 0.22, duckTime = 0.4,
  build = function(v, n, r)
    local face = 2400 * r:range(0.9, 1.14)
    local body = 150 * r:range(0.92, 1.1)
    return { dur = 0.75, layers = {
      { osc = "sub", at = 0, amp = 1, spec = { dur = 0.3, layers = {
        { osc = "noise", env = { type = "perc", a = 0.0002, d = 0.004, curve = 3 }, amp = 1 },
        { osc = "noise", env = { type = "perc", a = 0.0004, d = 0.03, curve = 5 }, amp = 0.3 } },
        fx = { { "resonate", mix = 0.55, gain = 1.8, modes = glassModes(face) },
               { "svf", type = "hp", cutoff = 900, q = 0.7 } },
        normalize = 0.9, trim = false } },
      { osc = "sine", freq = { from = body * 1.6, to = body * 0.62, tau = 0.02 },
        env = { type = "perc", a = 0.001, d = 0.1, curve = 2.8 }, amp = 0.45 },
      -- the confirming fifth, up an octave from where it used to hide
      { osc = "tri", freq = 523, env = { type = "perc", a = 0.004, d = 0.3, curve = 2.2 },
        amp = 0.18 },
      { osc = "tri", freq = 784, env = { type = "perc", a = 0.006, d = 0.34, curve = 2.2 },
        amp = 0.13 },
    }, fx = {
      { "svf", type = "hp", cutoff = 95, q = 0.7 },
      { "softclip", drive = 1.6, mix = 0.5 },
      { "shelf", type = "high", freq = 5200, db = 2.5 },
      { "reverb", mix = 0.16 },
    }, loudness = 0.18, loudWin = 0.2 }
  end,
})

-- O2 milestone -- a shimmering ascending arpeggio; the sky getting better.
def("o2_milestone", {
  bus = "ui", gain = 0.6, variants = 2, pitchVar = 0.01, limit = 1,
  build = function(v)
    local root = 67 + (v - 2) * 2
    local layers = {}
    for i, sst in ipairs({ 0, 4, 7, 11, 14 }) do
      local hz = Synth.noteToHz(root + sst)
      layers[#layers + 1] = { osc = "sub", at = (i - 1) * 0.07, amp = 0.85, spec = {
        dur = 1.15, layers = {
          { osc = "noise", env = { type = "perc", a = 0.0002, d = 0.002, curve = 3 }, amp = 0.3 },
          { osc = "fm", freq = hz, ratio = 4.01,
            index = { type = "exp", tau = 0.05, peak = 1.3 },
            env = { type = "perc", a = 0.003, d = 0.9, curve = 2.2 }, amp = 0.4 } },
        fx = { { "resonate", mix = 0.3, gain = 1.4, modes = glassModes(hz * 3) } },
        normalize = 0.8, trim = false } }
    end
    return { dur = 2.0, layers = layers, fx = {
      { "shelf", type = "high", freq = 5600, db = 3 },
      { "delay", time = 0.14, fb = 0.35, mix = 0.22 },
      { "reverb", mix = 0.3, room = 0.85, damp = 0.3 } },
      loudness = 0.16, loudWin = 0.35 }
  end,
})

--------------------------------------------------------------- music one-shots
-- The score is a sequencer, not a stem: engine/music.lua schedules these.
-- One chromatic octave per instrument; octaves come free from source pitch.
local MUSIC_BASE = 48   -- C3

local MUSIC = {}
local function mdef(name, t)
  t.name = name
  t.pitchVar = t.pitchVar or 0.0016   -- ~3 cents: alive, but still in tune
  t.gainVar = t.gainVar or 0.07
  t.variants = 12
  MUSIC[name] = t
  MUSIC[#MUSIC + 1] = name
  return t
end

mdef("pad", { gain = 0.5, dur = 2.5, rate = 11025, sparse = 4, build = function(hz)
  return { dur = 2.5, layers = {
    { osc = "saw", freq = hz, detune = -7, env = { a = 0.55, d = 0.6, s = 0.75, r = 1.1 }, amp = 0.16 },
    { osc = "saw", freq = hz, detune = 8, env = { a = 0.6, d = 0.6, s = 0.75, r = 1.1 }, amp = 0.16 },
    { osc = "tri", freq = hz * 2, env = { a = 0.7, d = 0.5, s = 0.6, r = 1.0 }, amp = 0.1 },
    { osc = "sine", freq = hz * 0.5, env = { a = 0.5, d = 0.4, s = 0.7, r = 1.0 }, amp = 0.08 },
  }, fx = {
    { "svf", type = "lp", cutoff = { from = 400, to = 2400, tau = 1.1 }, q = 0.9 },
    -- the bed is harmony, not weight: everything under 90 Hz belongs to the bass
    { "svf", type = "hp", cutoff = 90, q = 0.7 },
    { "chorus", mix = 0.4, rate = 0.28, depth = 0.006 },
    { "reverb", mix = 0.42, room = 0.9, damp = 0.35 },
  }, normalize = 0.78, trim = false, fadeIn = 0.02, fadeOut = 0.25 }
end })

-- BASS -- the instrument that was drowning the whole score. It used to be a
-- near-pure sine at hz/2, played an octave down by the sequencer, so its
-- fundamental landed near 36 Hz: 85-89% of the night and boss mixes sat below
-- 80 Hz, where a laptop, a phone and the web build reproduce nothing at all.
-- The fundamental is now at the written pitch with real 2nd and 3rd harmonics
-- over it, so the bass line is *audible as a line* on a small speaker, and a
-- 42 Hz high-pass stops the rest of the mix paying for headroom nobody hears.
mdef("bass", { gain = 0.72, dur = 1.0, rate = 11025, sparse = 2, build = function(hz)
  return { dur = 1.0, layers = {
    { osc = "sine", freq = hz, env = { type = "perc", a = 0.005, d = 0.7, curve = 1.7 },
      amp = 0.62 },
    { osc = "sine", freq = hz * 0.5, env = { type = "perc", a = 0.008, d = 0.5, curve = 1.9 },
      amp = 0.2 },
    { osc = "tri", freq = hz * 2, env = { type = "perc", a = 0.004, d = 0.26, curve = 2.2 },
      amp = 0.2 },
    { osc = "square", duty = 0.3, freq = hz * 3,
      env = { type = "perc", a = 0.002, d = 0.07, curve = 3 }, amp = 0.08 },
  }, fx = {
    { "svf", type = "lp", cutoff = { from = 1600, to = 420, tau = 0.3 }, q = 1.1 },
    { "svf", type = "hp", cutoff = 42, q = 0.7 },
    { "softclip", drive = 1.5, mix = 0.5 },
  }, normalize = 0.82, trim = false }
end })

-- BELL -- the melody instrument. It carries the theme in every state and it is
-- the only thing left at the ending, so it gets a mineral partial structure and
-- real air rather than an FM sine with reverb on it.
mdef("bell", { gain = 0.5, dur = 1.8, sparse = 3, build = function(hz)
  return { dur = 1.8, layers = {
    { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.0018, curve = 3 }, amp = 0.22 },
    { osc = "fm", freq = hz, ratio = 3.01, index = { type = "exp", tau = 0.09, peak = 2.3 },
      env = { type = "perc", a = 0.004, d = 1.5, curve = 1.9 }, amp = 0.45 },
    { osc = "sine", freq = hz, env = { type = "perc", a = 0.006, d = 1.3, curve = 1.7 },
      amp = 0.22 },
    { osc = "sine", freq = hz * 2, env = { type = "perc", a = 0.004, d = 0.6, curve = 2.6 },
      amp = 0.1 },
    { osc = "sine", freq = hz * 2.756, env = { type = "perc", a = 0.003, d = 0.3, curve = 2.8 },
      amp = 0.055 },
  }, fx = {
    { "svf", type = "hp", cutoff = 120, q = 0.7 },
    { "shelf", type = "high", freq = 5000, db = 2 },
    { "reverb", mix = 0.36, room = 0.9, damp = 0.3 },
  }, normalize = 0.8, trim = false }
end })

mdef("pluck", { gain = 0.4, dur = 0.9, sparse = 2, build = function(hz)
  return { dur = 0.9, layers = { { osc = "pluck", freq = hz, damp = 0.42, decay = 0.9955,
                                   soft = 0.4, amp = 0.7 } },
    fx = { { "svf", type = "lp", cutoff = 5200, q = 0.9 },
           { "svf", type = "hp", cutoff = 150, q = 0.7 },
           { "shelf", type = "high", freq = 4600, db = 2 },
           { "reverb", mix = 0.24, room = 0.8 } }, normalize = 0.8, trim = false }
end })

mdef("choir", { gain = 0.5, dur = 2.2, rate = 11025, sparse = 4, build = function(hz)
  return { dur = 2.2, layers = {
    { osc = "additive", freq = hz, env = { a = 0.5, d = 0.5, s = 0.7, r = 1.0 }, amp = 0.4,
      partials = { { 1, 0.5 }, { 2, 0.26, 5 }, { 3, 0.16, -6 }, { 5, 0.07, 8 },
                   { 1.005, 0.3 } } },
    { osc = "pink", env = { a = 0.6, d = 0.5, s = 0.25, r = 1.0 }, amp = 0.05 },
  }, fx = {
    { "svf", type = "bp", cutoff = 760, q = 1.5 },
    { "svf", type = "lp", cutoff = 2600, q = 0.8 },
    { "svf", type = "hp", cutoff = 110, q = 0.7 },
    { "chorus", mix = 0.45, rate = 0.19, depth = 0.007 },
    { "reverb", mix = 0.45, room = 0.92, damp = 0.28 },
  }, normalize = 0.75, trim = false, fadeIn = 0.03, fadeOut = 0.3 }
end })

-- Percussion (pitchless, so it lives in the music bank with 3 variants each).
local PERC = {
  -- the kick used to be pure sub under a 2.6 kHz lowpass; it now has a beater
  -- click so it reads as a pulse on a laptop instead of a pressure change
  kick = { gain = 0.85, rate = 11025, spec = function(r) return { dur = 0.7, layers = {
    { osc = "sine", freq = { from = 165 * r:range(0.94, 1.07), to = 48, tau = 0.035 },
      env = { type = "perc", a = 0.001, d = r:range(0.32, 0.46), curve = 1.8 }, amp = 0.9 },
    { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.004, curve = 3 }, amp = 0.32 },
    { osc = "tri", freq = 96, env = { type = "perc", a = 0.001, d = 0.09, curve = 3 }, amp = 0.2 },
  }, fx = { { "softclip", drive = 1.7, mix = 0.6 },
            { "svf", type = "hp", cutoff = 42, q = 0.7 },
            { "svf", type = "lp", cutoff = 4200, q = 0.8 } },
    normalize = 0.85, trim = false } end },
  hat = { gain = 0.3, spec = function(r) return { dur = 0.28, layers = {
    { osc = "noise", env = { type = "perc", a = 0.0004, d = r:range(0.025, 0.1), curve = 4 },
      amp = 0.5 } },
    fx = { { "svf", type = "hp", cutoff = r:range(4600, 6400), q = 1.1 },
           { "resonate", mix = 0.25, gain = 1.2, modes = glassModes(r:range(7000, 9000)) } },
    normalize = 0.6, trim = false } end },
  shaker = { gain = 0.3, spec = function(r) return { dur = 0.32, layers = {
    { osc = "pink", env = { type = "bp", points = { { 0, 0 }, { r:range(0.008, 0.02), 1 },
                                                    { r:range(0.07, 0.14), 0 } } }, amp = 0.5 } },
    fx = { { "svf", type = "bp", cutoff = r:range(3400, 5400), q = 1.4 } },
    normalize = 0.55, trim = false } end },
  tom = { gain = 0.55, rate = 11025, spec = function(r) return { dur = 0.6, layers = {
    { osc = "sine", freq = { from = 210 * r:range(0.85, 1.2), to = 82, tau = r:range(0.06, 0.13) },
      env = { type = "perc", a = 0.001, d = r:range(0.28, 0.42), curve = 2 }, amp = 0.8 },
    { osc = "noise", env = { type = "perc", a = 0.001, d = 0.05, curve = 4 }, amp = 0.16 },
  }, fx = { { "svf", type = "lp", cutoff = 3400, q = 0.9 },
            { "svf", type = "hp", cutoff = 55, q = 0.7 },
            { "reverb", mix = 0.18 } },
    normalize = 0.8, trim = false } end },
}

--------------------------------------------------------------------- loading
-- Sources are userdata, so each one lives in a small slot table that carries the
-- "is this voice using it" flag.
local function mkSlot(sd, loopFlag)
  local slot = { s = nil, busy = false }
  if not hasAudio() then return slot end
  local src = safe(love.audio.newSource, sd, "static")
  if src and loopFlag then safe(src.setLooping, src, true) end
  slot.s = src
  return slot
end

local function registerBuffer(entry, buf, loopFlag)
  local sd = buf:toSoundData()
  entry.data[#entry.data + 1] = sd
  entry.env[#entry.env + 1] = buf:envelope(50)
  entry.len[#entry.len + 1] = buf.n / buf.rate
  entry.src[#entry.src + 1] = { mkSlot(sd, loopFlag) }
  Audio.stats.variants = Audio.stats.variants + 1
  Audio.stats.samples = Audio.stats.samples + buf.n * buf.ch
  Audio.stats.bytes = Audio.stats.bytes + buf.n * buf.ch * 2
end

function Audio.load()
  if Audio.loaded then return Audio.stats.loadTime end
  local t0 = (love and love.timer) and love.timer.getTime() or os.clock()

  Synth.rate = Audio.rate
  rng = U.rng(0xB075)

  -- sfx bank
  for i = 1, #D do
    local name = D[i]
    local d = D[name]
    local entry = { def = d, data = {}, env = {}, len = {}, src = {}, next = 1 }
    local tS = (love and love.timer) and love.timer.getTime() or os.clock()
    for v = 1, d.variants do
      local spec = d.build(v, d.variants, rng)
      spec.rate = d.rate or Audio.rate
      registerBuffer(entry, Synth.render(spec), d.loop)
    end
    Audio.stats.cost[name] = ((love and love.timer) and love.timer.getTime() or os.clock()) - tS
    if d.keyed then
      entry.index = {}
      for k, key in ipairs(d.keyed) do entry.index[key] = k end
    end
    Audio.sounds[name] = entry
    Audio.stats.sounds = Audio.stats.sounds + 1
  end

  -- music instrument bank: one chromatic octave each
  Audio.music = {}
  for i = 1, #MUSIC do
    local name = MUSIC[i]
    local m = MUSIC[name]
    local entry = { def = m, data = {}, env = {}, len = {}, src = {}, music = true }
    local t0m = (love and love.timer) and love.timer.getTime() or os.clock()
    -- `sparse` renders every Nth semitone and fills the gaps by resampling the
    -- nearest anchor. A pad moved a semitone by resampling is indistinguishable
    -- from one synthesised there, and it is three times cheaper to build.
    local step = m.sparse or 1
    local anchors = {}
    for st = 0, 11 do
      local a = floor(st / step) * step
      local buf
      if st == a then
        local spec = m.build(Synth.noteToHz(MUSIC_BASE + st))
        spec.rate = m.rate or Audio.rate
        buf = Synth.render(spec)
        anchors[a] = buf
      else
        buf = anchors[a]:copy():pitchShift(st - a)
      end
      registerBuffer(entry, buf, false)
    end
    local tMus = ((love and love.timer) and love.timer.getTime() or os.clock()) - t0m
    Audio.music[name] = entry
    Audio.sounds["mus_" .. name] = entry
    entry.bus = "music"
    Audio.stats.cost["mus_" .. name] = tMus
  end

  -- percussion (pitchless, so it lives in the music bank with 3 variants each)
  local perc = PERC
  for name, p in pairs(perc) do
    local entry = { def = { name = name, gain = p.gain, pitchVar = 0.04, gainVar = 0.12,
                            bus = "music", variants = 3 },
                    data = {}, env = {}, len = {}, src = {}, music = true, bus = "music" }
    for v = 1, 3 do
      local spec = p.spec(rng)
      spec.rate = p.rate or Audio.rate
      registerBuffer(entry, Synth.render(spec), false)
    end
    Audio.music[name] = entry
    Audio.sounds["mus_" .. name] = entry
  end

  Audio.loaded = true
  local t1 = (love and love.timer) and love.timer.getTime() or os.clock()
  Audio.stats.loadTime = t1 - t0
  Signal.emit("audio:loaded", Audio.stats)
  return Audio.stats.loadTime
end

--------------------------------------------------------------------- playback
function Audio.setBusVolume(bus, v)
  if Audio.bus[bus] then Audio.bus[bus] = U.clamp(v, 0, 1) end
end

function Audio.getBusVolume(bus) return Audio.bus[bus] or 0 end

--- Duck the music bus (impacts, boss slams, the siren).
function Audio.duck(amount, dur)
  amount = U.saturate(amount or 0.35)
  if amount > duck.amount then duck.amount = amount end
  duck.decay = max(0.05, dur or 0.5)
end

--- 0..1 forest progress: how far up the pentatonic the plant chime rings.
function Audio.setForestProgress(p) forest = U.saturate(p or 0) end
function Audio.getForestProgress() return forest end

local function busGain(bus)
  local g = (Audio.bus[bus] or 1) * Audio.bus.master
  if bus == "music" then g = g * (1 - duck.amount * 0.75) end
  return g
end
Audio.busGain = busGain

local function pushRecent(name, vol)
  local r = Audio.recent
  table.insert(r, 1, { name = name, t = 0, vol = vol })
  for i = #r, 13, -1 do r[i] = nil end
end

--- Find a playable source for `entry` variant `vi`, cloning or stealing.
local function acquire(entry, vi)
  local list = entry.src[vi]
  if not list then return nil end
  for i = 1, #list do
    if not list[i].busy then return list[i] end
  end
  if #list < MAX_PER_SOUND and list[1].s then
    local c = safe(list[1].s.clone, list[1].s)
    if c then
      local slot = { s = c, busy = false }
      list[#list + 1] = slot
      return slot
    end
  end
  -- steal the oldest voice using this variant
  local oldest, oi = nil, nil
  for i = 1, #Audio.voices do
    local v = Audio.voices[i]
    if v.entry == entry and v.vi == vi and (not oldest or v.t > oldest.t) then oldest, oi = v, i end
  end
  if oldest then
    local slot = oldest.slot
    Audio.killVoice(oi)
    return slot
  end
  return list[1]
end

function Audio.killVoice(i)
  local v = Audio.voices[i]
  if not v then return end
  if v.slot then
    if v.slot.s then safe(v.slot.s.stop, v.slot.s) end
    v.slot.busy = false
  end
  v.dead = true
  U.removeSwap(Audio.voices, i)
end

--- Play a sound. Returns a voice handle (or nil if the sound does not exist).
function Audio.play(name, opts)
  if not Audio.loaded then Audio.load() end
  local entry = Audio.sounds[name]
  if not entry then return nil end
  local d = entry.def

  -- Retrigger throttle. Thirty enemies stepping in the same frame is not thirty
  -- footsteps, it is one smear; firing it once and letting the rest fold into it
  -- is both cheaper and closer to what a crowd actually sounds like.
  if d.minGap then
    local last = lastPlay[name]
    if last and clock - last < d.minGap then
      -- fold this trigger into the newest live voice instead of adding another
      local newest
      for i = 1, #Audio.voices do
        local v = Audio.voices[i]
        if v.name == name and (not newest or v.t < newest.t) then newest = v end
      end
      if newest and newest.src then
        local g = min(1, newest.gain * 1.16)
        newest.gain = g
        safe(newest.src.setVolume, newest.src, U.saturate(g * busGain(newest.bus)))
      end
      return newest
    end
  end

  -- Per-sound concurrency limit: no single sound may own the pool.
  if d.limit then
    local live = 0
    local oldest, oi
    for i = 1, #Audio.voices do
      local v = Audio.voices[i]
      if v.name == name then
        live = live + 1
        if not oldest or v.t > oldest.t then oldest, oi = v, i end
      end
    end
    if live >= d.limit then
      if oldest and oldest.t > 0.04 then Audio.killVoice(oi) else return nil end
    end
  end

  -- pick a variant
  local nv = #entry.data
  local vi
  local variation = opts and opts.variation
  if variation ~= nil then
    if type(variation) == "string" then
      vi = entry.index and entry.index[variation] or 1
    else
      vi = floor(variation)
    end
  elseif d.ladder then
    -- Ladder sounds walk a scale. `rungs` is how far up the ladder the forest
    -- has grown; `takes` is how many different strikes exist at that rung, so
    -- the same rung twice running is not the same buffer twice running.
    local p = (opts and opts.progress) or (name == "plant" and forest) or 0
    local rungs = d.rungs or nv
    local takes = d.takes or 1
    local rung = floor(1 + p * (rungs - 1) + 0.5)
    -- a little drift so a row of plants is a phrase, not a metronome
    if random() < 0.42 then rung = rung + (random() < 0.5 and -1 or 1) end
    rung = U.clamp(rung, 1, rungs)
    vi = (rung - 1) * takes + rng:int(1, takes)
  else
    vi = rng:int(1, nv)
  end
  vi = U.clamp(vi, 1, nv)

  local bus = (opts and opts.bus) or entry.bus or d.bus or "sfx"

  -- level and pitch variation, so nothing ever repeats exactly
  local vol = (opts and opts.volume or 1) * (d.gain or 0.8)
  vol = vol * (1 - (d.gainVar or 0.1) * random())
  local pitch = 1
  if opts then
    if opts.pitch then pitch = opts.pitch end
    local st = opts.semitones or opts.st
    if st then pitch = pitch * 2 ^ (st / 12) end
  end
  pitch = pitch * (1 + (random() * 2 - 1) * (d.pitchVar or 0.03))

  -- positional attenuation and pan
  local pan = opts and opts.pan or 0
  if opts and opts.x then
    local dx = opts.x - listener.x
    local dy = (opts.y or 0) - listener.y
    local dist = U.len(dx, dy)
    if dist > FAR then return nil end
    vol = vol * (1 - U.smoothstep(NEAR, FAR, dist) * 0.95)
    pan = U.clamp(dx / PAN_WIDTH, -1, 1)
    if vol < 0.004 then return nil end
  end

  -- Concurrency cap, bus-aware. An sfx trigger may only ever take a voice from
  -- the sfx/ui side of the pool; the score keeps MUSIC_RESERVE for itself so a
  -- busy night cannot silence it.
  local nonMusic = 0
  for i = 1, #Audio.voices do
    if Audio.voices[i].bus ~= "music" then nonMusic = nonMusic + 1 end
  end
  local capped = (#Audio.voices >= MAX_VOICES)
              or (bus ~= "music" and nonMusic >= SFX_CEILING)
  if capped then
    -- steal whatever is closest to being over, weighted down by how loud it is:
    -- cutting the tail off a quiet, nearly-finished voice is inaudible
    local worst, wi
    for i = 1, #Audio.voices do
      local v = Audio.voices[i]
      local eligible = not v.loop
      if bus ~= "music" then eligible = eligible and v.bus ~= "music" end
      if eligible then
        local score = v.t / max(0.05, v.dur) - v.gain * 0.5
        if not worst or score > worst then worst, wi = score, i end
      end
    end
    if wi then Audio.killVoice(wi) else return nil end
  end

  local slot = acquire(entry, vi)
  local src = slot and slot.s or nil
  local loopFlag = (opts and opts.loop) or d.loop or false
  local voice = {
    entry = entry, vi = vi, name = name, bus = bus, gain = vol, pan = pan,
    pitch = pitch, t = 0, dur = entry.len[vi] / max(0.05, pitch), src = src,
    slot = slot, loop = loopFlag and true or false,
  }
  if slot then slot.busy = true end
  if src then
    safe(src.setLooping, src, voice.loop)
    safe(src.setPitch, src, U.clamp(pitch, 0.06, 8))
    safe(src.setVolume, src, U.saturate(vol * busGain(bus)))
    -- Pan a mono source by placing it on the unit circle around the listener:
    -- the distance never changes, so we get pan without distance attenuation.
    safe(src.setRelative, src, true)
    safe(src.setAttenuationDistances, src, 1, 100)
    local z = -math.sqrt(max(0.02, 1 - pan * pan))
    safe(src.setPosition, src, pan, 0, z)
    safe(src.seek, src, 0)
    safe(src.play, src)
  end
  Audio.voices[#Audio.voices + 1] = voice
  lastPlay[name] = clock
  -- sounds that own the moment declare their own duck, so callers cannot forget
  if d.duckMusic then Audio.duck(d.duckMusic * (opts and opts.volume or 1), d.duckTime) end
  pushRecent(name, vol)
  return voice
end

--- Stop every voice of `name`, or one voice handle.
function Audio.stop(nameOrVoice)
  if type(nameOrVoice) == "table" then
    for i = #Audio.voices, 1, -1 do
      if Audio.voices[i] == nameOrVoice then Audio.killVoice(i) return end
    end
    return
  end
  for i = #Audio.voices, 1, -1 do
    if Audio.voices[i].name == nameOrVoice then Audio.killVoice(i) end
  end
end

function Audio.stopAll()
  for i = #Audio.voices, 1, -1 do Audio.killVoice(i) end
end

function Audio.isPlaying(name)
  for i = 1, #Audio.voices do
    if Audio.voices[i].name == name then return true end
  end
  return false
end

--- Change a live voice's level (used for the siphon drone as it comes closer).
function Audio.setVoiceVolume(voice, v)
  if not voice or voice.dead then return end
  voice.gain = v
  if voice.src then safe(voice.src.setVolume, voice.src, U.saturate(v * busGain(voice.bus))) end
end

--------------------------------------------------------------------- update
--- Envelope value of a voice at its current position, for the meters.
local function voiceLevel(v)
  local env = v.entry.env[v.vi]
  if not env then return 0 end
  local t = v.t
  if v.loop then t = t % max(0.01, v.dur) end
  local i = floor(t * v.pitch * env.hz) + 1
  if i < 1 or i > env.n then return 0 end
  return env[i]
end

function Audio.update(dt, lx, ly)
  listener.x = lx or listener.x
  listener.y = ly or listener.y
  clock = clock + dt

  if duck.amount > 0 then
    duck.amount = max(0, duck.amount - dt / duck.decay)
  end

  for _, m in pairs(meters) do m.rms = 0 m.voices = 0 end
  local mm = meters.master
  local acc = { master = 0, sfx = 0, music = 0, ui = 0 }

  for i = #Audio.voices, 1, -1 do
    local v = Audio.voices[i]
    v.t = v.t + dt
    if not v.loop and v.t >= v.dur + 0.02 then
      Audio.killVoice(i)
    else
      local lvl = voiceLevel(v) * v.gain
      local bg = busGain(v.bus)
      acc[v.bus] = (acc[v.bus] or 0) + (lvl * bg) ^ 2
      acc.master = acc.master + (lvl * bg) ^ 2
      local m = meters[v.bus]
      if m then m.voices = m.voices + 1 end
      mm.voices = mm.voices + 1
      -- keep live voices tracking bus/duck changes
      if v.src and (v.loop or v.bus == "music") then
        safe(v.src.setVolume, v.src, U.saturate(v.gain * bg))
      end
    end
  end

  for b, m in pairs(meters) do
    local target = math.sqrt(acc[b] or 0)
    -- fast attack, slow release: reads like a real meter
    if target > m.rms then m.rms = m.rms + (target - m.rms) * min(1, dt * 40)
    else m.rms = m.rms + (target - m.rms) * min(1, dt * 8) end
    m.peak = max(m.peak * (1 - min(1, dt * 1.2)), target)
    m.head = m.head % #m.hist + 1
    m.hist[m.head] = m.rms
  end
end

function Audio.meter(bus) return meters[bus] end
function Audio.duckAmount() return duck.amount end
function Audio.voiceCount() return #Audio.voices end

--- Names of the sounds in the bank (sorted), for the demo scene.
function Audio.names()
  local t = {}
  for i = 1, #D do t[#t + 1] = D[i] end
  table.sort(t)
  return t
end

--- Internal: the music sequencer plays through here so its voices are pooled,
--- metered and ducked exactly like everything else.
function Audio.playMusic(inst, semitoneFromC3, opts)
  local entry = Audio.music and Audio.music[inst]
  if not entry then return nil end
  opts = opts or {}
  local st = semitoneFromC3 or 0
  local nv = #entry.data
  local vi, ratio
  if nv == 12 then
    local oct = floor(st / 12)
    vi = st - oct * 12 + 1
    ratio = 2 ^ oct
  else
    vi = rng:int(1, nv)
    ratio = 2 ^ (st / 12)
  end
  opts.variation = vi
  opts.pitch = (opts.pitch or 1) * ratio
  opts.bus = "music"
  return Audio.play("mus_" .. inst, opts)
end

-- exposed for the demo scene and for tooling
Audio.defs = D
Audio.musicDefs = MUSIC
Audio.percDefs = PERC

return Audio
