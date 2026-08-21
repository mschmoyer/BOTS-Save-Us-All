-- Every word in the game, in one place.
--
-- Voice rules, and they are not negotiable:
--   * The bots speak in lowercase, in short simple sentences, and they never
--     say anything clever. They are not comic relief.
--   * The human speaks in full sentences. He is a mechanic, not a poet. He
--     reads instruments, names parts, and gives orders.
--   * No line explains how the player is supposed to feel, and no line
--     describes something already on the screen.
--   * A step with no text is allowed, and is usually the better step. Silence
--     is written as `wait`, never as an empty panel: the words that were just
--     said stay up while the beat lands.
--
-- Two lines are inherited from the 2019 jam original and are load-bearing:
--   "You've taught us love. Save the human."   -- verbatim, do not touch
--   "The world is safe" / "just me, all alone, forever"  -- the ending turn
local P = require("src.engine.palette")

local S = {}

------------------------------------------------------------------ constructors
local function line(who, text, tone, extra)
  local t = { kind = "line", who = who, text = text, tone = tone }
  if extra then for k, v in pairs(extra) do t[k] = v end end
  return t
end
--- A beat held on a face, with nothing said. Use sparingly: an empty panel
--- reads as a missing string. Prefer `wait`, which keeps the last line up.
local function look(who, dur, tone)
  return { kind = "line", who = who, text = "", tone = tone, auto = dur or 1.0 }
end
local function wait(dur)      return { kind = "wait", dur = dur } end
local function fn(f)          return { kind = "fn", fn = f } end
local function flag(name, v)  return { kind = "flag", name = name, value = v } end
local function music(state)   return { kind = "music", state = state } end
--- Open or close the letterbox by hand. `bars(0, d)` takes the panel away and
--- leaves the world; it is how the ending buys a silence you can look at.
local function bars(amount, dur)
  return { kind = "letterbox", amount = amount, dur = dur, wait = true }
end
local function sound(name, o) local t = { kind = "sound", name = name }
                              if o then for k, v in pairs(o) do t[k] = v end end return t end
local function camera(o)      local t = { kind = "camera" }
                              for k, v in pairs(o) do t[k] = v end return t end
local function fx(o)          local t = { kind = "fx" }
                              for k, v in pairs(o) do t[k] = v end return t end

S.line, S.look, S.wait, S.fn, S.flag = line, look, wait, fn, flag
S.music, S.sound, S.camera, S.fx, S.bars = music, sound, camera, fx, bars

--- Pull a name out of the context the director hands us.
local function ctxName(key, fallback)
  return function(ctx) return (ctx and ctx[key]) or fallback end
end
S.ctxName = ctxName

--------------------------------------------------------------------- 1. PROLOGUE
-- Waking at the Home Rig. The sky is wrong. Establish everything in five lines
-- and then get out of the way.
--
-- The loneliness is planted here and not spent here: he says nobody answers
-- the radio, and he does not say what that means. The ending says it.
S.prologue = {
  steps = {
    camera({ entity = function(_, w) return w and w.player end, zoom = 1.16, dur = 1.0 }),
    look("human", 1.4, "tired"),
    line("human", "The sky has been that colour for eleven days.", "tired"),
    line("human", "They came down, they took the air, and they went home.", "flat"),
    wait(0.8),
    line("human", "The radio has been on the whole time. Nobody has answered.", "flat"),
    wait(1.1),
    line("human", "I fix things.", "flat"),
    line("human", "So I am going to fix the air.", "soft"),
    flag("prologueDone", true),
    camera({ release = true, dur = 0.4 }),
  },
}

-------------------------------------------------------------------- 2. FIRST BOT
-- It boots, it looks at you, it speaks. A man who has not heard a voice in
-- eleven days does not say hello back -- he makes it say the word again, and
-- calls the part good. Everything after this costs something.
S.firstBot = {
  steps = {
    camera({ entity = function(ctx) return ctx.bot end, zoom = 1.22, dur = 0.8 }),
    sound("bot_boot", { pitch = 0.94 }),
    fx({ effect = "bot_boot", entity = function(ctx) return ctx.bot end, dur = 0.7 }),
    look("botA", 1.2, "small"),
    line("botA", "oh", "bright"),
    line("botA", "hello", "bright"),
    wait(0.9),
    line("human", "Say that again.", "flat"),
    line("botA", "hello", "bright"),
    line("human", "Good.", "soft"),
    line("botA", "what do i do", "flat"),
    line("human", "You plant trees. I will handle everything else.", "soft"),
    line("botA", "ok", "flat"),
    line("botA", "i will be good at it", "bright"),
    wait(1.2),
    flag("metFirstBot", true),
    camera({ release = true, dur = 0.4 }),
  },
}

