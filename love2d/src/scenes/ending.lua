-- The ending.
--
-- It gets the real world, with the forest the player actually grew still
-- standing in it, and it does not cut away from that once. Nothing here is a
-- results screen laid over a black rectangle: the tally grows up through the
-- trees that produced it.
--
-- Order of events:
--   quiet    the boss is gone and nothing moves. Longer than is comfortable.
--   gather   every surviving bot walks in and forms a ring around the player.
--   settle   they stand there. Nobody says anything.
--   words    script.ending -- "the world is safe", and the suit comes off. The
--            script takes the dialogue panel away for the silence in the
--            middle of it, so there is nothing on the screen but the ring.
--   after    silence, held past the point where a game would normally cut.
--   credits  the tally and the names, scrolling up over the forest.
--
-- The ring is the image the whole game is for, and by this point the island is
-- eight hundred trees deep, so the canopy x-ray is pointed at the whole circle
-- rather than at the player's shoulders: without it the last shot of the game
-- is a wall of leaves with a letterbox on it.
--
-- Every stage can be skipped with `back`; skipping always lands you further
-- down this same list, never on a black screen.
local U        = require("src.core.util")
local Settings = require("src.game.settings")
local P        = require("src.engine.palette")
local Signal   = require("src.core.signal")
local Input    = require("src.engine.input")
local Screen   = require("src.engine.screen")
local Opt      = require("src.core.optional")
local Camera   = require("src.engine.camera")
local TU       = require("src.game.tuning")
local Script   = require("src.game.script")
local Dialogue = require("src.game.dialogue")
local Story    = require("src.game.story")

local Draw     = Opt.require("src.engine.draw")
local Text     = Opt.require("src.engine.text")
local UI       = Opt.require("src.engine.ui")
local VFX      = Opt.require("src.engine.vfx")
local Audio    = Opt.require("src.engine.audio")
local Music    = Opt.require("src.engine.music")
local DayNight = Opt.require("src.engine.daynight")
local Lighting = Opt.require("src.engine.lighting")
local Post     = Opt.require("src.engine.postfx")
local Wind     = Opt.require("src.world.wind")
local Tree     = Opt.require("src.entities.tree")
local Bot      = Opt.require("src.entities.bot")

local lg = love.graphics
local floor, max, min = math.floor, math.max, math.min

local S = {}

------------------------------------------------------------------------ tuning
local T = {
  quiet     = 3.2,
  gatherDur = 4.6,       -- everyone arrives together, however far out they were
  settle    = 3.0,       -- they stand there. Nobody says anything.
  after     = 3.4,       -- silence after the last word. This is the whole point.
  ringGap   = 32,        -- arc length each bot wants on the circle
  ringMin   = 132,
  ringMax   = 226,
  gatherFar = 2400,      -- further out than this and it would read as a teleport
  -- Framing is derived from the ring, not fixed: two survivors and forty want
  -- the same picture, and 1.72 on a full-grown island is a close-up of a leaf.
  ringFrame = 405,       -- world half-height the ring should occupy on screen
  openTime  = 3.4,       -- seconds for the canopy over the circle to thin out
  -- What a tree standing inside the circle fades to. This was 0.16 and the
  -- last shot of the game was milky: three hundred canopies at sixteen percent
  -- stacked into an opaque veil over the one image the whole run is for. They
  -- get out of the way properly now, on a soft edge so the opening reads as a
  -- clearing rather than as a hole cut in a texture.
  openFade  = 0.02,
  openSoft  = 0.42,      -- squared radius inside which the canopy is fully gone
  openW     = 1.45,      -- the opening, as a multiple of the ring radius
  openH     = 1.25,
  zoomIn    = 1.20,
  zoomMax   = 1.80,
  zoomMin   = 0.88,
  zoomOut   = 0.70,
  scroll    = 46,        -- credits, pixels per second
  -- The memorial. It used to keep the gameplay camera: a slow pull all the way
  -- out to 0.70 over twenty-six seconds, which put the whole island under the
  -- names and never stopped moving. A memorial that drifts is restless. The
  -- push is now a tenth of that and it is over in the first ten seconds; after
  -- that the frame is still and the names are the only thing on it that moves.
  memZoom   = 0.92,      -- ...as a fraction of the framing the ring settled on
  memSettle = 10,        -- seconds the last of the push takes
  -- Pushing the world back behind the names. Not a curtain -- the restored
  -- forest is the point of the image -- but it stops being the subject: down
  -- two thirds of a stop, half the chroma, and further into the air.
  memBack   = 5.0,       -- seconds to fall back over
  memExpo   = 0.62,
  memSat    = 0.50,
  memBloom  = 0.55,
  memFog    = 0.62,      -- floor under the atmosphere wash while the list runs
  -- The scrim the names sit in. A wide soft column, so the frame keeps its
  -- bright edges and the type keeps its contrast wherever the world drifts.
  memDim    = 0.30,      -- over the whole frame
  memBand   = 0.62,      -- ...and again down the column
  memFeather= 190,       -- how far the column takes to fade out sideways
  -- ...but NOT YET. The column exists so that 13px caption type survives over a
  -- sunlit canopy, and the first thing it lands on is the title card -- which
  -- is 46px display type with its own shadow, needs none of it, and is sitting
  -- directly over the tableau the scene has spent forty seconds staging. At
  -- full strength the ring the player has just been shown is a grey smudge
  -- behind the game's name. The column comes up later and slower than the
  -- overall dim, and is at full strength by the time the first name arrives.
  memBandFrom = 3.0,
  memBandRise = 8.0,
  -- Where the last line comes to rest, as a fraction of screen height, and how
  -- long it is held there. The last thing the game says should be read, not
  -- watched sliding off the top edge.
  restAt    = 0.62,
  restHold  = 9.0,
  -- The air the ending is graded for. The world stopped being updated the
  -- moment the boss fell, so nothing is driving the oxygen grade any more and
  -- it would hold the reading the rig dragged it down to -- a bleached, airless
  -- sky behind "The world is safe." It comes back up to what the run actually
  -- reached instead, over the silence before he speaks.
  o2Rise    = 8.0,
  -- The turn at the end of the script is the image the whole game is for: he
  -- says he is alone while thirty machines stand there looking at him. The
  -- dialogue panel covers the bottom quarter of the frame while he says it and
  -- takes the near arc of the ring with it -- and the panel cannot simply be
  -- dropped for those lines, because its own alpha is driven off the letterbox
  -- and the lines would go unread. So the camera lifts instead, by half the
  -- panel, for exactly as long as the panel is up.
  panelPad  = 46,        -- world px of chassis-and-nameplate above and below
  -- THE TURN IS NOT SHOT ALONE -- and it must not be. Read this before you
  -- touch `turnClear`, `turnMin` or `turnMax`.
  --
  -- "Just me." / "All alone." / "Forever." -- and the helmet on the ground with
  -- the air hose still attached -- were played at the framing the whole ring
  -- settled on, which is a man 35 pixels tall and a helmet four pixels wide.
  -- The wide shot is the right image for the silence before it, where the point
  -- is how many of them are standing there; it is the wrong image for three
  -- lines about being alone. So the ending is two shots. The panel coming back
  -- up after the silence is the cut, and it pushes in to a portrait on him.
  -- Derived from the ring, like every other framing in this scene: a crew of
  -- six and a crew of forty get the same picture, which no fixed number does.
  --
  -- What the push ASKS for is "until the nearest machine on the circle is out
  -- of frame". IT NEVER GETS IT, and the arithmetic says it never can. The ring
  -- is r wide and 0.78r tall, so its widest axis is the horizontal -- which is
  -- the one `getWidth() * 0.5` below measures against -- and clearing it needs
  -- zoom > 800/r on a 1600px frame. `ringGap` puts the 33-machine crew of a
  -- finished run at r = 168, which asks for 4.8 against a `turnMax` of 3.6.
  -- Only a crew of about 44, standing at the full `ringMax` of 226 with the
  -- island wide enough that the circle kept its radius, ever comes in under the
  -- cap. Every real ending therefore stops AT 3.6 with the left and right
  -- shoulders of the circle still in shot: eight to fourteen machines, counted
  -- in captures.
  --
  -- THAT IS THE SHOT, AND IT IS THE BETTER ONE. The line is a man saying he is
  -- alone while the machines stand there looking at him; emptying the frame
  -- would make him right, and the irony is the whole image. What the cap buys
  -- is the half of the intent that was worth having -- off the wide, close
  -- enough to read his face, the crowd pressed to the edges instead of posed
  -- across the middle -- and it throws away the half that would have cost the
  -- scene its point.
  --
  -- So do not "correct" this to what the numbers claim. The ratio is what keeps
  -- a two-machine ending from being shot like a forty-machine one; the ceiling
  -- is what keeps the machines in the picture. Both stay.
  turnClear = 0.90,      -- how far past the half-frame the ring is pushed for
  turnMin   = 2.6,
  turnMax   = 3.6,       -- ...and the cap that always wins. See above.
  turnHush  = 2.0,       -- panel down this long and the silence has started
  turnSay   = 5.2,       -- ...and this far into it, one machine answers him
  -- The crowd does not introduce itself over the last shot of the game.
  -- Individuality is ONE name, not thirty-three: see `Bot.plateOnly`. The two
  -- machines the scene is written around keep their plates the whole way
  -- through, and because the guest list bypasses the distance ramp this no
  -- longer has to fight it.
  plateGain = 1.0,
  -- Dawn's fog is 0.50, which is right for a sky and wrong for the one shot
  -- the whole run is for: at full strength a pale peach veil sat over the ring
  -- of survivors for the first forty seconds of the ending and everything in
  -- the frame, bots included, read as translucent. The ending keeps dawn's
  -- colour and takes half its density, and the sun comes up faster.
  fogMul    = 0.42,
  sunrise   = 34,        -- seconds from first light to the sun being up
  barFrac   = 0.105,
}

