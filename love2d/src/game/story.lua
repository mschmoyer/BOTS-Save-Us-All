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
local Names    = require("src.game.names")
local Dialogue = require("src.game.dialogue")

local Draw = Opt.require("src.engine.draw")
local Text = Opt.require("src.engine.text")
local UI   = Opt.require("src.engine.ui")
-- Only for the two things a hint has to keep off: the bottom band, and the
-- screen during a cutscene.
local HUD  = Opt.require("src.game.hud")

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
  hurtQuiet   = 8.0,     -- seconds after a hit before a "calm" beat may play
  reinforceGap = 5.0,    -- ...between two walk-ins saying where they came from
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

--- Blight that does not leave at sunrise and cannot come at you. This is the
--- same predicate Enemy:flee tests to decide who stays: a Scar, and a dormant
--- Maw. tuning.lua's own note on the Scar is that it "never moves, never
--- chases, and cannot hurt the player at all".
---
--- They are excluded from the count below, and that is a fix rather than a
--- nicety. A Scar roots where something was chewing a tree, which is inside
--- the wood, and it is still there the next morning and the morning after. So
--- from about cycle four the player's own forest permanently contained one,
--- `blightNear` never read zero in daylight, and `guard = "calm"` -- which
--- demands exactly zero -- became unsatisfiable for the rest of the run. Every
--- beat behind it starved. In one traced run on seed 7 that cost the game both
--- of its middle beats outright: nothing was said between 1:21 and 13:33.
local function rooted(e)
  return (e.def and e.def.holdsGround) or e.type == "scar"
end

