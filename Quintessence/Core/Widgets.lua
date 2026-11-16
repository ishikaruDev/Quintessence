local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme

--[[-----------------------------------------------------------------------------
Small WMC-owned AceGUI widgets: WMC-Button, WMC-Spacer, WMC-TabStrip,
WMC-Title, WMC-Section and WMC-Window. (Input controls -- edit box,
dropdown, checkbox, icon, scroll frame -- are in Controls.lua.)

All of them own their pools: AceGUI widgets are pooled and shared with every
addon, so anything changed on one (an alignment offset, a texture) survives
its release and shows up wherever it is reused next. These are configured
once in their constructors and reset in OnAcquire. Their art comes from the
theme (Theme.lua), so the look does not depend on ElvUI or any other skin.

WMC-Button widget: every push button in the WMC window.

Styles (SetStyle): "normal" (bronze plate), "red" (destructive: Delete),
"toggle" (lit cyan lamp: a flag that is on), "close" (the window's square X)
and "pinx" (the small X that removes a pin). Each style has normal, hover,
pressed and disabled art; labels are live text on a blank face.

Methods: SetText, GetText, SetDisabled, SetStyle. Callback: OnClick.
Field: alignoffset -- Flow-layout alignment (see UI.lua alignWithEditBox);
reset to nil on every acquire.
-------------------------------------------------------------------------------]]
local Type, Version = "WMC-Button", 2
local HEIGHT = 24

local STYLES = {
    normal = { "button-normal", "button-hover", "button-pressed", "button-disabled" },
    red = { "red-normal", "red-hover", "red-pressed", "button-disabled" },
    toggle = { "toggle-on", "toggle-on-hover", "toggle-on", "button-disabled", textOffset = 8 },
    close = { "close-normal", "close-hover", "close-pressed", "close-pressed", size = 29, height = 27, noText = true },
    pinx = { "pin-x", "pin-x-hover", "pin-x-pressed", "pin-x-pressed", size = 18, noText = true },
}
addon.ButtonStyles = STYLES

local function UpdateLook(self)
    local style = STYLES[self.style] or STYLES.normal
    local piece
    if self.disabled then
        piece = style[4]
    elseif self.down then
        piece = style[3]
    elseif self.hover then
        piece = style[2]
    else
        piece = style[1]
    end
    self.slice:SetPiece(piece)
end

local function OnClick(frame, ...)
    AceGUI:ClearFocus()
    if PlaySound then
        PlaySound("igMainMenuOption")
    end
    frame.obj:Fire("OnClick", ...)
end

local function OnEnter(frame)
    local self = frame.obj
    self.hover = true
    UpdateLook(self)
end

local function OnLeave(frame)
    local self = frame.obj
    self.hover = false
    self.down = false
    UpdateLook(self)
end

local function OnMouseDown(frame, button)
    local self = frame.obj
    if button == "LeftButton" and not self.disabled then
        self.down = true
        UpdateLook(self)
    end
end

local function OnMouseUp(frame)
    local self = frame.obj
    if self.down then
        self.down = false
        UpdateLook(self)
    end
end

local methods = {
    ["OnAcquire"] = function(self)
        self.alignoffset = nil
        self.hover, self.down = false, false
        self:SetStyle("normal")
        self:SetHeight(HEIGHT)
        self:SetWidth(200)
        self:SetDisabled(false)
        self:SetText("")
    end,

    ["SetText"] = function(self, text)
        self.text = text or ""
        local style = STYLES[self.style] or STYLES.normal
        self.frame:SetText(style.noText and "" or self.text)
    end,

    ["GetText"] = function(self)
        return self.text
    end,

    ["SetDisabled"] = function(self, disabled)
        self.disabled = disabled and true or false
        if self.disabled then
            self.frame:Disable()
        else
            self.frame:Enable()
        end
        UpdateLook(self)
    end,

    -- style: a key of STYLES (nil = "normal"). Sized styles (close, pinx)
    -- set their own width and height.
    ["SetStyle"] = function(self, style)
        self.style = STYLES[style] and style or "normal"
        local spec = STYLES[self.style]
        self.label:ClearAllPoints()
        self.label:SetPoint("CENTER", self.frame, "CENTER", spec.textOffset or 0, 0)
        if spec.size then
            self:SetWidth(spec.size)
            self:SetHeight(spec.size)
        end
        if self.text then
            self.frame:SetText(spec.noText and "" or self.text)
        end
        UpdateLook(self)
    end,
}

local function Constructor()
    local frame = CreateFrame("Button", nil, UIParent)
    frame:Hide()
    frame:EnableMouse(true)
    frame:RegisterForClicks("LeftButtonUp")
    frame:SetScript("OnClick", OnClick)
    frame:SetScript("OnEnter", OnEnter)
    frame:SetScript("OnLeave", OnLeave)
    frame:SetScript("OnMouseDown", OnMouseDown)
    frame:SetScript("OnMouseUp", OnMouseUp)

    -- Live label on the blank face. The font string is created explicitly:
    -- a template-less 3.3.5 Button has none of its own.
    local label = frame:CreateFontString(nil, "OVERLAY")
    label:SetFontObject(GameFontHighlight)
    if frame.SetFontString then
        frame:SetFontString(label)
    end
    if frame.SetNormalFontObject then
        frame:SetNormalFontObject(GameFontHighlight)
        frame:SetHighlightFontObject(GameFontHighlight)
        frame:SetDisabledFontObject(GameFontDisable)
    end
    if frame.SetPushedTextOffset then
        frame:SetPushedTextOffset(1, -1)
    end

    local widget = {
        frame = frame,
        label = label,
        slice = Theme.CreateSlice(frame, "BACKGROUND"),
        text = "",
        style = "normal",
        type = Type,
    }
    for method, func in pairs(methods) do
        widget[method] = func
    end
    frame.obj = widget

    return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)

