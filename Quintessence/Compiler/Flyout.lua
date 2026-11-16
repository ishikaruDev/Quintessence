local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme

--[[-----------------------------------------------------------------------------
Flyout (addon.Flyout): live state at hand without opening the window. A small
crystal tube sits on the left edge of the screen: lit while any flag is on,
dark when none is. Hovering it opens a panel beside it (the dialogs' thin
panel look) with:

  FLAGS  one toggle per known flag (as in the State section)
  PINS   CLASS / ANY: pin the current target as its class or as the free
         pin; then each pin with its x
  MUTED  the class's remembered mutes: x (forget), checkbox (muted or not),
         the line (left out when the class has none)

Icon buttons sit in the top-right corner, level with the FLAGS tab: the
padlock (lock the tube's position), the Compiler's emblem to its left
(open or close the Compiler window, as the guide's part header shows it)
the bank's chest left of that (open or close Quintessence Macros), and
the key list's plate left of that (open or close Key Bindings, KeyList.lua).

Every action runs the matching /qmc command (same checks, same chat
feedback, same "applies when combat ends"). The panel keeps one width and
grows downwards; past MAX_HEIGHT of the screen it scrolls. Drag the tube to
move it up or down the edge (unless locked). Clicking the tube toggles Keep
open: the panel stays open without hovering until clicked again. /qmc tab
hides or shows it.

Tube and panel take the windows' scale (Theme.AddonScale): the same size
at any UI scale, and they follow the window size setting.

Saved (account-wide): settings.flyout = { y = offset from the screen's
vertical centre in UIParent's units, hide = bool, lock = bool,
keepOpen = bool }.
-------------------------------------------------------------------------------]]
local Flyout = {}
addon.Flyout = Flyout

local EDGE_X = 2          -- the tube's gap from the screen edge
local PANEL_GAP = 8       -- tube -> panel
local OPEN_DELAY = 0.15   -- hover this long before it opens
local CLOSE_DELAY = 0.3   -- grace after the mouse leaves tube and panel
local TICK = 0.25         -- tube light and open panel follow the state
local MAX_HEIGHT = 0.8    -- of the screen; taller content scrolls

-- Wide enough for "DUEL: Global Thermal Sapper Charge" on one line after
-- a mute's x and checkbox (~201 units in GameFontHighlightSmall).
local WIDTH = 290
local PAD = 12
local INNER = WIDTH - 2 * PAD
local BUTTON_GAP = 8
local BUTTON_WIDTH = math.floor((INNER - BUTTON_GAP) / 2) -- two per row
local BUTTON_HEIGHT = 24
local ROW_GAP = 6
local SECTION_GAP = 10
local TAB_GAP = 6         -- section tab -> its first row
local X_SIZE = 18
local X_GAP = 6
local BOX_SIZE = 20       -- a remembered mute's checkbox
local ICON_GAP = 4        -- between the corner icon buttons
local TEXT_WIDTH = INNER - X_SIZE - X_GAP
local ENTRY_GAP = 4
local BAR_WIDTH = 20      -- the panel widens by this while it scrolls
local SCROLL_STEP = 30
local DIM = "|cff808080"
local PIN_STATUS_TEXT = { absent = " (not in group)", offline = " (offline)", active = "" }

Flyout.WIDTH = WIDTH

local function settings()
    local db = addon.db and addon.db.settings
    if not db then
        return { y = 0 }
    end
    db.flyout = db.flyout or {}
    db.flyout.y = db.flyout.y or 0
    return db.flyout
end

local function isOver(frame)
    if not (frame and frame:IsShown()) then
        return false
    end
    if frame.IsMouseOver then
        return frame:IsMouseOver() and true or false
    end
    return MouseIsOver and MouseIsOver(frame) and true or false
end

local function measure(fontString, fallback)
    local value = fontString and fontString.GetStringHeight and fontString:GetStringHeight()
    return (type(value) == "number" and value > 0) and math.ceil(value) or fallback
end

--[[ The tube ]]

local function Tab_OnEnter()
    Flyout:HoverStarted()
end

local function Tab_OnLeave()
    Flyout:UpdateTab()
end

local function Tab_OnClick()
    Flyout:SetKeepOpen(not settings().keepOpen)
end

local function Tab_OnDragStart(tab)
    if settings().lock then
        return
    end
    Flyout:Close()
    tab.dragging = true
    tab:SetScript("OnUpdate", function()
        local _, cursorY = GetCursorPosition()
        local scale = UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1
        Flyout:SetOffset(cursorY / (scale or 1) - (UIParent:GetHeight() or 0) / 2)
    end)
end

local function Tab_OnDragStop(tab)
    if not tab.dragging then
        return -- locked: no drag started
    end
    tab.dragging = nil
    tab:SetScript("OnUpdate", nil)
    settings().y = Flyout.offset
end

-- UIParent's units per unit of `frame` (a frame at the windows' scale).
local function uiPerUnit(frame)
    local ui = UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1
    local own = frame.GetEffectiveScale and frame:GetEffectiveScale() or ui
    if not (ui > 0 and own > 0) then
        return 1
    end
    return own / ui
end

-- Keeps the tube on screen. y is in UIParent's units.
function Flyout:SetOffset(y)
    local tab = self.tab
    local ratio = uiPerUnit(tab)
    local half = math.max(0, ((UIParent:GetHeight() or 0) - (self.tabHeight or 0) * ratio) / 2)
    y = math.max(-half, math.min(half, math.floor((y or 0) + 0.5)))
    self.offset = y
    tab:ClearAllPoints()
    tab:SetPoint("LEFT", UIParent, "LEFT", EDGE_X, y / ratio)
end

-- The windows' scale (Theme.lua), for the tube and the panel.
function Flyout:ApplyScale()
    if not self.tab then
        return
    end
    local scale = Theme.AddonScale()
    self.tab:SetScale(scale)
    self.frame:SetScale(scale)
    self:SetOffset(self.offset or settings().y)
    if self:IsOpen() then
        self:Rebuild(true) -- the height limit is in the panel's units
    end
end

-- Lit while any flag is on or the panel is kept open; brighter and glowing
-- harder while hovered or open.
function Flyout:UpdateTab()
    local tab = self.tab
    if not tab then
        return
    end
    local flags = addon.State and addon.State.values.FLAG
    local lit = (flags ~= nil and next(flags) ~= nil) or settings().keepOpen == true
    local active = self:IsOpen() or isOver(tab)
    if lit ~= self.lit then
        Theme.SetPiece(tab.tube, lit and "tab-tube" or "tab-tube-dark")
    end
    if lit then
        tab.glow:SetAlpha(active and 1 or 0.45)
        tab.glow:Show()
    else
        tab.glow:Hide()
    end
    if active then
        tab.highlight:Show()
    else
        tab.highlight:Hide()
    end
    self.lit = lit
end

--[[ The panel ]]

local function Panel_OnMouseWheel(_, delta)
    local bar = Flyout.scrollbar
    if bar:IsShown() then
        bar:SetValue((bar:GetValue() or 0) - delta * SCROLL_STEP)
    end
end

local function Bar_OnValueChanged(bar, value)
    local self = Flyout
    local _, maximum = bar:GetMinMaxValues()
    value = math.max(0, math.min(maximum or 0, value or 0))
    self.scroll:SetVerticalScroll(value)
    if value > 0 then self.upButton:Enable() else self.upButton:Disable() end
    if value < (maximum or 0) then self.downButton:Enable() else self.downButton:Disable() end
end

local function Icon_OnEnter(button)
    local Tooltip = addon.Tooltip
    Tooltip:SetOwner(button, "ANCHOR_RIGHT")
    Tooltip:SetText(button.tooltip())
    Tooltip:Show()
end

local function Icon_OnLeave(button)
    if addon.Tooltip:IsOwned(button) then
        addon.Tooltip:Hide()
    end
end

local function iconButton(parent, onClick, tooltip)
    local button = Theme.CreateIconButton(parent)
    button.tooltip = tooltip
    button:SetScript("OnClick", function()
        onClick()
        if addon.Tooltip:IsOwned(button) then
            Icon_OnEnter(button) -- the text follows the new state
        end
    end)
    button:SetScript("OnEnter", Icon_OnEnter)
    button:SetScript("OnLeave", Icon_OnLeave)
    return button
end

function Flyout:Build()
    if self.tab then
        return
    end
    local tab = CreateFrame("Button", "WMCFlyoutTab", UIParent)
    local width, height = Theme.PieceSize("tab-tube")
    tab:SetWidth(width)
    tab:SetHeight(height)
    tab:SetFrameStrata("MEDIUM")
    tab:SetFrameLevel(10)
    tab:EnableMouse(true)
    tab:RegisterForDrag("LeftButton")
    local glowWidth, glowHeight = Theme.PieceSize("tab-glow")
    local glow = tab:CreateTexture(nil, "BACKGROUND")
    Theme.SetPiece(glow, "tab-glow")
    glow:SetWidth(glowWidth)
    glow:SetHeight(glowHeight)
    glow:SetPoint("CENTER", tab, "CENTER", 0, 0)
    tab.glow = glow
    local tube = tab:CreateTexture(nil, "ARTWORK")
    tube:SetAllPoints(tab)
    tab.tube = tube
    -- Hover / open: the tube added over itself, as the minimap button does.
    local highlight = tab:CreateTexture(nil, "OVERLAY")
    Theme.SetPiece(highlight, "tab-tube")
    highlight:SetAllPoints(tab)
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.3)
    highlight:Hide()
    tab.highlight = highlight
    tab:SetScript("OnEnter", Tab_OnEnter)
    tab:SetScript("OnLeave", Tab_OnLeave)
    tab:SetScript("OnClick", Tab_OnClick)
    tab:SetScript("OnDragStart", Tab_OnDragStart)
    tab:SetScript("OnDragStop", Tab_OnDragStop)
    self.tab, self.tabHeight = tab, height

    local frame = CreateFrame("Frame", "WMCFlyout", UIParent)
    frame:Hide()
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    if frame.EnableMouseWheel then
        frame:EnableMouseWheel(true)
    end
    frame:SetScript("OnMouseWheel", Panel_OnMouseWheel)
    frame:SetPoint("LEFT", tab, "RIGHT", PANEL_GAP, 0)
    frame:SetWidth(WIDTH)
    self.shadow = Theme.CreateShadow(frame, 12, 3, 3)
    self.panel = Theme.CreatePanel(frame, "BACKGROUND")
    self.frame = frame

    local scroll = CreateFrame("ScrollFrame", nil, frame)
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(WIDTH)
    content:SetHeight(1)
    scroll:SetScrollChild(content)
    self.scroll, self.content = scroll, content

    -- UIPanelScrollBarTemplate finds its arrows by global name.
    local bar = CreateFrame("Slider", "WMCFlyoutScrollBar", frame, "UIPanelScrollBarTemplate")
    -- The template's own OnValueChanged scrolls its parent, a plain frame
    -- here: drop it before SetValue fires it.
    bar:SetScript("OnValueChanged", nil)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    bar:Hide()
    local size = Theme.SCROLLBAR_WIDTH
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6 - size)
    bar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 6 + size)
    local upButton, downButton = Theme.ScrollBarButtons(bar)
    Theme.SkinScrollBar(bar, upButton, downButton)
    bar:SetScript("OnValueChanged", Bar_OnValueChanged)
    self.scrollbar, self.upButton, self.downButton = bar, upButton, downButton

    self.buttons, self.boxes, self.texts, self.sectionTabs = {}, {}, {}, {}

    self.lockButton = iconButton(content, function()
        Flyout:SetLocked(not settings().lock)
    end, function()
        return settings().lock and "Widget locked" or "Lock widget"
    end)
    self.compilerButton = iconButton(content, function()
        addon.UI:Toggle()
    end, function()
        local window = addon.UI.window
        return (window and window.frame:IsShown()) and "Close the Compiler" or "Open the Compiler"
    end)
    self.compilerButton:SetIcon("flyout-compiler")
    self.bankButton = iconButton(content, function()
        addon.BankUI:Toggle()
    end, function()
        return addon.BankUI:IsShown() and "Close Quintessence Macros" or "Open Quintessence Macros"
    end)
    self.bankButton:SetIcon("flyout-bank")
    self.keysButton = iconButton(content, function()
        local KeyList = addon.KeyList
        if KeyList:IsShown() then
            KeyList:Cancel()
        else
            KeyList:Open()
        end
    end, function()
        return addon.KeyList:IsShown() and "Close Key Bindings" or "Key Bindings"
    end)
    self.keysButton:SetIcon("flyout-keys")


    -- Hover timing, and the tube light / open panel following the state.
    local driver = CreateFrame("Frame")
    driver.elapsed = 0
    driver:SetScript("OnUpdate", function(_, elapsed)
        Flyout:OnUpdate(elapsed)
    end)
    driver:RegisterEvent("UI_SCALE_CHANGED")
    driver:RegisterEvent("DISPLAY_SIZE_CHANGED")
    driver:SetScript("OnEvent", function()
        Flyout:ApplyScale()
    end)
    self.driver = driver
