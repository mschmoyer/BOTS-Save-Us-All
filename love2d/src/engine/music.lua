-- The score: three authored tracks, streamed off disk. Replaces the sequencer,
-- which still exists in src/engine/music_procedural.lua for the demo scenes.
--
--   Music.load()
--   Music.update(dt)
--   Music.setState("title"|"day"|"dusk"|"night"|"boss"|"ending"|"draft", opts)
--   Music.stop(fadeSeconds)
--
-- Seven states, three tracks. Menu and finale states cut between whole tracks;
-- day and night BLEND, mixed every frame from `M.night` (see NIGHTNESS).
--
-- Voices are keyed on the file, not the slot: two slots naming one track share a
-- source, since crossfading a file against itself is two copies beating.
--
-- setIntensity/setO2/setCycle and bossPart/cohort/bossFell are kept because the
-- game calls them and they still bracket the rig drone and emit signals. They no
-- longer shape the music -- a streamed track has no layers to fade.

local U      = require("src.core.util")
local Signal = require("src.core.signal")
local Audio  = require("src.engine.audio")
local T      = require("src.game.tuning").music

local Music = {}

local max, min, floor = math.max, math.min, math.floor
local cos, sin = math.cos, math.sin
local HALF_PI = math.pi * 0.5

--- Which of the three tracks each musical state plays.
local STATE_TRACK = {
  title  = "title",
  day    = "day",
  dusk   = "day",     -- dusk is the day running out, not a new cue
  draft  = "day",
  night  = "night",
  boss   = "night",   -- the extraction happens in the dark and sounds like it
  ending = "title",   -- back to the menu's music: the run is over
}

--- Where each blend state pulls `M.night`. States absent here (menus, finale)
--- are hard cuts and leave the blend frozen where the sky left it.
--- `dusk` targets 1, not `night`: dusk IS the transition, so the score leaves
--- with the light instead of cutting once it is already dark.
local NIGHTNESS = { day = 0, dusk = 1, night = 1, draft = 0 }

local M = {
  state     = nil,
  track     = nil,      -- current slot name
  path      = nil,      -- current file (two slots may share one)
  cycle     = 1,
  intensity = 0,
  o2        = 0,
  bossPart  = nil,
  partT     = 0,
  tollIndex = 0,
  playing   = false,
  night     = 0,        -- 0..1 raw blend position; eased before it is heard
  nightTo   = 0,        -- where the current phase is pulling it
  blending  = false,    -- is the current state on the day/night blend at all
}
Music.M = M

-- path -> { src, level, trim }
local voices = {}
local ready = false

local function safe(fn, ...)
  local ok, a = pcall(fn, ...)
  if ok then return a end
  return nil
end

local function hasAudio()
  return love and love.audio and love.sound and love.filesystem
end

--------------------------------------------------------------------- loading
--- One streaming source per distinct file. Streamed, not static: three minutes
--- decodes to ~34 MB, and none of it needs to sit in memory.
local function voiceFor(path)
  if voices[path] then return voices[path] end
  if not hasAudio() then return nil end
  local info = safe(love.filesystem.getInfo, path)
  if not info then
    print("MUSIC: missing track " .. tostring(path))
    return nil
  end
  local src = safe(love.audio.newSource, path, "stream")
  if not src then
    print("MUSIC: could not open " .. tostring(path))
    return nil
  end
  src:setLooping(true)
  src:setVolume(0)
  voices[path] = { src = src, level = 0, trim = 1 }
  return voices[path]
end

function Music.load()
  if ready then return true end
  ready = true
  for _, path in pairs(T.tracks) do voiceFor(path) end
  for path, v in pairs(voices) do v.trim = Music.trimOf(path) end
  return true
end

--------------------------------------------------------------------- the mix
--- Where each open file wants to sit right now: path -> 0..1.
---
--- In the blend, `M.night` is eased twice: smootherstep, so neither end starts
--- or stops at a corner the ear can find; then equal-power (sin/cos), so the
--- pair sums to constant power. Linear would sag ~3 dB at the midpoint.
-- max, not sum: two slots naming one file still means one track.
local function add(out, slot, w)
  local path = T.tracks[slot]
  if not path or w <= 0 then return end
  if (out[path] or 0) < w then out[path] = w end
end

local function mixInto(out)
  for p in pairs(out) do out[p] = nil end
  if not M.playing then return out end
  if M.blending then
    local n = U.smootherstep(0, 1, M.night)
    add(out, "day",   cos(n * HALF_PI))
    add(out, "night", sin(n * HALF_PI))
  else
    add(out, STATE_TRACK[M.state] or "title", 1)
  end
  return out
end

local mix = {}

--- Trim for a file. Reachable from several slots; take the loudest.
function Music.trimOf(path)
  local g = nil
  for slot, p in pairs(T.tracks) do
    if p == path then
      local t = (T.gain and T.gain[slot]) or 1
      if g == nil or t > g then g = t end
    end
  end
  return g or 1
end

