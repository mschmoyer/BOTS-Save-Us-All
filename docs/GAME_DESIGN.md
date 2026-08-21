# BOTS: Save Us All! — Game Design Reference

A reconstruction of the game's plot, core loop, and theme from the source. Every number below
is taken from the GML; the file it lives in is cited so it can be re-checked after changes.

## Premise and plot

Aliens stole Earth's oxygen. You are the last human alive, and you happen to be a mechanic —
so you build robots to replant the world's forests and bring the atmosphere back.

The story is told in four short cutscenes, each a `convo_*` script driven by an
`obj_dialog_*` object:

| Beat | Script | Trigger |
| --- | --- | --- |
| **Introduction** — *"After aliens stole Earth's oxygen… I am the only human left! I must use my mechanical skills… to repopulate the Earth!"* | `convo_Introduction1` | `obj_game` alarm at 150 frames; on finish calls `scr_startGame()` which creates the mineral spawner |
| **First attack** — *"Ack! They're attacking my trees! I must protect them! [Press E to attack, mercilessly]"* | `convo_on_fighting` | First time an enemy closes on a tree (`obj_enemy/Step_0`); on finish sets `global.attackTipDone`, which is what actually unlocks the attack key |
| **The robots rebel** — *"You've taught us love. Save the human!"* | `convo_robots_save_us` | 3 seconds after the boss spawns (`obj_end_game_start`) |
| **Ending** — *"The world is safe! I no longer need this suit… … Just me all alone… Forever."* | `convo_ending` | Boss HP reaches 0 (`obj_boss/Step_0`); swaps the player sprite to `spr_player_no_suit` mid-line, then goes to `rm_ending` |

The turn at the end is the point of the game: you win, and the victory is hollow. You saved a
planet you are the only person on.

## Core loop

One room (`rm_game`), one continuous session, no levels.

1. **Gather.** Walk with WASD/arrows (`obj_player/Step_0`, speed 11). `obj_spawner` drops a
   **mineral** every 100 frames anywhere outside a 128px border, capped at 20 on screen.
   Touching one banks it; builder bots pick them up too, and minerals collected by a bot fly
   to the player (`obj_mineral/Step_0`).
2. **Spend minerals on robots.** All three are placed at the player's position via keypress
   events on `obj_player`; costs come from `rm_game/RoomCreationCode.gml`:

   | Key | Unit | Cost | Behaviour |
   | --- | --- | --- | --- |
   | `SPACE` | **Planter** (`obj_planter`) | 10 | Wanders randomly (new heading every 20–120 frames), plants a tree every 480 frames, forever |
   | `Q` | **Builder** (`obj_robot_builder`) | 35 | Wanders and builds a new Planter every 400 frames; starts with a supply of 4, refills by walking over minerals |
   | `R` | **Repulsor** (`obj_repulsor_bot`) | 5 | Stationary. Every 200 frames pushes every enemy within 200px away by 7 units. 10 pulses, then self-destructs |

3. **Trees compound.** A planted tree spawns a seedling every 8000 frames at a random offset
   of 50–120px, rejecting spots within 300px of another tree (`obj_tree/Alarm_1`). Growth is
   exponential once a forest gets going — this is why the mid-game music cue was moved to 33%.
4. **Defend.** Once `trees_planted > 6`, `obj_enemy_spawner` starts sending **tree eaters**
   from a random map edge every 200 frames, up to 20 alive. Each walks to the nearest
   un-attacked tree and chomps it; a bitten tree dies 500 frames later unless the eater is
   driven off. Press `E` to swing the melee arm (`obj_attack_arm` — a 64px-radius shove with a
   5-frame cooldown, unlocked only after the fighting cutscene). Repulsed enemies fade out and
   die.
5. **Fill the O2 bar.** The HUD (`obj_score/Draw_0`) shows `trees_planted / TREES_TO_WIN`
   (800) as an oxygen percentage, alongside the mineral count and the build hotkeys. Passing
   1/3 of the target swaps the soundtrack from `music_stage1` to `music_stage2`.
6. **Boss finale.** At 100% oxygen, `obj_end_game_start` spawns the boss at a random spot,
   `music_stage3` kicks in, and every robot puts up a confused thought-bubble and stops picking new
   headings (their wander alarms no longer re-arm, so they drift on their last course). The boss chases the player at speed 5 and knocks them back on contact.
   **The boss's max HP equals the number of Planters plus Builders alive at that moment** —
   so the size of your robot workforce *is* the difficulty of the fight, and there is no way
   to build more once it starts. 5 seconds in, `obj_score.good_robots_rebel` flips: bubbles
   change to hearts and every robot charges the boss, each dealing 1 damage and exploding
   (`obj_planter` collision). Boss HP hits 0 → everything is cleared and the ending plays.

**The tension:** minerals fund either growth (planters, builders) or defence (repulsors), and
trees are simultaneously the win condition, the enemies' food, and — via the boss HP rule —
the ammunition for the final fight. Building wide is rewarded twice over.

## Progression triggers

All progression is polled in `obj_score/Step_0` against `trees_planted`:

| Condition | Effect |
| --- | --- |
| `> 6` | Create `obj_enemy_spawner` (enemies begin) |
| `> TREES_TO_WIN / 3` (267) | Switch to `music_stage2` |
| `>= TREES_TO_WIN` (800) | `end_game_triggered = true`, `music_stage3`, spawn `obj_end_game_start`, arm the 5-second robot-rebellion alarm |
| Boss `hp <= 0` | Destroy all enemies, robots and spawners; play `convo_ending`; go to `rm_ending` |

Tutorial tips are a separate chain of fading `obj_*_tip` objects: the first mineral spawn shows
the pickup tip, collecting it shows the planter tip, and building a planter dismisses that one.

## Theme

Ecological rebuilding wrapped around a lonely punchline.

- **You never fight the war yourself.** Your two offensive options are a shove and a push
  field; everything that matters is grown, not killed. The verbs are *plant*, *build*,
  *protect*.
- **The robots are the emotional centre.** They start as disposable tools, get confused when
  their orders stop making sense, and end up choosing to die for the person who built them —
  love-bubbles and all. The title is theirs, not yours: *BOTS: Save Us All.*
- **The victory is the tragedy.** Restoring the planet was never the hard part of being the
  last human. The suit comes off, the world is green, and there is no one to show it to.
