-- The adaptive score. Not a loop of a wav: a small sequencer running on a
-- musical clock, firing pre-rendered instrument one-shots from the audio bank.
--
--   Music.load()
--   Music.update(dt)
--   Music.setState("title"|"day"|"dusk"|"night"|"boss"|"ending"|"draft", opts)
--   Music.setIntensity(0..1)   -- threat; layers fade in, tempo drifts up
--   Music.setO2(0..1)          -- the arpeggio opens up as the world heals
--   Music.setCycle(1..7)       -- the modal centre darkens as the run wears on
--
-- Theme: hopeful growth that curdles into loneliness. Cycle 1 is Lydian and
-- weightless; by cycle 7 the same music is Aeolian and thin. Night drops to
-- Aeolian outright, the boss goes Phrygian dominant, and the ending is one
-- unaccompanied Ionian line -- no pad, no bass, nobody else.

local U      = require("src.core.util")
local Signal = require("src.core.signal")
local Synth  = require("src.engine.synth")
local Audio  = require("src.engine.audio")

local Music = {}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local SCALES = Synth.scales
local NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

----------------------------------------------------------------------- layers
local LAYERS = { "pad", "bass", "arp", "bell", "perc", "choir" }

--------------------------------------------------------------------- palettes
-- Each state names a modal centre, a root offset from C3, a tempo, a chord
-- progression (scale degrees), how many bars each chord lasts, and where the
-- layers want to sit. Intensity and O2 push those targets around at run time.
local STATES = {
  title = {
    mode = "lydian", root = 2, bpm = 62, barsPerChord = 2,
    prog = { 1, 5, 6, 4 },
    layers = { pad = 0.85, bass = 0.3, arp = 0.25, bell = 0.5, perc = 0, choir = 0.12 },
    density = 0.5,
  },
  day = {
    mode = "lydian", root = 2, bpm = 74, barsPerChord = 2,
    prog = { 1, 2, 6, 5 },
    layers = { pad = 0.8, bass = 0.45, arp = 0.55, bell = 0.5, perc = 0, choir = 0 },
    density = 0.7,
  },
  dusk = {
    mode = "mixolydian", root = 2, bpm = 82, barsPerChord = 1,
    prog = { 1, 7, 6, 5 },
    layers = { pad = 0.75, bass = 0.7, arp = 0.45, bell = 0.5, perc = 0.25, choir = 0 },
    density = 0.75,
  },
  night = {
    -- The night used to be 94% of its energy below 250 Hz: a rumble with a kick
    -- in it. Pressure is not the same thing as weight -- the bass comes back a
    -- little and the tune, the arpeggio and the bed come forward, so the night
    -- is *busier* than the day rather than merely lower.
    mode = "aeolian", root = 2, bpm = 96, barsPerChord = 1,
    prog = { 1, 6, 7, 5 },
    layers = { pad = 0.7, bass = 0.75, arp = 0.6, bell = 0.75, perc = 0.75, choir = 0 },
    density = 0.95,
  },
  boss = {
    mode = "phrygianDominant", root = 1, bpm = 104, barsPerChord = 1,
    prog = { 1, 2, 1, 7 },      -- the b2 leaning on the tonic: threat, not menace-by-volume
    layers = { pad = 0.6, bass = 0.75, arp = 0.8, bell = 0.6, perc = 0.7, choir = 1.0 },
    density = 1.0,
  },
  draft = {
    mode = "ionian", root = 2, bpm = 60, barsPerChord = 2,
    prog = { 1, 4, 5, 1 },
    layers = { pad = 0.7, bass = 0.25, arp = 0.4, bell = 0.6, perc = 0, choir = 0.15 },
    density = 0.5,
  },
  ending = {
    -- One voice. Nothing under it. This is the whole point of the game.
    --
    -- The 2019 pass read "quiet" as the instruction and produced four notes in
    -- thirty seconds at -45 dBFS: not loneliness, an outage. Loneliness is not
    -- the absence of sound, it is a phrase that gets no answer. So the ending
    -- plays the theme's *call* in full, at a level you can actually hear, and
    -- then leaves the four bars where the answer lives completely empty except
    -- for one low tonic holding the floor. Then it asks again.
    mode = "ionian", root = 2, bpm = 54, barsPerChord = 4,
    prog = { 1, 6, 4, 1 },
    layers = { pad = 0, bass = 0, arp = 0, bell = 1.0, perc = 0, choir = 0 },
    density = 1.0,
  },
}

-- How bright the day/dusk material is allowed to be, per cycle. The music
-- forgets how to be hopeful at roughly the rate the player does.
local CYCLE_MODES = { "lydian", "lydian", "ionian", "ionian", "mixolydian", "dorian", "aeolian" }

