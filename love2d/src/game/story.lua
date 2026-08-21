-- The beat director, and the tutorial.
--
-- Two jobs, and they are deliberately in the same file because they are the
-- same job at two volumes:
--
--   BEATS     the eight cutscenes in game/script.lua. Each one is armed by a
--             signal, waits for a moment that will not ruin it, fires once,
--             and never fires again.
--   TUTORIAL  a chain of small, world-anchored, non-blocking hints. Each one
--             appears when the player is standing in front of the thing it is
--             about, and dismisses itself the instant they do it. No modals,
--             no walls of text, nothing that has to be acknowledged.
--
-- Plus a third, quieter thing: REACTIONS. When something happens that the bots
-- would have an opinion about, the nearest bot says one lowercase sentence in
-- its own speech bubble. It costs nothing and it is most of why they read as
-- people.
--
-- Rules:
--   * a beat never interrupts another beat
--   * a beat never fires while the player is being killed
--   * a beat that has waited past its patience is dropped, not queued forever
--   * skipping is Dialogue's problem, and Dialogue always clears world.cutscene
local U        = require("src.core.util")
local P        = require("src.engine.palette")
local Signal   = require("src.core.signal")
local Input    = require("src.engine.input")
local Opt      = require("src.core.optional")
local Script   = require("src.game.script")
local Dialogue = require("src.game.dialogue")

local Draw = Opt.require("src.engine.draw")
local Text = Opt.require("src.engine.text")
local UI   = Opt.require("src.engine.ui")

local lg = love.graphics
local floor, max, min = math.floor, math.max, math.min

local Story = {}

------------------------------------------------------------------------ tuning
local T = {
  beatGap     = 6.0,     -- quiet seconds between two cutscenes
  calmRadius  = 620,     -- no blight this close for a "calm" beat
  fightRadius = 300,     -- ...or this close for a "fight" beat
  hintMax     = 14.0,    -- a hint gives up after this long and stops nagging
  hintGap     = 1.1,
  hintRepeats = 2,       -- a hint may come back once if it went unanswered
  reactGap    = 5.5,
}
Story.tuning = T

------------------------------------------------------------------------- cast
-- Dialogue resolves `who` through this table. botA / botB are re-pointed at
-- real, living bots before every beat, so the name on the plate is a name the
-- player has seen in the world -- and the eye colour is read live, which is
-- why the bots' eyes go amber-confused during the extraction beat.
Story.cast = {
  human = {
    name = "MECHANIC",
    voice = "ui_move", pitch = 1,
    portrait = { kind = "human", suit = true, seed = 0, look = 0 },
  },
  botA = {
    name = "SEED-01", voice = "bot_chatter", pitch = 1.05,
    portrait = { kind = "bot", botType = "planter", eye = P.eye, seed = 3, look = 0 },
  },
  botB = {
    name = "FRAME-01", voice = "bot_chatter", pitch = 0.92,
    portrait = { kind = "bot", botType = "builder", eye = P.eye, seed = 9, look = 0 },
  },
}

local bound = { botA = nil, botB = nil }

local function bind(key, bot)
  local c = Story.cast[key]
  if not bot then return c end
  bound[key] = bot
  c.name = bot.name or c.name
  c.portrait.botType = bot.type or c.portrait.botType
  c.portrait.seed = ((bot.serial or 1) * 7) % 23
  c.pitch = 0.90 + ((bot.serial or 1) % 7) * 0.035
  return c
end
Story.bind = bind

--- Keep the portraits honest: a bot's eye colour is its mood, and the human
--- loses the helmet the moment the ending script takes it off him.
local function refreshCast(world)
  for key, bot in pairs(bound) do
    local c = Story.cast[key]
    if bot and bot.eyeColor and bot.alive then c.portrait.eye = bot:eyeColor() end
  end
  local p = world and world.player
  if p ~= nil and p.suit ~= nil then Story.cast.human.portrait.suit = p.suit end
end

--- Public: the ending scene stages its own sequence and still needs the
--- portraits to track the world (the helmet comes off mid-line).
function Story.refresh(world) refreshCast(world or Story.world) end

