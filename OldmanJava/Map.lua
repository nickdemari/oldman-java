-- Oldman Java world map overlay: soft shaded areas where each route objective is done (mobs, drops,
-- objects), a label per area, numbered markers for the next steps, and a thin line along the route
-- that follows the walkable way where the terrain gives one (Path.lua).
--
-- Drawn through a map-canvas data provider, the supported way to add to the world map, into frames
-- Oldman Java owns. Blizzard's pin pools are left untouched.
local _, SP = ...

local Map = {}
SP.Map = Map

local floor, max, min = math.floor, math.max, math.min

local MAX_BLOBS_PER_OBJECTIVE = 40
local MAX_BLOBS = 420
local MAX_STEPS = 10
local MARKER = 18          -- on-screen pixels, kept constant while zooming
local MARKER_CURRENT = 28 -- big enough to cover Blizzard's waypoint diamond at the same spot
local LINE = 2.5           -- on-screen pixels
local FAN_STEP = 26        -- spacing for crowded markers: clears a regular marker next to the big current one

-- One colour per quest so overlapping areas stay tellable apart.
local QUEST_COLORS = {
    { 0.36, 0.78, 0.98 }, { 1.00, 0.62, 0.30 }, { 0.62, 0.88, 0.40 }, { 0.86, 0.52, 0.96 },
    { 1.00, 0.84, 0.32 }, { 0.40, 0.90, 0.80 }, { 1.00, 0.50, 0.58 }, { 0.64, 0.68, 1.00 },
}

local provider, areaFrame, markerFrame
local topLevel -- frame level just above Blizzard's waypoint pin
local blobs, labels, markers, lines, spots = { n = 0 }, { n = 0 }, { n = 0 }, { n = 0 }, { n = 0 }
local cacheVersion, cacheMap, cacheCount, cacheAreas, cacheCx, cacheCy
local blobsFor, blobsW, blobsH -- what the shown blobs were laid out for (nil: lay out again)
local drawnSteps = 0
local KIND_COLOR -- step colours, filled lazily from Style (used by marker tooltips too)

---------------------------------------------------------------------------
-- Geometry (no frames; unit-tested offline)
---------------------------------------------------------------------------

local projVec -- one world-position vector, refilled per call (the client only reads it)

-- Position of a point on the shown map (0-1), or nil when it falls outside it.
function Map.Project(pt, mapID)
    if not pt then return nil end
    if pt.map == mapID then return pt.x, pt.y end
    if not (C_Map and C_Map.GetMapPosFromWorldPos) then return nil end
    projVec = projVec or SP.Data.Vec(0, 0)
    projVec.x, projVec.y = pt.wx, pt.wy
    local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, pt.c, projVec, mapID)
    if not ok or not pos then return nil end
    local x, y = pos.x, pos.y
    if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then return x, y end
    return nil
end

local function ObjectivePoints(node)
    local loc = SP.Data.Locations(node.q)
    if not loc then return nil end
    local index = node.key and tonumber(node.key:match("^o(%d+)$"))
    local obj = index and loc.objectives[index]
    if obj then return obj.sweep or obj.points end -- a patrolling mob's path is part of its area
    return loc.all
end

local function DenserFirst(a, b)
    if a.n ~= b.n then return a.n > b.n end
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
end

