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
    layers = { pad = 0.7, bass = 0.75, arp = 0.3, bell = 0.35, perc = 0.25, choir = 0 },
    density = 0.75,
  },
  night = {
    mode = "aeolian", root = 2, bpm = 96, barsPerChord = 1,
    prog = { 1, 6, 7, 5 },
    layers = { pad = 0.55, bass = 0.9, arp = 0.35, bell = 0.3, perc = 0.9, choir = 0 },
    density = 0.95,
  },
  boss = {
    mode = "phrygianDominant", root = 1, bpm = 104, barsPerChord = 1,
    prog = { 1, 1, 2, 1 },
    layers = { pad = 0.5, bass = 1.0, arp = 0.3, bell = 0.2, perc = 1.0, choir = 0.7 },
    density = 1.0,
  },
  draft = {
    mode = "ionian", root = 2, bpm = 60, barsPerChord = 2,
    prog = { 1, 4, 5, 1 },
    layers = { pad = 0.7, bass = 0.25, arp = 0.4, bell = 0.6, perc = 0, choir = 0.15 },
    density = 0.5,
  },
  ending = {
    -- one voice. Nothing under it. This is the whole point of the game.
    mode = "ionian", root = 2, bpm = 52, barsPerChord = 4,
    prog = { 1, 6, 4, 1 },
    layers = { pad = 0, bass = 0, arp = 0, bell = 0.75, perc = 0, choir = 0 },
    density = 0.22,
  },
}

-- How bright the day/dusk material is allowed to be, per cycle. The music
-- forgets how to be hopeful at roughly the rate the player does.
local CYCLE_MODES = { "lydian", "lydian", "ionian", "ionian", "mixolydian", "dorian", "aeolian" }

--------------------------------------------------------------------- state
local M = {
  state = "title", def = STATES.title,
  mode = SCALES.lydian, modeName = "lydian",
  root = 2, bpm = 62, targetBpm = 62,
  intensity = 0, o2 = 0, cycle = 1,
  playing = false,

  clock = 0,          -- seconds since start
  beat = 0,           -- fractional beats
  step = 0,           -- 16th index since start
  bar = 0, beatInBar = 0, stepInBar = 0,
  chordIndex = 1, barsSinceChord = 0,
  gains = {}, targets = {}, fade = 0.25,
  motif = { 1, 3, 5, 3, 6, 5, 3, 2 }, motifPos = 1,
  pending = nil,
  lastNotes = {},
}
Music.M = M

local rng = U.rng(0x5EED)

