-- Options.
--
-- Every row on this screen moves something real: an audio bus, a post stage, a
-- quality level, an accessibility multiplier. Nothing here is decorative, and
-- nothing is written that `game/settings.lua` will not validate and persist.
--
-- One row is described at a time, in the strip at the foot of the panel, so the
-- list itself stays a list rather than becoming a wall of explanatory text.
--
-- The accent is mint, the same green the shell, the title and the game itself
-- use. It was cobalt: "one accent per screen" followed to the letter, and the
-- result was that Options looked like a different product from the menu that
-- opened it.
--
-- Navigation: up/down moves between rows, left/right adjusts the focused row,
-- and the tab strip is simply the row above the first one -- so a stick, a
-- d-pad, arrow keys and a mouse all reach every control with no special cases.
local U        = require("src.core.util")
local P        = require("src.engine.palette")
local Draw     = require("src.engine.draw")
local Text     = require("src.engine.text")
local UI       = require("src.engine.ui")
local Input    = require("src.engine.input")
local Screen   = require("src.engine.screen")
local Settings = require("src.game.settings")
local Haptics  = require("src.game.haptics")
local J        = require("src.engine.juice")
local Opt      = require("src.core.optional")

local Audio    = Opt.require("src.engine.audio")
local Post     = Opt.require("src.engine.postfx")
local Lighting = Opt.require("src.engine.lighting")
local VFX      = Opt.require("src.engine.vfx")

local lg = love.graphics
local floor, min, max = math.floor, math.min, math.max

local S = {}

--------------------------------------------------------------------- the model
-- kind: slider | toggle | stepper. `key` is the settings key, which is also the
-- widget id -- one name for one thing, everywhere.
local TABS = { "AUDIO", "VISUALS", "ACCESS", "TOUCH" }

local QUALITY_LABEL = { "LOW", "MEDIUM", "HIGH" }
local QUALITY_VALUE = { "low", "medium", "high" }
local SIDE_LABEL    = { "LEFT", "RIGHT" }
local SIDE_VALUE    = { "left", "right" }

local PAGES = {
  { -- AUDIO
    { kind = "slider", key = "volMaster", label = "MASTER",
      desc = "Everything the game makes, at once." },
    { kind = "slider", key = "volMusic", label = "MUSIC",
      desc = "The generative score. It follows the cycle, and the oxygen." },
    { kind = "slider", key = "volSfx", label = "EFFECTS",
      desc = "Planting, shoving, bots booting up, bots going out." },
    { kind = "slider", key = "volAmbience", label = "INTERFACE",
      desc = "Menu clicks, card picks and the dawn tally." },
  },
  { -- VISUALS
    { kind = "toggle", key = "fxBloom", label = "BLOOM",
      desc = "Light bleeds out of bright things. Beacons and bot eyes lose most of their glow without it." },
    { kind = "toggle", key = "fxVignette", label = "VIGNETTE",
      desc = "Darkens the corners of the frame and pulses red when you are hit." },
    { kind = "toggle", key = "fxGrain", label = "FILM GRAIN",
      desc = "A fine moving grain over the whole image." },
    { kind = "toggle", key = "fxAberration", label = "CHROMATIC ABERRATION",
      desc = "Colour separates toward the edge of the lens. Turn it off if it reads as blur." },
    { kind = "toggle", key = "fxDistortion", label = "IMPACT WARP",
      desc = "Pulses and explosions push the image around them. Motion-sensitive players may prefer this off." },
    { kind = "stepper", key = "quality", label = "DETAIL",
      labels = QUALITY_LABEL, values = QUALITY_VALUE,
      desc = "Lighting resolution, particle budget and render scale, together. Drop it if the frame rate is uneven." },
  },
  { -- ACCESS
    { kind = "slider", key = "shakeAmount", label = "SCREEN SHAKE",
      desc = "How far the camera moves on an impact. Zero holds the camera perfectly still." },
    { kind = "slider", key = "flashAmount", label = "SCREEN FLASH",
      desc = "Brightness of hit and milestone flashes. Zero removes every full-screen flash." },
    -- A slider rather than the switch this used to be. Rumble is not one
    -- thing a player either wants or does not: the same intensity that reads
    -- as weight on a wired pad reads as a wasp on a light one, and a player
    -- who turns it off entirely usually only wanted it quieter. Zero is off,
    -- and moving the slider plays a pattern so the level is felt, not guessed.
    { kind = "slider", key = "rumbleAmount", label = "CONTROLLER RUMBLE",
      desc = "How hard the controller is allowed to move. Zero turns every "
          .. "rumble off. It is a designed language, not a constant buzz -- "
          .. "dawn and the extraction are felt, a kill is not." },
  },
  { -- TOUCH
    { kind = "stepper", key = "touchSide", label = "ACTION CLUSTER",
      labels = SIDE_LABEL, values = SIDE_VALUE,
      desc = "Which thumb gets the buttons. The movement stick takes the other side." },
    { kind = "slider", key = "touchScale", label = "CONTROL SIZE",
      min = 0.75, max = 1.4, step = 0.05, percent = false, decimals = 2,
      desc = "Scales every on-screen control to your hands." },
    { kind = "slider", key = "touchOpacity", label = "CONTROL OPACITY",
      min = 0.2, max = 1, step = 0.05,
      desc = "How much of the island the controls are allowed to cover." },
    { kind = "toggle", key = "touchLabels", label = "BUTTON LABELS",
      desc = "Words under the touch glyphs." },
    { kind = "toggle", key = "touchAimAssist", label = "AIM ASSIST",
      desc = "Touch aiming snaps toward the nearest threat." },
  },
}

