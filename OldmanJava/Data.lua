-- Oldman Java data layer: reads quest facts from QuestieDB (LibQuestieDB) and the
-- character's live state from the game client. No quest data is hardcoded here.
local _, SP = ...

local Data = {}
SP.Data = Data

local floor, huge = math.floor, math.huge
local pairs, ipairs, type, pcall = pairs, ipairs, type, pcall

local QuestDB, NpcDB, ObjectDB, ItemDB

local areaToUiMap = {}     -- AreaId -> UiMapID (0 = suppressed)
local dungeonAreas = {}    -- AreaId -> true for instance areas
local xpDB = {}            -- questId -> { level, baseXP }
local medianXP = {}        -- quest level -> median base XP (for quests without XP data)
local mapBasis = {}        -- UiMapID -> affine map->world transform, or false
local questInfo = {}       -- questId -> static info (built once per session)
local locCache = {}        -- questId -> resolved locations (built lazily)

Data.completed = {}        -- questId -> true, every quest this character has ever turned in
Data.completedCount = 0
Data.recentTurnIns = {}    -- turn-ins this session that the server list may not show yet
Data.log = {}              -- questId -> log entry
Data.logCount = 0
Data.indexReady = false

-- Masks can exceed 32 bits (Skyborne races use bits 32/33), so never use bit.band here.
local function HasBit(mask, bitValue)
    return floor(mask / bitValue) % 2 == 1
end
Data.HasBit = HasBit

local function LoadLuaTable(src)
    if type(src) == "table" then return src end
    if type(src) ~= "string" then return nil end
    local fn = loadstring(src)
    if not fn then return nil end
    setfenv(fn, {})
    local ok, result = pcall(fn)
    if ok and type(result) == "table" then return result end
    return nil
end

