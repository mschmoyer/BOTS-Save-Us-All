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
--- Never as the first step of a beat -- there is no panel yet to hold, so the
--- first one the player ever sees would be an empty one.
local function look(who, dur, tone)
  return { kind = "line", who = who, text = "", tone = tone, auto = dur or 1.0 }
end
local function wait(dur)      return { kind = "wait", dur = dur } end
local function fn(f)          return { kind = "fn", fn = f } end
local function flag(name, v)  return { kind = "flag", name = name, value = v } end
local function music(state)   return { kind = "music", state = state } end
--- Open or close the letterbox by hand. `bars(0, d)` takes the panel away and
--- leaves the world; it is how the ending buys a silence you can look at.
--- Note that the panel's alpha is driven by the bar amount, so words said
--- while the bars are down are words nobody can read.
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
-- The loneliness is planted here and not spent here: he says what the radio is
-- doing, not what it means. The ending says it.
--
-- "What they left was not worth the trip." is the only setup the Harvester
-- Prime gets, and it is the whole of it. It is a fact when you hear it and a
-- horror when you hear it again. It is phrased away from "They took / They
-- left", because three sentences opening on the same word is a figure, and a
-- man being terse is not performing one.
--
-- No line here announces the plan. He says what he is, once, and the game
-- shows the rest.
S.prologue = {
  steps = {
    camera({ entity = function(_, w) return w and w.player end, zoom = 1.9, dur = 1.0 }),
    line("human", "The sky has been that colour for eleven days.", "tired"),
    line("human", "They took the air and left.", "flat"),
    line("human", "What they left was not worth the trip.", "flat"),
    wait(0.8),
    line("human", "The radio has been on the whole time. Nothing on it.", "flat"),
    wait(1.1),
    line("human", "I fix things.", "flat"),
    wait(1.6),
    camera({ release = true, dur = 0.4 }),
  },
}

-------------------------------------------------------------------- 2. FIRST BOT
-- It boots, it looks at you, it speaks. A man who has not heard a voice in
-- eleven days does not say hello back -- he makes it say the word again, and
-- calls the part good. Everything after this costs something.
--
-- "oh" and "hello" are two characters of typing each, so they are timed rather
-- than prompted: at 40cps a keypress-gated "oh" is a button-mash, and this is
-- the best moment in the game.
--
-- It ends on a question about quantity that he does not answer, because he
-- cannot. That is the first thing it ever asks for itself.
S.firstBot = {
  steps = {
    camera({ entity = function(ctx) return ctx.bot end, zoom = 1.8, dur = 0.8 }),
    sound("bot_boot", { pitch = 0.94 }),
    fx({ effect = "bot_boot", entity = function(ctx) return ctx.bot end, dur = 0.7 }),
    look("botA", 1.2, "small"),
    line("botA", "oh", "bright", { auto = 1.1 }),
    line("botA", "hello", "bright", { auto = 1.1 }),
    wait(0.9),
    line("human", "Say that again.", "flat"),
    line("botA", "hello", "bright"),
    line("human", "Good.", "soft"),
    line("botA", "what do i do", "flat"),
    line("human", "You plant trees. I do the rest.", "soft"),
    line("botA", "ok", "flat"),
    line("botA", "how many", "flat"),
    wait(1.8),
    camera({ release = true, dur = 0.4 }),
  },
}

----------------------------------------------------------------- 3. FIRST ATTACK
-- The fighting tutorial. 2019 said: "Ack! They're attacking my trees! I must
-- protect them!" Same shape, no exclamation marks, and the pillar of the whole
-- game said out loud exactly once. The hint teaches the key; this teaches the
-- rule. It ends on the bot, not on the man -- and on the bot asking after the
-- tree rather than after itself.
S.firstAttack = {
  steps = {
    camera({ entity = function(ctx) return ctx.enemy end, zoom = 1.6, dur = 0.9 }),
    line("botA", "there is something on the little one", "urgent"),
    line("human", "Get behind me.", "urgent"),
    fx({ shake = 0.35, dur = 0.35 }),
    sound("chomp"),
    wait(0.7),
    line("human", "I cannot kill it. I can move it.", "flat"),
    line("botA", "did it get the tree", "small"),
    wait(0.9),
    camera({ release = true, dur = 0.4 }),
  },
}

