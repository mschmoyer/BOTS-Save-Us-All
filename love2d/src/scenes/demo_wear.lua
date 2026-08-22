-- Wear review scene. A per-instance mark on a machine thirty pixels tall is
-- not judgeable from source and it is not judgeable from an autoplay capture
-- either: nothing in a real run puts a fresh Planter next to a four-night one
-- in the same frame, at a known zoom, twice.
--
-- Three pages, chosen with BOTS_WEAR:
--
--   grid  (default) every type down the page against every shade level across
--         it, plus a scar column, at the zoom the game ships at. This is the
--         loop for the geometry itself.
--   crowd forty machines of mixed age and damage jumbled together on grass at
--         play zoom -- the actual question, which is whether you can pick the
--         veteran out without reading anything.
--   night the same crowd under the night grade and the lighting buffer, which
--         is where a one-pixel mark goes to die.
--
--   BOTS_SCENE=src.scenes.demo_wear tools/shot.sh 8 8 /tmp/wear
--   BOTS_WEAR=crowd BOTS_SCENE=src.scenes.demo_wear tools/shot.sh 8 8 /tmp/wc
--   BOTS_WEAR=night BOTS_SCENE=src.scenes.demo_wear tools/shot.sh 8 8 /tmp/wn
--   BOTS_ZOOM=3 ... -- blow it up, for judging geometry rather than legibility
local U     = require("src.core.util")
local P     = require("src.engine.palette")
local Draw  = require("src.engine.draw")
local Text  = require("src.engine.text")
local Bot   = require("src.entities.bot")
local TU    = require("src.game.tuning")
local Light = require("src.engine.lighting")

local lg = love.graphics
local S = {}

local function envN(k, d) return tonumber(os.getenv(k) or "") or d end

local TYPES = TU.bots.order
local W = TU.bots.wear

--- A bot with a history, standing still. Not a real world: `Bot.new` only needs
--- a table with a cycle on it, and nothing here updates.
local Names = require("src.game.names")

local function make(kind, nights, downs, serial, x, y, trait)
  local b = Bot.new(x, y, kind, { cycle = 1 }, U.rng(serial * 7919 + 13))
  b.serial = serial
  -- the grid page pins the trait, or the personality tint rides on top of the
  -- patina and the column comparison is measuring two things at once
  if trait then b.trait = Names.traits[trait] end
  b.name = string.format("%s-%02d", TU.bots[kind].prefix, serial % 100)
  b.state, b.bootT, b.stateT = "work", 0, 3
  b.log.nights, b.log.downs = nights, downs
  b.age = 12 + serial
  b.bob = (serial % 8) * 0.7
  b.faceY = 1
  b:refreshWear()
  return b
end

