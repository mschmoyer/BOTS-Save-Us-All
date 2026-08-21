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
--   words    script.ending -- "the world is safe", and the suit comes off. The
--            script takes the dialogue panel away for the silence in the
--            middle of it, so there is nothing on the screen but the ring.
--   after    silence, held past the point where a game would normally cut.
--   credits  the tally and the names, scrolling up over the forest.
--
-- The ring is the image the whole game is for, and by this point the island is
-- eight hundred trees deep, so the canopy x-ray is pointed at the whole circle
-- rather than at the player's shoulders: without it the last shot of the game
-- is a wall of leaves with a letterbox on it.
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
local Tree     = Opt.require("src.entities.tree")

local lg = love.graphics
local floor, max, min = math.floor, math.max, math.min

local S = {}

------------------------------------------------------------------------ tuning
local T = {
  quiet     = 3.2,
  gatherDur = 4.6,       -- everyone arrives together, however far out they were
  settle    = 3.0,       -- they stand there. Nobody says anything.
  after     = 3.4,       -- silence after the last word. This is the whole point.
  ringGap   = 32,        -- arc length each bot wants on the circle
  ringMin   = 132,
  ringMax   = 226,
  gatherFar = 2400,      -- further out than this and it would read as a teleport
  -- Framing is derived from the ring, not fixed: two survivors and forty want
  -- the same picture, and 1.72 on a full-grown island is a close-up of a leaf.
  ringFrame = 405,       -- world half-height the ring should occupy on screen
  openTime  = 3.4,       -- seconds for the canopy over the circle to thin out
  openFade  = 0.16,      -- what a tree standing inside the circle fades to
  openW     = 1.45,      -- the opening, as a multiple of the ring radius
  openH     = 1.25,
  zoomIn    = 1.20,
  zoomMax   = 1.80,
  zoomMin   = 0.88,
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
  -- Nobody updates the world from here on, so anything left in the speech
  -- queue would hang over the ending forever. A bot saying "more sun today"
  -- across the last shot of the game is not a small problem.
  if world.speeches then
    for i = #world.speeches, 1, -1 do world.speeches[i] = nil end
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

--- What the run cost, in the order it cost it.
---
--- This list is NOT sorted. Sorting it alphabetically turns a memorial into an
--- inventory: it groups the dead by model number and throws away the one thing
--- the order carried, which is the shape of the run -- three names from the
--- night everything went wrong, sitting together.
---
--- Every name brings what that bot actually did. Story keeps the epitaphs as
--- they are emitted; world.lua's record is the fallback, and a bare string
--- (which is all the older per-cycle list holds) still lands, just without a
--- line under it.
local function epitaphFor(name, rec)
  local ep = Story.epitaphs and Story.epitaphs[name]
  if ep then return ep end
  if type(rec) ~= "table" then return nil end
  if (rec.planted or 0) > 0 then
    return rec.planted == 1 and "planted one tree"
                             or ("planted " .. rec.planted .. " trees")
  end
  if (rec.built or 0) > 0 then
    return "built " .. rec.built .. (rec.built == 1 and " planter" or " planters")
  end
  -- Bot:epitaph's own fallbacks, so a name is never left bare. A ragged list --
  -- some names with a line under them, some without -- reads as missing data,
  -- and "was here" is not a smaller thing to have done than planting a tree.
  local t = rec.type
  if t == "repulsor"  then return "held the line" end
  if t == "beacon"    then return "kept a light on" end
  if t == "sentry"    then return "stood watch" end
  if t == "harvester" then return "carried what it found" end
  return "was here"
end

local function fallenRecords(world)
  local out, seen = {}, {}
  local function push(rec)
    local name = (type(rec) == "table") and rec.name or rec
    if not name or seen[name] then return end
    seen[name] = true
    out[#out + 1] = { name = name, epitaph = epitaphFor(name, rec) or "was here" }
  end
  if world.allLostNames then
    for i = 1, #world.allLostNames do push(world.allLostNames[i]) end
  end
  if world.lostNames then
    for i = 1, #world.lostNames do push(world.lostNames[i]) end
  end
  -- and the ones that went at the rig, in the order the cohorts left
  if Story.sacrificed then
    for i = 1, #Story.sacrificed do push(Story.sacrificed[i]) end
  end
  return out
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
    self.fallen = fallenRecords(world)
    self.stats = {
      trees   = world.treeCount or 0,
      lost    = (world.stats and world.stats.lost) or 0,
      planted = (world.stats and world.stats.planted) or 0,
      o2      = world.o2 or 0,
      cycles  = math.min(world.cycle or 1, TU.cycle.count),
      built   = (world.stats and world.stats.botsBuilt) or 0,
      rescued = (world.stats and world.stats.rescued) or 0,
      -- what the workforce actually paid for, as a percentage of the hull
      theirs  = world.boss and math.floor(100 * U.saturate(
                  1 - (world.boss.playerDamage or 0) / math.max(1, world.boss.maxHp))) or 0,
    }
    Story.prepare("ending", world)
  else
    self.bots, self.fallen = {}, {}
    self.stats = { trees = 0, lost = 0, planted = 0, o2 = 0, cycles = 0,
                   built = 0, rescued = 0, theirs = 0 }
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

  -- Only the ones close enough that walking in reads as walking in. On a
  -- forested island a Planter can be two thousand pixels away down a beach;
  -- dragging it across the map in four seconds looks like a bug, and leaving
  -- it where it is looks like a bot getting on with its job, which is true.
  local ring = {}
  for i = 1, #self.bots do
    local b = self.bots[i]
    b.ringX, b.ringY = nil, nil
    if U.dist(b.x, b.y, p.x, p.y) <= T.gatherFar then
      ring[#ring + 1] = { b = b, a = math.atan2(b.y - p.y, b.x - p.x) }
    end
  end
  local n = #ring
  if n == 0 then return end

  local r = U.clamp(n * T.ringGap / U.TAU, T.ringMin, T.ringMax)
  table.sort(ring, function(a, c) return a.a < c.a end)
  for i = 1, n do
    local a = -math.pi * 0.5 + (i - 1) / n * U.TAU
    local b = ring[i].b
    b.ringX = p.x + math.cos(a) * r
    b.ringY = p.y + math.sin(a) * r * 0.78
    b.ringA = a
    -- where it set off from, so the walk can be timed rather than paced: they
    -- all get there at the same moment, which is the only version of this
    -- that is a circle rather than an arrival queue
    b.gx, b.gy = b.x, b.y
  end
  self.ringR = r
  self.ringN = n
  -- frame the circle, whatever size it turned out to be
  self.ringZoom = U.clamp(T.ringFrame / (r * 0.78 + 96), T.zoomMin, T.zoomMax)
end

--- Walk the bots to their places. Their own AI is not running; this is us.
--- `k` is 0..1 across the gather, so the ones that started furthest out move
--- fastest and the circle closes all at once.
function S:stepBots(dt, k)
  local p = self.world and self.world.player
  if not p then return true end
  k = k == nil and 1 or U.saturate(k)
  local e = U.ease.inOutCubic and U.ease.inOutCubic(k) or U.ease.outCubic(k)
  for i = 1, #self.bots do
    local b = self.bots[i]
    b.age = (b.age or 0) + dt
    b.blink = (b.blink or 0) + dt
    if b.ringX and b.gx then
      local nx0, ny0 = b.x, b.y
      b.x = U.lerp(b.gx, b.ringX, e)
      b.y = U.lerp(b.gy, b.ringY, e)
      local vx, vy = (b.x - nx0), (b.y - ny0)
      b.vx, b.vy = (dt > 0) and vx / dt or 0, (dt > 0) and vy / dt or 0
      if b.setFacing and (vx ~= 0 or vy ~= 0) then
        local dx, dy = U.norm(vx, vy)
        b:setFacing(dx, dy)
      end
    else
      b.vx, b.vy = 0, 0
    end
    if b.lookAt then b:lookAt(p.x, p.y) end
  end
  return k >= 1
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

--- The world is not running, so the one line a bot says out loud during the
--- silence would otherwise never expire. Age it by hand.
function S:tickSpeech(dt)
  local sp = self.world and self.world.speeches
  if not sp then return end
  for i = #sp, 1, -1 do
    local e = sp[i]
    e.t = e.t + dt
    if e.t >= (e.dur or 3.2) then table.remove(sp, i) end
  end
end

--- Open the canopy over the whole circle, not just over the player's head.
--- World:draw re-points the focus at the player every frame with a 78px
--- radius, but the fade is driven from the update, so this is what wins.
function S:tickCanopy(dt)
  local world = self.world
  local p = world and world.player
  if not (p and world.trees and Tree.setFocus) then return end

  -- The focus is NOT the player. Tree:updateXray only considers canopies that
  -- sort in front of the focus point (`tree.y > focusY`), so pointing it at his
  -- feet leaves every tree between him and the top of the circle fully opaque
  -- -- which is exactly where half the ring is standing. Aim it at the back of
  -- the ring and widen it until the whole ellipse is inside.
  local r = self.ringR or T.ringMin
  Tree.setFocus(p.x, p.y - r * 0.62, r * 1.5)

  -- ...and the x-ray on its own is not enough. It takes a canopy down to 22%,
  -- which is plenty when one tree is in the way and useless when nine are:
  -- by the last cycle the island is eight hundred trees deep and the ring, the
  -- bots and the man himself are all under an unbroken roof. So the roof opens.
  -- Over the first few seconds of the ending, every tree standing inside the
  -- circle thins out and lets the light down, and the forest closes again
  -- behind the camera as it pulls away for the credits. It is the last thing
  -- the forest does for him: it gets out of the way.
  local closing = (self.stage == "credits")
  self.open = U.saturate((self.open or 0) + (closing and -dt / 7.0 or dt / T.openTime))
  local ox, oy = p.x, p.y - r * 0.30
  local rx, ry = r * T.openW, r * T.openH
  local list = world.trees
  for i = 1, #list do
    local t = list[i]
    if t.updateXray then
      if t.visible then t.onScreen = t:visible() end
      t:updateXray(dt)
      local dx = (t.x - ox) / rx
      local dy = (t.y - (t.height or 0) * 0.35 - oy) / ry
      if t.alive and dx * dx + dy * dy < 1 then
        t.fade = U.damp(t.fade or 1, U.lerp(1, T.openFade, self.open), 2.2, dt)
      end
    end
  end
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
  self:tickSpeech(realDt)
  self:tickCanopy(realDt)
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

  if stage ~= "credits" then
    local k = (stage == "gather") and (self.stageT / T.gatherDur) or 1
    self:stepBots(realDt, k)
  end
  Story.refresh(world)      -- the helmet comes off mid-scene; the portrait knows

  -- camera: in on the circle, then slowly out over the forest
  local cam = self.camera
  local p = world and world.player
  if cam and p then
    local held = self.ringZoom or T.zoomIn
    local zoom = held
    if stage == "after" then
      zoom = U.lerp(held, held * 0.78, U.saturate(self.stageT / T.after))
    elseif stage == "credits" then
      zoom = U.lerp(held * 0.78, T.zoomOut, U.saturate(self.creditsT / 26))
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
    if self.stageT >= T.gatherDur then self:advance("settle") end
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
    if r.suffix then
      txt = Text.format(v, { decimals = 0, suffix = r.suffix })
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
    for i = 1, #f do
      local r = f[i]
      -- name over epitaph, not name beside number: a two-line block reads as a
      -- headstone, a label-and-value row reads as a table of results
      push("name", r.name, r.epitaph, ROW.line + 30)
    end
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

  -- A scrim, not a curtain: the forest stays visible behind every word. It was
  -- 0.30 and the words were not readable -- eight hundred sunlit canopies is
  -- the brightest, busiest backdrop in the game, and 13px caption type over it
  -- simply disappears. The fix is a soft column the type sits in, so the
  -- forest stays bright at the edges of the frame and dark under the names.
  local k = U.saturate(self.creditsT / 5)
  Draw.setColor(P.black, 0.34 * k)
  lg.rectangle("fill", 0, 0, w, h)
  local bandW = colW + 150
  local bx = floor(cx - bandW * 0.5)
  local band = 0.50 * k
  Draw.setColor(P.black, band)
  lg.rectangle("fill", bx, 0, bandW, h)
  Draw.linearGradient(bx - 110, 0, 110, h,
                      P.alpha(P.black, 0), P.alpha(P.black, band), 0)
  Draw.linearGradient(bx + bandW, 0, 110, h,
                      P.alpha(P.black, band), P.alpha(P.black, 0), 0)
  Draw.radialGradient(cx, h * 0.5, colW * 1.35,
                      P.alpha(P.black, 0.22 * k), P.alpha(P.black, 0), h * 0.72)

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
          if r.value then
            -- what it did, in the voice it said it in: lowercase, body face,
            -- the same type its speech bubbles were set in
            Text.body(r.value, lx + 42, y + 24, 14,
                      { color = P.inkDim, alpha = a * 0.8 })
          end
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

--- A pool of light on the ground the ring is standing in. It used to be an
--- outlined ellipse drawn under the world, which the trees around the circle
--- chopped into two floating arcs -- it read as a broken UI element, not as
--- light. It is now a soft fill, laid over the scene, and barely there.
function S:drawCircleGlow()
  if not self.ringR or #self.bots == 0 then return end
  local p = self.world and self.world.player
  if not p then return end
  local k = U.saturate((self.t - T.quiet) / 4) * (1 - U.saturate(self.creditsT / 6))
  if k <= 0.01 then return end
  local r = self.ringR
  Draw.radialGradient(p.x, p.y - r * 0.10, r * 1.30,
                      P.alpha(P.love, 0.085 * k), P.alpha(P.love, 0), r * 1.05)
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
    world:draw(cam)
    self:drawCircleGlow()
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
