-- Bot identity: names, traits and the chatter that makes losing one hurt.
--
-- Chatter is the most-read text in the game by an enormous margin. A bot talks
-- every 9-26 seconds and there can be forty of them, so a fifteen-line pool is
-- exhausted inside a minute and the bots stop being people and start being a
-- screensaver. The pools below are wide, and every line has to pass three
-- tests before it goes in:
--
--   1. Would a machine that plants trees actually say this?
--   2. Is it worth reading the TWENTIETH time? Not the second -- measured, the
--      shared day pool is drawn about a hundred and twenty times a day and
--      cycles three times a phase, so a run reads every line in it twenty-odd
--      times. Flat reports survive that. Anything with a turn in it dies on
--      the fifth reading and grates by the tenth, which is why a wistful line,
--      a brave line and a funny line have all been cut from here since.
--   3. Does it belong to a bot, or is it the writer talking to the player?
--
-- Anything cute fails test 3. Nothing in here explains the theme, admires the
-- forest on the player's behalf, or says the word love. The one line that did
-- ("this is what love is") is gone. So is "we love you", which said it again.
--
-- Lines are also kept out of the cutscenes' way: no ambient line is a line a
-- bot says in a scripted beat, because hearing "it is very big" from a passing
-- harvester an hour before the boss lands spends it. "save the human" was in
-- the rebellion pool and is not any more: the first cohort launches in the same
-- tick the beat is queued, so it could -- and did -- reach the screen before
-- the cutscene said it.

local N = {}

------------------------------------------------------------------------ traits
-- Traits are SPEECH BEHAVIOURS, not moods. Twelve moods produce twelve
-- synonyms; six behaviours produce six grammars, and a grammar is audible in
-- ten seconds. A machine that only reports numbers, standing next to one that
-- only asks questions, is two people. Twelve adjectives sharing one pool are
-- one person twelve times -- which is what this was before.
--
-- `tint` is not read by anything yet. It is left here as the hook for per-bot
-- rendering rather than deleted, so whoever adds that has one number per
-- personality to reach for; if that never lands, delete the field.
N.traits = {
  { id = "counter", label = "COUNTER", tint =  0.02 },  -- reports numbers
  { id = "watcher", label = "WATCHER", tint =  0.14 },  -- reports what it sees
  { id = "quiet",   label = "QUIET",   tint = -0.10 },  -- one to three words
  { id = "fusser",  label = "FUSSER",  tint = -0.02 },  -- judges the work
  { id = "worrier", label = "WORRIER", tint = -0.12 },  -- only questions
  { id = "stayer",  label = "STAYER",  tint =  0.10 },  -- will not stop
}

