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
local NEAR, FAR      = 260, 1500
local PAN_WIDTH      = 820     -- world units mapped to full pan

--------------------------------------------------------------------- state
Audio.maxVoices = MAX_VOICES
Audio.bus = { master = 0.9, sfx = 1.0, music = 0.62, ui = 0.8 }
Audio.sounds = {}
Audio.voices = {}
Audio.recent = {}              -- ring of recently triggered names, for the demo HUD
Audio.stats  = { sounds = 0, variants = 0, samples = 0, bytes = 0, loadTime = 0 }
Audio.enabled = true
Audio.loaded = false

local duck      = { amount = 0, decay = 0, target = 0 }
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

------------------------------------------------------------------- the bank
-- PLANT -- the star of the show. Three parts:
--   1. a wooden knock: a bandpassed noise transient plus a fast-dropping sine,
--      so the hand-plant lands with a physical "tok" you feel in your fingers;
--   2. a soil puff: quiet lowpassed pink noise, the dirt closing over the seed;
--   3. a mallet bell tuned to a pentatonic ladder. Its degree is chosen from
--      Audio.setForestProgress(), so as the island fills in, every plant rings
--      higher and the whole forest slowly becomes one rising chord.
-- The ladder is major pentatonic (never a wrong note next to the score) with a
-- soft FM timbre (ratio 3.01, fast index decay = struck wood-metal, not a sine).
local PENTA = Synth.scales.pentaMajor
local PLANT_STEPS = 14

local function plantSpec(v)
  local st = Synth.degree(PENTA, v)        -- v = 1..PLANT_STEPS climbing degrees
  local hz = Synth.noteToHz(60 + st)       -- C4 upward
  return {
    dur = 1.0,
    layers = {
      -- wooden knock: present enough to feel, quiet enough to stay out of the
      -- bell's way (it is the frame, not the picture)
      { osc = "sine", freq = { from = 240, to = 96, tau = 0.012 },
        env = { type = "perc", a = 0.0008, d = 0.08, curve = 3 }, amp = 0.3 },
      { osc = "noise", env = { type = "perc", a = 0.0005, d = 0.03, curve = 5 }, amp = 0.22 },
      -- soil puff
      { osc = "pink", env = { type = "perc", a = 0.006, d = 0.16, curve = 2 }, amp = 0.1 },
      -- the bell
      { osc = "fm", freq = hz, ratio = 3.01,
        index = { type = "exp", tau = 0.05, peak = 2.2 },
        env = { type = "perc", a = 0.003, d = 0.95, curve = 1.5 }, amp = 0.62 },
      { osc = "sine", freq = hz, env = { type = "perc", a = 0.006, d = 0.9, curve = 1.6 },
        amp = 0.3 },
      { osc = "sine", freq = hz * 2, env = { type = "perc", a = 0.004, d = 0.45, curve = 2.4 },
        amp = 0.1 },
      { osc = "sine", freq = hz * 1.4983, env = { type = "perc", a = 0.01, d = 0.6, curve = 2 },
        amp = 0.07 },
    },
    fx = {
      { "svf", type = "lp", cutoff = { from = 6200, to = 2400, tau = 0.09 }, q = 0.8 },
      { "reverb", mix = 0.2, room = 0.66, damp = 0.42 },
    },
    normalize = 0.86,
  }
end

def("plant", {
  gain = 0.85, variants = PLANT_STEPS, ladder = true, pitchVar = 0.012,
  build = function(v) return plantSpec(v) end,
})

-- PICKUP -- a bright two-partial blip. Short, unobtrusive, endlessly repeatable.
def("pickup", {
  gain = 0.42, variants = 4, pitchVar = 0.05,
  build = function(v, n, r)
    local hz = 880 * 2 ^ (r:range(-0.08, 0.08))
    return { dur = 0.22, layers = {
      { osc = "sine", freq = { from = hz * 0.7, to = hz, tau = 0.01 },
        env = { type = "perc", a = 0.001, d = 0.11, curve = 2.6 }, amp = 0.5 },
      { osc = "sine", freq = hz * 3, env = { type = "perc", a = 0.001, d = 0.05, curve = 3 },
        amp = 0.14 },
      { osc = "noise", env = { type = "perc", a = 0.0004, d = 0.012, curve = 5 }, amp = 0.1 },
    }, fx = { { "svf", type = "hp", cutoff = 300, q = 0.7 } } }
  end,
})

-- PICKUP_STREAK -- the same blip walking up a pentatonic run; consecutive grabs
-- climb, so a good harvesting line turns into a little melody.
def("pickup_streak", {
  gain = 0.46, variants = 10, ladder = true, pitchVar = 0.01,
  build = function(v)
    local hz = Synth.noteToHz(72 + Synth.degree(PENTA, v))
    return { dur = 0.3, layers = {
      { osc = "sine", freq = { from = hz * 0.75, to = hz, tau = 0.008 },
        env = { type = "perc", a = 0.001, d = 0.14, curve = 2.4 }, amp = 0.5 },
      { osc = "fm", freq = hz * 2, ratio = 2, index = { type = "exp", tau = 0.03, peak = 1.4 },
        env = { type = "perc", a = 0.001, d = 0.1, curve = 3 }, amp = 0.16 },
    }, fx = { { "reverb", mix = 0.12, room = 0.5 } } }
  end,
})

-- DEPOSIT_POP -- cobalt landing in the Home Rig: a metal ping over a small
-- thunk, quiet enough to fire many times a second while a Harvester unloads.
def("deposit_pop", {
  gain = 0.45, variants = 4, pitchVar = 0.07,
  build = function(v, n, r)
    local hz = 1240 * r:range(0.9, 1.14)
    return { dur = 0.35, layers = {
      { osc = "fm", freq = hz, ratio = 2.41, index = { type = "exp", tau = 0.02, peak = 1.6 },
        env = { type = "perc", a = 0.001, d = 0.2, curve = 3 }, amp = 0.4 },
      { osc = "sine", freq = { from = 220, to = 110, tau = 0.02 },
        env = { type = "perc", a = 0.001, d = 0.08, curve = 3 }, amp = 0.35 },
      { osc = "noise", env = { type = "perc", a = 0.0004, d = 0.01, curve = 5 }, amp = 0.2 },
    }, fx = { { "svf", type = "hp", cutoff = 260, q = 0.7 },
              { "reverb", mix = 0.16, room = 0.6 } } }
  end,
})