end

-- At login, once the saved settings are loaded.
function Flyout:Initialize()
    self:Build()
    self:ApplyScale()
    self:Refresh()
end

function Flyout:Refresh()
    if not self.tab then
        return
    end
    if settings().hide then
        self:Close()
        self.tab:Hide()
    else
        self:SetOffset(settings().y)
        self.tab:Show()
        if settings().keepOpen and not self:IsOpen() then
            self:Open()
        end
        self:UpdateTab()
    end
end

-- Keep open: the panel stays up without hovering, until switched off (a
-- click on the tube, or the checkbox). Switching it off leaves the panel to
-- the usual hover rules, so it closes once the mouse is elsewhere.
function Flyout:SetKeepOpen(on)
    settings().keepOpen = on or nil
    if on and not self:IsOpen() then
        self:Open()
    elseif self:IsOpen() then
        self:Rebuild()
    end
    self:UpdateTab()
end

-- Lock position: the tube ignores drags.
function Flyout:SetLocked(on)
    settings().lock = on or nil
    if self:IsOpen() then
        self:Rebuild()
    end
end

-- /qmc tab: hide / show.
function Flyout:Toggle()
    local saved = settings()
    saved.hide = not saved.hide or nil
    self:Refresh()
    if saved.hide then
        addon:Print("Flyout tab hidden. /qmc tab shows it again.")
    else
        addon:Print("Flyout tab shown.")
    end