--[[-----------------------------------------------------------------------------
WMC-Spacer widget: an empty, fixed-height block for vertical spacing in Flow
and List layouts. (A SimpleGroup with noAutoHeight would do the same, but
AceGUI never resets that flag when it re-pools the group, so it would leak
to whatever reuses it.)
-------------------------------------------------------------------------------]]
do
    local SpacerType, SpacerVersion = "WMC-Spacer", 1

    local spacerMethods = {
        ["OnAcquire"] = function(self)
            self:SetHeight(8)
            self:SetWidth(200)
        end,
    }

    local function SpacerConstructor()
        local frame = CreateFrame("Frame", nil, UIParent)
        frame:Hide()
        local widget = { frame = frame, type = SpacerType }
        for method, func in pairs(spacerMethods) do
            widget[method] = func
        end
        return AceGUI:RegisterAsWidget(widget)
    end

    AceGUI:RegisterWidgetType(SpacerType, SpacerConstructor, SpacerVersion)
end

--[[-----------------------------------------------------------------------------
WMC-TabStrip widget: a gold section tab ("TEMPLATE SOURCE") followed by a
row of mode tabs, above the template source box (§13.2).

Not AceGUI's TabGroup: that one wraps its content in its own bordered mode
and takes 60px of width from it, which fights the source TextArea's own
box. This strip is only the tab row; the caller swaps the content itself.
Tabs wrap onto extra rows when they do not fit; the widget's height follows.

The caption and the tabs hang DROP units below the strip's own bottom edge,
so they rest on the rim of the box laid out under the strip (the panel's
rim is its art's top 1-3 rows) instead of floating just above it. They are
kept a few frame levels above the strip so the box never draws over them.

Methods: SetCaption(text), SetTabs({ { value = v, text = t }, ... }),
SelectTab(value) (look only -- fires nothing), GetSelected().
Callback: OnTabClicked(value, tabButton).
-------------------------------------------------------------------------------]]
do
    local StripType, StripVersion = "WMC-TabStrip", 3
    local TAB_HEIGHT = 20
    local ROW_GAP = 2
    local TAB_GAP = 2
    local TEXT_PADDING = 12 -- clear of the tab's slanted ends
    local CAPTION_GAP = 6
    local DROP = 2
    local LEVEL_ABOVE = 4 -- above the next widget's box and its panel
    addon.TAB_STRIP_DROP = DROP

    local function TabLook(button)
        local piece = button.selected and "tab-selected" or button.hovered and "tab-hover" or "tab-normal"
        button.slice:SetPiece(piece)
        local shade = button.selected and 1 or 0.8
        button.label:SetTextColor(shade, shade, shade)
    end

    local function Tab_OnClick(button)
        button.obj:Fire("OnTabClicked", button.value, button)
    end

    local function Tab_OnEnter(button)
        button.hovered = true
        TabLook(button)
    end

    local function Tab_OnLeave(button)
        button.hovered = false
        TabLook(button)
    end

    local function createTab(self)
        local button = CreateFrame("Button", nil, self.frame)
        button:SetHeight(TAB_HEIGHT)
        button:RegisterForClicks("LeftButtonUp")
        button:SetScript("OnClick", Tab_OnClick)
        button:SetScript("OnEnter", Tab_OnEnter)
        button:SetScript("OnLeave", Tab_OnLeave)
        button.obj = self
        button.slice = Theme.CreateSlice(button, "BACKGROUND")
        local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("CENTER", button, "CENTER", 0, -1)
        button.label = label
        TabLook(button)
        return button
    end

    -- insideParentLayout: called from OnWidthSet, i.e. while the parent's
    -- List/Flow layout is placing us -- it reads our height right after
    -- SetWidth, so it must not be asked to lay out again from in here.
    local function Layout(self, insideParentLayout)
        local width = self.width or self.frame:GetWidth() or 0
        local x = 0
        if self.captionText and self.captionText ~= "" then
            -- measured again, like the tabs below: it may have been measured
            -- before the strip joined the window, at another scale
            self.caption:SetText(self.captionText)
            x = math.ceil(self.caption:GetWidth() or 0) + CAPTION_GAP
        end
        local startX = x
        local row = 0
        -- The parent's layout may have changed our frame level since the
        -- last pass (AceGUI sets it on AddChild): re-raise every time.
        local level = (self.frame:GetFrameLevel() or 1) + LEVEL_ABOVE
        self.caption:SetFrameLevel(level)
        for index = 1, #self.tabList do
            local button = self.buttons[index]
            if not button then
                break -- tabs still being built (SetTabs lays out again once done)
            end
            local tabWidth = math.ceil(button.label:GetStringWidth() or 30) + 2 * TEXT_PADDING
            if x > startX and width > 0 and x + tabWidth > width then
                row = row + 1
                x = startX
            end
            button:SetWidth(tabWidth)
            button:SetFrameLevel(level)
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x, -row * (TAB_HEIGHT + ROW_GAP) - DROP)
            x = x + tabWidth + TAB_GAP
        end
        local rows = row + 1
        local height = rows * TAB_HEIGHT + (rows - 1) * ROW_GAP
        if height ~= self.layoutHeight then
            self.layoutHeight = height
            self:SetHeight(height)
            -- A wrap changes our height: the parent must re-flow.
            if not insideParentLayout and self.parent and self.parent.DoLayout then
                self.parent:DoLayout()
            end
        end
    end

    local function UpdateLook(self)
        for index, tab in ipairs(self.tabList) do
            local button = self.buttons[index]
            if not button then
                break
            end
            button.selected = tab.value == self.selected
            TabLook(button)
        end
    end

    local stripMethods = {
        ["OnAcquire"] = function(self)
            self.tabList = {}
            self.selected = nil
            self.layoutHeight = nil
            self.width = nil
            for _, button in ipairs(self.buttons) do
                button:Hide()
            end
            self:SetCaption("")
            self:SetHeight(TAB_HEIGHT)
            self:SetWidth(200)
        end,

        ["OnWidthSet"] = function(self, width)
            self.width = width
            Layout(self, true)
        end,

        ["SetCaption"] = function(self, text)
            self.captionText = text or ""
            self.caption:SetText(self.captionText)
            if self.captionText ~= "" then
                self.caption:Show()
            else
                self.caption:Hide()
            end
            Layout(self)
        end,

        -- tabs: { { value = <any>, text = <string, may carry color codes> } }
        -- Every button is created and filled BEFORE the new list is stored:
        -- showing a button can make AceGUI re-run our layout (OnWidthSet)
        -- right away, and that layout must never meet a tab with no button.
        ["SetTabs"] = function(self, tabs)
            tabs = tabs or {}
            for index, tab in ipairs(tabs) do
                local button = self.buttons[index]
                if not button then
                    button = createTab(self)
                    self.buttons[index] = button
                end
                button.value = tab.value
                button.label:SetText(tab.text)
            end
            self.tabList = tabs
            for index = 1, #tabs do
                self.buttons[index]:Show()
            end
            for index = #self.tabList + 1, #self.buttons do
                self.buttons[index]:Hide()
            end
            Layout(self)
            UpdateLook(self)
        end,

        ["SelectTab"] = function(self, value)
            self.selected = value
            UpdateLook(self)
        end,

        ["GetSelected"] = function(self)
            return self.selected
        end,
    }

    local function StripConstructor()
        local frame = CreateFrame("Frame", nil, UIParent)
        frame:Hide()
        -- The caption sits on the first tab row's baseline (both DROP low).
        local caption = Theme.CreateSectionTab(frame)
        caption:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, -TAB_HEIGHT - DROP)
        local widget = {
            frame = frame,
            caption = caption,
            buttons = {},
            tabList = {},
            type = StripType,
        }
        for method, func in pairs(stripMethods) do
            widget[method] = func
        end
        return AceGUI:RegisterAsWidget(widget)
    end

    AceGUI:RegisterWidgetType(StripType, StripConstructor, StripVersion)
