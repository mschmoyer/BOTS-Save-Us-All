-- DEPRECATED. The adaptive procedural score. Superseded by src/engine/music.lua,
-- which streams authored tracks; this module is kept because it still runs (the
-- demo scenes still drive it) and because the finale's five-part arc is the only
-- written record of what the extraction is supposed to sound like. Nothing in
-- the shipped game requires it any more.
--
-- Not a loop of a wav: a small sequencer running on a
-- musical clock, firing pre-rendered instrument one-shots from the audio bank.
--
--   Music.load()
--   Music.update(dt)
--   Music.setState("title"|"day"|"dusk"|"night"|"boss"|"ending"|"draft", opts)
--   Music.setIntensity(0..1)   -- threat; layers fade in, tempo drifts up
--   Music.setO2(0..1)          -- the arpeggio opens up as the world heals
--   Music.setCycle(1..7)       -- the modal centre darkens as the run wears on
--
-- and, for the finale only, because the finale is the only cue in the game with
-- a script rather than a level:
--
--   Music.bossPart(1..5)       -- arrival / procession / plates / core / fall
--   Music.cohort()             -- a wave of the workforce has left
--   Music.bossFell()           -- the rig is down; play the cadence
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
    -- The harmonic identity of the whole finale; the parts below inherit it and
    -- differ only in what is playing and how fast. See BOSS_PARTS.
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

----------------------------------------------------------------- the finale
-- The extraction used to be one cue: setState("boss") fired when the rig landed
-- and nothing moved for the next hundred seconds. That was defensible when the
-- fight was eight seconds long. It is not now -- the finale has a *shape*, and
-- it is not the shape of a health bar. The rig lands; the crew starts walking;
-- the plates come off; the last of them go in; the rig falls. Five things, in
-- that order, every time, whether the player built twelve bots or sixty.
--
-- So the boss state is five sub-states sharing one harmonic identity (Phrygian
-- dominant a semitone above C, the flat second leaning on the tonic). They all
-- run the same six layers; what changes is which of them are allowed to speak,
-- how fast, and how much of the game's own tune the cue is permitted to quote.
--
-- The argument the arc makes:
--
--   1 ARRIVAL     Almost nothing. A pedal, a heartbeat, a little floor tom. No
--                 choir, no arpeggio, and *no theme* -- the tune the player has
--                 heard in every state of the game is taken away the moment the
--                 rig lands. Withholding is the only device that makes an entry
--                 mean anything, and this cue has four entries to make.
--   2 PROCESSION  The crew starts walking. The choir arrives -- voices, at the
--                 exact moment the machines decide something -- with the arp
--                 pedal and the kit under it. Still no tune.
--   3 PLATES      The armour comes off. Tempo up, the harmony starts moving
--                 (a real vi), and the theme returns, but only its strong bones,
--                 the way the night fragments it. You hear it *trying*.
--   4 CORE        The last of them go in. Everything is in, the tune is whole
--                 for the first time since the day, and it is being played over
--                 the thing that came to kill the sky.
--   5 FALL        Ritardando to 62, everything but the choir and the bed gone,
--                 and one major triad on the tonic -- which Phrygian dominant
--                 already contains, so the resolution is not a modulation, it
--                 is the mode finally being allowed to mean the thing it always
--                 spelled. Then the ending scene takes over.
--
-- Layers here are absolute, not multipliers: the parts author the whole balance
-- and Music.setIntensity is deliberately almost inert inside them (see
-- setTargetsFromDef). During the finale the score is not reacting to threat --
-- it knows what is happening.
--
-- Measured on the music bus, relative to a cycle-1 day (tools: a headless pass
-- that runs each state and reads Audio.meter("music")):
--
--   arrival -2.0 dB   procession +1.7   plates +3.3   core +5.5   fall +1.4
--
-- Night is +2.9, so the arrival sits five dB below the night the player has just
-- survived -- that drop is what makes the rest of the cue an arrival rather than
-- a volume knob -- and the core, the loudest sustained thing in the game, is two
-- and a half dB above the night. The fall is quieter than either and has the
-- highest *peak* of any state in the game, because it is one chord and nothing
-- else.
--
-- The first pass of these numbers measured +8.2 dB at the core, which is the
-- same mistake the TRIM table below was written to fix. Every state in the game
-- now lives inside a seven and a half dB window that one fader can serve.
local BOSS_PARTS = {
  { name = "arrival",    bpm = 84,  barsPerChord = 2, prog = { 1, 1, 7, 1 },
    layers = { pad = 0.52, bass = 0.6, arp = 0, bell = 0, perc = 0.22, choir = 0 },
    theme = "none", density = 0.45, fadeBars = 1 },
  { name = "procession", bpm = 100, barsPerChord = 1, prog = { 1, 2, 1, 7 },
    layers = { pad = 0.58, bass = 0.66, arp = 0.42, bell = 0, perc = 0.5, choir = 0.68 },
    theme = "none", density = 0.85, fadeBars = 2 },
  { name = "plates",     bpm = 107, barsPerChord = 1, prog = { 1, 2, 6, 7 },
    layers = { pad = 0.6, bass = 0.72, arp = 0.58, bell = 0.5, perc = 0.62, choir = 0.78 },
    theme = "strong", density = 1.0, fadeBars = 2 },
  { name = "core",       bpm = 113, barsPerChord = 1, prog = { 1, 4, 6, 7 },
    layers = { pad = 0.46, bass = 0.7, arp = 0.56, bell = 0.8, perc = 0.58, choir = 0.78 },
    theme = "full", density = 1.0, fadeBars = 2 },
  { name = "fall",       bpm = 62,  barsPerChord = 4, prog = { 1, 1, 1, 1 },
    -- no bell layer: the only melodic note in the fall is the one Music
    -- .bossFell fires by hand, on the downbeat of the rig hitting the island
    layers = { pad = 0.8, bass = 0.28, arp = 0, bell = 0, perc = 0, choir = 0.9 },
    theme = "none", density = 0, fadeBars = 1 },
}

