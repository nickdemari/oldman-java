# Oldman Java

A live quest route for World of Warcraft: Forever (interface 16001). Oldman Java reads your character's real state: every quest the server says you've completed (at any level), your quest log, your level, race and class. From that it builds a route that picks up, completes and turns in quests in the order that earns the most XP per minute. The route updates every time you accept, progress, turn in or level.

## Install

Oldman Java reads its quest data from QuestieDB, which comes with it. You only install Oldman Java.

- **CurseForge or Wago app:** once Oldman Java is listed there, install it from the app, which adds QuestieDB automatically.
- **Manual:** unzip `OldmanJava-<version>-Forever.zip` into your Forever AddOns folder. It contains two folders, `OldmanJava` and `QuestieDB`, and both go in AddOns:

```
/Applications/World of Warcraft/_forever_/Interface/AddOns/
```

If you already use Questie, you already have QuestieDB, and Oldman Java shares it. You don't need Questie itself. Oldman Java carries Questie's list of quests that are in the database but not on Forever (2,531 of them), so it never routes you to a quest that doesn't exist.

## Use

- `/java` shows or hides the route panel. The old `/sp` still works.
- `/java settings` opens the settings window. It's also on the panel (hover, then Settings) and in Esc > Options > AddOns > Oldman Java. It covers difficulty, class quests, skipped and completed quests, the map overlay and its labels, the waypoint and beacon, and the panel's visibility, lock, Up Next lines, size and position.
- The compass on the panel points toward the current step from where your character is facing. The arrow fades from green (on course) through gold to red (turn around). Distance and compass direction sit underneath it.
- Objective steps show a live progress bar, and every objective in Up Next shows your count on the right ("1/7", or "2 in bags" for a quest you haven't picked up yet). The world map labels show the same count. The bar at the bottom shows your XP, with a lighter section for the XP this route will add, and the header estimates when you'll level up.
- Hover the panel to show Skip, Replan and Completed. Click "OLDMAN JAVA" to collapse the panel to just the current step. Drag to move it, and Ctrl + scroll to resize it.
- On the world map, each objective on your route gets a soft colored area where its mobs, drops or objects are. Darker means more spawns, and every quest has its own color with a label. Numbered markers show your next 10 steps, joined by a thin line from where you stand. Hover a marker to see the step. `/java map` turns the overlay on or off.
- Crates, chests and other objects with only a few possible spots become **SEARCH** steps. Only some of those spots have one at a time, and other players loot them. The arrow visits the nearest spot you haven't checked, the panel shows "8 possible spots · 3 checked", and the map rings every spot. A spot only counts as checked after you've stood near it for a moment out of combat. Hovering the object locks the search onto that spot until you've looted it, even if mobs chase you off. Click the compass to search every spot again. If none turns up, it starts another lap, because they respawn.
- The arrow points in a straight line and can't see cliffs or walls. If you keep moving for about 20 seconds without getting closer to a step, Oldman Java treats it as blocked: it moves a nearby step of another quest ahead of it, or tells you to look for a way around.
- `/java route` prints every remaining step with the distance and direction of each leg.
- `/java difficulty easy | normal | hard` sets how far above your level the route may go: easy is 1 level, normal 2 (the default), hard 4. Quests whose mobs are more than one level past that also wait. Too-hard quests already in your log are held, with a note on the panel, until you level up. Quests you've finished are still routed to their turn-in.
- `/java replan` rebuilds the route from scratch. Normally the route keeps its order as you play, and only changes when something clearly better comes up.
- `/java skip` skips the current quest. `/java unskip` clears all skips.
- `/java done` lists every quest this character has completed.
- `/java waypoint` turns the map waypoint and navigation arrow on or off.
- `/java reset` moves the panel back to the center.

## How the route is chosen

- Quests are filtered by race, class, faction, level, prerequisites, quest chains and exclusive quests.
- Repeatable, profession, reputation, dungeon, holiday and elite-group quests are left out. Escorts and other scripted events stay in, priced at the few minutes they take.
- Gray quests are left out, except class quests.
- Quests above your difficulty cap, and quests whose mobs are too high, wait until you level up.
- Each remaining quest is scored by XP (from QuestieDB's XP data, including XP from the mobs you kill for it) divided by the time it adds to the route. Travel time is estimated from your learned run or mount speed.
- Quests are inserted best-first, with pickup before objectives and objectives before turn-in. A quest is kept only if it beats a share of what you would earn from just grinding mobs.
- Class quests (spells, pets, totems, forms) are always kept when they're on your continent.
- When nothing nearby is worth doing, the route points you to the zone with the most XP available for your level.

## Limitations

- This is a heuristic, not a proven fastest route.
- QuestieDB's coverage of new Forever zones and quests is still incomplete. Quests it has no map data for are left out of the route, or shown without a waypoint.
- Flight paths, hearthstone and dungeons aren't planned yet.