---------------------------------------------------------------------- helpers
local function livingBots(world)
  return world and world.bots or nil
end

--- Nearest living, upright bot to a point. `skip` excludes one.
local function pickBot(world, x, y, skip, filter)
  local list = livingBots(world)
  if not list then return nil end
  local best, bestD
  for i = 1, #list do
    local b = list[i]
    if b.alive and b.state ~= "dead" and b.state ~= "down" and b ~= skip
       and (not filter or filter(b)) then
      local d = (x and U.dist2(b.x, b.y, x, y)) or i
      if not bestD or d < bestD then best, bestD = b, d end
    end
  end
  return best
end

local function blightNear(world, r)
  local p = world and world.player
  if not p then return 0 end
  local n = 0
  if world.hEnemy and world.hEnemy.each then
    world.hEnemy:each(p.x, p.y, r, function(e)
      if e.alive and not e.fleeing and U.dist2(e.x, e.y, p.x, p.y) <= r * r then n = n + 1 end
    end)
  elseif world.enemies then
    for i = 1, #world.enemies do
      local e = world.enemies[i]
      if e.alive and not e.fleeing and U.dist2(e.x, e.y, p.x, p.y) <= r * r then n = n + 1 end
    end
  end
  return n
end

--- Is this a moment a cutscene can have?
local function guardOk(kind, world)
  local p = world and world.player
  if not p then return false end
  if p.state and p.state ~= "alive" then return false end
  if kind == "now" then return true end
  local hp = p.hp or 3
  if kind == "fight" then
    return hp >= 2 and blightNear(world, T.fightRadius) <= 3
  end
  -- calm: daylight, nothing hunting you, and not mid-rescue
  if world.phase == "night" or world.phase == "dusk" then return false end
  if world.phase == "extraction" or world.phase == "ending" then return false end
  if hp < 2 then return false end
  if p.carrying then return false end
  return blightNear(world, T.calmRadius) == 0
end

------------------------------------------------------------------------ beats
-- pri 3 beats are load-bearing plot and are allowed to shoulder in.
-- `patience` is how long a beat will wait for its moment before it is dropped.
local BEATS = {
  {
    id = "prologue", pri = 3, guard = "now", delay = 0.9,
    prep = function(world, ctx)
      bind("botA", nil)
      return true
    end,
  },
  {
    id = "firstBot", pri = 2, guard = "calm", delay = 1.4, patience = 200,
    prep = function(world, ctx)
      local b = ctx.bot
      if not (b and b.alive and b.state ~= "dead") then b = pickBot(world, world.player and world.player.x, world.player and world.player.y) end
      if not b then return false end
      ctx.bot = b
      bind("botA", b)
      return true
    end,
  },
  {
    id = "firstAttack", pri = 3, guard = "fight", delay = 0.25,
    prep = function(world, ctx)
      local e = ctx.enemy
      if not (e and e.alive) then return false end
      bind("botA", pickBot(world, e.x, e.y))
      return true
    end,
  },
  {
    id = "firstLoss", pri = 2, guard = "calm", delay = 2.2, patience = 300,
    prep = function(world, ctx)
      -- somebody has to be left to ask the question
      local b = pickBot(world, ctx.lostX, ctx.lostY)
      if not b then return false end
      ctx.bot = b
      bind("botB", b)
      return true
    end,
  },
  {
    id = "question", pri = 1, guard = "calm", delay = 4.0, patience = 420,
    prep = function(world, ctx)
      local p = world.player
      local b = pickBot(world, p and p.x, p and p.y, nil,
                        function(bb) return bb.type == "planter" end)
             or pickBot(world, p and p.x, p and p.y)
      if not b then return false end
      ctx.bot = b
      bind("botA", b)
      return true
    end,
  },
  {
    -- The rig is on the ground and the bots have stopped working: this has to
    -- play promptly or not at all. If the player was mid-reboot when it landed
    -- it waits for them to get up, and gives up rather than talking over the
    -- rebellion.
    id = "extraction", pri = 3, guard = "now", delay = 1.6, patience = 26,
    prep = function(world, ctx)
      ctx.boss = ctx.boss or world.boss
      local a = pickBot(world, ctx.boss and ctx.boss.x, ctx.boss and ctx.boss.y)
      bind("botA", a)
      bind("botB", pickBot(world, world.player and world.player.x, world.player and world.player.y, a))
      return true
    end,
  },
  {
    -- Never before the scene that introduced the thing they are charging.
    id = "rebellion", pri = 3, guard = "now", delay = 0.4,
    require = function() return Story.fired.extraction or not Story.armed.extraction end,
    prep = function(world, ctx)
      local p = world.player
      local a = ctx.bot
      if not (a and a.alive) then a = pickBot(world, p and p.x, p and p.y) end
      ctx.bot = a
      bind("botA", a)
      bind("botB", pickBot(world, p and p.x, p and p.y, a))
      return true
    end,
  },
  {
    id = "ending", pri = 3, guard = "now", delay = 0,
    -- fired by scenes/ending.lua, which owns the staging around it
    prep = function(world, ctx)
      local p = world.player
      local a = pickBot(world, p and p.x, p and p.y)
      local b = pickBot(world, p and p.x, p and p.y, a)
      bind("botA", a)
      bind("botB", b)
      ctx.bot, ctx.bot2 = a, b
      return true
    end,
  },
}