for _, l in ipairs(LAYERS) do M.gains[l] = 0 M.targets[l] = 0 end

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
  local deg = M.def.prog[M.chordIndex]
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
    M.chordIndex = 1
    M.pending = nil
    M.playing = true
    M.bpm = d.bpm
    M.firstStep = true      -- fire the downbeat now, not a bar from now
  end
  M.fade = (opts.fadeBars or 3) * barSeconds()
  setTargetsFromDef()
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
  local beat = floor(sib / 4)
  local g = M.gains
  local d = M.def
  local dens = d.density or 0.7
  local it = M.intensity
  local tones = chordTones(d.prog[M.chordIndex], (M.state == "boss") and 7 or 9)

  ---------------------------------------------------------------- pad bed
  if g.pad > 0.02 and sib == 0 then
    for i = 1, 3 do
      local pan = (i - 2) * 0.45
      note("pad", tones[i] + 12, { volume = g.pad * (i == 1 and 0.9 or 0.7), pan = pan })
    end
    if M.state == "boss" or M.state == "night" then
      note("pad", tones[1], { volume = g.pad * 0.5, pan = 0 })
    end
  end

  ---------------------------------------------------------------- choir
  if g.choir > 0.02 and sib == 0 then
    note("choir", tones[2] + 12, { volume = g.choir * 0.8, pan = -0.25 })
    if M.state == "boss" then
      note("choir", tones[1], { volume = g.choir * 0.7, pan = 0.3 })
    end
  end

  ---------------------------------------------------------------- bass pulse
  if g.bass > 0.02 then
    local hit = (sib == 0) or (sib == 8)
    if it > 0.35 and sib == 6 then hit = true end
    if it > 0.6 and (sib == 11 or sib == 14) then hit = rng:chance(0.45 + it * 0.3) end
    if M.state == "boss" and (sib % 4 == 0) then hit = true end
    if hit then
      local n = tones[1] - 12
      if sib ~= 0 and rng:chance(0.25) then n = tones[3] - 12 end
      note("bass", n, { volume = g.bass * (sib == 0 and 0.95 or 0.7), pan = 0 })
    end
  end

  ---------------------------------------------------------------- arpeggio
  if g.arp > 0.02 then
    local every = (M.o2 > 0.55) and 2 or 4          -- opens from 8ths to 16ths
    if sib % every == 0 and rng:chance(0.55 + dens * 0.4) then
      local reach = 3 + floor(M.o2 * 4)             -- and reaches further up
      local idx = 1 + (floor(step / every) % reach)
      local semis = M.root + semisOf(d.prog[M.chordIndex] + (idx - 1) * 2) + 12
      note("pluck", semis, {
        volume = g.arp * (0.45 + 0.3 * M.o2) * (sib % 4 == 0 and 1 or 0.72),
        pan = ((step % 5) - 2) * 0.22,
      })
    end
  end

  ---------------------------------------------------------------- melody bell
  if g.bell > 0.02 then
    local slot = (M.state == "ending") and (sib == 0 or sib == 10)
              or (sib == 0 or sib == 6 or sib == 12)
    if slot and rng:chance(dens * 0.75 + 0.15) then
      local deg = M.motif[M.motifPos]
      M.motifPos = M.motifPos % #M.motif + 1
      local semis = M.root + semisOf(d.prog[M.chordIndex] + deg - 1) + 12
      note("bell", semis, {
        volume = g.bell * (sib == 0 and 0.8 or 0.6),
        pan = ((M.motifPos % 3) - 1) * 0.3,
      })
    end
  end

  ---------------------------------------------------------------- percussion
  if g.perc > 0.02 then
    if sib == 0 or sib == 8 or (it > 0.5 and sib == 11 and rng:chance(0.5)) then
      note("kick", 0, { volume = g.perc * 0.9 })
    end
    if sib % 2 == 0 and rng:chance(0.35 + it * 0.55) then
      note("hat", 0, { volume = g.perc * (sib % 4 == 0 and 0.5 or 0.32),
                       pan = rng:range(-0.35, 0.35) })
    end
    if sib % 4 == 2 and rng:chance(0.3 + it * 0.3) then
      note("shaker", 0, { volume = g.perc * 0.3, pan = rng:range(-0.5, 0.5) })
    end
    if sib == 14 and M.bar % 4 == 3 and rng:chance(0.6) then
      note("tom", rng:int(-3, 3), { volume = g.perc * 0.6, pan = -0.3 })
      note("tom", rng:int(-5, 0), { volume = g.perc * 0.5, pan = 0.3 })
    end
  end
end

--- Bar line: advance the progression and apply any pending modal change.
local function barTick()
  M.bar = M.bar + 1
  M.barsSinceChord = M.barsSinceChord + 1
  if M.barsSinceChord >= (M.def.barsPerChord or 1) then
    M.barsSinceChord = 0
    M.chordIndex = M.chordIndex % #M.def.prog + 1
    if M.chordIndex == 1 and M.pending then
      -- land modal changes at the top of the progression: the shift is felt,
      -- not heard as a seam
      M.mode = SCALES[M.pending.mode] or M.mode
      M.modeName = M.pending.mode
      M.root = M.pending.root
      M.pending = nil
      Signal.emit("music:mode", M.modeName)
    end
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
    bpm = M.bpm, bar = M.bar, beat = M.beatInBar + 1, step = M.stepInBar + 1,
    chord = chordName(), chordIndex = M.chordIndex, prog = M.def.prog,
    gains = M.gains, targets = M.targets, layers = LAYERS,
    intensity = M.intensity, o2 = M.o2, cycle = M.cycle,
    playing = M.playing, notes = M.lastNotes, pending = M.pending,
  }
end

Music.layerNames = LAYERS
Music.stateNames = { "title", "day", "dusk", "night", "boss", "draft", "ending" }

return Music