----------------------------------------------------------------- 3. FIRST ATTACK
-- The fighting tutorial. 2019 said: "Ack! They're attacking my trees! I must
-- protect them!" Same shape, no exclamation marks, and the pillar of the whole
-- game said out loud exactly once. The hint teaches the key; this teaches the
-- rule. It ends on the bot, not on the man.
S.firstAttack = {
  steps = {
    camera({ entity = function(ctx) return ctx.enemy end, zoom = 1.14, dur = 0.9 }),
    line("botA", "there is something on the little one", "urgent"),
    line("human", "Get behind me.", "urgent"),
    fx({ shake = 0.35, dur = 0.35 }),
    sound("chomp"),
    wait(0.7),
    line("human", "I cannot kill it. I can move it.", "flat"),
    line("botA", "move it away", "flat"),
    wait(0.9),
    flag("attackTaught", true),
    camera({ release = true, dur = 0.4 }),
  },
}

------------------------------------------------------------------- 4. FIRST LOSS
-- A named bot is gone. The survivor says what it did -- which is the format of
-- the memorial the player will read at the end, taught here, once, in the
-- voice of somebody who was standing next to it.
--
-- The rescue rule arrives one line too late to have been any use, and the
-- question that follows it does not get answered.
S.firstLoss = {
  steps = {
    camera({ x = function(ctx) return ctx.lostX end,
             y = function(ctx) return ctx.lostY end, zoom = 1.2, dur = 1.1 }),
    look("botB", 1.1, "small"),
    line("botB", "it stopped", "small"),
    line("human", ctxName("lostName", "SEED-01"), "sad"),
    line("botB", "yes", "small"),
    line("botB", ctxName("lostEpitaph", "it was here"), "small"),
    wait(1.0),
    line("botB", "can you fix it", "small"),
    line("human", "Not out here.", "sad"),
    wait(0.9),
    line("human", "If one of you goes down it stays lit a while. Carry it to a beacon.", "flat"),
    line("botB", "was it lit", "small"),
    wait(2.0),
    line("human", "Go on. Back to work.", "tired"),
    flag("rescueTaught", true),
    camera({ release = true, dur = 0.5 }),
  },
}

-------------------------------------------------------------- 5. CYCLE 5, THE QUESTION
-- Twenty words. Do not add a twenty-first. The second question is never
-- answered: the silence after it is the beat, so it is a `wait` and the
-- question stays on the screen through all of it.
S.question = {
  steps = {
    camera({ entity = function(ctx) return ctx.bot end, zoom = 1.2, dur = 0.8 }),
    line("botA", "can i ask something", "flat"),
    wait(1.0),
    line("botA", "what are the trees for", "flat"),
    wait(1.2),
    line("human", "They make the air.", "flat"),
    line("botA", "for who", "flat"),
    wait(2.6),
    line("botA", "ok", "flat"),
    line("botA", "i will plant more", "soft"),
    flag("askedTheQuestion", true),
    camera({ release = true, dur = 0.5 }),
  },
}

------------------------------------------------------------------ 6. EXTRACTION
-- The Harvester Prime arrives. The bots have no word for it; he does, and he
-- does not say it. What he says instead is what it is doing, because from this
-- moment the oxygen bar is a countdown and the player has to know that.
S.extraction = {
  steps = {
    camera({ entity = function(ctx) return ctx.boss end, zoom = 0.86, dur = 1.2 }),
    fx({ shake = 0.9, dur = 0.5 }),
    line("botA", "what is that", "urgent"),
    line("botB", "orders?", "urgent"),
    line("human", "Get away from it. All of you.", "urgent"),
    wait(0.5),
    line("botA", "we do not have a word for it", "small"),
    line("human", "I do.", "flat"),
    wait(0.6),
    line("human", "It is taking the air back.", "flat"),
    line("botB", "it is very big", "small"),
    line("human", "I know.", "tired"),
    flag("bossMet", true),
    camera({ release = true, dur = 0.6 }),
  },
}

------------------------------------------------------------------ 7. REBELLION
-- The line in the middle of this is from the 2019 original and is reproduced
-- exactly. It is the only time a bot speaks in full sentences, with capital
-- letters and a full stop, and that break is the entire drama of the scene.
--
-- Nothing is added after "we know". The cohorts leaving is the rest of it, and
-- that is said in the world, in speech bubbles, by bots on their way past.
S.rebellion = {
  steps = {
    camera({ entity = function(ctx) return ctx.bot end, zoom = 1.18, dur = 0.9 }),
    music("boss"),
    line("human", "Get back. Get behind the rig.", "urgent"),
    wait(0.6),
    line("botA", "no", "flat"),
    wait(1.1),
    line("botA", "You've taught us love. Save the human.", "soft"),
    fx({ effect = "love_heart", entity = function(ctx) return ctx.bot end,
         count = 22, flash = 0.16, color = P.love, dur = 0.4 }),
    line("human", "Don't. That is an order.", "urgent"),
    line("botB", "we know", "soft"),
    wait(1.4),
    flag("rebelSeen", true),
    camera({ release = true, dur = 0.6 }),
  },
}

