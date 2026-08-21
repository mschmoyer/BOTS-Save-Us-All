-- Building bots: the bar and the wheel.
--
-- Two ways in, and they are the same six things in the same order, so the
-- muscle memory transfers:
--
--   * the BAR along the bottom -- number keys 1-6, always visible, shows cost,
--     affordability, the recharge wipe after a placement and a red shake on a
--     refusal.
--   * the WHEEL -- hold `radial` (Tab / L1 / touch). Time drops to 0.25x, the
--     wedges bloom outward, the hovered one names itself and explains itself,
--     and a ghost of the bot -- with its actual working radius -- is previewed
--     at the spot in the world where it would land. Release to place.
--
-- The wheel selects by ANGLE, so the mouse, the left stick and the right stick
-- all drive it identically, and a flick is as valid as a careful sweep.
local U      = require("src.core.util")
local P      = require("src.engine.palette")
local Signal = require("src.core.signal")
local Opt    = require("src.core.optional")
local TU     = require("src.game.tuning")
local Input  = require("src.engine.input")
local UI     = require("src.engine.ui")
local Draw   = require("src.engine.draw")
local Text   = require("src.engine.text")
local J      = require("src.engine.juice")
local HUD    = require("src.game.hud")
local Audio  = Opt.require("src.engine.audio")

local lg = love.graphics
local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local cos, sin, pi, atan2 = math.cos, math.sin, math.pi, math.atan2
local TAU = U.TAU

local BuildMenu = {}

local ORDER = TU.bots.order
local N = #ORDER

--------------------------------------------------------------------- state
BuildMenu.world  = nil
BuildMenu.open   = 0          -- 0..1 bloom
BuildMenu.isOpen = false
BuildMenu.sel    = 1
BuildMenu.selAngle = -pi * 0.5
BuildMenu.time   = 0
BuildMenu.barAlpha = 1

local hoverK, denyK, buildK = {}, {}, {}
for i = 1, N do hoverK[i], denyK[i], buildK[i] = 0, 0, 0 end

local BAR = { x = 0, y = 0, w = 0, h = 66, slotW = 92, gap = 6, sw = 0, sh = 0 }

local ITOS = {}
local function itos(n)
  n = floor(n)
  local s = ITOS[n]
  if s == nil then s = tostring(n) if n >= 0 and n < 10000 then ITOS[n] = s end end
  return s
end

local function costOf(def, world)
  local mul = (world and world.chips and world.chips.get) and world.chips:get("botCost", 1) or 1
  return math.ceil(def.cost * mul)
end

--- The radius the bot actually works over, so the ghost tells the truth.
local function fieldRadius(botType, def, world)
  if botType == "repulsor" then return def.radius_pulse end
  if botType == "sentry" then
    return def.range * ((world and world.chips) and world.chips:get("sentryRange", 1) or 1)
  end
  if botType == "beacon" then
    return def.radius_field * ((world and world.chips) and world.chips:get("beaconRadius", 1) or 1)
  end
  if botType == "planter" then return def.minTreeGap * 2.2 end
  if botType == "harvester" then return 190 end
  return 0
end

--------------------------------------------------------------------- setup
local bound = false
function BuildMenu.init(world)
  BuildMenu.world = world
  BuildMenu.open, BuildMenu.isOpen = 0, false
  BuildMenu.sel = 1
  for i = 1, N do hoverK[i], denyK[i], buildK[i] = 0, 0, 0 end
  if bound then return end
  bound = true

  Signal.on("bot:built", function(b)
    for i = 1, N do if ORDER[i] == b.type then buildK[i] = 1 break end end
  end)
  Signal.on("ui:denied", function(reason)
    -- attribute the refusal to whichever slot the player just asked for
    for i = 1, N do
      if Input.down("build" .. i) then denyK[i] = 1 return end
    end
    if BuildMenu.isOpen then denyK[BuildMenu.sel] = 1 end
  end)
end

local function layout()
  local sw, sh = lg.getDimensions()
  if BAR.sw == sw and BAR.sh == sh then return end
  BAR.sw, BAR.sh = sw, sh
  BAR.slotW = (sw < 1180) and 78 or 92
  BAR.h     = (sh < 700) and 58 or 66
  BAR.w = N * BAR.slotW + (N - 1) * BAR.gap
  BAR.x = floor((sw - BAR.w) * 0.5)
  BAR.y = sh - UI.pad - BAR.h
end

--------------------------------------------------------------------- update
--- Where a bot placed right now would land.
function BuildMenu.placement()
  local w = BuildMenu.world
  local p = w and w.player
  if not p then return 0, 0 end
  return p.x + (p.faceX or 1) * 30, p.y + (p.faceY or 0) * 30
