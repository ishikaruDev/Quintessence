local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme

--[[-----------------------------------------------------------------------------
WMC's own popups: a modal dialog and a context menu.

Blizzard's StaticPopup frames and UIDropDownMenu lists are shared by the
whole game UI and every other addon (and ElvUI skins them), so WMC does not
reskin them; it draws its own.

Dialog (addon.Dialog): one shared, modal dialog in popup style A -- the
sections' 9-slice panel border around the dark-iron background, with a gold
section tab as its title ("DELETE TEMPLATE"). While it is open a dark veil
covers the owner window (and blocks its clicks and mouse wheel), and a wide
soft shadow sets the dialog off from it. It is always above the owner
window, its frame art and the export/import window.

  Dialog:Register(which, def)       def fields:
      title        section tab text
      text         body text; "%s" is replaced by Show's textArg
      hint         optional dim second line ("Esc to keep editing")
      hasEditBox   one-line input under the text (cyan focus glow)
      maxLetters   input limit (0 / nil = none)
      editText     function(data) -> the input's initial text
      highlight    select the initial text
      buttons      { { text = "Delete", style = "red", action = fn }, ... }
                   action(text, data) runs after the dialog closes; `text`
                   is the input's text (nil without an input)
      default      index of the button Enter presses (default 1)
      onCancel     function(data): Escape or a button with cancel = true
      owner        function() -> the window frame it belongs to (default:
                   SetOwner's, the main window)
  Dialog:Show(which, textArg, data) -- replaces (cancels) an open one
  Dialog:Click(index), Dialog:Enter(), Dialog:Cancel(), Dialog:IsShown(),
  Dialog.which, Dialog.editBox (the raw EditBox), Dialog.buttons.

Keyboard: Enter presses the default button, Escape cancels -- in the input
when it has focus, otherwise through the dialog frame (which takes the
keyboard while it is shown: it is modal). A click anywhere outside the
dialog cancels it too: a full-screen catcher just under it takes the click,
so it never reaches the owner window (a toplevel frame, which a click would
raise above the dialog, leaving its veil stuck over it).

Menu (addon.Menu): a panel with one row per item and a hover highlight,
opened under a widget or at the cursor; closes on a click outside, on
Escape and after an item is chosen.

  Menu:Open(items, anchor, opts)
                             items: { { text = ..., func = fn }, ... };
                             anchor: a frame to open under (nil = cursor);
                             opts: a dropdown's list (width, selected,
                             client, onClose -- see Open); owner: the
                             window it belongs to (default: the themed
                             window the anchor is in, else SetOwner's)
  Menu:Click(index), Menu:Close(), Menu:IsShown(), Menu:IsOpenFor(client),
  Menu:SetOffset(n), Menu:Scroll(delta), Menu.items.

WMC-Dropdown's list is this menu too: as wide as the dropdown, the current
value marked with the gold check mark (and a faint gold band). A list
longer than Menu.MAX_ROWS rows scrolls (themed scrollbar, mouse wheel) and
opens scrolled to the current value.

Both take their owner (the main window's frame) from SetOwner; their frame
levels are counted from it.
-------------------------------------------------------------------------------]]

local LEVEL_VEIL = 30
local LEVEL_DIALOG = 70
local LEVEL_MENU = 90

local function ownerLevel(owner)
    return owner and owner.GetFrameLevel and owner:GetFrameLevel() or 10
end

-- A popup is modal: whatever edit box still has the keyboard (the template
-- source, the search box...) gives it up, so keys can't type into the
-- window under the veil.
local function releaseKeyboard(keep)
    if AceGUI.ClearFocus then
        AceGUI:ClearFocus()
    end
    local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    if focus and focus ~= keep and focus.ClearFocus then
        focus:ClearFocus()
    end
end

--[[ Dialog ]]

local Dialog = { defs = {} }
addon.Dialog = Dialog

-- Shared with the icon picker (IconPicker.lua), which is modal the same way.
Dialog.LEVEL_VEIL, Dialog.LEVEL_DIALOG, Dialog.LEVEL_MENU = LEVEL_VEIL, LEVEL_DIALOG, LEVEL_MENU
Dialog.OwnerLevel = ownerLevel
Dialog.ReleaseKeyboard = releaseKeyboard

local WIDTH = 360
local TAB_HALF = math.floor(Theme.SECTION_TAB_HEIGHT / 2)
local RIM = 5            -- the panel art's rim (and corner brackets)
local PAD = 18           -- body inset from the dialog's left/right edges
local TEXT_TOP = Theme.SECTION_TAB_HEIGHT + 12
local TEXT_GAP = 12      -- text -> input, and input/text -> buttons
local BUTTON_GAP = 10
local BUTTON_MIN = 96
local BUTTON_HEIGHT = 24
local FIELD_HEIGHT = 24
local BOTTOM_PAD = 16
local HINT_COLOR = "|cff9a9a9a"

Dialog.WIDTH = WIDTH

local function Dialog_OnKeyDown(frame, key)
    if key == "ESCAPE" then
        Dialog:Cancel()
    elseif key == "ENTER" then
        Dialog:Enter()
    end
end

local function EditBox_OnEnterPressed()
    Dialog:Enter()
end

local function EditBox_OnEscapePressed()
    Dialog:Cancel()
end

local function EditBox_OnFocusGained(editBox)
    Dialog.fieldSlice:SetPiece("field-focus")
end

local function EditBox_OnFocusLost(editBox)
    Dialog.fieldSlice:SetPiece("field-normal")
    editBox:HighlightText(0, 0)
end

local function Veil_OnMouseWheel()
    -- swallowed: the window under the veil must not scroll
end

local function DialogCatcher_OnMouseDown()
    Dialog:Cancel()
end

function Dialog:Build()
    if self.frame then
        return
    end
    local frame = CreateFrame("Frame", "WMCDialog", UIParent)
    frame:Hide()
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetWidth(WIDTH)
    if frame.EnableKeyboard then
        frame:EnableKeyboard(true)
    end
    frame:SetScript("OnKeyDown", Dialog_OnKeyDown)
    self.frame = frame

    -- Everywhere outside the dialog: a click there cancels it.
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:Hide()
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetAllPoints(UIParent)
    catcher:EnableMouse(true)
    if catcher.EnableMouseWheel then
        catcher:EnableMouseWheel(true)
    end
    catcher:SetScript("OnMouseDown", DialogCatcher_OnMouseDown)
    catcher:SetScript("OnMouseWheel", Veil_OnMouseWheel)
    self.catcher = catcher

    -- The panel starts at the tab's middle, like a WMC-Section.
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -TAB_HALF)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    self.body = body
    self.shadow = Theme.CreateShadow(body)
    self.panel = Theme.CreatePanel(body, "BACKGROUND")
    -- Dark iron inside the rim, over the panel's own charcoal centre.
    self.background = Theme.CreateBackground(body, "BORDER", 0)

    local tab = Theme.CreateSectionTab(frame)
    tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    self.tab = tab

    -- On the body (a child frame, drawn over the dialog frame itself).
    local text = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -TEXT_TOP)
    text:SetWidth(WIDTH - 2 * PAD)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    if text.SetNonSpaceWrap then
        text:SetNonSpaceWrap(true)
    end
    self.text = text

    local editBox = CreateFrame("EditBox", nil, frame)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(Theme.TextFont())
    editBox:SetTextInsets(8, 8, 0, 0)
    editBox:SetHeight(FIELD_HEIGHT)
    editBox:SetScript("OnEnterPressed", EditBox_OnEnterPressed)
    editBox:SetScript("OnEscapePressed", EditBox_OnEscapePressed)
    editBox:SetScript("OnEditFocusGained", EditBox_OnFocusGained)
    editBox:SetScript("OnEditFocusLost", EditBox_OnFocusLost)
    self.fieldSlice = Theme.CreateSlice(editBox, "BACKGROUND")
    self.fieldSlice:SetPiece("field-normal")
    self.editBox = editBox

    self.buttons = {}
