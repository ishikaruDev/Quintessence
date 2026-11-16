local addon = WMacroCompiler
local Theme = addon.Theme

--[[-----------------------------------------------------------------------------
MinimapButton (addon.MinimapButton): the round brass flask button on the
minimap edge. Left-click opens / closes the WMC window; drag it along the
edge to move it. /qmc minimap hides or shows it.

The art (Media/MinimapIcon.tga) carries its own brass ring, so the button is
just that texture: no Blizzard tracking border around it. Positioning
follows LibDBIcon's rules (not bundled): an angle around the minimap, on a
circle for round minimaps and pushed out to the edge for square ones
(GetMinimapShape, which ElvUI and other minimap addons provide).

Saved (account-wide): settings.minimap = { angle = degrees, hide = bool }.
-------------------------------------------------------------------------------]]
local MinimapButton = {}
addon.MinimapButton = MinimapButton

local SIZE = 32
local DEFAULT_ANGLE = 225 -- lower left, LibDBIcon's default
local EDGE_OFFSET = 5     -- button centre beyond the minimap's edge
local TEXTURE = addon.ThemeData.path .. "MinimapIcon"

MinimapButton.SIZE = SIZE

-- Which quadrants (1 = top right, 2 = top left, 3 = bottom right, 4 =
-- bottom left) are round for each minimap shape (from LibDBIcon).
local SHAPES = {
    ["ROUND"] = { true, true, true, true },
    ["SQUARE"] = { false, false, false, false },
    ["CORNER-TOPLEFT"] = { false, false, false, true },
    ["CORNER-TOPRIGHT"] = { false, false, true, false },
    ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
    ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
    ["SIDE-LEFT"] = { false, true, false, true },
    ["SIDE-RIGHT"] = { true, false, true, false },
    ["SIDE-TOP"] = { false, false, true, true },
    ["SIDE-BOTTOM"] = { true, true, false, false },
    ["TRICORNER-TOPLEFT"] = { false, true, true, true },
    ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
    ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
    ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

local function settings()
    local db = addon.db and addon.db.settings
    if not db then
        return { angle = DEFAULT_ANGLE }
    end
    db.minimap = db.minimap or {}
    db.minimap.angle = db.minimap.angle or DEFAULT_ANGLE
    return db.minimap
end

-- Offset of the button's centre from the minimap's centre for `angle`.
function MinimapButton.Offset(angle, shape, radius)
    local rad = math.rad(angle)
    local x, y = math.cos(rad), math.sin(rad)
    local quadrant = 1
    if x < 0 then
        quadrant = quadrant + 1
    end
    if y > 0 then
        quadrant = quadrant + 2
    end
    local round = (SHAPES[shape] or SHAPES.ROUND)[quadrant]
    if round then
        return x * radius, y * radius
    end
    -- Square corner: go out along the diagonal, then clamp to the edge.
    local diagonal = math.sqrt(2 * radius * radius) - 10
    x = math.max(-radius, math.min(x * diagonal, radius))
    y = math.max(-radius, math.min(y * diagonal, radius))
    return x, y
end

function MinimapButton:UpdatePosition()
    local button = self.button
    if not button then
        return
    end
    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local radius = (Minimap:GetWidth() or 140) / 2 + EDGE_OFFSET
    local x, y = MinimapButton.Offset(settings().angle, shape, radius)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- The cursor's angle around the minimap's centre, in degrees.
local function cursorAngle()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale() or 1
    if not (mx and my and px and py) or scale <= 0 then
        return nil
    end
    return math.deg(math.atan2(py / scale - my, px / scale - mx)) % 360
end

local function Button_OnDragUpdate()
    local angle = cursorAngle()
    if angle then
        settings().angle = angle
        MinimapButton:UpdatePosition()
    end
end

local function Button_OnDragStart(button)
    button:LockHighlight()
    button.icon:SetVertexColor(0.8, 0.8, 0.8)
    button:SetScript("OnUpdate", Button_OnDragUpdate)
    if GameTooltip then
        GameTooltip:Hide()
    end
end

local function Button_OnDragStop(button)
    button:SetScript("OnUpdate", nil)
    button:UnlockHighlight()
    button.icon:SetVertexColor(1, 1, 1)
end

local function Button_OnClick(button, mouseButton)
    if mouseButton == "LeftButton" then
        addon.UI:Toggle()
    end
end

-- Pressed: the face sinks a little, like the theme's buttons.
local function Button_OnMouseDown(button)
    button.icon:ClearAllPoints()
    button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, -1)
    button.icon:SetVertexColor(0.8, 0.8, 0.8)
end

local function Button_OnMouseUp(button)
    button.icon:ClearAllPoints()
    button.icon:SetAllPoints(button)
    button.icon:SetVertexColor(1, 1, 1)
end

local function Button_OnEnter(button)
    if not GameTooltip then
        return
    end
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    local title = Theme.colors.title
    GameTooltip:AddLine(addon.TITLE, title[1], title[2], title[3])
    GameTooltip:AddLine("Click to open or close.", 1, 1, 1)
    GameTooltip:AddLine("Drag to move. /qmc minimap hides it.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function Button_OnLeave()
    if GameTooltip then
        GameTooltip:Hide()
    end
end

function MinimapButton:Build()
    if self.button or not Minimap then
        return
    end
    local button = CreateFrame("Button", "WMCMinimapButton", Minimap)
    button:SetWidth(SIZE)
    button:SetHeight(SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(TEXTURE)
    icon:SetAllPoints(button)
    button.icon = icon
    -- Hover: the same art added over itself, a soft brightening glow.
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture(TEXTURE)
    highlight:SetAllPoints(button)
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.35)
    button.highlight = highlight
    button:SetScript("OnClick", Button_OnClick)
    button:SetScript("OnMouseDown", Button_OnMouseDown)
    button:SetScript("OnMouseUp", Button_OnMouseUp)
    button:SetScript("OnDragStart", Button_OnDragStart)
    button:SetScript("OnDragStop", Button_OnDragStop)
    button:SetScript("OnEnter", Button_OnEnter)
    button:SetScript("OnLeave", Button_OnLeave)
    self.button = button
end

-- At login, once the saved settings are loaded.
function MinimapButton:Initialize()
    self:Build()
    self:Refresh()
end

function MinimapButton:Refresh()
    local button = self.button
    if not button then
        return
    end
    if settings().hide then
        button:Hide()
    else
        self:UpdatePosition()
        button:Show()
    end
end

function MinimapButton:IsShown()
    return self.button ~= nil and self.button:IsShown()
end

-- /qmc minimap: hide / show.
function MinimapButton:Toggle()
    local saved = settings()
    saved.hide = not saved.hide or nil
    self:Refresh()
    if saved.hide then
        addon:Print("Minimap button hidden. /qmc minimap shows it again.")
    else
        addon:Print("Minimap button shown.")
    end
end
