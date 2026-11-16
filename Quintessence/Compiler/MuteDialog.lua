local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme

--[[-----------------------------------------------------------------------------
MuteDialog (addon.MuteDialog): mutes (§5.16) from the editor, without the
/qmc mute command. It lists the open template's modes, one at a time, and
under the current one every line a mute entry could switch off, each with a
checkbox: ticked = muted in that mode on this character. A tick runs exactly
what /qmc mute MODE Entry runs (and an untick /qmc unmute MODE Entry), chat
confirmation included. Mutes of the mode that match none of the template's
lines are listed after them, so they can be unticked here too.

In the dialogs' look (popup style A: panel border, dark iron inside the rim,
gold section tab "MUTE LINES", soft shadow, veil over the main window):

  [<]            DUEL             [>]
  [x] Global Thermal Sapper Charge
  [ ] Saronite Bomb
  [ ] /startattack                       [bar]
  Ticked lines are left out of DUEL in every template ...
                                     [Close]

  MuteDialog:Open(source, anchor) -- source: the template text (the editor's,
      unsaved edits included); anchor: the window to center on and veil
      (default: the dialogs' owner). Opening again replaces an open one.
  MuteDialog:SetMode(index), :NextMode(delta), :Toggle(row index),
  :Close(), :Cancel(), :IsShown(), :SetOffset(row), :Scroll(rows).
  Fields: modes ({ name, text } per mode name, in source order), mode (the
  current index), list (the rows: { entry, muted = the stored entry or nil,
  extra = a mute no line of the template matches }), offset.

Keyboard: Escape and Enter close it (through the frame, which takes the
keyboard while shown: it is modal). A click outside it closes it too, as
the icon picker's catcher does. The rows are virtual (ROWS slots relabelled
on scroll).
-------------------------------------------------------------------------------]]

local MuteDialog = { modes = {}, list = {}, mode = 1, offset = 0 }
addon.MuteDialog = MuteDialog

local ROWS = 8
local ROW_H = 24
local LIST_H = ROWS * ROW_H

local RIM = 5             -- the panel art's rim
local PAD = 18
local WIDTH = 380
local BAR_GAP = 6
local BAR = Theme.SCROLLBAR_WIDTH
local ROW_W = WIDTH - 2 * PAD - BAR_GAP - BAR
local TAB_HALF = math.floor(Theme.SECTION_TAB_HEIGHT / 2)

local ARROW = 28          -- the guide's page arrows
local BUTTON_WIDTH = 88
local BUTTON_HEIGHT = 24

local MODE_TOP = Theme.SECTION_TAB_HEIGHT + 12
local LIST_TOP = MODE_TOP + ARROW + 10
local NOTE_TOP = LIST_TOP + LIST_H + 8
local BUTTONS_TOP = NOTE_TOP + 30
local HEIGHT = BUTTONS_TOP + BUTTON_HEIGHT + 16
-- No #MODE: only the message and Close, in a smaller dialog.
local EMPTY_LINES_H = 32        -- two lines of GameFontHighlight
local COMPACT_BUTTONS_TOP = MODE_TOP + EMPTY_LINES_H + 14
local COMPACT_HEIGHT = COMPACT_BUTTONS_TOP + BUTTON_HEIGHT + 16

MuteDialog.ROWS, MuteDialog.WIDTH, MuteDialog.HEIGHT, MuteDialog.COMPACT_HEIGHT = ROWS, WIDTH, HEIGHT, COMPACT_HEIGHT

--[[ Rows ]]

local function Row_OnClick(row)
    if row.index then
        MuteDialog:Toggle(row.index)
    end
end

local function Row_OnEnter(row)
    row.hovered = true
    row.text:SetTextColor(unpack(Theme.colors.gold))
end

local function Row_OnLeave(row)
    row.hovered = false
    MuteDialog:PaintRow(row)
end