local MAXROWS = 0
for i = 1, #PAGES do MAXROWS = max(MAXROWS, #PAGES[i]) end

--------------------------------------------------------------------- applying
local QI = { low = 1, medium = 2, high = 3 }
local RENDER_SCALE = { 0.60, 0.80, 1.00 }

--- One knob for the three things that cost frames. `settings.lua` only carries
--- a single `quality` enum, so lighting, particles and render scale move
--- together; see the note at the bottom of this file.
local function applyQuality()
  local i = QI[Settings.get("quality")] or 3
  if Lighting.setQuality then Lighting.setQuality(i - 1) end
  if VFX.setQuality then VFX.setQuality(i - 1) end
  local want = RENDER_SCALE[i]
  if Post.setScale and math.abs((Post.settings.scale or 1) - want) > 0.005 then
    Post.setScale(want)
  end
end

local BUS = { volMaster = "master", volMusic = "music", volSfx = "sfx",
              volAmbience = "ui" }
local POSTKEY = { fxBloom = "bloom", fxAberration = "ca", fxGrain = "grain",
                  fxVignette = "vignette", fxDistortion = "distort" }

local function applyAll()
  for key, bus in pairs(BUS) do
    if Audio.setBusVolume then Audio.setBusVolume(bus, Settings.get(key)) end
  end
  if Post.settings then
    for key, field in pairs(POSTKEY) do Post.settings[field] = Settings.get(key) end
  end
  Settings.applyJuice(J)
  Settings.applyInput(Input)
  Haptics.applySettings()
  applyQuality()
end
S.applyAll = applyAll

--- Applied the moment a row changes, so the player hears and sees the result
--- while the control is still under their thumb.
local function applyOne(key)
  if BUS[key] then
    if Audio.setBusVolume then Audio.setBusVolume(BUS[key], Settings.get(key)) end
  elseif POSTKEY[key] then
    if Post.settings then Post.settings[POSTKEY[key]] = Settings.get(key) end
  elseif key == "quality" then
    applyQuality()
  elseif key == "shakeAmount" or key == "flashAmount" then
    Settings.applyJuice(J)
  elseif key == "rumbleAmount" then
    -- `rumble` (the on/off consent engine/touch.lua also reads) follows the
    -- slider, so zero means off in exactly one place.
    Haptics.setAmount(Settings.get("rumbleAmount"))
    Haptics.preview()
  end
end