--------------------------------------------------------------------- controls
--- Switch musical state. In the blend this only moves the target, and the sound
--- takes a dusk to follow; outside it, it crossfades between files.
function Music.setState(name, opts)
  local slot = STATE_TRACK[name]
  if not slot then return end
  if not ready then Music.load() end
  opts = opts or {}

  local wasBlending = M.blending
  M.state = name
  M.track = slot
  if opts.cycle then M.cycle = U.clamp(floor(opts.cycle), 1, 7) end

  -- Brackets the rig's drone (see engine/audio): however the run ends, a looping
  -- source cannot outlive the fight. Why the finale still routes through here.
  if name == "boss" then
    M.bossPart = M.bossPart or 1
    M.partT = 0
    M.tollIndex = 0
    if Audio.rigOpen then Audio.rigOpen() end
  else
    M.bossPart = nil
    if Audio.rigStop then Audio.rigStop(true) end
  end

  local target = NIGHTNESS[name]
  M.blending = target ~= nil
  if M.blending then
    M.nightTo = opts.night or target
    -- Arriving from outside (title, a reload) there is nothing to ease across.
    if not wasBlending then M.night = M.nightTo end
  end

  M.playing = true
  M.path = T.tracks[slot]
  Signal.emit("music:state", name)
end

--- Threat, 0..1. Recorded for the debug view; a streamed track does not react.
function Music.setIntensity(v) M.intensity = U.saturate(v or 0) end

--- Forest recovery, 0..1. Recorded, not acted on.
function Music.setO2(v) M.o2 = U.saturate(v or 0) end

function Music.setCycle(c) M.cycle = U.clamp(floor(c or 1), 1, 7) end

--- Take the whole score down. `fade` overrides the ramp for this one call.
function Music.stop(fade)
  M.stopFade = fade or T.stopFade
  M.playing = false
  M.blending = false
  M.state, M.track, M.path = nil, nil, nil
end

function Music.isPlaying() return M.playing end

---------------------------------------------------------------- the finale
--- Advance the extraction cue. The music no longer changes shape with the part,
--- but other systems read it, so it is tracked and announced.
function Music.bossPart(n)
  n = U.clamp(floor(n or 1), 1, 5)
  if M.state ~= "boss" then Music.setState("boss") end
  if M.bossPart == n then return end
  M.bossPart = n
  M.partT = 0
  Signal.emit("music:bossPart", n)
end

function Music.bossPartIndex() return M.bossPart or 0 end

--- A wave of the workforce has left for the rig.
function Music.cohort(index)
  if M.state ~= "boss" then return end
  M.tollIndex = floor(index or (M.tollIndex + 1))
  if (M.bossPart or 1) < 2 then Music.bossPart(2) end
end

--- The rig is down.
function Music.bossFell()
  if M.state ~= "boss" then return end
  M.bossPart = 5
  M.partT = 0
  Signal.emit("music:bossPart", 5)
end

--- Optional one-line wiring for the finale. Nothing is bound until it is called:
--- requiring this module must never change what the game sounds like.
function Music.bindSignals(owner)
  owner = owner or Music
  Signal.clearOwner(owner)
  Signal.on("phase:extraction", function() Music.setState("boss") end, owner)
  Signal.on("bots:cohort",      function() Music.cohort() end, owner)
  Signal.on("boss:phase",       function(n) Music.bossPart((n or 2) + 1) end, owner)
  Signal.on("boss:died",        function() Music.bossFell() end, owner)
  return owner
end

--------------------------------------------------------------------- update
--- Advance the blend and push the bus onto the sources. The bus is applied every
--- frame, not on change: the slider moves it, impacts duck it, dialogue holds it
--- down, and a streamed source has no Audio voice to do that through.
function Music.update(dt)
  dt = min(max(dt or 0, 0), 1 / 15)
  local bus = Audio.busGain and Audio.busGain("music") or 1

  -- A fixed rate, not a fraction of the phase: dawn has no length (it waits on
  -- the draft), so a fade driven off its progress would stall then snap.
  if M.night ~= M.nightTo then
    local dur = (M.nightTo > M.night) and T.dayToNight or T.nightToDay
    local step = dt / max(0.01, dur)
    if M.nightTo > M.night then M.night = min(M.nightTo, M.night + step)
    else                        M.night = max(M.nightTo, M.night - step) end
  end

  mixInto(mix)

  for path, v in pairs(voices) do
    local target = mix[path] or 0
    -- Inert during the blend, which moves far slower than this cap. This is for
    -- the hard cuts: title, finale, Music.stop().
    if v.level ~= target then
      local out = M.playing and T.fadeOut or (M.stopFade or T.stopFade)
      local step = dt / max(0.01, target > v.level and T.fadeIn or out)
      if target > v.level then v.level = min(target, v.level + step)
      else                     v.level = max(target, v.level - step) end
    end
    if v.src then
      if v.level <= 0 then
        if v.src:isPlaying() then v.src:pause() end
      else
        v.src:setVolume(v.level * v.trim * bus)
        -- Wanted but not playing means it faded fully out: restart from the top.
        -- One caught mid-fade never stopped, so it resumes where it was.
        if not v.src:isPlaying() then
          v.src:seek(0)
          safe(v.src.play, v.src)
        end
      end
    end
  end

  if M.bossPart then M.partT = M.partT + dt end
end

--------------------------------------------------------------------- debug
function Music.debug()
  local levels = {}
  for p, v in pairs(voices) do levels[p] = v.level end
  return {
    state = M.state, track = M.track, path = M.path,
    playing = M.playing, levels = levels,
    night = M.night, nightTo = M.nightTo, blending = M.blending,
    intensity = M.intensity, o2 = M.o2, cycle = M.cycle,
    bossPart = M.bossPart, partT = M.partT, tollIndex = M.tollIndex,
  }
end

Music.stateNames = { "title", "day", "dusk", "night", "boss", "draft", "ending" }
Music.trackNames = { "title", "day", "night" }
Music.stateTrack = STATE_TRACK

return Music