end

-- A themed window darkens along its frame's outline (Theme.DimFrame); the
-- veil's own rectangular shade is only for an owner without frame art.
local function Veil_OnShow(veil)
    local owner = veil:GetParent()
    if owner.wmcArts then
        veil.shade:Hide()
        veil.dimming = true
        Theme.DimFrame(owner, true)
    else
        veil.shade:Show()
    end
end

local function Veil_OnHide(veil)
    if veil.dimming then
        veil.dimming = nil
        Theme.DimFrame(veil:GetParent(), false)
    end
end

-- A veil over `owner`: dark, and catching its clicks/wheel. Hidden.
function Dialog.CreateVeil(owner)
    local veil = CreateFrame("Frame", nil, owner)
    veil:SetAllPoints(owner)
    veil:EnableMouse(true)
    if veil.EnableMouseWheel then
        veil:EnableMouseWheel(true)
    end
    veil:SetScript("OnMouseWheel", Veil_OnMouseWheel)
    local shade = veil:CreateTexture(nil, "BACKGROUND")
    shade:SetAllPoints(veil)
    shade:SetTexture(0, 0, 0, 1)
    shade:SetVertexColor(0, 0, 0, Theme.VEIL_ALPHA)
    veil.shade = shade
    veil:Hide()
    veil:SetScript("OnShow", Veil_OnShow)
    veil:SetScript("OnHide", Veil_OnHide)
    return veil
