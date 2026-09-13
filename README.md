# Grayfather's Questshare (v1.2.0)

Puts your party's quest progress on the tooltip. Hover the mob or the item and see who still needs it:

```
Kill Ten Boars
  you 3/10  -  Bob 7/10  -  Cara done
```

For WoW 1.12 (vanilla).

## Why this isn't a pfQuest patch

Quest progress comes from the **Blizzard quest log API**, not from pfQuest. pfQuest is a display layer over the same data. So reading it directly means this works with [pfQuest](https://github.com/shagu/pfQuest), with Questie, or with neither, and survives updates to any of them. pfQuest is MIT licensed, so patching it would have been permitted — it just wouldn't have been better.

pfQuest has no progress sharing of its own; its only addon-message traffic is a version check.

## Nothing is saved between sessions

Deliberately. Quest progress goes stale the moment someone plays without you, and a party is a different set of people every time — stale numbers would be worse than no numbers. This is live only: what you see came from someone currently in your group, and someone who leaves the group stops appearing immediately.

## The dangerous part, and why it's handled

Reading quest objectives requires `SelectQuestLogEntry`, which changes **global** selection state — the same selection the default quest log UI and `SetAbandonQuest()` act on. An addon that scans the log and leaves the selection moved will silently cause the player to **abandon the wrong quest**: the UI keeps highlighting the row they clicked while the engine has quietly moved on.

That is not hypothetical. It was diagnosed in another inventory addon on this author's own install, where it had been abandoning the last quest in the log instead of the selected one.

So this addon saves `GetQuestLogSelection()` before scanning and restores it after, always — and there's a regression test asserting exactly that, including the "nothing selected" case, which is its own valid state.

## Usage

Everyone who wants to be included needs the addon. Progress is shared automatically with your party or raid whenever your quest log changes.

```
/gq            status: who in your group is running this, and what has been shared
/gq quests     every quest across the group, the ones you share listed first
/gq sync       share right now instead of waiting
/gq debug      verbose logging of every message sent and received
```

Hover any mob or quest item. If anyone in the group has an objective matching it, the lines appear under the normal tooltip.

### Are we on the same quest?

The tooltip answers that only when you happen to be hovering the right thing, so `/gq quests` answers it directly - every quest anyone in the group is on, with the shared ones listed first and highlighted:

```
2 quest(s) in common with your group:
  Kill Ten Boars - you 3/10, Bob done
  Wanted: Hogger - you 0/1, Bob 0/1
  Gather Hides - you 0/2 objectives
  Deliver the Package - Bob 0/1
```

A quest with several objectives reports how many are finished rather than a raw count, because "2/5" would be ambiguous between "two of five items" and "two of five objectives".

## How matching works

Objectives are matched by **name** against whatever you're hovering. The client formats kill objectives as `Mottled Boar slain: 3/10`, so the trailing word is stripped before matching — otherwise `Mottled Boar slain` would never match the mob named `Mottled Boar`. That word is taken from the client's own `QUEST_MONSTERS_KILLED` format string rather than hardcoded, so it works on a non-English client.

## Known limitations

- **Everyone needs the addon.** There's no way to read another player's quest log from the game.
- **Only objectives with counts** (`3/10`) are shared. Objectives that are just "Speak to someone" have nothing to compare.
- **Names, not IDs.** Two different quests whose objectives share a name will both show up on the tooltip. That's usually what you want, but it's worth knowing.

## Development

`tools/` runs the addon's logic on a desktop Lua, outside the game. It isn't shipped in the release zip and the client never loads it.

```
lua tools/vanilla_lint.lua GrayfathersQuestshare.lua
lua tools/test_questshare.lua
```

`vanilla_lint.lua` checks the source against what 1.12 actually runs — any Lua you can install today is 5.4 while vanilla is 5.0, so `#`, `%`, `goto`, `//` and bitwise operators all parse cleanly and then throw a script error in-game.

`test_questshare.lua` runs two simulated clients against a mock quest log and checks they exchange progress correctly. 32 checks, mutation-verified: failing to restore the quest log selection, failing to strip the localised kill suffix, showing people who left the group, oversizing the chunks, or calling a tooltip API that does not exist in 1.12 each make the suite fail.

That last one is why the suite now drives the tooltip hook for real rather than calling its helpers directly. v1.0.0 shipped calling `GameTooltip:GetUnit()`, which does not exist in vanilla, and threw on every tooltip - the tests passed because they exercised the line-building function and never the hook that calls it.

## Author

Built for [Salahaja](https://github.com/Salahaja).