local BEAT_BY_ID = {}
for i = 1, #BEATS do BEAT_BY_ID[BEATS[i].id] = BEATS[i] end
Story.beats = BEAT_BY_ID

--------------------------------------------------------------------- tutorial
-- Every step: when it arms, what counts as doing it, and what it points at.
local function playerOf(w) return w and w.player end

local TUT = {
  {
    -- not gated on the prologue flag: the prologue can be skipped, and a
    -- skipped prologue must not cost the player the only hint that teaches
    -- them the game has started
    id = "move",
    arm  = function(w) return (Story.time or 0) > 1.4 end,
    done = function(w) return (Story.moved or 0) > 260 end,
    anchor = playerOf,
    color = P.accent,
  },
  {
    id = "cobalt",
    arm  = function(w)
      local p = w.player
      return p and w.nearestCobalt and w:nearestCobalt(p.x, p.y, 900) ~= nil
    end,
    done = function(w) return Story.did.cobalt == true end,
    anchor = function(w)
      local p = w.player
      return p and w.nearestCobalt and w:nearestCobalt(p.x, p.y, 1400) or p
    end,
    color = P.ramp.cobalt[3],
  },
  {
    id = "planter",
    arm  = function(w) return (w.cobalt or 0) >= 10 and Story.did.cobalt == true end,
    done = function(w) return Story.did.build == true end,
    anchor = playerOf,
    color = P.accent,
  },
  {
    -- Dusk offers a trade with no UI attached to it anywhere else in the game:
    -- half a minute more daylight for a heavier night. A player who is never
    -- told cannot make the decision, and it is one of the two decisions in the
    -- run. It arms only while the offer is live, so it can never nag.
    id = "hold",
    arm  = function(w) return w.canHoldDawn ~= nil and w:canHoldDawn() == true end,
    done = function(w) return w.heldThisCycle == true end,
    anchor = playerOf,
    color = P.warn,
    maxT = 11.0,
  },
  {
    id = "shove",
    arm  = function(w)
      local p = w.player
      return p and w.nearestEnemy and w:nearestEnemy(p.x, p.y, 380) ~= nil
    end,
    done = function(w) return Story.did.shove == true end,
    anchor = function(w)
      local p = w.player
      return p and w.nearestEnemy and w:nearestEnemy(p.x, p.y, 520) or p
    end,
    color = P.warn,
  },
  {
    id = "dash",
    arm  = function(w)
      if Story.did.shove ~= true then return false end
      local p = w.player
      return p and w.nearestEnemy and w:nearestEnemy(p.x, p.y, 260) ~= nil
    end,
    done = function(w) return Story.did.dash == true end,
    anchor = playerOf,
    color = P.warn,
  },
  {
    id = "rescue",
    arm  = function(w)
      local p = w.player
      return p and w.nearestDownedBot and w:nearestDownedBot(p.x, p.y, 1400) ~= nil
    end,
    done = function(w) return Story.did.carry == true end,
    anchor = function(w)
      local p = w.player
      return p and w.nearestDownedBot and w:nearestDownedBot(p.x, p.y, 1600) or p
    end,
    color = P.love,
  },
}