-- THE PROCESSION'S LINE.
--
-- Each wave puts a low toll under an answering voice, and that voice climbs. The
-- obvious way to write it -- degree = how far through fourteen waves we are --
-- is wrong, because the procession does not reliably run to fourteen. It stops
-- when the hull drops under 16% (game/tuning, boss.rebelStopAt), a reserve never
-- leaves at all, and a run with three surviving bots sends exactly one cohort
-- and then nothing for another eighty seconds. A line indexed on wave count gets
-- cut off in the middle of a scale, on whatever degree it happened to reach.
--
-- So the degrees are authored, and they *plateau*. The climb takes seven waves
-- and reaches the octave; every wave after that is the octave or the tenth above
-- it. Wherever the procession actually stops -- wave 6, wave 10, wave 14 -- the
-- last thing heard is a consonance and the line has already arrived. The only
-- unstable degree in the sequence is the b2 at wave two, which is the interval
-- the whole cue is built on and is nowhere near where a procession ever ends.
--
-- Closure is not this line's job in any case: the tune comes back whole two
-- parts later and the cadence lands on top of it. The line only has to not sound
-- severed.
local TOLL_DEGREES = { 1, 2, 3, 5, 6, 7, 8, 8, 10, 8, 10, 8, 10, 8 }
local TOLL_TOP = 7          -- from here on the climb is over and the bell tolls

-- If the first cohort has not left by now, it is not coming: a run can reach the
-- extraction with no crew standing, and the boss's own phase gates then advance
-- on a 26 s stall timer rather than on arrivals. Part 1 is a withholding, and a
-- withholding that never resolves is not tension, it is a cue that has crashed.
-- A normal run's first wave lands at 8.5 s, so this only ever fires when there
-- genuinely is no procession.
local PART1_MAX_WAIT = 13.5

-- Each part is a complete state def in its own right, so nothing downstream has
-- to know the finale is special: it inherits the boss cue's modal centre and key
-- and overrides everything else. `part` is what marks it as one of these.
for i = 1, #BOSS_PARTS do
  local p = BOSS_PARTS[i]
  p.mode, p.root, p.part = STATES.boss.mode, STATES.boss.root, i
