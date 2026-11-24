-- Oldman Java terrain: which ground you can walk on, from the game's own height data, and the
-- shortest walkable way between two places.
--
-- The data (TerrainKalimdor.lua, built by tools/build_terrain.py) gives every 4.17-yard cell a slope
-- band, or marks it as water deep enough to swim, or as lava, slime and the like. A cell is passable when
-- its band is at or under the slope limit, or when it is swimming water, whatever the ground under it.
-- Swimming costs SWIM_COST times as much as walking, so a way crosses water only where that's quicker.
-- Only ground you can walk both ways counts: drops off ledges are not used. Rocks, trees and buildings
-- are not in the data. Without data for a continent, or if the client can't decode it, there is no
-- terrain: callers fall back to straight lines. No terrain never means "blocked".
local _, SP = ...

local Terrain = {}
SP.Terrain = Terrain

local TILE = 1600 / 3
local CELLS = 128                 -- cells per tile side
local UNIT = TILE / CELLS         -- yards per cell
local ORIGIN = 32 * TILE          -- world coordinate of cell 0
local SIDE = 64 * CELLS           -- cells per continent side
local NO_DATA = 6
local HURTS = 7                   -- lava, slime and the like: never passable
local SWIM = 8                    -- water deep enough to swim: passable at any slope limit
local SWIM_COST = 1.5             -- swimming (4.7 yd/s) against running (7 yd/s)
local ZLIB = 1                    -- Enum.CompressionMethod.Zlib
local MAX_TILES = 96              -- decoded tiles kept (16 KB each)

-- Slope limits the data has band edges for (degrees) -> highest walkable band.
local LIMIT_BAND = { [46] = 0, [50] = 1, [55] = 2, [60] = 3, [68] = 4 }
Terrain.LIMITS = { 46, 50, 55, 60, 68 }
Terrain.DEFAULT_LIMIT = 50
Terrain.UNIT = UNIT
Terrain.NO_DATA, Terrain.HURTS, Terrain.SWIM, Terrain.SWIM_COST = NO_DATA, HURTS, SWIM, SWIM_COST

local floor, abs, min, max, sqrt = math.floor, math.abs, math.min, math.max, math.sqrt
local byte = string.byte
local SQRT2 = sqrt(2)

local cache = {}      -- [continent] = { [tileKey] = band string | true (all walkable) | false (no tile) }
local cached = 0
local broken = {}     -- [continent] = true once a tile failed to decode
local anchored = {}   -- [continent] = true/false: the client's world axes match the data's
local obstacles = {}  -- [continent] = { [cellKey] = true }: ground found blocked this session

local function Decode(s)
    local E = C_EncodingUtil
    if not (E and E.DecodeBase64 and E.DecompressString) then return nil end
    local ok, raw = pcall(E.DecodeBase64, s)
    if not ok or type(raw) ~= "string" then return nil end
    local ok2, out = pcall(E.DecompressString, raw, ZLIB)
    if ok2 and type(out) == "string" and #out == CELLS * CELLS then return out end
    return nil
end

-- The data names a map corner and the world position it was built against. If the client places that
-- corner anywhere else (different axes, a different continent), every cell lookup would be wrong:
-- no terrain then, so straight lines.
local function Anchored(c, data)
    local ok = anchored[c]
    if ok ~= nil then return ok end
    local a = data.anchor
    ok = false
    if a and C_Map and C_Map.GetWorldPosFromMapPos and SP.Data then
        local fine, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, a.map, SP.Data.Vec(0, 0))
        ok = fine and cont == c and pos ~= nil and type(pos.x) == "number" and type(pos.y) == "number"
            and abs(pos.x - a.x) < 1 and abs(pos.y - a.y) < 1
    end
    anchored[c] = ok
    return ok
end

-- True when there is usable terrain for continent c.
function Terrain.Has(c)
    local data = SP.terrainData and SP.terrainData[c]
    if not data or broken[c] or not Anchored(c, data) then return false end
    if data.decoded then return true end
    local E = C_EncodingUtil
    return E ~= nil and E.DecodeBase64 ~= nil and E.DecompressString ~= nil
end

local function Tile(c, key)
    local tilesOf = cache[c]
    if not tilesOf then
        tilesOf = {}
        cache[c] = tilesOf
    end
    local t = tilesOf[key]
    if t ~= nil then return t end
    local data = SP.terrainData and SP.terrainData[c]
    local raw = data and data.tiles[key]
    if raw == nil then
        t = false
    elseif raw == true or data.decoded then
        t = raw
    else
        t = Decode(raw)
        if not t then
            broken[c] = true -- this continent goes back to straight lines
            return false
        end
        if cached >= MAX_TILES then
            for _, other in pairs(cache) do
                for k, v in pairs(other) do
                    if type(v) == "string" then other[k] = nil end
                end
            end
            cached = 0
        end
        cached = cached + 1
    end
    tilesOf[key] = t
    return t