end

local function tryBuild(i)
  local w = BuildMenu.world
  if not w or not w.spawnBot then return false end
  local p = w.player
  if not p or p.state ~= "alive" or w.cutscene then
    denyK[i] = 1
    Audio.play("ui_back")
    return false
  end
  local x, y = BuildMenu.placement()
  local ok = w:spawnBot(x, y, ORDER[i])
  if ok then
    buildK[i] = 1
    J.punch(0.006)
  else
    denyK[i] = 1
  end
  return ok and true or false
end
BuildMenu.tryBuild = tryBuild

function BuildMenu.update(dt, cam)
  if dt <= 0 then dt = 1 / 1000 end
  BuildMenu.time = BuildMenu.time + dt
  layout()
  local w = BuildMenu.world
  BuildMenu.camera = cam

  for i = 1, N do
    denyK[i]  = max(0, denyK[i] - dt * 2.6)
    buildK[i] = max(0, buildK[i] - dt * 1.8)
  end

  local want = Input.down("radial") and w and w.player and w.player.state == "alive"
               and not w.cutscene
  if want and not BuildMenu.isOpen then
    BuildMenu.isOpen = true
    BuildMenu.selAngle = -pi * 0.5
    Audio.play("ui_move")
  elseif not want and BuildMenu.isOpen then
    BuildMenu.isOpen = false
    -- release places the hovered bot
    if BuildMenu.open > 0.35 then tryBuild(BuildMenu.sel) end
    J.dilate(1, 0.05)
  end

  BuildMenu.open = U.damp(BuildMenu.open, BuildMenu.isOpen and 1 or 0, 15, dt)
  if BuildMenu.open < 0.002 then BuildMenu.open = 0 end

  if BuildMenu.isOpen then
    J.dilate(0.25, 0.16)

    -- pick by angle: stick first, then mouse, then keep the last choice
    local cx, cy = BuildMenu.centre()
    local ax, ay = 0, 0
    if Input.scheme == "pad" then
      ax, ay = Input.moveX, Input.moveY
      if abs(ax) + abs(ay) < 0.35 and Input.aimIsExplicit then ax, ay = Input.aimX, Input.aimY end
    else
      local mx, my = love.mouse.getPosition()
      local dx, dy = mx - cx, my - cy
      if dx * dx + dy * dy > 26 * 26 then ax, ay = dx, dy end
    end
    if abs(ax) + abs(ay) > 0.3 then
      BuildMenu.selAngle = atan2(ay, ax)
      local step = TAU / N
      local idx = floor(((BuildMenu.selAngle + pi * 0.5 + step * 0.5) % TAU) / step) + 1
      idx = U.clamp(idx, 1, N)
      if idx ~= BuildMenu.sel then
        BuildMenu.sel = idx
        Audio.play("ui_move", { volume = 0.7 })
      end
    end
    -- number keys still work while the wheel is up
    for i = 1, N do
      if Input.pressed("build" .. i) then BuildMenu.sel = i end
    end
  end

  for i = 1, N do
    hoverK[i] = U.damp(hoverK[i], (BuildMenu.isOpen and i == BuildMenu.sel) and 1 or 0, 16, dt)
  end
end

--- Screen-space centre of the wheel: the player, so placement reads as local.
function BuildMenu.centre()
  local cam = BuildMenu.camera
  local w = BuildMenu.world
  local sw, sh = lg.getDimensions()
  if cam and cam.toScreen and w and w.player then
    local x, y = cam:toScreen(w.player.x, w.player.y)
    return U.clamp(x, 220, sw - 220), U.clamp(y, 200, sh - 260)
  end
  return sw * 0.5, sh * 0.5
end

