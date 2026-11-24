-- Oldman Java walkable paths: the arrow's way to the current step and the route line on the map,
-- worked out over the terrain (Terrain.lua) in the background, one search at a time.
--
-- Anything the terrain can't help with goes straight, as before: no terrain for the continent, legs
-- under MIN_LEG or over MAX_LEG, no walkable way found, or a way so much longer than the straight line
-- that it's more likely missing a bridge or a tunnel (buildings and other models aren't in the data).
local _, SP = ...

local Path = {}
SP.Path = Path

local MIN_LEG = 100      -- yards: shorter legs go straight
local MAX_LEG = 2500     -- yards: longer legs go straight
local MAX_EXTRA = 400    -- a way is used when it adds at most this many yards, or when it is at most
local MAX_RATIO = 1.6    -- MAX_RATIO times the straight line and adds at most LONG_EXTRA
local LONG_EXTRA = 800
local RETARGET = 50      -- yards the target may move before the way is worked out again
local OFF_PATH = 30      -- yards off the way before it's worked out again from where you are
local REPATH_GAP = 2     -- seconds between those re-workings
local RETRY_MOVED = 60   -- yards moved before trying again when no way was found (you may have been
                         -- standing somewhere the data calls too steep)
local REACHED = 10       -- yards: close enough to a corner to aim at the next one
local LOOK_EVERY = 0.25  -- seconds between checks for a straight shot at the next corner
local MAX_BLOCKS = 3     -- blocked spots marked on one leg before giving up on finding a way
local MAX_STATIC = 40    -- route legs kept

local Terrain = SP.Terrain
local sqrt, floor, huge = math.sqrt, math.floor, math.huge

local queue = {}         -- searches waiting, current leg first: { c, ax, ay, bx, by, done = fn }
local busy = false
local static, staticCount = {}, 0 -- [key] = path table | false (straight) | true (being worked out)
local leg = {}           -- the arrow's leg: target, path, next corner, ...

local function Dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

local function Usable(path, straight)
    if not path then return false end
    local extra = path.length - straight
    return extra <= MAX_EXTRA or (path.length <= straight * MAX_RATIO and extra <= LONG_EXTRA)
end
Path.Usable = Usable

local Pump
local function Finish(req, result)
    busy = false
    local ok, err = pcall(req.done, result)
    if not ok and geterrorhandler then geterrorhandler()(err) end
    Pump()
end

function Pump()
    if busy or not queue[1] or not SP.AddJob then return end
    busy = true
    local req = table.remove(queue, 1)
    local result
    -- One search per job: a plan queued meanwhile runs before the next search.
    SP.AddJob(function()
        result = Terrain.FindPath(req.c, req.ax, req.ay, req.bx, req.by, coroutine.yield)
    end, function() Finish(req, result) end, function() Finish(req, nil) end, "path")
end

