local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme
local Macros = addon.Macros
local Bank = addon.Bank
local Loadouts = addon.Loadouts
local BankUI = addon.BankUI

--[[-----------------------------------------------------------------------------
BankSettings (addon.BankSettings): the Macro Bank's settings, a popup over
its window, in the dialogs' look (popup style A, as the mute dialog).
It holds what would crowd the bank's window:

  [Loadout] [Bank]      (two tabs; the one shown lit)

  Loadout: the bank window's Settings button opens it here.
    [PvE (in use)     v]  [New] [Rename] [Delete]
    General tab                  Rogue / Rogue PvE - General      [Remove]
                                 [Add a category...]
    Character tab                ...
    Use it
    [ ] On login        [ ] Primary talents    [ ] Secondary talents
    Gear set                     Subtlety: PvP Sub                [Remove]
                                 [A spec's set...]
    By talents                   While Combat                     [Remove]
                                 [While <tree>] [A talent...]
                                                                  [Close]

  Bank: the gear by the bank's section opens it here.
  Macro window
    [x] /macro and the game menu's Macros open the Macro Bank
  Saving
    [ ] Save new macros to the bank       (opt-in: Bank:AutoSave)
  Action bars
    [x] Put the bars back when a loadout is applied   (Loadouts:BarsOn)
    [x] Start a new character's bars from a classmate's (:SeedOn)
  Loadouts
    [ ] Give each class its own General tab  (opt-in: a class without
        loadouts gets one named after it; Loadouts:EnsureClassLoadout)
  Key bindings
    [Key bindings...]                     (the key list, KeyList.lua)
    [Import from BindPad]                 (when its data is loaded)
  MacroBank
    [Import from MacroBank]               (when its data is loaded)
                                                                  [Close]

The loadout shown is the bank window's (BankUI.loadout): choosing one here
chooses it there too. Its height follows the rows.

  BankSettings:Open(page ("loadout" | "bank"; nil: the last one)),
  :ShowPage(page), :Close(), :Cancel(), :IsShown(), :Refresh()
  Fields: frame, page, pageTabs, loadoutDropdown, takeoverBox, optionBoxes,
  importButton, useBoxes, rows (the pooled category / rule rows:
  { text, button }), buttons.

Escape and a click outside close it, as the mute dialog. A dialog opened
from it (new, rename, delete, a talent's name) goes above it: its owner is
this popup while it is shown (BankSettings:Owner()).
-------------------------------------------------------------------------------]]
local BankSettings = { rows = {}, buttons = {} }
addon.BankSettings = BankSettings

local RIM = 5
local PAD = 18
local WIDTH = 460
local TAB_HALF = math.floor(Theme.SECTION_TAB_HEIGHT / 2)
local ROW_H = 26
local CAPTION_H = 20
local GAP = 8
local LABEL_W = 110         -- "General tab", "By talents"...
local BUTTON_H = 24
local SMALL_BUTTON_W = 70
local X_SIZE = 18            -- the remove X (the pin list's)
local X_GAP = 6
local CLOSE_W = 88
local CONTENT_W = WIDTH - 2 * PAD

local CAPTION_COLOR = "|cff99ccff"
local DIM_COLOR = "|cff808080"

local USES = { { "login", "On login" }, { "primary", "Primary talents" }, { "secondary", "Secondary talents" } }
local PAGES = { { "loadout", "Loadout" }, { "bank", "Bank" } }
local IDLE_TAB_ALPHA = 0.55     -- the tab not shown (as the bank window's)
local TAB_GAP = 4
local TOP_OFFSET = 90           -- its top under the bank window's

-- The Bank tab's switches: under their caption; on unless switched off,
-- except where `optIn`.
local OPTIONS = {
    { caption = "Saving", key = "autoBank", optIn = true, label = "Save new macros to the bank",
        note = "Into the category their tab was loaded from." },
    { caption = "Action bars", key = "restoreBars", label = "Put the bars back when a loadout is applied" },
    { key = "seedBars", label = "Start a new character's bars from a classmate's" },
    { caption = "Loadouts", key = "classGeneral", optIn = true, label = "Give each class its own General tab",
        note = "A class with no loadouts gets one, named after it.",
        ticked = function() Loadouts:ClassGeneralTicked() end },
}

--[[ Building ]]

local function makeButton(parent, text, width, onClick)
    local button = AceGUI:Create("WMC-Button")
    button.frame:SetParent(parent)
    button:SetText(text)
    button:SetWidth(width)
    button:SetHeight(BUTTON_H)
    button:SetCallback("OnClick", onClick)
    button.frame:Show()
    return button
end

local function put(widget, frame, x, y)
    widget.frame:ClearAllPoints()
    widget.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
    widget.frame:Show()
end

local function Frame_OnKeyDown(frame, key)
    if key == "ESCAPE" then
        if frame.SetPropagateKeyboardInput then
            frame:SetPropagateKeyboardInput(false)
        end
        BankSettings:Cancel()
    end
end

function BankSettings:Build()
    if self.frame then
        return
    end
    local frame = CreateFrame("Frame", "QMBSettings", UIParent)
    frame:Hide()
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetWidth(WIDTH)
    if frame.EnableKeyboard then
        frame:EnableKeyboard(true)
    end
    frame:SetScript("OnKeyDown", Frame_OnKeyDown)
    frame.wmcPopup = true -- its dropdown's and buttons' menus go above it
    self.frame = frame

    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:Hide()
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetAllPoints(UIParent)
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", function() BankSettings:Cancel() end)
    self.catcher = catcher

    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -TAB_HALF)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    self.body = body
    Theme.CreateShadow(body)
    Theme.CreatePanel(body, "BACKGROUND")
    self.background = Theme.CreateBackground(body, "BORDER", 0)

    self.pageTabs = {}
    local previous
    for _, page in ipairs(PAGES) do
        local tab = Theme.CreateSectionTab(frame)
        if previous then
            tab:SetPoint("LEFT", previous, "RIGHT", TAB_GAP, 0)
        else
            tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        end
        tab:SetText(page[2])
        tab:EnableMouse(true)
        tab:SetScript("OnMouseUp", function()
            self:ShowPage(page[1])
        end)
        self.pageTabs[page[1]] = tab
        previous = tab
    end

    local texts = CreateFrame("Frame", nil, frame)
    texts:SetAllPoints(frame)
    self.texts = texts
    self.captions = {}

    local takeover = AceGUI:Create("WMC-CheckBox")
    takeover.frame:SetParent(frame)
    takeover:SetLabel("/macro and the game menu's Macros open the Macro Bank")
    takeover:SetWidth(CONTENT_W)
    takeover:SetCallback("OnValueChanged", function(_, _, checked)
        Macros.db.settings.takeover = checked and true or false
    end)
    self.takeoverBox = takeover

    self.optionBoxes = {}
    for _, option in ipairs(OPTIONS) do
        local box = AceGUI:Create("WMC-CheckBox")
        box.frame:SetParent(frame)
        box:SetLabel(option.label)
        box:SetWidth(CONTENT_W)
        box:SetCallback("OnValueChanged", function(_, _, checked)
            Macros.db.settings[option.key] = checked and true or false
            BankUI:SetStatus("")
            if checked and option.ticked then
                option.ticked()
                self:Refresh()
            end
        end)
        self.optionBoxes[option.key] = box
    end
    self.keysButton = makeButton(frame, "Key bindings...", 180, function()
        self:Close()
        addon.KeyList:Open(BankUI.window and BankUI.window.frame)
    end)
    self.bindPadButton = makeButton(frame, "Import from BindPad", 180, function()
        addon.BindPad:Run()
        self:Refresh()
    end)
    self.importButton = makeButton(frame, "Import from MacroBank", 180, function()
        BankUI:ImportMacroBank()
        self:Refresh()
    end)

    local dropdown = AceGUI:Create("WMC-Dropdown")
    dropdown.frame:SetParent(frame)
    dropdown:SetLabel("")
    dropdown:SetWidth(CONTENT_W - 3 * (SMALL_BUTTON_W + 4))
    dropdown:SetCallback("OnValueChanged", function(_, _, value)
        BankUI.loadout = value
        BankUI:RefreshLoadouts()
        self:Refresh()
    end)
    self.loadoutDropdown = dropdown
    self.newButton = makeButton(frame, "New", SMALL_BUTTON_W, function()
        addon.Dialog:Show("QMB_NEW_LOADOUT")
    end)
    self.renameButton = makeButton(frame, "Rename", SMALL_BUTTON_W, function()
        addon.Dialog:Show("QMB_RENAME_LOADOUT", BankUI.loadout, { name = BankUI.loadout })
    end)
    self.deleteButton = makeButton(frame, "Delete", SMALL_BUTTON_W, function()
        addon.Dialog:Show("QMB_DELETE_LOADOUT", BankUI.loadout, { name = BankUI.loadout })
    end)
    self.deleteButton:SetStyle("red")

    self.useBoxes = {}
    for _, use in ipairs(USES) do
        local box = AceGUI:Create("WMC-CheckBox")
        box.frame:SetParent(frame)
        box:SetLabel(use[2])
        box:SetWidth(math.floor(CONTENT_W / 3))
        box:SetCallback("OnValueChanged", function(_, _, checked)
            Loadouts:SetUse(use[1], checked and BankUI.loadout or nil)
        end)
        self.useBoxes[use[1]] = box
    end

    self.closeButton = makeButton(frame, CLOSE or "Close", CLOSE_W, function() self:Cancel() end)
end

-- Pooled pieces, handed out in order by each Refresh.
local function caption(self, text, x, y)
    self.captionCount = self.captionCount + 1
    local line = self.captions[self.captionCount]
    if not line then
        line = self.texts:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        line:SetJustifyH("LEFT")
        self.captions[self.captionCount] = line
    end
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x, -(y + 5))
    line:SetWidth(WIDTH - PAD - x)
    line:SetHeight(14) -- one line: a longer one is cut, never past the rim
    line:SetText(text)
    line:Show()
    return line
end

-- A line of text with a button at its right end (button nil: no button).
local function Remove_OnEnter(frame)
    if frame.tip then
        GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
        GameTooltip:SetText(frame.tip, 1, 1, 1)
        GameTooltip:Show()
    end
end

local function Remove_OnLeave()
    GameTooltip:Hide()
end

-- A line of text; with onClick, the X that removes it goes in front, its
-- tooltip `tip` (pooled).
local function row(self, text, y, tip, onClick)
    self.rowCount = self.rowCount + 1
    local entry = self.rows[self.rowCount]
    if not entry then
        local line = self.texts:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetJustifyH("LEFT")
        line:SetWidth(CONTENT_W - LABEL_W - X_SIZE - X_GAP)
        local remove = makeButton(self.frame, "x", X_SIZE, nil)
        remove:SetStyle("pinx")
        remove.frame:HookScript("OnEnter", Remove_OnEnter)
        remove.frame:HookScript("OnLeave", Remove_OnLeave)
        entry = { text = line, button = remove }
        self.rows[self.rowCount] = entry
    end
    -- (centred on the X's middle, not hung from the row's top)
    entry.text:ClearAllPoints()
    entry.text:SetPoint("LEFT", self.frame, "TOPLEFT", PAD + LABEL_W + X_SIZE + X_GAP, -(y + 1 + X_SIZE / 2))
    entry.text:SetText(text)
    entry.text:Show()
    if onClick then
        entry.button.frame.tip = tip
        entry.button:SetCallback("OnClick", onClick)
        put(entry.button, self.frame, PAD + LABEL_W, y + 1)
    else
        entry.button.frame:Hide()
    end
    return entry
end

-- A button of the given width at x (pooled).
local function button(self, text, width, x, y, onClick)
    self.buttonCount = self.buttonCount + 1
    local widget = self.buttons[self.buttonCount]
    if not widget then
        widget = makeButton(self.frame, "", width, nil)
        self.buttons[self.buttonCount] = widget
    end
    widget:SetText(text)
    widget:SetWidth(width)
    widget:SetCallback("OnClick", onClick)
    put(widget, self.frame, x, y)
    return widget
end

--[[ Showing ]]

function BankSettings:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

-- The dialogs opened from here go above it.
function BankSettings:Owner()
    return self:IsShown() and self.frame or nil
end

-- A category for `tab` of the loadout: a section first, then its category.
function BankSettings:AddCategory(tab, anchor)
    local name = BankUI.loadout
    local items = {}
    for _, section in ipairs(Bank.SECTIONS) do
        items[#items + 1] = { text = BankUI.SectionLabel(section), func = function()
            local categories = {}
            for _, category in ipairs(Bank:Categories(section)) do
                categories[#categories + 1] = { text = category, func = function()
                    self:PlaceAdded(Loadouts:AddPlace(name, tab, { section = section, category = category }))
                end }
            end
            categories[#categories + 1] = { text = DIM_COLOR .. Bank.UNSORTED .. "|r", func = function()
                self:PlaceAdded(Loadouts:AddPlace(name, tab, { section = section }))
            end }
            addon.Menu:Open(categories, anchor, { owner = self.frame })
        end }
    end
    addon.Menu:Open(items, anchor, { owner = self.frame })
end

local function classSpecs()
    local State = addon.State
    local _, class = UnitClass("player")
    return State and State.CLASS_SPECS[class] or {}
end

-- A menu of the class's three specs, the current one marked.
function BankSettings:SpecMenu(anchor, onPick)
    local current = addon.State and addon.State.values.PLAYER_SPEC
    local items = {}
    for _, spec in ipairs(classSpecs()) do
        items[#items + 1] = { text = BankUI.SpecName(spec) .. (spec == current and DIM_COLOR .. "  (now)|r" or ""),
            func = function() onPick(spec) end }
    end
    addon.Menu:Open(items, anchor, { owner = self.frame })
end

-- A spec rule for the loadout: any of the class's three, not only the
-- current one (a hybrid's loadout set up without respeccing first).
function BankSettings:AddSpec(anchor)
    local name = BankUI.loadout
    self:SpecMenu(anchor, function(spec)
        Loadouts:AddRule({ tree = spec, loadout = name })
    end)
end

function BankSettings:PlaceAdded(added, addError)
    if not added then
        BankUI:SetStatus(addError, "|cffff4040")
        self.note = addError
        self:Refresh()
    end
end

function BankSettings:Refresh()
    if not self:IsShown() then
        return
    end
    self.captionCount, self.rowCount, self.buttonCount = 0, 0, 0
    BankUI:RefreshLoadouts() -- (it settles which loadout is shown)
    local name = BankUI.loadout
    local loadout = Loadouts:Get(name)
    local y = Theme.SECTION_TAB_HEIGHT + 10
    for page, tab in pairs(self.pageTabs) do
        tab:SetAlpha(page == self.page and 1 or IDLE_TAB_ALPHA)
    end
    local loadoutWidgets = { self.loadoutDropdown, self.newButton, self.renameButton, self.deleteButton }
    for _, box in pairs(self.useBoxes) do
        loadoutWidgets[#loadoutWidgets + 1] = box
    end
    local bankWidgets = { self.takeoverBox, self.importButton, self.keysButton, self.bindPadButton }
    for _, box in pairs(self.optionBoxes) do
        bankWidgets[#bankWidgets + 1] = box
    end
    for _, widget in ipairs(self.page == "bank" and loadoutWidgets or bankWidgets) do
        widget.frame:Hide()
    end
    if self.ruleNote then
        self.ruleNote:Hide()
    end
    if self.page == "bank" then
        y = self:RefreshBank(y)
    else
        y = self:RefreshLoadout(y, name, loadout)
    end
    self:Finish(y)
end

function BankSettings:RefreshBank(y)
    local frame = self.frame
    caption(self, CAPTION_COLOR .. "Macro window|r", PAD, y)
    y = y + CAPTION_H
    self.takeoverBox:SetValue(addon.Takeover:Enabled())
    put(self.takeoverBox, frame, PAD, y)
    y = y + ROW_H + GAP
    local settings = Macros.db.settings
    for index, option in ipairs(OPTIONS) do
        if option.caption then
            caption(self, CAPTION_COLOR .. option.caption .. "|r", PAD, y)
            y = y + CAPTION_H
        end
        local box = self.optionBoxes[option.key]
        if option.optIn then
            box:SetValue(settings[option.key] == true)
        else
            box:SetValue(settings[option.key] ~= false)
        end
        put(box, frame, PAD, y)
        y = y + ROW_H
        if option.note then
            caption(self, DIM_COLOR .. option.note .. "|r", PAD, y - 4)
            y = y + CAPTION_H - 4
        end
        local nextOption = OPTIONS[index + 1]
        if not nextOption or nextOption.caption then
            y = y + GAP
        end
    end
    caption(self, CAPTION_COLOR .. "Key bindings|r", PAD, y)
    y = y + CAPTION_H
    put(self.keysButton, frame, PAD, y)
    y = y + ROW_H + GAP
    -- BindPad's keys, while its data is loaded (BindPad enabled).
    if addon.BindPad:Available() then
        put(self.bindPadButton, frame, PAD, y)
        y = y + ROW_H + GAP
    else
        self.bindPadButton.frame:Hide()
    end
    caption(self, CAPTION_COLOR .. "MacroBank|r", PAD, y)
    y = y + CAPTION_H
    if type(MacroBankDB) == "table" then
        put(self.importButton, frame, PAD, y)
        y = y + ROW_H + GAP
    else
        self.importButton.frame:Hide()
        caption(self, DIM_COLOR .. "Its data isn't loaded: enable MacroBank to import.|r", PAD, y - 4)
        y = y + CAPTION_H + GAP
    end
    return y
end

function BankSettings:RefreshLoadout(y, name, loadout)
    local frame = self.frame
    local names = Loadouts:Names()
    local current = Bank:Character().loadout
    local list = {}
    for _, loadoutName in ipairs(names) do
        list[loadoutName] = loadoutName == current and (loadoutName .. "  " .. DIM_COLOR .. "(in use)|r")
            or loadoutName
    end
    local dropdown = self.loadoutDropdown
    dropdown:SetList(list, names)
    dropdown:SetValue(name)
    dropdown:SetDisabled(#names == 0)
    if not loadout then
        dropdown:SetText(DIM_COLOR .. "No loadouts yet|r")
    end
    put(dropdown, frame, PAD, y)
    local x = WIDTH - PAD - 3 * SMALL_BUTTON_W - 2 * 4
    put(self.newButton, frame, x, y)
    put(self.renameButton, frame, x + SMALL_BUTTON_W + 4, y)
    put(self.deleteButton, frame, x + 2 * (SMALL_BUTTON_W + 4), y)
    self.renameButton:SetDisabled(not loadout)
    self.deleteButton:SetDisabled(not loadout)
    y = y + ROW_H + GAP

    if loadout then
        for _, tab in ipairs(Macros.TABS) do
            caption(self, Macros.TAB_NAMES[tab] .. " tab", PAD, y)
            local places = loadout[tab] or {}
            if #places == 0 then
                row(self, DIM_COLOR .. "Left as it is|r", y)
                y = y + ROW_H
            end
            for index, where in ipairs(places) do
                row(self, BankUI.PlaceName(where), y, "Remove from this loadout", function()
                    Loadouts:RemovePlace(name, tab, index)
                end)
                y = y + ROW_H
            end
            local add = button(self, "Add a category...", 140, PAD + LABEL_W, y, nil)
            add:SetCallback("OnClick", function(widget) self:AddCategory(tab, widget.frame) end)
            y = y + ROW_H + GAP
        end

        -- (a row of their own: the labels need the width)
        caption(self, "Use it", PAD, y)
        y = y + CAPTION_H
        local character = Bank:Character()
        local boxX = PAD
        for _, use in ipairs(USES) do
            local box = self.useBoxes[use[1]]
            box:SetValue(character[use[1]] == name)
            put(box, frame, boxX, y)
            boxX = boxX + math.floor(CONTENT_W / 3)
        end
        y = y + ROW_H + GAP
        y = self:RefreshGear(y, name)

        caption(self, "By talents", PAD, y)
        local any = false
        for index, rule in ipairs(Loadouts:Rules()) do
            if rule.loadout == name then
                any = true
                row(self, BankUI.RuleName(rule), y, "Remove this rule", function()
                    Loadouts:RemoveRule(index)
                end)
                y = y + ROW_H
            end
        end
        if not any then
            row(self, DIM_COLOR .. "Not chosen by talents|r", y)
            y = y + ROW_H
        end
        local treeX = PAD + LABEL_W
        local specButton = button(self, "A spec...", 110, treeX, y, nil)
        specButton:SetCallback("OnClick", function(widget) self:AddSpec(widget.frame) end)
        treeX = treeX + 110 + 4
        button(self, "A talent...", 110, treeX, y, function()
            addon.Dialog:Show("QMB_LOADOUT_TALENT", name, { name = name })
        end)
        y = y + ROW_H + GAP
        self.ruleNote = self.ruleNote or self.texts:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        local note = self.ruleNote
        note:ClearAllPoints()
        note:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -y)
        note:SetWidth(CONTENT_W)
        note:SetJustifyH("LEFT")
        note:SetText(DIM_COLOR .. "The talents decide, at login too: the first rule that matches, then the"
            .. " talent group; the login loadout when nothing else does. The talent rules count for every "
            .. (UnitClass and UnitClass("player") or "character") .. "; Use it is this character's.|r")
        note:Show()
        y = y + 3 * 14 + GAP
    else
        for _, box in pairs(self.useBoxes) do
            box.frame:Hide()
        end
        if self.ruleNote then
            self.ruleNote:Hide()
        end
        row(self, DIM_COLOR .. "New: a loadout of the categories the tabs were last loaded from.|r", y)
        y = y + ROW_H + GAP
    end
    return y
end

-- This character's equipment sets for the loadout, per spec: the first one put on with the loadout in use is learned;
-- set (a spec, then its set) or cleared here.

function BankSettings:RefreshGear(y, name)
    caption(self, "Gear set", PAD, y)
    local any = false
    for _, spec in ipairs(classSpecs()) do
        local set = Loadouts:Gear(name, spec)
        if set then
            any = true
            row(self, BankUI.SpecName(spec) .. ": " .. set, y, "Don't change gear in this spec", function()
                Loadouts:SetGear(name, spec, nil)
            end)
            y = y + ROW_H
        end
    end
    if not any then
        row(self, DIM_COLOR .. "None: the gear is left as it is|r", y)
        y = y + ROW_H
    end
    local sets = Loadouts:GearSets()
    if #sets == 0 then
        row(self, DIM_COLOR .. "No equipment sets: make them in the character window.|r", y)
        return y + ROW_H + GAP
    end
    local pick = button(self, "A spec's set...", 140, PAD + LABEL_W, y, nil)
    pick:SetCallback("OnClick", function(widget) self:PickGear(name, sets, widget.frame) end)
    y = y + ROW_H
    caption(self, DIM_COLOR .. "Or put a set on with this loadout in use: a spec with none keeps it.|r", PAD, y - 4)
    return y + CAPTION_H - 4 + GAP
end

-- A spec, then the set for it.
function BankSettings:PickGear(name, sets, anchor)
    self:SpecMenu(anchor, function(spec)
        local choices = {}
        for _, set in ipairs(sets) do
            choices[#choices + 1] = { text = set, func = function()
                Loadouts:SetGear(name, spec, set)
            end }
        end
        addon.Menu:Open(choices, anchor, { owner = self.frame })
    end)
end

-- Close at the bottom; what wasn't handed out hides; the height follows.
function BankSettings:Finish(y)
    local frame = self.frame
    put(self.closeButton, frame, WIDTH - PAD - CLOSE_W, y)
    y = y + BUTTON_H + 16

    -- What wasn't handed out this time hides.
    for index = self.captionCount + 1, #self.captions do
        self.captions[index]:Hide()
    end
    for index = self.rowCount + 1, #self.rows do
        self.rows[index].text:Hide()
        self.rows[index].button.frame:Hide()
    end
    for index = self.buttonCount + 1, #self.buttons do
        self.buttons[index].frame:Hide()
    end
    frame:SetHeight(y)
    self.background:Layout(RIM, RIM, WIDTH - 2 * RIM, y - TAB_HALF - 2 * RIM)
    self:SetLevels()
end

-- Child levels don't follow a later change of the parent's: set each.
function BankSettings:SetLevels()
    local level = self.frame:GetFrameLevel()
    local childLevel = level + 3
    self.body:SetFrameLevel(level + 1)
    for _, tab in pairs(self.pageTabs) do
        tab:SetFrameLevel(childLevel)
    end
    self.texts:SetFrameLevel(childLevel)
    local widgets = { self.takeoverBox, self.loadoutDropdown, self.newButton, self.renameButton, self.deleteButton,
        self.closeButton }
    for _, box in pairs(self.useBoxes) do
        widgets[#widgets + 1] = box
    end
    for _, box in pairs(self.optionBoxes) do
        widgets[#widgets + 1] = box
    end
    widgets[#widgets + 1] = self.importButton
    widgets[#widgets + 1] = self.keysButton
    for _, entry in ipairs(self.rows) do
        widgets[#widgets + 1] = entry.button
    end
    for _, widget in ipairs(self.buttons) do
        widgets[#widgets + 1] = widget
    end
    for _, widget in ipairs(widgets) do
        -- Created on UIParent by AceGUI: set the strata, don't inherit it.
        widget.frame:SetFrameStrata(self.frame:GetFrameStrata())
        widget.frame:SetFrameLevel(childLevel)
    end
end

function BankSettings:ShowPage(page)
    self.page = page
    addon.Menu:Close()
    self.loadoutDropdown:Close()
    self:Refresh()
end

function BankSettings:Open(page)
    if not Macros.db then
        return
    end
    self.page = page or self.page or "loadout"
    self:Build()
    local Dialog = addon.Dialog
    Dialog:Cancel()
    addon.MuteDialog:Cancel()
    addon.IconPicker:Cancel()
    addon.Menu:Close()
    Dialog.ReleaseKeyboard()
    local owner = BankUI.window and BankUI.window.frame
    local level = Dialog.OwnerLevel(owner)
    if owner then
        if not self.veil or self.veil:GetParent() ~= owner then
            self.veil = Dialog.CreateVeil(owner)
        end
        self.veil:SetFrameLevel(level + Dialog.LEVEL_VEIL)
        self.veil:Show()
    end
    local frame = self.frame
    Theme.ScalePopup(frame)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(level + Dialog.LEVEL_DIALOG)
    self.catcher:SetFrameLevel(level + Dialog.LEVEL_DIALOG - 1)
    self.catcher:Show()
    frame:ClearAllPoints()
    -- Hung from its top: switching tabs changes the height at the bottom
    -- only.
    if owner and owner:IsShown() then
        frame:SetPoint("TOP", owner, "TOP", 0, -TOP_OFFSET)
    else
        frame:SetPoint("TOP", UIParent, "CENTER", 0, 280)
    end
    frame:Show()
    self:Refresh()
    if PlaySound then
        PlaySound("igMainMenuOpen")
    end
end

function BankSettings:Close()
    if self.frame then
        self.frame:Hide()
    end
    if self.veil then
        self.veil:Hide()
    end
    if self.catcher then
        self.catcher:Hide()
    end
    if self.loadoutDropdown then
        self.loadoutDropdown:Close()
    end
end

function BankSettings:Cancel()
    if not self:IsShown() then
        return
    end
    self:Close()
    if PlaySound then
        PlaySound("igMainMenuClose")
    end
end