-- Keyed by phase so the bots' mood tracks the game's.
N.chatter = {
  -- Daylight. A shift. Most of it is work talk; a little of it is the bot
  -- noticing that somebody else exists. "you were here yesterday" was the model
  -- for this pool and now lives in `watcher`, where one kind of machine owns it.
  day = {
    "good dirt here", "another one in", "it will be tall", "i like this spot",
    "the ground is warm", "more sun today", "this row is not done",
    "i will come back to this one", "the seed did not take",
    "most of it is under the ground", "i put one behind the rock",
    "i will need more seed", "i am saving this hill",
    "somebody planted here before me", "this one grew overnight",
    "i will do the slope next", "i have been standing here too long",
    "it is taller than me now", "we are ahead of yesterday",
    "the rig is that way", "i marked this one", "there is room past the rocks",
    "the old row is still standing", "this one is dead. taking it out.",
    "nothing came here last night", "there are rocks under this",
    "one of the old ones fell over", "i am on the second row",
  },
  -- Night. Shorter lines, closer together, and nobody says it will be fine --
  -- which "morning is not far" did, so it is gone. Two lines about "the little
  -- ones" were cut with it: the register was worn through at five uses across
  -- this pool, `fusser` and `counter`, and "i am between it and the tree" is
  -- what the other two were trying to be.
  night = {
    "lights on", "stay near me", "i hear them", "do not go far",
    "count us when it is light", "they do not like the lamp",
    -- "if i stop, keep going" was here. "Go on without me" is the most worn
    -- line in this genre, and the header above already records a wistful, a
    -- brave and a funny line being cut -- this was the brave one that got
    -- through. `hurt` keeps "do not stop for me", which is the same idea about
    -- the present moment rather than a farewell, and is the better one.
    "the little ones are covered",
    "it is coming this way", "do not look at it. work.",
    "we lost the far row", "i am still here", "i cannot see you",
    "the lamp is holding", "i cannot see the north row", "one got past me",
    "stand in the light", "who is on the east row",
    "i am between it and the tree", "say something", "i lost it in the trees",
    "it is quiet on this side", "the north lamp is nearest",
    "i am coming to you",
  },
  -- The seventh night, and only the seventh. The dial has said THE LAST NIGHT
  -- for a minute, forty machines are out in it, and until this pool existed the
  -- ambient script was byte-identical to cycle one's. Wired the way `radio` is:
  -- one small pool, gated on story state, displacing part of a shared pool for
  -- the rest of the run. story.lua raises N.lastNight at the last dusk.
  --
  -- Nothing in here knows what happens after, and nothing in here is told. "and
  -- then what" is "for who" a second time, from a different machine, and it is
  -- never answered either. "we counted seven" is the only line in the file that
  -- names a tuning constant -- tools/poolcheck.lua fails if it stops matching
  -- T.cycle.count.
  lastnight = {
    "one more night", "we counted seven", "everyone is out tonight",
    "i was here for the first one", "and then what",
  },
  -- First light, and the thing the night pool asked for. "count us when it is
  -- light" is a request nobody ever fulfilled; this is the answer to it, and
  -- "who is missing" goes unanswered in its turn.
  dawn = {
    "count us", "%d", "everyone stand up", "who is missing",
    "the lamps can go off",
  },
  -- Said at first light, by one machine, and ONLY after the radio beat has
  -- played -- see story.lua's phase:dawn handler. Before that beat the rig's
  -- readout is furniture the player walks past; after it there is somebody else
  -- on the island who checks it every morning too, and says so, and the number
  -- never changes. Nothing in here remarks on that, and nothing in here is
  -- sad about it. It is a shift report.
  --
  -- This is the thread that carries cycles 4 to 7. Not another cutscene: one
  -- line, once a dawn, for the rest of the run, so that "Or the radio." at the
  -- end lands on a player who has heard a machine say it four times.
  radio = {
    "still zero", "i listened all night", "nothing on nine",
    "i will check again",
  },
  -- Its own damage. Reports of condition, never complaints, and the best of
  -- them report the tree instead of the machine.
  hurt = {
    "something broke", "still working", "that is fine", "keep going",
    "do not stop for me", "my arm is slow now", "it did not get the tree",
    "i can still walk", "i am at half", "i can finish the row", "again",
    "do not carry me yet",
  },
  -- Said by whoever was standing nearby. Never on the first loss of the run:
  -- the first-loss beat opens on "it stopped" and needs to say it first, so
  -- that line is not in here.
  --
  -- %s is the name of the bot that just went down -- see N.remember. It is the
  -- whole of what this pool does with a name: the instruction that used to sit
  -- next to it ("say the name") read as a ritual somebody invented rather than
  -- as a machine reacting, and the %s line does the job without being asked.
  loss = {
    "where did it go", "it will not get up", "i cannot hear them",
    "we lost one", "i will finish its row",
    "put it down gently", "%s was on this row", "who was standing with it",
    "i was too far", "do not step there", "it is not lit any more",
  },
  -- The human is on the ground and the reboot clock is running. Forty machines
  -- stood around watching this in silence before there was a pool for it.
  downed = {
    "get up", "he is not moving", "stand over him", "i cannot carry him",
    "someone go to the rig", "we are still working",
  },
  -- Said by the machine in your arms, not by a bystander. "am i still lit"
  -- is the human's own word out of the first-loss beat, twenty minutes later,
  -- from something that heard him say it.
  carried = {
    "am i still lit", "put me by the light", "i am heavy", "which way",
    "i can walk soon", "do not run",
  },
  -- It woke up in the light. Said by the one that stood back up.
  saved = {
    "i am up", "you came back", "the light did it", "i can work now",
    "i will stay near you",
  },
  -- Orders have stopped making sense. None of these is a line from the
  -- extraction beat.
  boss = {
    "why", "my orders stopped", "where do i stand",
    "it is standing on the trees", "where is he", "that is not blight",
    "i am waiting", "it does not stop", "the north rows are gone",
  },
  -- On the way past, at a run, once. "get behind us" is the answer to the only
  -- order he ever gave them that they refused. The line this pool is a
  -- rehearsal for is said in the cutscene and only there.
  rebel = {
    "go", "we have you", "get behind us", "stay there", "we are closer",
    "we are going",
  },
  -- Not crew. Every machine that was working somewhere else on the island when
  -- the rebellion started, walking in off the treeline. World:speak drops a
  -- bot's previous bubble for its next one, so this arrives in place of the
  -- `rebel` line rather than on top of it. Nobody in here is glad to be here
  -- and nobody says what they came for: they say what they left.
  reinforce = {
    "i was down by the water", "i was on the far side", "i left the row",
    "more behind me",
  },
  -- The oxygen crossed another quarter. The sky line is the prologue's first
  -- sentence, answered. Nothing in here admires it.
  grown = {
    "the sky changed colour", "the numbers went up",
    "i cannot count them any more", "i cannot see the water from here",
  },
  -- The player traded daylight for a worse night.
  hold = {
    "more light", "we can finish this row", "i will not stop at dark",
    "i will work fast", "the night will be longer",
  },
  -- The rig emptied the sky. About a second and a half before the cut, and
  -- nobody in here promises a next time.
  failed = {
    "the air is going", "hold on to me", "get to the rig",
    "i am still holding one",
  },
}

