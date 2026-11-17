local addon = WMacroCompiler
local Macros = addon.Macros

--[[-----------------------------------------------------------------------------
Bank (addon.Bank): the store of plain macros (bank-plan.md, phase 3). No
frames; the window is Bank/UI.lua.

A bank macro is a record in QuintessenceBankDB.macros[id]:
  { name, icon (a texture path; nil: the question mark), text,
    section ("GENERAL" or a class), category (nil: Unsorted),
    button (true once its text was ever over 255: QMB<id> exists) }
Ids come from the same run as the long macros' (Macros.NewId), so QMB<id>
is one button whoever owns the id. Names may repeat (a "Kick" for PvP and
one for PvE). Categories are one level, per section:
QuintessenceBankDB.categories[section][name] = { collapsed }.

Linked slots. A slot is linked to a bank macro when it holds what the bank
macro would put there: the same name and body (trailing blanks aside), or,
for a long one, its "/click QMB<id>". Nothing is stored for the link, so it
holds on every character and survives the slots moving; a slot changed
outside the bank simply stops being linked. Bank:Update writes the record
and every linked slot in sight, so the two stay the same.

Identical bank macros (the same name and text in two categories) share
their slots: such a slot is linked to all of them, so a loadout of either
finds it in place. Where one must be named (the editor, a tooltip, the
bars a loadout remembers), LinkOf picks the one from the categories the
slot's tab is filled from (its loadout's, else Bank:LoadedFrom), else the
first one made.

  Bank.SECTIONS, Bank.SectionName(section), Bank.UNSORTED
  Bank:Get(id)
  Bank:Add(section, category, name, icon, text) -> id, or nil and the error
  Bank:Update(id, name, icon, text) -> true, or nil and the error. icon nil:
                              the icon stays (the record's and the slots').
  Bank:Delete(id), Bank:Move(id, section, category)
  Bank:SlotBody(id)           -> what a slot holds for it
  Bank:LinksOf(macro)         -> the ids a slot (Macros.Get) is linked to
  Bank:LinkOf(macro)          -> one of them: see Links
  Bank:SlotsOf(id)            -> the linked slots' indexes, both tabs
  Bank:SaveSlot(index, section, category) -> id, "saved" | "updated" |
                              "linked" (it already was); or nil, the error
  Bank:HeldIn(macro, section, category) -> the id of the bank macro there
                              that the slot already is, or nil
  Bank:SaveCopy(index, section, category) -> as SaveSlot, but a slot linked
                              to a bank macro elsewhere is copied there
                              ("linked": it already is there). When the
                              tab prefers the copy (see Links), it takes
                              the keys and the slot.
  Bank:SaveTab(tab, section, category) -> how many were saved or updated,
                              nil, how many were already there; or nil,
                              the error. Each slot as SaveCopy.
  Bank:Load(id, tab)          -> the slot's index; or nil and the error.
                              Into the tab's macro of that name, else a
                              free slot.
  Bank:FillTab(tab, ids, rescue) -> placed, the first error, rescued, the
                              rescue's section and category. The tab then
                              holds exactly those bank macros; see below.
  Bank:LoadCategory(section, category, tab) -> as FillTab: the tab holds
                              the category, and remembers it (LoadedFrom)
  Bank:CategoryIds(section, category) -> its macros' ids, in list order
  Bank:LoadedFrom(tab)        -> { section, category } the tab was last
                              filled from, or nil. General's is
                              account-wide, Character's per character.
  Bank:SetLoadedFrom(tab, place)
  Bank.CharacterKey(), Bank:Character() -> this character's table in
                              QuintessenceBankDB.characters["Name-Realm"]
  Bank:List(section, filter, expandAll, inText) -> rows for the window, in order:
                              { category = name or false (Unsorted), count,
                              collapsed } and { id, record }
  Bank:Categories(section)    -> the names, sorted
  Bank:MoveCategory(section, name, toSection) -> true, or nil and the
                              error: the category and its macros go to
                              another section (loadouts follow)
  Bank:CreateCategory / RenameCategory / DeleteCategory /
  SetCategoryCollapsed(section, name ...): as the compiler's. Deleting a
  category never deletes macros: they become Unsorted.
  Bank:ImportMacroBank(data)  -> macros, categories added (MacroBankDB)
  Bank.FitName(name)          -> the name cut to a macro name's length
  Bank:FindCategory(section, name) -> the category of that name, any case
                              (and cut as an import cuts it), or nil
  Bank.SectionFor(name)       -> the section a category name mentions

Filling a tab (a whole category's load, a loadout: Loadouts.lua) replaces
what it holds, and never loses a macro: a slot that isn't linked to the
bank (made outside it, or a banked one edited outside it) is saved first,
into the category the tab was last filled from (its namesake there is
updated), Unsorted when nothing is recorded. A slot linked to the bank is
just removed: the bank has it. Slots already holding one of the macros
stay as they are.
-------------------------------------------------------------------------------]]
local Bank = {}
addon.Bank = Bank

