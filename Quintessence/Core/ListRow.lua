local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme

-- Template-list row backgrounds, as final opaque colors { r, g, b }. The
-- list's panel is opaque and dark, so these read the same as the old
-- alpha-blended palette composited over black; opaque fills let adjacent
-- rows overlap by a pixel without visible seams (see Constructor).
addon.RowPalette = {
    -- selected = { 0.13, 0.26, 0.47 }, -- dark steel blue
    selected = { 0.08, 0.35, 0.30 }, -- lighter pine green
    error = { 0.40, 0.07, 0.07 }, -- dark red
    header = { 0.07, 0.07, 0.09 }, -- category headers
    general = { 0.17, 0.17, 0.17 }, -- GENERAL scope rows
    classScale = 0.45, -- darkened class color for normal rows
    disabledScale = 0.10, -- even darker for disabled templates
    hoverAlpha = 0.10,
    frameHoverAlpha = 0.45, -- the hovered template row's frame (selected: full)
}

-- The raw (unscaled) class color for a scope, or false for GENERAL / unknown
-- scopes. Shared by TemplateRowColor (selected-row fill) and the row's
-- hover tint, so both agree on what "this row's class color" means.
function addon.ClassColor(scope)
    return scope ~= "GENERAL" and RAID_CLASS_COLORS and RAID_CLASS_COLORS[scope]
end

-- Background color for a template row. Priority: error > selected > resting.
-- Resting (unselected, non-error) rows return nil -- no fill at all, so the
-- class-color wash only ever shows up on the one row that's actually
-- selected.
function addon.TemplateRowColor(scope, isError, isSelected, isDisabled)
    local palette = addon.RowPalette
    if isError then
        return unpack(palette.error)
    end
    if isSelected then
        local color = addon.ClassColor(scope)
        local scale = isDisabled and palette.disabledScale or palette.classScale
        if color then
            return color.r * scale, color.g * scale, color.b * scale
        end
        return unpack(palette.selected) -- GENERAL scope: no class to color by
    end
    return nil -- intentional: resting rows are unfilled
end