--------------------------------------------------------------- trait grammars
-- A trait's private lines, and nobody else's. Only the two long phases have
-- them: day and night are where the player hears the same pool for ten minutes
-- and where a personality has room to register. Everything else -- a death, a
-- hit, the boss -- is a short, loud pool that every machine draws from flat,
-- because a bot that only asks questions still has to be able to say "i was
-- too far".
N.traitLines = {
  counter = {
    day = { "%d", "that makes %d", "i counted wrong. starting again.",
            "i counted them again", "i will count again at noon",
            "the number is right" },
    night = { "%d", "%d standing", "i counted us", "we were more this morning",
              "i cannot count in the dark" },
  },
  watcher = {
    day = { "you were here yesterday", "nothing is eating this one",
            "somebody walked through the north row",
            "there is a hole in the far row", "the blight edge moved",
            "you have not been to the hill" },
    night = { "something is moving out there", "the far lamp went out",
              "they are by the water", "it is not coming this way",
              "there is light at the rig" },
  },
  quiet = {
    day = { "working", "shade already", "here", "one more", "done", "growing" },
    night = { "lit", "awake", "hold", "it moved", "cold" },
  },
  fusser = {
    day = { "this one is crooked. leaving it.", "leave the small ones room",
            "the ground is soft on this side", "somebody planted these too close",
            "this hole is not deep enough", "i will straighten it tomorrow" },
    night = { "the row is not straight any more", "they trampled the edge",
              "i will fix this in the light", "this is not how i left it",
              "do not stand on the new ones" },
  },
  worrier = {
    day = { "is this the right row", "will it be enough",
            "should i be somewhere else", "did somebody count these",
            "is he coming back", "how deep should it be" },
    night = { "how long is left", "where is everyone", "is it still out there",
              "did anything get through", "is the lamp still on" },
  },
  -- Rebuilt. Five of its ten lines used to contain *stop* or *hold*, which is
  -- a synonym list and not a grammar -- the exact failure the six-trait
  -- redesign exists to escape. Stubbornness has kinds: refusing help, refusing
  -- shelter, claiming ground, staying latest. "i am the last one out here" and
  -- "nobody else needs to come out here" are stubbornness expressed as
  -- logistics, which is what a machine has instead of pride.
  stayer = {
    day = { "this row is mine", "i will finish before dark",
            "i can do the whole slope", "give me the far side",
            "nobody else needs to come out here" },
    -- "i do not want to stop" was here, and it broke this pool's own rule two
    -- comments up: stubbornness is expressed as LOGISTICS, which is what a
    -- machine has instead of pride. Its four siblings all obey that. Stating a
    -- want is the one thing the voice rules say has to come out of behaviour.
    night = { "i will hold this line", "not yet",
              "i am not going in", "i am the last one out here",
              "somebody has to be on this side" },
  },
}

