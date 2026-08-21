-- The ending.
--
-- It gets the real world, with the forest the player actually grew still
-- standing in it, and it does not cut away from that once. Nothing here is a
-- results screen laid over a black rectangle: the tally grows up through the
-- trees that produced it.
--
-- Order of events:
--   quiet    the boss is gone and nothing moves. Longer than is comfortable.
--   gather   every surviving bot walks in and forms a ring around the player.
--   settle   they stand there. Nobody says anything.
--   words    script.ending -- "the world is safe", and the suit comes off.
--   after    silence, held past the point where a game would normally cut.
--   credits  the tally and the names, scrolling up over the forest.
--
-- Every stage can be skipped with `back`; skipping always lands you further
-- down this same list, never on a black screen.
local U        = require("src.core.util")
local P        = require("src.engine.palette")
local Signal   = require("src.core.signal")
local Input    = require("src.engine.input")
local Screen   = require("src.engine.screen")
local Opt      = require("src.core.optional")
local Camera   = require("src.engine.camera")
local TU       = require("src.game.tuning")
local Script   = require("src.game.script")
local Dialogue = require("src.game.dialogue")
local Story    = require("src.game.story")

local Draw     = Opt.require("src.engine.draw")
local Text     = Opt.require("src.engine.text")
local UI       = Opt.require("src.engine.ui")
local VFX      = Opt.require("src.engine.vfx")
local Audio    = Opt.require("src.engine.audio")
local Music    = Opt.require("src.engine.music")
local DayNight = Opt.require("src.engine.daynight")
local Lighting = Opt.require("src.engine.lighting")
local Post     = Opt.require("src.engine.postfx")
local Wind     = Opt.require("src.world.wind")

local lg = love.graphics
local floor, max, min = math.floor, math.max, math.min

local S = {}

------------------------------------------------------------------------ tuning
local T = {
  quiet     = 3.2,
  gatherMax = 7.0,
  settle    = 2.0,
  after     = 2.6,       -- silence after the last word. This is the whole point.
  ringGap   = 40,        -- arc length each bot wants on the circle
  ringMin   = 132,
  ringMax   = 250,
  walk      = 96,
  zoomIn    = 1.72,
  zoomOut   = 0.70,
  scroll    = 46,        -- credits, pixels per second
  barFrac   = 0.105,
}

--------------------------------------------------------------------- the world
--- Freeze the island: no blight, no boss, no orders.
local function hush(world)
  world.phase = "ending"
  world.cutscene = true
  world.boss = nil
  if world.enemies then
    for i = #world.enemies, 1, -1 do
      local e = world.enemies[i]
      e.alive = false
      world.enemies[i] = nil
    end
  end
  if world.projectiles then
    for i = #world.projectiles, 1, -1 do world.projectiles[i] = nil end
  end
end