end

-- The dialog's veil over the owner window.
function Dialog:Veil()
    local owner = self.owner
    if not owner then
        return nil
    end
    self.veils = self.veils or {}
    self.veils[owner] = self.veils[owner] or Dialog.CreateVeil(owner)
    self.veil = self.veils[owner]
    return self.veil
end

-- The frame dialogs and menus belong to (the main window's frame).
function Dialog:SetOwner(frame)
    self.mainOwner = frame
    self.owner = frame
    addon.Menu.owner = frame
end

function Dialog:Register(which, def)
    self.defs[which] = def
end

function Dialog:IsShown()
    return self.frame ~= nil and self.frame:IsShown() and self.which ~= nil
end

local function buttonFor(self, index)
    local button = self.buttons[index]
    if not button then
        button = AceGUI:Create("WMC-Button")
        button.frame:SetParent(self.frame)
        button:SetCallback("OnClick", function()
            Dialog:Click(index)
        end)
        self.buttons[index] = button
    end
    return button
end

local function measure(fontString, fallback)
    local value = fontString and fontString.GetStringHeight and fontString:GetStringHeight()
    return (type(value) == "number" and value > 0) and math.ceil(value) or fallback
end

function Dialog:Layout()
    local def = self.def
    local height = TEXT_TOP + measure(self.text, 14)
    local editBox = self.editBox
    if def.hasEditBox then
        height = height + TEXT_GAP
        editBox:ClearAllPoints()
        editBox:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PAD, -height)
        editBox:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -PAD, -height)
        height = height + FIELD_HEIGHT
    end
    height = height + TEXT_GAP + 4

    -- Buttons, one row, centred.
    local widths, total = {}, 0
    for index, spec in ipairs(def.buttons) do
        local button = buttonFor(self, index)
        button:SetStyle(spec.style or "normal")
        button:SetText(spec.text)
        local textWidth = button.label and button.label.GetStringWidth and button.label:GetStringWidth()
        local width = math.max(BUTTON_MIN, math.ceil((type(textWidth) == "number" and textWidth or 0) + 32))
        widths[index] = width
        total = total + width + (index > 1 and BUTTON_GAP or 0)
    end
    local x = math.floor((WIDTH - total) / 2)
    for index, width in ipairs(widths) do
        local button = self.buttons[index]
        button:SetWidth(width)
        button:SetHeight(BUTTON_HEIGHT)
        button.frame:ClearAllPoints()
        button.frame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x, -height)
        -- Created on UIParent by AceGUI: set the strata, don't inherit it.
        button.frame:SetFrameStrata(self.frame:GetFrameStrata())
        button.frame:SetFrameLevel(self.frame:GetFrameLevel() + 3)
        button.frame:Show()
        x = x + width + BUTTON_GAP
    end
    for index = #def.buttons + 1, #self.buttons do
        self.buttons[index].frame:Hide()
    end
    height = height + BUTTON_HEIGHT + BOTTOM_PAD

    height = math.ceil(height)
    self.frame:SetHeight(height)
    self.height = height
    local bodyHeight = height - TAB_HALF
    self.background:Layout(RIM, RIM, WIDTH - 2 * RIM, bodyHeight - 2 * RIM)
    self.tab:SetFrameLevel(self.frame:GetFrameLevel() + 3)
    editBox:SetFrameLevel(self.frame:GetFrameLevel() + 3)
