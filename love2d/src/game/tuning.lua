-- Every gameplay constant in the game. Behaviour code must not contain magic numbers.
local T = {}

------------------------------------------------------------------------- world
T.world = {
  w = 3400, h = 2400,          -- island bounds in world units (1 unit = 1 px at zoom 1)
  shore = 260,                 -- water margin baked into terrain generation
  tileSize = 40,               -- terrain sampling grid
  homeRadius = 150,            -- safe ring around the Home Rig
}

------------------------------------------------------------------------ player
T.player = {
  radius        = 17,
  accel         = 2600,
  maxSpeed      = 300,
  friction      = 12,          -- per-second damping rate
  turnAssist    = 0.35,        -- extra accel when reversing direction
  hearts        = 3,
  invuln        = 1.25,
  knockback     = 320,
  reboot        = 6.0,         -- seconds down before you respawn at the Home Rig
  rebootCostPct = 0.25,

  dash = {
    speed = 900, dur = 0.16, cooldown = 0.62, iframes = 0.22,
    trail = 6, dilation = 0.55, dilationDur = 0.07,
  },
  shove = {
    arc = math.rad(100), range = 82, cooldown = 0.3, force = 520,
    stun = 0.55, hitstop = 0.055, trauma = 0.34, damage = 1,
    -- The blade lights what it cuts. Three lights are laid along the arc so
    -- the swing sweeps rather than flashes.
    light = { radius = 150, gain = 1.6 },
  },
  -- The Pulse used to cost eight cobalt. Traced across five runs the bank sits
  -- at 0-13 from cycle 2 onward, so the panic button was unaffordable at
  -- exactly the moments it exists for, and most players never pressed it once.
  -- It is priced in seconds now: free, and you get one every ten.
  pulse = {
    charge = 0.85, radius = 200, force = 900, cost = 0, cooldown = 10,
    stun = 1.2, hitstop = 0.11, trauma = 0.75, damage = 2,
  },
  -- Hand-planting cost three cobalt and was dominated by a Planter inside a
  -- minute. Free, on a long cooldown, it is a *placement* decision instead:
  -- the one tree you put exactly where you want it.
  plant  = { cost = 0, cooldown = 4.5 },
  carry  = { speedMul = 0.66, pickupRange = 34 },
  mineEvery = 0.55,            -- seconds per chunk while standing on a deposit
  lamp   = { radius = 310, warm = 1.25 },  -- the pool you actually work inside at night

  -- The sidearm. It fires itself, at the nearest thing inside about five body
  -- lengths, and that short range is the whole design: it is not a weapon you
  -- fight a night with, it is the reason walking toward trouble is a decision
  -- rather than a mistake. Anything further away is still the crew's job.
  blaster = {
    range  = 175,      -- ~5 body lengths at radius 17
    every  = 0.40,     -- seconds between shots
    damage = 1,
    speed  = 620,
    spread = 0.035,
  },
}

------------------------------------------------------------------------- rally
-- The one standing order the player can give. Without it a run is "walk to
-- cobalt, press 1" and the forest grows wherever it likes; with it, deciding
-- which way the wood advances is a decision you revisit every minute, and it
-- has a real cost: everything you point at is somewhere you are not defending.
T.rally = {
  -- Re-planting the flag was free, instant and unlimited, so the spec's claim
  -- that "the ground you point at is ground you are not defending" was not
  -- true of the code -- you simply moved it to whatever you were doing. A
  -- cooldown makes pointing it a commitment for most of a phase.
  cooldown = 42,
  radius     = 620,            -- how far from the flag bots will take an order
  pull       = 0.82,           -- how strongly wander targets are biased toward it
  workBonus  = 0.18,           -- they work faster when they know where they are going
}

------------------------------------------------------------------------ economy
T.cobalt = {
  nodeYield      = 7,          -- chunks per deposit
  nodeRespawn    = 26,         -- seconds
  nodesAtStart   = 26,
  nodeMax        = 34,
  nodeFloor      = 14,          -- the island always has this many out there
  chunkValue     = 2,          -- cobalt banked per chunk
  -- A deposit gives up one chunk at a time, to anybody. The player was
  -- throttled by T.player.mineEvery and the bots were not throttled at all --
  -- they called consumeCobaltNear every frame, so a Harvester emptied a
  -- seven-chunk node in seven frames and deposits evaporated as you walked
  -- toward them. The rate belongs to the rock, not to who is hitting it.
  mineEvery      = 0.28,
  driftSpeed     = 460,        -- fly-to-player speed
  magnetRange    = 90,
  startingCobalt = 30,
}

--------------------------------------------------------------------------- bots
-- cost, hp, and the numbers each behaviour needs.
T.bots = {
  -- What a bot puts back into the lighting buffer after dusk. The crew used to
  -- light a 5-radius circle at half strength while the Blight -- retuned twice
  -- since -- lit seven and a half at one and a half, so at night the enemy was
  -- the best-lit thing on the island and your own crew were shapes moving
  -- between the red pools. They are forty-eight lamps you paid for; they
  -- should read like it.
  light = {
    radius   = 6.6,   -- multiples of the bot's own radius
    gain     = 1.05,
    downGain = 0.55,  -- a bot on the ground still has to be findable
    core     = 1.7,   -- a tight centre, so the chassis is lit and not just the grass
    coreGain = 0.8,
    bodyGain = 0.55,  -- the glow drawn *on* it
    bodySize = 1.5,
  },
  order = { "planter", "builder", "repulsor", "sentry", "harvester", "beacon" },

  planter = {
    -- Planters are the obvious buy, so their price climbs faster than anything
    -- else: a roster of sixty Planters and seven of everything else is not a
    -- build, it is the absence of one.
    label = "PLANTER", prefix = "SEED", cost = 10, hp = 3, radius = 12, speed = 78,
    costGrowth = 0.26,
    -- Scaled with the cycle, and rescaled when the cycle changed again. This
    -- is a wall-clock period: the forest a run reaches is roughly its length
    -- divided by this, so the two have to move together or the sky is either
    -- unfillable or full by cycle four.
    plantEvery = 18.0, minTreeGap = 40, wanderRetarget = { 1.2, 3.4 },
    desc = "Wanders and plants saplings, forever.",
  },
  builder = {
    -- Doubled. A Builder makes Planters for free forever, which is the single
    -- best thing cobalt buys; at 35 it was the obvious first purchase and every
    -- run bought the same thing in the same order.
    label = "BUILDER", prefix = "FRAME", cost = 70, hp = 5, radius = 15, speed = 66,
    buildEvery = 14.0, carryStart = 3, carryMax = 6,
    -- What a Builder spends out of its *own* pockets to make a Planter. It used
    -- to charge half an escalating price to the player's bank, every fourteen
    -- seconds, per builder, with no way to see it, dismiss it or turn it off:
    -- three builders and fifteen planters drained more than a player earns
    -- standing on a deposit. It says "builds new Planters from cobalt it
    -- finds", and now that is what it does.
    -- Three chunks of what it found, per Planter. At one, a Builder converted
    -- node cobalt into workers far cheaper than the player's own escalating
    -- price and the crew ran away with itself -- traced runs reached a hundred
    -- and thirty-eight bots where twenty to forty is the shape of the game.
    -- The bank charge it used to make was the only brake, and taking that brake
    -- away without replacing it is what let go.
    buildCost = 3,
    desc = "Builds new Planters from cobalt it finds.",
  },
  repulsor = {
    label = "REPULSOR", prefix = "PYLON", cost = 12, hp = 4, radius = 14, speed = 0,
    pulseEvery = 1.2, radius_pulse = 230, force = 900, charges = 4, stun = 0.9, damage = 1,
    -- How often it shows you what it covers. A Repulsor is a mine you place in
    -- front of a wave and its footprint was invisible until it fired, so it
    -- could only ever be placed hopefully.
    reachEvery = 2.8,
    lightRadius = 300, lightGain = 0.7,
    desc = "Four hard shockwaves, fast, then it is gone. Throw it in front of a wave.",
  },
  sentry = {
    label = "SENTRY", prefix = "THORN", cost = 25, hp = 6, radius = 14, speed = 0,
    range = 265, fireEvery = 1.1, dartSpeed = 620, damage = 2, spread = math.rad(3),
    desc = "Static. Fires seed-darts at the Blight.",
  },
  harvester = {
    label = "HARVESTER", prefix = "SCRAP", cost = 20, hp = 4, radius = 13, speed = 108,
    capacity = 5, seekRange = 900, depositRange = 60,
    desc = "Gathers cobalt and brings it home.",
  },
  beacon = {
    label = "BEACON", prefix = "LAMP", cost = 30, hp = 8, radius = 17, speed = 0,
    radius_field = 240, growthBonus = 0.45, slow = 0.35, reviveTime = 2.2,
    desc = "Light, growth, and a place to revive the fallen.",
  },

  -- Each bot of a type you already own makes the next one dearer. This is what
  -- stops a runaway workforce, and it is why the cost-cutting chips matter.
  -- What the Home Rig can keep running at once. Cobalt's only sink is the
  -- workforce -- the Pulse and hand-planting are both priced in seconds now --
  -- so without a ceiling the crew simply absorbs the whole economy, and traced
  -- runs reached a hundred and thirty-eight. A cap turns "how many bots do I
  -- have" into "what is my crew made of", which is a decision; accumulation is
  -- not. Forty-eight is also where the extraction's rebel-share curve stops
  -- paying, so the cap and the reason to build sit at the same number.
  maxCrew      = 48,
  costGrowth   = 0.14,
  -- WHAT A DEATH COSTS. The escalation above used to be read off the crew you
  -- had standing, so a machine that died made the next one CHEAPER: the only
  -- material consequence of losing one had the wrong sign, and a run that lost
  -- half its Planters was handed a discount on rebuilding them. It is read off
  -- the PEAK crew of that type now (World:botCost), and these two say how long
  -- that peak is remembered.
  --
  --   costForgiveness  how much of the gap between the peak and the crew you
  --                    actually have is written off immediately. 0 remembers a
  --                    loss in full -- rebuilding costs what the machine you
  --                    lost would have cost, so it is a machine you buy twice.
  --                    1 is exactly the old behaviour and is the one-line way
  --                    back if this turns out wrong.
  --   costMemory       half-life in seconds of whatever is left. A cycle is
  --                    about two minutes; at 90 a night's losses are still
  --                    being paid for through the morning rebuild and are some
  --                    three-quarters forgiven by the next dusk. 0 means never
  --                    forget, which is a wall a catastrophic cycle 3 cannot
  --                    climb -- the point is a mark on the run, not a dead run.
  costForgiveness = 0,
  costMemory      = 90,
  -- The comment here used to say "never more than 4x the base price" over a
  -- value of 6. It is 14 now, and the reason is that the cap was the only thing
  -- deciding how big a workforce could get: past about twenty planters the
  -- price stopped rising, so every further bot was the same price as the last
  -- and traced runs ran to a hundred and thirty. The escalation has to keep
  -- biting for the whole run or it is not a brake, it is a speed bump.
  costGrowthMax = 14.0,        -- never more than fourteen times the base price

  downedTime   = 20,           -- seconds a bot survives at 0 hp before expiring
  bootTime     = 0.9,
  chatterEvery = { 9, 26 },
}

