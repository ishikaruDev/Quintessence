local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme
local Macros = addon.Macros
local Bank = addon.Bank
local Dialog = addon.Dialog
local Menu = addon.Menu

--[[-----------------------------------------------------------------------------
BankUI (addon.BankUI): the Macro Bank window (/qmb), in place of Blizzard's
macro window (Takeover.lua). bank-plan.md, phases 2 and 3.

  left:   the General and Character slots side by side, each a panel
          under a tab with its count ("GENERAL 12 / 36"; free slots drawn
          empty); the tab in use is lit; New, Delete.
          A click selects a macro (and its tab), a click on a free slot
          starts a new macro there, a drag puts it on the cursor (for the
          action bars).
  under:  the editor: icon (the icon picker), name, Save / Revert,
          in the text box, a column of icons: Bank, Template, Send (to
          another player: Send.lua);
          where the macro is (bank, slot), the text, and under it its
          length (past 255: a long macro, Macros.lua) with the status line
          at the row's right end.
          Under them, the loadouts (Loadouts.lua): the one chosen, Apply,
          Settings (the settings popup: Settings.lua), and what it loads
          and when this character uses it.
  right:  the bank (Store.lua): the section (General or a class), search,
          the list (categories, their macros; white: in a slot of this
          character), Load, New category; the gear by the section opens
          the settings' Bank tab, the book the guide (its Macros part). Right-click a
          macro or a category for the rest.

The editor holds a slot's macro, a bank macro, or a new one that Save
creates in the tab in use. A slot linked to a bank macro (Store.lua) is
edited as that bank macro: Save writes the bank and every linked slot.
Leaving unsaved edits (another macro, the other tab, New) asks first
(BankUI:Guard), as the compiler does.

The client moves slots on every change, so the selection is followed by
the macro's name and slot body (BankUI:MacrosChanged, on UPDATE_MACROS),
never trusted as a number.

  BankUI:Toggle(), :Show(), :Hide(), :IsShown()
  BankUI:SelectTab(tab), :Load(index or nil), :LoadBank(id), :New(),
  :Save(), :Revert(), :DeleteSelected(), :PickIcon(), :Refresh(),
  :RefreshBank(), :IsDirty(), :SetSection(section), :SaveToBank(category),
  :LoadSelected(wholeCategory), :ImportMacroBank(), :SendSelected()
  Fields: window, tab, selected (a slot index or nil), bankId (a bank id
  or nil), section, filter, cells, bankRows (the list's rows: .id or
  .category), nameBox, textArea, saveButton, revertButton, deleteButton,
  toBankButton, sendButton, loadButton, tabLabels, linkLine, counter, status. cells
  and tabLabels are per tab: cells.general[slot].
-------------------------------------------------------------------------------]]
local BankUI = { tab = "general", cells = {}, bankRows = {}, section = "GENERAL", filter = "" }
addon.BankUI = BankUI

addon.BANK_TITLE = "Quintessence Macros"

local STYLE = "bank"
-- The slots are a strip over the editor, as wide as its text box; the
-- bank's column on the right. No title plate (the text box's tab names the
-- macro); one gap everywhere; the loadout unframed, level with the bank's
-- buttons. The slots' panel is as wide as the text box's (not the widget,
-- whose scrollbar column is outside the box). General and Character side
-- by side, General 9 x 4 (its 36), Character 5 x 4 (its 18 and two spare),
-- each under a tab with its count; together as wide as the text box.
local LEFT_WIDTH = 639          -- the text box's widget
local GRID_WIDTH = LEFT_WIDTH - Theme.BOX_RIGHT_INSET
local SLOT_COLUMNS = { general = 9, character = 5 }
local SLOT_ROWS = 4
-- Each slot: the text box's panel piece, its rim 3 units; the icon inside.
local CELL = 37
local SLOT_RIM = 3
local CELL_GAP = 3
local PITCH = CELL + CELL_GAP
local GRID_PAD = 13
local IDLE_TAB_ALPHA = 0.55     -- the tab not in use
local TOP = 17                  -- below the title plate
local GAP = 8                   -- between the left column's blocks
local BUTTON_GAP = 6
local BUTTON_HEIGHT = 24
local ROW_GAP = 8

local NAME_WIDTH = 150
local NAME_ROW_HEIGHT = 42      -- the name box: its label (18) and field (24)
local ICON_SIZE = 32
local EDITOR_BUTTON_WIDTH = 76
local LINE_HEIGHT = 16

local RIGHT_WIDTH = 240
local LOADOUT_WIDTH = 240
local FIELD_HEIGHT = 42         -- a labelled field
local BOTTOM_CLEAR = 13         -- above the bottom band (and, with the pipe frame, its corner gear)
local CATEGORY_INDENT = 16

local ICON_ZOOM = 0.08
local EMPTY_SHADE = 0.05
local SELECTED_GLOW = "Interface\\Buttons\\CheckButtonHilight"
local GEAR_SIZE = 24             -- the field's height (the chevron's art is 24 tall)
local GEAR_ICON = "Interface\\Icons\\INV_Misc_Gear_01"
local HOVER_ALPHA = 0.15

local ERROR_COLOR = "|cffff4040"
local OK_COLOR = "|cff80ff80"
local NOTE_COLOR = "|cffffff80"
local DIM_COLOR = "|cff808080"
local CAPTION_COLOR = "|cff99ccff"

local function tabName(tab)
    return Macros.TAB_NAMES[tab]
end

-- A section's name, in its class's color.
local function sectionLabel(section)
    local color = addon.ClassColor(section)
    local name = Bank.SectionName(section)
    if not color then
        return name
    end
    return string.format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, name)
end

