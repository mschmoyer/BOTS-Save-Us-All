local S = {}
function S:enter()
  local Synth = require("src.engine.synth")
  Synth.rate = 22050
  local spec = { dur = 1.0, layers = { { osc = "saw", freq = 220, env = {a=0.01,d=0.3,s=0.5,r=0.4}, amp=0.5 } },
                 fx = { { "svf", type="lp", cutoff=2000, q=0.9 }, { "reverb", mix=0.3 } }, normalize=0.8, trim=false }
  local t0 = love.timer.getTime()
  local bufs = {}
  for i = 1, 30 do bufs[i] = Synth.render(spec) end
  local t1 = love.timer.getTime()
  for i = 1, 30 do bufs[i]:toSoundData() end
  local t2 = love.timer.getTime()
  -- envelope cost
  for i = 1, 30 do bufs[i]:envelope(50) end
  local t3 = love.timer.getTime()
  print(string.format("BENCH render=%.3f toSoundData=%.3f envelope=%.3f  (30 x 1s @22050)", t1-t0, t2-t1, t3-t2))
end
function S:draw() end
return S