end

function Flyout:IsOpen()
    return self.frame ~= nil and self.frame:IsShown()
end

function Flyout:HoverStarted()
    if not self:IsOpen() and not self.tab.dragging then
        self.openAt = GetTime() + OPEN_DELAY
    end
    self:UpdateTab()
end

function Flyout:Open()
    self.openAt, self.leaveAt = nil, nil
    self.key = nil
    self.frame:Show()
    self:Rebuild()
    self:UpdateTab()
end

function Flyout:Close()
    self.openAt, self.leaveAt = nil, nil
    if self.frame then
        self.frame:Hide()
    end
    self:UpdateTab()
end

function Flyout:OnUpdate(elapsed)
    local now = GetTime()
    if self.openAt and now >= self.openAt then
        self.openAt = nil
        if isOver(self.tab) and not self.tab.dragging then
            self:Open()
        end
    end
    if self:IsOpen() then
        if settings().keepOpen or isOver(self.tab) or isOver(self.frame) then
            self.leaveAt = nil
        else
            self.leaveAt = self.leaveAt or now + CLOSE_DELAY
            if now >= self.leaveAt then
                self:Close()
            end
        end
    end
    local driver = self.driver
    driver.elapsed = driver.elapsed + (elapsed or 0)
    if driver.elapsed >= TICK then
        driver.elapsed = 0
        self:UpdateTab()
        if self:IsOpen() then
            self:Rebuild()
        end
    end