-- BUILD -- a servo whirr that lifts (start) and a two-part clunk that lands (done).
def("build_start", {
  gain = 0.5, variants = 3,
  build = function(v, n, r)
    return { dur = 0.5, layers = {
      { osc = "saw", freq = { from = 90, to = 300 * r:range(0.94, 1.06), tau = 0.16, curve = "lin" },
        env = { a = 0.02, d = 0.1, s = 0.6, r = 0.18 }, amp = 0.2 },
      { osc = "square", freq = { from = 180, to = 600, tau = 0.16, curve = "lin" }, duty = 0.32,
        env = { a = 0.02, d = 0.1, s = 0.5, r = 0.2 }, amp = 0.09 },
      { osc = "pink", env = { type = "perc", a = 0.01, d = 0.4, curve = 2 }, amp = 0.09 },
    }, fx = { { "svf", type = "lp", cutoff = { from = 1400, to = 4200, tau = 0.2 }, q = 1.6 },
              { "reverb", mix = 0.14 } } }
  end,
})

def("build_done", {
  gain = 0.68, variants = 3,
  build = function(v, n, r)
    local hz = 196 * r:range(0.97, 1.03)
    return { dur = 0.7, layers = {
      { osc = "sine", freq = { from = hz * 1.6, to = hz * 0.5, tau = 0.02 },
        env = { type = "perc", a = 0.001, d = 0.14, curve = 3 }, amp = 0.6 },
      { osc = "noise", env = { type = "perc", a = 0.0005, d = 0.05, curve = 4 }, amp = 0.35 },
      { osc = "fm", freq = hz * 4, ratio = 1.41, index = { type = "exp", tau = 0.06, peak = 3 },
        env = { type = "perc", a = 0.002, d = 0.45, curve = 2 }, amp = 0.22 },
    }, fx = { { "svf", type = "bp", cutoff = 1100, q = 1.1, drive = 1.2 },
              { "softclip", drive = 1.6, mix = 0.5 },
              { "reverb", mix = 0.22, room = 0.7 } } }
  end,
})

-- BOT BOOT -- a friendly rising three-note chirp, one timbre per bot type, so
-- you learn to recognise what just woke up without looking. Square-ish and
-- quantised: these are small machines, and they are pleased to see you.
local BOOT_KINDS = { "planter", "builder", "repulsor", "sentry", "harvester", "beacon" }
local BOOT_TUNE = {
  planter   = { base = 72, notes = { 0, 4, 7 },  wave = "square", duty = 0.5,  dur = 0.075 },
  builder   = { base = 64, notes = { 0, 5, 7 },  wave = "square", duty = 0.28, dur = 0.09 },
  repulsor  = { base = 69, notes = { 0, 7, 12 }, wave = "tri",    duty = 0.5,  dur = 0.06 },
  sentry    = { base = 67, notes = { 0, 3, 10 }, wave = "square", duty = 0.18, dur = 0.07 },
  harvester = { base = 62, notes = { 0, 2, 9 },  wave = "saw",    duty = 0.5,  dur = 0.08 },
  beacon    = { base = 76, notes = { 0, 7, 11 }, wave = "sine",   duty = 0.5,  dur = 0.11 },
}

def("bot_boot", {
  gain = 0.5, variants = 6, keyed = BOOT_KINDS, pitchVar = 0.02,
  build = function(v)
    local k = BOOT_TUNE[BOOT_KINDS[v]]
    local layers = {}
    for i = 1, 3 do
      local hz = Synth.noteToHz(k.base + k.notes[i])
      layers[#layers + 1] = { osc = "sub", at = (i - 1) * k.dur * 1.35, amp = 0.9, spec = {
        dur = k.dur * 2.2,
        layers = {
          { osc = k.wave, freq = hz, duty = k.duty,
            env = { type = "perc", a = 0.004, d = k.dur * 1.7, curve = 2.2 }, amp = 0.4 },
          { osc = "sine", freq = hz * 2, env = { type = "perc", a = 0.003, d = k.dur, curve = 3 },
            amp = 0.1 },
        },
        fx = { { "svf", type = "lp", cutoff = 5200, q = 0.8 } }, normalize = 0.8, trim = false,
      } }
    end
    -- the unfold: a tiny servo tick under the chirp
    layers[#layers + 1] = { osc = "noise", env = { type = "perc", a = 0.001, d = 0.03, curve = 4 },
                            amp = 0.14 }
    return { dur = k.dur * 5.2 + 0.25, layers = layers,
             fx = { { "reverb", mix = 0.16, room = 0.6 } }, normalize = 0.82 }
  end,
})

-- BOT CHATTER -- wordless speech: a formant-ish two-band pulse wobbling over a
-- short contour. Six variants, wide pitch jitter, so a field of bots murmurs.
def("bot_chatter", {
  gain = 0.3, variants = 6, pitchVar = 0.11, gainVar = 0.22,
  build = function(v, n, r)
    local base = Synth.noteToHz(58 + r:int(0, 12))
    local wob = r:range(9, 17)
    local dep = r:range(0.05, 0.14)
    local seg = r:range(0.08, 0.16)
    local up = r:chance(0.5) and 1 or -1
    return { dur = seg * 3 + 0.2, layers = {
      { osc = "square", duty = 0.34,
        freq = function(t) return base * (1 + dep * math.sin(t * wob)) * (1 + up * 0.18 * t) end,
        env = { type = "bp", points = { { 0, 0 }, { 0.02, 1 }, { seg, 0.8 }, { seg * 2, 0.9 },
                                        { seg * 3, 0 } } }, amp = 0.3 },
      { osc = "sine", freq = function(t) return base * 2 * (1 + dep * math.sin(t * wob)) end,
        env = { type = "bp", points = { { 0, 0 }, { 0.03, 0.5 }, { seg * 3, 0 } } }, amp = 0.12 },
    }, fx = {
      { "svf", type = "bp", cutoff = r:range(700, 1500), q = 2.4 },
      { "svf", type = "lp", cutoff = 3200, q = 0.7 },
      { "reverb", mix = 0.14 },
    } }
  end,
})

def("bot_hurt", {
  gain = 0.6, variants = 4,
  build = function(v, n, r)
    local hz = Synth.noteToHz(70 + r:int(-3, 3))
    return { dur = 0.35, layers = {
      { osc = "square", duty = 0.4, freq = { from = hz, to = hz * 0.6, tau = 0.06 },
        env = { type = "perc", a = 0.001, d = 0.16, curve = 2.4 }, amp = 0.34 },
      { osc = "noise", env = { type = "perc", a = 0.0005, d = 0.06, curve = 3 }, amp = 0.3 },
    }, fx = { { "bitcrush", bits = 5, rateDiv = 2 },
              { "svf", type = "lp", cutoff = 3400, q = 1 } } }
  end,
})