------------------------------------------- NEW: what one machine carries of its
-- own run. In one block so a concurrent edit merges cleanly.
--
-- The first pillar of this game is that the bots are people, and until now the
-- entire per-instance model was two integers. Everything below exists to make
-- one machine distinguishable from the forty-seven standing next to it: what it
-- did (the ledger and the epitaph cut from it), what that did to it (the wear),
-- and what it costs the ones still standing when it goes (the grief).

--- How much of a machine's history is on its chassis, and how it is quantised.
---
--- One integer per bot -- `Bot.shadeK` -- decides how dark its metal is baked,
--- and BOTH nights survived and the speech trait feed it. That is deliberate:
--- the hulls are tessellated once per (type, shade) and replayed, so a
--- continuous tint would mean a bake per bot and a continuous *anything* here
--- would cost more than the whole rest of this file. Six levels is enough that
--- a four-night machine is plainly not a fresh one and cheap enough that the
--- whole crew shares thirty baked hulls.
T.bots.wear = {
  fullNights   = 4,      -- nights to full patina
  levels       = 4,      -- patina steps between fresh and full: one per night
  neutral      = 1,      -- shade index of a fresh, untinted machine
  shades       = 7,      -- total shade levels (0 .. shades-1)
  -- names.lua gives every trait a `tint`; this turns it into +-1 shade level.
  -- A quiet machine is physically dimmer than a loud one, which is free
  -- characterisation riding on the wear bake rather than a system of its own.
  -- Kept to one level against the patina's four on purpose: personality must
  -- not be mistakable for age, and the tick row is the unambiguous counter
  -- either way.
  tintScale    = 7,
  dropPerLevel = 0.14,   -- metal-ramp stops darker per level
  rimGain      = 0.18,   -- ...and how much brighter the rubbed rim gets
  -- The countable one. A machine wears one mark per night it has stood
  -- through, and they start at the second so that "has a mark at all" already
  -- means something -- everything alive is past its first dawn within minutes.
  tickFrom     = 2,
  tickMax      = 5,
  -- Scars: one per time it went down and got back up, drawn from a small baked
  -- library so two machines with the same count still do not match.
  scarMax      = 4,
  scarVariants = 8,
}

--- The thresholds an epitaph has to clear before it is worth saying. See
--- `Bot:epitaph`: the line is the RAREST true fact about the machine, and these
--- are where "true" stops being interesting.
T.bots.epitaph = {
  nights = 3,        -- nights before age outranks work
  mined  = 8,        -- cobalt chunks brought home
  walked = 30000,    -- world pixels under its own tracks
}

--- NEW: how the memorial composes a page out of those clauses. In one block so
--- a concurrent edit merges cleanly. See `S:composeMemorial` in scenes/ending.
---
--- Every row gets the ranked fact about that machine and then, where the ledger
--- honestly supports one, a second fact from a different bucket. The second one
--- is not chosen by rank alone: forty rows each independently picking their own
--- best remaining fact is how the first clause ended up on half the page, and
--- doing it twice would move the problem rather than solve it. The page keeps a
--- tally of what it has already said and a clause pays for every previous
--- printing of its kind, so the rarest true thing about a machine tends to be
--- the thing said about it.
T.bots.memorial = {
  -- Two penalties, because two things repeat and they are not equally bad.
  --
  -- `spread` is what one previous printing of the same KIND of fact costs, in
  -- ranks. It saturates at `spreadCap` printings: a form that has appeared four
  -- times does not read much worse than one that has appeared three, and
  -- letting it grow without limit meant a form spent in the first half of the
  -- page was unavailable in the second half, where it was needed.
  --
  -- `exact` is what one previous printing of the IDENTICAL SENTENCE costs, and
  -- it is much steeper and does not saturate. "it stood through five nights."
  -- beside "it stood through two nights." is a shared form with a fact in it;
  -- "it never went down." beside "it never went down." is a form letter. The
  -- first is worth some repetition, the second almost none -- which is why the
  -- clauses with no number in them are the ones that end up rationed.
  spread   = 1.2,
  spreadCap = 3,
  exact    = 3.0,
  -- How many rows a KIND of fact may lead before the page stops treating it as
  -- news. The work leads -- that is the ranking's whole point -- but a crew of
  -- Planters means the tree count is the ranked fact on nearly every machine,
  -- and after the third row the reader is no longer being told what this one
  -- did, they are being shown the template. Past this, a row whose headline has
  -- saturated may lead with something else it is and print the work second; the
  -- fact is not lost, it stops being the opening word. See `composeRow`.
  headMax  = 3,
  -- A row is one line under one name. Anything wider than this loses its second
  -- clause rather than wrapping into the row below it -- the scroll has a fixed
  -- row pitch and no reflow. Measured as a fraction of the memorial column, and
  -- allowed past 1: the names are set in that column but the scrim they sit in
  -- is 150px wider, so a long sentence can overhang the column and still be on
  -- its own dark ground.
  rowWidth = 1.12,
}

--- What a loss costs the machines that saw it. One spatial query, one timer and
--- one multiplier: the crew stops working and walks to the body, which is the
--- story of a death told entirely in movement.
T.bots.grief = {
  radius  = 340,     -- who saw it
  time    = 14,      -- seconds they carry it
  workMul = 0.5,     -- how much less they get done meanwhile
  arrive  = 46,      -- how close they stand
  chatter = 0.55,    -- chance a grieving bot's next line comes from the loss pool
}

--- A machine you walked out and picked up. For about a cycle it stays where it
--- can see you rather than going back to the flag.
T.bots.loyal = {
  time      = 150,   -- seconds
  pull      = 0.62,  -- chance its next wander target is picked near you
  radius    = 210,   -- ...and how far out
  plateFloor = 0.55, -- its nameplate never fades below this while it holds
}

-------------------------------------------------------------------------- trees
T.tree = {
  growTime      = 26,          -- sapling -> mature
  elderTime     = 540,         -- mature -> elder; Old Growth makes it far quicker
  -- Also scaled with the cycle, and it matters more than the Planters do:
  -- spread compounds, so the run's length changes the number of doublings
  -- rather than a fixed number of trees.
  spreadEvery   = { 82, 150 }, -- seconds between seedling attempts
  -- Only trees on the edge of the wood put out seedlings. That is what turns the
  -- forest into an advancing front with a defensible line instead of a mat.
  -- Nothing roots in bare rock. The island's stone spines therefore stay clear,
  -- and a finished forest has paths and clearings running through it instead of
  -- being one uniform mass edge to edge. A soil *threshold* was tried first and
  -- was far too blunt: it halved the wood everywhere rather than shaping it.
  barrenBiomes   = { rock = true, scar = true },
  frontierRadius = 130,
  frontierMax    = 4,          -- neighbours within that radius before it stops
  spreadRange   = { 70, 190 },
  spreadReject  = 46,          -- min distance to another tree
  chewTime      = 6.0,         -- seconds a chomper needs to fell a tree
  chewTelegraph = 1.4,         -- warning bite before the timer starts
  o2Sapling     = 0.35,
  o2Mature      = 1.0,
  o2Elder       = 2.0,
  maxTrees      = 1900,
  windSway      = 0.055,
}

----------------------------------------------------------------------- oxygen
-- Oxygen is not an accumulator: it is a reading of the forest that is standing
-- right now. Plant a tree and the needle moves; lose a grove overnight and it
-- falls. That is what makes defending trees legible.
T.o2 = {
  target      = 100,            -- percent
  -- The sky is full when the island is. Islands vary a lot by seed, so this is
  -- derived from plantable land rather than being a constant that some seeds
  -- could never reach: trees-worth of area, clamped so extremes stay sane.
  -- A full sky was pegged at one tree-point per 4300 square units of land, and
  -- clamped over a range wide enough that a big island demanded nearly two and
  -- a half times what a small one did. A forest does not scale with an island
  -- that way -- the player's time does not -- so the large seeds could not be
  -- filled and the meter finished in the sixties whatever the player did.
  -- Traced across three seeds, this lands a thoughtless autoplay run at 87-100%
  -- rather than 65-96%, with the strong runs filling the sky around cycle six
  -- and triggering the early extraction, which is what the win condition is for.
  -- Halved. A full sky used to want twelve hundred tree-points; it wants six
  -- hundred now, and every derived figure below is halved with it so the
  -- clamp keeps the same shape.
  fullForest    = 600,          -- fallback when there is no terrain
  forestPerArea = 1 / 5400,     -- tree-points per square world unit of plantable land
  -- The clamp does most of the work on purpose. A linear-in-area target cannot
  -- be right for both ends: set it so a small island is a real job and the big
  -- ones become unfillable; set it so the big ones are fillable and the small
  -- ones fill at cycle four and cut three cycles off the run. A full sky is
  -- around twelve hundred tree-points wherever you land, tilted by how much
  -- ground there is. Retuned upward twice as the economy fixes landed: with
  -- Builders no longer draining the bank and deposits no longer evaporating,
  -- the forest grows fast enough that the old target was met at cycle four and
  -- cut three cycles off the run.
  forestMin     = 475,
  forestMax     = 700,          -- tree-points that read as a fully restored sky
  rise        = 0.42,           -- how fast the reading climbs toward the forest
  fall        = 0.95,           -- ...and how fast it drops. Loss is felt sooner.
  weight      = { sapling = 0.35, young = 0.6, mature = 1.0, elder = 1.5 },
  -- The Siphon's damage is the tree it is perched on now; the meter dip is
  -- only the tell. 1.4 was double-dipping.
  siphonDrain = 0.6,            -- debt added per second per feeding siphon
  debtCap     = 45,             -- a swarm of siphons cannot zero you out
  debtRecover = 0.35,           -- debt bled off per second once they stop
}