--------------------------------------------------------------------- lifecycle
function S:enter(opts)
  -- Registers `rumbleAmount` on the settings schema before anything reads it.
  -- Idempotent, and normally already done by Input.load at boot.
  Haptics.load()
  self.t = 0
  -- BOTS_OPT_TAB lets tools/shot.sh photograph a page other than the first
  self.tab = U.clamp(tonumber(os.getenv("BOTS_OPT_TAB") or "") or 1, 1, #TABS)
  self.ctx = UI.context({ accent = P.accent })
  self.ctx.wrap = false
  self.opts = opts
  self.dirtyFlash = 0
  self.confirmReset = false
  self.panelH = nil
  Settings.load()
  applyAll()
  -- open on a row, not on the tab strip, so the description strip has something
  -- to say the moment the panel lands
  self.ctx.focusId = PAGES[self.tab][1].key
end

function S:leave()
  Settings.saveIfDirty()
end

function S:update(dt, realDt)
  realDt = realDt or dt
  self.t = self.t + realDt
  self.dirtyFlash = max(0, self.dirtyFlash - realDt * 1.6)

  if Screen.current() ~= self then return end
  if Input.pressed("back") or Input.pressed("pause") then
    if self.confirmReset then self.confirmReset = false return end
    Settings.saveIfDirty()
    Screen.pop()
    return
  end
  if self.pendingReset then
    self.pendingReset = false
    Settings.reset()
    applyAll()
    self.dirtyFlash = 1
  end
  self.ctx:beginFrame(realDt)
end

--------------------------------------------------------------------- geometry
-- Vertical rhythm, in grid units: header 14u, tabs 5u, one row 6.5u, the
-- description strip 11u, the footer 9u.
local HEAD_H, TABS_H, ROW_H, ROW_GAP = 112, 40, 44, 8
local DESC_H, FOOT_H, PAD_H = 88, 72, 24

local PANEL = {}
local function layout(rows)
  local w, h = lg.getDimensions()
  local pw = floor(min(880, w - UI.pad * 8) / UI.u) * UI.u
  local full = HEAD_H + TABS_H + rows * (ROW_H + ROW_GAP) + DESC_H + FOOT_H + PAD_H
  full = min(full, h - UI.pad * 4)
  PANEL.pw, PANEL.want = pw, full
  PANEL.px = floor((w - pw) * 0.5 / UI.u) * UI.u
  PANEL.cx = PANEL.px + 32
  PANEL.cw = pw - 64
  PANEL.h = h
  return PANEL
end

function S:resize() PANEL.pw = nil end

--------------------------------------------------------------------- one row
local SOPT = {}
local TOPT = {}

local function drawRow(ctx, row, x, y, w, h)
  local changed = false
  if row.kind == "slider" then
    SOPT.min = row.min or 0
    SOPT.max = row.max or 1
    SOPT.step = row.step or 0.05
    SOPT.percent = row.percent
    SOPT.decimals = row.decimals
    SOPT.labelW = floor(w * 0.34)
    SOPT.notches = row.notches or 4
    local v, ch = UI.slider(ctx, row.key, x, y, w, h, row.label,
                            Settings.get(row.key), SOPT)
    if ch then Settings.set(row.key, v) changed = true end
  elseif row.kind == "toggle" then
    local v, ch = UI.toggle(ctx, row.key, x, y, w, h, row.label,
                            Settings.get(row.key) and true or false, TOPT)
    if ch then Settings.set(row.key, v) changed = true end
  else
    local cur = Settings.get(row.key)
    local idx = 1
    for i = 1, #row.values do if row.values[i] == cur then idx = i break end end
    local ni, ch = UI.stepper(ctx, row.key, x, y, w, h, row.label, idx, row.labels, TOPT)
    if ch then Settings.set(row.key, row.values[ni]) changed = true end
  end
  if changed then applyOne(row.key) end
  return changed
end

--------------------------------------------------------------------- drawing
local PROMPTS = { { "confirm", "TOGGLE" }, { "back", "BACK" } }
local RESET_OPT = { size = UI.ts.small, danger = true }

function S:draw()
  local ctx = self.ctx
  local page = PAGES[self.tab]
  local L = layout(#page)
  local top = (Screen.current() == self)
  local t = self.t
  local a = U.saturate(t * 5)
  local prevLW = lg.getLineWidth()

  -- the panel is exactly as tall as the page it is showing, and resizes with a
  -- damp rather than a jump when the tab changes
  self.panelH = self.panelH and U.damp(self.panelH, L.want, 16, 1 / 60) or L.want
  local ph = self.panelH
  local py0 = floor((L.h - ph) * 0.5)

  UI.scrim(0.78 * a, P.black)
  UI.vignette(0.55 * a)

  -- the panel, rising the last few pixels into place
  local rise = (1 - U.ease.outCubic(U.saturate(t * 3.2))) * 18
  local px, py = L.px, py0 + rise
  UI.panel(px, py, L.pw, ph, 0.80 * a, 10, P.accent, 0.16 * a)
  Draw.setColor(UI.c(P.accent, 0.55 * a))
  Draw.roundRect("fill", px + 8, py + 30, 3, 44, 1.5)

  -- header
  UI.text("OPTIONS", L.cx, py + 32, UI.ts.h2, UI.c(P.ink, a), "left", a, 0.10)
  UI.caption("SAVED AS YOU CHANGE THEM", L.cx + L.cw, py + 36, UI.ts.micro,
             UI.c(P.inkFaint, 0.6 * a), "right")
  -- the device name is information, not an accent: the accent on this screen
  -- means "the thing you are pointing at", and nothing else may borrow it
  -- The active device, and -- only when it is worth saying -- that it has no
  -- motors in it. A player who has turned the rumble slider up and felt
  -- nothing deserves to be told why on the screen they turned it up on.
  local dev = Input.schemeName():upper()
  if Input.scheme == "pad" and Input.rumbleSupported == false then
    dev = dev .. "  /  NO RUMBLE MOTORS"
  end
  UI.caption(dev, L.cx + L.cw, py + 54, UI.ts.micro,
             UI.c(P.inkDim, 0.7 * a), "right")

  -- tabs
  local ti, tch = UI.tabs(ctx, "tab", L.cx, py + HEAD_H - TABS_H, L.cw, TABS_H,
                          TABS, self.tab)
  if tch then self.tab = ti end

  -- rows
  local rowsY = py + HEAD_H + 32
  local focusedRow
  for i = 1, #page do
    local row = page[i]
    drawRow(ctx, row, L.cx, rowsY + (i - 1) * (ROW_H + ROW_GAP), L.cw, ROW_H)
    if ctx.focusId == row.key then focusedRow = row end
  end

  -- the description strip: one row explained, never twenty
  local dy = py + ph - DESC_H - FOOT_H
  UI.rule(L.cx, dy, L.cw, P.ink, 0.10 * a, focusedRow and P.accent or nil)
  if focusedRow then
    UI.caption(focusedRow.label, L.cx, dy + 16, UI.ts.micro,
               UI.c(P.accent, 0.9 * a), "left")
    UI.body(focusedRow.desc, L.cx, dy + 34, UI.bs.base,
            UI.c(P.inkDim, 0.92 * a), L.cw)
  else
    UI.body("Pick a row to see what it does.", L.cx, dy + 34, UI.bs.base,
            UI.c(P.inkFaint, 0.6 * a), L.cw)
  end

  -- footer: prompts left, the one destructive action right
  local fy = py + ph - FOOT_H + 16
  -- promptRow returns its width without the trailing gap, so the next thing on
  -- the baseline has to open its own space or it reads as part of the last
  -- prompt's label ("BACK LEFT / RIGHT ADJUSTS").
  local prow = UI.promptRow(L.cx, fy + 16, PROMPTS, UI.ts.micro, P.inkDim, 0.85 * a, "left")
  local sepX = L.cx + prow + 20
  Draw.setColor(UI.c(P.ink, 0.16 * a))
  lg.setLineWidth(1)
  lg.line(sepX, fy + 9, sepX, fy + 27)
  UI.caption("LEFT / RIGHT ADJUSTS", sepX + 14, fy + 16, UI.ts.micro,
             UI.c(P.inkDim, 0.7 * a), "left")
  local bw = 208
  RESET_OPT.alpha = a
  RESET_OPT.accent = self.confirmReset and P.danger or nil
  if UI.button(ctx, "reset", L.cx + L.cw - bw, fy, bw, 40,
               self.confirmReset and "PRESS AGAIN TO RESTORE" or "RESTORE DEFAULTS",
               RESET_OPT) then
    -- the one destructive control on this screen asks twice, exactly as the
    -- pause menu's two destructive rows already do
    if self.confirmReset then
      self.pendingReset = true
      self.confirmReset = false
    else
      self.confirmReset = true
    end
  end
  if self.dirtyFlash > 0.01 then
    UI.caption("DEFAULTS RESTORED", L.cx + L.cw - bw - 20, fy + 14, UI.ts.micro,
               UI.c(P.warn, self.dirtyFlash * a), "right")
  end

  if self.confirmReset and ctx.focusId ~= "reset" then self.confirmReset = false end

  if top then ctx:endFrame() end
  lg.setLineWidth(prevLW)
  lg.setColor(1, 1, 1, 1)
end

-- NOTE for the settings owner: `quality` is the only render-quality key in the
-- schema, so DETAIL drives lighting, particles and render scale as one. Three
-- separate keys (`qualityLighting`, `qualityVfx`, `renderScale`) would let this
-- screen expose them independently, which the engine already supports.
-- `volAmbience` is likewise being used for the `ui` audio bus; a `volUi` key
-- would name it honestly.

return S