---------------------------------------------------------------- story overlay
-- A bot draws its idle line from the world's PHASE, in bot.lua's update loop,
-- because the phase is all a machine standing in a field knows. Two things
-- that change what it should be saying are not phases, so they are raised here
-- by story.lua and by nothing else.
--
--   extraction  The rig is on the island. bot.lua maps anything that is not
--               night to `day`, so the `boss` pool -- written for exactly this
--               -- was only ever heard from the two or three `boss:phase`
--               signals, while "good dirt here" played over the climax. Only
--               the machines still in `work` get mood = "confused"; every one
--               that has rebelled falls back through here.
--   lastNight   Cycle T.cycle.count's dusk and night. See `lastnight` above.
N.extraction = false
N.lastNight  = false

-- One night line in three comes out of `lastnight` instead of the shared pool.
-- Not more: the last night still has to sound like a night, and five lines at
-- a third of a hundred and twenty draws is already about five readings each.
local LASTNIGHT_SHARE = 0.34

-- How often a bot with a private pool reaches for it. Low enough that the
-- shared pool still carries the phase, high enough that a counter has said
-- three numbers before you have walked past it twice.
local TRAIT_SHARE = 0.35

--- Deterministic name from the bot type and a serial number.
function N.name(prefix, serial)
  return string.format("%s-%02d", prefix, serial % 100)
end

function N.trait(rng)
  return rng and rng:pick(N.traits) or N.traits[math.random(#N.traits)]
end

--- The name of the last bot to go down, for the `loss` pool's %s. It is a fact
--- about the world rather than an argument, so it is remembered here: the call
--- site that has the name (the director) is not the one that speaks the line
--- (a bot standing nearby).
N.lastLost = nil
function N.remember(name) N.lastLost = name end

--- A line from `phase`'s pool. A trait does not get a *slice* of the shared
--- pool any more -- that produced twelve vocabularies that differed by one
--- sentence in sixteen, and three pairs at night that were byte-identical. It
--- gets its own handful of lines and reaches for them about a third of the
--- time, so what separates two bots is how they talk, not which fifteen of the
--- same thirty sentences they happen to own.
function N.line(phase, rng, count, trait)
  -- Both overlays are applied to the pool NAME, before the trait lookup, so a
  -- caller that already knows better ("boss" from bot.lua's confused mood, or a
  -- fixed bot.lua) passes straight through unchanged.
  if phase == "day" and N.extraction then phase = "boss" end
  local pool = N.chatter[phase] or N.chatter.day
  local s
  local own = trait and N.traitLines[trait.id]
  own = own and own[phase]
  if own and #own > 0 then
    -- spelled out, not `rng and rng:chance(x) or ...`: that idiom falls through
    -- to the fallback every time chance() answers false, which quietly doubled
    -- the trait rate and took the draw off the bot's own rng.
    local roll
    if rng then roll = rng:chance(TRAIT_SHARE) else roll = math.random() < TRAIT_SHARE end
    if roll then s = rng and rng:pick(own) or own[math.random(#own)] end
  end
  -- ...and if the trait did not answer, the last night takes a third of what is
  -- left. Deliberately after the trait draw and not before it: a stayer is
  -- still a stayer on the seventh night, and the pool this displaces is the
  -- shared one.
  if not s and phase == "night" and N.lastNight then
    local ln = N.chatter.lastnight
    local roll
    if rng then roll = rng:chance(LASTNIGHT_SHARE) else roll = math.random() < LASTNIGHT_SHARE end
    if roll and ln and #ln > 0 then s = rng and rng:pick(ln) or ln[math.random(#ln)] end
  end
  s = s or (rng and rng:pick(pool) or pool[math.random(#pool)])
  if s:find("%%d") then
    local n = tostring(count or 0)
    s = s:gsub("%%d", function() return n end)
  end
  if s:find("%%s") then
    local who = N.lastLost or "one of us"
    s = s:gsub("%%s", function() return who end)
  end
  return s
end

return N
