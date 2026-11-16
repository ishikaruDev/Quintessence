local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme

--[[-----------------------------------------------------------------------------
IconPicker (addon.IconPicker): WMC's own icon chooser, in the dialogs' look
(popup style A: panel border, dark iron inside the rim, gold section tab
"CHOOSE ICON", soft shadow, veil over the main window). It never touches
Blizzard's MacroPopupFrame: that frame belongs to the native macro UI (and
ElvUI skins it).

  [preview] Spell_Nature_Lightning
            523 icons
  [Search icons..........................]
  [ 8 x 5 grid of icons              ] [bar]
  [Reset]                   [Cancel] [OK]

The grid is virtual: 40 cell slots relabelled on scroll, never one frame per
icon. The icons are the ones the native macro popup lists (GetNumMacroIcons /
GetMacroIconInfo), read once per open; records keep storing texture paths.
Search is a case-insensitive substring of the file name (the part after
Interface\Icons\), applied once typing pauses.

  IconPicker:Open(currentIcon, onAccept, anchor)
      onAccept(path) on OK, onAccept(nil) on Reset; Cancel / Escape run
      nothing. anchor: the window to center on and veil (default: the
      dialogs' owner). Opening again replaces an open picker.
  IconPicker:Select(path), :Accept(), :Reset(), :Cancel(), :IsShown(),
  :SetFilter(text) (at once, no delay), :SetOffset(row), :Scroll(rows).
  Fields: cells, list (the filtered paths), offset (in grid rows), selected.

Keyboard: Enter = OK, Escape = Cancel (in the search box or through the
frame, which takes the keyboard while shown: it is modal). Double-click on a
cell = OK. A click anywhere outside the picker = Cancel: a full-screen
catcher just under it takes that click, so it never reaches the main window
(a toplevel frame, which a click would raise above the picker).
-------------------------------------------------------------------------------]]

local IconPicker = { list = {}, offset = 0 }
addon.IconPicker = IconPicker

local COLUMNS, ROWS = 8, 5
local SLOTS = COLUMNS * ROWS
local CELL = 32           -- icon + its rim
local CELL_GAP = 4
local PITCH = CELL + CELL_GAP
local GRID_WIDTH = COLUMNS * PITCH - CELL_GAP
local GRID_HEIGHT = ROWS * PITCH - CELL_GAP

local RIM = 5             -- the panel art's rim
local PAD = 18
local BAR_GAP = 6
local BAR = Theme.SCROLLBAR_WIDTH
local WIDTH = PAD + GRID_WIDTH + BAR_GAP + BAR + PAD
local TAB_HALF = math.floor(Theme.SECTION_TAB_HEIGHT / 2)

local PREVIEW_ICON = 28
local PREVIEW_SLOT = math.floor(PREVIEW_ICON * 34 / 24 + 0.5) -- the slot art's opening is 24 of its 34
local FIELD_HEIGHT = 24
local BUTTON_WIDTH = 88
local BUTTON_HEIGHT = 24
local BUTTON_GAP = 10
local ROW_GAP = 10

local PREVIEW_TOP = Theme.SECTION_TAB_HEIGHT + 12
local SEARCH_TOP = PREVIEW_TOP + PREVIEW_SLOT + ROW_GAP
local GRID_TOP = SEARCH_TOP + FIELD_HEIGHT + ROW_GAP
local BUTTONS_TOP = GRID_TOP + GRID_HEIGHT + 14
local HEIGHT = BUTTONS_TOP + BUTTON_HEIGHT + 16

local SEARCH_DELAY = 0.15
-- Same corner-notch crop as the list and editor icons.
local ICON_ZOOM = 0.08
local BLACK_SQUARE = "Interface\\Buttons\\WHITE8X8"

IconPicker.COLUMNS, IconPicker.ROWS = COLUMNS, ROWS
IconPicker.WIDTH, IconPicker.HEIGHT = WIDTH, HEIGHT

-- "Interface\Icons\Spell_Nature_Lightning" -> "Spell_Nature_Lightning"
local function fileName(path)
    return path and (path:match("([^\\/]+)$") or path) or ""
end
IconPicker.FileName = fileName

--[[ Cells ]]

