-- Oldman Java route panel: a compass that points at the current step, the step itself, what comes
-- next, and how far the route takes you toward your next level.
local _, SP = ...

local UI = {}
SP.UI = UI

local Style = SP.Style
if not Style then
    -- Style.lua is new; a /reload can miss files added since the game started.
    DEFAULT_CHAT_FRAME:AddMessage("|cffdc9e55Oldman Java|r was updated with new files. Restart the game (not /reload) to load it.")
    function UI.Create() end
    function UI.Render() end
    function UI.SetStatus() end
    function UI.Toggle() end
    function UI.CurrentNode() return nil end
    function UI.OpenNodes() return {} end
    function UI.OpenNodesInto(buf) for i = #buf, 1, -1 do buf[i] = nil end return buf end
    function UI.OnPlan() end
    function UI.OnCompletedChanged() end
    function UI.PrintRoute() end
    function UI.ResetPosition() end
    function UI.SetScale() end
    return
end
local C = Style.color

local WIDTH = 336
local PAD = 14
local COMPASS = 62
local ARROW = 36
local COLUMN_X = PAD + COMPASS + 14
local COLUMN_W = WIDTH - COLUMN_X - PAD
local NEXT_LINES = 6 -- rows built; how many show is a setting (default 4)
local MIN_SCALE, MAX_SCALE = 0.7, 1.6

local KIND_COLOR = { pickup = C.pickup, obj = C.obj, turnin = C.turnin, travel = C.travel }
local TEXT_HEX = Style.Hex(C.text)

local frame
local hero, compass, list, footer = {}, {}, {}, {}
local controls, etaText, brand
local currentNode, lastWaypointKey, lastWaypointPt, lastShownKey
local controlsAlpha = 0

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function NodeKey(node)
    return node and (node.kind .. ":" .. tostring(node.q) .. ":" .. tostring(node.key or "") .. ":" .. (node.title or ""))
end

local donePoint = {} -- scratch player point for NodeDone, which keeps nothing

local LANDED_NEAR = 200 -- yards from the flight point you were flying to

-- Travel steps stay done once done: you may walk off again before the next plan drops them.
local function TravelDone(node)
    if node.done then return true end
    local Data = SP.Data
    local p = Data.PlayerPointInto(donePoint)
    local done
    if node.how == "fly" then
        -- Taken the flight (the next step shows while you fly), or got there some other way.
        done = (UnitOnTaxi and UnitOnTaxi("player")) or (p ~= nil and Data.Distance(p, node.exit) < LANDED_NEAR)
    elseif node.how == "hearth" then
        local S = SP.Shortcuts
        done = (S and S.lastHearth and S.lastHearth >= (node.made or 0)) or (p ~= nil and Data.Distance(p, node.pt) < 150)
    elseif node.how == "bind" then
        -- Set at this inn since the step appeared, or the game already says it's set here.
        local S = SP.Shortcuts
        local home = S and S.Home()
        done = (S and S.lastBound and S.lastBound >= (node.made or 0)) or (home ~= nil and Data.Distance(home.pt, node.pt) <= 150)
    else
        done = p ~= nil and (p.map == node.pt.map or Data.Distance(p, node.pt) < 150)
    end
    if done then node.done = true end
    return done and true or false
end

local function NodeDone(node)
    local Data = SP.Data
    if node.kind == "travel" then
        return TravelDone(node)
    elseif node.kind == "pickup" then
        return Data.log[node.q] ~= nil or Data.completed[node.q] == true
    elseif node.kind == "obj" then
        local entry = Data.log[node.q]
        if Data.completed[node.q] == true or (entry ~= nil and entry.complete) then return true end
        local objective = entry and node.gi and entry.objectives[node.gi]
        return objective ~= nil and objective.finished == true
    elseif node.kind == "turnin" then
        return Data.completed[node.q] == true
    end
    return false
end

-- Fills buf with the route's open steps, in order, stopping after `limit` (all when nil).
local function CollectOpen(buf, limit)
    local n = 0
    for _, node in ipairs(SP.Planner.route) do
        if limit and n >= limit then break end
        if not NodeDone(node) then
            n = n + 1
            buf[n] = node
        end
    end
    for i = n + 1, #buf do buf[i] = nil end
    return buf
end

local function OpenNodes()
    return CollectOpen({})
end

local firstOpen, renderOpen, NO_STEPS = {}, {}, {}

function UI.CurrentNode()
    return CollectOpen(firstOpen, 1)[1]
end

UI.OpenNodes = OpenNodes
-- Reusable-buffer form for per-frame callers (the map overlay): buf is cleared and refilled.
UI.OpenNodesInto = CollectOpen
UI.NodeDone = NodeDone

-- Live objective progress from the quest log, for "Kill 3/8"-style steps.
local function Progress(node)
    if not node or node.kind ~= "obj" or not node.gi then return nil end
    local entry = SP.Data.log[node.q]
    local objective = entry and entry.objectives[node.gi]
    if not objective or not objective.numRequired or objective.numRequired <= 1 then return nil end
    return objective.numFulfilled or 0, objective.numRequired
end

-- How far along an objective is: "3/8" from the quest log, or the bag count for an item on a
-- quest not picked up yet. Returns the text and whether it's done.
local function CountText(node)
    if not node or node.kind ~= "obj" then return nil end
    local entry = node.gi and SP.Data.log[node.q]
    local objective = entry and entry.objectives[node.gi]
    if objective and objective.numRequired and objective.numRequired > 0 then
        local have = objective.numFulfilled or 0
        return string.format("%d/%d", have, objective.numRequired), have >= objective.numRequired
    end
    if node.itemId then
        local n = SP.Data.ItemCount(node.itemId)
        if n > 0 then return n .. " in bags", false end
    end
    return nil
end
UI.CountText = CountText

-- Off-course angle -> arrow colour, blending green -> gold -> red.
local function CourseColor(off)
    local t = math.min(1, off / math.pi)
    local a, b, f
    if t < 0.3 then
        a, b, f = C.good, C.warn, t / 0.3
    else
        a, b, f = C.warn, C.bad, math.min(1, (t - 0.3) / 0.4)
    end
    return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f
end