------------------------------------------------------------- the airless world
-- How hard the oxygen reading grades the frame. This is the campaign's only
-- picture of itself: the premise is that the aliens stripped the atmosphere
-- eleven days ago, and the one mechanic that answers it is the forest, so the
-- world has to *look* airless at 0% and has to visibly come back as the needle
-- climbs. Consumed only by src/engine/daynight.lua, applied on top of the
-- time-of-day grade, and a pure function of the current reading -- not of
-- progress -- so the extraction rig dragging oxygen back down drags the colour
-- out of the island with it.
--
-- Every value below is the multiplier (or mix weight) at **0% oxygen**. At
-- 100% every one of them is inert and the frame is exactly the frame the game
-- shipped with: the restored look is the target, and this block only describes
-- the distance the world has to travel to reach it.
T.deadAir = {
  -- Recovery curve. r = o2^curve, and r is what everything below lerps on.
  -- Below 1 this front-loads the arc, and it has to stay below 1: a linear ramp
  -- banks the whole payoff in the last two cycles, where the player is fighting
  -- the boss and not looking at the grass, while a front-loaded one pays out at
  -- every dawn, which is when the player actually re-reads the island.
  --
  -- 0.55 over-corrected. It spent HALF the visual recovery inside the first
  -- four minutes: at cycle 2 and 14% oxygen the island was already an
  -- unmistakably live green world, so the premise the prologue states out loud
  -- -- the sky has been that colour for eleven days -- was only visually true
  -- for the first ninety seconds of a seventeen-minute run.
  --
  -- 0.85 keeps the front-loading and stops over-paying for it. r at 14/50/90%
  -- goes 0.34/0.68/0.94 -> 0.19/0.55/0.91. Measured as mean pixel saturation
  -- over the play area at a fixed reading (`BOTS_O2` pins the grade for exactly
  -- this A/B; the anchors are 0.156 dead and 0.514 live), the fraction of the
  -- recovery already spent goes 24%/60%/93% -> 11%/46%/89%: a third of the
  -- early payout is deferred and the top of the ramp is untouched, which is the
  -- half that must not move.
  curve      = 0.85,

  -- Chroma is the main tell, and the one that is easiest to overdo. 0.33 takes
  -- day's 1.22 grade saturation down to ~0.40; measured over the play area of
  -- a cycle-1 frame that is a mean pixel saturation of 0.15 against the live
  -- world's 0.63. Far enough that the sward reads as straw and the sea reads
  -- as tin; not so far that the frame goes monochrome, because a fully grey
  -- island looks like a broken shader rather than a dead planet. It is worth
  -- knowing which way the failure lies: too little and it is a hazy morning,
  -- too much and it is a black-and-white photograph.
  saturation = 0.33,
  -- High key, not dim. Nothing is filtering the sun any more, so the frame is
  -- *brighter* than a live one, pushed far enough into the tonemap's shoulder
  -- that the sand and the surf bleach out. This is the single value that keeps
  -- the dead world beautiful instead of depressing: drop it below 1.0 and the
  -- same desaturation immediately reads as mud.
  exposure   = 1.09,
  -- Barely any. "Crushed shadows" was the first instinct and it was mostly
  -- wrong here: once the chroma is gone the darkest thing on the island is a
  -- blight scar at about 0.05 luminance, and squeezing that turned every scar
  -- into a black hole that read as a missing tile rather than as poisoned
  -- ground. 1.06 did exactly that and was backed off to this; the `lift` at
  -- the bottom of the block puts a floor back under the same pixels.
  contrast   = 1.03,

  -- The dust. `haze` is added to the phase's own fog strength rather than
  -- multiplying it, because day's fog is 0.11 and dusk's is 0.46: a multiplier
  -- big enough to matter at noon is a whiteout at dusk. `fogMul` is the gentle
  -- multiplicative part that survives at every hour.
  --
  -- Both the added haze and its colour are scaled by how high the key light
  -- is, so the dust only shows where there is light to scatter in it. That is
  -- what protects the night: at midnight this whole paragraph is zero and the
  -- night grade is the night grade, lift and all.
  -- Both feed Post.setFog, whose strength is multiplied by Post.tuning.fogAmount
  -- (0.13) before it reaches the shader -- so `haze` of 1.3 at noon is a wash
  -- of about 18% of the dust colour over the frame, which is a lot of dust and
  -- still not a whiteout. fogMul stays near the old 1.06 on purpose: it is the
  -- part that survives into the night, where a bigger number would just make
  -- the dark navy fog darker.
  fogMul     = 1.15,
  haze       = 1.30,
  -- How far the atmosphere's colour is dragged toward P.deadHaze at noon.
  hazeTint   = 0.86,
  -- ...and how far the *shadow* tint is dragged toward P.deadShade. Lower than
  -- the haze: the grade normalises this one to unit luminance and uses it on
  -- every dark pixel in the frame, so a strong warm here turns the whole
  -- island sepia, which is the exact postcard this is trying not to be.
  shadeTint  = 0.72,
  -- Glare. Dry air scatters the highlights, and a touch more bloom over a
  -- bleached frame reads as heat rather than as a bug.
  bloom      = 1.16,
  -- The floor the dust puts under the frame, screened into the shadows the way
  -- the sky's own lift is. Small -- 0.055 of a pale bone -- but it is the
  -- difference between a scar reading as poisoned ground and reading as a hole
  -- in the map, and it is what keeps a bleached frame from going contrasty and
  -- grim. Scaled by the same daylight factor, so it never touches night.
  lift       = 0.055,
}

------------------------------------------------------------------------ cycles
T.cycle = {
  count      = 7,
  -- Two minutes a cycle, dusk included. The ratio of day to night is kept from
  -- the old curve -- three-fifths day at the start, even by the end -- so the
  -- shape of the campaign survives the compression even though the run does
  -- not: seven cycles is about seventeen minutes.
  dayLen     = { 64, 64, 62, 60, 58, 56, 54 },
  duskLen    = 12,
  -- Dusk is otherwise twelve dead seconds. HOLD THE DAWN buys more day at the
  -- price of a worse night: one decision, every cycle, with a real cost.
  holdExtra  = 24,
  holdBudget = 1.45,
  nightLen   = { 44, 44, 46, 48, 50, 52, 54 },
  -- The night's spend used to be mostly a function of how big your forest was:
  -- 0.28 a tree meant every tree you grew bought the Blight more of a night,
  -- in exact proportion, so growth was self-punishing and loss was
  -- self-relieving. The pressure is authored per cycle now and the forest term
  -- is a much smaller reminder that a bigger wood is a longer perimeter.
  -- Re-cut once the crew was capped at forty-eight. This curve was set when a
  -- traced run fielded ninety to a hundred and thirty bots; against a workforce
  -- half that size, and a Director that now spends the same budget on far more
  -- dangerous compositions, the late nights took a forest apart -- one seed
  -- finished at eighty-nine trees and fourteen percent.
  budget     = { 24, 42, 66, 94, 130, 168, 214 },    -- floor for the night's spend
  budgetPerTree = 0.16,        -- ...plus this much for every tree you have grown
  -- What the night is made of, by cycle: the weight of each type at the cycle it
  -- unlocks, and how that weight drifts per cycle afterwards (under 1 fades,
  -- over 1 grows). The Director used to hard-code one set of weights with no
  -- cycle term at all, so night six was night three with a bigger number in
  -- front of it. A type absent from this table can never be drafted -- which is
  -- how the Scar exists as an enemy without being something the Blight buys.
  mix = {
    chomper = { 4.0, 0.84 },
    skitter = { 2.6, 0.86 },
    spitter = { 1.2, 1.20 },
    siphon  = { 1.6, 1.16 },
    bulwark = { 1.0, 1.34 },
    warden  = { 1.4, 1.25 },
    maw     = { 0.5, 1.20 },
  },
  -- Two pacing shapes, blended across the run. An early night has a real lull in
  -- the middle of it; a late one has a floor under it and never drops back
  -- through that floor once it is up.
  curveEarly = { 0.25, 0.50, 0.85, 1.00, 0.55, 0.40, 0.70, 0.95, 1.00, 0.60 },
  curveLate  = { 0.55, 0.80, 0.72, 0.95, 0.82, 1.00, 0.90, 1.00, 1.00, 0.95 },

  clutchBudget = 18,      -- cost-worth of a clutch; cheap types arrive in packs
  frontsFrom   = 5,       -- the cycle the rift opens a second side
  focusFrom    = 4,       -- ...and the cycle it starts reinforcing success
  focusChance  = 0.34,
  focusDecay   = 12,      -- seconds a place stays hot after teeth went into it
  anchorWindow = 0.45,    -- fraction of the night a surviving Scar pulls waves in
  -- Four waves in five opening on a Scar turned a bad dawn into a spiral: the
  -- night began inside the wood you had already lost, which cost more trees,
  -- which left more Scars. It still pulls the opening inland; it no longer
  -- decides the whole first half of the night.
  anchorChance = 0.55,
  escortFrom   = 6,       -- Wardens and Maws arrive with a bodyguard from here
  escortSpend  = 0.22,    -- ...paid for out of this share of what is left
  scarQuota    = { 0, 1, 2, 2, 3, 3, 4 },  -- Scars the Blight may leave per dawn
  mawAlive     = 1,       -- live Maws at once, dormant ones included
  -- The world advances its phase clock before it ticks the Director, so a night
  -- whose two clocks are exactly equal ended without the Director ever seeing
  -- its own last frame: endNight never ran, director:dawn never fired (the HUD
  -- has a NIGHT SURVIVED toast that had never once been shown) and `active`
  -- stayed true all through the following day. The Director's night ends a hair
  -- before the phase's, which is invisible and gives it its ending back.
  directorLead = 0.35,

  maxAlive   = { 14, 20, 26, 32, 38, 44, 52 },
  maxAlivePerTree = 0.016,
}

