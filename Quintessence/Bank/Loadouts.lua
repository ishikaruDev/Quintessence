local addon = WMacroCompiler
local Macros = addon.Macros
local Bank = addon.Bank

--[[-----------------------------------------------------------------------------
Loadouts (addon.Loadouts): named sets of bank categories for the General and
Character tabs, applied by hand, on login and when the talents change
(bank-plan.md, Loadouts). No frames but a timer.

A loadout is QuintessenceBankDB.loadouts[class][name] = { general = {
place... }, character = { place... } }, a place being { section, category }
(category nil: that section's Unsorted). Applying it fills each tab with
its places' macros, in order (Store.lua: Bank:FillTab, so a macro the bank
doesn't have is saved first, never lost); a tab with no places is left
alone. Loadouts belong to a class: a character sees
its class's only, and names are unique within a class. Which one a
character uses is its own, in QuintessenceBankDB.characters["Name-Realm"]
(Bank:Character()):
  loadout                     the one it last applied
  login, primary, secondary   chosen for login and for each talent group
  bars[loadout][group] = { [action slot] = entry } the whole action bars
                              as this loadout last had them, per talent
                              group (a hybrid and Subtlety may share a
                              group, but not their items):
                              its macros by bank id, other macros by name,
                              spells, items, equipment sets, companions,
                              false for an empty button. Followed as the
                              buttons change, saved before any loadout is
                              applied (this one again too) and at logout,
                              only while the tabs can be trusted to hold
                              it; put back after it is applied. With none
                              of its own for the group, it starts from the
                              class's other character that saved this
                              loadout's bars: a max-level one first, then
                              the same race, then the same realm, then the
                              latest saved
  awaiting[loadout][group] = { [slot] = entry } what couldn't be put back
                              (a spell not learned yet, an item not in the
                              bags, Shadowmeld on a human): its button
                              stays empty, the record keeps the entry, and
                              it goes on its button by itself once it can
                              (a spell learned, the item in the bags); a
                              thing put on that button drops it
  barsSaved[loadout]          when its bars were saved (time())
  gear[loadout][spec]         the equipment set (the client's Equipment
                              Manager: a character's own, by name) this
                              character first put on with this loadout in
                              use, per spec (a PLAYER_SPEC: Subtlety may
                              not stay in one talent group); later swaps (a fishing set)
                              don't change it, the settings do; put on
                              again when it is applied or the spec comes
                              back
  level, race, realm          for choosing whose bars to start from

The talent rules are the class's, shared by its characters (a new rogue
picks its loadout by its talents with nothing to set up): QuintessenceBankDB.rules[class] = { { tree, talent, loadout }... },
tree a PLAYER_SPEC ("SUBTLETY"), talent a talent's name that must have
points; either may be left out. The first rule that matches wins; one with
a talent goes before the tree-only ones, so a talent tells two specs of
one tree apart. Each character's own rules of before were moved in.

  Loadouts:Names(), :Get(name), :Rules()
  Loadouts:Save(name, general, character) -> name, or nil and the error
  Loadouts:Rename(old, new), :Delete(name)
  Loadouts:FromTabs()         -> { general, character }: the places the tabs
                              were last filled from (for a new loadout)
  Loadouts:AddPlace(name, tab, place), :RemovePlace(name, tab, index)
  Loadouts:SetUse(slot, name) this character's login / primary / secondary
                              (name nil: none)
  Loadouts:AddRule(rule), :RemoveRule(index), :RemoveRules(name): the
                              class's rules (one with a key talent goes
                              first, before the tree-only ones)
  Loadouts:UsesOf(name)       -> how this character uses it (the class's
                              rules included): { "login",
                              "primary", rule... }
  Loadouts:Candidates()       -> the loadouts the talents fit now (the
                              key-talent rules' if any, else the trees')
  Loadouts:Rivals(name)       -> the others, when name is one of several
  Loadouts:Choose()           -> the loadout to use, and why ("rule" |
                              "picked" (of several that fit, the one this
                              character applied last) | "primary" |
                              "secondary" | "login"): the
                              talents decide, at login too; the login one
                              is the fallback.
  Loadouts:GearSets()         -> this character's equipment sets' names
  Loadouts:Gear(name, spec)   -> the set this character wears with it
                              (spec nil: the current one)
  Loadouts:SetGear(name, spec, set) (set nil: none)
  Loadouts:GearWorn(set)      a set was put on (UseEquipmentSet,
                              EQUIPMENT_SWAP_FINISHED): the current
                              loadout's, for the current spec, if it has
                              none yet
  Loadouts:Apply(name)        -> true, the summary; or nil and the error.
                              In combat it waits for the combat's end.

When the talents change it waits until they settle (SETTLE_SECONDS with no
change: spending points changes them on every click); then, if they really
are different (the talent group, or the points in a tree: the client sends
talent events that change nothing) and some tree has points, it applies
the chosen loadout if it isn't the current one. On login it always applies
the chosen one: the General tab is shared, another character may have
changed it.
-------------------------------------------------------------------------------]]
local Loadouts = {}
addon.Loadouts = Loadouts

-- The settings' Bank tab: the bars put back on an apply, and
-- a character's first bars from a classmate's; both on unless switched off.
function Loadouts:BarsOn()
    return not (Macros.db and Macros.db.settings.restoreBars == false)
end

function Loadouts:SeedOn()
    return not (Macros.db and Macros.db.settings.seedBars == false)
end