end

--[[ Panel contents ]]

-- What the panel shows, as a string: rebuilt only when it changes, so a
-- click is never swallowed by a redraw.
local function stateKey(flags, pins, mutes, target)
    local parts = {}
    for _, flag in ipairs(flags) do
        table.insert(parts, flag.name .. (flag.on and "+" or "-"))
    end
    table.insert(parts, "|")
    for _, pin in ipairs(pins) do
        table.insert(parts, pin.class .. ">" .. pin.name .. ">" .. pin.status)
    end
    table.insert(parts, "|")
    for _, row in ipairs(mutes) do
        table.insert(parts, row.mode .. ">" .. row.entry .. (row.on and "+" or "-"))
    end
    table.insert(parts, "|" .. (target and target.class or "-"))
    return table.concat(parts, ",")
end

local function buttonAt(self, index)
    local button = self.buttons[index]
    if not button then
        button = AceGUI:Create("WMC-Button")
        button.frame:SetParent(self.content)
        button:SetCallback("OnClick", function()
            local action = button.flyoutAction
            if action then
                action()
                Flyout:Rebuild()
            end
        end)
        self.buttons[index] = button
    end
    -- Created on UIParent by AceGUI: set the strata, don't inherit it.
    button.frame:SetFrameStrata(self.frame:GetFrameStrata())
    button.frame:SetFrameLevel(self.frame:GetFrameLevel() + 3)
    button.frame:Show()
    return button
