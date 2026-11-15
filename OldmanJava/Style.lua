-- Oldman Java visual style: palette, fonts and the rounded-panel building blocks shared by every window.
local _, SP = ...

local Style = {}
SP.Style = Style

local MEDIA = "Interface\\AddOns\\OldmanJava\\media\\"
Style.MEDIA = MEDIA
Style.FONT = "Fonts\\FRIZQT__.TTF" -- WoW's own UI font; present on every client

-- Coffee: espresso panels, crema text, caramel accent. Step colours stay clearly apart.
Style.color = {
    panel = { 0.067, 0.047, 0.036, 0.94 },
    panelTop = { 0.125, 0.088, 0.066, 0.94 },
    border = { 1, 0.86, 0.66, 0.09 },
    text = { 0.98, 0.94, 0.87 },
    soft = { 0.91, 0.86, 0.78 },
    muted = { 0.76, 0.69, 0.60 },
    faint = { 0.58, 0.51, 0.44 },
    accent = { 0.86, 0.62, 0.33 },
    pickup = { 0.56, 0.84, 0.46 },
    obj = { 1.00, 0.76, 0.30 },
    turnin = { 0.45, 0.70, 1.00 },
    travel = { 0.80, 0.58, 0.95 },
    class = { 1.00, 0.56, 0.24 },
    good = { 0.42, 0.90, 0.52 },
    warn = { 1.00, 0.80, 0.30 },
    bad = { 1.00, 0.46, 0.36 },
}

function Style.Hex(c)
    return string.format("%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5),
        math.floor(c[3] * 255 + 0.5))
end

function Style.Text(parent, size, color, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(Style.FONT, size, "")
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.75)
    color = color or Style.color.text
    fs:SetTextColor(color[1], color[2], color[3], color[4] or 1)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- The Oldman Java cup logo, tinted caramel.
function Style.Logo(parent, size)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetTexture(MEDIA .. "cup.tga")
    t:SetSize(size, size)
    local c = Style.color.accent
    t:SetVertexColor(c[1], c[2], c[3], 1)
    return t
end

-- A texture drawn as a 9-slice so its rounded corners keep their size at any width or height.
function Style.Sliced(parent, layer, file, margin, color, sublevel)
    local t = parent:CreateTexture(nil, layer, nil, sublevel or 0)
    t:SetTexture(MEDIA .. file)
    if t.SetTextureSliceMargins then
        t:SetTextureSliceMargins(margin, margin, margin, margin)
        if t.SetTextureSliceMode and Enum and Enum.UITextureSliceMode then
            t:SetTextureSliceMode(Enum.UITextureSliceMode.Stretched)
        end
    end
    if color then t:SetVertexColor(color[1], color[2], color[3], color[4] or 1) end
    return t
end

-- Rounded glass panel: soft shadow, body with a subtle top-down gradient, hairline border.
function Style.Panel(frame)
    local C = Style.color
    local shadow = Style.Sliced(frame, "BACKGROUND", "shadow.tga", 28, { 0, 0, 0, 0.55 }, -8)
    shadow:SetPoint("TOPLEFT", -14, 12)
    shadow:SetPoint("BOTTOMRIGHT", 14, -16)
    local body = Style.Sliced(frame, "BACKGROUND", "panel.tga", 16, C.panel, -7)
    body:SetAllPoints()
    if body.SetGradient and CreateColor then
        pcall(body.SetGradient, body, "VERTICAL",
            CreateColor(C.panel[1], C.panel[2], C.panel[3], C.panel[4]),
            CreateColor(C.panelTop[1], C.panelTop[2], C.panelTop[3], C.panelTop[4]))
    end
    local border = Style.Sliced(frame, "BORDER", "border.tga", 16, C.border)
    border:SetAllPoints()
    return body
end

-- Small pill button with a hover state.
function Style.Button(parent, label, onClick, tooltip)
    local C = Style.color
    local button = CreateFrame("Button", nil, parent)
    button:SetHeight(22)
    local bg = Style.Sliced(button, "BACKGROUND", "pill.tga", 8, { 1, 1, 1, 0.08 })
    bg:SetAllPoints()
    local text = Style.Text(button, 12, C.soft)
    text:SetPoint("CENTER", 0, 0)
    text:SetText(label)
    button:SetWidth(math.max(40, math.floor(text:GetStringWidth() + 18)))
    button:SetScript("OnEnter", function(self)
        bg:SetVertexColor(1, 1, 1, 0.18)
        text:SetTextColor(C.text[1], C.text[2], C.text[3])
        if tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(tooltip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    button:SetScript("OnLeave", function()
        bg:SetVertexColor(1, 1, 1, 0.08)
        text:SetTextColor(C.soft[1], C.soft[2], C.soft[3])
        GameTooltip:Hide()
    end)
    button:SetScript("OnClick", onClick)
    button.label = text
    return button
end

-- Rounded progress bar with an optional ghost segment (e.g. XP this route will add).
function Style.Bar(parent, height, color)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(height)
    bar.track = Style.Sliced(bar, "BACKGROUND", "bar.tga", 3, { 1, 1, 1, 0.08 })
    bar.track:SetAllPoints()
    bar.ghost = Style.Sliced(bar, "BORDER", "bar.tga", 3, { color[1], color[2], color[3], 0.30 })
    bar.ghost:SetPoint("TOPLEFT")
    bar.ghost:SetPoint("BOTTOMLEFT")
    bar.fill = Style.Sliced(bar, "ARTWORK", "bar.tga", 3, color)
    bar.fill:SetPoint("TOPLEFT")
    bar.fill:SetPoint("BOTTOMLEFT")
    -- fraction: 0-1 filled; ghost: 0-1 total including the ghost segment.
    function bar:SetValues(fraction, ghost)
        local width = self:GetWidth()
        if not width or width <= 0 then return end
        local minWidth = height -- keep the rounded ends intact
        fraction = math.max(0, math.min(1, fraction or 0))
        ghost = math.max(fraction, math.min(1, ghost or 0))
        self.fill:SetShown(fraction > 0)
        self.fill:SetWidth(math.max(minWidth, width * fraction))
        self.ghost:SetShown(ghost > fraction)
        self.ghost:SetWidth(math.max(minWidth, width * ghost))
    end
    function bar:SetColor(c)
        self.fill:SetVertexColor(c[1], c[2], c[3], 1)
        self.ghost:SetVertexColor(c[1], c[2], c[3], 0.30)
    end
    return bar
end

function Style.FormatDistance(yards)
    if not yards then return "" end
    if yards < 1000 then return string.format("%d yd", yards) end
    return string.format("%.1fk yd", yards / 1000)
end

function Style.FormatDuration(seconds)
    seconds = math.max(0, seconds or 0)
    if seconds < 90 then return "1 min" end
    local minutes = math.floor(seconds / 60 + 0.5)
    if minutes < 60 then return minutes .. " min" end
    return string.format("%dh %02dm", math.floor(minutes / 60), minutes % 60)
end

-- Travel time: "39s", "1m 05s", "1h 02m".
function Style.FormatETA(seconds)
    seconds = math.max(0, math.floor((seconds or 0) + 0.5))
    if seconds < 60 then return seconds .. "s" end
    if seconds < 3600 then return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60) end
    return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor(seconds / 60) % 60)
end

function Style.FormatXP(xp)
    xp = math.floor((xp or 0) + 0.5)
    if xp < 1000 then return tostring(xp) end
    if xp < 10000 then return string.format("%.1fk", xp / 1000) end
    return string.format("%dk", math.floor(xp / 1000 + 0.5))
end
