-- Dawn draft upgrades. A chip is data: an id, a family, a rarity, copy, and a
-- table of modifiers (or a hook). The active set answers `get`/`has` queries
-- that behaviour code makes.
local Class  = require("src.core.class")
local U      = require("src.core.util")
local Signal = require("src.core.signal")

local Chips = Class("Chips")

local F = { GROWTH = "GROWTH", COMBAT = "COMBAT", LOGISTICS = "LOGISTICS",
            BOTS = "BOTS", PLAYER = "PLAYER" }
Chips.families = F

-- rarity: 1 common, 2 uncommon, 3 rare
local C = {
  ---------------------------------------------------------------- growth
  { id = "mycelium",   f = F.GROWTH, r = 1, name = "MYCELIUM",     desc = "Trees spread 25% faster.",              mod = { spreadRate = 1.25 } },
  { id = "deepRoots",  f = F.GROWTH, r = 1, name = "DEEP ROOTS",   desc = "Trees take 40% longer to chew down.",   mod = { chewTime = 1.4 } },
  { id = "oldGrowth",  f = F.GROWTH, r = 3, name = "OLD GROWTH",   desc = "Mature trees become elders. Elders make double oxygen.", flag = true },
  { id = "rainMemory", f = F.GROWTH, r = 2, name = "RAIN MEMORY",  desc = "Rain lasts twice as long and doubles growth.", flag = true },
  { id = "seedBank",   f = F.GROWTH, r = 2, name = "SEED BANK",    desc = "Hand-planting is free.",                flag = true },
  { id = "canopy",     f = F.GROWTH, r = 2, name = "CANOPY",       desc = "Trees within 90px of three others grow 35% faster.", flag = true },
  { id = "hardBark",   f = F.GROWTH, r = 1, name = "HARD BARK",    desc = "Saplings survive one acid hit.",        flag = true },
  { id = "pioneer",    f = F.GROWTH, r = 2, name = "PIONEER",      desc = "Trees can root in blight scars, and heal them.", flag = true },
  { id = "fastRoot",   f = F.GROWTH, r = 1, name = "FAST ROOT",    desc = "Saplings mature 30% sooner.",           mod = { growRate = 1.3 } },

  ---------------------------------------------------------------- combat
  { id = "kineticCuffs", f = F.COMBAT, r = 1, name = "KINETIC CUFFS", desc = "Shove arc +40%.",                    mod = { shoveArc = 1.4 } },
  { id = "longArm",      f = F.COMBAT, r = 1, name = "LONG ARM",      desc = "Shove reach +35%.",                  mod = { shoveRange = 1.35 } },
  { id = "recoil",       f = F.COMBAT, r = 2, name = "RECOIL",        desc = "Every shove that connects refunds 1 cobalt.", flag = true },
  { id = "thornburst",   f = F.COMBAT, r = 3, name = "THORNBURST",    desc = "Killed Blight leaves a spore cloud that damages its kin.", flag = true },
  { id = "kickstart",    f = F.COMBAT, r = 2, name = "KICKSTART",     desc = "Dashing releases a small shockwave.", flag = true },
  { id = "overcharge",   f = F.COMBAT, r = 2, name = "OVERCHARGE",    desc = "Pulse radius +30% and costs 3 less.", mod = { pulseRadius = 1.3, pulseCost = -3 } },
  { id = "brittle",      f = F.COMBAT, r = 2, name = "BRITTLE",       desc = "Stunned Blight takes double damage.", flag = true },
  { id = "pinBreaker",   f = F.COMBAT, r = 3, name = "PIN BREAKER",   desc = "Your shove can move armoured Blight.", flag = true },

  ---------------------------------------------------------------- logistics
  { id = "veinSense",   f = F.LOGISTICS, r = 1, name = "VEIN SENSE",   desc = "Cobalt is outlined anywhere on the island.", flag = true },
  { id = "deepDeposit", f = F.LOGISTICS, r = 1, name = "DEEP DEPOSITS",desc = "Deposits yield 50% more.",           mod = { nodeYield = 1.5 } },
  { id = "lodestone",   f = F.LOGISTICS, r = 1, name = "LODESTONE",    desc = "Cobalt pickup range doubled.",       mod = { magnet = 2.0 } },
  { id = "tithe",       f = F.LOGISTICS, r = 2, name = "TITHE",        desc = "Harvesters carry 3 more, and gather faster.", mod = { harvestBonus = 1 } },
  { id = "salvage",     f = F.LOGISTICS, r = 2, name = "SALVAGE",      desc = "Lost bots refund half their cost.",  flag = true },
  { id = "richSeam",    f = F.LOGISTICS, r = 3, name = "RICH SEAM",    desc = "Deposits respawn twice as fast, and one extra is always out there.", mod = { nodeRespawn = 0.5 } },
  { id = "surplus",     f = F.LOGISTICS, r = 2, name = "SURPLUS",      desc = "Dawn pays out 1 cobalt per 4 living trees.", flag = true },

  ---------------------------------------------------------------- bots
  { id = "warranty",   f = F.BOTS, r = 3, name = "WARRANTY",     desc = "Every bot survives its first death once.", flag = true },
  { id = "chorus",     f = F.BOTS, r = 2, name = "CHORUS",       desc = "Bots near two others work and move 20% faster.", flag = true },
  { id = "secondShift",f = F.BOTS, r = 2, name = "SECOND SHIFT", desc = "Planters plant two saplings at a time.", flag = true },
  { id = "hardHat",    f = F.BOTS, r = 1, name = "HARD HAT",     desc = "Bots have +2 health.",                  mod = { botHp = 2 } },
  { id = "brightEyes", f = F.BOTS, r = 1, name = "BRIGHT EYES",  desc = "Bot lights are larger and warmer.",     mod = { botLight = 1.6 } },
  { id = "quickBoot",  f = F.BOTS, r = 1, name = "QUICK BOOT",   desc = "Bots boot instantly and cost 15% less.", mod = { botCost = 0.85 } },
  { id = "medic",      f = F.BOTS, r = 2, name = "FIELD MEDIC",  desc = "Downed bots last twice as long, and revive faster.", mod = { downedTime = 2 } },
  { id = "swarm",      f = F.BOTS, r = 3, name = "SWARM LOGIC",  desc = "Builders build 40% faster and start with 6 cobalt.", mod = { buildRate = 1.4 } },
  { id = "sentinel",   f = F.BOTS, r = 2, name = "SENTINEL",     desc = "Sentries fire 30% faster and further.", mod = { sentryRate = 1.3, sentryRange = 1.25 } },
  { id = "lampOil",    f = F.BOTS, r = 2, name = "LAMP OIL",     desc = "Beacon fields are 35% wider.",          mod = { beaconRadius = 1.35 } },

  ---------------------------------------------------------------- player
  { id = "longLegs",   f = F.PLAYER, r = 1, name = "LONG LEGS",   desc = "Move 12% faster.",                     mod = { moveSpeed = 1.12 } },
  { id = "heldBreath", f = F.PLAYER, r = 3, name = "HELD BREATH", desc = "One more heart.",                      mod = { hearts = 1 } },
  { id = "afterimage", f = F.PLAYER, r = 2, name = "AFTERIMAGE",  desc = "Dash cooldown -35%.",                  mod = { dashCd = 0.65 } },
  { id = "steadyHand", f = F.PLAYER, r = 1, name = "STEADY HAND", desc = "Invulnerability after a hit lasts 60% longer.", mod = { invuln = 1.6 } },
  { id = "greenThumb", f = F.PLAYER, r = 2, name = "GREEN THUMB", desc = "Hand-planted trees start half grown.", flag = true },
  { id = "lastLight",  f = F.PLAYER, r = 3, name = "LAST LIGHT",  desc = "Below one heart, time slows and you move faster.", flag = true },
}