end

--[[-----------------------------------------------------------------------------
WMC-Title widget: the editor's heading ("Rogue / MWD3B2"): large gold text on
a dark bronze plate (the guide's topic-row plate, taller: "heading-plate";
sized to the text, at
least PLATE_MIN_WIDTH wide), with a
divider running on from the plate's point to the right edge. Methods:
SetText, GetText, SetRightInset(units) (the plate and divider stop that far
short of the right edge, leaving room for something placed there; reset on
acquire).
-------------------------------------------------------------------------------]]
do
    local TitleType, TitleVersion = "WMC-Title", 4
    local TITLE_HEIGHT = 34
    -- Text inside the plate: clear of its brass cap (left) and point (right).
    local PLATE_PAD_LEFT = 20
    local PLATE_PAD_RIGHT = 18
    -- A short name ("M3") still gets a proper plate, not a stub.
    local PLATE_MIN_WIDTH = 160
    -- The heading font is the large gold one at this size, lifted a little,
    -- so descenders ("g") stay inside the plate's inner gold line.
    local FONT_SIZE = 14
    local TEXT_LIFT = 1
    local DIVIDER_GAP = 4

    -- Sizes the plate to the text (no wider than the room left) and runs the
    -- divider from its point to the inset.
    local function Layout(self)
        -- Measured with no width set: a width-limited font string reports
        -- the width of its shortened ("...") text.
        self.label:SetWidth(0)
        local textWidth = self.label.GetStringWidth and self.label:GetStringWidth()
        textWidth = type(textWidth) == "number" and math.ceil(textWidth) or 0
        local room = (self.frame.width or self.frame:GetWidth() or 0) - self.rightInset
        local plateWidth = math.max(PLATE_MIN_WIDTH, textWidth + PLATE_PAD_LEFT + PLATE_PAD_RIGHT)
        if room > 0 then
            plateWidth = math.min(plateWidth, room)
        end
        self.plate:SetWidth(plateWidth)
        self.label:SetWidth(math.max(1, plateWidth - PLATE_PAD_LEFT - PLATE_PAD_RIGHT))
        self.divider:ClearAllPoints()
        self.divider:SetPoint("LEFT", self.plate, "RIGHT", DIVIDER_GAP, 0)
        self.divider:SetPoint("RIGHT", self.frame, "RIGHT", -self.rightInset, 0)
    end

    local titleMethods = {
        ["OnAcquire"] = function(self)
            self.rightInset = 0
            self:SetText("")
            self:SetHeight(TITLE_HEIGHT)
            self:SetWidth(200)
        end,

        ["SetText"] = function(self, text)
            self.text = text or ""
            self.label:SetText(self.text)
            Layout(self)
        end,

        ["GetText"] = function(self)
            return self.text
        end,

        ["SetRightInset"] = function(self, units)
            self.rightInset = units or 0
            Layout(self)
        end,

        ["OnWidthSet"] = function(self, width)
            self.frame.width = width
            Layout(self)
        end,
    }

    local function TitleConstructor()
        local frame = CreateFrame("Frame", nil, UIParent)
        frame:Hide()
        local plate = CreateFrame("Frame", nil, frame)
        plate:SetHeight(select(2, Theme.PieceSize("heading-plate")))
        plate:SetPoint("LEFT", frame, "LEFT", 0, 0)
        local slice = Theme.CreateSlice(plate, "BACKGROUND")
        slice:SetPiece("heading-plate")
        local label = plate:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        label:SetPoint("LEFT", plate, "LEFT", PLATE_PAD_LEFT, TEXT_LIFT)
        local fontFile, _, fontFlags
        if GameFontNormalLarge and GameFontNormalLarge.GetFont then
            fontFile, _, fontFlags = GameFontNormalLarge:GetFont()
        end
        if fontFile and label.SetFont then
            label:SetFont(fontFile, FONT_SIZE, fontFlags)
        end
        -- One line: a name too long for the room is cut short.
        label:SetHeight(FONT_SIZE + 2)
        label:SetJustifyH("LEFT")
        label:SetTextColor(unpack(Theme.colors.title))
        local divider = CreateFrame("Frame", nil, frame)
        divider:SetHeight(select(2, Theme.PieceSize("divider")))
        local dividerSlice = Theme.CreateSlice(divider, "ARTWORK")
        dividerSlice:SetPiece("divider")
        local widget = { frame = frame, plate = plate, label = label, divider = divider, text = "",
            rightInset = 0, type = TitleType }
        for method, func in pairs(titleMethods) do
            widget[method] = func
        end
        return AceGUI:RegisterAsWidget(widget)
    end

    AceGUI:RegisterWidgetType(TitleType, TitleConstructor, TitleVersion)