local TUT_BY_ID = {}
for i = 1, #TUT do
  local s = TUT[i]
  for j = 1, #Script.tutorial do
    if Script.tutorial[j].id == s.id then s.copy = Script.tutorial[j] end
  end
  s.maxT = s.maxT or T.hintMax
  TUT_BY_ID[s.id] = s
end
Story.tutorialSteps = TUT

--------------------------------------------------------------------- reactions
-- One bot, one lowercase sentence, in the world. Never during a cutscene.
local function react(phase, x, y)
  local w = Story.world
  if not w or w.cutscene or Dialogue.isActive() then return end
  if Story.reactT > 0 then return end
  local p = w.player
  local b = pickBot(w, x or (p and p.x), y or (p and p.y))
  if not b or not b.say then return end
  b:say(phase)
  Story.reactT = T.reactGap
end
Story.react = react

------------------------------------------------------------------------- state
local function resetState()
  Story.world    = nil
  Story.pending  = {}
  Story.fired    = {}
  Story.armed    = {}
  Story.cooldown = 0
  Story.reactT   = 0
  Story.time     = 0
  Story.moved    = 0
  Story.lastX, Story.lastY = nil, nil
  Story.did      = {}
  Story.epitaphs = {}
  Story.sacrificed = {}
  Story.watch    = nil
  Story.tut      = { active = nil, a = 0, t = 0, gap = 1.5, fading = false,
                     shown = {}, doneIds = {} }
end
resetState()

function Story.reset()
  Signal.clearOwner(Story)
  Dialogue.abort()
  resetState()
end