end

local function textAt(self, index)
    local text = self.texts[index]
    if not text then
        text = self.content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetWidth(TEXT_WIDTH)
        text:SetJustifyH("LEFT")
        text:SetJustifyV("TOP")
        if text.SetNonSpaceWrap then
            text:SetNonSpaceWrap(true) -- long macro lines with no spaces
        end
        self.texts[index] = text
    end
    text:Show()
    return text
end

local function boxAt(self, index)
    local box = self.boxes[index]
    if not box then
        box = AceGUI:Create("WMC-CheckBox")
        box.frame:SetParent(self.content)
        box:SetWidth(BOX_SIZE)
        box:SetHeight(BOX_SIZE)
        box:SetCallback("OnValueChanged", function(_, _, checked)
            local action = box.flyoutAction
            if action then
                action(checked)
                Flyout:Rebuild()
            end
        end)
        self.boxes[index] = box
    end
    box.frame:SetFrameStrata(self.frame:GetFrameStrata())
    box.frame:SetFrameLevel(self.frame:GetFrameLevel() + 3)
    box.frame:Show()
    return box
end

local function sectionTabAt(self, index)
    local tab = self.sectionTabs[index]
    if not tab then
        tab = Theme.CreateSectionTab(self.content)
        self.sectionTabs[index] = tab
    end
    tab:SetFrameLevel(self.frame:GetFrameLevel() + 3)
    tab:Show()
    return tab
end