end

local lastC, lastKey, lastTile
local function BandAt(c, x, y)
    if x < 0 or y < 0 or x >= SIDE or y >= SIDE then return NO_DATA end
    local tx, ty = floor(x / CELLS), floor(y / CELLS)
    local key = tx * 64 + ty
    local t
    if c == lastC and key == lastKey then
        t = lastTile
    else
        t = Tile(c, key)
        lastC, lastKey, lastTile = c, key, t
    end
    if t == true then return 0 end
    if not t then return NO_DATA end
    return byte(t, (y - ty * CELLS) * CELLS + (x - tx * CELLS) + 1)
end
Terrain.BandAt = BandAt

function Terrain.LimitBand()
    local limit = SP.db and SP.db.slopeLimit
    return LIMIT_BAND[limit] or LIMIT_BAND[Terrain.DEFAULT_LIMIT]
end

-- World position (wx = world X, north; wy = world Y, west) -> cell column and row.
function Terrain.Cell(wx, wy)
    return floor((ORIGIN - wy) / UNIT), floor((ORIGIN - wx) / UNIT)
end

-- Cell -> world position of its centre (wx, wy).
function Terrain.Center(x, y)
    return ORIGIN - (y + 0.5) * UNIT, ORIGIN - (x + 0.5) * UNIT
end

-- Walkable at the limit, or swimming water.
function Terrain.Walkable(c, x, y)
    local obs = obstacles[c]
    if obs and obs[y * SIDE + x] then return false end
    local v = BandAt(c, x, y)
    return v <= Terrain.LimitBand() or v == SWIM
end

-- Marks the cells within radius yards of a world point as blocked for the rest of the session.
function Terrain.AddObstacle(c, wx, wy, radius)
    local obs = obstacles[c]
    if not obs then
        obs = {}
        obstacles[c] = obs
    end
    local cx, cy = Terrain.Cell(wx, wy)
    local r = math.ceil(radius / UNIT)
    for dy = -r, r do
        for dx = -r, r do
            if dx * dx + dy * dy <= r * r then obs[(cy + dy) * SIDE + cx + dx] = true end
        end
    end
end

function Terrain.ClearObstacles() obstacles = {} end

-- Every cell the straight segment between two cell centres touches is open. Where it passes exactly
-- through a corner, both side cells must be open: no squeezing diagonally between two cliffs.
-- With swim(x, y) given, also returns how many cells the line runs through and how many are water.
local function LineOpen(open, x0, y0, x1, y1, swim)
    local dx, dy = x1 - x0, y1 - y0
    local sx, sy = dx > 0 and 1 or -1, dy > 0 and 1 or -1
    local nx, ny = abs(dx), abs(dy)
    local x, y, ix, iy = x0, y0, 0, 0
    if not open(x, y) then return false end
    local cells, wet = 1, (swim and swim(x, y)) and 1 or 0
    while ix < nx or iy < ny do
        local d = (1 + 2 * ix) * ny - (1 + 2 * iy) * nx
        if d == 0 then
            if not open(x + sx, y) or not open(x, y + sy) then return false end
            x, y, ix, iy = x + sx, y + sy, ix + 1, iy + 1
        elseif d < 0 then
            x, ix = x + sx, ix + 1
        else
            y, iy = y + sy, iy + 1
        end
        if not open(x, y) then return false end
        cells = cells + 1
        if swim and swim(x, y) then wet = wet + 1 end
    end
    return true, cells, wet
end
Terrain.LineOpen = LineOpen

-- What a straight line between two cells costs (in cells, swimming counted SWIM_COST times), or nil
-- when it isn't open.
local function LineCost(open, swim, x0, y0, x1, y1)
    local ok, cells, wet = LineOpen(open, x0, y0, x1, y1, swim)
    if not ok then return nil end
    local dx, dy = x1 - x0, y1 - y0
    return sqrt(dx * dx + dy * dy) * (1 + (SWIM_COST - 1) * wet / cells)
end

-- open(x, y) for the current limit and obstacles, and swim(x, y) for water, remembering cell values in
-- memo (optional).
function Terrain.Opener(c, memo)
    local limit, obs = Terrain.LimitBand(), obstacles[c]
    local function value(x, y)
        if not memo then return BandAt(c, x, y) end
        local k = y * SIDE + x
        local v = memo[k]
        if v == nil then
            v = BandAt(c, x, y)
            memo[k] = v
        end
        return v
    end
    local function open(x, y)
        if obs and obs[y * SIDE + x] then return false end
        local v = value(x, y)
        return v <= limit or v == SWIM
    end
    local function swim(x, y)
        return value(x, y) == SWIM
    end
    return open, swim