-- "Rogue / PvP" (a record's section and category).
local function placeName(record)
    local categories = Macros.db.categories[record.section]
    local category = record.category and categories and categories[record.category] and record.category
    return Bank.SectionName(record.section) .. " / " .. (category or Bank.UNSORTED)
end

--[[ Popups ]]

local function bankWindow()
    return BankUI.window and BankUI.window.frame
end

local ACCEPT_TEXT, CANCEL_TEXT, DELETE_TEXT = ACCEPT or "Accept", CANCEL or "Cancel", DELETE or "Delete"

local function cancelButton()
    return { text = CANCEL_TEXT, cancel = true }
end

Dialog:Register("QMB_DISCARD_CHANGES", {
    title = "Unsaved changes",
    text = "Save changes to '%s' before leaving?",
    hint = "Esc to keep editing",
    owner = bankWindow,
    buttons = {
        { text = "Save", action = function() BankUI:GuardSave() end },
        { text = "Discard", style = "red", action = function() BankUI:GuardDiscard() end },
    },
    default = 1,
    onCancel = function()
        BankUI.guardContinue = nil
    end,
})

Dialog:Register("QMB_DELETE_MACRO", {
    title = "Delete macro",
    text = "Delete macro '%s'? This cannot be undone.",
    owner = bankWindow,
    buttons = {
        {
            text = DELETE_TEXT,
            style = "red",
            action = function(_, data)
                BankUI:DeleteConfirmed(data)
            end,
        },
        cancelButton(),
    },
    -- Enter never deletes: it presses Cancel.
    default = 2,
})

Dialog:Register("QMB_DELETE_BANK_MACRO", {
    title = "Delete from the bank",
    text = "Delete '%s' from the bank? A slot that holds it keeps its macro.",
    owner = bankWindow,
    buttons = {
        {
            text = DELETE_TEXT,
            style = "red",
            action = function(_, data)
                BankUI:DeleteBankConfirmed(data.id)
            end,
        },
        cancelButton(),
    },
    default = 2,
})

Dialog:Register("QMB_NEW_CATEGORY", {
    title = "New category",
    text = "New category name:",
    hasEditBox = true,
    maxLetters = 40,
    owner = bankWindow,
    buttons = {
        {
            text = ACCEPT_TEXT,
            action = function(text)
                local name, createError = Bank:CreateCategory(BankUI.section, text)
                BankUI:SetStatus(name and ("Created the category '" .. name .. "'.") or createError,
                    name and OK_COLOR or ERROR_COLOR)
            end,
        },
        cancelButton(),
    },
})

Dialog:Register("QMB_RENAME_CATEGORY", {
    title = "Rename category",
    text = "Rename category '%s':",
    hasEditBox = true,
    maxLetters = 40,
    owner = bankWindow,
    editText = function(data)
        return data.name
    end,
    highlight = true,
    buttons = {
        {
            text = ACCEPT_TEXT,
            action = function(text, data)
                local name, renameError = Bank:RenameCategory(data.section, data.name, text)
                if not name then
                    BankUI:SetStatus(renameError, ERROR_COLOR)
                end
            end,
        },
        cancelButton(),
    },
})

Dialog:Register("QMB_DELETE_CATEGORY", {
    title = "Delete category",
    text = "Delete category '%s'? Its macros become unsorted.",
    owner = bankWindow,
    buttons = {
        {
            text = DELETE_TEXT,
            style = "red",
            action = function(_, data)
                Bank:DeleteCategory(data.section, data.name)
            end,
        },
        cancelButton(),
    },
    default = 2,
})

Dialog:Register("QMB_DELETE_UNSORTED", {
    title = "Delete unsorted",
    text = "Delete %s from the bank? A slot that holds one keeps its macro.",
    owner = bankWindow,
    buttons = {
        {
            text = DELETE_TEXT,
            style = "red",
            action = function(_, data)
                BankUI:DeleteUnsortedConfirmed(data.section)
            end,
        },
        cancelButton(),
    },
    default = 2,
})

Dialog:Register("QMB_MAKE_TEMPLATE", {
    title = "Make template",
    text = "%s", -- BankUI:MakeTemplate: the name, and a warning when there is one
    owner = bankWindow,
    buttons = {
        { text = "Switch", action = function(_, data) BankUI:TemplateConfirmed(data, true) end },
        { text = "Make", action = function(_, data) BankUI:TemplateConfirmed(data, false) end },
        cancelButton(),
    },
    default = 2,
})

-- BankUI:SendSelected: the saved macro to a player, who is asked first.
Dialog:Register("QMB_SEND_MACRO", {
    title = "Send macro",
    text = "Send '%s' to:",
    hint = "The player's name. They need Quintessence, and are asked first.",
    hasEditBox = true,
    maxLetters = 12,
    owner = bankWindow,
    editText = function(data)
        return data and data.target or ""
    end,
    highlight = true,
    buttons = {
        {
            text = "Send",
            action = function(text, data)
                addon.Send:OfferMacro(data.section, data.name, data.icon, data.text, text)
            end,
        },
        cancelButton(),
    },
})

Dialog:Register("QMB_IMPORT_BINDPAD", {
    title = "BindPad",
    text = "BindPad has %s with keys or macros. Bring its macros into the bank and its keys into Quintessence?",
    hint = "Later: the Bank tab of the settings (the gear), or /qmb keys import",
    owner = bankWindow,
    buttons = {
        { text = "Import", action = function() addon.BindPad:Run() end },
        { text = "Not now", cancel = true },
    },
})

Dialog:Register("QMB_IMPORT_MACROBANK", {
    title = "MacroBank",
    text = "MacroBank holds %s. Copy them into the Macro Bank?",
    hint = "Later: the Bank tab of the settings (the gear), or /qmb import",
    owner = bankWindow,
    buttons = {
        { text = "Import", action = function() BankUI:ImportMacroBank() end },
        { text = "Not now", cancel = true },
    },
})

-- The loadout dialogs go above the settings popup when it is open.
local function loadoutOwner()
    return addon.BankSettings and addon.BankSettings:Owner() or bankWindow()
end

Dialog:Register("QMB_NEW_LOADOUT", {
    title = "New loadout",
    text = "A loadout of the categories the tabs were last loaded from. Name:",
    hasEditBox = true,
    maxLetters = 40,
    owner = loadoutOwner,
    buttons = {
        { text = ACCEPT_TEXT, action = function(text) BankUI:NewLoadout(text) end },
        cancelButton(),
    },
})

Dialog:Register("QMB_RENAME_LOADOUT", {
    title = "Rename loadout",
    text = "Rename loadout '%s':",
    hasEditBox = true,
    maxLetters = 40,
    owner = loadoutOwner,
    editText = function(data)
        return data.name
    end,
    highlight = true,
    buttons = {
        {
            text = ACCEPT_TEXT,
            action = function(text, data)
                local name, renameError = addon.Loadouts:Rename(data.name, text)
                if name then
                    BankUI.loadout = name
                    BankUI:RefreshLoadouts()
                else
                    BankUI:SetStatus(renameError, ERROR_COLOR)
                end
            end,
        },
        cancelButton(),
    },
})

Dialog:Register("QMB_DELETE_LOADOUT", {
    title = "Delete loadout",
    text = "Delete loadout '%s'? Its categories and macros stay in the bank.",
    owner = loadoutOwner,
    buttons = {
        {
            text = DELETE_TEXT,
            style = "red",
            action = function(_, data)
                addon.Loadouts:Delete(data.name)
            end,
        },
        cancelButton(),
    },
    default = 2,
})

Dialog:Register("QMB_LOADOUT_TALENT", {
    title = "Use by a talent",
    text = "Use '%s' when this talent has points:",
    hasEditBox = true,
    maxLetters = 40,
    owner = loadoutOwner,
    buttons = {
        {
            text = ACCEPT_TEXT,
            action = function(text, data)
                text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if text ~= "" then
                    addon.Loadouts:AddRule({ talent = text, loadout = data.name })
                end
            end,
        },
        cancelButton(),
    },
})

--[[ Slots ]]

local function updateRim(cell)
    if cell.index and cell.hovered then
        cell.hover:Show()
    else
        cell.hover:Hide()
    end
    if cell.index and cell.index == BankUI.selected then
        cell.glow:Show()
    else
        cell.glow:Hide()
    end
end

local function showTooltip(cell)
    local macro = cell.index and Macros.Get(cell.index)
    if not macro then
        return
    end
    local tooltip = addon.Tooltip
    tooltip:SetOwner(cell, "ANCHOR_RIGHT")
    tooltip:SetText(macro.name, 1, 1, 1)
    if macro.long then
        tooltip:AddLine("Long macro: " .. #macro.text .. " characters", unpack(Theme.colors.caption))
    end
    local record = Bank:Get(Bank:LinkOf(macro))
    if record then
        tooltip:AddLine("In the bank: " .. placeName(record), unpack(Theme.colors.caption))
    end
    tooltip:AddLine("Drag it onto an action bar.", unpack(Theme.colors.dim))
    tooltip:Show()
end

local function Cell_OnClick(cell)
    if cell.index then
        BankUI:ClickSlot(cell.index)
    elseif cell.tab then
        BankUI:NewIn(cell.tab)
    end
end

local function Cell_OnDragStart(cell)
    if cell.index and PickupMacro then
        PickupMacro(cell.index)
    end
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
    cell:RegisterForDrag("LeftButton")
    cell:SetScript("OnClick", Cell_OnClick)
    cell:SetScript("OnDragStart", Cell_OnDragStart)
    cell:SetScript("OnEnter", Cell_OnEnter)
    cell:SetScript("OnLeave", Cell_OnLeave)
    Theme.CreatePanel(cell, "BORDER")
    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", cell, "TOPLEFT", SLOT_RIM, -SLOT_RIM)
    icon:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -SLOT_RIM, SLOT_RIM)
    cell.icon = icon
    local hover = cell:CreateTexture(nil, "OVERLAY")
    hover:SetAllPoints(icon)
    hover:SetTexture(1, 1, 1, HOVER_ALPHA)
    hover:SetBlendMode("ADD")
    hover:Hide()
    cell.hover = hover
    local glow = cell:CreateTexture(nil, "OVERLAY")
    glow:SetTexture(SELECTED_GLOW)
    glow:SetBlendMode("ADD")
    glow:SetAllPoints(cell)
    glow:Hide()
    cell.glow = glow
    return cell
end

--[[ Window ]]

-- Puts an AceGUI widget at a fixed place in `parent` (no layout engine:
-- the window has a fixed size).
local function place(widget, parent, x, y)
    local frame = widget.frame
    frame:SetParent(parent)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    frame:Show()
    return widget
end

-- The gear that opens the settings on their Bank tab: the theme's
-- "bank-gear" pieces once drawn (prompt: bank-gear-art.md), till then the
-- game's gear icon.
local function Gear_OnEnter(button)
    local tooltip = addon.Tooltip
    tooltip:SetOwner(button, "ANCHOR_RIGHT")
    tooltip:SetText("Bank settings", 1, 1, 1)
    tooltip:Show()
end

local function createGear(parent)
    local button
    if pcall(Theme.Piece, "bank-gear") then
        button = Theme.CreateIconButton(parent)
        button:SetIcon("bank-gear")
    else
        button = CreateFrame("Button", nil, parent)
        button:SetWidth(GEAR_SIZE)
        button:SetHeight(GEAR_SIZE)
        button:SetNormalTexture(GEAR_ICON)
        button:SetHighlightTexture(GEAR_ICON, "ADD")
    end
    button:SetScript("OnClick", function()
        addon.BankSettings:Open("bank")
    end)
    button:SetScript("OnEnter", Gear_OnEnter)
    button:SetScript("OnLeave", function() addon.Tooltip:Hide() end)
    return button
end

local function makeButton(text, width, onClick)
    local button = AceGUI:Create("WMC-Button")
    button:SetText(text)
    button:SetWidth(width)
    button:SetCallback("OnClick", onClick)
    return button
end

local function makeLine(parent, x, y, width)
    local line = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    line:SetWidth(width)
    line:SetJustifyH("LEFT")
    return line
end

function BankUI:Build()
    if self.window then
        return self.window
    end
    local settings = Macros.db.settings
    local window = AceGUI:Create("WMC-Window")
    window:SetFrameStyle(STYLE)
    window:SetTitle(addon.BANK_TITLE)
    settings.window = settings.window or {}
    window:SetStatusTable(settings.window)
    window:SetCallback("OnClose", function(widget)
        -- Its popups go with it, as Escape.
        if Dialog:IsShown() and Dialog.owner == widget.frame then
            Dialog:Cancel()
        end
        Menu:Close()
        addon.IconPicker:Cancel()
        addon.BankSettings:Close()
        addon.Tooltip:Hide()
        widget:Hide()
    end)
    self.window = window
    -- Escape closes it (no underscore: never a template's WMC_<name>).
    _G.QMBWindow = window.frame
    if UISpecialFrames then
        table.insert(UISpecialFrames, "QMBWindow")
    end
    -- The guide docks beside it when opened from here (the book), and
    -- follows when it is dragged.
    addon.Guide:Attach("bank", window.frame)
    if window.title and window.title.HookScript then
        window.title:HookScript("OnMouseUp", function()
            addon.Guide:MainMoved("bank")
        end)
    end
    -- The bank opens on this character's class;
    -- a section picked after stays until the next login or reload.
    local class = select(2, UnitClass("player"))
    if class and Bank.SectionName(class) ~= class then
        self.section = class
    end

    local content = window.content
    local frameData, insets = Theme.FrameData(STYLE), Theme.CONTENT_INSETS[STYLE]
    local contentWidth = frameData.width - insets.left - insets.right
    local contentHeight = frameData.height - insets.top - insets.bottom

    -- The tabs side by side: each its slots in a panel, under a section
    -- tab with its count; the one in use (where New makes a macro) lit.
    local tabRise = Theme.SECTION_TAB_HEIGHT - 8
    local gridTop = TOP + tabRise
    local gridHeight = 2 * GRID_PAD + SLOT_ROWS * PITCH - CELL_GAP
    self.tabLabels = {}
    for _, tab in ipairs(Macros.TABS) do
        local columns = SLOT_COLUMNS[tab]
        local gridWidth = 2 * GRID_PAD + columns * PITCH - CELL_GAP
        local grid = CreateFrame("Frame", nil, content)
        grid:SetPoint("TOPLEFT", content, "TOPLEFT", tab == "general" and 0 or GRID_WIDTH - gridWidth, -gridTop)
        grid:SetWidth(gridWidth)
        grid:SetHeight(gridHeight)
        Theme.CreatePanel(grid)
        local label = Theme.CreateSectionTab(grid)
        label:SetPoint("BOTTOMLEFT", grid, "TOPLEFT", 0, -8)
        label:EnableMouse(true)
        label:SetScript("OnMouseUp", function()
            self:ClickTab(tab)
        end)
        self.tabLabels[tab] = label
        local cells = {}
        for slot = 1, columns * SLOT_ROWS do
            local cell = createCell(grid)
            cell.tab = tab
            local column, row = (slot - 1) % columns, math.floor((slot - 1) / columns)
            cell:SetPoint("TOPLEFT", grid, "TOPLEFT", GRID_PAD + column * PITCH, -(GRID_PAD + row * PITCH))
            cells[slot] = cell
        end
        self.cells[tab] = cells
    end

    -- From the slots down to the loadout (its dropdown, buttons, two
    -- lines; it ends level with the bank's last button): the text box
    -- takes whole lines, and what is left over is shared by the three gaps
    -- between the blocks: the slots / New, Delete / the editor (the name
    -- row, the bank line, the text box and its length line) / the loadout.
    local loadoutTop = contentHeight - BOTTOM_CLEAR - (FIELD_HEIGHT + 4 + 2 * 14)
    local boxExtra = tabRise + 18 -- the tab over the text box, its padding and edge
    local editorExtra = NAME_ROW_HEIGHT + 4 + LINE_HEIGHT + 4 + boxExtra + 4 + LINE_HEIGHT
    local free = loadoutTop - (gridTop + gridHeight) - BUTTON_HEIGHT - editorExtra
    local lines = math.floor((free - 3 * GAP) / 14)
    local blockGap = math.floor((free - lines * 14) / 3)

    -- Under the slots, what acts on them: New, Delete; next to them the
    -- drag hint.
    local top = gridTop + gridHeight + blockGap
    place(makeButton("New", EDITOR_BUTTON_WIDTH, function() self:New() end), content, 0, top)
    local deleteButton = makeButton("Delete", EDITOR_BUTTON_WIDTH, function() self:DeleteSelected() end)
    deleteButton:SetStyle("red")
    place(deleteButton, content, EDITOR_BUTTON_WIDTH + BUTTON_GAP, top)
    self.deleteButton = deleteButton
    local hintLeft = 2 * (EDITOR_BUTTON_WIDTH + BUTTON_GAP) + GAP
    local hint = makeLine(content, hintLeft, top + 5, GRID_WIDTH - hintLeft)
    hint:SetText(DIM_COLOR .. "Drag a macro onto an action bar.|r")

    -- The editor: the icon, the name, Save and Revert; the bank line; the
    -- text, its tab naming the macro.
    local width = LEFT_WIDTH
    local lineWidth = width - addon.SECTION_RIGHT_INSET
    top = top + BUTTON_HEIGHT + blockGap
    local fieldTop = top + NAME_ROW_HEIGHT - BUTTON_HEIGHT -- the name field, under its label
    local icon = AceGUI:Create("WMC-Icon")
    icon:SetImageSize(24, 24)
    icon:SetCallback("OnClick", function() self:PickIcon() end)
    place(icon, content, 0, fieldTop + (BUTTON_HEIGHT - ICON_SIZE) / 2)
    self.iconWidget = icon

    local nameBox = AceGUI:Create("WMC-EditBox")
    nameBox:SetLabel("Name")
    nameBox:SetWidth(NAME_WIDTH)
    nameBox:SetMaxLetters(Macros.NAME_MAX)
    nameBox:SetCallback("OnTextChanged", function() self:EditorChanged() end)
    nameBox:SetCallback("OnEnterPressed", function()
        nameBox:ClearFocus()
        self:Save()
    end)
    local x = ICON_SIZE + ROW_GAP
    place(nameBox, content, x, top)
    self.nameBox = nameBox

    x = x + NAME_WIDTH + ROW_GAP
    self.saveButton = place(makeButton("Save", EDITOR_BUTTON_WIDTH, function() self:Save() end), content, x, fieldTop)
    x = x + EDITOR_BUTTON_WIDTH + BUTTON_GAP
    self.revertButton = place(makeButton("Revert", EDITOR_BUTTON_WIDTH, function() self:Revert() end), content, x,
        fieldTop)

    top = top + NAME_ROW_HEIGHT + 4
    self.linkLine = makeLine(content, 0, top, lineWidth)

    -- The text box, its length line right under it ("19/255 is too far
    -- from the text box").
    local textTop = top + LINE_HEIGHT + 4
    local counterTop = textTop + boxExtra + lines * 14 + 4

    local textArea = AceGUI:Create("WMC-TextArea")
    textArea:SetSectionTab("Macro text")
    textArea:SetNumLines(lines)
    textArea:SetWidth(width)
    textArea:SetCallback("OnTextChanged", function() self:EditorChanged() end)
    -- the compiler editor's colors (its tokenizer reads plain macro lines
    -- too: slash commands, conditions, #showtooltip)
    if addon.UI and addon.UI.HighlightSource then
        textArea:SetHighlighter(addon.UI.HighlightSource)
    end
    place(textArea, content, 0, textTop)
    self.textArea = textArea
    self:BuildEditorIcons(textArea)
    -- (UpdateEditorState names the macro on the text box's tab)
    self.heading = {
        SetText = function(heading, text)
            heading.text = text
            textArea:SetSectionTab(text)
        end,
        GetText = function(heading)
            return heading.text
        end,
    }

    -- The length line, and at its right end the status line (next to the
    -- editor, where its actions are), as wide as
    -- the length leaves it (FitStatus).
    self.counter = makeLine(content, 0, counterTop, lineWidth)
    self.counterWidth = lineWidth
    self.status = makeLine(content, 0, counterTop, lineWidth)
    self.status:ClearAllPoints()
    self.status:SetPoint("TOPRIGHT", content, "TOPLEFT", lineWidth, -counterTop)
    self.status:SetJustifyH("RIGHT")
    self.status:SetHeight(LINE_HEIGHT) -- one line; a longer one is cut

    -- The loadouts, along the bottom: labelled as the bank's dropdown.
    local loadoutDropdown = AceGUI:Create("WMC-Dropdown")
    loadoutDropdown:SetLabel("Loadout")
    loadoutDropdown:SetWidth(LOADOUT_WIDTH)
    loadoutDropdown:SetCallback("OnValueChanged", function(_, _, value)
        self.loadout = value
        self:RefreshLoadouts()
    end)
    place(loadoutDropdown, content, 0, loadoutTop)
    self.loadoutDropdown = loadoutDropdown
    local rowTop = loadoutTop + FIELD_HEIGHT - BUTTON_HEIGHT -- level with the field
    x = LOADOUT_WIDTH + ROW_GAP
    self.applyButton = place(makeButton("Apply", EDITOR_BUTTON_WIDTH, function() self:ApplyLoadout() end), content,
        x, rowTop)
    x = x + EDITOR_BUTTON_WIDTH + BUTTON_GAP
    self.loadoutSettingsButton = place(makeButton("Settings", EDITOR_BUTTON_WIDTH, function()
        addon.BankSettings:Open("loadout")
    end), content, x, rowTop)
    self.loadoutInfo = makeLine(content, 0, loadoutTop + FIELD_HEIGHT + 4, lineWidth)
    self.loadoutInfo:SetJustifyV("TOP")

    -- Right: the bank.
    local right = contentWidth - RIGHT_WIDTH
    local sectionDropdown = AceGUI:Create("WMC-Dropdown")
    sectionDropdown:SetLabel("Bank section")
    sectionDropdown:SetWidth(RIGHT_WIDTH - 2 * (GEAR_SIZE + BUTTON_GAP))
    local list = {}
    for _, section in ipairs(Bank.SECTIONS) do
        list[section] = sectionLabel(section)
    end
    sectionDropdown:SetList(list, Bank.SECTIONS)
    sectionDropdown:SetValue(self.section)
    sectionDropdown:SetCallback("OnValueChanged", function(_, _, value)
        self:SetSection(value)
    end)
    place(sectionDropdown, content, right, TOP)
    self.sectionDropdown = sectionDropdown
    -- The settings' Bank tab, by the field.
    local gear = createGear(content)
    local gearTop = -(TOP + FIELD_HEIGHT - BUTTON_HEIGHT + (BUTTON_HEIGHT - GEAR_SIZE) / 2)
    gear:SetPoint("TOPLEFT", content, "TOPLEFT", right + RIGHT_WIDTH - 2 * GEAR_SIZE - BUTTON_GAP, gearTop)
    self.gearButton = gear
    -- Then the book: the guide, at its Macros part.
    local book = Theme.CreateIconButton(content)
    book:SetIcon("bank-book")
    book:SetPoint("TOPLEFT", content, "TOPLEFT", right + RIGHT_WIDTH - GEAR_SIZE, gearTop)
    book:SetScript("OnClick", function()
        addon.Guide:ToggleFor("bank", "macros")
    end)
    book:SetScript("OnEnter", function(button)
        addon.Tooltip:SetOwner(button, "ANCHOR_RIGHT")
        addon.Tooltip:SetText("Arcanum", 1, 1, 1)
        addon.Tooltip:AddLine("The in-game guide: how this window works.", nil, nil, nil, true)
        addon.Tooltip:Show()
    end)
    book:SetScript("OnLeave", function() addon.Tooltip:Hide() end)
    self.bookButton = book

    local search = AceGUI:Create("WMC-EditBox")
    search:SetLabel("Search")
    search:SetWidth(RIGHT_WIDTH)
    search:SetCallback("OnTextChanged", function(_, _, value)
        self.filter = value or ""
        self:RefreshBank()
    end)
    -- Names only, or names and the macro text (settings.searchInText).
    self.searchModeButton = addon.SearchModeButton(
        function() return Macros.db.settings.searchInText == true end,
        function(on)
            Macros.db.settings.searchInText = on or nil
            self:RefreshBank()
        end)
    search:SetSideButton(self.searchModeButton)
    place(search, content, right, TOP + FIELD_HEIGHT + 4)
    self.searchBox = search

    local bankButtonsTop = contentHeight - BOTTOM_CLEAR - BUTTON_HEIGHT
    local listTop = TOP + 2 * FIELD_HEIGHT + 4 + ROW_GAP
    local scroll = AceGUI:Create("WMC-ScrollFrame")
    scroll:SetFramed(true)
    scroll:SetLayout("List")
    scroll:SetWidth(RIGHT_WIDTH)
    scroll:SetHeight(bankButtonsTop - ROW_GAP - listTop)
    place(scroll, content, right, listTop)
    self.bankScroll = scroll

    local bankHalf = math.floor((RIGHT_WIDTH - BUTTON_GAP) / 2)
    self.loadButton = place(makeButton("Load", bankHalf, function()
        self:LoadSelected(IsShiftKeyDown and IsShiftKeyDown())
    end), content, right, bankButtonsTop)
    place(makeButton("New category", bankHalf, function()
        Dialog:Show("QMB_NEW_CATEGORY")
    end), content, right + RIGHT_WIDTH - bankHalf, bankButtonsTop)

    window:Hide()
    self:Load(self:FirstSlot())
    self:RefreshLoadouts()
    return window
end

--[[ Showing ]]

function BankUI:IsShown()
    return self.window ~= nil and self.window.frame:IsShown()
end

-- MacroBank's macros and categories, when its data is loaded.
local function macroBankCounts()
    local store = type(MacroBankDB) == "table" and MacroBankDB.global and MacroBankDB.global.Macros
    if type(store) ~= "table" then
        return nil
    end
    local macros, categories = 0, 0
    local function walk(entry)
        if type(entry) ~= "table" then
            return
        end
        categories = categories + 1
        macros = macros + (type(entry[2]) == "table" and #entry[2] or 0)
        for _, sub in ipairs(type(entry[3]) == "table" and entry[3] or {}) do
            walk(sub)
        end
    end
    for _, entry in ipairs(store) do
        walk(entry)
    end
    return macros, categories
end

function BankUI:Show()
    if not Macros.db then
        return -- before PLAYER_LOGIN
    end
    self:Build()
    if self:IsShown() then
        return
    end
    self.window:Show()
    self:MacrosChanged()
    self:RefreshBank()
    -- Offered once: MacroBank's store.
    local settings = Macros.db.settings
    local macros, categories = macroBankCounts()
    if macros and macros > 0 and not settings.macroBankAsked and not (Macros.db.imported or {}).macroBank then
        settings.macroBankAsked = true
        Dialog:Show("QMB_IMPORT_MACROBANK", macros .. " macros in " .. categories .. " categories")
    elseif addon.BindPad then
        -- Offered once per character: BindPad's keys.
        addon.BindPad:Offer()
    end
end

function BankUI:Hide()
    if self:IsShown() then
        self.window:Hide()
    end
end

function BankUI:Toggle()
    if self:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

--[[ The grid ]]

function BankUI:FirstSlot()
    local macro = Macros.List(self.tab)[1]
    return macro and macro.index or nil
end

function BankUI:Refresh()
    if not self.window then
        return
    end
    for _, tab in ipairs(Macros.TABS) do
        local list = Macros.List(tab)
        local used, max = Macros.Count(tab)
        local label = self.tabLabels[tab]
        label:SetText(tabName(tab) .. "   " .. used .. " / " .. max)
        label:SetAlpha(tab == self.tab and 1 or IDLE_TAB_ALPHA)
        for slot, cell in ipairs(self.cells[tab]) do
            local macro = list[slot]
            cell.index = macro and macro.index or nil
            if slot > max then
                cell.hovered = false
                cell:Hide()
            else
                if macro then
                    cell.icon:SetTexture(macro.icon or Macros.DEFAULT_ICON)
                    cell.icon:SetTexCoord(ICON_ZOOM, 1 - ICON_ZOOM, ICON_ZOOM, 1 - ICON_ZOOM)
                    cell.icon:SetVertexColor(1, 1, 1, 1)
                else
                    cell.icon:SetTexture(EMPTY_SHADE, EMPTY_SHADE, EMPTY_SHADE, 1)
                end
                updateRim(cell)
                cell:Show()
                if cell.hovered then
                    if macro then
                        showTooltip(cell)
                    else
                        addon.Tooltip:Hide()
                    end
                end
            end
        end
    end
    self.deleteButton:SetDisabled(not self.selected)
end

-- UPDATE_MACROS (and on show): the slots may have moved or changed under
-- the selection. It is found again by its name and slot body; a macro that
-- is gone leaves unsaved edits in the editor (as a new macro, or as its
-- bank macro), and otherwise gives the editor to whatever is in its place.
function BankUI:MacrosChanged()
    if not self:IsShown() or self.busy then
        return
    end
    local banked = self.bankId and Bank:Get(self.bankId)
    if self.selected then
        local now = Macros.Find(self.tab, self.identity.name, self.identity.body, self.selected)
        if now then
            self.selected = now
        elseif self:IsDirty() then
            self.selected, self.identity = nil, nil
            self:UpdateEditorState()
        elseif banked then
            self:LoadBank(self.bankId)
            return
        else
            self:Load(Macros.Get(self.selected) and self.selected or self:FirstSlot())
            return
        end
    elseif banked and not self:IsDirty() then
        self:LoadBank(self.bankId) -- it may be in a slot now
        return
    end
    self:Refresh()
    self:RefreshBank()
end

--[[ The bank's list ]]

-- Scrolls the list so `row` is in view, centred if it was out of it.
local function scrollTo(scroll, row, offset)
    local top = 0
    for _, child in ipairs(scroll.children or {}) do
        if child == row then
            break
        end
        top = top + (child.frame:GetHeight() or 0)
    end
    local height = row.frame:GetHeight() or 0
    local view = scroll.scrollframe and scroll.scrollframe:GetHeight() or 0
    if top >= offset and top + height <= offset + view then
        return offset
    end
    return math.max(0, math.floor(top + height / 2 - view / 2))
end

local function scrollStatus(scroll)
    return scroll.status or scroll.localstatus
end

function BankUI:RefreshBank()
    local scroll = self.bankScroll
    if not scroll then
        return
    end
    local status = scrollStatus(scroll)
    local keepOffset = status and status.offset or 0
    scroll:ReleaseChildren()
    scroll:PauseLayout() -- one layout for the whole list, not one per row
    self.bankRows = {}

    -- The bank macros in a slot of this character are drawn brighter.
    local inSlot = {}
    for _, tab in ipairs(Macros.TABS) do
        for _, macro in ipairs(Macros.List(tab)) do
            for _, id in ipairs(Bank:LinksOf(macro)) do
                inSlot[id] = true
            end
        end
    end

    local revealed
    local section = self.section
    local hover = addon.ClassColor(section)
    local inCategory = false
    for _, entry in ipairs(Bank:List(section, self.filter, nil, Macros.db.settings.searchInText == true)) do
        local row = AceGUI:Create("WMC-ListRow")
        row:SetFullWidth(true)
        if entry.id then
            local id, record = entry.id, entry.record
            local selected = id == self.bankId
            row.id = id
            row:SetIndent(inCategory and CATEGORY_INDENT or 0)
            row:SetRowIcon(record.icon or Macros.DEFAULT_ICON)
            row:SetText(record.name)
            if inSlot[id] then
                row:SetTextColor(1, 1, 1)
            else
                row:SetTextColor(0.72, 0.72, 0.72)
            end
            row:SetRowBackground(addon.TemplateRowColor(section, false, selected, false))
            row:SetSelected(selected)
            if selected then
                revealed = row
            end
            if hover then
                row:SetHoverColor(hover.r, hover.g, hover.b)
            end
            row:SetCallback("OnClick", function() self:ClickBank(id) end)
            row:SetCallback("OnIconClick", function() self:ClickBank(id) end)
            row:SetCallback("OnRightClick", function() self:OpenMacroMenu(id) end)
            -- Its key here at the row's end (Keys.lua).
            local key = addon.Keys:KeyFor("macro", id)
            row:SetKeyText(key and addon.Keys.ShortText(key))
        else
            local name = entry.category
            row.id = nil
            row.category = name
            inCategory = name and true or false
            row:SetRowIcon(false)
            row:SetText((name or Bank.UNSORTED) .. "  " .. DIM_COLOR .. "(" .. entry.count .. ")|r")
            if name then
                row:SetTextColor(1, 0.82, 0)
            else
                row:SetTextColor(0.7, 0.7, 0.7)
            end
            if name and not entry.forced then
                local function toggle()
                    Bank:SetCategoryCollapsed(section, name, not entry.collapsed)
                end
                row:SetExpanded(not entry.collapsed)
                row:SetCallback("OnToggle", toggle)
                row:SetCallback("OnClick", toggle)
            else
                row:SetExpanded(nil)
            end
            row:SetCallback("OnRightClick", function() self:OpenCategoryMenu(name) end)
        end
        scroll:AddChild(row)
        self.bankRows[#self.bankRows + 1] = row
    end
    scroll:ResumeLayout()
    scroll:DoLayout()
    local reveal = self.revealing
    self.revealing = nil
    if status then
        status.offset = (reveal and revealed) and scrollTo(scroll, revealed, keepOffset) or keepOffset
        if scroll.FixScroll and self:IsShown() then
            scroll:FixScroll()
        end
    end
    local banked = self.bankId and Bank:Get(self.bankId)
    self.loadButton:SetDisabled(not banked)
    if banked then
        self.keyButton:Enable()
    else
        self.keyButton:Disable()
    end
    if self.selected then
        self.toBankButton:Enable()
    else
        self.toBankButton:Disable()
    end
end

-- The store changed (Store.lua).
function BankUI:BankChanged()
    if not self.window or self.busy then
        return
    end
    if self.bankId and not Bank:Get(self.bankId) then
        self.bankId = nil
    end
    -- a slot may have become linked, or stopped being
    if self.selected and not self:IsDirty() then
        self.bankId = Bank:LinkOf(Macros.Get(self.selected))
    end
    self:UpdateEditorState()
    self:Refresh()
    self:RefreshBank()
end

function BankUI:SetSection(section)
    self.section = section
    if self.sectionDropdown then
        self.sectionDropdown:SetValue(section)
    end
    self:RefreshBank()
end

--[[ The editor ]]

function BankUI:SetStatus(text, color)
    if not self.status then
        return
    end
    if not text or text == "" then
        self.status:SetText("")
    else
        self.status:SetText((color or "") .. text .. (color and "|r" or ""))
    end
end

-- The status line takes what the length line leaves of their row.
function BankUI:FitStatus()
    local width = self.counterWidth - math.ceil(self.counter:GetStringWidth() or 0) - GAP
    self.status:SetWidth(math.max(width, 1))
end

function BankUI:IsDirty()
    if not self.window then
        return false
    end
    return self.pendingIcon ~= nil or self.nameBox:GetText() ~= self.cleanName
        or self.textArea:GetText() ~= self.cleanText
end

-- The heading, the buttons, the place line and the length line, for the
-- editor as it is.
function BankUI:UpdateEditorState()
    local name = self.nameBox:GetText()
    local record = Bank:Get(self.bankId)
    local shownName = self.identity and self.identity.name or (record and record.name) or name
    if self.selected then
        self.heading:SetText(tabName(self.tab) .. " / " .. shownName)
    elseif record then
        self.heading:SetText("Bank / " .. shownName)
    else
        self.heading:SetText("New " .. tabName(self.tab):lower() .. " macro")
    end
    self.saveButton:SetText((self.selected or record) and "Save" or "Create")
    self.revertButton:SetDisabled(not self:IsDirty())
    self.iconWidget:SetImage(self.pendingIcon or self.cleanIcon or Macros.DEFAULT_ICON, ICON_ZOOM, 1 - ICON_ZOOM,
        ICON_ZOOM, 1 - ICON_ZOOM)

    if record and self.selected then
        self.linkLine:SetText(CAPTION_COLOR .. "In the bank: " .. placeName(record) .. "|r")
    elseif record then
        self.linkLine:SetText(CAPTION_COLOR .. placeName(record) .. "|r" .. DIM_COLOR
            .. "  (not in a slot of this character)|r")
    elseif self.selected then
        self.linkLine:SetText(DIM_COLOR .. "Not in the bank.|r")
    else
        self.linkLine:SetText("")
    end

    local text = self.textArea:GetText()
    local length = #text
    if length <= Macros.BODY_MAX then
        self.counter:SetText(length .. " / " .. Macros.BODY_MAX)
        self:FitStatus()
        return
    end
    local buttons, measureError = addon.Secure.Measure("INTERNAL_QMB0000", text)
    if not buttons then
        self.counter:SetText(ERROR_COLOR .. length .. " characters. " .. measureError .. "|r")
    else
        self.counter:SetText(NOTE_COLOR .. "Long macro: " .. length .. " characters|r (its slot runs it with /click).")
    end
    self:FitStatus()
end

function BankUI:EditorChanged()
    self:SetStatus("")
    self:UpdateEditorState()
end

-- Fills the editor's fields and redraws both lists.
local function fill(self, name, text, icon)
    self.cleanName, self.cleanText, self.cleanIcon = name, text, icon
    self.pendingIcon = nil
    self.nameBox:SetText(name)
    self.textArea:SetText(text)
    self:SetStatus("")
    self:UpdateEditorState()
    self:Refresh()
    self:RefreshBank()
end

-- Fills the editor from a slot (nil: a new macro in the shown tab). A slot
-- linked to a bank macro is edited as that bank macro.
function BankUI:Load(index)
    local macro = index and Macros.Get(index)
    if macro then
        self.tab = macro.tab
    end
    self.selected = macro and macro.index or nil
    self.identity = macro and { name = macro.name, body = macro.body } or nil
    self.bankId = Bank:LinkOf(macro)
    fill(self, macro and macro.name or "", macro and macro.text or "", macro and macro.icon or nil)
end

-- Fills the editor from a bank macro; its linked slot (the shown tab's
-- first, else the other tab's) is selected with it.
function BankUI:LoadBank(id)
    local record = Bank:Get(id)
    if not record then
        self:Load(self:FirstSlot())
        return
    end
    local slot
    for _, index in ipairs(Bank:SlotsOf(id)) do
        if not slot or (Macros.TabOf(index) == self.tab and Macros.TabOf(slot) ~= self.tab) then
            slot = index
        end
    end
    local macro = slot and Macros.Get(slot)
    if macro then
        self.tab = macro.tab
    end
    self.selected = macro and macro.index or nil
    self.identity = macro and { name = macro.name, body = macro.body } or nil
    self.bankId = id
    fill(self, record.name, record.text, macro and macro.icon or record.icon)
end

function BankUI:Revert()
    if self.bankId and Bank:Get(self.bankId) then
        self:LoadBank(self.bankId)
    else
        self:Load(self.selected)
    end
end

-- Runs continue() now, or after the unsaved-changes popup: Save (only if
-- the save works), Discard; Escape keeps editing.
function BankUI:Guard(continue)
    if not self:IsDirty() then
        continue()
        return
    end
    self.guardContinue = continue
    local record = Bank:Get(self.bankId)
    Dialog:Show("QMB_DISCARD_CHANGES", self.identity and self.identity.name or (record and record.name)
        or self.nameBox:GetText())
end

function BankUI:GuardSave()
    local continue = self.guardContinue
    self.guardContinue = nil
    if self:Save() and continue then
        continue()
    end
end

function BankUI:GuardDiscard()
    local continue = self.guardContinue
    self.guardContinue = nil
    if continue then
        continue()
    end
end

-- A click on a slot. The guard's Save may move the slots: the clicked
-- macro is found again before it is loaded.
function BankUI:ClickSlot(index)
    if index == self.selected then
        self:Reveal(self.bankId)
        return
    end
    local macro = Macros.Get(index)
    if not macro then
        return
    end
    self:Guard(function()
        self:Load(Macros.Find(macro.tab, macro.name, macro.body, index))
        self:Reveal(self.bankId)
    end)
end

-- Shows bank macro `id` in the list: its section, its category open, the
-- search cleared if it hides it, and the list scrolled to it.
function BankUI:Reveal(id)
    local record = Bank:Get(id)
    if not record then
        return
    end
    if not Bank.Matches(record, self.filter, Macros.db.settings.searchInText == true) then
        self.filter = ""
        self.searchBox:SetText("")
    end
    local categories = Macros.db.categories[record.section]
    local category = record.category and categories and categories[record.category]
    if category and category.collapsed then
        self.busy = true -- one redraw, below
        Bank:SetCategoryCollapsed(record.section, record.category, false)
        self.busy = false
    end
    if record.section ~= self.section then
        self.section = record.section
        self.sectionDropdown:SetValue(record.section)
    end
    self.revealing = true
    self:RefreshBank()
end


function BankUI:ClickBank(id)
    if id == self.bankId then
        return
    end
    self:Guard(function()
        self:LoadBank(id)
    end)
end

function BankUI:SelectTab(tab)
    self.tab = tab
    self:Load(self:FirstSlot())
end

function BankUI:ClickTab(tab)
    if tab == self.tab then
        return
    end
    self:Guard(function()
        self:SelectTab(tab)
    end)
end

function BankUI:New()
    self:Guard(function()
        self:Load(nil)
        self.nameBox:SetFocus()
    end)
end

-- A click on an empty slot: a new macro in its tab.
function BankUI:NewIn(tab)
    self:Guard(function()
        self.tab = tab
        self:Load(nil)
        self.nameBox:SetFocus()
    end)
end

-- Save (a bank macro and its linked slots, or a slot) or Create (a new
-- slot macro). Returns true when done.
function BankUI:Save()
    local name, text = self.nameBox:GetText(), self.textArea:GetText()
    local banked = self.bankId and Bank:Get(self.bankId) and self.bankId
    local creating = not self.selected and not banked
    -- The client's UPDATE_MACROS arrives while the selection is stale.
    self.busy = true
    local index, saveError
    if banked then
        index, saveError = Bank:Update(banked, name, self.pendingIcon, text)
    elseif creating then
        index, saveError = Macros:Create(self.tab, name, self.pendingIcon, text)
    else
        index, saveError = Macros:Edit(self.selected, name, self.pendingIcon, text)
    end
    self.busy = false
    if not index then
        self:SetStatus(saveError, ERROR_COLOR)
        return false
    end
    -- A new one into the category its tab was filled from, when asked for
    -- (the settings' Bank tab).
    local bankNote
    if creating and Bank:AutoSave() then
        self.busy = true
        local id, result, where = Bank:SaveToLoaded(index)
        self.busy = false
        if id then
            banked = id
            bankNote = " Saved to the bank: " .. placeName(Bank:Get(id)) .. "."
        elseif where then
            bankNote = " Not saved to the bank: " .. tostring(result)
        end
    end
    if banked then
        self:LoadBank(banked)
    else
        self:Load(index)
    end
    self:SetStatus((creating and "Created." or "Saved.") .. (bankNote or ""), OK_COLOR)
    return true
end

function BankUI:DeleteSelected()
    if not self.selected then
        return
    end
    Dialog:Show("QMB_DELETE_MACRO", self.identity.name, { tab = self.tab, name = self.identity.name,
        body = self.identity.body, index = self.selected })
end

-- data: the macro the popup was opened for (found again: the slots may
-- have moved while it was open).
function BankUI:DeleteConfirmed(data)
    local index = Macros.Find(data.tab, data.name, data.body, data.index)
    if not index then
        self:SetStatus("That macro no longer exists.", ERROR_COLOR)
        return
    end
    self.busy = true
    local done, deleteError = Macros:Delete(index)
    self.busy = false
    if not done then
        self:SetStatus(deleteError, ERROR_COLOR)
        return
    end
    -- The macro now in its place, or the tab's last one.
    local used = Macros.Count(data.tab)
    local first = index - (index - 1) % (MAX_ACCOUNT_MACROS or 36)
    self.tab = data.tab
    self:Load(used > 0 and math.min(index, first + used - 1) or nil)
    self:SetStatus("Deleted '" .. data.name .. "'.", OK_COLOR)
end

-- Reset in the picker gives the question mark: the icon the client
-- replaces with the macro's #showtooltip one.
--[[ The editor's icons ]]

-- A column of rail plates inside the text box, at its right: the chest
-- (the slot's macro into a bank category), the Compiler's emblem (the
-- macro as a template) and the rail's send (the saved macro to a player).
local EDITOR_ICON_INSET = 6     -- from the box's top and right edges
local EDITOR_ICON_GAP = 5       -- as the Compiler's rail

local function EditorIcon_OnEnter(button)
    local tooltip = addon.Tooltip
    tooltip:SetOwner(button, "ANCHOR_RIGHT")
    tooltip:SetText(button.title)
    tooltip:AddLine(button.text, nil, nil, nil, true)
    tooltip:Show()
end

local function EditorIcon_OnLeave(button)
    if addon.Tooltip:IsOwned(button) then
        addon.Tooltip:Hide()
    end
end

function BankUI:BuildEditorIcons(textArea)
    local box = textArea.box
    local y = -EDITOR_ICON_INSET
    local widest = 0
    local function icon(piece, title, text, onClick)
        local button = CreateFrame("Button", nil, box)
        local width, height = Theme.PieceSize(piece)
        button:SetWidth(width)
        button:SetHeight(height)
        Theme.SetRailPiece(button, piece)
        Theme.HideHoverWhileHeld(button)
        button:SetFrameLevel(box:GetFrameLevel() + 5)
        button:SetPoint("TOPRIGHT", box, "TOPRIGHT", -EDITOR_ICON_INSET, y)
        button.title, button.text = title, text
        button:SetScript("OnClick", function()
            if PlaySound then
                PlaySound("igMainMenuOption")
            end
            onClick(button)
        end)
        button:SetScript("OnEnter", EditorIcon_OnEnter)
        button:SetScript("OnLeave", EditorIcon_OnLeave)
        y = y - height - EDITOR_ICON_GAP
        widest = math.max(widest, width)
        return button
    end
    self.toBankButton = icon("rail-bank", "Bank",
        "This slot's macro into a bank category.", function(button)
            self:OpenSaveMenu(button)
        end)
    self.templateButton = icon("rail-template", "Make template",
        "This macro as a Compiler template, its text the #DEFAULT.", function()
            self:MakeTemplate()
        end)
    -- Keys bind bank macros, by their bank id.
    self.keyButton = icon("rail-key", "Key binding",
        "A key that runs this bank macro, no macro slot needed. Also in its menu in the list.", function()
            self:BindSelected()
        end)
    self.sendButton = icon("rail-send", "Send",
        "The saved macro to another player. They need Quintessence, and are asked first.", function()
            self:SendSelected()
        end)
    textArea:SetRightReserve(widest + EDITOR_ICON_INSET)
end

--[[ Key binding ]]

-- The key prompt for the editor's macro; it has to be in the bank (keys
-- run bank macros, Keys.lua).
function BankUI:BindSelected()
    local record = self.bankId and Bank:Get(self.bankId)
    if not record then
        self:SetStatus("Bank the macro first: keys run bank macros.", NOTE_COLOR)
        return
    end
    addon.KeyPrompt:Open("macro", self.bankId, record.name, self.window and self.window.frame)
end

--[[ Send ]]

-- The send dialog for the editor's macro as saved (unsaved edits: saved
-- first), to the target when it's a player, else the last recipient. It
-- lands in the receiver's bank, Unsorted in its bank section; a slot's
-- macro not in the bank goes to General's, or the class's for the
-- Character tab.
function BankUI:SendSelected()
    local record = Bank:Get(self.bankId)
    if self:IsDirty() or not (self.selected or record) then
        self:SetStatus("Save the macro first, then send it.", NOTE_COLOR)
        return
    end
    local section = record and record.section
    if not section then
        section = self.tab == "character" and select(2, UnitClass("player")) or "GENERAL"
    end
    local target = UnitIsPlayer and UnitIsPlayer("target") and not UnitIsUnit("target", "player")
        and UnitName("target") or (addon.db.settings.lastRecipient or "")
    Dialog:Show("QMB_SEND_MACRO", self.cleanName, { section = section, name = self.cleanName,
        icon = self.cleanIcon, text = self.cleanText, target = target })
end

--[[ Make Template ]]

-- A template's (button's) name from a macro's: letters, digits and
-- underscores only ("Key and HP pots" -> "Key_and_HP_pots").
local function templateName(name)
    local cleaned = (name or ""):gsub("[^%w_]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return cleaned:sub(1, 40)
end
BankUI.TemplateName = templateName

-- The editor's macro (its text as it stands, edits included) as a Compiler
-- template's #DEFAULT, in the scope of its bank section (linked) or the
-- section shown.
function BankUI:MakeTemplate()
    local name = templateName(self.nameBox:GetText())
    if name == "" then
        self:SetStatus("The macro needs a name.", ERROR_COLOR)
        return
    end
    local record = self.bankId and Bank:Get(self.bankId)
    local scope = record and record.section or self.section
    if addon.db.templates[scope] and addon.db.templates[scope][name] then
        self:SetStatus("A template named " .. name .. " already exists in " .. Bank.SectionName(scope) .. ".",
            ERROR_COLOR)
        return
    end
    -- (short: a longer wording pushed the buttons past the dialog)
    local text = "Make template '" .. name .. "' from this macro.\nSwitch: the macro then clicks it."
    local warning = self:SwitchWarning(scope)
    if warning then
        text = text .. "\n\n" .. NOTE_COLOR .. warning .. "|r"
    end
    Dialog:Show("QMB_MAKE_TEMPLATE", text, { name = name, scope = scope, text = self.textArea:GetText(),
        icon = self.pendingIcon or self.cleanIcon })
end

-- A class template's button exists only on that class: switched, the macro
-- does nothing where another class loads it. Which tab it sits in doesn't
-- matter (loadouts give each class its General tab);
-- what does is another class's loadout loading its bank category.
function BankUI:SwitchWarning(scope)
    local record = self.bankId and Bank:Get(self.bankId)
    if scope == "GENERAL" or not record then
        return nil
    end
    local users = {}
    for class, loadouts in pairs(Macros.db.loadouts or {}) do
        if class ~= scope and type(loadouts) == "table" then
            for name, loadout in pairs(loadouts) do
                for _, tab in ipairs(Macros.TABS) do
                    for _, where in ipairs(type(loadout) == "table" and loadout[tab] or {}) do
                        if where.section == record.section and where.category == record.category then
                            users[#users + 1] = Bank.SectionName(class) .. " loadout '" .. name .. "'"
                        end
                    end
                end
            end
        end
    end
    if #users == 0 then
        return nil
    end
    table.sort(users)
    return table.concat(users, ", ") .. (#users == 1 and " loads" or " load") .. " this macro's category: switched,"
        .. " it would click a button that only " .. Bank.SectionName(scope) .. " characters have."
end

function BankUI:TemplateConfirmed(data, switch)
    local made, makeError = addon:SaveTemplate(data.scope, data.name, "#DEFAULT\n" .. (data.text or ""), nil, nil,
        true, true)
    if not made then
        self:SetStatus(makeError, ERROR_COLOR)
        return
    end
    if data.icon then
        addon:SetTemplateIcon(data.scope, data.name, data.icon)
    end
    local note = "Template " .. data.name .. " made in " .. Bank.SectionName(data.scope) .. "."
    if switch then
        self.textArea:SetText("/click WMC_" .. data.name)
        if not self:Save() then
            return
        end
        note = note .. " The macro now clicks it."
    end
    self:SetStatus(note, OK_COLOR)
    -- Into the Compiler, on the new template.
    local UI = addon.UI
    if UI and UI.Toggle and not (UI.window and UI.window.frame:IsShown()) then
        UI:Toggle()
    end
    if UI and UI.Select then
        UI:Select(data.scope, data.name)
    end
end

function BankUI:PickIcon()
    addon.IconPicker:Open(self.pendingIcon or self.cleanIcon, function(icon)
        self.pendingIcon = icon or Macros.DEFAULT_ICON
        self:EditorChanged()
    end, self.window.frame)
end

--[[ Bank and slots ]]

-- The selected slot's macro into the bank: `category` of the shown section
-- (nil: Unsorted).
function BankUI:SaveToBank(category)
    if not self.selected then
        return
    end
    if self:IsDirty() then
        self:SetStatus("Save your changes first.", ERROR_COLOR)
        return
    end
    self.busy = true
    local id, result = Bank:SaveSlot(self.selected, self.section, category)
    self.busy = false
    if not id then
        self:SetStatus(result, ERROR_COLOR)
        return
    end
    self:LoadBank(id)
    local record = Bank:Get(id)
    if result == "linked" then
        self:SetStatus("Already in the bank: " .. placeName(record) .. ".", NOTE_COLOR)
    else
        self:SetStatus((result == "updated" and "Updated in the bank: " or "Saved to the bank: ")
            .. placeName(record) .. ".", OK_COLOR)
    end
end

-- The selected bank macro into the shown tab; wholeCategory (Shift): every
-- macro of its category.
function BankUI:LoadSelected(wholeCategory)
    local record = Bank:Get(self.bankId)
    if not record then
        return
    end
    if self:IsDirty() then
        self:SetStatus("Save your changes first.", ERROR_COLOR)
        return
    end
    if wholeCategory then
        local categories = Macros.db.categories[record.section]
        self:LoadCategory(record.section, record.category and categories and categories[record.category]
            and record.category or nil, self.tab)
        return
    end
    self:LoadInto(self.bankId, self.tab)
end

function BankUI:LoadInto(id, tab)
    self.busy = true
    local index, loadError = Bank:Load(id, tab)
    self.busy = false
    if not index then
        self:SetStatus(loadError, ERROR_COLOR)
        return
    end
    self:Load(index)
    self:SetStatus("Loaded into " .. tabName(tab) .. ".", OK_COLOR)
end

-- The tab then holds the category (Store.lua: FillTab).
function BankUI:LoadCategory(section, category, tab)
    self.busy = true
    local loaded, loadError, rescued, rescueSection, rescueCategory = Bank:LoadCategory(section, category, tab)
    self.busy = false
    self:FillDone(tab, loaded, loadError, rescued, rescueSection, rescueCategory)
end

-- After a tab was filled (a category, a loadout): the editor, and what
-- happened in the status line.
function BankUI:FillDone(tab, loaded, loadError, rescued, rescueSection, rescueCategory)
    if not self.window then
        return
    end
    self.tab = tab
    if self.bankId and Bank:Get(self.bankId) then
        self:LoadBank(self.bankId)
    else
        self:Load(self:FirstSlot())
    end
    local text = ""
    if loaded then
        text = "Loaded " .. loaded .. (loaded == 1 and " macro" or " macros") .. " into " .. tabName(tab) .. "."
    end
    if rescued and rescued > 0 then
        text = text .. " Saved " .. rescued .. " that " .. (rescued == 1 and "wasn't" or "weren't")
            .. " in the bank to " .. placeName({ section = rescueSection, category = rescueCategory }) .. "."
    end
    if loadError then
        self:SetStatus(text .. " " .. loadError, ERROR_COLOR)
    else
        self:SetStatus(text, OK_COLOR)
    end
end

-- A loadout was applied (Loadouts.lua), maybe by a spec swap: the
-- dropdown shows it; the editor follows the slots as on any change
-- (MacrosChanged), so the shown tab and unsaved edits stay.
function BankUI:LoadoutApplied(name, summary, failed)
    if not self.window then
        return
    end
    self.loadout = name
    self:MacrosChanged()
    self:RefreshLoadouts()
    self:SetStatus(summary, failed and ERROR_COLOR or OK_COLOR)
end

-- The loadouts or a character's choices changed.
function BankUI:LoadoutsChanged()
    self:RefreshLoadouts()
    if addon.BankSettings then
        addon.BankSettings:Refresh()
    end
end

function BankUI:SaveTabTo(category)
    self.busy = true
    local saved, saveError = Bank:SaveTab(self.tab, self.section, category)
    self.busy = false
    if not saved then
        self:SetStatus(saveError, ERROR_COLOR)
        return
    end
    self:BankChanged()
    self:SetStatus("Saved " .. saved .. (saved == 1 and " macro" or " macros") .. " to "
        .. (category or Bank.UNSORTED) .. ".", OK_COLOR)
end

function BankUI:DeleteBankConfirmed(id)
    local record = Bank:Get(id)
    if not record then
        return
    end
    local wasShown = id == self.bankId
    Bank:Delete(id)
    if wasShown and not self.selected then
        self:Load(self:FirstSlot())
    end
    self:SetStatus("Deleted '" .. record.name .. "' from the bank.", OK_COLOR)
end

--[[ Menus ]]

local function menuOptions()
    return { owner = bankWindow() }
end

-- The shown section's categories, to pick one: choose(category or nil).
function BankUI:OpenCategoryPicker(anchor, choose)
    local items = {}
    for _, name in ipairs(Bank:Categories(self.section)) do
        items[#items + 1] = { text = name, func = function() choose(name) end }
    end
    items[#items + 1] = { text = DIM_COLOR .. Bank.UNSORTED .. "|r", func = function() choose(nil) end }
    Menu:Open(items, anchor, menuOptions())
end

-- "Bank" (by Save and Revert): where to.
function BankUI:OpenSaveMenu(anchor)
    if not self.selected then
        return
    end
    self:OpenCategoryPicker(anchor, function(category)
        self:SaveToBank(category)
    end)
end

function BankUI:OpenMacroMenu(id)
    local record = Bank:Get(id)
    if not record then
        return
    end
    local items = {}
    for _, tab in ipairs(Macros.TABS) do
        items[#items + 1] = { text = "Load into " .. tabName(tab), func = function()
            self:Guard(function() self:LoadInto(id, tab) end)
        end }
    end
    items[#items + 1] = { text = "Move to...", func = function()
        self:OpenCategoryPicker(nil, function(category)
            Bank:Move(id, self.section, category)
        end)
    end }
    items[#items + 1] = { text = "Key binding...", func = function()
        addon.KeyPrompt:Open("macro", id, record.name, self.window and self.window.frame)
    end }
    items[#items + 1] = { text = "Delete from the bank", func = function()
        Dialog:Show("QMB_DELETE_BANK_MACRO", record.name, { id = id })
    end }
    Menu:Open(items, nil, menuOptions())
end

-- name: a category, or nil / false for Unsorted.
function BankUI:OpenCategoryMenu(name)
    name = name or nil
    local section = self.section
    local items = {}
    for _, tab in ipairs(Macros.TABS) do
        items[#items + 1] = { text = "Load all into " .. tabName(tab), func = function()
            self:Guard(function() self:LoadCategory(section, name, tab) end)
        end }
    end
    items[#items + 1] = { text = "Save the " .. tabName(self.tab) .. " tab's macros here", func = function()
        self:Guard(function() self:SaveTabTo(name) end)
    end }
    if name then
        items[#items + 1] = { text = "Move to section...", func = function()
            self:OpenSectionMenu(section, name)
        end }
        items[#items + 1] = { text = "Rename...", func = function()
            Dialog:Show("QMB_RENAME_CATEGORY", name, { section = section, name = name })
        end }
        items[#items + 1] = { text = "Delete", func = function()
            Dialog:Show("QMB_DELETE_CATEGORY", name, { section = section, name = name })
        end }
    else
        items[#items + 1] = { text = "Delete its macros", func = function()
            local count = #Bank:UnsortedIds(section)
            Dialog:Show("QMB_DELETE_UNSORTED", count == 1 and "the 1 unsorted macro"
                or ("the " .. count .. " unsorted macros"), { section = section })
        end }
    end
    Menu:Open(items, nil, menuOptions())
end

function BankUI:DeleteUnsortedConfirmed(section)
    self.busy = true -- one redraw, after
    local count = Bank:DeleteUnsorted(section)
    self.busy = false
    self:BankChanged()
    if self.bankId and not Bank:Get(self.bankId) then
        self.bankId = nil
    end
    if not self.selected and not self.bankId then
        self:Load(self:FirstSlot())
    end
    self:SetStatus("Deleted " .. count .. (count == 1 and " unsorted macro" or " unsorted macros")
        .. " from the bank.", OK_COLOR)
end

-- A category to another section (for the imported ones whose names don't
-- say their class).
function BankUI:OpenSectionMenu(section, name)
    local items = {}
    for _, target in ipairs(Bank.SECTIONS) do
        if target ~= section then
            items[#items + 1] = { text = sectionLabel(target), func = function()
                local moved, moveError = Bank:MoveCategory(section, name, target)
                if moved then
                    self:SetStatus("Moved '" .. name .. "' to " .. Bank.SectionName(target) .. ".", OK_COLOR)
                else
                    self:SetStatus(moveError, ERROR_COLOR)
                end
            end }
        end
    end
    Menu:Open(items, nil, menuOptions())
end

--[[ Loadouts ]]

local function placeList(places)
    local names = {}
    for _, where in ipairs(places or {}) do
        names[#names + 1] = placeName(where)
    end
    return #names > 0 and table.concat(names, ", ") or (DIM_COLOR .. "left as it is|r")
end

-- "SUBTLETY" -> "Subtlety".
-- "SUBTLETY" -> "Subtlety", "BEAST_MASTERY" -> "Beast Mastery".
local function specName(spec)
    return (spec:lower():gsub("_", " "):gsub("(%a)(%w*)", function(first, rest)
        return first:upper() .. rest
    end))
end

local USE_NAMES = { login = "on login", primary = "primary talents", secondary = "secondary talents" }
local USE_LABELS = { login = "on login", primary = "for primary talents", secondary = "for secondary talents" }

local function useName(use)
    if type(use) == "string" then
        return USE_NAMES[use]
    end
    -- ("SPEC: Subtlety", "TALENT: Shadow Dance")
    local parts = {}
    if use.tree then
        parts[#parts + 1] = "SPEC: " .. specName(use.tree)
    end
    if use.talent then
        parts[#parts + 1] = "TALENT: " .. use.talent
    end
    return table.concat(parts, ", ")
end

-- For the settings popup (Settings.lua).
BankUI.SectionLabel, BankUI.PlaceName, BankUI.SpecName, BankUI.RuleName = sectionLabel, placeName, specName, useName

-- When other loadouts fit the talents too: the one applied here last wins.
local function rivalsNote(name)
    local rivals = addon.Loadouts:Rivals(name)
    if #rivals == 0 then
        return ""
    end
    return DIM_COLOR .. "  (" .. table.concat(rivals, ", ") .. (#rivals == 1 and " fits" or " fit")
        .. " too: the one applied here last is used)|r"
end

-- This character's set for it, in the active talent group.
local function gearNote(name)
    local set = addon.Loadouts:Gear(name)
    return set and ("     " .. CAPTION_COLOR .. "Gear:|r " .. set) or ""
end

function BankUI:RefreshLoadouts()
    if not self.loadoutDropdown then
        return
    end
    local Loadouts = addon.Loadouts
    local names = Loadouts:Names()
    local current = Bank:Character().loadout
    if not (self.loadout and Loadouts:Get(self.loadout)) then
        self.loadout = current and Loadouts:Get(current) and current or names[1]
    end
    local list = {}
    for _, name in ipairs(names) do
        list[name] = name == current and (name .. "  " .. DIM_COLOR .. "(in use)|r") or name
    end
    self.loadoutDropdown:SetList(list, names)
    self.loadoutDropdown:SetValue(self.loadout)
    self.loadoutDropdown:SetDisabled(#names == 0)
    self.applyButton:SetDisabled(not self.loadout)
    local loadout = Loadouts:Get(self.loadout)
    if not loadout then
        self.loadoutDropdown:SetText(DIM_COLOR .. "No loadouts yet|r")
        self.loadoutInfo:SetText(DIM_COLOR .. "Settings: a new loadout from what the tabs were last loaded from.|r")
        return
    end
    local uses = {}
    for _, use in ipairs(Loadouts:UsesOf(self.loadout)) do
        uses[#uses + 1] = useName(use)
    end
    self.loadoutInfo:SetText(CAPTION_COLOR .. "General:|r " .. placeList(loadout.general) .. "     "
        .. CAPTION_COLOR .. "Character:|r " .. placeList(loadout.character) .. "\n"
        .. CAPTION_COLOR .. "When:|r " .. (#uses > 0 and table.concat(uses, ", ")
            or (DIM_COLOR .. "by hand only|r")) .. gearNote(self.loadout) .. rivalsNote(self.loadout))
end

function BankUI:ApplyLoadout()
    local name = self.loadout
    if not addon.Loadouts:Get(name) then
        return
    end
    self:Guard(function()
        local applied, message = addon.Loadouts:Apply(name)
        if not applied then
            self:SetStatus(message, ERROR_COLOR)
        end
    end)
end

function BankUI:NewLoadout(text)
    local places = addon.Loadouts:FromTabs()
    local name, saveError = addon.Loadouts:Save(text, places.general, places.character)
    if not name then
        self:SetStatus(saveError, ERROR_COLOR)
        return
    end
    self.loadout = name
    self:RefreshLoadouts()
    self:SetStatus("Created the loadout '" .. name .. "'.", OK_COLOR)
end

--[[ MacroBank ]]

function BankUI:ImportMacroBank()
    if not Macros.db then
        return
    end
    if type(MacroBankDB) ~= "table" then
        addon:Print("MacroBank's data isn't loaded: enable MacroBank, then /qmb import.")
        return
    end
    local macros, categories = Bank:ImportMacroBank(MacroBankDB)
    if not macros then
        addon:Print(categories)
        return
    end
    local text = "Imported " .. macros .. (macros == 1 and " macro" or " macros") .. " and " .. categories
        .. (categories == 1 and " category" or " categories") .. " from MacroBank."
    addon:Print(text)
    if self.window then
        -- Show a section that has something in it.
        if #Bank:List(self.section, "") == 0 then
            for _, section in ipairs(Bank.SECTIONS) do
                if #Bank:List(section, "") > 0 then
                    self:SetSection(section)
                    break
                end
            end
        end
        self:SetStatus(text, OK_COLOR)
    end
end

--[[ /qmb ]]

SLASH_QUINTESSENCEBANK1 = "/qmb"
SlashCmdList.QUINTESSENCEBANK = function(input)
    local command, rest = (input or ""):match("^(%S*)%s*(.-)$")
    command = string.lower(command or "")
    if command == "" then
        BankUI:Toggle()
    elseif command == "blizzard" then
        addon.Takeover:OpenBlizzard()
    elseif command == "takeover" then
        addon.Takeover:Command(string.lower(rest))
    elseif command == "import" then
        BankUI:ImportMacroBank()
    elseif command == "load" then
        BankUI:LoadoutCommand(rest)
    elseif command == "keys" then
        addon.Keys:Command(rest)
    elseif command == "bars" then
        if Macros.db then
            for _, line in ipairs(addon.Loadouts:BarsReport()) do
                addon:Print(line)
            end
        end
    else
        addon:Print("Commands: /qmb (the Macro Bank), /qmb blizzard (Blizzard's macro window),"
            .. " /qmb takeover on | off (whether /macro opens the Macro Bank),"
            .. " /qmb import (copy MacroBank's macros into the bank),"
            .. " /qmb load <loadout> (apply a loadout; no name: list them),"
            .. " /qmb bars (what the bank sees on the action bars),"
            .. " /qmb keys (key bindings: /qmb keys help).")
    end
end

-- /qmb load <name> (any case); no name: the loadouts.
function BankUI:LoadoutCommand(name)
    if not Macros.db then
        return
    end
    local Loadouts = addon.Loadouts
    name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        local names = Loadouts:Names()
        local current = Bank:Character().loadout
        for index, loadout in ipairs(names) do
            if loadout == current then
                names[index] = loadout .. " (current)"
            end
        end
        addon:Print(#names > 0 and ("Loadouts: " .. table.concat(names, ", ") .. ".")
            or "No loadouts yet: make one in the Macro Bank (/qmb).")
        return
    end
    for _, loadout in ipairs(Loadouts:Names()) do
        if loadout:lower() == name:lower() then
            local _, summary = Loadouts:Apply(loadout)
            addon:Print(summary)
            return
        end
    end
    addon:Print("No loadout named '" .. name .. "'. /qmb load lists them.")
end