----------------------------------------------------------------------- bar
--- One slot.
---
--- Affordability is the thing this bar has to say from across the room while
--- something is chewing a tree, so it is said three ways at once and none of
--- them is subtle: an affordable slot is lit and has a live accent underline;
--- an unaffordable one goes flat, loses its underline, and its cost is drawn in
--- danger red with a bar showing how much of it you have. Guessing at four
--- shades of grey was never going to work mid-fight.
local function drawSlot(i, x, y, w, h, world, a)
  local id = ORDER[i]
  local def = TU.bots[id]
  local cost = costOf(def, world)
  local have = world and world.cobalt or 0
  local afford = have >= cost
  local progress = cost > 0 and U.saturate(have / cost) or 1
  local deny = U.ease.outQuad(denyK[i])
  local built = buildK[i]
  local hov = hoverK[i]
  local shake = deny > 0 and sin(BuildMenu.time * 52) * deny * 4 or 0
  x = x + shake

  local ka = (afford and 1 or 0.5) * a          -- one dimming factor, used everywhere

  Draw.setColor(UI.c(P.black, ((afford and 0.5 or 0.66) + 0.2 * hov) * a))
  Draw.roundRect("fill", x, y, w, h, UI.r)
  if hov > 0.002 then
    UI.vgrad(x + 1, y + h * 0.4, w - 2, h * 0.6 - 1, P.black, P.accent, 0, 0.14 * hov * a)
  end
  if built > 0.01 then
    UI.vgrad(x + 1, y + 1, w - 2, h - 2, P.accent, P.accent, 0.22 * built * a, 0.02 * built * a)
  end
  lg.setLineWidth(1)
  Draw.setColor(UI.c(deny > 0.02 and P.danger or (afford and P.ink or P.inkFaint),
                     ((afford and 0.16 or 0.08) + 0.3 * hov + 0.5 * deny) * a))
  Draw.roundRect("line", x + 0.5, y + 0.5, w - 1, h - 1, UI.r)

  -- Key chip, top-left -- and only on a keyboard. build1..build6 have no pad
  -- binding, so on a controller these digits were six small lies; the wheel is
  -- the pad's way in and the prompt beside the bar says so.
  if Input.scheme ~= "pad" then
    Draw.setColor(UI.c(P.black, 0.55 * a))
    Draw.roundRect("fill", x + 5, y + 5, 17, 15, 3)
    UI.text(itos(i), x + 13.5, y + 7, UI.ts.micro,
            UI.c(afford and P.ink or P.inkFaint, (afford and 0.9 or 0.5) * a),
            "center", a, 0.04)
  end

  -- silhouette
  HUD.botGlyph(id, x + w * 0.5, y + 27, 13,
               afford and P.ramp.metal[3] or P.inkFaint, (afford and 1 or 0.45) * a)

  -- name
  UI.caption(def.label, x + w * 0.5, y + h - 24, UI.ts.micro,
             UI.c(afford and P.ink or P.inkFaint, (afford and 0.92 or 0.5) * a),
             "center", nil, 1)

  -- Cost, and how close you are to it when you are not there yet. Deliberately
  -- *not* red: six red numerals along the bottom of the screen the moment you
  -- go broke shouts as loudly as taking damage does, and the eye cannot tell
  -- the two apart mid-fight. Red here belongs to the refusal shake alone.
  local costCol = deny > 0.02 and P.danger
                  or (afford and P.ramp.cobalt[4] or P.ramp.cobalt[3])
  local cw = Text.measure(itos(cost), UI.ts.small, nil)
  local cxx = x + w * 0.5 - (cw + 13) * 0.5
  Draw.setColor(UI.c(afford and P.ramp.cobalt[3] or P.inkFaint, (afford and 1 or 0.6) * a))
  Draw.diamond(cxx + 4, y + h - 8, 3.2, 4.2, "fill")
  UI.text(itos(cost), cxx + 12, y + h - 14, UI.ts.small,
          UI.c(costCol, (afford and 1 or 0.7) * a), "left", a, 0.02)

  -- the bottom edge: an accent underline when you can build it, a cobalt
  -- progress sliver when you cannot
  if afford then
    Draw.setColor(UI.c(P.accent, (0.5 + 0.4 * hov) * a))
    Draw.roundRect("fill", x + 8, y + h - 3, w - 16, 2, 1)
  elseif progress > 0.02 then
    Draw.setColor(UI.c(P.ramp.cobalt[2], 0.5 * a))
    Draw.roundRect("fill", x + 8, y + h - 3, w - 16, 2, 1)
    Draw.setColor(UI.c(P.ramp.cobalt[3], 0.8 * a))
    Draw.roundRect("fill", x + 8, y + h - 3, (w - 16) * progress, 2, 1)
  end

  -- recharge wipe after a successful placement
  if built > 0.01 then
    local k = 1 - built
    Draw.setColor(UI.c(P.accent, 0.75 * built * a))
    lg.rectangle("fill", x + 2, y + h - 3, (w - 4) * k, 2)
  end
  return ka
end

function BuildMenu.drawBar(a)
  local world = BuildMenu.world
  a = (a or 1) * BuildMenu.barAlpha * (1 - BuildMenu.open * 0.75) * (BuildMenu.lockFade or 1)
  if a <= 0.01 then return end
  layout()
  for i = 1, N do
    drawSlot(i, BAR.x + (i - 1) * (BAR.slotW + BAR.gap), BAR.y, BAR.slotW, BAR.h, world, a)
  end
  -- The affordance for the wheel sits above the bar's left end rather than
  -- floating beside it on bare ground, where it measured 1.6:1 against a
  -- sunlit canopy no matter what colour it was.
  UI.prompt(BAR.x + 2, BAR.y - 18, "radial", "WHEEL",
            UI.ts.micro, P.ink, 0.8 * a, "left")