end

--[[-----------------------------------------------------------------------------
WMC-Section container: a panel with a gold section tab on its top-left
corner ("BUTTON", "FORMS", "STATE"); children are laid out inside it (List
layout by default) and the section grows to fit them.

The panel stops Theme.BOX_RIGHT_INSET short of the widget's right edge: the
text areas above (source, preview) keep that column for their scrollbar, so
all five boxes share the same left and right edges.
Methods: SetTitle(text), GetText() (the title as given).
-------------------------------------------------------------------------------]]
do
    local SectionType, SectionVersion = "WMC-Section", 2
    local TAB_HEIGHT = Theme.SECTION_TAB_HEIGHT
    local PAD_X = 10
    local PAD_TOP = TAB_HEIGHT + 4
    local PAD_BOTTOM = 9
    local RIGHT_INSET = Theme.BOX_RIGHT_INSET
    addon.SECTION_RIGHT_INSET = RIGHT_INSET

    local sectionMethods = {
        ["OnAcquire"] = function(self)
            self:SetTitle("")
            self:SetWidth(300)
            self:SetHeight(PAD_TOP + PAD_BOTTOM)
        end,

        ["SetTitle"] = function(self, text)
            self.title = text or ""
            self.tab:SetText(text or "")
            if text and text ~= "" then
                self.tab:Show()
            else
                self.tab:Hide()
            end
        end,

        -- The title as given (the tab shows it in capitals).
        ["GetText"] = function(self)
            return self.title
        end,

        ["LayoutFinished"] = function(self, width, height)
            if self.noAutoHeight then
                return
            end
            self:SetHeight((height or 0) + PAD_TOP + PAD_BOTTOM)
        end,

        ["OnWidthSet"] = function(self, width)
            local content = self.content
            local contentWidth = math.max(0, width - RIGHT_INSET - 2 * PAD_X)
            content:SetWidth(contentWidth)
            content.width = contentWidth
        end,

        ["OnHeightSet"] = function(self, height)
            local content = self.content
            local contentHeight = math.max(0, height - PAD_TOP - PAD_BOTTOM)
            content:SetHeight(contentHeight)
            content.height = contentHeight
        end,
    }

    local function SectionConstructor()
        local frame = CreateFrame("Frame", nil, UIParent)
        frame:Hide()
        -- The panel starts at the tab's middle, so the tab sits on its edge.
        local panelFrame = CreateFrame("Frame", nil, frame)
        panelFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -math.floor(TAB_HEIGHT / 2))
        panelFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -RIGHT_INSET, 0)
        local panel = Theme.CreatePanel(panelFrame)
        local tab = Theme.CreateSectionTab(frame)
        tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        tab:SetFrameLevel(panelFrame:GetFrameLevel() + 2)
        local content = CreateFrame("Frame", nil, frame)
        content:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_X, -PAD_TOP)
        content:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(RIGHT_INSET + PAD_X), -PAD_TOP)
        content:SetHeight(1)
        local widget = {
            frame = frame,
            content = content,
            panel = panel,
            panelFrame = panelFrame,
            tab = tab,
            type = SectionType,
        }
        for method, func in pairs(sectionMethods) do
            widget[method] = func
        end
        return AceGUI:RegisterAsContainer(widget)
    end

    AceGUI:RegisterWidgetType(SectionType, SectionConstructor, SectionVersion)
