-- The single source of colour for the whole game.
-- Nothing outside this file may contain a colour literal.
local U = require("src.core.util")

local P = {}

local function hex(s, a)
  s = s:gsub("#", "")
  return {
    tonumber(s:sub(1, 2), 16) / 255,
    tonumber(s:sub(3, 4), 16) / 255,
    tonumber(s:sub(5, 6), 16) / 255,
    a or 1,
  }
end
P.hex = hex

--------------------------------------------------------------------- ramps
-- Every material is a 4-stop ramp: shadow, base, light, rim.
-- Chroma is deliberate: a stylised frame lives or dies on whether the greens
-- separate from each other. `grass` is the warm sunlit sward, `moss` is the
-- cool blue-green counterweight, and the two leaf ramps straddle them, so a
-- forest built from all four never collapses into one olive mass.
P.ramp = {
  grass  = { hex "#143a26", hex "#357d42", hex "#66b64f", hex "#9ade5c" },
  moss   = { hex "#0d2b23", hex "#1b5340", hex "#2f8659", hex "#57c48c" },
  soil   = { hex "#261a12", hex "#452e1d", hex "#6b4c2d", hex "#957044" },
  sand   = { hex "#5e4527", hex "#a08049", hex "#d6b374", hex "#f6e2ad" },
  rock   = { hex "#161d27", hex "#2b3a4b", hex "#4a5a6b", hex "#7a8b9b" },
  -- Bedded stone: the spines the forest cannot close. `rock` above stays the
  -- cold blue-grey of loose pebbles, machine-struck craters and gravel; a
  -- standing cliff face needs a ramp that *warms* as it rises, or the sun has
  -- nothing to land on and the whole headland reads as slate. Lower in value
  -- than `rock` too, so a spine does not glow through a night grade.
  stone  = { hex "#15171b", hex "#2d2f33", hex "#4e4f50", hex "#7b7a74" },
  water  = { hex "#031321", hex "#093c5b", hex "#0f86a3", hex "#a9f0f2" },
  bark   = { hex "#26170f", hex "#412b1a", hex "#634427", hex "#8c6339" },
  leaf   = { hex "#0f3a2a", hex "#1d7047", hex "#37a95a", hex "#6ed861" },
  leafHi = { hex "#204527", hex "#428f45", hex "#77cf58", hex "#a9e95f" },
  metal  = { hex "#1d262e", hex "#4c5f6c", hex "#96abb7", hex "#e2eef4" },
  metalW = { hex "#2b2119", hex "#67543c", hex "#a98c66", hex "#e6d7b4" }, -- warm/brass bots
  -- The last human's pressure suit. It used to be cut from `metalW`, and a warm
  -- tan is *exactly* the value and the chroma of sunlit grass -- at play scale
  -- the one character in the game you must never lose track of dissolved into
  -- the ground he was standing on. This ramp is deliberately the darkest and
  -- coolest thing that walks on the island, so he separates from the sward by
  -- value and by hue at once and the only bright marks on him -- the visor, the
  -- chest lamp, one hard rim -- are read as *him* and not as scenery.
  suit   = { hex "#0b1119", hex "#22303d", hex "#3f5b6b", hex "#a8d8f0" },
  -- The blight is a *bruise*, not a sweet. The wide-area stops are near-neutral
  -- so a scar reads by value and texture; only the last stop is allowed to be
  -- hot, and it is only ever used on hairline veins.
  blight = { hex "#150a17", hex "#33202f", hex "#6b2a6b", hex "#d552bd" },
  -- Dead, poisoned ground: warm ash over cold cinder. Carries the scar's value
  -- structure so the purple never has to.
  ash    = { hex "#151215", hex "#2b2422", hex "#4d423a", hex "#857665" },
  rift   = { hex "#170430", hex "#3d0f6b", hex "#7b2ff7", hex "#c79bff" },
}

P.ramp.cobalt = { hex "#062435", hex "#0f5f89", hex "#3fb6f0", hex "#cdf1ff" }
P.ramp.ember  = { hex "#3a1405", hex "#8a3a0b", hex "#e07a1f", hex "#ffd98a" }

--------------------------------------------------------------------- singles
P.ink        = hex "#e9f4f0"
P.inkDim     = hex "#9fb3ba"
P.inkFaint   = hex "#5f747d"
P.accent     = hex "#4fe3a8"
P.accentCool = hex "#7ba9ff"
P.warn       = hex "#ffb63d"
P.danger     = hex "#ff5470"
P.black      = hex "#05070b"
P.white      = hex "#ffffff"
P.eye        = hex "#ffc46b"
P.eyeDown    = hex "#ff6a4d"
-- The crew's own eye, and it is not `eye`. An amber that hot is orange (hue 33
-- degrees); bloom it, run it through the extraction's cool grade and it lands a
-- short walk from `danger` (349) and the Blight's own bar, so your friends
-- ended up glowing like the thing eating them. This is blue, because blue is
-- what the crew's light is, and an eye that does not match the lamp behind it
-- is two machines. `eye` stays exactly where it belongs: on a Beacon's
-- lantern, which is a lamp and ought to be warm.
P.botEye     = hex "#8fd4ff"