local COMBAT_ERROR = "Macros can't be changed in combat."
local CATEGORY_MAX = 40

Bank.UNSORTED = "Unsorted"
Bank.SECTIONS = { "GENERAL", "DEATHKNIGHT", "DRUID", "HUNTER", "MAGE", "PALADIN", "PRIEST", "ROGUE", "SHAMAN",
    "WARLOCK", "WARRIOR" }
local CLASS_NAMES = {
    DEATHKNIGHT = "Death Knight", DRUID = "Druid", HUNTER = "Hunter", MAGE = "Mage", PALADIN = "Paladin",
    PRIEST = "Priest", ROGUE = "Rogue", SHAMAN = "Shaman", WARLOCK = "Warlock", WARRIOR = "Warrior",
}

function Bank.SectionName(section)
    if section == "GENERAL" then
        return "General"
    end
    return LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[section] or CLASS_NAMES[section] or section
end

local function isSection(section)
    return section == "GENERAL" or CLASS_NAMES[section] ~= nil
end

local function rtrim(text)
    return (text:gsub("%s+$", ""))
end

local function db()
    return Macros.db
end

-- Any change to the store: the link index is stale, the window's list too.
local function changed()
    Bank.index = nil
    Bank.generation = (Bank.generation or 0) + 1
    if addon.BankUI and addon.BankUI.BankChanged then
        addon.BankUI:BankChanged()
    end
end

function Bank:Get(id)
    return id and db().macros[id] or nil
end

--[[ Categories ]]