----------------------------------------------------------------------- enemies
T.enemy = {
  chomper = { cost = 4,  hp = 3,  speed = 74,  radius = 14, damage = 1, from = 1,
              treeSearch = 480 },   -- past this it comes for your bots instead
  -- A hit-and-run animal: it plants, winds up, throws itself, and backs off
  -- whatever happened. Chasing one is a waste of a night.
  skitter = { cost = 5,  hp = 2,  speed = 168, radius = 11, damage = 1, from = 2,
              lungeRange = 230, lungeWind = 0.36, lungeSpeed = 640, lungeTime = 0.32,
              backoff = 1.6, backoffSpeed = 1.5 },
  -- It gives ground inside this fraction of its range: a Spitter that stands
  -- still while you walk up to it is a Chomper with extra steps.
  spitter = { cost = 9,  hp = 4,  speed = 62,  radius = 14, damage = 1, from = 3,
              range = 280, fireEvery = 2.6, projSpeed = 330, puddle = 6, kite = 0.5 },
  -- It perches on one specific tree and takes *that tree*, through the same
  -- timer and the same tally as everything else. The oxygen dip is the tell,
  -- not the damage. While it is feeding it takes more than double.
  siphon  = { cost = 11, hp = 5,  speed = 52,  radius = 16, damage = 0, from = 3, float = true,
              perchRange = 2400, perchRadius = 56, perchHeight = 26, feedVuln = 2.2 },
  -- instSearch: how far it will walk to find an installation before settling
  -- for the wood. It used to be the whole island, which made it a homing
  -- missile that never touched a tree in its life.
  bulwark = { cost = 18, hp = 14, speed = 44,  radius = 22, damage = 2, from = 4, armoured = true,
              armour = 0.5,      -- fraction of incoming damage it shrugs off
              instSearch = 720 },
  -- A rift does not walk off at sunrise: it goes dormant, and every night it
  -- survives it wakes up hungrier.
  maw     = { cost = 34, hp = 22, speed = 0,   radius = 30, damage = 0, from = 5,
              armoured = true, armour = 1.0,
              spawnEvery = 4.5, shovesToClose = 6,
              holdsGround = true, wakeStep = 0.84, wakeFloor = 2.4 },
  -- The Warden has no attack. It hangs behind the pack and everything Blight
  -- near it shrugs off most of a hit and moves faster, which turns a late-cycle
  -- wave from "hit the nearest thing" into "get to the back".
  warden  = { cost = 16, hp = 9,  speed = 58,  radius = 18, damage = 0, from = 6,
              float = true, wardRadius = 250, wardCut = 0.55, wardHaste = 0.22,
              wardTick = 0.2, standOff = 210, shy = 330, flockRange = 900 },
  -- The Scar: what the Blight leaves in the ground when the sun comes up. It is
  -- the day's opposition and it is deliberately not a fight -- it never moves,
  -- never chases, and cannot hurt the player at all. It eats the wood around
  -- it, its reach grows all day, it seeds another if left to finish growing,
  -- and at dusk it is where the night starts. `from` is absent on purpose: a
  -- type with no entry in T.cycle.mix can never be drafted as a wave card, and
  -- a Scar is never bought -- it is left behind.
  scar    = { cost = 0,  hp = 20, speed = 0,   radius = 20, damage = 0,
              armoured = true, armour = 0.45, shovesToClose = 5,
              creepStart = 110, creepMax = 300, creepGrow = 2.2,
              rotEvery = 9, rotRamp = 0.55, spreadEvery = 26, maxAlive = 6,
              -- how far apart the dawn quota plants them, so a morning is
              -- several problems in several places rather than one thick one
              rootSpread = 300,
              bounty = 8 },
  spawnEdgePad = 90,
  fleeOnDawn   = 8,             -- seconds to retreat and despawn at dawn

  -- What the Blight puts back into the lighting buffer after dusk. Night is
  -- the game, and until these existed the thing attacking you was a dark shape
  -- on dark ground.
  -- Turned up twice. The first pass lit the *ground* around a Blight and left
  -- the Blight itself a dark shape standing in it, which is not the same thing
  -- as seeing it: the body is dark-valued and the eyeshine that reads it was
  -- being drawn at a fifth of the strength of the lamp underneath.
  light = {
    radius   = 7.6,   -- multiples of the enemy's own radius
    gain     = 1.45,  -- at full dark; scaled down toward dusk
    core     = 2.0,   -- a tight hot centre so the body reads as lit
    coreGain = 1.05,
    rooted   = 2.1,   -- Maws and Scars are landmarks: visible from across the island
    -- the glow drawn *on* the thing, as opposed to the light it casts. Without
    -- this a lit patch of grass is all you get.
    eyeGain  = 0.85,
    eyeSize  = 1.9,
  },
}

-------------------------------------------------------------------------- boss
T.boss = {
  -- The rig's hull is a fixed job with a fixed shape, and the workforce pays for
  -- most of it. What the size of your crew changes is not how long the fight is
  -- -- it is how much each individual bot is worth when it goes.
  hpBase       = 1000,
  hpPerBot     = 2.0,
  hpFloor      = 620,
  dartResist   = 0.28,         -- seed-darts plink off a rig this size
  -- One point of player damage, against a hull this size. Shove is 1 damage on
  -- a 0.3s cooldown, so an open core is about 14 damage a second and armour
  -- plates cut that to six: the numbers the fight is actually paced around.
  hullScale    = 4.4,
  platePenalty = 0.42,
  -- What fraction of the rig the workforce pays for, as a function of how big
  -- it is. Twelve bots cannot carry three quarters of a fight this size and it
  -- is a lie to pretend they do; sixty can, and should. This is the curve that
  -- makes the eleven minutes of building before the rig lands *matter* -- a
  -- bigger crew is not more damage per bot, it is less of the fight left to you.
  -- Tuned so building the crew visibly *removes work* from the player rather
  -- than adding hull for them to chew. At thirteen bots the player owes about
  -- 560 of the rig; at sixty, about 240. Eleven minutes of building used to buy
  -- a 27% shorter final fight, which is not enough to be worth eleven minutes.
  rebelShareMin   = 0.34,
  rebelShareMax   = 0.78,
  rebelSharePerBot = 0.009,

  -- The procession. Cohort size scales with the crew so the rebellion always
  -- takes about the same number of waves, whether you built twelve bots or
  -- sixty: the rhythm of the thing is authored, its weight is not.
  -- Not everyone goes. The rig falls before the last of them get there, and
  -- whoever is still walking when it does simply stops -- which is the only
  -- mercy in the ending, and also the reason there is anybody left standing in
  -- the ring at dawn. Without this the whole crew was always spent and the
  -- last shot of the game was the player alone on a beach.
  -- Low enough that most of the ones who are willing actually get there. At
  -- 0.16 a crew of forty-five sent thirty of its thirty-eight and the player
  -- picked up the slack: the measured burden fell only 24% between a crew of
  -- thirteen and a crew of forty-five, when the whole point of the curve is
  -- that a big workforce takes the fight off you.
  rebelStopAt  = 0.07,         -- hull fraction below which no new cohort leaves
  rebelKeep    = 0.30,         -- and this share of the crew never leaves at all
  rebelKeepMin = 5,
  rebelWaves   = 14,
  -- One, so that rebelWaves is the authority on the *shape* of the procession
  -- at every crew size. At two, a crew of thirteen sent ten bots in five waves
  -- and was finished forty-six seconds into a hundred-and-fifty second fight:
  -- the climax was over in the first third and the rest was a solo damage race
  -- against a bar with nothing left to give.
  rebelCohort  = 1,
  rebelEvery   = 6.5,
  rebelDelay   = 8.5,

  -- REINFORCEMENTS. The crew you brought is finite, and once it is spent the
  -- rest of the hull was the player's problem alone: measured, the rebellion
  -- takes the bar to about a third and the last third was a damage race a
  -- player cannot win against a rig that is draining the sky the whole time.
  --
  -- So the island answers. From phase two, a bot a second walks in off the map
  -- edge and makes for the rig. They are not your crew -- they cost nothing,
  -- they do not count against the cap, they are not in the ending's ledger --
  -- they are every machine still working somewhere on the island, arriving
  -- because the rebellion started.
  reinforce = {
    fromPhase = 2,
    -- Paced by arrival rate rather than by a weaker hit: they land the same
    -- blow one of yours does, and the throttle is that they have to walk in
    -- from the treeline. Tuned from the measured length of the fight.
    every     = 1.0,      -- seconds between arrivals
    maxAlive  = 26,       -- in flight at once, so the walk-in never becomes a mob
    edgePad   = 70,       -- how far outside the land they step in from
  },

  -- The hull will not go below this fraction of maximum from player damage
  -- alone. The plates come off when the bots arrive, not when you hit hard
  -- enough -- so the player cannot end the fight before the rebellion does, and
  -- the bar visibly stalls at a line until the next cohort lands.
  phaseFloor   = { 0.66, 0.34, 0.0 },
  phase2Land   = 0.24,         -- fraction of the crew that must have landed
  phase3Land   = 0.58,
  phaseStall   = 26,           -- failsafe: a phase never lasts longer than this
  phaseGap     = 6.0,          -- a phase always gets its moment before the next

  speed        = 108,
  contactDmg   = 1,
  -- The rig is the antagonist of the whole run and it was 62 units across,
  -- which on a forested island is smaller than the canopy of one tree. It
  -- reads at this size, and being easier to hit is the right trade.
  radius       = 88,
  columnHeight = 1500,         -- the extraction column, up out of the frame
  -- The rig always takes the same *share* of whatever sky it found, so a run
  -- that reached the deadline at 30% still gets a real fight instead of an
  -- automatic loss.
  -- Every run gets the same number of seconds, whatever the meter read when
  -- the rig landed. The old floor did the opposite of what its comment claimed:
  -- max(45, o2) / 200 gave a run arriving at 100% the full two hundred seconds
  -- and a run arriving at 22% only ninety-three, so it *shortened* the fight
  -- for exactly the runs that were already behind.
  extractWindow = 200,         -- seconds from arrival to an empty sky
  beamCharge   = 1.5,
  beamSweep    = 3.2,
  slamEvery    = 6.0,
  droneEvery   = 5.0,

  -- The rig's clock. Nothing below touches the fight -- these are the rates the
  -- machine *animates* at, and they live here rather than in the entity file
  -- for the same reason every other rate does: so the thing can be re-timed
  -- without reading draw code.
  art = {
    drillRps      = 1.05,   -- turbine revolutions per second, phase 1
    drillPhaseUp  = 0.4,    -- ...and how much faster per phase, as a fraction
    drillBlades   = 9,
    drillGhosts   = 3,      -- motion-blur passes trailing the blades
    beaconRps     = 0.5,    -- the sweeping amber beacon on the superstructure
    strobeHz      = 0.62,   -- the red hull strobes
    ventHz        = 2.3,    -- heat shimmer over the vents
    hoverAmp      = 5,      -- world units of idle bob
    recoilDecay   = 3.0,    -- 1/s: how fast a landed hit's shudder dies
    recoilHit     = 0.6,    -- shudder added by a hit that lands
    recoilBlock   = 0.4,    -- ...and by one the plates refuse
    descend       = 400,    -- how far above the canopy the arrival starts
    gaitLift      = 0.22,   -- foot lift, in rig radii
    gaitReach     = 0.15,   -- foot swing along the heading, in rig radii
    -- The molten core, rebuilt as a near-black crust with hot cracks in it
    -- rather than a graded tan disc. The crack field turns slowly, each crack
    -- breathes on its own clock and a bright pulse travels up it, so the
    -- fissure network moves without a frame of it being authored.
    coreCracks    = 7,      -- fissures out of the vent; a finer set again between
    coreDriftRps  = 0.026,  -- the whole crack field turns at this, revs/sec
    coreCrack     = 0.017,  -- crack width, in rig radii, with the core sealed
    coreCrackOpen = 0.014,  -- ...added on top once it is open
    coreFlowHz    = 0.30,   -- the pulse that travels up a crack, and its wander
    coreVeins     = 6,      -- cracks running out of the core over the deck
    deckRivets    = 8,      -- one per deck seam; it used to be twenty-four
    -- The beam. It used to be drawn wide at the muzzle with a 62 px radial
    -- bloom on top, which clipped to white and read as a lens flare. It is
    -- tightest where it leaves the barrel now and opens downrange.
    beamMuzzleW   = 0.085,  -- beam half-width at the muzzle, in rig radii
    beamFarW      = 0.26,   -- ...and at the far end of its range
    beamMuzzle    = 0.30,   -- the muzzle flash's reach, in rig radii
    beamSpall     = 9,      -- sparks shed sideways along the cut
    columnMotes   = 34,
    columnRings   = 6,
    columnRise    = 0.26,   -- column-heights per second travelled by rings/motes
    suctionMotes  = 30,
    suctionReach  = 4.4,    -- rig radii the intake pulls leaves in from
    suctionRate   = 0.5,    -- inward trips per second
    slamTell      = 0.85,   -- wind-up seconds; mirrors updateSlam's foot-fall
    slamRadius    = 300,    -- mirrors the areaShove radius, so the ring is honest
    slamRing      = 0.45,   -- seconds the payoff ring takes to reach it
    beamRange     = 900,    -- mirrors updateBeam's beamLen
    -- Its own lighting. The rig used to paint itself lavender and stop reading
    -- as metal; the key is deliberately a cold near-neutral and the colour is
    -- pushed out to the ground and the throat where it belongs.
    keyRadius     = 380, keyGain    = 0.30,
    strobeRadius  = 300, strobeGain = 0.40,
    throatRadius  = 150, throatGain = 0.30,
    moltenRadius  = 330, moltenGain = 0.28,
  },
}