local function blightNear(world, r)
  local p = world and world.player
  if not p then return 0 end
  local n = 0
  if world.hEnemy and world.hEnemy.each then
    world.hEnemy:each(p.x, p.y, r, function(e)
      if e.alive and not e.fleeing and not rooted(e)
         and U.dist2(e.x, e.y, p.x, p.y) <= r * r then n = n + 1 end
    end)
  elseif world.enemies then
    for i = 1, #world.enemies do
      local e = world.enemies[i]
      if e.alive and not e.fleeing and not rooted(e)
         and U.dist2(e.x, e.y, p.x, p.y) <= r * r then n = n + 1 end
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
  -- calm: daylight, nothing hunting you, not mid-rescue, and not in the
  -- seconds after a hit.
  if world.phase == "night" or world.phase == "dusk" then return false end
  if world.phase == "extraction" or world.phase == "ending" then return false end
  -- That last clause used to read `hp < 2`, and it was the second thing
  -- starving the middle of the run. Hearts never come back except by going
  -- down and rebooting, so a player who took two hits on cycle two and then
  -- played well spent the rest of the game on one heart -- and every beat
  -- behind this guard was unreachable for the whole of it. The better they
  -- played, the less of the story they were told. Measured on seed 2: the
  -- answer beat sat through both of its cycles at hp=1 with zero blight on
  -- the screen and was dropped on its patience.
  --
  -- What the rule wants is "not while they are being killed", and that is a
  -- clock, not a resource.
  if (Story.hurtT or 0) > 0 then return false end
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
      -- The one the player heard say "oh". Not "the first bot built": the beat
      -- can be cancelled and re-prepped against a different machine, and it is
      -- the one that spoke that beats 7 and 10 are about.
      Story.theFirstOne = b
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
    -- Cycle 3, not cycle 5. Three is the first dawn the player owns a real
    -- wood and a real crew, which is when "what are the trees for" has
    -- anything behind it -- and it is what opens cycle 6 for the answer, so
    -- the middle of the run has two beats in it instead of one.
    --
    -- pri 2, not 1. At the bottom of the table it yielded to everything, and
    -- in a traced run it slipped a cycle and a half past its own signal.
    id = "question", pri = 2, guard = "calm", delay = 4.0, patience = 420,
    prep = function(world, ctx)
      local p = world.player
      local b = pickBot(world, p and p.x, p and p.y, nil,
                        function(bb) return bb.type == "planter" end)
             or pickBot(world, p and p.x, p and p.y)
      if not b then return false end
      ctx.bot = b
      bind("botA", b)
      -- beat 6 opens on this machine quoting its own log back
      Story.questionBot = b
      return true
    end,
  },
  {
    -- Cycle 4. The only thing standing in the measured 4:13 -> 10:20 silence.
    -- It has no geography: the subject is the rig's radio, which is a fixture,
    -- the camera is on the bot, and the only cancel path is "no living bot",
    -- which cancels the run's whole story anyway. It touches no relic and reads
    -- no position, so it cannot starve on where the player happens to be.
    id = "radio", pri = 2, guard = "calm", delay = 4.0, patience = 420,
    -- It only exists between the two. Held behind the question; once the answer
    -- has played it can never fire, and expires on its patience unplayed -- a
    -- beat about the middle must not arrive after the end of the middle.
    require = function() return Story.fired.question and not Story.fired.answer end,
    prep = function(world, ctx)
      local p = world.player
      -- The machine that asked, if it is still standing. Same fallback as the
      -- answer beat: cancelling here would reopen the dead zone this is for.
      local b = Story.questionBot
      if not (b and b.alive and b.state ~= "dead" and b.state ~= "down") then
        b = pickBot(world, p and p.x, p and p.y, nil,
                    function(bb) return bb.type == "planter" end)
         or pickBot(world, p and p.x, p and p.y)
      end
      if not b then return false end
      ctx.bot = b
      bind("botA", b)
      -- ...and promote the replacement, so the answer beat gets the machine the
      -- player just heard rather than re-picking a third stranger.
      Story.questionBot = b
      return true
    end,
  },
  {
    -- The answer, three cycles later. It only exists as a reply, so it will
    -- not play until the question has actually been asked: `require` is
    -- checked at fire time, every frame, so a question still sitting in the
    -- queue holds this one behind it instead of racing it.
    id = "answer", pri = 1, guard = "calm", delay = 4.0, patience = 420,
    require = function() return Story.fired.question end,
    prep = function(world, ctx)
      local p = world.player
      -- Preferring the bot that asked is the beat: "i asked what the trees are
      -- for" is a machine reading its own log. The fallback is not a nicety --
      -- cancelling here would reopen the exact dead zone this beat is for.
      local b = Story.questionBot
      if not (b and b.alive and b.state ~= "dead" and b.state ~= "down") then
        b = pickBot(world, p and p.x, p and p.y, nil,
                    function(bb) return bb.type == "planter" end)
         or pickBot(world, p and p.x, p and p.y)
      end
      if not b then return false end
      ctx.bot = b
      bind("botA", b)
      return true
    end,
  },
  {
    -- The bot from beat 2 is gone. Queued only when it is NOT the run's first
    -- loss -- if it is, firstLoss has the body, and two funerals over it would
    -- be worse than none.
    id = "firstBotLost", pri = 2, guard = "calm", delay = 2.2, patience = 300,
    prep = function(world, ctx)
      -- botB, not botA: botA is the machine that died, and the survivor
      -- standing over it is somebody else. ctx.lostX/lostY stay put -- the
      -- camera step reads them, and there is no body to follow.
      local b = pickBot(world, ctx.lostX, ctx.lostY)
      if not b then return false end
      ctx.bot = b
      bind("botB", b)
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
      -- The machine that said "oh / hello" gets "you can take it off now", if
      -- it is still standing. The nearest survivor is whoever the ring happened
      -- to seat closest, and in one traced capture that was a repulsor pylon
      -- built four minutes earlier. scenes/ending.lua revives the downed before
      -- it calls this, so `state == "down"` is not a reason to pass it over.
      local first = Story.theFirstOne
      if not (first and first.alive and first.state ~= "dead") then first = nil end
      local a = first or pickBot(world, p and p.x, p and p.y)
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
  -- HOLD THE DAWN used to be a step here. It is a decision the player makes
  -- again every cycle, and a hint that shows twice and then gives up is the
  -- wrong shape for that: game/hud.lua stands the offer under the cycle dial
  -- for as long as it is open instead.
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

  -- The back half. Each of these arms the first time the player is in the
  -- situation the thing exists for -- not on a timer, and not all at once.
  {
    id = "pulse",
    arm = function(w)
      if Story.did.shove ~= true then return false end
      local p = w.player
      if not p or not w.hEnemy then return false end
      local near = 0
      w.hEnemy:each(p.x, p.y, 240, function(e) if e.alive and not e.fleeing then near = near + 1 end end)
      return near >= 3
    end,
    done = function(w) return Story.did.pulse == true end,
    anchor = playerOf,
    color = P.accentCool,
  },
  {
    id = "handplant",
    arm = function(w)
      -- once there is a wood to extend, and the player is standing away from it
      return (w.cycle or 1) >= 2 and (w.treeCount or 0) >= 14
             and Story.did.build == true
    end,
    done = function(w) return Story.did.handplant == true end,
    anchor = playerOf,
    color = P.ramp.leaf[4],
  },
  {
    id = "harvester",
    arm = function(w)
      return (w.cycle or 1) >= 2 and w.botCost
             and (w.cobalt or 0) >= w:botCost("harvester")
             and w:countBots("harvester") == 0
    end,
    done = function(w) return w:countBots("harvester") > 0 end,
    anchor = playerOf,
    color = P.ramp.cobalt[3],
  },
  {
    id = "builder",
    arm = function(w)
      return (w.cycle or 1) >= 2 and w.botCost
             and (w.cobalt or 0) >= w:botCost("builder")
             and w:countBots("builder") == 0
    end,
    done = function(w) return w:countBots("builder") > 0 end,
    anchor = playerOf,
    color = P.accent,
  },
  {
    id = "beacon",
    arm = function(w)
      -- the first time somebody goes down a long way from the rig, which is
      -- exactly the problem a Beacon solves
      local p = w.player
      if not p or w:countBots("beacon") > 0 then return false end
      local b = w.nearestDownedBot and w:nearestDownedBot(p.x, p.y, 2400)
      if not b then return false end
      return U.dist(b.x, b.y, w.homeX, w.homeY) > 700
             and w.botCost and (w.cobalt or 0) >= w:botCost("beacon")
    end,
    done = function(w) return w:countBots("beacon") > 0 end,
    anchor = playerOf,
    color = P.eye,
  },
  {
    id = "sentry",
    arm = function(w)
      return (w.cycle or 1) >= 3 and w.botCost
             and (w.cobalt or 0) >= w:botCost("sentry")
             and w:countBots("sentry") == 0
    end,
    done = function(w) return w:countBots("sentry") > 0 end,
    anchor = playerOf,
    color = P.warn,
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

--- The same thing, but from a bot we already have. Some lines belong to one
--- machine and not to whoever happens to be standing nearest: the one in your
--- arms is the one with an opinion about being carried, and `pickBot` skips
--- downed bots anyway, so routing those through `react` would have put "put me
--- by the light" in the mouth of a bystander.
local function reactFrom(bot, phase)
  local w = Story.world
  if not w or w.cutscene or Dialogue.isActive() then return end
  if Story.reactT > 0 then return end
  if not bot or not bot.alive or not bot.say then return end
  bot:say(phase)
  Story.reactT = T.reactGap
end
Story.reactFrom = reactFrom

--- Which of the two long pools the world is in. Anything that can happen at
--- any hour has to ask: a hit taken at noon used to answer with the night pool,
--- so a bot would say "morning is not far" in broad daylight.
local function phasePool()
  local w = Story.world
  local ph = w and w.phase
  return (ph == "night" or ph == "dusk") and "night" or "day"
end

------------------------------------------------------------------------- state
local function resetState()
  Story.world    = nil
  Story.pending  = {}
  Story.fired    = {}
  Story.armed    = {}
  Story.cooldown = 0
  Story.reactT   = 0
  Story.dawnFlip = false
  Story.hurtT    = 0
  Story.reinforceT = 0
  Story.time     = 0
  Story.moved    = 0
  Story.lastX, Story.lastY = nil, nil
  Story.did      = {}
  -- Two machines the story keeps hold of by name. The first is the one the
  -- player heard boot and speak; the second is the one that asked what the
  -- trees are for, so the beat that answers can be the same voice.
  Story.theFirstOne  = nil
  Story.questionBot  = nil
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
    -- Reinforcements walked in off the treeline during the rebellion; world.lua
    -- says in so many words that they are not in the ending's ledger, "because
    -- the names in that ledger are the ones you built and lost". They leaked in
    -- through here, and because they arrive with empty ledgers and live seconds
    -- they filled twenty-two rows of one memorial with the same sentence.
    if bot.offRoster then return end
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
    -- The name goes over first: the `loss` pool can say it, and "say the name"
    -- is only a ritual if somebody then does.
    Names.remember(bot.name)
    if not first then react("loss", bot.x, bot.y) end
    local ep = bot.epitaph and bot:epitaph() or nil
    queue("firstLoss", { lostName = bot.name, lostX = bot.x, lostY = bot.y,
                         lostType = bot.type,
                         lostEpitaph = ep and ("it " .. ep) or nil })
    -- ...and if the one that just stopped is the one that said hello, it gets
    -- its own beat rather than a line in the toast feed. Only when it is not
    -- also the first loss: that body already has a scene standing over it.
    if not first and Story.theFirstOne and bot == Story.theFirstOne then
      queue("firstBotLost", { lostX = bot.x, lostY = bot.y })
    end
  end, Story)

  -- The two scheduled beats, and the only two things in the table that are on
  -- a clock rather than on an event. Everything else fires off something the
  -- player did or something that happened to them, which is why the middle of
  -- the run went quiet: nothing happens in the middle that the story is
  -- listening for. Re-queued every cycle on purpose -- `armed` swallows the
  -- duplicate, and if either is ever dropped on its patience the next dawn
  -- puts it back.
  Signal.on("phase:day", function(cycle)
    if not cycle then return end
    if cycle >= 3 then queue("question", {}) end
    -- re-queued every dawn from cycle 4; `armed` swallows the duplicate
    if cycle >= 4 then queue("radio",    {}) end
    if cycle >= 6 then queue("answer",   {}) end
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
  -- Dawn is not just "day again": the night pool spends itself asking to be
  -- counted at first light, and this is the pool that counts.
  -- First light. Once the radio beat has played, one machine in four reports
  -- the readout instead of counting the crew -- the recurring half of that beat,
  -- and the only thing that speaks in cycles 4 through 7 on most runs. The
  -- number it reports has never changed and never will.
  Signal.on("phase:dawn",  function()
    -- Alternating, not random: a coin flip can hand a whole run the counting
    -- pool and the thread never appears. There are only three or four dawns
    -- left after the beat fires and every one of them has to count.
    if Story.fired.radio then
      Story.dawnFlip = not Story.dawnFlip
      react(Story.dawnFlip and "radio" or "dawn")
    else
      react("dawn")
    end
  end, Story)
  Signal.on("boss:phase",  function() react("boss") end, Story)

  -- The player traded a worse night for more daylight. Somebody who has to
  -- work through that night has an opinion about it.
  Signal.on("world:heldDawn", function() react("hold") end, Story)
  -- Deliberately NOT routed through phasePool(). An oxygen milestone is an
  -- event with a pool of its own, like `loss` and `boss` and `failed`, and
  -- phasePool() only picks between the two long ambient pools -- sending this
  -- through it would answer the best number in the game with "good dirt here".
  -- The one line in `grown` that reads oddly after dark is "the sky changed
  -- colour", one draw in five, and the cost of fixing it is a second five-line
  -- pool for a moment that happens four times a run. Left as it is on purpose.
  Signal.on("o2:milestone",   function() react("grown") end, Story)

  -- The island answers. A machine that was working somewhere else walks in off
  -- the treeline, and it says where it came from rather than one of the crew's
  -- rebellion lines -- which is what made the reinforcements read as the game
  -- topping up the fight instead of as strangers arriving. It said a `rebel`
  -- line inside Bot:rebel a tick ago; World:speak drops a bot's previous bubble
  -- when it gets a new one, so this replaces that rather than stacking on it.
  --
  -- Its own clock, deliberately not the shared reaction gap: measured, the
  -- shared gap is already spent by the fight these are arriving into, and
  -- routing them through it gave one walk-in in ten its own line and left the
  -- other nine sounding like crew. One every five seconds against an arrival a
  -- second is a trickle of strangers rather than a chant.
  Signal.on("bots:reinforce", function(b)
    local w = Story.world
    if not w or w.cutscene or Dialogue.isActive() then return end
    if (Story.reinforceT or 0) > 0 then return end
    if not b or not b.alive or not b.say then return end
    b:say("reinforce")
    Story.reinforceT = T.reinforceGap
  end, Story)

  -- Deliberately NOT subscribed: "bots:cohort". Bot:rebel already says a rebel
  -- line for every bot that launches, so a cohort of eight arrives with its own
  -- voices; adding a ninth here only competes with them for the three speech
  -- slots. The work that beat needed was in the pool, not in the director.

  -- The rig drained the sky. There is about a second and a half before the
  -- screen goes black, and the last thing in it should be one of them.
  Signal.on("world:failed", function()
    Story.reactT = 0
    react("failed")
  end, Story)
  Signal.on("player:hurt", function()
    local p = Story.world and Story.world.player
    -- ...and hold the quiet beats off for a few seconds. This is the whole of
    -- what `guard = "calm"` used to try to say with `hp >= 2`.
    Story.hurtT = T.hurtQuiet
    react(phasePool(), p and p.x, p and p.y)
  end, Story)
  -- He is on the ground and the reboot clock is up. This one jumps the queue:
  -- whatever a bot was about to say about the dirt matters less.
  Signal.on("player:down", function(p)
    Story.reactT = 0
    react("downed", p and p.x, p and p.y)
  end, Story)
  Signal.on("tree:planted", function(t, by)
    if by == "player" then Story.did.handplant = true end
    local w = Story.world
    -- ...and not "day": the fortieth tree gets planted after dark as often as
    -- not, and a bubble reading "more sun today" at 0:13 of a bad night is the
    -- same mistake as answering a hit with the night pool.
    if w and (w.treeCount or 0) % 40 == 0 then react(phasePool(), t and t.x, t and t.y) end
  end, Story)
  -- This used to fire the REBELLION pool, so a routine daylight rescue on cycle
  -- two had a bystander saying "save the human" and "goodbye" twenty minutes
  -- before the scene that those belong to. It is the bot that just stood up
  -- that has something to say, and what it has to say is about standing up.
  Signal.on("bot:revived", function(b) reactFrom(b, "saved") end, Story)

  -- tutorial acknowledgements
  Signal.on("player:shove", function() Story.did.shove = true end, Story)
  Signal.on("player:pulse", function() Story.did.pulse = true end, Story)
  Signal.on("player:dash",  function() Story.did.dash = true end, Story)
  Signal.on("player:carry", function(bot)
    Story.did.carry = true
    reactFrom(bot, "carried")
  end, Story)
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

--- Is this a moment that can carry a hint at all?
---
--- Hints are for a player who is still learning the game, and they are not for
--- the last three minutes of it. During the extraction the screen belongs to
--- the rig, to the bar with its name on it and to the bots walking into it --
--- a hint reading WALK over the player's head in the middle of that is an
--- insult, and one drawn across HARVESTER PRIME is worse. Cutscenes are out
--- for the same reason: the letterbox is down and nothing else may be on top
--- of it.
local function hintsAllowed(world)
  if not world then return false end
  if world.cutscene or Dialogue.isActive() then return false end
  local ph = world.phase
  return ph ~= "extraction" and ph ~= "ending"
end
Story.hintsAllowed = hintsAllowed

local function updateTutorial(dt, world)
  local tu = Story.tut
  local allowed = hintsAllowed(world)
  if tu.active then
    local s = tu.active
    tu.t = tu.t + dt
    local isDone = s.done(world) == true
    if isDone or not allowed or tu.t > s.maxT or s.arm(world) ~= true then tu.fading = true end
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
  if not allowed then return end
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
  if Story.hurtT > 0 then Story.hurtT = Story.hurtT - dt end
  if Story.reinforceT > 0 then Story.reinforceT = Story.reinforceT - dt end

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
  -- the HUD owns the bottom band: the build bar sits in it, and so does the
  -- boss's name and health. A hint anchored to something off the bottom of the
  -- screen stops above it rather than being drawn through it.
  local floorY = (HUD.overlayFloor and HUD.overlayFloor()) or (sh - 150)
  sy = U.clamp(sy, 96, min(sh - 150, floorY))

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
  -- a step with both a button and a caption needs a third row of box
  local both = (action and words) and true or false
  local subH = 20 + (both and 32 or 0)
  local wordW = 0
  if words then
    wordW = (UI.captionWidth and UI.captionWidth(words, 10))
            or (Text.measure(words, 10, HINT_TEXT) or 0)
  end
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
      UI.caption(words, sx, by + 12 + size + 44, 10, P.inkDim, "center", e * 0.9)
    end
  elseif words then
    UI.caption(words, sx, by + 14 + size + 8, 10, P.inkDim, "center", e * 0.95)
  end
  lg.setColor(1, 1, 1, 1)
end

function Story.draw()
  local world = Story.world
  if not world or not world.camera then return end
  if not hintsAllowed(world) then return end
  local tu = Story.tut
  if tu.active and tu.a > 0.004 then drawHint(tu.active, tu.a, world) end
end

return Story