-- forLeg: the arrow's leg, which goes first and replaces any older leg search still waiting.
local function Request(c, ax, ay, bx, by, done, forLeg)
    local req = { c = c, ax = ax, ay = ay, bx = bx, by = by, done = done, forLeg = forLeg }
    if forLeg then
        for i = #queue, 1, -1 do
            if queue[i].forLeg then table.remove(queue, i) end
        end
        table.insert(queue, 1, req)
    else
        queue[#queue + 1] = req
    end
    Pump()
end

-- Same continent, terrain there, and a length worth a search.
local function Pathable(a, b)
    if not (a and b) or a.c ~= b.c or not Terrain.Has(a.c) then return false end
    local d = Dist(a.wx, a.wy, b.wx, b.wy)
    return d >= MIN_LEG and d <= MAX_LEG, d
end

---------------------------------------------------------------------------
-- The arrow's leg
---------------------------------------------------------------------------

local function Suffix(points)
    local suffix = { [#points] = 0 }
    for i = #points - 1, 1, -1 do
        local p, q = points[i], points[i + 1]
        suffix[i] = suffix[i + 1] + Dist(p.wx, p.wy, q.wx, q.wy)
    end
    return suffix
end

local function StartLeg(player, target, straight, keepBlocks)
    local id = (leg.id or 0) + 1
    local blocks = keepBlocks and leg.blocks or 0
    leg = { id = id, c = target.c, tx = target.wx, ty = target.wy, pending = true, blocks = blocks,
        started = GetTime(), fx = player.wx, fy = player.wy }
    Request(player.c, player.wx, player.wy, target.wx, target.wy, function(path)
        if leg.id ~= id then return end -- a newer leg replaced this one
        leg.pending = false
        if Usable(path, straight) then
            leg.path, leg.k, leg.suffix, leg.lookAt = path, 2, Suffix(path.points), 0
        else
            leg.path = false
        end
        if SP.Map then SP.Map.Refresh() end
    end, true)
end

-- Distance from p to the segment a-b, and how far along it p's closest point is (0-1).
local function ToSegment(px, py, a, b)
    local ex, ey = b.wx - a.wx, b.wy - a.wy
    local len2 = ex * ex + ey * ey
    local t = len2 > 0 and ((px - a.wx) * ex + (py - a.wy) * ey) / len2 or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return Dist(px, py, a.wx + ex * t, a.wy + ey * t), t
end

-- Where the arrow should point on the way to target, and the yards left along the way.
-- nil: go straight (no way worked out, or none needed).
function Path.Aim(player, target)
    if UnitOnTaxi and UnitOnTaxi("player") then return nil end -- flying: the ground doesn't matter
    local pathable, straight = Pathable(player, target)
    if not pathable then
        if leg.tx and not (target and leg.c == target.c and Dist(leg.tx, leg.ty, target.wx, target.wy) <= RETARGET) then
            leg = { id = (leg.id or 0) + 1 } -- a new target that goes straight: drop the old way
        end
        return nil
    end
    if leg.c ~= target.c or not leg.tx or Dist(leg.tx, leg.ty, target.wx, target.wy) > RETARGET then
        StartLeg(player, target, straight)
        return nil
    end
    local path = leg.path
    local now = GetTime()
    if path == false and Dist(player.wx, player.wy, leg.fx, leg.fy) > RETRY_MOVED and now - leg.started >= REPATH_GAP then
        StartLeg(player, target, straight, true)
        return nil
    end
    if not path then return nil end
    local points, k = path.points, leg.k
    local px, py = player.wx, player.wy
    while k < #points and Dist(px, py, points[k].wx, points[k].wy) < REACHED do k = k + 1 end
    if k < #points and now - leg.lookAt >= LOOK_EVERY then
        leg.lookAt = now
        -- Cut the corner when the line to the one after is open and costs no more than going round it:
        -- a shortcut across water can take longer than walking the shore.
        local cur, nxt = points[k], points[k + 1]
        local direct = Terrain.Cost(player.c, px, py, nxt.wx, nxt.wy)
        if direct then
            local a = Terrain.Cost(player.c, px, py, cur.wx, cur.wy)
            local b = Terrain.Cost(player.c, cur.wx, cur.wy, nxt.wx, nxt.wy)
            if not (a and b) or direct <= a + b then k = k + 1 end
        end
    end
    leg.k = k
    if ToSegment(px, py, points[k - 1], points[k]) > OFF_PATH and now - leg.started >= REPATH_GAP then
        StartLeg(player, target, straight, true) -- worked out again from here; keep the old way meanwhile
        leg.path, leg.k, leg.suffix, leg.lookAt = path, k, Suffix(points), 0
        leg.pending = true
    end
    local corner = points[k]
    return corner, Dist(px, py, corner.wx, corner.wy) + (leg.suffix and leg.suffix[k] or 0)
end

-- The arrow's way and the index of its next corner, when it leads to pt (for the map).
function Path.Remaining(pt)
    local path = leg.path
    if not path or not pt or leg.c ~= pt.c or Dist(leg.tx, leg.ty, pt.wx, pt.wy) > RETARGET then return nil end
    return path, leg.k
end

function Path.Following()
    return leg.path ~= nil and leg.path ~= false
end

-- You kept walking without getting closer while following the way: mark the ground just ahead as
-- blocked (a rock, a tree, a ledge the data missed) and find another way. False once a leg has had
-- MAX_BLOCKS of these, or when not following a way: the caller handles it as before.
function Path.BlockAhead(player, target)
    local path = leg.path
    if not path or not player or player.c ~= leg.c or (leg.blocks or 0) >= MAX_BLOCKS then return false end
    local points, k = path.points, leg.k
    if #points < 2 then return false end
    local _, t = ToSegment(player.wx, player.wy, points[k - 1], points[k])
    local a, b = points[k - 1], points[k]
    -- Walk along the way from your closest point and block 5-20 yards of it.
    local x, y = a.wx + (b.wx - a.wx) * t, a.wy + (b.wy - a.wy) * t
    local walked, i = 0, k
    while walked < 20 and i <= #points do
        local q = points[i]
        local seg = Dist(x, y, q.wx, q.wy)
        local step = 0
        while step < seg and walked + step <= 20 do
            if walked + step >= 5 then
                local f = seg > 0 and step / seg or 0
                Terrain.AddObstacle(player.c, x + (q.wx - x) * f, y + (q.wy - y) * f, 4)
            end
            step = step + 3
        end
        walked = walked + seg
        x, y, i = q.wx, q.wy, i + 1
    end
    local blocks = (leg.blocks or 0) + 1
    Path.Reset()
    leg.blocks = blocks
    local _, straight = Pathable(player, target)
    if straight then StartLeg(player, target, straight, true) end
    return true
end

---------------------------------------------------------------------------
-- Route legs for the map
---------------------------------------------------------------------------

-- The walkable way from a to b (route step to route step), or nil while it's being worked out or when
-- the leg goes straight.
function Path.Between(a, b)
    local pathable, straight = Pathable(a, b)
    if not pathable then return nil end
    local ax, ay = Terrain.Cell(a.wx, a.wy)
    local bx, by = Terrain.Cell(b.wx, b.wy)
    local key = a.c .. ":" .. ax .. ":" .. ay .. ":" .. bx .. ":" .. by
    local known = static[key]
    if known == nil then
        if staticCount >= MAX_STATIC then
            static, staticCount = {}, 0
        end
        static[key], staticCount = true, staticCount + 1
        local mine = static
        Request(a.c, a.wx, a.wy, b.wx, b.wy, function(path)
            if static ~= mine then return end -- reset meanwhile
            static[key] = Usable(path, straight) and path or false
            if SP.Map then SP.Map.Refresh() end
        end)
        return nil
    end
    return known or nil
end

-- Forget every way worked out (the slope limit changed, or ground was found blocked).
function Path.Reset()
    static, staticCount = {}, 0
    for i = #queue, 1, -1 do queue[i] = nil end
    leg = { id = (leg.id or 0) + 1 }
end

-- For /java terrain.
function Path.Status()
    if leg.pending then return "working out the way" end
    if leg.path then
        local swim = leg.path.swim or 0
        return string.format("following a way of %d corners, %.0f yd", #leg.path.points, leg.path.length)
            .. (swim >= 1 and string.format(", %.0f of them swimming", swim) or "")
    end
    if leg.path == false then return "no better way found, going straight" end
    return "going straight"
end