--[[-----------------------------------------------------------------------------
WMC-ListRow widget: one row in the template list.

A plain Button with a full-row background texture, a hover glow, an optional
collapse toggle (category headers: the theme's brass arrows), an optional
clickable icon (templates; black square when no icon is set) in a drawn
two-tone metal rim, and a left-justified label. The rim turns gold while the
row is hovered or selected (SetSelected). A template row is framed in the
panel's rim (the panel art with its interior cleared, scaled down) while
selected or in error (SetError), and faintly while hovered; the fill then
runs under the rim. Those rows' fill and hover glow use SharedMedia's
Glamour4 texture when it is installed.

A template's key, when it has one, ends the row in faint text (SetKeyText,
as an action button's hotkey); the label then stops short of it, a long
name cut with "...".

Callbacks: OnClick, OnRightClick, OnIconClick, OnToggle, OnEnter, OnLeave.
-------------------------------------------------------------------------------]]
local Type, Version = "WMC-ListRow", 6

local ROW_HEIGHT = 26      -- category headers (no icon)
local ICON_ROW_HEIGHT = 32 -- template rows
local ICON_SIZE = 22       -- the icon with its rim
-- Left inset for row content (header toggles, the label's right end).
local PADDING = 3
-- The icon's left inset; equals its vertical padding so the icon is
-- uniformly padded, clear of the row frame's rim.
local ICON_PADDING = (ICON_ROW_HEIGHT - ICON_SIZE) / 2
-- The row frame: the panel-rim piece at this scale (rim ~3 units, corners ~6).
local FRAME_SCALE = 0.75
-- The fill's inset from the row's edges while framed: its edges end under
-- the rim (texels 1-3 of the art), clear of the rounded outer corners.
local FRAME_FILL_INSET = 1.5
local TOGGLE_SIZE = 12
local KEY_GAP = 4            -- between the label and the key
local KEY_COLOR = { 0.62, 0.62, 0.62 }
local BLACK_SQUARE = "Interface\\Buttons\\WHITE8X8"
-- Same corner-notch crop as UI.lua's editor icon (see comment there),
-- applied here so the small row icons read as squares too.
local ICON_ZOOM = 0.08
-- The selected, erroring and hovered template rows' fill: SharedMedia's
-- Glamour4 status-bar texture, tinted with the row's color. Without
-- SharedMedia the rows keep their flat fills.
local GLAMOUR_TEXTURE = "Interface\\AddOns\\SharedMedia\\Media\\Statusbar\\Glamour4"

-- Whether the Glamour texture exists, probed once: SetTexture returns nil
-- for a file that isn't on disk.
local glamourAvailable
local function GlamourAvailable()
    if glamourAvailable == nil then
        local probe = UIParent:CreateTexture()
        glamourAvailable = probe:SetTexture(GLAMOUR_TEXTURE) and true or false
        probe:SetTexture(nil)
        probe:Hide()
    end
    return glamourAvailable
end

-- Paints a fill texture in a color: tinted Glamour on template rows that are
-- selected, in error or hovered (when SharedMedia is installed), a flat
-- color otherwise.
local function PaintFill(self, texture, r, g, b, a)
    if self.iconShown and (self.selected or self.error or self.hovered) and GlamourAvailable() then
        texture:SetTexture(GLAMOUR_TEXTURE)
        texture:SetVertexColor(r, g, b, a)
    else
        texture:SetTexture(r, g, b, a)
        texture:SetVertexColor(1, 1, 1, 1)
    end
end

-- Repaints the row's fill and hover glow for its current state.
local function UpdateFill(self)
    local fill = self.fillColor
    if fill then
        PaintFill(self, self.background, fill[1], fill[2], fill[3], 1)
    end
    local glow = self.hoverColor
    PaintFill(self, self.hover, glow[1], glow[2], glow[3], addon.RowPalette.hoverAlpha)
end

-- The rim's inner line: brass at rest, gold while hovered or selected.
local function UpdateRim(self)
    local color = (self.hovered or self.selected) and Theme.colors.gold or Theme.colors.rimBrass
    self.rimInner:SetTexture(color[1], color[2], color[3], 1)
end

-- The panel frame: full while selected or in error, faint while hovered,
-- none at rest or on category headers (rows without an icon). The fill shrinks inside
-- the frame while it shows; otherwise it keeps its one-pixel overlap with
-- the row above (see Constructor).
local function UpdateFrame(self)
    local alpha = self.iconShown
        and ((self.selected or self.error) and 1 or self.hovered and addon.RowPalette.frameHoverAlpha)
    local background = self.background
    background:ClearAllPoints()
    if alpha then
        background:SetPoint("TOPLEFT", self.frame, "TOPLEFT", FRAME_FILL_INSET, -FRAME_FILL_INSET)
        background:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -FRAME_FILL_INSET, FRAME_FILL_INSET)
    else
        background:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 1)
        background:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT")
    end
    if alpha then
        self.rowFrame:SetVertexColor(1, 1, 1, alpha)
        self.rowFrame:Show()
    else
        self.rowFrame:Hide()
    end
    UpdateFill(self)
end

-- The rim is two stacked fills, not line textures: the dark square at full
-- size, the brass one inset by exactly one screen pixel, the icon by two.
-- Each edge rounds to a pixel on its own, and two edges one pixel apart
-- always round one pixel apart, so both lines are exactly 1px wide at any
-- UI scale and any (fractional) row position. A thin line texture there
-- could draw 0 or 2 pixels wide. Re-read on every layout: the pixel size
-- follows the UI scale.
local function LayoutRim(self)
    local pixel = Theme.PixelSize(self.iconButton) or 1
    local button = self.iconButton
    self.rimInner:ClearAllPoints()
    self.rimInner:SetPoint("TOPLEFT", button, "TOPLEFT", pixel, -pixel)
    self.rimInner:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -pixel, pixel)
    self.iconTexture:ClearAllPoints()
    self.iconTexture:SetPoint("TOPLEFT", button, "TOPLEFT", 2 * pixel, -2 * pixel)
    self.iconTexture:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2 * pixel, 2 * pixel)
end

local function Row_OnClick(frame, button)
    if button == "RightButton" then
        frame.obj:Fire("OnRightClick")
    else
        frame.obj:Fire("OnClick")
    end
end

local function Row_OnEnter(frame)
    local self = frame.obj
    self.hover:Show()
    self.hovered = true
    UpdateRim(self)
    UpdateFrame(self)
    self:Fire("OnEnter")
end

local function Row_OnLeave(frame)
    local self = frame.obj
    self.hover:Hide()
    self.hovered = false
    UpdateRim(self)
    UpdateFrame(self)
    self:Fire("OnLeave")
end

local function Toggle_OnClick(frame)
    frame.obj:Fire("OnToggle")
end

local function Icon_OnClick(frame)
    frame.obj:Fire("OnIconClick")
end