-- Opt-in (the settings' Bank tab): each class its own
-- General tab.
function Loadouts:ClassGeneralOn()
    return Macros.db ~= nil and Macros.db.settings.classGeneral == true
end

local SETTLE_SECONDS = 3
local RETRY_SECONDS = 0.5
local RECORD_SECONDS = 1
local FILL_SECONDS = 1
local retryTimer
local recordTimer
local fillTimer
local NAME_MAX = 40
local RACIAL = "Racial" -- a racial's rank text (GetSpellName)
local ACTION_SLOTS = 120

local function db()
    return Macros.db
end

local function changed()
    Bank.generation = (Bank.generation or 0) + 1
    if addon.BankUI and addon.BankUI.LoadoutsChanged then
        addon.BankUI:LoadoutsChanged()
    end
end

local function playerClass()
    local _, class = UnitClass("player")
    return class or "?"
end

local function looksLikeLoadout(value)
    if type(value) ~= "table" then
        return false
    end
    for _, tab in ipairs(Macros.TABS) do
        local places = value[tab]
        if type(places) == "table" and (places[1] == nil or type(places[1].section) == "string") then
            return true
        end
    end
    return false
end

-- The first version kept loadouts by name only; each goes to the class its
-- categories are for (the first class section), else the player's.
local function migrate()
    local loadouts = db().loadouts
    local moved = {}
    for key, value in pairs(loadouts) do
        if type(value) == "table"
            and not (key ~= "GENERAL" and Bank.SectionName(key) ~= key and not looksLikeLoadout(value)) then
            moved[key] = value
        end
    end
    for name, loadout in pairs(moved) do
        loadouts[name] = nil
        local class = playerClass()
        for _, tab in ipairs(Macros.TABS) do
            for _, place in ipairs(loadout[tab] or {}) do
                if place.section ~= "GENERAL" and class == playerClass() then
                    class = place.section
                end
            end
        end
        loadouts[class] = loadouts[class] or {}
        local target, count = name, 1
        while loadouts[class][target] do
            count = count + 1
            target = name .. " (" .. count .. ")"
        end
        loadouts[class][target] = loadout
    end
end

-- This character's class's loadouts, by name.
local function mine()
    local loadouts = db().loadouts
    if not loadouts.migrated then
        loadouts.migrated = true
        migrate()
    end
    local class = playerClass()
    loadouts[class] = loadouts[class] or {}
    return loadouts[class]
end

-- Where a rule goes in a list: one with a talent after the other talent
-- ones, before the tree-only ones; a tree-only one last.
local function insertRule(list, rule)
    local at = #list + 1
    if rule.talent then
        at = 1
        while list[at] and list[at].talent do
            at = at + 1
        end
    end
    table.insert(list, at, { tree = rule.tree, talent = rule.talent, loadout = rule.loadout })
end

-- The class's rules. Each character's own of before go in first (a rule
-- whose condition the list has already is dropped: it could never win).
local function rules()
    local all = db().rules
    local keys = {}
    for key, character in pairs(db().characters) do
        if type(character.rules) == "table" and character.class then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local character = db().characters[key]
        local list = all[character.class] or {}
        all[character.class] = list
        for _, rule in ipairs(character.rules) do
            local known = false
            for _, other in ipairs(list) do
                if other.tree == rule.tree and other.talent == rule.talent then
                    known = true
                end
            end
            if rule.loadout and not known then
                insertRule(list, rule)
            end
        end
        character.rules = nil
    end
    local class = playerClass()
    all[class] = all[class] or {}
    return all[class]
end

function Loadouts:Rules()
    return rules()
end

function Loadouts:Get(name)
    return name and mine()[name] or nil
end

function Loadouts:Names()
    local names = {}
    for name in pairs(mine()) do
        names[#names + 1] = name
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

local function copyPlaces(places)
    local copy = {}
    for _, place in ipairs(places or {}) do
        copy[#copy + 1] = { section = place.section, category = place.category }
    end
    return copy
end

local function validName(name, except)
    if type(name) ~= "string" then
        return nil, "Loadout name is required."
    end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        return nil, "Loadout name is required."
    end
    if #name > NAME_MAX then
        return nil, "Loadout name is too long."
    end
    for existing in pairs(mine()) do
        if existing ~= except and existing:upper() == name:upper() then
            return nil, "A loadout with that name already exists."
        end
    end
    return name
end

-- Creates or (same name) replaces a loadout.
function Loadouts:Save(name, general, character)
    local loadout = mine()[name]
    local checked, nameError = validName(name, loadout and name)
    if not checked then
        return nil, nameError
    end
    mine()[checked] = { general = copyPlaces(general), character = copyPlaces(character) }
    changed()
    return checked
end

-- The characters of this class (a loadout's name means another one for
-- another class).
local function classmates()
    local list, class = {}, playerClass()
    for _, character in pairs(db().characters) do
        if character.class == class then
            list[#list + 1] = character
        end
    end
    return list
end

-- Every character's references to a loadout: fn(holder, key) for each
-- field that names it.
local function eachReference(name, fn)
    for _, character in ipairs(classmates()) do
        for _, key in ipairs({ "loadout", "login", "primary", "secondary" }) do
            if character[key] == name then
                fn(character, key)
            end
        end
    end
    for _, rule in ipairs(rules()) do
        if rule.loadout == name then
            fn(rule, "loadout")
        end
    end
end

function Loadouts:Rename(oldName, newName)
    local loadout = mine()[oldName]
    if not loadout then
        return nil, "Loadout not found."
    end
    local checked, nameError = validName(newName, oldName)
    if not checked then
        return nil, nameError
    end
    mine()[oldName] = nil
    mine()[checked] = loadout
    eachReference(oldName, function(holder, key) holder[key] = checked end)
    for _, character in ipairs(classmates()) do
        if character.bars and character.bars[oldName] then
            character.bars[checked], character.bars[oldName] = character.bars[oldName], nil
        end
        for _, key in ipairs({ "barsSaved", "awaiting", "gear" }) do
            local byName = character[key]
            if byName then
                byName[checked], byName[oldName] = byName[oldName], nil
            end
        end
    end
    changed()
    return checked
end

function Loadouts:Delete(name)
    if not mine()[name] then
        return nil, "Loadout not found."
    end
    mine()[name] = nil
    eachReference(name, function(holder, key) holder[key] = nil end)
    local list = rules()
    for index = #list, 1, -1 do
        if not list[index].loadout then
            table.remove(list, index)
        end
    end
    for _, character in ipairs(classmates()) do
        if character.bars then
            character.bars[name] = nil
        end
        for _, key in ipairs({ "barsSaved", "awaiting", "gear" }) do
            if character[key] then
                character[key][name] = nil
            end
        end
    end
    changed()
    return true
end

function Loadouts:FromTabs()
    local places = {}
    for _, tab in ipairs(Macros.TABS) do
        local place = Bank:LoadedFrom(tab)
        places[tab] = place and { place } or {}
    end
    return places
end

function Loadouts:AddPlace(name, tab, place)
    local loadout = self:Get(name)
    if not loadout then
        return nil, "Loadout not found."
    end
    loadout[tab] = loadout[tab] or {}
    for _, existing in ipairs(loadout[tab]) do
        if existing.section == place.section and existing.category == place.category then
            return nil, "The loadout already has that category."
        end
    end
    table.insert(loadout[tab], { section = place.section, category = place.category })
    changed()
    return true
end

function Loadouts:RemovePlace(name, tab, index)
    local loadout = self:Get(name)
    if not (loadout and loadout[tab] and loadout[tab][index]) then
        return nil, "Loadout not found."
    end
    table.remove(loadout[tab], index)
    changed()
    return true
end

function Loadouts:SetUse(slot, name)
    Bank:Character()[slot] = name
    changed()
end

function Loadouts:AddRule(rule)
    local list = rules()
    local entry = { tree = rule.tree, talent = rule.talent, loadout = rule.loadout }
    if entry.talent then
        table.insert(list, 1, entry)
    else
        table.insert(list, entry)
    end
    changed()
end

-- One of the class's rules (its index in Loadouts:Rules()).
function Loadouts:RemoveRule(index)
    local list = rules()
    if list[index] then
        table.remove(list, index)
        changed()
    end
end

function Loadouts:RemoveRules(name)
    local list = rules()
    for index = #list, 1, -1 do
        if list[index].loadout == name then
            table.remove(list, index)
        end
    end
    changed()
end

function Loadouts:UsesOf(name)
    local character = Bank:Character()
    local uses = {}
    for _, slot in ipairs({ "login", "primary", "secondary" }) do
        if name and character[slot] == name then
            uses[#uses + 1] = slot
        end
    end
    for _, rule in ipairs(rules()) do
        if name and rule.loadout == name then
            uses[#uses + 1] = rule
        end
    end
    return uses
end

--[[ Choosing ]]

local function hasTalent(name)
    if not (GetNumTalents and GetTalentInfo) then
        return false
    end
    local group = GetActiveTalentGroup and GetActiveTalentGroup() or nil
    for tab = 1, 3 do
        for index = 1, GetNumTalents(tab, false, false, group) or 0 do
            local talent, _, _, _, rank = GetTalentInfo(tab, index, false, false, group)
            if talent == name and (rank or 0) > 0 then
                return true
            end
        end
    end
    return false
end

local function playerSpec()
    return addon.State and addon.State.values.PLAYER_SPEC or nil
end

local function ruleMatches(rule)
    if not (rule.tree or rule.talent) then
        return false
    end
    if rule.tree and rule.tree ~= playerSpec() then
        return false
    end
    return not rule.talent or hasTalent(rule.talent)
end

-- The loadouts the talents fit now: those of the matching rules with a
-- key talent if any match, else those of the matching tree-only ones.
function Loadouts:Candidates()
    local byTalent, byTree, seen = {}, {}, {}
    for _, rule in ipairs(rules()) do
        if rule.loadout and mine()[rule.loadout] and not seen[rule.loadout] and ruleMatches(rule) then
            seen[rule.loadout] = true
            local list = rule.talent and byTalent or byTree
            list[#list + 1] = rule.loadout
        end
    end
    return #byTalent > 0 and byTalent or byTree
end

-- Several loadouts fitting the same talents (two rogues on SPEC: Combat,
-- each with its own categories until they are unified): each character keeps the one it applied last among them, by
-- hand or not. Keyed by the set of them.
local function pickKey(candidates)
    local names = {}
    for index, name in ipairs(candidates) do
        names[index] = name
    end
    table.sort(names)
    return table.concat(names, "\n")
end

local function rememberPick(name)
    local candidates = Loadouts:Candidates()
    if #candidates < 2 then
        return
    end
    for _, candidate in ipairs(candidates) do
        if candidate == name then
            local character = Bank:Character()
            character.picks = character.picks or {}
            character.picks[pickKey(candidates)] = name
            return
        end
    end
end

-- The other loadouts the talents fit now, when `name` is one of several.
function Loadouts:Rivals(name)
    local candidates, others, found = self:Candidates(), {}, false
    for _, candidate in ipairs(candidates) do
        if candidate == name then
            found = true
        else
            others[#others + 1] = candidate
        end
    end
    return found and others or {}
end

function Loadouts:Choose()
    local character = Bank:Character()
    local candidates = self:Candidates()
    if #candidates > 1 then
        local picked = character.picks and character.picks[pickKey(candidates)]
        for _, name in ipairs(candidates) do
            if name == picked then
                return name, "picked"
            end
        end
    end
    if candidates[1] then
        return candidates[1], "rule"
    end
    local group = GetActiveTalentGroup and GetActiveTalentGroup() or 1
    local slot = group == 2 and "secondary" or "primary"
    if character[slot] and mine()[character[slot]] then
        return character[slot], slot
    end
    if character.login and mine()[character.login] then
        return character.login, "login"
    end
    return nil
end

--[[ The action bars ]]

local function idsOf(places)
    local ids, seen = {}, {}
    for _, place in ipairs(places) do
        for _, id in ipairs(Bank:CategoryIds(place.section, place.category)) do
            if not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    return ids
end

-- A loadout's macros: wanted[id] = tab, and byName[tab][name] = id (the
-- first of that name). Kept until the bank or a loadout changes
-- (Bank.generation): a button change asks for them each time.
local macroCache = setmetatable({}, { __mode = "k" })

local function macrosOf(loadout)
    local cached = macroCache[loadout]
    if cached and cached.generation == Bank.generation then
        return cached.wanted, cached.byName
    end
    local wanted, byName = {}, {}
    for _, tab in ipairs(Macros.TABS) do
        byName[tab] = {}
        for _, id in ipairs(idsOf(loadout[tab] or {})) do
            wanted[id] = tab
            local name = Bank:Get(id).name
            byName[tab][name] = byName[tab][name] or id
        end
    end
    macroCache[loadout] = { generation = Bank.generation, wanted = wanted, byName = byName }
    return wanted, byName
end

-- Which of the loadout's macros a slot (Macros.Get) is: by its link, else
-- by its name (a copy edited outside the bank, as ActionBarSaver finds
-- macros by name). nil: none of them.
local function loadoutMacro(macro, wanted, byName)
    for _, id in ipairs(Bank:LinksOf(macro)) do
        if wanted[id] == macro.tab then
            return id
        end
    end
    return byName[macro.tab] and byName[macro.tab][macro.name] or nil
end

-- Whether the tabs hold that loadout (each of its tabs: every macro is one
-- of its, and none of its is missing): then its buttons can be read even
-- before anything was applied this session.
local function tabsHold(loadout)
    local wanted, byName = macrosOf(loadout)
    for _, tab in ipairs(Macros.TABS) do
        if #(loadout[tab] or {}) > 0 then
            local found = {}
            for _, macro in ipairs(Macros.List(tab)) do
                local id = loadoutMacro(macro, wanted, byName)
                if not id then
                    return false
                end
                found[id] = true
            end
            for id, wantedTab in pairs(wanted) do
                if wantedTab == tab and not found[id] then
                    return false
                end
            end
        end
    end
    return true
end

-- Each talent group has its own action bars (dual spec), so a loadout's
-- buttons are kept per group: bars[loadout][group] = { [slot] = id }.
local function talentGroup()
    return GetActiveTalentGroup and GetActiveTalentGroup() or 1
end

local function barsOf(name, create)
    local character = Bank:Character()
    character.bars = character.bars or {}
    local byGroup = character.bars[name]
    local _, first = next(byGroup or {})
    if type(byGroup) ~= "table" or type(first) == "number" then
        byGroup = nil -- none yet, or the first version's (one set, no groups)
    end
    if not byGroup and create then
        byGroup = {}
    end
    character.bars[name] = byGroup
    if not byGroup then
        return nil
    end
    local group = talentGroup()
    if not byGroup[group] and create then
        byGroup[group] = {}
    end
    return byGroup[group]
end

-- What choosing whose bars to start from needs to know of a character.
local function noteCharacter(character)
    character.level = UnitLevel and UnitLevel("player") or character.level
    character.race = UnitRace and select(2, UnitRace("player")) or character.race
end

-- What couldn't be put back, for the active group: awaiting[loadout][group].
local function awaitingOf(name, create)
    local character = Bank:Character()
    local byName = character.awaiting
    if not byName then
        if not create then
            return nil
        end
        byName = {}
        character.awaiting = byName
    end
    local group = talentGroup()
    if not byName[name] and create then
        byName[name] = {}
    end
    if not byName[name] then
        return nil
    end
    if not byName[name][group] and create then
        byName[name][group] = {}
    end
    return byName[name][group]
end

local function copyEntries(entries)
    local copy = {}
    for slot, entry in pairs(entries or {}) do
        copy[slot] = entry
    end
    return copy
end

local function setAwaiting(name, entries)
    local list = awaitingOf(name, next(entries) ~= nil)
    if not list then
        return
    end
    for slot in pairs(list) do
        list[slot] = nil
    end
    for slot, entry in pairs(entries) do
        list[slot] = entry
    end
end

-- What a button holds, as recorded: a number, one of the loadout's macros
-- (its bank id); false, nothing; else { kind, ... }: { "macro", name, tab }
-- (another macro, found again by name, as ActionBarSaver does), { "spell",
-- name, rank }, { "item", id }, { "equipmentset", name }, { "companion",
-- type, spell id, index }. nil: something not recorded, left alone.
local function buttonEntry(slot, wanted, byName)
    local kind, id, subType, extra = GetActionInfo(slot)
    if not kind then
        return false
    elseif kind == "macro" then
        local macro = id and Macros.Get(id)
        if not macro then
            return false
        end
        return loadoutMacro(macro, wanted, byName) or { "macro", macro.name, macro.tab }
    elseif kind == "spell" then
        local name, rank
        if GetSpellName and id then
            name, rank = GetSpellName(id, BOOKTYPE_SPELL)
        end
        return name and { "spell", name, rank ~= "" and rank or nil } or nil
    elseif kind == "item" or kind == "equipmentset" then
        return id and { kind, id } or nil
    elseif kind == "companion" then
        return subType and { "companion", subType, extra, id } or nil
    end
    return nil
end

local function sameEntry(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- What to record for a button of `name`'s. One that couldn't be put back
-- (awaiting) keeps its entry while it stays empty.
local function recordOf(name, slot, wanted, byName)
    local entry = buttonEntry(slot, wanted, byName)
    local awaiting = awaitingOf(name)
    if awaiting and awaiting[slot] ~= nil then
        if entry == false then
            return awaiting[slot]
        end
        awaiting[slot] = nil
    end
    return entry
end

-- Whether the buttons now are the current loadout's to record. Not from a
-- talent event until the chosen loadout is applied (the client has swapped
-- in the other group's bars by then), nor while one is being applied; at
-- login, nothing until the chosen loadout is applied: the General tab is
-- the account's, and another character's loadout swap made its macros
-- anew; buttons point at a macro's own id, so this character's buttons
-- with the old ones are empty, and recording them would lose the record
-- that puts them back (a character's bars could be gone at login after
-- other characters played). With nothing applied at login, only
-- while the tabs hold it (the General tab may hold another character's
-- macros, and the buttons point at them).
function Loadouts:CanRecord()
    local loadout = self:Get(Bank:Character().loadout)
    if not loadout or self.frozen or self.applying or not GetActionInfo or not self:BarsOn() then
        return false
    end
    if self.live then
        return talentGroup() == self.group
    end
    return not self.loggingIn and tabsHold(loadout)
end

-- The active group's bars, every button, as `name`'s.
function Loadouts:SaveBars(name)
    local loadout = self:Get(name)
    if not (loadout and GetActionInfo) then
        return
    end
    local wanted, byName = macrosOf(loadout)
    local bars = barsOf(name, true)
    self.waiting = nil
    for slot in pairs(bars) do
        bars[slot] = nil
    end
    for slot = 1, ACTION_SLOTS do
        bars[slot] = recordOf(name, slot, wanted, byName)
    end
    local character = Bank:Character()
    character.barsSaved = character.barsSaved or {}
    character.barsSaved[name] = time and time() or 0
    noteCharacter(character)
end

-- Whose bars a character starts from, best first:
-- a max-level one over a lower one, then the same race, then the same
-- realm, then the one saved last.
local function realmOf(key)
    return key:match("^[^-]*%-(.*)$")
end

local function rank(name, character, key, me, myKey)
    local top = MAX_PLAYER_LEVEL or 80
    return {
        (character.level or 0) >= top and 1 or 0,
        character.race and character.race == me.race and 1 or 0,
        realmOf(key) == realmOf(myKey) and 1 or 0,
        character.barsSaved and character.barsSaved[name] or 0,
    }
end

local function better(a, b)
    for index = 1, #a do
        if a[index] ~= b[index] then
            return a[index] > b[index]
        end
    end
    return false
end

-- A classmate's record of `name` to start from (and whose it is): of the
-- same talent group if it has one, else its other.
local function classmateBars(name)
    local me, myKey, group = Bank:Character(), Bank.CharacterKey(), talentGroup()
    noteCharacter(me)
    local best, bestRank, owner
    for key, character in pairs(db().characters) do
        local byGroup = character ~= me and character.class == me.class and character.bars
            and character.bars[name]
        local _, first = next(type(byGroup) == "table" and byGroup or {})
        if type(first) == "table" then -- (not the first version's)
            local record = byGroup[group] or byGroup[group == 1 and 2 or 1]
            local score = rank(name, character, key, me, myKey)
            if record and (not best or better(score, bestRank)) then
                best, bestRank, owner = record, score, character
            end
        end
    end
    return best, owner
end

-- With no record of its own for the active group, `name` starts from a
-- classmate's (copied) -> true when it did.
function Loadouts:SeedBars(name)
    if barsOf(name) or not self:SeedOn() then
        return false
    end
    local from, owner = classmateBars(name)
    if not from then
        return false
    end
    -- Another race's racial is never this one's (Shadowmeld on a human): an empty button, not one waiting for it.
    local otherRace = owner.race ~= Bank:Character().race
    local bars = barsOf(name, true)
    for slot, entry in pairs(from) do
        if otherRace and type(entry) == "table" and entry[1] == "spell" and entry[3] == RACIAL then
            entry = false
        end
        if type(entry) == "table" then
            local copy = {}
            for key, value in pairs(entry) do
                copy[key] = value
            end
            entry = copy
        end
        bars[slot] = entry
    end
    return true
end

function Loadouts:SaveCurrentBars()
    if self:CanRecord() then
        self:SaveBars(Bank:Character().loadout)
    end
end

-- ACTIONBAR_SLOT_CHANGED: the player put something on a button or took it
-- off; the current loadout's record follows, a moment later. Unlearning
-- talents empties their buttons just before the talent event comes (a
-- talent's macro could be lost from the record): a
-- talent event in that moment drops what was waiting.
function Loadouts:SlotChanged(slot)
    if not (Macros.db and type(slot) == "number" and slot >= 1 and slot <= ACTION_SLOTS) or not self:CanRecord() then
        return
    end
    self.waiting = self.waiting or {}
    self.waiting[slot] = true
    recordTimer.elapsed = 0
    recordTimer:Show()
end

function Loadouts:RecordWaiting()
    local waiting = self.waiting
    self.waiting = nil
    if not (waiting and self:CanRecord()) then
        return
    end
    local name = Bank:Character().loadout
    local wanted, byName = macrosOf(self:Get(name))
    local bars = barsOf(name, true)
    for slot in pairs(waiting) do
        bars[slot] = recordOf(name, slot, wanted, byName)
    end
end

recordTimer = CreateFrame("Frame")
recordTimer:Hide()
Loadouts.recordTimer = recordTimer
recordTimer:SetScript("OnUpdate", function(frame, delta)
    frame.elapsed = (frame.elapsed or 0) + delta
    if frame.elapsed < RECORD_SECONDS then
        return
    end
    frame:Hide()
    Loadouts:RecordWaiting()
end)

-- Where a bank macro is now: its slot, else a slot of that name in its
-- tab.
local function slotOf(id, tab)
    local index = Bank:SlotsOf(id)[1]
    if index then
        return index
    end
    local record = Bank:Get(id)
    for _, macro in ipairs(record and tab and Macros.List(tab) or {}) do
        if macro.name == record.name then
            return macro.index
        end
    end
    return nil
end

-- The spellbook's indexes by name (the highest rank) and by name and rank.
local function spellbook()
    local spells = {}
    if not (GetSpellTabInfo and GetSpellName) then
        return spells
    end
    for tab = 1, MAX_SKILLLINE_TABS or 8 do
        local _, _, offset, count = GetSpellTabInfo(tab)
        for index = (offset or 0) + 1, (offset or 0) + (count or 0) do
            local name, rank = GetSpellName(index, BOOKTYPE_SPELL)
            if name then
                spells[name] = index
                if rank and rank ~= "" then
                    spells[name .. "|" .. rank] = index
                end
            end
        end
    end
    return spells
end

-- Puts a record's entry on the cursor -> the cursor kind it should show,
-- or nil when there is nothing to pick up.
local function pickUp(entry, wanted, spells)
    if type(entry) == "number" then
        local index = PickupMacro and slotOf(entry, wanted[entry])
        if not index then
            return nil
        end
        PickupMacro(index)
        return "macro"
    end
    local kind = entry[1]
    if kind == "macro" then
        for _, macro in ipairs(PickupMacro and Macros.List(entry[3]) or {}) do
            if macro.name == entry[2] then
                PickupMacro(macro.index)
                return kind
            end
        end
    elseif kind == "spell" then
        local index = (entry[3] and spells[entry[2] .. "|" .. entry[3]]) or spells[entry[2]]
        if index and PickupSpell then
            PickupSpell(index, BOOKTYPE_SPELL)
            return kind
        end
    elseif kind == "item" then
        if PickupItem then
            PickupItem(entry[2])
            return kind
        end
    elseif kind == "equipmentset" then
        for index = 1, PickupEquipmentSet and GetNumEquipmentSets() or 0 do
            if GetEquipmentSetInfo(index) == entry[2] then
                PickupEquipmentSet(index)
                return kind
            end
        end
    elseif kind == "companion" then
        if PickupCompanion then
            local found = entry[4]
            for index = 1, GetNumCompanions(entry[2]) or 0 do
                if select(3, GetCompanionInfo(entry[2], index)) == entry[3] then
                    found = index
                    break
                end
            end
            PickupCompanion(entry[2], found)
            return kind
        end
    end
    return nil
end

-- Placing makes a sound per button: off meanwhile, as ActionBarSaver.
local function quiet()
    if not (GetCVar and SetCVar) then
        return nil
    end
    local was = GetCVar("Sound_EnableAllSound")
    SetCVar("Sound_EnableAllSound", 0)
    return was
end

local function loud(was)
    if was ~= nil then
        SetCVar("Sound_EnableAllSound", was)
    end
end

-- Puts `name`'s bars back as the active group's record has them (`only`:
-- just those buttons): every recorded button; an empty one is emptied, and
-- one whose entry can't be picked up is emptied too (not left holding the
-- previous loadout's). A button not in the record is left alone. As
-- ActionBarSaver: the entry must be on the cursor before it is placed.
-- Returns the buttons changed, and those that couldn't be ({ slot = entry }).
function Loadouts:RestoreBars(name, only)
    local bars = barsOf(name)
    local loadout = self:Get(name)
    if not (bars and loadout and GetActionInfo and PlaceAction) then
        return 0, {}
    end
    local wanted, byName = macrosOf(loadout)
    local spells = spellbook()
    local restored, failed = 0, {}
    local sound = quiet()
    if ClearCursor then
        ClearCursor()
    end
    for slot, entry in pairs(only or bars) do
        local current = buttonEntry(slot, wanted, byName)
        if not sameEntry(current, entry) then
            if entry == false then
                if PickupAction then
                    PickupAction(slot)
                    restored = restored + 1
                end
            else
                local kind = pickUp(entry, wanted, spells)
                if kind and (not GetCursorInfo or GetCursorInfo() == kind) then
                    PlaceAction(slot)
                    restored = restored + 1
                else
                    failed[slot] = entry
                    if ClearCursor then
                        ClearCursor()
                    end
                    if current ~= false and PickupAction then
                        PickupAction(slot)
                    end
                end
            end
            if ClearCursor then
                ClearCursor() -- what was there, if anything
            end
        end
    end
    loud(sound)
    return restored, failed
end

local KIND_NAMES = { macro = "macros", spell = "spells", item = "items", equipmentset = "equipment sets",
    companion = "companions" }

-- The entries that couldn't go back, for the chat: "Thermal Sapper Charge
-- (item 42641), Shadowstep".
local function describe(failed)
    local names = {}
    for _, entry in pairs(failed) do
        local text
        if type(entry) == "number" then
            local record = Bank:Get(entry)
            text = record and record.name or "a macro"
        elseif entry[1] == "item" then
            text = (GetItemInfo and GetItemInfo(entry[2])) or ("item " .. entry[2])
        elseif entry[1] == "companion" then
            text = (GetSpellInfo and GetSpellInfo(entry[3])) or "a companion"
        else
            text = entry[2]
        end
        names[#names + 1] = text
    end
    table.sort(names)
    return table.concat(names, ", ", 1, math.min(#names, 6)) .. (#names > 6 and ", ..." or "")
end

-- /qmb bars: what the bank sees on the action bars.
function Loadouts:BarsReport()
    local character = Bank:Character()
    local current = character.loadout
    local loadout = self:Get(current)
    local wanted, byName = {}, {}
    if loadout then
        wanted, byName = macrosOf(loadout)
    end
    local buttons, linked, mine, strangers = 0, 0, 0, {}
    for slot = 1, GetActionInfo and ACTION_SLOTS or 0 do
        local kind, index = GetActionInfo(slot)
        local macro = kind == "macro" and index and Macros.Get(index)
        if macro then
            buttons = buttons + 1
            if #Bank:LinksOf(macro) > 0 then
                linked = linked + 1
            end
            if loadoutMacro(macro, wanted, byName) then
                mine = mine + 1
            else
                strangers[#strangers + 1] = slot .. ": " .. macro.name
            end
        end
    end
    local counts, empty = {}, 0
    for _, entry in pairs(loadout and barsOf(current) or {}) do
        if entry == false then
            empty = empty + 1
        else
            local kind = type(entry) == "number" and "macro" or entry[1]
            counts[kind] = (counts[kind] or 0) + 1
        end
    end
    local recorded = {}
    for _, kind in ipairs({ "macro", "spell", "item", "equipmentset", "companion" }) do
        if counts[kind] then
            recorded[#recorded + 1] = counts[kind] .. " " .. KIND_NAMES[kind]
        end
    end
    local lines = {
        buttons .. " buttons hold macros; " .. linked .. " of them are in the bank.",
        loadout and ("Loadout '" .. current .. "': " .. mine .. " of them are its macros. Recorded for it (talent group "
            .. talentGroup() .. "): " .. (#recorded > 0 and table.concat(recorded, ", ") or "nothing")
            .. (empty > 0 and (", " .. empty .. " empty") or "") .. "; its tabs "
            .. (tabsHold(loadout) and "hold it" or "don't hold it") .. "; recording "
            .. (self:CanRecord() and "on" or "paused") .. ".") or "No current loadout.",
    }
    if loadout and #strangers > 0 then
        lines[#lines + 1] = "Other macros: " .. table.concat(strangers, ", ", 1, math.min(#strangers, 12))
            .. (#strangers > 12 and ", ..." or "") .. "."
    end
    return lines
end

--[[ Gear ]]

function Loadouts:GearSets()
    local names = {}
    for index = 1, GetNumEquipmentSets and GetNumEquipmentSets() or 0 do
        local set = GetEquipmentSetInfo(index)
        if set then
            names[#names + 1] = set
        end
    end
    table.sort(names)
    return names
end

local function hasSet(set)
    for _, name in ipairs(Loadouts:GearSets()) do
        if name == set then
            return true
        end
    end
    return false
end

function Loadouts:Gear(name, spec)
    spec = spec or playerSpec()
    local gear = Bank:Character().gear
    return spec and gear and gear[name] and gear[name][spec] or nil
end

function Loadouts:SetGear(name, spec, set)
    if not (self:Get(name) and spec) then
        return
    end
    local character = Bank:Character()
    character.gear = character.gear or {}
    character.gear[name] = character.gear[name] or {}
    character.gear[name][spec] = set
    if not next(character.gear[name]) then
        character.gear[name] = nil
    end
    changed()
end

-- Only while the loadout is surely the one in use: applied this session,
-- the talents settled, no apply under way (it puts on its own set). Only
-- the first: a set put on for a while doesn't
-- replace it.
function Loadouts:GearWorn(set)
    local name = Macros.db and Bank:Character().loadout
    if type(set) ~= "string" or set == "" or not self:Get(name) or not self.live or self.frozen
        or self.applying or talentGroup() ~= self.group or self:Gear(name) then
        return
    end
    self:SetGear(name, playerSpec(), set)
end

-- How many more times a set put on is put on again while pieces of it are
-- left in the bags (SwapFinished).
local GEAR_RETRIES = 2

-- Whether a piece of `set` is still in the bags or the bank: one the swap
-- skipped. Unknown (no API) counts as all on.
local function gearLeftOff(set)
    if not GetEquipmentSetLocations or not EquipmentManager_UnpackLocation then
        return false
    end
    local locations = GetEquipmentSetLocations(set)
    for _, location in pairs(locations or {}) do
        -- 1: a slot the set ignores; 0 / -1: empty, or the item is missing.
        if location ~= 1 and location ~= 0 and location ~= -1 then
            local _, bank, bags = EquipmentManager_UnpackLocation(location)
            if bank or bags then
                return true
            end
        end
    end
    return false
end

-- Puts on `name`'s set for the current spec -> what to say (nil: no set).
-- In combat it waits for the combat's end.
function Loadouts:PutOnGear(name)
    local set = self:Gear(name)
    if not set then
        return nil
    end
    if not hasSet(set) then
        return "Its gear set '" .. set .. "' is gone."
    end
    if addon:IsInCombat() then
        self.gearPending = name
        return "Gear: " .. set .. ", when combat ends."
    end
    self.gearPending = nil
    self.gearSet, self.gearRetries = set, GEAR_RETRIES
    UseEquipmentSet(set)
    return "Gear: " .. set .. "."
end

-- A swap finished. A piece the client skipped goes on when the set is put
-- on again: a jewelcrafter wears at most three of their own gems, and a
-- piece that would make four is skipped while the piece it replaces, still
-- on, holds one more.
function Loadouts:SwapFinished(set)
    if set ~= self.gearSet then
        return
    end
    if (self.gearRetries or 0) > 0 and not addon:IsInCombat() and gearLeftOff(set) then
        self.gearRetries = self.gearRetries - 1
        UseEquipmentSet(set)
        return
    end
    self.gearSet, self.gearRetries = nil, nil
end

--[[ Applying ]]

function Loadouts:Apply(name)
    local loadout = self:Get(name)
    if not loadout then
        return nil, "Loadout not found."
    end
    if addon:IsInCombat() then
        self.pending = name
        return nil, "In combat: the loadout '" .. name .. "' is applied when combat ends."
    end
    self.pending = nil
    local character = Bank:Character()
    -- The bars as the outgoing loadout (or this one, applied again) left
    -- them.
    self:SaveCurrentBars()
    local UI = addon.BankUI
    local parts, firstError = {}, nil
    UI.busy = true
    self.applying = true
    for _, tab in ipairs(Macros.TABS) do
        local places = loadout[tab] or {}
        if #places > 0 then
            local placed, fillError, rescued, section, category = Bank:FillTab(tab, idsOf(places),
                Bank:LoadedFrom(tab))
            if placed then
                Bank:SetLoadedFrom(tab, places[1])
                local part = Macros.TAB_NAMES[tab] .. " " .. placed
                if rescued > 0 then
                    part = part .. " (" .. rescued .. " saved to " .. Bank.SectionName(section) .. " / "
                        .. (category or Bank.UNSORTED) .. ")"
                end
                parts[#parts + 1] = part
            end
            firstError = firstError or fillError
        end
    end
    character.loadout = name
    rememberPick(name)
    self.live, self.group, self.loggingIn = true, talentGroup(), false
    local seeded, known, restored, failed = false, nil, 0, {}
    if self:BarsOn() then
        seeded = self:SeedBars(name)
        known = copyEntries(awaitingOf(name))
        restored, failed = self:RestoreBars(name)
    end
    UI.busy = false
    -- What didn't go back (a macro made this very moment may not be ready
    -- for the cursor) is tried once more a moment later; the record isn't
    -- touched until then.
    if next(failed) then
        self.retry = { name = name, failed = failed, known = known }
        retryTimer.elapsed = 0
        retryTimer:Show()
    else
        setAwaiting(name, {})
        self.applying, self.frozen = false, false
    end
    local summary = "Loadout '" .. name .. "': " .. (#parts > 0 and table.concat(parts, ", ") or "nothing to load")
        .. "."
    if seeded then
        summary = summary .. " Its bars start from another " .. (UnitClass and UnitClass("player") or "character")
            .. "'s."
    end
    if restored > 0 then
        summary = summary .. " " .. restored .. (restored == 1 and " button" or " buttons") .. " put back."
    end
    local gearNote = self:PutOnGear(name)
    if gearNote then
        summary = summary .. " " .. gearNote
    end
    if firstError then
        summary = summary .. " " .. firstError
    end
    if UI.LoadoutApplied then
        UI:LoadoutApplied(name, summary, firstError)
    end
    changed()
    return true, summary
end

-- Applies the chosen loadout (login: always; a talent change: when it
-- differs). Reports in the chat, as it happens without a click.
function Loadouts:ApplyChosen(force)
    local name, why = self:Choose()
    if not name or (not force and name == Bank:Character().loadout) then
        return
    end
    local applied, summary = self:Apply(name)
    if applied or self.pending then
        local reason = why == "rule" and " (chosen by the talents)"
            or why == "picked" and " (chosen by the talents: of those that fit them, the one applied here last)" or ""
        addon:Print(summary .. (applied and reason or ""))
    end
    return true
end

--[[ Events ]]

local timer = CreateFrame("Frame")
timer:Hide()
Loadouts.timer = timer
timer:SetScript("OnUpdate", function(frame, delta)
    frame.elapsed = (frame.elapsed or 0) + delta
    if frame.elapsed < SETTLE_SECONDS then
        return
    end
    frame:Hide()
    Loadouts:Settled()
end)

-- The talent group and the points in each tree.
local function talentSignature()
    local group = GetActiveTalentGroup and GetActiveTalentGroup() or 1
    local parts = { group }
    for tab = 1, 3 do
        local points = GetTalentTabInfo and select(3, GetTalentTabInfo(tab, false, false, group)) or 0
        parts[#parts + 1] = points or 0
    end
    return table.concat(parts, ":")
end

local function arm()
    timer.elapsed = 0
    timer:Show()
end

-- The second try at the buttons that didn't go back (Apply).
retryTimer = CreateFrame("Frame")
retryTimer:Hide()
Loadouts.retryTimer = retryTimer
retryTimer:SetScript("OnUpdate", function(frame, delta)
    frame.elapsed = (frame.elapsed or 0) + delta
    if frame.elapsed < RETRY_SECONDS then
        return
    end
    frame:Hide()
    Loadouts:Retry()
end)

function Loadouts:Retry()
    local retry = self.retry
    self.retry = nil
    if retry and Bank:Character().loadout == retry.name and not addon:IsInCombat() then
        local restored, failed = self:RestoreBars(retry.name, retry.failed)
        -- (what was already waiting isn't news)
        local news, missed = {}, 0
        for slot, entry in pairs(failed) do
            if not (retry.known and sameEntry(retry.known[slot], entry)) then
                news[slot] = entry
                missed = missed + 1
            end
        end
        if restored > 0 or missed > 0 then
            addon:Print("Loadout '" .. retry.name .. "': " .. restored .. " more "
                .. (restored == 1 and "button" or "buttons") .. " put back"
                .. (missed > 0 and (", " .. missed .. " couldn't be yet: " .. describe(news)
                    .. "; each goes on its button once it can") or "") .. ".")
        end
        -- What was waiting and wasn't tried now (its button has something)
        -- is dropped when the button is recorded.
        local awaiting = copyEntries(awaitingOf(retry.name))
        for slot in pairs(retry.failed) do
            awaiting[slot] = nil
        end
        for slot, entry in pairs(failed) do
            awaiting[slot] = entry
        end
        setAwaiting(retry.name, awaiting)
    end
    self.applying, self.frozen = false, false
    self:SaveCurrentBars()
end

-- With ClassGeneralOn: a class without loadouts gets one named after it
-- ("Rogue", not "Default", which every class would show), loading two
-- empty categories of its section, "<Class> - General" into General and
-- "<Class> - Specific" into Character; marked `default`. A character of the
-- class with no login loadout uses it on login. -> the loadout's name when
-- one was made now.
function Loadouts:EnsureClassLoadout()
    if not (Macros.db and self:ClassGeneralOn()) then
        return nil
    end
    local loadouts, made = mine(), nil
    if not next(loadouts) then
        local section = playerClass()
        local className = Bank.SectionName(section)
        local places = {}
        for _, kind in ipairs({ "General", "Specific" }) do
            local category = className .. " - " .. kind
            local exists = false
            for _, name in ipairs(Bank:Categories(section)) do
                exists = exists or name == category
            end
            if not exists then
                Bank:CreateCategory(section, category)
            end
            places[#places + 1] = { section = section, category = category }
        end
        made = self:Save(className, { places[1] }, { places[2] })
        if made then
            loadouts[made].default = true
        end
    end
    local character = Bank:Character()
    if not (character.login and loadouts[character.login]) then
        for name, loadout in pairs(loadouts) do
            if type(loadout) == "table" and loadout.default then
                character.login = name
            end
        end
    end
    return made
end

-- The setting ticked: the class's loadout made and applied at once.
function Loadouts:ClassGeneralTicked()
    local made = self:EnsureClassLoadout()
    if made then
        local applied, summary = self:Apply(made)
        if applied or self.pending then
            addon:Print(summary)
        end
    end
    return made
end

function Loadouts:Initialize()
    self:EnsureClassLoadout()
    noteCharacter(Bank:Character())
    self.live, self.pending, self.atLogin, self.loggingIn = false, nil, true, true
    self.frozen, self.applying, self.retry, self.group = false, false, nil, nil
    arm()
end

-- PLAYER_TALENT_UPDATE, ACTIVE_TALENT_GROUP_CHANGED: wait for them to
-- settle; the buttons aren't recorded meanwhile.
function Loadouts:TalentsChanged()
    if Macros.db then
        self.frozen = true
        self.waiting = nil
        arm()
    end
end

function Loadouts:Settled()
    if self.atLogin then
        -- The talents may not have been readable yet when State first
        -- looked (State:RetryPlayerSpec).
        if playerSpec() == nil and addon.State and addon.State.RetryPlayerSpec then
            local categories = addon.State:RetryPlayerSpec()
            if categories then
                addon:HandleStateChange(categories)
            end
        end
        self.atLogin = false
        self.signature = talentSignature()
        self:ApplyChosen(true)
        if not self.pending then
            -- (applied, or nothing chosen; a pending one, when combat ends)
            self.loggingIn = false
        end
        if not self.pending and not self.applying then
            self.frozen = false
        end
        return
    end
    -- Mid-respec (no points in any tree): wait for the next change. The
    -- reset is noted, so learning the same talents again is a change (a
    -- reset, then the same hybrid, applied nothing).
    local signature = talentSignature()
    if playerSpec() == nil then
        self.signature = signature
        return
    end
    local talentsChanged, applied = signature ~= self.signature, false
    if talentsChanged then
        self.signature = signature
        applied = self:ApplyChosen(false)
    end
    -- Nothing (else) to apply: the buttons shown are the current
    -- loadout's again; after a real change, put back: a group switch shows the other group's, whose macros may
    -- have been taken out of the tabs (and so off every group's buttons)
    -- while another loadout was in; a respec empties the unlearned
    -- talents' buttons (Preparation's macro), which the record still has.
    if not self.pending and not self.applying then
        local group = talentGroup()
        self.group = group
        if talentsChanged and not applied and self.live then
            local name = Bank:Character().loadout
            self:PutBack(name)
            local gearNote = self:PutOnGear(name)
            if gearNote then
                addon:Print("Loadout '" .. name .. "': " .. gearNote)
            end
        end
        if not self.applying then
            self.frozen = false
            if talentsChanged then
                self:SaveCurrentBars()
            end
        end
    end
end

-- The current loadout's bars for the active group, without loading its
-- categories again (a talent change that keeps the loadout): only into the
-- buttons that are empty now. What is on a button was put there since (a
-- talent just learned, dragged out while the talents settled: not
-- recorded yet) or was there all along; the bars are saved after.
function Loadouts:PutBack(name)
    if not self:Get(name) or not self:BarsOn() then
        return
    end
    self.applying = true
    local seeded = self:SeedBars(name)
    local only
    if not seeded then
        only = {}
        for slot, entry in pairs(barsOf(name) or {}) do
            if entry ~= false and not GetActionInfo(slot) then
                only[slot] = entry
            end
        end
    end
    local known = copyEntries(awaitingOf(name))
    local restored, failed = self:RestoreBars(name, only)
    if next(failed) then
        self.retry = { name = name, failed = failed, known = known }
        retryTimer.elapsed = 0
        retryTimer:Show()
    else
        if seeded then
            setAwaiting(name, {})
        end
        self.applying = false
    end
    if restored > 0 then
        addon:Print("Loadout '" .. name .. "': " .. restored .. (restored == 1 and " button" or " buttons")
            .. " put back (talent group " .. talentGroup() .. ").")
    end
end

function Loadouts:CombatEnded()
    if self.pending and Macros.db then
        local applied, summary = self:Apply(self.pending)
        if applied then
            addon:Print(summary)
        end
    elseif self.gearPending and Macros.db then
        if self.gearPending == Bank:Character().loadout then
            self:PutOnGear(self.gearPending)
        end
        self.gearPending = nil
    end
    if self.fillKinds then
        fillTimer.elapsed = 0
        fillTimer:Show()
    end
end

--[[ What was waiting ]]

-- SPELLS_CHANGED ("spell": a spell learned; anything but items is tried)
-- and BAG_UPDATE ("item"): what was waiting may go on its button now, a
-- moment later (a loot spree is one try).
function Loadouts:Available(kind)
    if not Macros.db or not self:BarsOn() then
        return
    end
    local name = Bank:Character().loadout
    local awaiting = name and awaitingOf(name)
    if not (awaiting and next(awaiting)) then
        return
    end
    self.fillKinds = self.fillKinds or {}
    self.fillKinds[kind] = true
    fillTimer.elapsed = 0
    fillTimer:Show()
end

-- Puts on their buttons what was waiting and now can be: only into a
-- button still empty (one that holds something drops its entry).
function Loadouts:FillAwaiting()
    local kinds = self.fillKinds
    local name = Bank:Character().loadout
    local loadout = self:Get(name)
    local awaiting = loadout and awaitingOf(name)
    if not (kinds and awaiting and self.live) or self.frozen or self.applying or talentGroup() ~= self.group
        or addon:IsInCombat() or not (GetActionInfo and PlaceAction) then
        return -- (combat: tried again when it ends)
    end
    self.fillKinds = nil
    local wanted, byName = macrosOf(loadout)
    local bars = barsOf(name, true)
    local spells, placed = nil, {}
    local sound = quiet()
    if ClearCursor then
        ClearCursor()
    end
    for slot, entry in pairs(awaiting) do
        local isItem = type(entry) == "table" and entry[1] == "item"
        if GetActionInfo(slot) then
            awaiting[slot] = nil
        elseif kinds[isItem and "item" or "spell"] then
            if not isItem and not spells then
                spells = spellbook()
            end
            local kind = pickUp(entry, wanted, spells or {})
            if kind and (not GetCursorInfo or GetCursorInfo() == kind) then
                PlaceAction(slot)
                bars[slot] = entry
                awaiting[slot] = nil
                placed[slot] = entry
            end
            if ClearCursor then
                ClearCursor()
            end
        end
    end
    loud(sound)
    if next(placed) then
        addon:Print("Loadout '" .. name .. "': " .. describe(placed) .. " put on " .. (next(placed, next(placed))
            and "their buttons" or "its button") .. ".")
    end
end

fillTimer = CreateFrame("Frame")
fillTimer:Hide()
Loadouts.fillTimer = fillTimer
fillTimer:SetScript("OnUpdate", function(frame, delta)
    frame.elapsed = (frame.elapsed or 0) + delta
    if frame.elapsed < FILL_SECONDS then
        return
    end
    frame:Hide()
    Loadouts:FillAwaiting()
end)

-- PLAYER_LOGOUT (also a /reload): the current loadout's bars.
function Loadouts:Logout()
    if Macros.db then
        self:SaveCurrentBars()
    end
end