local function BuildMedianXP()
    local buckets = {}
    for _, row in pairs(xpDB) do
        local level, xp = row[1], row[2]
        if type(level) == "number" and level > 0 and type(xp) == "number" and xp > 0 then
            local b = buckets[level]
            if not b then b = {}; buckets[level] = b end
            b[#b + 1] = xp
        end
    end
    for level, b in pairs(buckets) do
        table.sort(b)
        medianXP[level] = b[floor((#b + 1) / 2)]
    end
end

local function MedianXP(level)
    if medianXP[level] then return medianXP[level] end
    for d = 1, 10 do
        if medianXP[level - d] then return medianXP[level - d] end
        if medianXP[level + d] then return medianXP[level + d] end
    end
    return 100
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------

function Data.Init()
    if type(LibQuestieDB) ~= "table" then
        return false, "QuestieDB is not installed or not enabled. Oldman Java needs it for quest data."
    end
    if type(LibQuestieDB.RequireContract) == "function" then
        local ok, msg = LibQuestieDB.RequireContract(4)
        if not ok then
            return false, msg or "Your QuestieDB is too old for Oldman Java. Update QuestieDB."
        end
    end
    QuestDB, NpcDB = LibQuestieDB.Quest, LibQuestieDB.Npc
    ObjectDB, ItemDB = LibQuestieDB.Object, LibQuestieDB.Item

    local zone = LibQuestieDB.Support and LibQuestieDB.Support.Get("ZoneDB")
    local priv = type(zone) == "table" and zone.private
    if type(priv) == "table" then
        local base = LoadLuaTable(priv.areaIdToUiMapId) or {}
        local override = LoadLuaTable(priv.areaIdToUiMapIdOverride) or {}
        for k, v in pairs(base) do areaToUiMap[k] = v end
        for k, v in pairs(override) do areaToUiMap[k] = v end
        if type(priv.dungeons) == "table" then
            for areaId, entry in pairs(priv.dungeons) do
                dungeonAreas[areaId] = true
                if type(entry) == "table" and type(entry[2]) == "table" then
                    for _, alt in ipairs(entry[2]) do dungeonAreas[alt] = true end
                end
            end
        end
    end

    local xpSupport = LibQuestieDB.Support and LibQuestieDB.Support.Get("QuestXP")
    xpDB = (type(xpSupport) == "table" and type(xpSupport.db) == "table") and xpSupport.db or {}
    BuildMedianXP()

    Data.RefreshPlayer()
    return true
end

function Data.RefreshPlayer()
    local _, _, raceID = UnitRace("player")
    local _, classToken = UnitClass("player")
    local enum = LibQuestieDB.Enum or {}
    Data.raceBit = enum.raceMaskById and enum.raceMaskById[raceID] or nil
    Data.classBit = enum.classKeys and enum.classKeys[classToken] or nil
    Data.faction = UnitFactionGroup("player")
    Data.level = UnitLevel("player") or 1
    Data.maxLevel = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
end

---------------------------------------------------------------------------
-- Optional Questie integration: its IsDoable() knows about quests that are
-- in the database but not actually in the game (blacklist), holiday rules, etc.
---------------------------------------------------------------------------

local questieDoable
local questieBroken = false

function Data.HookQuestie()
    if questieDoable then return true end
    if type(QuestieLoader) ~= "table" or type(Questie) ~= "table" then return false end
    if not (Questie.API and Questie.API.isReady) then return false end
    local ok, QDB = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
    if ok and type(QDB) == "table" and type(QDB.IsDoable) == "function" then
        questieDoable = QDB.IsDoable
        return true
    end
    return false
end

function Data.HasQuestie()
    return questieDoable ~= nil and not questieBroken
end

-- True only when Questie explicitly says the quest is not doable.
local function QuestieRejects(questId)
    if not questieDoable or questieBroken then return false end
    local ok, result = pcall(questieDoable, questId)
    if not ok then
        questieBroken = true -- an API change in Questie; fall back for the rest of the session
        return false
    end
    return result == false
end

---------------------------------------------------------------------------
-- XP
---------------------------------------------------------------------------

-- Adjusts base quest XP for the level difference (formula from Questie's QuestieXP.lua, via cmangos).
local function AdjustXP(xp, questLevel, playerLevel)
    local mult = 2 * (questLevel - playerLevel) + 20
    if mult < 1 then mult = 1 elseif mult > 10 then mult = 10 end
    xp = xp * mult / 10
    if xp <= 100 then
        xp = 5 * floor((xp + 2) / 5)
    elseif xp <= 500 then
        xp = 10 * floor((xp + 5) / 10)
    elseif xp <= 1000 then
        xp = 25 * floor((xp + 12) / 25)
    else
        xp = 50 * floor((xp + 25) / 50)
    end
    return xp
end

-- Returns adjusted XP and whether it was estimated (no XP data for this quest).
function Data.QuestXP(questId, questLevel)
    local level = Data.level
    if level >= Data.maxLevel then return 0, false end
    local row = xpDB[questId]
    if row and row[1] and row[1] > 0 and row[2] and row[2] > 0 then
        return AdjustXP(row[2], row[1], level), false
    end
    local qLevel = (questLevel and questLevel > 0) and questLevel or level
    return AdjustXP(MedianXP(qLevel), qLevel, level), true
end

-- XP for killing a same-level mob in Classic rules: 45 + 5 * level.
-- Classic mob XP at the character's level ("zero difference" table and gray cutoff).
local function ZeroDifference(level)
    if level <= 7 then return 5 elseif level <= 9 then return 6 elseif level <= 11 then return 7
    elseif level <= 15 then return 8 elseif level <= 19 then return 9 elseif level <= 29 then return 11
    elseif level <= 39 then return 12 elseif level <= 44 then return 13 elseif level <= 49 then return 14
    elseif level <= 54 then return 15 elseif level <= 59 then return 16 end
    return 17
end

-- Highest mob level that gives no XP at all ("gray").
function Data.GrayLevel(level)
    level = level or Data.level
    if level <= 5 then return 0 end
    if level <= 39 then return level - math.floor(level / 10) - 5 end
    if level <= 59 then return level - math.floor(level / 5) - 1 end
    return 48
end

-- XP for one kill of a mob of mobLevel (default: same level as the character). Gray mobs give 0.
function Data.MobXP(mobLevel)
    local level = Data.level
    mobLevel = (mobLevel and mobLevel > 0) and mobLevel or level
    local base = 45 + 5 * level
    if mobLevel >= level then return base * (1 + 0.05 * math.min(mobLevel - level, 4)) end
    if mobLevel <= Data.GrayLevel(level) then return 0 end
    return base * (1 - (level - mobLevel) / ZeroDifference(level))
end

-- How many levels above the character a quest may be. Solo players in quest gear want "normal".
local DIFFICULTY = { easy = 1, normal = 2, hard = 4 }
function Data.MaxAbove()
    return DIFFICULTY[SP.db and SP.db.difficulty or "normal"] or 2
end
Data.DIFFICULTY = DIFFICULTY

-- Highest mob level a route may send the character to fight (one above the quest cap).
function Data.MaxMobLevel()
    return Data.level + Data.MaxAbove() + 1
end

function Data.IsTrivial(questLevel)
    if not questLevel or questLevel <= 0 then return false end
    local diff = questLevel - Data.level
    if diff >= -2 then return false end
    local range
    if C_QuestLog and C_QuestLog.GetTrivialRange then
        range = C_QuestLog.GetTrivialRange()
    elseif GetQuestGreenRange then
        range = GetQuestGreenRange("player")
    end
    return -diff > (range or 5)
end

---------------------------------------------------------------------------
-- Coordinates
---------------------------------------------------------------------------

local function Vec(x, y)
    if CreateVector2D then return CreateVector2D(x, y) end
    return { x = x, y = y }
end
Data.Vec = Vec

local function WorldPos(uiMap, x, y)
    local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, uiMap, Vec(x, y))
    if ok and cont and pos then return cont, pos.x, pos.y end
    return nil
end

-- Map rectangles are axis-aligned in world space, so three corners give an exact transform.
local function GetBasis(uiMap)
    local basis = mapBasis[uiMap]
    if basis ~= nil then return basis end
    basis = false
    if C_Map and C_Map.GetWorldPosFromMapPos then
        local c0, x0, y0 = WorldPos(uiMap, 0, 0)
        local c1, x1, y1 = WorldPos(uiMap, 1, 0)
        local c2, x2, y2 = WorldPos(uiMap, 0, 1)
        if c0 and c1 and c2 and not (x0 == x1 and y0 == y1) then
            basis = { c0, x0, y0, x1 - x0, y1 - y0, x2 - x0, y2 - y0 }
        end
    end
    mapBasis[uiMap] = basis
    return basis
end

-- x, y are 0-1 map fractions. Returns continentID, worldX, worldY (yards).
function Data.ToWorld(uiMap, x, y)
    local b = GetBasis(uiMap)
    if not b then return nil end
    return b[1], b[2] + x * b[4] + y * b[6], b[3] + x * b[5] + y * b[7]
end

-- Width and height of a map in yards (nil if the client can't place it in the world).
function Data.MapSizeYards(uiMap)
    local b = uiMap and GetBasis(uiMap)
    if not b then return nil end
    return (b[4] * b[4] + b[5] * b[5]) ^ 0.5, (b[6] * b[6] + b[7] * b[7]) ^ 0.5
end

function Data.MakePoint(uiMap, x, y)
    local c, wx, wy = Data.ToWorld(uiMap, x, y)
    if not c then return nil end
    return { map = uiMap, x = x, y = y, c = c, wx = wx, wy = wy }
end

local function PlayerMapPosition()
    local uiMap = C_Map.GetBestMapForUnit("player")
    if not uiMap then return nil end
    local pos = C_Map.GetPlayerMapPosition(uiMap, "player")
    if not pos then return nil end
    local x, y = pos.x, pos.y
    if not x or not y then return nil end
    return uiMap, x, y
end

function Data.PlayerPoint()
    local uiMap, x, y = PlayerMapPosition()
    if not uiMap then return nil end
    return Data.MakePoint(uiMap, x, y)
end

-- PlayerPoint without the allocation: fills `out` and returns it (nil when there is no position).
-- For per-frame callers that don't keep the point; anything stored must use PlayerPoint.
function Data.PlayerPointInto(out)
    local uiMap, x, y = PlayerMapPosition()
    if not uiMap then return nil end
    local c, wx, wy = Data.ToWorld(uiMap, x, y)
    if not c then return nil end
    out.map, out.x, out.y, out.c, out.wx, out.wy = uiMap, x, y, c, wx, wy
    return out
end

-- North/west components (yards) of the vector a -> b. Zone maps have north up and east right,
-- so the map's own axes give compass directions without assuming a world-axis convention.
local function NorthWest(a, b)
    if not a or not b or a.c ~= b.c then return nil end
    local basis = GetBasis(a.map)
    if not basis then return nil end
    local dx, dy = b.wx - a.wx, b.wy - a.wy
    local ex, ey, sx, sy = basis[4], basis[5], basis[6], basis[7]
    local el = (ex * ex + ey * ey) ^ 0.5
    local sl = (sx * sx + sy * sy) ^ 0.5
    if el == 0 or sl == 0 then return nil end
    local east = (dx * ex + dy * ey) / el
    local south = (dx * sx + dy * sy) / sl
    return -south, -east
end

-- Absolute bearing from a to b: radians, 0 = north, counter-clockwise (same convention as GetPlayerFacing).
function Data.Bearing(a, b)
    local north, west = NorthWest(a, b)
    if not north then return nil end
    return math.atan2(west, north)
end

local COMPASS = { "N", "NW", "W", "SW", "S", "SE", "E", "NE" }
function Data.Compass(a, b)
    local bearing = Data.Bearing(a, b)
    if not bearing then return nil end
    local sector = floor((bearing % (2 * math.pi)) / (math.pi / 4) + 0.5) % 8
    return COMPASS[sector + 1]
end

-- Angle to turn toward pt relative to where the player faces (radians, counter-clockwise = left).
function Data.TurnAngle(player, pt)
    local bearing = Data.Bearing(player, pt)
    local facing = GetPlayerFacing and GetPlayerFacing()
    if not bearing or not facing then return nil end
    return bearing - facing
end

function Data.Distance(a, b)
    if not a or not b or a.c ~= b.c then return huge end
    local dx, dy = a.wx - b.wx, a.wy - b.wy
    return (dx * dx + dy * dy) ^ 0.5
end

-- Appends world points for a QuestieDB spawn list ({ [areaId] = { {x, y, phase?}, ... } }).
local function AddSpawnPoints(spawns, out)
    if type(spawns) ~= "table" then return out end
    for areaId, list in pairs(spawns) do
        local uiMap = areaToUiMap[areaId]
        if uiMap and uiMap ~= 0 and not dungeonAreas[areaId] and type(list) == "table" then
            -- Data.MakePoint inlined: same fields, same arithmetic, one basis lookup per area.
            local b = GetBasis(uiMap)
            if b then
                local c, b2, b3, b4, b5, b6, b7 = b[1], b[2], b[3], b[4], b[5], b[6], b[7]
                local n = #out
                for i = 1, #list do
                    local p = list[i]
                    local x, y = p[1], p[2]
                    if type(x) == "number" and type(y) == "number" and x >= 0 and y >= 0 then
                        x, y = x / 100, y / 100
                        n = n + 1
                        out[n] = { map = uiMap, x = x, y = y, c = c, wx = b2 + x * b4 + y * b6, wy = b3 + x * b5 + y * b7 }
                    end
                end
            end
        end
    end
    return out
end

local CELL = 100 -- yards

-- The general case: string cell keys (also tells continents apart).
local function HotspotByString(points)
    local n = #points
    local cells = {}
    for i = 1, n do
        local p = points[i]
        local cx, cy = floor(p.wx / CELL), floor(p.wy / CELL)
        local key = p.c .. ":" .. cx .. ":" .. cy
        local cell = cells[key]
        if not cell then
            cell = { c = p.c, cx = cx, cy = cy, n = 0 }
            cells[key] = cell
        end
        cell.n = cell.n + 1
        cell[cell.n] = p
    end
    local best, bestScore
    for _, cell in pairs(cells) do
        local score = 0
        for dx = -1, 1 do
            for dy = -1, 1 do
                local other = cells[cell.c .. ":" .. (cell.cx + dx) .. ":" .. (cell.cy + dy)]
                if other then score = score + other.n end
            end
        end
        -- Ties break on cell position so the same spawns always give the same hotspot.
        if not bestScore or score > bestScore
            or (score == bestScore and (cell.cx < best.cx or (cell.cx == best.cx and cell.cy < best.cy))) then
            best, bestScore = cell, score
        end
    end
    local sx, sy = 0, 0
    for i = 1, best.n do sx = sx + best[i].wx; sy = sy + best[i].wy end
    local mx, my = sx / best.n, sy / best.n
    local pick, pickD = best[1], huge
    for i = 1, best.n do
        local p = best[i]
        local d = (p.wx - mx) ^ 2 + (p.wy - my) ^ 2
        if d < pickD then pick, pickD = p, d end
    end
    return pick, bestScore
end

local KEY_LIMIT, KEY_SCALE = 4194304, 16777216 -- cells within 2^22 of the origin; 2^24 apart in the key

-- Densest cluster of points, scored over each 3x3 neighbourhood of 100-yard cells.
-- Returns a real point from the cluster (so it carries a valid map id) and the cluster size.
-- Points on one continent (the usual case) use numeric cell keys and no strings; cell order then
-- never matters because ties break on cell position.
function Data.Hotspot(points)
    local n = #points
    if n == 0 then return nil, 0 end
    if n == 1 then return points[1], 1 end
    local c1 = points[1].c
    local cells, list = {}, {}
    for i = 1, n do
        local p = points[i]
        local cx, cy = floor(p.wx / CELL), floor(p.wy / CELL)
        if p.c ~= c1 or not (cx >= -KEY_LIMIT and cx <= KEY_LIMIT and cy >= -KEY_LIMIT and cy <= KEY_LIMIT)
            or (cx == 0 and 1 / cx < 0) or (cy == 0 and 1 / cy < 0) then
            return HotspotByString(points) -- several continents, a -0 cell, or coordinates out of range
        end
        local key = cx * KEY_SCALE + cy
        local cell = cells[key]
        if not cell then
            cell = { cx = cx, cy = cy, n = 0 }
            cells[key] = cell
            list[#list + 1] = cell
        end
        cell.n = cell.n + 1
        cell[cell.n] = p
    end
    local best, bestScore
    for k = 1, #list do
        local cell = list[k]
        local cx, cy = cell.cx, cell.cy
        local score = 0
        for dx = -1, 1 do
            local row = (cx + dx) * KEY_SCALE + cy
            for dy = -1, 1 do
                local other = cells[row + dy]
                if other then score = score + other.n end
            end
        end
        if not bestScore or score > bestScore
            or (score == bestScore and (cx < best.cx or (cx == best.cx and cy < best.cy))) then
            best, bestScore = cell, score
        end
    end
    local sx, sy = 0, 0
    for i = 1, best.n do sx = sx + best[i].wx; sy = sy + best[i].wy end
    local mx, my = sx / best.n, sy / best.n
    local pick, pickD = best[1], huge
    for i = 1, best.n do
        local p = best[i]
        local d = (p.wx - mx) ^ 2 + (p.wy - my) ^ 2
        if d < pickD then pick, pickD = p, d end
    end
    return pick, bestScore
end

local function Nearest(points, ref)
    if #points == 0 then return nil end
    if not ref then return points[1] end
    local best, bestD = points[1], huge
    for i = 1, #points do
        local d = Data.Distance(points[i], ref)
        if d < bestD then best, bestD = points[i], d end
    end
    return best
end
Data.Nearest = Nearest

---------------------------------------------------------------------------
-- Completed quests and the quest log
---------------------------------------------------------------------------

function Data.RefreshCompleted()
    local set, count = {}, 0
    local ids = C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs and C_QuestLog.GetAllCompletedQuestIDs()
    if type(ids) == "table" then
        for i = 1, #ids do
            if not set[ids[i]] then set[ids[i]] = true; count = count + 1 end
        end
    end
    for id in pairs(Data.recentTurnIns) do
        if not set[id] then set[id] = true; count = count + 1 end
    end
    Data.completed = set
    Data.completedCount = count
    return count
end

function Data.MarkTurnedIn(questId)
    if not questId then return end
    Data.recentTurnIns[questId] = true
    if not Data.completed[questId] then
        Data.completed[questId] = true
        Data.completedCount = Data.completedCount + 1
    end
end

function Data.ReadQuestLog()
    local log, count = {}, 0
    local n = C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, n do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID and info.questID > 0 then
            local qid = info.questID
            local complete = C_QuestLog.IsComplete(qid)
            if not complete and C_QuestLog.ReadyForTurnIn then
                complete = C_QuestLog.ReadyForTurnIn(qid)
            end
            log[qid] = {
                title = info.title,
                level = info.level,
                complete = complete and true or false,
                objectives = C_QuestLog.GetQuestObjectives(qid) or {},
            }
            if not info.isHidden then count = count + 1 end
        end
    end
    Data.log, Data.logCount = log, count
    return log, count
end

function Data.MaxQuests()
    local max = C_QuestLog.GetMaxNumQuestsCanAccept and C_QuestLog.GetMaxNumQuestsCanAccept()
    return (max and max > 0) and max or 20
end

-- A compact signature of quest-log state, used to replan only when something meaningful changed.
function Data.LogSignature(log)
    local parts = {}
    for qid, entry in pairs(log) do
        local done = 0
        for i, obj in ipairs(entry.objectives) do
            if obj.finished then done = done + 2 ^ (i - 1) end
        end
        parts[#parts + 1] = qid .. ":" .. done .. (entry.complete and "c" or "")
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function DoneMask(entry)
    local done = 0
    for i, obj in ipairs(entry.objectives) do
        if obj.finished then done = done + 2 ^ (i - 1) end
    end
    return done
end

-- LogSignature(a) == LogSignature(b), without building either string: same quests, same finished
-- objectives, same complete flags. Runs on every quest-log update, so it allocates nothing.
function Data.SameLogState(a, b)
    if not a or not b then return false end
    local n = 0
    for qid, ea in pairs(a) do
        local eb = b[qid]
        if not eb or (not ea.complete) ~= (not eb.complete) or DoneMask(ea) ~= DoneMask(eb) then return false end
        n = n + 1
    end
    for _ in pairs(b) do
        n = n - 1
        if n < 0 then return false end
    end
    return n == 0
end

---------------------------------------------------------------------------
-- Static quest index (built once per session, spread over frames by the caller)
---------------------------------------------------------------------------

local RANK_ELITE, RANK_RAREELITE, RANK_BOSS = 1, 2, 3

-- Blizzard QuestSort IDs for class quest categories.
local CLASS_SORT = {
    WARRIOR = -81, PALADIN = -141, HUNTER = -261, ROGUE = -162, PRIEST = -262,
    SHAMAN = -82, MAGE = -161, WARLOCK = -61, DRUID = -263,
}
local IS_CLASS_SORT = {}
for _, sort in pairs(CLASS_SORT) do IS_CLASS_SORT[sort] = true end

local function NonEmpty(t) return type(t) == "table" and next(t) ~= nil end

local function ItemCount(itemId)
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    if not fn then return 0 end
    local ok, count = pcall(fn, itemId)
    return (ok and count) or 0
end
Data.ItemCount = ItemCount

local function FriendlyStarter(npcId)
    local f = NpcDB.Get(npcId, "friendlyToFaction")
    if not f or f == "AH" then return true end
    if f == "H" then return Data.faction == "Horde" end
    if f == "A" then return Data.faction == "Alliance" end
    return false
end

-- Builds the static record for one quest, or records why it can never be routed.
local function BuildInfo(id)
    local name = QuestDB.name(id)
    if not name then return nil end
    local info = { id = id, name = name }

    info.level = QuestDB.questLevel(id) or 0
    info.reqLevel = QuestDB.requiredLevel(id) or 0
    info.reqMaxLevel = QuestDB.requiredMaxLevel(id) or 0
    info.zoneOrSort = QuestDB.zoneOrSort(id) or 0
    info.preSingle = QuestDB.preQuestSingle(id)
    info.preGroup = QuestDB.preQuestGroup(id)
    info.exclusive = QuestDB.exclusiveTo(id)
    info.breadcrumbFor = QuestDB.breadcrumbForQuestId(id) or 0
    info.breadcrumbs = QuestDB.breadcrumbs(id) -- breadcrumbs that lead to this quest
    info.nextInChain = QuestDB.nextQuestInChain(id) or 0
    info.parent = QuestDB.parentQuest(id) or 0
    info.untilDone = QuestDB.availableUntilCompleted(id) or 0
    info.startWith = QuestDB.availableStartingWith(id) or 0
    info.disabledBy = QuestDB.disabledByQuest(id) or 0

    local races = QuestDB.requiredRaces(id) or 0
    local classes = QuestDB.requiredClasses(id) or 0
    local specialFlags = QuestDB.specialFlags(id) or 0
    local zoneOrSort = info.zoneOrSort
    local _, classToken = UnitClass("player")
    local mySort = CLASS_SORT[classToken]

    -- Class quests: restricted to exactly this class, or filed under this class's quest category.
    -- Multi-class masks still pass the class filter but are scored like any other quest.
    info.classQuest = (Data.classBit ~= nil and classes == Data.classBit) or (mySort ~= nil and zoneOrSort == mySort)
    -- Completed by a scripted event (escorts, defenses, rituals): the "party accept" quest flag or
    -- the "needs event" special flag.
    local questFlags = QuestDB.questFlags and QuestDB.questFlags(id) or 0
    info.event = HasBit(questFlags, 2) or HasBit(specialFlags, 2)

    local reason
    if SP.NotInGame and SP.NotInGame[id] then
        reason = "not-in-game" -- in the database but not on Forever (Questie's blacklist, see NotInGame.lua)
    elseif specialFlags % 2 == 1 then
        reason = "repeatable"
    elseif races ~= 0 and Data.raceBit and not HasBit(races, Data.raceBit) then
        reason = "race"
    elseif classes ~= 0 and Data.classBit and not HasBit(classes, Data.classBit) then
        reason = "class"
    elseif IS_CLASS_SORT[zoneOrSort] and zoneOrSort ~= mySort then
        reason = "class"
    elseif QuestDB.requiredSkill(id) or QuestDB.requiredRanks(id)
        or (QuestDB.requiredSpecialization(id) or 0) ~= 0 then
        reason = "profession"
    elseif QuestDB.requiredMinRep(id) or QuestDB.requiredMaxRep(id) then
        reason = "reputation"
    elseif (QuestDB.requiredSpell(id) or 0) ~= 0 then
        reason = "requirement"
    elseif dungeonAreas[zoneOrSort] then
        reason = "dungeon"
    elseif zoneOrSort < 0 and not info.classQuest then
        reason = "event" -- holidays, professions and other special categories
    end

    local startedBy = QuestDB.startedBy(id) or {}
    info.startNpcs = startedBy[1]
    info.startObjects = startedBy[2]
    info.startItems = startedBy[3]
    -- Started only by an item: routable once that item is in the bags (checked live).
    info.itemOnly = NonEmpty(startedBy[3]) and not NonEmpty(startedBy[1]) and not NonEmpty(startedBy[2])
    if not reason then
        if info.itemOnly then
            -- fine; see Data.IsAvailable
        elseif not NonEmpty(startedBy[1]) and not NonEmpty(startedBy[2]) then
            reason = "no-starter"
        elseif NonEmpty(startedBy[1]) then
            local anyFriendly = false
            for _, npcId in ipairs(startedBy[1]) do
                if FriendlyStarter(npcId) then anyFriendly = true; break end
            end
            if not anyFriendly and not NonEmpty(startedBy[2]) then reason = "faction" end
        end
    end

    info.blocked = reason
    return info
end

-- Every quest that is not blocked, as a list: what the planner scans for candidates.
local openInfo, openListed = {}, {}
local function NoteInfo(id, info)
    if info and not info.blocked and not openListed[id] then
        openListed[id] = true
        openInfo[#openInfo + 1] = info
    end
end

-- Builds the index in slices; call repeatedly from a coroutine. Yields every `slice` quests.
Data.itemOnlyIds = {}

-- Yields once about SLICE_MS of work has run, however many steps that took (one step's cost
-- varies with what QuestieDB has to decode). Counts steps where there's no clock.
local SLICE_MS = 2
local function Slicer(every)
    if not every then return function() end end
    local clock = debugprofilestop
    if not clock then
        local n = 0
        return function()
            n = n + 1
            if n % every == 0 then coroutine.yield() end
        end
    end
    local last = clock()
    return function()
        if clock() - last >= SLICE_MS then
            coroutine.yield()
            last = clock()
        end
    end
end

function Data.BuildIndex(yieldEvery)
    local ids = QuestDB.GetAllIds()
    local tick = Slicer(yieldEvery)
    local itemOnly = {}
    for i = 1, #ids do
        local id = ids[i]
        if questInfo[id] == nil then
            local ok, info = pcall(BuildInfo, id)
            questInfo[id] = (ok and info) or false
        end
        local info = questInfo[id]
        NoteInfo(id, info)
        if info and info.itemOnly and not info.blocked then itemOnly[#itemOnly + 1] = id end
        tick()
    end
    Data.itemOnlyIds = itemOnly
    Data.indexReady = true
end

-- Friendly innkeepers, for setting your hearthstone: { id, name, pt }. Found once per session.
-- GetRaw reads one row without keeping it, so scanning every NPC leaves nothing cached.
Data.inns = {}
function Data.BuildInns(yieldEvery)
    local enum = LibQuestieDB.Enum and LibQuestieDB.Enum.npcFlags
    local flag = enum and enum.INNKEEPER
    if not flag then return end
    local read = NpcDB.GetRaw or NpcDB.Get
    local ids = NpcDB.GetAllIds()
    local tick = Slicer(yieldEvery)
    local inns = {}
    for i = 1, #ids do
        local id = ids[i]
        local flags = read(id, "npcFlags")
        if type(flags) == "number" and HasBit(flags, flag) and FriendlyStarter(id) then
            local points = AddSpawnPoints(NpcDB.spawns(id), {})
            if points[1] then inns[#inns + 1] = { id = id, name = NpcDB.name(id), pt = points[1] } end
        end
        tick()
    end
    Data.inns = inns
end

function Data.Info(id)
    local info = questInfo[id]
    if info == nil then
        local ok, built = pcall(BuildInfo, id)
        info = (ok and built) or false
        questInfo[id] = info
        NoteInfo(id, info)
    end
    return info or nil
end

function Data.AllInfo() return questInfo end

-- The entries of AllInfo() that are not blocked (the only ones Data.IsAvailable can accept).
function Data.OpenInfo() return openInfo end

---------------------------------------------------------------------------
-- Dynamic availability
---------------------------------------------------------------------------

-- preQuestGroup, with Questie's rules: a negative id means quest -id must be done, and a positive
-- prerequisite also counts as done when one of its exclusiveTo alternatives was done instead.
local function AllDone(list, completed)
    if type(list) ~= "table" then return true end
    for _, q in ipairs(list) do
        if q < 0 then
            if not completed[-q] then return false end
        elseif not completed[q] then
            -- Read questInfo directly: this runs inside pairs() over it, so it must never insert.
            local pre = questInfo[q]
            local alt = false
            if pre and type(pre.exclusive) == "table" then
                for _, e in ipairs(pre.exclusive) do
                    if completed[e] then alt = true; break end
                end
            end
            if not alt then return false end
        end
    end
    return true
end

local function AnyDone(list, completed)
    if type(list) ~= "table" or #list == 0 then return true end
    for _, q in ipairs(list) do
        if completed[q] then return true end
    end
    return false
end

-- Can the character pick this quest up right now (ignoring travel)?
function Data.IsAvailable(info, skipped)
    local id, completed, log = info.id, Data.completed, Data.log
    if info.blocked or completed[id] or log[id] or (skipped and skipped[id]) then return false end
    local level = Data.level
    if info.reqLevel > level then return false end
    if info.reqMaxLevel ~= 0 and level > info.reqMaxLevel then return false end
    if info.level > 0 and info.level - level > Data.MaxAbove() then return false end -- too hard for now
    -- Gray quests are skipped, except class quests: those unlock abilities at any level.
    local classAlways = info.classQuest and not (SP.db and SP.db.classQuests == false)
    if not classAlways and Data.IsTrivial(info.level) then return false end
    if not AllDone(info.preGroup, completed) then return false end
    if not AnyDone(info.preSingle, completed) then return false end
    if type(info.exclusive) == "table" then
        for _, q in ipairs(info.exclusive) do
            if completed[q] or log[q] then return false end
        end
    end
    if info.breadcrumbFor ~= 0 and (completed[info.breadcrumbFor] or log[info.breadcrumbFor]) then return false end
    -- The server won't offer a quest while one of its breadcrumbs is in the log.
    if type(info.breadcrumbs) == "table" then
        for _, q in ipairs(info.breadcrumbs) do
            if log[q] then return false end
        end
    end
    -- Once the next quest in the chain is active or done, this one is no longer offered.
    if info.nextInChain ~= 0 and (completed[info.nextInChain] or log[info.nextInChain]) then return false end
    if info.parent ~= 0 and not log[info.parent] then return false end
    if info.untilDone ~= 0 and completed[info.untilDone] then return false end
    if info.startWith ~= 0 and not (completed[info.startWith] or log[info.startWith]) then return false end
    if info.disabledBy ~= 0 and log[info.disabledBy] then return false end
    if info.itemOnly and not Data.HasStartItem(info) then return false end
    if QuestieRejects(id) then return false end
    return true
end

function Data.HasStartItem(info)
    if type(info.startItems) ~= "table" then return false end
    for _, itemId in ipairs(info.startItems) do
        if ItemCount(itemId) > 0 then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Locations (lazy, cached per quest)
---------------------------------------------------------------------------

local DEFAULT_COUNT = { kill = 8, item = 6, object = 4, explore = 1, spell = 1, event = 1 }

-- Objective text for something you have to see through, not just reach ("Escort Pal'juh out of Kolkar Crag").
local ESCORT_TEXT = { "^escort", "^protect", "^defend", "^guard ", "^lead ", "^guide ", "^accompany", "^help .- escape" }
function Data.IsEscortText(text)
    if type(text) ~= "string" then return false end
    text = text:lower():gsub("^%s+", "")
    for _, pattern in ipairs(ESCORT_TEXT) do
        if text:find(pattern) then return true end
    end
    return false
end

-- First clause of the quest's objective text: "Escort OOX-17/TN to Steamwheedle Port".
local function EventName(id)
    local lines = QuestDB.objectivesText and QuestDB.objectivesText(id)
    local text = type(lines) == "table" and lines[1]
    if type(text) ~= "string" or text == "" then return nil end
    text = text:gsub(",%s*then.*$", ""):gsub("%s+and then.*$", ""):gsub("%s+then%s.*$", ""):gsub("[%.%s]+$", "")
    if #text > 60 then text = text:sub(1, 57):gsub("%s+%S*$", "") .. "..." end
    return text
end
local SEARCH_MAX_SPOTS = 12

-- Spawn points and stats per NPC and object, shared by every quest that uses them (a mob is often
-- the target of several quests, and quest givers start and finish many). Each QuestieDB table read
-- is a fresh decode, so this saves most of the reads of a cold plan. Same lifetime as locCache.
local npcSpawnCache, npcStatCache, objectSpawnCache = {}, {}, {}

local function Append(out, points)
    local n = #out
    for i = 1, #points do out[n + i] = points[i] end
    return out
end

local function NpcSpawnPoints(npcId)
    local points = npcSpawnCache[npcId]
    if not points then
        points = AddSpawnPoints(NpcDB.spawns(npcId), {})
        if npcId ~= nil then npcSpawnCache[npcId] = points end
    end
    return points
end

local function ObjectSpawnPoints(objectId)
    local points = objectSpawnCache[objectId]
    if not points then
        points = AddSpawnPoints(ObjectDB.spawns(objectId), {})
        if objectId ~= nil then objectSpawnCache[objectId] = points end
    end
    return points
end

-- { rank, minLevel, maxLevel, name } of an NPC (name read on first use).
local function NpcStats(npcId)
    local stats = npcStatCache[npcId]
    if not stats then
        stats = { NpcDB.Get(npcId, "rank") or 0, NpcDB.Get(npcId, "minLevel") or 0, NpcDB.Get(npcId, "maxLevel") or 0 }
        if npcId ~= nil then npcStatCache[npcId] = stats end
    end
    return stats
end

-- Returns the points, whether they are elite, the easiest NPC level among those used, and the
-- summed kill XP over the points added (divide by their count for the average kill).
-- Normal NPCs win: elites count (and mark the result elite) only when no normal NPC within the
-- level cap has spawns, so one elite or dungeon boss on a drop list doesn't block the quest.
local function NpcPoints(npcIds, out, levelCap, names)
    if type(npcIds) ~= "table" then return out, false, nil, 0 end
    local base = #out
    local easiest, xpSum = nil, 0
    local elitePoints, eliteNames, eliteEasiest, eliteXP
    for _, npcId in ipairs(npcIds) do
        local stats = NpcStats(npcId)
        local minLevel = stats[2]
        if not levelCap or minLevel == 0 or minLevel <= levelCap then
            local rank = stats[1]
            local isElite = rank == RANK_ELITE or rank == RANK_RAREELITE or rank == RANK_BOSS
            if isElite and not elitePoints then elitePoints = {} end
            local dest = isElite and elitePoints or out
            local before = #dest
            Append(dest, NpcSpawnPoints(npcId))
            local added = #dest - before
            if added > 0 then
                local maxLevel = stats[3]
                local level = (maxLevel > 0 and maxLevel) or minLevel
                -- Kill XP, weighted by how many of the spawns are this NPC's.
                local low = minLevel > 0 and minLevel or nil
                local high = maxLevel > 0 and maxLevel or low
                local xp = added * (Data.MobXP(low) + Data.MobXP(high)) / 2
                local name
                if names then
                    name = stats.name
                    if name == nil then name = NpcDB.name(npcId) or false; stats.name = name end
                end
                if isElite then
                    if level > 0 and (not eliteEasiest or level < eliteEasiest) then eliteEasiest = level end
                    eliteXP = (eliteXP or 0) + xp
                    if name then
                        eliteNames = eliteNames or {}
                        eliteNames[#eliteNames + 1] = name
                    end
                else
                    if level > 0 and (not easiest or level < easiest) then easiest = level end
                    xpSum = xpSum + xp
                    if name then names[#names + 1] = name end
                end
            end
        end
    end
    if #out == base and elitePoints and #elitePoints > 0 then
        Append(out, elitePoints)
        if names and eliteNames then
            for i = 1, #eliteNames do names[#names + 1] = eliteNames[i] end
        end
        return out, true, eliteEasiest, eliteXP or 0
    end
    return out, false, easiest, xpSum
end

local function ObjectPoints(objectIds, out)
    if type(objectIds) ~= "table" then return out end
    for _, objectId in ipairs(objectIds) do
        Append(out, ObjectSpawnPoints(objectId))
    end
    return out
end

-- Where an item objective can be obtained. Limits generic drops to a handful of sources.
local function ItemPoints(itemId, levelCap)
    local points, elite, vendor, mobLevel, xpSum = {}, false, false, nil, 0
    local sources = {} -- names of the mobs it drops from (within the difficulty cap)
    local npcs = ItemDB.npcDrops(itemId)
    if type(npcs) == "table" then
        local limited = {}
        for i = 1, math.min(#npcs, 12) do limited[i] = npcs[i] end
        local _, e, l, x = NpcPoints(limited, points, levelCap, sources)
        elite, mobLevel, xpSum = e, l, x
    end
    local fromNpcs = #points
    local killXP = fromNpcs > 0 and xpSum / fromNpcs or nil
    ObjectPoints(ItemDB.objectDrops(itemId), points)
    if #points == 0 then
        local vendors = ItemDB.vendors(itemId)
        if type(vendors) == "table" then
            NpcPoints(vendors, points)
            vendor = #points > 0
        end
    end
    local objectsOnly = fromNpcs == 0 and #points > 0 and not vendor
    if vendor or objectsOnly then mobLevel, sources, killXP = nil, nil, nil end
    return points, elite, vendor, objectsOnly, mobLevel, sources, killXP
end

local function ObjectiveName(kind, entityId)
    if kind == "kill" then return NpcDB.name(entityId) end
    if kind == "object" then return ObjectDB.name(entityId) end
    if kind == "item" then return ItemDB.name(entityId) end
    return nil
end

local starterCache = {}

-- Spawn points of the friendly NPCs/objects that start a quest (cheap; used to pre-filter by distance).
function Data.StarterPoints(id)
    local cached = starterCache[id]
    if cached then return cached end
    local info = Data.Info(id)
    local points = {}
    if info then
        if type(info.startNpcs) == "table" then
            for _, npcId in ipairs(info.startNpcs) do
                if FriendlyStarter(npcId) then Append(points, NpcSpawnPoints(npcId)) end
            end
        end
        ObjectPoints(info.startObjects, points)
    end
    starterCache[id] = points
    return points
end

-- Returns { starters = {points}, finishers = {points}, objectives = { {kind, name, points, ...} }, elite = bool }
function Data.Locations(id)
    local cached = locCache[id]
    if cached ~= nil then return cached or nil end
    local info = Data.Info(id)
    if not info then locCache[id] = false; return nil end

    -- Drop sources above the difficulty cap are never farm targets (e.g. level 16 plainstriders at 12).
    local levelCap = Data.MaxMobLevel()
    local loc = { starters = Data.StarterPoints(id), finishers = {}, objectives = {}, all = {}, unlocated = {}, elite = false }
    -- loc.mobLevel: level of the hardest mobs the quest requires fighting (easiest source per objective).
    local function NoteMob(level)
        if level and (not loc.mobLevel or level > loc.mobLevel) then loc.mobLevel = level end
    end

    local finishedBy = QuestDB.finishedBy(id) or {}
    if type(finishedBy[1]) == "table" then
        for _, npcId in ipairs(finishedBy[1]) do
            if FriendlyStarter(npcId) then Append(loc.finishers, NpcSpawnPoints(npcId)) end
        end
    end
    ObjectPoints(finishedBy[2], loc.finishers)

    local objectives = QuestDB.objectives(id) or {}
    local function Add(kind, entityId, points, text, extra)
        if #points == 0 then
            -- No usable spawn data (inside a dungeon, or new Forever content QuestieDB lacks).
            loc.unlocated[#loc.unlocated + 1] = text or ObjectiveName(kind, entityId) or kind
            return
        end
        local entry = {
            kind = kind,
            name = text or ObjectiveName(kind, entityId),
            points = points,
            count = DEFAULT_COUNT[kind] or 1,
        }
        if extra then for k, v in pairs(extra) do entry[k] = v end end
        -- Escorts and other scripted events take minutes, not a walk-through.
        if kind == "event" or (kind == "explore" and Data.IsEscortText(entry.name)) then entry.scripted = true end
        -- A crate, chest or other object with only a few possible spots: only some are spawned at a
        -- time and others may have just looted it, so the route searches them one by one.
        if (kind == "object" or entry.objectsOnly) and #points <= SEARCH_MAX_SPOTS then entry.search = true end
        loc.objectives[#loc.objectives + 1] = entry
        for i = 1, #points do loc.all[#loc.all + 1] = points[i] end
    end

    if type(objectives[1]) == "table" then
        for _, o in ipairs(objectives[1]) do
            local points, elite, mobLevel, xpSum = NpcPoints({ o[1] }, {}, nil)
            if elite then loc.elite = true end
            NoteMob(mobLevel)
            Add("kill", o[1], points, o[2], { mobLevel = mobLevel, killXP = #points > 0 and xpSum / #points or nil })
        end
    end
    if type(objectives[2]) == "table" then
        for _, o in ipairs(objectives[2]) do
            local objectName = ObjectDB.name(o[1])
            Add("object", o[1], ObjectPoints({ o[1] }, {}), o[2], { names = objectName and { [objectName] = true } or nil })
        end
    end
    if type(objectives[3]) == "table" then
        for _, o in ipairs(objectives[3]) do
            local points, elite, vendor, objectsOnly, mobLevel, sources, killXP = ItemPoints(o[1], levelCap)
            if elite then loc.elite = true end
            NoteMob(mobLevel)
            -- Names of the objects that hold the item, so hovering one can be recognised.
            local names
            if objectsOnly then
                names = {}
                for _, objectId in ipairs(ItemDB.objectDrops(o[1]) or {}) do
                    local n = ObjectDB.name(objectId)
                    if n then names[n] = true end
                end
            end
            Add("item", o[1], points, o[2], { vendor = vendor, objectsOnly = objectsOnly, mobLevel = mobLevel, itemId = o[1],
                names = names, sources = sources, killXP = killXP })
        end
    end
    if type(objectives[5]) == "table" then
        for _, o in ipairs(objectives[5]) do
            local points, elite, mobLevel, xpSum = NpcPoints(o[1], {}, nil)
            if elite then loc.elite = true end
            NoteMob(mobLevel)
            Add("kill", o[2], points, o[3] or NpcDB.name(o[2]), { mobLevel = mobLevel, killXP = #points > 0 and xpSum / #points or nil })
        end
    end
    local trigger = QuestDB.triggerEnd(id)
    if type(trigger) == "table" and type(trigger[2]) == "table" then
        Add("explore", nil, AddSpawnPoints(trigger[2], {}), trigger[1])
    end
    local extras = QuestDB.extraObjectives(id)
    local extraPoints = {}
    if type(extras) == "table" then
        for _, e in ipairs(extras) do
            if type(e[1]) == "table" then
                local points = AddSpawnPoints(e[1], {})
                for i = 1, #points do
                    loc.all[#loc.all + 1] = points[i]
                    extraPoints[#extraPoints + 1] = points[i]
                end
            end
        end
    end
    -- Items the quest needs that aren't objectives or handed over by the giver (a carcass, a
    -- feather): nothing routes to them, so the steps say to bring them.
    local sourceItems = QuestDB.requiredSourceItems and QuestDB.requiredSourceItems(id)
    if type(sourceItems) == "table" then
        local skip = { [QuestDB.sourceItemId and QuestDB.sourceItemId(id) or 0] = true }
        if type(objectives[3]) == "table" then
            for _, o in ipairs(objectives[3]) do skip[o[1]] = true end
        end
        for _, itemId in ipairs(sourceItems) do
            local name = not skip[itemId] and ItemDB.name(itemId)
            if name then
                loc.bring = loc.bring or {}
                loc.bring[#loc.bring + 1] = name
            end
        end
    end

    -- A scripted quest with nothing else to do (escorts, mostly): the event itself is the objective.
    -- It starts where the quest says, or with the quest giver (escorts begin at the NPC you escort).
    if info.event and #loc.objectives == 0 and #loc.unlocated == 0 then
        local points = #extraPoints > 0 and extraPoints or loc.starters
        if points and #points > 0 then Add("event", nil, points, EventName(id) or info.name) end
    end

    for _, obj in ipairs(loc.objectives) do
        obj.spot, obj.density = Data.Hotspot(obj.points)
    end

    locCache[id] = loc
    return loc
end

local starterNameCache, finisherNameCache = {}, {}

function Data.ClearLocationCache()
    locCache = {}
    starterCache = {}
    npcSpawnCache, npcStatCache, objectSpawnCache = {}, {}, {}
    starterNameCache, finisherNameCache = {}, {}
end

-- Matches a game objective ("5/7 Plainstrider Meat" or "Plainstrider Meat: 5/7") to a DB objective.
function Data.MatchObjective(loc, gameText, used)
    if not loc or not gameText then return nil end
    local text = gameText:lower()
    for i, obj in ipairs(loc.objectives) do
        if not used[i] and obj.name and obj.name ~= "" then
            -- Trigger texts often end in a period the game's objective line doesn't have.
            local name = obj.name:lower():gsub("[%.%s]+$", "")
            if name ~= "" and text:find(name, 1, true) then return i end
        end
    end
    return nil
end

-- Name and zone helpers for display.
function Data.QuestName(id)
    local name = QuestDB and QuestDB.name(id)
    if not name and C_QuestLog.GetTitleForQuestID then name = C_QuestLog.GetTitleForQuestID(id) end
    return name or ("Quest #" .. id)
end

function Data.QuestLevel(id)
    local level = QuestDB and QuestDB.questLevel(id)
    if level and level > 0 then return level end
    return nil
end

function Data.AreaName(areaId)
    if not areaId or areaId <= 0 then return nil end
    if C_Map.GetAreaInfo then
        local ok, name = pcall(C_Map.GetAreaInfo, areaId)
        if ok and name then return name end
    end
    return nil
end

function Data.MapName(uiMap)
    local info = uiMap and C_Map.GetMapInfo(uiMap)
    return info and info.name or nil
end

function Data.QuestZoneName(id)
    local zoneOrSort = QuestDB and QuestDB.zoneOrSort(id) or 0
    if zoneOrSort > 0 then
        return Data.AreaName(zoneOrSort) or Data.MapName(areaToUiMap[zoneOrSort])
    end
    if zoneOrSort < 0 then
        local classes = QuestDB.requiredClasses(id) or 0
        if classes ~= 0 then return "Class" end
        return "Special"
    end
    return nil
end

local function StarterName(id)
    local info = Data.Info(id)
    if info and type(info.startNpcs) == "table" and info.startNpcs[1] then
        return NpcDB.name(info.startNpcs[1])
    end
    if info and type(info.startObjects) == "table" and info.startObjects[1] then
        return ObjectDB.name(info.startObjects[1])
    end
    return nil
end

local function FinisherName(id)
    local finishedBy = QuestDB and QuestDB.finishedBy(id) or {}
    if type(finishedBy[1]) == "table" and finishedBy[1][1] then return NpcDB.name(finishedBy[1][1]) end
    if type(finishedBy[2]) == "table" and finishedBy[2][1] then return ObjectDB.name(finishedBy[2][1]) end
    return nil
end

-- Both are read for every unit of every plan; the names never change.
function Data.StarterName(id)
    local name = starterNameCache[id]
    if name == nil then
        name = StarterName(id) or false
        if id ~= nil and QuestDB then starterNameCache[id] = name end
    end
    return name or nil
end

function Data.FinisherName(id)
    local name = finisherNameCache[id]
    if name == nil then
        name = FinisherName(id) or false
        if id ~= nil and QuestDB then finisherNameCache[id] = name end
    end
    return name or nil
end