end

--[[-----------------------------------------------------------------------------
WMC-Window container: a fixed-size window in a composed frame (replaces
AceGUI's Frame for the main window, Quintessence Macros and the
export/import window).

SetFrameStyle("main" | "bank" | "text") picks the frame art and size (fixed:
the frame is composed offline for that size). The title is live text on the
hanging plaque, which is also the drag handle; the close button sits in the
top-right housing, under its rim. A style in Theme.POPUP_FRAMES ("text")
has the popups' look instead (SetPopupLook): the title on the gold tab,
which is the drag handle, and no X (the window's own Close button, at
the bottom, closes it). No status bar.

API kept from AceGUI's Frame, so UI.lua's calls stay the same: SetTitle
(which also takes shorter fallbacks: SetTitle(long, short, ...)),
SetStatusText (no-op), SetStatusTable, ApplyStatus, Show, Hide, and the
fields frame, content, title (drag handle), titletext, closebutton.
Callback: OnClose.
-------------------------------------------------------------------------------]]
do
    local WindowType, WindowVersion = "WMC-Window", 1

    local TAB_HALF = math.floor(Theme.SECTION_TAB_HEIGHT / 2) -- the popup look's panel starts at its tab's middle

    local function Frame_OnClose(frame)
        frame.obj:Fire("OnClose")
    end

    -- Also on a UI scale or screen size change: the windows' own scale
    -- follows (Theme.AddonScale), then the title's fit.
    local function Frame_OnShow(frame)
        local self = frame.obj
        if not self then
            return
        end
        self:ApplyScale()
        if self.titles then
            self:FitTitle()
        end
    end

    local function Frame_OnMouseDown()
        AceGUI:ClearFocus()
    end

    local function Title_OnMouseDown(frame)
        frame:GetParent():StartMoving()
        AceGUI:ClearFocus()
    end

    local function Title_OnMouseUp(frame)
        local window = frame:GetParent()
        window:StopMovingOrSizing()
        local self = window.obj
        local status = self.status or self.localstatus
        status.top = window:GetTop()
        status.left = window:GetLeft()
        status.scale = window:GetScale() -- the units top / left are in
    end

    local function Close_OnClick(button)
        if PlaySound then
            PlaySound("gsTitleOptionExit")
        end
        button.window.obj:Hide()
    end

    local windowMethods = {
        ["OnAcquire"] = function(self)
            self.frame:SetParent(UIParent)
            self.frame:SetFrameStrata("FULLSCREEN_DIALOG")
            self:SetFrameStyle(self.style or "main")
            self:SetTitle()
            self:ApplyStatus()
            self:Show()
        end,

        ["OnRelease"] = function(self)
            self.status = nil
            for key in pairs(self.localstatus) do
                self.localstatus[key] = nil
            end
        end,

        ["SetFrameStyle"] = function(self, style)
            local popup = Theme.POPUP_FRAMES[style]
            local frameData = popup or Theme.FrameData(style)
            if not frameData then
                error("WMC-Window: unknown frame style " .. tostring(style), 2)
            end
            local frame = self.frame
            self.style = style
            self.arts = self.arts or {}
            for name, art in pairs(self.arts) do
                if name ~= style then
                    art:Hide()
                end
            end
            if popup then
                self:SetPopupLook(popup)
                return
            end
            if self.popupLook then
                self.popupLook.body:Hide()
                self.popupLook.tab:Hide()
            end
            self.titletext:Show()
            if not self.arts[style] then
                self.arts[style] = Theme.BuildFrameArt(frame, style)
            end
            self.arts[style]:Show()
            Theme.ApplyBackground(frame, style)

            local insets = Theme.CONTENT_INSETS[style]
            self.insets = insets
            local content = self.content
            content:ClearAllPoints()
            content:SetPoint("TOPLEFT", frame, "TOPLEFT", insets.left, -insets.top)
            content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -insets.right, insets.bottom)

            -- Drag handle and title text: the plaque's face.
            local fx0, fy0, fx1, fy1 = Theme.Rect(style, "face")
            local title = self.title
            title:ClearAllPoints()
            title:SetPoint("TOPLEFT", frame, "TOPLEFT", math.floor(fx0), -math.floor(fy0))
            title:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", math.ceil(fx1), -math.ceil(fy1))
            title:SetFrameLevel(frame:GetFrameLevel() + 20 + Theme.FRAME_ART_LEVELS)
            -- above the art and its layers, so a modal veil darkens it
            -- separately. A dark title is left as it is: faded, it all but
            -- vanished into its darkened plate.
            frame.wmcDimFrames = Theme.TITLE_DARK[style] and {} or { title }
            local titletext = self.titletext
            titletext:ClearAllPoints()
            titletext:SetPoint("CENTER", title, "CENTER", 0, Theme.TITLE_LIFT[style] or 0)
            if Theme.TITLE_DARK[style] then
                titletext:SetTextColor(unpack(Theme.colors.tabText))
                if titletext.SetShadowColor then
                    titletext:SetShadowColor(0, 0, 0, 0)
                end
            else
                titletext:SetTextColor(unpack(Theme.colors.windowTitle))
                if titletext.SetShadowColor then
                    titletext:SetShadowColor(0, 0, 0, 1)
                end
            end
            if self.titles then
                self:FitTitle()
            elseif self.titletext.SetFont then
                self.titletext:SetFont(Theme.TITLE_FONT, Theme.TITLE_FONT_SIZES[style] or Theme.TITLE_FONT_SIZE)
            end

            -- Close button: centred on the housing's opening, a few units
            -- bigger so the housing's rim (drawn above it) overlaps its edge.
            -- Placed at whole units: at a half unit the client snaps it a
            -- pixel to one side, and the rim hides more of that side. Its
            -- width is the one that centres it on whole units (the opening's
            -- centre is 941.5, 16: at 29 x 27 it sits at 927, 3, where the
            -- art's plate fills the opening, CLOSE_PLATE in build_theme.py).
            -- A frame with a column as its right edge has its own button
            -- (frameData.close: piece prefix, width, height), sized for the
            -- column's socket: 35 x 36 around its 31 x 32 opening, centred
            -- on 989.5, 11.
            local hx0, hy0, hx1, hy1 = Theme.Rect(style, "hole")
            local prefix, width, height = "close", addon.ButtonStyles.close.size, addon.ButtonStyles.close.height
            if frameData.close then
                prefix, width, height = unpack(frameData.close)
            end
            local close = self.closebutton
            Theme.SetButtonPiece(close, "Normal", prefix .. "-normal")
            Theme.SetButtonPiece(close, "Pushed", prefix .. "-pressed")
            Theme.SetButtonPiece(close, "Highlight", prefix .. "-hover")
            close:ClearAllPoints()
            close:SetWidth(width)
            close:SetHeight(height)
            close:SetPoint("TOPLEFT", frame, "TOPLEFT", math.floor((hx0 + hx1 - width) / 2 + 0.5),
                -math.floor((hy0 + hy1 - height) / 2 + 0.5))
            close:SetFrameLevel(frame:GetFrameLevel() + 5)
            close:Show()

            self:SetWidth(frameData.width)
            self:SetHeight(frameData.height)
            -- Keep the art above the window (plaque, crest) on screen too.
            if frame.SetClampRectInsets then
                -- (and the art past its right edge: a column's)
                frame:SetClampRectInsets(0, math.max(0, (frameData.reach or 0) - frameData.width), Theme.ArtAbove(style), 0)
            end
        end,

        -- The popup look (Theme.POPUP_FRAMES): the panel with its shadow and
        -- dark-iron inside, the gold tab with the title, which is also the
        -- drag handle; no X (the window has a Close button of its own).
        ["SetPopupLook"] = function(self, popup)
            local frame = self.frame
            local look = self.popupLook
            if not look then
                local body = CreateFrame("Frame", nil, frame)
                body:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -TAB_HALF)
                body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
                look = { body = body }
                look.shadow = Theme.CreateShadow(body)
                look.panel = Theme.CreatePanel(body, "BACKGROUND")
                look.background = Theme.CreateBackground(body, "BORDER", 0)
                look.tab = Theme.CreateSectionTab(frame)
                look.tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
                self.popupLook = look
            end
            -- under the content (the window's other children), the tab over it
            look.body:SetFrameLevel(frame:GetFrameLevel())
            look.tab:SetFrameLevel(frame:GetFrameLevel() + 2)
            look.body:Show()
            look.tab:Show()
            if frame.wmcBackground then
                frame.wmcBackground:Hide() -- a frame style's dark iron
            end
            local rim = Theme.POPUP_RIM
            look.background:Layout(rim, rim, popup.width - 2 * rim, popup.height - TAB_HALF - 2 * rim)

            local insets = popup.insets
            self.insets = insets
            local content = self.content
            content:ClearAllPoints()
            content:SetPoint("TOPLEFT", frame, "TOPLEFT", insets.left, -insets.top)
            content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -insets.right, insets.bottom)

            local title = self.title
            title:ClearAllPoints()
            title:SetPoint("TOPLEFT", look.tab, "TOPLEFT", 0, 0)
            title:SetPoint("BOTTOMRIGHT", look.tab, "BOTTOMRIGHT", 0, 0)
            title:SetFrameLevel(look.tab:GetFrameLevel() + 1)
            frame.wmcDimFrames = { title, look.tab }
            self.titletext:Hide()
            if self.titles then
                self:FitTitle()
            end

            -- no X: the window has a Close button of its own
            self.closebutton:Hide()

            self:SetWidth(popup.width)
            self:SetHeight(popup.height)
            if frame.SetClampRectInsets then
                frame:SetClampRectInsets(0, 0, 0, 0)
            end
        end,

        ["OnWidthSet"] = function(self, width)
            local insets = self.insets or Theme.CONTENT_INSETS.main
            local content = self.content
            local contentWidth = math.max(0, width - insets.left - insets.right)
            content.width = contentWidth
        end,

        ["OnHeightSet"] = function(self, height)
            local insets = self.insets or Theme.CONTENT_INSETS.main
            local content = self.content
            local contentHeight = math.max(0, height - insets.top - insets.bottom)
            content.height = contentHeight
        end,

        -- SetTitle(title, shorter...): the first that fits the plaque's face
        -- is shown; if none does, the font steps down a few points, and only
        -- then is the last cut short with "...".
        ["SetTitle"] = function(self, ...)
            self.titles = { ... }
            self:FitTitle()
        end,

        -- Also run on show and on a UI scale change: the font's size in
        -- pixels is rounded, so how wide the title draws depends on the scale.
        ["FitTitle"] = function(self)
            local titles, text = self.titles or {}, self.titletext
            local popup = Theme.POPUP_FRAMES[self.style]
            if popup then
                -- on the tab, in its capitals
                local tab = self.popupLook.tab
                local upper = {}
                for index, title in ipairs(titles) do
                    upper[index] = string.upper(title)
                end
                local room = popup.width - Theme.SECTION_TAB_PADDING - Theme.POPUP_TAB_MARGIN
                tab.label = Theme.FitText(tab.text, room, upper)
                tab:SetWidth(math.ceil(tab.text:GetStringWidth() or 0) + Theme.SECTION_TAB_PADDING)
                return
            end
            local fx0, _, fx1 = Theme.Rect(self.style, "face")
            local width = fx1 - fx0 - 2 * Theme.TITLE_PAD
            local size = Theme.TITLE_FONT_SIZES[self.style] or Theme.TITLE_FONT_SIZE
            if not text.SetFont then
                Theme.FitText(text, width, titles)
                return
            end
            for step = 0, Theme.TITLE_SHRINK do
                text:SetFont(Theme.TITLE_FONT, size - step)
                local shown = Theme.FitText(text, width, titles)
                for _, title in ipairs(titles) do
                    if shown == title then
                        return
                    end
                end
            end
        end,

        ["SetStatusText"] = function()
            -- No status bar in the themed window.
        end,

        ["Hide"] = function(self)
            self.frame:Hide()
        end,

        ["Show"] = function(self)
            self.frame:Show()
        end,

        ["SetStatusTable"] = function(self, status)
            assert(type(status) == "table")
            self.status = status
            self:ApplyStatus()
        end,

        -- Position only: the size is fixed by the frame style. The corner
        -- lands on a whole screen pixel, so the art (whole units) does too.
        ["ApplyStatus"] = function(self)
            local status = self.status or self.localstatus
            local frame = self.frame
            frame:ClearAllPoints()
            local top, left = status.top, status.left
            if not (top and left) and Theme.PixelSize(frame) then
                -- centred, on whole pixels
                local width, height = frame:GetWidth(), frame:GetHeight()
                local scale = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
                left = (Theme.RoomFor(frame) - width) / 2
                top = (UIParent:GetHeight() * scale + height) / 2
            end
            if top and left then
                frame:SetPoint("TOP", UIParent, "BOTTOM", 0, Theme.SnapToPixel(frame, top))
                frame:SetPoint("LEFT", UIParent, "LEFT", Theme.SnapToPixel(frame, left), 0)
            else
                frame:SetPoint("CENTER")
            end
        end,

        -- Takes the windows' scale (Theme.AddonScale). The saved top / left
        -- are in the window's own units at the scale saved with them
        -- (status.scale; none: 1, from before the windows had a scale of
        -- their own): converted, so it stays put on screen.
        ["ApplyScale"] = function(self)
            local frame = self.frame
            local scale = Theme.AddonScale()
            local status = self.status or self.localstatus
            local saved = status.scale or 1
            if status.top and status.left and math.abs(scale - saved) >= 1e-4 then
                status.top, status.left = status.top * saved / scale, status.left * saved / scale
            end
            status.scale = scale
            if math.abs(scale - frame:GetScale()) < 1e-4 then
                return
            end
            frame:SetScale(scale)
            self:ApplyStatus()
        end,
    }

    local function WindowConstructor()
        local frame = CreateFrame("Frame", nil, UIParent)
        frame:Hide()
        frame:EnableMouse(true)
        frame:SetMovable(true)
        frame:SetClampedToScreen(true)
        frame:SetFrameStrata("FULLSCREEN_DIALOG")
        frame:SetToplevel(true)
        frame:SetScript("OnHide", Frame_OnClose)
        frame:SetScript("OnShow", Frame_OnShow)
        frame:SetScript("OnEvent", Frame_OnShow)
        frame:RegisterEvent("UI_SCALE_CHANGED")
        frame:RegisterEvent("DISPLAY_SIZE_CHANGED")
        frame:SetScript("OnMouseDown", Frame_OnMouseDown)

        local title = CreateFrame("Frame", nil, frame)
        title:EnableMouse(true)
        title:SetScript("OnMouseDown", Title_OnMouseDown)
        title:SetScript("OnMouseUp", Title_OnMouseUp)

        -- A font object first, so a client without the title font still
        -- shows the text.
        local titletext = title:CreateFontString(nil, "OVERLAY")
        titletext:SetFontObject(GameFontNormalLarge)
        if titletext.SetFont then
            titletext:SetFont(Theme.TITLE_FONT, Theme.TITLE_FONT_SIZE)
        end
        titletext:SetPoint("CENTER", title, "CENTER", 0, 2) -- per frame in SetFrameStyle (Theme.TITLE_LIFT)
        titletext:SetTextColor(unpack(Theme.colors.windowTitle))
        if titletext.SetShadowColor then
            titletext:SetShadowColor(0, 0, 0, 1)
            titletext:SetShadowOffset(1, -1)
        end

        local closebutton = CreateFrame("Button", nil, frame)
        closebutton.window = frame
        Theme.SetButtonPiece(closebutton, "Normal", "close-normal")
        Theme.SetButtonPiece(closebutton, "Pushed", "close-pressed")
        Theme.SetButtonPiece(closebutton, "Highlight", "close-hover")
        closebutton:SetScript("OnClick", Close_OnClick)
        Theme.HideHoverWhileHeld(closebutton)

        local content = CreateFrame("Frame", nil, frame)

        local widget = {
            localstatus = {},
            title = title,
            titletext = titletext,
            closebutton = closebutton,
            content = content,
            frame = frame,
            type = WindowType,
        }
        for method, func in pairs(windowMethods) do
            widget[method] = func
        end
        return AceGUI:RegisterAsContainer(widget)
    end

    AceGUI:RegisterWidgetType(WindowType, WindowConstructor, WindowVersion)
end