local function LevelETA()
    local stats = SP.Planner.stats
    local level = UnitLevel("player")
    local maxLevel = SP.Data.maxLevel or 60
    if level >= maxLevel or not stats.seconds or stats.seconds <= 0 or (stats.value or 0) <= 0 then return nil end
    local need = UnitXPMax("player") - UnitXP("player")
    if need <= 0 then return nil end
    local seconds = need / (stats.value / stats.seconds)
    -- No "~": WoW's UI font draws it as a raised bar.
    return string.format("Level %d in |cff%s%s|r", level + 1, TEXT_HEX, Style.FormatDuration(seconds))
end

---------------------------------------------------------------------------
-- Search: objects with only a few possible spots (crates, chests). The arrow visits the nearest
-- spot you haven't checked; reaching a spot checks it; after every spot it starts another lap,
-- because looted objects respawn.
---------------------------------------------------------------------------

local SEARCH_REACH = 25 -- yards: close enough to see whether it's there
local SEARCH_DWELL = 1.5 -- seconds near a spot, out of combat, before it counts as checked
local search = { key = nil, checked = {}, count = 0, laps = 0, dwell = {}, found = nil }

local function ResetSearch(key)
    search.key, search.checked, search.count, search.laps, search.dwell, search.found = key, {}, 0, 0, {}, nil
end

local function SearchTarget(node, player)
    local key = NodeKey(node)
    if search.key ~= key then ResetSearch(key) end
    -- You've seen it (hovered it): stay on that spot until it's looted.
    if search.found then return search.found, false end
    local spots, Data = node.spots, SP.Data
    local newlyChecked = false
    local now = GetTime()
    local fighting = InCombatLockdown and InCombatLockdown()
    if player then
        for i, spot in ipairs(spots) do
            if not search.checked[i] then
                local near = Data.Distance(player, spot) <= SEARCH_REACH
                if near and not fighting then
                    -- Only a calm look counts: passing by, or fighting next to it, doesn't.
                    search.dwell[i] = search.dwell[i] or now
                    if now - search.dwell[i] >= SEARCH_DWELL then
                        search.checked[i] = true
                        search.count = search.count + 1
                        newlyChecked = true
                    end
                else
                    search.dwell[i] = nil
                end
            end
        end
    end
    if search.count >= #spots then
        search.checked, search.count, search.laps, search.dwell = {}, 0, search.laps + 1, {}
    end
    local best, bestDistance
    for i, spot in ipairs(spots) do
        if not search.checked[i] then
            local d = player and Data.Distance(player, spot) or 0
            if not bestDistance or d < bestDistance then best, bestDistance = spot, d end
        end
    end
    return best or node.pt, newlyChecked
end