local function createRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetWidth(ROW_W)
    row:SetHeight(ROW_H)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", Row_OnClick)
    row:SetScript("OnEnter", Row_OnEnter)
    row:SetScript("OnLeave", Row_OnLeave)
    local boxWidth, boxHeight = Theme.PieceSize("check-box")
    local box = row:CreateTexture(nil, "ARTWORK")
    box:SetWidth(boxWidth)
    box:SetHeight(boxHeight)
    box:SetPoint("LEFT", row, "LEFT", 0, 0)
    Theme.SetPiece(box, "check-box")
    local checkWidth, checkHeight = Theme.PieceSize("check-mark")
    local check = row:CreateTexture(nil, "OVERLAY")
    check:SetWidth(checkWidth)
    check:SetHeight(checkHeight)
    check:SetPoint("CENTER", box, "CENTER", 1, 1)
    Theme.SetPiece(check, "check-mark")
    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetJustifyH("LEFT")
    text:SetHeight(ROW_H)
    text:SetPoint("LEFT", box, "RIGHT", 6, 0)
    text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.box, row.check, row.text = box, check, text
    return row
end

--[[ Frame ]]

local function Frame_OnKeyDown(frame, key)
    if key == "ESCAPE" or key == "ENTER" then
        MuteDialog:Cancel()
    end
end

local function Frame_OnMouseWheel(frame, delta)
    MuteDialog:Scroll(-delta)
end

local function Catcher_OnMouseDown()
    MuteDialog:Cancel()
end

local function Catcher_OnMouseWheel()
    -- swallowed: nothing under the dialog scrolls
end

local function Bar_OnValueChanged(slider, value)
    MuteDialog:SetOffset(value)
end

local function UpButton_OnClick()
    MuteDialog:Scroll(-1)
end

local function DownButton_OnClick()
    MuteDialog:Scroll(1)
end

local function createArrow(frame, piece, x, delta)
    local button = CreateFrame("Button", nil, frame)
    button:SetWidth(ARROW)
    button:SetHeight(ARROW)
    button:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -MODE_TOP)
    Theme.SetButtonPiece(button, "Normal", piece)
    Theme.SetButtonPiece(button, "Highlight", piece .. "-hover")
    Theme.SetButtonPiece(button, "Pushed", piece .. "-pressed")
    Theme.SetButtonPiece(button, "Disabled", piece)
    local disabled = button.GetDisabledTexture and button:GetDisabledTexture()
    if disabled and disabled.SetDesaturated then
        disabled:SetDesaturated(true)
    end
    button:SetScript("OnClick", function()
        MuteDialog:NextMode(delta)
    end)
    return button
end