------------------------------------------------------------------------ queue
local function queue(id, ctx)
  if Story.fired[id] or Story.armed[id] then return end
  local def = BEAT_BY_ID[id]
  if not def then return end
  Story.armed[id] = true
  Story.pending[#Story.pending + 1] = { def = def, ctx = ctx or {}, wait = def.delay or 0, age = 0 }
end
Story.queue = queue

local function fire(entry, force)
  local beat = Script.beats[entry.def.id]
  if not beat then return true end
  local world = Story.world
  if entry.def.prep and entry.def.prep(world, entry.ctx) == false then
    return true                       -- cancel: the scene lost its cast
  end
  refreshCast(world)
  local id = entry.def.id
  local h = Dialogue.play(beat.steps, {
    world   = world,
    cast    = Story.cast,
    ctx     = entry.ctx,
    id      = id,
    replace = force == true,
    onDone  = function()
      Story.cooldown = T.beatGap
      Story.tut.gap = max(Story.tut.gap or 0, 1.6)
    end,
  })
  if not h then return false end
  Story.fired[id] = true
  Story.cooldown = T.beatGap
  return true
end

--- Point the cast at live bots for a beat without playing it. The ending
--- scene stages its own sequence and needs the same cast wiring.
function Story.prepare(id, world, ctx)
  ctx = ctx or {}
  local def = BEAT_BY_ID[id]
  if def and def.prep then def.prep(world, ctx) end
  refreshCast(world)
  return ctx
end

--- Play a beat right now, whatever else is happening. For testing and for the
--- ending scene, which stages its own sequence.
function Story.force(id, ctx)
  local def = BEAT_BY_ID[id]
  if not def then return false end
  for i = #Story.pending, 1, -1 do
    if Story.pending[i].def.id == id then table.remove(Story.pending, i) end
  end
  Story.armed[id] = true
  return fire({ def = def, ctx = ctx or {} }, true)
end

----------------------------------------------------------------------- signals
local function subscribe()
  Signal.on("bot:built", function(bot)
    Story.did.build = true
    queue("firstBot", { bot = bot })
  end, Story)

  Signal.on("enemy:spawned", function(e)
    -- arm the fighting beat, then wait for a chomper to actually reach a tree
    if Story.fired.firstAttack or Story.armed.firstAttack then return end
    Story.watch = Story.watch or {}
    Story.watch.attack = true
  end, Story)

  -- Every bot that dies hands over one line about what it actually did. It is
  -- said out loud once, by the bot standing next to it, in the first-loss beat
  -- -- and then again, in writing, next to its name in the memorial.
  Signal.on("bot:epitaph", function(name, text)
    if name and text then Story.epitaphs[name] = text end
  end, Story)

  -- A bot that charges the rig is not "lost" -- world.lua only records deaths
  -- that go through bot:lost, and the rebellion bypasses it. Without this the
  -- memorial prints EVERY ONE OF THEM CAME HOME directly after the player has
  -- watched twenty of them explode, which is not a small mistake. They died
  -- last, so they are last on the list, which is where they belong.
  Signal.on("bot:sacrificed", function(bot)
    if not bot or not bot.name then return end
    if bot.epitaph then Story.epitaphs[bot.name] = bot:epitaph() end
    Story.sacrificed[#Story.sacrificed + 1] = {
      name = bot.name, type = bot.type,
      planted = bot.planted or 0, built = bot.built or 0,
    }
  end, Story)

  Signal.on("bot:lost", function(bot, peaceful)
    if peaceful then return end
    -- world.lua owns world.allLostNames (it records a record per bot, not a
    -- bare name). Writing strings in here too made the memorial sort a mixed
    -- list and crash the ending.
    local first = not (Story.fired.firstLoss or Story.armed.firstLoss)
    -- On the very first one, keep quiet: the cutscene opens on "it stopped",
    -- and an ambient bubble that got there first spends the line.
    if not first then react("loss", bot.x, bot.y) end
    local ep = bot.epitaph and bot:epitaph() or nil
    queue("firstLoss", { lostName = bot.name, lostX = bot.x, lostY = bot.y,
                         lostType = bot.type,
                         lostEpitaph = ep and ("it " .. ep) or nil })
  end, Story)

  Signal.on("phase:day", function(cycle)
    if cycle and cycle >= 5 then queue("question", {}) end
  end, Story)

  Signal.on("phase:extraction", function(boss)
    queue("extraction", { boss = boss })
  end, Story)

  Signal.on("bots:rebel", function()
    queue("rebellion", {})
  end, Story)

  -- reactions: the bots noticing their own lives
  Signal.on("phase:dusk", function() react("night") end, Story)
  Signal.on("phase:night", function() react("night") end, Story)
  Signal.on("phase:dawn",  function() react("day") end, Story)
  Signal.on("boss:phase",  function() react("boss") end, Story)

  -- The player traded a worse night for more daylight. Somebody who has to
  -- work through that night has an opinion about it.
  Signal.on("world:heldDawn", function() react("hold") end, Story)
  Signal.on("o2:milestone",   function() react("grown") end, Story)

  -- The rebellion goes in waves. The cutscene says it once; every cohort after
  -- that says it in the world, on its way past, and then does not come back.
  Signal.on("bots:cohort", function()
    Story.reactT = 0
    react("rebel")
  end, Story)

  -- The rig drained the sky. There is about a second and a half before the
  -- screen goes black, and the last thing in it should be one of them.
  Signal.on("world:failed", function()
    Story.reactT = 0
    react("failed")
  end, Story)
  Signal.on("player:hurt", function()
    local p = Story.world and Story.world.player
    react("night", p and p.x, p and p.y)
  end, Story)
  Signal.on("tree:planted", function(t)
    local w = Story.world
    if w and (w.treeCount or 0) % 40 == 0 then react("day", t and t.x, t and t.y) end
  end, Story)
  Signal.on("bot:revived", function(b) react("rebel", b.x, b.y) end, Story)

  -- tutorial acknowledgements
  Signal.on("player:shove", function() Story.did.shove = true end, Story)
  Signal.on("player:dash",  function() Story.did.dash = true end, Story)
  Signal.on("player:carry", function() Story.did.carry = true end, Story)
  Signal.on("cobalt:gained", function() Story.did.cobalt = true end, Story)
end

------------------------------------------------------------------------- begin
--- Take over a world. `beat` is the beat to open on (normally "prologue").
function Story.begin(world, beat)
  Signal.clearOwner(Story)
  resetState()
  Story.world = world
  if world then
    world.flags = world.flags or {}
    world.cutscene = false
  end
  Story.cast.human.portrait.suit = true
  bound.botA, bound.botB = nil, nil
  subscribe()
  if beat then queue(beat, {}) end
  return Story
end

function Story.isBlocking()
  if Dialogue.isActive() then return true end
  local w = Story.world
  return (w and w.cutscene) == true
end

------------------------------------------------------------------------ update
--- Poll for the one trigger that has no signal: a chomper arriving at a tree.
local function pollFirstAttack(world)
  if not (Story.watch and Story.watch.attack) then return end
  if Story.fired.firstAttack or Story.armed.firstAttack then Story.watch.attack = nil return end
  local list = world.enemies
  if not list then return end
  for i = 1, #list do
    local e = list[i]
    local t = e.alive and e.target or nil
    if t and t.alive and t.stage ~= "dead" and U.dist2(e.x, e.y, t.x, t.y) < 200 * 200 then
      Story.watch.attack = nil
      queue("firstAttack", { enemy = e, tree = t })
      return
    end
  end
end

local function updateBeats(dt, world)
  if Story.cooldown > 0 then Story.cooldown = Story.cooldown - dt end
  local n = #Story.pending
  if n == 0 then return end

  local pick, pickI
  for i = 1, n do
    local e = Story.pending[i]
    e.age = e.age + dt
    if e.wait > 0 then e.wait = e.wait - dt end
    -- drop a low-priority beat that never got its moment
    if e.def.patience and e.age > e.def.patience then
      e.expired = true
    elseif e.wait <= 0 and (Story.cooldown <= 0 or e.def.pri >= 3) then
      if guardOk(e.def.guard, world) and (not e.def.require or e.def.require(world, e.ctx)) then
        if not pick or e.def.pri > pick.def.pri then pick, pickI = e, i end
      end
    end
  end

  for i = n, 1, -1 do
    if Story.pending[i].expired then
      Story.armed[Story.pending[i].def.id] = nil
      table.remove(Story.pending, i)
      if pickI and i < pickI then pickI = pickI - 1 end
    end
  end

  if pick and not Dialogue.isActive() and not (world.cutscene == true) then
    if fire(pick) then
      for i = #Story.pending, 1, -1 do
        if Story.pending[i] == pick then table.remove(Story.pending, i) end
      end
    end
  end
end

local function updateTutorial(dt, world)
  local tu = Story.tut
  if tu.active then
    local s = tu.active
    tu.t = tu.t + dt
    local isDone = s.done(world) == true
    if isDone or tu.t > s.maxT or s.arm(world) ~= true then tu.fading = true end
    tu.a = U.approach(tu.a, tu.fading and 0 or 1, dt * (tu.fading and 2.6 or 1.8))
    if tu.fading and tu.a <= 0.002 then
      tu.shown[s.id] = (tu.shown[s.id] or 0) + 1
      if isDone then tu.doneIds[s.id] = true end
      tu.active, tu.fading, tu.a, tu.t = nil, false, 0, 0
      tu.gap = T.hintGap
    end
    return
  end

  tu.gap = (tu.gap or 0) - dt
  if tu.gap > 0 then return end
  if world.cutscene or Dialogue.isActive() then return end
  local p = world.player
  if not p or (p.state and p.state ~= "alive") then return end

  for i = 1, #TUT do
    local s = TUT[i]
    if not tu.doneIds[s.id] and (tu.shown[s.id] or 0) < T.hintRepeats and s.arm(world) == true then
      if s.done(world) == true then
        tu.doneIds[s.id] = true          -- they worked it out on their own
      else
        tu.active, tu.a, tu.t, tu.fading = s, 0, 0, false
        return
      end
    end
  end
end

function Story.update(dt)
  local world = Story.world
  if not world then return end

  Story.time = (Story.time or 0) + dt
  if Story.reactT > 0 then Story.reactT = Story.reactT - dt end

  local p = world.player
  if p then
    if Story.lastX then
      local d = U.dist(p.x, p.y, Story.lastX, Story.lastY)
      if d < 40 then Story.moved = (Story.moved or 0) + d end
    end
    Story.lastX, Story.lastY = p.x, p.y
  end

  refreshCast(world)
  pollFirstAttack(world)
  updateBeats(dt, world)
  updateTutorial(dt, world)
end

-------------------------------------------------------------------------- draw
--- The hint the active step wants under its label: a real button glyph where
--- there is one action to press, plain words where there is not.
local function hintFor(step)
  local c = step.copy
  if not c then return nil, nil end
  if c.id == "move" then
    if Input.scheme == "pad" then return nil, c.pad or "L-STICK" end
    if Input.scheme == "touch" then return nil, c.touch or "DRAG" end
    return nil, c.hint or "WASD"
  end
  -- a step may carry both: the button to press, and what pressing it costs
  return c.action, c.hint
end

local HINT_TEXT = { tracking = 0.08, snap = true }

--- One hint, anchored to the thing it is about. A stem, a word, a key.
local function drawHint(step, alpha, world)
  local cam = world.camera
  local a = world.camera and step.anchor(world) or nil
  if not a then return end
  local ax, ay = a.x, a.y
  if not ax then return end

  local sw, sh = lg.getDimensions()
  local sx, sy = cam:toScreen(ax, ay - (a.radius or 14) * 1.9)
  local pad = 92
  sx = U.clamp(sx, pad, sw - pad)
  sy = U.clamp(sy, 96, sh - 150)

  local e = U.ease.outCubic(alpha)
  local rise = (1 - e) * 12
  local col = step.color or P.accent
  local label = (step.copy and step.copy.label) or string.upper(step.id)
  local action, words = hintFor(step)

  local size = 17
  local lw = Text.measure(label, size, HINT_TEXT) or 0
  if lw > 300 then
    size = size * 300 / lw
    lw = 300
  end
  local subH = 20 + ((action and words) and 16 or 0)
  local wordW = words and (Text.measure(words, 10, HINT_TEXT) or 0) or 0
  local boxW = max(lw, wordW, 92) + 40
  local boxH = size + subH + 26
  local bx = floor(sx - boxW * 0.5)
  local by = floor(sy - boxH - 16 + rise)

  -- stem: the hint is attached to the world, not floating over it
  Draw.setColor(col, 0.34 * e)
  lg.setLineWidth(1)
  lg.line(sx, by + boxH, sx, sy - 4 + rise)
  Draw.setColor(col, 0.65 * e)
  lg.circle("fill", sx, sy - 3 + rise, 2.1)

  UI.panel(bx, by, boxW, boxH, 0.72 * e, 6, col, 0.26 * e)
  Draw.setColor(col, 0.9 * e)
  lg.setLineWidth(2)
  lg.line(bx + 12, by + 0.5, bx + 12 + min(26, boxW * 0.34), by + 0.5)

  UI.text(label, sx, by + 12, size, col, "center", e, 0.08)
  if action then
    UI.prompt(sx, by + 12 + size + 14, action, nil, 12, P.ink, e, "center")
    if words then
      UI.caption(words, sx, by + 12 + size + 38, 10, P.inkDim, "center", e * 0.9)
    end
  elseif words then
    UI.caption(words, sx, by + 14 + size + 8, 10, P.inkDim, "center", e * 0.95)
  end
  lg.setColor(1, 1, 1, 1)
end

function Story.draw()
  local world = Story.world
  if not world or not world.camera then return end
  if world.cutscene then return end
  local tu = Story.tut
  if tu.active and tu.a > 0.004 then drawHint(tu.active, tu.a, world) end
end

return Story