-- BOT DOWN -- the one that has to hurt. A falling minor third to a fifth below
-- (spec section 9), played on a soft bell that is losing power: the pitch sags
-- a few cents on the last note, the filter closes, and the reverb tail is the
-- longest of any sound in the game. Under it, a capacitor whine winding down.
def("bot_down", {
  rate = 11025,
  gain = 0.8, variants = 3, pitchVar = 0.015,
  build = function(v, n, r)
    local root = 74 + (v - 2)                     -- D5-ish
    local notes = { root, root - 3, root - 12 + 7 }  -- root, m3 down, fifth below
    local step = 0.17
    local layers = {}
    for i = 1, 3 do
      local hz = Synth.noteToHz(notes[i]) * (i == 3 and 0.994 or 1)   -- the sag
      layers[#layers + 1] = { osc = "sub", at = (i - 1) * step, amp = 1 - (i - 1) * 0.1, spec = {
        dur = i == 3 and 1.5 or 0.6,
        layers = {
          { osc = "fm", freq = hz, ratio = 2.01,
            index = { type = "exp", tau = 0.09, peak = 1.9 },
            env = { type = "perc", a = 0.004, d = i == 3 and 1.3 or 0.5, curve = 1.8 }, amp = 0.42 },
          { osc = "sine", freq = hz * 0.5,
            env = { type = "perc", a = 0.01, d = i == 3 and 1.2 or 0.4, curve = 2 }, amp = 0.16 },
        }, normalize = 0.8, trim = false,
      } }
    end
    -- the power-down whine and a last spark
    layers[#layers + 1] = { osc = "sine", freq = { from = 620, to = 70, tau = 0.5 },
                            env = { type = "bp", points = { { 0, 0 }, { 0.05, 0.22 },
                                                            { 1.1, 0.05 }, { 1.5, 0 } } }, amp = 0.3 }
    layers[#layers + 1] = { osc = "noise",
                            env = { type = "perc", a = 0.001, d = 0.05, curve = 4 }, amp = 0.12 }
    return { dur = 2.1, layers = layers, fx = {
      { "svf", type = "lp", cutoff = { from = 5200, to = 900, tau = 0.7 }, q = 0.8 },
      { "reverb", mix = 0.34, room = 0.86, damp = 0.28 },
    }, normalize = 0.84 }
  end,
})

def("bot_revive", {
  gain = 0.7, variants = 3,
  build = function(v, n, r)
    local root = 62 + r:int(-1, 1)
    local layers = {}
    for i, s in ipairs({ 0, 7, 12, 16 }) do
      local hz = Synth.noteToHz(root + s)
      layers[#layers + 1] = { osc = "sub", at = (i - 1) * 0.085, amp = 0.85, spec = {
        dur = 0.9,
        layers = { { osc = "fm", freq = hz, ratio = 2, index = { type = "exp", tau = 0.1, peak = 1.2 },
                     env = { type = "perc", a = 0.006, d = 0.75, curve = 2 }, amp = 0.4 } },
        normalize = 0.8, trim = false } }
    end
    layers[#layers + 1] = { osc = "pink", env = { type = "ar", a = 0.28, r = 0.3 }, amp = 0.1 }
    return { dur = 1.5, layers = layers, fx = {
      { "svf", type = "lp", cutoff = { from = 1200, to = 6000, tau = 0.25 }, q = 0.9 },
      { "reverb", mix = 0.3, room = 0.8 } } }
  end,
})

-- PLAYER VERBS ------------------------------------------------------------
def("dash", {
  gain = 0.5, variants = 4, pitchVar = 0.06,
  build = function(v, n, r)
    return { dur = 0.4, layers = {
      { osc = "pink", env = { type = "bp", points = { { 0, 0 }, { 0.015, 1 }, { 0.09, 0.5 },
                                                      { 0.3, 0 } } }, amp = 0.5 },
      { osc = "sine", freq = { from = 420, to = 120, tau = 0.06 },
        env = { type = "perc", a = 0.002, d = 0.16, curve = 2.5 }, amp = 0.22 },
    }, fx = {
      { "svf", type = "bp", cutoff = { from = 900, to = 3000 * r:range(0.85, 1.2), tau = 0.08 },
        q = 1.5 },
      { "svf", type = "hp", cutoff = 240, q = 0.7 },
      { "reverb", mix = 0.12 },
    } }
  end,
})

def("shove_swing", {
  gain = 0.42, variants = 4, pitchVar = 0.07,
  build = function(v, n, r)
    return { dur = 0.3, layers = {
      { osc = "noise", env = { type = "bp", points = { { 0, 0 }, { 0.03, 1 }, { 0.16, 0 } } },
        amp = 0.5 },
    }, fx = {
      { "svf", type = "bp", cutoff = { from = 700, to = 2600 * r:range(0.9, 1.15), tau = 0.06 },
        q = 2.2 },
      { "svf", type = "hp", cutoff = 400, q = 0.7 },
    } }
  end,
})

-- SHOVE_HIT -- a click and a thump, which is what impact actually is: a hard
-- transient (contact) plus a body resonance (mass). Kept short so hitstop reads.
def("shove_hit", {
  gain = 0.85, variants = 4, pitchVar = 0.05,
  build = function(v, n, r)
    local body = 110 * r:range(0.9, 1.12)
    return { dur = 0.4, layers = {
      { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.012, curve = 6 }, amp = 0.7 },
      { osc = "sine", freq = { from = body * 2.4, to = body, tau = 0.018 },
        env = { type = "perc", a = 0.001, d = 0.17, curve = 2.6 }, amp = 0.75 },
      { osc = "tri", freq = body * 3.1, env = { type = "perc", a = 0.001, d = 0.06, curve = 3 },
        amp = 0.18 },
    }, fx = {
      { "softclip", drive = 2.2, mix = 0.7 },
      { "svf", type = "lp", cutoff = 4200, q = 0.9 },
      { "reverb", mix = 0.14 },
    } }
  end,
})

