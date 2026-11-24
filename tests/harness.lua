-- Offline tests for Oldman Java: a stubbed WoW client and a fake LibQuestieDB drive the real addon files.
-- usage: luajit tests/harness.lua OldmanJava        (add -joff to run at roughly in-game speed)
local addonDir = assert(arg[1], "addon dir")

local failures, passes = 0, 0

-- Optional: time every coroutine slice (one resume = work done in one frame before yielding).
local sliceMax, sliceCount, sliceOver = 0, 0, 0
if os.getenv("TIME_SLICES") then
    local resume = coroutine.resume
    coroutine.resume = function(co, ...)
        local t0 = os.clock()
        local r = { resume(co, ...) }
        local ms = (os.clock() - t0) * 1000
        sliceCount = sliceCount + 1
        if ms > 16 then sliceOver = sliceOver + 1 end
        if ms > sliceMax then sliceMax = ms end
        return unpack(r)
    end
end
local function check(cond, msg)
    if cond then passes = passes + 1 else failures = failures + 1; print("FAIL: " .. msg) end
end

---------------------------------------------------------------------------
-- Player state
---------------------------------------------------------------------------
local player = { level = 3, raceID = 6, race = "Tauren", class = "HUNTER", faction = "Horde",
    map = 1412, x = 0.45, y = 0.75, mounted = false }
local completedIds = { 108 }
local questLog = {} -- array of {questID, title, level, complete, objectives}
local bags = { [5000] = 1 }

---------------------------------------------------------------------------
-- WoW API stubs
---------------------------------------------------------------------------
function UnitRace() return player.race, player.race, player.raceID end
function UnitClass() return player.class:sub(1,1) .. player.class:sub(2):lower(), player.class, 3 end
function UnitFactionGroup() return player.faction end
function UnitLevel() return player.level end
function GetMaxPlayerLevel() return 60 end
function UnitXP() return 1200 end
function UnitXPMax() return 4000 end
function IsControlKeyDown() return false end
local inCombat = false
function InCombatLockdown() return inCombat end
function IsMounted() return player.mounted end
function GetPlayerFacing() return player.facing or 0 end
function GetUnitSpeed() return player.mounted and 14 or 0 end
local clock = 0
function GetTime() return clock end
function debugprofilestop() return os.clock() * 1000 end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function BreakUpLargeNumbers(n) return tostring(n) end
tinsert = table.insert
UISpecialFrames = {}

function CreateVector2D(x, y) return { x = x, y = y } end

-- Two fake zones side by side on continent 1.
local MAPS = {
    [1412] = { name = "Mulgore", ox = 0, oy = 0, w = 3000, h = 2000 },
    [1413] = { name = "The Barrens", ox = 3000, oy = 0, w = 4000, h = 4000 },
    [1500] = { name = "Testlands", cont = 2, wow = true, top = 5000, left = 2000, w = 2400, h = 2400 },
    [1414] = { name = "Kalimdor", ox = 0, oy = 0, w = 7000, h = 4000 },
}
C_Map = {}
function C_Map.GetWorldPosFromMapPos(map, v)
    local m = MAPS[map]
    if not m then return nil end
    if m.wow then
        -- WoW convention: world X grows north, world Y grows west.
        return m.cont, { x = m.top - v.y * m.h, y = m.left - v.x * m.w }
    end
    return m.cont or 1, { x = m.ox + v.x * m.w, y = m.oy + v.y * m.h }
end
function C_Map.GetMapPosFromWorldPos(cont, v, mapID)
    local m = MAPS[mapID]
    if not m or (m.cont or 1) ~= cont then return nil end
    if m.wow then
        return mapID, { x = (m.left - v.y) / m.w, y = (m.top - v.x) / m.h }
    end
    return mapID, { x = (v.x - m.ox) / m.w, y = (v.y - m.oy) / m.h }
end
function C_Map.GetBestMapForUnit() return player.map end
function C_Map.GetPlayerMapPosition() return { x = player.x, y = player.y } end
function C_Map.GetMapInfo(map) return MAPS[map] and { name = MAPS[map].name } end
function C_Map.GetAreaInfo(area) return ({ [215] = "Mulgore", [17] = "The Barrens" })[area] end
local waypoint
function C_Map.CanSetUserWaypointOnMap() return true end
function C_Map.SetUserWaypoint(p) assert(p.uiMapID and p.position and p.position.x); waypoint = p; return true end
function C_Map.ClearUserWaypoint() waypoint = nil end
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
C_Item = { GetItemCount = function(id) return bags[id] or 0 end }
C_AddOns = { IsAddOnLoaded = function() return false end, GetAddOnMetadata = function() return "test" end }

C_QuestLog = {}
function C_QuestLog.GetAllCompletedQuestIDs() local t = {}; for i, v in ipairs(completedIds) do t[i] = v end; return t end
function C_QuestLog.GetNumQuestLogEntries() return #questLog end
function C_QuestLog.GetInfo(i)
    local q = questLog[i]
    return q and { questID = q.questID, title = q.title, level = q.level, isHeader = false, isHidden = false }
end
local function findLog(id) for _, q in ipairs(questLog) do if q.questID == id then return q end end end
function C_QuestLog.IsComplete(id) local q = findLog(id); return q and q.complete or false end
function C_QuestLog.ReadyForTurnIn(id) return C_QuestLog.IsComplete(id) end
function C_QuestLog.GetQuestObjectives(id)
    local q = findLog(id); if not q then return {} end
    local out = {}
    for i, o in ipairs(q.objectives) do out[i] = { text = o.text, type = o.type, finished = o.finished, numFulfilled = o.have, numRequired = o.need } end
    return out
end
function C_QuestLog.GetMaxNumQuestsCanAccept() return 20 end
function C_QuestLog.GetTrivialRange() return 5 end
function C_QuestLog.GetTitleForQuestID(id) return nil end

-- Timers: queued and flushed by the harness.
local timers, tickers = {}, {}
C_Timer = {}
function C_Timer.After(_, fn) timers[#timers + 1] = fn end
function C_Timer.NewTicker(_, fn) tickers[#tickers + 1] = fn; return {} end

-- Generic frame mock: any unknown method is a no-op; Create* methods return new mocks.
local frames = {}
local function NewMock()
    local obj = { scripts = {}, shown = true, text = "", events = false }
    return setmetatable(obj, { __index = function(t, k)
        if type(k) == "string" and k:sub(1, 6) == "Create" then return function() return NewMock() end end
        if k == "GetStringWidth" then return function() return 40 end end
        if k == "GetWidth" then return function() return 200 end end
        if k == "IsMouseOver" then return function() return false end end
        if k == "GetFrameLevel" then return function() return 5 end end
        if k == "GetHeight" then return function() return 150 end end
        if k == "SetScript" then return function(self, name, fn) self.scripts[name] = fn end end
        if k == "GetScript" then return function(self, name) return self.scripts[name] end end
        if k == "RegisterEvent" then return function(self, e) if not rawget(self, "events") then rawset(self, "events", {}) end; self.events[e] = true end end
        if k == "SetText" then return function(self, s) self.text = s or "" end end
        if k == "GetText" then return function(self) return self.text end end
        if k == "Show" then return function(self) self.shown = true end end
        if k == "Hide" then return function(self) self.shown = false end end
        if k == "SetShown" then return function(self, v) self.shown = v and true or false end end
        if k == "IsShown" then return function(self) return self.shown end end
        if k == "GetStringHeight" then return function() return 12 end end
        if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
        return function() end
    end })
end
function CreateFrame(_, name)
    local f = NewMock()
    frames[#frames + 1] = f
    if name then _G[name] = f end
    return f
end
UIParent = NewMock()
GameTooltip = NewMock()
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) print("  [chat] " .. msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end }
SlashCmdList = {}
local tooltipCallbacks = {}
Enum = { TooltipDataType = { Item = 0, Unit = 2, Object = 3 } }
TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) tooltipCallbacks[kind] = fn end }

MapCanvasDataProviderMixin = {
    OnAdded = function(self, map) self.owningMap = map end,
    GetMap = function(self) return self.owningMap end,
}
function CreateFromMixins(...)
    local out = {}
    for _, m in ipairs({ ... }) do for k, v in pairs(m) do out[k] = v end end
    return out
