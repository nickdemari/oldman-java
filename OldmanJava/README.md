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
- `/java settings` opens the settings window. It's also on the panel (hover, then Settings) and in Esc > Options > AddOns > Oldman Java. It covers difficulty, class quests, flying and hearthing, accepting and turning in for you, skipped and completed quests, the map overlay and its labels, the waypoint and beacon, and the panel's visibility, lock, Up Next lines, size and position.
- The compass on the panel points toward the current step from where your character is facing. The arrow fades from green (on course) through gold to red (turn around). Distance and compass direction sit underneath it.
- Objective steps show a live progress bar, and every objective in Up Next shows your count on the right ("1/7", or "2 in bags" for a quest you haven't picked up yet). The world map labels show the same count. The bar at the bottom shows your XP, with a lighter section for the XP this route will add, and the header estimates when you'll level up.
- Hover the panel to show Skip, Replan and Completed. Click "OLDMAN JAVA" to collapse the panel to just the current step. Drag to move it, and Ctrl + scroll to resize it.
- On the world map, each objective on your route gets a soft colored area where its mobs, drops or objects are. Darker means more spawns, and every quest has its own color with a label. Numbered markers show your next 10 steps, joined by a thin line from where you stand. Hover a marker to see the step. `/java map` turns the overlay on or off.
- Crates, chests and other objects with only a few possible spots become **SEARCH** steps. Only some of those spots have one at a time, and other players loot them. The arrow visits the nearest spot you haven't checked, the panel shows "8 possible spots · 3 checked", and the map rings every spot. A spot only counts as checked after you've stood near it for a moment out of combat. Hovering the object locks the search onto that spot until you've looted it, even if mobs chase you off. Click the compass to search every spot again. If none turns up, it starts another lap, because they respawn.
- Some mobs and quest givers walk a path instead of standing on their spawn point. When one has only a few spawn points, the arrow leads you along its path until you meet it, the panel says "patrols", and the map area covers the path. If you've walked the whole path and it isn't there, the panel says so: it's dead or someone got to it first, and it'll be back.
- In Kalimdor the arrow follows walkable ground. Oldman Java carries the slope of every 4-yard patch of Kalimdor's ground, taken from the game's own terrain, and works out a way around cliffs and steep hills. The arrow points at the next turn of that way, and the distance under it is the distance along it. The world map line follows the same way. It knows the water too: the way swims where that's quicker than walking round, counting swimming at its slower speed, and keeps you out of lava, slime, fel and tar. Rocks, trees and buildings aren't in that data, and the way never takes a drop you couldn't climb back up. Outside Kalimdor, and for legs under 100 or over 2,500 yards, the arrow points straight.
- The route flies and hearths when that's quicker. A **FLY** step sends you to a flight master and names where to fly; it's done once you're in the air, and the next step shows while you fly. Oldman Java only uses flight points you know, and learns them from the flight map whenever you talk to a flight master, so talk to one once after installing. Flight times start as an estimate and become the real times once you've flown each route. A **HEARTH** step means use your Hearthstone now. The route uses it once, on the leg where it saves the most, and only when it's off cooldown by then. Oldman Java learns where your hearthstone takes you while you're in that town, and exactly when you set it or use it. When the route works from a new town (three or more of its quest givers there), a **SET HEARTH** step sends you to that town's innkeeper while you're there, and hearths after it go back to that town. It waits while your current home still holds at least half as much of the route. Turn all of this off in settings (Fly and hearth when it's quicker).
- When you talk to a quest giver, Oldman Java accepts the quests your route picks up and turns in the ones you've finished. Quests the route leaves out (skipped, dungeon, elite, too high or gray) are left for you, and so are repeatable hand-ins and turn-ins that cost money. When a quest offers a choice of rewards, the window stays open and the chat tells you to pick. Hold Shift as you start talking to an NPC to handle that conversation yourself. Turn it off in settings (Accept and turn in for me). If Questie's own auto accept or turn-in is on, Oldman Java leaves that part to Questie.
- If you keep moving for about 20 seconds without getting closer to a step, Oldman Java treats the way as blocked. While it's following a way over the terrain, it marks the ground just ahead as blocked and finds another. Otherwise it moves a nearby step of another quest ahead, or tells you to look for a way around.
- `/java route` prints every remaining step with the distance and direction of each leg.
- `/java difficulty easy | normal | hard` sets how far above your level the route may go: easy is 1 level, normal 2 (the default), hard 4. Quests whose mobs are more than one level past that also wait. Too-hard quests already in your log are held, with a note on the panel, until you level up. Quests you've finished are still routed to their turn-in.
- `/java replan` rebuilds the route from scratch. Normally the route keeps its order as you play, and only changes when something clearly better comes up.
- `/java skip` skips the current quest. `/java unskip` clears all skips.
- `/java done` lists every quest this character has completed.
- `/java waypoint` turns the map waypoint and navigation arrow on or off.
- `/java slope 46 | 50 | 55 | 60 | 68` sets how steep the ground the arrow may lead you over can be, in degrees. 50 is the default. If it leads you up slopes you can't climb, lower it. If it sends you the long way round a slope you could walk, raise it. `/java terrain` tells you what the data says about the ground under you (how steep, or water), whether the game says you're swimming, and the way the arrow is following.
- `/java travel` lists the flight points the route can use and says where your hearthstone goes and when it's ready.
- `/java reset` moves the panel back to the center.

## How the route is chosen

- Quests are filtered by race, class, faction, level, prerequisites, quest chains and exclusive quests.
- Repeatable, profession, reputation, dungeon, holiday and elite-group quests are left out. Escorts and other scripted events stay in, priced at the few minutes they take.
- Gray quests are left out, except class quests.
- Quests above your difficulty cap, and quests whose mobs are too high, wait until you level up.
- Each remaining quest is scored by XP (from QuestieDB's XP data, including XP from the mobs you kill for it) divided by the time it adds to the route. Travel time is estimated from your learned run or mount speed, or by air where flying is quicker.
- Quests are inserted best-first, with pickup before objectives and objectives before turn-in. A quest is kept only if it beats a share of what you would earn from just grinding mobs.
- Class quests (spells, pets, totems, forms) are always kept when they're on your continent.
- When nothing nearby is worth doing, the route points you to the zone with the most XP available for your level.

## Limitations

- This is a heuristic, not a proven fastest route.
- QuestieDB's coverage of new Forever zones and quests is still incomplete. Quests it has no map data for are left out of the route, or shown without a waypoint.
- Dungeons aren't planned yet.
- The route's order counts flights but not the hearthstone: the hearth goes on the leg it shortens most in a route already put in order.
- Flight points are known for Kalimdor and the Eastern Kingdoms only.
- The route's order is still worked out from straight-line distances. The arrow and the map line follow walkable ground, but the planner doesn't yet know that a leg around a ridge is longer than it looks.
- Walkable ground is known for Kalimdor only.