-- The drawn two-tone rim of the list icons (ListRow.lua): brass at rest,
-- gold while hovered or selected.
local function updateRim(cell)
    local selected = cell.path ~= nil and cell.path == IconPicker.selected
    local color = (cell.hovered or selected) and Theme.colors.gold or Theme.colors.rimBrass
    cell.rimInner:SetTexture(color[1], color[2], color[3], 1)
end

-- Stacked fills, not line textures, inset by whole screen pixels so both
-- rim lines are exactly 1px at any UI scale (see ListRow.lua's LayoutRim).
local function layoutRim(cell, pixel)
    cell.rimInner:ClearAllPoints()
    cell.rimInner:SetPoint("TOPLEFT", cell, "TOPLEFT", pixel, -pixel)
    cell.rimInner:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -pixel, pixel)
    cell.icon:ClearAllPoints()
    cell.icon:SetPoint("TOPLEFT", cell, "TOPLEFT", 2 * pixel, -2 * pixel)
    cell.icon:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -2 * pixel, 2 * pixel)
end

local function showTooltip(cell)
    if not cell.path then
        return
    end
    addon.Tooltip:SetOwner(cell, "ANCHOR_RIGHT")
    addon.Tooltip:SetText(fileName(cell.path), 1, 1, 1)
    addon.Tooltip:Show()
end

local function Cell_OnClick(cell)
    IconPicker:Select(cell.path)
end

local function Cell_OnDoubleClick(cell)
    IconPicker:Select(cell.path)
    IconPicker:Accept()
end

local function Cell_OnEnter(cell)
    cell.hovered = true
    updateRim(cell)
    showTooltip(cell)
end

local function Cell_OnLeave(cell)
    cell.hovered = false
    updateRim(cell)
    addon.Tooltip:Hide()
end

local function createCell(parent)
    local cell = CreateFrame("Button", nil, parent)
    cell:SetWidth(CELL)
    cell:SetHeight(CELL)
    cell:RegisterForClicks("LeftButtonUp")
    cell:SetScript("OnClick", Cell_OnClick)
    cell:SetScript("OnDoubleClick", Cell_OnDoubleClick)
    cell:SetScript("OnEnter", Cell_OnEnter)
    cell:SetScript("OnLeave", Cell_OnLeave)
    local dark = Theme.colors.rimDark
    local rimOuter = cell:CreateTexture(nil, "BACKGROUND")
    rimOuter:SetAllPoints(cell)
    rimOuter:SetTexture(dark[1], dark[2], dark[3], 1)
    cell.rimOuter = rimOuter
    cell.rimInner = cell:CreateTexture(nil, "BORDER")
    cell.icon = cell:CreateTexture(nil, "ARTWORK")
    return cell
end

--[[ Frame ]]

local function Frame_OnKeyDown(frame, key)
    if key == "ESCAPE" then
        IconPicker:Cancel()
    elseif key == "ENTER" then
        IconPicker:Accept()
    end
end

local function Frame_OnMouseWheel(frame, delta)
    IconPicker:Scroll(-delta)
end

local function Catcher_OnMouseDown()
    IconPicker:Cancel()
end

local function Catcher_OnMouseWheel()
    -- swallowed: nothing under the picker scrolls
end

local function Search_OnTextChanged(editBox)
    local text = editBox:GetText() or ""
    IconPicker.placeholder[text == "" and "Show" or "Hide"](IconPicker.placeholder)
    if text ~= IconPicker.filter then
        local timer = IconPicker.searchTimer
        timer.elapsed = 0
        timer:Show()
    end
end

local function Search_OnEnterPressed()
    IconPicker:Accept()
end

local function Search_OnEscapePressed()
    IconPicker:Cancel()
end

local function Search_OnFocusGained()
    IconPicker.fieldSlice:SetPiece("field-focus")
end

local function Search_OnFocusLost(editBox)
    IconPicker.fieldSlice:SetPiece("field-normal")
    editBox:HighlightText(0, 0)
end

-- Filters once typing pauses (SEARCH_DELAY after the last change).
local function SearchTimer_OnUpdate(timer, elapsed)
    timer.elapsed = (timer.elapsed or 0) + elapsed
    if timer.elapsed < SEARCH_DELAY then
        return
    end
    timer:Hide()
    IconPicker:SetFilter(IconPicker.searchBox:GetText())
end

local function Bar_OnValueChanged(slider, value)
    IconPicker:SetOffset(value)
end