end
local shownMapID, canvasScale = 1500, 1
local canvasMock = NewMock()
WorldMapFrame = {
    providers = {},
    AddDataProvider = function(self, p) self.providers[#self.providers + 1] = p; p:OnAdded(self) end,
    GetMapID = function() return shownMapID end,
    GetCanvas = function() return canvasMock end,
    GetCanvasScale = function() return canvasScale end,
    IsShown = function() return true end,
    GetPinFrameLevelsManager = function()
        return { GetValidFrameLevel = function(_, t) return t == "PIN_FRAME_LEVEL_QUEST_BLOB" and 2100 or 2400 end }
    end,
}

---------------------------------------------------------------------------
-- Fake LibQuestieDB
---------------------------------------------------------------------------
local Q = {}   -- questId -> fields
local N = {}   -- npcId -> fields
local O = {}   -- objectId -> fields
local I = {}   -- itemId -> fields

local function npc(id, name, area, x, y, extra)
    N[id] = { name = name, spawns = { [area] = { { x, y } } }, friendlyToFaction = "AH", rank = 0, minLevel = 1 }
    if extra then for k, v in pairs(extra) do N[id][k] = v end end
end
local function mobs(id, name, area, cx, cy, n, extra)
    local list = {}
    for i = 1, n do list[i] = { cx + (i % 4) * 0.6, cy + math.floor(i / 4) * 0.6 } end
    N[id] = { name = name, spawns = { [area] = list }, rank = 0, minLevel = 1 }
    if extra then for k, v in pairs(extra) do N[id][k] = v end end
end
local function quest(id, f)
    f.name = f.name or ("Quest " .. id)
    f.startedBy = f.startedBy or { {} }
    f.finishedBy = f.finishedBy or f.startedBy
    f.objectives = f.objectives or {}
    Q[id] = f
end

-- Mulgore hub at (44, 76); mob camps south-east.
npc(1, "Grull Hawkwind", 215, 44.0, 76.0)
npc(2, "Chief Hawkwind", 215, 44.5, 76.5)
npc(3, "Seer Ravenfeather", 215, 45.0, 75.5)
npc(4, "Hunter Trainer", 215, 44.2, 76.2)
npc(5, "Alliance Guy", 215, 40, 70, { friendlyToFaction = "A" })
npc(6, "Barrens Giver", 17, 50, 50)
mobs(10, "Plainstrider", 215, 50, 80, 12)
mobs(11, "Prairie Wolf", 215, 48, 70, 12)
mobs(12, "Bristleback Elite", 215, 60, 60, 4, { rank = 1 })
mobs(13, "Battleboar", 215, 41, 82, 10)
mobs(15, "Ridge Stalker", 215, 47, 72, 8, { minLevel = 9, maxLevel = 9 })
mobs(16, "Ornery Plainstrider", 215, 30, 30, 20, { minLevel = 16, maxLevel = 17 })
mobs(14, "Zhevra Runner", 17, 52, 54, 12)
I[100] = { name = "Plainstrider Meat", npcDrops = { 10, 16 } }
O[50] = { name = "Supply Crate", spawns = { [215] = { { 52, 70 }, { 52.4, 70.3 }, { 52.2, 70.6 }, { 49, 78 }, { 49.3, 78.4 }, { 49.1, 78.8 } } } }
I[200] = { name = "Crate of Supplies", objectDrops = { 50 } }
I[5000] = { name = "Dusty Letter" }

quest(100, { name = "The Hunt Begins", questLevel = 2, requiredLevel = 1, startedBy = { { 1 } }, objectives = { nil, nil, { { 100 } } } })
quest(101, { name = "Rite of Strength", questLevel = 4, requiredLevel = 3, startedBy = { { 2 } }, preQuestSingle = { 100 }, objectives = { { { 13 } } } })
quest(102, { name = "Taming the Beast", questLevel = 10, requiredLevel = 10, requiredClasses = 4, startedBy = { { 4 } }, objectives = { { { 13 } } } })
quest(103, { name = "Warrior Only", questLevel = 3, requiredLevel = 1, requiredClasses = 1, startedBy = { { 3 } } })
quest(104, { name = "Human Only", questLevel = 3, requiredLevel = 1, requiredRaces = 1, startedBy = { { 3 } } })
quest(105, { name = "Repeatable", questLevel = 3, requiredLevel = 1, specialFlags = 1, startedBy = { { 3 } } })
quest(106, { name = "Dungeon Quest", questLevel = 3, requiredLevel = 1, zoneOrSort = 718, startedBy = { { 3 } } })
quest(107, { name = "Far Away", questLevel = 3, requiredLevel = 1, startedBy = { { 6 } }, objectives = { { { 14 } } } })
quest(108, { name = "Already Done", questLevel = 2, requiredLevel = 1, startedBy = { { 3 } } })
quest(109, { name = "Gray Quest", questLevel = 1, requiredLevel = 1, startedBy = { { 3 } }, objectives = { { { 11 } } } })
quest(110, { name = "Dusty Letter", questLevel = 3, requiredLevel = 1, startedBy = { nil, nil, { 5000 } }, finishedBy = { { 3 } } })
quest(111, { name = "Hunter Category Quest", questLevel = 3, requiredLevel = 1, zoneOrSort = -261, startedBy = { { 4 } }, finishedBy = { { 4 } } })
quest(112, { name = "Warrior Category Quest", questLevel = 3, requiredLevel = 1, zoneOrSort = -81, startedBy = { { 4 } } })
quest(113, { name = "Elite Camp", questLevel = 4, requiredLevel = 1, startedBy = { { 3 } }, objectives = { { { 12 } } } })
quest(114, { name = "Wolves at the Door", questLevel = 3, requiredLevel = 1, startedBy = { { 3 } }, objectives = { { { 11 } } } })
quest(115, { name = "Hostile Giver", questLevel = 3, requiredLevel = 1, startedBy = { { 5 } } })
-- 787 is on Questie's not-in-game list; give it a juicy, nearby, valid-looking entry.
quest(121, { name = "Find the Crate", questLevel = 3, requiredLevel = 1, startedBy = { { 3 } }, objectives = { nil, nil, { { 200 } } } })
quest(116, { name = "Three Levels Up", questLevel = 6, requiredLevel = 1, startedBy = { { 3 } }, objectives = { { { 13 } } } })
quest(118, { name = "Scary Mobs", questLevel = 3, requiredLevel = 1, startedBy = { { 3 } }, objectives = { { { 15 } } } })
quest(120, { name = "Two Levels Up", questLevel = 5, requiredLevel = 1, startedBy = { { 3 } }, objectives = { { { 13 } } } })
quest(117, { name = "Too Hard Already", questLevel = 7, requiredLevel = 1, startedBy = { { 3 } }, objectives = { { { 11 } } } })
quest(119, { name = "Hard But Done", questLevel = 7, requiredLevel = 1, startedBy = { { 3 } } })
quest(787, { name = "The New Horde", questLevel = 3, requiredLevel = 1, startedBy = { { 3 } }, objectives = { { { 11 } } } })

math.randomseed(7)
for k = 1, 30 do
    local qid, giver, mob = 2000 + k, 2000 + k, 3000 + k
    npc(giver, "Giver " .. k, 400, 10 + math.random() * 80, 10 + math.random() * 80)
    mobs(mob, "Beast" .. string.char(64 + k), 400, 8 + math.random() * 80, 8 + math.random() * 80, 10, { minLevel = 19, maxLevel = 20 })
    local finisher = (k % 3 == 0) and { { 2000 + ((k % 30) + 1) } } or { { giver } }
    quest(qid, { name = "Test Quest " .. k, questLevel = 20, requiredLevel = 18, startedBy = { { giver } },
        finishedBy = finisher, objectives = { { { mob } } } })
end

-- Escorts and scripted events, in the Barrens at level 30 (out of the way of the other scenarios).
npc(4001, "Test Prisoner", 17, 60, 60)
npc(4002, "Escort Finisher", 17, 62, 60)
quest(4101, { name = "Rescue Test", questLevel = 30, requiredLevel = 28, startedBy = { { 4001 } }, finishedBy = { { 4002 } },
    questFlags = 2, specialFlags = 2, objectivesText = { "Escort Test Prisoner to the gate, then report to Escort Finisher." } })
quest(4102, { name = "Lost Test", questLevel = 30, requiredLevel = 28, startedBy = { { 4001 } }, finishedBy = { { 4002 } },
    triggerEnd = { "Escort Test Prisoner out of the crag.", { [17] = { { 64, 62 } } } } })
quest(4103, { name = "Explore Test", questLevel = 30, requiredLevel = 28, startedBy = { { 4001 } }, finishedBy = { { 4002 } },
    specialFlags = 2, triggerEnd = { "Explore the test mine", { [17] = { { 58, 64 } } } } })
-- Needs an item that isn't an objective (like Ishamuhale's zhevra carcass).
mobs(4003, "Test Boar", 17, 61, 62, 8, { minLevel = 29, maxLevel = 30 })
I[4201] = { name = "Test Carcass" }
I[4202] = { name = "Test Tusk", npcDrops = { 4003 } }
quest(4104, { name = "Carcass Test", questLevel = 30, requiredLevel = 28, startedBy = { { 4001 } }, finishedBy = { { 4002 } },
    objectives = { nil, nil, { { 4202 } } }, requiredSourceItems = { 4201 } })

-- NPCs that walk a path, in the Barrens at level 40 (out of the way of the other scenarios).
-- One map unit is 40 yards there. The first path point sits on the spawn point and the third
-- sits next to the second, so both are dropped.
local function path(x, y) return { [17] = { { { x + 0.1, y }, { x + 1.25, y }, { x + 1.5, y }, { x + 2.5, y }, { x + 3.75, y } } } } end
npc(4301, "Road Walker", 17, 30, 30, { waypoints = path(30, 30) })
N[4302] = { name = "Patrol Captain", rank = 0, minLevel = 39, maxLevel = 40, spawns = { [17] = { { 20, 20 } } }, waypoints = path(20, 20) }
mobs(4303, "Camp Guard", 17, 26, 20, 6, { minLevel = 39, maxLevel = 40, waypoints = path(26, 24) })
N[4304] = { name = "Odd Walker", rank = 0, minLevel = 39, maxLevel = 40, spawns = { [17] = { { 24, 24 } } },
    waypoints = { [17] = "junk", [215] = { 5, { "x", { 1 } } } } }
I[4350] = { name = "Captain's Orders", npcDrops = { 4302, 4303 } }
quest(4311, { name = "Patrol Kill", questLevel = 40, requiredLevel = 38, startedBy = { { 4301 } }, objectives = { { { 4302 } } } })
quest(4312, { name = "Mixed Drops", questLevel = 40, requiredLevel = 38, startedBy = { { 4301 } }, objectives = { nil, nil, { { 4350 } } } })
quest(4313, { name = "Odd Path", questLevel = 40, requiredLevel = 38, startedBy = { { 4301 } }, objectives = { { { 4304 } } } })
N[4305] = { name = "Twin Walker", rank = 0, minLevel = 39, maxLevel = 40, spawns = { [17] = { { 40, 40 }, { 40, 45 } } }, waypoints = path(40, 40) }
quest(4314, { name = "Two Spawns", questLevel = 40, requiredLevel = 38, startedBy = { { 4301 } }, objectives = { { { 4305 } } } })