--------------------------------------------------------------------- the world
--- Freeze the island: no blight, no boss, no orders.
local function hush(world)
  world.phase = "ending"
  world.cutscene = true
  world.boss = nil
  if world.enemies then
    for i = #world.enemies, 1, -1 do
      local e = world.enemies[i]
      e.alive = false
      world.enemies[i] = nil
    end
  end
  if world.projectiles then
    for i = #world.projectiles, 1, -1 do world.projectiles[i] = nil end
  end
  -- Nobody updates the world from here on, so anything left in the speech
  -- queue would hang over the ending forever. A bot saying "more sun today"
  -- across the last shot of the game is not a small problem.
  if world.speeches then
    for i = #world.speeches, 1, -1 do world.speeches[i] = nil end
  end
  -- the standing order outlived the thing it was standing against
  if world.clearRally then world:clearRally() end
  -- And settle the forest. Nothing updates a tree from here on either, so
  -- whatever pose a tree was holding when the rig fell is the pose it holds for
  -- the rest of the game -- including a trunk still mid-recoil from a shove.
  -- That recoil is an explicit spring integrated at the frame's own dt, so at
  -- the accelerated dt a capture runs at it does not decay, it diverges: the
  -- canopy shear in the tree shader is driven straight off it, and the last two
  -- minutes of the game were crossed by screen-wide green wedges where a tree's
  -- crown had been flung a thousand pixels sideways and frozen there. Nothing
  -- is going to shove these trees again; the shove is over.
  if world.trees then
    for i = 1, #world.trees do
      local t = world.trees[i]
      t.hitS, t.hitV = 0, 0
      t.swayNow, t.swayLag = 0, 0
    end
  end
end

