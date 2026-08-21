local S = {}
function S:enter()
  local Audio = require("src.engine.audio")
  local t = {}
  local tot = 0
  for k, v in pairs(Audio.stats.cost) do t[#t+1] = {k, v}; tot = tot + v end
  table.sort(t, function(a,b) return a[2] > b[2] end)
  for i = 1, #t do print(string.format("COST,%s,%.4f", t[i][1], t[i][2])) end
  print(string.format("COST,TOTAL,%.3f,n=%d,variants=%d,sounds=%d,bytes=%d",
    tot, #t, Audio.stats.variants, Audio.stats.sounds, Audio.stats.bytes))
end
function S:draw() end
return S