local XP = { [121] = { 3, 450 }, [116] = { 6, 700 }, [118] = { 3, 400 }, [120] = { 5, 500 }, [117] = { 7, 800 }, [119] = { 7, 800 }, [787] = { 3, 900 }, [100] = { 2, 170 }, [101] = { 4, 450 }, [102] = { 10, 800 }, [107] = { 3, 300 }, [109] = { 1, 80 },
    [110] = { 3, 250 }, [111] = { 3, 200 }, [113] = { 4, 500 }, [114] = { 3, 350 } }
-- Level 30 quests pay about this much; escorts are worth their four minutes at this rate.
XP[4101], XP[4102], XP[4103], XP[4104] = { 30, 2800 }, { 30, 2800 }, { 30, 2800 }, { 30, 2800 }
XP[4311], XP[4312], XP[4313], XP[4314] = { 40, 3600 }, { 40, 3600 }, { 40, 3600 }, { 40, 3600 }

local NUMERIC = { questLevel = true, requiredLevel = true, requiredMaxLevel = true, requiredRaces = true,
    requiredClasses = true, zoneOrSort = true, specialFlags = true, breadcrumbForQuestId = true, parentQuest = true,
    availableUntilCompleted = true, availableStartingWith = true, disabledByQuest = true, requiredSpell = true,
    requiredSpecialization = true, rank = true, minLevel = true, maxLevel = true }