def("pulse_charge", {
  gain = 0.5, variants = 2, loopable = true, pitchVar = 0.01,
  build = function(v)
    return { dur = 0.9, layers = {
      { osc = "saw", freq = { from = 70, to = 520, tau = 0.85, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 0.1, 0.4 }, { 0.85, 1 }, { 0.9, 0.9 } } },
        amp = 0.22, detune = -6 },
      { osc = "saw", freq = { from = 70, to = 524, tau = 0.85, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 0.1, 0.4 }, { 0.85, 1 }, { 0.9, 0.9 } } },
        amp = 0.22, detune = 7 },
      { osc = "sine", freq = { from = 140, to = 1040, tau = 0.85, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 0.5, 0.3 }, { 0.9, 0.8 } } }, amp = 0.16 },
      { osc = "pink", env = { type = "bp", points = { { 0, 0 }, { 0.9, 0.5 } } }, amp = 0.12 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 600, to = 5200, tau = 0.5 }, q = 2.6 },
      { "chorus", mix = 0.3, rate = 1.4 },
    }, trim = false, fadeOut = 0.02 }
  end,
})

def("pulse_release", {
  rate = 11025,
  gain = 0.95, variants = 3, pitchVar = 0.03,
  build = function(v, n, r)
    return { dur = 1.3, layers = {
      { osc = "sine", freq = { from = 900, to = 42, tau = 0.09 },
        env = { type = "perc", a = 0.001, d = 0.5, curve = 2 }, amp = 0.8 },
      { osc = "noise", env = { type = "perc", a = 0.001, d = 0.35, curve = 3 }, amp = 0.4 },
      { osc = "tri", freq = { from = 300, to = 60, tau = 0.15 },
        env = { type = "perc", a = 0.002, d = 0.4, curve = 2.4 }, amp = 0.3 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 6000, to = 700, tau = 0.25 }, q = 1.1 },
      { "softclip", drive = 1.8, mix = 0.6 },
      { "reverb", mix = 0.3, room = 0.8, damp = 0.3 },
    } }
  end,
})

def("player_hurt", {
  gain = 0.8, variants = 3,
  build = function(v, n, r)
    return { dur = 0.6, layers = {
      { osc = "sine", freq = { from = 300, to = 80, tau = 0.05 },
        env = { type = "perc", a = 0.001, d = 0.22, curve = 2.4 }, amp = 0.6 },
      { osc = "noise", env = { type = "perc", a = 0.0006, d = 0.09, curve = 3 }, amp = 0.45 },
      { osc = "square", duty = 0.42, freq = 62 * r:range(0.95, 1.05),
        env = { type = "perc", a = 0.002, d = 0.3, curve = 2 }, amp = 0.2 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 3000, to = 500, tau = 0.15 }, q = 1.2 },
      { "softclip", drive = 2.4, mix = 0.8 },
      { "reverb", mix = 0.16 },
    } }
  end,
})

-- PLAYER_DOWN -- the suit failing: everything drops an octave, a heartbeat-ish
-- sub thud, and the world muffles (a long lowpass sweep down to almost nothing).
def("player_down", {
  rate = 11025,
  gain = 0.9, variants = 2,
  build = function(v)
    return { dur = 2.6, layers = {
      { osc = "sine", freq = { from = 180, to = 44, tau = 0.5 },
        env = { type = "bp", points = { { 0, 0 }, { 0.02, 1 }, { 0.9, 0.35 }, { 2.4, 0 } } },
        amp = 0.7 },
      { osc = "sine", freq = 55, env = { type = "perc", a = 0.005, d = 0.5, curve = 2 }, amp = 0.4 },
      { osc = "sine", freq = 52, env = { type = "bp", points = { { 0, 0 }, { 0.6, 0 }, { 0.63, 0.7 },
                                                                 { 0.95, 0 } } }, amp = 0.4 },
      { osc = "pink", env = { type = "bp", points = { { 0, 0.5 }, { 0.4, 0.2 }, { 2.4, 0 } } },
        amp = 0.2 },
      { osc = "square", duty = 0.5, freq = { from = 440, to = 110, tau = 0.8 },
        env = { type = "bp", points = { { 0, 0.2 }, { 1.6, 0.05 }, { 2.4, 0 } } }, amp = 0.12 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 4000, to = 260, tau = 0.7 }, q = 1 },
      { "bitcrush", bits = 7, rateDiv = 2 },
      { "reverb", mix = 0.35, room = 0.88, damp = 0.25 },
    } }
  end,
})

-- BLIGHT ------------------------------------------------------------------
def("enemy_step", {
  rate = 11025,
  gain = 0.26, variants = 6, pitchVar = 0.14, gainVar = 0.3,
  build = function(v, n, r)
    return { dur = 0.2, layers = {
      { osc = "noise", env = { type = "perc", a = 0.001, d = r:range(0.04, 0.08), curve = 3 },
        amp = 0.4 },
      { osc = "sine", freq = { from = r:range(120, 190), to = 60, tau = 0.02 },
        env = { type = "perc", a = 0.001, d = 0.07, curve = 3 }, amp = 0.4 },
    }, fx = { { "svf", type = "lp", cutoff = r:range(900, 1800), q = 1.3 } } }
  end,
})

def("enemy_hurt", {
  gain = 0.55, variants = 5, pitchVar = 0.1,
  build = function(v, n, r)
    return { dur = 0.3, layers = {
      { osc = "saw", freq = { from = r:range(300, 420), to = 90, tau = 0.05 },
        env = { type = "perc", a = 0.001, d = 0.15, curve = 2.6 }, amp = 0.4 },
      { osc = "noise", env = { type = "perc", a = 0.0006, d = 0.05, curve = 4 }, amp = 0.3 },
    }, fx = {
      { "bitcrush", bits = 4, rateDiv = 3 },
      { "svf", type = "bp", cutoff = r:range(700, 1400), q = 1.6 },
      { "softclip", drive = 2, mix = 0.6 },
    } }
  end,
})

def("enemy_die", {
  rate = 11025,
  gain = 0.7, variants = 4, pitchVar = 0.08,
  build = function(v, n, r)
    return { dur = 0.9, layers = {
      { osc = "saw", freq = { from = r:range(260, 360), to = 40, tau = 0.12 },
        env = { type = "perc", a = 0.001, d = 0.35, curve = 2 }, amp = 0.42 },
      { osc = "noise", env = { type = "perc", a = 0.001, d = 0.3, curve = 2.5 }, amp = 0.4 },
      { osc = "pink", env = { type = "bp", points = { { 0, 0 }, { 0.05, 0.4 }, { 0.7, 0 } } },
        amp = 0.25 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 4500, to = 400, tau = 0.25 }, q = 1.1 },
      { "bitcrush", bits = 5, rateDiv = 2 },
      { "softclip", drive = 1.7, mix = 0.5 },
      { "reverb", mix = 0.2 },
    } }
  end,
})