-- The player hovered an object with this name: if it's what the current search step is looking
-- for, lock the search onto the nearest listed spot (or right where they're standing).
function UI.ObjectSeen(name, forNode)
    local node = forNode or currentNode
    if not (node and node.search and node.spots and node.names and node.names[name]) then return end
    local Data = SP.Data
    local player = Data.PlayerPoint()
    if not player then return end
    local key = NodeKey(node)
    if search.key ~= key then ResetSearch(key) end
    local best, bestDistance = nil, 60
    for _, spot in ipairs(node.spots) do
        local d = Data.Distance(player, spot)
        if d < bestDistance then best, bestDistance = spot, d end
    end
    local found = best or player
    if search.found ~= found then
        search.found = found
        UI.Render()
    end
end

-- Start the search over (compass click).
function UI.RestartSearch()
    local node = currentNode
    if node and node.search then
        ResetSearch(NodeKey(node))
        UI.Render()
    end
end

UI.SearchTarget = SearchTarget

-- Hunt: mobs that roam a wide area (kill and drop objectives), and any NPC that walks a path
-- (a named mob, a quest giver on a road). Once you're near any of their spots, the arrow points
-- at the nearest one instead of one fixed spot that might be up a ridge or empty.
local HUNT_RANGE = 400   -- yards
local HUNT_RECHECK = 0.5 -- seconds between nearest-spawn lookups
local HUNT_SEEN = 40     -- yards: spawn spots you've passed this close are swept
local HUNT_RESET = 120   -- seconds: swept spots come back (mobs respawn and wander)
local PATROL_WAIT = 15   -- seconds at the end of a path, out of combat, before saying it isn't there
-- seen, seenCount, lapAt, checked: for a step at an NPC that walks a path, which of its spots
-- you've been to since you came into the area, when the last of them was reached, and whether
-- the panel now says the path was checked. Unlike swept, seen spots don't come back with time
-- (a long path takes longer to walk than HUNT_RESET) and a blocked spot is not a seen one.
local hunt = { key = nil, target = nil, at = -1, waypoint = nil, swept = {}, seen = {}, seenCount = 0, lapAt = nil, checked = false }

local function NewLap()
    hunt.seen, hunt.seenCount, hunt.lapAt = {}, 0, nil
end

-- Spawn spots are where mobs can appear, not where they are now. The arrow sweeps them: once
-- you've passed a spot it moves on to the nearest one you haven't seen lately.
-- Also returns true when "you've been to every spot and it wasn't there" starts or stops holding.
local function HuntTarget(node, player)
    local now, key = GetTime(), NodeKey(node)
    if hunt.key ~= key then
        hunt.waypoint, hunt.swept, hunt.target, hunt.checked = nil, {}, nil, false
        NewLap()
    end
    if hunt.key == key and hunt.target and now - hunt.at < HUNT_RECHECK then return hunt.target end
    local Data, swept, seen, spots = SP.Data, hunt.swept, hunt.seen, node.spots
    local best, bestDistance, fallback, fallbackDistance = nil, HUNT_RANGE, nil, HUNT_RANGE
    for i, spot in ipairs(spots) do
        local d = Data.Distance(player, spot)
        if d <= HUNT_SEEN then
            swept[i] = now
            if not seen[i] then seen[i] = true; hunt.seenCount = hunt.seenCount + 1 end
        end
        if d < HUNT_RANGE then
            local fresh = not swept[i] or now - swept[i] >= HUNT_RESET
            if fresh and d < bestDistance then best, bestDistance = spot, d end
            if d < fallbackDistance then fallback, fallbackDistance = spot, d end
        end
    end
    if not fallback then
        if hunt.seenCount > 0 then NewLap() end -- left the area: coming back is a new look
    elseif hunt.seenCount >= #spots and (not hunt.lapAt or (InCombatLockdown and InCombatLockdown())) then
        hunt.lapAt = now -- the wait runs from the last spot reached, and from the end of a fight there
    end
    local checked = hunt.lapAt ~= nil and now - hunt.lapAt >= PATROL_WAIT
    local changed = checked ~= hunt.checked
    hunt.key, hunt.target, hunt.at, hunt.checked = key, best or fallback or node.pt, now, checked
    return hunt.target, changed
end

-- An NPC that walks a path: say so, and say when its whole path has been walked without the step
-- getting done (it's dead, or someone else got there first), so an empty spot isn't a puzzle.
local function PatrolLine(node, sub)
    local checked = hunt.key == NodeKey(node) and hunt.checked
    return (sub and sub ~= "" and (sub .. "  ·  ") or "") .. (checked and "path checked, it'll be back" or "patrols")
end
UI.PatrolLine = PatrolLine

-- "Drops from Greater Plainstrider, Fleeting Plainstrider" for item drops on hunt steps.
local dropsLines = setmetatable({}, { __mode = "k" }) -- node -> line (or false); sources never change
local BuildDropsLine
local function DropsLine(node)
    local line = dropsLines[node]
    if line == nil then
        line = BuildDropsLine(node) or false
        dropsLines[node] = line
    end
    return line or nil
end
function BuildDropsLine(node)
    if not (node.sources and #node.sources > 0) then return nil end
    local seen, names = {}, {}
    for _, n in ipairs(node.sources) do
        if n and not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
    if #names > 3 then
        return "Drops from " .. table.concat(names, ", ", 1, 3) .. string.format(" and %d more", #names - 3)
    end
    return "Drops from " .. table.concat(names, ", ")
end
UI.HuntTarget = HuntTarget

---------------------------------------------------------------------------
-- Blocked paths
---------------------------------------------------------------------------
-- Moving for a while without getting any closer means the way is blocked. When the arrow follows a
-- walkable way from the terrain, the ground just ahead is marked blocked and another way is found.
-- Otherwise (a straight line) the step moves later, or a hunt gives up on that spawn spot.
local BLOCKED_AFTER = 20 -- seconds of moving without progress
local BLOCKED_GAIN = 15  -- yards closer that counts as progress
local BLOCKED_AWAY = 60  -- yards farther: heading somewhere else (or the long way round), start over
local BLOCKED_NEAR = 60  -- yards: this close you're working the area, not stuck
local BLOCKED_NOTE = 20  -- seconds the panel explains what happened
local BLOCKED_WINDOW = 35 -- the moving has to happen within this long (town errands add up slowly)
local watch = { key = nil, target = nil, anchor = 0, since = 0, moving = 0, last = nil, pos = nil }

local function Reanchor(yards, now)
    watch.anchor, watch.since, watch.moving = yards, now, 0
end
local blockedNote -- { from = UI node key, title = step title, hunt = bool, untilTime = t }

-- Trying to move: the position changed, or the game reports speed (running into a wall).
local function TryingToMove(player)
    local moved = watch.pos ~= nil and SP.Data.Distance(watch.pos, player) > 0.2
    watch.pos = player
    if moved then return true end
    local speed = GetUnitSpeed and GetUnitSpeed("player")
    if speed == nil or (issecretvalue and issecretvalue(speed)) then return false end
    return type(speed) == "number" and speed > 0
end

-- Called on every arrow update; true once when the step looks blocked.
local function WatchProgress(node, player, target, yards)
    local now, key = GetTime(), NodeKey(node)
    local dt = watch.last and (now - watch.last) or 0
    watch.last = now
    local trying = TryingToMove(player)
    if watch.key ~= key or watch.target ~= target then
        watch.key, watch.target = key, target
        Reanchor(yards, now)
        return false
    end
    -- Not a blocked path: travelling far, searching, escorting (the NPC sets the pace and the path),
    -- already in the area, fighting, on a flight path or dead.
    if node.kind == "travel" or node.search or node.scripted or yards < BLOCKED_NEAR or InCombatLockdown()
        or (UnitOnTaxi and UnitOnTaxi("player")) or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) then
        Reanchor(yards, now)
        return false
    end
    if yards <= watch.anchor - BLOCKED_GAIN or yards >= watch.anchor + BLOCKED_AWAY
        or now - watch.since > BLOCKED_WINDOW then
        Reanchor(yards, now)
        return false
    end
    if trying and dt > 0 and dt < 1 then watch.moving = watch.moving + dt end
    if watch.moving < BLOCKED_AFTER then return false end
    Reanchor(yards, now)
    return true
end

local function OnBlocked(node, player, target)
    local now = GetTime()
    if SP.Path and SP.Path.BlockAhead(player, target) then
        blockedNote = { from = NodeKey(node), path = true, untilTime = now + BLOCKED_NOTE }
        UI.Render()
        return
    end
    if node.hunt and node.spots then
        -- Spawn spots out of reach (up a ridge): skip that spot and its neighbours, try the next.
        for i, spot in ipairs(node.spots) do
            if SP.Data.Distance(spot, target) <= 50 then hunt.swept[i] = now end
        end
        hunt.at = -1
        blockedNote = { from = NodeKey(node), hunt = true, untilTime = now + BLOCKED_NOTE }
        UI.Render()
        return
    end
    blockedNote = { from = NodeKey(node), title = node.title or node.text or "it", untilTime = now + BLOCKED_NOTE }
    if SP.Planner.MarkBlocked(node, player) then
        SP.RequestPlan() -- the new plan re-renders the panel
    else
        UI.Render()
    end
end

-- Reached a step that was blocked (found the way round): it can come first again.
local function ClearReachedBlocks(player)
    local blocked = SP.Planner.blocked
    if not blocked or next(blocked) == nil then return end
    for key, b in pairs(blocked) do
        if SP.Data.Distance(player, b.target) < BLOCKED_NEAR then
            blocked[key] = nil
            SP.RequestPlan()
        end
    end
end

-- The panel's note for the current step, while it's fresh.
local function BlockedLine(node)
    if not blockedNote or GetTime() >= blockedNote.untilTime then return nil end
    local here = blockedNote.from == NodeKey(node)
    if blockedNote.path then return here and "That way looks blocked. Finding another." or nil end
    if blockedNote.hunt then return here and "That spot looks out of reach. Trying the next one." or nil end
    if here then return "No straight way there. Look for a path around." end
    return "Couldn't get closer to " .. blockedNote.title .. ". Doing this first."
end

function UI.SearchState()
    return search
end

-- Which spots of this search step have been checked ({ [index] = true }).
function UI.SearchChecked(node)
    return (node and search.key == NodeKey(node)) and search.checked or {}
end

local function SearchLine(node)
    if search.key == NodeKey(node) and search.found then
        return "You spotted it here. Loot it when it's safe."
    end
    local line = string.format("%d possible spots  ·  %d checked", #node.spots, search.key == NodeKey(node) and search.count or 0)
    if search.key == NodeKey(node) and search.laps > 0 then
        line = line .. "  ·  lap " .. (search.laps + 1) .. ", it respawns"
    end
    return line
end

---------------------------------------------------------------------------
-- Waypoint
---------------------------------------------------------------------------

local ownedWaypoint -- { map, x, y } of the waypoint Oldman Java placed, until it is cleared

local function SetWaypoint(node, target)
    if not SP.db.waypoint or not node or not node.pt or node.inBags or node.how == "hearth" then return end
    local pt = target or node.pt
    if pt == lastWaypointPt and lastWaypointKey then return end -- same spot as last call (search/hunt ticks)
    local key = pt.map .. ":" .. pt.x .. ":" .. pt.y
    lastWaypointPt = pt
    if key == lastWaypointKey then return end
    lastWaypointKey = key
    if not (C_Map and C_Map.SetUserWaypoint) then return end
    if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(pt.map) then return end
    local ok, wasSet = pcall(C_Map.SetUserWaypoint, { uiMapID = pt.map, position = SP.Data.Vec(pt.x, pt.y) })
    if ok and wasSet ~= false then
        ownedWaypoint = { map = pt.map, x = pt.x, y = pt.y }
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
        end
    end
end

-- Removes our waypoint, but never one the player has placed since.
local function ClearWaypoint()
    lastWaypointKey, lastWaypointPt = nil, nil
    hunt.waypoint = nil -- a hunt step places its pin again when waypoints come back on
    local own = ownedWaypoint
    ownedWaypoint = nil
    if not own or not (C_Map and C_Map.ClearUserWaypoint) then return end
    local current = C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
    if current and (current.uiMapID ~= own.map or not current.position
        or math.abs(current.position.x - own.x) > 0.0005 or math.abs(current.position.y - own.y) > 0.0005) then
        return
    end
    pcall(C_Map.ClearUserWaypoint)
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

local function SavePosition()
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    SP.db.position = { point, relativePoint, x, y }
end

function UI.SetScale(scale)
    scale = math.max(MIN_SCALE, math.min(MAX_SCALE, scale))
    SP.db.scale = scale
    if frame then
        frame:SetScale(scale)
        SavePosition()
    end
end

function UI.ResetPosition()
    if not frame then return end
    frame:ClearAllPoints()
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -80, 80)
    frame:SetScale(1)
    SP.db.scale = 1
    SavePosition()
    UI.Toggle(true)
end

local function BuildHeader()
    local logo = Style.Logo(frame, 16)
    logo:SetPoint("TOPLEFT", PAD - 2, -10)
    brand = Style.Text(frame, 11, C.accent)
    brand:SetPoint("TOPLEFT", PAD + 18, -14)
    brand:SetText("OLDMAN JAVA")
    brand:SetAlpha(0.9)

    -- Clicking the title collapses the panel to just the current step.
    local toggle = CreateFrame("Button", nil, frame)
    toggle:SetPoint("TOPLEFT", brand, "TOPLEFT", -4, 4)
    toggle:SetPoint("BOTTOMRIGHT", brand, "BOTTOMRIGHT", 12, -4)
    toggle:RegisterForDrag("LeftButton")
    toggle:SetScript("OnDragStart", function() if not SP.db.locked then frame:StartMoving() end end)
    toggle:SetScript("OnDragStop", function() frame:StopMovingOrSizing(); SavePosition() end)
    toggle:SetScript("OnClick", function()
        SP.db.collapsed = not SP.db.collapsed
        UI.Render()
    end)
    toggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText(SP.db.collapsed and "Click to expand" or "Click to collapse", 1, 1, 1)
        GameTooltip:AddLine("Drag the panel to move it. Ctrl + scroll to resize.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    toggle:SetScript("OnLeave", function() GameTooltip:Hide() end)

    etaText = Style.Text(frame, 12, C.muted)
    etaText:SetPoint("TOPRIGHT", -PAD, -13)
    etaText:SetJustifyH("RIGHT")

    -- Controls fade in while the mouse is over the panel.
    controls = CreateFrame("Frame", nil, frame)
    controls:SetSize(1, 22)
    controls:SetPoint("TOPRIGHT", -PAD + 4, -8)
    local settings = Style.Button(controls, "Settings", function()
        if SP.Settings then SP.Settings.Toggle() end
    end, "Difficulty, map overlay, panel size and more")
    settings:SetPoint("TOPRIGHT")
    local replan = Style.Button(controls, "Replan", function()
        SP.Planner.Forget()
        SP.RequestPlan()
    end, "Rebuild the route from scratch")
    replan:SetPoint("RIGHT", settings, "LEFT", -4, 0)
    local skip = Style.Button(controls, "Skip", function() SP.SkipCurrent() end,
        "Skip this quest. /java unskip brings skipped quests back.")
    skip:SetPoint("RIGHT", replan, "LEFT", -4, 0)
    controls.skip = skip
    controls:SetAlpha(0)
    controls:Hide()
end

local function BuildHero()
    local top = -40
    -- Compass: dark disc, faint ring, live arrow.
    compass.frame = CreateFrame("Frame", nil, frame)
    -- Click the compass on a search step to search every spot again; dragging still moves the panel.
    compass.frame:EnableMouse(true)
    compass.frame:RegisterForDrag("LeftButton")
    compass.frame:SetScript("OnDragStart", function() if not SP.db.locked then frame:StartMoving() end end)
    compass.frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing(); SavePosition() end)
    compass.frame:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" and currentNode and currentNode.search then UI.RestartSearch() end
    end)
    compass.frame:SetScript("OnEnter", function(self)
        if not (currentNode and currentNode.search) then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Searching for " .. (currentNode.title or "it"), 1, 1, 1)
        GameTooltip:AddLine("Walk to each spot; hovering the object locks the search onto it.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Click to search every spot again.", 0.86, 0.62, 0.33)
        GameTooltip:Show()
    end)
    compass.frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
    compass.frame:SetSize(COMPASS, COMPASS)
    compass.frame:SetPoint("TOPLEFT", PAD, top)
    compass.disc = compass.frame:CreateTexture(nil, "BACKGROUND")
    compass.disc:SetTexture(Style.MEDIA .. "disc.tga")
    compass.disc:SetAllPoints()
    compass.disc:SetVertexColor(0, 0, 0, 0.45)
    compass.ring = compass.frame:CreateTexture(nil, "BORDER")
    compass.ring:SetTexture(Style.MEDIA .. "ring.tga")
    compass.ring:SetAllPoints()
    compass.ring:SetVertexColor(1, 1, 1, 0.12)
    compass.arrow = compass.frame:CreateTexture(nil, "ARTWORK")
    compass.arrow:SetTexture(Style.MEDIA .. "arrow.tga")
    compass.arrow:SetSize(ARROW, ARROW)
    compass.arrow:SetPoint("CENTER")
    compass.center = Style.Text(compass.frame, 12, C.good)
    compass.center:SetPoint("CENTER")
    compass.center:SetJustifyH("CENTER")
    compass.distance = Style.Text(frame, 14, C.text)
    compass.distance:SetPoint("TOP", compass.frame, "BOTTOM", 0, -6)
    compass.distance:SetJustifyH("CENTER")
    compass.direction = Style.Text(frame, 12, C.muted)
    compass.direction:SetPoint("TOP", compass.distance, "BOTTOM", 0, -2)
    compass.direction:SetJustifyH("CENTER")

    -- Step text column.
    hero.label = Style.Text(frame, 12, C.obj)
    hero.label:SetPoint("TOPLEFT", COLUMN_X, top + 1)
    hero.title = Style.Text(frame, 18, C.text)
    hero.title:SetPoint("TOPLEFT", hero.label, "BOTTOMLEFT", 0, -5)
    hero.title:SetWidth(COLUMN_W)
    hero.title:SetWordWrap(true)
    hero.title:SetMaxLines(2)
    hero.sub = Style.Text(frame, 13, C.muted)
    hero.sub:SetPoint("TOPLEFT", hero.title, "BOTTOMLEFT", 0, -4)
    hero.sub:SetWidth(COLUMN_W)
    hero.sub:SetWordWrap(true)
    hero.sub:SetMaxLines(2)
    hero.bar = Style.Bar(frame, 6, C.obj)
    hero.bar:SetWidth(COLUMN_W - 40)
    hero.count = Style.Text(frame, 12, C.soft)
    hero.count:SetJustifyH("RIGHT")

    -- Soft flash when a step completes.
    hero.flash = Style.Sliced(frame, "ARTWORK", "panel.tga", 16, { 1, 1, 1, 0 }, 7)
    hero.flash:SetPoint("TOPLEFT", 3, -32)
    hero.flash:SetPoint("RIGHT", -3, 0)
    hero.flash:SetHeight(COMPASS + 46)
    hero.flash:SetBlendMode("ADD")
    hero.flash:Hide() -- only exists while the animation runs
    local flash = hero.flash:CreateAnimationGroup()
    if flash.SetToFinalAlpha then flash:SetToFinalAlpha(true) end
    local up = flash:CreateAnimation("Alpha")
    up:SetFromAlpha(0); up:SetToAlpha(0.18); up:SetDuration(0.12); up:SetOrder(1)
    local down = flash:CreateAnimation("Alpha")
    down:SetFromAlpha(0.18); down:SetToAlpha(0); down:SetDuration(0.5); down:SetOrder(2)
    local function Done() hero.flash:SetAlpha(0); hero.flash:Hide() end
    flash:SetScript("OnFinished", Done)
    flash:SetScript("OnStop", Done)
    hero.flashAnim = flash
end

local function BuildList()
    list.divider = frame:CreateTexture(nil, "BORDER")
    list.divider:SetHeight(1)
    list.divider:SetColorTexture(1, 1, 1, 0.06)
    list.header = Style.Text(frame, 11, C.faint)
    list.header:SetText("UP NEXT")
    list.rows = {}
    for i = 1, NEXT_LINES do
        local dot = frame:CreateTexture(nil, "ARTWORK")
        dot:SetTexture(Style.MEDIA .. "disc.tga")
        dot:SetSize(6, 6)
        local text = Style.Text(frame, 14, C.soft)
        text:SetWidth(WIDTH - PAD * 2 - 14)
        local count = Style.Text(frame, 13, C.muted)
        count:SetJustifyH("RIGHT")
        list.rows[i] = { dot = dot, text = text, count = count }
    end
end

local function BuildFooter()
    footer.left = Style.Text(frame, 12, C.muted)
    footer.right = Style.Text(frame, 12, C.muted)
    footer.right:SetJustifyH("RIGHT")
    footer.bar = Style.Bar(frame, 6, C.accent)
    footer.bar:SetWidth(WIDTH - PAD * 2)
    footer.bar:EnableMouse(true)
    footer.bar:SetScript("OnEnter", function(self)
        local xp, maxXP = UnitXP("player"), UnitXPMax("player")
        local stats = SP.Planner.stats
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Experience", 1, 1, 1)
        GameTooltip:AddDoubleLine("This level", string.format("%s / %s", BreakUpLargeNumbers and BreakUpLargeNumbers(xp) or xp,
            BreakUpLargeNumbers and BreakUpLargeNumbers(maxXP) or maxXP), 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddDoubleLine("This route", "+" .. Style.FormatXP(stats.value or 0) .. " XP", 0.7, 0.7, 0.7,
            C.accent[1], C.accent[2], C.accent[3])
        GameTooltip:AddLine("The lighter part of the bar is the XP this route adds.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    footer.bar:SetScript("OnLeave", function() GameTooltip:Hide() end)
    footer.held = Style.Text(frame, 12, C.warn)
    footer.held:SetWidth(WIDTH - PAD * 2)
    footer.held:SetWordWrap(true)
    footer.status = Style.Text(frame, 13, C.muted)
    footer.status:SetWidth(WIDTH - PAD * 2)
    footer.status:SetWordWrap(true)
end

function UI.Create()
    if frame then return end
    frame = CreateFrame("Frame", "OldmanJavaFrame", UIParent)
    frame:SetSize(WIDTH, 160)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) if not SP.db.locked then self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    -- Ctrl + scroll resizes. The wheel is only captured while Ctrl is held, so camera zoom still
    -- works with the mouse over the panel.
    frame:EnableMouseWheel(false)
    frame:RegisterEvent("MODIFIER_STATE_CHANGED")
    frame:SetScript("OnEvent", function(self) self:EnableMouseWheel(IsControlKeyDown()) end)
    frame:SetScript("OnMouseWheel", function(self, delta)
        if not IsControlKeyDown() then return end
        UI.SetScale((SP.db.scale or 1) + delta * 0.05)
        if SP.Settings then SP.Settings.Refresh() end
    end)

    local pos = SP.db.position
    if pos then
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -80, 80)
    end
    frame:SetScale(SP.db.scale or 1)

    Style.Panel(frame)
    BuildHeader()
    BuildHero()
    BuildList()
    BuildFooter()

    UI.SetStatus("Loading...")
    if SP.db.shown then frame:Show() else frame:Hide() end

    C_Timer.NewTicker(0.5, UI.Tick)

    -- Hovering a world object: if it's what a search step is after, lock onto it. Mirrors
    -- Questie's guards: only public (non-secret) tooltip data is read, so combat can't break it.
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
        and Enum.TooltipDataType.Object and type(GameTooltip.GetPrimaryTooltipData) == "function" then
        local function Public(v)
            if issecretvalue and issecretvalue(v) then return false end
            return type(v) == "table" and not (issecrettable and issecrettable(v))
        end
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Object, function(tooltip, data)
            if tooltip ~= GameTooltip or not (currentNode and currentNode.search) then return end
            if not Public(data) or not Public(data.lines) or not Public(data.lines[1]) then return end
            local name = data.lines[1].leftText
            if (issecretvalue and issecretvalue(name)) or type(name) ~= "string" or name == "" then return end
            UI.ObjectSeen(name)
        end)
    end
    local elapsedSince = 0
    frame:SetScript("OnUpdate", function(self, elapsed)
        -- Controls fade in on hover; the level estimate makes room for them.
        local target = (self:IsMouseOver() and SP.ready) and 1 or 0
        if controlsAlpha ~= target then
            controlsAlpha = target > controlsAlpha and math.min(1, controlsAlpha + elapsed * 6)
                or math.max(0, controlsAlpha - elapsed * 6)
            controls:SetShown(controlsAlpha > 0)
            controls:SetAlpha(controlsAlpha)
            etaText:SetAlpha(1 - controlsAlpha)
        end
        elapsedSince = elapsedSince + elapsed
        if elapsedSince < 0.05 then return end
        elapsedSince = 0
        if SP.ready and SP.Data.indexReady then UI.UpdateArrow() end
    end)
end

function UI.Toggle(show)
    if not frame then return end
    if show == nil then show = not frame:IsShown() end
    if show then frame:Show() else frame:Hide() end
    SP.db.shown = show
end

local statusText
function UI.SetStatus(text)
    statusText = text
    UI.Render()
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

-- "Use your Hearthstone" / "Hearthstone ready in 4 min"
local function HearthLine()
    local S = SP.Shortcuts
    local left = S and S.CooldownLeft() or 0
    if left > 1.5 then return "Hearthstone ready in " .. Style.FormatDuration(left) end
    return "Use your Hearthstone"
end

local function ShowHero(node)
    local kindColor = KIND_COLOR[node.kind] or C.accent
    local label = node.label or "STEP"
    if node.class then label = label .. "  |cff" .. Style.Hex(C.class) .. "CLASS|r" end
    hero.label:SetText(label)
    hero.label:SetTextColor(kindColor[1], kindColor[2], kindColor[3])
    hero.title:SetText(node.title or node.text or "")
    local sub = node.sub
    if sub == node.title then sub = nil end
    if node.how == "hearth" then sub = HearthLine() end
    if node.search and node.spots then sub = SearchLine(node) end
    if node.hunt then sub = DropsLine(node) or sub end
    if node.patrol then sub = PatrolLine(node, sub) end
    local note = BlockedLine(node)
    if note then sub = note end
    local subColor = note and C.warn or C.muted
    hero.sub:SetTextColor(subColor[1], subColor[2], subColor[3])
    hero.sub:SetText(sub or "")
    hero.sub:SetShown(sub ~= nil and sub ~= "")

    local y = -40 - hero.label:GetStringHeight() - 5 - hero.title:GetStringHeight()
    if hero.sub:IsShown() then y = y - 4 - hero.sub:GetStringHeight() end

    local have, need = Progress(node)
    if have then
        y = y - 9
        hero.bar:ClearAllPoints()
        hero.bar:SetPoint("TOPLEFT", COLUMN_X, y)
        hero.bar:SetColor(kindColor)
        hero.bar:Show()
        hero.bar:SetValues(have / need)
        hero.count:SetText(have .. "/" .. need)
        hero.count:ClearAllPoints()
        hero.count:SetPoint("LEFT", hero.bar, "RIGHT", 8, 0)
        hero.count:Show()
        y = y - 6
    else
        hero.bar:Hide()
        hero.count:Hide()
    end
    hero.label:Show()
    hero.title:Show()
    compass.frame:Show()
    compass.distance:Show()
    compass.direction:Show()
    -- The column and the compass block (disc + distance + direction) set the height.
    return math.min(y, -40 - COMPASS - 6 - 16 - 2 - 14)
end

local function HideHero()
    hero.label:Hide(); hero.title:Hide(); hero.sub:Hide(); hero.bar:Hide(); hero.count:Hide()
    compass.frame:Hide(); compass.distance:Hide(); compass.direction:Hide()
end

function UI.Render()
    if not frame then return end
    local ready = SP.ready and SP.Data.indexReady
    -- Only the current step and the Up Next rows are shown: stop looking after those.
    local open = ready and CollectOpen(renderOpen, NEXT_LINES + 1) or NO_STEPS
    local node = open[1]

    -- A finished step gets a short flash in its colour before the next one appears.
    local key = NodeKey(node)
    if currentNode and key ~= lastShownKey and NodeDone(currentNode) then
        local c = KIND_COLOR[currentNode.kind] or C.accent
        hero.flashAnim:Stop()
        hero.flash:SetVertexColor(c[1], c[2], c[3], 1)
        hero.flash:SetAlpha(0)
        hero.flash:Show()
        hero.flashAnim:Play()
    end
    lastShownKey = key
    currentNode = node

    etaText:SetText(LevelETA() or "")
    controls.skip:SetShown(node ~= nil and node.q ~= nil)

    local y
    if node then
        y = ShowHero(node)
        -- Search steps aim the waypoint at the next unchecked spot (see UpdateArrow).
        if SP.db.waypoint and not node.search and not node.hunt and not node.patrol then SetWaypoint(node) end
    else
        HideHero()
        y = -40
    end
    -- Waypoints off, no step, or a step with no place (started from the bags): drop our pin.
    if not SP.db.waypoint or not node or node.inBags or node.how == "hearth" then ClearWaypoint() end

    local collapsed = SP.db.collapsed
    -- Up next
    local shownNext = 0
    if not collapsed then
        for i = 1, math.min(NEXT_LINES, SP.db.nextLines or 4) do
            if open[i + 1] then shownNext = i end
        end
    end
    if shownNext > 0 then
        y = y - 12
        list.divider:ClearAllPoints()
        list.divider:SetPoint("TOPLEFT", PAD, y)
        list.divider:SetPoint("TOPRIGHT", -PAD, y)
        list.divider:Show()
        y = y - 10
        list.header:ClearAllPoints()
        list.header:SetPoint("TOPLEFT", PAD, y)
        list.header:Show()
        y = y - list.header:GetStringHeight() - 6
    else
        list.divider:Hide()
        list.header:Hide()
    end
    for i = 1, NEXT_LINES do
        local row, step = list.rows[i], open[i + 1]
        if step and i <= shownNext then
            local c = KIND_COLOR[step.kind] or C.accent
            row.dot:SetVertexColor(c[1], c[2], c[3], 0.95)
            row.dot:ClearAllPoints()
            row.dot:SetPoint("TOPLEFT", PAD + 1, y - 6)
            row.dot:Show()
            -- Count on the right ("1/7", "2 in bags"); the step text gives it room.
            local countText, done = CountText(step)
            local countWidth = 0
            if countText then
                row.count:SetText(countText)
                local cc = done and C.good or C.muted
                row.count:SetTextColor(cc[1], cc[2], cc[3])
                row.count:ClearAllPoints()
                row.count:SetPoint("TOPRIGHT", -PAD, y)
                row.count:Show()
                countWidth = (row.count:GetStringWidth() or 30) + 10
            else
                row.count:Hide()
            end
            row.text:SetText(step.text or "")
            row.text:SetWidth(WIDTH - PAD * 2 - 14 - countWidth)
            row.text:ClearAllPoints()
            row.text:SetPoint("TOPLEFT", PAD + 14, y)
            row.text:SetAlpha(1 - (i - 1) * 0.07) -- later steps recede, but stay readable
            row.text:Show()
            y = y - 21
        else
            row.dot:Hide()
            row.text:Hide()
            row.count:Hide()
        end
    end

    -- Footer: route summary and XP bar.
    local stats = SP.Planner.stats
    if node and not collapsed then
        y = y - 8
        local tooHard = stats.tooHard or 0
        local other = #SP.Planner.deferred - tooHard
        local left = string.format("%d quests  ·  %s XP", stats.quests or 0, Style.FormatXP(stats.value or 0))
        if other > 0 then left = left .. string.format("  ·  %d not routed", other) end

        footer.left:SetText(left)
        footer.left:ClearAllPoints()
        footer.left:SetPoint("TOPLEFT", PAD, y)
        footer.left:Show()
        footer.right:SetText(Style.FormatDuration(stats.seconds or 0))
        footer.right:ClearAllPoints()
        footer.right:SetPoint("TOPRIGHT", -PAD, y)
        footer.right:Show()
        y = y - footer.left:GetStringHeight() - 6
        footer.bar:ClearAllPoints()
        footer.bar:SetPoint("TOPLEFT", PAD, y)
        footer.bar:Show()
        local maxXP = UnitXPMax("player")
        if maxXP and maxXP > 0 then
            local xp = UnitXP("player")
            footer.bar:SetValues(xp / maxXP, (xp + (stats.value or 0)) / maxXP)
        end
        y = y - 6
        if tooHard > 0 then
            y = y - 8
            footer.held:SetText(string.format("%d %s in your log held until you level up", tooHard,
                tooHard == 1 and "quest" or "quests"))
            footer.held:ClearAllPoints()
            footer.held:SetPoint("TOPLEFT", PAD, y)
            footer.held:Show()
            y = y - footer.held:GetStringHeight()
        else
            footer.held:Hide()
        end
    else
        footer.left:Hide(); footer.right:Hide(); footer.bar:Hide(); footer.held:Hide()
    end

    -- Status (loading, errors, empty route)
    local message = statusText or SP.error
    if not message and ready and not node then
        if SP.Planner.version == nil then
            message = "Planning your route..." -- no plan has finished yet (login, instance, combat)
        else
            message = "Nothing left to route here. Try Replan, or /java unskip if you skipped quests."
        end
    end
    if message then
        y = y - 10
        footer.status:SetText(message)
        footer.status:ClearAllPoints()
        footer.status:SetPoint("TOPLEFT", PAD, y)
        footer.status:Show()
        y = y - footer.status:GetStringHeight()
    else
        footer.status:Hide()
    end

    frame:SetHeight(-y + PAD)
    UI.UpdateArrow()
    if SP.Map then SP.Map.Refresh() end
end

function UI.Tick()
    if not frame or not frame:IsShown() then return end
    if not (SP.ready and SP.Data.indexReady) then return end
    if currentNode and NodeDone(currentNode) then
        UI.Render() -- advance to the next open step
    elseif blockedNote and GetTime() >= blockedNote.untilTime then
        blockedNote = nil
        UI.Render() -- the note has said its piece
    end
end

-- How fast the character covers ground right now (yards/second): actual speed while moving,
-- otherwise run speed, or the learned mount speed when mounted.
local RUN_SPEED = 7
local function TravelSpeed()
    local speed = RUN_SPEED
    if IsMounted and IsMounted() and SP.speed and SP.speed > speed then speed = SP.speed end
    local current = GetUnitSpeed and GetUnitSpeed("player")
    if current and not (issecretvalue and issecretvalue(current)) and type(current) == "number" and current > speed then
        speed = current
    end
    return speed
end
UI.TravelSpeed = TravelSpeed

-- Points the arrow at the current step relative to where the character faces.
function UI.UpdateArrow()
    local node = currentNode
    if not frame or not node then return end
    local arrow, center = compass.arrow, compass.center
    local Data = SP.Data
    if node.how == "hearth" then
        local S = SP.Shortcuts
        local left = S and S.CooldownLeft() or 0
        arrow:Hide()
        center:SetText("HS")
        center:SetTextColor(C.travel[1], C.travel[2], C.travel[3])
        center:Show()
        compass.distance:SetText(left > 1.5 and "Not yet" or "Hearth")
        compass.direction:SetText(left > 1.5 and Style.FormatETA(left) or "ready")
        return
    end
    if node.inBags then
        arrow:Hide()
        center:SetText("BAG")
        center:SetTextColor(C.pickup[1], C.pickup[2], C.pickup[3])
        center:Show()
        compass.distance:SetText("In bags")
        compass.direction:SetText("")
        return
    end
    local player = node.pt and Data.PlayerPoint()
    local target = node.pt
    if node.search and node.spots and player then
        local newlyChecked
        target, newlyChecked = SearchTarget(node, player)
        if SP.db.waypoint then SetWaypoint(node, target) end
        if newlyChecked then
            UI.Render() -- refresh "N checked" and the map rings
            return
        end
    end
    if (node.hunt or node.patrol) and node.spots and player then
        local checkedChanged
        target, checkedChanged = HuntTarget(node, player)
        -- Move the map waypoint only when the target really changes, so it doesn't jitter.
        if SP.db.waypoint and (not hunt.waypoint or Data.Distance(hunt.waypoint, target) > 150) then
            hunt.waypoint = target
            SetWaypoint(node, target)
        end
        if checkedChanged and node.patrol then
            UI.Render() -- the line under the title says whether the path has been checked
            return
        end
    end
    local yards = player and Data.Distance(player, target)
    if player then ClearReachedBlocks(player) end
    if not yards then
        arrow:Hide(); center:Hide()
        compass.distance:SetText("")
        compass.direction:SetText("")
        return
    end
    if yards == math.huge then
        arrow:Hide()
        center:SetText("FAR")
        center:SetTextColor(C.travel[1], C.travel[2], C.travel[3])
        center:Show()
        compass.distance:SetText("Other")
        compass.direction:SetText("continent")
        return
    end
    -- On the way to the step, aim at the next corner of the walkable way when there is one.
    local aim, remaining = target, yards
    local corner, along = nil, nil
    if SP.Path then corner, along = SP.Path.Aim(player, target) end
    if corner then aim, remaining = corner, along end
    if WatchProgress(node, player, target, remaining) then
        OnBlocked(node, player, target)
        return
    end
    if yards < 12 then
        arrow:Hide()
        center:SetText("HERE")
        center:SetTextColor(C.good[1], C.good[2], C.good[3])
        center:Show()
        compass.distance:SetText("Arrived")
        compass.direction:SetText("")
        return
    end
    center:Hide()
    local turn = Data.TurnAngle(player, aim)
    if turn then
        arrow:SetRotation(turn)
        local off = math.abs(((turn + math.pi) % (2 * math.pi)) - math.pi)
        arrow:SetVertexColor(CourseColor(off))
        arrow:Show()
    else
        arrow:Hide() -- no facing available (e.g. inside an instance)
    end
    compass.distance:SetText(Style.FormatDistance(remaining))
    -- Direction to walk now and the time to get there, e.g. "NE  ·  39s".
    local eta = Style.FormatETA(remaining / TravelSpeed())
    local compassText = Data.Compass(player, aim)
    compass.direction:SetText(compassText and (compassText .. "  ·  " .. eta) or eta)
end

-- Prints the remaining route with leg distances and compass directions.
function UI.PrintRoute()
    local Data = SP.Data
    local prev = Data.PlayerPoint()
    local open = OpenNodes()
    if #open == 0 then SP.Print("no route yet.") return end
    SP.Print(#open .. " steps:")
    for i, node in ipairs(open) do
        local leg = ""
        if node.inBags then
            leg = "from bags"
        elseif node.how == "hearth" then
            leg = "hearthstone"
        elseif prev and node.pt then
            local yards = Data.Distance(prev, node.pt)
            leg = (yards == math.huge and "other continent" or Style.FormatDistance(yards)) .. " "
                .. (Data.Compass(prev, node.pt) or "")
        end
        local c = KIND_COLOR[node.kind] or C.accent
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %d. |cff%s%s|r %s  |cff999999(%s)|r", i, Style.Hex(c),
            node.label or node.kind, node.title or node.text or "", leg))
        if node.pt and not node.inBags then prev = node.exit or node.pt end
    end
end

function UI.OnPlan()
    statusText = nil
    lastWaypointKey, lastWaypointPt = nil, nil
    UI.Render()
end

function UI.OnCompletedChanged()
    if SP.CompletedList then SP.CompletedList.Refresh() end
end