------------------------------------------------------------------- 4. FIRST LOSS
-- A named bot is gone. The survivor says what it did -- which is the format of
-- the memorial the player will read at the end, taught here, once, in the
-- voice of somebody who was standing next to it.
--
-- The rescue rule arrives one line too late to have been any use, and it
-- arrives as an order and then a number, at a machine that has just asked
-- whether its friend can be fixed. Twenty seconds is T.downedTime; if that
-- moves, this line moves with it.
--
-- "Back to work." and nothing else. The full sentence belongs to the beat
-- where the first bot dies, and this is what makes it land there.
S.firstLoss = {
  steps = {
    camera({ x = function(ctx) return ctx.lostX end,
             y = function(ctx) return ctx.lostY end, zoom = 1.7, dur = 1.1 }),
    look("botB", 1.1, "small"),
    line("botB", "it stopped", "small"),
    line("human", ctxName("lostName", "SEED-01"), "sad"),
    line("botB", "yes", "small"),
    line("botB", ctxName("lostEpitaph", "it was here"), "small"),
    wait(1.0),
    line("botB", "can you fix it", "small"),
    line("human", "Not out here.", "sad"),
    wait(0.9),
    line("human", "If one of you goes down, carry it to a beacon.", "flat"),
    line("human", "It stays lit twenty seconds. After that, no.", "flat"),
    line("botB", "was it lit", "small"),
    wait(2.0),
    line("human", "Back to work.", "tired"),
    camera({ release = true, dur = 0.5 }),
  },
}

------------------------------------------------------ 5. THE QUESTION  (cycle 3)
-- Sixteen words. Do not add a seventeenth. The second question is never
-- answered: the silence after it is the beat, so it is a `wait` and the
-- question stays on the screen through all of it.
--
-- It ends on "ok". The bot does not decide anything here -- it takes the
-- answer, and it goes back to work. What it does with the answer is beat 6,
-- and putting the decision here spends that beat before it exists.
S.question = {
  steps = {
    camera({ entity = function(ctx) return ctx.bot end, zoom = 1.8, dur = 0.8 }),
    wait(1.0),
    line("botA", "what are the trees for", "flat"),
    wait(1.2),
    line("human", "They make the air.", "flat"),
    line("botA", "for who", "flat"),
    wait(2.6),
    line("botA", "ok", "flat"),
    camera({ release = true, dur = 0.5 }),
  },
}

------------------------------------------------------- 6. THE RADIO  (cycle 4)
-- The one beat between "for who" and "i do not use air", and the only thing
-- standing in a measured four-to-six minute silence. It is on the rig's radio,
-- and deliberately NOT on the empty pressure suits: relic.lua's rule for those
-- is "no toast, no tooltip, no codex entry, no achievement and no bot line",
-- and the four of them work for exactly as long as nothing points at one. A
-- scene over an empty suit is also a funeral, three minutes after one funeral
-- and three minutes before another.
--
-- The radio is a fixture -- it is on the rig, the lamp sweeps all run -- so
-- this beat has no geography and cannot starve. It is the prologue's plant
-- touched once in the middle, so that the ending's "Or the radio." has a
-- history rather than being a callback fifteen minutes cold.
--
-- Nobody says what the number counts. The plate on the hull says SIGNALS
-- RECEIVED, the dawn card says NO ANSWER, and the prologue said it in words;
-- a fourth telling is the writer making sure the player got it. He names the
-- part and stops, which is the whole of what he will admit to.
--
-- "it was zero yesterday" is the line the beat exists for. It is offered
-- helpfully, by a machine that does not know what it is reporting, to the one
-- man who does. He does not answer it. What he says instead is a maintenance
-- habit, and the player can count the mornings.
--
-- It ends on him giving it a frequency. A machine cannot offer him company, so
-- it offers him labour; he cannot accept the first and cannot refuse the
-- second, so he hands over a part number and closes the job. "i will listen
-- too" is the same grammar as "i will plant more" two cycles later -- this bot
-- answers every impossible thing by volunteering for more work, and that is
-- what makes the rebellion inevitable rather than sudden.
S.radio = {
  steps = {
    camera({ entity = function(ctx) return ctx.bot end, zoom = 1.8, dur = 0.8 }),
    line("botA", "the number on the rig is zero", "flat"),
    wait(1.6),
    line("human", "That is the radio.", "flat"),
    wait(2.4),
    line("botA", "it was zero yesterday", "flat"),
    wait(3.0),
    line("human", "I check it every morning.", "tired"),
    wait(1.8),
    line("botA", "i will listen too", "small"),
    wait(1.2),
    line("human", "It is on channel nine.", "flat"),
    wait(1.6),
    camera({ release = true, dur = 0.5 }),
  },
}