---------------------------------------------------------------------- readouts
-- The bots are the emotional core of the game and by the middle of a run they
-- are invisible: eight hundred canopies close over the island and a capture of
-- an extraction with thirty-four bots alive did not show a single one of them.
-- The player has had an occlusion-proof marker since the first build. These
-- numbers give the workforce the same, and nothing more than the same: a mark
-- that only appears when there is genuinely canopy in the way.
T.hud = {
  -- The chrome hides *under* the cinematic letterbox rather than being sliced
  -- by it. Scaled so the readouts are gone before the bars have finished
  -- closing, and so they come back up with the bars rather than after them.
  chromeHide   = 1.7,
  -- No world-anchored overlay may reach into the bottom band, which belongs to
  -- the build bar and, during the extraction, to the boss's health.
  overlayFloor = 168,

  -- The phone layout. On a 6-inch pane held in landscape the two bottom corners
  -- are under thumbs and the hands that carry them, so the whole "what you have"
  -- column -- cobalt, forest, crew, integrity and the event feed -- moves into
  -- the top-left, the feed grows downward out of it instead of upward out of the
  -- floor, and the right rail carries the clock, the map and the two orders
  -- nobody gives in a panic.
  touch = {
    pad       = 14,    -- grid inset *inside* the safe box
    colW      = 300,   -- the left column's width, for the chatter keep-out
    heartGap  = 10,    -- below the resources block
    heartH    = 44,
    feedGap   = 10,    -- below the hearts
    feedMax   = 0.62,  -- the feed may not grow past this fraction of the height
    dialR     = 29,    -- the cycle dial shrinks: it is a clock, not a feature
    mapW      = 168,   -- the minimap plate, on the right rail under the clock
    mapGap    = 14,    -- below the dial
    holdW     = 260,   -- HOLD THE DAWN moves to the freed bottom-centre band and
    holdH     = 74,    -- becomes a tap target rather than a key prompt
    holdUp    = 26,    -- above the bottom safe edge
    holdGap   = 14,    -- ...and this much clear of the thumb cluster
    bossUp    = 118,   -- the boss bar's baseline above the bottom safe edge
    bossW     = 0.42,  -- ...and its width, so its end clears the thumb cluster
    overlayFloor = 214,
    o2Max     = 400,   -- the oxygen arc never grows past this on a phone
  },

  -- HOLD THE DAWN, under the cycle dial: a decision about the clock, drawn
  -- beside the clock. It is one of the two real decisions in a run, so it gets
  -- a standing affordance instead of a tutorial hint that expires unread.
  hold = {
    w    = 200,
    h    = 80,
    gap  = 14,       -- below the cycle dial
    rise = 14,       -- how far it slides up as it arrives
    rate = 7,        -- 1/s ease, in and out
  },

  botPip = {
    cover      = 3,      -- canopies over a bot before its mark is at full strength
    coverR     = 62,     -- world radius of the cover test around a bot's head
    coverUp    = 26,     -- how far above its feet that test is centred
    coverBack  = 70,     -- a canopy rooted behind this only counts if it sorts in front
    fade       = 7,      -- 1/s ramp, matching the player pip so the two agree
    size       = 7,      -- chevron size in screen px; the player's is 11
    rise       = 2.4,    -- bot radii above its feet the mark floats
    bob        = 2.6,    -- idle bob rate, 1/s -- slower than the player's, so it reads as a crowd
    max        = 48,     -- most marks drawn in a frame; the down and the rebelling get theirs first
    ringR      = 5.5,    -- the static bots' ring; they are installations, not somebody walking
    downPulse  = 5.0,
    downRing   = 1.8,    -- multiplier on ringR for the rescue clock
    -- A red ring and an amber ring are the same shape, and at a glance across a
    -- forest that is all the eye gets. The ping is what separates them: a bot on
    -- the ground is calling, and a distress signal expands.
    pingRate   = 0.8,    -- distress pings per second
    pingGrow   = 2.2,    -- how many ring radii a ping travels before it dies
    -- A sunlit crown sits at almost exactly the same value as P.eye, so the
    -- mark reads by hue alone and in daylight that is not enough. The black
    -- pass is what carries it; it has to be wide and it has to be dark.
    halo       = 5.0,    -- width of the black outline pass that lifts a mark off the canopy
    haloA      = 0.72,
    -- The rebellion is the moment the whole game has been building to and it
    -- happens under the thickest canopy of the run, so a rebel's mark is larger
    -- than a worker's, carries a wake, and lights itself.
    rebelScale = 1.5,
    tail       = 28,     -- screen px of wake behind a marching rebel
    tailSteps  = 4,
    -- Every focus is a hole in the canopy and a forest full of holes is not a
    -- forest, so the x-ray is spent only on the bots you have to walk onto.
    xrayMax    = 3,
    xrayRadius = 58,
  },
}

-------------------------------------------------------------------------- juice
T.juice = {
  maxTrauma      = 1.0,
  traumaDecay    = 1.6,
  shakeAmp       = 26,
  shakeRotAmp    = 0.035,
  hitstopMax     = 0.18,
  zoomPunchDecay = 7.0,
}

