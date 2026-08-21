-- Prints the load-time budget and exits. `BOTS_SCENE=tools.bootscene`.
-- main.lua already ran, so requiring it returns the Boot table it built.
local S = {}
function S:enter()
  local Boot = package.loaded["main"] or require("main")
  local Tree = require("src.entities.tree")
  local t0 = love.timer.getTime()
  local secs, cells = Tree.prewarm()
  local cnt, verts = Tree.libraryStats()
  print(string.format("BOOT,audioSynth,%.2f", Boot.audioTime or -1))
  print(string.format("BOOT,treePrewarm,%.2f,cells=%d,meshes=%d,verts=%d", secs, cells, cnt, verts))
  print(string.format("BOOT,thisScene,%.2f", love.timer.getTime() - t0))
end
function S:draw() end
return S
