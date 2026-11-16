local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme
local Keys = addon.Keys

--[[-----------------------------------------------------------------------------
KeyPrompt (addon.KeyPrompt): binding a key to a template or a bank macro,
opened by a right-click on a template's row, or the bank macro menu's "Key
binding..." (keybinds-plan.md, "The prompt"). A popup in the
dialogs' look (popup style A, as the mute dialog), over the window the row
is in:

  [Key binding]
  sample_template_2
  Press a key or a mouse button. Escape closes.
  Now: Alt-F (Rogue)
  [ ] Rogue only                 (a General template's only)
  [ ] Subtlety only
  Alt-F set. It overrides your binding: Action Button 3.
  [Clear]                                                    [Close]

A key pressed while it is open is bound at once at the level the boxes say
(Keys:Set), replacing the template's key at that level; what the key had
before is said under the boxes. Middle, 4th and 5th mouse buttons and the
wheel count as keys (a click on the popup itself); left and right clicks
are for its boxes and buttons. Clear removes the key at that level.
Escape, Close or a click outside closes it.

  KeyPrompt:Open(kind, id, name, owner), :Close(), :Cancel(), :IsShown()
  KeyPrompt:Press(key)   a key as the client names it, without modifiers
                         (the held ones are added)
-------------------------------------------------------------------------------]]
local KeyPrompt = {}
addon.KeyPrompt = KeyPrompt

local RIM = 5
local PAD = 18
local WIDTH = 340
local TAB_HALF = math.floor(Theme.SECTION_TAB_HEIGHT / 2)
local BUTTON_W = 88
local BUTTON_H = 24
local BOX_H = 24

local NAME_TOP = Theme.SECTION_TAB_HEIGHT + 12
local HINT_TOP = NAME_TOP + 24
local NOW_TOP = HINT_TOP + 20
local BOXES_TOP = NOW_TOP + 24
local GAP = 10
local STATUS_LINE = 13      -- GameFontHighlightSmall's line, for a status not yet measured
-- The height follows the content:
-- one or two boxes, the status only when there is one; it grows downward
-- from its top, which stays put.

local ERROR_COLOR = "|cffff6060"
local WHITE = "|cffffffff"

-- Keys that only modify another.
local MODIFIER_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
    UNKNOWN = true }
local MOUSE_KEYS = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }

local function held()
    return ((IsAltKeyDown and IsAltKeyDown()) and "ALT-" or "")
        .. ((IsControlKeyDown and IsControlKeyDown()) and "CTRL-" or "")
        .. ((IsShiftKeyDown and IsShiftKeyDown()) and "SHIFT-" or "")
end

local function Frame_OnKeyDown(frame, key)
    if key == "ESCAPE" then
        KeyPrompt:Cancel()
    elseif not MODIFIER_KEYS[key] then
        KeyPrompt:Press(key)
    end
end

local function Frame_OnMouseDown(frame, button)
    if MOUSE_KEYS[button] then
        KeyPrompt:Press(MOUSE_KEYS[button])
    end
end

local function Frame_OnMouseWheel(frame, delta)
    KeyPrompt:Press(delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN")
end

local function makeButton(parent, text, onClick)
    local button = AceGUI:Create("WMC-Button")
    button.frame:SetParent(parent)
    button:SetText(text)
    button:SetWidth(BUTTON_W)
    button:SetHeight(BUTTON_H)
    button:SetCallback("OnClick", onClick)
    return button
end

local function makeBox(parent, onChange)
    local box = AceGUI:Create("WMC-CheckBox")
    box.frame:SetParent(parent)
    box:SetWidth(WIDTH - 2 * PAD)
    box:SetCallback("OnValueChanged", function(_, _, checked)
        onChange(checked)
    end)
    return box
end

local function line(parent, font, top)
    local text = parent:CreateFontString(nil, "OVERLAY", font)
    text:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -top)
    text:SetWidth(WIDTH - 2 * PAD)
    text:SetJustifyH("LEFT")
    return text
end