-------------------------------------------------------- 7. THE ANSWER  (cycle 6)
-- The bot works it out. Not in a speech: by reading its own log back, one
-- clause at a time, the way a machine checks a figure.
--
-- The human's "No." is a confirmation, not a contradiction, and it is the only
-- thing he gives it. He does not soften it and he does not explain it.
--
-- "i will plant more" was the last line of the question beat until it was
-- moved here. It is the same bot making the same decision a second time, now
-- that it knows the thing it is building is not for it. Nothing states that,
-- and nothing may.
--
-- This is also what makes "no" at the rebellion cost something: by then they
-- are not disobeying an order, they are keeping a decision they already made.
S.answer = {
  steps = {
    camera({ entity = function(ctx) return ctx.bot end, zoom = 1.8, dur = 0.8 }),
    line("botA", "i asked what the trees are for", "flat"),
    wait(1.0),
    line("botA", "you said the air", "flat"),
    wait(1.4),
    line("botA", "i do not use air", "small"),
    wait(2.8),
    line("human", "No.", "flat"),
    wait(2.2),
    line("botA", "i will plant more", "soft"),
    camera({ release = true, dur = 0.5 }),
  },
}

--------------------------------------------------------------- 8. THE FIRST ONE
-- The bot from beat 2 is gone. Without this it goes in the toast feed with
-- every other one, and the only long relationship in the game ends as a line
-- of scrolling text.
--
-- "that was the first one you made" and not "that was the first one": by this
-- point the player has watched thirty machines stop, and the short form parses
-- as the first of tonight's. Five words, and it is a bot stating a fact about
-- the man, which is how these machines look at him everywhere else.
--
-- "Go on. Back to work." is verbatim from the first loss, where it is trimmed
-- to its second half. The repetition is the beat: the second time it is all he
-- has, and the player hears that there is nothing else. He gets no new line
-- here, and must not be given one. The two silences around it are the length
-- of the beat -- it is the only long relationship in the game ending, and four
-- seconds of screen time was not enough to be one.
S.firstBotLost = {
  steps = {
    camera({ x = function(ctx) return ctx.lostX end,
             y = function(ctx) return ctx.lostY end, zoom = 1.7, dur = 1.1 }),
    line("botB", "that was the first one you made", "small"),
    wait(2.8),
    line("human", "Go on. Back to work.", "tired"),
    wait(1.6),
    camera({ release = true, dur = 0.5 }),
  },
}

