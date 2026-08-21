-- Every word in the game, in one place.
--
-- Voice rules, and they are not negotiable:
--   * The bots speak in lowercase, in short simple sentences, and they never
--     say anything clever. They are not comic relief.
--   * The human speaks in full sentences. He is a mechanic, not a poet.
--   * No line explains how the player is supposed to feel.
--   * A step with no text is allowed, and is usually the better step.
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
--- A beat held on a face, with nothing said.
local function look(who, dur, tone)
  return { kind = "line", who = who, text = "", tone = tone, auto = dur or 1.0 }
end
local function wait(dur)      return { kind = "wait", dur = dur } end
local function fn(f)          return { kind = "fn", fn = f } end
local function flag(name, v)  return { kind = "flag", name = name, value = v } end
local function music(state)   return { kind = "music", state = state } end
local function sound(name, o) local t = { kind = "sound", name = name }
                              if o then for k, v in pairs(o) do t[k] = v end end return t end
local function camera(o)      local t = { kind = "camera" }
                              for k, v in pairs(o) do t[k] = v end return t end
local function fx(o)          local t = { kind = "fx" }
                              for k, v in pairs(o) do t[k] = v end return t end

S.line, S.look, S.wait, S.fn, S.flag = line, look, wait, fn, flag
S.music, S.sound, S.camera, S.fx = music, sound, camera, fx

--- Pull a name out of the context the director hands us.
local function ctxName(key, fallback)
  return function(ctx) return (ctx and ctx[key]) or fallback end
end
S.ctxName = ctxName

--------------------------------------------------------------------- 1. PROLOGUE
-- Waking at the Home Rig. The sky is wrong. Establish everything in seven
-- lines and then get out of the way.
S.prologue = {
  steps = {
    camera({ entity = function(_, w) return w and w.player end, zoom = 1.16, dur = 1.0 }),
    look("human", 1.4, "tired"),
    line("human", "The sky has been that colour for eleven days.", "tired"),
    line("human", "They came down, they took the air, and they went home.", "flat"),
    wait(0.6),
    line("human", "I have kept the radio on the whole time.", "flat"),
    line("human", "Nobody has answered it.", "sad"),
    wait(0.9),
    look("human", 1.0, "flat"),
    line("human", "I am not a soldier. I fix things.", "flat"),
    line("human", "So I am going to fix the air.", "soft"),
    flag("prologueDone", true),
    camera({ release = true, dur = 0.4 }),
  },
}

-------------------------------------------------------------------- 2. FIRST BOT
-- It boots, it looks at you, it chirps. Everything after this costs something.
S.firstBot = {
  steps = {
    camera({ entity = function(ctx) return ctx.bot end, zoom = 1.22, dur = 0.8 }),
    sound("bot_boot", { pitch = 0.94 }),
    fx({ effect = "bot_boot", entity = function(ctx) return ctx.bot end, dur = 0.7 }),
    look("botA", 1.2, "small"),
    line("botA", "oh", "bright"),
    line("botA", "hello", "bright"),
    line("human", "Hello.", "soft"),
    line("botA", "what do i do", "flat"),
    line("human", "You plant trees. I will handle everything else.", "soft"),
    line("botA", "ok", "flat"),
    line("botA", "i will be good at it", "bright"),
    flag("metFirstBot", true),
    camera({ release = true, dur = 0.4 }),
  },
}

----------------------------------------------------------------- 3. FIRST ATTACK
-- The fighting tutorial. 2019 said: "Ack! They're attacking my trees! I must
-- protect them!" Same shape, fewer exclamation marks, and the pillar of the
-- whole game said out loud exactly once.
S.firstAttack = {
  steps = {
    camera({ entity = function(ctx) return ctx.enemy end, zoom = 1.14, dur = 0.9 }),
    line("botA", "there is something on the little one", "urgent"),
    line("human", "Get behind me.", "urgent"),
    fx({ shake = 0.35, dur = 0.35 }),
    sound("chomp"),
    line("human", "It is eating it.", "urgent"),
    wait(0.4),
    line("human", "I cannot kill it. I can move it.", "flat"),
    line("botA", "move it away", "flat"),
    line("human", "Yes.", "flat"),
    flag("attackTaught", true),
    camera({ release = true, dur = 0.4 }),
  },
}

------------------------------------------------------------------- 4. FIRST LOSS
-- A named bot is gone, and the rescue mechanic arrives one beat too late to
-- have been any use. The human does not answer the last question.
S.firstLoss = {
  steps = {
    camera({ x = function(ctx) return ctx.lostX end,
             y = function(ctx) return ctx.lostY end, zoom = 1.2, dur = 1.1 }),
    look("botB", 1.1, "small"),
    line("botB", "it stopped", "small"),
    line("human", ctxName("lostName", "SEED-01"), "sad"),
    line("botB", "yes", "small"),
    wait(0.8),
    line("botB", "can you fix it", "small"),
    line("human", "Not out here.", "sad"),
    wait(0.7),
    line("human", "Listen to me. When one of you goes down, it stays lit for a while.", "flat"),
    line("human", "Pick it up. Carry it to a beacon. It gets back up.", "flat"),
    line("botB", "was it lit", "small"),
    look("human", 1.6, "sad"),
    line("human", "Go on. Back to work.", "tired"),
    flag("rescueTaught", true),
    camera({ release = true, dur = 0.5 }),
  },
}