end

function Dialog:Show(which, textArg, data)
    local def = self.defs[which]
    if not def then
        error("WMC dialog: unknown " .. tostring(which), 2)
    end
    self:Build()
    if self:IsShown() then
        self:Cancel()
    end
    -- One modal popup at a time.
    if addon.IconPicker then
        addon.IconPicker:Cancel()
    end
    if addon.MuteDialog then
        addon.MuteDialog:Cancel()
    end
    addon.Menu:Close()
    releaseKeyboard(self.editBox)
    self.which, self.def, self.data = which, def, data
    self.owner = def.owner and def.owner() or self.mainOwner

    self.tab:SetText(def.title or "")
    local body = def.text or ""
    if body:find("%s", 1, true) then
        body = body:format(tostring(textArg or ""))
    end
    if def.hint then
        body = body .. "\n" .. HINT_COLOR .. def.hint .. "|r"
    end
    self.text:SetText(body)

    local editBox = self.editBox
    if def.hasEditBox then
        editBox:SetMaxLetters(def.maxLetters or 0)
        editBox:SetText(def.editText and def.editText(data) or "")
        editBox:Show()
    else
        editBox:ClearFocus()
        editBox:Hide()
    end

    -- Above the owner window, its pipe art (+20) and the export window (+50).
    local level = ownerLevel(self.owner)
    local veil = self:Veil()
    if veil then
        veil:SetFrameLevel(level + LEVEL_VEIL)
        veil:Show()
    end
    local frame = self.frame
    Theme.ScalePopup(frame) -- the windows' scale (Theme.lua)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(level + LEVEL_DIALOG)
    self.catcher:SetFrameLevel(level + LEVEL_DIALOG - 1)
    self.catcher:Show()
    self:Layout()
    frame:ClearAllPoints()
    if self.owner and self.owner.IsShown and self.owner:IsShown() then
        frame:SetPoint("CENTER", self.owner, "CENTER", 0, 40)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    end
    frame:Show()
    if PlaySound then
        PlaySound("igMainMenuOpen")
    end
    if def.hasEditBox then
        editBox:SetFocus()
        if def.highlight then
            editBox:HighlightText()
        end
    end
    return self
end

-- Closes the dialog without running anything; returns what was shown.
function Dialog:Close()
    local which, def, data = self.which, self.def, self.data
    local text = def and def.hasEditBox and self.editBox:GetText() or nil
    self.which, self.def, self.data = nil, nil, nil
    if self.editBox then
        self.editBox:ClearFocus()
    end
    if self.frame then
        self.frame:Hide()
    end
    if self.veil then
        self.veil:Hide()
    end
    if self.catcher then
        self.catcher:Hide()
    end
    return which, def, data, text
end

function Dialog:Click(index)
    if not self:IsShown() then
        return
    end
    local spec = self.def.buttons[index]
    if not spec then
        return
    end
    if spec.cancel then
        self:Cancel()
        return
    end
    local _, _, data, text = self:Close()
    if PlaySound then
        PlaySound("igMainMenuOptionCheckBoxOn")
    end
    if spec.action then
        spec.action(text, data)
    end