function MuteDialog:Build()
    if self.frame then
        return
    end
    local frame = CreateFrame("Frame", "WMCMuteDialog", UIParent)
    frame:Hide()
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetWidth(WIDTH)
    frame:SetHeight(HEIGHT)
    if frame.EnableKeyboard then
        frame:EnableKeyboard(true)
    end
    frame:SetScript("OnKeyDown", Frame_OnKeyDown)
    if frame.EnableMouseWheel then
        frame:EnableMouseWheel(true)
    end
    frame:SetScript("OnMouseWheel", Frame_OnMouseWheel)
    self.frame = frame

    -- Everywhere outside the dialog: a click there closes it.
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:Hide()
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetAllPoints(UIParent)
    catcher:EnableMouse(true)
    if catcher.EnableMouseWheel then
        catcher:EnableMouseWheel(true)
    end
    catcher:SetScript("OnMouseDown", Catcher_OnMouseDown)
    catcher:SetScript("OnMouseWheel", Catcher_OnMouseWheel)
    self.catcher = catcher

    -- Popup style A, as Dialog:Build: the panel starts at the tab's middle.
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -TAB_HALF)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    self.body = body
    self.shadow = Theme.CreateShadow(body)
    self.panel = Theme.CreatePanel(body, "BACKGROUND")
    self.background = Theme.CreateBackground(body, "BORDER", 0)

    local tab = Theme.CreateSectionTab(frame)
    tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    tab:SetText("Mute Lines")
    self.tab = tab

    -- Texts on a frame of their own, raised with the other children: on the
    -- base frame they would sit under the panel and its background.
    local texts = CreateFrame("Frame", nil, frame)
    texts:SetAllPoints(frame)
    self.texts = texts

    -- The mode, between the guide's page arrows.
    self.prevButton = createArrow(frame, "guide-prev", PAD, -1)
    self.nextButton = createArrow(frame, "guide-next", WIDTH - PAD - ARROW, 1)
    local modeText = texts:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    modeText:SetPoint("CENTER", frame, "TOPLEFT", WIDTH / 2, -(MODE_TOP + ARROW / 2))
    modeText:SetTextColor(unpack(Theme.colors.gold))
    self.modeText = modeText

    self.rows = {}
    for slot = 1, ROWS do
        local row = createRow(frame)
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(LIST_TOP + (slot - 1) * ROW_H))
        self.rows[slot] = row
    end

    local empty = texts:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    empty:SetWidth(WIDTH - 2 * PAD)
    empty:SetJustifyH("LEFT")
    empty:SetTextColor(unpack(Theme.colors.dim))
    empty:Hide()
    self.emptyText = empty

    local note = texts:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -NOTE_TOP)
    note:SetWidth(WIDTH - 2 * PAD)
    note:SetJustifyH("LEFT")
    note:SetTextColor(unpack(Theme.colors.dim))
    self.noteText = note

    -- Themed scrollbar, one row per step (built like the icon picker's).
    local bar = CreateFrame("Slider", "WMCMuteDialogScrollBar", frame, "UIPanelScrollBarTemplate")
    -- The template's own OnValueChanged scrolls its parent (SetVerticalScroll),
    -- which only a ScrollFrame has. Drop it before SetValue fires it.
    bar:SetScript("OnValueChanged", nil)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    bar:Hide()
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -(LIST_TOP + BAR))
    bar:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -PAD, -(LIST_TOP + LIST_H - BAR))
    local upButton, downButton = Theme.ScrollBarButtons(bar)
    Theme.SkinScrollBar(bar, upButton, downButton)
    if upButton then
        upButton:SetScript("OnClick", UpButton_OnClick)
    end
    if downButton then
        downButton:SetScript("OnClick", DownButton_OnClick)
    end
    bar:SetScript("OnValueChanged", Bar_OnValueChanged)
    self.scrollbar, self.upButton, self.downButton = bar, upButton, downButton

    local close = AceGUI:Create("WMC-Button")
    close.frame:SetParent(frame)
    close:SetStyle("normal")
    close:SetText(CLOSE or "Close")
    close:SetWidth(BUTTON_WIDTH)
    close:SetHeight(BUTTON_HEIGHT)
    close.frame:ClearAllPoints()
    close:SetCallback("OnClick", function() MuteDialog:Cancel() end)
    close.frame:Show()
    self.closeButton = close
end

--[[ State ]]

function MuteDialog:IsShown()
    return self.frame ~= nil and self.frame:IsShown() and self.isOpen == true
end

-- The template's modes, one per name (a name's segments joined), in
-- source order.
local function readModes(source)
    local modes, byName = {}, {}
    for _, segment in ipairs(addon.Compiler.SplitModes(source or "")) do
        if segment.kind == "MODE" and segment.name ~= "?" then
            local mode = byName[segment.name]
            if not mode then
                mode = { name = segment.name, parts = {} }
                byName[segment.name] = mode
                table.insert(modes, mode)
            end
            table.insert(mode.parts, segment.text)
        end
    end
    for _, mode in ipairs(modes) do
        mode.text = table.concat(mode.parts, "\n")
        mode.parts = nil
    end
    return modes
end

local function sameKey(a, b)
    local keyA, keyB = addon.Compiler.MuteKey(a), addon.Compiler.MuteKey(b)
    return keyA and keyB and keyA.command == keyB.command and keyA.argument == keyB.argument or false
end

-- The current mode's rows: its lines' entries, then its other mutes.
local function buildList(mode)
    local list = {}
    if not mode then
        return list
    end
    local stored = addon.State and addon.State:Mutes()[mode.name] or {}
    local used = {}
    for _, entry in ipairs(addon.Compiler.MuteCandidates(mode.text)) do
        local row = { entry = entry }
        for index, existing in ipairs(stored) do
            if not used[index] and sameKey(entry, existing) then
                row.muted, used[index] = existing, true
                break
            end
        end
        table.insert(list, row)
    end
    for index, existing in ipairs(stored) do
        if not used[index] then
            table.insert(list, { entry = existing, muted = existing, extra = true })
        end
    end
    return list
