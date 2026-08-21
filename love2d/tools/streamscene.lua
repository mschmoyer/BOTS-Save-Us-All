-- Exercises the streaming sound bank without a human: hammers every cue every
-- frame, counts how many triggers came back silent because the cue was not
-- built yet, and reports when the queue drains.
--   BOTS_SCENE=tools.streamscene BOTS_AUDIO_STREAM=1 tools/shot.sh 900 900 /tmp/x
local Audio = require("src.engine.audio")
local S = {}
local frame, miss, hit, doneAt = 0, 0, 0, nil
local names, first = {}, {}

function S:enter()
  names = Audio.names()
  for _, n in ipairs(names) do first[n] = false end
  print(string.format("STREAM,start,jobs=%d,prepared=%s,complete=%s",
    Audio.stats.jobs or -1, tostring(Audio.prepared), tostring(Audio.complete)))
end

function S:update(dt)
  frame = frame + 1
  Audio.update(dt, 0, 0)
  for _, n in ipairs(names) do
    local v = Audio.play(n, { volume = 0.2 })
    if v then hit = hit + 1 first[n] = true else miss = miss + 1 end
  end
  -- and the music bank, by written pitch
  for _, inst in ipairs({ "pad", "bass", "bell", "pluck", "choir" }) do
    Audio.playMusic(inst, (frame % 24) - 6, { volume = 0.2 })
  end
  for _, p in ipairs({ "kick", "hat", "shaker", "tom" }) do
    Audio.playMusic(p, 0, { volume = 0.2 })
  end
  if not doneAt and Audio.complete then
    doneAt = frame
    local unheard = {}
    for _, n in ipairs(names) do if not first[n] then unheard[#unheard + 1] = n end end
    print(string.format("STREAM,drained,frame=%d,variants=%d,bytes=%d,dsp=%.2f",
      frame, Audio.stats.variants, Audio.stats.bytes, Audio.stats.loadTime))
    print(string.format("STREAM,triggers,hit=%d,silent=%d,neverPlayed=%d %s",
      hit, miss, #unheard, table.concat(unheard, " ")))
  end
end

function S:draw()
  if frame > 0 and not doneAt and frame % 120 == 0 then
    print(string.format("STREAM,progress,frame=%d,%.3f,next=%s",
      frame, Audio.streamProgress(), tostring(Audio.streamLabel())))
  end
end
return S