-- CHOMP -- wet, organic, upsetting: two bandpassed noise bites with a pitch
-- drop between them, plus a low gulp. It should read as "your tree is dying".
def("chomp", {
  rate = 11025,
  gain = 0.6, variants = 5, pitchVar = 0.09,
  build = function(v, n, r)
    local g = r:range(0.9, 1.15)
    return { dur = 0.45, layers = {
      { osc = "noise", env = { type = "bp", points = { { 0, 0 }, { 0.008, 1 }, { 0.06, 0.1 },
                                                       { 0.1, 0.7 }, { 0.2, 0 } } }, amp = 0.5 },
      { osc = "sine", freq = { from = 260 * g, to = 70 * g, tau = 0.05 },
        env = { type = "perc", a = 0.002, d = 0.2, curve = 2.2 }, amp = 0.4 },
      { osc = "brown", env = { type = "perc", a = 0.01, d = 0.25, curve = 2 }, amp = 0.3 },
    }, fx = {
      { "svf", type = "bp", cutoff = { from = 1600 * g, to = 500, tau = 0.08 }, q = 2 },
      { "softclip", drive = 1.6, mix = 0.5 },
    } }
  end,
})

-- TREE_FALL -- the loss sound. Fibre tearing (filtered noise with a downward
-- sweep), then a heavy body impact and a settling rustle. Long, so it lands.
def("tree_fall", {
  rate = 11025,
  gain = 0.85, variants = 3, pitchVar = 0.04,
  build = function(v, n, r)
    return { dur = 2.2, layers = {
      { osc = "noise", env = { type = "bp", points = { { 0, 0 }, { 0.06, 0.55 }, { 0.5, 0.3 },
                                                       { 0.75, 0.1 } } }, amp = 0.4 },
      { osc = "saw", freq = { from = 190, to = 46, tau = 0.35 },
        env = { type = "bp", points = { { 0, 0 }, { 0.03, 0.5 }, { 0.8, 0.1 }, { 1.0, 0 } } },
        amp = 0.22 },
      { osc = "sub", at = 0.82, amp = 1, spec = { dur = 1.2, layers = {
          { osc = "sine", freq = { from = 120, to = 38, tau = 0.05 },
            env = { type = "perc", a = 0.001, d = 0.5, curve = 2 }, amp = 0.9 },
          { osc = "noise", env = { type = "perc", a = 0.002, d = 0.25, curve = 2.5 }, amp = 0.5 },
        }, fx = { { "svf", type = "lp", cutoff = 900, q = 1 } }, normalize = 0.9, trim = false } },
      { osc = "sub", at = 1.0, amp = 0.5, spec = { dur = 1.1, layers = {
          { osc = "pink", env = { type = "bp", points = { { 0, 0.6 }, { 0.5, 0.2 }, { 1.0, 0 } } },
            amp = 0.4 } },
        fx = { { "svf", type = "bp", cutoff = 2600, q = 1.2 } }, normalize = 0.7, trim = false } },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 3200, to = 1400, tau = 1.0 }, q = 0.8 },
      { "reverb", mix = 0.26, room = 0.8, damp = 0.4 },
    } }
  end,
})

def("spit", {
  gain = 0.5, variants = 4, pitchVar = 0.1,
  build = function(v, n, r)
    return { dur = 0.4, layers = {
      { osc = "noise", env = { type = "perc", a = 0.002, d = 0.12, curve = 3 }, amp = 0.4 },
      { osc = "sine", freq = { from = 700 * r:range(0.9, 1.1), to = 1500, tau = 0.09, curve = "lin" },
        env = { type = "perc", a = 0.003, d = 0.13, curve = 2 }, amp = 0.25 },
    }, fx = {
      { "svf", type = "bp", cutoff = { from = 1200, to = 3200, tau = 0.1 }, q = 3 },
      { "delay", time = 0.07, fb = 0.2, mix = 0.2 },
    } }
  end,
})

-- SIPHON_DRAIN -- a loop you want to end. Two detuned saws a semitone apart
-- (beating), amplitude-wobbled at 5.5 Hz, bandpassed to a nasal formant, with a
-- sub underneath. Deliberately unpleasant and deliberately quiet-until-close.
def("siphon_drain", {
  rate = 11025,
  gain = 0.4, variants = 2, loop = true, pitchVar = 0.02,
  build = function(v, n, r)
    local base = 92 + v * 3
    return { dur = 2.0, layers = {
      { osc = "saw", freq = base, amp = 0.26, detune = -14 },
      { osc = "saw", freq = base * 1.0595, amp = 0.24, detune = 11 },
      { osc = "sine", freq = base * 0.5, amp = 0.3 },
      { osc = "square", duty = 0.2, freq = base * 2,
        env = function(t) return 0.5 + 0.5 * math.sin(t * 5.5 * 6.2831853) end, amp = 0.1 },
    }, fx = {
      { "svf", type = "bp", cutoff = 620, q = 2.8 },
      { "svf", type = "lp", cutoff = 2400, q = 0.8 },
      { "softclip", drive = 1.5, mix = 0.5 },
      { "chorus", mix = 0.25, rate = 0.23 },
    }, trim = false, normalize = 0.7, fadeIn = 0.02, fadeOut = 0.02 }
  end,
})

def("rift_open", {
  gain = 0.9, variants = 2,
  build = function(v)
    return { dur = 2.4, layers = {
      { osc = "noise", env = { type = "bp", points = { { 0, 0 }, { 0.4, 0.6 }, { 0.8, 1 },
                                                       { 1.6, 0.2 }, { 2.2, 0 } } }, amp = 0.4 },
      { osc = "saw", freq = { from = 40, to = 150, tau = 1.0, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 0.9, 0.6 }, { 2.2, 0 } } }, amp = 0.2,
        detune = -9 },
      { osc = "saw", freq = { from = 41, to = 149, tau = 1.0, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 0.9, 0.6 }, { 2.2, 0 } } }, amp = 0.2,
        detune = 12 },
      { osc = "fm", freq = 220, ratio = 5.13, index = { type = "bp",
        points = { { 0, 0 }, { 0.8, 6 }, { 1.4, 2 }, { 2.2, 0 } } },
        env = { type = "bp", points = { { 0, 0 }, { 0.7, 0.4 }, { 2.0, 0 } } }, amp = 0.3 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 500, to = 4200, tau = 0.9 }, q = 1.6 },
      { "reverb", mix = 0.4, room = 0.9, damp = 0.2 },
      { "softclip", drive = 1.4, mix = 0.4 },
    } }
  end,
})

