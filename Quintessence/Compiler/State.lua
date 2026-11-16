local addon = WMacroCompiler
local State = { values = {} }
addon.State = State

local classSpecs = {
    DEATHKNIGHT = { "BLOOD", "FROST", "UNHOLY" },
    DRUID = { "BALANCE", "FERAL", "RESTORATION" },
    HUNTER = { "BEAST_MASTERY", "MARKSMANSHIP", "SURVIVAL" },
    MAGE = { "ARCANE", "FIRE", "FROST" },
    PALADIN = { "HOLY", "PROTECTION", "RETRIBUTION" },
    PRIEST = { "DISCIPLINE", "HOLY", "SHADOW" },
    ROGUE = { "ASSASSINATION", "COMBAT", "SUBTLETY" },
    SHAMAN = { "ELEMENTAL", "ENHANCEMENT", "RESTORATION" },
    WARLOCK = { "AFFLICTION", "DEMONOLOGY", "DESTRUCTION" },
    WARRIOR = { "ARMS", "FURY", "PROTECTION" },
}

-- (the bank's loadout rules offer a class's specs: Bank/Settings.lua)
State.CLASS_SPECS = classSpecs


-- True when `spec` is one of `class`'s three specializations (or the class
-- is unknown). Spec-inference tables are keyed by spell NAME across every
-- class, and some names are shared (a druid's "Enrage" vs the warrior
-- talent), so an inferred spec is only accepted if it fits the class.
local function specFitsClass(class, spec)
    local order = class and classSpecs[class]
    if not order then
        return true
    end
    for _, candidate in ipairs(order) do
        if candidate == spec then
            return true
        end
    end
    return false
end

-- Maps a WoW unit token to its AURA:<ADDRESS> key, for every addressable
-- unit except target -- target is handled separately by ScanTargetAuras,
-- which additionally does Gladdy-style spec inference from its auras.
local auraUnitAddress = {
    player = "SELF",
    focus = "FOCUS",
    party1 = "PARTY1",
    party2 = "PARTY2",
    party3 = "PARTY3",
    party4 = "PARTY4",
    arena1 = "ARENA1",
    arena2 = "ARENA2",
    arena3 = "ARENA3",
    arena4 = "ARENA4",
    arena5 = "ARENA5",
}

-- Maps a WoW unit token to its COMBAT:<ADDRESS> key. Deliberately excludes
-- "player" (unlike auraUnitAddress above): the player's own combat status
-- is already exact and immediate via PLAYER_REGEN_DISABLED/ENABLED, WoW's
-- native [combat] macro conditional already covers it with no addon
-- involvement, and it could never actually reach a live secure button
-- anyway -- entering/leaving combat IS the event that opens and closes the
-- window in which secure writes are possible at all, so a COMBAT:SELF
-- condition could only ever be true at an instant when applying it is
-- impossible. "target" is included here (unlike auraUnitAddress, which
-- special-cases target through ScanTargetAuras for its spec-inference side
-- effect) because combat status has no such side effect to keep separate.
-- DUELOPPONENT has no entry here: this map is keyed by real WoW unit
-- tokens ("target", "arena1", ...) as delivered by UNIT_FLAGS' unit arg,
-- and there is no such token for "the duel opponent" -- duels only ever
-- expose a name (§9.1). Its COMBAT:DUELOPPONENT value is instead derived
-- opportunistically by RefreshDuelOpponent, called directly from
-- every place that can change it (target changes, the target's own combat
-- status changing, and the duel activating/ending) rather than dispatched
-- through this table.
local combatUnitAddress = {
    target = "TARGET",
    focus = "FOCUS",
    party1 = "PARTY1",
    party2 = "PARTY2",
    party3 = "PARTY3",
    party4 = "PARTY4",
    arena1 = "ARENA1",
    arena2 = "ARENA2",
    arena3 = "ARENA3",
    arena4 = "ARENA4",
    arena5 = "ARENA5",
}


-- Inference lock window: a fresh inferred spec cannot be flipped by a
-- conflicting inference (Gladdy locks the first detection). Also the
-- re-inspect throttle after a successful read.
local SPEC_LOCK_SECONDS = 60
-- Sticky cache eviction: a cached spec is shown on every retarget for as
-- long as the player keeps producing sightings (targeting, or combat-log
-- events from/to their GUID). After SPEC_CACHE_IDLE_SECONDS without any
-- sighting the entry is dropped, so one-off encounters (Dalaran crowds)
-- do not accumulate. SPEC_CACHE_MAX is hard crowd insurance.
local SPEC_CACHE_IDLE_SECONDS = 1200
local SPEC_CACHE_MAX = 200
-- PLAYER_CD ignores the global cooldown: after any cast, every spellbook
-- spell reports a GCD-length "cooldown", which must not count as being on
-- cooldown. Real cooldowns are longer than 1.5 s.
local GCD_SECONDS = 1.5
-- Duel succubus capture (DUEL_SUCCUBUS / the SUCCUBUS placeholder): the
-- spell whose landing on the player teaches us the opponent's succubus name,
-- the combat-log subevents that carry it (each requires the player as the
-- destination), and the cap on the persisted warlock -> succubus-name book.
-- Match by spell ID, not the localized name. Verify in game with
-- /run print(GetSpellInfo(6358)) -- it should print "Seduction".
local SEDUCTION_SPELL_ID = 6358
local SEDUCTION_LEARN_SUBEVENTS = {
    SPELL_CAST_START = true,
    SPELL_CAST_SUCCESS = true,
    SPELL_AURA_APPLIED = true,
    SPELL_MISSED = true,
}
local SUCCUBUS_BOOK_MAX = 500

local function now()
    return GetTime and GetTime() or 0
end

-- Generic string-set equality (AURA name sets, PLAYER_CD sets, ...).
local function setsEqual(a, b)
    if a == b then
        return true
    end
    if not a or not b then
        return false
    end
    for key in pairs(a) do
        if not b[key] then
            return false
        end
    end
    for key in pairs(b) do
        if not a[key] then
            return false
        end
    end
    return true
end

-- Keeps the compile-time clock fresh on the values snapshot. Called on
-- every handled event, so timed conditions always evaluate against a
-- current _NOW.
function State:RefreshNow()
    self.values._NOW = now()
end

-- Refreshes the last-sighting timestamp of a cached GUID. Called on
-- targeting and on combat-log events whose source or destination GUID is
-- cached; this is the "still in the area" signal that keeps entries alive.
function State:NoteSpecSighting(guid)
    if guid and self.specByGUID and self.specByGUID[guid] then
        self.specSeenByGUID[guid] = now()
    end
end

-- Returns the cached spec for a GUID, dropping the entry when it has been
-- idle too long. No age limit while sightings continue (sticky display).
function State:CachedSpec(guid)
    local spec = guid and self.specByGUID[guid]
    if not spec then
        return nil
    end
    local seen = self.specSeenByGUID[guid]
    if seen and now() - seen > SPEC_CACHE_IDLE_SECONDS then
        self.specByGUID[guid] = nil
        self.specTimeByGUID[guid] = nil
        self.specSourceByGUID[guid] = nil
        self.specSeenByGUID[guid] = nil
        return nil
    end
    return spec
end

-- Hard cap for the GUID cache: sweep idle entries first, then oldest-seen.
function State:PruneSpecCache()
    local count = 0
    for _ in pairs(self.specByGUID) do
        count = count + 1
    end
    if count <= SPEC_CACHE_MAX then
        return
    end
    local currentTime = now()
    for guid in pairs(self.specByGUID) do
        local seen = self.specSeenByGUID[guid]
        if not seen or currentTime - seen > SPEC_CACHE_IDLE_SECONDS then
            self.specByGUID[guid] = nil
            self.specTimeByGUID[guid] = nil
            self.specSourceByGUID[guid] = nil
            self.specSeenByGUID[guid] = nil
        end
    end
    while true do
        count = 0
        local oldestGUID, oldestSeen
        for guid in pairs(self.specByGUID) do
            count = count + 1
            local seen = self.specSeenByGUID[guid] or 0
            if not oldestSeen or seen < oldestSeen then
                oldestGUID, oldestSeen = guid, seen
            end
        end
        if count <= SPEC_CACHE_MAX or not oldestGUID then
            return
        end
        self.specByGUID[oldestGUID] = nil
        self.specTimeByGUID[oldestGUID] = nil
        self.specSourceByGUID[oldestGUID] = nil
        self.specSeenByGUID[oldestGUID] = nil
    end
end

local function refreshPlayerClass()
    local _, class = UnitClass("player")
    State.values.PLAYER_CLASS = class
end

-- group: a talent group (nil: the active one).
local function getTalentSpec(unit, isNotPlayer, group)
    if not GetTalentTabInfo then
        return nil
    end
    local _, class = UnitClass(unit)
    local order = classSpecs[class]
    if not order then
        return nil
    end
    if not group and GetActiveTalentGroup then
        group = GetActiveTalentGroup(isNotPlayer)
    end
    local bestTab, bestPoints = nil, -1
    for tab = 1, 3 do
        local _, _, points = GetTalentTabInfo(tab, isNotPlayer, nil, group)
        points = points or 0
        if points > bestPoints then
            bestPoints = points
            bestTab = tab
        end
    end
    if bestTab and bestPoints > 0 then
        return order[bestTab]
    end
    return nil
end

-- The player's spec in a talent group (1 or 2), as PLAYER_SPEC names it;
-- nil with no points there.
function State.PlayerSpecOfGroup(group)
    return getTalentSpec("player", false, group)
end