function KeyPrompt:Build()
    if self.frame then
        return
    end
    local frame = CreateFrame("Frame", "QuintessenceKeyPrompt", UIParent)
    frame:Hide()
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetWidth(WIDTH)
    if frame.EnableKeyboard then
        frame:EnableKeyboard(true)
    end
    frame:SetScript("OnKeyDown", Frame_OnKeyDown)
    frame:SetScript("OnMouseDown", Frame_OnMouseDown)
    if frame.EnableMouseWheel then
        frame:EnableMouseWheel(true)
    end
    frame:SetScript("OnMouseWheel", Frame_OnMouseWheel)
    self.frame = frame

    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:Hide()
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetAllPoints(UIParent)
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", function() KeyPrompt:Cancel() end)
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
    tab:SetText("Key binding")
    self.tab = tab

    -- Texts on a frame of their own, raised with the other children.
    local texts = CreateFrame("Frame", nil, frame)
    texts:SetAllPoints(frame)
    self.texts = texts
    self.nameText = line(texts, "GameFontNormalLarge", NAME_TOP)
    self.nameText:SetTextColor(unpack(Theme.colors.gold))
    self.hintText = line(texts, "GameFontHighlightSmall", HINT_TOP)
    self.hintText:SetTextColor(unpack(Theme.colors.dim))
    self.hintText:SetText("Press a key or a mouse button. Escape closes.")
    self.nowText = line(texts, "GameFontHighlight", NOW_TOP)
    self.statusText = line(texts, "GameFontHighlightSmall", BOXES_TOP)
    self.statusText:SetJustifyV("TOP")

    self.classBox = makeBox(frame, function(checked)
        if not checked then
            self.specBox:SetValue(false)
        end
        self:SetStatus("")
        self:Refresh()
    end)
    self.specBox = makeBox(frame, function(checked)
        if checked and self.classBox.frame:IsShown() then
            self.classBox:SetValue(true)
        end
        self:SetStatus("")
        self:Refresh()
    end)

    self.clearButton = makeButton(frame, "Clear", function() self:ClearKey() end)
    self.closeButton = makeButton(frame, CLOSE or "Close", function() self:Cancel() end)
end

-- Places the status (when there is one) and the buttons under the boxes,
-- and sizes the popup to them.
function KeyPrompt:Layout()
    local frame = self.frame
    local y = (self.boxesBottom or BOXES_TOP) + GAP
    local status = self.statusText
    if (status:GetText() or "") ~= "" then
        status:ClearAllPoints()
        status:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -y)
        status:Show()
        local height = status:GetStringHeight()
        if type(height) ~= "number" or height <= 0 then
            height = STATUS_LINE * math.ceil(#status:GetText() / 52)
        end
        y = y + math.ceil(height) + GAP
    else
        status:Hide()
    end
    for _, button in ipairs({ { self.clearButton, PAD }, { self.closeButton, WIDTH - PAD - BUTTON_W } }) do
        button[1].frame:ClearAllPoints()
        button[1].frame:SetPoint("TOPLEFT", frame, "TOPLEFT", button[2], -y)
    end
    local height = y + BUTTON_H + 16
    frame:SetHeight(height)
    self.background:Layout(RIM, RIM, WIDTH - 2 * RIM, height - TAB_HALF - 2 * RIM)
end

function KeyPrompt:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

-- The level the boxes say: "SPEC", "CLASS" or "ALL".
function KeyPrompt:Scope()
    if self.specBox:GetValue() then
        return "SPEC"
    end
    if self.home or self.classBox:GetValue() then
        return "CLASS"
    end
    return "ALL"
end

function KeyPrompt:SetStatus(text)
    self.statusText:SetText(text or "")
    if self:IsShown() then
        self:Layout()
    end
end

function KeyPrompt:Refresh()
    local kind, id = self.kind, self.id
    self.nameText:SetText(self.name)
    local class = select(2, UnitClass("player"))
    local spec = addon.State and addon.State.values.PLAYER_SPEC
    local y = BOXES_TOP
    if self.home then
        self.classBox.frame:Hide()
    else
        self.classBox:SetLabel(addon.Bank.SectionName(class) .. " only")
        self.classBox.frame:ClearAllPoints()
        self.classBox.frame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PAD, -y)
        self.classBox.frame:Show()
        y = y + BOX_H
    end
    self.specBox:SetLabel(spec and (addon.BankUI.SpecName(spec) .. " only") or "Your spec only (no talents yet)")
    self.specBox:SetDisabled(spec == nil or self.blocked)
    self.classBox:SetDisabled(self.blocked)
    self.specBox.frame:ClearAllPoints()
    self.specBox.frame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PAD, -y)
    self.specBox.frame:Show()
    self.boxesBottom = y + BOX_H
    self:Layout()

    local key = not self.blocked and Keys:KeyAt(kind, id, self:Scope())
    if self.blocked then
        self.nowText:SetText("")
    elseif key then
        local text = "Now: " .. WHITE .. Keys.KeyText(key) .. "|r"
        local holder, level = Keys:HolderOf(key)
        if holder ~= self.name then
            text = text .. "  |cff888888(here " .. (holder and (Keys.LevelName(level) .. "'s " .. holder) or "nothing")
                .. " has it)|r"
        end
        self.nowText:SetText(text)
    else
        self.nowText:SetText("|cff888888No key at this level.|r")
    end
    self.clearButton:SetDisabled(not key)