--- Who is left. Anyone still on the ground gets helped up first.
local function survivors(world)
  local out = {}
  local list = world.bots or {}
  for i = 1, #list do
    local b = list[i]
    if b.alive and b.state ~= "dead" then
      if b.state == "down" then
        b.state = "work"
        b.hp = max(1, floor((b.maxHp or 2) * 0.5))
        b.carried = false
        if VFX.emit then VFX.emit("bot_boot", b.x, b.y, { power = 0.8 }) end
      end
      b.mood = "love"
      out[#out + 1] = b
    end
  end
  return out
end

--- What the run cost, in the order it cost it.
---
--- This list is NOT sorted. Sorting it alphabetically turns a memorial into an
--- inventory: it groups the dead by model number and throws away the one thing
--- the order carried, which is the shape of the run -- three names from the
--- night everything went wrong, sitting together.
---
--- Every name brings what that bot actually did.
---
--- `Bot:epitaph` is the PRIMARY SOURCE and it is the only one of the two that
--- has the machine itself to look at. Story keeps whatever it emitted at the
--- moment of death, keyed by name, and that is what nearly every line here is.
--- What follows is not a replacement for it: it is what to say when that line
--- is missing (a record restored from a save) or when it came back generic.
---
--- "was here" is the generic. It fires for any bot that died before it planted
--- or built anything, which in real runs is three names in fourteen -- and a
--- Planter that died before its first tree is the most affecting entry on the
--- list, so it is the worst possible place for the game to say nothing. Where
--- the record still carries a fact -- what the machine was built to do, and
--- which cycle took it -- the fact wins over the generic line.
---
--- Only the exact string "was here" is treated as generic. The type-constant
--- lines Bot:epitaph currently returns for the other four roles are left alone
--- even though they are just as repetitive, because they are that function's to
--- improve and it is being given a per-bot ledger to do it with.
local ORD = { "first", "second", "third", "fourth", "fifth", "sixth", "seventh" }
-- what a machine of each type was built to do. Only reached when Story has no
-- line at all for this name -- a record read back from a save.
local KEPT = {
  repulsor  = "held the line",
  beacon    = "kept a light on",
  sentry    = "stood watch",
  harvester = "carried what it found",
}
-- ...and what it did not get to do, for the two that make things. This is the
-- answer to "was here", and it is the truest thing the record can say about a
-- machine that was building the world and ran out of time doing it.
local NEVER = {
  planter = "never planted its first tree",
  builder = "never finished its first build",
}
local GENERIC = { ["was here"] = true }

--- Everything the memorial can honestly say from the record alone. Nothing
--- here is inferred: `cycle` is the cycle the loss was recorded in, so it can
--- only be reported as the cycle, not as a count of nights survived.
local function fromRecord(rec)
  if type(rec) ~= "table" then return nil end
  -- the memorial's one number rule, which these rows are on the same page as
  local count = (Bot and Bot.count) or tostring
  local n = rec.planted or 0
  if n > 0 then
    return "planted " .. count(n) .. (n == 1 and " tree" or " trees")
  end
  n = rec.built or 0
  if n > 0 then
    return "built " .. count(n) .. (n == 1 and " planter" or " planters")
  end
  local never = NEVER[rec.type]
  if never then return never end
  local kept = KEPT[rec.type]
  if kept then return kept end
  local ord = ORD[rec.cycle or 0]
  return ord and ("lost in the " .. ord .. " cycle") or nil
end

local function epitaphFor(name, rec)
  local ep = Story.epitaphs and Story.epitaphs[name]
  if ep and not GENERIC[ep] then return ep end
  return fromRecord(rec) or ep
end

local function fallenRecords(world)
  local out, seen = {}, {}
  local mem = world.memorial            -- Bot:epitaph left the whole ledger here
  local function push(rec)
    local name = (type(rec) == "table") and rec.name or rec
    if not name or seen[name] then return end
    seen[name] = true
    out[#out + 1] = { name = name,
                      clauses = mem and mem[name] or nil,
                      line = epitaphFor(name, rec) or "was here",
                      epitaph = epitaphFor(name, rec) or "was here" }
  end
  if world.allLostNames then
    for i = 1, #world.allLostNames do push(world.allLostNames[i]) end
  end
  if world.lostNames then
    for i = 1, #world.lostNames do push(world.lostNames[i]) end
  end
  -- and the ones that went at the rig, in the order the cohorts left
  if Story.sacrificed then
    for i = 1, #Story.sacrificed do push(Story.sacrificed[i]) end
  end
  return out
end

--------------------------------------------------------------- the memorial
--- THE PAGE COMPOSES THE ROW; THE MACHINE DOES NOT COMPOSE ITS OWN LINE.
---
--- Forty-two names and, on a real seven-cycle run, eight surviving sentences
--- between them, twenty-four of them beginning "planted". Ranking each row on
--- its own merits is what produced that: every Planter's rarest true fact is
--- that it planted, so every Planter says so and the page reads as a table
--- however good any single row is. A second clause per row does not fix it by
--- itself either -- forty rows independently picking their own next-best fact
--- puts "it stood through four nights." on fifteen of them and moves the
--- problem one clause to the right.
---
--- So the second clause is chosen HERE, where the whole list is in hand. The
--- page keeps a tally of every kind of clause it has already printed and a
--- candidate pays `T.bots.memorial.spread` ranks for each previous printing, so
--- a machine tends to be described by whatever is rarest about it on this
--- particular page rather than by whatever is rarest about it in the abstract.
--- Two runs with the same crew get different memorials, which is correct: the
--- page is about this run.
---
--- Three rules it will not break.
---
---   * The head clause is the machine's own ranked fact, and for the first
---     `T.bots.memorial.headMax` printings of that kind of fact the tally does
---     not get to move it. The work leads; that is the whole point of the
---     ranking, and a page that reshuffled every headline for variety would be
---     describing machines by what its neighbours had not said yet.
---
---     PAST THAT IT MAY BE DEMOTED, and this is the difference between a page
---     and a table. Most of a crew are Planters, so "planted" is the ranked
---     fact on most of the page; eleven consecutive rows were captured whose
---     head clause was the tree count and nothing else. By the fourth of those
---     the reader has stopped reading the fact and started reading the form. So
---     once a head kind has led `headMax` rows, a machine that has something
---     ELSE worth leading with -- see `LEAD` -- opens on that instead and the
---     work count moves into the second clause, where it is still said, still
---     exact, and no longer the first word for the tenth time. A machine with
---     nothing else to say still leads with its work: a page that padded to
---     avoid a pattern would be worse than the pattern.
---   * No row ever repeats the row above it word for word. Two identical
---     sentences in a row is the one thing a memorial cannot survive. A second
---     clause is tried first, then a demotion of the head.
---   * If the ledger cannot honestly support a second clause, the row prints
---     one. A memorial that pads is worse than a memorial that repeats.
---
--- Rows restored from a save have no clause list -- the ledger only exists on
--- the machine, and it went with it -- so those print the frozen line and take
--- no part in the tally.
local SECOND = {         -- clauses that can be a row's second sentence
  planted = true, built = true, lit = true, shots = true, mined = true,
  carried = true, saves = true, never = true, walked = true, nights = true,
  came = true, born = true,
  -- "first" is a headline and nothing else; "lasted" is what the page says
  -- when there is nothing to say, and it is never worth saying twice.
}

--- ...and the ones worth OPENING a row with once the work has saturated. Not
--- every second clause is a headline. "it came online on the third day" and
--- "it got up twice" are true, and they are footnotes; leading forty rows with
--- them would trade one template for a duller one. These four are facts a
--- reader would want first: what the player did with their hands, the machine
--- that never fell, the one that covered the whole island, and how long it
--- stood. Which of them a row actually gets is decided by the same page-wide
--- tally as the second clause, so a promoted headline that has already led
--- three rows is as expensive as any other repetition and the page moves on.
local LEAD = { carried = true, never = true, walked = true, nights = true }

--- Which wording of a clause to use, and the tally slot it belongs to. Only one
--- clause -- the tree count, which lands on two thirds of a long page -- has
--- more than one wording; the page takes whichever of the two it has used less.
--- Counted per WORDING and not per finished phrase, because every tree count is
--- a different phrase and a per-phrase tally would only ever alternate when two
--- machines happened to plant the same number.
---
--- ...AND THE TIE IS BROKEN BY THE ROW, NOT BY THE COUNTER. "Take whichever I
--- have used less" is a perfect alternator: the counts can never differ by more
--- than one, so the page printed planted / put / planted / put down eleven
--- consecutive rows. Two wordings in strict rotation are more obviously a
--- template than one wording repeated -- the reader stops seeing a fact and
--- starts seeing the machine that generated it. `jit` is a per-row coin from
--- the golden ratio: deterministic (the same run always composes the same
--- page), balanced (the counts still cannot drift apart, because the tie is all
--- it decides), and aperiodic -- so the page gets pairs in either order and
--- never a phase you can hear.
---
--- `avoid` is the sentence the row above opened with, and is passed only for a
--- row's HEAD. Two rows in a row that begin "planted five trees." are two
--- machines that happened to plant the same number, and the coin is not allowed
--- to put them under each other: that is the one collision the strict
--- alternation used to prevent by accident, and the page has always had a rule
--- against a row repeating the one above it.
local function phrase(c, worded, jit, avoid)
  if not c.alt then return c.text, c.key end
  local a, b = c.key .. "|a", c.key .. "|b"
  local na, nb = worded[a] or 0, worded[b] or 0
  local text, slot
  if na == nb then
    if jit then text, slot = c.alt, b else text, slot = c.text, a end
  elseif na < nb then text, slot = c.text, a
  else text, slot = c.alt, b end
  if avoid and text == avoid then
    if slot == a then return c.alt, b end
    return c.text, a
  end
  return text, slot
end

--- The coin. Row `i` of the page, off the golden ratio: no period a reader can
--- pick up, and no dependence on anything but which row this is.
local function rowJitter(i)
  return ((i * 0.6180339887) % 1) < 0.5
end

--- A clause as a sentence of its own. Most are bare predicates about the
--- machine and take "it"; the two the crew says about themselves keep theirs.
local function sentence(c, ph)
  return (c.subject and ph or ("it " .. ph)) .. "."
end

local function rowWidth(str, size)
  if Text.bodyMeasure then return (Text.bodyMeasure(str, size)) end
  return #str * size * 0.5
end

--- The clause on this machine worth opening its row with instead of its own
--- ranked fact, or nil for "nothing better than the work". Scored like a second
--- clause -- rank, then what the page has already spent on that kind of fact --
--- so a promotion is as page-aware as every other choice here, and a promoted
--- headline saturates in its turn.
local function bestLead(list, used, said, worded, heads, jit, MEM)
  local best, bestScore
  for i = 2, #list do
    local c = list[i]
    local ph = phrase(c, worded, jit)
    -- Three things a promotion has to be. In the machine's LEAD set; under the
    -- same ceiling as the headline it is replacing, or the commonest of them --
    -- every machine has stood through some number of nights -- just becomes the
    -- new first word of the page; and a sentence this page has not printed yet.
    --
    -- That last one is not a nicety. `said` counts second clauses too, and
    -- without it the page put "it walked the whole island." at the end of one
    -- row and "walked the whole island." at the head of the next, and led two
    -- consecutive rows with "stood through two nights." A work count at least
    -- has a different number in it every time; a promoted headline that is not
    -- new is strictly worse than the template it was promoted over.
    if LEAD[c.key] and (heads[c.key] or 0) < MEM.headMax and (said[ph] or 0) == 0 then
      local sc = i + MEM.spread * min(used[c.key] or 0, MEM.spreadCap)
      if not bestScore or sc < bestScore then best, bestScore = i, sc end
    end
  end
  return best
end

--- One row. `used` counts kinds of fact, `said` counts finished sentences,
--- `heads` counts kinds of fact that have LED a row, `prev` is the line above.
local function composeRow(list, used, said, worded, heads, jit, prev, prevHead,
                          maxW, size)
  local MEM = TU.bots.memorial
  local cand = {}
  local function claim(c, ph, vk)
    used[c.key] = (used[c.key] or 0) + 1
    said[ph] = (said[ph] or 0) + 1
    worded[vk] = (worded[vk] or 0) + 1
  end

  -- Which entries of the list to try as the head, in order. The machine's own
  -- ranked fact, then -- only if that collides with the row above and nothing
  -- else will separate them -- the fact under it. Ahead of both, once that kind
  -- of fact has already led `headMax` rows, whatever this machine has that is
  -- worth leading with instead.
  local promoted
  if list[1] and (heads[list[1].key] or 0) >= MEM.headMax then
    promoted = bestLead(list, used, said, worded, heads, jit, MEM)
  end
  local order, nOrder = {}, 0
  if promoted then nOrder = 1 order[1] = promoted end
  for h = 1, math.min(#list, 2) do
    if h ~= promoted then nOrder = nOrder + 1 order[nOrder] = h end
  end

  for oi = 1, nOrder do
    local h = order[oi]
    local head = list[h]
    local hp, hv = phrase(head, worded, jit, prevHead)
    local n = 0
    for i = 1, #list do
      local c = list[i]
      if i ~= h and SECOND[c.key] and c.key ~= head.key then
        n = n + 1
        cand[n] = c
        c._ph, c._vk = phrase(c, worded, jit)
        c._say = sentence(c, c._ph)
        c._score = i + MEM.spread * min(used[c.key] or 0, MEM.spreadCap)
                     + MEM.exact * (said[c._ph] or 0)
        -- A DEMOTED HEADLINE IS MOVED, NOT DROPPED. When the row opens on a
        -- promoted clause, the machine's own ranked fact takes the second
        -- sentence ahead of everything else: the page decided it should not
        -- LEAD forty rows, not that this machine's work should go unsaid.
        if h == promoted and i == 1 then c._score = -1 end
      end
    end
    for i = n + 1, #cand do cand[i] = nil end
    table.sort(cand, function(a, b) return a._score < b._score end)
    for i = 1, n do
      local line = hp .. ". " .. cand[i]._say
      if line ~= prev and rowWidth(line, size) <= maxW then
        claim(head, hp, hv)
        heads[head.key] = (heads[head.key] or 0) + 1
        claim(cand[i], cand[i]._ph, cand[i]._vk)
        return line, hp
      end
    end
    -- ...but a promoted head only earns the row if the work came with it. On
    -- its own it is a machine described by how long it stood while the trees
    -- it planted go unmentioned, which is not an improvement on the template.
    local line = hp .. "."
    if h ~= promoted and line ~= prev then
      claim(head, hp, hv)
      heads[head.key] = (heads[head.key] or 0) + 1
      return line, hp
    end
  end
  -- LAST RESORT, and it used to print the same sentence twice in a row. It
  -- took neither `prevHead` nor `claim`, so `phrase` saw counters that never
  -- moved and handed two adjacent machines with one clause apiece a byte-
  -- identical epitaph -- captured, LAMP-05 over FRAME-05. Avoiding the head
  -- above and claiming the wording is what every other exit here already does.
  local hp, hv = phrase(list[1], worded, jit, prevHead)
  claim(list[1], hp, hv)
  heads[list[1].key] = (heads[list[1].key] or 0) + 1
  return hp .. ".", hp
end

--- Write every row's finished sentence. Called from `layoutCredits`, so a
--- resize re-fits the second clauses to the new column instead of overflowing.
function S:composeMemorial(colW, size)
  local rows = self.fallen
  if not rows then return end
  local maxW = colW * TU.bots.memorial.rowWidth
  local used, said, worded, heads = {}, {}, {}, {}
  local prev, prevHead = nil, nil
  for i = 1, #rows do
    local r = rows[i]
    local list = r.clauses
    if list and #list > 0 then
      r.epitaph, prevHead = composeRow(list, used, said, worded, heads,
                                       rowJitter(i), prev, prevHead, maxW, size)
    else
      r.epitaph = (r.line or "was here") .. "."
      prevHead = nil
    end
    prev = r.epitaph
  end
end

------------------------------------------------------------------------- enter
function S:enter(world)
  local w, h = lg.getDimensions()
  self.world = world
  self.t = 0
  self.stage = "quiet"
  self.stageT = 0
  self.bar = 0
  self.scrollY = 0
  self.creditsT = 0
  self.leaving = false
  self.spoke = false

  self.camera = (world and world.camera) or Camera.new(w, h)
  self.camera:resize(w, h)
  if world then world.camera = self.camera end
  if self.camera.setBounds then self.camera:setBounds(0, 0, TU.world.w, TU.world.h) end

  if VFX.init then VFX.init() end
  if Post.init then Post.init(w, h) end
  if Lighting.init then Lighting.init(w, h) end

  if world then
    -- THE RIG, THEIR SHARE, read before `hush` -- because `hush` clears
    -- `world.boss`, and this line was computed fourteen lines after it and so
    -- printed 0% in every run the game has ever finished. It is the line the
    -- script's own comment calls the one the game is about.
    local boss = world.boss
    local hull = boss and boss.maxHp        -- a stub world's rig has no hull
    local theirs = hull and math.floor(100 * U.saturate(
                     1 - (boss.playerDamage or 0) / max(1, hull))) or 0
    -- OXYGEN RESTORED is the sky the run actually reached, not the reading the
    -- Harvester Prime left behind: it spends the whole extraction dragging the
    -- meter down, and a player who filled the sky and then fought the rig off
    -- was being told he restored forty percent, printed directly under a man
    -- who has just said "The world is safe."
    local o2 = world.o2Peak or world.o2 or 0
    hush(world)
    self.bots = survivors(world)
    self.fallen = fallenRecords(world)
    self.stats = {
      trees   = world.treeCount or 0,
      lost    = (world.stats and world.stats.lost) or 0,
      planted = (world.stats and world.stats.planted) or 0,
      o2      = o2,
      cycles  = math.min(world.cycle or 1, TU.cycle.count),
      built   = (world.stats and world.stats.botsBuilt) or 0,
      rescued = (world.stats and world.stats.rescued) or 0,
      theirs  = theirs,
    }
    -- The run's record. Nothing called this before, so the title screen has
    -- been reading NO RUN RECORDED since the feature was written -- and the
    -- cover's treeline, which fills in as the best sky climbs, had nothing to
    -- fill in from.
    if Settings and Settings.recordRun then
      Settings.recordRun(math.min(world.cycle or 1, TU.cycle.count),
                         world.treeCount or 0, world.o2Peak or world.o2 or 0)
    end
    -- Cache the cast. `prepare` re-picks botA/botB from the living crew every
    -- time it is called, so calling it twice can seat two different machines:
    -- traced, botA came back SEED-19 here and FRAME-03 at S:speak. The bot that
    -- says "you can take it off now" has to be the bot the scene has been
    -- staged around since it opened.
    self.ctx = Story.prepare("ending", world)
    -- ...and the two machines that keep a name. `ctx.bot` is the one that says
    -- "you can take it off now", which is the one the player heard boot and
    -- speak if it is still standing; `ctx.bot2` is whoever is next to him.
    local only = {}
    if self.ctx.bot then only[self.ctx.bot] = true end
    if self.ctx.bot2 then only[self.ctx.bot2] = true end
    self.plateOnly = next(only) and only or nil
  else
    self.bots, self.fallen = {}, {}
    self.stats = { trees = 0, lost = 0, planted = 0, o2 = 0, cycles = 0,
                   built = 0, rescued = 0, theirs = 0 }
  end

  if Bot then
    Bot.plateGain = T.plateGain
    Bot.plateOnly = self.plateOnly
  end
  if Music.setState then Music.setState("ending") end
  if Music.setIntensity then Music.setIntensity(0) end
  -- the sun comes up across the whole ending, and is fully up by the credits
  self.dawnT = 0
  -- The oxygen grade. Game:syncDayNight drives DayNight.o2Influence from the
  -- live meter every frame, and nothing in this scene ticks the world, so it
  -- would hold whatever the rig had dragged the reading down to for the whole
  -- ending. The honest figure for a finished run is the one it reached, and
  -- the air coming back up to it while he stands there is not a bad image, so
  -- it rises over the first few seconds rather than snapping.
  self.o2Peak = 100 * ((self.stats and self.stats.o2) or 0) / math.max(1, TU.o2.target)
  self.o2From = world and (100 * (world.o2 or 0) / math.max(1, TU.o2.target))
                       or self.o2Peak
  self.o2T = 0
  self:tickAir(0)
  if DayNight.set then DayNight.set("dawn", 0) end
  DayNight.fogStrength = (DayNight.fogStrength or 0) * T.fogMul

  self:layoutCredits()
end

--- Bring the oxygen grade up to what the run actually reached. See `o2Rise`.
function S:tickAir(dt)
  if not DayNight.o2Influence then return end
  self.o2T = math.min(1, (self.o2T or 0) + dt / T.o2Rise)
  local peak = self.o2Peak or 0
  DayNight.o2Influence(U.lerp(self.o2From or peak, peak, U.ease.outCubic(self.o2T)))
end

function S:leave()
  if self.world then self.world.cutscene = false end
  if Bot then Bot.plateGain = 1 Bot.plateOnly = nil end
end

function S:resize(w, h)
  self.camera:resize(w, h)
  if Post.resize then Post.resize(w, h) end
  if Lighting.resize then Lighting.resize(w, h) end
  self:layoutCredits()
end

---------------------------------------------------------------------- staging
-- How hard the ring is allowed to work to find dry ground: turns of the arc,
-- and how far it may close if turning alone will not do it.
local RING_TURNS  = 24
local RING_SCALES = { 1.0, 0.88, 0.76, 0.64 }

--- Ring positions, assigned by angle so nobody crosses the circle to get home.
function S:assignRing()
  local p = self.world and self.world.player
  if not p then return end

  -- Only the ones close enough that walking in reads as walking in. On a
  -- forested island a Planter can be two thousand pixels away down a beach;
  -- dragging it across the map in four seconds looks like a bug, and leaving
  -- it where it is looks like a bot getting on with its job, which is true.
  local ring = {}
  for i = 1, #self.bots do
    local b = self.bots[i]
    b.ringX, b.ringY = nil, nil
    if U.dist(b.x, b.y, p.x, p.y) <= T.gatherFar then
      ring[#ring + 1] = { b = b, a = math.atan2(b.y - p.y, b.x - p.x) }
    end
  end
  local n = #ring
  if n == 0 then return end

  local r = U.clamp(n * T.ringGap / U.TAU, T.ringMin, T.ringMax)
  table.sort(ring, function(a, c) return a.a < c.a end)

  -- PUT THE CIRCLE ON THE ISLAND. The ring is struck around wherever the player
  -- happens to be standing when the rig falls, and on one traced seed that was
  -- close enough to the shore that a third of the crew formed up in the sea for
  -- the last shot of the game. The island's own shape decides where the circle
  -- goes: turn the arc and, if turning is not enough, close it, keeping
  -- whichever combination puts the most machines on land -- then any single
  -- straggler still wet is walked in along its own radius until it is not.
  local terr = self.world and self.world.terrain
  local land = terr and terr.isLand and function(x, y) return terr:isLand(x, y) end or nil
  local rot = 0
  if land then
    local best = -1
    for si = 1, #RING_SCALES do
      local sc = RING_SCALES[si]
      for ti = 0, RING_TURNS - 1 do
        local off = ti / RING_TURNS * U.TAU
        local hits = 0
        for i = 1, n do
          local a = -math.pi * 0.5 + off + (i - 1) / n * U.TAU
          if land(p.x + math.cos(a) * r * sc, p.y + math.sin(a) * r * sc * 0.78) then
            hits = hits + 1
          end
        end
        if hits > best then best, rot = hits, off self.ringScale = sc end
        if best >= n then break end
      end
      if best >= n then break end
    end
    r = r * (self.ringScale or 1)
  end

  for i = 1, n do
    local a = -math.pi * 0.5 + rot + (i - 1) / n * U.TAU
    local b = ring[i].b
    local rr = r
    if land and not land(p.x + math.cos(a) * rr, p.y + math.sin(a) * rr * 0.78) then
      for k = 0.85, 0.05, -0.1 do
        if land(p.x + math.cos(a) * r * k, p.y + math.sin(a) * r * k * 0.78) then
          rr = r * k
          break
        end
      end
    end
    b.ringX = p.x + math.cos(a) * rr
    b.ringY = p.y + math.sin(a) * rr * 0.78
    b.ringA = a
    -- where it set off from, so the walk can be timed rather than paced: they
    -- all get there at the same moment, which is the only version of this
    -- that is a circle rather than an arrival queue
    b.gx, b.gy = b.x, b.y
  end
  self.ringR = r
  self.ringN = n
  -- frame the circle, whatever size it turned out to be
  self.ringZoom = U.clamp(T.ringFrame / (r * 0.78 + 96), T.zoomMin, T.zoomMax)
  -- ...and the second shot: close enough that the circle is off the edges.
  self.turnZoom = U.clamp(lg.getWidth() * 0.5 / max(1, r * T.turnClear),
                          T.turnMin, T.turnMax)
end

--- Walk the bots to their places. Their own AI is not running; this is us.
--- `k` is 0..1 across the gather, so the ones that started furthest out move
--- fastest and the circle closes all at once.
function S:stepBots(dt, k)
  local p = self.world and self.world.player
  if not p then return true end
  k = k == nil and 1 or U.saturate(k)
  local e = U.ease.inOutCubic and U.ease.inOutCubic(k) or U.ease.outCubic(k)
  for i = 1, #self.bots do
    local b = self.bots[i]
    b.age = (b.age or 0) + dt
    b.blink = (b.blink or 0) + dt
    if b.ringX and b.gx then
      local nx0, ny0 = b.x, b.y
      b.x = U.lerp(b.gx, b.ringX, e)
      b.y = U.lerp(b.gy, b.ringY, e)
      local vx, vy = (b.x - nx0), (b.y - ny0)
      b.vx, b.vy = (dt > 0) and vx / dt or 0, (dt > 0) and vy / dt or 0
      if b.setFacing and (vx ~= 0 or vy ~= 0) then
        local dx, dy = U.norm(vx, vy)
        b:setFacing(dx, dy)
      end
    else
      b.vx, b.vy = 0, 0
    end
    if b.lookAt then b:lookAt(p.x, p.y) end
  end
  return k >= 1
end

function S:advance(stage)
  self.stage = stage
  self.stageT = 0
  if stage == "gather" then
    self:assignRing()
  elseif stage == "words" then
    self:speak()
  elseif stage == "credits" then
    Dialogue.abort()
    self.scrollY = 0
    if Audio.play then Audio.play("o2_milestone", { volume = 0.5, pitch = 0.8 }) end
  end
end

function S:speak()
  if self.spoke then return end
  self.spoke = true
  local scene = self
  local ctx = self.ctx or Story.prepare("ending", self.world)
  ctx.onSuitOff = function()
    local p = scene.world and scene.world.player
    if p and VFX.emit then VFX.emit("bot_boot", p.x, p.y - 10, { power = 1.4 }) end
    -- He does not shed the suit, he sets a part down. Player:draw self-arms
    -- this the first frame `suit` is false; calling it here picks the side it
    -- lands on and emits player:helmetOff.
    if p and p.setHelmetDown then p:setHelmetDown(1) end
    -- "Or the radio." -- the other half of the line. The rig's amber lamp has
    -- swept all run and its readout has said the same number since the first
    -- dawn; both stop here, and nothing says so.
    local rig = scene.world and scene.world.rig
    if rig and rig.radioOff then rig:radioOff() end
    for i = 1, #scene.bots do
      local b = scene.bots[i]
      if VFX.emit then VFX.emit("love_heart", b.x, b.y - 14, { power = 0.6 }) end
    end
  end
  Dialogue.play(Script.ending.steps, {
    world  = self.world,
    cast   = Story.cast,
    ctx    = ctx,
    id     = "ending",
    camera = self.camera,
    replace = true,
    onDone = function() scene:advance("after") end,
  })
end

--- THE ONE LINE THAT ANSWERS HIM, and it has never once been said.
---
--- The script fires it from an `fn` step in the middle of the silence -- one
--- machine saying "we are here" in the world, with no panel and no box, a few
--- seconds before he says "All alone." It goes through `World:speak`, whose
--- first rule is that nobody talks over a cutscene, and `hush` sets
--- `world.cutscene` on the ending's first frame. So the guard has eaten the
--- only line in the ending that can contradict him, in every finished run the
--- game has ever had. The ending lifts it for exactly this sentence and puts it
--- straight back: it is not a bot chattering over a cutscene, it is the scene.
function S:hushLine()
  if self.saidQuiet then return end
  local world = self.world
  local ctx = self.ctx
  local b = ctx and (ctx.bot or ctx.bot2)
  local line = Script.credits and Script.credits.quiet
  if not (world and world.speak and line) then return end
  if not (b and b.alive and b.state ~= "dead") then return end
  self.saidQuiet = true
  local was = world.cutscene
  world.cutscene = false
  world:speak(b, line)
  world.cutscene = was
end

--- ...and draw it, by hand, because nothing else will.
---
--- THREE THINGS SILENCED THIS LINE AND ONLY ONE OF THEM WAS EVER FIXED.
--- `World:drawSpeech` reaches it and calls `self:drawBubble` -- but
--- `game/hud.lua` monkey-patches that method on the class into a push onto a
--- HUD-side queue, and the ending scene never calls `HUD.draw`, so the queue is
--- never flushed; and `HUD.drawSpeech` drops everything while `world.cutscene`
--- is set, which the ending sets on its first frame. An earlier pass found the
--- cutscene guard on `World:speak` and lifted it, and the line has still never
--- appeared in a finished run: it was queued, aged by `tickSpeech`, and thrown
--- away. `drawBubbleRaw` is the unpatched method, kept for exactly this.
---
--- Drawn inside the camera, over the world, before the glow -- which is where
--- `World:drawSpeech` would have put it. The alpha is that function's, so the
--- line fades in and out the way a bot's line does anywhere else in the game.
function S:drawQuietLine(world)
  local Wo = package.loaded["src.world.world"]
  local raw = Wo and rawget(Wo, "drawBubbleRaw")
  local sp = world and world.speeches
  if not (raw and sp) then return end
  for i = 1, #sp do
    local e = sp[i]
    local who = e.who
    if who and who.alive then
      local a = U.saturate(math.min(e.t * 4, (e.dur - e.t) * 2))
      if a > 0.01 then
        raw(world, who.x, who.y - (who.radius or 12) * 2.4, e.line, a)
      end
    end
  end
end

--- The world is not running, so the one line a bot says out loud during the
--- silence would otherwise never expire. Age it by hand.
function S:tickSpeech(dt)
  local sp = self.world and self.world.speeches
  if not sp then return end
  for i = #sp, 1, -1 do
    local e = sp[i]
    e.t = e.t + dt
    if e.t >= (e.dur or 3.2) then table.remove(sp, i) end
  end
end

--- Open the canopy over the whole circle, not just over the player's head.
--- World:draw re-points the focus at the player every frame with a 78px
--- radius, but the fade is driven from the update, so this is what wins.
function S:tickCanopy(dt)
  local world = self.world
  local p = world and world.player
  if not (p and world.trees and Tree.setFocus) then return end

  -- The focus is NOT the player. Tree:updateXray only considers canopies that
  -- sort in front of the focus point (`tree.y > focusY`), so pointing it at his
  -- feet leaves every tree between him and the top of the circle fully opaque
  -- -- which is exactly where half the ring is standing. Aim it at the back of
  -- the ring and widen it until the whole ellipse is inside.
  local r = self.ringR or T.ringMin
  Tree.setFocus(p.x, p.y - r * 0.62, r * 1.5)

  -- ...and the x-ray on its own is not enough. It takes a canopy down to 22%,
  -- which is plenty when one tree is in the way and useless when nine are:
  -- by the last cycle the island is eight hundred trees deep and the ring, the
  -- bots and the man himself are all under an unbroken roof. So the roof opens.
  -- Over the first few seconds of the ending, every tree standing inside the
  -- circle thins out and lets the light down, and the forest closes again
  -- behind the camera as it pulls away for the credits. It is the last thing
  -- the forest does for him: it gets out of the way.
  local closing = (self.stage == "credits")
  self.open = U.saturate((self.open or 0) + (closing and -dt / 7.0 or dt / T.openTime))
  local ox, oy = p.x, p.y - r * 0.30
  local rx, ry = r * T.openW, r * T.openH
  local cam = self.camera
  local list = world.trees
  for i = 1, #list do
    local t = list[i]
    if t.updateXray then
      -- World:draw reads `world.visTrees`, which is the depth-ordered set of
      -- on-screen trees that the *update* sweep builds -- and this scene never
      -- updates the world. So the forest the ending drew was whichever trees
      -- happened to be on camera at the instant the rig fell, frozen: pan or
      -- pull back at all and the island went bare. That is the backdrop the
      -- memorial is supposed to have behind it. Rebuild the set here, from
      -- this scene's own camera rather than from Tree's static view rect,
      -- because the view rect is only refreshed by a frame that draws.
      if cam then
        t.onScreen = cam:visible(t.x, t.y, (t.canopyR or 0) + (t.height or 0))
      elseif t.visible then
        t.onScreen = t:visible()
      end
      t:updateXray(dt)
      local dx = (t.x - ox) / rx
      local dy = (t.y - (t.height or 0) * 0.35 - oy) / ry
      local d2 = dx * dx + dy * dy
      if t.alive and d2 < 1.2 then
        local edge = 1 - U.smoothstep(T.openSoft, 1.0, d2)
        t.fade = U.damp(t.fade or 1, U.lerp(1, T.openFade, self.open * edge), 2.2, dt)
      end
    end
  end
  if world.refreshVisibleTrees then world:refreshVisibleTrees() end
end

------------------------------------------------------------------------ update
function S:update(dt, realDt)
  realDt = realDt or dt
  self.t = self.t + realDt
  self.stageT = self.stageT + realDt

  local world = self.world
  if Wind.update then Wind.update(realDt) end
  if VFX.update then VFX.update(realDt) end
  if Music.update then Music.update(realDt) end
  self:tickSpeech(realDt)
  self:tickCanopy(realDt)
  self:tickAir(realDt)
  self.dawnT = min(1, (self.dawnT or 0) + realDt / T.sunrise)
  if DayNight.set then DayNight.set("dawn", self.dawnT) end
  DayNight.fogStrength = (DayNight.fogStrength or 0) * T.fogMul
  if Audio.update and world and world.player then
    Audio.update(realDt, world.player.x, world.player.y)
  end

  local stage = self.stage

  -- skip, handled before anything else consumes the press. Skipping always
  -- lands further down the same list; it never lands on a black screen, and it
  -- never skips the turn at the end of the script.
  if Input.pressed("back") or Input.pressed("pause") then
    Input.consume("back") Input.consume("pause")
    if stage == "credits" then
      self:toTitle()
      return
    elseif stage == "words" then
      if Dialogue.isActive() then Dialogue.skip() end
      self:advance("after")
      stage = self.stage
    elseif stage == "after" then
      self:advance("credits")
      stage = self.stage
    else
      self:advance("words")
      stage = self.stage
    end
  end

  -- The crew's plates: up for the ring, and gone by the time the memorial has
  -- settled. They are what make the crowd read as individuals, which is why
  -- they have no business over a list of the dead.
  if Bot then
    Bot.plateGain = T.plateGain * (1 - U.saturate(self.creditsT / T.memBack))
  end

  -- THE CUT INTO THE TURN, detected rather than scripted. The script takes the
  -- dialogue panel away for the silence in the middle of the ending and brings
  -- it back for the last three lines; that returning edge is the only cut in
  -- the scene and it is the one thing the camera has to know about. Read off
  -- the panel rather than off a line of dialogue, so rewriting the script
  -- cannot silently leave the camera in the wrong place -- and if a rewrite
  -- ever removes the silence, the turn simply never fires and the ending keeps
  -- the wide shot it has always had.
  if stage == "words" then
    local panel = Dialogue.bar or 0
    if panel > 0.5 then
      if self.panelSeen and self.hushed then self.turn = true end
      self.panelSeen = true
      self.hushT = 0
    elseif panel < 0.05 and self.panelSeen then
      self.hushT = (self.hushT or 0) + realDt
      if self.hushT > T.turnHush then self.hushed = true end
      if self.hushT > T.turnSay then self:hushLine() end
    end
  end

  local barWant = (stage == "credits") and 0 or 1
  self.bar = U.approach(self.bar, barWant, realDt * (barWant > 0 and 1.5 or 0.9))

  if stage ~= "credits" then
    local k = (stage == "gather") and (self.stageT / T.gatherDur) or 1
    self:stepBots(realDt, k)
  end
  Story.refresh(world)      -- the helmet comes off mid-scene; the portrait knows

  -- camera: in on the circle, then a short push back that stops
  local cam = self.camera
  local p = world and world.player
  if cam and p then
    local held = self.ringZoom or T.zoomIn
    local zoom = held
    if stage == "after" then
      zoom = U.lerp(held, held * 0.78, U.saturate(self.stageT / T.after))
    elseif stage == "credits" then
      zoom = U.lerp(held * 0.78, held * T.memZoom * 0.78,
                    U.ease.outCubic(U.saturate(self.creditsT / T.memSettle)))
    end
    -- Lift, for as long as the dialogue panel is up and by exactly as much as
    -- it covers. Driven off the panel's own presence rather than off a stage,
    -- so it goes away by itself in the silence the script cuts into the middle
    -- of the turn, and comes back for the last three lines.
    local lift = 0
    if stage ~= "credits" then
      local panel = U.saturate((Dialogue.bar or 0) * 1.4)
      if panel > 0.004 then
        local L = Dialogue.layout and Dialogue.layout()
        -- the clear band: under the top letterbox, above the panel
        local top = L and L.bar or (lg.getHeight() * T.barFrac)
        local bot = L and L.py or (lg.getHeight() * 0.64)
        local mid = (top + bot) * 0.5
        if self.turn then
          -- The second shot. The ring is not fitted into the band -- it is not
          -- meant to be in the frame at all. The line is about being alone.
          zoom = U.lerp(zoom, self.turnZoom or T.turnMax, panel)
        else
          -- ...and the ring has to fit inside it, which at the framing the ring
          -- settled on it does not: 36 machines are 480 screen pixels tall and
          -- the band is 480 pixels of screen. Give the whole ellipse the band.
          local need = (self.ringR or T.ringMin) * 0.78 + T.panelPad
          local fit  = U.clamp((bot - top) * 0.5 / need, T.zoomMin, zoom)
          zoom = U.lerp(zoom, fit, panel)
        end
        lift = panel * (10 + (lg.getHeight() * 0.5 - mid) / math.max(0.2, cam.zoom))
      end
    end
    cam.zoomTarget = zoom
    cam.zoom = U.damp(cam.zoom, cam.zoomTarget, 1.1, realDt)
    cam.x = U.damp(cam.x, p.x, 1.6, realDt)
    cam.y = U.damp(cam.y, p.y - 10 + lift, 1.6, realDt)
    if cam.clampToBounds then cam:clampToBounds() end
  end

  if stage == "quiet" then
    if self.stageT > T.quiet then self:advance("gather") end
  elseif stage == "gather" then
    if self.stageT >= T.gatherDur then self:advance("settle") end
  elseif stage == "settle" then
    if self.stageT > T.settle then self:advance("words") end
  elseif stage == "words" then
    Dialogue.update(dt, realDt)
    if not Dialogue.isActive() and self.stageT > 0.4 then self:advance("after") end
  elseif stage == "after" then
    if self.stageT > T.after then self:advance("credits") end
  elseif stage == "credits" then
    local fast = Input.down("confirm") and 4 or 1
    self.dawnT = min(1, self.dawnT + realDt * (fast - 1) / 64)
    self.creditsT = self.creditsT + realDt * fast
    -- The scroll stops. The last name on the list is the last thing the game
    -- says and it used to slide off the top edge while it was being read; it
    -- comes to rest a little above centre instead and is held there.
    local rest = self.restScroll or (self.creditsH or 0)
    self.scrollY = min(rest, self.scrollY + T.scroll * realDt * fast)
    if self.scrollY >= rest then
      self.holdT = (self.holdT or 0) + realDt * fast
      if self.holdT > T.restHold then self:toTitle() end
    end
  end

  if stage ~= "words" then Dialogue.update(dt, realDt) end
end

function S:toTitle()
  if self.leaving then return end
  self.leaving = true
  if self.world then self.world.cutscene = false end
  Story.reset()
  Signal.emit("ending:done")
  Screen.transition(1.1, function()
    Screen.switch(require("src.scenes.title"))
  end)
end

--------------------------------------------------------------------- credits
-- Laid out once into a flat list of rows so the scroll is a single offset.
local ROW = { gap = 34, head = 56, line = 30, big = 92,
              -- The name and what it did. The epitaph was 13px inkDim under a
              -- 19px ink name -- the serial number set larger and brighter than
              -- the sentence, on a memorial whose entire premise is that the
              -- sentence is the point. The sentence is 15px now and it is ink
              -- rather than inkDim; the name stays the label it is.
              name = 19, epi = 15, epiAlpha = 0.82,
              sapGap = 18 }        -- sapling to the left of the name's own edge
--- The memorial's column, which the layout pass and the draw pass have to agree
--- on: one is where the second clauses are fitted, the other is where they land.
local function memColumn(w)
  return min(520, w - 120)
end
local SHADOW = { dx = 0, dy = 2, alpha = 0.65 }
local NAME_M = { tracking = 0.1 }      -- must match the name's own tracking
local EPI = {}
local CRED = {}
local function credOpts()
  for k in pairs(CRED) do CRED[k] = nil end
  CRED.shadow = SHADOW
  return CRED
end

function S:layoutCredits()
  local rows = {}
  local C = Script.credits
  self:composeMemorial(memColumn(lg.getWidth()), ROW.epi)
  local function push(kind, text, value, size)
    rows[#rows + 1] = { kind = kind, text = text, value = value, size = size,
                        h = size or ROW.line }
  end

  push("space", nil, nil, ROW.big)
  push("title", C.title, nil, 46)
  rows[#rows].h = 68
  push("sub", C.sub, nil, 20)
  rows[#rows].h = ROW.head
  push("space", nil, nil, ROW.head)

  push("head", C.tally, nil, ROW.head)
  local st = self.stats or {}
  for i = 1, #C.rows do
    local r = C.rows[i]
    local v = st[r.key] or 0
    local txt
    if r.suffix then
      txt = Text.format(v, { decimals = 0, suffix = r.suffix })
    else
      txt = Text.format(v, { comma = true })
    end
    push("stat", r.label, txt, ROW.line)
  end

  push("space", nil, nil, ROW.head)
  push("head", C.fallen, nil, ROW.head)
  local f = self.fallen or {}
  if #f == 0 then
    push("none", C.none, nil, ROW.line)
  else
    for i = 1, #f do
      local r = f[i]
      -- name over epitaph, not name beside number: a two-line block reads as a
      -- headstone, a label-and-value row reads as a table of results
      push("name", r.name, r.epitaph, ROW.line + 30)
      -- measured once, here: the sapling hangs off the left edge of a centred
      -- name, and measuring display type per row per frame is not free
      rows[#rows].nameW = (Text.measure and Text.measure(r.name, ROW.name, NAME_M))
                          or (#r.name * ROW.name * 0.6)
    end
  end

  -- There is no closing line. `S.credits.close` was deleted from the script --
  -- two readers called it the writer congratulating the player over a list of
  -- the dead -- and the empty 30px row it left behind went with it. The game
  -- ends on the last name and what that machine did.
  push("space", nil, nil, ROW.big)

  local y = 0
  for i = 1, #rows do rows[i].y = y y = y + rows[i].h end
  self.credits = rows
  self.creditsH = y

  -- Where the scroll stops: the last thing with words on it, resting a little
  -- above centre. A row is at `h - scrollY + row.y`, so this is the offset that
  -- puts that row at `h * restAt`.
  local last
  for i = #rows, 1, -1 do
    if rows[i].text then last = rows[i] break end
  end
  local sh = lg.getHeight()
  self.restScroll = max(0, (last and last.y or y) + sh * (1 - T.restAt))
end

--- A sapling, drawn beside a name. It grows as the line comes up the screen.
local function sapling(x, y, k, alpha)
  if k <= 0.02 then return end
  local hgt = 22 * k
  Draw.setColor(P.shade(P.ramp.bark, 2.6), alpha)
  lg.setLineWidth(1.8)
  lg.line(x, y, x, y - hgt)
  local leaf = min(1, k * 1.4) * 5.4
  Draw.setColor(P.shade(P.ramp.leafHi, 3), alpha * 0.95)
  lg.circle("fill", x - leaf * 0.66, y - hgt + 1.5, leaf)
  lg.circle("fill", x + leaf * 0.70, y - hgt - 3.0, leaf * 0.86)
end

function S:drawCredits()
  local rows = self.credits
  if not rows then return end
  local w, h = lg.getDimensions()
  local cx = floor(w * 0.5)
  local colW = memColumn(w)
  local lx = cx - colW * 0.5
  local rx = cx + colW * 0.5
  local top = h - self.scrollY

  -- A scrim, not a curtain: the forest stays visible behind every word. It was
  -- 0.30 and the words were not readable -- eight hundred sunlit canopies is
  -- the brightest, busiest backdrop in the game, and 13px caption type over it
  -- simply disappears. The fix is a soft column the type sits in, so the
  -- forest stays bright at the edges of the frame and dark under the names.
  --
  -- It is not allowed to depend on where the camera happens to be pointing.
  -- One capture had the right half of the frame in full sunlight and the list
  -- legible only because it happened to be over dark ground: the column is
  -- wider and deeper now, and the world behind it has been graded back in
  -- S:draw, so the contrast is guaranteed rather than hoped for.
  local k = U.saturate(self.creditsT / 5)
  local bk = U.saturate((self.creditsT - T.memBandFrom) / T.memBandRise)
  Draw.setColor(P.black, T.memDim * k)
  lg.rectangle("fill", 0, 0, w, h)
  local bandW = colW + 150
  local bx = floor(cx - bandW * 0.5)
  local band = T.memBand * bk
  local feather = T.memFeather
  Draw.setColor(P.black, band)
  lg.rectangle("fill", bx, 0, bandW, h)
  Draw.linearGradient(bx - feather, 0, feather, h,
                      P.alpha(P.black, 0), P.alpha(P.black, band), 0)
  Draw.linearGradient(bx + bandW, 0, feather, h,
                      P.alpha(P.black, band), P.alpha(P.black, 0), 0)
  Draw.radialGradient(cx, h * 0.5, colW * 1.35,
                      P.alpha(P.black, 0.22 * bk), P.alpha(P.black, 0), h * 0.72)

  for i = 1, #rows do
    local r = rows[i]
    local y = top + r.y
    if y > -60 and y < h + 60 then
      -- fade in from the bottom edge, out at the top: the words grow and go
      local a = U.saturate((h - y) / 140) * U.saturate((y - 4) / 120)
      if a > 0.004 then
        local kind = r.kind
        if kind == "title" then
          UI.text(r.text, cx, y, 46, P.ink, "center", a, 0.16, credOpts())
        elseif kind == "sub" then
          UI.text(r.text, cx, y, 20, P.accent, "center", a * 0.9, 0.42, credOpts())
        elseif kind == "head" then
          UI.rule(lx, y + 24, colW, P.ink, 0.18 * a, nil)
          UI.text(r.text, cx, y, 13, P.inkDim, "center", a * 0.95, 0.26, credOpts())
        elseif kind == "stat" then
          UI.text(r.text, lx, y + 3, 13, P.inkDim, "left", a * 0.95, 0.2, credOpts())
          UI.text(r.value, rx, y - 2, 20, P.ink, "right", a, 0.04, credOpts())
        elseif kind == "name" then
          -- ON THE PAGE'S OWN AXIS. Both headers are centred and the names were
          -- left-aligned a quarter of the way across, with four hundred pixels
          -- of dead column to their right: under centred headers that reads as
          -- broken layout, on the last screen of the game. The pair is centred
          -- and the sapling hangs off the left edge of the name, so the
          -- memorial has one axis instead of two.
          local grow = U.saturate((h * 0.80 - y) / 220)
          local nw = r.nameW or 0
          sapling(cx - nw * 0.5 - ROW.sapGap, y + 20, grow, a)
          UI.text(r.text, cx, y, ROW.name, P.ink, "center", a * 0.95, 0.1, credOpts())
          if r.value then
            -- what it did, in the voice it said it in: lowercase, body face,
            -- the same type its speech bubbles were set in
            EPI.color, EPI.alpha, EPI.align = P.ink, a * ROW.epiAlpha, "center"
            Text.body(r.value, cx, y + 24, ROW.epi, EPI)
          end
        elseif kind == "none" then
          UI.text(r.text, cx, y, 13, P.accent, "center", a, 0.26, credOpts())
        end
      end
    end
  end
end

-------------------------------------------------------------------------- draw
local function drawBars(amount)
  if amount <= 0.002 then return end
  local w, h = lg.getDimensions()
  local bh = floor(h * T.barFrac) * U.ease.outCubic(amount)
  Draw.setColor(P.black, 0.96)
  lg.rectangle("fill", 0, 0, w, bh)
  lg.rectangle("fill", 0, h - bh, w, bh)
  lg.setColor(1, 1, 1, 1)
end

--- A pool of light on the ground the ring is standing in. It used to be an
--- outlined ellipse drawn under the world, which the trees around the circle
--- chopped into two floating arcs -- it read as a broken UI element, not as
--- light. It is now a soft fill, laid over the scene, and barely there.
function S:drawCircleGlow()
  if not self.ringR or #self.bots == 0 then return end
  local p = self.world and self.world.player
  if not p then return end
  local k = U.saturate((self.t - T.quiet) / 4) * (1 - U.saturate(self.creditsT / 6))
  if k <= 0.01 then return end
  local r = self.ringR
  Draw.radialGradient(p.x, p.y - r * 0.10, r * 1.30,
                      P.alpha(P.love, 0.085 * k), P.alpha(P.love, 0), r * 1.05)
  lg.setColor(1, 1, 1, 1)
end

function S:draw()
  local world = self.world
  local cam = self.camera

  if Post.setGrade then
    -- Under the memorial the world is a backdrop, not the subject. It is not
    -- hidden -- the restored forest behind the names is half the point of the
    -- image -- but it is taken down two thirds of a stop, half its chroma and
    -- further into the air, so that the names are unambiguously the thing on
    -- the screen and the type does not have to fight a sunlit canopy for it.
    local ex, sat = DayNight.exposure, DayNight.saturation
    local bloom, fog = DayNight.bloom, DayNight.fogStrength or 0
    if self.stage == "credits" then
      local k = U.saturate(self.creditsT / T.memBack)
      ex    = ex * U.lerp(1, T.memExpo, k)
      sat   = sat * U.lerp(1, T.memSat, k)
      bloom = bloom * U.lerp(1, T.memBloom, k)
      fog   = U.lerp(fog, max(fog, T.memFog), k)
    end
    Post.setGrade(DayNight.skyTint, ex, DayNight.contrast, sat, DayNight.lift)
    Post.setBloom(bloom)
    Post.setFog(DayNight.fogColor, fog)
  end
  if Post.beginScene then Post.beginScene() end

  lg.clear(P.ramp.water[1])
  if world and world.draw then
    cam:attach()
    world:draw(cam)
    self:drawQuietLine(world)
    self:drawCircleGlow()
    cam:detach()
  end

  if Lighting.beginFrame and world and world.emitLights then
    Lighting.beginFrame(cam)
    Lighting.setAmbient(DayNight.ambient, DayNight.ambientStrength)
    if Lighting.addSunShadowParams then
      Lighting.addSunShadowParams(DayNight.sunAngle, DayNight.sunLength)
    end
    if Lighting.setLightGain then Lighting.setLightGain(DayNight.lightGain) end
    world:emitLights(Lighting)
    Lighting.finish()
  end

  if Post.endScene then Post.endScene() end
  if Post.render then Post.render() end

  drawBars(self.bar)
  Dialogue.draw()
  if self.stage == "credits" then self:drawCredits() end
  lg.setColor(1, 1, 1, 1)
end

function S:keypressed(k)
  if k == "escape" then return end
end

return S