def("rift_close", {
  rate = 11025,
  gain = 0.85, variants = 2,
  build = function(v)
    return { dur = 1.6, layers = {
      { osc = "noise", env = { type = "bp", points = { { 0, 0.8 }, { 0.35, 0.5 }, { 0.6, 0 } } },
        amp = 0.4 },
      { osc = "saw", freq = { from = 220, to = 30, tau = 0.3 },
        env = { type = "bp", points = { { 0, 0.6 }, { 0.5, 0.2 }, { 0.7, 0 } } }, amp = 0.3 },
      { osc = "sub", at = 0.6, amp = 1, spec = { dur = 1.0, layers = {
        { osc = "sine", freq = { from = 90, to = 34, tau = 0.06 },
          env = { type = "perc", a = 0.001, d = 0.45, curve = 2 }, amp = 0.9 },
        { osc = "noise", env = { type = "perc", a = 0.001, d = 0.09, curve = 4 }, amp = 0.4 },
      }, normalize = 0.9, trim = false } },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 3600, to = 600, tau = 0.4 }, q = 1 },
      { "reverb", mix = 0.28, room = 0.8 },
    } }
  end,
})

-- WAVE_START -- the siren. The brief was "make the player's stomach drop", so:
--  * an inhale (reversed noise swell) pulls you into the downbeat;
--  * a detuned pair of saws a *falling* minor second apart -- beating, sour,
--    and moving down instead of up, which reads as dread rather than alarm;
--  * a sub that glides 140 -> 48 Hz over two seconds, the actual stomach part;
--  * a far-off metallic ring (high-index FM) so it sounds like it is coming
--    from somewhere outside the island;
--  * gentle bitcrush + big dark reverb: a broken PA in an empty sky.
def("wave_start", {
  rate = 11025,
  bus = "sfx", gain = 1.0, variants = 2, pitchVar = 0.01,
  build = function(v)
    local base = 138 * (v == 2 and 0.97 or 1)
    return { dur = 3.4, layers = {
      { osc = "pink", env = { type = "bp", points = { { 0, 0 }, { 0.55, 0.55 }, { 0.62, 0.15 },
                                                      { 2.4, 0.05 }, { 3.2, 0 } } }, amp = 0.32 },
      { osc = "saw", freq = { from = base, to = base * 0.6, tau = 1.5, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 0.6, 0.9 }, { 2.2, 0.7 }, { 3.2, 0 } } },
        amp = 0.24, detune = -10 },
      { osc = "saw", freq = { from = base * 0.944, to = base * 0.57, tau = 1.5, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 0.6, 0.9 }, { 2.2, 0.7 }, { 3.2, 0 } } },
        amp = 0.24, detune = 13 },
      { osc = "sine", freq = { from = 140, to = 48, tau = 0.9 },
        env = { type = "bp", points = { { 0, 0 }, { 0.5, 1 }, { 2.6, 0.6 }, { 3.3, 0 } } },
        amp = 0.55 },
      { osc = "fm", freq = 430, ratio = 7.02,
        index = { type = "bp", points = { { 0, 0 }, { 0.7, 3.4 }, { 2.0, 1.2 }, { 3.2, 0 } } },
        env = { type = "bp", points = { { 0, 0 }, { 0.66, 0.3 }, { 2.6, 0.08 }, { 3.2, 0 } } },
        amp = 0.28 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 900, to = 2600, tau = 0.7 }, q = 1.4 },
      { "bitcrush", bits = 8, rateDiv = 2 },
      { "softclip", drive = 1.5, mix = 0.55 },
      { "reverb", mix = 0.42, room = 0.92, damp = 0.22 },
    }, normalize = 0.93 }
  end,
})

-- DAWN -- the exhale. A warm major-add9 chord that arrives softly and resolves,
-- with a bell on the ninth. The only sound in the game with no transient.
def("dawn", {
  rate = 11025,
  bus = "sfx", gain = 0.75, variants = 2, pitchVar = 0.005,
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
    }, normalize = 0.8, fadeIn = 0.02 }
  end,
})

-- BOSS --------------------------------------------------------------------
def("boss_step", {
  rate = 11025,
  gain = 1.0, variants = 3, pitchVar = 0.04,
  build = function(v, n, r)
    return { dur = 1.4, layers = {
      { osc = "sine", freq = { from = 90, to = 28, tau = 0.06 },
        env = { type = "perc", a = 0.001, d = 0.6, curve = 1.8 }, amp = 0.95 },
      { osc = "noise", env = { type = "perc", a = 0.001, d = 0.12, curve = 3 }, amp = 0.4 },
      { osc = "tri", freq = 62 * r:range(0.95, 1.05),
        env = { type = "perc", a = 0.002, d = 0.3, curve = 2 }, amp = 0.25 },
      { osc = "sub", at = 0.02, amp = 0.4, spec = { dur = 0.9, layers = {
        { osc = "pink", env = { type = "bp", points = { { 0, 0.5 }, { 0.4, 0.15 }, { 0.85, 0 } } },
          amp = 0.4 } }, fx = { { "svf", type = "bp", cutoff = 3200, q = 1.4 } },
        normalize = 0.6, trim = false } },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 2400, to = 500, tau = 0.3 }, q = 1 },
      { "softclip", drive = 2, mix = 0.6 },
      { "reverb", mix = 0.24, room = 0.85 },
    } }
  end,
})

def("boss_hurt", {
  gain = 0.9, variants = 3, pitchVar = 0.05,
  build = function(v, n, r)
    return { dur = 1.0, layers = {
      { osc = "noise", env = { type = "perc", a = 0.0004, d = 0.02, curve = 6 }, amp = 0.6 },
      { osc = "fm", freq = 150 * r:range(0.94, 1.08), ratio = 1.71,
        index = { type = "exp", tau = 0.08, peak = 5 },
        env = { type = "perc", a = 0.001, d = 0.55, curve = 2 }, amp = 0.55 },
      { osc = "sine", freq = { from = 200, to = 55, tau = 0.05 },
        env = { type = "perc", a = 0.001, d = 0.25, curve = 2.4 }, amp = 0.5 },
    }, fx = {
      { "softclip", drive = 2.6, mix = 0.7 },
      { "svf", type = "lp", cutoff = 5000, q = 0.9 },
      { "reverb", mix = 0.2, room = 0.8 },
    } }
  end,
})