-- The night's colour language. After dusk the scene is multiplied by the
-- lighting buffer, so the light a thing puts back is most of what you can see
-- of it -- which makes these three colours the difference between reading a
-- night at a glance and reading the minimap instead.
--
--   red     something that wants to hurt you
--   blue    your crew
--   yellow  you, and the beacons you planted
--
-- Nothing else may borrow them. The bot eye above is in the blue family for
-- the same reason: it used to be amber, which under the extraction's teal
-- grade came back salmon-pink -- the same family as P.danger -- so at the one
-- moment the game is about your crew, your crew glowed like the enemy.
P.lightHostile = hex "#ff4a3d"
P.lightFriend  = hex "#5cb8ff"
P.lightPlayer  = hex "#ffd15c"
P.love       = hex "#ff7ba8"
P.acid       = hex "#b6ff3d"
P.o2         = hex "#6fe4ff"
-- Sun-bleached sage. The only thing that lives on bare rock, and deliberately
-- outside every green ramp so a lichen patch never reads as grass or moss.
P.lichen     = hex "#7f8f68"
-- Necrosis. A bruise is plum at its heart and goes olive-yellow at the margins
-- as it dies down, and that pair is the only hue a blight scar's wide areas get
-- (the plum is `blight`'s second stop). Barely a hue at all on purpose: a scar
-- reads by value and texture, and anything more saturated over that much of the
-- screen turns dead ground into a colour swatch.
P.necrosis   = hex "#6b6a44"
-- The two colours of an airless world, used only by the oxygen grade in
-- daynight.lua. Eleven days without an atmosphere is not a *dirty* sky, it is
-- an *absent* one: nothing left up there to scatter blue, so the light arrives
-- unfiltered and everything under it goes to bone and dust. Both of these are
-- deliberately pale and warm-neutral rather than brown -- the failure mode of a
-- "dead world" grade is a sepia filter, and the fix is to bleach the frame
-- instead of dirtying it.
--
-- `deadHaze` is the dust hanging in the daylight; it is washed over the whole
-- frame by the fog step, so it must be *lighter* than the scene or the island
-- goes muddy instead of dry.
P.deadHaze   = hex "#e8d3a6"
-- `deadShade` is the hue the shadows take when there is no sky to tint them.
-- Only the *hue* is used -- the grade normalises this one to unit luminance
-- before using it as a gain -- so read it as "warm stone", not as a
-- brightness. More chromatic than the haze because of that normalisation: at
-- the tint amount the post chain runs, a colour this saturated still only
-- lands about +10% red and -20% blue on a shadow.
P.deadShade  = hex "#c2a578"

-- Dying grass, for the few metres of living ground a scar has already reached.
-- Grass does not go grey when it dies, it goes straw and lies down; a scar that
-- fades out through neutral grey wears a halo, and the halo is the tell.
P.wither     = hex "#8a7c4a"

--------------------------------------------------------- time-of-day ambients
-- Each entry: ambient light colour, exposure, and the fog/atmosphere tint.
P.tod = {
  dawn  = { amb = hex "#ffb98c", exposure = 1.08, fog = hex "#ffd2a6", strength = 0.50 },
  day   = { amb = hex "#ffffff", exposure = 1.14, fog = hex "#c8e6ff", strength = 0.11 },
  dusk  = { amb = hex "#b06a9c", exposure = 1.00, fog = hex "#e88bab", strength = 0.46 },
  night = { amb = hex "#3a63a6", exposure = 0.86, fog = hex "#0f2447", strength = 0.66 },
}

--------------------------------------------------------------------- helpers
--- Look up a ramp stop with a float index (1..4), blending between stops.
function P.shade(ramp, t, alpha)
  t = U.clamp(t, 1, 4)
  local i = math.floor(t)
  local f = t - i
  local a = ramp[i]
  local b = ramp[math.min(i + 1, 4)]
  return { U.lerp(a[1], b[1], f), U.lerp(a[2], b[2], f), U.lerp(a[3], b[3], f), alpha or 1 }
end

function P.mix(a, b, t, alpha)
  return {
    U.lerp(a[1], b[1], t), U.lerp(a[2], b[2], t), U.lerp(a[3], b[3], t),
    alpha or U.lerp(a[4] or 1, b[4] or 1, t),
  }
end

function P.alpha(c, a) return { c[1], c[2], c[3], a } end

--- Multiply brightness, keeping alpha.
function P.scale(c, k, a) return { c[1] * k, c[2] * k, c[3] * k, a or c[4] or 1 } end

--- Perceptual-ish lighten toward white.
function P.lighten(c, t, a) return P.mix(c, P.white, t, a or c[4]) end
function P.darken(c, t, a) return P.mix(c, P.black, t, a or c[4]) end

--- HSV -> linear-ish rgb table, for procedural variety.
function P.hsv(h, s, v, a)
  h = (h % 1) * 6
  local i = math.floor(h)
  local f = h - i
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  local r, g, b
  if i == 0 then r, g, b = v, t, p
  elseif i == 1 then r, g, b = q, v, p
  elseif i == 2 then r, g, b = p, v, t
  elseif i == 3 then r, g, b = p, q, v
  elseif i == 4 then r, g, b = t, p, v
  else r, g, b = v, p, q end
  return { r, g, b, a or 1 }
end

------------------------------------------------------ NEW: the radio and the sky
-- The narrative pass, in one block so a concurrent edit merges cleanly.
--
-- `radioLamp` is the Home Rig's radio beacon, and it is the one warm orange
-- that turns. Deliberately deeper and redder than `eye` -- a Beacon's lantern
-- is a pale honey and reads as somewhere to carry the fallen; this reads as a
-- filament, and the two are never on screen close enough to be compared. It is
-- small, it is one bead, and it never bloomed hard enough to join the night's
-- red vocabulary in practice; if it ever does, take value out of it, not hue.
P.radioLamp  = hex "#ff9418"
-- The point of light that crosses the top of the frame three times before the
-- Harvester Prime lands. Not a colour with an opinion: a cold white with just
-- enough blue in it to sit outside every warm thing on the island, so it reads
-- as *far away* rather than as another lamp somebody lit.
P.skyContact = hex "#dce8f4"

--------------------------------------------------- NEW: the ones who were here
-- Relics. The island carries a handful of hand-authored objects that say people
-- worked here and are not here now (see src/entities/relic.lua). They are drawn
-- from these four values and from the ramps above, and nothing else in the game
-- uses them, so the whole vocabulary of "abandoned" can be re-tuned from one
-- block.
--
-- `derelict` is the ramp everything dead is cut from, and it is deliberately
-- NOT `metal`. A bot, a Repulsor, the Home Rig -- every working machine on the
-- island is `metal` or `metalW`, both of which run bright and blue at the top.
-- This one is darker at every stop, and its highlight is a grey rather than a
-- near-white, so a wreck reads as *matte* next to anything that is still
-- switched on. A player should be able to tell at a hundred yards whether a
-- silhouette is worth walking to, and the answer must always be no.
-- Lifted once already: cut two stops lower than this, every relic on a sunlit
-- meadow read as a hole in the ground rather than as an object standing on it.
-- The boss can be the darkest mass in the frame because it is ninety units
-- across; a twenty-four unit suit cannot.
P.ramp.derelict = { hex "#191d22", hex "#333c44", hex "#5b6873", hex "#96a2aa" }
-- Poured concrete under a dead sky. Warm grey-buff rather than the cold blue of
-- `rock`, because a slab a person laid is not the same material as the island's
-- own stone and the two must not read as one thing.
P.ramp.concrete = { hex "#3a3730", hex "#6d675b", hex "#948b7b", hex "#c0b6a2" }

-- Oxide bleeding out of a seam. Warm, low and desaturated: bright rust is a
-- decorative colour and this is a stain, so it never runs above the value of
-- the metal it is running down.
P.rust       = hex "#6f4326"
-- Sun-killed paint. Every painted mark a person left -- a lane line, a cargo
-- strap, a stencil edge -- is this, at a low alpha. It is the same chalky bone
-- as `deadHaze` because it has been under the same dead sky for eleven days.
P.chalk      = hex "#cabfa6"
-- What grows back over the edge of a thing nobody maintains any more. A single
-- colour rather than a ramp, used at low alpha over the rim of a slab or the
-- verge of a road: the tell that says a hard edge is old is that the ground has
-- started eating it.
P.encroach   = hex "#2c5f39"

---------------------------------------------- NEW: what a machine has been through
-- Two colours, and they are the only ones the per-bot wear system uses (see
-- `Bot:drawWear`). Everything else it needs -- the patina on the hull, the
-- brightened rim -- it takes off `P.ramp.metal`, because a machine that has
-- been out for four nights is the same metal, darker.
--
-- Neither of these may be red, the crew's blue, or the player's yellow. After
-- dusk the frame is multiplied by the lighting buffer and those three colours
-- are the whole of the night's language -- something that wants to hurt you,
-- your crew, you -- so a service mark that borrowed one would be a lie told at
-- the exact moment the player is reading colour and nothing else.
--
-- `wearMark` is the mark itself: one per night survived, scored into the
-- plating. Bone rather than white, and only just warm, so it separates from the
-- cool near-white rim it sits a few pixels away from -- at play scale a machine
-- is thirty pixels tall and two near-whites would be one near-white.
P.wearMark   = hex "#d9cdb2"
-- ...and the dark it is scored into: the shadow inside an opened seam, and the
-- cut a fall leaves. Deliberately above `P.black` -- a true black hole in a
-- chassis reads as a missing polygon rather than as damage.
P.wearCut    = hex "#0e141a"


return P