------------------------------------------------------------------ 9. EXTRACTION
-- The Harvester Prime arrives. What he says is what it is doing, because from
-- this moment the oxygen bar is a countdown and the player has to know that.
--
-- The bots have no category for it, so one of them reaches for the only
-- category it has, and the other applies the rule he taught it in beat 3 to a
-- thing the rule does not fit. "I know." is a man agreeing that his own rule
-- has run out.
--
-- "is it one of ours" is answered with what the thing is DOING and not with a
-- "No.", which is a better answer and leaves the word belonging to one beat in
-- the game -- the one two minutes earlier where it carried a whole scene.
S.extraction = {
  steps = {
    camera({ entity = function(ctx) return ctx.boss end, zoom = 0.86, dur = 1.2 }),
    fx({ shake = 0.9, dur = 0.5 }),
    line("botA", "what is that", "urgent"),
    line("botB", "what do we do", "urgent"),
    line("human", "Get away from it. All of you.", "urgent"),
    wait(0.5),
    line("botA", "is it one of ours", "small"),
    wait(0.6),
    line("human", "It is taking the air back.", "flat"),
    line("botB", "we cannot move that one", "small"),
    line("human", "I know.", "tired"),
    camera({ release = true, dur = 0.6 }),
  },
}

----------------------------------------------------------------- 10. REBELLION
-- The line in the middle of this is from the 2019 original and is reproduced
-- exactly. It is the only time a bot speaks in full sentences, with capital
-- letters and a full stop, and that break is the entire drama of the scene.
--
-- His order is the one they obeyed the first time, word for word, in beat 3.
-- That is what "no" is refusing. The bots running past say "get behind us",
-- which is the same sentence turned around.
--
-- "Don't. That is an order." is the ONLY contraction the human uses in the
-- whole game. It is his composure going. It is not a typo. Do not repair it.
--
-- Nothing is added after "we know". The cohorts leaving is the rest of it, and
-- that is said in the world, in speech bubbles, by bots on their way past.
S.rebellion = {
  steps = {
    camera({ entity = function(ctx) return ctx.bot end, zoom = 1.6, dur = 0.9 }),
    music("boss"),
    line("human", "Get behind me.", "urgent"),
    wait(0.6),
    line("botA", "no", "flat"),
    wait(1.1),
    line("botA", "You've taught us love. Save the human.", "soft"),
    fx({ effect = "love_heart", entity = function(ctx) return ctx.bot end,
         count = 22, flash = 0.16, color = P.love, dur = 0.4 }),
    line("human", "Don't. That is an order.", "urgent"),
    line("botB", "we know", "soft"),
    wait(1.4),
    camera({ release = true, dur = 0.6 }),
  },
}

-------------------------------------------------------------------- 11. ENDING
-- The product.
--
-- 2019: "The world is safe! I no longer need this suit... ... Just me all
-- alone... Forever." Every beat of that turn is kept. What is added is the
-- radio -- planted in the prologue, drawn on the helmet in every line he has
-- ever spoken, and switched off here. He gives up the suit and the only thing
-- that could ever have answered him in the same breath.
--
-- He opens with the job, not with a reading. The meter on the HUD has been
-- climbing for fifteen minutes and the player can see where it got to; a
-- number said out loud here can only disagree with it. He cracks the seal, he
-- checks that it holds, and the bot gives him permission he did not ask for.
--
-- The silence in the middle is not a pause. The panel is taken away for it, so
-- there is nothing on the screen but a man with his helmet off in a forest
-- full of machines that are looking at him. A bot says the one thing that
-- could contradict what he is about to say. He says it anyway.
--
-- The bars come back for the turn because the panel is how the words are
-- readable at all -- its alpha follows the bar. The camera has to clear the
-- ring instead; scenes/ending.lua owns that.
--
-- Played by scenes/ending.lua, which owns the staging around it.
S.ending = {
  steps = {
    wait(2.6),
    line("human", "Cracking the seal.", "flat", { auto = 2.2 }),
    wait(1.4),
    line("human", "It holds.", "flat", { auto = 2.0 }),
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
  },
}

------------------------------------------------------------------------ barks
-- Said in the world, in a speech bubble, not in a panel. There is one, and it
-- is the only thing he ever says about a rescue.
--
-- The player carries a downed machine to a beacon and it stands up: the game
-- answers that with a toast reading BACK ON ITS FEET, and nothing else. This
-- is the word he gave the first bot in beat 2 for saying hello. He does not
-- have another one, and by now the player knows that.
--
-- Once a run, on the first machine the PLAYER carried -- `bot.savedBy` is
-- "player" only then; a beacon reviving one on its own is not a thing he
-- watched anybody do. Not a beat: a letterbox, a portrait and a held silence
-- for four characters would be the game stopping itself to be pleased, which
-- is the opposite of the line. See S.credits.quiet, which is spoken the same
-- way.
S.bark = {
  rescued = "Good.",
}