local function UpButton_OnClick()
    IconPicker:Scroll(-1)
end

local function DownButton_OnClick()
    IconPicker:Scroll(1)
end

local function createButton(self, text, x, onClick)
    local button = AceGUI:Create("WMC-Button")
    button.frame:SetParent(self.frame)
    button:SetStyle("normal")
    button:SetText(text)
    button:SetWidth(BUTTON_WIDTH)
    button:SetHeight(BUTTON_HEIGHT)
    button.frame:ClearAllPoints()
    button.frame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x, -BUTTONS_TOP)
    button:SetCallback("OnClick", onClick)
    button.frame:Show()
    return button
end

function IconPicker:Build()
    if self.frame then
        return
    end
    local frame = CreateFrame("Frame", "WMCIconPicker", UIParent)
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

    -- Everywhere outside the picker: a click there cancels it.
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
    self.background:Layout(RIM, RIM, WIDTH - 2 * RIM, HEIGHT - TAB_HALF - 2 * RIM)

    local tab = Theme.CreateSectionTab(frame)
    tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    tab:SetText("Choose Icon")
    self.tab = tab

    -- The selected icon, large, in the brass slot.
    local preview = CreateFrame("Frame", nil, frame)
    preview:SetWidth(PREVIEW_SLOT)
    preview:SetHeight(PREVIEW_SLOT)
    preview:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PREVIEW_TOP)
    local previewIcon = preview:CreateTexture(nil, "ARTWORK")
    previewIcon:SetWidth(PREVIEW_ICON)
    previewIcon:SetHeight(PREVIEW_ICON)
    previewIcon:SetPoint("CENTER", preview, "CENTER", 0, 0)
    local slot = preview:CreateTexture(nil, "OVERLAY")
    slot:SetAllPoints(preview)
    Theme.SetPiece(slot, "icon-slot")
    self.preview, self.previewIcon = preview, previewIcon

    local nameLeft = PAD + PREVIEW_SLOT + 10
    local name = preview:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("TOPLEFT", frame, "TOPLEFT", nameLeft, -(PREVIEW_TOP + 5))
    name:SetWidth(WIDTH - nameLeft - PAD)
    name:SetJustifyH("LEFT")
    self.nameText = name
    local count = preview:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    count:SetPoint("TOPLEFT", frame, "TOPLEFT", nameLeft, -(PREVIEW_TOP + 23))
    count:SetWidth(WIDTH - nameLeft - PAD)
    count:SetJustifyH("LEFT")
    count:SetTextColor(unpack(Theme.colors.dim))
    self.countText = count

    -- Search field (the dialog input's look), across grid and bar.
    local searchBox = CreateFrame("EditBox", nil, frame)
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject(Theme.TextFont())
    searchBox:SetTextInsets(8, 8, 0, 0)
    searchBox:SetHeight(FIELD_HEIGHT)
    searchBox:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -SEARCH_TOP)
    searchBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -SEARCH_TOP)
    searchBox:SetScript("OnTextChanged", Search_OnTextChanged)
    searchBox:SetScript("OnEnterPressed", Search_OnEnterPressed)
    searchBox:SetScript("OnEscapePressed", Search_OnEscapePressed)
    searchBox:SetScript("OnEditFocusGained", Search_OnFocusGained)
    searchBox:SetScript("OnEditFocusLost", Search_OnFocusLost)
    self.fieldSlice = Theme.CreateSlice(searchBox, "BACKGROUND")
    self.fieldSlice:SetPiece("field-normal")
    local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    placeholder:SetPoint("LEFT", searchBox, "LEFT", 8, 0)
    placeholder:SetTextColor(unpack(Theme.colors.dim))
    placeholder:SetText("Search icons (e.g. frost)")
    self.searchBox, self.placeholder = searchBox, placeholder

    local timer = CreateFrame("Frame", nil, frame)
    timer:Hide()
    timer:SetScript("OnUpdate", SearchTimer_OnUpdate)
    self.searchTimer = timer

    -- The grid's cell slots.
    self.cells = {}
    for slotIndex = 1, SLOTS do
        local cell = createCell(frame)
        local column = (slotIndex - 1) % COLUMNS
        local row = math.floor((slotIndex - 1) / COLUMNS)
        cell:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + column * PITCH, -(GRID_TOP + row * PITCH))
        self.cells[slotIndex] = cell
    end

    local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    empty:SetPoint("CENTER", frame, "TOPLEFT", PAD + GRID_WIDTH / 2, -(GRID_TOP + GRID_HEIGHT / 2))
    empty:SetTextColor(unpack(Theme.colors.dim))
    empty:SetText("No icons match")
    empty:Hide()
    self.emptyText = empty

    -- Themed scrollbar, one grid row per step (built like Menu's).
    local bar = CreateFrame("Slider", "WMCIconPickerScrollBar", frame, "UIPanelScrollBarTemplate")
    -- The template's own OnValueChanged scrolls its parent (SetVerticalScroll),
    -- which only a ScrollFrame has. Drop it before SetValue fires it.
    bar:SetScript("OnValueChanged", nil)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    bar:Hide()
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -(GRID_TOP + BAR))
    bar:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -PAD, -(GRID_TOP + GRID_HEIGHT - BAR))
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

    -- [Reset] left; [Cancel] [OK] right.
    local okX = WIDTH - PAD - BUTTON_WIDTH
    self.resetButton = createButton(self, "Reset", PAD, function() IconPicker:Reset() end)
    self.cancelButton = createButton(self, CANCEL or "Cancel", okX - BUTTON_GAP - BUTTON_WIDTH,
        function() IconPicker:Cancel() end)
    self.okButton = createButton(self, OKAY or "OK", okX, function() IconPicker:Accept() end)
