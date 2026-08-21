-- Pause.
--
-- The world keeps drawing underneath -- it is pushed back rather than replaced:
-- a heavy scrim, a cool wash, three slow bokeh discs and a vignette, which
-- together read as depth of field without a blur pass.
--
-- The left column is the menu, in the same place and at the same measure as the
-- title's, so pausing feels like stepping back to the cover rather than opening
-- a dialog. The right column is the state of the run, because a paused player
-- is usually pausing to take stock.
local U        = require("src.core.util")
local P        = require("src.engine.palette")
local Draw     = require("src.engine.draw")
local Text     = require("src.engine.text")
local UI       = require("src.engine.ui")
local Input    = require("src.engine.input")
local Screen   = require("src.engine.screen")
local Settings = require("src.game.settings")
local TU       = require("src.game.tuning")
local HUD      = require("src.game.hud")
local Opt      = require("src.core.optional")
local Audio    = Opt.require("src.engine.audio")
local BuildMenu = Opt.require("src.game.buildmenu")

local lg = love.graphics
local floor, min, max = math.floor, math.min, math.max

local S = {}
S.updateWhenCovered = true       -- the bokeh keeps drifting behind Options

local PHASE_LABEL = { day = "DAY", dusk = "DUSK", night = "NIGHT", dawn = "DAWN",
                      extraction = "EXTRACTION", ending = "ENDING" }

local MENU = {
  { id = "resume",  label = "RESUME",         sub = "Back to the island." },
  { id = "options", label = "OPTIONS" },
  { id = "restart", label = "RESTART RUN",    danger = true },
  { id = "quit",    label = "QUIT TO TITLE",  danger = true },
}
local PROMPTS = { { "confirm", "SELECT" }, { "pause", "RESUME" } }
local BOPT = { size = UI.ts.h3 }

--------------------------------------------------------------------- lifecycle
function S:enter(game)
  self.game = game
  self.world = game and game.world
  self.t = 0
  self.confirm = nil
  self.leaving = false
  self.ctx = UI.context({ accent = P.warn })
  self.ctx.focusId = "resume"
  if Audio.play then Audio.play("ui_back", { volume = 0.7 }) end
end

function S:leave()
  HUD.alpha = 1
  BuildMenu.barAlpha = 1
end

local function act(self, id)
  if self.leaving then return end
  if id == "resume" then
    Screen.pop()
  elseif id == "options" then
    Screen.push(require("src.scenes.options"))
  elseif id == "restart" or id == "quit" then
    -- one destructive press is never enough: the row asks again first
    if self.confirm ~= id then
      self.confirm = id
      return
    end
    self.leaving = true
    Settings.saveIfDirty()
    Screen.transition(0.5, function()
      Screen.pop()
      if id == "restart" then
        Screen.switch(require("src.scenes.game"))
      else
        Screen.switch(require("src.scenes.title"))
      end
    end, "iris")
  end
end

function S:update(dt, realDt)
  realDt = realDt or dt
  self.t = self.t + realDt
  -- the instrument panel goes quiet while the game is held
  HUD.alpha = U.damp(HUD.alpha, 0.12, 7, realDt)
  BuildMenu.barAlpha = U.damp(BuildMenu.barAlpha, 0.12, 7, realDt)
  if Screen.current() ~= self then return end

  if self.pending then
    local id = self.pending
    self.pending = nil
    if id ~= self.confirm then self.confirm = nil end
    act(self, id)
    return
  end
  if Input.pressed("pause") or Input.pressed("back") then
    if self.confirm then self.confirm = nil return end
    Screen.pop()
    return
  end
  self.ctx:beginFrame(realDt)
end

--------------------------------------------------------------------- the run
--- The right-hand column: what the run looks like at the moment it was frozen.
local STAT_LABEL = { "FOREST", "OXYGEN", "COBALT" }

