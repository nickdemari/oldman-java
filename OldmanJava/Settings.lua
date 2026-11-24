-- Oldman Java settings window: every option in one place, in the same style as the route panel.
-- Open with /java settings, the Settings button on the panel, or Esc > Options > AddOns > Oldman Java.
local _, SP = ...

local Settings = {}
SP.Settings = Settings

local WIDTH, PAD = 460, 20
local CONTROL_W = 170
local frame
local controls = {}

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------

local function Style() return SP.Style end

-- On/off switch: pill track with a sliding knob.
local function Toggle(parent, get, set)
    local S, C = Style(), Style().color
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(42, 22)
    b.track = S.Sliced(b, "BACKGROUND", "pill.tga", 8, { 1, 1, 1, 0.14 })
    b.track:SetAllPoints()
    b.knob = b:CreateTexture(nil, "ARTWORK")
    b.knob:SetTexture(S.MEDIA .. "disc.tga")
    b.knob:SetSize(16, 16)
    function b:Refresh()
        local on = get()
        if on then
            self.track:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.95)
            self.knob:SetVertexColor(1, 1, 1, 1)
        else
            self.track:SetVertexColor(1, 1, 1, 0.14)
            self.knob:SetVertexColor(0.75, 0.78, 0.82, 1)
        end
        self.knob:ClearAllPoints()
        self.knob:SetPoint("LEFT", self, "LEFT", on and 23 or 3, 0)
    end
    b:SetScript("OnClick", function(self)
        set(not get())
        Settings.Refresh()
    end)
    return b
end

-- Segmented choice: one pill per option, the selected one filled.
local function Segmented(parent, options, get, set)
    local S, C = Style(), Style().color
    local f = CreateFrame("Frame", nil, parent)
    f.bg = S.Sliced(f, "BACKGROUND", "pill.tga", 8, { 1, 1, 1, 0.07 })
    f.bg:SetAllPoints()
    f.buttons = {}
    local x = 3
    for i, opt in ipairs(options) do
        local b = CreateFrame("Button", nil, f)
        b.fill = S.Sliced(b, "BORDER", "pill.tga", 8, { 1, 1, 1, 0 })
        b.fill:SetAllPoints()
        b.text = S.Text(b, 12, C.soft)
        b.text:SetPoint("CENTER")
        b.text:SetText(opt.label)
        b:SetSize(math.max(48, b.text:GetStringWidth() + 22), 20)
        b:SetPoint("LEFT", f, "LEFT", x, 0)
        x = x + b:GetWidth() + 2
        b.value = opt.value
        b:SetScript("OnClick", function()
            set(opt.value)
            Settings.Refresh()
        end)
        f.buttons[i] = b
    end
    f:SetSize(x + 1, 26)
    function f:Refresh()
        local current = get()
        for _, b in ipairs(self.buttons) do
            if b.value == current then
                b.fill:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.95)
                b.text:SetTextColor(0.04, 0.05, 0.08)
            else
                b.fill:SetVertexColor(1, 1, 1, 0)
                b.text:SetTextColor(C.soft[1], C.soft[2], C.soft[3])
            end
        end
    end
    return f
end

-- Horizontal slider with a filled track and the value on the right.
local function SliderControl(parent, minValue, maxValue, step, get, set, format)
    local S, C = Style(), Style().color
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(CONTROL_W, 22)
    local s = CreateFrame("Slider", nil, f)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(CONTROL_W - 46, 16)
    s:SetPoint("LEFT")
    s:SetMinMaxValues(minValue, maxValue)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:EnableMouseWheel(true)
    local track = S.Sliced(s, "BACKGROUND", "bar.tga", 3, { 1, 1, 1, 0.12 })
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(6)
    local fill = S.Sliced(s, "BORDER", "bar.tga", 3, C.accent)
    fill:SetPoint("LEFT")
    fill:SetHeight(6)
    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(S.MEDIA .. "disc.tga")
    thumb:SetSize(14, 14)
    s:SetThumbTexture(thumb)
    local text = S.Text(f, 12, C.soft)
    text:SetPoint("RIGHT")
    text:SetJustifyH("RIGHT")
    local updating = false
    local function Show(value)
        local width = s:GetWidth() or (CONTROL_W - 46)
        fill:SetWidth(math.max(6, width * (value - minValue) / (maxValue - minValue)))
        text:SetText(format(value))
    end
    s:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value / step + 0.5) * step
        Show(value)
        if not updating then set(value) end
    end)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(math.max(minValue, math.min(maxValue, self:GetValue() + delta * step)))
    end)
    function f:Refresh()
        updating = true
        local value = get()
        s:SetValue(value)
        Show(value)
        updating = false
    end
    return f
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function Section(y, title)
    local S, C = Style(), Style().color
    local header = S.Text(frame, 11, C.accent)
    header:SetPoint("TOPLEFT", PAD, y)
    header:SetText(title)
    local rule = frame:CreateTexture(nil, "BORDER")
    rule:SetColorTexture(1, 1, 1, 0.07)
    rule:SetHeight(1)
    rule:SetPoint("LEFT", header, "RIGHT", 10, 0)
    rule:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
    return y - 26
