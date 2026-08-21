-- Bot identity: names, traits and the chatter that makes losing one hurt.
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

-- Chatter is keyed by phase so the bots' mood tracks the game's.
N.chatter = {
  day = {
    "good dirt here", "another one down", "it will be tall", "i like this spot",
    "counting: %d", "the ground is warm", "more sun today", "seventeen more",
    "this one is crooked. leaving it.", "growing is slow work", "i can smell water",
    "you were here yesterday", "hello", "working", "the air tastes better",
  },
  night = {
    "lights on", "stay near me", "i hear them", "it is very dark",
    "do not go far", "i will hold this line", "they are coming from the east",
    "keep the little ones safe", "i am not afraid", "i am a bit afraid",
  },
  hurt = { "ow", "still working", "that is fine", "i am fine", "keep going" },
  loss = { "where did it go", "it stopped", "i cannot hear them", "we lost one" },
  boss = { "what is that", "orders?", "i do not understand", "why", "it is very big" },
  rebel = { "save the human", "we love you", "go", "we have you", "this is what love is" },
  ending = { "it is quiet", "you can take it off now", "we are still here", "look at it" },
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