function State:RefreshPlayer()
    refreshPlayerClass()
    self.values.PLAYER_SPEC = getTalentSpec("player", false)
    self.playerGUID = UnitGUID and UnitGUID("player") or nil
end

-- Target reaction: ALLY when the unit is friendly (same-faction duel
-- opponents keep a friendly reading for the whole duel), ENEMY below a
-- friendly UnitReaction, NEUTRAL at exactly 4. Nil without a target.
local function computeReaction()
    if not UnitExists or not UnitExists("target") then
        return nil
    end
    if UnitIsFriend and UnitIsFriend("player", "target") then
        return "ALLY"
    end
    local reaction = UnitReaction and UnitReaction("player", "target")
    if reaction then
        if reaction >= 5 then
            return "ALLY"
        end
        if reaction == 4 then
            return "NEUTRAL"
        end
        return "ENEMY"
    end
    if UnitIsEnemy and UnitIsEnemy("player", "target") then
        return "ENEMY"
    end
    return nil
end

function State:RefreshReaction()
    self.values.REACTION = computeReaction()
end

-- The player's own pet: values.PET is nil when no pet is summoned, an
-- uppercased demon-family token (IMP, SUCCUBUS, FELHUNTER, VOIDWALKER,
-- FELGUARD, INFERNAL) when one is and its family is recognized, or
-- "UNKNOWN" when a pet exists but UnitCreatureFamily couldn't identify it
-- (e.g. an unrecognized creature family) -- "UNKNOWN" still satisfies
-- PET=YES like any other summoned pet (see petConditionMatches in
-- Compiler.lua) but correctly fails every specific-type comparison.
-- Unlike CLASS/SPEC/ARENA-style detection, this needs no inference or
-- caching: UnitExists("pet") and UnitCreatureFamily("pet") are both
-- immediate and always accurate for the player's own pet, with none of
-- the stealth/fog-of-war ambiguity a remote unit's status can have.
-- Returns true when the visible PET value changed.
function State:RefreshPet()
    local newValue
    if UnitExists and UnitExists("pet") then
        local family = UnitCreatureFamily and UnitCreatureFamily("pet")
        newValue = family and string.upper(family) or "UNKNOWN"
    end
    local changed = self.values.PET ~= newValue
    self.values.PET = newValue
    return changed
end


-- Party roster: classes are always synchronously known via direct roster
-- queries (no inference needed, unlike arena). Returns whether the slots'
-- AURA and COMBAT values changed.
function State:RefreshParty()
    local auraChanged = false
    local combatChanged = false
    for index = 1, 4 do
        local unit = "party" .. index
        local exists = UnitExists and UnitExists(unit)
        local class
        if exists and UnitClass then
            local _, token = UnitClass(unit)
            class = token
        end
        self.values["PARTY" .. index] = class
        if self:ScanUnitAuras(unit, "PARTY" .. index) then
            auraChanged = true
        end
        if self:ScanUnitCombat(unit, "PARTY" .. index) then
            combatChanged = true
        end
    end
    return auraChanged, combatChanged
end

-- ---------------------------------------------------------------------------
-- Group roster for the group placeholders (§6.1): outside an arena, ROGUE
-- in a body resolves to a raid or party member's NAME (not a raidN token:
-- raid indices shift when someone leaves, and a stale [@raid7] written
-- before combat would then silently point at a different player, whereas
-- [@Name] keeps pointing at the right one or simply stops firing), and
-- MAINTANK / MAINASSIST resolve to the players the raid leader assigned.
--
-- values._GROUP = { kind = "RAID"|"PARTY", members = { ... } } in raid
-- order (raid1..raidN) or party order (party1..party4); nil when solo.
-- Each member: name ("Name" or "Name-Realm"; nil while the client still
-- reports it as unknown), class token, isPlayer, MAINTANK / MAINASSIST
-- flags, and pet (its raidpetN / partypetN token, when one is out). The
-- underscore keeps it out of every condition field: it only feeds
-- placeholder substitution.
-- ---------------------------------------------------------------------------
local function memberName(unit)
    if not UnitName then
        return nil
    end
    local name, realm = UnitName(unit)
    if not name or name == "" or name == (UNKNOWNOBJECT or "Unknown") then
        return nil
    end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function readMember(unit, petUnit, raidIndex)
    local _, class = UnitClass(unit)
    local member = {
        unit = unit,
        name = memberName(unit),
        class = class,
        isPlayer = UnitIsUnit and UnitIsUnit(unit, "player") and true or false,
        -- Connection state. Offline members never resolve as a placeholder
        -- (targeting them is never useful, §6.1); a missing API counts as
        -- online so the feature degrades to the old behaviour.
        online = (not UnitIsConnected) or (UnitIsConnected(unit) and true or false),
    }
    if raidIndex then
        -- 3.3.5a: GetRaidRosterInfo's 10th return is the assigned role
        -- ("MAINTANK" / "MAINASSIST"); GetPartyAssignment answers the same
        -- question per unit. Either one is enough.
        local role = GetRaidRosterInfo and select(10, GetRaidRosterInfo(raidIndex))
        member.MAINTANK = role == "MAINTANK"
            or (GetPartyAssignment and GetPartyAssignment("MAINTANK", unit) and true) or false
        member.MAINASSIST = role == "MAINASSIST"
            or (GetPartyAssignment and GetPartyAssignment("MAINASSIST", unit) and true) or false
    end
    if UnitExists(petUnit) then
        member.pet = petUnit
    end
    return member
end

-- Rebuilds values._GROUP. Returns true when anything a placeholder could
-- resolve to changed (membership, order, names, classes, assignments,
-- pets), so GROUP-watching templates only recompile when it matters.
function State:RefreshGroup()
    if not UnitExists then
        return false
    end
    local kind
    local members = {}
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raidCount > 0 then
        kind = "RAID"
        for index = 1, math.min(raidCount, 40) do
            local unit = "raid" .. index
            if UnitExists(unit) then
                table.insert(members, readMember(unit, "raidpet" .. index, index))
            end
        end
    elseif (GetNumPartyMembers and GetNumPartyMembers() or 0) > 0 then
        kind = "PARTY"
        for index = 1, 4 do
            local unit = "party" .. index
            if UnitExists(unit) then
                table.insert(members, readMember(unit, "partypet" .. index))
            end
        end
    end
    local parts = { kind or "SOLO" }
    for _, member in ipairs(members) do
        table.insert(parts, table.concat({
            member.name or "?", member.class or "?",
            member.isPlayer and "P" or "", member.MAINTANK and "T" or "",
            member.MAINASSIST and "A" or "", member.pet or "",
            member.online and "" or "X",
        }, ","))
    end
    local signature = table.concat(parts, ";")
    local changed = signature ~= self.groupSignature
    self.groupSignature = signature
    self.values._GROUP = kind and { kind = kind, members = members } or nil
    -- Leaving the group ends its pins: a raid's composition is per run.
    if not kind and next(self.pins) then
        self.pins = {}
        changed = true
    end
    self:PublishPins()
    if changed and self.groupAurasWanted then
        self:ScanRaidAuras()
    end
    return changed
end

