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
  plant  = { cost = 3, cooldown = 0.45 },
  carry  = { speedMul = 0.66, pickupRange = 34 },
  lamp   = { radius = 190, warm = 0.85 },
}

------------------------------------------------------------------------ economy
T.cobalt = {
  nodeYield      = 4,          -- chunks per deposit
  nodeRespawn    = 26,         -- seconds
  nodesAtStart   = 22,
  nodeMax        = 30,
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
    plantEvery = 9.0, minTreeGap = 46, wanderRetarget = { 1.2, 3.4 },
    desc = "Wanders and plants saplings, forever.",
  },
  builder = {
    label = "BUILDER", prefix = "FRAME", cost = 35, hp = 5, radius = 15, speed = 66,
    buildEvery = 14.0, carryStart = 3, carryMax = 6,
    desc = "Builds new Planters from cobalt it finds.",
  },
  repulsor = {
    label = "REPULSOR", prefix = "PYLON", cost = 5, hp = 4, radius = 14, speed = 0,
    pulseEvery = 3.4, radius_pulse = 200, force = 620, charges = 10, stun = 0.6,
    desc = "Static. Ten shockwaves, then it powers down.",
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

  downedTime   = 20,           -- seconds a bot survives at 0 hp before expiring
  bootTime     = 0.9,
  chatterEvery = { 9, 26 },
}

-------------------------------------------------------------------------- trees
T.tree = {
  growTime      = 26,          -- sapling -> mature
  elderTime     = 150,         -- mature -> elder (with the Old Growth chip)
  spreadEvery   = { 34, 58 },  -- seconds between seedling attempts
  spreadRange   = { 70, 190 },
  spreadReject  = 62,          -- min distance to another tree
  chewTime      = 9.0,         -- seconds a chomper needs to fell a tree
  o2Sapling     = 0.35,
  o2Mature      = 1.0,
  o2Elder       = 2.0,
  maxTrees      = 900,
  windSway      = 0.055,
}

----------------------------------------------------------------------- oxygen
T.o2 = {
  target        = 100,          -- percent
  perTreeSecond = 0.0125,       -- % per mature tree per second
  decayPerSec   = 0.006,        -- the atmosphere leaks; forests must out-run it
  siphonDrain   = 0.42,         -- % per second per feeding siphon
}

------------------------------------------------------------------------ cycles
T.cycle = {
  count      = 7,
  dayLen     = { 78, 84, 90, 94, 98, 104, 110 },
  duskLen    = 12,
  nightLen   = { 52, 62, 70, 78, 86, 94, 104 },
  budget     = { 26, 46, 74, 108, 150, 200, 262 },   -- director spend per night
  maxAlive   = { 14, 20, 26, 32, 38, 44, 52 },
}

----------------------------------------------------------------------- enemies
T.enemy = {
  chomper = { cost = 4,  hp = 3,  speed = 74,  radius = 14, damage = 1, from = 1 },
  skitter = { cost = 5,  hp = 2,  speed = 168, radius = 11, damage = 1, from = 2 },
  spitter = { cost = 9,  hp = 4,  speed = 62,  radius = 14, damage = 1, from = 3,
              range = 280, fireEvery = 2.6, projSpeed = 330, puddle = 6 },
  siphon  = { cost = 11, hp = 5,  speed = 52,  radius = 16, damage = 0, from = 3, float = true },
  bulwark = { cost = 18, hp = 14, speed = 44,  radius = 22, damage = 2, from = 4, armoured = true },
  maw     = { cost = 34, hp = 22, speed = 0,   radius = 30, damage = 0, from = 5,
              spawnEvery = 4.5, shovesToClose = 6 },
  spawnEdgePad = 90,
  fleeOnDawn   = 8,             -- seconds to retreat and despawn at dawn
}

-------------------------------------------------------------------------- boss
T.boss = {
  hpPerBot     = 1,
  hpFloor      = 12,
  speed        = 108,
  contactDmg   = 1,
  phase2At     = 0.66,
  phase3At     = 0.33,
  rebelDelay   = 5.0,
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
  zoom        = 1.0,
  zoomAim     = 0.94,
  edgePad     = 40,
}

return T
