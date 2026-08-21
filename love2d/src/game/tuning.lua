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
  lamp   = { radius = 310, warm = 1.0 },   -- the pool you actually work inside at night
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
  order = { "planter", "builder", "repulsor", "sentry", "harvester", "beacon" },

  planter = {
    -- Planters are the obvious buy, so their price climbs faster than anything
    -- else: a roster of sixty Planters and seven of everything else is not a
    -- build, it is the absence of one.
    label = "PLANTER", prefix = "SEED", cost = 10, hp = 3, radius = 12, speed = 78,
    costGrowth = 0.26,
    plantEvery = 15.0, minTreeGap = 40, wanderRetarget = { 1.2, 3.4 },
    desc = "Wanders and plants saplings, forever.",
  },
  builder = {
    label = "BUILDER", prefix = "FRAME", cost = 35, hp = 5, radius = 15, speed = 66,
    buildEvery = 14.0, carryStart = 3, carryMax = 6,
    -- What a Builder spends out of its *own* pockets to make a Planter. It used
    -- to charge half an escalating price to the player's bank, every fourteen
    -- seconds, per builder, with no way to see it, dismiss it or turn it off:
    -- three builders and fifteen planters drained more than a player earns
    -- standing on a deposit. It says "builds new Planters from cobalt it
    -- finds", and now that is what it does.
    buildCost = 1,
    desc = "Builds new Planters from cobalt it finds.",
  },
  repulsor = {
    label = "REPULSOR", prefix = "PYLON", cost = 12, hp = 4, radius = 14, speed = 0,
    pulseEvery = 1.2, radius_pulse = 230, force = 900, charges = 4, stun = 0.9, damage = 1,
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
  costGrowth   = 0.14,
  costGrowthMax = 6.0,         -- never more than 4x the base price

  downedTime   = 20,           -- seconds a bot survives at 0 hp before expiring
  bootTime     = 0.9,
  chatterEvery = { 9, 26 },
}

-------------------------------------------------------------------------- trees
T.tree = {
  growTime      = 26,          -- sapling -> mature
  elderTime     = 540,         -- mature -> elder; Old Growth makes it far quicker
  spreadEvery   = { 70, 128 }, -- seconds between seedling attempts
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
  fullForest    = 1200,         -- fallback when there is no terrain
  forestPerArea = 1 / 2700,     -- tree-points per square world unit of plantable land
  -- The clamp does most of the work on purpose. A linear-in-area target cannot
  -- be right for both ends: set it so a small island is a real job and the big
  -- ones become unfillable; set it so the big ones are fillable and the small
  -- ones fill at cycle four and cut three cycles off the run. A full sky is
  -- around twelve hundred tree-points wherever you land, tilted by how much
  -- ground there is. Retuned upward twice as the economy fixes landed: with
  -- Builders no longer draining the bank and deposits no longer evaporating,
  -- the forest grows fast enough that the old target was met at cycle four and
  -- cut three cycles off the run.
  forestMin     = 950,
  forestMax     = 1400,         -- tree-points that read as a fully restored sky
  rise        = 0.42,           -- how fast the reading climbs toward the forest
  fall        = 0.95,           -- ...and how fast it drops. Loss is felt sooner.
  weight      = { sapling = 0.35, young = 0.6, mature = 1.0, elder = 1.5 },
  siphonDrain = 1.4,            -- debt added per second per feeding siphon
  debtCap     = 45,             -- a swarm of siphons cannot zero you out
  debtRecover = 0.35,           -- debt bled off per second once they stop
}

------------------------------------------------------------------------ cycles
T.cycle = {
  count      = 7,
  dayLen     = { 78, 84, 90, 94, 98, 104, 110 },
  duskLen    = 12,
  -- Dusk is otherwise twelve dead seconds. HOLD THE DAWN buys more day at the
  -- price of a worse night: one decision, every cycle, with a real cost.
  holdExtra  = 30,
  holdBudget = 1.45,
  nightLen   = { 52, 62, 70, 78, 86, 94, 104 },
  -- The night's spend used to be mostly a function of how big your forest was:
  -- 0.28 a tree meant every tree you grew bought the Blight more of a night,
  -- in exact proportion, so growth was self-punishing and loss was
  -- self-relieving. The pressure is authored per cycle now and the forest term
  -- is a much smaller reminder that a bigger wood is a longer perimeter.
  budget     = { 26, 46, 78, 120, 172, 236, 310 },   -- floor for the night's spend
  budgetPerTree = 0.16,        -- ...plus this much for every tree you have grown
  maxAlive   = { 14, 20, 26, 32, 38, 44, 52 },
  maxAlivePerTree = 0.016,
}

----------------------------------------------------------------------- enemies
T.enemy = {
  chomper = { cost = 4,  hp = 3,  speed = 74,  radius = 14, damage = 1, from = 1,
              treeSearch = 480 },   -- past this it comes for your bots instead
  skitter = { cost = 5,  hp = 2,  speed = 168, radius = 11, damage = 1, from = 2 },
  spitter = { cost = 9,  hp = 4,  speed = 62,  radius = 14, damage = 1, from = 3,
              range = 280, fireEvery = 2.6, projSpeed = 330, puddle = 6 },
  siphon  = { cost = 11, hp = 5,  speed = 52,  radius = 16, damage = 0, from = 3, float = true },
  bulwark = { cost = 18, hp = 14, speed = 44,  radius = 22, damage = 2, from = 3, armoured = true,
              armour = 0.5 },   -- fraction of incoming damage it shrugs off
  maw     = { cost = 34, hp = 22, speed = 0,   radius = 30, damage = 0, from = 4,
              armoured = true, armour = 1.0,
              spawnEvery = 4.5, shovesToClose = 6 },
  spawnEdgePad = 90,
  fleeOnDawn   = 8,             -- seconds to retreat and despawn at dawn
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
  rebelKeep    = 0.15,         -- and this share of the crew never leaves at all
  rebelKeepMin = 3,
  rebelWaves   = 14,
  -- One, so that rebelWaves is the authority on the *shape* of the procession
  -- at every crew size. At two, a crew of thirteen sent ten bots in five waves
  -- and was finished forty-six seconds into a hundred-and-fifty second fight:
  -- the climax was over in the first third and the rest was a solo damage race
  -- against a bar with nothing left to give.
  rebelCohort  = 1,
  rebelEvery   = 6.5,
  rebelDelay   = 8.5,

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
    moltenRadius  = 330, moltenGain = 0.42,
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

return T
