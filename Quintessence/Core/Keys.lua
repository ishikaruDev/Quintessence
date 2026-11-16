local addon = WMacroCompiler

--[[-----------------------------------------------------------------------------
Keys (addon.Keys): templates and bank macros bound to keys, without a macro
slot (keybinds-plan.md).

WMacroCompilerDB.keys[level][key] = { kind = "template" | "macro",
                                      id = <template id> | <bank id> }
  level  "ALL" (every character), a class ("ROGUE": every rogue) or a class
         and spec ("ROGUE:SUBTLETY": rogues in Subtlety, the spec as
         PLAYER_SPEC has it). On one key the most specific level wins.
  key    the client's name for it: modifiers ALT-, CTRL-, SHIFT- in that
         order, then the key ("CTRL-F", "SHIFT-BUTTON4").
An item has at most one key per level; a key at a
level has one item. Where an item can be bound follows where it lives: a
General template or bank macro at any level, a class one at its class's
levels only.

The bindings are override bindings on our own frame (SetOverrideBindingClick),
priority ones: action bar addons (ElvUI) put their keys on as override
bindings too, after ours at login, and of two ordinary overrides the last
set wins (after a /reload a bound key ran the action button again). The
player's binding sets are never written, so turning this off gives every
key back. They are set again at login, when the spec changes and when a key
or a template changes; never in combat (the client forbids it): then at the
end of combat. A key clicks the template's button, WMC_<name>, or the bank macro's,
QMB<id> (the long macros' button, Bank/Macros.lua: made for a bound macro
whatever its length, kept in step with its edits), with LeftButton; the buttons fire on the press (Secure.lua registers them for
AnyDown).

  Keys:Set(kind, id, key, scope) -> true, the item it took the key from (or
                              nil); or nil and the error. scope: "ALL",
                              "CLASS", "SPEC" (this character's class or
                              spec); nil: the item's own (General: ALL, a
                              class item: CLASS)
  Keys:SetAt(kind, id, key, level) the same at a level named in full
                              ("ROGUE:COMBAT": another talent group's
                              spec; the BindPad import)
  Keys:Clear(kind, id, scope) its key at that level (scope nil: every
                              level); -> how many were removed
  Keys:KeyFor(kind, id)       -> key, level: the key that runs it on this
                              character now, if any
  Keys:KeyAt(kind, id, scope) -> its key at that level (whether in effect
                              here or not), if any
  Keys:HolderOf(key)          -> the name of what the key runs here, and
                              its level
  Keys:CanBind(kind, id)      -> true; or nil and why not (another class's)
  Keys:HomeOf(kind, id)       -> its class, nil for General
  Keys:Entries()              -> the key list's rows (KeyList.lua)
  Keys:ClearAt(level, key)    removes that one
  Keys:Report()               -> the lines /qmb keys print prints
  Keys:Apply()                sets the override bindings for this character
  Keys:TemplateChanged(oldId, newId) a template renamed, moved or deleted
                              (newId nil)
  Keys:Rehome(kind, oldId, newId, home) an item renamed (newId), moved to
                              a section (home: its class, nil: General) or
                              gone (newId nil)
  Keys:MacroDeleted(id)       a bank macro deleted: its keys and its button
-------------------------------------------------------------------------------]]
local Keys = {}
addon.Keys = Keys

local owner = CreateFrame("Frame")
Keys.owner = owner

local MODIFIERS = { "ALT", "CTRL", "SHIFT" }

local function db()
    return addon.db and addon.db.keys
end

local function playerClass()
    local _, class = UnitClass("player")
    return class
end

local function playerSpec()
    return addon.State and addon.State.values.PLAYER_SPEC
end

-- This character's spec level ("ROGUE:SUBTLETY"), or nil with no talents.
function Keys.SpecLevel()
    local class, spec = playerClass(), playerSpec()
    return class and spec and (class .. ":" .. spec) or nil
end

