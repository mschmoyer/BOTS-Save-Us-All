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
  radius        = 15,
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
  pulse = {
    charge = 0.85, radius = 200, force = 900, cost = 8,
    stun = 1.2, hitstop = 0.11, trauma = 0.75, damage = 2,
  },
  plant  = { cost = 3, cooldown = 2.4 },
  carry  = { speedMul = 0.66, pickupRange = 34 },
  lamp   = { radius = 190, warm = 0.85 },
}

------------------------------------------------------------------------ economy
T.cobalt = {
  nodeYield      = 4,          -- chunks per deposit
  nodeRespawn    = 26,         -- seconds
  nodesAtStart   = 26,
  nodeMax        = 34,
  nodeFloor      = 14,          -- the island always has this many out there
  driftSpeed     = 460,        -- fly-to-player speed
  magnetRange    = 90,
  startingCobalt = 30,
}

--------------------------------------------------------------------------- bots
-- cost, hp, and the numbers each behaviour needs.
T.bots = {
  order = { "planter", "builder", "repulsor", "sentry", "harvester", "beacon" },

  planter = {
    label = "PLANTER", prefix = "SEED", cost = 10, hp = 3, radius = 12, speed = 78,
    plantEvery = 15.0, minTreeGap = 40, wanderRetarget = { 1.2, 3.4 },
    desc = "Wanders and plants saplings, forever.",
  },
  builder = {
    label = "BUILDER", prefix = "FRAME", cost = 35, hp = 5, radius = 15, speed = 66,
    buildEvery = 14.0, carryStart = 3, carryMax = 6,
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
  costGrowth   = 0.2,
  costGrowthMax = 6.0,         -- never more than 4x the base price

  downedTime   = 20,           -- seconds a bot survives at 0 hp before expiring
  bootTime     = 0.9,
  chatterEvery = { 9, 26 },
}

-------------------------------------------------------------------------- trees
T.tree = {
  growTime      = 26,          -- sapling -> mature
  elderTime     = 110,         -- mature -> elder (only with the Old Growth chip)
  spreadEvery   = { 70, 128 }, -- seconds between seedling attempts
  -- Only trees on the edge of the wood put out seedlings. That is what turns the
  -- forest into an advancing front with a defensible line instead of a mat.
  frontierRadius = 130,
  frontierMax    = 4,          -- neighbours within that radius before it stops
  spreadRange   = { 70, 190 },
  spreadReject  = 46,          -- min distance to another tree
  chewTime      = 5.0,         -- seconds a chomper needs to fell a tree
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
  fullForest  = 950,            -- tree-points that read as a fully restored sky
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
  budget     = { 26, 46, 74, 108, 150, 200, 262 },   -- floor for the night's spend
  budgetPerTree = 0.42,        -- ...plus this much for every tree you have grown
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
              spawnEvery = 4.5, shovesToClose = 6 },
  spawnEdgePad = 90,
  fleeOnDawn   = 8,             -- seconds to retreat and despawn at dawn
}

-------------------------------------------------------------------------- boss
T.boss = {
  -- The size of your workforce is the difficulty of the fight, exactly as in the
  -- 2019 original - but the bots only carry about three quarters of it, so the
  -- last stretch is always yours.
  hpPerBot     = 2.6,
  hpFloor      = 60,
  rebelCohort  = 8,            -- bots charge in waves, so the sacrifice has rhythm
  rebelEvery   = 2.5,
  phaseGap     = 6.0,          -- a phase always gets its moment before the next
  speed        = 108,
  contactDmg   = 1,
  phase2At     = 0.66,
  phase3At     = 0.33,
  rebelDelay   = 5.0,
  o2Drain      = 0.42,         -- % of sky the rig takes every second it lives
  beamCharge   = 1.5,
  beamSweep    = 3.2,
  slamEvery    = 6.0,
  droneEvery   = 5.0,
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

------------------------------------------------------------------------ camera
T.camera = {
  followRate  = 7.5,
  lookahead   = 0.28,          -- fraction of velocity projected ahead
  lookaheadMax = 130,
  deadzone    = 12,
  zoom        = 1.25,
  zoomAim     = 1.16,
  edgePad     = 40,
}

return T