Chips.catalogue = C
local byId = {}
for _, c in ipairs(C) do byId[c.id] = c end
Chips.byId = byId

function Chips:init()
  self.owned = {}
  self.mods = {}
  self.list = {}
end

function Chips:add(chip)
  if type(chip) == "string" then chip = byId[chip] end
  if not chip then return end
  self.owned[chip.id] = (self.owned[chip.id] or 0) + 1
  self.list[#self.list + 1] = chip
  if chip.mod then
    for k, v in pairs(chip.mod) do
      -- multiplicative for ratios (>0 and near 1), additive for the rest
      if self.mods[k] == nil then
        self.mods[k] = v
      elseif v > 0 and v < 5 and math.abs(v - 1) < 1 then
        self.mods[k] = self.mods[k] * v
      else
        self.mods[k] = self.mods[k] + v
      end
    end
  end
  Signal.emit("chip:added", chip)
end

function Chips:has(id) return (self.owned[id] or 0) > 0 end
function Chips:get(key, default)
  local v = self.mods[key]
  if v == nil then return default end
  return v
end
function Chips:count() return #self.list end

--- Three distinct offers, weighted by rarity and biased away from what you have.
function Chips:draft(rng, n, cycle)
  n = n or 3
  local pool = {}
  for _, c in ipairs(C) do
    if not self:has(c.id) then
      local weight = (c.r == 1 and 6 or (c.r == 2 and 3 or 1))
      weight = weight + (cycle or 1) * (c.r - 1) * 0.6      -- rares get likelier late
      for _ = 1, math.max(1, math.floor(weight)) do pool[#pool + 1] = c end
    end
  end
  local out, seen = {}, {}
  local guard = 0
  while #out < n and guard < 400 do
    guard = guard + 1
    local c = rng:pick(pool)
    if c and not seen[c.id] then seen[c.id] = true out[#out + 1] = c end
  end
  return out
end

return Chips