-- Re-anchors the row's children according to indent, toggle and icon
-- visibility: [indent][padding][toggle][icon][label].
local function LayoutRow(self)
    local left = self.indent + (self.iconShown and ICON_PADDING or PADDING)
    if self.toggleShown then
        self.toggle:ClearAllPoints()
        self.toggle:SetPoint("LEFT", self.frame, "LEFT", left + 2, 0)
        left = left + 17
    end
    if self.iconShown then
        self.iconButton:ClearAllPoints()
        self.iconButton:SetPoint("LEFT", self.frame, "LEFT", left, 0)
        LayoutRim(self)
        left = left + ICON_SIZE + 4
    end
    self.label:ClearAllPoints()
    self.label:SetPoint("LEFT", self.frame, "LEFT", left, 0)
    if self.keyShown then
        self.keyLabel:ClearAllPoints()
        self.keyLabel:SetPoint("RIGHT", self.frame, "RIGHT", -(ICON_PADDING + 1), 0)
        self.label:SetPoint("RIGHT", self.keyLabel, "LEFT", -KEY_GAP, 0)
    else
        self.label:SetPoint("RIGHT", self.frame, "RIGHT", -PADDING, 0)
    end
end

local methods = {
    ["OnAcquire"] = function(self)
        self:SetHeight(ROW_HEIGHT)
        self.indent = 0
        self.toggleShown = false
        self.iconShown = false
        self.hovered = false
        self.selected = false
        self.error = false
        self.fillColor = nil
        self.hoverColor = { 1, 1, 1 } -- reset; class rows recolor via SetHoverColor
        UpdateRim(self)
        UpdateFrame(self)
        self.toggle:Hide()
        self.iconButton:Hide()
        self.background:Hide()
        self.hover:Hide()
        self.label:SetText("")
        self.label:SetTextColor(1, 1, 1)
        self.keyShown = false
        self.keyLabel:SetText("")
        self.keyLabel:Hide()
        self.frame:EnableMouse(true)
        LayoutRow(self)
    end,

    -- The key at the row's end (nil or "": none).
    ["SetKeyText"] = function(self, text)
        self.keyShown = text ~= nil and text ~= ""
        self.keyLabel:SetText(text or "")
        if self.keyShown then
            self.keyLabel:Show()
        else
            self.keyLabel:Hide()
        end
        LayoutRow(self)
    end,

    ["SetText"] = function(self, text)
        self.label:SetText(text)
    end,

    ["SetTextColor"] = function(self, r, g, b)
        self.label:SetTextColor(r, g, b)
    end,

    -- Tints the hover glow (ADD-blended, so this is the color, not the
    -- final on-screen brightness -- RowPalette.hoverAlpha still controls
    -- intensity). Defaults back to white on every OnAcquire.
    ["SetHoverColor"] = function(self, r, g, b)
        self.hoverColor = { r or 1, g or 1, b or 1 }
        UpdateFill(self)
    end,

    -- The selected template's row: its icon rim stays gold, and it is
    -- framed.
    ["SetSelected"] = function(self, selected)
        self.selected = selected and true or false
        UpdateRim(self)
        UpdateFrame(self)
    end,

    -- A template in error: its (red) row is framed like the selected one.
    ["SetError"] = function(self, isError)
        self.error = isError and true or false
        UpdateFrame(self)
    end,

    -- Row background color (flat, or tinted Glamour while selected / in
-- error / hovered); nil clears it.
    ["SetRowBackground"] = function(self, r, g, b)
        if not r then
            self.fillColor = nil
            self.background:Hide()
            return
        end
        self.fillColor = { r, g, b }
        UpdateFill(self)
        self.background:Show()
    end,

    ["SetIndent"] = function(self, pixels)
        self.indent = pixels or 0
        LayoutRow(self)
    end,

    -- expanded=true/false shows the arrow toggle (down = open, right =
    -- collapsed); nil hides it.
    ["SetExpanded"] = function(self, expanded)
        if expanded == nil then
            self.toggleShown = false
            self.toggle:Hide()
        else
            self.toggleShown = true
            local piece = expanded and "arrow-down" or "arrow-right"
            local width, height = Theme.PieceSize(piece)
            Theme.SetPiece(self.toggleArt, piece)
            self.toggleArt:SetWidth(width)
            self.toggleArt:SetHeight(height)
            self.toggle:Show()
        end
        LayoutRow(self)
    end,

    -- Template icon; nil shows the black-square placeholder; false hides the
    -- icon button entirely (category headers). coords, when given, is a
    -- {left, right, top, bottom} texcoord quad (the class-icon fallback's
    -- sprite-sheet slice) used verbatim instead of the custom-icon crop.
    ["SetRowIcon"] = function(self, path, coords)
        if path == false then
            self.iconShown = false
            self.iconButton:Hide()
            self:SetHeight(ROW_HEIGHT)
        else
            self.iconShown = true
            self:SetHeight(ICON_ROW_HEIGHT)
            if path then
                self.iconTexture:SetTexture(path)
                if coords then
                    self.iconTexture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                else
                    self.iconTexture:SetTexCoord(ICON_ZOOM, 1 - ICON_ZOOM, ICON_ZOOM, 1 - ICON_ZOOM)
                end
                self.iconTexture:SetVertexColor(1, 1, 1, 1)
            else
                self.iconTexture:SetTexture(BLACK_SQUARE)
                self.iconTexture:SetTexCoord(0, 1, 0, 1)
                self.iconTexture:SetVertexColor(0.10, 0.10, 0.10, 1)
            end
            self.iconButton:Show()
        end
        LayoutRow(self)
        UpdateFrame(self)
    end,
}