-- One objective's spawn points grouped into grid cells on one map: { {x, y, n} }, densest first
-- (ties break on position so the drawing is stable), at most what one objective may draw.
-- Spawn lists are never changed once built (a cleared location cache builds new ones), so this is
-- worked out once per list and map, not again every time a step completes and the areas rebuild.
local cellCache = setmetatable({}, { __mode = "k" }) -- spawn list -> { [mapID] = cells }
local NO_CELLS = {}
local function DenseCells(points, mapID, cx, cy)
    if not points then return NO_CELLS end
    local byMap = cellCache[points]
    if not byMap then
        byMap = {}
        cellCache[points] = byMap
    end
    local out = byMap[mapID]
    if out then return out end
    local cells, list = {}, {}
    for _, pt in ipairs(points) do
        local x, y = Map.Project(pt, mapID)
        if x then
            local key = floor(x / cx) * 65536 + floor(y / cy)
            local cell = cells[key]
            if not cell then
                cell = { n = 0, sx = 0, sy = 0 }
                cells[key] = cell
                list[#list + 1] = cell
            end
            cell.n, cell.sx, cell.sy = cell.n + 1, cell.sx + x, cell.sy + y
        end
    end
    for _, cell in ipairs(list) do cell.x, cell.y = cell.sx / cell.n, cell.sy / cell.n end
    table.sort(list, DenserFirst)
    out = {}
    for j = 1, min(#list, MAX_BLOBS_PER_OBJECTIVE) do
        out[j] = { x = list[j].x, y = list[j].y, n = list[j].n }
    end
    byMap[mapID] = out
    return out
end

-- Groups each open objective's spawn points into grid cells on the shown map.
-- Returns areas { color, title, quest, current, blobs = { {x, y, n} }, label = {x, y} } and the
-- cell size in map units. Blob entries are shared between calls: read them, don't change them.
function Map.BuildAreas(open, mapID)
    local width, height = SP.Data.MapSizeYards(mapID)
    if not width or width <= 0 or height <= 0 then return {}, 0, 0 end
    local cellYards = max(60, width / 120) -- coarser cells on continent maps
    local cx, cy = cellYards / width, cellYards / height
    local areas, seen, questColor, nextColor, total = {}, {}, {}, 0, 0
    for i, node in ipairs(open) do
        if node.kind == "obj" and node.q then
            local id = node.q .. ":" .. tostring(node.key)
            if not seen[id] then
                seen[id] = true
                local cells = total < MAX_BLOBS and DenseCells(ObjectivePoints(node), mapID, cx, cy) or NO_CELLS
                if #cells > 0 then
                    if not questColor[node.q] then
                        nextColor = nextColor % #QUEST_COLORS + 1
                        questColor[node.q] = QUEST_COLORS[nextColor]
                    end
                    local area = {
                        color = questColor[node.q], title = node.title, quest = node.sub, node = node,
                        current = (i == 1), step = i, blobs = {},
                    }
                    for j = 1, min(#cells, MAX_BLOBS - total) do area.blobs[j] = cells[j] end
                    total = total + #area.blobs
                    area.label = { x = area.blobs[1].x, y = area.blobs[1].y }
                    areas[#areas + 1] = area
                end
            end
        end
    end
    return areas, cx, cy
end

-- Screen-space boxes ({x, y, w, h}, centred) and marker placement. A crowded marker tries the eight
-- spots one marker-width around its true position; if all are taken it overlaps rather than drift,
-- so a marker never ends up looking like it belongs somewhere else.
function Map.Overlaps(boxes, x, y, w, h)
    for _, b in ipairs(boxes) do
        if math.abs(x - b.x) * 2 < (w + b.w) and math.abs(y - b.y) * 2 < (h + b.h) then return true end
    end
    return false
end

local FAN = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, -1 }, { 0, 1 }, { 1, -1 }, { -1, -1 }, { 1, 1 }, { -1, 1 } }

function Map.PlaceMarker(boxes, x, y, w, h, step)
    local stepX, stepY = max(step, w + 4), max(step, h + 4)
    for _, o in ipairs(FAN) do
        local px, py = x + o[1] * stepX, y + o[2] * stepY
        if not Map.Overlaps(boxes, px, py, w, h) then return px, py end
    end
    return x, y
end

-- Consecutive steps at (almost) the same spot become one group marker, e.g. accept, kill and turn
-- in at one NPC. The current step always stands alone. steps: { {sx, sy, index, node}, ... } in
-- screen space; radius in screen pixels.
local MAX_GROUP = 6

-- Groups steps[1..n] into `groups`, reusing the group tables already there; returns the count.
local function GroupInto(steps, n, radius, groups)
    local count, last = 0, nil
    for k = 1, n do
        local s = steps[k]
        local joins = last and not last.current and last.size < MAX_GROUP
            and math.abs(s.sx - last.sx) <= radius and math.abs(s.sy - last.sy) <= radius
            and s.index ~= 1
        if joins then
            last.size = last.size + 1
            last.steps[last.size] = s
        else
            count = count + 1
            last = groups[count]
            if not last then
                last = { steps = {} }
                groups[count] = last
            end
            last.sx, last.sy, last.current, last.size = s.sx, s.sy, (s.index == 1), 1
            last.steps[1] = s
        end
    end
    for g = 1, count do
        local group = groups[g]
        for j = #group.steps, group.size + 1, -1 do group.steps[j] = nil end
    end
    return count
end

function Map.GroupSteps(steps, radius)
    local groups = {}
    GroupInto(steps, #steps, radius, groups)
    return groups
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

-- The last values given to each pooled widget. Draw runs on every zoom frame; the client is only
-- called for what changed. Only this file touches these widgets, so the record stays true.
local given = setmetatable({}, { __mode = "k" })
local function Given(w)
    local g = given[w]
    if not g then
        g = {}
        given[w] = g
    end
    return g
end

local function Acquire(pool, create)
    pool.n = pool.n + 1
    local obj = pool[pool.n]
    if not obj then
        obj = create()
        pool[pool.n] = obj
    end
    local g = Given(obj)
    if g.shown ~= true then
        obj:Show()
        g.shown = true
    end
    return obj
end

local function HideOne(obj)
    local g = Given(obj)
    if g.shown ~= false then
        obj:Hide()
        g.shown = false
    end
end

local function HideFrom(pool, first)
    for i = first, #pool do HideOne(pool[i]) end
end

-- Anchors w's centre at (x, y) from rel's top left.
local function PlaceAt(w, rel, x, y)
    local g = Given(w)
    if g.x ~= x or g.y ~= y or g.rel ~= rel then
        w:ClearAllPoints()
        w:SetPoint("CENTER", rel, "TOPLEFT", x, y)
        g.x, g.y, g.rel = x, y, rel
    end
end

local function SizeTo(w, width, height)
    local g = Given(w)
    if g.w ~= width or g.h ~= height then
        w:SetSize(width, height)
        g.w, g.h = width, height
    end
end

local function Tint(w, r, g_, b, a)
    local g = Given(w)
    if g.r ~= r or g.g ~= g_ or g.b ~= b or g.a ~= a then
        w:SetVertexColor(r, g_, b, a)
        g.r, g.g, g.b, g.a = r, g_, b, a
    end
end

local function ScaleTo(w, scale)
    local g = Given(w)
    if g.scale ~= scale then
        w:SetScale(scale)
        g.scale = scale
    end
end

local function LevelTo(w, level)
    local g = Given(w)
    if g.level ~= level then
        w:SetFrameLevel(level)
        g.level = level
    end
end

local function ResetPools()
    labels.n, markers.n, lines.n, spots.n = 0, 0, 0, 0 -- blobs keep theirs until laid out again
end

local function HideAll()
    ResetPools()
    blobs.n, blobsFor = 0, nil
    drawnSteps = 0
    HideFrom(blobs, 1); HideFrom(labels, 1); HideFrom(markers, 1); HideFrom(lines, 1); HideFrom(spots, 1)
end

local function NewBlob()
    local t = areaFrame:CreateTexture(nil, "ARTWORK")
    t:SetTexture(SP.Style.MEDIA .. "glow.tga")
    return t
end

local function NewSpot()
    local t = areaFrame:CreateTexture(nil, "OVERLAY", nil, 2)
    t:SetTexture(SP.Style.MEDIA .. "ring.tga")
    return t
end

local function NewLine()
    local line = areaFrame:CreateLine(nil, "OVERLAY")
    line:SetColorTexture(1, 1, 1, 1)
    return line
end

local function NewLabel()
    local f = CreateFrame("Frame", nil, markerFrame)
    f:SetSize(1, 1)
    f.text = f:CreateFontString(nil, "OVERLAY")
    f.text:SetFont(SP.Style.FONT, 12, "OUTLINE")
    f.text:SetPoint("CENTER")
    f.sub = f:CreateFontString(nil, "OVERLAY")
    f.sub:SetFont(SP.Style.FONT, 10, "OUTLINE")
    f.sub:SetPoint("TOP", f.text, "BOTTOM", 0, -1)
    f.sub:SetTextColor(0.85, 0.87, 0.9, 0.9)
    return f
end

local GROUP_DISC, GROUP_GAP, GROUP_PAD = 16, 3, 4

local function NewDisc(f)
    local d = {}
    d.shadow = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    d.shadow:SetTexture(SP.Style.MEDIA .. "disc.tga")
    d.shadow:SetVertexColor(0, 0, 0, 0.55)
    d.disc = f:CreateTexture(nil, "ARTWORK")
    d.disc:SetTexture(SP.Style.MEDIA .. "disc.tga")
    d.number = f:CreateFontString(nil, "OVERLAY")
    d.number:SetFont(SP.Style.FONT, 10, "")
    d.number:SetTextColor(0.05, 0.06, 0.08)
    d.number:SetPoint("CENTER", d.disc, "CENTER", 0, 0)
    return d
end

local function NewMarker()
    local f = CreateFrame("Frame", nil, markerFrame)
    -- Group background: dark pill behind the step discs.
    f.bg = SP.Style.Sliced(f, "BACKGROUND", "pill.tga", 8, { 0.04, 0.05, 0.07, 0.86 })
    f.bg:SetAllPoints()
    f.border = SP.Style.Sliced(f, "BORDER", "pill.tga", 8, { 1, 1, 1, 0.10 })
    f.border:SetPoint("TOPLEFT", -1, 1)
    f.border:SetPoint("BOTTOMRIGHT", 1, -1)
    f.border:SetDrawLayer("BACKGROUND", -1)
    f.discs = {}
    f.ring = f:CreateTexture(nil, "OVERLAY")
    f.ring:SetTexture(SP.Style.MEDIA .. "ring.tga")
    f.ring:SetPoint("TOPLEFT", -5, 5)
    f.ring:SetPoint("BOTTOMRIGHT", 5, -5)
    -- Slow pulse on the current step's ring.
    f.pulse = f.ring:CreateAnimationGroup()
    pcall(f.pulse.SetLooping, f.pulse, "BOUNCE")
    local fade = f.pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.25)
    fade:SetDuration(0.9)
    -- Hover lists the step(s); clicks and drags fall through to the map.
    if f.SetMouseClickEnabled then
        f:SetMouseClickEnabled(false)
        f:SetMouseMotionEnabled(true)
        f:SetScript("OnEnter", function(self)
            local group = self.group
            if not group then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            for i, s in ipairs(group.steps) do
                local node = s.node
                local c = KIND_COLOR and KIND_COLOR[node.kind] or { 1, 1, 1 }
                local line = string.format("%d.  %s  %s", s.index, node.label or "", node.title or node.text or "")
                if i == 1 then GameTooltip:SetText(line, c[1], c[2], c[3]) else GameTooltip:AddLine(line, c[1], c[2], c[3]) end
                if node.sub and node.sub ~= node.title then GameTooltip:AddLine("     " .. node.sub, 0.75, 0.78, 0.82) end
            end
            GameTooltip:AddLine(#group.steps > 1 and "These steps are at the same place." or "Step of your Oldman Java route",
                0.5, 0.75, 0.95)
            GameTooltip:Show()
        end)
        f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return f
end

-- Size of a marker for a group, in screen pixels.
local function MarkerSize(group)
    local n = #group.steps
    if n == 1 then
        local size = group.current and MARKER_CURRENT or MARKER
        return size, size
    end
    return n * GROUP_DISC + (n - 1) * GROUP_GAP + 2 * GROUP_PAD, GROUP_DISC + 2 * GROUP_PAD
end

local function LayoutMarker(f, group, colors)
    local n = #group.steps
    local w, h = MarkerSize(group)
    f.group = group
    local g = Given(f)
    -- The current step's ring pulses; nothing else plays it, so a stopped one stays stopped.
    if group.current then
        if not f.pulse:IsPlaying() then f.pulse:Play() end
        g.pulsing = true
    elseif g.pulsing ~= false then
        f.pulse:Stop()
        g.pulsing = false
    end
    -- Same steps as last time (zooming, live counts): the discs are already right.
    local same = g.n == n and g.current == group.current
    if same then
        for i = 1, n do
            local s = group.steps[i]
            if g.kinds[i] ~= s.node.kind or g.indexes[i] ~= s.index then
                same = false
                break
            end
        end
    end
    if same then return w, h end
    g.n, g.current = n, group.current
    g.kinds, g.indexes = g.kinds or {}, g.indexes or {}
    for i = 1, n do g.kinds[i], g.indexes[i] = group.steps[i].node.kind, group.steps[i].index end
    f:SetSize(w, h)
    f.bg:SetShown(n > 1)
    f.border:SetShown(n > 1)
    for i = 1, max(n, #f.discs) do
        local d = f.discs[i]
        if i <= n then
            if not d then d = NewDisc(f); f.discs[i] = d end
            local s = group.steps[i]
            local c = colors[s.node.kind] or SP.Style.color.accent
            d.disc:SetVertexColor(c[1], c[2], c[3], 1)
            d.disc:ClearAllPoints()
            d.shadow:ClearAllPoints()
            if n == 1 then
                d.disc:SetAllPoints(f)
                d.shadow:SetPoint("TOPLEFT", f, "TOPLEFT", -2, 2)
                d.shadow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, -2)
                d.shadow:Show()
                d.number:SetFont(SP.Style.FONT, group.current and 14 or 10, "")
            else
                d.disc:SetSize(GROUP_DISC, GROUP_DISC)
                d.disc:SetPoint("LEFT", f, "LEFT", GROUP_PAD + (i - 1) * (GROUP_DISC + GROUP_GAP), 0)
                d.shadow:Hide()
                d.number:SetFont(SP.Style.FONT, 9, "")
            end
            d.number:SetText(s.index)
            d.disc:Show(); d.number:Show()
        elseif d then
            d.disc:Hide(); d.number:Hide(); d.shadow:Hide()
        end
    end
    f.ring:SetShown(group.current)
    f.ring:SetVertexColor(1, 1, 1, 0.95)
    return w, h
end


-- Scratch tables reused by every Draw (it runs on each frame of a zoom).
local drawOpen, stepPool, steps, groups, boxPool, boxes, order = {}, {}, {}, {}, {}, {}, {}
local linePoint = {} -- scratch player point for the route line
local wayX, wayY = {}, {} -- scratch: the corners of one route leg on the shown map

-- A walkable way's corners projected onto a map (0-1), worked out once per way and map.
-- false when a corner falls off the map.
local function ProjectWay(path, mapID)
    local proj = path.proj
    if proj and proj.map == mapID then return proj.ok and proj end
    proj = { map = mapID, ok = true }
    for i, p in ipairs(path.points) do
        local x, y = Map.Project(p, mapID)
        if not x then proj.ok = false break end
        proj[i * 2 - 1], proj[i * 2] = x, y
    end
    path.proj = proj
    return proj.ok and proj
end

-- Fills wayX/wayY (screen space) with the corners between a and b for route leg k; returns the count.
-- The first leg is the arrow's way from where you stand; the others are worked out step to step.
local function WayCorners(k, a, b, mapID, W, H)
    local Path = SP.Path
    if not Path then return 0 end
    local points, first, path
    if k == 1 then
        path, first = Path.Remaining(b)
        if not path then return 0 end
        points = path.points
    else
        path = Path.Between(a, b)
        if not path then return 0 end
        points, first = path.points, 2
    end
    local proj = path and ProjectWay(path, mapID)
    if not proj then return 0 end
    local n = 0
    for i = first, #points - 1 do -- the last point is the step itself: the marker stands there
        n = n + 1
        wayX[n], wayY[n] = proj[i * 2 - 1] * W, -proj[i * 2] * H
    end
    return n
end
local LABEL_SHIFTS = { 0, 1, -1, 2, -2 } -- label slots tried, in label heights (+6) from its spot
local function EarlierStep(a, b) return a.step < b.step end

-- Screen-space boxes already used by markers and labels this Draw; labels never overlap them.
local function AddBox(x, y, w, h)
    local n = #boxes + 1
    local b = boxPool[n]
    if not b then
        b = {}
        boxPool[n] = b
    end
    b.x, b.y, b.w, b.h = x, y, w, h
    boxes[n] = b
end

local function Draw()
    if not (provider and areaFrame and SP.ready and SP.Data.indexReady) then return end
    ResetPools()
    if SP.db and SP.db.mapOverlay == false then HideAll() return end

    local map = provider:GetMap()
    local mapID = map and map:GetMapID()
    local canvas = map and map:GetCanvas()
    if not mapID or not canvas then HideAll() return end
    local W, H = canvas:GetWidth(), canvas:GetHeight()
    if not W or W <= 0 then HideAll() return end
    local canvasScale = (map.GetCanvasScale and map:GetCanvasScale()) or 1
    if canvasScale <= 0 then canvasScale = 1 end
    local markerScale = 1 / canvasScale

    local C = SP.Style.color
    KIND_COLOR = KIND_COLOR or { pickup = C.pickup, obj = C.obj, turnin = C.turnin, travel = C.travel }

    local open = SP.UI.OpenNodesInto(drawOpen)

    -- Areas are cached per plan, map and remaining step count; re-layout is cheap.
    local version = SP.Planner.version
    if not cacheAreas or version ~= cacheVersion or mapID ~= cacheMap or #open ~= cacheCount then
        cacheAreas, cacheCx, cacheCy = Map.BuildAreas(open, mapID)
        cacheVersion, cacheMap, cacheCount = version, mapID, #open
    end
    local areas, cx, cy = cacheAreas, cacheCx, cacheCy

    -- Shaded areas: one soft blob per occupied cell; overlaps read as density. They sit in canvas
    -- space, so zooming doesn't move them: lay them out only when the areas or the canvas change.
    if blobsFor ~= areas or blobsW ~= W or blobsH ~= H then
        blobs.n = 0
        for _, area in ipairs(areas) do
            local c = area.color
            -- Wide, faint blobs merge into one continuous area; overlaps still read darker where spawns are dense.
            local alpha = area.current and 0.30 or 0.18
            local w, h = cx * 3.6 * W, cy * 3.6 * H
            for _, b in ipairs(area.blobs) do
                local t = Acquire(blobs, NewBlob)
                PlaceAt(t, areaFrame, b.x * W, -b.y * H)
                SizeTo(t, w, h)
                Tint(t, c[1], c[2], c[3], alpha)
            end
        end
        HideFrom(blobs, blobs.n + 1)
        blobsFor, blobsW, blobsH = areas, W, H
    end

    -- Steps on this map, in route order, in screen space (marker scale).
    local nSteps = 0
    for i = 1, min(#open, MAX_STEPS) do
        local node = open[i]
        if not node.inBags then -- items started from the bags have no place on the map
            local x, y = Map.Project(node.pt, mapID)
            if not x then break end -- the route leaves this map here
            nSteps = nSteps + 1
            local s = stepPool[nSteps]
            if not s then
                s = {}
                stepPool[nSteps] = s
            end
            s.node, s.index, s.sx, s.sy = node, i, x * W / markerScale, -y * H / markerScale
            steps[nSteps] = s
        end
    end

    for i = #boxes, 1, -1 do boxes[i] = nil end

    -- Markers: one per group of steps at the same place; crowded groups fan out around their spot.
    local nGroups = GroupInto(steps, nSteps, MARKER, groups)
    drawnSteps = nSteps
    local baseLevel = markerFrame:GetFrameLevel()
    for k = 1, nGroups do
        local group = groups[k]
        local f = Acquire(markers, NewMarker)
        ScaleTo(f, markerScale)
        local w, h = LayoutMarker(f, group, KIND_COLOR)
        local bw, bh = w + 2, h + 2 -- reserve exactly the box we place with
        group.x, group.y = Map.PlaceMarker(boxes, group.sx, group.sy, bw, bh, FAN_STEP)
        PlaceAt(f, markerFrame, group.x, group.y)
        -- The current step sits above Blizzard's waypoint diamond so the map reads in one style.
        LevelTo(f, group.current and (topLevel or baseLevel + 20)
            or (baseLevel + 12 - min(group.steps[1].index, 10)))
        AddBox(group.x, group.y, bw, bh)
    end

    -- Route line from the player through each marker, ending exactly on the drawn markers. Each leg
    -- follows the walkable way where there is one, and goes straight otherwise.
    local thick, shadowThick = LINE * markerScale, (LINE + 2.5) * markerScale
    local function LineTo(ax, ay, bx, by, alpha)
        for pass = 1, 2 do
            local line = Acquire(lines, NewLine)
            local g = Given(line)
            if g.ax ~= ax or g.ay ~= ay then
                line:SetStartPoint("TOPLEFT", areaFrame, ax, ay)
                g.ax, g.ay = ax, ay
            end
            if g.bx ~= bx or g.by ~= by then
                line:SetEndPoint("TOPLEFT", areaFrame, bx, by)
                g.bx, g.by = bx, by
            end
            local t = pass == 1 and shadowThick or thick
            if g.thick ~= t then
                line:SetThickness(t)
                g.thick = t
            end
            if pass == 1 then
                Tint(line, 0, 0, 0, 0.45)
            else
                Tint(line, 1, 1, 1, alpha)
            end
        end
    end
    local ax, ay
    local from = SP.Data.PlayerPointInto(linePoint)
    local px, py = Map.Project(from, mapID)
    if px then ax, ay = px * W, -py * H end
    local segment = 0
    local last -- the previous marker's last step
    for k = 1, nGroups do
        local bx, by = groups[k].x * markerScale, groups[k].y * markerScale
        local first = groups[k].steps[1].node
        local to = first.pt
        if ax and last and last.how == "fly" then
            -- The flight itself: straight to where it lands, then the walk from there.
            local ex, ey = Map.Project(last.exit, mapID)
            if ex then
                LineTo(ax, ay, ex * W, -ey * H, 0.35)
                ax, ay = ex * W, -ey * H
                from = last.exit
            else
                ax = nil
            end
        end
        -- A hearth step is a teleport: no line leads into it.
        if ax and first.how ~= "hearth" then
            segment = segment + 1
            local alpha = segment == 1 and 0.95 or 0.6
            local n = WayCorners(k, from, to, mapID, W, H)
            for i = 1, n do
                LineTo(ax, ay, wayX[i], wayY[i], alpha)
                ax, ay = wayX[i], wayY[i]
            end
            LineTo(ax, ay, bx, by, alpha)
        end
        ax, ay = bx, by
        from = to
        local steps = groups[k].steps
        last = steps[#steps].node
    end

    -- Search step: ring every possible spot; checked ones fade.
    local currentNode = open[1]
    if currentNode and currentNode.search and currentNode.spots then
        local checked = SP.UI.SearchChecked and SP.UI.SearchChecked(currentNode) or {}
        local c = KIND_COLOR[currentNode.kind] or C.accent
        local size = 16 * markerScale
        for i, spot in ipairs(currentNode.spots) do
            local x, y = Map.Project(spot, mapID)
            if x then
                local t = Acquire(spots, NewSpot)
                PlaceAt(t, areaFrame, x * W, -y * H)
                SizeTo(t, size, size)
                if checked[i] then Tint(t, 1, 1, 1, 0.3) else Tint(t, c[1], c[2], c[3], 1) end
            end
        end
    end

    -- Area labels: only for objectives within the next steps, current first, never overlapping.
    for i = #order, 1, -1 do order[i] = nil end
    if SP.db.mapLabels ~= false then -- labels can be turned off in settings
        for _, area in ipairs(areas) do
            if area.step <= MAX_STEPS then order[#order + 1] = area end
        end
        table.sort(order, EarlierStep)
    end
    for _, area in ipairs(order) do
        local f = Acquire(labels, NewLabel)
        local g = Given(f)
        local c = area.color
        -- Live count next to the name, e.g. "Plainstrider Beak  1/7".
        local count = SP.UI.CountText and SP.UI.CountText(area.node)
        local text = (area.title or "") .. (count and ("  |cffffffff" .. count .. "|r") or "")
        local sub = (area.current and area.quest ~= area.title) and area.quest or ""
        if g.text ~= text then
            f.text:SetText(text)
            g.text = text
        end
        if g.color ~= c then
            f.text:SetTextColor(min(1, c[1] + 0.2), min(1, c[2] + 0.2), min(1, c[3] + 0.2))
            g.color = c
        end
        if g.sub ~= sub then
            f.sub:SetText(sub)
            g.sub = sub
        end
        local w = (f.text:GetStringWidth() or 60) + 8
        local h = (f.text:GetStringHeight() or 12) + (sub ~= "" and 14 or 0) + 4
        local lx, ly = area.label.x * W / markerScale, -area.label.y * H / markerScale
        local placed
        for k = 1, #LABEL_SHIFTS do
            local dy = LABEL_SHIFTS[k] * (h + 6)
            if not Map.Overlaps(boxes, lx, ly + dy, w, h) then placed = ly + dy break end
        end
        if placed then
            ScaleTo(f, markerScale)
            PlaceAt(f, markerFrame, lx, placed)
            AddBox(lx, placed, w, h)
        else
            HideOne(f)
            labels.n = labels.n - 1 -- give the slot back
        end
    end

    HideFrom(lines, lines.n + 1)
    HideFrom(labels, labels.n + 1)
    HideFrom(markers, markers.n + 1)
    HideFrom(spots, spots.n + 1)
end

---------------------------------------------------------------------------
-- Provider
---------------------------------------------------------------------------

local function FrameLevel(map, levelType, fallback)
    local ok, level = pcall(function() return map:GetPinFrameLevelsManager():GetValidFrameLevel(levelType) end)
    return (ok and level) or fallback
end

function Map.Init()
    if provider or not (WorldMapFrame and WorldMapFrame.AddDataProvider and MapCanvasDataProviderMixin and CreateFromMixins) then
        return
    end
    provider = CreateFromMixins(MapCanvasDataProviderMixin)

    function provider:OnAdded(map)
        MapCanvasDataProviderMixin.OnAdded(self, map)
        local canvas = map:GetCanvas()
        areaFrame = CreateFrame("Frame", nil, canvas)
        areaFrame:SetAllPoints(canvas)
        areaFrame:SetFrameLevel(FrameLevel(map, "PIN_FRAME_LEVEL_QUEST_BLOB", 2000))
        markerFrame = CreateFrame("Frame", nil, canvas)
        markerFrame:SetAllPoints(canvas)
        markerFrame:SetFrameLevel(FrameLevel(map, "PIN_FRAME_LEVEL_AREA_POI", 2010))
        topLevel = FrameLevel(map, "PIN_FRAME_LEVEL_WAYPOINT_LOCATION", markerFrame:GetFrameLevel() + 40) + 1
    end

    function provider:RemoveAllData() HideAll() end
    function provider:RefreshAllData() Draw() end
    function provider:OnCanvasScaleChanged() Draw() end
    function provider:OnCanvasSizeChanged() Draw() end

    WorldMapFrame:AddDataProvider(provider)
end

-- Counts of what the last draw put on the map (for tests and /sp debugging).
function Map.Stats()
    return { blobs = blobs.n, markers = markers.n, lines = lines.n, labels = labels.n, steps = drawnSteps }
end

-- Called after plans and progress updates; only does work while the map is open.
function Map.Refresh()
    if provider and WorldMapFrame and WorldMapFrame:IsShown() then Draw() end
end

function Map.Toggle()
    SP.db.mapOverlay = not (SP.db.mapOverlay ~= false)
    if provider then
        if SP.db.mapOverlay then Draw() else HideAll() end
    end
    return SP.db.mapOverlay
end