function S:drawStatus(x, y, w, a)
  local wd = self.world
  if not wd then return end
  UI.header(x, y, w, "THIS RUN", UI.ts.h4, P.warn, a)

  local cy = y + 44
  UI.caption("CYCLE", x, cy, UI.ts.micro, UI.c(P.inkFaint, 0.85 * a), "left")
  local cw = UI.text(tostring(wd.cycle or 1), x, cy + 16, UI.ts.h1,
                     UI.c(P.ink, a), "left", a, 0.02)
  UI.caption("OF " .. tostring(TU.cycle.count), x + cw + 12, cy + 54, UI.ts.micro,
             UI.c(P.inkDim, 0.8 * a), "left")
  UI.caption(PHASE_LABEL[wd.phase] or "--", x + w, cy + 16, UI.ts.label,
             UI.c(P.warn, 0.9 * a), "right")

  -- the three numbers that describe the island
  local sy = cy + 96
  local cellW = floor(w / 3)
  local vals = {
    tostring(floor(wd.treeCount or 0)),
    Text.format(wd.o2 or 0, { decimals = 1, suffix = "%" }),
    tostring(floor(wd.cobalt or 0)),
  }
  local cols = { P.accent, P.o2, P.ramp.cobalt[4] }
  UI.rule(x, sy - 14, w, P.ink, 0.12 * a)
  for i = 1, 3 do
    UI.stat(x + (i - 1) * cellW, sy, STAT_LABEL[i], vals[i], UI.ts.h3, cols[i],
            "left", a)
  end

  -- workforce, by silhouette
  local ry = sy + 80
  UI.rule(x, ry - 14, w, P.ink, 0.12 * a)
  UI.caption("WORKFORCE", x, ry, UI.ts.micro, UI.c(P.inkFaint, 0.85 * a), "left")
  local order = TU.bots.order
  local n = #order
  local counts, total = self.counts, 0
  if not counts then counts = {} self.counts = counts end
  for i = 1, n do counts[i] = 0 end
  local bots = wd.bots
  if bots then
    for i = 1, #bots do
      local b = bots[i]
      if b.alive and b.state ~= "dead" then
        for k = 1, n do if order[k] == b.type then counts[k] = counts[k] + 1 break end end
      end
    end
  end
  local cellB = floor(w / n)
  for i = 1, n do
    local bx = x + (i - 1) * cellB + cellB * 0.5
    total = total + counts[i]
    local live = counts[i] > 0
    HUD.botGlyph(order[i], bx, ry + 34, 12, live and P.ramp.metal[3] or P.inkFaint,
                 (live and 0.95 or 0.25) * a)
    UI.text(tostring(counts[i]), bx, ry + 50, UI.ts.small,
            UI.c(live and P.ink or P.inkFaint, (live and 1 or 0.3) * a), "center", a, 0.02)
  end
  UI.caption(tostring(total) .. " ONLINE", x + w, ry, UI.ts.micro,
             UI.c(P.accentCool, 0.85 * a), "right")

  -- chips, as a wrapped row of pills
  local chips = wd.chips and wd.chips.list
  local py = ry + 88
  UI.rule(x, py - 14, w, P.ink, 0.12 * a)
  UI.caption("CHIPS", x, py, UI.ts.micro, UI.c(P.inkFaint, 0.85 * a), "left")
  if not chips or #chips == 0 then
    UI.body("No chips yet. The first draft is at dawn.", x, py + 18, UI.bs.small,
            UI.c(P.inkFaint, 0.6 * a), w)
    return
  end
  local cxp, cyp = x, py + 20
  for i = 1, min(#chips, 10) do
    local c = chips[i]
    local tw = UI.captionWidth(c.name, UI.ts.micro) + 20
    if cxp + tw > x + w then cxp = x cyp = cyp + 26 end
    Draw.setColor(UI.c(P.ramp.ember[4], 0.12 * a))
    Draw.roundRect("fill", cxp, cyp, tw, 20, 4)
    lg.setLineWidth(1)
    Draw.setColor(UI.c(P.ramp.ember[4], 0.34 * a))
    Draw.roundRect("line", cxp + 0.5, cyp + 0.5, tw - 1, 19, 4)
    UI.caption(c.name, cxp + tw * 0.5, cyp + 5, UI.ts.micro,
               UI.c(P.ramp.ember[4], 0.95 * a), "center")
    cxp = cxp + tw + 6
  end
end

--------------------------------------------------------------------- drawing
-- `draw`, not `drawOverlay`: Screen runs every scene's draw in stack order and
-- only then every overlay, so an overlay here would end up on top of Options.
function S:draw()
  local w, h = lg.getDimensions()
  local ctx = self.ctx
  local top = (Screen.current() == self)
  local t = self.t
  local a = U.ease.outQuad(U.saturate(t * 4))
  local prevLW = lg.getLineWidth()

  UI.defocus(a, t)
  -- seat both columns, so the world behind them never competes with a numeral
  Draw.softShadow(w * 0.20, h * 0.52, w * 0.26, h * 0.36, 0.5 * a)
  Draw.softShadow(w * 0.83, h * 0.44, w * 0.22, h * 0.30, 0.5 * a)

  local x0 = floor(max(UI.pad * 2, w * 0.065) / UI.u) * UI.u
  local colW = 336
  local headY = floor(h * 0.26 / UI.u) * UI.u

  -- heading
  local hk = UI.stagger(t, 1, 0.02, 0, 0.4, U.ease.outExpo)
  UI.text("PAUSED", x0 + (1 - hk) * -14, headY, UI.ts.h1, UI.c(P.ink, a * hk),
          "left", a * hk, U.lerp(0.30, 0.08, hk))
  UI.caption("THE ISLAND IS HOLDING ITS BREATH", x0, headY + 66, UI.ts.micro,
             UI.c(P.inkFaint, 0.8 * a * hk), "left")
  Draw.setColor(UI.c(P.warn, 0.9 * a * hk))
  lg.setLineWidth(2)
  lg.line(x0, headY + 90, x0 + colW * hk, headY + 90)

  -- menu
  local menuY = headY + 120
  local rowH = 60
  for i = 1, #MENU do
    local m = MENU[i]
    local k = UI.stagger(t, i, 0.10, 0.06, 0.34)
    local label = m.label
    if self.confirm == m.id then label = "CONFIRM " .. m.label end
    BOPT.sub = (self.confirm == m.id) and "This cannot be undone." or m.sub
    BOPT.alpha = k * a
    BOPT.slide = (1 - k) * -18
    BOPT.accent = (self.confirm == m.id) and P.danger
                  or (m.danger and P.ramp.ember[4] or nil)
    local act2 = UI.button(ctx, m.id, x0, menuY + (i - 1) * (rowH + UI.u),
                           colW, rowH, label, BOPT)
    if act2 then self.pending = m.id end
  end

  -- run status, right column
  local sk = UI.stagger(t, 1, 0.26, 0, 0.5)
  local sw = floor(min(420, w * 0.30) / UI.u) * UI.u
  self:drawStatus(w - UI.pad * 3 - sw, headY, sw, a * sk)

  -- footer
  UI.promptRow(x0, h - UI.pad - 26, PROMPTS, UI.ts.micro, P.inkDim, 0.8 * a, "left")

  if top then ctx:endFrame() end
  lg.setLineWidth(prevLW)
  lg.setColor(1, 1, 1, 1)
end

return S