local function Constructor()
    local frame = CreateFrame("Button", nil, UIParent)
    frame:Hide()
    frame:SetHeight(ROW_HEIGHT)
    frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    frame:SetScript("OnClick", Row_OnClick)
    frame:SetScript("OnEnter", Row_OnEnter)
    frame:SetScript("OnLeave", Row_OnLeave)

    local background = frame:CreateTexture(nil, "BACKGROUND")
    -- Extend one pixel above the frame's top: each row then repaints the
    -- boundary with the row above it in its own opaque color, so fractional
    -- screen positions can't produce a thin dark seam between contrasting
    -- rows. The first row's extra pixel is clipped by the scroll viewport.
    background:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 1)
    background:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT")
    background:Hide()

    local hover = frame:CreateTexture(nil, "ARTWORK")
    hover:SetAllPoints()
    hover:SetBlendMode("ADD")
    hover:Hide()

    -- Above the fill and the hover glow; the icon (a child frame) is above it.
    local rowFrame = Theme.CreateSlice(frame, "ARTWORK", 1)
    rowFrame:SetScale(FRAME_SCALE)
    rowFrame:SetHollow(true) -- the rim's middle is empty: skip the texture
    rowFrame:SetPiece("panel-rim")
    rowFrame:Hide()

    local toggle = CreateFrame("Button", nil, frame)
    toggle:SetWidth(TOGGLE_SIZE + 4)
    toggle:SetHeight(TOGGLE_SIZE + 4)
    toggle:SetScript("OnClick", Toggle_OnClick)
    toggle:SetScript("OnEnter", Row_OnEnter)
    toggle:SetScript("OnLeave", Row_OnLeave)
    toggle:Hide()
    local toggleArt = toggle:CreateTexture(nil, "ARTWORK")
    toggleArt:SetPoint("CENTER", toggle, "CENTER", 0, 0)

    local iconButton = CreateFrame("Button", nil, frame)
    iconButton:SetWidth(ICON_SIZE)
    iconButton:SetHeight(ICON_SIZE)
    iconButton:SetScript("OnClick", Icon_OnClick)
    iconButton:SetScript("OnEnter", Row_OnEnter)
    iconButton:SetScript("OnLeave", Row_OnLeave)
    iconButton:Hide()

    -- The rim (see LayoutRim): dark bronze outside, brass inside it.
    local dark = Theme.colors.rimDark
    local rimOuter = iconButton:CreateTexture(nil, "BACKGROUND")
    rimOuter:SetAllPoints(iconButton)
    rimOuter:SetTexture(dark[1], dark[2], dark[3], 1)
    local rimInner = iconButton:CreateTexture(nil, "BORDER")

    local iconTexture = iconButton:CreateTexture(nil, "ARTWORK")

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetJustifyH("LEFT")
    label:SetJustifyV("MIDDLE")
    -- (one line: a long name is cut, not wrapped under the key)
    if label.SetWordWrap then
        label:SetWordWrap(false)
    end

    local keyLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    keyLabel:SetJustifyH("RIGHT")
    keyLabel:SetTextColor(KEY_COLOR[1], KEY_COLOR[2], KEY_COLOR[3])
    keyLabel:Hide()

    local widget = {
        frame = frame,
        background = background,
        hover = hover,
        rowFrame = rowFrame,
        toggle = toggle,
        toggleArt = toggleArt,
        iconButton = iconButton,
        iconTexture = iconTexture,
        rimOuter = rimOuter,
        rimInner = rimInner,
        label = label,
        keyLabel = keyLabel,
        indent = 0,
        toggleShown = false,
        iconShown = false,
        type = Type,
    }
    toggle.obj, iconButton.obj, frame.obj = widget, widget, widget
    for method, func in pairs(methods) do
        widget[method] = func
    end

    return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