------------------------------------------------------------------------ haptics
-- THE VOCABULARY, and why most of the game is silent in it.
--
-- A gamepad -- a DualSense included -- gives LOVE two rumble motors and a
-- duration. That is the entire instrument: a heavy low-frequency mass on the
-- left and a light high-frequency one on the right. It has no pitch, no
-- position and no adaptive triggers reachable from here (see game/haptics.lua).
--
-- So it is spent like a small budget, and the first rule is *what does not get
-- a voice*. This game runs sixty enemy kills a minute at night. A controller
-- that answers every one of them is a controller the player puts down, and it
-- also destroys the only dynamic range the instrument has: if a kill is worth
-- 0.2, then dawn cannot be worth more than 0.2 either, because the hand has
-- stopped listening. Kills, cobalt pickups, bot chatter, bot-planted trees,
-- enemy spawns and reinforcements arriving are therefore *silent*, on purpose.
--
-- What is left is ranked, and the rank is enforced three ways: `pri` lets a
-- big moment duck a small one that is already playing, `gap` is the minimum
-- time between two firings of the same pattern, and the mixer's per-second
-- budget drops low-priority voices during a storm rather than mudding it.
--
--   5  the run's punctuation: dawn, the extraction, the end
--   4  events that change what the player is doing: night, boss phase, a chip
--   3  consequence: a bot down, a tree lost, the Blight taking ground
--   2  acknowledgement: a bot built, a bot back on its feet
--   1  texture: the hand-plant. Nearly inaudible, and that is correct.
--
-- SEPARATION OF THE TWO MOTORS carries meaning and is not decoration:
--   low  (left)  = mass, impact, dread. Things that are heavy or are ending.
--   high (right) = mechanism, confirmation, UI. Things that click or complete.
-- A bot being built is high-then-low: a click, then the weight settling on it.
-- A bot going down is low alone, sagging to nothing. Nothing else may borrow
-- that shape.
--
-- A pattern is a list of stages, each `{ low, high, seconds }`. The voice ramps
-- linearly from the previous stage's amplitudes (starting at silence) to this
-- stage's over `seconds`, so `{0, 0.4, 0}` is an instant attack and a trailing
-- `{0, 0, 0.3}` is a 300 ms release. Everything is authored here; the mixer in
-- engine/input.lua knows nothing about any particular moment in the game.
T.haptics = {
  -- The mixer. See Input.rumbleUpdate.
  mix = {
    maxVoices  = 8,      -- concurrent voices; the oldest lowest-priority is cut
    duck       = 0.45,   -- a voice is scaled this far by anything above its rank
    eps        = 0.02,   -- amplitude change worth another call to the driver
    refresh    = 0.20,   -- re-issue the current amplitudes at least this often
    hold       = 0.35,   -- duration handed to the driver; > refresh, so a lost
                         -- frame cannot leave a motor stuck on
    budget     = 12,     -- new voices per second before triage starts
    budgetPri  = 3,      -- ...and the rank that survives triage
    -- The finale sends forty bots into the rig one at a time. Each detonation
    -- is deliberately below the threshold of notice; what the player feels is
    -- the *sum* of them, so the same pattern is allowed to stack -- but only
    -- this far, or a cohort of eight lands as one solid slab.
    maxSame    = 4,
  },

  -- The browser has no rumble path at all (SDL's Emscripten joystick backend
  -- implements none), so the web build can only speak to the page. One line per
  -- voice, at most this often; see Input.rumbleBridge.
  web = { gap = 0.08, minPri = 2 },

  pat = {
    ---------------------------------------------------------------- rank 5
    -- The sun. A slow warm swell that arrives, opens out and resolves -- the
    -- only pattern in the game that is allowed to take two seconds, because it
    -- is the only moment the player is not doing anything.
    dawn        = { pri = 5, gap = 4.0, s = { {0.16,0.02,0.55}, {0.34,0.09,0.45}, {0.09,0.15,0.35}, {0,0,0.85} } },
    -- The rig comes down. Nine tenths of it is a rise you feel before you see,
    -- and then it lands.
    extraction  = { pri = 5, gap = 10.0, s = { {0.08,0.00,0.90}, {0.30,0.04,0.70}, {1.00,0.85,0.04}, {0.42,0.10,0.45}, {0,0,1.10} } },
    failed      = { pri = 5, gap = 10.0, s = { {0.90,0.70,0.02}, {0.55,0.15,0.80}, {0.24,0.04,1.20}, {0,0,1.60} } },
    won         = { pri = 5, gap = 10.0, s = { {0.80,0.50,0.03}, {0.28,0.34,0.60}, {0.11,0.20,1.00}, {0,0,1.40} } },

    ---------------------------------------------------------------- rank 4
    night       = { pri = 4, gap = 5.0,  s = { {0.05,0.00,0.35}, {0.40,0.03,0.50}, {0.11,0.00,0.60}, {0,0,0.50} } },
    bossPhase   = { pri = 4, gap = 1.0,  s = { {0.85,0.55,0.02}, {0.34,0.24,0.35}, {0,0,0.50} } },
    rebel       = { pri = 4, gap = 10.0, s = { {0.10,0.06,0.50}, {0.50,0.22,0.60}, {0.18,0.08,0.80}, {0,0,0.70} } },
    playerDown  = { pri = 4, gap = 1.0,  s = { {0.75,0.30,0.03}, {0.34,0.05,0.55}, {0,0,0.90} } },
    -- A chip is a decision the player made. Click, then seat it.
    chip        = { pri = 4, gap = 0.30, s = { {0.00,0.55,0.01}, {0.00,0.00,0.05}, {0.42,0.12,0.03}, {0.16,0.02,0.18}, {0,0,0.16} } },
    heldDawn    = { pri = 4, gap = 2.0,  s = { {0.30,0.25,0.05}, {0.14,0.30,0.40}, {0,0,0.40} } },
    o2          = { pri = 4, gap = 1.0,  s = { {0.00,0.42,0.02}, {0.20,0.14,0.22}, {0,0,0.30} } },

    ---------------------------------------------------------------- rank 3
    -- Low alone, sagging. Something heavy stopped working.
    botDown     = { pri = 3, gap = 0.25, s = { {0.52,0.05,0.02}, {0.30,0.00,0.16}, {0,0,0.34} } },
    botLost     = { pri = 3, gap = 0.35, s = { {0.46,0.10,0.02}, {0.22,0.02,0.30}, {0,0,0.45} } },
    treeLost    = { pri = 3, gap = 0.40, s = { {0.34,0.06,0.02}, {0.10,0.00,0.20}, {0,0,0.22} } },
    -- Ground lost for good: two grinding lows, not a hit.
    blight      = { pri = 3, gap = 0.80, s = { {0.30,0.10,0.06}, {0.10,0.04,0.12}, {0.34,0.12,0.06}, {0,0,0.40} } },
    wave        = { pri = 3, gap = 3.0,  s = { {0.24,0.08,0.05}, {0.06,0.02,0.20}, {0,0,0.25} } },
    -- Scaled by the fraction of the boss bar taken off, and hard-gapped: the
    -- finale lands hundreds of these.
    bossHurt    = { pri = 3, gap = 0.16, s = { {0.30,0.22,0.01}, {0,0,0.11} } },
    playerUp    = { pri = 3, gap = 1.0,  s = { {0.05,0.05,0.25}, {0.28,0.30,0.12}, {0,0,0.30} } },

    ---------------------------------------------------------------- rank 2
    -- The click of the mechanism, then its weight settling.
    botBuilt    = { pri = 2, gap = 0.15, s = { {0.00,0.40,0.01}, {0.00,0.06,0.05}, {0.34,0.04,0.03}, {0.10,0.00,0.18}, {0,0,0.12} } },
    botRevived  = { pri = 2, gap = 0.20, s = { {0.16,0.16,0.03}, {0.05,0.28,0.12}, {0,0,0.18} } },
    cohort      = { pri = 2, gap = 0.50, s = { {0.28,0.10,0.04}, {0.08,0.02,0.22}, {0,0,0.20} } },
    scarCleared = { pri = 2, gap = 0.50, s = { {0.10,0.24,0.03}, {0.04,0.08,0.16}, {0,0,0.20} } },
    rally       = { pri = 2, gap = 0.30, s = { {0.00,0.30,0.01}, {0.06,0.10,0.05}, {0,0,0.10} } },
    -- Information, not celebration: two fast, tiny high ticks.
    denied      = { pri = 2, gap = 0.20, s = { {0.00,0.22,0.005}, {0,0,0.03}, {0.00,0.22,0.005}, {0,0,0.04} } },

    ---------------------------------------------------------------- rank 1
    -- The verb of the whole game, and it happens constantly, so it is one soft
    -- tick on the light motor and nothing else. Bot-planted and self-seeded
    -- trees get nothing at all.
    plant       = { pri = 1, gap = 0.12, s = { {0.00,0.16,0.005}, {0,0,0.045} } },
    -- One bot on the hull. Forty of these arrive in the finale and not one of
    -- them is meant to be felt alone; `mix.maxSame` lets them pile into a
    -- texture instead.
    sacrifice   = { pri = 1, gap = 0.00, s = { {0.14,0.05,0.005}, {0,0,0.07} } },
    -- The catch-all the four existing Input.rumble() calls in entities/player.lua
    -- land on. Its shape is built from the call's own arguments, and its rank
    -- from the call's own strength (see Input.rumble), so a dash tick ducks
    -- under a big moment and taking a hit still cuts through one.
    legacy      = { pri = 3, gap = 0.00, s = { {1,1,0} } },
  },
}

-------------------------------------------------------------------------- touch
-- The iPhone control layer, entire. Every number the touch UI lays itself out
-- with lives here; engine/touch.lua contains no geometry of its own.
--
-- Fractions of S = min(screenW, screenH) unless the name says otherwise, so one
-- set of numbers holds for a letterboxed browser canvas, a native retina buffer
-- and the headless capture harness alike.
--
-- The arrangement: a phone held in landscape is gripped at the bottom corners,
-- and the two arcs a thumb sweeps out from those corners are the only ground on
-- the screen that is both reachable and already hidden by a hand. So the verbs
-- live on those arcs -- three constant ones on the near arc, two deliberate ones
-- one ring further out -- the movement stick owns the mirrored arc on the other
-- side, and every readout the player has to *read* is pushed up into the top
-- band where no hand ever goes.
T.touch = {
  maxTouches   = 10,

  -- The reference length everything below is a fraction of. It is the short
  -- edge -- but never more than this much of the long one, because on a tablet
  -- or anything near square the short edge is enormous and a thumb is not: at
  -- 1366x1024 a plain min(w,h) gave 137 px buttons and a stick you could stand
  -- in. A landscape phone is nowhere near this ratio, so it is unaffected.
  aspectRef    = 0.60,

  ---------------------------------------------------------------- floating stick
  stickRing    = 0.112,   -- ring radius: full deflection
  stickNub     = 0.046,
  stickDead    = 0.155,   -- fraction of the ring ignored at the centre
  stickGrip    = 0.011,   -- absolute jitter floor before anything moves at all
  stickCurve   = 1.25,    -- >1 = finer control near the centre
  stickFollow  = 26,      -- damp rate at which the ring chases a runaway thumb
  stickZoneX   = 0.52,    -- fraction of screen width owned by the stick
  -- The stick may not spawn under the top band: a finger planted over the
  -- oxygen arc hides the one readout the whole campaign is measured in.
  stickZoneTop = 0.36,    -- below the top safe inset, in S
  -- Where the resting ghost sits when nobody is touching the glass. This is the
  -- only thing on a first touch screen that says "drag anywhere here to walk",
  -- so it is drawn at the thumb's actual rest position, not in a corner.
  homeX        = 0.235,   -- in from the safe left edge
  homeY        = 0.215,   -- up from the safe bottom edge
  ghostA       = 0.62,    -- ghost opacity, relative to the layer
  ghostPulse   = 1.1,     -- breaths per second while it is still being taught
  hintMove     = 2.6,     -- seconds of actual stick use before the ghost retires
  hintFade     = 1.6,     -- 1/s it retires at

  ------------------------------------------------------------- action cluster
  -- Two arcs struck from a pivot at the grip corner. Angles are degrees in
  -- screen space: 180 is straight inboard, 270 is straight up, and anything
  -- below 180 would fall off the bottom of the phone.
  pivotX       = 0.105,   -- pivot inset from the safe right edge
  pivotY       = 0.020,   -- ... and up from the safe bottom edge
  arcIn        = 0.272,   -- near arc: the constant verbs
  arcOut       = 0.424,   -- far arc: the deliberate ones
  innerAng     = { 187, 226, 265 },
  -- BUILD takes the inboard seat on the far arc: it is the frequent one of the
  -- two, the thumb reaches it by lying flat rather than stretching up, and its
  -- wheel blooms into open screen instead of over the map.
  outerAng     = { 248, 202 },
  btnIn        = 0.067,   -- near-arc button radius
  btnOut       = 0.055,   -- far-arc button radius
  btnRail      = 0.042,   -- right-rail utility button radius
  btnHitPad    = 1.44,    -- invisible hit radius multiplier
  btnSlop      = 2.30,    -- drag this far off a button before it cancels
  -- Glyph and caption both live *inside* the disc. A caption hung underneath a
  -- button clips on the bottom row of the arc and collides with its neighbour
  -- on the diagonal, and a landscape phone has neither the height nor the width
  -- to spare for either.
  glyphOff     = -0.24,   -- glyph centre, in button radii from the disc centre
  labelOff     = 0.30,    -- caption top, likewise
  labelSize    = 0.30,    -- caption size, in button radii

  ------------------------------------------------------------------- right rail
  -- Utility verbs nobody presses in a panic: they sit above the thumb arc,
  -- grouped under the map, where reaching for them is a deliberate act.
  -- The rail stacks down the *inboard* edge of the minimap plate rather than
  -- under it: under it is where the far arc's top button already is, and two
  -- controls that nearly touch are two controls a thumb will confuse.
  railGap      = 0.032,   -- between rail buttons
  railDrop     = 0.030,   -- inboard of the minimap plate
  railFallback = 0.400,   -- down the right edge, where there is no map to hang off

  -------------------------------------------------------------------- build radial
  radialInner  = 0.072,
  radialOuter  = 0.245,
  radialGap    = 0.030,   -- wedge separation, radians
  radialHold   = 0.15,    -- hold this long (or drag) to open
  radialDrag   = 0.030,   -- ... or drag this far, whichever comes first
  radialDilate = 0.25,    -- the world runs this slow while the wheel is open
  radialGlyph  = 0.115,   -- bot silhouette size, in wheel outer radii
  radialMargin = 1.10,    -- wheel radii of clearance kept inside the safe box

  --------------------------------------------------------------------------- aim
  aimDead      = 0.028,   -- drag before an aim touch commits
  aimRange     = 430,     -- world units for auto-aim
  aimCone      = 1.05,    -- half-angle of the travel cone, radians
  aimStick     = 0.55,    -- how strongly a locked target is preferred

  -------------------------------------------------------------------------- feel
  fade         = 7.0,     -- opacity damp rate
  press        = 26.0,    -- press-scale damp rate
  latch        = 0.085,   -- min time a tapped action reports down
  gateMin      = 0.30,    -- below this drawn strength the layer refuses presses
  ripple       = 0.36,
  hapticTap    = 0.011,
  hapticSlide  = 0.006,
  hapticFire   = 0.020,

  ------------------------------------------------------------------- safe area
  safeMin      = 0.020,   -- fallback inset when the OS will not tell us
  safeNotch    = 0.055,   -- assumed notch inset on iOS when the API is absent
  -- Nothing load-bearing may sit in the outermost band of a phone screen even
  -- when the OS swears there is no notch: the browser's own chrome, a rounded
  -- display corner and a camera housing all live there.
  safeFloor    = 24,      -- px, absolute
}