end

--[[ State ]]

function IconPicker:IsShown()
    return self.frame ~= nil and self.frame:IsShown() and self.isOpen == true
end

local function maxOffset(self)
    return math.max(0, math.ceil(#self.list / COLUMNS) - ROWS)
end

-- Relabels the cell slots for the current offset and selection.
function IconPicker:Refresh()
    local first = self.offset * COLUMNS
    for slotIndex, cell in ipairs(self.cells) do
        local path = self.list[first + slotIndex]
        cell.path = path
        if path then
            cell.icon:SetTexture(path)
            cell.icon:SetTexCoord(ICON_ZOOM, 1 - ICON_ZOOM, ICON_ZOOM, 1 - ICON_ZOOM)
            updateRim(cell)
            cell:Show()
            if cell.hovered then
                showTooltip(cell)
            end
        else
            cell.hovered = false
            cell:Hide()
        end
    end
    if #self.list == 0 then
        self.emptyText:Show()
    else
        self.emptyText:Hide()
    end
    local top = maxOffset(self)
    if self.upButton then
        if self.offset > 0 then self.upButton:Enable() else self.upButton:Disable() end
    end
    if self.downButton then
        if self.offset < top then self.downButton:Enable() else self.downButton:Disable() end
    end
end

-- The preview, the name line and OK follow the selection.
function IconPicker:UpdateSelection()
    local path = self.selected
    if path then
        self.previewIcon:SetTexture(path)
        self.previewIcon:SetTexCoord(ICON_ZOOM, 1 - ICON_ZOOM, ICON_ZOOM, 1 - ICON_ZOOM)
        self.previewIcon:SetVertexColor(1, 1, 1, 1)
        self.nameText:SetText(fileName(path))
        self.nameText:SetTextColor(1, 1, 1)
    else
        self.previewIcon:SetTexture(BLACK_SQUARE)
        self.previewIcon:SetTexCoord(0, 1, 0, 1)
        self.previewIcon:SetVertexColor(0.02, 0.02, 0.02, 1)
        self.nameText:SetText("No icon selected")
        self.nameText:SetTextColor(unpack(Theme.colors.dim))
    end
    self.okButton:SetDisabled(path == nil)
end

function IconPicker:UpdateCount()
    local total, shown = #self.icons, #self.list
    if self.filter ~= "" then
        self.countText:SetText(shown .. " of " .. total .. " icons")
    else
        self.countText:SetText(total .. " icons")
    end
end

-- Scrolls so grid row `value` (0-based) is the top row.
function IconPicker:SetOffset(value)
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

function IconPicker:Scroll(delta)
    self:SetOffset(self.offset + (delta or 0))
end

-- The bar's range follows the filtered list's length.
function IconPicker:UpdateBar()
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

-- Filters the grid at once (the search box goes through the delay timer).
function IconPicker:SetFilter(text)
    text = (text or ""):lower()
    self.filter = text
    if self.searchTimer then
        self.searchTimer:Hide()
    end
    local list = {}
    for index, path in ipairs(self.icons) do
        if text == "" or self.names[index]:find(text, 1, true) then
            list[#list + 1] = path
        end
    end
    self.list = list
    self.offset = 0
    self:UpdateBar()
    self:Refresh()
    self:UpdateCount()
end

function IconPicker:Select(path)
    if not self:IsShown() or not path then
        return
    end
    self.selected = path
    for _, cell in ipairs(self.cells) do
        if cell.path then
            updateRim(cell)
        end
    end
    self:UpdateSelection()
end

-- Every icon the native macro popup lists.
local function readIcons()
    local icons, names = {}, {}
    local count = GetNumMacroIcons and GetNumMacroIcons() or 0
    for index = 1, count do
        local path = GetMacroIconInfo(index)
        if path then
            icons[#icons + 1] = path
            names[#names + 1] = fileName(path):lower()
        end
    end
    return icons, names
end

function IconPicker:Open(currentIcon, onAccept, anchor)
    self:Build()
    self:Cancel()
    addon.Dialog:Cancel()
    if addon.MuteDialog then
        addon.MuteDialog:Cancel()
    end
    addon.Menu:Close()
    local Dialog = addon.Dialog
    Dialog.ReleaseKeyboard(self.searchBox)
    self.onAccept = onAccept
    self.isOpen = true

    self.icons, self.names = readIcons()
    self.searchBox:SetText("")
    self.placeholder:Show()
    self.selected = currentIcon
    self:SetFilter("")

    -- Open with the current icon's row about mid-grid.
    if currentIcon then
        for index, path in ipairs(self.list) do
            if path == currentIcon then
                local row = math.ceil(index / COLUMNS) - 1
                self.offset = math.max(0, math.min(maxOffset(self), row - math.floor(ROWS / 2)))
                break
            end
        end
    end

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
    self.preview:SetFrameLevel(childLevel)
    self.searchBox:SetFrameLevel(childLevel)
    for _, cell in ipairs(self.cells) do
        cell:SetFrameLevel(childLevel)
    end
    self.scrollbar:SetFrameLevel(childLevel)
    for _, button in ipairs({ self.upButton, self.downButton }) do
        if button then
            button:SetFrameLevel(childLevel + 1)
        end
    end
    for _, button in ipairs({ self.resetButton, self.cancelButton, self.okButton }) do
        -- Created on UIParent by AceGUI: set the strata, don't inherit it.
        button.frame:SetFrameStrata(frame:GetFrameStrata())
        button.frame:SetFrameLevel(childLevel)
    end

    frame:ClearAllPoints()
    if owner and owner.IsShown and owner:IsShown() then
        frame:SetPoint("CENTER", owner, "CENTER", 0, 20)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    end
    frame:Show()

    -- Pixel-exact rims: read now, the UI scale may have changed.
    local pixel = Theme.PixelSize(frame) or 1
    for _, cell in ipairs(self.cells) do
        layoutRim(cell, pixel)
    end
    self:UpdateBar()
    self:Refresh()
    self:UpdateSelection()
    if PlaySound then
        PlaySound("igMainMenuOpen")
    end
    self.searchBox:SetFocus()
end

-- Closes without running anything; returns the callback.
function IconPicker:Close()
    local onAccept = self.onAccept
    self.onAccept, self.isOpen = nil, nil
    if self.searchBox then
        self.searchBox:ClearFocus()
    end
    if self.searchTimer then
        self.searchTimer:Hide()
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
    addon.Tooltip:Hide()
    return onAccept
end

function IconPicker:Accept()
    if not self:IsShown() or not self.selected then
        return
    end
    local path = self.selected
    local onAccept = self:Close()
    if PlaySound then
        PlaySound("igMainMenuOptionCheckBoxOn")
    end
    if onAccept then
        onAccept(path)
    end
end

function IconPicker:Reset()
    if not self:IsShown() then
        return
    end
    local onAccept = self:Close()
    if PlaySound then
        PlaySound("igMainMenuOptionCheckBoxOn")
    end
    if onAccept then
        onAccept(nil)
    end
end

function IconPicker:Cancel()
    if not self:IsShown() then
        return
    end
    self:Close()
    if PlaySound then
        PlaySound("igMainMenuClose")
    end
end
