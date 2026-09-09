# TinyBuffBars

Player auras as stacked bars. Retail 12.1+.

| Block | Shows | Colour |
| --- | --- | --- |
| Tracking | what minimap tracking is on | orange |
| Permanent buffs | buffs with no duration | green |
| Timed buffs | remaining time, bar and text | blue |
| Debuffs | remaining time, timed and permanent | by dispel type |
| Weapon buffs | poisons, stones, imbues | purple |

Debuff colours follow `dispelName` — magic blue, curse purple, disease brown,
poison green, everything else red. Bleeds land in "everything else"; the client
exposes nothing finer.

- **Right click** cancels a buff or a weapon buff. Debuffs cannot be cancelled.
- Stacks show in the icon's bottom right corner, from two upwards.
- **Click the tracking row** for the minimap's tracking menu.
- Blocks with timers sort by remaining time, longest first.
- Durations use two units: `1h 15m`, not `75m`.
- Tooltips open beside the row, away from the screen edges the bars sit
  against: to the right on the left half, and growing down from the row's top
  edge on the top half — mirrored on each axis.
- Bar texture is ElvUI Norm when `ElvUI-media` or ElvUI is installed, else flat.

## Commands

| Command | |
| --- | --- |
| `/tbb` | version, lock state, size, texture, learned-buff count |
| `/tbb unlock` / `lock` | show or hide the drag handle |
| `/tbb reset` | back to the centre of the screen |
| `/tbb width N` / `height N` | bar size, 220x16 default, needs `/reload` |
| `/tbb alpha N` | backing transparency, 0 to 1 |
| `/tbb blizz` | show or hide Blizzard's own buff frames |
| `/tbb track` | what the client reports as tracking |
| `/tbb forget` | drop the learned buff classification |

Unlocked by default. The handle lies over the top row, so locking it moves
nothing. Blizzard's buff and debuff frames are hidden by default — weapon
enchants live inside theirs, so those go too.

## One thing worth knowing

Since 12.1 an addon cannot read aura data and draw its own bars — the values go
secret in combat, encounters, keys and PvP. Everything here is declared to the
client instead, and the client fills it in. That shapes most of the
implementation, and the consequences are explained where they bite: the header
of `TinyBuffBars.lua`, the header of `TinyBuffBars.xml`, and the comments around
each aura group.

Chat and UI strings are English and hardcoded. Aura names and time units come
from the client and follow its locale.

## Who wrote it

Claude (Anthropic), driving Claude Code, across one session on 2026-09-08.
Specified, tested in game and corrected throughout by mixMugz — most of the bugs
in here he spotted first, and the trick the bars are built on came out of a
question he asked.
