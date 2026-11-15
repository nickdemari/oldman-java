-- Oldman Java route planner.
--
-- Treats leveling as a prize-collecting tour with pickup -> objectives -> turn-in precedence.
-- Quests are inserted greedily by XP gained per second added to the route, and only kept when
-- they beat a share of the XP/second you would get from just killing mobs. Class quests are
-- must-do and skip that threshold. The result is a heuristic, not a proven optimum.
local _, SP = ...

local Planner = {}
SP.Planner = Planner

local huge, max, min = math.huge, math.max, math.min
local ipairs, pairs = ipairs, pairs

-- Tunables (seconds, yards)
local OTHER_CONTINENT = 900   -- flat cost of a boat/zeppelin trip plus the run around it
local TALK_TIME = 6           -- accepting or turning in at an NPC
local KILL_TIME = 22          -- one kill including recovery
local DROP_RATE = 0.55        -- assumed effective drop rate for item objectives
local LOOT_TIME = 10          -- one object interaction including finding the next
local THRESHOLD = 0.6         -- keep a quest when it beats this share of the grinding XP rate
local ACTIVE_BONUS = 1.5      -- quests already in the log need no slot and no pickup
local CLASS_BONUS = 4         -- class quests: abilities, pets, totems, forms
local STICKY = 1.15           -- keep last plan's quests unless something is clearly better
local MAX_NODES = 70
local NEARBY = 90             -- candidates considered per plan, nearest starters first

Planner.route = {}
Planner.deferred = {}
Planner.stats = { quests = 0, xp = 0, seconds = 0 }
local lastPlanned = {}

-- Wraps the caller's yield so it fires once ~SLICE_MS of work has run, however many steps that
-- took. Count-based yields let one slice run long when each step (a cold Locations) is slow.
local SLICE_MS = 2
local function Pacer(yield)
    if not yield then return nil end
    local clock = debugprofilestop
    if not clock then
        local n = 0
        return function()
            n = n + 1
            if n % 8 == 0 then yield() end
        end
    end
    local last = clock()
    return function()
        if clock() - last >= SLICE_MS then
            yield()
            last = clock()
        end
    end
end

local function Travel(a, b, speed)
    if not a or not b then return 0 end
    if a.c ~= b.c then return OTHER_CONTINENT end
    local dx, dy = a.wx - b.wx, a.wy - b.wy
    return (dx * dx + dy * dy) ^ 0.5 / speed
end
Planner.Travel = Travel

local KIND_FROM_GAME = { monster = "kill", item = "item", object = "object", event = "explore" }
local VERB = { kill = "Kill", item = "Collect", object = "Use", explore = "Explore", event = "" }
local EVENT_TIME = 240 -- escorts, defenses and other scripted events: a few minutes each

local function WorkFor(obj, kind, count, levelDiff)
    local hard = 1 + 0.25 * max(0, levelDiff - 2)    -- orange quests take longer per kill
    -- Mobs 3+ levels below you die in a hit or two.
    if obj and obj.mobLevel and obj.mobLevel > 0 and SP.Data.level - obj.mobLevel >= 3 then hard = hard * 0.6 end
    local work
    if kind == "kill" then
        work = count * KILL_TIME * hard
    elseif kind == "item" then
        if obj and obj.vendor then
            work = 15
        elseif obj and obj.objectsOnly then
            work = count * LOOT_TIME
        else
            work = count * KILL_TIME * hard / DROP_RATE
        end
    elseif kind == "object" then
        work = count * LOOT_TIME
    elseif obj and obj.scripted then
        work = EVENT_TIME
    elseif kind == "explore" then
        work = 5
    else
        work = 45
    end
    -- Sparse spawns mean walking between targets.
    if obj and obj.density and obj.density < count then
        work = work * (1 + min(1, (count - obj.density) / count))
    end
    return work
end

-- Average XP per kill for an objective's mobs (spawn-weighted over its sources; gray mobs give 0).
local function KillXP(obj)
    return (obj and obj.killXP) or SP.Data.MobXP(obj and obj.mobLevel)
end

local function KillsFor(obj, kind, count)
    if kind == "kill" then return count end
    if kind == "item" and obj and not obj.vendor and not obj.objectsOnly then return count / DROP_RATE end
    return 0
end

-- label: short action shown on the panel ("COLLECT"); title: what it applies to; sub: context line.
-- text ("Collect Fungal Spores") is the one-line form used in lists and chat.
local function NewNode(kind, qid, pt, work, label, verb, title, sub)
    return {
        kind = kind, q = qid, pt = pt, work = work,
        label = label, title = title, sub = sub, text = (verb ~= "" and (verb .. " ") or "") .. title,
    }
end

local LABEL = { kill = "KILL", item = "COLLECT", object = "USE", explore = "EXPLORE", event = "DO" }

-- Panel label and verb for an objective. Scripted steps carry their own verb in the title
-- ("Escort Pal'juh out of Kolkar Crag"), so the label says ESCORT or DO and the verb is dropped.
local function LabelFor(kind, scripted, title)
    if scripted then return SP.Data.IsEscortText(title) and "ESCORT" or "DO", "" end
    return LABEL[kind] or "DO", VERB[kind] or "Do"
end

-- "0/4 Fungal Spores" / "Fungal Spores: 0/4" / "Bristleback slain: 0/8" -> the bare objective name.
local function StripCounts(text)
    text = (text or ""):gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", "")
    text = text:gsub("%s+slain$", "")
    return text
end

-- "to Furl Scornbrow  ·  bring Fresh Zhevra Carcass"
local function WithNote(sub, note)
    if not note then return sub end
    return (sub and (sub .. "  ·  ") or "") .. note
end

local function BringNote(loc)
    return loc and loc.bring and ("bring " .. table.concat(loc.bring, ", ")) or nil
end

local function CombinedSpot(loc)
    if not loc or #loc.all == 0 then return nil end
    local spot = SP.Data.Hotspot(loc.all)
    return spot
end


---------------------------------------------------------------------------
-- Turning quests into node sequences
---------------------------------------------------------------------------

