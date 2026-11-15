# Oldman Java

A leveling addon for World of Warcraft: Forever (client 1.60, interface 16001). It reads your character's real state (every quest you've completed, your quest log, level, race and class) and builds a live route that picks up, completes and turns in quests in the order that earns the most XP per minute. The route updates as you accept, progress, turn in and level.

- A panel with the current step, a compass arrow, live objective counts, your XP bar with the XP the route will add, and a level-up estimate.
- A world map overlay: a colored area for each objective's mobs, drops or objects, and numbered markers for your next 10 steps.
- Quests are filtered by race, class, faction, level, prerequisites, chains and exclusive pairs, plus Questie's list of quests that aren't on Forever. Quests above your difficulty cap wait until you level.
- Each quest is scored by its XP, including the real XP of the mobs you kill for it, divided by the time it adds to the route.

The full guide to the panel, map and slash commands is in [OldmanJava/README.md](OldmanJava/README.md). That file also ships inside the addon.

## Install

No release has been published yet. To build one yourself:

```
./build.sh
```

The script needs `curl`, `unzip`, `zip`, `python3` and `shasum`. It downloads the latest stable [QuestieDB](https://github.com/Questie/QuestieDB) Forever release, verifies its checksum, and writes `dist/OldmanJava-<version>-Forever.zip`. Unzip that into `_forever_/Interface/AddOns` in your World of Warcraft folder. It holds two folders, `OldmanJava` and `QuestieDB`, and both go in AddOns. Questie itself is optional.

## Development

```
OldmanJava/   the addon (Lua 5.1, loaded in .toc order)
tests/        offline tests that run the real addon files against a stubbed client
tools/        blacklist importer and texture generator
build.sh      release zips
```

Run the tests with [LuaJIT](https://luajit.org):

```
luajit tests/harness.lua OldmanJava
luajit tests/notingame.lua OldmanJava/NotInGame.lua
```

Add `-joff` to the first command to run at roughly in-game speed. Set `TIME_SLICES=1` to print the longest planner time slice.

`OldmanJava/NotInGame.lua` is generated. Refresh it with `python3 tools/import_questie_blacklist.py <path to a Questie checkout>`. See [RELEASING.md](RELEASING.md) for the release steps.

## License

GPL-3.0. See [LICENSE](LICENSE). `NotInGame.lua` is generated from [Questie](https://github.com/Questie/Questie)'s quest blacklist, and the quest data comes from QuestieDB. Both are GPL-3.0.
