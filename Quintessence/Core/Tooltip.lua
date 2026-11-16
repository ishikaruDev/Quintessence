local addon = WMacroCompiler
local Theme = addon.Theme

--[[-----------------------------------------------------------------------------
Tooltip (addon.Tooltip): WMC's own hover tooltip, in the theme's look (the
panel box and soft shadow of WMC's menu), so it looks the same whatever skin
another addon (ElvUI...) puts on the shared GameTooltip. Used inside WMC's
windows; the minimap button keeps GameTooltip, to match the minimap's other
buttons.

The calls mirror the GameTooltip ones WMC used:

  Tooltip:SetOwner(frame, anchor)  anchor: "ANCHOR_RIGHT" (beside the owner's
                                   top-right, going up), "ANCHOR_LEFT" (its
                                   top-left, going up) or "ANCHOR_TOPLEFT"
                                   (above it, left edges aligned)
  Tooltip:AddLine(text, r, g, b, wrap)   wrap: wrap at MAX_WIDTH
  Tooltip:SetText(text, r, g, b)   clears, then one line
  Tooltip:Show(), Tooltip:Hide(), Tooltip:IsShown(), Tooltip:IsOwned(frame)

The first line is in the gold heading font, the others in the small white
font (each line's own colour, when given, wins). It hides itself when its
owner is hidden. The box is measured again on the frame after it shows: a
font string first used then could measure short, the text running past the
box until the next hover.
-------------------------------------------------------------------------------]]
local Tooltip = { lines = {} }
addon.Tooltip = Tooltip

local PAD_X = 10
local PAD_Y = 8
local LINE_GAP = 2
local MAX_WIDTH = 280
local OFFSET = 4

local function measure(fontString, method, fallback)
    local value = fontString[method] and fontString[method](fontString)
    return (type(value) == "number" and value > 0) and math.ceil(value) or fallback
end

function Tooltip:Build()
    if self.frame then
        return self.frame
    end
    local frame = CreateFrame("Frame", "WMCTooltip", UIParent)
    frame:Hide()
    frame:SetFrameStrata("TOOLTIP")
    frame:SetClampedToScreen(true)
    self.shadow = Theme.CreateShadow(frame, 12, 3, 3)
    self.panel = Theme.CreatePanel(frame)
    frame:SetScript("OnUpdate", function()
        if not (self.owner and self.owner:IsVisible()) then
            self:Hide()
        elseif self.remeasure then
            self.remeasure = nil
            self:Layout()
        end
    end)
    self.frame = frame
    self.fontStrings = {}
    return frame
end

function Tooltip:SetOwner(owner, anchor)
    self:Build()
    self.owner = owner
    self.anchor = anchor or "ANCHOR_RIGHT"
    self.lines = {}
end

function Tooltip:IsOwned(owner)
    return self.owner == owner and self:IsShown()
end

function Tooltip:AddLine(text, r, g, b, wrap)
    local color = r and { r, g, b } or nil
    table.insert(self.lines, { text = tostring(text or ""), color = color, wrap = wrap and true or false })
end

function Tooltip:SetText(text, r, g, b)
    self.lines = {}
    self:AddLine(text, r, g, b)
end

-- Lays the lines out and places the box beside its owner.
function Tooltip:Show()
    local frame = self:Build()
    if not self.owner or #self.lines == 0 then
        return
    end
    self:Layout()
    self.remeasure = true
    frame:Show()
end

-- Sizes the box to its lines.
function Tooltip:Layout()
    local frame = self.frame
    -- Width: the widest line (wrapped lines at most MAX_WIDTH).
    local width = 0
    for index, line in ipairs(self.lines) do
        local fontString = self.fontStrings[index]
        if not fontString then
            fontString = frame:CreateFontString(nil, "OVERLAY")
            fontString:SetJustifyH("LEFT")
            self.fontStrings[index] = fontString
        end
        local heading = index == 1
        fontString:SetFontObject(heading and GameFontNormal or GameFontHighlightSmall)
        local color = line.color or (heading and Theme.colors.title or Theme.colors.text)
        fontString:SetTextColor(color[1], color[2], color[3])
        fontString:SetWidth(0)
        fontString:SetText(line.text)
        local natural = measure(fontString, "GetStringWidth", #line.text * 6)
        width = math.max(width, line.wrap and math.min(natural, MAX_WIDTH) or natural)
        fontString:Show()
    end
    for index = #self.lines + 1, #self.fontStrings do
        self.fontStrings[index]:Hide()
    end
    -- A line that doesn't wrap keeps no width: set to exactly its measured
    -- width, the client's pixel snapping can draw it a fraction wider and
    -- wrap it onto a second row. Wrapped lines get a pixel of slack.
    local y = PAD_Y
    for index, line in ipairs(self.lines) do
        local fontString = self.fontStrings[index]
        fontString:SetWidth(line.wrap and width + 1 or 0)
        fontString:ClearAllPoints()
        fontString:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_X, -y)
        y = y + measure(fontString, "GetStringHeight", 12) + LINE_GAP
    end
    frame:SetWidth(width + 2 * PAD_X)
    frame:SetHeight(y - LINE_GAP + PAD_Y)

    local owner = self.owner
    frame:ClearAllPoints()
    if self.anchor == "ANCHOR_LEFT" then
        frame:SetPoint("BOTTOMRIGHT", owner, "TOPLEFT", -OFFSET, 0)
    elseif self.anchor == "ANCHOR_TOPLEFT" then
        frame:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", 0, OFFSET)
    else
        frame:SetPoint("BOTTOMLEFT", owner, "TOPRIGHT", OFFSET, 0)
    end
end

function Tooltip:Hide()
    self.owner = nil
    if self.frame then
        self.frame:Hide()
    end
end

function Tooltip:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end