-- Class pins (§6.1): the player decides who a class placeholder means in
-- the current group; a free pin (ANY) takes any member, whatever their
-- class. State.pins = { MAGE = "Name", ANY = "Name" } is runtime-only (never
-- saved: a raid's composition is per run) and is published to the compiler
-- as values._PINS, a copy, so the compiler stays pure. A pin is KEPT while
-- its player is absent or offline (the compiler then ignores it) and
-- applies again when they return.
State.pins = {}

function State:PublishPins()
    local copy = {}
    for class, name in pairs(self.pins) do
        copy[class] = name
    end
    self.values._PINS = copy
end

local function prettyClass(class)
    return class:sub(1, 1) .. class:sub(2):lower()
end

local function baseName(name)
    return (name:match("^([^-]+)") or name)
end

-- Finds the roster member a name refers to: an exact (case-insensitive)
-- match of "Name" or "Name-Realm", or a bare "Name" for a cross-realm
-- member.
local function findMemberByName(group, query)
    local lowered = query:lower()
    local partial
    for _, member in ipairs(group and group.members or {}) do
        if member.name then
            local name = member.name:lower()
            if name == lowered then
                return member
            end
            if not partial and baseName(name) == lowered then
                partial = member
            end
        end
    end
    return partial
end

-- The current target as a group member that can be pinned (not yourself),
-- or nil and why not. The flyout's CLASS / ANY buttons ask this too.
function State:TargetMember()
    local group = self.values._GROUP
    if not group then
        return nil, "You are not in a group"
    end
    local name = UnitExists and UnitExists("target") and memberName("target") or nil
    if not name then
        return nil, "No target to pin (target a group member or give a name)"
    end
    local member = findMemberByName(group, name)
    if not member then
        return nil, name .. " is not in your group"
    end
    if member.isPlayer then
        return nil, "You cannot pin yourself"
    end
    return member
end

-- Pins the current target (query nil) or the named group member as the
-- class's #1, or as a free pin (ANY). Returns the pinned member's name and
-- whether anything changed, or nil and an error message.
function State:SetPin(class, query)
    class = class and class:upper()
    local Compiler = addon.Compiler
    local free = class and Compiler and Compiler.freePins[class]
    if not class or not (free or (Compiler and Compiler.classNames[class])) then
        return nil, "Unknown class \"" .. tostring(class or "") .. "\""
    end
    local group = self.values._GROUP
    if not group then
        return nil, "You are not in a group"
    end
    local member
    if query and query ~= "" then
        member = findMemberByName(group, query)
        if not member then
            return nil, query .. " is not in your group"
        end
    else
        local reason
        member, reason = self:TargetMember()
        if not member then
            return nil, reason
        end
    end
    if member.isPlayer then
        return nil, "You cannot pin yourself"
    end
    if not free and member.class ~= class then
        return nil, member.name .. " is a " .. prettyClass(member.class or "?") .. ", not a " .. prettyClass(class)
    end
    local changed = self.pins[class] ~= member.name
    self.pins[class] = member.name
    self:PublishPins()
    return member.name, changed
end

function State:ClearPin(class)
    class = class and class:upper()
    local had = class and self.pins[class] ~= nil
    if had then
        self.pins[class] = nil
        self:PublishPins()
    end
    return had
end

function State:ClearPins()
    local had = next(self.pins) ~= nil
    if had then
        self.pins = {}
        self:PublishPins()
    end
    return had
end

-- Pins as a sorted list { class, name, status } where status is "active",
-- "absent" (not in the group now) or "offline".
function State:ActivePins()
    local list = {}
    local group = self.values._GROUP
    local freePins = addon.Compiler and addon.Compiler.freePins or {}
    for class, name in pairs(self.pins) do
        local status = "absent"
        local member = group and findMemberByName(group, name)
        if member and (freePins[class] or member.class == class) and not member.isPlayer then
            status = member.online == false and "offline" or "active"
        end
        table.insert(list, { class = class, name = name, status = status })
    end
    table.sort(list, function(a, b)
        return a.class < b.class
    end)
    return list
end

-- User flags (FLAG=<NAME>, §5.15): names the player switches on and off
-- with /qmc flag, for states the game cannot detect (hunting players in the
-- open world, farming, ...). Stored per character in
-- WMacroCompilerDB.flags["Name-Realm"] = { NAME = true }, so they survive
-- reloads and an alt's flags stay its own. values.FLAG is always a set
-- (possibly empty): a flag is never "unknown", so NOT FLAG=X is meaningful.
local function flagKey()
    local name = UnitName and UnitName("player") or nil
    local realm = GetRealmName and GetRealmName() or nil
    return (name or "?") .. "-" .. (realm or "?")
end

function State:FlagStore()
    local db = addon.db
    if not db then
        self.flagFallback = self.flagFallback or {}
        return self.flagFallback
    end
    db.flags = db.flags or {}
    local key = flagKey()
    db.flags[key] = db.flags[key] or {}
    return db.flags[key]
end

-- Mutes (§5.16): macro lines the player switched off in a mode's branches.
-- Stored per character like flags, WMacroCompilerDB.mutes["Name-Realm"] =
-- { DUEL = { "Global Thermal Sapper Charge", ... } }, entries as typed and
-- in the order added (that order decides which mute a branch keeps when
-- muting them all would empty it). The compiler applies them to each parse
-- (Compiler.ApplyMutes); State only keeps the list.
function State:Mutes()
    local db = addon.db
    if not db then
        self.muteFallback = self.muteFallback or {}
        return self.muteFallback
    end
    db.mutes = db.mutes or {}
    local key = flagKey()
    db.mutes[key] = db.mutes[key] or {}
    return db.mutes[key]
end

local function findMute(list, key)
    for index, entry in ipairs(list) do
        local other = addon.Compiler.MuteKey(entry)
        if other and other.command == key.command and other.argument == key.argument then
            return index
        end
    end
    return nil
end

-- Adds entries to MODE's mutes. Returns the added entries and the ones
-- already muted, or nil and an error (nothing is added then).
function State:AddMutes(mode, entries)
    local keys = {}
    for index, entry in ipairs(entries) do
        local key, keyError = addon.Compiler.MuteKey(entry)
        if not key then
            return nil, keyError
        end
        keys[index] = key
    end
    local mutes = self:Mutes()
    local list = mutes[mode] or {}
    local added, already = {}, {}
    for index, entry in ipairs(entries) do
        if findMute(list, keys[index]) then
            table.insert(already, entry)
        else
            table.insert(list, entry)
            table.insert(added, entry)
        end
    end
    mutes[mode] = #list > 0 and list or nil
    self:RememberMutes(mode, entries)
    return added, already
end

-- Remembered mutes: every line muted on a class, kept per class after it is
-- unmuted so it can be switched back on without retyping it (the State
-- section's and the flyout's checkboxes). WMacroCompilerDB.muteHistory[CLASS]
-- = { DUEL = { entry, ... } }, in the order first muted. Muting itself stays
-- per character (State:Mutes).
function State:RememberedMutes()
    local db = addon.db
    if not db then
        self.historyFallback = self.historyFallback or {}
        return self.historyFallback
    end
    local _, class = UnitClass("player")
    class = class or "UNKNOWN"
    db.muteHistory = db.muteHistory or {}
    db.muteHistory[class] = db.muteHistory[class] or {}
    return db.muteHistory[class]
end

function State:RememberMutes(mode, entries)
    local history = self:RememberedMutes()
    local list = history[mode] or {}
    for _, entry in ipairs(entries) do
        local key = addon.Compiler.MuteKey(entry)
        if key and not findMute(list, key) then
            table.insert(list, entry)
        end
    end
    history[mode] = #list > 0 and list or nil
end

-- Adds the character's current mutes to its class's remembered ones (once
-- at login: mutes made before the list existed).
function State:RememberCurrentMutes()
    for mode, entries in pairs(self:Mutes()) do
        self:RememberMutes(mode, entries)
    end
end

-- Drops an entry from the remembered mutes. Returns true if it was there.
-- (It is not unmuted here: addon:ForgetMute does both.)
function State:ForgetMute(mode, entry)
    local history = self:RememberedMutes()
    local list = history[mode]
    local key = addon.Compiler.MuteKey(entry)
    local index = list and key and findMute(list, key)
    if not index then
        return false
    end
    table.remove(list, index)
    history[mode] = #list > 0 and list or nil
    return true
end

-- Every remembered mute as { mode, entry, on } (on: muted now on this
-- character), by mode, then in the order first muted.
function State:MuteRows()
    self:RememberCurrentMutes()
    local current = self:Mutes()
    local modes = {}
    for mode in pairs(self:RememberedMutes()) do
        table.insert(modes, mode)
    end
    table.sort(modes)
    local rows = {}
    for _, mode in ipairs(modes) do
        for _, entry in ipairs(self:RememberedMutes()[mode]) do
            local key = addon.Compiler.MuteKey(entry)
            local on = current[mode] and key and findMute(current[mode], key) and true or false
            table.insert(rows, { mode = mode, entry = entry, on = on })
        end
    end
    return rows
end

-- Removes entries from MODE's mutes, or all of MODE's mutes when entries
-- is nil. Returns the removed entries and the ones that were not muted.
function State:RemoveMutes(mode, entries)
    local mutes = self:Mutes()
    local list = mutes[mode]
    if not list then
        return {}, entries or {}
    end
    if not entries then
        mutes[mode] = nil
        return list, {}
    end
    local removed, missing = {}, {}
    for _, entry in ipairs(entries) do
        local key = addon.Compiler.MuteKey(entry)
        local index = key and findMute(list, key)
        if index then
            table.insert(removed, table.remove(list, index))
        else
            table.insert(missing, entry)
        end
    end
    mutes[mode] = #list > 0 and list or nil
    return removed, missing
end

function State:ClearMutes()
    local mutes = self:Mutes()
    local had = next(mutes) ~= nil
    for mode in pairs(mutes) do
        mutes[mode] = nil
    end
    return had
end

-- Sorted list { mode, entries } of the modes with mutes.
function State:MuteList()
    local list = {}
    for mode, entries in pairs(self:Mutes()) do
        table.insert(list, { mode = mode, entries = entries })
    end
    table.sort(list, function(a, b)
        return a.mode < b.mode
    end)
    return list
end

function State:RefreshFlags()
    local set = {}
    for name, on in pairs(self:FlagStore()) do
        if on then
            set[name] = true
        end
    end
    local changed = not setsEqual(set, self.values.FLAG)
    self.values.FLAG = set
    return changed
end

-- Sorted list of the active flag names.
function State:ActiveFlags()
    local list = {}
    for name in pairs(self.values.FLAG or {}) do
        table.insert(list, name)
    end
    table.sort(list)
    return list
end

-- on: true, false, or nil to toggle. Returns the new state and whether it
-- changed.
function State:SetFlag(name, on)
    local store = self:FlagStore()
    if on == nil then
        on = not store[name]
    end
    store[name] = on and true or nil
    return on and true or false, self:RefreshFlags()
end

function State:ClearFlags()
    local store = self:FlagStore()
    for name in pairs(store) do
        store[name] = nil
    end
    return self:RefreshFlags()
end

-- Auras are rescanned unconditionally on every call, since
-- PLAYER_FOCUS_CHANGED (the event that drives this) means the unit itself
-- may be unchanged while its auras haven't been sampled yet. Returns
-- whether the focus's AURA and COMBAT values changed.
function State:RefreshFocus()
    local auraChanged = self:ScanUnitAuras("focus", "FOCUS")
    local combatChanged = self:ScanUnitCombat("focus", "FOCUS")
    return auraChanged, combatChanged
end

-- Our own talents are authoritative for our own GUID: no inspection or
-- inference is needed to know the player's spec. Keeps the sticky GUID
-- cache (and a self-target's visible SPEC) in sync with talent changes,
-- so targeting oneself after a respec never restores a stale cached spec.
-- Returns true when the visible SPEC value changed.
function State:SyncPlayerSpec()
    if not UnitGUID or not self.specByGUID then
        return false
    end
    local guid = UnitGUID("player")
    if not guid then
        return false
    end
    local spec = self.values.PLAYER_SPEC
    if spec then
        return self:SetSpec(guid, spec, "INSPECT")
    end
    -- No spec (e.g. no talents spent): drop any stale entry for ourselves.
    local hadEntry = self.specByGUID[guid] ~= nil
    self.specByGUID[guid] = nil
    self.specTimeByGUID[guid] = nil
    self.specSourceByGUID[guid] = nil
    self.specSeenByGUID[guid] = nil
    if self.targetGUID == guid and self.values.SPEC ~= nil then
        self.values.SPEC = nil
        return true
    end
    return false
end
-- Bounded one-shot recheck for a PLAYER_SPEC read that lost the race
-- against the client's own talent-data load (§8.1). GetTalentTabInfo can
-- return stale/zero data for a second or two right after
-- PLAYER_ENTERING_WORLD, before the client finishes pulling talent data
-- from the server. Unlike the target's SPEC (rescanned on every retarget),
-- nothing else naturally revisits PLAYER_SPEC once that first read loses
-- the race: PLAYER_TALENT_UPDATE/ACTIVE_TALENT_GROUP_CHANGED only fire on
-- an actual talent change, not when previously-unavailable data simply
-- becomes available. Driven by a one-shot timer in Quintessence.lua
-- (playerSpecRetryTimer), armed only when PLAYER_ENTERING_WORLD leaves
-- PLAYER_SPEC nil. Returns the changed watch categories, or nil when the
-- recheck simply reconfirms nil (e.g. a genuinely talent-less character) --
-- so a lost race costs one extra scan, not a recompile.
function State:RetryPlayerSpec()
    local before = self.values.PLAYER_SPEC
    self:RefreshPlayer()
    if self.values.PLAYER_SPEC == before then
        return nil
    end
    local categories = { "PLAYER_SPEC" }
    if self:SyncPlayerSpec() then
        table.insert(categories, "SPEC")
    end
    return categories
end

function State:RefreshInstance()
    local name, instanceType
    if GetInstanceInfo then
        name, instanceType = GetInstanceInfo()
    end
    self.values.INSTANCE_NAME = name and string.upper(name) or nil
    self.values.INSTANCE = instanceType and string.upper(instanceType) or nil
    local zone
    if GetRealZoneText then
        zone = GetRealZoneText()
    elseif GetZoneText then
        zone = GetZoneText()
    end
    self.values.ZONE = zone and zone ~= "" and string.upper(zone) or nil
end

-- Arena opponents: per-slot classes (ARENA1-5), the COMP presence set and
-- sticky per-match sighted flags (an "#WATCH ARENA ASSUME" overlay only
-- ever fills slots that have never been sighted this match), reset on
-- PLAYER_ENTERING_WORLD. Returns whether the slots' AURA and COMBAT
-- values changed.
function State:RefreshArena()
    self.arenaSighted = self.arenaSighted or {}
    -- Match size, when the API offers it: an ASSUME overlay only fills
    -- slots that can actually exist in this match (never slots 3-5 of a 2v2).
    if GetNumArenaOpponents then
        self.arenaOpponentCount = GetNumArenaOpponents()
    end
    local auraChanged = false
    local combatChanged = false
    self.arenaClass = self.arenaClass or {}
    local comp
    for index = 1, 5 do
        local unit = "arena" .. index
        local class
        if UnitClass then
            local _, token = UnitClass(unit)
            class = token
        end
        if class then
            self.arenaClass[index] = class
        elseif self.arenaSighted[index] then
            -- Sticky for the match: an opponent who stealths (or walks out
            -- of sight) is still on the enemy team, so its class keeps
            -- feeding ARENAn/COMP and the @<CLASS> placeholders. Reset on
            -- PLAYER_ENTERING_WORLD and on an ARENA_OPPONENT_UPDATE "cleared".
            class = self.arenaClass[index]
        end
        self.values["ARENA" .. index] = class
        if class then
            self.arenaSighted[index] = true
            comp = comp or {}
            comp[class] = true
        end
        -- Feeds both a direct AURA:ARENAn lookup and, indirectly,
        -- AURA:COMP:<CLASS> (see auraCompConditionMatches in Compiler.lua),
        -- which reads this slot's class alongside its aura set.
        if self:ScanUnitAuras(unit, "ARENA" .. index) then
            auraChanged = true
        end
        -- Same relationship for COMBAT:ARENAn / COMBAT:COMP:<CLASS>.
        if self:ScanUnitCombat(unit, "ARENA" .. index) then
            combatChanged = true
        end
    end
    self.values.COMP = comp
    return auraChanged, combatChanged
end

-- Maps uppercased spellbook names to their properly-cased spellbook names.
-- Spell APIs are case-sensitive, while template conditions are uppercased
-- by the parser -- this map is how PLAYER_CD spell references are resolved
-- (and validated: absent from the map = not in the player's spellbook).
function State:ScanSpellbook()
    local map = {}
    self.spellsSeen = self.spellsSeen or {}
    local seen = self.spellsSeen
    -- GetSpellBookItemName is the 4.0+ name (provided on 3.3.5a by
    -- !!!ClassicAPI); GetSpellName is the native 3.3.5a API.
    local getName = GetSpellBookItemName or GetSpellName
    if getName then
        local index = 1
        while true do
            local name = getName(index, BOOKTYPE_SPELL or "spell")
            if not name then
                break
            end
            local upper = string.upper(name)
            if not map[upper] then
                map[upper] = name
            end
            seen[upper] = true
            index = index + 1
        end
    end
    self.spellbookByUpper = map
end

-- Maps uppercased item names to item IDs for PLAYER_CD conditions on used
-- items (Global Thermal Sapper Charge, an on-use trinket...), learned from
-- the bags and equipped gear. Learned IDs are kept in
-- WMacroCompilerDB.itemIDs, so an item keeps resolving after its last
-- charge is used (it is still on cooldown) or when it is not carried at
-- login. Item cooldowns are queried by ID, which works without the item.
function State:ScanItems()
    local map = (addon.db and addon.db.itemIDs) or self.itemsByUpper or {}
    local function learn(link)
        local id = link and tonumber(link:match("item:(%d+)"))
        local name = link and link:match("%[(.-)%]")
        if id and name then
            map[string.upper(name)] = id
        end
    end
    if GetContainerNumSlots and GetContainerItemLink then
        for bag = 0, NUM_BAG_SLOTS or 4 do
            for slot = 1, GetContainerNumSlots(bag) or 0 do
                learn(GetContainerItemLink(bag, slot))
            end
        end
    end
    if GetInventoryItemLink then
        for slot = 1, 19 do
            learn(GetInventoryItemLink("player", slot))
        end
    end
    self.itemsByUpper = map
end

-- True when a PLAYER_CD name resolved to neither a spell nor an item yet
-- (the bags are rescanned for it when they change).
function State:HasUnresolvedCooldowns()
    for upper in pairs(self.cooldownWanted or {}) do
        if not (self.cooldownSpells and self.cooldownSpells[upper])
            and not (self.cooldownItems and self.cooldownItems[upper]) then
            return true
        end
    end
    return false
end

-- Replaces the set of spells and items tracked for PLAYER_CD conditions
-- (uppercased names collected from the active templates). A name is a
-- spellbook spell first, else a known item. Unknown names are reported
-- once a session (never a spell seen in the spellbook this session, such
-- as the other spec's) and simply never enter the PLAYER_CD set. Returns true when the
-- visible PLAYER_CD state changed.
function State:SetCooldownWatches(spellSet)
    self.cooldownWanted = spellSet or {}
    if not self.spellbookByUpper then
        self:ScanSpellbook()
    end
    if not self.itemsByUpper then
        self:ScanItems()
    end
    -- An item picked up since the last scan: rescan before calling it unknown.
    for upper in pairs(self.cooldownWanted) do
        if not self.spellbookByUpper[upper] and not self.itemsByUpper[upper] then
            self:ScanItems()
            break
        end
    end
    self.unknownCooldownWarned = self.unknownCooldownWarned or {}
    self.cooldownSpells = {}
    self.cooldownItems = {}
    for upper in pairs(self.cooldownWanted) do
        local proper = self.spellbookByUpper[upper]
        local itemID = self.itemsByUpper[upper]
        if proper then
            self.cooldownSpells[upper] = proper
        elseif itemID then
            self.cooldownItems[upper] = itemID
        elseif not self.unknownCooldownWarned[upper] and not (self.spellsSeen and self.spellsSeen[upper]) then
            self.unknownCooldownWarned[upper] = true
            addon:Print('PLAYER_CD: unknown spell or item "' .. upper
                .. '" (not in your spellbook, bags or equipped gear).')
        end
    end
    return self:RefreshPlayerCooldowns()
end

-- Rebuilds values.PLAYER_CD (the set of tracked spells and items currently
-- on cooldown, keyed by uppercased name) straight from GetSpellCooldown /
-- GetItemCooldown -- always exact, never inferred. Returns true when the
-- set changed.
function State:RefreshPlayerCooldowns()
    local set = {}
    if self.cooldownSpells and GetSpellCooldown then
        for upper, proper in pairs(self.cooldownSpells) do
            local start, duration = GetSpellCooldown(proper)
            if start and duration and start > 0 and duration > GCD_SECONDS then
                set[upper] = true
            end
        end
    end
    if self.cooldownItems and GetItemCooldown then
        for upper, itemID in pairs(self.cooldownItems) do
            local start, duration = GetItemCooldown(itemID)
            if start and duration and start > 0 and duration > GCD_SECONDS then
                set[upper] = true
            end
        end
    end
    local changed = not setsEqual(self.values.PLAYER_CD, set)
    self.values.PLAYER_CD = set
    -- GetSpellCooldown reaching zero is a pure function of elapsed time --
    -- nothing fires an event for that moment (unlike a cooldown *starting*,
    -- which does trigger SPELL_UPDATE_COOLDOWN) -- so a watchdog timer
    -- (addon.cooldownTimer) polls for it. Only run that timer while
    -- something is actually tracked as on cooldown; every call site that
    -- can change PLAYER_CD funnels through here, so this is the single
    -- place that needs to manage it.
    if addon.cooldownTimer then
        if next(set) then
            addon.cooldownTimer:Show()
        else
            addon.cooldownTimer:Hide()
        end
    end
    return changed
end

-- Returns true when the target resolved an active duel's class (DUEL).
function State:RefreshTarget()
    local exists = UnitExists and UnitExists("target")
    if not exists then
        self.values.CLASS = nil
        self.values.SPEC = nil
        self.values.NAME = nil
        self.values["AURA:TARGET"] = nil
        self.values["COMBAT:TARGET"] = nil
        self.values.REACTION = nil
        self:RefreshDuelOpponent()
        self.targetGUID = nil
        return false
    end
    local previousGUID = self.targetGUID
    self.targetGUID = UnitGUID and UnitGUID("target") or nil
    local _, class = UnitClass("target")
    self.values.CLASS = class
    if UnitName then
        local name = UnitName("target")
        self.values.NAME = name and string.upper(name) or nil
    end
    self:RefreshReaction()
    if self.targetGUID ~= previousGUID then
        -- New target: sticky restore of any cached spec, however old, as
        -- long as the entry is still producing sightings (see CachedSpec).
        self.values.SPEC = self:CachedSpec(self.targetGUID)
    end
    -- Duel capture completion: an active duel whose class is still
    -- unresolved resolves when the player's own target matches the
    -- opponent's name (an ordinary watched-field change to DUEL).
    local duelChanged = false
    if self.duelActive and self.values.DUEL == nil and self.values.DUEL_NAME
        and self.values.NAME and string.upper(self.values.DUEL_NAME) == self.values.NAME then
        local _, token = UnitClass("target")
        if token then
            self.values.DUEL = token
            duelChanged = true
        end
    end
    self:NoteSpecSighting(self.targetGUID)
    self:ScanTargetAuras()
    self:ScanUnitCombat("target", "TARGET")
    self:RefreshDuelOpponent()
    self:RequestTargetInspect()
    return duelChanged
end


-- Records an inferred or inspected spec for a GUID. Inspection is
-- authoritative and always wins. While an entry's detection is fresh,
-- inference neither overrides an inspected spec nor flips an earlier
-- inference (Gladdy locks the first detection too); entries whose
-- detection is older than SPEC_LOCK_SECONDS may be replaced. Display is
-- sticky: the entry stays visible on retarget until it goes idle.
-- Returns true when the visible SPEC value changed.
function State:SetSpec(guid, spec, source)
    if not guid or not spec then
        return false
    end
    if source ~= "INSPECT" then
        local class = guid == self.targetGUID and self.values.CLASS or nil
        if not specFitsClass(class, spec) then
            return false
        end
        local existing = self.specByGUID[guid]
        local existingTime = self.specTimeByGUID[guid]
        local fresh = existingTime and (now() - existingTime) < SPEC_LOCK_SECONDS
        if existing and fresh then
            if existing ~= spec or self.specSourceByGUID[guid] == "INSPECT" then
                return false
            end
            -- Same spec re-confirmed: refresh the timestamps.
        end
    end
    self.specByGUID[guid] = spec
    self.specTimeByGUID[guid] = now()
    self.specSourceByGUID[guid] = source
    self.specSeenByGUID[guid] = now()
    self:PruneSpecCache()
    if guid ~= self.targetGUID or self.values.SPEC == spec then
        return false
    end
    self.values.SPEC = spec
    return true
end

-- One pass over the target's auras doing two jobs: rebuild
-- values["AURA:TARGET"] (uppercased buff AND debuff names, any caster) and
-- Gladdy-style spec inference from spec-defining buffs cast by the target
-- itself (or its pet). Returns specChanged, auraChanged.
function State:ScanTargetAuras()
    if not UnitAura or not UnitExists or not UnitExists("target") then
        local auraChanged = self.values["AURA:TARGET"] ~= nil
        self.values["AURA:TARGET"] = nil
        self:RefreshDuelOpponent()
        return false, auraChanged
    end
    local specBuffs = addon.SpecData and addon.SpecData.specBuffs
    local guid = self.targetGUID
    local inspectFresh = guid
        and self.specSourceByGUID[guid] == "INSPECT"
        and self.specTimeByGUID[guid]
        and now() - self.specTimeByGUID[guid] < SPEC_LOCK_SECONDS
    local auras = {}
    local specChanged = false
    for pass = 1, 2 do
        local filter = pass == 1 and "HELPFUL" or "HARMFUL"
        for index = 1, 40 do
            local name, _, _, _, _, _, _, caster = UnitAura("target", index, filter)
            if not name then
                break
            end
            local upperName = string.upper(name)
            auras[upperName] = true
            if pass == 1 and not inspectFresh and specBuffs and guid then
                local spec = specBuffs[upperName]
                if spec and caster and UnitIsUnit
                    and (UnitIsUnit(caster, "target") or UnitIsUnit(caster, "targetpet")) then
                    if self:SetSpec(guid, spec, "AURA") then
                        specChanged = true
                    end
                end
            end
        end
    end
    local auraChanged = not setsEqual(self.values["AURA:TARGET"], auras)
    self.values["AURA:TARGET"] = auras
    self:RefreshDuelOpponent()
    return specChanged, auraChanged
end

-- Per-aura info for .TIME / .STACKS (§5.7.1): { [NAME] = { count, expires } }.
-- count is the highest stack count among the aura's copies (a copy with no
-- stacks counts as 1); expires is the latest expiration time among copies
-- with a duration, nil when every copy is permanent (TIME is then unknown).
local function readAuras(unit)
    local set, info = {}, {}
    for pass = 1, 2 do
        local filter = pass == 1 and "HELPFUL" or "HARMFUL"
        for index = 1, 40 do
            local name, _, _, count, _, duration, expires = UnitAura(unit, index, filter)
            if not name then
                break
            end
            local upperName = string.upper(name)
            set[upperName] = true
            local entry = info[upperName] or { count = 0 }
            info[upperName] = entry
            entry.count = math.max(entry.count, (count and count > 0) and count or 1)
            if duration and duration > 0 and expires and expires > 0 then
                entry.expires = math.max(entry.expires or 0, expires)
            end
        end
    end
    return set, info
end

local function auraInfoEqual(a, b)
    if a == b then
        return true
    end
    if not a or not b then
        return false
    end
    for name, entry in pairs(a) do
        local other = b[name]
        if not other or other.count ~= entry.count or other.expires ~= entry.expires then
            return false
        end
    end
    for name in pairs(b) do
        if not a[name] then
            return false
        end
    end
    return true
end

-- Stores a unit's auras in values._UNITAURA[unit] (the player and the
-- group units: what AURA:SELF measures and AURA:<PLACEHOLDER> resolve to),
-- or drops them when the unit is gone. Returns true when anything changed.
function State:StoreUnitAuras(unit)
    local store = self.values._UNITAURA
    if not store then
        store = {}
        self.values._UNITAURA = store
    end
    local old = store[unit]
    if not UnitAura or not UnitExists or not UnitExists(unit) then
        store[unit] = nil
        return old ~= nil
    end
    local set, info = readAuras(unit)
    store[unit] = { set = set, info = info }
    return not old or not setsEqual(old.set, set) or not auraInfoEqual(old.info, info)
end

-- Raid units are scanned only while an active template uses an
-- AURA:<PLACEHOLDER> address (State.groupAurasWanted, set by
-- addon:RebuildConditionRegistries); party units and the player always are.
function State:ScanRaidAuras()
    local changed = false
    local count = self.groupAurasWanted and GetNumRaidMembers and GetNumRaidMembers() or 0
    for index = 1, 40 do
        local unit = "raid" .. index
        if index <= count then
            if self:StoreUnitAuras(unit) then
                changed = true
            end
        elseif self.values._UNITAURA and self.values._UNITAURA[unit] then
            self.values._UNITAURA[unit] = nil
            changed = true
        end
    end
    return changed
end

function State:SetGroupAuraWatch(wanted)
    wanted = wanted and true or false
    if wanted == (self.groupAurasWanted or false) then
        return false
    end
    self.groupAurasWanted = wanted
    return self:ScanRaidAuras()
end

-- One pass over <unit>'s current auras (uppercased buff AND debuff names,
-- any caster), stored as values["AURA:" .. address]. This backs every
-- addressable #IF AURA:<ADDRESS>=... condition except target, which stays
-- on ScanTargetAuras above (it additionally does Gladdy-style spec
-- inference, so it's kept separate rather than folded in here). nil --
-- never an empty table -- when the unit doesn't exist, matching how
-- CLASS/PARTYn/ARENAn already read "unknown" for an absent unit elsewhere
-- in this file. Returns true when the visible set changed.
-- The player and party units also keep their per-aura info
-- (StoreUnitAuras), so a refreshed buff (new expiration) counts as a change.
function State:ScanUnitAuras(unit, address)
    local key = "AURA:" .. address
    local infoChanged = false
    if unit == "player" or unit:match("^party%d$") then
        infoChanged = self:StoreUnitAuras(unit)
    end
    if not UnitAura or not UnitExists or not UnitExists(unit) then
        local auraChanged = self.values[key] ~= nil
        self.values[key] = nil
        return auraChanged or infoChanged
    end
    local auras = readAuras(unit)
    local auraChanged = not setsEqual(self.values[key], auras)
    self.values[key] = auras
    return auraChanged or infoChanged
end

-- True for an arena slot whose opponent was sighted this match but whose
-- unit can't currently be read (stealth, out of sight): it exists, its
-- status just can't be assessed.
function State:IsUnseenArenaOpponent(unit)
    local index = tonumber(unit:match("^arena(%d)$") or "")
    return index ~= nil and self.arenaClass ~= nil and self.arenaClass[index] ~= nil
end

-- Refreshes values["COMBAT:" .. address] from UnitAffectingCombat(unit) --
-- the string "YES" or "NO", matching REACTION's categorical-string
-- convention (not a Lua boolean) so the generic scalar-field path in
-- Compiler.lua's conditionMatches can compare it directly, the same way it
-- already compares REACTION. nil -- never "NO" -- when the unit doesn't
-- exist, the same "unknown never matches" convention CLASS/AURA/PARTYn/
-- ARENAn already use elsewhere in this file.
--
-- A third, distinct value, "UNKNOWN", covers a unit that exists (it's a
-- real target/party member/arena opponent) but whose live combat flag
-- can't currently be assessed -- most notably a stealthed arena opponent:
-- the slot and class are known, but the client has no current visibility
-- into the unit to read a real YES/NO from. This must not be silently
-- folded into "NO" (UnitAffectingCombat returning nil already reads as
-- falsy in Lua, which is why this distinction needs an explicit check
-- rather than the naive `UnitAffectingCombat(unit) and "YES" or "NO"`
-- idiom): "confirmed out of combat" and "can't tell" are different facts,
-- and only #WATCH COMBAT ASSUME=YES/NO (§5.8) may deliberately conflate
-- them, per-template, at compile time.
--
-- Note: no dedicated WoW event marks a unit becoming un-/re-assessable
-- (there's no "stealth" event exposed here), so this can go briefly stale
-- until the next event that already re-runs ScanUnitCombat for the unit
-- (UNIT_FLAGS, a roster refresh, a target change, ...) -- the same kind of
-- bounded staleness §8.4 accepts for cooldown-expiry detection.
--
-- Returns true when the visible value changed.
function State:ScanUnitCombat(unit, address)
    local key = "COMBAT:" .. address
    if not UnitAffectingCombat or not UnitExists or not UnitExists(unit) then
        -- A sighted-but-unseen arena opponent is "UNKNOWN", not absent, so
        -- #WATCH COMBAT ASSUME=YES/NO applies to it (§5.8).
        local status = UnitExists and self:IsUnseenArenaOpponent(unit) and "UNKNOWN" or nil
        local changed = self.values[key] ~= status
        self.values[key] = status
        return changed
    end
    local status
    if UnitIsVisible and not UnitIsVisible(unit) then
        status = "UNKNOWN"
    else
        status = UnitAffectingCombat(unit) and "YES" or "NO"
    end
    local changed = self.values[key] ~= status
    self.values[key] = status
    return changed
end


-- Raw OnEvent payload for COMBAT_LOG_EVENT_UNFILTERED on 3.3.5a:
--   1 timestamp, 2 subEvent, 3 sourceGUID, 4 sourceName, 5 sourceFlags,
--   6 destGUID, 7 destName, 8 destFlags, 9 spellID, 10 spellName, 11 spellSchool
-- Returns the changed watch categories (DUEL and/or SPEC).
function State:HandleCombatLog(timestamp, subEvent, sourceGUID, sourceName, sourceFlags,
                               destGUID, destName, destFlags, spellID, spellName, spellSchool)
    -- Any combat-log traffic involving the opponent confirms the duel has
    -- begun (only a live duel produces such events).
    if self.duelPendingUntil and self.values.DUEL_NAME then
        local opponent = string.upper(self.values.DUEL_NAME)
        if (sourceName and string.upper(sourceName) == opponent)
            or (destName and string.upper(destName) == opponent) then
            self:ConfirmDuel()
        end
    end
    -- Sightings keep cached specs alive for players still in the area.
    self:NoteSpecSighting(sourceGUID)
    self:NoteSpecSighting(destGUID)

    local categories
    local upperName = spellName and string.upper(spellName)

    -- Duel succubus capture. A Seduction landing on the player during a live
    -- duel can only come from the opponent's succubus, and its combat-log
    -- source name IS the pet's name -- the one place a name is ever exposed
    -- (3.3.5a has no unit API that returns another player's pet name, and
    -- no "targetpet" token). The name goes live immediately (DUEL category:
    -- templates compile now, or queue until combat ends per #COMPILE) and is
    -- stored per warlock so later duels start populated (State:ActivateDuel).
    -- The combat log carries no pet owner, so a stray hostile succubus
    -- seducing the player mid-duel can't be told apart from the opponent's;
    -- the only exact filter available is the opponent's class: once it is
    -- known and isn't a Warlock, no succubus can be theirs, so skip.
    if spellID == SEDUCTION_SPELL_ID and SEDUCTION_LEARN_SUBEVENTS[subEvent]
        and self.duelActive and self.values.DUEL_NAME
        and (self.values.DUEL == nil or self.values.DUEL == "WARLOCK")
        and sourceName and sourceName ~= ""
        and destGUID and destGUID == self.playerGUID then
        if self.values.DUEL_SUCCUBUS ~= sourceName then
            self.values.DUEL_SUCCUBUS = sourceName
            categories = categories or {}
            table.insert(categories, "DUEL")
        end
        self:SaveSuccubus(self.values.DUEL_NAME, sourceName)
    end

    -- Gladdy-style spec inference from spec-defining casts stays
    -- target-only by design -- SpecData.specSpells exists specifically to
    -- infer the *target's* spec from what it casts (§9).
    if upperName and sourceGUID == self.targetGUID then
        local specSpells = addon.SpecData and addon.SpecData.specSpells
        local spec = specSpells and specSpells[upperName]
        if spec and self:SetSpec(sourceGUID, spec, "SPELL") then
            categories = categories or {}
            table.insert(categories, "SPEC")
        end
    end

    return categories
end

function State:RequestTargetInspect()
    if addon:IsInCombat() or not NotifyInspect or not CanInspect or not UnitExists("target") then
        return
    end
    if not UnitIsVisible or not UnitIsVisible("target") or not CanInspect("target") then
        return
    end
    local guid = UnitGUID("target")
    if not guid then
        return
    end
    -- Throttle: 60s after a successful inspect, 3s retry when we have no result.
    local throttle = self.specTimeByGUID[guid] and 60 or 3
    if self.inspectGUID == guid and now() - self.inspectTime < throttle then
        return
    end
    self.inspectGUID = guid
    self.inspectTime = now()
    NotifyInspect("target")
end

function State:HandleInspectReady()
    if not self.inspectGUID or not UnitExists("target") then
        return false
    end
    local guid = UnitGUID("target")
    if guid ~= self.inspectGUID then
        return false
    end
    local spec = getTalentSpec("target", true)
    if not spec then
        return false
    end
    return self:SetSpec(guid, spec, "INSPECT")
end

-- ---------------------------------------------------------------------------
-- Duel tracking
--
-- The 3.3.5a client exposes no "duel started" event (DUEL_STARTING and
-- DUEL_CANCELLED do not exist here): the observable signals are
-- DUEL_REQUESTED (incoming challenge, challenger name), the StartDuel hook
-- (outgoing challenge), DUEL_OUTOFBOUNDS/DUEL_INBOUNDS (fire only during an
-- active duel), and DUEL_FINISHED (the duel ended). So the challenge itself
-- is the activation: the opponent's name/class go live immediately (before
-- they can stealth), and duel macros are ready through the accept window and
-- countdown. Because a declined or ignored challenge produces no event, an
-- activation carries a pending deadline: real duel activity (combat-log
-- traffic involving the opponent, bounds events, the opponent's flag flip)
-- cancels it; otherwise the state is assumed declined and wiped on expiry.
-- The latest challenge always wins and re-triggers a recompile. No
-- persistent cache: a duel is a single bounded encounter.
-- ---------------------------------------------------------------------------

local DUEL_PENDING_SECONDS = 60

function State:ClearDuel()
    self.duelActive = nil
    self.duelPendingUntil = nil
    self.values.DUEL = nil
    self.values.DUEL_NAME = nil
    self.values.DUEL_SUCCUBUS = nil
    self:RefreshDuelOpponent()
end

-- ---------------------------------------------------------------------------
-- Succubus book: warlock name -> that warlock's succubus name, persisted in
-- WMacroCompilerDB.duelSuccubi so a returning opponent's SUCCUBUS
-- placeholder is populated from the challenge onward. Keys are the
-- uppercased warlock name (the codebase compares names uppercased); the
-- value keeps the pet's original casing. `seen` (wall-clock time()) is
-- refreshed whenever an entry is captured or recalled, so the oldest-seen
-- entry is the one evicted at SUCCUBUS_BOOK_MAX.
-- ---------------------------------------------------------------------------
function State:SuccubusBook()
    return addon.db and addon.db.duelSuccubi
end

-- Returns the stored succubus name for a warlock, or nil. `touch` marks the
-- entry as recently used.
function State:LookupSuccubus(warlockName, touch)
    local book = self:SuccubusBook()
    local entry = book and warlockName and book[string.upper(warlockName)]
    if not entry then
        return nil
    end
    if touch then
        entry.seen = time and time() or 0
    end
    return entry.name
end

function State:SaveSuccubus(warlockName, petName)
    local book = self:SuccubusBook()
    if not book or not warlockName or warlockName == "" or not petName or petName == "" then
        return
    end
    local key = string.upper(warlockName)
    book[key] = { name = petName, warlock = warlockName, seen = time and time() or 0 }
    self:PruneSuccubusBook(key)
end

-- Evicts oldest-seen entries until the book is within SUCCUBUS_BOOK_MAX,
-- never the entry just written (keepKey).
function State:PruneSuccubusBook(keepKey)
    local book = self:SuccubusBook()
    if not book then
        return
    end
    local count = 0
    for _ in pairs(book) do
        count = count + 1
    end
    while count > SUCCUBUS_BOOK_MAX do
        local oldestKey, oldestSeen
        for key, entry in pairs(book) do
            if key ~= keepKey then
                local seen = entry.seen or 0
                if not oldestSeen or seen < oldestSeen then
                    oldestKey, oldestSeen = key, seen
                end
            end
        end
        if not oldestKey then
            return
        end
        book[oldestKey] = nil
        count = count - 1
    end
end

-- Returns the book as a name-sorted array of { warlock, name } rows
-- (warlock in its original casing when recorded, else the uppercased key),
-- optionally narrowed to rows whose warlock or succubus name contains
-- `filter` (case-insensitive, plain-text match), plus the unfiltered total.
function State:ListSuccubi(filter)
    local book = self:SuccubusBook()
    local rows, total = {}, 0
    if not book then
        return rows, total
    end
    local wanted = filter and filter ~= "" and string.upper(filter) or nil
    for key, entry in pairs(book) do
        total = total + 1
        local pet = entry.name or "?"
        if not wanted or key:find(wanted, 1, true) or string.upper(pet):find(wanted, 1, true) then
            table.insert(rows, { warlock = entry.warlock or key, name = pet })
        end
    end
    table.sort(rows, function(a, b)
        return string.upper(a.warlock) < string.upper(b.warlock)
    end)
    return rows, total
end

-- Manually stores a succubus name for a warlock (for names learned outside
-- the addon). Overwrites any existing entry. Returns true when stored, plus
-- liveChanged: true when that warlock is the current duel opponent and the
-- live DUEL_SUCCUBUS value changed, so the caller must recompile
-- DUEL-watching templates.
function State:AddSuccubus(warlockName, petName)
    if not self:SuccubusBook() or not warlockName or warlockName == "" or not petName or petName == "" then
        return false, false
    end
    self:SaveSuccubus(warlockName, petName)
    local liveChanged = false
    if self.values.DUEL_NAME and string.upper(self.values.DUEL_NAME) == string.upper(warlockName)
        and self.values.DUEL_SUCCUBUS ~= petName then
        self.values.DUEL_SUCCUBUS = petName
        liveChanged = true
    end
    return true, liveChanged
end

-- Removes a warlock's whole entry (key, pet name, and timestamp) from the
-- book. Returns removed, liveChanged: liveChanged is true when that warlock
-- is the current duel opponent and the live DUEL_SUCCUBUS value was dropped
-- too, so the caller must recompile DUEL-watching templates.
function State:ForgetSuccubus(warlockName)
    local book = self:SuccubusBook()
    if not book or not warlockName or warlockName == "" then
        return false, false
    end
    local key = string.upper(warlockName)
    if not book[key] then
        return false, false
    end
    book[key] = nil
    local liveChanged = false
    if self.values.DUEL_NAME and string.upper(self.values.DUEL_NAME) == key
        and self.values.DUEL_SUCCUBUS ~= nil then
        self.values.DUEL_SUCCUBUS = nil
        liveChanged = true
    end
    return true, liveChanged
end

-- Resolves values["COMBAT:DUELOPPONENT"] (§5.8) and the AURA mirror
-- below. There is no unit token for
-- "the duel opponent" -- UnitAffectingCombat only accepts real unit IDs
-- (target, arena1, partyN, ...), and duels are identified by name only, so
-- a name can never be fed to it directly. The only live read available is
-- borrowing the TARGET unit's own COMBAT:TARGET, and only while TARGET
-- provably *is* the duel opponent (DUEL_NAME matched against the current
-- target's NAME) -- targeting something else mid-duel must never silently
-- inherit that other unit's combat status.
--
-- Three-way result, matching the existing "absent vs. unknown" convention:
--   * No duel is active at all: nil (the address doesn't exist, exactly
--     like an empty arena slot -- never matches, negated or not, and
--     #WATCH COMBAT ASSUME does not apply to it).
--   * A duel is active but TARGET isn't confirmed to be the opponent (no
--     target, or a different one): "UNKNOWN" -- the opponent demonstrably
--     exists, but its live status can't currently be read, the same
--     "exists but unassessable" state a stealthed arena opponent produces.
--     This is what makes #WATCH COMBAT ASSUME=YES/NO apply here (the
--     overlay in CompileValuesFor rewrites "UNKNOWN", never nil).
--   * A duel is active and TARGET matches: whatever COMBAT:TARGET currently
--     reads (itself already YES/NO/UNKNOWN -- e.g. UNKNOWN if the opponent
--     is targeted but has gone invisible/stealthed).
--
-- AURA:DUELOPPONENT (§5.7) borrows the same way, but two-way: TARGET's
-- value while TARGET is the opponent, otherwise nil (an aura set has no
-- "exists but unassessable" state to fall back on, so an untargeted
-- opponent reads as unknown -- never matches, negated or not).
--
-- Called directly by every event that can change any of these inputs
-- (RefreshTarget, the UNIT_FLAGS handler for "target", the target's aura
-- scan, ActivateDuel, ClearDuel) rather than through the unit maps, since
-- there is no real unit event for it. Returns true when any visible value
-- changed.
local DUEL_MIRRORED = { "AURA" }
function State:RefreshDuelOpponent()
    local status
    local isTarget = false
    if self.duelActive and self.values.DUEL_NAME then
        if self.values.NAME and string.upper(self.values.NAME) == string.upper(self.values.DUEL_NAME) then
            status = self.values["COMBAT:TARGET"]
            isTarget = true
        else
            status = "UNKNOWN"
        end
    end
    local changed = self.values["COMBAT:DUELOPPONENT"] ~= status
    self.values["COMBAT:DUELOPPONENT"] = status
    for _, prefix in ipairs(DUEL_MIRRORED) do
        local key = prefix .. ":DUELOPPONENT"
        local value = isTarget and self.values[prefix .. ":TARGET"] or nil
        if self.values[key] ~= value then
            changed = true
        end
        self.values[key] = value
    end
    return changed
end

-- Captures the class of the player's current target when its name matches
-- the given opponent name. Returns the class token (or nil).
function State:CaptureClassFromTarget(name)
    if not name or not UnitExists or not UnitExists("target") or not UnitName then
        return nil
    end
    local targetName = UnitName("target")
    if not targetName or string.upper(targetName) ~= string.upper(name) then
        return nil
    end
    local _, token = UnitClass("target")
    return token
end

-- Challenge activation: the opponent's name/class go live now and the
-- pending deadline starts. When capture never resolved a class, DUEL carries
-- a known name but an unknown class (condition matching falls through per
-- the unknown-never-matches rule, unless a template declares #WATCH DUEL
-- ASSUME; DUEL=ANY still matches, since the duel itself is live). Returns
-- true when an activation happened.
function State:ActivateDuel(name, class)
    if not name or name == "" then
        return nil
    end
    self:RefreshNow()
    self.duelActive = true
    self.values.DUEL = class
    self.values.DUEL_NAME = name
    -- A returning warlock's succubus name comes straight from the book, so
    -- SUCCUBUS-gated branches are ready before the countdown ends. Always
    -- re-read it (rather than carrying the live value over): a different
    -- opponent must not inherit the previous one's name, and a repeat
    -- challenge from the same one finds anything learned mid-duel already
    -- saved.
    self.values.DUEL_SUCCUBUS = self:LookupSuccubus(name, true)
    self.duelPendingUntil = self.values._NOW + DUEL_PENDING_SECONDS
    self:RefreshReaction()
    self:RefreshDuelOpponent()
    return true
end

-- The duel provably started: cancel the pending deadline; the state then
-- persists until DUEL_FINISHED (or a world change) no matter how long the
-- duel runs.
function State:ConfirmDuel()
    self.duelPendingUntil = nil
end

-- Deadline watchdog driven by the core duel timer. An unconfirmed pending
-- duel whose deadline has passed is assumed declined/ignored and wiped.
-- Returns true when a wipe happened (an ordinary watched-field change).
function State:TickDuel()
    if not self.duelPendingUntil then
        return false
    end
    self:RefreshNow()
    if self.values._NOW < self.duelPendingUntil then
        return false
    end
    self:HandleDuelFinished()
    self:RefreshReaction()
    return true
end

-- Incoming challenge (DUEL_REQUESTED, arg1 = challenger name): activate
-- immediately. Returns true when an activation happened.
function State:HandleDuelRequested(name)
    if not name or name == "" then
        return nil
    end
    -- The class is read off the current target when it is the challenger;
    -- otherwise it resolves later, when the player targets them (see
    -- RefreshTarget). There is no auto-target: TargetUnit is protected.
    local class = self:CaptureClassFromTarget(name)
    return self:ActivateDuel(name, class)
end

-- Outgoing challenge (the client sends no event for duels we start; core
-- hooks StartDuel, the same global /duel and the unit menu both go through).
-- The argument is a unit token, a plain name, or nil (current target).
-- Returns true when an activation happened.
function State:HandleStartDuel(unit)
    local name, class
    if unit and unit ~= "" then
        if UnitExists and UnitExists(unit) then
            name = UnitName and UnitName(unit)
            local _, token = UnitClass(unit)
            class = token
        else
            name = unit -- plain name string
        end
    elseif UnitExists and UnitExists("target") then
        name = UnitName and UnitName("target")
        local _, token = UnitClass("target")
        class = token
    end
    return self:ActivateDuel(name, class)
end

function State:HandleDuelFinished()
    self:ClearDuel()
end

function State:Initialize()
    self.values = { _UNITAURA = {} }
    self.pins = {}
    self.specByGUID = {}
    self.specTimeByGUID = {}
    self.specSourceByGUID = {}
    self.specSeenByGUID = {}
    self.targetGUID = nil
    self.playerGUID = nil
    self.inspectGUID = nil
    self.inspectTime = 0
    self.arenaSighted = {}
    self.arenaClass = {}
    self.duelActive = nil
    self.duelPendingUntil = nil
    self.cooldownWanted = {}
    self.cooldownSpells = {}
    self.cooldownItems = {}
    self.unknownCooldownWarned = {}
    self:RememberCurrentMutes()
    self:RefreshNow()
    self:ScanSpellbook()
    self:ScanItems()
    self:RefreshPlayer()
    self:RefreshInstance()
    self:RefreshArena()
    self:RefreshParty()
    self.groupSignature = nil
    self:RefreshGroup()
    self:RefreshFlags()
    self:RefreshFocus()
    self:RefreshTarget()
    self:RefreshPet()
    self:ScanUnitAuras("player", "SELF")
    self:RefreshPlayerCooldowns()
    self:SyncPlayerSpec()
    self.initialized = true
end

function State:HandleEvent(event, ...)
    local unit = select(1, ...)
    local categories = {}
    self:RefreshNow()
    if event == "PLAYER_ENTERING_WORLD" then
        self:RefreshPlayer()
        self:RefreshInstance()
        self:ScanSpellbook()
        self:ScanItems()
        self:ClearDuel()
        -- A new match/world: arena sighting state resets and the
        -- tracked-cooldown set is rebuilt.
        self.arenaSighted = {}
        self.arenaClass = {}
        self:RefreshArena()
        self:RefreshParty()
        self:RefreshFocus()
        self:RefreshTarget()
        self:ScanUnitAuras("player", "SELF")
        self:RefreshPet()
        self:RefreshGroup()
        local cooldownChanged = self:SetCooldownWatches(self.cooldownWanted)
        categories = { "PLAYER_SPEC", "INSTANCE", "ZONE", "CLASS", "SPEC", "NAME", "AURA", "ARENA", "REACTION", "PARTY", "DUEL", "COMBAT", "PET", "GROUP" }
        if cooldownChanged then
            table.insert(categories, "PLAYER_CD")
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        local duelChanged = self:RefreshTarget()
        categories = { "CLASS", "SPEC", "NAME", "AURA", "REACTION", "COMBAT" }
        if duelChanged then
            table.insert(categories, "DUEL")
        end
    elseif event == "ARENA_OPPONENT_UPDATE" then
        -- arg2 is the reason: "seen", "unseen", "destroyed" or "cleared".
        -- "cleared" empties the slot, so its sticky class goes too; an
        -- "unseen" (stealthed) opponent keeps it.
        local reason = select(2, ...)
        local index = type(unit) == "string" and tonumber(unit:match("^arena(%d)$") or "")
        if reason == "cleared" and index and self.arenaClass then
            self.arenaClass[index] = nil
        end
        local auraChanged, combatChanged = self:RefreshArena()
        categories = { "ARENA" }
        if auraChanged then
            table.insert(categories, "AURA")
        end
        if combatChanged then
            table.insert(categories, "COMBAT")
        end
    elseif event == "RAID_ROSTER_UPDATE" then
        -- Joins, leaves, subgroup moves and main tank / main assist
        -- assignments all arrive here.
        if self:RefreshGroup() then
            categories = { "GROUP" }
        end
    elseif event == "PARTY_MEMBER_DISABLE" or event == "PARTY_MEMBER_ENABLE" then
        -- A member went offline / came back: offline members stop resolving.
        if self:RefreshGroup() then
            categories = { "GROUP" }
        end
    elseif event == "UNIT_NAME_UPDATE" then
        -- A member whose name was still "Unknown" when the roster was read.
        if type(unit) == "string" and (unit:match("^raid%d") or unit:match("^party%d"))
            and self:RefreshGroup() then
            categories = { "GROUP" }
        end
    elseif event == "PARTY_MEMBERS_CHANGED" then
        local auraChanged, combatChanged = self:RefreshParty()
        categories = { "PARTY" }
        if self:RefreshGroup() then
            table.insert(categories, "GROUP")
        end
        if auraChanged then
            table.insert(categories, "AURA")
        end
        if combatChanged then
            table.insert(categories, "COMBAT")
        end
    elseif event == "PLAYER_FOCUS_CHANGED" then
        local auraChanged, combatChanged = self:RefreshFocus()
        if auraChanged then
            table.insert(categories, "AURA")
        end
        if combatChanged then
            table.insert(categories, "COMBAT")
        end
    elseif event == "UNIT_FLAGS" then
        local address = combatUnitAddress[unit]
        if address and self:ScanUnitCombat(unit, address) then
            categories = { "COMBAT" }
            if address == "TARGET" then
                -- DUELOPPONENT mirrors COMBAT:TARGET whenever they're the
                -- same unit (§5.8); keep it in lockstep. No separate
                -- category needed -- "COMBAT" above already covers both
                -- addresses under the one #WATCH COMBAT line.
                self:RefreshDuelOpponent()
            end
        end
    elseif event == "SPELL_UPDATE_COOLDOWN" or event == "BAG_UPDATE_COOLDOWN" then
        if self:RefreshPlayerCooldowns() then
            categories = { "PLAYER_CD" }
        end
    elseif event == "BAG_UPDATE" or event == "PLAYER_EQUIPMENT_CHANGED" then
        -- A PLAYER_CD item looted or equipped after login resolves now.
        if self:HasUnresolvedCooldowns() then
            self:ScanItems()
            if self:SetCooldownWatches(self.cooldownWanted) then
                categories = { "PLAYER_CD" }
            end
        end
    elseif event == "SPELLS_CHANGED" then
        self:ScanSpellbook()
        if self:SetCooldownWatches(self.cooldownWanted) then
            categories = { "PLAYER_CD" }
        end
    elseif event == "UNIT_FACTION" then
        if unit == "target" then
            self:RefreshReaction()
            categories = { "REACTION" }
            -- A targeted duel opponent's flag flip confirms the duel began.
            if self.duelPendingUntil and self.values.DUEL_NAME and self.values.NAME
                and string.upper(self.values.DUEL_NAME) == self.values.NAME then
                self:ConfirmDuel()
            end
        end
    elseif event == "UNIT_PET" then
        -- Fires with the pet's owner as the unit arg; only the player's
        -- own pet is tracked (see RefreshPet's comment on why no
        -- inference/caching is needed here, unlike CLASS/SPEC/ARENA).
        if unit == "player" and self:RefreshPet() then
            categories = { "PET" }
        elseif unit ~= "player" and self:RefreshGroup() then
            -- A group member's pet came or went: ROGUEPET-style group
            -- placeholders point at raidpetN / partypetN tokens.
            categories = { "GROUP" }
        end
    elseif event == "DUEL_REQUESTED" then
        -- arg1 is the challenger's name; the challenge itself activates.
        if self:HandleDuelRequested(unit) then
            -- COMBAT: DUELOPPONENT goes from absent to a real (if possibly
            -- "UNKNOWN") value the instant the duel activates.
            categories = { "DUEL", "REACTION", "COMBAT", "AURA" }
        end
    elseif event == "DUEL_OUTOFBOUNDS" or event == "DUEL_INBOUNDS" then
        -- Bounds events fire only during an active duel: confirmation only,
        -- no watched field changes.
        self:ConfirmDuel()
    elseif event == "DUEL_FINISHED" then
        self:HandleDuelFinished()
        self:RefreshReaction()
        -- COMBAT: DUELOPPONENT reverts to absent (ClearDuel already called
        -- RefreshDuelOpponent internally via HandleDuelFinished).
        categories = { "DUEL", "REACTION", "COMBAT", "AURA" }
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        categories = self:HandleCombatLog(...) or {}
    elseif event == "UNIT_AURA" then
        if unit == "target" then
            local specChanged, auraChanged = self:ScanTargetAuras()
            if specChanged then
                table.insert(categories, "SPEC")
            end
            if auraChanged then
                table.insert(categories, "AURA")
            end
        else
            local address = auraUnitAddress[unit]
            if address and self:ScanUnitAuras(unit, address) then
                table.insert(categories, "AURA")
            elseif self.groupAurasWanted and type(unit) == "string" and unit:match("^raid%d+$")
                and self:StoreUnitAuras(unit) then
                table.insert(categories, "AURA")
            end
        end
    elseif event == "INSPECT_TALENT_READY" then
        if self:HandleInspectReady() then
            categories = { "SPEC" }
        end
    elseif event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        self:RefreshPlayer()
        self:ScanSpellbook()
        categories = { "PLAYER_SPEC" }
        if self:SetCooldownWatches(self.cooldownWanted) then
            table.insert(categories, "PLAYER_CD")
        end
        if self:SyncPlayerSpec() then
            table.insert(categories, "SPEC")
        end
    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED_INDOORS" then
        self:RefreshInstance()
        categories = { "INSTANCE", "ZONE" }
    end
    return categories
end