end

function Dialog:Enter()
    if self:IsShown() then
        self:Click(self.def.default or 1)
    end
end

function Dialog:Cancel()
    if not self:IsShown() then
        return
    end
    local _, def, data = self:Close()
    if PlaySound then
        PlaySound("igMainMenuClose")
    end
    if def.onCancel then
        def.onCancel(data)
    end
end

--[[ Menu ]]

local Menu = { items = {}, offset = 0, visible = 0 }
addon.Menu = Menu

local ROW_HEIGHT = 20
local ROW_PAD_X = 10
local MENU_PAD = 6
local MENU_MIN_WIDTH = 140
local MAX_ROWS = 12      -- longer lists scroll
local CHECK_SPACE = 20   -- a list's check-mark column (the piece is 18 wide)
local BAR_GAP = 2

Menu.MAX_ROWS = MAX_ROWS
Menu.ROW_HEIGHT = ROW_HEIGHT

local function Row_OnClick(row)
    Menu:Click(row.index)
end

local function Menu_OnKeyDown(frame, key)
    if key == "ESCAPE" then
        Menu:Close()
    end
end

local function Menu_OnMouseWheel(frame, delta)
    Menu:Scroll(-delta)
end

local function Catcher_OnMouseDown()
    Menu:Close()
end

local function Bar_OnValueChanged(slider, value)
    Menu:SetOffset(value)
end

local function UpButton_OnClick()
    Menu:Scroll(-1)
end

local function DownButton_OnClick()
    Menu:Scroll(1)
end

function Menu:Build()
    if self.frame then
        return
    end
    -- Everywhere outside the menu: a click there closes it. That includes
    -- the dropdown that opened a list, so clicking its field again closes
    -- the list (the click never reaches the field to reopen it).
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:Hide()
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetAllPoints(UIParent)
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", Catcher_OnMouseDown)
    self.catcher = catcher

    local frame = CreateFrame("Frame", "WMCMenu", UIParent)
    frame:Hide()
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    if frame.EnableKeyboard then
        frame:EnableKeyboard(true)
    end
    frame:SetScript("OnKeyDown", Menu_OnKeyDown)
    if frame.EnableMouseWheel then
        frame:EnableMouseWheel(true)
    end
    frame:SetScript("OnMouseWheel", Menu_OnMouseWheel)
    self.shadow = Theme.CreateShadow(frame, 12, 3, 3)
    self.panel = Theme.CreatePanel(frame)
    self.frame = frame
    self.rows = {}

    -- The themed scrollbar of a long list; one row per step. Named:
    -- UIPanelScrollBarTemplate finds its arrows by global name.
    local size = Theme.SCROLLBAR_WIDTH
    local bar = CreateFrame("Slider", "WMCMenuScrollBar", frame, "UIPanelScrollBarTemplate")
    -- The template's own OnValueChanged scrolls its parent (SetVerticalScroll),
    -- which only a ScrollFrame has; the menu is a plain frame. Drop it before
    -- SetValue fires it.
    bar:SetScript("OnValueChanged", nil)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    bar:Hide()
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -MENU_PAD, -MENU_PAD - size)
    bar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -MENU_PAD, MENU_PAD + size)
    local upButton, downButton = Theme.ScrollBarButtons(bar)
    Theme.SkinScrollBar(bar, upButton, downButton)
    -- The template's arrows step half the bar's height; ours step a row.
    if upButton then
        upButton:SetScript("OnClick", UpButton_OnClick)
    end
    if downButton then
        downButton:SetScript("OnClick", DownButton_OnClick)
    end
    -- Set the script last, so it doesn't fire yet.
    bar:SetScript("OnValueChanged", Bar_OnValueChanged)
    self.scrollbar, self.upButton, self.downButton = bar, upButton, downButton
end