--- Who is left. Anyone still on the ground gets helped up first.
local function survivors(world)
  local out = {}
  local list = world.bots or {}
  for i = 1, #list do
    local b = list[i]
    if b.alive and b.state ~= "dead" then
      if b.state == "down" then
        b.state = "work"
        b.hp = max(1, floor((b.maxHp or 2) * 0.5))
        b.carried = false
        if VFX.emit then VFX.emit("bot_boot", b.x, b.y, { power = 0.8 }) end
      end
      b.mood = "love"
      out[#out + 1] = b
    end
  end
  return out
end

--- The names the run cost. World keeps them per-cycle, so gather every list.
local function fallenNames(world)
  local names, seen = {}, {}
  local function push(n)
    if n and not seen[n] then seen[n] = true names[#names + 1] = n end
  end
  if world.allLostNames then
    for i = 1, #world.allLostNames do
      local e = world.allLostNames[i]
      push(type(e) == "table" and e.name or e)
    end
  end
  if world.lostNames then
    for i = 1, #world.lostNames do push(world.lostNames[i]) end
  end
  table.sort(names)
  return names
end

------------------------------------------------------------------------- enter
function S:enter(world)
  local w, h = lg.getDimensions()
  self.world = world
  self.t = 0
  self.stage = "quiet"
  self.stageT = 0
  self.bar = 0
  self.scrollY = 0
  self.creditsT = 0
  self.leaving = false
  self.spoke = false

  self.camera = (world and world.camera) or Camera.new(w, h)
  self.camera:resize(w, h)
  if world then world.camera = self.camera end
  if self.camera.setBounds then self.camera:setBounds(0, 0, TU.world.w, TU.world.h) end

  if VFX.init then VFX.init() end
  if Post.init then Post.init(w, h) end
  if Lighting.init then Lighting.init(w, h) end

  if world then
    hush(world)
    self.bots = survivors(world)
    self.fallen = fallenNames(world)
    self.stats = {
      trees   = world.treeCount or 0,
      planted = (world.stats and world.stats.planted) or 0,
      o2      = world.o2 or 0,
      cycles  = math.min(world.cycle or 1, TU.cycle.count),
      built   = (world.stats and world.stats.botsBuilt) or 0,
      rescued = (world.stats and world.stats.rescued) or 0,
    }
    Story.prepare("ending", world)
  else
    self.bots, self.fallen = {}, {}
    self.stats = { trees = 0, planted = 0, o2 = 0, cycles = 0, built = 0, rescued = 0 }
  end

  if Music.setState then Music.setState("ending") end
  if Music.setIntensity then Music.setIntensity(0) end
  -- the sun comes up across the whole ending, and is fully up by the credits
  self.dawnT = 0
  if DayNight.set then DayNight.set("dawn", 0) end

  self:layoutCredits()
end

function S:leave()
  if self.world then self.world.cutscene = false end
end

function S:resize(w, h)
  self.camera:resize(w, h)
  if Post.resize then Post.resize(w, h) end
  if Lighting.resize then Lighting.resize(w, h) end
  self:layoutCredits()
end

---------------------------------------------------------------------- staging
--- Ring positions, assigned by angle so nobody crosses the circle to get home.
function S:assignRing()
  local p = self.world and self.world.player
  if not p then return end
  local n = #self.bots
  if n == 0 then return end
  local r = U.clamp(n * T.ringGap / U.TAU, T.ringMin, T.ringMax)
  local order = {}
  for i = 1, n do
    local b = self.bots[i]
    order[i] = { b = b, a = math.atan2(b.y - p.y, b.x - p.x) }
  end
  table.sort(order, function(a, c) return a.a < c.a end)
  for i = 1, n do
    local a = -math.pi * 0.5 + (i - 1) / n * U.TAU
    local b = order[i].b
    b.ringX = p.x + math.cos(a) * r
    b.ringY = p.y + math.sin(a) * r * 0.78
    b.ringA = a
  end
  self.ringR = r
end

--- Walk the bots to their places. Their own AI is not running; this is us.
function S:stepBots(dt)
  local p = self.world and self.world.player
  if not p then return true end
  local settled = true
  for i = 1, #self.bots do
    local b = self.bots[i]
    b.age = (b.age or 0) + dt
    b.blink = (b.blink or 0) + dt
    if b.ringX then
      local dx, dy = b.ringX - b.x, b.ringY - b.y
      local d = U.len(dx, dy)
      if d > 3 then
        settled = false
        local sp = min(T.walk, d * 3.2)
        local nx, ny = U.norm(dx, dy)
        b.x, b.y = b.x + nx * sp * dt, b.y + ny * sp * dt
        b.vx, b.vy = nx * sp, ny * sp
        if b.setFacing then b:setFacing(nx, ny) end
      else
        b.vx, b.vy = 0, 0
      end
    end
    if b.lookAt then b:lookAt(p.x, p.y) end
  end
  return settled
end

function S:advance(stage)
  self.stage = stage
  self.stageT = 0
  if stage == "gather" then
    self:assignRing()
  elseif stage == "words" then
    self:speak()
  elseif stage == "credits" then
    Dialogue.abort()
    self.scrollY = 0
    if Audio.play then Audio.play("o2_milestone", { volume = 0.5, pitch = 0.8 }) end
  end
end

function S:speak()
  if self.spoke then return end
  self.spoke = true
  local scene = self
  local ctx = Story.prepare("ending", self.world)
  ctx.onSuitOff = function()
    local p = scene.world and scene.world.player
    if p and VFX.emit then VFX.emit("bot_boot", p.x, p.y - 10, { power = 1.4 }) end
    for i = 1, #scene.bots do
      local b = scene.bots[i]
      if VFX.emit then VFX.emit("love_heart", b.x, b.y - 14, { power = 0.6 }) end
    end
  end
  Dialogue.play(Script.ending.steps, {
    world  = self.world,
    cast   = Story.cast,
    ctx    = ctx,
    id     = "ending",
    camera = self.camera,
    replace = true,
    onDone = function() scene:advance("after") end,
  })
end

------------------------------------------------------------------------ update
function S:update(dt, realDt)
  realDt = realDt or dt
  self.t = self.t + realDt
  self.stageT = self.stageT + realDt

  local world = self.world
  if Wind.update then Wind.update(realDt) end
  if VFX.update then VFX.update(realDt) end
  if Music.update then Music.update(realDt) end
  self.dawnT = min(1, (self.dawnT or 0) + realDt / 64)
  if DayNight.set then DayNight.set("dawn", self.dawnT) end
  if Audio.update and world and world.player then
    Audio.update(realDt, world.player.x, world.player.y)
  end

  local stage = self.stage

  -- skip, handled before anything else consumes the press. Skipping always
  -- lands further down the same list; it never lands on a black screen, and it
  -- never skips the turn at the end of the script.
  if Input.pressed("back") or Input.pressed("pause") then
    Input.consume("back") Input.consume("pause")
    if stage == "credits" then
      self:toTitle()
      return
    elseif stage == "words" then
      if Dialogue.isActive() then Dialogue.skip() end
      self:advance("after")
      stage = self.stage
    elseif stage == "after" then
      self:advance("credits")
      stage = self.stage
    else
      self:advance("words")
      stage = self.stage
    end
  end

  local barWant = (stage == "credits") and 0 or 1
  self.bar = U.approach(self.bar, barWant, realDt * (barWant > 0 and 1.5 or 0.9))

  if stage ~= "credits" then self:stepBots(realDt) end
  Story.refresh(world)      -- the helmet comes off mid-scene; the portrait knows

  -- camera: in on the circle, then slowly out over the forest
  local cam = self.camera
  local p = world and world.player
  if cam and p then
    local zoom = T.zoomIn
    if stage == "after" then
      zoom = U.lerp(T.zoomIn, 0.92, U.saturate(self.stageT / T.after))
    elseif stage == "credits" then
      zoom = U.lerp(0.92, T.zoomOut, U.saturate(self.creditsT / 26))
    end
    cam.zoomTarget = zoom
    cam.zoom = U.damp(cam.zoom, cam.zoomTarget, 1.1, realDt)
    cam.x = U.damp(cam.x, p.x, 1.6, realDt)
    cam.y = U.damp(cam.y, p.y - 10, 1.6, realDt)
    if cam.clampToBounds then cam:clampToBounds() end
  end

  if stage == "quiet" then
    if self.stageT > T.quiet then self:advance("gather") end
  elseif stage == "gather" then
    local settled = self:stepBots(0)
    if settled or self.stageT > T.gatherMax then self:advance("settle") end
  elseif stage == "settle" then
    if self.stageT > T.settle then self:advance("words") end
  elseif stage == "words" then
    Dialogue.update(dt, realDt)
    if not Dialogue.isActive() and self.stageT > 0.4 then self:advance("after") end
  elseif stage == "after" then
    if self.stageT > T.after then self:advance("credits") end
  elseif stage == "credits" then
    local fast = Input.down("confirm") and 4 or 1
    self.dawnT = min(1, self.dawnT + realDt * (fast - 1) / 64)
    self.creditsT = self.creditsT + realDt * fast
    self.scrollY = self.scrollY + T.scroll * realDt * fast
    if self.scrollY > self.creditsH + lg.getHeight() * 0.25 then self:toTitle() end
  end

  if stage ~= "words" then Dialogue.update(dt, realDt) end
end

function S:toTitle()
  if self.leaving then return end
  self.leaving = true
  if self.world then self.world.cutscene = false end
  Story.reset()
  Signal.emit("ending:done")
  Screen.transition(1.1, function()
    Screen.switch(require("src.scenes.title"))
  end)
end

--------------------------------------------------------------------- credits
-- Laid out once into a flat list of rows so the scroll is a single offset.
local ROW = { gap = 34, head = 56, line = 30, big = 92 }
local SHADOW = { dx = 0, dy = 2, alpha = 0.65 }
local CRED = {}
local function credOpts()
  for k in pairs(CRED) do CRED[k] = nil end
  CRED.shadow = SHADOW
  return CRED
end

function S:layoutCredits()
  local rows = {}
  local C = Script.credits
  local function push(kind, text, value, size)
    rows[#rows + 1] = { kind = kind, text = text, value = value, size = size,
                        h = size or ROW.line }
  end

  push("space", nil, nil, ROW.big)
  push("title", C.title, nil, 46)
  rows[#rows].h = 68
  push("sub", C.sub, nil, 20)
  rows[#rows].h = ROW.head
  push("space", nil, nil, ROW.head)

  push("head", C.tally, nil, ROW.head)
  local st = self.stats or {}
  for i = 1, #C.rows do
    local r = C.rows[i]
    local v = st[r.key] or 0
    local txt
    if r.key == "o2" then
      txt = Text.format(v, { decimals = 0, suffix = "%" })
    else
      txt = Text.format(v, { comma = true })
    end
    push("stat", r.label, txt, ROW.line)
  end

  push("space", nil, nil, ROW.head)
  push("head", C.fallen, nil, ROW.head)
  local f = self.fallen or {}
  if #f == 0 then
    push("none", C.none, nil, ROW.line)
  else
    for i = 1, #f do push("name", f[i], nil, ROW.line + 4) end
  end

  push("space", nil, nil, ROW.big)
  push("close", C.close, nil, 30)
  push("space", nil, nil, ROW.big)

  local y = 0
  for i = 1, #rows do rows[i].y = y y = y + rows[i].h end
  self.credits = rows
  self.creditsH = y
end

--- A sapling, drawn beside a name. It grows as the line comes up the screen.
local function sapling(x, y, k, alpha)
  if k <= 0.02 then return end
  local hgt = 22 * k
  Draw.setColor(P.shade(P.ramp.bark, 2.6), alpha)
  lg.setLineWidth(1.8)
  lg.line(x, y, x, y - hgt)
  local leaf = min(1, k * 1.4) * 5.4
  Draw.setColor(P.shade(P.ramp.leafHi, 3), alpha * 0.95)
  lg.circle("fill", x - leaf * 0.66, y - hgt + 1.5, leaf)
  lg.circle("fill", x + leaf * 0.70, y - hgt - 3.0, leaf * 0.86)
end

function S:drawCredits()
  local rows = self.credits
  if not rows then return end
  local w, h = lg.getDimensions()
  local cx = floor(w * 0.5)
  local colW = min(520, w - 120)
  local lx = cx - colW * 0.5
  local rx = cx + colW * 0.5
  local top = h - self.scrollY

  -- a scrim, not a curtain: the forest stays visible behind every word
  local k = U.saturate(self.creditsT / 5)
  Draw.setColor(P.black, 0.30 * k)
  lg.rectangle("fill", 0, 0, w, h)
  Draw.radialGradient(cx, h * 0.5, colW * 1.35,
                      P.alpha(P.black, 0.34 * k), P.alpha(P.black, 0), h * 0.72)

  for i = 1, #rows do
    local r = rows[i]
    local y = top + r.y
    if y > -60 and y < h + 60 then
      -- fade in from the bottom edge, out at the top: the words grow and go
      local a = U.saturate((h - y) / 140) * U.saturate((y - 4) / 120)
      if a > 0.004 then
        local kind = r.kind
        if kind == "title" then
          UI.text(r.text, cx, y, 46, P.ink, "center", a, 0.16, credOpts())
        elseif kind == "sub" then
          UI.text(r.text, cx, y, 20, P.accent, "center", a * 0.9, 0.42, credOpts())
        elseif kind == "head" then
          UI.rule(lx, y + 24, colW, P.ink, 0.18 * a, nil)
          UI.text(r.text, cx, y, 13, P.inkDim, "center", a * 0.95, 0.26, credOpts())
        elseif kind == "stat" then
          UI.text(r.text, lx, y + 3, 13, P.inkDim, "left", a * 0.95, 0.2, credOpts())
          UI.text(r.value, rx, y - 2, 20, P.ink, "right", a, 0.04, credOpts())
        elseif kind == "name" then
          local grow = U.saturate((h * 0.80 - y) / 220)
          sapling(lx + 12, y + 20, grow, a)
          UI.text(r.text, lx + 42, y, 19, P.ink, "left", a * 0.95, 0.1, credOpts())
        elseif kind == "none" then
          UI.text(r.text, cx, y, 13, P.accent, "center", a, 0.26, credOpts())
        elseif kind == "close" then
          UI.text(r.text, cx, y, 26, P.accent, "center", a, 0.3, credOpts())
        end
      end
    end
  end
end

-------------------------------------------------------------------------- draw
local function drawBars(amount)
  if amount <= 0.002 then return end
  local w, h = lg.getDimensions()
  local bh = floor(h * T.barFrac) * U.ease.outCubic(amount)
  Draw.setColor(P.black, 0.96)
  lg.rectangle("fill", 0, 0, w, bh)
  lg.rectangle("fill", 0, h - bh, w, bh)
  lg.setColor(1, 1, 1, 1)
end

--- A soft ring of light on the ground where the bots are standing. It is the
--- only thing in the scene that is not diegetic, and it is barely there.
function S:drawCircleGlow()
  if not self.ringR or #self.bots == 0 then return end
  local p = self.world and self.world.player
  if not p then return end
  local k = U.saturate((self.t - T.quiet) / 3)
  if k <= 0.01 then return end
  Draw.setColor(P.love, 0.05 * k)
  lg.ellipse("fill", p.x, p.y + 6, self.ringR * 1.06, self.ringR * 0.84)
  Draw.setColor(P.love, 0.12 * k)
  lg.setLineWidth(1.4)
  lg.ellipse("line", p.x, p.y + 6, self.ringR, self.ringR * 0.78)
  lg.setColor(1, 1, 1, 1)
end

function S:draw()
  local world = self.world
  local cam = self.camera

  if Post.setGrade then
    Post.setGrade(DayNight.skyTint, DayNight.exposure, DayNight.contrast,
                  DayNight.saturation, DayNight.lift)
    Post.setBloom(DayNight.bloom)
    Post.setFog(DayNight.fogColor, DayNight.fogStrength)
  end
  if Post.beginScene then Post.beginScene() end

  lg.clear(P.ramp.water[1])
  if world and world.draw then
    cam:attach()
    self:drawCircleGlow()
    world:draw(cam)
    cam:detach()
  end

  if Lighting.beginFrame and world and world.emitLights then
    Lighting.beginFrame(cam)
    Lighting.setAmbient(DayNight.ambient, DayNight.ambientStrength)
    if Lighting.addSunShadowParams then
      Lighting.addSunShadowParams(DayNight.sunAngle, DayNight.sunLength)
    end
    if Lighting.setLightGain then Lighting.setLightGain(DayNight.lightGain) end
    world:emitLights(Lighting)
    Lighting.finish()
  end

  if Post.endScene then Post.endScene() end
  if Post.render then Post.render() end

  drawBars(self.bar)
  Dialogue.draw()
  if self.stage == "credits" then self:drawCredits() end
  lg.setColor(1, 1, 1, 1)
end

function S:keypressed(k)
  if k == "escape" then return end
end

return S