------------------------------------------------------------------------ camera
T.camera = {
  followRate  = 7.5,
  lookahead   = 0.28,          -- fraction of velocity projected ahead
  lookaheadMax = 130,
  deadzone    = 12,
  zoom        = 1.25,
  zoomAim     = 1.16,
  edgePad     = 40,
  -- How far past the island's own bounding box the view may travel. The camera
  -- is clamped to the land, not to the world rectangle, so a beach still shows
  -- its wet sand, its surf and a band of open sea -- and never half a screen of
  -- empty water, which is what clamping to the world rect gave.
  landPad     = 260,
}

------------------------------------------------------------------------- music
-- Authored tracks, streamed from assets/music (see src/engine/music.lua). Three
-- slots; the game's seven musical states fold onto them, so dusk plays the day's
-- track and the extraction the night's.
--
-- frontier-static.ogg is encoded and shipped but bound to no slot: bind or drop
-- it before release, it is 1.8 MB nobody hears.
T.music = {
  tracks = {
    title = "assets/music/stellar-drift-title.ogg",
    day   = "assets/music/beyond-the-airlock.ogg",
    night = "assets/music/frontier-thrum-night.ogg",
  },
  gain = { title = 1.0, day = 1.0, night = 1.0 },   -- per-slot trim

  -- Day and night blend rather than cut. The fall matches T.cycle.duskLen so the
  -- score is dark on the frame the sky is; move that, move this. The climb is
  -- quicker -- relief should arrive faster than dread -- and is a fixed duration
  -- because dawn has none of its own.
  dayToNight = 12,
  nightToDay = 9,

  -- Hard cuts only: menus, finale, stop().
  fadeIn   = 1.6,
  fadeOut  = 2.2,
  stopFade = 1.5,
}

------------------------------------------------------------- NEW: the radio
-- The narrative pass, in one block so a concurrent edit merges cleanly.
--
-- The radio is the only thing in this game that accumulates. It is a row on
-- the dawn screen, a lamp on the Home Rig and a readout beside it, and the
-- three of them say exactly the same thing seven times in a row. None of the
-- numbers below is allowed to move during a run except `dayZero + cycle`.
T.radio = {
  -- Days since the sky went, at the first dawn. The prologue says "eleven
  -- days" and the HUD then counts cycles, so the eleven never became twelve
  -- anywhere the player could see it. 11 + cycle is where it becomes twelve.
  dayZero    = 11,

  -- The rig's amber lamp. A slow turn, not a pulse: `sweep` seconds per
  -- revolution, and `peak` is the power the facing term is raised to, which is
  -- what makes the pass a pass rather than a sine wave. `floor` is what the
  -- bead reads with its back to you -- never zero, or the lamp looks broken
  -- rather than turned away.
  sweep      = 6.4,
  peak       = 7,
  floor      = 0.14,
  lampRange  = 150,            -- how far the amber carries, in world units

  -- The readout, in the bot nameplate's micro type because it is the same kind
  -- of object: a machine saying what it is. Further out than a plate, because
  -- bots come to you and the rig does not.
  --
  -- It is NOT dimmer any more. 0.62 was chosen so the rig's own readout would
  -- not shout over the crew's names; what it actually did was make the first
  -- thing the game wants the player to read the hardest thing on the screen to
  -- read -- mid-grey micro type on a 28%-black chip over a sunlit meadow. It is
  -- furniture, and furniture still has to be legible; the way to stop it
  -- shouting is that it never changes, which it never does.
  plateNear  = 200,
  plateFade  = 130,
  plateSize  = 7.5,
  plateAlpha = 0.88,
  -- The number on it. It is a constant. That is the whole readout.
  signals    = 0,
}

-- The light in the sky, three times, before the thing it belongs to lands.
-- Screen-space, drawn over the graded scene by src/world/weather.lua, and
-- deliberately made of nothing the player can act on: no sound, no ping, no
-- toast, and it never comes down.
T.skyContact = {
  -- Fires on the o2 milestone step. Was 3 (75%), which a traced run does not
  -- reach until cycle six -- so all three sightings crowded into the last two
  -- cycles and the thing arrived with no more warning than it had before. At 2
  -- the first one lands mid-run, which is the whole point of it.
  o2Mark     = 2,
  lastCycles = 2,              -- ...then at dusk on each of the last two
  dur        = 8.0,            -- seconds to cross the frame
  y0         = 0.045,          -- entry height, as a fraction of the frame
  y1         = 0.105,          -- exit height: a straight track, barely sloped
  r          = 3.4,            -- the point itself, in pixels
  glow       = 62,
  alpha      = 0.95,
  edge       = 0.14,           -- fraction of the pass spent fading in and out
}