def("boss_beam", {
  gain = 0.95, variants = 2,
  build = function(v)
    return { dur = 2.6, layers = {
      { osc = "saw", freq = { from = 180, to = 320, tau = 1.2, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 1.2, 0.7 }, { 1.4, 1 }, { 2.4, 0 } } },
        amp = 0.26, detune = -8 },
      { osc = "square", duty = 0.24, freq = { from = 90, to = 160, tau = 1.2, curve = "lin" },
        env = { type = "bp", points = { { 0, 0 }, { 1.3, 0.6 }, { 2.4, 0 } } }, amp = 0.18 },
      { osc = "noise", env = { type = "bp", points = { { 0, 0 }, { 1.35, 0.2 }, { 1.45, 1 },
                                                       { 2.3, 0 } } }, amp = 0.45 },
      { osc = "sine", freq = { from = 1200, to = 240, tau = 0.5 },
        env = { type = "bp", points = { { 0, 0 }, { 1.4, 0 }, { 1.45, 0.8 }, { 2.4, 0 } } },
        amp = 0.4 },
    }, fx = {
      { "svf", type = "bp", cutoff = { from = 800, to = 2600, tau = 1.0 }, q = 1.8 },
      { "softclip", drive = 2, mix = 0.6 },
      { "reverb", mix = 0.3, room = 0.86 },
    } }
  end,
})

-- UI ----------------------------------------------------------------------
def("ui_move", {
  bus = "ui", gain = 0.35, variants = 3, pitchVar = 0.04,
  build = function(v, n, r)
    local hz = 1180 * r:range(0.97, 1.03)
    return { dur = 0.12, layers = {
      { osc = "sine", freq = hz, env = { type = "perc", a = 0.001, d = 0.05, curve = 3 }, amp = 0.4 },
      { osc = "noise", env = { type = "perc", a = 0.0003, d = 0.008, curve = 5 }, amp = 0.12 },
    }, fx = { { "svf", type = "hp", cutoff = 500, q = 0.7 } } }
  end,
})

def("ui_select", {
  bus = "ui", gain = 0.5, variants = 3, pitchVar = 0.03,
  build = function(v, n, r)
    local hz = 660 * r:range(0.98, 1.02)
    return { dur = 0.35, layers = {
      { osc = "sub", at = 0, amp = 1, spec = { dur = 0.2, layers = {
        { osc = "sine", freq = hz, env = { type = "perc", a = 0.001, d = 0.09, curve = 3 },
          amp = 0.5 } }, normalize = 0.8, trim = false } },
      { osc = "sub", at = 0.055, amp = 1, spec = { dur = 0.28, layers = {
        { osc = "sine", freq = hz * 1.5, env = { type = "perc", a = 0.001, d = 0.16, curve = 2.6 },
          amp = 0.5 },
        { osc = "sine", freq = hz * 3, env = { type = "perc", a = 0.001, d = 0.06, curve = 3 },
          amp = 0.12 } }, normalize = 0.8, trim = false } },
    }, fx = { { "reverb", mix = 0.12 } } }
  end,
})

def("ui_back", {
  bus = "ui", gain = 0.45, variants = 3, pitchVar = 0.03,
  build = function(v, n, r)
    local hz = 520 * r:range(0.98, 1.02)
    return { dur = 0.3, layers = {
      { osc = "sub", at = 0, amp = 1, spec = { dur = 0.18, layers = {
        { osc = "sine", freq = hz, env = { type = "perc", a = 0.001, d = 0.08, curve = 3 },
          amp = 0.5 } }, normalize = 0.8, trim = false } },
      { osc = "sub", at = 0.05, amp = 1, spec = { dur = 0.24, layers = {
        { osc = "sine", freq = hz * 0.75, env = { type = "perc", a = 0.001, d = 0.13, curve = 2.6 },
          amp = 0.5 } }, normalize = 0.8, trim = false } },
    }, fx = { { "svf", type = "lp", cutoff = 3000, q = 0.8 } } }
  end,
})

def("card_hover", {
  bus = "ui", gain = 0.3, variants = 4, pitchVar = 0.06,
  build = function(v, n, r)
    return { dur = 0.25, layers = {
      { osc = "pink", env = { type = "bp", points = { { 0, 0 }, { 0.02, 1 }, { 0.12, 0 } } },
        amp = 0.35 },
      { osc = "sine", freq = 1600 * r:range(0.9, 1.12),
        env = { type = "perc", a = 0.002, d = 0.07, curve = 3 }, amp = 0.12 },
    }, fx = { { "svf", type = "bp", cutoff = { from = 1800, to = 4200, tau = 0.06 }, q = 1.6 } } }
  end,
})

-- CARD_PICK -- the thunk. Card face slap (bright noise transient), the table
-- underneath (a short 90 Hz body), and a confirming fifth so it feels rewarded.
def("card_pick", {
  bus = "ui", gain = 0.8, variants = 3, pitchVar = 0.02,
  build = function(v, n, r)
    return { dur = 0.7, layers = {
      { osc = "noise", env = { type = "perc", a = 0.0004, d = 0.02, curve = 5 }, amp = 0.55 },
      { osc = "sine", freq = { from = 190, to = 88, tau = 0.02 },
        env = { type = "perc", a = 0.001, d = 0.14, curve = 2.6 }, amp = 0.8 },
      { osc = "tri", freq = 262, env = { type = "perc", a = 0.004, d = 0.3, curve = 2.2 },
        amp = 0.16 },
      { osc = "tri", freq = 392, env = { type = "perc", a = 0.006, d = 0.34, curve = 2.2 },
        amp = 0.12 },
    }, fx = {
      { "svf", type = "lp", cutoff = { from = 6000, to = 2000, tau = 0.06 }, q = 0.9 },
      { "softclip", drive = 1.8, mix = 0.6 },
      { "reverb", mix = 0.16 },
    } }
  end,
})