end

--------------------------------------------------------------------- ghost
--- The bot, previewed where it would land, at world scale.
local function drawGhost(a)
  local cam = BuildMenu.camera
  local w = BuildMenu.world
  if not cam or not cam.toScreen or not w or not w.player then return end
  local id = ORDER[BuildMenu.sel]
  local def = TU.bots[id]
  local wx, wy = BuildMenu.placement()
  local sx, sy = cam:toScreen(wx, wy)
  local z = cam.zoom or 1
  local pulse = 0.6 + 0.4 * sin(BuildMenu.time * 4)
  local afford = (w.cobalt or 0) >= costOf(def, w)
  local col = afford and P.accent or P.danger

  -- working radius
  local fr = fieldRadius(id, def, w) * z
  if fr > 4 then
    Draw.setColor(UI.c(col, 0.1 * a))
    lg.circle("fill", sx, sy, fr, 48)
    Draw.dashedCircle(sx, sy, fr, 14, 12, BuildMenu.time * 26, 1.5, UI.c(col, 0.4 * a))
  end
  -- footprint
  Draw.softShadow(sx, sy + def.radius * z * 0.5, def.radius * z * 1.5, def.radius * z * 0.6,
                  0.35 * a)
  Draw.dashedCircle(sx, sy, def.radius * z * 1.9, 8, 7, -BuildMenu.time * 34, 2,
                    UI.c(col, (0.55 + 0.3 * pulse) * a))
  -- the bot itself, ghosted
  HUD.botGlyph(id, sx, sy - def.radius * z * 0.4, def.radius * z * 1.1, P.ink, 0.5 * a)
  Draw.glow(sx, sy, def.radius * z * 2.4, col, 0.22 * a * pulse, 2)
end

