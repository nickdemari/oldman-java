-- Oldman Java core: saved variables, events, and the frame-sliced planning loop.
local ADDON, SP = ...

SP.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "dev"
SP.speed = 7
SP.ready = false
SP.error = nil

local Data, Planner -- bound in Init

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffdc9e55Oldman Java|r " .. tostring(msg))
end
SP.Print = Print

local function IsLoaded(name)
    if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(name) end
    if IsAddOnLoaded then return IsAddOnLoaded(name) end
    return false
end
SP.IsLoaded = IsLoaded

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------

local function InitSaved()
    OldmanJavaDB = OldmanJavaDB or {}
    local db = OldmanJavaDB
    if db.waypoint == nil then db.waypoint = true end
    if db.shown == nil then db.shown = true end
    if db.classQuests == nil then db.classQuests = true end
    if db.mapLabels == nil then db.mapLabels = true end
    if db.nextLines == nil then db.nextLines = 4 end
    if db.autoQuest == nil then db.autoQuest = true end
    if db.shortcuts == nil then db.shortcuts = true end

    OldmanJavaCharDB = OldmanJavaCharDB or {}
    local char = OldmanJavaCharDB
    char.skipped = char.skipped or {}
    if type(char.speed) == "number" and char.speed > SP.speed then SP.speed = char.speed end
    SP.db, SP.char = db, char
end

---------------------------------------------------------------------------
-- Work scheduler: runs coroutines a few milliseconds per frame.
---------------------------------------------------------------------------

local driver = CreateFrame("Frame")
local jobs = {}
local BUDGET_MS = 6

local function Now()
    if debugprofilestop then return debugprofilestop() end
    return GetTime() * 1000
end

local function YieldFn() coroutine.yield() end

local function RunJobs()
    local deadline = Now() + BUDGET_MS
    while jobs[1] and Now() < deadline do
        local job = jobs[1]
        local ok, err = coroutine.resume(job.co)
        if not ok then
            table.remove(jobs, 1)
            if job.onError then job.onError(err) end
        elseif coroutine.status(job.co) == "dead" then
            table.remove(jobs, 1)
            if job.onDone then job.onDone() end
        end
    end
    if not jobs[1] then driver:SetScript("OnUpdate", nil) end
end