------------------------------------------------------------------- the theme
-- The tune. Fixed pitches on a fixed rhythm, four bars long, in two halves: a
-- CALL that climbs to the octave and settles back on the third, and an ANSWER
-- that climbs one step further and comes to rest on the fifth.
--
-- This is the one thing the 2019 sequencer did not have. Its "melody" was eight
-- scale degrees fired at whichever of three slots per bar happened to win a coin
-- toss, so the pitches recurred but the rhythm never did, and the phrase drifted
-- out of phase with the harmony after two and a half bars. A player cannot hum a
-- melody whose rhythm is random. Everything else in the score can be generative;
-- the tune cannot be.
--
-- The same eight bars carry the whole game: weightless in Lydian on the title,
-- darkening a mode per cycle, fragmented under the night, in augmentation on the
-- choir at the boss -- and alone, unanswered, at the end.
--
-- Entries are { step within the phrase (0..63), scale degree, length in 16ths,
-- velocity }. Degrees are relative to the key, not the chord: a melody sits
-- above a progression, it does not follow it around.
local THEME = {
  -- call: bars 1-2
  { 0,  5, 6, 1.00 }, { 6,  6, 2, 0.68 }, { 8,  8, 4, 0.92 }, { 12, 7, 4, 0.74 },
  { 16, 6, 6, 0.86 }, { 22, 5, 2, 0.62 }, { 24, 3, 8, 0.80 },
  -- answer: bars 3-4
  { 32, 5, 6, 0.92 }, { 38, 6, 2, 0.64 }, { 40, 8, 4, 0.88 }, { 44, 9, 4, 0.82 },
  { 48, 8, 6, 0.90 }, { 54, 6, 2, 0.60 }, { 56, 5, 10, 0.95 },
}
local PHRASE = 64             -- four bars of sixteenths

-- step -> the theme notes that start on it, built once.
local THEME_AT = {}
for i = 1, #THEME do
  local t = THEME[i]
  THEME_AT[t[1]] = THEME_AT[t[1]] or {}
  table.insert(THEME_AT[t[1]], t)
end

-- Per-layer output trim. The score used to run 12 dB louder at the boss than in
-- the day purely because the bass and kick were sub-heavy; these keep the states
-- inside a range one music-bus fader can serve.
local TRIM = { pad = 1.05, bass = 0.55, arp = 1.0, bell = 1.2, perc = 0.58, choir = 1.15 }

--------------------------------------------------------------------- state
local M = {
  state = "title", def = STATES.title,
  mode = SCALES.lydian, modeName = "lydian",
  prog = STATES.title.prog,
  root = 2, bpm = 62, targetBpm = 62,
  intensity = 0, o2 = 0, cycle = 1,
  playing = false,

  clock = 0,          -- seconds since start
  curStep = 0, phraseStep = 0,
  beat = 0,           -- fractional beats
  step = 0,           -- 16th index since start
  bar = 0, beatInBar = 0, stepInBar = 0,
  chordIndex = 1, barsSinceChord = 0,
  gains = {}, targets = {}, fade = 0.25,
  pending = nil,
  lastNotes = {},
  armed = {},         -- a layer only starts playing on a bar line, never mid-phrase
}
Music.M = M

local rng = U.rng(0x5EED)

for _, l in ipairs(LAYERS) do M.gains[l] = 0 M.targets[l] = 0 M.armed[l] = false end

------------------------------------------------------------------- harmony
local function semisOf(deg) return Synth.degree(M.mode, deg) end

--- Triad (plus optional 7th/9th colour) on a scale degree, as semitones from C3.
local function chordTones(deg, extra)
  local t = { M.root + semisOf(deg), M.root + semisOf(deg + 2), M.root + semisOf(deg + 4) }
  if extra == 7 then t[4] = M.root + semisOf(deg + 6) end
  if extra == 9 then t[4] = M.root + semisOf(deg + 8) end
  return t
end

local function chordName()
  local deg = M.prog[M.chordIndex]
  local root = (M.root + semisOf(deg)) % 12
  local third = semisOf(deg + 2) - semisOf(deg)
  local quality = (third <= 3) and "m" or ""
  return NAMES[root + 1] .. quality
end
Music.chordName = chordName

---------------------------------------------------------------------- timing
local function barSeconds() return 4 * 60 / M.bpm end