-- Nodes for a quest already in the log: its unfinished objectives, then the turn-in.
local function ActiveUnit(qid, entry, ref)
    local Data = SP.Data
    local info = Data.Info(qid)
    local loc = Data.Locations(qid)
    local name = entry.title or Data.QuestName(qid)
    -- Too hard to do solo right now: hold it until the character levels up. Finished quests
    -- still get their turn-in.
    if not entry.complete then
        local questTooHard = entry.level and entry.level - Data.level > Data.MaxAbove()
        local mobsTooHard = loc and loc.mobLevel and loc.mobLevel > Data.MaxMobLevel()
        if questTooHard or mobsTooHard then return nil, "hard" end
    end
    local levelDiff = max((entry.level or Data.level) - Data.level, ((loc and loc.mobLevel) or 0) - Data.level)
    local seq, kills, notes = {}, 0, {} -- kills: XP from the kills the objectives need

    if not entry.complete then
        local used, unmatched, matched = {}, {}, {}
        for gi, gobj in ipairs(entry.objectives) do
            if not gobj.finished then
                local di = Data.MatchObjective(loc, gobj.text, used)
                if di then used[di] = true; matched[gi] = di else unmatched[#unmatched + 1] = gi end
            end
        end
        -- One leftover game objective and one leftover DB objective: pair them up.
        if #unmatched == 1 and loc then
            local free
            for i in ipairs(loc.objectives) do if not used[i] then free = free and -1 or i end end
            if free and free > 0 then matched[unmatched[1]] = free end
        end
        for gi, gobj in ipairs(entry.objectives) do
            if not gobj.finished then
                local di = matched[gi]
                local obj = di and loc.objectives[di] or nil
                local remaining = max(1, (gobj.numRequired or 1) - (gobj.numFulfilled or 0))
                local kind = (obj and obj.kind) or KIND_FROM_GAME[gobj.type] or "other"
                local spot = (obj and obj.spot) or CombinedSpot(loc)
                if spot then
                    local title = (obj and obj.name) or StripCounts(gobj.text)
                    -- Unmatched escort lines ("Escort Pal'juh") still take minutes.
                    local scripted = (obj and obj.scripted) or (not obj and SP.Data.IsEscortText(title))
                    local work = WorkFor(obj or (scripted and { scripted = true }) or nil, kind, remaining, levelDiff)
                    -- Kill XP at the mobs' real level: gray mobs give none.
                    kills = kills + KillsFor(obj, kind, remaining) * KillXP(obj)
                    local label, verb = LabelFor(kind, scripted, title)
                    local node = NewNode("obj", qid, spot, work, label, verb, title, name)
                    node.scripted = scripted or nil
                    node.gi = gi -- game objective index: the panel reads live progress from it
                    node.itemId = obj and obj.itemId
                    if obj and obj.search then
                        node.search, node.spots, node.names, node.label = true, obj.points, obj.names, "SEARCH"
                    elseif obj and (obj.kind == "kill" or (obj.kind == "item" and not obj.vendor and not obj.objectsOnly)) then
                        node.hunt, node.spots, node.sources = true, obj.points, obj.sources
                    end
                    -- Same key as the planned (not yet accepted) version of this objective,
                    -- so accepting a quest doesn't reshuffle the route.
                    node.key = di and ("o" .. di) or ("g" .. gi)
                    seq[#seq + 1] = node
                else
                    notes[#notes + 1] = StripCounts(gobj.text)
                end
            end
        end
        -- Escorts often show no objective lines: the quest isn't done until the event is,
        -- so the event goes before the turn-in.
        if #entry.objectives == 0 and loc then
            for di, obj in ipairs(loc.objectives) do
                if obj.kind == "event" and obj.spot then
                    local label, verb = LabelFor(obj.kind, true, obj.name)
                    local node = NewNode("obj", qid, obj.spot, WorkFor(obj, obj.kind, 1, levelDiff), label, verb, obj.name, name)
                    node.key = "o" .. di
                    node.scripted = true
                    seq[#seq + 1] = node
                end
            end
        end
    end

    local lastPt = seq[#seq] and seq[#seq].pt or ref
    local finisher = loc and Data.Nearest(loc.finishers, lastPt)
    if not finisher then
        if #seq == 0 then return nil end -- nothing we can place on the map
    else
        local finisherName = Data.FinisherName(qid)
        local sub = finisherName and ("to " .. finisherName) or nil
        if #notes > 0 then sub = (sub and (sub .. "  ·  ") or "") .. "also " .. table.concat(notes, ", ") end
        sub = WithNote(sub, BringNote(loc))
        seq[#seq + 1] = NewNode("turnin", qid, finisher, TALK_TIME, "TURN IN", "Turn in", name, sub)
    end

    for _, node in ipairs(seq) do node.class = info and info.classQuest or nil end
    local xp = Data.QuestXP(qid, entry.level)
    return {
        q = qid, seq = seq, active = true, class = info and info.classQuest,
        value = xp + kills, questXP = xp, -- kills holds kill XP
    }
end

-- Can this not-yet-accepted quest be routed solo right now? Returns its locations when it can.
-- Used by the route and by the next-zone picker, so both agree on what counts.
local function Routable(info)
    local Data = SP.Data
    local loc = Data.Locations(info.id)
    if not loc then return nil end
    if not info.classQuest and (loc.elite or #loc.unlocated > 0) then return nil end
    -- Mobs above the difficulty cap make the quest wait, class quests included.
    if loc.mobLevel and loc.mobLevel > Data.MaxMobLevel() then return nil end
    return loc
end

-- Nodes for a quest not yet picked up: pickup, objectives (DB defaults for counts), turn-in.
local function CandidateUnit(info, ref)
    local Data = SP.Data
    local loc = Routable(info)
    if not loc then return nil end

    local start
    if info.itemOnly then
        start = ref -- the starting item is already in the bags
    else
        start = Data.Nearest(loc.starters, ref)
    end
    if not start then return nil end

    local levelDiff = max((info.level > 0 and info.level or Data.level) - Data.level, (loc.mobLevel or 0) - Data.level)
    local seq, kills = {}, 0
    local starter = Data.StarterName(info.id)
    if info.itemOnly then
        seq[1] = NewNode("pickup", info.id, start, TALK_TIME, "START", "Start", info.name, "from an item in your bags")
    else
        seq[1] = NewNode("pickup", info.id, start, TALK_TIME, "ACCEPT", "Accept", info.name, starter and ("from " .. starter) or nil)
    end
    seq[1].inBags = info.itemOnly or nil -- no real location: no waypoint or distance
    seq[1].sub = WithNote(seq[1].sub, BringNote(loc))

    for i, obj in ipairs(loc.objectives) do
        if obj.spot then
            local work = WorkFor(obj, obj.kind, obj.count, levelDiff)
            kills = kills + KillsFor(obj, obj.kind, obj.count) * KillXP(obj)
            local label, verb = LabelFor(obj.kind, obj.scripted, obj.name)
            local node = NewNode("obj", info.id, obj.spot, work, label, verb, obj.name or "objective", info.name)
            node.scripted = obj.scripted
            node.key = "o" .. i
            node.itemId = obj.itemId -- lets the panel show how many you already carry
            if obj.search then
                node.search, node.spots, node.names, node.label = true, obj.points, obj.names, "SEARCH"
            elseif obj.kind == "kill" or (obj.kind == "item" and not obj.vendor and not obj.objectsOnly) then
                node.hunt, node.spots, node.sources = true, obj.points, obj.sources -- mobs roam: the arrow sweeps spawns
            end
            seq[#seq + 1] = node
        end
    end

    local lastPt = seq[#seq].pt
    local finisher = Data.Nearest(loc.finishers, lastPt)
    if not finisher then return nil end
    local finisherName = Data.FinisherName(info.id)
    local sub = finisherName and ("to " .. finisherName) or nil
    if #loc.unlocated > 0 then
        sub = (sub and (sub .. "  ·  ") or "") .. "also " .. table.concat(loc.unlocated, ", ") .. " (no map data)"
    end
    if loc.elite then sub = (sub and (sub .. "  ·  ") or "") .. "group recommended" end
    sub = WithNote(sub, BringNote(loc))
    seq[#seq + 1] = NewNode("turnin", info.id, finisher, TALK_TIME, "TURN IN", "Turn in", info.name, sub)

    for _, node in ipairs(seq) do node.class = info.classQuest or nil end
    local xp = Data.QuestXP(info.id, info.level)
    return {
        q = info.id, seq = seq, active = false, class = info.classQuest,
        value = xp + kills, questXP = xp, -- kills holds kill XP
    }
end

---------------------------------------------------------------------------
-- Insertion with precedence
---------------------------------------------------------------------------

local function PointAt(route, i, start)
    if i == 0 then return start end
    return route[i].pt
end

-- Cheapest position (lo..hi) to insert `node`; it becomes route[pos].
local function BestInsert(route, start, node, lo, hi, speed)
    local n = #route
    hi = min(hi or (n + 1), n + 1)
    local bestPos, bestDelta = nil, huge
    for pos = lo, hi do
        local prev = PointAt(route, pos - 1, start)
        local nxt = route[pos] and route[pos].pt
        local delta = Travel(prev, node.pt, speed)
        if nxt then delta = delta + Travel(node.pt, nxt, speed) - Travel(prev, nxt, speed) end
        if delta < bestDelta then bestPos, bestDelta = pos, delta end
    end
    return bestPos, bestDelta
end

local function IndexOf(route, node)
    for i = 1, #route do if route[i] == node then return i end end
    return nil
end

-- Inserts a quest's nodes into a copy of the route. Returns the new route and the added seconds.
local function InsertUnit(route, start, unit, speed)
    local r = {}
    for i = 1, #route do r[i] = route[i] end
    local added = 0
    local pickup
    for _, node in ipairs(unit.seq) do
        local lo = 1
        if node.kind == "obj" then
            lo = (pickup and IndexOf(r, pickup) or 0) + 1
        elseif node.kind == "turnin" then
            for _, other in ipairs(unit.seq) do
                if other ~= node then
                    local idx = IndexOf(r, other)
                    if idx and idx + 1 > lo then lo = idx + 1 end
                end
            end
        end
        local pos, delta = BestInsert(r, start, node, lo, nil, speed)
        table.insert(r, pos, node)
        added = added + delta + node.work
        if node.kind == "pickup" then pickup = node end
    end
    return r, added
end

-- Scratch tables reused between calls (a pool, so a plan suspended mid-search never shares one).
local evalPool, searchPool = {}, {}

-- Base route for EvalUnit: positions 0 (start) .. n, and the cost of each leg (BE[k]: k-1 -> k).
-- Returns false when a point is missing; the caller then uses InsertUnit.
local function SetBase(E, route, start, speed)
    if not start then return false end
    local n = #route
    local BX, BY, BC, BP, BE = E.BX, E.BY, E.BC, E.BP, E.BE
    BP[0], BX[0], BY[0], BC[0] = start, start.wx, start.wy, start.c
    for k = 1, n do
        local pt = route[k].pt
        if not pt then return false end
        BP[k], BX[k], BY[k], BC[k] = pt, pt.wx, pt.wy, pt.c
        BE[k] = Travel(BP[k - 1], pt, speed)
    end
    E.n = n
    return true
end

-- The seconds InsertUnit would add, without building the new route: the unit's nodes are placed
-- on a virtual route (the base route plus the few nodes placed so far). Visits the same positions
-- in the same order with the same arithmetic, so it returns exactly InsertUnit's `added`.
-- Returns nil if InsertUnit should be used instead.
local function EvalUnit(E, unit, speed)
    local n = E.n
    local BX, BY, BC, BP, BE = E.BX, E.BY, E.BC, E.BP, E.BE
    local insGap, insNode = E.insGap, E.insNode -- placed nodes in route order, and the base leg each sits in
    local m, added, pickup = 0, 0, nil
    local seq = unit.seq
    for si = 1, #seq do
        local node = seq[si]
        local pt = node.pt
        if not pt then return nil end
        local xx, xy, xc = pt.wx, pt.wy, pt.c
        local kind = node.kind
        -- Start right after the pickup (objectives) or after everything placed so far (turn-in).
        -- g: base leg; e: placed node just before the slot (0 = base node g); nextI: next placed node.
        local g, e, nextI = 0, 0, 1
        if kind == "obj" then
            if pickup then
                for k = 1, m do
                    if insNode[k] == pickup then g, e, nextI = insGap[k], k, k + 1; break end
                end
            end
        elseif kind == "turnin" then
            if m > 0 then g, e, nextI = insGap[m], m, m + 1 end
        end
        local dPrev
        if e > 0 then
            dPrev = Travel(insNode[e].pt, pt, speed)
        elseif BC[g] ~= xc then
            dPrev = OTHER_CONTINENT
        else
            local dx, dy = BX[g] - xx, BY[g] - xy
            dPrev = (dx * dx + dy * dy) ^ 0.5 / speed
        end
        local bestDelta, bestG, bestI = huge, nil, nil
        while true do
            if e == 0 and not (nextI <= m and insGap[nextI] == g) then
                -- A run of legs with none of the unit's nodes in them: slots between base nodes.
                local stop = (nextI <= m) and insGap[nextI] or n
                for k = g + 1, stop do
                    local dNext
                    if BC[k] ~= xc then
                        dNext = OTHER_CONTINENT
                    else
                        local dx, dy = BX[k] - xx, BY[k] - xy
                        dNext = (dx * dx + dy * dy) ^ 0.5 / speed
                    end
                    local delta = dPrev + dNext - BE[k]
                    if delta < bestDelta then bestDelta, bestG, bestI = delta, k - 1, nextI end
                    dPrev = dNext
                end
                g = stop
                if nextI > m then
                    -- end of the route
                    if dPrev < bestDelta then bestDelta, bestG, bestI = dPrev, g, nextI end
                    break
                end
            end
            -- Slots next to the unit's placed nodes in leg g.
            while nextI <= m and insGap[nextI] == g do
                local np = insNode[nextI].pt
                local dNext = Travel(pt, np, speed)
                local delta = dPrev + dNext - Travel(e > 0 and insNode[e].pt or BP[g], np, speed)
                if delta < bestDelta then bestDelta, bestG, bestI = delta, g, nextI end
                e, nextI = nextI, nextI + 1
                dPrev = dNext
            end
            if g < n then
                -- from the last placed node of leg g to base node g + 1
                local k = g + 1
                local dNext
                if BC[k] ~= xc then
                    dNext = OTHER_CONTINENT
                else
                    local dx, dy = BX[k] - xx, BY[k] - xy
                    dNext = (dx * dx + dy * dy) ^ 0.5 / speed
                end
                local delta = dPrev + dNext - Travel(insNode[e].pt, BP[k], speed)
                if delta < bestDelta then bestDelta, bestG, bestI = delta, g, nextI end
                g, e = k, 0
                dPrev = dNext
            else
                -- end of the route, after a placed node
                if dPrev < bestDelta then bestDelta, bestG, bestI = dPrev, g, nextI end
                break
            end
        end
        if not bestG then return nil end
        added = added + bestDelta + node.work
        for k = m, bestI, -1 do insGap[k + 1], insNode[k + 1] = insGap[k], insNode[k] end
        insGap[bestI], insNode[bestI] = bestG, node
        m = m + 1
        if kind == "pickup" then pickup = node end
    end
    for k = 1, m do insNode[k] = nil end
    return added
end

-- Allowed insertion positions for a node given the other nodes of its quest.
local function ValidRange(route, node)
    local lo, hi = 1, #route + 1
    for i = 1, #route do
        local other = route[i]
        if other.q == node.q then
            local before = (other.kind == "pickup" and node.kind ~= "pickup")
                or (other.kind == "obj" and node.kind == "turnin")
            local after = (node.kind == "pickup" and other.kind ~= "pickup")
                or (node.kind == "obj" and other.kind == "turnin")
            if before and i + 1 > lo then lo = i + 1 end
            if after and i < hi then hi = i end
        end
    end
    return lo, hi
end

-- Every quest's nodes appear as pickup -> objectives -> turn-in.
local function IsValid(route)
    local seen = {}
    for i = 1, #route do
        local node = route[i]
        if node.q then
            local s = seen[node.q]
            if not s then s = {}; seen[node.q] = s end
            if s.turnin then return false end
            if node.kind == "pickup" then
                if s.obj then return false end
                s.pickup = true
            elseif node.kind == "obj" then
                s.obj = true
            elseif node.kind == "turnin" then
                s.turnin = true
            end
        end
    end
    return true
end
Planner.IsValid = IsValid

local function Reverse(route, i, j)
    while i < j do
        route[i], route[j] = route[j], route[i]
        i, j = i + 1, j - 1
    end
end

-- 2-opt: reverse a stretch of the route when that removes a crossing (open path, fixed start).
local function TwoOpt(route, start, speed, yield)
    local n, improved = #route, false
    for i = 1, n - 1 do
        local prev = PointAt(route, i - 1, start)
        for j = i + 1, n do
            local a, b = route[i].pt, route[j].pt
            local nxt = route[j + 1] and route[j + 1].pt
            local before = Travel(prev, a, speed) + (nxt and Travel(b, nxt, speed) or 0)
            local after = Travel(prev, b, speed) + (nxt and Travel(a, nxt, speed) or 0)
            if after < before - 0.5 then
                Reverse(route, i, j)
                if IsValid(route) then
                    improved = true
                    prev = PointAt(route, i - 1, start)
                else
                    Reverse(route, i, j)
                end
            end
        end
        if yield then yield() end -- the route is consistent between passes over i
    end
    return improved
end

-- Or-opt: move a run of 1-3 consecutive stops to a cheaper spot, keeping quest order legal.
local function OrOpt(route, start, speed, yield)
    local improved = false
    for len = 1, 3 do
        local i = 1
        while i + len - 1 <= #route do
            local n = #route
            local first, last = route[i], route[i + len - 1]
            local prev = PointAt(route, i - 1, start)
            local nxt = route[i + len] and route[i + len].pt
            local removeGain = Travel(prev, first.pt, speed) + (nxt and Travel(last.pt, nxt, speed) or 0)
                - (nxt and Travel(prev, nxt, speed) or 0)
            local segment = {}
            for k = 1, len do segment[k] = table.remove(route, i) end
            local bestPos, bestCost = nil, removeGain - 0.5
            for pos = 1, n - len + 1 do
                if pos ~= i then
                    local p = PointAt(route, pos - 1, start)
                    local q = route[pos] and route[pos].pt
                    local cost = Travel(p, first.pt, speed) + (q and Travel(last.pt, q, speed) or 0)
                        - (q and Travel(p, q, speed) or 0)
                    if cost < bestCost then
                        for k = 1, len do table.insert(route, pos + k - 1, segment[k]) end
                        if IsValid(route) then bestPos, bestCost = pos, cost end
                        for _ = 1, len do table.remove(route, pos) end
                    end
                end
            end
            local at = bestPos or i
            for k = 1, len do table.insert(route, at + k - 1, segment[k]) end
            if bestPos then improved = true end
            i = i + 1
            if yield then yield() end -- the segment is back in the route here
        end
    end
    return improved
end

---------------------------------------------------------------------------
-- The same local search on node ids with a distance matrix. On a legal route (and every move
-- TwoOpt/OrOpt accept keeps it legal) it makes exactly the moves they make, in the same order:
-- legality of a move is decided from the quests it touches instead of rechecking the route.
---------------------------------------------------------------------------

local KIND_CODE = { pickup = 1, obj = 2, turnin = 3 }

-- Reversing ord[i..j] keeps a legal route legal unless some quest has its pickup and one of its
-- objectives inside the stretch, or its turn-in and any other of its nodes. Growing the stretch
-- never makes it legal again, so the scan for this i stops there.
local function TwoOptFast(S, n, W)
    local ord, D, QI, K = S.ord, S.D, S.QI, S.K
    local mark, hp, ho, ht = S.mark, S.hp, S.ho, S.ht
    local improved = false
    for i = 1, n - 1 do
        local pRow = (ord[i - 1] - 1) * W
        local stamp = S.stamp + 1
        S.stamp = stamp
        local id = ord[i]
        local q = QI[id]
        if q > 0 then
            local k = K[id]
            mark[q], hp[q], ho[q], ht[q] = stamp, k == 1, k == 2, k == 3
        end
        for j = i + 1, n do
            local b = ord[j]
            q = QI[b]
            if q > 0 then
                local k = K[b]
                if mark[q] ~= stamp then
                    mark[q], hp[q], ho[q], ht[q] = stamp, k == 1, k == 2, k == 3
                else
                    if k == 1 then hp[q] = true elseif k == 2 then ho[q] = true elseif k == 3 then ht[q] = true end
                    if ht[q] or (hp[q] and ho[q]) then break end
                end
            end
            local a, nx = ord[i], ord[j + 1]
            local before = D[pRow + a] + D[(b - 1) * W + nx]
            local after = D[pRow + b] + D[(a - 1) * W + nx]
            if after < before - 0.5 then
                local x, y = i, j
                while x < y do
                    ord[x], ord[y] = ord[y], ord[x]
                    x, y = x + 1, y - 1
                end
                improved = true
            end
        end
    end
    return improved
end

-- Positions (in the route without the stretch ord[i..i+len-1]) where the stretch may go back.
local function MoveRange(S, n, i, len)
    local ord, QI, K = S.ord, S.QI, S.K
    local mark, hp, ho, ht = S.mark, S.hp, S.ho, S.ht
    local stamp = S.stamp + 1
    S.stamp = stamp
    local any = false
    for k = i, i + len - 1 do
        local id = ord[k]
        local q = QI[id]
        if q > 0 then
            if mark[q] ~= stamp then mark[q], hp[q], ho[q], ht[q] = stamp, false, false, false end
            local kind = K[id]
            if kind == 1 then hp[q] = true elseif kind == 2 then ho[q] = true elseif kind == 3 then ht[q] = true end
            any = true
        end
    end
    local lo, hi = 1, huge
    if not any then return lo, hi end
    local last = i + len - 1
    for k = 1, n do
        if k < i or k > last then
            local id = ord[k]
            local q = QI[id]
            if q > 0 and mark[q] == stamp then
                local r = k < i and k or k - len
                local kind = K[id]
                -- its turn-in stays after the stretch; with the stretch's turn-in everything else stays before
                if kind == 3 and r < hi then hi = r end
                if ht[q] and r + 1 > lo then lo = r + 1 end
                -- objectives stay after the stretch's pickup; the pickup stays before the stretch's objectives
                if kind == 2 and hp[q] and r < hi then hi = r end
                if kind == 1 and ho[q] and r + 1 > lo then lo = r + 1 end
            end
        end
    end
    return lo, hi
end

local function OrOptFast(S, n, W)
    local ord, D = S.ord, S.D
    local improved = false
    for len = 1, 3 do
        local i = 1
        while i + len - 1 <= n do
            local first, last = ord[i], ord[i + len - 1]
            local pRow, lRow = (ord[i - 1] - 1) * W, (last - 1) * W
            local nxt = ord[i + len]
            local removeGain = D[pRow + first] + D[lRow + nxt] - D[pRow + nxt]
            local bestPos, bestCost = nil, removeGain - 0.5
            local lo, hi
            -- Slots before the stretch: neighbours ord[pos - 1], ord[pos].
            for pos = 1, i - 1 do
                local p, q = ord[pos - 1], ord[pos]
                local row = (p - 1) * W
                local cost = D[row + first] + D[lRow + q] - D[row + q]
                if cost < bestCost then
                    if not lo then lo, hi = MoveRange(S, n, i, len) end
                    if pos >= lo and pos <= hi then bestPos, bestCost = pos, cost end
                end
            end
            -- Slots after it: neighbours ord[pos - 1 + len], ord[pos + len] (the end marker past the end).
            for pos = i + 1, n - len + 1 do
                local p, q = ord[pos - 1 + len], ord[pos + len]
                local row = (p - 1) * W
                local cost = D[row + first] + D[lRow + q] - D[row + q]
                if cost < bestCost then
                    if not lo then lo, hi = MoveRange(S, n, i, len) end
                    if pos >= lo and pos <= hi then bestPos, bestCost = pos, cost end
                end
            end
            if bestPos then
                local s1, s2, s3 = ord[i], ord[i + 1], ord[i + 2]
                if bestPos < i then
                    for k = i - 1, bestPos, -1 do ord[k + len] = ord[k] end
                else
                    for k = i, bestPos - 1 do ord[k] = ord[k + len] end
                end
                ord[bestPos] = s1
                if len > 1 then ord[bestPos + 1] = s2 end
                if len > 2 then ord[bestPos + 2] = s3 end
                improved = true
            end
            i = i + 1
        end
    end
    return improved
end

local function WriteBack(route, S, n)
    local ord, nodes = S.ord, S.nodes
    for i = 1, n do route[i] = nodes[ord[i]] end
end

-- Ids: 1 = start, 2..n+1 = route nodes, n+2 = end of route (zero cost to everything).
local function OptimizeFast(route, start, speed, yield)
    local n = #route
    local S = table.remove(searchPool) or { D = {}, P = {}, QI = {}, K = {}, ord = {}, nodes = {},
        mark = {}, hp = {}, ho = {}, ht = {}, stamp = 0 }
    local W = n + 2
    local P, QI, K, ord, nodes, D = S.P, S.QI, S.K, S.ord, S.nodes, S.D
    local questIndex, quests = {}, 0
    P[1], QI[1], K[1], ord[0] = start, 0, 0, 1
    for i = 1, n do
        local node, id = route[i], i + 1
        nodes[id], P[id], ord[i] = node, node.pt, id
        local q = node.q
        if q then
            local qi = questIndex[q]
            if not qi then quests = quests + 1; qi = quests; questIndex[q] = qi end
            QI[id] = qi
        else
            QI[id] = 0
        end
        K[id] = KIND_CODE[node.kind] or 0
    end
    ord[n + 1] = W
    for a = 1, W do
        local row = (a - 1) * W
        for b = 1, W do
            if a == W or b == W then
                D[row + b] = 0
            elseif b < a then
                D[row + b] = D[(b - 1) * W + a]
            else
                D[row + b] = Travel(P[a], P[b], speed)
            end
        end
    end
    for _ = 1, 8 do
        local a = TwoOptFast(S, n, W)
        if yield then WriteBack(route, S, n); yield() end
        local b = OrOptFast(S, n, W)
        if yield then WriteBack(route, S, n); yield() end
        if not a and not b then break end
    end
    WriteBack(route, S, n)
    for i = 1, W do nodes[i], P[i] = nil, nil end
    searchPool[#searchPool + 1] = S
end

-- Local search until the route stops getting shorter.
local function Optimize(route, start, speed, yield)
    if IsValid(route) then return OptimizeFast(route, start, speed, yield) end
    for _ = 1, 8 do
        local a = TwoOpt(route, start, speed, yield)
        if yield then yield() end
        local b = OrOpt(route, start, speed, yield)
        if yield then yield() end
        if not a and not b then break end
    end
end
Planner.Optimize = Optimize

function Planner.RouteSeconds(route, start, speed)
    local total, prev = 0, start
    for _, node in ipairs(route) do
        total = total + Travel(prev, node.pt, speed) + node.work
        prev = node.pt
    end
    return total
end

---------------------------------------------------------------------------
-- Stability: keep the order the player has already seen unless a reshuffle saves real time.
---------------------------------------------------------------------------

local prevRank -- node key -> position in the previous plan

local function NodeKey(node)
    return node.kind .. ":" .. tostring(node.q or 0) .. ":" .. tostring(node.key or "")
end

local function RememberOrder(route)
    prevRank = {}
    for i, node in ipairs(route) do prevRank[NodeKey(node)] = i end
end

---------------------------------------------------------------------------
-- Blocked steps: the UI saw the player moving without getting closer (a cliff, a ridge)
---------------------------------------------------------------------------

local BLOCK_RADIUS = 250 -- yards from where it happened; farther away the straight line is a different one
local BLOCK_TTL = 900    -- seconds

Planner.blocked = {} -- planner node key -> { at = player point, target = step point, time = GetTime() }

-- Returns false when the step is already marked (no replan needed).
function Planner.MarkBlocked(node, at)
    local key = NodeKey(node)
    if Planner.blocked[key] then return false end
    Planner.blocked[key] = { at = at, target = node.pt, time = GetTime() }
    return true
end

function Planner.IsBlocked(node)
    return node ~= nil and Planner.blocked[NodeKey(node)] ~= nil
end

-- If the first step is blocked, do the nearest step of another quest first.
local function AvoidBlocked(route, start)
    local Data, now = SP.Data, GetTime()
    for key, b in pairs(Planner.blocked) do
        if now - b.time > BLOCK_TTL or Data.Distance(b.at, start) > BLOCK_RADIUS then Planner.blocked[key] = nil end
    end
    if next(Planner.blocked) == nil then return route end
    local first
    for i, node in ipairs(route) do
        if node.kind ~= "travel" then first = i; break end
    end
    local blockedNode = first and route[first]
    if not blockedNode or not Planner.blocked[NodeKey(blockedNode)] then return route end
    local between = {} -- quests with a step between the blocked one and the candidate
    for k = first + 1, #route do
        local node = route[k]
        if node.q and node.q ~= blockedNode.q and node.kind ~= "travel" and not between[node.q]
            and not Planner.blocked[NodeKey(node)] then
            local moved = {}
            for i = 1, first - 1 do moved[#moved + 1] = route[i] end
            moved[#moved + 1] = node
            for i = first, #route do
                if i ~= k then moved[#moved + 1] = route[i] end
            end
            if IsValid(moved) then return moved end
        end
        if node.q then between[node.q] = true end
    end
    return route
end

local RESHUFFLE_GAIN = 1.25 -- a from-scratch plan must earn 25% more XP per minute to replace the current one

-- Rebuilds the previous plan from today's units, in the order the player has already seen.
-- Units the previous plan contained keep their place; their new nodes (if any) are slotted in.
local function SeedRoute(units, start, speed, slots)
    if not prevRank then return nil end
    -- Pickups the previous plan contained, earliest first: if the log has fewer free slots now
    -- (a quest accepted off-route), keep only as many as fit, the ones the player reaches first.
    local pickups, keep = {}, {}
    for _, unit in ipairs(units) do
        if unit.active then
            for _, node in ipairs(unit.seq) do
                if prevRank[NodeKey(node)] then keep[unit] = true break end
            end
        else
            local rank = unit.seq[1] and prevRank[NodeKey(unit.seq[1])]
            if rank then pickups[#pickups + 1] = { unit = unit, rank = rank } end
        end
    end
    table.sort(pickups, function(a, b) return a.rank < b.rank end)
    for i = 1, min(#pickups, slots) do keep[pickups[i].unit] = true end

    local ranked, pending, placed, slotsUsed = {}, {}, {}, 0
    for _, unit in ipairs(units) do
        if keep[unit] then
            placed[unit] = true
            if not unit.active then slotsUsed = slotsUsed + 1 end
            for _, node in ipairs(unit.seq) do
                local rank = prevRank[NodeKey(node)]
                if rank then ranked[#ranked + 1] = { node = node, rank = rank } else pending[#pending + 1] = node end
            end
        end
    end
    if #ranked == 0 then return nil end
    table.sort(ranked, function(a, b) return a.rank < b.rank end)
    local route = {}
    for i, entry in ipairs(ranked) do route[i] = entry.node end
    for _, node in ipairs(pending) do
        local lo, hi = ValidRange(route, node)
        if lo > hi then return nil end
        local pos = BestInsert(route, start, node, lo, hi, speed)
        if not pos then return nil end
        table.insert(route, pos, node)
    end
    if not IsValid(route) then return nil end
    return route, placed, slotsUsed
end

local function PlanRate(route, placed, start, speed)
    local value = 0
    for unit in pairs(placed) do value = value + unit.value end
    return value / max(Planner.RouteSeconds(route, start, speed), 1)
end

-- Mutually exclusive quests: once q is planned, its exclusiveTo partners can't be.
local function BlockExclusive(blocked, q)
    local info = SP.Data.Info(q)
    if info and type(info.exclusive) == "table" then
        for _, other in ipairs(info.exclusive) do blocked[other] = true end
    end
end

-- noFloor: take the best quests even when they're slower than grinding (nothing better anywhere).
local function Construct(units, start, speed, slots, yield, seedRoute, seedPlaced, noFloor)
    local Data = SP.Data
    local route, placed, blocked = {}, {}, {}
    if seedRoute then
        for i, node in ipairs(seedRoute) do route[i] = node end
        for unit in pairs(seedPlaced) do
            placed[unit] = true
            BlockExclusive(blocked, unit.q)
        end
    end
    local grindRate = Data.MobXP() / KILL_TIME
    local classOn = SP.db.classQuests ~= false
    local E = table.remove(evalPool) or { BX = {}, BY = {}, BC = {}, BP = {}, BE = {}, insGap = {}, insNode = {} }
    while #route < MAX_NODES do
        local best, bestRoute, bestRatio, bestAdded
        local must, mustRoute, mustRatio -- best class quest on this continent: must-do, skips the threshold
        -- Units are scored without copying the route; only the winner's route is built.
        local fast = SetBase(E, route, start, speed)
        for _, unit in ipairs(units) do
            if not placed[unit] and (unit.active or (slots > 0 and not blocked[unit.q])) then
                local r, added
                if fast then added = EvalUnit(E, unit, speed) end
                if not added then r, added = InsertUnit(route, start, unit, speed) end
                local ratio = unit.value / max(added, 1)
                if unit.active then ratio = ratio * ACTIVE_BONUS end
                if unit.class and classOn then ratio = ratio * CLASS_BONUS end
                if lastPlanned[unit.q] then ratio = ratio * STICKY end
                if not bestRatio or ratio > bestRatio then
                    best, bestRoute, bestRatio, bestAdded = unit, r, ratio, added
                end
                if unit.class and classOn and unit.seq[1] and unit.seq[1].pt.c == start.c
                    and (not mustRatio or ratio > mustRatio) then
                    must, mustRoute, mustRatio = unit, r, ratio
                end
                if yield then yield() end
            end
        end
        if not best then break end
        if not noFloor and bestRatio < grindRate * THRESHOLD then
            -- Nothing beats grinding any more, but class quests are still worth doing.
            if not must then break end
            best, bestRoute = must, mustRoute
        end
        if #route + #best.seq > MAX_NODES then break end
        route = bestRoute or InsertUnit(route, start, best, speed)
        placed[best] = true
        BlockExclusive(blocked, best.q)
        if not best.active then slots = slots - 1 end
    end
    for k = 0, E.n or 0 do E.BP[k] = nil end
    evalPool[#evalPool + 1] = E
    Optimize(route, start, speed, yield)
    return route, placed
end

-- A fresh plan, or the previous order extended, whichever is clearly better (keeps the route steady).
local function Choose(units, start, speed, slots, yield, noFloor)
    local route, placed = Construct(units, start, speed, slots, yield, nil, nil, noFloor)
    local seedRoute, seedPlaced, seedSlots = SeedRoute(units, start, speed, slots)
    if not seedRoute then return route, placed, "new" end
    local kept, keptPlaced = Construct(units, start, speed, max(0, slots - seedSlots), yield, seedRoute, seedPlaced, noFloor)
    if #kept > 0 and PlanRate(route, placed, start, speed) < PlanRate(kept, keptPlaced, start, speed) * RESHUFFLE_GAIN then
        return kept, keptPlaced, "kept"
    end
    return route, placed, "fresh"
end

local function CollectCandidates(start, skipped, nearbyOnly, yield)
    local Data = SP.Data
    local list = {}
    local scanned = 0
    -- Only quests that are not blocked for this character (Data.IsAvailable rejects the rest);
    -- completed and logged ones are skipped here without the call.
    local open = Data.OpenInfo()
    for k = 1, #open do
        local info = open[k]
        local id = info.id
        scanned = scanned + 1
        if yield and scanned % 25 == 0 then yield() end -- the pacer decides when it really yields
        if not Data.completed[id] and not Data.log[id] and Data.IsAvailable(info, skipped) then
            local d
            if info.itemOnly then
                d = 0
            else
                local sp = Data.Nearest(Data.StarterPoints(id), start)
                d = sp and Data.Distance(sp, start) or huge
                if d == huge and sp and not nearbyOnly then d = 1e6 + Travel(start, sp, 1) end
            end
            if d < huge then list[#list + 1] = { info = info, d = d } end
        end
    end
    table.sort(list, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return a.info.id < b.info.id
    end)
    return list
end

-- Builds a route from the current state. `state` = { player, speed, skipped, maxQuests }.
-- `yield` (optional) is called periodically so the caller can spread work over frames.
function Planner.Build(state, yield)
    local Data = SP.Data
    yield = Pacer(yield)
    local start = state.player
    local speed = max(state.speed or 7, 1)
    local log = Data.log
    local units = {}
    local deferred = {}
    local tooHard = 0

    -- Yields sit between the pcalls (Lua 5.1 cannot yield across one); a cold quest reads its
    -- locations from QuestieDB, so a few at a time.
    for qid, entry in pairs(log) do
        local ok, unit, why = false, nil, nil
        if not (state.skipped and state.skipped[qid]) then
            ok, unit, why = pcall(ActiveUnit, qid, entry, start)
        end
        if ok and unit and #unit.seq > 0 then
            units[#units + 1] = unit
        else
            deferred[#deferred + 1] = qid
            if ok and why == "hard" then tooHard = tooHard + 1 end
        end
        if yield then yield() end
    end
    if yield then yield() end

    local candidates = CollectCandidates(start, state.skipped, true, yield)
    if yield then yield() end
    local taken = 0
    for _, c in ipairs(candidates) do
        if taken >= NEARBY then break end
        local ok, unit = pcall(CandidateUnit, c.info, start)
        if ok and unit then
            units[#units + 1] = unit
            taken = taken + 1
        end
        if yield then yield() end
    end

    local slots = max(0, (state.maxQuests or 20) - Data.logCount)
    local route, placed
    route, placed, Planner.lastChoice = Choose(units, start, speed, slots, yield)

    -- No new quest here is worth it: head for a better hub if one is worth the trip,
    -- otherwise take the best of what's here (rather than an empty panel).
    local placedNew = 0
    for unit in pairs(placed) do if not unit.active then placedNew = placedNew + 1 end end
    -- With a full log there is nothing new to add, so this is skipped.
    if placedNew == 0 and slots > 0 then
        local hub = Planner.BestHub(start, state.skipped, yield)
        local hubRoute, hubPlaced
        if hub then
            local hubUnits = {}
            for _, info in ipairs(hub.infos) do
                local ok, unit = pcall(CandidateUnit, info, hub.point)
                if ok and unit then hubUnits[#hubUnits + 1] = unit end
                if yield then yield() end
            end
            hubRoute, hubPlaced = Construct(hubUnits, hub.point, speed, slots, yield)
            if next(hubPlaced) == nil then hub = nil end
        end
        if not hub then
            if #units > 0 then route, placed, Planner.lastChoice = Choose(units, start, speed, slots, yield, true) end
        elseif #route <= 2 then
            -- Finish what is left here (turn-ins) before leaving, then travel, then the new hub.
            route[#route + 1] = NewNode("travel", nil, hub.point, 0, "TRAVEL", "Travel to", hub.name or "the next zone",
                hub.count .. " quests at your level")
            for _, node in ipairs(hubRoute) do route[#route + 1] = node end
            for unit in pairs(hubPlaced) do placed[unit] = true end
        end
    end

    route = AvoidBlocked(route, start)

    -- Active quests that did not make the cut are listed separately.
    for _, unit in ipairs(units) do
        if unit.active and not placed[unit] then deferred[#deferred + 1] = unit.q end
    end

    local xp, value, quests = 0, 0, 0
    lastPlanned = {}
    for unit in pairs(placed) do
        xp = xp + unit.questXP
        value = value + unit.value
        quests = quests + 1
        lastPlanned[unit.q] = true
    end
    local seconds = Planner.RouteSeconds(route, start, speed)

    RememberOrder(route)
    Planner.version = (Planner.version or 0) + 1 -- lets the map overlay know its cache is stale
    Planner.route = route
    Planner.deferred = deferred
    -- value includes XP from the mobs killed along the way; it drives the level-up estimate.
    Planner.stats = { quests = quests, xp = xp, value = value, seconds = seconds, candidates = #candidates,
        tooHard = tooHard }
    return route
end

-- Best place to go when nothing nearby is worth it: map with the most available XP per travel time.
function Planner.BestHub(start, skipped, yield)
    local Data = SP.Data
    local byMap = {}
    for _, c in ipairs(CollectCandidates(start, skipped, false, yield)) do
        local info = c.info
        if yield then yield() end
        if not info.itemOnly and Routable(info) then
            local sp = Data.Nearest(Data.StarterPoints(info.id), start)
            if sp then
                local hub = byMap[sp.map]
                if not hub then
                    hub = { map = sp.map, infos = {}, xp = 0, count = 0, point = sp }
                    byMap[sp.map] = hub
                end
                hub.infos[#hub.infos + 1] = info
                hub.count = hub.count + 1
                hub.xp = hub.xp + Data.QuestXP(info.id, info.level)
            end
        end
    end
    local best, bestScore
    for _, hub in pairs(byMap) do
        -- Hub point: the densest starter cluster on that map.
        local points = {}
        for _, info in ipairs(hub.infos) do
            local sp = Data.Nearest(Data.StarterPoints(info.id), start)
            if sp then points[#points + 1] = sp end
        end
        hub.point = Data.Hotspot(points) or hub.point
        local score = hub.xp / (Travel(start, hub.point, 7) + 600)
        if not bestScore or score > bestScore then best, bestScore = hub, score end
    end
    if best then best.name = Data.MapName(best.map) end
    return best
end

-- Clears plan memory (used when the user skips or resets).
function Planner.Forget()
    lastPlanned = {}
    prevRank = nil
    Planner.blocked = {} -- a fresh route starts without blocks
end
