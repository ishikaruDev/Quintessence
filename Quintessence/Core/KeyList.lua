local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme
local Keys = addon.Keys

--[[-----------------------------------------------------------------------------
KeyList (addon.KeyList): every key that can apply on this character, in a
popup (keybinds-plan.md, "The list"), in the dialogs' look (popup style A):

  [KEY BINDINGS]
  TEMPLATES  o==========================================o
  .------.  [ Preparation                       >   x
  | a-F  |    Rogue  ·  over Strangulate
  '------'
  MACROS  o=============================================o
  .------.  [ Fan                               >   x
  | s-M4 |    Subtlety
  '------'
  On one key the most specific wins: your spec's, then
  your class's, then everyone's.                 [Close]

Its own art (keylist-row, -hover and keylist-cap). A row: the
key on a raised brass keycap, in dark letters, its modifiers in full
("Ctrl-T", "Shift-M4"; the caps as wide as the widest key); the name on a
plain bevelled strip (its rim lit on hover); the X at the end; under the
strip, the level and what the key is doing here, with the whole width for
it ("over Bottom Action Bar Button 5"). The full key name and the rest
again in the row's tooltip. Section headings on the guide's riveted
divider. The popup is as tall as its rows, up to MAX_LIST_H, then scrolls
(the themed bar, the wheel). It opens centred on its window (or the
screen) and can be dragged; back from the prompt, it stays where it was.

The rows are Keys:Entries(): every character's keys, the class's and the
class's specs' (another spec's marked "not this spec"); a key not running
here is dim; a disabled template or a gone item in red. The X removes that
one key at that level (Keys:ClearAt). A click on a row opens the key
prompt for its item at its level; the list comes back when it closes.
Adding is done from the items themselves (a template's right-click or the
source box's keycap, a bank macro's menu or the editor's keycap).

  KeyList:Open(owner), :Close(), :Cancel(), :IsShown(), :Reload()
  .rows: the item frames shown, top to bottom (each .item: { heading } or
  { entry }).
-------------------------------------------------------------------------------]]
local KeyList = {}
addon.KeyList = KeyList

local RIM = 5
local PAD = 18
local WIDTH = 420
local TAB_HALF = math.floor(Theme.SECTION_TAB_HEIGHT / 2)
local BAR_GAP = 6
local BAR = Theme.SCROLLBAR_WIDTH

local PLATE_H = select(2, Theme.PieceSize("keylist-row"))   -- 26
local CAP_MIN_W = 58            -- the key's cap: as wide as the widest key
local CAP_MAX_W = 124
local CAP_PAD = 16
local CAP_H = 24
local CAP_GAP = 6
local X_SIZE = 18
local X_GAP = 6
local CAPTION_H = 14
local ROW_H = PLATE_H + CAPTION_H + 4
local HEADING_H = 24
local MAX_LIST_H = 7 * ROW_H + 2 * HEADING_H
local EMPTY_H = 44

local LIST_TOP = Theme.SECTION_TAB_HEIGHT + 12
local GAP = 10
local NOTE_H = 26               -- two lines of GameFontHighlightSmall
local BUTTON_WIDTH = 88
local BUTTON_HEIGHT = 24

local LEVEL_COLOR = "|cffd8b878"
local DIM = "|cff8a8a8a"
local PROBLEM = "|cffff6060"
local SEPARATOR = DIM .. "  ·  |r"
local HEADINGS = { template = "Templates", macro = "Macros" }

KeyList.ROW_H, KeyList.HEADING_H, KeyList.MAX_LIST_H = ROW_H, HEADING_H, MAX_LIST_H

local function itemHeight(item)
    return item.heading and HEADING_H or ROW_H
end

--[[ Rows ]]

local function Row_OnClick(row)
    if row.item and row.item.entry then
        KeyList:Change(row.item.entry)
    end
end

local function Row_OnEnter(row)
    local entry = row.item and row.item.entry
    if not entry then
        return
    end
    row.plate:SetPiece("keylist-row-hover")
    row.name:SetTextColor(unpack(Theme.colors.gold))
    local tooltip = addon.Tooltip
    tooltip:SetOwner(row, "ANCHOR_RIGHT")
    tooltip:SetText(entry.name)
    tooltip:AddLine(Keys.KeyText(entry.key) .. ", " .. Keys.LevelName(entry.level)
        .. (entry.level == "ALL" and " (every character)" or ""), 1, 1, 1, true)
    if entry.note then
        tooltip:AddLine(entry.note, nil, nil, nil, true)
    end
    tooltip:AddLine("Click to change it.", nil, nil, nil, true)
    tooltip:Show()
end

local function Row_OnLeave(row)
    if row.item and row.item.entry then
        row.plate:SetPiece("keylist-row")
        KeyList:PaintRow(row)
    end
    if addon.Tooltip:IsOwned(row) then
        addon.Tooltip:Hide()
    end
end

function KeyList:CreateEntryRow()
    local row = CreateFrame("Button", nil, self.frame)
    row:SetHeight(ROW_H)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", Row_OnClick)
    row:SetScript("OnEnter", Row_OnEnter)
    row:SetScript("OnLeave", Row_OnLeave)

    -- The key, on a raised keycap.
    local cap = CreateFrame("Frame", nil, row)
    cap:SetWidth(CAP_MIN_W)
    cap:SetHeight(CAP_H)
    cap:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -math.floor((PLATE_H - CAP_H) / 2))
    Theme.CreateSlice(cap, "BACKGROUND"):SetPiece("keylist-cap")
    row.cap = cap
    local key = cap:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    -- on the cap's face, above its thicker lower bevel; dark, as engraved
    key:SetPoint("LEFT", cap, "LEFT", 4, 1)
    key:SetPoint("RIGHT", cap, "RIGHT", -4, 1)
    key:SetJustifyH("CENTER")
    key:SetShadowColor(1, 0.92, 0.7, 0.35)
    key:SetShadowOffset(0, -1)
    row.key = key

    -- The name, on the strip.
    local plateFrame = CreateFrame("Frame", nil, row)
    plateFrame:SetHeight(PLATE_H)
    plateFrame:SetPoint("TOPLEFT", row, "TOPLEFT", CAP_MIN_W + CAP_GAP, 0)
    plateFrame:SetPoint("TOPRIGHT", row, "TOPRIGHT", -(X_SIZE + X_GAP), 0)
    row.plate = Theme.CreateSlice(plateFrame, "BACKGROUND")
    row.plate:SetPiece("keylist-row")
    row.plateFrame = plateFrame
    local name = plateFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", plateFrame, "LEFT", 14, 0)
    name:SetPoint("RIGHT", plateFrame, "RIGHT", -14, 0)
    name:SetHeight(12)
    name:SetJustifyH("LEFT")
    if name.SetWordWrap then
        name:SetWordWrap(false)
    end
    row.name = name

    -- Its level and what it's doing here, under the plate.
    local caption = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    caption:SetPoint("TOPLEFT", plateFrame, "BOTTOMLEFT", 14, -2)
    caption:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    caption:SetHeight(CAPTION_H - 2)
    caption:SetJustifyH("LEFT")
    if caption.SetWordWrap then
        caption:SetWordWrap(false)
    end
    row.caption = caption

    local remove = AceGUI:Create("WMC-Button")
    remove.frame:SetParent(row)
    remove:SetStyle("pinx")
    remove:SetText("x")
    remove:SetWidth(X_SIZE)
    remove:SetHeight(X_SIZE)
    remove.frame:ClearAllPoints()
    remove.frame:SetPoint("RIGHT", plateFrame, "RIGHT", X_SIZE + X_GAP, 0)
    remove:SetCallback("OnClick", function()
        if row.item and row.item.entry then
            self:Remove(row.item.entry)
        end
    end)
    row.remove = remove
    return row
end

function KeyList:CreateHeadingRow()
    local row = CreateFrame("Frame", nil, self.frame)
    row:SetHeight(HEADING_H)
    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", row, "LEFT", 0, 0)
    text:SetTextColor(unpack(Theme.colors.title))
    row.heading = text
    local divider = CreateFrame("Frame", nil, row)
    divider:SetHeight(select(2, Theme.PieceSize("guide-divider")))
    divider:SetPoint("LEFT", text, "RIGHT", 8, 0)
    divider:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    Theme.CreateSlice(divider, "ARTWORK"):SetPiece("guide-divider")
    row.divider = divider
    return row
end

--[[ Frame ]]

local function Frame_OnKeyDown(frame, key)
    if key == "ESCAPE" then
        KeyList:Cancel()
    end
end

local function Frame_OnMouseWheel(frame, delta)
    KeyList:Scroll(-delta)
end

function KeyList:Build()
    if self.frame then
        return
    end
    local frame = CreateFrame("Frame", "QuintessenceKeyList", UIParent)
    frame:Hide()
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetWidth(WIDTH)
    if frame.EnableKeyboard then
        frame:EnableKeyboard(true)
    end
    frame:SetScript("OnKeyDown", Frame_OnKeyDown)
    if frame.EnableMouseWheel then
        frame:EnableMouseWheel(true)
    end
    frame:SetScript("OnMouseWheel", Frame_OnMouseWheel)
    -- Dragged by its panel or tab (the rows take their own clicks).
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    self.frame = frame

    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:Hide()
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetAllPoints(UIParent)
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", function() KeyList:Cancel() end)
    self.catcher = catcher

    -- Popup style A: the panel starts at the tab's middle.
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -TAB_HALF)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    self.body = body
    Theme.CreateShadow(body)
    Theme.CreatePanel(body, "BACKGROUND")
    self.background = Theme.CreateBackground(body, "BORDER", 0)

    local tab = Theme.CreateSectionTab(frame)
    tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    tab:SetText("Key Bindings")
    self.tab = tab

    local texts = CreateFrame("Frame", nil, frame)
    texts:SetAllPoints(frame)
    self.texts = texts

    self.entryPool, self.headingPool, self.rows = {}, {}, {}

    local empty = texts:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    empty:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(LIST_TOP + 4))
    empty:SetWidth(WIDTH - 2 * PAD)
    empty:SetJustifyH("LEFT")
    empty:SetTextColor(unpack(Theme.colors.dim))
    empty:SetText("No keys yet. Right-click a template in the list, or use the keycap in a template's"
        .. " source box or a bank macro's editor.")
    empty:Hide()
    self.emptyText = empty

    local note = texts:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetWidth(WIDTH - 2 * PAD - BUTTON_WIDTH - 12)
    note:SetJustifyH("LEFT")
    note:SetJustifyV("TOP")
    note:SetTextColor(unpack(Theme.colors.dim))
    note:SetText("On one key the most specific wins: your spec's, then your class's, then everyone's.")
    self.noteText = note

    local measure = texts:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    measure:Hide()
    self.measure = measure

    -- Themed scrollbar, one item per step (as the mute dialog's).
    local bar = CreateFrame("Slider", "QuintessenceKeyListScrollBar", frame, "UIPanelScrollBarTemplate")
    bar:SetScript("OnValueChanged", nil)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    bar:Hide()
    local upButton, downButton = Theme.ScrollBarButtons(bar)
    Theme.SkinScrollBar(bar, upButton, downButton)
    if upButton then
        upButton:SetScript("OnClick", function() KeyList:Scroll(-1) end)
    end
    if downButton then
        downButton:SetScript("OnClick", function() KeyList:Scroll(1) end)
    end
    bar:SetScript("OnValueChanged", function(_, value) KeyList:SetOffset(value) end)
    self.scrollbar, self.upButton, self.downButton = bar, upButton, downButton

    local close = AceGUI:Create("WMC-Button")
    close.frame:SetParent(frame)
    close:SetText(CLOSE or "Close")
    close:SetWidth(BUTTON_WIDTH)
    close:SetHeight(BUTTON_HEIGHT)
    close:SetCallback("OnClick", function() KeyList:Cancel() end)
    self.closeButton = close
end

--[[ State ]]

function KeyList:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

-- The list's items: a heading per kind, then its keys.
local function buildList()
    local list, kind = {}, nil
    for _, entry in ipairs(Keys:Entries()) do
        if entry.kind ~= kind then
            kind = entry.kind
            list[#list + 1] = { heading = HEADINGS[kind] }
        end
        list[#list + 1] = { entry = entry }
    end
    return list
end

local function totalHeight(list)
    local height = 0
    for _, item in ipairs(list) do
        height = height + itemHeight(item)
    end
    return height
end

-- The last offset that still fills the list's height.
local function maxOffset(self)
    local list = self.list
    local height, offset = 0, #list
    while offset > 0 and height + itemHeight(list[offset]) <= MAX_LIST_H do
        height = height + itemHeight(list[offset])
        offset = offset - 1
    end
    return offset
end

function KeyList:PaintRow(row)
    local entry = row.item and row.item.entry
    if not entry then
        return
    end
    if entry.inEffect then
        row.key:SetTextColor(0.16, 0.09, 0.03)
    else
        row.key:SetTextColor(0.42, 0.31, 0.16)
    end
    if entry.problem then
        row.name:SetTextColor(1, 0.38, 0.38)
    elseif entry.inEffect then
        row.name:SetTextColor(1, 1, 1)
    else
        row.name:SetTextColor(0.6, 0.6, 0.6)
    end
end

local function caption(entry)
    local text = LEVEL_COLOR .. Keys.LevelName(entry.level) .. "|r"
    if entry.note then
        text = text .. SEPARATOR .. (entry.problem and PROBLEM or DIM) .. entry.note .. "|r"
    end
    return text
end

-- Places the items from the offset down, as many as fit.
function KeyList:Refresh()
    for _, row in ipairs(self.rows) do
        row:Hide()
    end
    self.rows = {}
    local right = PAD + (maxOffset(self) > 0 and (BAR + BAR_GAP) or 0)
    local used = { entry = 0, heading = 0 }
    local y = 0
    for index = self.offset + 1, #self.list do
        local item = self.list[index]
        local height = itemHeight(item)
        if y + height > MAX_LIST_H then
            break
        end
        local kind = item.heading and "heading" or "entry"
        used[kind] = used[kind] + 1
        local pool = item.heading and self.headingPool or self.entryPool
        local row = pool[used[kind]]
        if not row then
            row = item.heading and self:CreateHeadingRow() or self:CreateEntryRow()
            pool[used[kind]] = row
            self:SetRowLevel(row)
        end
        row.item = item
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PAD, -(LIST_TOP + y))
        row:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -right, -(LIST_TOP + y))
        if item.heading then
            row.heading:SetText(item.heading:upper())
        else
            local entry = item.entry
            row.key:SetText(Keys.ListText(entry.key))
            row.cap:SetWidth(self.capW)
            row.plateFrame:SetPoint("TOPLEFT", row, "TOPLEFT", self.capW + CAP_GAP, 0)
            row.name:SetText(entry.name)
            row.caption:SetText(caption(entry))
            row.plate:SetPiece("keylist-row")
            self:PaintRow(row)
        end
        row:Show()
        self.rows[#self.rows + 1] = row
        y = y + height
    end
    if self.upButton then
        if self.offset > 0 then self.upButton:Enable() else self.upButton:Disable() end
    end
    if self.downButton then
        if self.offset < maxOffset(self) then self.downButton:Enable() else self.downButton:Disable() end
    end
end

-- The popup's height: its rows (up to MAX_LIST_H), the note and Close.
function KeyList:Layout()
    local frame = self.frame
    local listH
    if #self.list == 0 then
        self.emptyText:Show()
        listH = EMPTY_H
    else
        self.emptyText:Hide()
        listH = math.min(totalHeight(self.list), MAX_LIST_H)
    end
    local top = LIST_TOP + listH + GAP
    self.noteText:ClearAllPoints()
    self.noteText:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -top)
    local close = self.closeButton.frame
    close:ClearAllPoints()
    close:SetPoint("TOPLEFT", frame, "TOPLEFT", WIDTH - PAD - BUTTON_WIDTH, -(top + NOTE_H - BUTTON_HEIGHT))
    local height = top + NOTE_H + 16
    frame:SetHeight(height)
    self.background:Layout(RIM, RIM, WIDTH - 2 * RIM, height - TAB_HALF - 2 * RIM)
    local bar = self.scrollbar
    bar:ClearAllPoints()
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -(LIST_TOP + BAR))
    bar:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -PAD, -(LIST_TOP + listH - BAR))
