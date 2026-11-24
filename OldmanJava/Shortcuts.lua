-- Oldman Java shortcuts: the flight paths you know and your hearthstone. The planner flies a leg when
-- walking to a flight master, flying and walking from the landing beats walking all the way, and
-- hearths once when that saves the most time.
--
-- The flight points you know are learned at a flight master. Flight times start as an estimate from
-- the straight distance and are replaced by the real time of every flight you take. Where your hearthstone takes you is learned while you're in that town (and
-- exactly when you set it or use it).
local _, SP = ...

local Short = {}
SP.Shortcuts = Short

local HEARTHSTONE = 6948
local HEARTH_SPELL = 8690
Short.HEARTH_TIME = 15  -- seconds: the cast and the trip
local FLY_SPEED = 30    -- yards/second along a flight path (about 430% of run speed)
local FLY_DETOUR = 1.2  -- flight paths bend and hop between flight points
local FLY_OVERHEAD = 15 -- talking to the flight master, take-off and landing
local FACTION = { Horde = 1, Alliance = 2 } -- flight point factions; 0 is neutral
local CONTINENTS = { 1414, 1415 }          -- Kalimdor, Eastern Kingdoms
local NEAR_NODE = 150   -- yards: a flight starts or ends at the flight point this close

local net = { gen = 0, list = {}, byC = {}, F = {}, sig = "" }
local EMPTY = {}

function Short.Enabled()
    return SP.db ~= nil and SP.db.shortcuts ~= false
end

---------------------------------------------------------------------------
-- Flight points
---------------------------------------------------------------------------

-- A flight point's place on its zone map (waypoints and the arrow work there), else on the continent.
local function NodePoint(map, x, y)
    local Data = SP.Data
    local zone = C_Map.GetMapInfoAtPosition and C_Map.GetMapInfoAtPosition(map, x, y)
    if zone and zone.mapID and zone.mapID ~= map then
        local c, wx, wy = Data.ToWorld(map, x, y)
        if c and C_Map.GetMapPosFromWorldPos then
            local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, c, Data.Vec(wx, wy), zone.mapID)
            if ok and pos and pos.x and pos.x >= 0 and pos.x <= 1 and pos.y >= 0 and pos.y <= 1 then
                local pt = Data.MakePoint(zone.mapID, pos.x, pos.y)
                if pt then return pt end
            end
        end
    end
    return Data.MakePoint(map, x, y)
end

-- "Crossroads, The Barrens" -> "Crossroads"
local function ShortName(name)
    return (name or ""):match("^([^,]+)") or name
end

local function FlightKey(a, b)
    if a > b then a, b = b, a end
    return a .. ":" .. b
end