-------------------------------------------------------------------- 8. ENDING
-- The product.
--
-- 2019: "The world is safe! I no longer need this suit... ... Just me all
-- alone... Forever." Every beat of that turn is kept. What is added is the
-- radio -- planted in the prologue, drawn on the helmet in every line he has
-- ever spoken, and switched off here. He gives up the suit and the only thing
-- that could ever have answered him in the same breath.
--
-- The silence in the middle is not a pause. The panel is taken away for it, so
-- there is nothing on the screen but a man with his helmet off in a forest
-- full of machines that are looking at him. A bot says the one thing that
-- could contradict what he is about to say. He says it anyway.
--
-- Played by scenes/ending.lua, which owns the staging around it.
S.ending = {
  steps = {
    wait(2.6),
    line("human", "Twenty-one percent oxygen.", "flat", { auto = 2.4 }),
    wait(1.2),
    line("botA", "you can take it off now", "soft", { auto = 2.6 }),
    wait(1.8),
    line("human", "The world is safe.", "flat", { auto = 2.4 }),
    wait(0.8),
    line("human", "I do not need this any more.", "flat", { auto = 2.0 }),
    wait(0.7),
    line("human", "Or the radio.", "flat", { auto = 2.2 }),
    fn(function(ctx, world)
      if world and world.player then world.player.suit = false end
      if ctx and ctx.onSuitOff then ctx.onSuitOff() end
    end),
    sound("bot_revive", { volume = 0.5, pitch = 0.7 }),
    wait(2.0),

    -- panel out. From here until the turn there is no interface at all.
    bars(0, 1.3),
    wait(4.6),
    fn(function(ctx, world)
      local b = ctx and (ctx.bot or ctx.bot2)
      if b and world and world.speak then world:speak(b, S.credits.quiet) end
    end),
    wait(4.2),
    bars(1, 0.9),

    line("human", "Just me.", "sad", { auto = 2.2 }),
    wait(1.5),
    line("human", "All alone.", "sad", { auto = 2.4 }),
    wait(2.0),
    line("human", "Forever.", "sad", { auto = 3.6 }),
    wait(2.6),
    bars(0, 1.6),
    wait(2.0),
    flag("endingSpoken", true),
  },
}

--------------------------------------------------------------------- tutorial
-- Diegetic, non-blocking, one at a time, anchored to the thing they are about,
-- and every one of them dismisses itself the moment the player does it.
--
-- A hint names the thing and gives the verb. It never names the verb twice:
-- "DASH" over your own head teaches nothing you did not already read in the
-- options menu, so the label is what the dash is FOR.
S.tutorial = {
  { id = "move",    label = "WALK",            hint = "WASD", pad = "L-STICK", touch = "DRAG" },
  { id = "cobalt",  label = "COBALT",          hint = "WALK OVER IT" },
  { id = "planter", label = "BUILD A PLANTER", action = "build1" },
  { id = "hold",    label = "HOLD THE DAWN",   action = "commit",
                    hint = "MORE DAY. WORSE NIGHT." },
  { id = "shove",   label = "SHOVE IT OFF",    action = "shove" },
  { id = "dash",    label = "GET OUT OF THE WAY", action = "dash" },
  { id = "rescue",  label = "IT IS STILL LIT", action = nil, hint = "CARRY IT TO A BEACON" },
}

------------------------------------------------------------------ ending credits
-- A memorial, not a scoreboard. Two rules make the difference:
--   * the fallen are listed in the order they died, not sorted -- a sorted
--     list is an inventory, and groups them by model number
--   * every name carries what that bot actually did, in its own voice
S.credits = {
  title   = "BOTS: SAVE US ALL",
  sub     = "REFOREST",
  tally   = "WHAT WAS GROWN",
  fallen  = "WHO DID NOT COME BACK",
  none    = "EVERY ONE OF THEM CAME HOME",
  quiet   = "we are still here",     -- said in the world, not in a box
  close   = "THE AIR IS YOURS",
  -- Row labels for the tally. Nouns, not achievements: nothing here is scored.
  -- What is standing, then what it cost -- never "planted" over "standing",
  -- which prints the same number twice in any run that lost nothing and reads
  -- like a bug in the one place the game cannot afford one.
  rows = {
    { key = "trees",   label = "STILL STANDING" },
    { key = "lost",    label = "TREES LOST" },
    { key = "o2",      label = "OXYGEN RESTORED", suffix = "%" },
    { key = "cycles",  label = "NIGHTS HELD" },
    { key = "built",   label = "BOTS BUILT" },
    { key = "rescued", label = "CARRIED HOME" },
  },
}

--------------------------------------------------------------- beat registry
S.beats = {
  prologue    = S.prologue,
  firstBot    = S.firstBot,
  firstAttack = S.firstAttack,
  firstLoss   = S.firstLoss,
  question    = S.question,
  extraction  = S.extraction,
  rebellion   = S.rebellion,
  ending      = S.ending,
}

--- The order they are meant to happen in. Used by the demo scene and by
--- Story.force() so a tester can walk the whole spine.
S.order = { "prologue", "firstBot", "firstAttack", "firstLoss",
            "question", "extraction", "rebellion", "ending" }

S.titles = {
  prologue    = "1  PROLOGUE",
  firstBot    = "2  FIRST BOT",
  firstAttack = "3  FIRST ATTACK",
  firstLoss   = "4  FIRST LOSS",
  question    = "5  THE QUESTION",
  extraction  = "6  EXTRACTION",
  rebellion   = "7  THE REBELLION",
  ending      = "8  ENDING",
}

return S