end

function KeyList:UpdateBar()
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

-- The caps' width: the widest key's, for every row (the names line up).
local function capWidth(self, list)
    local widest = 0
    local measure = self.measure
    for _, item in ipairs(list) do
        if item.entry then
            measure:SetText(Keys.ListText(item.entry.key))
            widest = math.max(widest, measure.GetStringWidth and measure:GetStringWidth() or 0)
        end
    end
    return math.max(CAP_MIN_W, math.min(CAP_MAX_W, math.ceil(widest) + CAP_PAD))
end

-- Reads the keys again, keeping the scroll position.
function KeyList:Reload()
    self.list = buildList()
    self.capW = capWidth(self, self.list)
    self.offset = math.min(self.offset or 0, maxOffset(self))
    self:Layout()
    self:UpdateBar()
    self:Refresh()
end

function KeyList:SetOffset(value)
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

function KeyList:Scroll(delta)
    self:SetOffset(self.offset + (delta or 0))
end

function KeyList:Remove(entry)
    if PlaySound then
        PlaySound("igMainMenuOptionCheckBoxOff")
    end
    addon.Tooltip:Hide()
    Keys:ClearAt(entry.level, entry.key)
    self:Reload()
end

-- The key prompt for a row's item, at its level; the list comes back after.
function KeyList:Change(entry)
    local owner, offset = self.owner, self.offset
    self:Close()
    addon.KeyPrompt:Open(entry.kind, entry.id, entry.name, owner, {
        level = entry.level,
        onClose = function()
            self:Open(owner, true)
            self:SetOffset(offset)
        end,
    })