local function AddJob(fn, onDone, onError, name)
    for _, job in ipairs(jobs) do
        if job.name and job.name == name then return end
    end
    jobs[#jobs + 1] = { co = coroutine.create(fn), onDone = onDone, onError = onError, name = name }
    driver:SetScript("OnUpdate", RunJobs)
end
SP.AddJob = AddJob -- Path.lua runs its terrain searches here, one per job

---------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------

local planPending, planRunning, planTimer = false, false, nil
local retryScheduled, logDirty = false, false
local lastLog

-- Replans when an objective or quest actually finished since the last look.
local function CheckLog()
    local log = Data.ReadQuestLog()
    if not Data.SameLogState(lastLog, log) then
        lastLog = log
        SP.RequestPlan()
    end
end

-- Quest-starting items in the bags; true when that set changed since the last look.
local itemStarts, itemStartsNext, itemStartsCount = {}, {}, nil
local function ItemStartsChanged()
    local now, count = itemStartsNext, 0
    for id in pairs(now) do now[id] = nil end
    for _, id in ipairs(Data.itemOnlyIds) do
        local info = Data.Info(id)
        if info and not Data.completed[id] and not Data.log[id] and Data.HasStartItem(info) then
            now[id] = true
            count = count + 1
        end
    end
    local changed = count ~= itemStartsCount
    if not changed then
        for id in pairs(now) do
            if not itemStarts[id] then changed = true; break end
        end
    end
    itemStarts, itemStartsNext, itemStartsCount = now, itemStarts, count
    return changed
end

local function StartPlan()
    -- Never start over a running plan: it would swap Data.log and Data.completed under it.
    if planRunning then planPending = true; return end
    planPending = false
    if not SP.ready or not Data.indexReady then return end
    if InCombatLockdown() then planPending = true; return end
    -- Not from mid-air: Shortcuts asks for a plan when you land.
    if UnitOnTaxi and UnitOnTaxi("player") then planPending = true; return end
    local player = Data.PlayerPoint()
    if not player then
        -- No map position (instance, loading screen). Try again shortly, with one timer.
        planPending = true
        if not retryScheduled then
            retryScheduled = true
            C_Timer.After(3, function()
                retryScheduled = false
                if planPending then SP.RequestPlan() end
            end)
        end
        return
    end
    planRunning = true
    logDirty = false
    Data.RefreshPlayer()
    Data.RefreshCompleted() -- always plan against the server's full completed list
    lastLog = Data.ReadQuestLog()
    ItemStartsChanged() -- baseline: a quest item looted from now on triggers a replan
    local state = {
        player = player,
        speed = SP.speed,
        skipped = SP.char.skipped,
        maxQuests = Data.MaxQuests(),
    }
    AddJob(function()
        Planner.Build(state, YieldFn)
    end, function()
        planRunning = false
        -- Quest-log changes are held while planning; catch up before showing the new route.
        if logDirty then logDirty = false; CheckLog() end
        if SP.UI then SP.UI.OnPlan() end
        if SP.AutoQuest then SP.AutoQuest.OnPlan() end
        if planPending then SP.RequestPlan("queued") end
    end, function(err)
        planRunning = false
        -- Recover before the error handler runs, so a throwing handler can't skip it.
        if logDirty then logDirty = false; CheckLog() end
        if planPending then SP.RequestPlan("queued") end
        Print("planning error: " .. tostring(err))
        if geterrorhandler then geterrorhandler()(err) end
    end, "plan")
end

-- Debounced: bursts of quest events collapse into one plan.
function SP.RequestPlan()
    if planRunning then planPending = true; return end
    if planTimer then return end
    planTimer = true
    C_Timer.After(0.4, function()
        planTimer = nil
        StartPlan()
    end)
end

local function BuildIndex()
    AddJob(function()
        Data.BuildIndex(60)
        Data.BuildInns(250)
    end, function()
        if SP.UI then SP.UI.SetStatus(nil) end
        SP.RequestPlan()
    end, function(err)
        SP.error = "Could not read QuestieDB: " .. tostring(err)
        Print(SP.error)
        if SP.UI then SP.UI.SetStatus(SP.error) end
    end, "index")
end

---------------------------------------------------------------------------
-- Init and events
---------------------------------------------------------------------------

local function Init()
    Data, Planner = SP.Data, SP.Planner
    local ok, err = Data.Init()
    if not ok then
        SP.error = err
        Print(err)
        if SP.UI then SP.UI.SetStatus(err) end
        return
    end
    SP.ready = true
    Data.RefreshCompleted()
    if SP.Map then SP.Map.Init() end
    if SP.Settings then pcall(SP.Settings.RegisterBlizzardCategory) end
    if SP.UI then SP.UI.SetStatus("Reading quest database...") end

    if IsLoaded("Questie") and type(Questie) == "table" and Questie.API and Questie.API.RegisterOnReady then
        Questie.API.RegisterOnReady(function()
            if Data.HookQuestie() then SP.RequestPlan() end
        end)
    end
    BuildIndex()
end

local events = CreateFrame("Frame")
local handlers = {}

function handlers.ADDON_LOADED(name)
    if name == ADDON then
        InitSaved()
        if SP.UI then SP.UI.Create() end
    end
end

function handlers.PLAYER_LOGIN()
    Init()
end

function handlers.PLAYER_ENTERING_WORLD()
    if not SP.ready then return end
    Data.RefreshPlayer()
    Data.RefreshCompleted()
    -- The server's completed list can arrive late on a fresh login.
    C_Timer.After(5, function()
        local before = Data.completedCount
        if Data.RefreshCompleted() ~= before then SP.RequestPlan() end
    end)
    SP.RequestPlan()
end

function handlers.QUEST_ACCEPTED() SP.RequestPlan() end
function handlers.QUEST_REMOVED() SP.RequestPlan() end

function handlers.QUEST_TURNED_IN(questID)
    if not SP.ready then return end
    Data.MarkTurnedIn(questID)
    if SP.UI then SP.UI.OnCompletedChanged() end
    SP.RequestPlan()
end

function handlers.QUEST_LOG_UPDATE()
    if not SP.ready or not Data.indexReady then return end
    -- A plan is reading the log: note the change and check once it's done.
    if planRunning then logDirty = true; return end
    CheckLog()
    if SP.UI then SP.UI.Render() end -- objective progress bar
end

-- Keeps the XP bar and the level estimate current between plans.
function handlers.PLAYER_XP_UPDATE()
    if SP.ready and SP.UI then SP.UI.Render() end
end

function handlers.PLAYER_LEVEL_UP(level)
    if not SP.ready then return end
    Data.RefreshPlayer()
    if level then Data.level = level end
    Data.ClearLocationCache()
    SP.RequestPlan()
end

function handlers.ZONE_CHANGED_NEW_AREA()
    if not SP.ready then return end
    local route = Planner.route
    if #route == 0 or (route[1] and route[1].kind == "travel") then SP.RequestPlan() end
end

function handlers.BAG_UPDATE_DELAYED()
    if not SP.ready or not Data.indexReady then return end
    -- Compared with the set taken when the last plan started (nothing to compare before that).
    if itemStartsCount ~= nil and ItemStartsChanged() then SP.RequestPlan() end
    if SP.UI then SP.UI.Render() end -- "N in bags" counts on the panel and map
end

function handlers.PLAYER_REGEN_ENABLED()
    if planPending then SP.RequestPlan() end
end

-- Quest giver events for AutoQuest.lua.
for event, fn in pairs(SP.AutoQuest and SP.AutoQuest.handlers or {}) do
    assert(not handlers[event], event)
    handlers[event] = fn
end

for event in pairs(handlers) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event, ...)
    local handler = handlers[event]
    if handler then handler(...) end
