-- Bot identity: names, traits and the chatter that makes losing one hurt.
--
-- Chatter is the most-read text in the game by an enormous margin. A bot talks
-- every 9-26 seconds and there can be forty of them, so a fifteen-line pool is
-- exhausted inside a minute and the bots stop being people and start being a
-- screensaver. The pools below are wide, and every line has to pass three
-- tests before it goes in:
--
--   1. Would a machine that plants trees actually say this?
--   2. Is it worth reading the second time?
--   3. Does it belong to a bot, or is it the writer talking to the player?
--
-- Anything cute fails test 3. Nothing in here explains the theme, admires the
-- forest on the player's behalf, or says the word love. The one line that did
-- ("this is what love is") is gone.
--
-- Lines are also kept out of the cutscenes' way: no ambient line is a line a
-- bot says in a scripted beat, because hearing "it is very big" from a passing
-- harvester an hour before the boss lands spends it.
local U = require("src.core.util")

local N = {}

N.traits = {
  { id = "eager",     label = "EAGER",     tint = 0.10 },
  { id = "careful",   label = "CAREFUL",   tint = -0.05 },
  { id = "dreamy",    label = "DREAMY",    tint = 0.18 },
  { id = "loud",      label = "LOUD",      tint = 0.06 },
  { id = "shy",       label = "SHY",       tint = -0.10 },
  { id = "stubborn",  label = "STUBBORN",  tint = -0.02 },
  { id = "curious",   label = "CURIOUS",   tint = 0.14 },
  { id = "tidy",      label = "TIDY",      tint = 0.02 },
  { id = "anxious",   label = "ANXIOUS",   tint = -0.12 },
  { id = "proud",     label = "PROUD",     tint = 0.08 },
  { id = "gentle",    label = "GENTLE",    tint = 0.12 },
  { id = "restless",  label = "RESTLESS",  tint = 0.04 },
}

-- Keyed by phase so the bots' mood tracks the game's.
N.chatter = {
  -- Daylight. A shift. Most of it is work talk; a little of it is the bot
  -- noticing that somebody else exists.
  day = {
    "good dirt here", "another one in", "it will be tall", "i like this spot",
    "that makes %d", "the ground is warm", "more sun today", "seventeen more",
    "this one is crooked. leaving it.", "growing is slow work",
    "i can smell water", "you were here yesterday", "working",
    "the air tastes better", "roots go further down than you think",
    "i put one behind the rock", "nothing is eating this one",
    "the wind turns at noon", "i am saving this hill",
    "somebody planted here before me", "this one grew overnight",
    "leave the small ones room", "i will do the slope next",
    "my feet are muddy", "it is taller than me now",
    "i counted wrong. starting again.", "shade already",
    "you can rest. i have this.", "we are ahead of yesterday",
    "%d and still going",
  },
  -- Night. Shorter lines, closer together, and nobody says it will be fine.
  night = {
    "lights on", "stay near me", "i hear them", "do not go far",
    "i will hold this line", "something is moving out there",
    "keep the little ones safe", "i am not afraid", "i am a bit afraid",
    "count us when it is light", "they do not like the lamp",
    "i can hold longer than this", "if i stop, keep going",
    "the little ones are covered", "it is coming this way",
    "do not look at it. work.", "we lost the far row", "i am still here",
    "morning is not far",
  },
  hurt = {
    "ow", "still working", "that is fine", "keep going",
    "do not stop for me", "i have a dent", "it did not get the tree",
    "i can still walk",
  },
  -- Said by whoever was standing nearby. Never on the first loss of the run:
  -- the first-loss beat opens on "it stopped" and needs to say it first.
  loss = {
    "where did it go", "it stopped", "i cannot hear them", "we lost one",
    "say the name", "i will finish its row", "put it down gently",
  },
  -- Orders have stopped making sense. None of these is a line from the
  -- extraction beat.
  boss = {
    "i do not understand", "why", "my orders stopped",
    "nothing is telling me what to do", "it is standing on the trees",
    "where is he", "that is not blight", "i am waiting",
  },
  -- On the way past, at a run, once. "get behind us" is the answer to the only
  -- order he ever gave them that they refused.
  rebel = {
    "save the human", "we love you", "go", "we have you",
    "get behind us", "it is our turn", "goodbye",
  },
  -- The oxygen crossed another quarter. The sky line is the prologue's first
  -- sentence, answered.
  grown = {
    "the sky changed colour", "the numbers went up", "it is working",
    "that is a real forest now", "more of it every day",
  },
  -- The player traded daylight for a worse night.
  hold = {
    "more light", "we can finish this row", "it will be a long night",
    "i will work fast", "keep the sun up",
  },
  -- The rig emptied the sky. About a second and a half before the cut.
  failed = {
    "the air is going", "hold on to me", "get to the rig",
    "we can start again", "it is taking it back",
  },
  ending = { "we are still here", "you can take it off now" },
}

--- Deterministic name from the bot type and a serial number.
function N.name(prefix, serial)
  return string.format("%s-%02d", prefix, serial % 100)
end

function N.trait(rng)
  return rng and rng:pick(N.traits) or N.traits[math.random(#N.traits)]
end

function N.line(phase, rng, count)
  local pool = N.chatter[phase] or N.chatter.day
  local s = rng and rng:pick(pool) or pool[math.random(#pool)]
  if s:find("%%d") then s = s:format(count or 0) end
  return s
end

return N