function S:enter()
  self.mode = (os.getenv("BOTS_WEAR") or "grid"):lower()
  self.zoom = envN("BOTS_ZOOM", 0)
  self.t = 0
  Bot.plateGain = 0            -- the plates are not the subject on any page
  Light.init(lg.getWidth(), lg.getHeight())
  Light.setQuality(1)
  self.cam = { x = 0, y = 0, zoom = 1, w = 0, h = 0 }

  self.grid, self.crowd = {}, {}
  for r = 1, #TYPES do
    for c = 0, W.fullNights do
      self.grid[#self.grid + 1] = { make(TYPES[r], c, 0, r * 10 + c, 0, 0, 1), r, c, "n" }
    end
    -- the scar columns are fresh machines, so a cut is not read against a tick
    for c = 1, W.scarMax do
      self.grid[#self.grid + 1] =
        { make(TYPES[r], 0, c, r * 40 + c, 0, 0, 1), r, W.fullNights + 1 + c, "s" }
    end
    -- ...and the six traits at zero nights, which is the other axis feeding the
    -- same shade level
    for c = 1, #Names.traits do
      self.grid[#self.grid + 1] =
        { make(TYPES[r], 0, 0, r * 70 + c, 0, 0, c), r, W.fullNights + W.scarMax + 1 + c, "t" }
    end
  end

  -- Forty machines, mixed. Ages are deliberately clumped the way a real crew's
  -- are: a handful of survivors from the first cycles and a lot of new build.
  local rng = U.rng(4242)
  local AGES = { 0, 0, 0, 0, 0, 1, 1, 1, 2, 3, 4, 6 }
  for i = 1, 40 do
    local kind = TYPES[rng:int(1, #TYPES)]
    local nights = AGES[rng:int(1, #AGES)]
    local downs = (nights > 1 and rng:chance(0.45)) and rng:int(1, W.scarMax) or 0
    local b = make(kind, nights, downs, i,
                   140 + (i % 8) * 96 + rng:range(-14, 14),
                   120 + math.floor((i - 1) / 8) * 92 + rng:range(-10, 10))
    self.crowd[#self.crowd + 1] = b
  end
end

function S:update(dt) self.t = self.t + dt end

local TAG = { tracking = 0.24 }
local function tag(str, x, y, size, color, align)
  TAG.color, TAG.align = color or P.inkFaint, align
  Text.display(str, x, y, size or 11, TAG)
  TAG.align = nil
end

------------------------------------------------------------------------- grid
function S:drawGrid()
  local w, h = lg.getDimensions()
  Draw.linearGradient(0, 0, w, h, P.ramp.rock[1], P.black, math.pi * 0.5)
  local cols = W.fullNights + 1 + W.scarMax + #Names.traits
  local x0, y0 = 130, 96
  local cw = math.floor((w - x0 - 40) / cols)
  local ch = math.floor((h - y0 - 30) / #TYPES)
  local z = self.zoom > 0 and self.zoom or TU.camera.zoom

  tag("PER-INSTANCE WEAR", 24, 26, 20, P.ink)
  tag(string.format("zoom %.2f  (ship zoom %.2f)", z, TU.camera.zoom), 24, 52, 11)
  for c = 0, W.fullNights do
    tag(c .. (c == 1 and " NIGHT" or " NIGHTS"), x0 + cw * c + cw * 0.5, 70, 11,
        P.inkDim, "center")
  end
  for c = 1, W.scarMax do
    tag(c .. (c == 1 and " DOWN" or " DOWNS"), x0 + cw * (W.fullNights + c) + cw * 0.5,
        70, 11, P.warn, "center")
  end
  for c = 1, #Names.traits do
    tag(Names.traits[c].label, x0 + cw * (W.fullNights + W.scarMax + c) + cw * 0.5,
        70, 10, P.accentCool, "center")
  end

  for i = 1, #self.grid do
    local e = self.grid[i]
    local b, r, c = e[1], e[2], e[3]
    local cx = x0 + cw * (c - (e[4] ~= "n" and 1 or 0)) + cw * 0.5
    local cy = y0 + ch * (r - 1) + ch * 0.62
    lg.push()
    lg.translate(cx, cy)
    lg.scale(z)
    b.x, b.y = 0, 0
    b:drawShadow()
    b:draw()
    lg.pop()
  end
  for r = 1, #TYPES do
    tag(TU.bots[TYPES[r]].label, 24, y0 + ch * (r - 1) + ch * 0.55, 13, P.ink)
  end
end

----------------------------------------------------------------------- crowd
function S:drawCrowd(night)
  local w, h = lg.getDimensions()
  -- flat sward rather than real terrain: the question is whether a mark
  -- separates from a machine, not whether it separates from grass texture
  Draw.linearGradient(0, 0, w, h, P.ramp.grass[2], P.ramp.grass[1], math.pi * 0.5)
  local z = self.zoom > 0 and self.zoom or TU.camera.zoom

  lg.push()
  lg.scale(z)
  for i = 1, #self.crowd do self.crowd[i]:drawShadow() end
  for i = 1, #self.crowd do self.crowd[i]:draw() end
  lg.pop()

  if night then
    -- The real thing: the scene multiplied by the lighting buffer, which is
    -- what the game does after dusk and the reason a mark that reads in
    -- daylight can still be invisible at the hour it matters. The fake camera
    -- reproduces `lg.scale(z)` with no translation, which is how the crowd
    -- above was drawn.
    self.cam.x, self.cam.y, self.cam.zoom = w / (2 * z), h / (2 * z), z
    self.cam.w, self.cam.h = w, h
    Light.setAmbient(P.tod.night.amb, P.tod.night.strength)
    Light.setLightGain(0.45)
    Light.beginFrame(self.cam)
    for i = 1, #self.crowd do self.crowd[i]:emitLight(Light) end
    Light.finish()
  end

  -- the key: what each machine actually is, so the picture can be marked
  lg.push()
  lg.scale(z)
  for i = 1, #self.crowd do
    local b = self.crowd[i]
    local L = b.log
    Draw.setColor(P.black, 0.5)
    Draw.roundRect("fill", b.x - 14, b.y + b.radius * 1.2, 28, 11, 4)
    tag(L.nights .. "N " .. L.downs .. "D", b.x, b.y + b.radius * 1.2 + 2, 7,
        P.wearMark, "center")
  end
  lg.pop()
  Draw.setColor(P.black, 0.55)
  lg.rectangle("fill", 0, 0, w, 30)
  tag(night and "CROWD, NIGHT -- nN = nights, nD = times downed"
             or "CROWD, DAY -- nN = nights, nD = times downed", 16, 9, 12, P.ink)
end

function S:draw()
  if self.mode == "crowd" then self:drawCrowd(false)
  elseif self.mode == "night" then self:drawCrowd(true)
  else self:drawGrid() end
end

return S