-------------------------------------------------------------------------- hud
-- Words the interface says for itself. There is only one of them, because
-- there is only one standing offer in the game: the dawn. It is written here
-- with its numbers left blank -- how much day it buys and how much worse the
-- night gets are tuning's business, not the script's.
S.hud = {
  holdLabel = "HOLD THE DAWN",
  holdBuy   = "+%dS OF DAY",
  holdCost  = "%d%% HEAVIER NIGHT",
  holdTaken = "DAWN HELD",
  -- the confirmation reuses the offer's own word for the price, so the toast
  -- reads as the receipt for the number they just agreed to
  holdAfter = "A HEAVIER NIGHT",
  -- The day's opposition announces itself. Without this a Scar is a dot on the
  -- minimap that the player never learns is the reason the night started in the
  -- middle of their wood.
  scarRooted  = "BLIGHT TOOK ROOT",
  scarWhere   = "THE NIGHT WILL START HERE",
  scarSpread  = "IT SPREAD",
  scarCleared = "GROUND RECLAIMED",

  -- The oxygen milestones. The meter used to celebrate identically at 25, 50,
  -- 75 and 100 -- four rounds of ATMOSPHERE RISING -- which trains the player
  -- that filling it is unambiguously good, and the meter is the summoning
  -- circle: world.lua begins the extraction the moment the air is breathable.
  -- So the top two turn. Same colour, same furniture, same chime; only the
  -- words change, and they change into a fact about how far a sky can be seen
  -- rather than into a warning. Nobody says who is looking.
  o2Rising  = "ATMOSPHERE RISING",
  o2AtRange = "VISIBLE AT RANGE",
  o2Orbit   = "VISIBLE FROM ORBIT",
  -- The last night has a name instead of a denominator. "CYCLE 7 OF 7" is a
  -- fraction, and the game never tells the player what is on the other side of
  -- seven; this at least tells them there is no eighth.
  lastNight = "THE LAST NIGHT",
}

------------------------------------------------------------------------ dawn
-- The dawn screen, and the rig.
--
-- One thread, said twice, in the two places the player will actually be
-- standing: a row on the dawn card and a plate on the hull. The wording never
-- changes and the number never changes. Nothing in the game remarks on either
-- of them, and the ending's "Or the radio." switches the lamp off without
-- naming what it is switching off.
--
-- Do not make any of this emotive. Its whole power is that the player reads it
-- twice, stops reading it, and remembers at the end that they stopped.
S.dawn = {
  radio    = "RADIO",
  noAnswer = "NO ANSWER",
  day      = "DAY %d",          -- 11 + cycle: the prologue's eleven days, kept
  signals  = "SIGNALS RECEIVED",
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
  -- HOLD THE DAWN was a step here and is not one any more. A decision the
  -- player makes every cycle cannot be taught by a hint that shows twice and
  -- then never again: it lives in the HUD now, for as long as the offer is
  -- open. See S.hud above and game/hud.lua's drawHoldOffer.
  { id = "shove",   label = "SHOVE IT OFF",    action = "shove" },
  { id = "dash",    label = "GET OUT OF THE WAY", action = "dash" },
  { id = "rescue",  label = "IT IS STILL LIT", action = nil, hint = "CARRY IT TO A BEACON" },
  -- The back half of the tutorial. Six things the player had to work out from
  -- an icon and a number, spread across the middle cycles so the run keeps
  -- teaching after the first three minutes instead of going quiet for eight.
  { id = "pulse",     label = "TOO MANY OF THEM",  action = "pulse",
    hint = "HOLD IT, THEN LET GO" },
  { id = "handplant", label = "PUT ONE HERE",      action = "plant",
    hint = "FREE. ONLY THE OUTER TREES SEED." },
  { id = "harvester", label = "SEND IT MINING",    action = "build5",
    hint = "IT BRINGS COBALT HOME WHILE YOU FIGHT" },
  { id = "builder",   label = "IT PLANTS PLANTERS", action = "build2",
    hint = "OUT OF COBALT IT FINDS, NOT YOURS" },
  { id = "beacon",    label = "SOMEWHERE TO CARRY THEM", action = "build6",
    hint = "THE DOWNED WAKE UP INSIDE ITS LIGHT" },
  { id = "sentry",    label = "IT WILL HOLD THIS ROW", action = "build4",
    hint = "STATIC. IT SHOOTS WHAT COMES." },
}