end

-- Child levels don't follow a later change of the parent's: set each.
function KeyList:SetRowLevel(row)
    local level = self.childLevel or (self.frame:GetFrameLevel() + 3)
    row:SetFrameLevel(level)
    for _, child in ipairs({ row.cap or false, row.plateFrame or false, row.divider or false }) do
        if child then
            child:SetFrameLevel(level)
        end
    end
    if row.remove then
        row.remove.frame:SetFrameStrata(self.frame:GetFrameStrata())
        row.remove.frame:SetFrameLevel(level + 1)
    end
end

local function setLevels(self, level)
    self.body:SetFrameLevel(level + 1)
    self.childLevel = level + 3
    self.tab:SetFrameLevel(self.childLevel)
    self.texts:SetFrameLevel(self.childLevel)
    for _, pool in ipairs({ self.entryPool, self.headingPool }) do
        for _, row in ipairs(pool) do
            self:SetRowLevel(row)
        end
    end
    self.scrollbar:SetFrameLevel(self.childLevel)
    for _, button in ipairs({ self.upButton, self.downButton }) do
        if button then
            button:SetFrameLevel(self.childLevel + 1)
        end
    end
    self.closeButton.frame:SetFrameStrata(self.frame:GetFrameStrata())
    self.closeButton.frame:SetFrameLevel(self.childLevel)
