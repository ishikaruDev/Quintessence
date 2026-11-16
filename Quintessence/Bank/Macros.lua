local addon = WMacroCompiler

--[[-----------------------------------------------------------------------------
Macros (addon.Macros): the game's macro slots, as the Macro Bank sees them
(bank-plan.md). No frames of its own except the long macros' secure buttons.

Slots: 36 General (index 1-36, account-wide) and 18 Character (37-54). The
client keeps each tab sorted, so a create, a rename or a delete moves the
others: an index is only good until the next change, and every function
that changes a macro returns where it is now.

  Macros.TABS                 { "general", "character" }
  Macros.Count(tab)           -> used, max
  Macros.Get(index)           -> { index, tab, name, icon, body, text, long }
                              or nil. body: what the slot holds; text: what
                              it runs (the long macro's text, else the body);
                              long: the long macro's id, else nil.
  Macros.List(tab)            -> { Get(first), ... }
  Macros.Find(tab, name, body [, hint]) -> the index of that macro, or nil
  Macros:Check(name, text)    -> true, or nil and what is wrong with them
  Macros:Create(tab, name, icon, text) -> index, or nil and the error
  Macros:Edit(index, name, icon, text) -> its new index, or nil and the
                              error. icon nil: the icon stays as it is.
  Macros:Delete(index)        -> true, or nil and the error
  Macros.IconIndex(texture)   -> the icon's index for CreateMacro / EditMacro
  Macros.SlotBody(id, text)   -> a long macro's slot body
  Macros.LongId(body)         -> the long macro a slot body runs, or nil

icon is a texture path, as GetMacroInfo and the icon picker give it.
Nothing can be changed in combat (the client refuses): Create, Edit and
Delete return an error then.

  Macros.Write(index, name, icon, body) -> its new index: the slot as given,
                              nothing checked (the bank's linked slots)
  Macros.ApplyButton(id)      (re)writes QMB<id> from its text

Long macros. A slot holds at most 255 characters. A longer text is kept in
QuintessenceBankDB.long[id] (or, for a macro of the bank, in its record:
Store.lua; the two share one run of ids) and run by a hidden secure button, QMB<id>
(Secure.lua's chain buttons, so there is no upper limit, only that of a
single line); the slot holds "/click QMB<id>". The id is the bank's own
and never reused, so nothing has to be renumbered when the slots move. The
text's first line, when it is "#showtooltip <something>" (or #show), is
repeated in the slot, so the slot still shows that icon and tooltip.
-------------------------------------------------------------------------------]]
local Macros = { buttons = {} }
addon.Macros = Macros

local NAME_MAX = 16
local BODY_MAX = 255
local DB_VERSION = 1
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local COMBAT_ERROR = "Macros can't be changed in combat."

Macros.NAME_MAX, Macros.BODY_MAX = NAME_MAX, BODY_MAX
Macros.DEFAULT_ICON = DEFAULT_ICON
Macros.TABS = { "general", "character" }
Macros.TAB_NAMES = { general = "General", character = "Character" }

local function accountMax()
    return MAX_ACCOUNT_MACROS or 36
end

local function characterMax()
    return MAX_CHARACTER_MACROS or 18
end

-- The saved table (its own version, apart from WMacroCompilerDB's).
function Macros:DefaultDatabase()
    QuintessenceBankDB = QuintessenceBankDB or {}
    local db = QuintessenceBankDB
    db.version = db.version or DB_VERSION
    db.long = db.long or {}
    db.nextId = db.nextId or 1
    -- the bank's own (Store.lua)
    db.macros = db.macros or {}
    db.categories = db.categories or {}
    db.settings = db.settings or {}
    db.loadedFrom = db.loadedFrom or {}
    db.characters = db.characters or {}
    db.loadouts = db.loadouts or {}
    db.rules = db.rules or {}
    self.db = db
    return db
end

function Macros:Initialize()
    self:DefaultDatabase()
    self.buttons = {}
    self:ApplyLong()
end

--[[ Slots ]]

function Macros.Count(tab)
    local account, character = GetNumMacros()
    if tab == "character" then
        return character or 0, characterMax()
    end
    return account or 0, accountMax()
end

function Macros.TabOf(index)
    return index > accountMax() and "character" or "general"
end

local function firstIndex(tab)
    return tab == "character" and accountMax() + 1 or 1
end

-- "#showtooltip Kick\n/click QMB12" or "/click QMB12" -> 12.
function Macros.LongId(body)
    body = body or ""
    local id = body:match("^/click QMB(%d+)%s*$") or body:match("^#show[^\n]*\n/click QMB(%d+)%s*$")
    return tonumber(id)
end

function Macros.Get(index)
    local name, icon, body = GetMacroInfo(index)
    if not name then
        return nil
    end
    body = body or ""
    local macro = { index = index, tab = Macros.TabOf(index), name = name, icon = icon, body = body, text = body }
    local id = Macros.LongId(body)
    local text = id and Macros.db and Macros.LongText(id)
    if text then
        macro.long, macro.text = id, text
    end
    return macro
end

function Macros.List(tab)
    local list = {}
    local first = firstIndex(tab)
    for offset = 0, Macros.Count(tab) - 1 do
        list[#list + 1] = Macros.Get(first + offset)
    end
    return list
end

-- Where the macro with that name and slot body is now: `hint` when it is
-- still there, else the first match in the tab.
function Macros.Find(tab, name, body, hint)
    local function matches(index)
        local macroName, _, macroBody = GetMacroInfo(index)
        return macroName == name and (macroBody or "") == body
    end
    if hint and Macros.TabOf(hint) == tab and matches(hint) then
        return hint
    end
    local first = firstIndex(tab)
    for offset = 0, Macros.Count(tab) - 1 do
        if matches(first + offset) then
            return first + offset
        end
    end
    return nil
end

--[[ Icons ]]

-- texture -> index, read once per session (a few thousand icons).
local iconIndexes

function Macros.IconIndex(texture)
    if not texture or not (GetNumMacroIcons and GetMacroIconInfo) then
        return 1
    end
    if not iconIndexes then
        iconIndexes = {}
        for index = 1, GetNumMacroIcons() do
            local path = GetMacroIconInfo(index)
            if path and not iconIndexes[path:lower()] then
                iconIndexes[path:lower()] = index
            end
        end
    end
    return iconIndexes[texture:lower()] or 1 -- the question mark
end

--[[ Long macros ]]

-- The pseudo-template Secure.lua builds a long macro's buttons from.
local function buttonFor(id)
    local button = Macros.buttons[id]
    if not button then
        button = { id = "BANK:" .. id, name = "INTERNAL_QMB" .. id, primaryName = "QMB" .. id }
        Macros.buttons[id] = button
    end
    return button
end

function Macros.SlotBody(id, text)
    local click = "/click QMB" .. id
    local show = (text or ""):match("^(#show%a*[ \t]+[^%s][^\n]*)\n")
    if show and #show + 1 + #click <= BODY_MAX then
        return show .. "\n" .. click
    end
    return click
end

-- The text QMB<id> runs: a bank macro's (the bank owns that id), else a
-- stored long macro's; nil when the id is unknown.
function Macros.LongText(id)
    local record = Macros.db.macros[id]
    if record then
        return record.text
    end
    local stored = Macros.db.long[id]
    return stored and stored.text or nil
end

-- Writes one long macro's buttons. In combat it waits (CombatEnded).
local function applyLong(id)
    local text = Macros.LongText(id)
    if not text then
        return
    end
    local done, applyError = addon.Secure.Apply(buttonFor(id), text)
    if not done and addon:IsInCombat() then
        Macros.pending = true
    end
    return done, applyError
end
Macros.ApplyButton = applyLong

function Macros.RemoveButton(id)
    addon.Secure.Remove(Macros.buttons[id])
    Macros.buttons[id] = nil
end

-- Every long macro's buttons (login, and after combat when some had to
-- wait): the stored ones, and the bank macros that have (or ever had) one
-- (record.button: a slot of another character may still click it) or a
-- key (Keys.lua made it: in Macros.buttons).
function Macros:ApplyLong()
    self.pending = false
    for id in pairs(self.db.long) do
        applyLong(id)
    end
    for id, record in pairs(self.db.macros) do
        if record.button or self.buttons[id] then
            applyLong(id)
        end
    end
end

function Macros:CombatEnded()
    if self.pending and self.db then
        self:ApplyLong()
    end
end

local function storeLong(id, text)
    if Macros.db.macros[id] then
        return -- the bank's: Store.lua writes its record and its button
    end
    Macros.db.long[id] = { text = text }
    return applyLong(id)
end

-- Forgets a long macro, unless a slot in sight still runs it (or it is the
-- bank's).
local function dropLong(id)
    if Macros.db.macros[id] then
        return
    end
    for _, tab in ipairs(Macros.TABS) do
        for _, macro in ipairs(Macros.List(tab)) do
            if macro.long == id then
                return
            end
        end
    end
    Macros.db.long[id] = nil
    Macros.RemoveButton(id)
end

--[[ Changes ]]

function Macros:Check(name, text)
    if type(name) ~= "string" or name == "" then
        return nil, "The macro needs a name."
    end
    -- (characters, not bytes: the client counts a UTF-8 letter once)
    if #name:gsub("[\128-\191]", "") > NAME_MAX then
        return nil, "A macro name is at most " .. NAME_MAX .. " characters."
    end
    if #(text or "") > BODY_MAX then
        local buttons, measureError = addon.Secure.Measure("INTERNAL_QMB0000", text)
        if not buttons then
            return nil, measureError
        end
    end
    return true
end

-- What the slot gets for `text`, and the long macro's id when it needs one
-- (`id`: the one the slot already has).
local function slotFor(text, id)
    if #text <= BODY_MAX then
        return text, nil
    end
    id = id or Macros.NewId()
    return Macros.SlotBody(id, text), id
end

function Macros:Create(tab, name, icon, text)
    text = text or ""
    local valid, checkError = self:Check(name, text)
    if not valid then
        return nil, checkError
    end
    if addon:IsInCombat() then
        return nil, COMBAT_ERROR
    end
    local used, max = Macros.Count(tab)
    if used >= max then
        return nil, "No free " .. Macros.TAB_NAMES[tab]:lower() .. " macro slots."
    end
    local body, id = slotFor(text)
    local index = CreateMacro(name, Macros.IconIndex(icon), body, tab == "character" and 1 or nil)
    if not index then
        return nil, "Could not create the macro."
    end
    if id then
        storeLong(id, text)
    end
    return Macros.Find(tab, name, body, index) or index
end

function Macros:Edit(index, name, icon, text)
    text = text or ""
    local current = Macros.Get(index)
    if not current then
        return nil, "That macro no longer exists."
    end
    local valid, checkError = self:Check(name, text)
    if not valid then
        return nil, checkError
    end
    if addon:IsInCombat() then
        return nil, COMBAT_ERROR
    end
    local body, id = slotFor(text, current.long)
    local moved = EditMacro(index, name, icon and Macros.IconIndex(icon) or nil, body)
    if id then
        storeLong(id, text)
    end
    local now = Macros.Find(current.tab, name, body, type(moved) == "number" and moved or index) or index
    if current.long and not id then
        dropLong(current.long)
    end
    return now
end

function Macros.NewId()
    local id = Macros.db.nextId
    Macros.db.nextId = id + 1
    return id
end

function Macros.Write(index, name, icon, body)
    local tab = Macros.TabOf(index)
    local moved = EditMacro(index, name, icon and Macros.IconIndex(icon) or nil, body)
    return Macros.Find(tab, name, body, type(moved) == "number" and moved or index) or index
end

function Macros:Delete(index)
    local current = Macros.Get(index)
    if not current then
        return nil, "That macro no longer exists."
    end
    if addon:IsInCombat() then
        return nil, COMBAT_ERROR
    end
    DeleteMacro(index)
    if current.long then
        dropLong(current.long)
    end
    return true
end
