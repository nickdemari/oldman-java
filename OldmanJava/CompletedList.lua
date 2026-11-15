-- Oldman Java completed-quest browser: every quest the server reports this character has
-- turned in, at any level, searchable by name or zone.
local _, SP = ...

local List = {}
SP.CompletedList = List

local ROWS = 20
local ROW_HEIGHT = 22
local WIDTH, PAD = 500, 18

local frame, search, countText, rangeText
local rows = {}
local entries, filtered = {}, {}
local offset = 0

local function Build()
    local Data = SP.Data
    Data.RefreshCompleted()
    entries = {}
    for id in pairs(Data.completed) do
        local name = Data.QuestName(id)
        local level = Data.QuestLevel(id)
        local zone = Data.QuestZoneName(id) or ""
        entries[#entries + 1] = {
            id = id, name = name, level = level, zone = zone,
            haystack = (name .. " " .. zone):lower(),
        }
    end
    table.sort(entries, function(a, b)
        local la, lb = a.level or 0, b.level or 0
        if la ~= lb then return la < lb end
        return a.name < b.name
    end)
end

local function ApplyFilter()
    local query = search and search:GetText() or ""
    query = query:lower()
    if query == "" then
        filtered = entries
    else
        filtered = {}
        for _, e in ipairs(entries) do
            if e.haystack:find(query, 1, true) then filtered[#filtered + 1] = e end
        end
    end
    offset = 0
end

local function Render()
    if not frame then return end
    local total = #filtered
    local maxOffset = math.max(0, total - ROWS)
    if offset > maxOffset then offset = maxOffset end
    if offset < 0 then offset = 0 end
    for i = 1, ROWS do
        local row, e = rows[i], filtered[offset + i]
        if e then
            row.level:SetText(e.level and tostring(e.level) or "?")
            -- Level colour: how far below you the quest is now (blue-gray for long-outgrown quests).
            local diff = (e.level or 0) - (SP.Data.level or 0)
            local c = SP.Style.color
            local tint = (not e.level) and c.faint or (diff >= -2 and c.obj) or (diff >= -8 and c.pickup) or c.muted
            row.level:SetTextColor(tint[1], tint[2], tint[3])
            row.name:SetText(e.name)
            row.zone:SetText(e.zone)
            row.entry = e
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end
    countText:SetText(string.format("%d completed", #entries))
    if total == 0 then
        rangeText:SetText(#entries == 0 and "No completed quests reported by the server yet." or "No matches.")
    else
        rangeText:SetText(string.format("%d-%d of %d", offset + 1, math.min(offset + ROWS, total), total))
    end
end

local function Create()
    local Style = SP.Style
    local C = Style.color
    frame = CreateFrame("Frame", "OldmanJavaCompletedFrame", UIParent)
    frame:SetSize(WIDTH, 128 + ROWS * ROW_HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        offset = offset - delta * 3
        Render()
    end)
    tinsert(UISpecialFrames, "OldmanJavaCompletedFrame") -- Escape closes it
    Style.Panel(frame)

    local logo = Style.Logo(frame, 16)
    logo:SetPoint("TOPLEFT", PAD - 2, -10)
    local brand = Style.Text(frame, 11, C.accent)
    brand:SetPoint("TOPLEFT", PAD + 18, -14)
    brand:SetText("OLDMAN JAVA")
    local title = Style.Text(frame, 18, C.text)
    title:SetPoint("TOPLEFT", PAD, -32)
    title:SetText("Completed quests")
    countText = Style.Text(frame, 13, C.muted)
    countText:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 10, 1)

    local close = Style.Button(frame, "Close", function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -PAD + 2, -12)

    search = CreateFrame("EditBox", nil, frame)
    search:SetSize(WIDTH - PAD * 2, 28)
    search:SetPoint("TOPLEFT", PAD, -62)
    search:SetFont(Style.FONT, 14, "")
    search:SetTextColor(C.text[1], C.text[2], C.text[3])
    search:SetAutoFocus(false)
    search:SetTextInsets(12, 12, 0, 0)
    local searchBg = Style.Sliced(search, "BACKGROUND", "pill.tga", 8, { 1, 1, 1, 0.07 })
    searchBg:SetAllPoints()
    local placeholder = Style.Text(search, 14, C.faint)
    placeholder:SetPoint("LEFT", 12, 0)
    placeholder:SetText("Search by quest or zone")
    search:SetScript("OnTextChanged", function(self)
        placeholder:SetShown(self:GetText() == "")
        ApplyFilter()
        Render()
    end)
    search:SetScript("OnEditFocusGained", function() searchBg:SetVertexColor(1, 1, 1, 0.12) end)
    search:SetScript("OnEditFocusLost", function() searchBg:SetVertexColor(1, 1, 1, 0.07) end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local header = Style.Text(frame, 11, C.faint)
    header:SetPoint("TOPLEFT", PAD, -102)
    header:SetText("LVL      QUEST")
    local headerZone = Style.Text(frame, 11, C.faint)
    headerZone:SetPoint("TOPRIGHT", -PAD, -102)
    headerZone:SetJustifyH("RIGHT")
    headerZone:SetText("ZONE")

    for i = 1, ROWS do
        local row = CreateFrame("Frame", nil, frame)
        row:SetSize(WIDTH - PAD * 2, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", PAD, -118 - (i - 1) * ROW_HEIGHT)
        row:EnableMouse(true)
        local hl = Style.Sliced(row, "HIGHLIGHT", "pill.tga", 8, { 1, 1, 1, 0.07 })
        hl:SetPoint("TOPLEFT", -6, 0)
        hl:SetPoint("BOTTOMRIGHT", 6, 0)
        row.level = Style.Text(row, 13, C.soft)
        row.level:SetPoint("LEFT", 0, 0)
        row.level:SetWidth(28)
        row.level:SetJustifyH("RIGHT")
        row.zone = Style.Text(row, 13, C.muted)
        row.zone:SetPoint("RIGHT", 0, 0)
        row.zone:SetWidth(150)
        row.zone:SetJustifyH("RIGHT")
        row.name = Style.Text(row, 14, C.text)
        row.name:SetPoint("LEFT", row.level, "RIGHT", 12, 0)
        row.name:SetPoint("RIGHT", row.zone, "LEFT", -10, 0)
        row:SetScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.entry.name, 1, 1, 1)
            GameTooltip:AddLine("Quest ID " .. self.entry.id, 0.7, 0.7, 0.7)
            if self.entry.level then GameTooltip:AddLine("Level " .. self.entry.level, 0.7, 0.7, 0.7) end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[i] = row
    end

    rangeText = Style.Text(frame, 12, C.muted)
    rangeText:SetPoint("BOTTOMLEFT", PAD, 14)
    local hint = Style.Text(frame, 12, C.faint)
    hint:SetPoint("BOTTOMRIGHT", -PAD, 14)
    hint:SetJustifyH("RIGHT")
    hint:SetText("Scroll to browse")
    frame:Hide()
end

function List.Toggle()
    if not SP.ready then
        SP.Print(SP.error or "still loading.")
        return
    end
    if not frame then Create() end
    if frame:IsShown() then
        frame:Hide()
        return
    end
    Build()
    ApplyFilter()
    Render()
    frame:Show()
end

function List.Refresh()
    if frame and frame:IsShown() then
        local keep = offset
        Build()
        ApplyFilter()
        offset = keep
        Render()
    end
end
