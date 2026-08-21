# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this project is

**BOTS: Save Us All!** — a top-down survival/base-builder made in **GameMaker Studio 2 (GML)**
for the **Chillenium 2019** 48-hour game jam. Two authors, both with roughly a day of GameMaker
experience at the time.

Open `bots.yyp` in GameMaker Studio 2 to run it. There is no build script, test suite, or
package manager in this repo — it is a pure GMS2 project tree.

See **[docs/GAME_DESIGN.md](docs/GAME_DESIGN.md)** for the plot, core loop, tuning numbers,
and theme.

## Repository layout

| Path | Contents |
| --- | --- |
| `bots.yyp` | GameMaker project file (asset registry — GMS2 rewrites it; avoid hand-editing) |
| `objects/<name>/*.gml` | One file per GML event: `Create_0`, `Step_0`, `Draw_0`, `Alarm_N`, `KeyPress_<keycode>`, `Collision_<guid>` |
| `scripts/<name>/<name>.gml` | Shared scripts — helpers (`clampMe`), the dialog system (`scr_*`), and conversation data (`convo_*`) |
| `rooms/rm_title \| rm_game \| rm_ending` | The three rooms. `rm_game/RoomCreationCode.gml` holds global init and unit costs |
| `sprites/`, `sounds/`, `fonts/`, `tilesets/`, `timelines/` | Standard GMS2 asset folders |
| `Soundtrack/` | Raw `.mp3` source for the four music tracks |

Collision event files are named by GUID (`Collision_<guid>.gml`), so grep for their contents
rather than trying to guess a filename. The `/// @description` comment at the top of each
event is usually the best hint about what it does.

## Conventions in this codebase

- **Prefixes:** `obj_` objects, `spr_` sprites, `snd_`/`music_` audio, `scr_` scripts,
  `convo_` dialog data, `rm_` rooms, `fnt_` fonts.
- **Layers** (in `rm_game`): `TilesLayer`, `TreeLayer`, `PhysicalObjectsLayer`,
  `EffectsLayer`, `InterfaceBackLayer`, `InterfaceLayer`. Create instances on the layer that
  matches their role — trees go on `TreeLayer`, units and pickups on `PhysicalObjectsLayer`,
  spawners/dialogs on `EffectsLayer`, tutorial tips on `InterfaceLayer`.
- **State lives on singletons, not in globals**, mostly. `obj_score` is the de-facto game-state
  manager (score, progression flags, stage transitions, HUD drawing) and other objects read it
  directly as `obj_score.<var>`. Only a handful of true globals exist, all initialized in
  `rooms/rm_game/RoomCreationCode.gml` or `obj_game/Create_0.gml`:
  `global.planterCost`, `global.builderCost`, `global.repulsorCost`, `global.dialogActive`,
  `global.dialogInstance`, `global.introductionDone`, `global.attackTipStarted`,
  `global.attackTipDone`, `global.current_song`.
- **Timers are alarms.** Nearly every recurring behaviour (spawning, planting, wandering,
  cutscene delays) is an `alarm[N]` that re-arms itself at the end of its own handler.
- **Guard gameplay input on `global.dialogActive`** so the player cannot act during cutscenes.
  Some existing code forgets to — that is a bug, not a pattern to copy.

## The dialog system

A small reusable cutscene system; each cutscene is its own object:

1. `scr_InitializeDialog1()` — called from the dialog object's `Create` event. Sets
   `global.dialogActive = true`, computes box/avatar/text layout, and clears the `dialog[]`
   2D array (100 rows of `[avatar sprite, text, sprite subimage]`).
2. A `convo_*` script fills that array via `scr_AddDialogLine(sprite, text, image_index)`.
3. `scr_DisplayConvoText()` — called every `Step`. Types the current line out one character
   per frame, then waits for `SPACE` to advance. Sets `finished = true` and clears
   `global.dialogActive` after the last line.
4. `scr_DrawDialog()` — called from `Draw`. Renders the box, avatar, and typed text.
5. The object's `Step` event checks `finished` and does the follow-up (start the game, set a
   tutorial flag, change room).

To add a cutscene: write a new `convo_*` script, then clone one of the `obj_dialog_*` objects
and point it at that script.

## Code quality expectations

The README says it plainly: the code is jam code. Expect duplicated blocks, commented-out
experiments, unused objects (`obj_egg` has no events), copy-paste bugs (e.g.
`obj_dialog_save_human` sets `global.attackTipDone`, which it has no business touching), and
malformed-but-tolerated GML such as the misplaced parentheses in `obj_player/Step_0.gml`'s
`keyboard_check` conditions.

When changing this project:

- Match the surrounding style; do not restyle files wholesale as a side effect of a fix.
- Keep gameplay-tuning constants where they already live (`Create` events or
  `RoomCreationCode.gml`) rather than introducing a new config layer.
- Changes cannot be verified without GameMaker Studio 2, so keep edits small and reason
  carefully about GML semantics — there is nothing here to run in CI.