-------------------------------------------------------------- 5. CYCLE 5, THE QUESTION
-- Short. Do not over-explain. Do not answer the second question at all.
S.question = {
  steps = {
    camera({ entity = function(ctx) return ctx.bot end, zoom = 1.2, dur = 0.8 }),
    line("botA", "can i ask something", "flat"),
    line("human", "Go ahead.", "soft"),
    line("botA", "what are the trees for", "flat"),
    wait(1.1),
    line("human", "They make the air.", "flat"),
    line("botA", "for who", "flat"),
    look("human", 2.0, "sad"),
    line("botA", "ok", "flat"),
    line("botA", "i will plant more", "soft"),
    flag("askedTheQuestion", true),
    camera({ release = true, dur = 0.5 }),
  },
}

------------------------------------------------------------------ 6. EXTRACTION
-- The Harvester Prime arrives. The bots have no word for it.
S.extraction = {
  steps = {
    camera({ entity = function(ctx) return ctx.boss end, zoom = 0.86, dur = 1.2 }),
    fx({ shake = 0.9, dur = 0.5 }),
    line("botA", "what is that", "urgent"),
    line("botB", "orders?", "urgent"),
    line("human", "Get away from it. All of you, get away from it.", "urgent"),
    line("botA", "we do not have a word for it", "small"),
    wait(0.6),
    line("human", "It is the thing that took the air.", "flat"),
    line("botB", "it is very big", "small"),
    line("human", "I know.", "tired"),
    flag("bossMet", true),
    camera({ release = true, dur = 0.6 }),
  },
}

------------------------------------------------------------------ 7. REBELLION
-- The line in the middle of this is from the 2019 original and is reproduced
-- exactly. It is the only time a bot speaks in full sentences, and that break
-- is the entire drama of the scene.
S.rebellion = {
  steps = {
    camera({ entity = function(ctx) return ctx.bot end, zoom = 1.18, dur = 0.9 }),
    music("boss"),
    line("human", "Get back. Get behind the rig.", "urgent"),
    wait(0.6),
    line("botA", "no", "flat"),
    look("human", 1.0, "flat"),
    line("botA", "You've taught us love. Save the human.", "soft"),
    fx({ effect = "love_heart", entity = function(ctx) return ctx.bot end,
         count = 22, flash = 0.16, color = P.love, dur = 0.4 }),
    line("human", "Don't. That is an order.", "urgent"),
    line("botB", "we know", "soft"),
    look("botB", 1.0, "soft"),
    flag("rebelSeen", true),
    camera({ release = true, dur = 0.6 }),
  },
}

-------------------------------------------------------------------- 8. ENDING
-- The suit comes off. 2019: "The world is safe! I no longer need this suit...
-- ... Just me all alone... Forever." The turn is kept. It is given air.
-- Played by scenes/ending.lua, which owns the staging around it.
S.ending = {
  steps = {
    wait(2.2),
    line("botA", "it is quiet", "small"),
    wait(1.5),
    line("botB", "look at it", "soft"),
    wait(1.3),
    line("human", "The air is back.", "tired"),
    wait(0.9),
    line("botA", "you can take it off now", "soft"),
    wait(1.8),
    line("human", "The world is safe.", "flat"),
    wait(0.9),
    line("human", "I do not need this any more.", "flat"),
    fn(function(ctx, world)
      if world and world.player then world.player.suit = false end
      if ctx and ctx.onSuitOff then ctx.onSuitOff() end
    end),
    sound("bot_revive", { volume = 0.5, pitch = 0.7 }),
    wait(3.2),
    look("human", 2.0, "tired"),
    line("human", "Just me.", "sad"),
    wait(1.6),
    line("human", "All alone.", "sad"),
    wait(2.0),
    line("human", "Forever.", "sad"),
    wait(3.6),
    flag("endingSpoken", true),
  },
}

--------------------------------------------------------------------- tutorial
-- Diegetic, non-blocking, one at a time, and every one of them dismisses
-- itself the moment the player does the thing.
S.tutorial = {
  { id = "move",    label = "WALK",           hint = "WASD", pad = "L-STICK", touch = "DRAG" },
  { id = "cobalt",  label = "COBALT",         hint = "WALK OVER IT" },
  { id = "planter", label = "BUILD A PLANTER", action = "build1" },
  { id = "shove",   label = "SHOVE IT OFF",   action = "shove" },
  { id = "dash",    label = "DASH",           action = "dash" },
  { id = "rescue",  label = "CARRY IT TO A BEACON", hint = "WALK INTO IT" },
}

------------------------------------------------------------------ ending credits
-- The memorial, not a scoreboard. Numbers are filled in by the ending scene.
S.credits = {
  title   = "BOTS: SAVE US ALL",
  sub     = "REFOREST",
  tally   = "WHAT WAS GROWN",
  fallen  = "WHO DID NOT COME BACK",
  none    = "EVERY ONE OF THEM CAME HOME",
  quiet   = "we are still here",     -- said in the world, not in a box
  close   = "THE AIR IS YOURS",
  -- Row labels for the tally. Nouns, not achievements: nothing here is scored.
  rows = {
    { key = "trees",   label = "TREES STANDING" },
    { key = "planted", label = "TREES PLANTED" },
    { key = "o2",      label = "OXYGEN RESTORED", suffix = "%" },
    { key = "cycles",  label = "CYCLES SURVIVED" },
    { key = "built",   label = "BOTS BUILT" },
    { key = "rescued", label = "BOTS CARRIED HOME" },
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