end

-- owner: the window it goes over (nil: the Compiler's). Centred on it, or
-- on the screen; keepPlace (back from the prompt): where it was left.
function KeyList:Open(owner, keepPlace)
    self:Build()
    local Dialog = addon.Dialog
    Dialog:Cancel()
    addon.MuteDialog:Cancel()
    addon.IconPicker:Cancel()
    addon.KeyPrompt:Cancel()
    addon.Menu:Close()
    Dialog.ReleaseKeyboard()
    addon.Tooltip:Hide()

    owner = owner or Dialog.mainOwner
    self.owner = owner
    local ownerLevel = Dialog.OwnerLevel(owner)
    if owner then
        if not self.veil or self.veil:GetParent() ~= owner then
            self.veil = Dialog.CreateVeil(owner)
        end
        self.veil:SetFrameLevel(ownerLevel + Dialog.LEVEL_VEIL)
        self.veil:Show()
    end
    local frame = self.frame
    Theme.ScalePopup(frame)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(ownerLevel + Dialog.LEVEL_DIALOG)
    self.catcher:SetFrameLevel(ownerLevel + Dialog.LEVEL_DIALOG - 1)
    self.catcher:Show()
    setLevels(self, ownerLevel + Dialog.LEVEL_DIALOG)
    if not keepPlace then
        frame:ClearAllPoints()
        if owner and owner.IsShown and owner:IsShown() then
            frame:SetPoint("CENTER", owner, "CENTER", 0, 0)
        else
            frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
    end
    self.closeButton.frame:Show()
    frame:Show()
    self.offset = 0
    self:Reload()
    if PlaySound then
        PlaySound("igMainMenuOpen")
    end
end

function KeyList:Close()
    if self.frame then
        self.frame:Hide()
        self.closeButton.frame:Hide()
    end
    if self.veil then
        self.veil:Hide()
    end
    if self.catcher then
        self.catcher:Hide()
    end
end

function KeyList:Cancel()
    if not self:IsShown() then
        return
    end
    self:Close()
    if PlaySound then
        PlaySound("igMainMenuClose")
    end
end