end

-- A row: label and description on the left, a control on the right.
local function Row(y, label, description, control, refresh)
    local S, C = Style(), Style().color
    local title = S.Text(frame, 13, C.text)
    title:SetPoint("TOPLEFT", PAD, y)
    title:SetText(label)
    -- Text gets whatever the control leaves free, so wide controls never cover it.
    local textWidth = WIDTH - PAD * 2 - (control:GetWidth() or CONTROL_W) - 24
    title:SetWidth(textWidth)
    local h = title:GetStringHeight()
    local desc
    if description then
        desc = S.Text(frame, 11, C.muted)
        desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
        desc:SetWidth(textWidth)
        desc:SetWordWrap(true)
        if type(description) == "function" then
            desc.dynamic = description
            desc:SetText(description())
        else
            desc:SetText(description)
        end
        h = h + 3 + desc:GetStringHeight()
    end
    control:ClearAllPoints()
    control:SetPoint("RIGHT", frame, "TOPRIGHT", -PAD, y - math.max(h, control:GetHeight()) / 2)
    controls[#controls + 1] = { control = control, desc = desc }
    return y - math.max(h, control:GetHeight()) - 16
end

local function ActionButton(label, onClick)
    local b = Style().Button(frame, label, onClick)
    b:SetHeight(24)
    b.Refresh = function() end
    return b
end

local function SkippedCount()
    local n = 0
    for _ in pairs(SP.char and SP.char.skipped or {}) do n = n + 1 end
    return n
end

local function Build()
    local S, C = Style(), Style().color
    frame = CreateFrame("Frame", "OldmanJavaSettingsFrame", UIParent)
    frame:SetWidth(WIDTH)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetScript("OnShow", function() Settings.Refresh() end)
    tinsert(UISpecialFrames, "OldmanJavaSettingsFrame") -- Escape closes it
    S.Panel(frame)

    local logo = S.Logo(frame, 16)
    logo:SetPoint("TOPLEFT", PAD - 2, -12)
    local brand = S.Text(frame, 11, C.accent)
    brand:SetPoint("TOPLEFT", PAD + 18, -16)
    brand:SetText("OLDMAN JAVA")
    local title = S.Text(frame, 18, C.text)
    title:SetPoint("TOPLEFT", PAD, -34)
    title:SetText("Settings")
    local close = S.Button(frame, "Close", function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -PAD + 4, -14)

    local db = function() return SP.db end
    local y = -70

    y = Section(y, "ROUTE")
    y = Row(y, "Difficulty", "Max levels above you for quests and mobs.",
        Segmented(frame, {
            { value = "easy", label = "Easy +1" },
            { value = "normal", label = "Normal +2" },
            { value = "hard", label = "Hard +4" },
        }, function() return db().difficulty or "normal" end, function(v)
            db().difficulty = v
            SP.Data.ClearLocationCache() -- which mobs count as farmable depends on the cap
            SP.RequestPlan()
        end))
    y = Row(y, "Always include class quests", "Spells, pets, totems and forms stay on the route even when they give little XP.",
        Toggle(frame, function() return db().classQuests ~= false end, function(v)
            db().classQuests = v
            SP.RequestPlan()
        end))
    y = Row(y, "Fly and hearth when it's quicker", "Uses the flight paths you know and your hearthstone.",
        Toggle(frame, function() return db().shortcuts ~= false end, function(v)
            db().shortcuts = v
            SP.RequestPlan()
        end))
    y = Row(y, "Accept and turn in for me", "Takes the quests your route wants and hands in finished ones. Hold Shift to do it yourself.",
        Toggle(frame, function() return db().autoQuest ~= false end, function(v)
            db().autoQuest = v
        end))
    y = Row(y, "Skipped quests", function()
        local n = SkippedCount()
        return n == 0 and "You haven't skipped any quests." or string.format("%d skipped. Clear to put them back on the route.", n)
    end, ActionButton("Clear", function()
        if SP.char then SP.char.skipped = {} end
        SP.RequestPlan()
        Settings.Refresh()
    end))
    y = Row(y, "Completed quests", "Every quest this character has turned in, at any level.",
        ActionButton("Open", function()
            if SP.CompletedList then SP.CompletedList.Toggle() end
        end))

    y = y - 6
    y = Section(y, "NAVIGATION")
    y = Row(y, "Map overlay", "Quest areas, numbered steps and the route line on the world map.",
        Toggle(frame, function() return db().mapOverlay ~= false end, function(v)
            db().mapOverlay = v
            if SP.Map then SP.Map.Refresh() end
        end))
    y = Row(y, "Area labels on the map", "Names on the shaded areas for your next steps.",
        Toggle(frame, function() return db().mapLabels ~= false end, function(v)
            db().mapLabels = v
            if SP.Map then SP.Map.Refresh() end
        end))
    y = Row(y, "Waypoint and beacon", "Blizzard's map waypoint and on-screen beacon on your current step.",
        Toggle(frame, function() return db().waypoint ~= false end, function(v)
            db().waypoint = v
            if SP.UI then SP.UI.Render() end -- sets or clears the waypoint; keeps the status line
        end))

    y = y - 6
    y = Section(y, "PANEL")
    y = Row(y, "Show panel", nil,
        Toggle(frame, function() return db().shown ~= false end, function(v)
            if SP.UI then SP.UI.Toggle(v) end
        end))
    y = Row(y, "Lock position", "Stops the panel from being dragged.",
        Toggle(frame, function() return db().locked == true end, function(v)
            db().locked = v
        end))
    y = Row(y, "Up next lines", "How many upcoming steps the panel lists.",
        SliderControl(frame, 0, 6, 1, function() return db().nextLines or 4 end, function(v)
            db().nextLines = v
            if SP.UI then SP.UI.Render() end
        end, function(v) return tostring(v) end))
    y = Row(y, "Size", "Also works with Ctrl + scroll over the panel.",
        SliderControl(frame, 0.7, 1.6, 0.05, function() return db().scale or 1 end, function(v)
            if SP.UI then SP.UI.SetScale(v) end
        end, function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end))
    y = Row(y, "Position", "Moves the panel back to its starting spot.",
        ActionButton("Reset", function()
            if SP.UI then SP.UI.ResetPosition() end
            Settings.Refresh()
        end))

    local version = S.Text(frame, 11, C.faint)
    version:SetPoint("TOPLEFT", PAD, y - 2)
    version:SetText("Oldman Java " .. tostring(SP.version) .. "  ·  /java settings")
    frame:SetHeight(-y + 30)
    frame:Hide()
end

function Settings.Refresh()
    if not frame then return end
    for _, row in ipairs(controls) do
        if row.control.Refresh then row.control:Refresh() end
        if row.desc and row.desc.dynamic then row.desc:SetText(row.desc.dynamic()) end
    end
end

function Settings.Open()
    if not SP.db then return end
    if not frame then Build() end
    frame:Show()
    Settings.Refresh()
end

function Settings.Toggle()
    if frame and frame:IsShown() then frame:Hide() else Settings.Open() end
end

-- Esc > Options > AddOns > Oldman Java: a short page with a button to this window.
function Settings.RegisterBlizzardCategory()
    if Settings.category or not (_G.Settings and _G.Settings.RegisterCanvasLayoutCategory) then return end
    local S, C = Style(), Style().color
    local page = CreateFrame("Frame")
    local title = S.Text(page, 18, C.text)
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Oldman Java")
    local text = S.Text(page, 13, C.muted)
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    text:SetWidth(420)
    text:SetWordWrap(true)
    text:SetText("Oldman Java's settings live in their own window. You can also open it with /java settings.")
    local open = S.Button(page, "Open Oldman Java settings", function() Settings.Open() end)
    open:SetHeight(26)
    open:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -14)
    local ok, category = pcall(_G.Settings.RegisterCanvasLayoutCategory, page, "Oldman Java")
    if ok and category then
        pcall(_G.Settings.RegisterAddOnCategory, category)
        Settings.category = category
    end
end
