local addon = WMacroCompiler

--[[-----------------------------------------------------------------------------
BindPad import (addon.BindPad; keybinds-plan.md, phase 5): BindPad's keys
brought over once, while BindPad is enabled (its BindPadVars is only loaded
then). Offered once per character when the bank window opens; again from
the bank settings' Bank tab, or /qmb keys import.

BindPad 2.x:
  BindPadVars[1..42]                 its General tab's slots, every
                                     character's; their keys live only in
                                     the game's binding set
  BindPadVars["PROFILE_<realm>_<name>"] = {
      [1..5] = { [1..126] = slot, keys = { [action] = key } },
      profileForTalentGroup = { [group] = profile number },
  }
  slot = { type = "CLICK" | "MACRO" | "SPELL" | "ITEM", name, texture,
           macrotext (CLICK), action = the binding's command }

What it does:
  CLICK (BindPad's own macros): a bank macro each, in the class's Unsorted
      (General's from its General tab), a taken name numbered (Bank:FreeName);
      one already there with the same text is used instead, so importing
      twice adds nothing.
  MACRO (a slot holding one of your macros): the key goes to the bank macro
      with that name and text, General's or the class's; else it is named
      in the chat.
  SPELL, ITEM: named in the chat; they stay with BindPad or the game's
      Key Bindings window.
A key's level (Keys.lua): a profile's key in both talent groups (or with no
second group, or the same spec in both): the class; in one only: that
group's spec. Its General tab's keys: every character's when the binding
set is the account's, else the class. A key Quintessence already gives
something else at that level is kept, and said.

The player's binding set is not written: Quintessence's keys are priority
override bindings, over BindPad's on the same keys. (Clearing BindPad's
bindings afterwards would not help: while BindPad is enabled it would
bind them again, and once it is disabled Quintessence's keys still cover
them.)

  BindPad:Available()  -> whether BindPadVars is loaded
  BindPad:Read()       -> the items (see read()), or nil and why
  BindPad:Import()     -> a report: { macros, keys, kept, skipped, left },
                          or nil and why
  BindPad:Run()        the import, said in the chat and the bank's status
  BindPad:Offer()      the once-per-character offer (BankUI:Show)
-------------------------------------------------------------------------------]]
local BindPad = {}
addon.BindPad = BindPad

local GENERAL_SLOTS = 42
local PROFILE_SLOTS = 126

local function vars()
    return type(BindPadVars) == "table" and BindPadVars or nil
end

local function playerClass()
    local _, class = UnitClass("player")
    return class
end

function BindPad:Available()
    return vars() ~= nil
end

-- An item per distinct slot (type, name, text): { slot, general, groups =
-- { [talent group] = key }, generalKey }.
local function read(data)
    local items, byIdentity = {}, {}
    local function itemFor(slot, general)
        if type(slot) ~= "table" or type(slot.type) ~= "string" or type(slot.name) ~= "string" then
            return nil
        end
        local identity = (general and "G" or "C") .. "\0" .. slot.type .. "\0" .. slot.name .. "\0"
            .. (slot.macrotext or "")
        local item = byIdentity[identity]
        if not item then
            item = { slot = slot, general = general, groups = {} }
            byIdentity[identity] = item
            items[#items + 1] = item
        end
        return item
    end

    for index = 1, GENERAL_SLOTS do
        local slot = data[index]
        local item = itemFor(slot, true)
        if item and slot.action and GetBindingKey then
            item.generalKey = item.generalKey or GetBindingKey(slot.action)
        end
    end

    local realm, name = GetRealmName and GetRealmName(), UnitName("player")
    local character = realm and name and data["PROFILE_" .. realm .. "_" .. name]
    if type(character) == "table" then
        local forGroup = type(character.profileForTalentGroup) == "table" and character.profileForTalentGroup or {}
        local groups = GetNumTalentGroups and GetNumTalentGroups() or 1
        for group = 1, math.max(1, groups) do
            local profile = character[forGroup[group] or group]
            if type(profile) == "table" then
                local keys = type(profile.keys) == "table" and profile.keys or {}
                for index = 1, PROFILE_SLOTS do
                    local slot = profile[index]
                    local item = itemFor(slot, false)
                    if item then
                        item.groups[group] = item.groups[group] or (slot.action and keys[slot.action]) or nil
                    end
                end
            end
        end
        items.dual = groups > 1
    end
    return items
end

function BindPad:Read()
    local data = vars()
    if not data then
        return nil, "BindPad's data isn't loaded: enable BindPad, then /qmb keys import."
    end
    return read(data)
end

-- The levels an item's keys go on: { { key, level }... }.
local function levelsOf(item, dual)
    local class = playerClass()
    local out = {}
    if item.general then
        if item.generalKey then
            local accountSet = GetCurrentBindingSet and GetCurrentBindingSet() == 1
            out[#out + 1] = { key = item.generalKey, level = accountSet and "ALL" or class }
        end
        return out
    end
    local first, second = item.groups[1], item.groups[2]
    local State = addon.State
    local spec1 = State.PlayerSpecOfGroup(1)
    local spec2 = dual and State.PlayerSpecOfGroup(2) or nil
    if (first or second) and (first == second or not dual or spec1 == spec2) then
        out[#out + 1] = { key = first or second, level = class }
        return out
    end
    for group, key in pairs({ first or false, second or false }) do
        if key then
            local spec = group == 1 and spec1 or spec2
            out[#out + 1] = { key = key, level = spec and (class .. ":" .. spec) or class }
        end
    end
    return out
end

local function bankMacro(section, name, text)
    for id, record in pairs(addon.Macros.db.macros) do
        if record.section == section and record.text == text and (name == nil or record.name == name) then
            return id
        end
    end
end

-- The game macro a MACRO slot names, as the bank keeps it.
local function bankMacroFor(name)
    local index = GetMacroIndexByName and GetMacroIndexByName(name) or 0
    if index == 0 then
        return nil
    end
    local _, _, body = GetMacroInfo(index)
    body = (body or ""):gsub("%s+$", "")
    return bankMacro("GENERAL", name, body) or bankMacro(playerClass(), name, body)
end

local function describe(item)
    local key = item.generalKey or item.groups[1] or item.groups[2]
    return item.slot.name .. (key and (" (" .. addon.Keys.KeyText(key) .. ")") or "")
end

function BindPad:Import()
    local items, why = self:Read()
    if not items then
        return nil, why
    end
    if addon:IsInCombat() then
        return nil, "Not in combat: import from BindPad when the fight ends."
    end
    local Bank, Keys = addon.Bank, addon.Keys
    local class = playerClass()
    local report = { macros = 0, keys = 0, kept = {}, skipped = {}, left = {} }
    for _, item in ipairs(items) do
        local slot = item.slot
        local levels = levelsOf(item, items.dual)
        local id
        if slot.type == "CLICK" and type(slot.macrotext) == "string" then
            local section = item.general and "GENERAL" or class
            local text = slot.macrotext:gsub("%s+$", "")
            id = bankMacro(section, nil, text)
            if not id then
                local name = Bank:FreeName(section, Bank.FitName(slot.name))
                local icon = type(slot.texture) == "string" and slot.texture or nil
                local added, addError = Bank:Add(section, nil, name, icon, text)
                if added then
                    id = added
                    report.macros = report.macros + 1
                else
                    report.skipped[#report.skipped + 1] = slot.name .. ": " .. tostring(addError)
                end
            end
        elseif slot.type == "MACRO" then
            id = bankMacroFor(slot.name)
            if not id and #levels > 0 then
                report.skipped[#report.skipped + 1] = describe(item) .. ": no bank macro with its name and text"
            end
        elseif #levels > 0 then
            report.left[#report.left + 1] = describe(item)
        end
        if id then
            for _, entry in ipairs(levels) do
                local key = Keys.Normalize(entry.key)
                local holder = key and (addon.db.keys[entry.level] or {})[key]
                if holder and not (holder.kind == "macro" and holder.id == id) then
                    report.kept[#report.kept + 1] = Keys.KeyText(key) .. " (" .. Keys.LevelName(entry.level)
                        .. ") stays on what Quintessence has there"
                elseif key and not holder then
                    local done, setError = Keys:SetAt("macro", id, key, entry.level)
                    if done then
                        report.keys = report.keys + 1
                    else
                        report.skipped[#report.skipped + 1] = describe(item) .. ": " .. tostring(setError)
                    end
                end
            end
        end
    end
    Bank:Character().bindPadImported = true
    return report
end

function BindPad:Run()
    local report, why = self:Import()
    if not report then
        addon:Print(why)
        return
    end
    local summary = "From BindPad: " .. report.macros .. (report.macros == 1 and " macro" or " macros")
        .. " into the bank, " .. report.keys .. (report.keys == 1 and " key." or " keys.")
    addon:Print(summary)
    if #report.kept > 0 then
        addon:Print("Kept: " .. table.concat(report.kept, "; ") .. ".")
    end
    if #report.skipped > 0 then
        addon:Print("Not imported: " .. table.concat(report.skipped, "; ") .. ".")
    end
    if #report.left > 0 then
        addon:Print("Spells and items stay with BindPad (or the game's Key Bindings): "
            .. table.concat(report.left, ", ") .. ".")
    end
    local BankUI = addon.BankUI
    if BankUI.window then
        BankUI:RefreshBank()
        BankUI:SetStatus(summary, "|cff80ff80")
    end
end

-- What there is to bring over: the slots with a key, or a BindPad macro.
local function worth(items)
    local count = 0
    for _, item in ipairs(items) do
        if item.slot.type == "CLICK" or item.generalKey or next(item.groups) then
            count = count + 1
        end
    end
    return count
end

function BindPad:Offer()
    local items = vars() and self:Read()
    if not items then
        return
    end
    local character = addon.Bank:Character()
    if character.bindPadAsked or character.bindPadImported then
        return
    end
    local count = worth(items)
    if count > 0 then
        character.bindPadAsked = true
        addon.Dialog:Show("QMB_IMPORT_BINDPAD", count .. (count == 1 and " slot" or " slots"))
    end
end