local function setTargetsFromDef()
  local d = M.def
  local it = M.intensity
  for _, l in ipairs(LAYERS) do M.targets[l] = d.layers[l] or 0 end
  -- intensity: rhythm section forward, pad back, so pressure reads as pulse
  M.targets.bass  = min(1, M.targets.bass * (0.75 + it * 0.6))
  M.targets.perc  = min(1, M.targets.perc * (0.55 + it * 0.9))
  M.targets.pad   = M.targets.pad * (1.05 - it * 0.28)
  M.targets.bell  = M.targets.bell * (1.0 - it * 0.35)
  -- oxygen: the arpeggio is the sound of the world healing
  M.targets.arp   = M.targets.arp * (0.15 + 1.05 * M.o2)
  M.targetBpm = d.bpm * (1 + it * 0.1)
end

--------------------------------------------------------------------- loading
function Music.load()
  if not Audio.loaded then Audio.load() end
  rng = U.rng(0x5EED)
  M.playing = false
  return true
end

--------------------------------------------------------------------- controls
--- Switch musical state. Harmony changes on the next bar line, never mid-bar.
function Music.setState(name, opts)
  local d = STATES[name]
  if not d then return end
  if not Audio.loaded then Music.load() end
  opts = opts or {}
  M.state = name
  M.def = d
  if opts.cycle then M.cycle = U.clamp(opts.cycle, 1, #CYCLE_MODES) end

  -- modal centre: states with their own colour keep it, day/dusk darken by cycle
  local modeName = d.mode
  if name == "day" or name == "draft" or name == "title" then
    modeName = CYCLE_MODES[M.cycle] or d.mode
  elseif name == "dusk" then
    local m = CYCLE_MODES[M.cycle]
    modeName = (m == "lydian" or m == "ionian") and "mixolydian" or "aeolian"
  end
  local newRoot = d.root - (M.cycle - 1) * ((name == "day" or name == "dusk") and 0.5 or 0)
  newRoot = floor(newRoot + 0.5)

  M.pending = { mode = modeName, root = newRoot, prog = d.prog }
  if not M.playing then
    -- first state: take it immediately so there is no silent bar at boot
    M.mode = SCALES[modeName] or SCALES.ionian
    M.modeName = modeName
    M.root = newRoot
    M.prog = d.prog
    M.chordIndex = 1
    M.pending = nil
    M.playing = true
    M.bpm = d.bpm
    M.firstStep = true      -- fire the downbeat now, not a bar from now
    M.snap = true           -- and come in at level, rather than fading up from nothing
  end
  M.fade = (opts.fadeBars or 3) * barSeconds()
  setTargetsFromDef()
  if M.snap then
    for _, l in ipairs(LAYERS) do M.gains[l] = M.targets[l] M.armed[l] = true end
    M.snap = nil
  end
  Signal.emit("music:state", name)
end

function Music.setIntensity(v)
  M.intensity = U.saturate(v or 0)
  setTargetsFromDef()
end

function Music.setO2(v)
  M.o2 = U.saturate(v or 0)
  setTargetsFromDef()
end

function Music.setCycle(c)
  M.cycle = U.clamp(floor(c or 1), 1, #CYCLE_MODES)
end

function Music.stop(fade)
  for _, l in ipairs(LAYERS) do M.targets[l] = 0 end
  M.fade = (fade or 2) * barSeconds()
end

function Music.isPlaying() return M.playing end

------------------------------------------------------------------ note firing
--- Is a layer allowed to make a sound this step? A layer must be both audible
--- and *armed* -- armed happens on a bar line, so a layer that fades up in the
--- middle of a phrase still waits for the downbeat to come in.
local function live(layer)
  return M.gains[layer] > 0.05 and M.armed[layer]
end

local function note(inst, semis, opts)
  semis = U.clamp(floor(semis + 0.5), -30, 32)
  local v = Audio.playMusic(inst, semis, opts)
  local ln = M.lastNotes
  table.insert(ln, 1, { inst = inst, semis = semis, t = 0 })
  for i = #ln, 9, -1 do ln[i] = nil end
  return v
end

--- One 16th step of the sequencer.
local function stepTick(step)
  local sib = step % 16                     -- step in bar
  local sip = step % PHRASE                 -- step in the four-bar phrase
  M.curStep, M.phraseStep = step, sip       -- exposed for the debug view
  local barInPhrase = floor(sip / 16)       -- 0..3
  local g = M.gains
  local d = M.def
  local dens = d.density or 0.7
  local it = M.intensity
  local st = M.state
  local ending = (st == "ending")
  local boss = (st == "boss")
  local tones = chordTones(M.prog[M.chordIndex], boss and 7 or 9)

  ---------------------------------------------------------------- pad bed
  if live("pad") and sib == 0 then
    for i = 1, 3 do
      local pan = (i - 2) * 0.45
      note("pad", tones[i] + 12, { volume = g.pad * TRIM.pad * (i == 1 and 0.9 or 0.7),
                                   pan = pan })
    end
    if boss or st == "night" then
      note("pad", tones[1], { volume = g.pad * TRIM.pad * 0.5, pan = 0 })
    end
  end

  ---------------------------------------------------------------- choir
  -- At the boss the choir does not simply switch on: it enters on the second
  -- half of the phrase and answers with the theme in augmentation, so the
  -- tension arrives as a voice joining rather than as a fader moving.
  if live("choir") and sib == 0 then
    if boss then
      if barInPhrase >= 2 then
        note("choir", tones[2] + 12, { volume = g.choir * TRIM.choir * 0.9, pan = -0.25 })
        note("choir", tones[1] + 12, { volume = g.choir * TRIM.choir * 0.8, pan = 0.3 })
      end
    else
      note("choir", tones[2] + 12, { volume = g.choir * TRIM.choir * 0.8, pan = -0.25 })
    end
  end
  -- the theme, at half speed, on the choir: the boss cue's actual argument
  if boss and live("choir") and sip % 8 == 0 then
    local idx = floor(sip / 8) + 1
    local t = THEME[idx]
    if t and t[4] > 0.8 then
      note("choir", M.root + semisOf(t[2]) + 12,
           { volume = g.choir * TRIM.choir * 0.75 * t[4], pan = 0.15 })
    end
  end

  ---------------------------------------------------------------- bass pulse
  if live("bass") then
    local hit = (sib == 0) or (sib == 8)
    if it > 0.35 and sib == 6 then hit = true end
    if it > 0.6 and (sib == 11 or sib == 14) then hit = rng:chance(0.45 + it * 0.3) end
    if boss and (sib % 4 == 0) then hit = true end
    if hit then
      local n = tones[1] - 12
      if sib ~= 0 and rng:chance(0.25) then n = tones[3] - 12 end
      -- the boss climbs chromatically through the last bar of every phrase:
      -- pressure you can hear coming rather than pressure that is simply loud
      if boss and barInPhrase == 3 then n = n + floor(sib / 4) end
      note("bass", n, { volume = g.bass * TRIM.bass * (sib == 0 and 0.95 or 0.7), pan = 0 })
    end
  end

  ---------------------------------------------------------------- arpeggio
  if live("arp") then
    local every = (M.o2 > 0.55 or boss) and 2 or 4    -- opens from 8ths to 16ths
    if sib % every == 0 and (boss or rng:chance(0.55 + dens * 0.4)) then
      local semis
      if boss then
        -- a relentless pedal alternating the tonic and the flat second: the
        -- interval the whole boss mode is built on, hammered
        semis = M.root + semisOf(1) + ((floor(step / 2) % 2 == 1) and 1 or 0) + 12
      else
        local reach = 3 + floor(M.o2 * 4)             -- and reaches further up
        local idx = 1 + (floor(step / every) % reach)
        semis = M.root + semisOf(M.prog[M.chordIndex] + (idx - 1) * 2) + 12
      end
      note("pluck", semis, {
        volume = g.arp * TRIM.arp * (0.45 + 0.3 * M.o2) * (sib % 4 == 0 and 1 or 0.72),
        pan = ((step % 5) - 2) * 0.22,
      })
    end
  end

  ---------------------------------------------------------------- the theme
  if live("bell") then
    local notes = THEME_AT[sip]
    if notes then
      for i = 1, #notes do
        local t = notes[i]
        local isAnswer = (t[1] >= 32)
        -- the ending asks and is not answered
        local play = not (ending and isAnswer)
        -- under a night, only the strong bones of the tune survive
        if st == "night" and t[4] < 0.8 then play = false end
        if play then
          local semis = M.root + semisOf(t[2]) + 12
          note("bell", semis, {
            volume = g.bell * TRIM.bell * (0.55 + 0.45 * t[4]) * (ending and 1.25 or 1),
            pan = ((t[2] % 3) - 1) * 0.22,
          })
        end
      end
    end
    -- The ending's empty half. Two low tonics, one per two bars, holding the
    -- floor under the bars where the answer should have been -- so the silence
    -- is a room the phrase is standing in, and not a dropout. Without them the
    -- cue goes to true digital zero for five seconds, which does not read as
    -- loneliness; it reads as the audio having stopped.
    if ending and (sip == 32 or sip == 48) then
      note("bell", M.root + semisOf(1) - 12,
           { volume = g.bell * TRIM.bell * (sip == 32 and 0.5 or 0.34), pan = 0 })
    end
  end

  ---------------------------------------------------------------- percussion
  if live("perc") then
    local vol = g.perc * TRIM.perc
    if sib == 0 or sib == 8 or (it > 0.5 and sib == 11 and rng:chance(0.5)) then
      note("kick", 0, { volume = vol * 0.9 })
    end
    if boss and barInPhrase == 3 and sib % 4 == 2 then
      note("kick", 0, { volume = vol * 0.7 })
    end
    if sib % 2 == 0 and rng:chance(0.35 + it * 0.55) then
      note("hat", 0, { volume = vol * (sib % 4 == 0 and 0.5 or 0.32),
                       pan = rng:range(-0.35, 0.35) })
    end
    if sib % 4 == 2 and rng:chance(0.3 + it * 0.3) then
      note("shaker", 0, { volume = vol * 0.3, pan = rng:range(-0.5, 0.5) })
    end
    -- fills land at the end of a phrase, where the ear is already expecting one
    if barInPhrase == 3 and sib >= 12 and (boss or rng:chance(0.5)) then
      if sib % 2 == 0 then
        note("tom", rng:int(-5, 3) - (sib - 12), { volume = vol * 0.55,
                                                   pan = ((sib % 4) - 1.5) * 0.3 })
      end
    end
  end
end

--- Bar line: advance the progression and apply any pending modal change.
local function barTick()
  M.bar = M.bar + 1
  M.barsSinceChord = M.barsSinceChord + 1
  for i = 1, #LAYERS do
    local l = LAYERS[i]
    M.armed[l] = (M.gains[l] > 0.05) or (M.targets[l] > 0.05 and M.gains[l] > 0.02)
  end
  if M.pending then
    -- harmony only ever changes on a bar line, so a state change is felt as a
    -- modulation rather than heard as a seam. Layer gains keep crossfading.
    M.mode = SCALES[M.pending.mode] or M.mode
    M.modeName = M.pending.mode
    M.root = M.pending.root
    M.prog = M.pending.prog
    M.chordIndex = 1
    M.barsSinceChord = 0
    M.pending = nil
    Signal.emit("music:mode", M.modeName)
  elseif M.barsSinceChord >= (M.def.barsPerChord or 1) then
    M.barsSinceChord = 0
    M.chordIndex = M.chordIndex % #M.prog + 1
  end
end

--------------------------------------------------------------------- update
function Music.update(dt)
  if not M.playing then return end
  dt = min(dt or 0, 1 / 15)

  -- layer crossfades (2-4 bars); tempo drifts toward its target
  local k = 1 - math.exp(-dt / max(0.05, M.fade / 3))
  for _, l in ipairs(LAYERS) do
    M.gains[l] = M.gains[l] + (M.targets[l] - M.gains[l]) * k
  end
  M.bpm = U.damp(M.bpm, M.targetBpm, 0.35, dt)

  if M.firstStep then M.firstStep = false stepTick(0) end

  M.clock = M.clock + dt
  local stepsPerSec = M.bpm / 60 * 4
  local prev = M.step
  M.beat = M.beat + dt * M.bpm / 60
  local newStep = M.step + dt * stepsPerSec
  -- fire every whole 16th we crossed (dt is clamped, so this is 0..3 steps)
  local i = floor(prev)
  while i < floor(newStep) do
    i = i + 1
    if i % 16 == 0 then barTick() end
    stepTick(i)
  end
  M.step = newStep
  M.stepInBar = floor(M.step) % 16
  M.beatInBar = floor(M.stepInBar / 4)

  for _, n in ipairs(M.lastNotes) do n.t = n.t + dt end
end

--------------------------------------------------------------------- debug
--- Everything the demo visualiser draws.
function Music.debug()
  return {
    state = M.state, mode = M.modeName, root = NAMES[(M.root % 12) + 1],
    bpm = M.bpm, bar = M.bar + 1, beat = M.beatInBar + 1, step = M.stepInBar + 1,
    chord = chordName(), chordIndex = M.chordIndex, prog = M.prog,
    gains = M.gains, targets = M.targets, layers = LAYERS,
    intensity = M.intensity, o2 = M.o2, cycle = M.cycle,
    playing = M.playing, notes = M.lastNotes, pending = M.pending,
    phraseStep = M.phraseStep, theme = THEME, phrase = PHRASE,
  }
end

Music.theme = THEME
Music.phraseSteps = PHRASE
Music.layerNames = LAYERS
Music.stateNames = { "title", "day", "dusk", "night", "boss", "draft", "ending" }

return Music