end)

-- Learn travel speed: the fastest out-of-combat speed seen while mounted.
local function Faster(speed) return speed > SP.speed and speed < 30 end
C_Timer.NewTicker(1, function()
    if not SP.char then return end
    if IsMounted and IsMounted() and not InCombatLockdown() then
        local speed = GetUnitSpeed("player")
        -- GetUnitSpeed can return a restricted (secret) value in some situations; never compare those.
        if not speed or (issecretvalue and issecretvalue(speed)) then return end
        local ok, faster = pcall(Faster, speed)
        if ok and faster then
            SP.speed = speed
            SP.char.speed = speed
        end
    end
end)

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

function SP.SkipCurrent()
    local node = SP.UI and SP.UI.CurrentNode()
    if not node or not node.q then
        Print("nothing to skip.")
        return
    end
    SP.char.skipped[node.q] = true
    Print("skipping " .. Data.QuestName(node.q) .. ". /java unskip to undo all skips.")
    SP.RequestPlan()
end

SLASH_OLDMANJAVA1 = "/java"
SLASH_OLDMANJAVA2 = "/oldmanjava"
SLASH_OLDMANJAVA3 = "/sp" -- the old command keeps working
SlashCmdList.OLDMANJAVA = function(input)
    local cmd = strtrim((input or ""):lower())
    if cmd == "" then
        if SP.UI then SP.UI.Toggle() end
    elseif cmd == "replan" or cmd == "r" then
        Planner.Forget()
        SP.RequestPlan()
        Print("replanning.")
    elseif cmd == "skip" then
        SP.SkipCurrent()
    elseif cmd == "unskip" then
        SP.char.skipped = {}
        Print("cleared all skipped quests.")
        SP.RequestPlan()
    elseif cmd:match("^difficulty") then
        local level = cmd:match("^difficulty%s+(%a+)$")
        local caps = Data.DIFFICULTY
        if level and caps[level] then
            SP.db.difficulty = level
            Data.ClearLocationCache() -- which mobs count as farmable depends on the cap
            Print(string.format("difficulty %s: quests up to %d levels above you.", level, caps[level]))
            Planner.Forget()
            SP.RequestPlan()
        else
            local current = SP.db.difficulty or "normal"
            Print(string.format("difficulty is %s (quests up to %d levels above you).", current, caps[current] or 2))
            Print("/java difficulty easy - up to 1 level above you (solo, weak gear)")
            Print("/java difficulty normal - up to 2 levels above (default)")
            Print("/java difficulty hard - up to 4 levels above (good gear or a group)")
        end
    elseif cmd == "map" then
        local on = SP.Map and SP.Map.Toggle()
        Print("map overlay " .. (on and "on." or "off."))
    elseif cmd == "settings" or cmd == "config" or cmd == "options" then
        if SP.Settings then SP.Settings.Open() end
    elseif cmd == "route" then
        if SP.UI then SP.UI.PrintRoute() end
    elseif cmd == "done" or cmd == "completed" then
        if SP.CompletedList then SP.CompletedList.Toggle() end
    elseif cmd == "waypoint" or cmd == "wp" then
        SP.db.waypoint = not SP.db.waypoint
        Print("waypoints " .. (SP.db.waypoint and "on." or "off."))
        if SP.UI then SP.UI.Render() end -- sets or clears the waypoint; keeps the status line
    elseif cmd == "reset" then
        if SP.UI then SP.UI.ResetPosition() end
    elseif cmd:match("^slope") then
        local T = SP.Terrain
        local value = tonumber(cmd:match("^slope%s+(%d+)$"))
        local valid = false
        for _, v in ipairs(T.LIMITS) do
            if v == value then valid = true end
        end
        if valid then
            SP.db.slopeLimit = value
            if SP.Path then SP.Path.Reset() end
            Print(string.format("the arrow now uses ground up to %d degrees steep.", value))
        else
            Print(string.format("the arrow uses ground up to %d degrees steep. /java slope 46, 50, 55, 60 or 68 changes it.",
                SP.db.slopeLimit or T.DEFAULT_LIMIT))
        end
    elseif cmd == "terrain" then
        -- Diagnostic: what the terrain data says about where you stand.
        local T, p = SP.Terrain, Data.PlayerPoint()
        if not p then
            Print("no position here.")
        elseif not T.Has(p.c) then
            Print("no terrain data for this continent: the arrow points straight.")
        else
            local x, y = T.Cell(p.wx, p.wy)
            local names = { [0] = "ground up to 46 degrees", "ground 46 to 50 degrees", "ground 50 to 55 degrees",
                "ground 55 to 60 degrees", "ground 60 to 68 degrees", "ground steeper than 68 degrees", "no ground data",
                "lava, slime or the like", "water deep enough to swim" }
            local band = T.BandAt(p.c, x, y)
            local verdict
            if band == T.SWIM then
                verdict = "swimmable"
            elseif band == T.HURTS or band == T.NO_DATA then
                verdict = "never used"
            else
                verdict = (T.Walkable(p.c, x, y) and "walkable" or "too steep")
                    .. string.format(" at the %d degree limit", SP.db.slopeLimit or T.DEFAULT_LIMIT)
            end
            -- The game's own word on whether you're swimming, to check the water data against.
            local swimming = IsSwimming and (IsSwimming() and "you're swimming" or "you're not swimming") or nil
            Print(string.format("here: %s (cell %d, %d), %s.%s", names[band] or tostring(band), x, y, verdict,
                swimming and (" Game says " .. swimming .. ".") or ""))
            Print("arrow: " .. SP.Path.Status() .. ".")
        end
    elseif cmd == "travel" then
        if SP.Shortcuts then SP.Shortcuts.Describe(Print) end
    elseif cmd == "nav" then
        -- Diagnostic: does the game's own navigation know a path to the current step?
        local node = SP.UI and SP.UI.CurrentNode()
        if node then
            Print(string.format("step: %s %s (%s, %.0fs) at %.1f, %.1f", node.label or "", node.title or "", node.kind,
                node.work or 0, node.pt.x * 100, node.pt.y * 100))
        end
        local mapID = C_Map.GetBestMapForUnit("player")
        local ok, wp = pcall(C_Map.GetUserWaypoint)
        Print("user waypoint: " .. ((ok and wp and wp.position) and string.format("%.1f, %.1f", wp.position.x * 100, wp.position.y * 100) or "none"))
        local tracked = C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint and C_SuperTrack.IsSuperTrackingUserWaypoint()
        Print("super-tracked: " .. tostring(tracked))
        if C_Navigation and C_Navigation.GetNextWaypointForMap and mapID then
            local ok2, x, y, desc = pcall(C_Navigation.GetNextWaypointForMap, mapID)
            Print("game navigation: " .. ((ok2 and x) and string.format("%.1f, %.1f %s", x * 100, y * 100, tostring(desc or "")) or "nothing"))
        else
            Print("game navigation: not available")
        end
    else
        Print("commands:")
        Print("/java - show or hide the route")
        Print("/java settings - open the settings window")
        Print("/java replan - rebuild the route now")
        Print("/java route - print every step with distance and direction")
        Print("/java map - show or hide quest areas and the route on the world map")
        Print("/java difficulty - how far above your level the route may go (easy, normal, hard)")
        Print("/java skip - skip the current quest (/java unskip clears skips)")
        Print("/java done - list every quest this character has completed")
        Print("/java waypoint - toggle map waypoints")
        Print("/java slope - how steep the ground the arrow leads you over may be")
        Print("/java travel - the flight points and hearthstone the route can use")
        Print("/java reset - move the window back to the center")
    end
end