local function Entity(store)
    local e = {}
    function e.Get(id, key)
        local row = store[id]
        if not row then return nil end
        local v = row[key]
        if v == nil and NUMERIC[key] then return 0 end
        if type(v) == "table" then
            -- fresh copy, like the real provider
            local function copy(t) local c = {}; for k, x in pairs(t) do c[k] = type(x) == "table" and copy(x) or x end; return c end
            return copy(v)
        end
        return v
    end
    function e.GetAllIds()
        local ids = {}
        for id in pairs(store) do ids[#ids + 1] = id end
        table.sort(ids)
        return ids
    end
    function e.Exists(id) return store[id] ~= nil end
    return setmetatable(e, { __index = function(_, key) return function(id) return e.Get(id, key) end end })
end

LibQuestieDB = {
    Quest = Entity(Q), Npc = Entity(N), Object = Entity(O), Item = Entity(I),
    RequireContract = function(n) return n <= 4, "too old" end,
    Enum = {
        raceMaskById = { [1] = 1, [2] = 2, [5] = 16, [6] = 32, [8] = 128, [96] = 8589934592 },
        classKeys = { WARRIOR = 1, PALADIN = 2, HUNTER = 4, ROGUE = 8, PRIEST = 16, SHAMAN = 64, MAGE = 128, WARLOCK = 256, DRUID = 1024 },
    },
    Support = {
        Get = function(name)
            if name == "ZoneDB" then
                return { private = {
                    areaIdToUiMapId = "return { [215] = 1412, [17] = 1413, [718] = 1413, [400] = 1500 }",
                    areaIdToUiMapIdOverride = "return { [0] = 0 }",
                    dungeons = { [718] = { "Wailing Caverns", nil, 17, { { 17, 46, 36.5 } } } },
                } }
            elseif name == "QuestXP" then
                return { db = XP }
            end
        end,
    },
}

---------------------------------------------------------------------------
-- Load the addon
---------------------------------------------------------------------------
local SP = {}
local toc = io.open(addonDir .. "/OldmanJava.toc"):read("*a")
for line in toc:gmatch("[^\r\n]+") do
    if line:match("%.lua$") then
        local chunk = assert(loadfile(addonDir .. "/" .. line))
        chunk("OldmanJava", SP)
    end
end
if os.getenv("NO_NOTINGAME") then SP.NotInGame = nil end
local events
for _, f in ipairs(frames) do if f.events and f.events.ADDON_LOADED then events = f end end
assert(events, "event frame not found")
local function fire(event, ...) events.scripts.OnEvent(events, event, ...) end

local function flush()
    -- Run frames until timers are drained and the planner's job driver goes idle.
    -- The route panel has a permanent OnUpdate (arrow), so it doesn't count as pending work.
    for _ = 1, 20000 do
        local pending = timers
        timers = {}
        for _, fn in ipairs(pending) do fn() end
        local busy = false
        for _, f in ipairs(frames) do
            local onUpdate = f.scripts.OnUpdate
            if onUpdate then
                onUpdate(f, 0.016)
                if f ~= _G.OldmanJavaFrame then busy = true end
            end
        end
        if #timers == 0 and not busy then break end
    end
    for _, fn in ipairs(tickers) do fn() end
end

local function routeQuests()
    local set = {}
    for _, node in ipairs(SP.Planner.route) do if node.q then set[node.q] = true end end
    return set
end

local function printRoute(title)
    print("\n== " .. title .. " ==")
    for i, node in ipairs(SP.Planner.route) do
        print(string.format("%2d. %-7s %-45s %s", i, node.kind, (node.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""), node.sub or ""))
    end
    local s = SP.Planner.stats
    print(string.format("   %d quests, %d XP, %.0f s, deferred %d", s.quests, s.xp, s.seconds, #SP.Planner.deferred))
end

local function precedenceOK()
    local idx = {}
    for i, node in ipairs(SP.Planner.route) do
        if node.q then
            idx[node.q] = idx[node.q] or {}
            local t = idx[node.q]
            if node.kind == "pickup" then t.pickup = i
            elseif node.kind == "turnin" then t.turnin = i
            else t.objMin = math.min(t.objMin or i, i); t.objMax = math.max(t.objMax or i, i) end
        end
    end
    for q, t in pairs(idx) do
        if t.pickup and t.objMin and t.pickup > t.objMin then return false, q end
        if t.turnin and t.objMax and t.objMax > t.turnin then return false, q end
        if t.pickup and t.turnin and t.pickup > t.turnin then return false, q end
    end
    return true
end

---------------------------------------------------------------------------
-- Scenario A: level 3 Tauren Hunter in Mulgore, one active quest
---------------------------------------------------------------------------
questLog = { { questID = 114, title = "Wolves at the Door", level = 3, complete = false,
    objectives = { { text = "3/8 Prairie Wolf slain", type = "monster", finished = false, have = 3, need = 8 } } } }

fire("ADDON_LOADED", "OldmanJava")
fire("PLAYER_LOGIN")
flush()
fire("PLAYER_ENTERING_WORLD")
flush()

check(SP.ready, "addon ready")
check(SP.Data.indexReady, "index built")
printRoute("Scenario A: level 3")
local inRoute = routeQuests()
check(inRoute[100], "The Hunt Begins routed")
check(not inRoute[101], "Rite of Strength waits for its prerequisite")
check(not inRoute[103], "warrior-only quest excluded")
check(not inRoute[104], "human-only quest excluded")
check(not inRoute[105], "repeatable excluded")
check(not inRoute[106], "dungeon quest excluded")
check(not inRoute[108], "completed quest excluded")
check(inRoute[110], "item-started quest routed when the item is in bags")
check(inRoute[111], "hunter-category class quest routed")
check(not inRoute[112], "warrior-category quest excluded")
check(not inRoute[113], "elite quest excluded")
check(inRoute[114], "active quest routed")
check(not inRoute[115], "quest from hostile NPC excluded")
check(not inRoute[787], "quest Questie lists as not in the game is excluded")
check(SP.NotInGame and SP.NotInGame[787], "not-in-game list loaded from the TOC")
check(not inRoute[107], "far-away quest not worth the trip at level 3")
local ok, bad = precedenceOK()
check(ok, "pickup -> objectives -> turn-in order (quest " .. tostring(bad) .. ")")
check(SP.Planner.route[1].inBags and waypoint == nil, "no waypoint for a quest started from the bags")
check(SP.Data.completed[108], "server completed list read")

---------------------------------------------------------------------------
-- Turn in 100: completed set updates and 101 unlocks
---------------------------------------------------------------------------
completedIds[#completedIds + 1] = 100
fire("QUEST_TURNED_IN", 100)
flush()
inRoute = routeQuests()
printRoute("After turning in The Hunt Begins")
check(SP.Data.completed[100], "turn-in recorded as completed")
check(not inRoute[100], "turned-in quest leaves the route")
check(inRoute[101], "follow-up quest unlocked by prerequisite")

---------------------------------------------------------------------------
-- Scenario B: level 10 - class quest with a level requirement, gray quests drop
---------------------------------------------------------------------------
player.level = 10
fire("PLAYER_LEVEL_UP", 10)
flush()
inRoute = routeQuests()
printRoute("Scenario B: level 10")
check(inRoute[102], "level-10 class quest routed")
check(inRoute[111], "gray class quest still routed")
check(not inRoute[109], "gray quest dropped")
ok, bad = precedenceOK()
check(ok, "precedence at level 10 (quest " .. tostring(bad) .. ")")

-- Skipping an active quest removes it from the route; unskip brings it back.
-- Skip the active quest (point the "current step" at it by skipping until it's current is overkill;
-- mark it skipped directly through the same path /sp skip uses).
SP.char.skipped[114] = true
SP.RequestPlan()
flush()
check(not routeQuests()[114], "skipped active quest leaves the route")
check(#SP.Planner.deferred >= 1, "skipped active quest listed as not routed")
local current = SP.UI.CurrentNode()
SlashCmdList.OLDMANJAVA("skip")
flush()
check(current and current.q and not routeQuests()[current.q], "/sp skip removes the current quest")
SlashCmdList.OLDMANJAVA("unskip")
flush()
check(routeQuests()[114], "unskip brings the active quest back")

---------------------------------------------------------------------------
-- Scenario C: Mulgore exhausted at level 3 -> travel to the next hub
---------------------------------------------------------------------------
player.level = 3
for _, id in ipairs({ 100, 101, 102, 109, 110, 111, 113, 114, 120, 121 }) do completedIds[#completedIds + 1] = id end
questLog = {}
fire("PLAYER_LEVEL_UP", 3)
flush()
printRoute("Scenario C: zone exhausted")
local first = SP.Planner.route[1]
check(first and first.kind == "travel", "first step is travel when nothing is left nearby")
check(first and first.text:find("The Barrens", 1, true) ~= nil, "travel target is The Barrens")
check(routeQuests()[107], "route continues with the next hub's quest")
check(waypoint and waypoint.uiMapID == 1413, "waypoint points at the next zone")
ok, bad = precedenceOK()
check(ok, "precedence after travel (quest " .. tostring(bad) .. ")")

---------------------------------------------------------------------------
-- Completed list and commands run without errors
---------------------------------------------------------------------------
SlashCmdList.OLDMANJAVA("done")
SlashCmdList.OLDMANJAVA("skip")
flush()
SlashCmdList.OLDMANJAVA("unskip")
flush()
SlashCmdList.OLDMANJAVA("help")

-- Skyborne masks go past 32 bits
check(SP.Data.HasBit(8589934592 + 32, 8589934592), "HasBit bit 33")
check(not SP.Data.HasBit(32, 8589934592), "HasBit bit 33 absent")
check(SP.Data.HasBit(8589934592 + 32, 32), "HasBit low bit with high bit set")


---------------------------------------------------------------------------
-- Direction: compass and turn angle on both world-axis conventions
---------------------------------------------------------------------------
local D = SP.Data
local function near(a, b) return math.abs(a - b) < 1e-6 end
for _, map in ipairs({ 1412, 1500 }) do
    local here = D.MakePoint(map, 0.5, 0.5)
    check(D.Compass(here, D.MakePoint(map, 0.5, 0.2)) == "N", map .. ": north is up")
    check(D.Compass(here, D.MakePoint(map, 0.8, 0.5)) == "E", map .. ": east is right")
    check(D.Compass(here, D.MakePoint(map, 0.2, 0.8)) == "SW", map .. ": south-west")
    check(D.Compass(here, D.MakePoint(map, 0.8, 0.2)) == "NE", map .. ": north-east")
    player.facing = 0
    check(near(D.TurnAngle(here, D.MakePoint(map, 0.5, 0.2)), 0), map .. ": facing north, target north -> straight")
    local t = D.TurnAngle(here, D.MakePoint(map, 0.2, 0.5))
    check(near(t, math.pi / 2), map .. ": facing north, target west -> arrow left (" .. tostring(t) .. ")")
    player.facing = math.pi / 2
    t = D.TurnAngle(here, D.MakePoint(map, 0.5, 0.2))
    check(near(t, -math.pi / 2), map .. ": facing west, target north -> arrow right (" .. tostring(t) .. ")")
end
player.facing = 0

---------------------------------------------------------------------------
-- Scenario D: walk a 30-quest zone step by step, like a player would
---------------------------------------------------------------------------
local function keys(nodes)
    local out = {}
    for _, n in ipairs(nodes) do out[#out + 1] = n.kind .. ":" .. tostring(n.q) .. ":" .. tostring(n.key or "") end
    return out
end
local function openNodes()
    local out = {}
    for _, n in ipairs(SP.Planner.route) do
        local done = false
        if n.kind == "pickup" then done = SP.Data.log[n.q] ~= nil
        elseif n.kind == "turnin" then done = SP.Data.completed[n.q] == true end
        if not done then out[#out + 1] = n end
    end
    return out
end

questLog = {}
completedIds = { 108 }
player.level = 20
player.map, player.x, player.y = 1500, 0.5, 0.5
fire("PLAYER_LEVEL_UP", 20)
SlashCmdList.OLDMANJAVA("replan")
flush()
check(SP.Planner.IsValid(SP.Planner.route), "Scenario D route order is legal")
local planned = SP.Planner.stats.quests
check(planned >= 10, "Scenario D plans a full batch of quests (" .. planned .. ")")

-- Local optimum: running the optimizer again changes nothing.
local before = SP.Planner.RouteSeconds(SP.Planner.route, D.PlayerPoint(), 7)
local copy = {}
for i, n in ipairs(SP.Planner.route) do copy[i] = n end
SP.Planner.Optimize(copy, D.PlayerPoint(), 7)
check(SP.Planner.RouteSeconds(copy, D.PlayerPoint(), 7) >= before - 1, "optimizer has converged")

printRoute("Scenario D: 30 random quests")

local steps, flips, inversions, walked = 0, 0, 0, 0
while steps < 200 do
    local node = SP.UI.CurrentNode()
    if not node or node.kind == "travel" then break end
    local expected = keys(SP.UI.CurrentNode() and openNodes() or {})
    table.remove(expected, 1)
    local here = D.PlayerPoint()
    walked = walked + D.Distance(here, node.pt)
    player.map, player.x, player.y = node.pt.map, node.pt.x, node.pt.y
    if node.kind == "pickup" then
        local mob = Q[node.q].objectives[1][1][1]
        questLog[#questLog + 1] = { questID = node.q, title = Q[node.q].name, level = 20, complete = false,
            objectives = { { text = "0/8 " .. N[mob].name .. " slain", type = "monster", finished = false, have = 0, need = 8 } } }
        fire("QUEST_ACCEPTED", node.q)
    elseif node.kind == "obj" then
        for _, e in ipairs(questLog) do
            if e.questID == node.q then
                e.objectives[1].finished = true; e.objectives[1].have = 8; e.complete = true
                e.objectives[1].text = e.objectives[1].text:gsub("^0/", "8/")
            end
        end
        fire("QUEST_LOG_UPDATE")
    elseif node.kind == "turnin" then
        for i, e in ipairs(questLog) do if e.questID == node.q then table.remove(questLog, i) break end end
        completedIds[#completedIds + 1] = node.q
        fire("QUEST_TURNED_IN", node.q)
    end
    flush()
    steps = steps + 1
    local got = keys(openNodes())
    if expected[1] and got[1] ~= expected[1] then
        flips = flips + 1
        if os.getenv("DEBUG_WALK") then
            print(string.format("  step %d (%s %s) plan=%s expected %s got %s", steps, node.kind, tostring(node.q),
                tostring(SP.Planner.lastChoice), expected[1], tostring(got[1])))
        end
    end
    -- Steps that moved = surviving steps minus the longest run still in the original order.
    local pos, seq = {}, {}
    for i, k in ipairs(got) do pos[k] = i end
    -- Only the window the panel shows: the current step plus the next four.
    for i = 1, math.min(5, #expected) do local k = expected[i]; if pos[k] then seq[#seq + 1] = pos[k] end end
    local lis, best = {}, 0
    for i = 1, #seq do
        lis[i] = 1
        for j = 1, i - 1 do if seq[j] < seq[i] and lis[j] + 1 > lis[i] then lis[i] = lis[j] + 1 end end
        if lis[i] > best then best = lis[i] end
    end
    inversions = inversions + (#seq - best)
end
print(string.format("\nScenario D walk: %d steps, %.0f yd walked, %d next-step changes, %d visible steps moved, %d quests left in log",
    steps, walked, flips, inversions, #questLog))
check(steps >= planned * 3 - 2, "walked through the planned quests (" .. steps .. " steps)")
check(flips <= math.max(2, math.floor(steps / 20)), "the step shown next is the step you get (" .. flips .. " changes)")
check(inversions <= math.max(2, math.floor(steps / 20)), "visible steps keep their order while walking (" .. inversions .. " moved)")

---------------------------------------------------------------------------
-- Map overlay
---------------------------------------------------------------------------
local M = SP.Map
check(#WorldMapFrame.providers == 1, "map overlay registered one data provider")
-- Projection: same map is identity; Mulgore points land inside Kalimdor; Barrens is outside Mulgore.
local mp = D.MakePoint(1412, 0.5, 0.25)
local x, y = M.Project(mp, 1412)
check(x == 0.5 and y == 0.25, "projection onto the same map is unchanged")
x, y = M.Project(mp, 1414)
check(x and math.abs(x - 1500 / 7000) < 1e-9 and math.abs(y - 500 / 4000) < 1e-9, "Mulgore point lands in the right spot on Kalimdor")
check(M.Project(D.MakePoint(1413, 0.5, 0.5), 1412) == nil, "points outside the shown map are dropped")
local wp = D.MakePoint(1500, 0.3, 0.7)
x, y = M.Project(wp, 1500)
check(x == 0.3 and y == 0.7, "projection on a WoW-axis map is unchanged")

-- Draw the Scenario D zone after re-planning from the middle of it.
questLog = {}
player.map, player.x, player.y = 1500, 0.5, 0.5
fire("PLAYER_LEVEL_UP", 20)
SlashCmdList.OLDMANJAVA("unskip")
for i = #completedIds, 1, -1 do if completedIds[i] > 2000 and completedIds[i] < 2100 then table.remove(completedIds, i) end end
for id in pairs(SP.Data.recentTurnIns) do if id > 2000 and id < 2100 then SP.Data.recentTurnIns[id] = nil end end
SlashCmdList.OLDMANJAVA("replan")
flush()
local open = SP.UI.OpenNodes()
local areas = M.BuildAreas(open, 1500)
local objs = 0
for _, n in ipairs(open) do if n.kind == "obj" then objs = objs + 1 end end
check(objs > 0 and #areas == objs, "one shaded area per open objective (" .. #areas .. "/" .. objs .. ")")
local maxBlobs, totalBlobs = 0, 0
for _, a in ipairs(areas) do maxBlobs = math.max(maxBlobs, #a.blobs); totalBlobs = totalBlobs + #a.blobs end
check(maxBlobs <= 40 and totalBlobs <= 420, "blob caps hold (" .. maxBlobs .. " max, " .. totalBlobs .. " total)")
check(areas[1] and areas[1].label and areas[1].color, "areas carry a label position and a colour")
SP.Map.Refresh()
local st = M.Stats()
check(st.blobs == totalBlobs, "every area blob is drawn")
local nearAreas = 0
for _, a in ipairs(areas) do if a.step <= 10 then nearAreas = nearAreas + 1 end end
check(st.labels >= 1 and st.labels <= nearAreas, "labels only for objectives in the next 10 steps (" .. st.labels .. "/" .. nearAreas .. ")")
check(st.steps == math.min(10, #open) and st.markers >= 1 and st.markers <= st.steps and st.lines >= 2,
    "next 10 steps are drawn, grouped into markers, with a route line (" .. st.steps .. " steps, " .. st.markers .. " markers)")
canvasScale = 3
SP.Map.Refresh()
check(M.Stats().steps == st.steps and M.Stats().markers >= st.markers, "zooming in keeps every step; grouped markers may separate")
canvasScale = 1
shownMapID = 1412
SP.Map.Refresh()
st = M.Stats()
check(st.blobs == 0 and st.markers == 0, "a map the route isn't on stays clean")
shownMapID = 1500
SlashCmdList.OLDMANJAVA("map")
st = M.Stats()
check(st.blobs == 0 and st.markers == 0 and SP.db.mapOverlay == false, "/sp map hides the overlay")
SlashCmdList.OLDMANJAVA("map")
check(SP.db.mapOverlay == true and M.Stats().steps > 0, "/sp map brings it back")

-- Crowded markers: placed exactly the way Map.lua places them (box = size + 2, step 26).
do
    local function Place(boxes, x, y, size)
        local box = size + 2
        local px, py = M.PlaceMarker(boxes, x, y, box, box, 26)
        boxes[#boxes + 1] = { x = px, y = py, w = box, h = box }
        return px, py
    end
    -- The big current step, then three steps at one NPC nearby (accept, kill, turn in), then more.
    local boxes = {}
    Place(boxes, 100, -100, 28)
    local maxDrift = 0
    for i = 1, 8 do
        local px, py = Place(boxes, 60, -100, 18)
        maxDrift = math.max(maxDrift, math.sqrt((px - 60) ^ 2 + (py + 100) ^ 2))
    end
    local overlaps = 0
    for i = 1, #boxes do
        for j = i + 1, #boxes do
            local a, b = boxes[i], boxes[j]
            if math.abs(a.x - b.x) * 2 < (a.w + b.w) and math.abs(a.y - b.y) * 2 < (a.h + b.h) then overlaps = overlaps + 1 end
        end
    end
    check(overlaps == 0, "no two markers overlap (" .. overlaps .. " overlapping pairs)")
    check(maxDrift <= 26 * math.sqrt(2) + 0.01, string.format("crowded markers stay within one step of their spot (%.1f px)", maxDrift))
    local fx, fy = M.PlaceMarker({}, 10, -10, 20, 20, 26)
    check(fx == 10 and fy == -10, "an uncrowded marker sits exactly on its spot")
end

-- Steps at one NPC (accept, kill, turn in) become one group marker; the current step stands alone.
do
    local function S(i, x, y) return { index = i, sx = x, sy = y, node = { kind = "pickup" } } end
    local groups = M.GroupSteps({ S(1, 200, -100), S(2, 60, -100), S(3, 66, -96), S(4, 60, -100), S(5, 60, -300), S(6, 61, -301) }, 18)
    check(#groups == 3, "1 | 2-3-4 | 5-6 grouped (" .. #groups .. " groups)")
    check(groups[1].current and #groups[1].steps == 1, "the current step is its own marker")
    check(#groups[2].steps == 3 and groups[2].steps[1].index == 2 and groups[2].steps[3].index == 4, "steps 2-4 share one marker, in order")
    local apart = M.GroupSteps({ S(2, 0, 0), S(3, 100, 0), S(4, 0, 0) }, 18)
    check(#apart == 3, "steps that leave and come back are not merged out of order")
end

---------------------------------------------------------------------------
-- Scenario E: difficulty (level 3, solo)
---------------------------------------------------------------------------
player.level = 3
player.map, player.x, player.y = 1412, 0.45, 0.75
completedIds = { 108 }
for id in pairs(SP.Data.recentTurnIns) do SP.Data.recentTurnIns[id] = nil end
questLog = {
    { questID = 117, title = "Too Hard Already", level = 7, complete = false,
      objectives = { { text = "0/8 Prairie Wolf slain", type = "monster", finished = false, have = 0, need = 8 } } },
    { questID = 119, title = "Hard But Done", level = 7, complete = true, objectives = {} },
}
fire("PLAYER_LEVEL_UP", 3)
SlashCmdList.OLDMANJAVA("difficulty normal")
flush()
inRoute = routeQuests()
printRoute("Scenario E: level 3, normal difficulty")
check(not inRoute[116], "a quest 3 levels above you waits on normal")
check(inRoute[120], "a quest 2 levels above you is fine on normal")
check(not inRoute[118], "a quest whose mobs are far above you waits")
check(not inRoute[117] and SP.Planner.stats.tooHard == 1, "a too-hard quest already in your log is held")
check(inRoute[119], "a finished hard quest still gets its turn-in")
SlashCmdList.OLDMANJAVA("difficulty hard")
flush()
check(routeQuests()[116], "hard difficulty allows a quest 3 levels up")
SlashCmdList.OLDMANJAVA("difficulty easy")
flush()
check(not routeQuests()[120], "easy difficulty holds a quest 2 levels up")
SlashCmdList.OLDMANJAVA("difficulty normal")
flush()

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
-- Class quests toggle: at level 10 the gray level-3 hunter quest is routed only while it's on.
player.level = 10
player.map, player.x, player.y = 1412, 0.45, 0.75
completedIds = { 108 }
questLog = {}
fire("PLAYER_LEVEL_UP", 10)
flush()
check(routeQuests()[111], "class quests on: gray class quest routed")
SP.db.classQuests = false
SP.RequestPlan()
flush()
check(not routeQuests()[111], "class quests off: gray class quest dropped")
SP.db.classQuests = true
SP.RequestPlan()
flush()

-- Map labels toggle.
shownMapID = 1412
SP.db.mapLabels = false
SP.Map.Refresh()
check(M.Stats().labels == 0, "map labels off: no labels drawn")
SP.db.mapLabels = true
SP.Map.Refresh()

-- Open the window and click every control in it once; nothing may error.
local before = #frames
SlashCmdList.OLDMANJAVA("settings")
check(_G.OldmanJavaSettingsFrame ~= nil, "/sp settings opens the settings window")
local clicked, failed = 0, 0
local overlay = SP.db.mapOverlay
for i = before + 1, #frames do
    local onClick = frames[i].scripts.OnClick
    if onClick then
        local ok, err = pcall(onClick, frames[i], "LeftButton")
        clicked = clicked + 1
        if not ok then failed = failed + 1; print("  settings click error: " .. tostring(err)) end
    end
end
flush()
check(clicked >= 12 and failed == 0, "every settings control works (" .. clicked .. " clicked, " .. failed .. " errors)")
check(SP.db.mapOverlay ~= overlay, "clicking the map overlay switch flips it")
SP.Settings.Refresh()
SP.db.mapOverlay, SP.db.difficulty = true, "normal"

---------------------------------------------------------------------------
-- Item counts on the panel and map
---------------------------------------------------------------------------
do
    local CT = SP.UI.CountText
    -- Active objective: live count from the quest log.
    questLog = { { questID = 114, title = "Wolves at the Door", level = 3, complete = false,
        objectives = { { text = "3/8 Prairie Wolf slain", type = "monster", finished = false, have = 3, need = 8 } } } }
    SP.Data.ReadQuestLog()
    local text, done = CT({ kind = "obj", q = 114, gi = 1 })
    check(text == "3/8" and not done, "Up Next shows 3/8 for a quest in your log (" .. tostring(text) .. ")")
    questLog[1].objectives[1].have = 8
    SP.Data.ReadQuestLog()
    text, done = CT({ kind = "obj", q = 114, gi = 1 })
    check(text == "8/8" and done, "a finished objective reads 8/8 and counts as done")
    -- Planned quest: items already in the bags.
    bags[100] = 2
    text = CT({ kind = "obj", q = 100, itemId = 100 })
    check(text == "2 in bags", "a planned item objective shows what you already carry (" .. tostring(text) .. ")")
    bags[100] = nil
    check(CT({ kind = "obj", q = 100, itemId = 100 }) == nil, "nothing shown when you have none yet")
    check(CT({ kind = "pickup", q = 100 }) == nil, "no count on accept or turn-in steps")
    questLog = {}
    SP.Data.ReadQuestLog()
end

---------------------------------------------------------------------------
-- Search steps for objects with a few possible spots
---------------------------------------------------------------------------
do
    local loc = SP.Data.Locations(121)
    local obj = loc and loc.objectives[1]
    check(obj and obj.search and #obj.points == 6, "a crate with 6 possible spots is a search objective")
    -- The route marks the step SEARCH and carries the spots.
    player.level = 3
    player.map, player.x, player.y = 1412, 0.45, 0.75
    completedIds = { 108 }
    questLog = {}
    fire("PLAYER_LEVEL_UP", 3)
    SP.Planner.Forget()
    SP.RequestPlan()
    flush()
    local node
    for _, n in ipairs(SP.Planner.route) do if n.q == 121 and n.kind == "obj" then node = n end end
    check(node and node.search and node.label == "SEARCH" and #node.spots == 6, "the crate step is a SEARCH step with its 6 spots")
    if node then
        local T = SP.UI.SearchTarget
        -- Standing on spot 1 checks it; the target moves to the nearest unchecked spot.
        local at1 = D.MakePoint(1412, 0.52, 0.70)
        T(node, at1)
        check(SP.UI.SearchState().count == 0, "walking past a spot doesn't count as checking it")
        clock = clock + 2
        local target = T(node, at1)
        -- The three spots of the near cluster are all within sight, so all three are checked at once.
        check(SP.UI.SearchState().count == 3, "reaching a cluster checks every spot within sight (" .. SP.UI.SearchState().count .. ")")
        local far = D.MakePoint(1412, 0.49, 0.78)
        check(D.Distance(far, target) < 30, "next target is the other cluster")
        -- Walk every spot: the search starts another lap.
        for _, spot in ipairs(node.spots) do T(node, spot); clock = clock + 2; T(node, spot) end
        local st = SP.UI.SearchState()
        check(st.laps == 1 and st.count < #node.spots, "after every spot is checked, a new lap starts (" .. st.laps .. " laps)")

        -- Fighting at a spot doesn't count as having looked there.
        SP.UI.RestartSearch() -- no-op unless it's the current step; reset directly through a new search
        local far1 = node.spots[4]
        T(node, D.MakePoint(1412, 0.20, 0.20)) -- elsewhere: fresh dwell state
        inCombat = true
        local before = SP.UI.SearchState().count
        T(node, far1); clock = clock + 5; T(node, far1)
        check(SP.UI.SearchState().count == before, "standing at a spot while fighting doesn't check it")
        inCombat = false

        -- Hovering the crate locks the search onto it, even after running away.
        player.map, player.x, player.y = 1412, 0.491, 0.781
        SP.UI.ObjectSeen("Supply Crate", node)
        local fled = D.MakePoint(1412, 0.60, 0.60)
        local lockedOn = T(node, fled)
        check(SP.UI.SearchState().found ~= nil and D.Distance(lockedOn, D.MakePoint(1412, 0.49, 0.78)) < 30,
            "after hovering the crate, the arrow stays on it even when you run off")
        SP.UI.ObjectSeen("Some Other Thing", node)
        check(SP.UI.SearchState().found ~= nil, "hovering an unrelated object changes nothing")
        check(tooltipCallbacks[Enum.TooltipDataType.Object] ~= nil, "the object tooltip hook is registered")
    end
end

---------------------------------------------------------------------------
-- Hunting roaming mobs, and drop sources above the difficulty cap
---------------------------------------------------------------------------
do
    player.level = 3
    SP.Data.level = 3
    SP.db.difficulty = "normal"
    SP.Data.ClearLocationCache()
    local loc = SP.Data.Locations(100)
    local hasOrnery = false
    for _, pt in ipairs(loc.objectives[1].points) do
        if pt.x < 0.35 and pt.y < 0.35 then hasOrnery = true end
    end
    check(not hasOrnery, "level 16 droppers are not farm targets at level 3")
    SP.db.difficulty = "hard"
    SP.Data.level = 12
    SP.Data.ClearLocationCache()
    hasOrnery = false
    for _, pt in ipairs(SP.Data.Locations(100).objectives[1].points) do
        if pt.x < 0.35 and pt.y < 0.35 then hasOrnery = true end
    end
    check(hasOrnery, "the same droppers count once they're within your cap")
    SP.db.difficulty = "normal"
    SP.Data.level = 3
    SP.Data.ClearLocationCache()

    -- Hunt steps: nearest spawn when you're near any, the planned spot when you're far away.
    local spots = { D.MakePoint(1412, 0.50, 0.80), D.MakePoint(1412, 0.52, 0.81), D.MakePoint(1412, 0.60, 0.60) }
    local node = { kind = "obj", q = 999, key = "o1", title = "Test Mob", hunt = true, spots = spots, pt = spots[3] }
    clock = clock + 1
    local t = SP.UI.HuntTarget(node, D.MakePoint(1412, 0.515, 0.805))
    check(t == spots[2] or t == spots[1], "a hunt step points at the nearest spawn when you're close")
    clock = clock + 1
    t = SP.UI.HuntTarget(node, D.MakePoint(1412, 0.10, 0.10))
    check(t == node.pt, "far from every spawn, it points at the planned spot")

    -- Sweep: after passing a spawn spot, the arrow moves on; swept spots come back after 2 minutes.
    local spots2 = { D.MakePoint(1412, 0.50, 0.50), D.MakePoint(1412, 0.53, 0.50), D.MakePoint(1412, 0.56, 0.50) }
    local node2 = { kind = "obj", q = 998, key = "o1", title = "Sweep Mob", hunt = true, spots = spots2, pt = spots2[2] }
    clock = clock + 1
    local first = SP.UI.HuntTarget(node2, spots2[1])
    check(first == spots2[2], "standing on a spawn spot sweeps it and points at the next one")
    clock = clock + 1
    local second = SP.UI.HuntTarget(node2, spots2[2])
    check(second == spots2[3], "the sweep keeps moving to spots you haven't seen")
    clock = clock + 200
    local back = SP.UI.HuntTarget(node2, D.MakePoint(1412, 0.48, 0.50)) -- 60 yd west of spot 1
    check(back == spots2[1], "after a couple of minutes, swept spots count again (mobs respawn)")

    -- Drop sources are named for the panel.
    local src = SP.Data.Locations(100).objectives[1].sources
    check(src and src[1] == "Plainstrider" and #src == 1, "item drops list the mobs they come from (within your cap)")
end

-- ETA to the current step.
do
    local F = SP.Style.FormatETA
    check(F(39.4) == "39s" and F(65) == "1m 05s" and F(3720) == "1h 02m", "ETA formats as 39s / 1m 05s / 1h 02m")
    player.mounted = false
    check(SP.UI.TravelSpeed() == 7, "on foot and standing still, ETA uses run speed (7 yd/s)")
    player.mounted = true
    check(SP.UI.TravelSpeed() >= 14, "mounted, ETA uses mount speed")
    player.mounted = false
end

-- Mob XP at the mobs' real level (Classic formula).
do
    local saved = SP.Data.level
    SP.Data.level = 12
    local X = SP.Data.MobXP
    local function near(a, b) return math.abs(a - b) < 0.01 end
    check(X() == 105 and X(12) == 105, "a same-level kill at 12 is worth 105 XP")
    check(SP.Data.GrayLevel(12) == 6 and X(6) == 0 and X(5) == 0, "gray mobs (6 and below at 12) give no XP")
    check(near(X(7), 39.375), "a level 7 mob at 12 gives 39 XP")
    check(near(X(14), 115.5) and near(X(20), 126), "higher mobs give +5% a level, capped at +4")
    SP.Data.level = 60
    check(SP.Data.GrayLevel(60) == 48 and X(48) == 0 and X(49) > 0, "at 60, level 48 mobs are gray")
    SP.Data.level = 3
    check(SP.Data.GrayLevel(3) == 0 and X(1) > 0, "nothing is gray below level 6")
    SP.Data.level = saved
end

-- Quests whose mobs are gray are worth less, but a zone of them still gets a route.
do
    for k = 1, 30 do N[3000 + k].minLevel, N[3000 + k].maxLevel = 1, 1 end
    local savedLog, savedDone = questLog, completedIds
    questLog, completedIds = {}, { 108 }
    player.level = 20
    player.map, player.x, player.y = 1500, 0.5, 0.5
    fire("PLAYER_LEVEL_UP", 20)
    SlashCmdList.OLDMANJAVA("replan")
    flush()
    local quests, travel = 0, false
    for _, n in ipairs(SP.Planner.route) do
        if n.kind == "pickup" then quests = quests + 1 end
        if n.kind == "travel" then travel = true end
    end
    check(quests > 0 and not travel, "a zone of gray-mob quests still gets a route, not an empty panel (" .. quests .. ")")
    check(SP.Planner.stats.value < SP.Planner.stats.xp + 1, "gray mobs add no kill XP to the plan's value")
    for k = 1, 30 do N[3000 + k].minLevel, N[3000 + k].maxLevel = 19, 20 end
    questLog, completedIds = savedLog, savedDone
end

-- Full log: nothing new can be added, so no fallback and no hub search; bad quests stay deferred.
do
    for k = 1, 30 do N[3000 + k].minLevel, N[3000 + k].maxLevel = 1, 1 end
    local savedLog, savedMax = questLog, C_QuestLog.GetMaxNumQuestsCanAccept
    questLog = {
        { questID = 2001, title = Q[2001].name, level = 20, complete = false,
          objectives = { { text = "0/8 " .. N[3001].name .. " slain", type = "monster", finished = false, have = 0, need = 8 } } },
        { questID = 107, title = "Far Away", level = 3, complete = false,
          objectives = { { text = "0/8 Zhevra Runner slain", type = "monster", finished = false, have = 0, need = 8 } } },
    }
    C_QuestLog.GetMaxNumQuestsCanAccept = function() return 2 end
    local hubCalls, realHub = 0, SP.Planner.BestHub
    SP.Planner.BestHub = function(...) hubCalls = hubCalls + 1; return realHub(...) end
    player.level = 20
    player.map, player.x, player.y = 1500, 0.5, 0.5
    fire("QUEST_LOG_UPDATE")
    SlashCmdList.OLDMANJAVA("replan")
    flush()
    local far, pickups = false, 0
    for _, n in ipairs(SP.Planner.route) do
        if n.q == 107 then far = true end
        if n.kind == "pickup" then pickups = pickups + 1 end
    end
    local deferred = false
    for _, q in ipairs(SP.Planner.deferred) do if q == 107 then deferred = true end end
    check(not far and deferred, "with a full log, a far gray-mob quest stays held, not forced into the route")
    check(pickups == 0 and hubCalls == 0, "with a full log there's no hub search and nothing new to pick up")
    SP.Planner.BestHub = realHub
    C_QuestLog.GetMaxNumQuestsCanAccept = savedMax
    questLog = savedLog
    for k = 1, 30 do N[3000 + k].minLevel, N[3000 + k].maxLevel = 19, 20 end
end

-- Drop objectives with mixed-level droppers: kill XP is weighted by spawns, not set by the weakest mob.
do
    local savedLevel = SP.Data.level
    SP.Data.level = 12
    SP.db.difficulty = "hard"
    SP.Data.ClearLocationCache()
    local obj = SP.Data.Locations(100).objectives[1]
    -- 12 gray Plainstriders (0 XP) and 20 Ornery Plainstriders at 16-17 (126 XP each).
    check(math.abs((obj.killXP or -1) - 20 * 126 / 32) < 0.01, "mixed droppers average their kill XP (" .. tostring(obj.killXP) .. ")")
    SP.db.difficulty = "normal"
    SP.Data.ClearLocationCache()
    obj = SP.Data.Locations(100).objectives[1]
    check(obj.killXP == 0, "only gray droppers within your cap: no kill XP")
    SP.Data.level = savedLevel
    SP.Data.ClearLocationCache()
end

-- Escorts and scripted events take minutes, and an escort in the log isn't ready to turn in.
do
    local E = SP.Data.IsEscortText
    check(E("Escort Pal'juh out of Kolkar Crag.") and E("Help Pal'juh escape Kolkar Crag") and not E("Explore the Fargodeep Mine"),
        "escort wording is recognised, exploring isn't")
    SP.Data.ClearLocationCache()
    local ev = SP.Data.Locations(4101).objectives[1]
    check(ev and ev.kind == "event" and ev.scripted and ev.name == "Escort Test Prisoner to the gate",
        "a flagged escort with no objectives gets an escort step (" .. tostring(ev and ev.name) .. ")")
    check(SP.Data.Locations(4102).objectives[1].scripted and not SP.Data.Locations(4103).objectives[1].scripted,
        "an escort trigger is scripted, an explore trigger is not")

    local savedLog, savedDone = questLog, completedIds
    questLog, completedIds = {}, { 108 }
    player.level = 30
    player.map, player.x, player.y = 1413, 0.59, 0.59
    fire("PLAYER_LEVEL_UP", 30)
    SlashCmdList.OLDMANJAVA("replan")
    flush()
    local byQuest = {}
    for _, n in ipairs(SP.Planner.route) do
        if n.kind == "obj" then byQuest[n.q] = n end
    end
    local a, b, c = byQuest[4101], byQuest[4102], byQuest[4103]
    check(a and a.label == "ESCORT" and a.work >= 200 and a.text == "Escort Test Prisoner to the gate",
        "the planner counts minutes for a flagged escort (" .. tostring(a and a.work) .. "s)")
    check(b and b.label == "ESCORT" and b.work >= 200, "the planner counts minutes for an escort trigger")
    check(c and c.label == "EXPLORE" and c.work < 30, "an explore trigger stays a quick stop")
    local pickup, turnin
    for _, n in ipairs(SP.Planner.route) do
        if n.q == 4104 and n.kind == "pickup" then pickup = n end
        if n.q == 4104 and n.kind == "turnin" then turnin = n end
    end
    check(pickup ~= nil, "a quest with a required source item is offered without the item in the bags")
    check(pickup and pickup.sub and pickup.sub:find("bring Test Carcass", 1, true)
        and turnin and turnin.sub and turnin.sub:find("bring Test Carcass", 1, true),
        "its pickup and turn-in say what to bring (" .. tostring(pickup and pickup.sub) .. ")")

    -- In the log with no objective lines and not complete: escort first, then the turn-in.
    questLog = {
        { questID = 4101, title = "Rescue Test", level = 30, complete = false, objectives = {} },
        { questID = 4102, title = "Lost Test", level = 30, complete = false,
          objectives = { { text = "Escort Test Prisoner out of the crag", type = "event", finished = false, have = 0, need = 1 } } },
    }
    fire("QUEST_LOG_UPDATE")
    SlashCmdList.OLDMANJAVA("replan")
    flush()
    local escortAt, turninAt, matchedWork
    for i, n in ipairs(SP.Planner.route) do
        if n.q == 4101 and n.kind == "obj" then escortAt = i end
        if n.q == 4101 and n.kind == "turnin" then turninAt = i end
        if n.q == 4102 and n.kind == "obj" then matchedWork = n.work end
    end
    check(escortAt and turninAt and escortAt < turninAt, "an unfinished escort in the log is done before its turn-in")
    check(matchedWork and matchedWork >= 200, "the game's escort line matches the trigger despite its trailing period")

    questLog, completedIds = savedLog, savedDone
    player.level = 3
    player.map, player.x, player.y = 1412, 0.44, 0.76
    fire("PLAYER_LEVEL_UP", 3)
end

-- Patrols: an NPC with a few spawn points that walks a path can be anywhere along it.
do
    local D = SP.Data
    local savedLog, savedDone = questLog, completedIds
    questLog, completedIds = {}, { 108 }
    player.level = 40
    local function at(x, y) player.map, player.x, player.y = 1413, x, y end
    local function replan()
        fire("PLAYER_LEVEL_UP", 40)
        SlashCmdList.OLDMANJAVA("replan")
        flush()
        clock = clock + 2
    end
    local function run(seconds, step)
        for i = 1, math.floor(seconds / 0.05) do
            clock = clock + 0.05
            if step then step(i) end
            SP.UI.UpdateArrow()
        end
    end
    local function find(q, kind)
        for _, n in ipairs(SP.Planner.route) do if n.q == q and n.kind == kind then return n end end
    end
    at(0.30, 0.31)
    replan()

    -- The data: spawn points stay what the route is planned from; the path is extra places to look.
    local kill = D.Locations(4311).objectives[1]
    check(#kill.points == 1 and kill.spot == kill.points[1] and kill.density == 1,
        "a patrolling mob is still planned from its one spawn point")
    check(kill.sweep and #kill.sweep == 4 and kill.sweep[1] == kill.points[1] and kill.patrols == true,
        "its path is swept too, without the points its spawn or an earlier point covers (" .. tostring(kill.sweep and #kill.sweep) .. ")")
    local mixed = D.Locations(4312).objectives[1]
    check(#mixed.points == 7 and mixed.sweep and #mixed.sweep == 10 and not mixed.patrols,
        "a drop from a patroller and a camp sweeps his path; mobs with many spawns don't add theirs ("
        .. #mixed.points .. ", " .. tostring(mixed.sweep and #mixed.sweep) .. ")")
    local odd = D.Locations(4313).objectives[1]
    check(odd and #odd.points == 1 and odd.sweep == nil and not odd.patrols, "path data in an unknown shape is ignored")
    local twin = D.Locations(4314).objectives[1]
    check(#twin.points == 2 and twin.sweep and #twin.sweep == 5 and twin.patrols == true
        and twin.points[1].patrol == twin.points[2].patrol,
        "an NPC with two spawn points and a path: both spawns and the path, once (" .. tostring(twin.sweep and #twin.sweep) .. ")")
    check(D.Locations(4104).objectives[1].sweep == nil, "mobs that don't patrol have nothing extra to sweep")

    -- The route: quest givers and turn-ins are looked for along their path but stay fixed steps.
    local pickup, hunt, turnin = find(4311, "pickup"), find(4311, "obj"), find(4311, "turnin")
    check(pickup and pickup.patrol and not pickup.hunt and #pickup.spots == 4 and pickup.spots[1] == pickup.pt,
        "a quest giver who walks a road is looked for along it")
    check(turnin and turnin.patrol and not turnin.hunt and #turnin.spots == 4, "and so is the NPC a quest is turned in to")
    check(hunt and hunt.hunt and hunt.patrol and hunt.spots == kill.sweep and hunt.pt == kill.points[1],
        "the kill step sweeps the mob's path and still starts from its spawn point")

    if hunt then
        local T, line = SP.UI.HuntTarget, SP.UI.PatrolLine
        local s = hunt.spots
        clock = clock + 1
        check(T(hunt, s[1]) == s[2], "on the empty spawn point, the arrow moves on along the path")
        check(line(hunt, "Patrol Kill") == "Patrol Kill  ·  patrols" and line(hunt, nil) == "patrols", "the panel says the mob patrols")
        clock = clock + 1
        check(T(hunt, s[2]) == s[3], "and keeps following it")
        clock = clock + 1
        T(hunt, s[3])
        clock = clock + 1
        local _, changed = T(hunt, s[4])
        check(not changed and line(hunt, nil) == "patrols", "reaching the last spot says nothing yet: the mob may be right there")
        -- Fighting at the end of the path (that's the mob): the wait starts when the fight ends.
        inCombat = true
        clock = clock + 30
        _, changed = T(hunt, s[4])
        inCombat = false
        check(not changed and line(hunt, nil) == "patrols", "a fight at the end of the path doesn't count as waiting")
        clock = clock + 10
        _, changed = T(hunt, s[4])
        check(not changed, "ten seconds after the fight is still too soon")
        clock = clock + 6
        _, changed = T(hunt, s[4])
        check(changed and line(hunt, "Patrol Kill") == "Patrol Kill  ·  path checked, it'll be back",
            "a while after the whole path with the step not done, the panel says so and keeps its line")
        clock = clock + 300
        _, changed = T(hunt, s[4])
        check(not changed and line(hunt, nil) == "path checked, it'll be back", "and goes on saying so while you wait there")
        clock = clock + 1
        _, changed = T(hunt, D.MakePoint(1413, 0.60, 0.60))
        check(changed and line(hunt, nil) == "patrols", "leaving the area starts a fresh look")
    end

    if turnin then
        -- A path that takes longer to walk than swept spots take to come back still gets its line.
        local T, line = SP.UI.HuntTarget, SP.UI.PatrolLine
        for i = 1, 4 do clock = clock + 130; T(turnin, turnin.spots[i]) end
        clock = clock + 16
        local _, changed = T(turnin, turnin.spots[4])
        check(changed and line(turnin, "to Road Walker") == "to Road Walker  ·  path checked, it'll be back",
            "a long path is checked once every spot has been reached, however long that took")
    end

    -- In the log: the kill step and the turn-in of an accepted quest patrol too.
    questLog = { { questID = 4311, title = "Patrol Kill", level = 40, complete = false,
        objectives = { { text = "0/1 Patrol Captain slain", type = "monster", finished = false, have = 0, need = 1 } } } }
    completedIds = { 108, 4312, 4313, 4314 }
    fire("QUEST_LOG_UPDATE")
    at(0.20, 0.21)
    replan()
    local activeHunt, activeTurnin = find(4311, "obj"), find(4311, "turnin")
    check(activeHunt and activeHunt.hunt and activeHunt.patrol and #activeHunt.spots == 4, "an accepted quest's kill step sweeps the path")
    check(activeTurnin and activeTurnin.patrol and not activeTurnin.hunt, "an accepted quest's turn-in looks along the path")
    -- Walking the path through the real arrow update: the panel re-renders when the line changes.
    local current = SP.UI.CurrentNode()
    check(current == activeHunt, "the kill step is the current step (" .. tostring(current and current.text) .. ")")
    if current == activeHunt then
        for i = 1, 4 do
            at(current.spots[i].x, current.spots[i].y)
            run(2)
        end
        check(SP.UI.PatrolLine(current, nil) == "patrols", "at the end of the path, the panel waits before saying it's empty")
        run(16)
        check(SP.UI.PatrolLine(current, nil) == "path checked, it'll be back", "the arrow update flips the line by itself")
    end

    -- Blocked on the way to a patrolling quest giver: the step moves later, like any fixed step,
    -- and the panel doesn't claim the path was checked.
    questLog, completedIds = {}, { 108 }
    fire("QUEST_LOG_UPDATE")
    SP.Planner.blocked = {}
    at(0.30, 0.3375) -- 150 yards south of the giver's spawn point
    replan()
    local first = SP.UI.CurrentNode()
    check(first and first.kind == "pickup" and first.patrol, "blocked patrol test starts on the patrolling giver (" .. tostring(first and first.text) .. ")")
    if first and first.patrol then
        run(22, function(i) at(0.30 + (i % 2 == 0 and 0.0003 or 0), 0.3375) end)
        flush()
        check(SP.Planner.IsBlocked(first), "moving 20s without getting closer to a patrolling giver moves that step later")
        check(SP.UI.PatrolLine(first, nil) == "patrols", "and the panel doesn't say its path was checked")
    end

    SP.Planner.blocked = {}
    questLog, completedIds = savedLog, savedDone
    player.level = 3
    player.map, player.x, player.y = 1412, 0.44, 0.76
    fire("PLAYER_LEVEL_UP", 3)
    fire("QUEST_LOG_UPDATE")
end

-- Blocked paths: moving without getting closer moves the step later; real progress never does.
do
    local D = SP.Data
    local savedLog, savedDone = questLog, completedIds
    questLog, completedIds = {}, { 108 }
    player.level, player.mounted = 3, false
    SP.Planner.blocked = {}
    local savedBags = bags[5000]
    bags[5000] = nil -- no item-started quest (it has no arrow to follow)
    local function at(x, y) player.map, player.x, player.y = 1412, x, y end
    local function replanAt(x, y)
        at(x, y)
        fire("PLAYER_LEVEL_UP", 3)
        SlashCmdList.OLDMANJAVA("replan")
        flush()
        clock = clock + 2 -- a gap the detector ignores
        return SP.UI.CurrentNode()
    end
    -- Runs the arrow for `seconds`, moving the character by step(i) each tick.
    local function run(seconds, step)
        for i = 1, math.floor(seconds / 0.05) do
            clock = clock + 0.05
            if step then step(i) end
            SP.UI.UpdateArrow()
        end
    end
    local function jitter(x, y) return function(i) at(x + (i % 2 == 0 and 0.0003 or 0), y) end end
    local function towards(node, sign)
        return function()
            local dx, dy = (node.pt.x - player.x) * 3000, (node.pt.y - player.y) * 2000
            local len = math.sqrt(dx * dx + dy * dy)
            at(player.x + sign * dx / len * 0.35 / 3000, player.y + sign * dy / len * 0.35 / 2000)
        end
    end

    -- Running along a cliff at the same distance: blocked, another quest's step comes first.
    local first = replanAt(0.20, 0.40)
    check(first and first.kind ~= "travel" and not first.hunt and not first.search and not first.inBags, "blocked test starts on a fixed step (" .. tostring(first and first.text) .. ")")
    run(22, jitter(0.20, 0.40))
    flush()
    local now = SP.UI.CurrentNode()
    check(SP.Planner.IsBlocked(first) and now and now.q ~= first.q, "moving 20s without getting closer puts another quest's step first (" .. tostring(now and now.text) .. ")")
    check(SP.Planner.IsValid(SP.Planner.route), "the reordered route is still legal")
    -- Found the way round: reaching the blocked step clears it.
    at(first.pt.x + 0.005, first.pt.y)
    SP.UI.UpdateArrow()
    check(not SP.Planner.IsBlocked(first), "reaching a blocked step clears the block")
    flush()

    -- Progress, errands, standing still and fighting never count as blocked.
    SP.Planner.blocked = {}
    first = replanAt(0.20, 0.40)
    run(22, towards(first, 1))
    check(not SP.Planner.IsBlocked(first), "walking toward the step is never blocked")
    first = replanAt(0.20, 0.40)
    run(22, towards(first, -1))
    check(not SP.Planner.IsBlocked(first), "walking steadily away (an errand) is not blocked")
    first = replanAt(0.20, 0.40)
    run(30)
    check(not SP.Planner.IsBlocked(first), "standing still is not blocked")
    first = replanAt(0.20, 0.40)
    inCombat = true
    run(30, jitter(0.20, 0.40))
    inCombat = false
    check(not SP.Planner.IsBlocked(first), "fighting is not blocked")
    -- Town errands: short walks at about the same distance, with stops in between, for two minutes.
    first = replanAt(0.20, 0.40)
    for _ = 1, 10 do
        run(4, jitter(0.20, 0.40))
        run(8)
    end
    check(not SP.Planner.IsBlocked(first), "short walks with stops (errands) don't add up to a block")
    -- A manual replan starts without blocks.
    SP.Planner.MarkBlocked(first, D.PlayerPoint())
    SlashCmdList.OLDMANJAVA("replan")
    flush()
    check(not SP.Planner.IsBlocked(first), "/java replan clears blocks")

    -- Escorts: the NPC sets the path and the pace, so they're never watched.
    local escort = { kind = "obj", q = 4102, key = "o1", title = "Escort Test Prisoner out of the crag", scripted = true,
        pt = D.MakePoint(1412, 0.40, 0.40) }
    SP.Planner.route = { escort }
    SP.UI.Render()
    clock = clock + 2
    run(30, jitter(0.20, 0.40))
    check(not SP.Planner.IsBlocked(escort), "an escort step is never marked blocked")

    -- Hunts: an unreachable spawn spot and its neighbours are skipped; the arrow tries the next.
    local A1, A2, B = D.MakePoint(1412, 0.60, 0.30), D.MakePoint(1412, 0.605, 0.30), D.MakePoint(1412, 0.60, 0.40)
    local ridge = { kind = "obj", q = 997, key = "o1", title = "Ridge Mob", hunt = true, spots = { A1, A2, B }, pt = A1 }
    SP.Planner.route = { ridge }
    at(0.60, 0.265)
    SP.UI.Render()
    clock = clock + 2
    run(1)
    check(SP.UI.HuntTarget(ridge, D.PlayerPoint()) == A1, "the hunt starts on the nearest spawn spot")
    run(22, jitter(0.60, 0.265))
    clock = clock + 1
    check(SP.UI.HuntTarget(ridge, D.PlayerPoint()) == B, "an unreachable spawn spot and its neighbours are skipped")

    SP.Planner.blocked = {}
    questLog, completedIds = savedLog, savedDone
    bags[5000] = savedBags
    replanAt(0.44, 0.76)
end

if os.getenv("TIME_SLICES") then
    print(string.format("slices: %d, longest %.1f ms, over 16 ms: %d", sliceCount, sliceMax, sliceOver))
end
print(string.format("\n%d passed, %d failed", passes, failures))
os.exit(failures == 0 and 0 or 1)
