# Releasing Oldman Java

1. Bump `## Version` in `OldmanJava/OldmanJava.toc`.
2. Refresh the list of quests that aren't on Forever from a current Questie checkout: `python3 tools/import_questie_blacklist.py <path to Questie>`. It reads Questie's blacklist as text and evaluates each entry the way Questie does on Forever. It stops if it finds an entry it doesn't understand.
3. Run the tests: `luajit tests/harness.lua OldmanJava` and `luajit tests/notingame.lua OldmanJava/NotInGame.lua`. Both must exit 0.
4. Run `./build.sh`. It downloads the latest stable QuestieDB Forever release from GitHub, verifies its SHA-256 against QuestieDB's `release.json`, and checks the data contract and client interface. It then writes:
   - `dist/OldmanJava-<version>-Forever.zip`, which holds `OldmanJava/` and `QuestieDB/`. Upload this to GitHub releases and Wago, and use it for manual installs.
   - `dist/OldmanJava-<version>-Forever-CurseForge.zip`, which holds `OldmanJava/` only.
5. On CurseForge:
   - Upload the CurseForge zip.
   - Set game version **Forever** (CurseForge game version id `17053`).
   - Under Relations, add **questiedb** as a **Required Dependency**. The CurseForge app then installs QuestieDB together with Oldman Java. This is the same setup Questie uses.

QuestieDB is GPL-3.0. The bundle ships it unmodified, with its `LICENSE.md` and `gpl-3.0.md`.