-- The flight points this character knows. The game's map data has every flight point, but on
-- this client it doesn't say which you've found (it lists them all as found), so the known ones
-- are learned at the flight master: the flight map marks the ones you can fly to.
local function ReadKnown()
    local found = {}
    if not (C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap) then return found end
    local taxi = SP.char and SP.char.taxi or EMPTY
    local mine = FACTION[UnitFactionGroup and UnitFactionGroup("player") or ""]
    local seen = {}
    for _, map in ipairs(CONTINENTS) do
        local ok, nodes = pcall(C_TaxiMap.GetTaxiNodesForMap, map)
        for _, n in ipairs(ok and nodes or EMPTY) do
            local friendly = n.faction == 0 or n.faction == nil or n.faction == mine
            if n.nodeID and taxi[n.nodeID] and not seen[n.nodeID] and friendly and n.isUndiscovered ~= true and n.position then
                seen[n.nodeID] = true
                local pt = NodePoint(map, n.position.x, n.position.y)
                if pt then found[#found + 1] = { id = n.nodeID, name = n.name, short = ShortName(n.name), pt = pt } end
            end
        end
    end
    table.sort(found, function(a, b) return a.id < b.id end)
    return found
end

local CURRENT, REACHABLE = 0, 1 -- Enum.FlightPathState

-- At a flight master: every flight point it can fly you to is one you know.
local function LearnTaxi()
    if not SP.char then return end
    SP.char.taxi = SP.char.taxi or {}
    local taxi, learned = SP.char.taxi, 0
    if C_TaxiMap and C_TaxiMap.GetAllTaxiNodes then
        for _, map in ipairs(CONTINENTS) do
            local ok, nodes = pcall(C_TaxiMap.GetAllTaxiNodes, map)
            for _, n in ipairs(ok and nodes or EMPTY) do
                if n.nodeID and (n.state == CURRENT or n.state == REACHABLE) then
                    if not taxi[n.nodeID] then learned = learned + 1 end
                    taxi[n.nodeID] = true
                end
            end
        end
    end
    if learned > 0 then SP.RequestPlan() end
end
Short.LearnTaxi = LearnTaxi

-- Seconds from taking off at one flight point to standing at the other, ready to walk.
local function FlightSeconds(a, b)
    local measured = SP.db and SP.db.flights and SP.db.flights[FlightKey(a.id, b.id)]
    if measured then return measured + FLY_OVERHEAD end
    local dx, dy = a.pt.wx - b.pt.wx, a.pt.wy - b.pt.wy
    return (dx * dx + dy * dy) ^ 0.5 * FLY_DETOUR / FLY_SPEED + FLY_OVERHEAD
end

-- Re-reads the known flight points; the planner calls this once per plan.
function Short.Refresh()
    local list = Short.Enabled() and ReadKnown() or {}
    local parts = {}
    for i, n in ipairs(list) do parts[i] = n.id end
    local flights = 0
    for _ in pairs(SP.db and SP.db.flights or EMPTY) do flights = flights + 1 end
    local sig = table.concat(parts, ",") .. "|" .. flights
    if sig == net.sig then return net end
    local byC, F = {}, {}
    for i, n in ipairs(list) do
        local c = n.pt.c
        byC[c] = byC[c] or {}
        byC[c][#byC[c] + 1] = i
        F[i] = {}
    end
    for i, a in ipairs(list) do
        for j, b in ipairs(list) do
            if i ~= j and a.pt.c == b.pt.c then F[i][j] = FlightSeconds(a, b) end
        end
    end
    net = { gen = net.gen + 1, list = list, byC = byC, F = F, sig = sig }
    return net
end

function Short.Known()
    return net.list
end

-- Nearest known flight point on the point's continent: its index and the yards to it.
-- Cached on the point until the known set changes.
local function Access(pt)
    if pt._sg == net.gen then return pt._si, pt._sd end
    local best, bestD
    local list = net.list
    for _, i in ipairs(net.byC[pt.c] or EMPTY) do
        local q = list[i].pt
        local dx, dy = q.wx - pt.wx, q.wy - pt.wy
        local d = (dx * dx + dy * dy) ^ 0.5
        if not bestD or d < bestD then best, bestD = i, d end
    end
    pt._sg, pt._si, pt._sd = net.gen, best, bestD
    return best, bestD
end

-- Seconds to go from a to b by air (walk to a flight master, fly, walk from the landing), and the
-- flight points used; nil when there's no flight to take. speed: walking speed in yards/second.
function Short.Fly(a, b, speed)
    local ia, da = Access(a)
    if not ia then return nil end
    local ib, db = Access(b)
    if not ib or ia == ib then return nil end
    local f = net.F[ia][ib]
    if not f then return nil end
    return (da + db) / speed + f, ia, ib
end

function Short.Node(i)
    return net.list[i]
end

function Short.FlightTime(ia, ib)
    return net.F[ia] and net.F[ia][ib]
end

-- Remembers which flight point a ride started at, and its real duration when it ends.
local ride
local function NearestNode(p)
    if not p then return nil end
    if net.gen == 0 then Short.Refresh() end
    local i, d = Access(p)
    if i and d <= NEAR_NODE then return net.list[i] end
    return nil
end

---------------------------------------------------------------------------
-- Hearthstone
---------------------------------------------------------------------------

local function CooldownLeft()
    local fn = (C_Container and C_Container.GetItemCooldown) or (C_Item and C_Item.GetItemCooldown) or GetItemCooldown
    if not fn then return 0 end
    local ok, start, duration = pcall(fn, HEARTHSTONE)
    if not ok or not start or start == 0 or not duration then return 0 end
    return math.max(0, start + duration - GetTime())
end
Short.CooldownLeft = CooldownLeft

-- Where the hearthstone takes you, learned from the game.
--   "bound":   you just set it, so you're at the innkeeper
--   "arrived": you just hearthed (counts only if you're in that town: a hearth can be interrupted)
--   "visit":   you're in that town; the spot is the average of where you've been there
local function LearnBind(how)
    local name = GetBindLocation and GetBindLocation()
    if not SP.char or not name or name == "" then return end
    local bind = SP.char.bind
    if not bind or bind.name ~= name then
        bind = { name = name }
        SP.char.bind = bind
    end
    local exact = how ~= "visit"
    if bind.exact and not exact then return end
    local here = GetSubZoneText and GetSubZoneText() == name
    -- A city inn is bound to the city's name.
    if not here and how ~= "visit" then here = GetZoneText and GetZoneText() == name end
    if not here then return end
    local p = SP.Data.PlayerPoint()
    if not p then return end
    if exact or bind.map ~= p.map then
        bind.map, bind.x, bind.y, bind.n, bind.exact = p.map, p.x, p.y, 1, exact or nil
        return
    end
    local n = math.min((bind.n or 1) + 1, 600)
    bind.x, bind.y, bind.n = bind.x + (p.x - bind.x) / n, bind.y + (p.y - bind.y) / n, n
end

function Short.HasHearthstone()
    return Short.Enabled() and SP.char ~= nil and SP.Data.ItemCount(HEARTHSTONE) > 0
end

-- Seconds until the hearthstone is ready (the global cooldown doesn't count).
function Short.ReadyIn()
    local left = CooldownLeft()
    return left > 2 and left or 0
end

-- Where your hearthstone is set: { pt, name }, or nil while that isn't known yet.
function Short.Home()
    local bind = SP.char and SP.char.bind
    local name = GetBindLocation and GetBindLocation()
    if not bind or not bind.map or not name or bind.name ~= name then return nil end
    local pt = SP.Data.MakePoint(bind.map, bind.x, bind.y)
    return pt and { pt = pt, name = name } or nil
end

-- { pt, name, readyIn } when the hearthstone can be part of the route, else nil.
function Short.Hearth()
    if not Short.HasHearthstone() then return nil end
    local home = Short.Home()
    if not home then return nil end
    return { pt = home.pt, name = home.name, readyIn = Short.ReadyIn() }
end

-- The names the game gives the place an inn stands in (the town first), for matching your
-- hearthstone's setting and naming the step. Only places you've explored have names here.
function Short.InnPlaces(inn)
    local names = {}
    local explore = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredAreaIDsAtPosition
    if explore then
        local ok, ids = pcall(explore, inn.pt.map, SP.Data.Vec(inn.pt.x, inn.pt.y))
        for _, id in ipairs(ok and ids or EMPTY) do
            local name = SP.Data.AreaName(id)
            if name then names[#names + 1] = name end
        end
    end
    local zone = SP.Data.MapName(inn.pt.map)
    table.sort(names, function(a, b) return (a ~= zone) and b == zone end)
    if zone and #names == 0 then names[1] = zone end
    return names
end

-- Your hearthstone is already set at this inn (by the learned spot, or by the place's name).
function Short.IsHome(inn)
    local home = Short.Home()
    if home and SP.Data.Distance(home.pt, inn.pt) <= 150 then return true end
    local name = GetBindLocation and GetBindLocation()
    for _, place in ipairs(Short.InnPlaces(inn)) do
        if place == name then return true end
    end
    return false
end

Short.lastBound = nil -- GetTime() you last set your hearthstone
Short.lastHearth = nil -- GetTime() of your last hearth
local ARRIVE_AFTER, ARRIVE_GIVE_UP = 3, 30 -- seconds after a hearth: you're at the inn by then
local arriving = false -- hearthed: learn the inn once you're standing there

---------------------------------------------------------------------------
-- Events and the once-a-second check
---------------------------------------------------------------------------

local function OnTick()
    if not (SP.ready and SP.char) then return end
    local onTaxi = UnitOnTaxi and UnitOnTaxi("player")
    if onTaxi then
        if not ride then
            local from = NearestNode(SP.Data.PlayerPoint())
            ride = { t = GetTime(), from = from and from.id }
        end
        return
    end
    if ride then
        local to = NearestNode(SP.Data.PlayerPoint())
        if ride.from and to and to.id ~= ride.from and SP.db then
            SP.db.flights = SP.db.flights or {}
            SP.db.flights[FlightKey(ride.from, to.id)] = math.floor(GetTime() - ride.t + 0.5)
        end
        ride = nil
        SP.RequestPlan() -- plans wait while you fly
        return
    end
    if arriving then
        local since = GetTime() - (Short.lastHearth or 0)
        if since >= ARRIVE_AFTER and SP.Data.PlayerPoint() then
            arriving = false
            LearnBind("arrived")
            SP.RequestPlan()
        elseif since > ARRIVE_GIVE_UP then
            arriving = false
        end
        return
    end
    LearnBind("visit")
end
Short.Tick = OnTick

local events = CreateFrame("Frame")
events:RegisterEvent("HEARTHSTONE_BOUND")
events:RegisterEvent("TAXIMAP_OPENED")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
events:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "TAXIMAP_OPENED" then
        LearnTaxi()
    elseif event == "HEARTHSTONE_BOUND" then
        Short.lastBound = GetTime()
        LearnBind("bound")
        SP.RequestPlan()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" and unit == "player" and spellID == HEARTH_SPELL then
        Short.lastHearth = GetTime()
        arriving = true
    end
end)
Short.events = events
C_Timer.NewTicker(1, OnTick)

-- For /java travel.
function Short.Describe(print)
    if not Short.Enabled() then
        print("flying and hearthing are off (Settings).")
        return
    end
    Short.Refresh()
    local names = {}
    for i, n in ipairs(net.list) do names[i] = n.short end
    print(#names > 0 and (#names .. " flight points known: " .. table.concat(names, ", ") .. ".")
        or "no flight points known yet. Talk to any flight master once and the route learns yours.")
    local flights = 0
    for _ in pairs(SP.db.flights or EMPTY) do flights = flights + 1 end
    if flights > 0 then print(flights .. " flight times measured.") end
    local here = SP.Data.PlayerPoint()
    local inns = 0
    for _, inn in ipairs(SP.Data.inns or EMPTY) do
        if here and inn.pt.c == here.c then inns = inns + 1 end
    end
    print(inns .. " friendly innkeepers on this continent.")
    local check = SP.Planner.BindCheck and SP.Planner.BindCheck(here)
    if check then print(check) end
    local name = GetBindLocation and GetBindLocation()
    local bind = SP.char and SP.char.bind
    local hasStone = SP.Data.ItemCount(HEARTHSTONE) > 0
    if not hasStone then
        print("no hearthstone in your bags.")
    elseif not name or name == "" then
        print("hearthstone isn't set.")
    elseif not (bind and bind.map and bind.name == name) then
        print("hearthstone: " .. name .. ". Walk through " .. name .. " once so the route knows where that is.")
    else
        local left = CooldownLeft()
        print("hearthstone: " .. name .. (bind.exact and "" or " (place estimated)") .. ", "
            .. (left > 0 and ("ready in " .. SP.Style.FormatDuration(left)) or "ready") .. ".")
    end
end