end

-- Nearest open cell within r cells of (x, y), or nil.
local function Snap(open, x, y, r)
    if open(x, y) then return x, y end
    local best, bx, by
    for dy = -r, r do
        for dx = -r, r do
            local d = dx * dx + dy * dy
            if d <= r * r and (not best or d < best) and open(x + dx, y + dy) then best, bx, by = d, x + dx, y + dy end
        end
    end
    return bx, by
end

local WEIGHT = 1.3        -- weighted A*: a few percent longer at worst, far fewer cells searched
local MAX_EXPAND = 250000
local MARGIN_MIN = 72     -- cells (300 yd) of room around the start-goal box
local MARGIN_MAX = 360

-- Quickest walkable way between two world points on continent c (8 directions, no diagonal squeeze),
-- swimming where that's quicker than walking round. yield is called now and then so the search can be
-- spread over frames.
-- Returns { points = { {c, wx, wy}, ... }, length = yards, swim = yards of it swimming, expanded = n }
-- or nil, reason.
function Terrain.FindPath(c, fromX, fromY, toX, toY, yield)
    if not Terrain.Has(c) then return nil, "no terrain" end
    local memo = {}
    local open, swim = Terrain.Opener(c, memo)
    local x0, y0 = Terrain.Cell(fromX, fromY)
    local x1, y1 = Terrain.Cell(toX, toY)
    local sx, sy = Snap(open, x0, y0, 3)
    local gx, gy = Snap(open, x1, y1, 4)
    if not sx then return nil, "start not walkable" end
    if not gx then return nil, "goal not walkable" end
    local dist = max(abs(gx - sx), abs(gy - sy))
    local margin = min(MARGIN_MAX, max(MARGIN_MIN, floor(dist / 2)))
    local bx0, bx1 = min(sx, gx) - margin, max(sx, gx) + margin
    local by0, by1 = min(sy, gy) - margin, max(sy, gy) + margin

    local g, parent, closed = {}, {}, {}
    local hk, hf, n = {}, {}, 0
    local function push(k, f)
        n = n + 1
        local i = n
        while i > 1 do
            local p = floor(i / 2)
            if hf[p] <= f then break end
            hk[i], hf[i] = hk[p], hf[p]
            i = p
        end
        hk[i], hf[i] = k, f
    end
    local function pop()
        local k = hk[1]
        local lastK, lastF = hk[n], hf[n]
        hk[n], hf[n] = nil, nil
        n = n - 1
        if n > 0 then
            local i = 1
            while true do
                local l = i * 2
                if l > n then break end
                local r = l + 1
                if r <= n and hf[r] < hf[l] then l = r end
                if hf[l] >= lastF then break end
                hk[i], hf[i] = hk[l], hf[l]
                i = l
            end
            hk[i], hf[i] = lastK, lastF
        end
        return k
    end
    local function h(x, y)
        local dx, dy = abs(x - gx), abs(y - gy)
        if dx < dy then dx, dy = dy, dx end
        return (dx + (SQRT2 - 1) * dy) * WEIGHT
    end

    local start, goal = sy * SIDE + sx, gy * SIDE + gx
    g[start] = 0
    push(start, h(sx, sy))
    local expanded, found = 0, false
    while n > 0 do
        local k = pop()
        if not closed[k] then
            if k == goal then found = true break end
            closed[k] = true
            expanded = expanded + 1
            if expanded > MAX_EXPAND then return nil, "too far around" end
            if yield and expanded % 256 == 0 then yield() end
            local y = floor(k / SIDE)
            local x = k - y * SIDE
            local gk = g[k]
            local e = open(x + 1, y) and x + 1 <= bx1
            local w = open(x - 1, y) and x - 1 >= bx0
            local s = open(x, y + 1) and y + 1 <= by1
            local nn = open(x, y - 1) and y - 1 >= by0
            for i = 1, 8 do
                local nx, ny, step, ok
                if i == 1 then nx, ny, step, ok = x + 1, y, 1, e
                elseif i == 2 then nx, ny, step, ok = x - 1, y, 1, w
                elseif i == 3 then nx, ny, step, ok = x, y + 1, 1, s
                elseif i == 4 then nx, ny, step, ok = x, y - 1, 1, nn
                elseif i == 5 then nx, ny, step, ok = x + 1, y + 1, SQRT2, e and s
                elseif i == 6 then nx, ny, step, ok = x + 1, y - 1, SQRT2, e and nn
                elseif i == 7 then nx, ny, step, ok = x - 1, y + 1, SQRT2, w and s
                else nx, ny, step, ok = x - 1, y - 1, SQRT2, w and nn end
                if ok and (step == 1 or open(nx, ny)) then
                    local nk = ny * SIDE + nx
                    if not closed[nk] then
                        local ng = gk + (swim(nx, ny) and step * SWIM_COST or step)
                        local old = g[nk]
                        if not old or ng < old then
                            g[nk] = ng
                            parent[nk] = k
                            push(nk, ng + h(nx, ny))
                        end
                    end
                end
            end
        end
    end
    if not found then return nil, "no walkable way" end

    -- Cells from start to goal.
    local cells, k = {}, goal
    while k do
        cells[#cells + 1] = k
        k = parent[k]
    end
    local m = #cells
    for i = 1, floor(m / 2) do cells[i], cells[m + 1 - i] = cells[m + 1 - i], cells[i] end

    -- Keep only the corners: from each kept cell, jump to the farthest cell still in a straight
    -- walkable line (doubling, then halving back) that costs no more than the way it replaces. On land
    -- a straight line always does; across water it may not, since swimming is slower than walking the
    -- shore.
    local function xy(i)
        local y = floor(cells[i] / SIDE)
        return cells[i] - y * SIDE, y
    end
    local function visible(i, j)
        local ax, ay = xy(i)
        local cx, cy = xy(j)
        local cost = LineCost(open, swim, ax, ay, cx, cy)
        return cost ~= nil and cost <= g[cells[j]] - g[cells[i]] + 1e-6
    end
    local keep, i = { 1 }, 1
    while i < m do
        local good, step = i + 1, 1
        while i + step * 2 <= m and visible(i, i + step * 2) do
            step = step * 2
            good = i + step
        end
        local lo, hi = good, min(m, i + step * 2)
        while hi - lo > 1 do
            local mid = floor((lo + hi) / 2)
            if visible(i, mid) then lo = mid else hi = mid end
        end
        if hi > lo and hi <= m and visible(i, hi) then lo = hi end
        keep[#keep + 1] = lo
        i = lo
        if yield then yield() end
    end

    local points, length, swum = {}, 0, 0
    for idx, ci in ipairs(keep) do
        local cx, cy = xy(ci)
        local wx, wy = Terrain.Center(cx, cy)
        if idx == 1 then wx, wy = fromX, fromY end
        if idx == #keep then wx, wy = toX, toY end
        local p = { c = c, wx = wx, wy = wy }
        local prev = points[#points]
        if prev then
            local ddx, ddy = wx - prev.wx, wy - prev.wy
            local seg = sqrt(ddx * ddx + ddy * ddy)
            length = length + seg
            local px, py = xy(keep[idx - 1])
            local _, n, wet = LineOpen(open, px, py, cx, cy, swim)
            if n then swum = swum + seg * wet / n end
        end
        points[#points + 1] = p
    end
    return { points = points, length = length, swim = swum, expanded = expanded }
end

-- True when a straight walk between two world points stays on walkable ground (or swimming water).
function Terrain.Clear(c, ax, ay, bx, by)
    if not Terrain.Has(c) then return true end
    local x0, y0 = Terrain.Cell(ax, ay)
    local x1, y1 = Terrain.Cell(bx, by)
    return (LineOpen(Terrain.Opener(c), x0, y0, x1, y1))
end

-- What going straight between two world points costs, in yards with swimming counted SWIM_COST times,
-- or nil when the line crosses ground you can't walk. No terrain: the plain distance.
function Terrain.Cost(c, ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    local d = sqrt(dx * dx + dy * dy)
    if not Terrain.Has(c) then return d end
    local x0, y0 = Terrain.Cell(ax, ay)
    local x1, y1 = Terrain.Cell(bx, by)
    local open, swim = Terrain.Opener(c)
    local ok, n, wet = LineOpen(open, x0, y0, x1, y1, swim)
    if not ok then return nil end
    return d * (1 + (SWIM_COST - 1) * wet / n)
end

-- Tests: give continent c terrain from already-decoded tiles ({ [tx * 64 + ty] = 16384-byte string or true }),
-- built against anchor { map, x, y } (the world position of that map's top-left corner).
function Terrain.SetTestTiles(c, tiles, anchor)
    SP.terrainData = SP.terrainData or {}
    SP.terrainData[c] = tiles and { tiles = tiles, decoded = true, anchor = anchor } or nil
    cache[c], broken[c], obstacles[c], anchored[c] = nil, nil, nil, nil
    lastC, lastKey, lastTile = nil, nil, nil
end