--------------------------------------------------------------------- wheel
function BuildMenu.drawWheel(a)
  local k = BuildMenu.open
  if k <= 0.004 then return end
  local world = BuildMenu.world
  local e = U.ease.outBack(U.saturate(k))
  local aa = a * U.saturate(k * 1.6)
  local cx, cy = BuildMenu.centre()

  local rIn  = 66 * e
  local rOut = 148 * e
  local step = TAU / N

  drawGhost(aa)

  -- backdrop: a soft dark disc so the wheel reads over any terrain
  Draw.setColor(UI.c(P.black, 0.5 * aa))
  lg.circle("fill", cx, cy, rOut + 26, 64)
  Draw.setColor(UI.c(P.black, 0.28 * aa))
  lg.circle("fill", cx, cy, rOut + 70, 64)

  for i = 1, N do
    local id = ORDER[i]
    local def = TU.bots[id]
    local cost = costOf(def, world)
    local afford = (world and world.cobalt or 0) >= cost
    local hov = hoverK[i]
    local a0 = -pi * 0.5 + (i - 1) * step - step * 0.5 + 0.028
    local a1 = a0 + step - 0.056
    local mid = (a0 + a1) * 0.5
    local push = hov * 12
    local ri, ro = rIn + push * 0.35, rOut + push

    -- wedge body
    local segs = 14
    local col = afford and (hov > 0.02 and P.accent or P.ink) or P.inkFaint
    Draw.setColor(UI.c(col, (0.09 + 0.24 * hov) * aa))
    lg.arc("fill", "pie", cx, cy, ro, a0, a1, segs)
    Draw.setColor(UI.c(P.black, (0.55 + 0.25 * hov) * aa))
    lg.circle("fill", cx, cy, ri, 48)

    -- rim
    Draw.ring(cx, cy, ro - 1, 1 + hov * 2, a0, a1,
              UI.c(afford and P.ink or P.inkFaint, (0.16 + 0.6 * hov) * aa),
              hov > 0.3 and 3 or 0)

    local gx = cx + cos(mid) * (ri + (ro - ri) * 0.44)
    local gy = cy + sin(mid) * (ri + (ro - ri) * 0.44)
    HUD.botGlyph(id, gx, gy, 17 + hov * 3,
                 afford and P.ramp.metal[3] or P.inkFaint, (afford and 1 or 0.4) * aa)

    -- cost, outboard of the glyph
    local kx = cx + cos(mid) * (ro - 17)
    local ky = cy + sin(mid) * (ro - 17)
    UI.text(itos(cost), kx, ky - UI.ts.small * 0.5, UI.ts.small,
            UI.c(afford and P.ramp.cobalt[4] or P.danger, (afford and 1 or 0.6) * aa),
            "center", aa, 0.02)

    -- the same digit the bar shows, inboard: the two ways in teach each other
    if Input.scheme ~= "pad" then
      local nx2 = cx + cos(mid) * (ri + 13)
      local ny2 = cy + sin(mid) * (ri + 13)
      UI.text(itos(i), nx2, ny2 - UI.ts.micro * 0.5, UI.ts.micro,
              UI.c(P.ink, (0.3 + 0.5 * hov) * aa), "center", aa, 0.04)
    end
  end

  -- hub: what you can spend
  Draw.setColor(UI.c(P.black, 0.72 * aa))
  lg.circle("fill", cx, cy, rIn - 6, 48)
  lg.setLineWidth(1)
  Draw.setColor(UI.c(P.ink, 0.14 * aa))
  lg.circle("line", cx, cy, rIn - 6, 48)
  UI.caption("COBALT", cx, cy - 22, UI.ts.micro, UI.c(P.inkFaint, 0.8 * aa), "center")
  UI.text(itos(world and world.cobalt or 0), cx, cy - 8, UI.ts.h3,
          UI.c(P.ramp.cobalt[4], aa), "center", aa, 0.02)

  -- the pointer
  local pa = BuildMenu.selAngle
  Draw.setColor(UI.c(P.accent, 0.8 * aa))
  lg.setLineWidth(2)
  Draw.chevron(cx + cos(pa) * (rIn - 16), cy + sin(pa) * (rIn - 16), 8, pa, 2, 0.8)

  -- the plate: name, cost, and the one line that explains the bot
  if k > 0.2 then
    local id = ORDER[BuildMenu.sel]
    local def = TU.bots[id]
    local pw, ph = 460, 88
    local px = cx - pw * 0.5
    local py = cy + rOut + 30
    local sh = select(2, lg.getDimensions())
    -- The plate has to clear the build bar as well as the bottom of the screen;
    -- the prompt used to be hung underneath it and landed on top of the bar.
    if py + ph > sh - UI.pad - BAR.h - 16 then py = cy - rOut - 30 - ph end
    local pa2 = aa * U.saturate((k - 0.2) / 0.5)
    UI.panel(px, py, pw, ph, 0.72 * pa2, UI.r, P.accent, 0.2 * pa2)
    UI.text(def.label, px + 20, py + 14, UI.ts.h3, UI.c(P.ink, pa2), "left", pa2, 0.1)
    local lw = Text.measure(def.label, UI.ts.h3, nil)
    local cost = costOf(def, BuildMenu.world)
    local afford = (BuildMenu.world and BuildMenu.world.cobalt or 0) >= cost
    Draw.setColor(UI.c(afford and P.ramp.cobalt[3] or P.danger, pa2))
    Draw.diamond(px + 20 + lw + 20, py + 24, 4.5, 6, "fill")
    UI.text(itos(cost), px + 20 + lw + 32, py + 14, UI.ts.h4,
            UI.c(afford and P.ramp.cobalt[4] or P.danger, pa2), "left", pa2, 0.02)
    UI.body(def.desc, px + 21, py + 42, UI.bs.base, UI.c(P.inkDim, 0.92 * pa2), pw - 42)
    if not afford then
      UI.caption("NOT ENOUGH COBALT", px + pw - 20, py + 14, UI.ts.micro,
                 UI.c(P.danger, pa2), "right", nil, 1)
    end
    UI.prompt(px + pw - 20, py + ph - 20, "radial", "RELEASE TO PLACE", UI.ts.micro,
              P.inkDim, 0.85 * pa2, "right")
  end
end

----------------------------------------------------------------------- draw
--- Nothing is built once the rig arrives; the bar fades out rather than
--- offering six purchases the world will refuse.
local lockFade = 1
function BuildMenu.draw(cam)
  local w = BuildMenu.world
  local locked = w and (w.phase == "extraction" or w.phase == "ending")
  lockFade = require("src.core.util").damp(lockFade, locked and 0 or 1, 5,
                                           love.timer.getDelta())
  BuildMenu.lockFade = lockFade
  BuildMenu.camera = cam or BuildMenu.camera
  local prev = lg.getLineWidth()
  BuildMenu.drawBar(1)
  BuildMenu.drawWheel(1)
  lg.setLineWidth(prev)
  lg.setColor(1, 1, 1, 1)
end

return BuildMenu