------------------------------------------------------------------ ending credits
-- A memorial, not a scoreboard. Two rules make the difference:
--   * the fallen are listed in the order they died, not sorted -- a sorted
--     list is an inventory, and groups them by model number
--   * every name carries what that bot actually did, in its own voice
--
-- There is no closing line. The last thing in the game is the last name, or
-- the word under the header when there are none.
S.credits = {
  title   = "BOTS: SAVE US ALL",
  sub     = "REFOREST",
  tally   = "WHAT WAS GROWN",
  fallen  = "WHO DID NOT COME BACK",
  none    = "NONE",
  quiet   = "we are here",           -- said in the world, not in a box
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
    -- A COUNT OF TRIPS, NOT OF MACHINES. `stats.rescued` counts rescue events:
    -- one machine you went out for four times is four. Under BOTS BUILT 65 a
    -- row reading CARRIED HOME 73 is a subset larger than its set, which on
    -- this page reads as a bug rather than as a fact. The label says what the
    -- number counts, and the count is the one worth having -- it is the number
    -- of times the player put the work down and walked out for one of them.
    { key = "rescued", label = "TIMES YOU CARRIED ONE HOME" },
    -- The last line of the tally is the one the game is about: the rig came
    -- down mostly because they walked into it, and the number says how much.
    -- Named in full, because it sits under OXYGEN RESTORED 84% and "THEY
    -- BROUGHT DOWN 91%" is the one row where the reader has to guess what the
    -- second percentage is a percentage of.
    { key = "theirs",  label = "THEY BROUGHT THE RIG DOWN", suffix = "%" },
  },
}

--------------------------------------------------------------- beat registry
S.beats = {
  prologue     = S.prologue,
  firstBot     = S.firstBot,
  firstAttack  = S.firstAttack,
  firstLoss    = S.firstLoss,
  question     = S.question,
  radio        = S.radio,
  answer       = S.answer,
  firstBotLost = S.firstBotLost,
  extraction   = S.extraction,
  rebellion    = S.rebellion,
  ending       = S.ending,
}

--- The order they are meant to happen in. Used by the demo scene and by
--- Story.force() so a tester can walk the whole spine.
---
--- `firstBotLost` is the one that is not on a clock: it fires whenever the bot
--- from beat 2 dies, which can be any time after the first loss. It sits here
--- where it usually lands.
---
--- `radio` is the middle of the spine and is deliberately between the question
--- and the answer: it is the same machine on the cycle after it asked, and it
--- must never play after the answer has. story.lua holds it behind
--- `Story.fired.question` and drops it once `Story.fired.answer` is set.
S.order = { "prologue", "firstBot", "firstAttack", "firstLoss",
            "question", "radio", "answer", "firstBotLost",
            "extraction", "rebellion", "ending" }

S.titles = {
  prologue     = "1  PROLOGUE",
  firstBot     = "2  FIRST BOT",
  firstAttack  = "3  FIRST ATTACK",
  firstLoss    = "4  FIRST LOSS",
  question     = "5  THE QUESTION",
  radio        = "6  THE RADIO",
  answer       = "7  THE ANSWER",
  firstBotLost = "8  THE FIRST ONE",
  extraction   = "9  EXTRACTION",
  rebellion    = "10  THE REBELLION",
  ending       = "11  ENDING",
}

return S