-- Rebuilds the panel when what it shows changed (force: always).
function Flyout:Rebuild(force)
    if not self.frame then
        return
    end
    local State = addon.State
    local flags = addon:KnownFlags()
    local pins = State:ActivePins()
    local mutes = State:MuteRows()
    local target = State:TargetMember()
    local key = stateKey(flags, pins, mutes, target)
        .. (settings().lock and "L" or "-") .. (settings().keepOpen and "K" or "-")
    if key == self.key and not force then
        return
    end
    self.key = key

    local content = self.content
    local used = { buttons = 0, boxes = 0, texts = 0, tabs = 0 }
    local y = PAD

    local function sectionTab(title)
        used.tabs = used.tabs + 1
        local tab = sectionTabAt(self, used.tabs)
        tab:SetText(title)
        tab:ClearAllPoints()
        tab:SetPoint("TOPLEFT", content, "TOPLEFT", PAD - 4, -y)
        y = y + Theme.SECTION_TAB_HEIGHT + TAB_GAP
    end

    local function button(text, style, x, action, disabled)
        used.buttons = used.buttons + 1
        local widget = buttonAt(self, used.buttons)
        widget:SetStyle(style)
        widget:SetText(text)
        if style ~= "pinx" then
            widget:SetWidth(BUTTON_WIDTH)
            widget:SetHeight(BUTTON_HEIGHT)
        end
        widget:SetDisabled(disabled)
        widget.flyoutAction = action
        widget.frame:ClearAllPoints()
        widget.frame:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
        return widget
    end

    local function line(text, x)
        used.texts = used.texts + 1
        local fontString = textAt(self, used.texts)
        fontString:SetWidth(PAD + INNER - x)
        fontString:SetText(text)
        fontString:ClearAllPoints()
        fontString:SetPoint("TOPLEFT", content, "TOPLEFT", x, -(y + 3))
        return fontString
    end

    -- An x, an optional checkbox (checked: true / false), then its text
    -- (wrapped when long).
    local function entry(text, action, checked, onToggle)
        local remove = button("x", "pinx", PAD, action)
        local x = PAD + X_SIZE + X_GAP
        local box
        if checked ~= nil then
            used.boxes = used.boxes + 1
            box = boxAt(self, used.boxes)
            box:SetValue(checked)
            box.flyoutAction = onToggle
            box.frame:ClearAllPoints()
            box.frame:SetPoint("TOPLEFT", content, "TOPLEFT", x, -(y - 1))
            x = x + BOX_SIZE + X_GAP
        end
        local fontString = line(text, x)
        y = y + math.max(X_SIZE, measure(fontString, 12) + 3) + ENTRY_GAP
        return remove, box
    end

    self.flagButtons, self.pinButtons, self.muteButtons = {}, {}, {}

    -- The corner icons, level with the first tab.
    local lock, compiler, bank, keys = self.lockButton, self.compilerButton, self.bankButton, self.keysButton
    local icons = { lock, compiler, bank, keys }
    lock:SetIcon(settings().lock and "flyout-lock" or "flyout-unlock")
    local iconWidth, iconHeight = Theme.PieceSize("flyout-lock")
    local iconTop = y - math.floor((iconHeight - Theme.SECTION_TAB_HEIGHT) / 2)
    local iconRight = WIDTH - PAD
    for _, icon in ipairs(icons) do
        icon:SetFrameLevel(self.frame:GetFrameLevel() + 3)
    end
    lock:ClearAllPoints()
    lock:SetPoint("TOPLEFT", content, "TOPLEFT", iconRight - iconWidth, -iconTop)
    lock:Show()
    compiler:ClearAllPoints()
    compiler:SetPoint("TOPLEFT", content, "TOPLEFT", iconRight - 2 * iconWidth - ICON_GAP, -iconTop)
    compiler:Show()
    bank:ClearAllPoints()
    bank:SetPoint("TOPLEFT", content, "TOPLEFT", iconRight - 3 * iconWidth - 2 * ICON_GAP, -iconTop)
    bank:Show()
    keys:ClearAllPoints()
    keys:SetPoint("TOPLEFT", content, "TOPLEFT", iconRight - 4 * iconWidth - 3 * ICON_GAP, -iconTop)
    keys:Show()

    sectionTab("Flags")
    if #flags == 0 then
        local fontString = line(DIM .. "none yet (FLAG=NAME in a template)|r", PAD)
        y = y + measure(fontString, 12) + 3 + ROW_GAP
    end
    for index, flag in ipairs(flags) do
        local name = flag.name
        local column = (index - 1) % 2
        local text = flag.on and ("|cffffd100" .. name .. ": ON|r") or (name .. ": off")
        local widget = button(text, flag.on and "toggle" or "normal", PAD + column * (BUTTON_WIDTH + BUTTON_GAP),
            function()
                addon:FlagCommand(name)
            end)
        self.flagButtons[name] = widget
        if column == 1 or index == #flags then
            y = y + BUTTON_HEIGHT + ROW_GAP
        end
    end

    y = y + SECTION_GAP - ROW_GAP
    sectionTab("Pins")
    self.classButton = button("CLASS", "normal", PAD, function()
        local member = addon.State:TargetMember()
        if member then
            addon:PinCommand(member.class)
        end
    end, target == nil)
    self.anyButton = button("ANY", "normal", PAD + BUTTON_WIDTH + BUTTON_GAP, function()
        addon:PinCommand("ANY")
    end, target == nil)
    y = y + BUTTON_HEIGHT + ROW_GAP
    for _, pin in ipairs(pins) do
        local class = pin.class
        local text = class .. " -> " .. pin.name .. PIN_STATUS_TEXT[pin.status]
        if pin.status ~= "active" then
            text = DIM .. text .. "|r"
        end
        self.pinButtons[class] = entry(text, function()
            addon:UnpinCommand(class)
        end)
    end

    if #mutes > 0 then
        y = y + SECTION_GAP - ENTRY_GAP
        sectionTab("Muted")
        for _, row in ipairs(mutes) do
            local mode, muted = row.mode, row.entry
            local text = mode .. ": " .. muted
            if not row.on then
                text = DIM .. text .. "|r"
            end
            local remove, box = entry(text, function()
                addon:ForgetMute(mode, muted)
            end, row.on, function(checked)
                addon[checked and "MuteCommand" or "UnmuteCommand"](addon, mode .. " " .. muted)
            end)
            table.insert(self.muteButtons, { mode = mode, entry = muted, on = row.on, button = remove, box = box })
        end
        y = y - ENTRY_GAP
    elseif #pins > 0 then
        y = y - ENTRY_GAP
    else
        y = y - ROW_GAP
    end

    y = math.ceil(y + PAD)

    for index = used.buttons + 1, #self.buttons do
        self.buttons[index].frame:Hide()
        self.buttons[index].flyoutAction = nil
    end
    for index = used.boxes + 1, #self.boxes do
        self.boxes[index].frame:Hide()
        self.boxes[index].flyoutAction = nil
    end
    for index = used.texts + 1, #self.texts do
        self.texts[index]:Hide()
    end
    for index = used.tabs + 1, #self.sectionTabs do
        self.sectionTabs[index]:Hide()
    end

    -- Size: grows down to MAX_HEIGHT of the screen, then scrolls (the
    -- panel widens for the bar so the rows keep their places).
    content:SetHeight(y)
    self.contentHeight = y
    local limit = math.floor((UIParent:GetHeight() or 0) / uiPerUnit(self.frame) * MAX_HEIGHT)
    local bar = self.scrollbar
    if limit > 0 and y > limit then
        self.frame:SetHeight(limit)
        self.frame:SetWidth(WIDTH + BAR_WIDTH)
        local maximum = y - limit
        bar:SetMinMaxValues(0, maximum)
        bar:Show()
        bar:SetValue(math.min(bar:GetValue() or 0, maximum))
        Bar_OnValueChanged(bar, bar:GetValue())
    else
        self.frame:SetHeight(y)
        self.frame:SetWidth(WIDTH)
        bar:SetMinMaxValues(0, 0)
        bar:SetValue(0)
        bar:Hide()
        self.scroll:SetVerticalScroll(0)
    end
    self.height = y
end