end

function KeyPrompt:Press(key)
    if not self:IsShown() or self.blocked then
        return
    end
    local full = Keys.Normalize(held() .. key)
    local done, taken = Keys:Set(self.kind, self.id, full, self:Scope())
    if not done then
        self:SetStatus(ERROR_COLOR .. tostring(taken) .. "|r")
        return
    end
    local text = Keys.KeyText(full) .. " set."
    if taken then
        text = text .. " It was " .. taken .. "'s."
    end
    local blizzard = Keys.BlizzardAction(full)
    if blizzard then
        text = text .. " It overrides your binding: " .. blizzard .. "."
    end
    if addon:IsInCombat() then
        text = text .. " It takes effect when combat ends."
    end
    self:SetStatus(text)
    self:Refresh()
end

function KeyPrompt:ClearKey()
    if Keys:Clear(self.kind, self.id, self:Scope()) > 0 then
        self:SetStatus("Removed.")
    end
    self:Refresh()
end

-- Child levels don't follow a later change of the parent's: set each.
local function setLevels(self, level)
    self.body:SetFrameLevel(level + 1)
    local childLevel = level + 3
    self.tab:SetFrameLevel(childLevel)
    self.texts:SetFrameLevel(childLevel)
    for _, widget in ipairs({ self.classBox, self.specBox, self.clearButton, self.closeButton }) do
        -- Created on UIParent by AceGUI: set the strata, don't inherit it.
        widget.frame:SetFrameStrata(self.frame:GetFrameStrata())
        widget.frame:SetFrameLevel(childLevel)
    end
end

-- kind "template" | "macro", id its template id | bank id, name what the
-- popup calls it, owner the window it goes over (nil: the Compiler's).
-- options.level: the level whose key it shows first (the key list's row;
-- default: the level of its key here); options.onClose: called once when
-- it closes (the key list comes back).
function KeyPrompt:Open(kind, id, name, owner, options)
    options = options or {}
    self:Build()
    local Dialog = addon.Dialog
    Dialog:Cancel()
    addon.MuteDialog:Cancel()
    addon.IconPicker:Cancel()
    addon.Menu:Close()
    Dialog.ReleaseKeyboard()
    addon.Tooltip:Hide()

    self.kind, self.id, self.name = kind, id, name
    local canBind, why = Keys:CanBind(kind, id)
    self.blocked = not canBind
    self.home = Keys:HomeOf(kind, id)
    -- The boxes start at the level of its key here, if it has one.
    local level = options.level
    if not level or (level:find(":") and level ~= Keys.SpecLevel()) then
        level = select(2, Keys:KeyFor(kind, id))
    end
    self.onClose = options.onClose
    self.specBox:SetValue(level ~= nil and level:find(":") ~= nil)
    self.classBox:SetValue(level ~= nil and level ~= "ALL")
    self:SetStatus(canBind and "" or (ERROR_COLOR .. tostring(why) .. "|r"))

    owner = owner or Dialog.mainOwner
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
    frame:ClearAllPoints()
    if owner and owner.IsShown and owner:IsShown() then
        frame:SetPoint("TOP", owner, "CENTER", 0, 110)
    else
        frame:SetPoint("TOP", UIParent, "CENTER", 0, 150)
    end
    self.clearButton.frame:Show()
    self.closeButton.frame:Show()
    frame:Show()
    self:Refresh()
    if PlaySound then
        PlaySound("igMainMenuOpen")
    end
end

function KeyPrompt:Close()
    if self.frame then
        self.frame:Hide()
        self.classBox.frame:Hide()
        self.specBox.frame:Hide()
        self.clearButton.frame:Hide()
        self.closeButton.frame:Hide()
    end
    if self.veil then
        self.veil:Hide()
    end
    if self.catcher then
        self.catcher:Hide()
    end
    local onClose = self.onClose
    self.onClose = nil
    if onClose then
        onClose()
    end
end

function KeyPrompt:Cancel()
    if not self:IsShown() then
        return
    end
    self:Close()
    if PlaySound then
        PlaySound("igMainMenuClose")
    end
end