-- The levels that apply on this character, least specific first.
local function levelsHere()
    local class, spec = playerClass(), playerSpec()
    local levels = { "ALL" }
    if class then
        levels[#levels + 1] = class
        if spec then
            levels[#levels + 1] = class .. ":" .. spec
        end
    end
    return levels
end

-- A key as the client names it ("ctrl-f" -> "CTRL-F", "shift-ctrl-1" ->
-- "CTRL-SHIFT-1"), or nil.
function Keys.Normalize(text)
    text = (text or ""):upper():gsub("%s+", "")
    if text == "" then
        return nil
    end
    local parts = {}
    for part in (text .. "-"):gmatch("(.-)%-") do
        parts[#parts + 1] = part
    end
    local base = table.remove(parts)
    if not base or base == "" then
        return nil
    end
    local held = {}
    for _, part in ipairs(parts) do
        if part == "CONTROL" then
            part = "CTRL"
        end
        if part ~= "ALT" and part ~= "CTRL" and part ~= "SHIFT" then
            return nil
        end
        held[part] = true
    end
    local key = ""
    for _, modifier in ipairs(MODIFIERS) do
        if held[modifier] then
            key = key .. modifier .. "-"
        end
    end
    return key .. base
end

-- "CTRL-SHIFT-BUTTON4" -> "Ctrl-Shift-Mouse Button 4" (the client's name
-- for the key itself when it has one).
function Keys.KeyText(key)
    local text = ""
    local base = key
    for _, modifier in ipairs(MODIFIERS) do
        if base:sub(1, #modifier + 1) == modifier .. "-" then
            text = text .. modifier:sub(1, 1) .. modifier:sub(2):lower() .. "-"
            base = base:sub(#modifier + 2)
        end
    end
    local name = GetBindingText and GetBindingText(base, "KEY_")
    return text .. ((name and name ~= "") and name or base)
end

-- The short form for a row's end, as action bars abbreviate:
-- "CTRL-SHIFT-BUTTON4" -> "cs-M4", "ALT-NUMPAD1" -> "a-N1", "F" -> "F".
local SHORT_KEYS = { MOUSEWHEELUP = "WU", MOUSEWHEELDOWN = "WD", SPACE = "Spc", BACKSPACE = "Bs",
    PAGEUP = "PU", PAGEDOWN = "PD", INSERT = "Ins", DELETE = "Del", HOME = "Hm", END = "End" }

function Keys.ShortText(key)
    local prefix = ""
    local base = key
    for _, modifier in ipairs(MODIFIERS) do
        if base:sub(1, #modifier + 1) == modifier .. "-" then
            prefix = prefix .. modifier:sub(1, 1):lower()
            base = base:sub(#modifier + 2)
        end
    end
    local short = SHORT_KEYS[base]
        or (base:match("^BUTTON(%d+)$") and "M" .. base:match("^BUTTON(%d+)$"))
        or (base:match("^NUMPAD(.+)$") and "N" .. base:match("^NUMPAD(.+)$"))
        or base
    return (prefix ~= "" and (prefix .. "-") or "") .. short
end

-- The key list's form, its caps having the room: the modifiers in full,
-- the key short: "CTRL-SHIFT-BUTTON4" -> "Ctrl-Shift-M4", "SHIFT-M" -> "Shift-M".
function Keys.ListText(key)
    local prefix = ""
    local base = key
    for _, modifier in ipairs(MODIFIERS) do
        if base:sub(1, #modifier + 1) == modifier .. "-" then
            prefix = prefix .. modifier:sub(1, 1) .. modifier:sub(2):lower() .. "-"
            base = base:sub(#modifier + 2)
        end
    end
    return prefix .. Keys.ShortText(base)
end

-- "ALL" -> "All", "ROGUE" -> "Rogue", "ROGUE:SUBTLETY" -> "Subtlety".
function Keys.LevelName(level)
    if level == "ALL" then
        return "All"
    end
    local class, spec = level:match("^([^:]+):(.+)$")
    if spec then
        return addon.BankUI.SpecName(spec)
    end
    return addon.Bank.SectionName(level)
end

-- The template a key points at: its record and scope, if it still exists.
local function templateOf(id)
    local scope, name = (id or ""):match("^([^:]+):(.+)$")
    local values = scope and addon.db.templates[scope]
    return values and values[name], scope, name
end

local function macroOf(id)
    local db = addon.Macros.db
    return db and db.macros[id]
end

local function itemName(entry)
    if entry.kind == "template" then
        local _, _, name = templateOf(entry.id)
        return name or entry.id
    end
    local record = macroOf(entry.id)
    return record and record.name or tostring(entry.id)
end

-- The button a key clicks on this character, or nil (the item is gone,
-- disabled, or another class's).
local function buttonOf(entry)
    if entry.kind == "template" then
        local record, scope, name = templateOf(entry.id)
        if record and record.enabled ~= false and (scope == "GENERAL" or scope == playerClass()) then
            return "WMC_" .. name
        end
    elseif entry.kind == "macro" then
        local record = macroOf(entry.id)
        if record and (record.section == "GENERAL" or record.section == playerClass()) then
            if not addon.Macros.buttons[entry.id] then
                addon.Macros.ApplyButton(entry.id)
            end
            return "QMB" .. entry.id
        end
    end
    return nil
end

-- The class an item belongs to (nil: General), and whether it exists.
local function homeOf(kind, id)
    if kind == "template" then
        local record, scope = templateOf(id)
        if not record then
            return nil, false
        end
        return scope ~= "GENERAL" and scope or nil, true
    elseif kind == "macro" then
        local record = macroOf(id)
        if not record then
            return nil, false
        end
        return record.section ~= "GENERAL" and record.section or nil, true
    end
    return nil, false
end

-- The keys in effect here: key -> { entry, level }, the most specific
-- level winning.
local function effective()
    local keys = db() or {}
    local result = {}
    for _, level in ipairs(levelsHere()) do
        for key, entry in pairs(keys[level] or {}) do
            result[key] = { entry = entry, level = level }
        end
    end
    return result
end

function Keys:Initialize()
    addon.db.keys = addon.db.keys or {}
    self:Apply()
end

function Keys:Apply()
    if not db() then
        return
    end
    if addon:IsInCombat() then
        self.pending = true
        return
    end
    self.pending = false
    self.appliedSpec = playerSpec()
    ClearOverrideBindings(owner)
    for key, found in pairs(effective()) do
        local button = buttonOf(found.entry)
        if button then
            SetOverrideBindingClick(owner, true, key, button, "LeftButton")
        end
    end
end

-- The template list and the bank's show each row's key here.
local function refreshLists()
    if addon.UI and addon.UI.RefreshList then
        addon.UI:RefreshList()
    end
    local BankUI = addon.BankUI
    if BankUI and BankUI.window and BankUI.RefreshBank then
        BankUI:RefreshBank()
    end
    if addon.KeyList and addon.KeyList:IsShown() then
        addon.KeyList:Reload()
    end
end

function Keys:CombatEnded()
    if self.pending then
        self:Apply()
    end
end

-- The State changed PLAYER_SPEC (a talent event, the login retry): the
-- spec levels follow it.
function Keys:SpecChanged()
    if db() and playerSpec() ~= self.appliedSpec then
        self:Apply()
        refreshLists()
    end
end

-- scope ("ALL" | "CLASS" | "SPEC" | nil) -> the level, or nil and the error.
local function levelFor(kind, id, scope)
    local home, exists = homeOf(kind, id)
    if not exists then
        return nil, "Nothing to bind: it no longer exists."
    end
    local class = playerClass()
    if home and home ~= class then
        return nil, "It belongs to " .. addon.Bank.SectionName(home) .. ": bind it on one."
    end
    scope = scope or (home and "CLASS" or "ALL")
    if scope == "ALL" then
        if home then
            return nil, "A class's own can't be bound for every class."
        end
        return "ALL"
    elseif scope == "CLASS" then
        return class
    elseif scope == "SPEC" then
        local spec = playerSpec()
        if not spec then
            return nil, "No spec yet: spend some talent points first."
        end
        return class .. ":" .. spec
    end
    return nil, "Unknown level: " .. tostring(scope)
end

local function same(entry, kind, id)
    return entry.kind == kind and entry.id == id
end

function Keys:Set(kind, id, key, scope)
    local keys = db()
    if not keys then
        return nil, "Not loaded yet."
    end
    key = Keys.Normalize(key)
    if not key then
        return nil, "Not a key: use the client's names, such as CTRL-F or SHIFT-BUTTON4."
    end
    local level, levelError = levelFor(kind, id, scope)
    if not level then
        return nil, levelError
    end
    return self:Write(kind, id, key, level)
end

-- A level named in full: "ALL" for a General item, this character's class,
-- or its class and any of the class's specs.
function Keys:SetAt(kind, id, key, level)
    if not db() then
        return nil, "Not loaded yet."
    end
    key = Keys.Normalize(key)
    if not key then
        return nil, "Not a key: " .. tostring(key)
    end
    local home, exists = homeOf(kind, id)
    if not exists then
        return nil, "Nothing to bind: it no longer exists."
    end
    local class = playerClass()
    local levelClass = level:match("^([^:]+)")
    if level == "ALL" then
        if home then
            return nil, "A class's own can't be bound for every class."
        end
    elseif levelClass ~= class or (home and home ~= class) then
        return nil, "Not this class's level: " .. level
    end
    return self:Write(kind, id, key, level)
end

-- Keys:Set and :SetAt, the level checked: the key on it.
function Keys:Write(kind, id, key, level)
    local keys = db()
    local atLevel = keys[level] or {}
    keys[level] = atLevel
    for other, entry in pairs(atLevel) do
        if same(entry, kind, id) and other ~= key then
            atLevel[other] = nil
        end
    end
    local previous = atLevel[key]
    if previous and same(previous, kind, id) then
        previous = nil
    end
    atLevel[key] = { kind = kind, id = id }
    self:Apply()
    refreshLists()
    return true, previous and itemName(previous) or nil
end

function Keys:Clear(kind, id, scope)
    local keys = db()
    if not keys then
        return 0
    end
    local only
    if scope then
        local level = levelFor(kind, id, scope)
        if not level then
            return 0
        end
        only = level
    end
    local removed = 0
    for level, atLevel in pairs(keys) do
        if not only or level == only then
            for key, entry in pairs(atLevel) do
                if same(entry, kind, id) then
                    atLevel[key] = nil
                    removed = removed + 1
                end
            end
        end
    end
    if removed > 0 then
        self:Apply()
        refreshLists()
    end
    return removed
end

-- The class an item belongs to (nil: General).
function Keys:HomeOf(kind, id)
    return (homeOf(kind, id))
end

function Keys:CanBind(kind, id)
    local level, levelError = levelFor(kind, id, nil)
    return level and true or nil, levelError
end

function Keys:KeyAt(kind, id, scope)
    local keys = db()
    local level = keys and levelFor(kind, id, scope)
    for key, entry in pairs(level and keys[level] or {}) do
        if same(entry, kind, id) then
            return key
        end
    end
    return nil
end

function Keys:HolderOf(key)
    local found = effective()[key]
    if found then
        return itemName(found.entry), found.level
    end
    return nil
end

function Keys:KeyFor(kind, id)
    for key, found in pairs(effective()) do
        if same(found.entry, kind, id) then
            return key, found.level
        end
    end
    return nil
end

-- A template renamed or moved (newId) or deleted (newId nil).
function Keys:TemplateChanged(oldId, newId)
    if oldId == newId then
        return
    end
    local newScope = newId and newId:match("^([^:]+):")
    self:Rehome("template", oldId, newId, newScope ~= "GENERAL" and newScope or nil)
end

-- A move to a class takes its every-character keys to that class; keys of
-- a class it no longer belongs to are dropped.
function Keys:Rehome(kind, oldId, newId, home)
    local keys = db()
    if not keys then
        return
    end
    local moves = {}
    for level, atLevel in pairs(keys) do
        for key, entry in pairs(atLevel) do
            if same(entry, kind, oldId) then
                atLevel[key] = nil
                if newId then
                    local class = level:match("^([^:]+)")
                    if level == "ALL" and home then
                        moves[#moves + 1] = { home, key }
                    elseif level == "ALL" or not home or class == home then
                        moves[#moves + 1] = { level, key }
                    end
                end
            end
        end
    end
    for _, move in ipairs(moves) do
        local atLevel = keys[move[1]] or {}
        keys[move[1]] = atLevel
        if not atLevel[move[2]] then
            atLevel[move[2]] = { kind = kind, id = newId }
        end
    end
    self:Apply()
    refreshLists()
end

-- (Store.lua's Bank:Delete, the record already gone.) Its button goes
-- too, unless a slot still runs it as a long macro (Macros.db.long).
function Keys:MacroDeleted(id)
    self:Rehome("macro", id, nil)
    local Macros = addon.Macros
    if Macros.buttons[id] and not Macros.db.long[id] and not addon:IsInCombat() then
        Macros.RemoveButton(id)
    end
end

-- What the player's own bindings have on a key ("Action Button 3"), or nil.
function Keys.BlizzardAction(key)
    local action = GetBindingAction and GetBindingAction(key)
    if not action or action == "" then
        return nil
    end
    local name = GetBindingText and GetBindingText(action, "BINDING_NAME_")
    return (name and name ~= "") and name or action
end

local DIM = "|cff888888"

-- F2 before F10: the numbers in a key compared by value.
local function sortable(key)
    return (key:gsub("%d+", function(digits) return ("%05d"):format(tonumber(digits)) end))
end

-- The keys that can apply on this character (every character's, its
-- class's, its class's specs'), templates first, each sorted by key:
-- { key, kind, id, name, level, note (what it's doing here, or nil),
-- inEffect, problem (its item disabled or gone) }.
function Keys:Entries()
    local keys = db() or {}
    local class = playerClass()
    local specLevel = Keys.SpecLevel()
    local here = effective()
    local rows = {}
    for level, atLevel in pairs(keys) do
        local levelClass = level:match("^([^:]+)")
        if level == "ALL" or levelClass == class then
            for key, entry in pairs(atLevel) do
                local row = { key = key, kind = entry.kind, id = entry.id, name = itemName(entry), level = level }
                row.inEffect = here[key] ~= nil and here[key].level == level
                if level:find(":") and level ~= specLevel then
                    row.note = "not this spec"
                elseif not row.inEffect then
                    row.note = "replaced by " .. Keys.LevelName(here[key].level) .. "'s"
                elseif not buttonOf(entry) then
                    local _, exists = homeOf(entry.kind, entry.id)
                    row.note, row.problem = exists and "off" or "gone", true
                else
                    local blizzard = Keys.BlizzardAction(key)
                    row.note = blizzard and ("over " .. blizzard) or nil
                end
                rows[#rows + 1] = row
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.kind ~= b.kind then
            return a.kind == "template"
        end
        if a.key ~= b.key then
            return sortable(a.key) < sortable(b.key)
        end
        return a.level < b.level
    end)
    return rows
end

-- Removes one key at one level (the key list's X).
function Keys:ClearAt(level, key)
    local atLevel = db() and db()[level]
    if atLevel and atLevel[key] then
        atLevel[key] = nil
        self:Apply()
        refreshLists()
        return true
    end
end

local KIND_HEADINGS = { template = "Templates", macro = "Macros" }

function Keys:Report()
    local class, spec = playerClass(), playerSpec()
    local lines = { "Key bindings (" .. addon.Bank.SectionName(class or "?")
        .. (spec and (", " .. addon.BankUI.SpecName(spec)) or "") .. "):" }
    local rows = self:Entries()
    if #rows == 0 then
        lines[#lines + 1] = "  None yet: right-click a template, or a macro in the bank."
    end
    local kind
    for _, row in ipairs(rows) do
        if row.kind ~= kind then
            kind = row.kind
            lines[#lines + 1] = "  " .. KIND_HEADINGS[kind] .. ":"
        end
        lines[#lines + 1] = "    " .. Keys.KeyText(row.key) .. ": " .. row.name .. " (" .. Keys.LevelName(row.level) .. ")"
            .. (row.note and (DIM .. " " .. row.note .. "|r") or "")
    end
    return lines
end

-- The template a name typed in a command means: General's or this class's.
local function findTemplate(name)
    name = (name or ""):lower()
    for _, scope in ipairs({ "GENERAL", playerClass() }) do
        for templateName in pairs(addon.db.templates[scope] or {}) do
            if templateName:lower() == name then
                return addon:TemplateId(scope, templateName), templateName
            end
        end
    end
end

local SCOPE_WORDS = { all = "ALL", class = "CLASS", spec = "SPEC" }

-- /qmb keys (the list), /qmb keys print (into the chat), /qmb keys import
-- (BindPad's, Bank/BindPad.lua),
-- /qmb keys bind <template> <key> [all | class | spec],
-- /qmb keys clear <template> [all | class | spec]
function Keys:Command(rest)
    if not db() then
        return
    end
    local command, args = (rest or ""):match("^(%S*)%s*(.-)$")
    command = command:lower()
    if command == "" then
        addon.KeyList:Open()
        return
    elseif command == "print" then
        for _, line in ipairs(self:Report()) do
            addon:Print(line)
        end
        return
    elseif command == "import" then
        addon.BindPad:Run()
        return
    end
    local name, key, word = args:match("^(%S+)%s*(%S*)%s*(%S*)$")
    if command == "clear" then
        word, key = key, nil
    end
    local id, templateName = findTemplate(name)
    local scope = word and word ~= "" and SCOPE_WORDS[word:lower()] or nil
    if command == "bind" and id and key ~= "" and (scope or word == "") then
        local done, result = self:Set("template", id, key, scope)
        if not done then
            addon:Print(result)
            return
        end
        local bound, level = self:KeyFor("template", id)
        addon:Print(templateName .. " is on " .. Keys.KeyText(Keys.Normalize(key))
            .. (result and (", taken from " .. result) or "")
            .. (bound and (" (" .. Keys.LevelName(level) .. ")") or " (not in effect here)") .. "."
            .. (addon:IsInCombat() and " It takes effect when combat ends." or ""))
    elseif command == "clear" and id and (scope or word == "") then
        local removed = self:Clear("template", id, scope)
        addon:Print(removed > 0 and (templateName .. ": " .. removed .. (removed == 1 and " key" or " keys") .. " removed.")
            or (templateName .. " has no key there."))
    elseif (command == "bind" or command == "clear") and name and not id then
        addon:Print("No template named '" .. name .. "' here (General's or your class's).")
    else
        addon:Print("Keys: /qmb keys (the list), /qmb keys print (into the chat), /qmb keys import (BindPad's),"
            .. " /qmb keys bind <template> <key> [all | class | spec],"
            .. " /qmb keys clear <template> [all | class | spec].")
    end
end
