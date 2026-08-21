-- A/B the baked sound bank against the synthesizer that authored it.
--
-- Loads the bank twice in one process -- once from src/bake/audio, once from
-- the specs -- and compares the actual samples. Vorbis is lossy, so equality is
-- the wrong test; what matters is that nothing changed *shape*. Three numbers
-- per cue:
--
--   err   the coding error, RMS(baked - synth) against RMS(synth), in dB.
--         Transparent-ish coding of this palette lands around -30 dB; a cue
--         that reads worse than about -18 dB is worth listening to.
--   env   the largest disagreement between the two 50 Hz RMS envelopes, as a
--         fraction of the cue's peak envelope. This is the one that catches a
--         changed attack, a shifted decay or a pitch that moved -- the coding
--         error can stay small while the sound walks away.
--   len   sample-count difference. Vorbis carries the exact length in its
--         granule position, so anything but zero here is a bug.
--
--   BOTS_SCENE=tools.abaudio BOTS_AUDIO_STREAM=1 tools/shot.sh 1 1 /tmp/x
local S = {}
local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt

local function freshBank(useBake)
  package.loaded["src.engine.audio"] = nil
  package.loaded["src.engine.synth"] = nil
  local A = require("src.engine.audio")
  A.useBake = useBake
  local t = love.timer.getTime()
  A.load()
  return A, love.timer.getTime() - t
end

--- Interleaved sample count, which is what SoundData:getSample indexes.
local function total(sd) return sd:getSampleCount() * sd:getChannelCount() end

--- Everything about one pair in a single pass over the samples.
local function compare(a, b, rate)
  local na, nb = total(a), total(b)
  local n = min(na, nb)
  local win = max(1, floor(rate / 50))
  local sa, sd = 0, 0
  local wa, wb, wn, envMax, envPeak = 0, 0, 0, 0, 0
  for i = 0, n - 1 do
    local x, y = a:getSample(i), b:getSample(i)
    local d = y - x
    sa = sa + x * x
    sd = sd + d * d
    wa = wa + x * x
    wb = wb + y * y
    wn = wn + 1
    if wn == win then
      local ea, eb = sqrt(wa / wn), sqrt(wb / wn)
      envPeak = max(envPeak, ea)
      envMax = max(envMax, abs(ea - eb))
      wa, wb, wn = 0, 0, 0
    end
  end
  local rmsA, rmsD = sqrt(sa / max(1, n)), sqrt(sd / max(1, n))
  local db = (rmsD > 0 and rmsA > 0) and 20 * math.log(rmsD / rmsA) / math.log(10) or -999
  return db, (envPeak > 0 and envMax / envPeak or 0), nb - na, rmsA
end

--- The three looping cues (the rig's intake and core, a feeding Siphon) are
--- spliced by Buf:loopify, so their first and last samples very nearly meet. A
--- transform codec does not have to preserve that, and a step across the seam is
--- a click once a frame of loop -- so it is measured rather than assumed.
local function seam(sd)
  local n = total(sd)
  local peak = 0
  for i = 0, n - 1 do
    local v = abs(sd:getSample(i))
    if v > peak then peak = v end
  end
  return abs(sd:getSample(0) - sd:getSample(n - 1)) / max(1e-6, peak)
end

function S:enter()
  local synth, tSynth = freshBank(false)
  local baked, tBaked = freshBank(true)
  print(string.format("AB load: synth %.3f s, baked %.3f s (%.1fx)",
                      tSynth, tBaked, tSynth / max(0.0001, tBaked)))

  local rows, pairsSeen, silent = {}, 0, 0
  local names = {}
  for name in pairs(synth.sounds) do names[#names + 1] = name end
  table.sort(names)

  for _, name in ipairs(names) do
    local ea, eb = synth.sounds[name], baked.sounds[name]
    if eb then
      local worstDb, worstEnv, lenDiff, quiet = -999, 0, 0, true
      for i = 1, #ea.data do
        local A, B = ea.data[i], eb.data[i]
        if B then
          local db, env, dn, rms = compare(A, B, A:getSampleRate())
          if rms > 1e-6 then quiet = false end
          worstDb = max(worstDb, db)
          worstEnv = max(worstEnv, env)
          if dn ~= 0 then lenDiff = lenDiff + 1 end
          pairsSeen = pairsSeen + 1
        end
      end
      if quiet then silent = silent + 1 end
      rows[#rows + 1] = { name = name, db = worstDb, env = worstEnv, len = lenDiff,
                          n = #ea.data }
    end
  end

  for _, name in ipairs(names) do
    local ea, eb = synth.sounds[name], baked.sounds[name]
    if eb and ea.def and ea.def.loop and ea.data[1] and eb.data[1] then
      print(string.format("AB loop seam %-14s synth %.4f  baked %.4f  (of peak)",
                          name, seam(ea.data[1]), seam(eb.data[1])))
    end
  end

  table.sort(rows, function(x, y) return x.db > y.db end)
  local sum, worstEnv, lens = 0, 0, 0
  for _, r in ipairs(rows) do
    sum = sum + r.db
    worstEnv = max(worstEnv, r.env)
    lens = lens + r.len
  end
  print(string.format("AB %d cues, %d variants compared, %d length mismatches",
                      #rows, pairsSeen, lens))
  print("AB worst 12 cues by coding error:")
  for i = 1, min(12, #rows) do
    local r = rows[i]
    print(string.format("  %-16s err %7.2f dB   env %5.3f   len %d/%d",
                        r.name, r.db, r.env, r.len, r.n))
  end
  print(string.format("AB mean err %.2f dB, worst env delta %.3f, all-silent cues %d",
                      sum / max(1, #rows), worstEnv, silent))
  if love.event then love.event.quit() end
end

function S:draw() end
return S