local function rowFor(self, slot)
    local row = self.rows[slot]
    if not row then
        row = CreateFrame("Button", nil, self.frame)
        row:SetHeight(ROW_HEIGHT)
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", Row_OnClick)
        local gold = Theme.colors.gold
        -- A list's current value: a faint gold band and the check mark.
        local current = row:CreateTexture(nil, "BACKGROUND")
        current:SetAllPoints(row)
        current:SetTexture(1, 1, 1, 1)
        current:SetVertexColor(gold[1], gold[2], gold[3], 0.10)
        current:Hide()
        row.current = current
        local check = row:CreateTexture(nil, "OVERLAY")
        Theme.SetPiece(check, "check-mark")
        local checkWidth, checkHeight = Theme.PieceSize("check-mark")
        check:SetWidth(checkWidth)
        check:SetHeight(checkHeight)
        check:SetPoint("LEFT", row, "LEFT", ROW_PAD_X - 6, 0)
        check:Hide()
        row.check = check
        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetJustifyH("LEFT")
        row.label = label
        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints(row)
        highlight:SetTexture(1, 1, 1, 1)
        highlight:SetVertexColor(gold[1], gold[2], gold[3], 0.18)
        if highlight.SetBlendMode then
            highlight:SetBlendMode("ADD")
        end
        row.highlight = highlight
        self.rows[slot] = row
    end
    return row
end

function Menu:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