-- O2 milestone -- a shimmering ascending arpeggio; the sky getting better.
def("o2_milestone", {
  bus = "ui", gain = 0.6, variants = 3, pitchVar = 0.01,
  build = function(v)
    local root = 67 + (v - 2) * 2
    local layers = {}
    for i, s in ipairs({ 0, 4, 7, 11, 14 }) do
      layers[#layers + 1] = { osc = "sub", at = (i - 1) * 0.07, amp = 0.85, spec = {
        dur = 1.1, layers = {
          { osc = "fm", freq = Synth.noteToHz(root + s), ratio = 4.01,
            index = { type = "exp", tau = 0.05, peak = 1.3 },
            env = { type = "perc", a = 0.003, d = 0.9, curve = 2.2 }, amp = 0.4 } },
        normalize = 0.8, trim = false } }
    end
    return { dur = 1.9, layers = layers, fx = {
      { "delay", time = 0.14, fb = 0.35, mix = 0.22 },
      { "reverb", mix = 0.3, room = 0.85, damp = 0.3 } } }
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
    { osc = "sine", freq = hz * 0.5, env = { a = 0.5, d = 0.4, s = 0.7, r = 1.0 }, amp = 0.1 },
  }, fx = {
    { "svf", type = "lp", cutoff = { from = 400, to = 1900, tau = 1.1 }, q = 0.9 },
    { "chorus", mix = 0.4, rate = 0.28, depth = 0.006 },
    { "reverb", mix = 0.42, room = 0.9, damp = 0.35 },
  }, normalize = 0.78, trim = false, fadeIn = 0.02, fadeOut = 0.25 }
end })

mdef("bass", { gain = 0.72, dur = 1.0, rate = 11025, sparse = 2, build = function(hz)
  return { dur = 1.0, layers = {
    { osc = "sine", freq = hz * 0.5, env = { type = "perc", a = 0.006, d = 0.75, curve = 1.7 },
      amp = 0.75 },
    { osc = "tri", freq = hz, env = { type = "perc", a = 0.004, d = 0.3, curve = 2.2 }, amp = 0.16 },
    { osc = "square", duty = 0.3, freq = hz, env = { type = "perc", a = 0.002, d = 0.06, curve = 3 },
      amp = 0.07 },
  }, fx = {
    { "svf", type = "lp", cutoff = { from = 900, to = 260, tau = 0.3 }, q = 1.1 },
    { "softclip", drive = 1.5, mix = 0.5 },
  }, normalize = 0.82, trim = false }
end })

mdef("bell", { gain = 0.44, dur = 1.5, sparse = 3, build = function(hz)
  return { dur = 1.5, layers = {
    { osc = "fm", freq = hz, ratio = 3.01, index = { type = "exp", tau = 0.06, peak = 2.2 },
      env = { type = "perc", a = 0.004, d = 1.25, curve = 2 }, amp = 0.45 },
    { osc = "sine", freq = hz * 2, env = { type = "perc", a = 0.004, d = 0.6, curve = 2.6 },
      amp = 0.12 },
  }, fx = { { "reverb", mix = 0.34, room = 0.88, damp = 0.3 } }, normalize = 0.8, trim = false }
end })

mdef("pluck", { gain = 0.4, dur = 0.9, sparse = 2, build = function(hz)
  return { dur = 0.9, layers = { { osc = "pluck", freq = hz, damp = 0.42, decay = 0.9955,
                                   soft = 0.4, amp = 0.7 } },
    fx = { { "svf", type = "lp", cutoff = 4200, q = 0.9 },
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
    { "chorus", mix = 0.45, rate = 0.19, depth = 0.007 },
    { "reverb", mix = 0.45, room = 0.92, damp = 0.28 },
  }, normalize = 0.75, trim = false, fadeIn = 0.03, fadeOut = 0.3 }
end })

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
    for v = 1, d.variants do
      local spec = d.build(v, d.variants, rng)
      spec.rate = d.rate or Audio.rate
      registerBuffer(entry, Synth.render(spec), d.loop)
    end
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
    Audio.music[name] = entry
    Audio.sounds["mus_" .. name] = entry
    entry.bus = "music"
  end

  -- percussion (pitchless, so it lives in the music bank with 3 variants each)
  local perc = {
    kick = { gain = 0.85, rate = 11025, spec = function(r) return { dur = 0.7, layers = {
      { osc = "sine", freq = { from = 150 * r:range(0.95, 1.05), to = 42, tau = 0.035 },
        env = { type = "perc", a = 0.001, d = 0.42, curve = 1.8 }, amp = 0.9 },
      { osc = "noise", env = { type = "perc", a = 0.0004, d = 0.012, curve = 5 }, amp = 0.2 },
    }, fx = { { "softclip", drive = 1.7, mix = 0.6 }, { "svf", type = "lp", cutoff = 2600, q = 0.8 } },
      normalize = 0.85, trim = false } end },
    hat = { gain = 0.3, spec = function(r) return { dur = 0.28, layers = {
      { osc = "noise", env = { type = "perc", a = 0.0004, d = r:range(0.03, 0.09), curve = 4 },
        amp = 0.5 } },
      fx = { { "svf", type = "hp", cutoff = 5200, q = 1.1 }, { "bitcrush", bits = 7 } },
      normalize = 0.6, trim = false } end },
    shaker = { gain = 0.3, spec = function(r) return { dur = 0.3, layers = {
      { osc = "pink", env = { type = "bp", points = { { 0, 0 }, { 0.012, 1 }, { 0.1, 0 } } },
        amp = 0.5 } },
      fx = { { "svf", type = "bp", cutoff = r:range(3600, 5200), q = 1.4 } },
      normalize = 0.55, trim = false } end },
    tom = { gain = 0.55, rate = 11025, spec = function(r) return { dur = 0.6, layers = {
      { osc = "sine", freq = { from = 200 * r:range(0.9, 1.15), to = 78, tau = 0.09 },
        env = { type = "perc", a = 0.001, d = 0.35, curve = 2 }, amp = 0.8 },
      { osc = "noise", env = { type = "perc", a = 0.001, d = 0.05, curve = 4 }, amp = 0.12 },
    }, fx = { { "svf", type = "lp", cutoff = 3000, q = 0.9 }, { "reverb", mix = 0.18 } },
      normalize = 0.8, trim = false } end },
  }
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
  opts = opts or nil
  local d = entry.def

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
    -- ladder sounds walk a scale: index chosen by progress, with a little drift
    local p = (opts and opts.progress) or (name == "plant" and forest) or 0
    local base = 1 + p * (nv - 1)
    vi = floor(base + 0.5) + (random() < 0.4 and (random() < 0.5 and -1 or 1) or 0)
  else
    vi = rng:int(1, nv)
  end
  vi = U.clamp(vi, 1, nv)

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

  local bus = (opts and opts.bus) or entry.bus or d.bus or "sfx"

  -- concurrency cap: steal the quietest, oldest voice
  if #Audio.voices >= MAX_VOICES then
    -- steal whatever is closest to being over, weighted down by how loud it is:
    -- cutting the tail off a quiet, nearly-finished voice is inaudible
    local worst, wi
    for i = 1, #Audio.voices do
      local v = Audio.voices[i]
      if not v.loop then
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

return Audio