end

local function maxOffset(self)
    return math.max(0, #self.list - ROWS)
end

function MuteDialog:PaintRow(row)
    local item = row.index and self.list[row.index]
    if not item then
        return
    end
    if item.muted then row.check:Show() else row.check:Hide() end
    if row.hovered then
        row.text:SetTextColor(unpack(Theme.colors.gold))
    elseif item.extra then
        row.text:SetTextColor(unpack(Theme.colors.dim))
    else
        row.text:SetTextColor(1, 1, 1)
    end
end

-- Full (a mode's list) or compact (no #MODE: the message and Close).
function MuteDialog:Layout(compact)
    if self.compact == compact then
        return
    end
    self.compact = compact
    local frame = self.frame
    local height = compact and COMPACT_HEIGHT or HEIGHT
    frame:SetHeight(height)
    self.background:Layout(RIM, RIM, WIDTH - 2 * RIM, height - TAB_HALF - 2 * RIM)
    self.emptyText:ClearAllPoints()
    self.emptyText:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(compact and MODE_TOP or (LIST_TOP + 8)))
    local close = self.closeButton.frame
    close:ClearAllPoints()
    close:SetPoint("TOPLEFT", frame, "TOPLEFT", WIDTH - PAD - BUTTON_WIDTH,
        -(compact and COMPACT_BUTTONS_TOP or BUTTONS_TOP))
end

-- Relabels the row slots for the current offset.
function MuteDialog:Refresh()
    for slot, row in ipairs(self.rows) do
        local index = self.offset + slot
        local item = self.list[index]
        if item then
            row.index = index
            row.text:SetText(item.extra and (item.entry .. "  (no line here)") or item.entry)
            self:PaintRow(row)
            row:Show()
        else
            row.index, row.hovered = nil, false
            row:Hide()
        end
    end
    local mode = self.modes[self.mode]
    self:Layout(mode == nil)
    if not mode then
        self.emptyText:SetText("This template has no #MODE. Mutes switch lines off in a mode's branches.")
        self.emptyText:Show()
    elseif #self.list == 0 then
        self.emptyText:SetText("No macro lines to mute in " .. mode.name .. ".")
        self.emptyText:Show()
    else
        self.emptyText:Hide()
    end
    self.modeText:SetText(mode and mode.name or "")
    self.noteText:SetText(mode and ("Ticked lines are left out of " .. mode.name
        .. " in every template, on this character (/qmc mute).") or "")
    local several = #self.modes > 1
    for _, button in ipairs({ self.prevButton, self.nextButton }) do
        if several then button:Enable() else button:Disable() end
        if mode then button:Show() else button:Hide() end
    end
    local top = maxOffset(self)
    if self.upButton then
        if self.offset > 0 then self.upButton:Enable() else self.upButton:Disable() end
    end
    if self.downButton then
        if self.offset < top then self.downButton:Enable() else self.downButton:Disable() end
    end
end

function MuteDialog:UpdateBar()
    local top = maxOffset(self)
    local bar = self.scrollbar
    if top > 0 then
        bar:SetMinMaxValues(0, top)
        bar:SetValue(self.offset)
        bar:Show()
    else
        bar:Hide()
        bar:SetMinMaxValues(0, 0)
    end
end

-- Re-reads the rows (after a mute change, keeping the scroll position).
function MuteDialog:Reload()
    self.list = buildList(self.modes[self.mode])
    self.offset = math.min(self.offset, maxOffset(self))
    self:UpdateBar()
    self:Refresh()
end

function MuteDialog:SetMode(index)
    if not self.modes[index] then
        return
    end
    self.mode = index
    self.lastMode = self.modes[index].name
    self.offset = 0
    self:Reload()
end

-- The next (delta 1) or previous (-1) mode, wrapping round.
function MuteDialog:NextMode(delta)
    local count = #self.modes
    if count < 2 then
        return
    end
    if PlaySound then
        PlaySound("igMainMenuOptionCheckBoxOn")
    end
    self:SetMode((self.mode - 1 + (delta or 1)) % count + 1)
end

function MuteDialog:SetOffset(value)
    value = math.floor((tonumber(value) or 0) + 0.5)
    value = math.max(0, math.min(maxOffset(self), value))
    if value == self.offset then
        return
    end
    self.offset = value
    self:Refresh()
    if self.scrollbar then
        self.scrollbar:SetValue(value)
    end
end

function MuteDialog:Scroll(delta)
    self:SetOffset(self.offset + (delta or 0))
end

-- Ticks / unticks row `index`: /qmc mute or unmute, then the rows again.
function MuteDialog:Toggle(index)
    local item = self.list[index]
    local mode = self.modes[self.mode]
    if not (self:IsShown() and item and mode) then
        return
    end
    if PlaySound then
        PlaySound(item.muted and "igMainMenuOptionCheckBoxOff" or "igMainMenuOptionCheckBoxOn")
    end
    if item.muted then
        addon:UnmuteCommand(mode.name .. " " .. item.muted)
    else
        addon:MuteCommand(mode.name .. " " .. item.entry)
    end
    self:Reload()
end

function MuteDialog:Open(source, anchor)
    self:Build()
    self:Cancel()
    local Dialog = addon.Dialog
    Dialog:Cancel()
    addon.IconPicker:Cancel()
    addon.Menu:Close()
    Dialog.ReleaseKeyboard()
    self.isOpen = true

    self.modes = readModes(source)
    local index = 1
    for position, mode in ipairs(self.modes) do
        if mode.name == self.lastMode then
            index = position
        end
    end
    self.mode = index
    self.offset = 0
    self.list = buildList(self.modes[index])

    -- Levels as the dialog's: above the window, its art and the export
    -- window; a menu would still go above it.
    local owner = anchor or Dialog.mainOwner
    local level = Dialog.OwnerLevel(owner)
    if owner then
        if not self.veil or self.veil:GetParent() ~= owner then
            self.veil = Dialog.CreateVeil(owner)
        end
        self.veil:SetFrameLevel(level + Dialog.LEVEL_VEIL)
        self.veil:Show()
    end
    local frame = self.frame
    Theme.ScalePopup(frame) -- the windows' scale (Theme.lua)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(level + Dialog.LEVEL_DIALOG)
    self.catcher:SetFrameLevel(level + Dialog.LEVEL_DIALOG - 1)
    self.catcher:Show()
    -- Child levels don't follow a later change of the parent's: set each.
    self.body:SetFrameLevel(level + Dialog.LEVEL_DIALOG + 1)
    local childLevel = level + Dialog.LEVEL_DIALOG + 3
    self.tab:SetFrameLevel(childLevel)
    for _, child in ipairs({ self.texts, self.prevButton, self.nextButton, self.scrollbar }) do
        child:SetFrameLevel(childLevel)
    end
    for _, row in ipairs(self.rows) do
        row:SetFrameLevel(childLevel)
    end
    for _, button in ipairs({ self.upButton, self.downButton }) do
        if button then
            button:SetFrameLevel(childLevel + 1)
        end
    end
    -- Created on UIParent by AceGUI: set the strata, don't inherit it.
    self.closeButton.frame:SetFrameStrata(frame:GetFrameStrata())
    self.closeButton.frame:SetFrameLevel(childLevel)

    frame:ClearAllPoints()
    if owner and owner.IsShown and owner:IsShown() then
        frame:SetPoint("CENTER", owner, "CENTER", 0, 20)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    end
    frame:Show()
    self:UpdateBar()
    self:Refresh()
    if PlaySound then
        PlaySound("igMainMenuOpen")
    end
end

function MuteDialog:Close()
    self.isOpen = nil
    if self.frame then
        self.frame:Hide()
    end
    if self.veil then
        self.veil:Hide()
    end
    if self.catcher then
        self.catcher:Hide()
    end
    addon.Tooltip:Hide()
end

function MuteDialog:Cancel()
    if not self:IsShown() then
        return
    end
    self:Close()
    if PlaySound then
        PlaySound("igMainMenuClose")
    end
end