function Bank:Categories(section)
    local names = {}
    for name in pairs(db().categories[section] or {}) do
        names[#names + 1] = name
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function Bank:ValidateCategoryName(section, name)
    if type(name) ~= "string" then
        return nil, "Category name is required."
    end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        return nil, "Category name is required."
    end
    if #name > CATEGORY_MAX then
        return nil, "Category name is too long."
    end
    if name:upper() == Bank.UNSORTED:upper() then
        return nil, "That category name is reserved."
    end
    for existing in pairs(db().categories[section] or {}) do
        if existing:upper() == name:upper() then
            return nil, "A category with that name already exists."
        end
    end
    return name
end

function Bank:CreateCategory(section, name)
    local validName, nameError = self:ValidateCategoryName(section, name)
    if not validName then
        return nil, nameError
    end
    db().categories[section] = db().categories[section] or {}
    db().categories[section][validName] = { collapsed = false }
    changed()
    return validName
end

function Bank:RenameCategory(section, oldName, newName)
    local categories = db().categories[section]
    if not categories or not categories[oldName] then
        return nil, "Category not found."
    end
    if oldName == newName then
        return oldName
    end
    local validName, nameError = self:ValidateCategoryName(section, newName)
    if not validName then
        return nil, nameError
    end
    categories[validName] = categories[oldName]
    categories[oldName] = nil
    for _, record in pairs(db().macros) do
        if record.section == section and record.category == oldName then
            record.category = validName
        end
    end
    for _, place in ipairs(Bank:Places()) do
        if place.section == section and place.category == oldName then
            place.category = validName
        end
    end
    changed()
    return validName
end

function Bank:DeleteCategory(section, name)
    local categories = db().categories[section]
    if not categories or not categories[name] then
        return nil, "Category not found."
    end
    categories[name] = nil
    for _, record in pairs(db().macros) do
        if record.section == section and record.category == name then
            record.category = nil
        end
    end
    -- A loadout no longer loads it; a tab's record now means its section's
    -- Unsorted, where its macros went.
    for _, loadout in ipairs(Bank:AllLoadouts()) do
        for _, tab in ipairs(Macros.TABS) do
            local places = loadout[tab] or {}
            for index = #places, 1, -1 do
                if places[index].section == section and places[index].category == name then
                    table.remove(places, index)
                end
            end
        end
    end
    for _, place in ipairs(Bank:Places()) do
        if place.section == section and place.category == name then
            place.category = nil
        end
    end
    changed()
    return true
end

function Bank:MoveCategory(section, name, toSection)
    local categories = db().categories[section]
    if not categories or not categories[name] then
        return nil, "Category not found."
    end
    if not isSection(toSection) then
        return nil, "Unknown section."
    end
    if toSection == section then
        return true
    end
    if self:FindCategory(toSection, name) then
        return nil, Bank.SectionName(toSection) .. " already has a category named '" .. name .. "'."
    end
    db().categories[toSection] = db().categories[toSection] or {}
    db().categories[toSection][name] = categories[name]
    categories[name] = nil
    for id, record in pairs(db().macros) do
        if record.section == section and record.category == name then
            record.section = toSection
            if addon.Keys then
                addon.Keys:Rehome("macro", id, id, toSection ~= "GENERAL" and toSection or nil)
            end
        end
    end
    for _, place in ipairs(Bank:Places()) do
        if place.section == section and place.category == name then
            place.section = toSection
        end
    end
    changed()
    return true
end

function Bank:SetCategoryCollapsed(section, name, collapsed)
    local categories = db().categories[section]
    if not categories or not categories[name] then
        return nil, "Category not found."
    end
    categories[name].collapsed = collapsed and true or false
    changed()
    return true
end

function Bank:FindCategory(section, name)
    local wanted = name:sub(1, CATEGORY_MAX):upper()
    for existing in pairs(db().categories[section] or {}) do
        if existing:upper() == wanted then
            return existing
        end
    end
    return nil
end

-- A record's category when it still exists, else nil (Unsorted).
local function categoryOf(record)
    local categories = db().categories[record.section]
    return record.category and categories and categories[record.category] and record.category or nil
end

--[[ Characters and places ]]

-- A place is { section, category } (category nil: Unsorted): where a tab
-- was filled from, or what a loadout fills it with.

function Bank.CharacterKey()
    local name = UnitName and UnitName("player") or nil
    local realm = GetRealmName and GetRealmName() or nil
    return (name or "?") .. "-" .. (realm or "?")
end

function Bank:Character()
    local characters = db().characters
    local key = Bank.CharacterKey()
    characters[key] = characters[key] or {}
    local character = characters[key]
    -- (loadouts are per class: whose references a rename may touch)
    character.class = character.class or select(2, UnitClass("player"))
    return character
end

-- Every class's loadouts (QuintessenceBankDB.loadouts[class][name]).
function Bank:AllLoadouts()
    local all = {}
    for _, byName in pairs(db().loadouts) do
        for _, loadout in pairs(type(byName) == "table" and byName or {}) do
            if type(loadout) == "table" then
                all[#all + 1] = loadout
            end
        end
    end
    return all
end

function Bank:LoadedFrom(tab)
    if tab == "character" then
        return (self:Character().loadedFrom or {}).character
    end
    return db().loadedFrom.general
end

function Bank:SetLoadedFrom(tab, place)
    place = place and { section = place.section, category = place.category } or nil
    if tab == "character" then
        local character = self:Character()
        character.loadedFrom = character.loadedFrom or {}
        character.loadedFrom.character = place
    else
        db().loadedFrom.general = place
    end
end

-- Every stored place (renaming or deleting a category updates them).
function Bank:Places()
    local places = {}
    local function add(place)
        if type(place) == "table" then
            places[#places + 1] = place
        end
    end
    add(db().loadedFrom.general)
    for _, character in pairs(db().characters) do
        add((character.loadedFrom or {}).character)
    end
    for _, loadout in ipairs(Bank:AllLoadouts()) do
        for _, tab in ipairs(Macros.TABS) do
            for _, place in ipairs(loadout[tab] or {}) do
                add(place)
            end
        end
    end
    return places
end

--[[ Records ]]

-- section / category for a new or moved record; the category must exist.
local function checkPlace(section, category)
    if not isSection(section) then
        return nil, "Unknown section."
    end
    if category and not (db().categories[section] and db().categories[section][category]) then
        return nil, "Category not found."
    end
    return true
end

function Bank:Add(section, category, name, icon, text)
    text = text or ""
    local placed, placeError = checkPlace(section, category)
    if not placed then
        return nil, placeError
    end
    local valid, checkError = Macros:Check(name, text)
    if not valid then
        return nil, checkError
    end
    local id = Macros.NewId()
    local record = { name = name, icon = icon, text = text, section = section, category = category }
    db().macros[id] = record
    if #text > Macros.BODY_MAX then
        record.button = true
        Macros.ApplyButton(id)
    end
    changed()
    return id
end

function Bank:Move(id, section, category)
    local record = self:Get(id)
    if not record then
        return nil, "That macro is not in the bank."
    end
    local placed, placeError = checkPlace(section, category)
    if not placed then
        return nil, placeError
    end
    local moved = record.section ~= section
    record.section, record.category = section, category
    if moved and addon.Keys then
        addon.Keys:Rehome("macro", id, id, section ~= "GENERAL" and section or nil)
    end
    changed()
    return true
end

local function slotBody(id, record)
    if #record.text > Macros.BODY_MAX then
        return Macros.SlotBody(id, record.text)
    end
    return record.text
end

function Bank:SlotBody(id)
    local record = self:Get(id)
    return record and slotBody(id, record) or nil
end

--[[ Links ]]

local function linkKey(name, body)
    return name .. "\n" .. rtrim(body)
end

-- name + body -> { id... } (lowest first), for the records a slot can hold
-- as they are (the long ones are found by their id).
local NO_LINKS = {}

local function linkIndex()
    if not Bank.index then
        local index = {}
        for id, record in pairs(db().macros) do
            if #record.text <= Macros.BODY_MAX then
                local key = linkKey(record.name, record.text)
                index[key] = index[key] or {}
                table.insert(index[key], id)
            end
        end
        for _, ids in pairs(index) do
            table.sort(ids)
        end
        Bank.index = index
    end
    return Bank.index
end

function Bank:LinksOf(macro)
    if not macro then
        return NO_LINKS
    end
    if macro.long then
        return db().macros[macro.long] and { macro.long } or NO_LINKS
    end
    return linkIndex()[linkKey(macro.name, macro.body)] or NO_LINKS
end

-- The places a tab is filled from: its loadout's, and its last fill.
local function tabPlaces(tab)
    local places = {}
    local Loadouts = addon.Loadouts
    local loadout = Loadouts and Loadouts:Get(Bank:Character().loadout)
    for _, place in ipairs(loadout and loadout[tab] or {}) do
        places[#places + 1] = place
    end
    places[#places + 1] = Bank:LoadedFrom(tab)
    return places
end

-- Of identical bank macros, the one from the places the tab is filled
-- from, else the first.
local function preferred(tab, ids)
    if #ids < 2 then
        return ids[1]
    end
    for _, place in ipairs(tabPlaces(tab)) do
        for _, id in ipairs(ids) do
            local record = db().macros[id]
            if record.section == place.section and categoryOf(record) == place.category then
                return id
            end
        end
    end
    return ids[1]
end

function Bank:LinkOf(macro)
    return preferred(macro and macro.tab, self:LinksOf(macro))
end

local function linksTo(ids, id)
    for _, linked in ipairs(ids) do
        if linked == id then
            return true
        end
    end
    return false
end

function Bank:SlotsOf(id)
    local slots = {}
    for _, tab in ipairs(Macros.TABS) do
        for _, macro in ipairs(Macros.List(tab)) do
            if linksTo(self:LinksOf(macro), id) then
                slots[#slots + 1] = macro.index
            end
        end
    end
    return slots
end

--[[ Changes that reach the slots ]]

function Bank:Update(id, name, icon, text)
    text = text or ""
    local record = self:Get(id)
    if not record then
        return nil, "That macro is not in the bank."
    end
    local valid, checkError = Macros:Check(name, text)
    if not valid then
        return nil, checkError
    end
    -- The linked slots, by what they hold now: writing one moves the others.
    local linked = {}
    for _, index in ipairs(self:SlotsOf(id)) do
        local macro = Macros.Get(index)
        linked[#linked + 1] = { tab = macro.tab, name = macro.name, body = macro.body }
    end
    if #linked > 0 and addon:IsInCombat() then
        return nil, COMBAT_ERROR
    end
    record.name, record.text = name, text
    if icon then
        record.icon = icon
    end
    if #text > Macros.BODY_MAX then
        record.button = true
    end
    if record.button or Macros.buttons[id] then -- (a key's: Keys.lua)
        Macros.ApplyButton(id)
    end
    local body = slotBody(id, record)
    for _, slot in ipairs(linked) do
        local index = Macros.Find(slot.tab, slot.name, slot.body)
        if index then
            Macros.Write(index, name, icon, body)
        end
    end
    changed()
    return true
end

function Bank:Delete(id)
    local record = self:Get(id)
    if not record then
        return nil, "That macro is not in the bank."
    end
    db().macros[id] = nil
    if record.button then
        -- A slot in sight that clicks its button keeps working: the text
        -- goes back to the plain long macros.
        local running = false
        for _, tab in ipairs(Macros.TABS) do
            for _, macro in ipairs(Macros.List(tab)) do
                if Macros.LongId(macro.body) == id then
                    running = true
                end
            end
        end
        if running then
            db().long[id] = { text = record.text }
        elseif not addon:IsInCombat() then
            Macros.RemoveButton(id)
        end
    end
    if addon.Keys then
        addon.Keys:MacroDeleted(id)
    end
    changed()
    return true
end

-- Every macro of `section`'s Unsorted out of the bank -> how many. Slots that hold them keep their macros, as with one.
function Bank:UnsortedIds(section)
    local ids = {}
    for id, record in pairs(db().macros) do
        if record.section == section and not categoryOf(record) then
            ids[#ids + 1] = id
        end
    end
    return ids
end

function Bank:DeleteUnsorted(section)
    local ids = self:UnsortedIds(section)
    for _, id in ipairs(ids) do
        self:Delete(id)
    end
    return #ids
end

-- noUpdate: ids not to update (a new record instead): FillTab's, so two
-- stray macros of one name don't end up as one.
function Bank:SaveSlot(index, section, category, noUpdate)
    local macro = Macros.Get(index)
    if not macro then
        return nil, "That macro no longer exists."
    end
    local linked = self:LinkOf(macro)
    if linked then
        return linked, "linked"
    end
    local placed, placeError = checkPlace(section, category)
    if not placed then
        return nil, placeError
    end
    -- The bank's macro of that name in that category is updated; else a
    -- new one is added.
    local existing
    for id, record in pairs(db().macros) do
        if record.section == section and categoryOf(record) == category and record.name == macro.name
            and not (noUpdate and noUpdate[id]) and (not existing or id < existing) then
            existing = id
        end
    end
    local ownLong = macro.long -- a plain long macro's id (not the bank's: it would be linked)
    if existing then
        if ownLong and addon:IsInCombat() then
            return nil, COMBAT_ERROR -- its slot has to click the bank's button
        end
        local record = db().macros[existing]
        record.text, record.icon = macro.text, macro.icon
        if #record.text > Macros.BODY_MAX then
            record.button = true
        end
        if record.button then
            Macros.ApplyButton(existing)
        end
        if ownLong then
            Macros.Write(index, macro.name, nil, slotBody(existing, record))
            db().long[ownLong] = nil
            Macros.RemoveButton(ownLong)
        end
        changed()
        return existing, "updated"
    end
    local id = ownLong or Macros.NewId()
    db().macros[id] = { name = macro.name, icon = macro.icon, text = macro.text, section = section,
        category = category, button = ownLong and true or nil }
    if ownLong then
        db().long[ownLong] = nil -- the bank owns the id (and its button) now
    end
    changed()
    return id, "saved"
end

-- Whether new macros (the bank window's, the Compiler's Make Macro) go
-- into the bank by themselves: opt-in (the settings' Bank tab).
function Bank:AutoSave()
    return Macros.db ~= nil and Macros.db.settings.autoBank == true
end

-- A slot into the category its tab was last filled from (the Compiler's
-- Make Macro) -> id, result, place; nil when nothing was loaded there.
function Bank:SaveToLoaded(index)
    if not db() then
        return nil
    end
    local place = self:LoadedFrom(Macros.TabOf(index))
    if not place then
        return nil
    end
    local id, result = self:SaveSlot(index, place.section, place.category)
    return id, result, place
end

-- The bank macro in that place that a slot already is: one it is linked
-- to, or one of its name and text (a long slot links to one record only).
function Bank:HeldIn(macro, section, category)
    for _, id in ipairs(self:LinksOf(macro)) do
        local record = db().macros[id]
        if record.section == section and categoryOf(record) == category then
            return id
        end
    end
    for id, record in pairs(db().macros) do
        if record.section == section and categoryOf(record) == category and record.name == macro.name
            and record.text == macro.text then
            return id
        end
    end
    return nil
end

-- A bank macro copied into another place: its namesake there is updated,
-- else a new one is added (a slot linked to it is then linked to both).
local function copyInto(id, section, category)
    local source = db().macros[id]
    local existing
    for otherId, record in pairs(db().macros) do
        if record.section == section and categoryOf(record) == category and record.name == source.name
            and (not existing or otherId < existing) then
            existing = otherId
        end
    end
    if not existing then
        local newId, addError = Bank:Add(section, category, source.name, source.icon, source.text)
        if not newId then
            return nil, addError
        end
        return newId, "saved"
    end
    local record = db().macros[existing]
    record.text, record.icon = source.text, source.icon
    if #record.text > Macros.BODY_MAX then
        record.button = true
    end
    if record.button then
        Macros.ApplyButton(existing)
    end
    changed()
    return existing, "updated"
end

function Bank:SaveCopy(index, section, category)
    local id, result = self:SaveSlot(index, section, category)
    if result ~= "linked" then
        return id, result
    end
    local macro = Macros.Get(index)
    local held = self:HeldIn(macro, section, category)
    if held then
        return held, "linked"
    end
    if macro.long and addon:IsInCombat() then
        return nil, COMBAT_ERROR -- its slot may have to click the copy's button
    end
    local copied, copyResult = copyInto(id, section, category)
    if not copied then
        return nil, copyResult
    end
    -- The copy the tab prefers takes over: the keys, and a long slot (it
    -- clicks one bank macro's button) clicks the copy's.
    if preferred(macro.tab, { id, copied }) == copied then
        if macro.long then
            local record = db().macros[copied]
            Macros.Write(index, macro.name, nil, slotBody(copied, record))
        end
        if addon.Keys then
            addon.Keys:Hand("macro", id, copied)
        end
    end
    return copied, copyResult
end

function Bank:SaveTab(tab, section, category)
    local placed, placeError = checkPlace(section, category)
    if not placed then
        return nil, placeError
    end
    -- By what the slots hold: saving a long one may rewrite (and move) it.
    local saved, already = 0, 0
    for _, macro in ipairs(Macros.List(tab)) do
        local index = Macros.Find(tab, macro.name, macro.body, macro.index)
        local _, result = self:SaveCopy(index, section, category)
        if result == "saved" or result == "updated" then
            saved = saved + 1
        elseif result == "linked" then
            already = already + 1
        end
    end
    return saved, nil, already
end

-- A new slot for the record, whatever the tab holds.
local function createSlot(id, record, tab)
    local used, max = Macros.Count(tab)
    if used >= max then
        return nil, "No free " .. Macros.TAB_NAMES[tab]:lower() .. " macro slots."
    end
    local body = slotBody(id, record)
    local icon = record.icon or Macros.DEFAULT_ICON
    local index = CreateMacro(record.name, Macros.IconIndex(icon), body, tab == "character" and 1 or nil)
    if not index then
        return nil, "Could not create the macro."
    end
    return Macros.Find(tab, record.name, body, index) or index
end

function Bank:Load(id, tab)
    local record = self:Get(id)
    if not record then
        return nil, "That macro is not in the bank."
    end
    if addon:IsInCombat() then
        return nil, COMBAT_ERROR
    end
    for _, macro in ipairs(Macros.List(tab)) do
        if macro.name == record.name then
            return Macros.Write(macro.index, record.name, record.icon or Macros.DEFAULT_ICON, slotBody(id, record))
        end
    end
    return createSlot(id, record, tab)
end

-- Where FillTab saves a tab's stray macros: the place given while its
-- section is known (its category, while it exists), else Unsorted in
-- General (the General tab) or the player's class (the Character tab).
local function rescuePlace(tab, place)
    if place and isSection(place.section) then
        local categories = db().categories[place.section]
        local category = place.category
        if category and not (categories and categories[category]) then
            category = nil
        end
        return place.section, category
    end
    local _, class = UnitClass("player")
    if tab == "character" and isSection(class) then
        return class, nil
    end
    return "GENERAL", nil
end

function Bank:FillTab(tab, ids, rescue)
    if addon:IsInCombat() then
        return nil, COMBAT_ERROR, 0
    end
    local wanted = {}
    for _, id in ipairs(ids) do
        wanted[id] = self:Get(id) and true or nil
    end
    -- Strays are saved first. One that can't be leaves everything as it was.
    local section, category = rescuePlace(tab, rescue)
    local rescued, touched = 0, {}
    for _, macro in ipairs(Macros.List(tab)) do
        if not self:LinkOf(macro) then
            local index = Macros.Find(tab, macro.name, macro.body, macro.index)
            local id, result = self:SaveSlot(index, section, category, touched)
            if not id then
                return nil, result, rescued, section, category
            end
            touched[id] = true
            rescued = rescued + 1
        end
    end
    -- What isn't wanted (or is there twice) goes. A slot shared by
    -- identical macros stays for the one of them that is wanted.
    local kept = {}
    for _, macro in ipairs(Macros.List(tab)) do
        local ids, keep = self:LinksOf(macro), nil
        for _, id in ipairs(ids) do
            if wanted[id] and not kept[id] then
                keep = id
                break
            end
        end
        if keep then
            kept[keep] = true
        elseif #ids > 0 then
            Macros:Delete(Macros.Find(tab, macro.name, macro.body, macro.index))
        end
    end
    local placed, firstError = 0, nil
    for _, id in ipairs(ids) do
        if kept[id] then
            placed = placed + 1
        elseif wanted[id] then
            local index, loadError = createSlot(id, self:Get(id), tab)
            if index then
                placed = placed + 1
                kept[id] = true
            else
                firstError = firstError or loadError
            end
        end
    end
    return placed, firstError, rescued, section, category
end

function Bank:CategoryIds(section, category)
    local ids = {}
    for _, row in ipairs(self:List(section, "", true)) do
        if row.id and categoryOf(row.record) == category then
            ids[#ids + 1] = row.id
        end
    end
    return ids
end

function Bank:LoadCategory(section, category, tab)
    local placed, firstError, rescued, rescueSection, rescueCategory = self:FillTab(tab,
        self:CategoryIds(section, category), self:LoadedFrom(tab))
    if placed then
        self:SetLoadedFrom(tab, { section = section, category = category })
    end
    return placed, firstError, rescued, rescueSection, rescueCategory
end

--[[ The list ]]

local function byName(a, b)
    local nameA, nameB = a.record.name:lower(), b.record.name:lower()
    if nameA ~= nameB then
        return nameA < nameB
    end
    return a.id < b.id
end

-- filter: a part of the name, any case. While searching, categories with
-- no match are left out and the others are open. expandAll: collapsed
-- categories list their macros too.
-- A macro's name, or with inText its text too, holds the filter (plain
-- text, any case).
function Bank.Matches(record, filter, inText)
    filter = (filter or ""):lower()
    return filter == "" or record.name:lower():find(filter, 1, true) ~= nil
        or (inText and (record.text or ""):lower():find(filter, 1, true) ~= nil)
end

function Bank:List(section, filter, expandAll, inText)
    filter = (filter or ""):lower()
    local searching = filter ~= ""
    local members, unsorted = {}, {}
    for id, record in pairs(db().macros) do
        if record.section == section and Bank.Matches(record, filter, inText) then
            local category = categoryOf(record)
            local list = unsorted
            if category then
                members[category] = members[category] or {}
                list = members[category]
            end
            list[#list + 1] = { id = id, record = record }
        end
    end
    local rows = {}
    local function addMacros(list)
        table.sort(list, byName)
        for _, row in ipairs(list) do
            rows[#rows + 1] = row
        end
    end
    local names = self:Categories(section)
    for _, name in ipairs(names) do
        local list = members[name] or {}
        if not searching or #list > 0 then
            local collapsed = db().categories[section][name].collapsed and not searching and not expandAll
            rows[#rows + 1] = { category = name, count = #list, collapsed = collapsed and true or false,
                forced = searching }
            if not collapsed then
                addMacros(list)
            end
        end
    end
    if #unsorted > 0 then
        if #names > 0 then
            rows[#rows + 1] = { category = false, count = #unsorted, collapsed = false }
        end
        addMacros(unsorted)
    end
    return rows
end

-- The first `count` characters of `text` (UTF-8).
local function firstCharacters(text, count)
    local position = 1
    for _ = 1, count do
        if position > #text then
            break
        end
        local byte = text:byte(position)
        position = position + (byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1)
    end
    return text:sub(1, position - 1)
end

-- `name`, or the first of "name 2", "name 3"... that no macro of `section`
-- has (the name cut to leave room), as a received template gets "_2".
function Bank:FreeName(section, name)
    local taken = {}
    for _, record in pairs(db().macros) do
        if record.section == section then
            taken[record.name:lower()] = true
        end
    end
    if not taken[name:lower()] then
        return name
    end
    for number = 2, 999 do
        local suffix = " " .. number
        local base = firstCharacters(name, Macros.NAME_MAX - #suffix):gsub("%s+$", "")
        local candidate = base .. suffix
        if not taken[candidate:lower()] then
            return candidate
        end
    end
    return name
end

--[[ MacroBank ]]

-- "Rogue PvP - General" -> ROGUE; no class in the name: GENERAL.
function Bank.SectionFor(categoryName)
    local lowered = " " .. categoryName:lower() .. " "
    for section, className in pairs(CLASS_NAMES) do
        if lowered:find("%f[%a]" .. className:lower() .. "%f[%A]") then
            return section
        end
    end
    return "GENERAL"
end

-- A macro name is at most 16 characters; cut at a character's start.
local function fitName(name)
    local count, position = 0, 1
    while position <= #name do
        local byte = name:byte(position)
        local length = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1
        if count == Macros.NAME_MAX then
            return name:sub(1, position - 1)
        end
        count, position = count + 1, position + length
    end
    return name
end
Bank.FitName = fitName

-- MacroBank's store (MacroBankDB.global.Macros): { name, { { description,
-- name, icon, body }... }, { sub-categories } } per category. Nested ones
-- become "A / B". Bodies lose their trailing blank lines. A macro already
-- in the bank (same place, name and text) is skipped, so importing twice
-- adds nothing. Returns macros added, categories added.
function Bank:ImportMacroBank(data)
    local store = type(data) == "table" and data.global and data.global.Macros
    if type(store) ~= "table" then
        return nil, "MacroBank's data was not found."
    end
    local macros, categories = 0, 0
    local function categoryNamed(section, name)
        local existing = Bank:FindCategory(section, name)
        if existing then
            return existing
        end
        name = name:sub(1, CATEGORY_MAX)
        if name:upper() == Bank.UNSORTED:upper() then
            return nil
        end
        db().categories[section] = db().categories[section] or {}
        db().categories[section][name] = { collapsed = true }
        categories = categories + 1
        return name
    end
    local function import(entry, prefix)
        if type(entry) ~= "table" or type(entry[1]) ~= "string" then
            return
        end
        local name = prefix .. entry[1]
        local section = Bank.SectionFor(name)
        local category
        for _, macro in ipairs(type(entry[2]) == "table" and entry[2] or {}) do
            local macroName, icon, body = macro[2], macro[3], macro[4]
            if type(macroName) == "string" and macroName ~= "" and type(body) == "string" then
                category = category or categoryNamed(section, name)
                macroName, body = fitName(macroName), rtrim(body)
                if type(icon) == "number" then
                    icon = GetMacroIconInfo and GetMacroIconInfo(icon) or nil
                elseif type(icon) ~= "string" then
                    icon = nil
                end
                local known = false
                for _, record in pairs(db().macros) do
                    if record.section == section and record.category == category and record.name == macroName
                        and record.text == body then
                        known = true
                        break
                    end
                end
                if not known and Macros:Check(macroName, body) then
                    db().macros[Macros.NewId()] = { name = macroName, icon = icon, text = body, section = section,
                        category = category, button = #body > Macros.BODY_MAX or nil }
                    macros = macros + 1
                end
            end
        end
        for _, sub in ipairs(type(entry[3]) == "table" and entry[3] or {}) do
            import(sub, name .. " / ")
        end
    end
    for _, entry in ipairs(store) do
        import(entry, "")
    end
    db().imported = db().imported or {}
    db().imported.macroBank = true
    if not addon:IsInCombat() then
        Macros:ApplyLong()
    else
        Macros.pending = true
    end
    changed()
    return macros, categories
end