-- True while the list `client` opened (Open's opts.client) is showing.
function Menu:IsOpenFor(client)
    return client ~= nil and self:IsShown() and self.client == client
end

-- Shows items offset+1 .. offset+visible in the row slots.
function Menu:Refresh()
    for slot = 1, self.visible do
        local row = self.rows[slot]
        local index = self.offset + slot
        local item = self.items[index]
        row.index = index
        row.label:SetText(item.text or "")
        if item.disabled then
            row:Disable()
            row.label:SetTextColor(0.5, 0.5, 0.5)
        else
            row:Enable()
            row.label:SetTextColor(1, 1, 1)
        end
        if self.isList and index == self.selected then
            row.check:Show()
            row.current:Show()
        else
            row.check:Hide()
            row.current:Hide()
        end
    end
    local maxOffset = #self.items - self.visible
    if self.upButton then
        if self.offset > 0 then self.upButton:Enable() else self.upButton:Disable() end
    end
    if self.downButton then
        if self.offset < maxOffset then self.downButton:Enable() else self.downButton:Disable() end
    end
end

-- Scrolls a long list so item offset+1 is the top row.
function Menu:SetOffset(value)
    local maxOffset = math.max(0, #self.items - self.visible)
    value = math.floor((tonumber(value) or 0) + 0.5)
    value = math.max(0, math.min(maxOffset, value))
    if value == self.offset then
        return
    end
    self.offset = value
    self:Refresh()
    if self.scrollbar then
        self.scrollbar:SetValue(value)
    end
end

function Menu:Scroll(delta)
    self:SetOffset(self.offset + (delta or 0))
end

-- items: { { text = "Rename...", func = fn, disabled = bool }, ... }
-- anchor: a frame (the menu opens under it), or nil for the cursor.
-- opts (optional; a dropdown's list):
--   width     the exact width (default: fit the widest item)
--   selected  index of the current value: check mark + gold band, and the
--             list opens scrolled so it is visible
--   list      true: reserve the check-mark column even with no selection
--   client    whoever opened it (see IsOpenFor)
--   onClose   function(): runs once when it closes, however it closes
--             (before a chosen item's func)
-- (a window, or a popup that holds controls: wmcPopup, Bank/Settings.lua)
local function windowOf(anchor)
    local frame = anchor
    while frame and frame.GetParent do
        if frame.wmcArts or frame.wmcPopup then
            return frame
        end
        frame = frame:GetParent()
    end
    return nil
end

function Menu:Open(items, anchor, opts)
    self:Build()
    self:Close()
    releaseKeyboard()
    opts = opts or {}
    self.items = items or {}
    self.opts = opts
    self.client = opts.client
    self.selected = opts.selected
    self.isList = opts.list or opts.selected ~= nil
    local count = #self.items
    local visible = math.min(count, MAX_ROWS)
    local scrolls = count > visible
    self.visible = visible
    local frame = self.frame
    local textLeft = ROW_PAD_X + (self.isList and CHECK_SPACE or 0)
    local barSpace = scrolls and (Theme.SCROLLBAR_WIDTH + BAR_GAP) or 0

    local width = opts.width
    if not width then
        width = MENU_MIN_WIDTH
        local probe = rowFor(self, 1).label
        for _, item in ipairs(self.items) do
            probe:SetText(item.text or "")
            local textWidth = probe.GetStringWidth and probe:GetStringWidth()
            if type(textWidth) == "number" then
                width = math.max(width, math.ceil(textWidth) + textLeft + ROW_PAD_X + 2 * MENU_PAD + barSpace)
            end
        end
    end

    -- The frame's level first, then its children's: the client moves a
    -- frame's children with it, so lowering the frame after them (a menu of
    -- the settings popup, then one of the bank window: a lower owner) would
    -- sink the rows under its backdrop, an empty menu.
    local level = ownerLevel(opts.owner or windowOf(anchor) or self.owner)
    self.catcher:SetFrameLevel(level + LEVEL_MENU - 1)
    frame:SetFrameLevel(level + LEVEL_MENU)
    for slot = 1, visible do
        local row = rowFor(self, slot)
        local y = -MENU_PAD - (slot - 1) * ROW_HEIGHT
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", MENU_PAD, y)
        row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -MENU_PAD - barSpace, y)
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", row, "LEFT", textLeft, 0)
        row.label:SetPoint("RIGHT", row, "RIGHT", -ROW_PAD_X, 0)
        row:SetFrameLevel(level + LEVEL_MENU + 1)
        row:Show()
    end
    for slot = visible + 1, #self.rows do
        self.rows[slot]:Hide()
    end
    frame:SetWidth(width)
    frame:SetHeight(2 * MENU_PAD + visible * ROW_HEIGHT)
    self.width = width

    -- Open scrolled so the current value is visible (about mid-list).
    local offset = 0
    if scrolls and self.selected then
        offset = math.max(0, math.min(count - visible, self.selected - math.ceil(visible / 2)))
    end
    self.offset = offset
    local bar = self.scrollbar
    if scrolls then
        bar:SetMinMaxValues(0, count - visible)
        bar:SetValue(offset)
        bar:SetFrameLevel(level + LEVEL_MENU + 1)
        for _, button in ipairs({ self.upButton, self.downButton }) do
            button:SetFrameLevel(level + LEVEL_MENU + 2)
        end
        bar:Show()
    else
        bar:Hide()
        bar:SetMinMaxValues(0, 0)
    end
    self:Refresh()

    Theme.ScalePopup(frame) -- the windows' scale (Theme.lua)
    frame:ClearAllPoints()
    if anchor then
        frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    else
        local x, y = 0, 0
        if GetCursorPosition then
            x, y = GetCursorPosition()
        end
        local scale = frame.GetEffectiveScale and frame:GetEffectiveScale() or 1
        if not scale or scale <= 0 then
            scale = 1
        end
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", math.floor((x or 0) / scale), math.floor((y or 0) / scale))
    end
    self.catcher:Show()
    frame:Show()
    if PlaySound then
        PlaySound("igMainMenuOptionCheckBoxOn")
    end
end

function Menu:Close()
    if self.catcher then
        self.catcher:Hide()
    end
    if self.frame and self.frame:IsShown() then
        self.frame:Hide()
    end
    local opts = self.opts
    self.opts, self.client = nil, nil
    if opts and opts.onClose then
        opts.onClose()
    end
end

function Menu:Click(index)
    local item = self.items[index]
    if not item or item.disabled then
        return
    end
    self:Close()
    if item.func then
        item.func()
    end
end