end

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
--
-- `perc` was 0.58 and it was compensating twice. That figure was set against a
-- kick that measured 98% of its energy below 80 Hz: the whole kit had to come
-- down 4.7 dB to stop one sine nobody could hear from eating the headroom, and
-- the hat, the shaker and the tom went down with it. The kick has a beater and a
-- shell now and the four kit pieces are loudness-matched to each other rather
-- than peak-normalised (engine/audio, PERC), so soloing the layer measures what
-- it actually contributes -- which dropped from -1.7 dB against the pad to -5.7,
-- because most of what it used to measure was inaudible. This puts the kit back
-- where a kit belongs: level with the bed, a little under the tune.
local TRIM = { pad = 1.05, bass = 0.55, arp = 1.0, bell = 1.2, perc = 0.88, choir = 1.15 }

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
  bossPart = nil,     -- 1..5 while the finale is running, nil otherwise
  partT = 0,          -- seconds in the current boss part
  tollIndex = 0, tollPending = false, tollsSeen = false,
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
  if d.part then
    -- The finale authors its own balance, so intensity is almost inert inside
    -- it. Threat is a reading of how badly a night is going; during the
    -- extraction it is neither news nor true -- the fight's shape is scripted
    -- and the score is playing the script, not reacting to it. All threat is
    -- allowed to do here is lean on the kit. O2 is ignored outright: the
    -- arpeggio is the sound of the world healing, and the world is not healing.
    M.targets.perc = min(1, M.targets.perc * (0.88 + it * 0.18))
    M.targets.bass = min(1, M.targets.bass * (0.92 + it * 0.12))
    -- The choir is the workforce. If the finale has got past its first part
    -- without a single cohort leaving -- no crew, or a crew of three of whom
    -- two are held in reserve -- then there is nobody to sing, and a full choir
    -- would be the score claiming something the screen is not showing. It comes
    -- in thin instead, which is its own reading: you are doing this alone.
    if not M.tollsSeen then M.targets.choir = M.targets.choir * 0.5 end
    M.targetBpm = d.bpm
    return
  end
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
  if opts.cycle then M.cycle = U.clamp(opts.cycle, 1, #CYCLE_MODES) end

  -- The finale is five sub-states, and it always enters at the first of them.
  -- The state also brackets the rig's own drone (engine/audio): the machine is
  -- allowed a voice exactly as long as its cue is running, so however the run
  -- ends -- victory, defeat, a scene switch nobody wrote a teardown for -- a
  -- looping source cannot outlive the fight.
  if name == "boss" then
    M.bossPart = U.clamp(floor(opts.part or 1), 1, #BOSS_PARTS)
    M.tollIndex, M.tollPending, M.tollsSeen = 0, false, false
    M.partT = 0
    d = BOSS_PARTS[M.bossPart]
    if Audio.rigOpen then Audio.rigOpen() end
  else
    M.bossPart = nil
    if Audio.rigStop then Audio.rigStop(true) end
  end
  M.def = d

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
  M.fade = (opts.fadeBars or d.fadeBars or 3) * barSeconds()
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

--- The procession's toll. A cohort has walked into the rig; this is the score
--- acknowledging it, quantised to the next beat so fourteen of them are a
--- rhythm and not fourteen interruptions.
---
--- The low bell never changes -- it is a bell in a tower, and it does not get
--- more interesting because more of them have gone. What changes is the voice
--- that answers it, which walks one step up the mode per wave, from the tonic to
--- the octave across the whole procession. That is deliberately the same shape
--- the game's theme opens with (THEME: a call that climbs to the octave), so the
--- rebellion sings the first half of the player's own tune without ever quoting
--- it -- and then the tune itself comes back two parts later.
---
--- These bypass the layer gains on purpose. The toll is an event, not a bed: it
--- has to be audible in part 1 where the choir has not arrived yet.
local function toll()
  local i = max(1, M.tollIndex or 1)
  local deg = TOLL_DEGREES[min(i, #TOLL_DEGREES)]
  local up = min(1, (i - 1) / (TOLL_TOP - 1))
  local top = (i >= TOLL_TOP)

  -- The low bell. It does not get more interesting because more of them have
  -- gone -- until the climb is over, at which point it starts alternating the
  -- tonic and the fifth beneath it, which is what a bell does when it is no
  -- longer announcing anything and is simply still ringing.
  local lowDeg = 1
  if top and (i - TOLL_TOP) % 2 == 1 then lowDeg = -2 end        -- the fifth below
  note("bell", M.root + semisOf(lowDeg) - 12,
       { volume = (i == 1 and 0.72 or 0.6) * TRIM.bell, pan = -0.12 })

  -- and the voice that answers it
  note("choir", M.root + semisOf(deg) + 12,
       { volume = (0.44 + 0.34 * up) * TRIM.choir, pan = 0.22 })
  note("bell", M.root + semisOf(deg) + 12,
       { volume = (0.28 + 0.26 * up) * TRIM.bell, pan = 0.34 })

  if not M.tollsSeen then
    M.tollsSeen = true
    setTargetsFromDef()      -- the choir was thin because nobody had gone yet
  end
end

---------------------------------------------------------------- the finale
--- Advance the extraction cue. Idempotent, so it is safe to drive from a signal
--- that may fire more than once.
function Music.bossPart(n)
  n = U.clamp(floor(n or 1), 1, #BOSS_PARTS)
  if M.state ~= "boss" then Music.setState("boss", { part = n }) return end
  if M.bossPart == n then return end
  M.bossPart = n
  M.partT = 0
  local d = BOSS_PARTS[n]
  M.def = d
  -- harmony moves on the next bar line like every other change in this file;
  -- the layers start crossfading immediately
  M.pending = { mode = d.mode, root = d.root, prog = d.prog }
  M.fade = (d.fadeBars or 2) * barSeconds()
  setTargetsFromDef()
  Signal.emit("music:bossPart", n, d.name)
end

--- Which part is running (0 if the finale is not).
function Music.bossPartIndex() return M.bossPart or 0 end

--- A wave of the workforce has left for the rig. Call it once per wave; `index`
--- is optional and defaults to counting. There is deliberately no "total": the
--- line is authored to survive stopping anywhere (see TOLL_DEGREES).
function Music.cohort(index)
  if M.state ~= "boss" then return end
  M.tollIndex = floor(index or ((M.tollIndex or 0) + 1))
  M.tollPending = true
  -- the first wave is the moment the whole game has been walking toward, and it
  -- is also the choir's cue
  if (M.bossPart or 1) < 2 then Music.bossPart(2) end
end

--- The rig is down.
---
--- Everything but the bed and the voices stops, the tempo falls away, and the
--- cue plays the one chord Phrygian dominant has been spelling since the rig
--- landed and never been allowed to mean: the major triad on its own tonic. It
--- is not a modulation and it is not a key change -- it is the mode finally
--- resolving to the thing it always contained, which is the only cadence this
--- particular ending could honestly have.
---
--- It does not wait for a bar line. The rig hitting the island is the downbeat.
function Music.bossFell()
  if M.state ~= "boss" then return end
  local n = #BOSS_PARTS
  local d = BOSS_PARTS[n]
  M.bossPart = n
  M.partT = 0
  M.def = d
  M.mode = SCALES[d.mode] or M.mode
  M.modeName = d.mode
  M.root = d.root
  M.prog = d.prog
  M.chordIndex, M.barsSinceChord = 1, 0
  M.pending = nil
  M.tollPending = false
  setTargetsFromDef()
  M.fade = 1.0
  -- the kit and the pedal go now, not over four bars: a ritardando under a
  -- hi-hat is a slowing-down, not an ending
  M.gains.arp, M.targets.arp = 0, 0
  M.gains.perc, M.targets.perc = 0, 0
  M.armed.pad, M.armed.choir, M.armed.bass = true, true, true

  local t = chordTones(1)
  note("choir", t[1] + 12, { volume = 1.0 * TRIM.choir, pan = -0.3 })
  note("choir", t[2] + 12, { volume = 0.82 * TRIM.choir, pan = 0.06 })
  note("choir", t[3] + 12, { volume = 0.78 * TRIM.choir, pan = 0.32 })
  note("pad", t[1], { volume = 0.85 * TRIM.pad, pan = 0 })
  note("pad", t[2] + 12, { volume = 0.6 * TRIM.pad, pan = 0.35 })
  note("pad", t[3] + 12, { volume = 0.6 * TRIM.pad, pan = -0.35 })
  note("bass", t[1] - 12, { volume = 0.9 * TRIM.bass })
  note("bell", t[1] + 24, { volume = 0.8 * TRIM.bell, pan = 0.15 })
  Signal.emit("music:bossPart", n, d.name)
end

--- Optional one-line wiring for the finale. Every cue it needs already exists as
--- a signal, so a caller that would rather not scatter four Music.* calls
--- through the game loop can bind them here instead. Nothing is bound until this
--- is called: requiring this module must never change what the game sounds like.
function Music.bindSignals(owner)
  owner = owner or Music
  Signal.clearOwner(owner)
  Signal.on("phase:extraction", function() Music.setState("boss") end, owner)
  Signal.on("bots:cohort",      function() Music.cohort() end, owner)
  Signal.on("boss:phase",       function(n) Music.bossPart((n or 2) + 1) end, owner)
  Signal.on("boss:died",        function() Music.bossFell() end, owner)
  return owner
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
  local part = d.part or 0                  -- 1..5 inside the finale, 0 outside
  local tones = chordTones(M.prog[M.chordIndex], boss and 7 or 9)

  -- a cohort's toll waits for the next beat rather than firing where it landed,
  -- which is what turns fourteen sacrifices into one line instead of fourteen
  -- interruptions of the bar
  if M.tollPending and sib % 4 == 0 then
    M.tollPending = false
    toll()
  end

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
    if boss and part <= 4 then
      if barInPhrase >= 2 then
        note("choir", tones[2] + 12, { volume = g.choir * TRIM.choir * 0.9, pan = -0.25 })
        note("choir", tones[1] + 12, { volume = g.choir * TRIM.choir * 0.8, pan = 0.3 })
      end
    else
      note("choir", tones[2] + 12, { volume = g.choir * TRIM.choir * 0.8, pan = -0.25 })
      -- the fall holds a whole triad rather than a colour tone: it is a cadence,
      -- not a bed
      if boss then
        note("choir", tones[1] + 12, { volume = g.choir * TRIM.choir * 0.72, pan = 0.28 })
        note("choir", tones[3] + 12, { volume = g.choir * TRIM.choir * 0.6, pan = 0.02 })
      end
    end
  end
  -- the theme, at half speed, on the choir: the boss cue's actual argument
  if boss and part <= 4 and live("choir") and sip % 8 == 0 then
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
    -- the finale's four-on-the-floor pedal, but not while the rig is still
    -- landing: part 1 keeps the two-hit heartbeat so part 2 has somewhere to go
    if boss and part >= 2 and part <= 4 and (sib % 4 == 0) then hit = true end
    -- ...and the fall keeps one tonic a bar, under the held chord. A cadence
    -- with a syncopated bass fill in it is not a cadence.
    if boss and part == 5 then hit = (sib == 0) end
    if hit then
      local n = tones[1] - 12
      if sib ~= 0 and rng:chance(0.25) then n = tones[3] - 12 end
      -- the boss climbs chromatically through the last bar of every phrase:
      -- pressure you can hear coming rather than pressure that is simply loud
      if boss and part >= 3 and barInPhrase == 3 then n = n + floor(sib / 4) end
      note("bass", n, { volume = g.bass * TRIM.bass * (sib == 0 and 0.95 or 0.7), pan = 0 })
    end
  end

  ---------------------------------------------------------------- arpeggio
  if live("arp") then
    -- opens from 8ths to 16ths. In the finale that is a part gate, not an
    -- oxygen one: the pedal doubles when the plates come off.
    local every = 4
    if boss then every = (part >= 3) and 2 or 4
    elseif M.o2 > 0.55 then every = 2 end
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
        -- The finale takes the tune away and gives it back. It is gone while the
        -- rig lands and while the crew walks; its strong bones return when the
        -- plates come off; and it is whole again over the open core -- the first
        -- time it has been whole since the daylight. Nothing else in the arc
        -- does as much work as this does.
        if d.theme == "none" then play = false
        elseif d.theme == "strong" and t[4] < 0.86 then play = false end
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
    if boss and part >= 3 and barInPhrase == 3 and sib % 4 == 2 then
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

  -- The finale's one self-driven move. Everything else in the boss cue is told
  -- to it by the game; this is the case where the game has nothing to tell it,
  -- because there is no crew and no procession is coming. See PART1_MAX_WAIT.
  if M.bossPart == 1 then
    M.partT = M.partT + dt
    if M.partT > PART1_MAX_WAIT then Music.bossPart(2) end
  elseif M.bossPart then
    M.partT = M.partT + dt
  end

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
    bossPart = M.bossPart,
    bossPartName = M.bossPart and BOSS_PARTS[M.bossPart].name or nil,
    tollIndex = M.tollIndex, tollsSeen = M.tollsSeen, partT = M.partT,
    playing = M.playing, notes = M.lastNotes, pending = M.pending,
    phraseStep = M.phraseStep, theme = THEME, phrase = PHRASE,
  }
end

Music.theme = THEME
Music.phraseSteps = PHRASE
Music.layerNames = LAYERS
Music.stateNames = { "title", "day", "dusk", "night", "boss", "draft", "ending" }
Music.bossParts = BOSS_PARTS

return Music