------------------------------------------------------------- NEW: relics
-- The evidence. A handful of hand-authored objects placed once at world
-- generation, drawn once, and never spoken about: see src/entities/relic.lua.
--
-- The three rules that make this block worth reading:
--
--  1. Nothing here is a reward curve or a difficulty knob. A relic is not
--     interactive, has no caption, is not on the minimap and emits no light.
--     Every number below is either a *distance* or a *count*.
--  2. `noPlant` is the only way a relic touches gameplay at all. A Planter
--     refuses a spot inside that radius, so a wood grows around a wreck rather
--     than swallowing it, and the thing is still standing in the clearing at the
--     ending when the camera pulls back over the canopy. It is much wider than
--     the object it protects, and the note on `noPlant` below says why.
--  3. The `near` distances exist so a player who never leaves the valley they
--     woke up in still walks past two or three of these across a run, and the
--     rest are out where only exploring finds them. Placement that relies on
--     the player going looking is placement that most players never see.
T.relic = {
  -- Relics take their own RNG stream, seeded off the run's seed. They must not
  -- draw from `world.rng`: that stream places the home rig, the cobalt and every
  -- spread roll after it, so spending from it would shift every island in the
  -- game the day this file landed and make every previous balance trace a
  -- comparison between two different worlds.
  seedSalt   = 104729,
  -- Placement attempts before a relic is skipped. Generous, and it has to be:
  -- a scattered relic must clear `separation` from a dozen already-placed
  -- objects, `roadClear` from every road segment, the shore and the rig, and at
  -- 70 the fourth suit and the second pallet simply failed to land on the
  -- smaller seeds. This runs once, at world generation, behind a loading screen
  -- that is already spending most of a second baking the terrain.
  tries      = 260,

  homeClear  = 250,            -- nothing of ours inside this of the player's rig
  -- Two separations, and the split matters.
  --
  -- `separation` is between relics of DIFFERENT kinds. A suit and a pallet in
  -- one frame is two sentences; that is fine, and sometimes better than fine.
  --
  -- `sameKind` is between two of the SAME kind, and it is much wider, because
  -- two identical objects in one frame is not two sentences -- it is one prop,
  -- twice, and it reads as a spawner. An early capture caught two empty suits
  -- in a single view and instantly turned the strongest object in the set into
  -- set dressing. The camera shows about 1280x720 world units, so `sameKind`
  -- puts the second one a screen and a half away.
  --
  -- Both were 500 for a while and that failed differently: twelve relics each
  -- claiming a 500-unit disc is 9.4 million square units of exclusion on a
  -- 3.5 million unit island, so the fourth suit and the hauler simply had
  -- nowhere legal to stand and were dropped on half the seeds tested.
  separation = 420,
  sameKind   = 900,
  -- ...AND THE ONE EXCEPTION, which is a reversal. The rule above was written
  -- to keep two suits out of one frame, and four played runs said the rule was
  -- the thing costing the set its weight: at four suits, a screen and a half
  -- apart, on a 3400x2400 island, a player meets one, forgets it, and meets
  -- another one ten minutes later. Two bodies in one field is not a prop drawn
  -- twice; it is the only arrangement in the set that says this happened to
  -- more than one person. 560 is under half a screen width, so two CAN share a
  -- frame, and with seven of them scattered over the island most pairs still do
  -- not. The argument the old number was making survives for everything else,
  -- which is why this is one entry and not a new default.
  sameKindBy = { suit = 430 },
  roadClear  = 130,            -- ...except to a road segment, which is thinner
  minShore   = 70,             -- keep everything out of the surf

  -- Seven suits, one pallet. Seven because four of the least legible objects in
  -- the set, spread over an island this size, is a handful of moments nobody
  -- registers; one pallet because two untouched pallets of air said they had
  -- plenty. The remaining one is cut open with two canisters gone.
  count      = { suit = 7, pallet = 1 },
  -- The near-band suit is drawn this much larger. It is the one a player who
  -- never explores is guaranteed to walk past, and at 1.0 it was a grey lump at
  -- play zoom -- legible only in the gallery at 5x, where the critic called it
  -- the best object in the game. One of the seven survives the zoom; the other
  -- six stay the size they were, because seven oversized bodies would be a
  -- theme park.
  suitNear   = { scale = 1.55 },
  -- Which SCATTERED suit gets pose 4, the one with the helmet off beside it.
  -- Index into the scatter loop, which starts at 2. Exactly one per island, by
  -- index rather than by a roll: it is the only object in the set that says a
  -- person decided something, and two of them would make it a motif.
  suitHelmetOff = 4,

  -- Where each one goes, as a distance band from the Home Rig. `wreckMin` is a
  -- floor rather than a band: the second rig is chosen as the furthest valid
  -- candidate found, because "somebody else tried this, a long way from you" is
  -- the whole sentence and it is ruined by proximity.
  near       = {
    suit     = { 340, 700 },
    pallet   = { 380, 780 },
    road     = { 260, 520 },   -- the road passes the rig; he parked by it
  },
  far        = {
    mast     = { 700, 1600 },
  },
  wreckMin   = 1150,
  scatterMin = 560,            -- scattered relics keep at least this from home

  -- The road. Segments are all one length so a single baked shape serves the
  -- whole run, and they overlap by `overlap` so the joins do not show.
  road       = {
    segLen   = 150,
    width    = 62,
    overlap  = 9,
    perSide  = 6,              -- segments laid each way from the anchor
    curve    = 0.13,           -- radians of heading drift per segment, max
    variants = 3,
  },

  -- How far a Planter has to stay off each kind, in world units. The road's is
  -- measured from its segment rather than from its centre, so it is a corridor
  -- and not a bead on a string.
  --
  -- These have to be wider than the object they protect, because a canopy is
  -- drawn above its trunk: a mature tree standing well SOUTH of a relic still
  -- paints over it, which is the same occlusion problem the bot pips and the
  -- x-ray focus exist to solve. Measured in a nine-hundred-tree forest, at 74
  -- the empty suits were completely buried and at 54 the road could not be
  -- found in the frame at all.
  --
  -- AND THEY HAVE TO BE NARROWER THAN THAT WANTS TO BE, because denying ground
  -- is not free and the first pass at these numbers was a real balance
  -- regression. Sampled against the same two tests `plantTree` applies, the
  -- 112/78 set took 13.6% of the plantable island on the largest seed measured
  -- and 24.3% on the smallest -- and a fill test on that small seed reached 450
  -- trees where an unrelic'd island reached 500, widening to 515 against 663 at
  -- a higher target. A fifth of the wood is not a price a prop gets to charge.
  --
  -- What resolved it: the nine-hundred-tree probe is harsher than the game. A
  -- real run finishes at four to five hundred trees on this island, so the
  -- occlusion these have to beat is the canopy of a *sparse* wood. Re-verified
  -- at that density, the set below reads as well as the wide one did and costs
  -- roughly half the ground. The road is the biggest saving and the most
  -- deliberate: it protects the carriageway and nothing more, so the wood does
  -- close over stretches of it -- which is the object's own description.
  --
  -- HOW TO RE-MEASURE, because the number above is the one that decides whether
  -- any of this is affordable:
  --
  --   BOTS_RELIC=map BOTS_SEED=777 BOTS_SCENE=src.scenes.demo_relic \
  --     tools/shot.sh 8 8 /tmp/m        # prints RELICAREA,...,pct=
  --
  -- `demo_relic` samples 40,000 points against the same two tests `plantTree`
  -- applies -- on land, and not a barren biome -- so the denominator is ground
  -- a Planter would otherwise have taken. `BOTS_HUSKS=30` scatters a full cap
  -- of husks first, which is how the husk cost below was priced.
  noPlant    = {
    wreck = 112, road = 44, suit = 86, pallet = 88,
    mast = 88, hauler = 80,
    -- A HUSK IS SMALL AND ITS EXCLUSION IS SMALL, and this is the number the
    -- whole feature had to be affordable at. The wide radii above exist to beat
    -- canopy occlusion on objects the player is meant to FIND; a husk is not
    -- found, it is remembered -- the player watched it happen and knows where.
    -- So this is not a sightline, it is a footprint: nothing gets planted on
    -- top of the body, and that is all it claims. Be honest about the limit --
    -- at 27 units a mature tree standing south of a husk will still overhang
    -- it, exactly as `T.tree` occlusion does to everything else. The choice was
    -- between a small honest hole thirty times over and a real clearing thirty
    -- times over, and the second one is a fifth of the island.
    --
    -- Priced at 34 first, and 34 was too much: a full cap added 2.4-4.4 points
    -- of denied ground across four seeds, taking the smallest island to 17.3%.
    -- 27 adds 1.5-2.9 points (8.1->9.6, 13.5->15.9, 11.4->13.5, 8.7->11.6 on
    -- seeds 4242/12345/777/7) and costs the forest almost nothing where it
    -- matters: a fill test at a realistic 500-tree target reached 500 of 500 on
    -- seed 7 with a full cap of husks down, and 484 against 498 on seed 12345.
    husk = 27,
  },

  -- WHERE A MACHINE DIED, and it stays there. See the husk note at the top of
  -- src/entities/relic.lua for the four arguments; these are the three numbers.
  --
  -- `cap` is a hard limit on how much of a run the island remembers, and it
  -- exists for the plantable ground rather than for the frame -- thirty static
  -- baked shapes cost nothing to draw, but thirty more exclusion discs is
  -- ground denied. At 27 units, thirty of them is pi*27^2*30 = 69k square units
  -- against a plantable island of roughly 1.6-2.4 million. Measured cost is in
  -- the `noPlant` note above, and it is a pessimistic bound: the sampler
  -- scatters them evenly, and a real run stacks them on whatever perimeter kept
  -- failing, where the discs overlap each other instead of the island.
  --
  -- `fade` is how many further deaths an about-to-be-retired husk spends going
  -- out, so a body never vanishes in front of anybody. `floor` is where it gets
  -- to before it goes -- not zero, because the last frame before removal should
  -- still be a shape on the ground rather than nothing.
  --
  -- `minGap` is one body per place, and it is not an optimisation. A traced
  -- night put eight husks inside twenty world units -- two of them on identical
  -- coordinates -- because a perimeter that fails, fails in the same spot. A
  -- stack of eight overlapping lozenges is a heap, not a history. A loss that
  -- lands on an already-marked place is still counted by the memorial, which is
  -- what keeps the ledger; this only decides what is on the ground.
  husk = {
    cap    = 30,
    fade   = 6,
    floor  = 0.45,
    minGap = 34,
  },
}

------------------------------------------------ NEW: what he does with his hands
-- The last human speaks eight times in fifteen minutes. Everything else he
-- feels has to arrive as behaviour, so these three blocks are the whole of his
-- non-verbal vocabulary. Every number in them is small on purpose: the player
-- sees each of these fifty times in a run, and anything that reads as a
-- performance the second time is worse than nothing.
--
-- One block per thing he does, so a concurrent edit merges cleanly.

-- Standing still. An ambient weight shift that never stops, and on top of it a
-- gesture every few seconds: he works a shoulder, he looks at the sky, he
-- checks the suit. Near the Home Rig it is always the same one -- he checks the
-- radio -- because it is the only thing on the island he keeps doing that never
-- works.
T.idle = {
  delay      = 1.5,            -- seconds standing before the first gesture
  gap        = { 3.2, 6.4 },   -- and between them after that
  stillSpeed = 26,             -- under this he counts as standing

  -- The weight shift. Always running while he is on his feet, sub-pixel slow,
  -- and it is the difference between a man standing and a sprite parked.
  swayPeriod = 7.3,
  sway       = 1.1,            -- pixels of hip travel, each way

  -- The radio. Inside this of the rig, every idle is the radio idle.
  rigRange   = 320,

  dur = { shoulder = 1.5, sky = 2.2, suit = 1.7, radio = 2.6 },

  -- Amplitudes, as fractions of the body radius unless noted.
  roll       = 1.0,            -- how far the shoulder rolls back, 0..1
  headLift   = 0.34,           -- the sky look
  leanIn     = 0.12,           -- the radio lean, in shear units
  chestBlink = 0.60,           -- how far the chest readout dips while he reads it
  damp       = 8,              -- how fast a pose channel reaches its target
}

-- He notices the dead. A bot goes down near him and he turns his head to it.
-- That is all of it: no animation, no sound, no toast. It is purely cosmetic --
-- the aim cone, the blaster and the shove never see it -- so it can never cost
-- the player anything, which is why it is allowed to happen while they are busy.
T.notice = {
  range    = 460,              -- how near a body has to fall to register
  dur      = 1.35,             -- how long the head stays turned
  cooldown = 1.8,              -- a bad night must not turn him into a bobblehead
  turn     = 0.26,             -- head offset toward it, in body radii
  lean     = 0.09,             -- and what the torso does about it, in shear units
  gaze     = 11,               -- how fast the head comes round
}

-- The helmet, at the end. He does not gain a pale head: he takes the thing off
-- and sets it on the grass, and it stays there. Driven off wall-clock rather
-- than a dt, because the scene that plays this does not tick the world.
T.helmet = {
  seal   = 0.55,               -- seconds spent breaking the seal, helmet still up
  lower  = 1.15,               -- and setting it down
  side   = 1.5,                -- where it lands, in body radii, to his near side
  drop   = 1.25,               -- and in front of his boots
  arc    = 20,                 -- pixels the hand travels through on the way down
  fade   = 7.0,                -- seconds the visor takes to go out on the ground
}

------------------------------------------------------- NEW: what a rescue costs
-- Carrying a downed machine to a beacon is the tenderest verb in the game and
-- it used to cost 34% movement speed and nothing else: you could shove, dash
-- and pulse with a body in your arms, and only dying put it down. Traced, every
-- pickup reached a beacon -- a hundred percent conversion, which is another way
-- of saying there was no decision in it.
--
-- Dash is deliberately still allowed. It is the escape verb, and taking it away
-- makes rescues impossible rather than tense.
T.rescue = {
  handsFull  = true,           -- no shove and no pulse with someone in your arms
  dropOnHit  = true,           -- and a hit puts them down where you stood
  fumble     = 0.6,            -- seconds before you can pick them back up

  -- The night's own pressure on the rescue clock. Applied on top of whatever
  -- the chips say, so late nights are a triage problem -- three down at once on
  -- cycle 7 is a choice about which one you can reach.
  clockByCycle = 0.94,         -- multiplier per cycle after the first
  clockFloor   = 0.62,         -- never below this fraction of T.downedTime
}

------------------------------------------------------- NEW: staging a cutscene
-- Two numbers, and they exist because a captured `radio` beat framed the
-- speaking bot perfectly and the bot was invisible: it was standing under a
-- mature canopy and the camera was looking at the top of a tree. The forest is
-- opaque and the game already knows how to open it -- `Tree.addFocus` is what
-- clears the crowns over the player and over anyone lying on the ground -- so
-- this is that same mechanism pointed at whatever the camera is framing,
-- turned down.
--
-- Turned down is the whole point. The player's own focus takes 88% of a
-- canopy's alpha, which is a hole; a hole punched over the subject for the
-- length of a scene reads as the wood being deleted to make room for the
-- dialogue. `focus` is a *fraction* of that full strength, chosen so an
-- occluding crown lands at about 0.35 alpha -- see the arithmetic below. You
-- can still read the forest, and you can see the machine through it.
--
-- It costs nothing when nothing is playing: `World:draw` only asks for the
-- focus while `world.cutscene` is set, and a frame with no cutscene adds no
-- focus, so `Tree:updateXray`'s existing early-outs are untouched.
T.cutscene = {
  -- 1 - focus * TUNE.xrayAlpha(0.88) = 0.35 alpha on an occluding canopy.
  focus  = 0.74,
  -- World units cleared around the framed point. Wider than the player's 96:
  -- the camera is centred on the subject, so this is the middle of the screen
  -- and a bot with its nameplate up is taller than it is wide.
  radius = 140,
}


return T
