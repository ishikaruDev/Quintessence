local addon = WMacroCompiler or {}
WMacroCompiler = addon

addon.version = "0.1.0"
addon.MAX_MACROTEXT = 1023
addon.runtime = addon.runtime or {
    active = {},
    byId = {},
    pendingRebuild = false,
    inCombat = false,
}

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isInCombat()
    if InCombatLockdown then
        return InCombatLockdown()
    end
    return UnitAffectingCombat and UnitAffectingCombat("player") or false
end

local classScopes = {
    DEATHKNIGHT = true,
    DRUID = true,
    HUNTER = true,
    MAGE = true,
    PALADIN = true,
    PRIEST = true,
    ROGUE = true,
    SHAMAN = true,
    WARLOCK = true,
    WARRIOR = true,
}

function addon:IsInCombat()
    return self.runtime.inCombat or isInCombat()
end

-- The display name (window title, minimap tooltip). The internal names --
-- WMC_ buttons, WMacroCompilerDB, the !WMC: export header -- stay as they
-- are on a rename (/wmc stays as a second name for /qmc).
addon.TITLE = "Quintessence Compiler"

function addon:Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffQMC:|r " .. tostring(message))
end

function addon:TemplateId(scope, name)
    return scope .. ":" .. name
end

function addon:ValidateName(name)
    if type(name) ~= "string" then
        return nil, "Button name is required."
    end
    name = trim(name)
    if name == "" then
        return nil, "Button name is required."
    end
    if not name:match("^[A-Za-z0-9_]+$") then
        return nil, "Button name may contain only letters, numbers, and underscores."
    end
    if #name > 40 then
        return nil, "Button name is too long."
    end
    if name == "EventFrame" or name == "MainFrame" or name == "CategoryMenu" or name == "MacroMenu"
        or name:match("^INTERNAL_") then
        return nil, "That button name is reserved by the addon."
    end
    return name
end

function addon:NormalizeScope(scope)
    scope = string.upper(trim(scope or ""))
    if scope == "GENERAL" then
        return scope
    end
    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[scope] then
        return scope
    end
    local _, playerClass = UnitClass("player")
    if scope == "" and playerClass then
        return playerClass
    end
    return scope
end

-- Flag names used by FLAG=<NAME> in a template source, memoized by source
-- text (the editor asks on every refresh; parsing happens once per edit).
local flagNameCache, flagNameCacheSize = {}, 0
local function flagNamesInSource(source)
    local cached = flagNameCache[source]
    if cached then
        return cached
    end
    local names = {}
    local parsed = addon.Compiler.Parse(source)
    if parsed then
        for name in pairs(addon.Compiler.CollectFlagNames(parsed)) do
            table.insert(names, name)
        end
    end
    if flagNameCacheSize >= 300 then
        flagNameCache, flagNameCacheSize = {}, 0
    end
    flagNameCache[source] = names
    flagNameCacheSize = flagNameCacheSize + 1
    return names
end

-- Every flag the player can switch: the flags currently on plus every
-- FLAG=<NAME> used by this character's class templates and GENERAL ones,
-- so a flag that is off is still one click away. Sorted, with its state:
-- { { name = "WPVP", on = true }, ... }.
function addon:KnownFlags()
    local known = {}
    for _, name in ipairs(self.State and self.State:ActiveFlags() or {}) do
        known[name] = true
    end
    local templates = self.db and self.db.templates or {}
    local _, playerClass = UnitClass("player")
    for _, scope in ipairs({ "GENERAL", playerClass }) do
        for _, record in pairs(templates[scope] or {}) do
            if record.source then
                for _, name in ipairs(flagNamesInSource(record.source)) do
                    known[name] = true
                end
            end
        end
    end
    local active = self.State and self.State.values.FLAG or {}
    local list = {}
    for name in pairs(known) do
        table.insert(list, { name = name, on = active[name] and true or false })
    end
    table.sort(list, function(a, b)
        return a.name < b.name
    end)
    return list
end

function addon:NameConflict(scope, name, excludedId)
    local templates = self.db and self.db.templates or {}
    local function exists(checkScope)
        local record = templates[checkScope] and templates[checkScope][name]
        return record and self:TemplateId(checkScope, name) ~= excludedId
    end

    if scope == "GENERAL" then
        for checkScope, values in pairs(templates) do
            if values[name] and self:TemplateId(checkScope, name) ~= excludedId then
                return true, checkScope
            end
        end
    elseif exists("GENERAL") then
        return true, "GENERAL"
    elseif exists(scope) then
        return true, scope
    end
    return false
end

function addon:DefaultDatabase()
    WMacroCompilerDB = WMacroCompilerDB or {}
    WMacroCompilerDB.templates = WMacroCompilerDB.templates or {}
    WMacroCompilerDB.templates.GENERAL = WMacroCompilerDB.templates.GENERAL or {}
    WMacroCompilerDB.categories = WMacroCompilerDB.categories or {}
    WMacroCompilerDB.settings = WMacroCompilerDB.settings or {}
    -- Learned data, not configuration: uppercased warlock name ->
    -- { name = <succubus name>, seen = <time()> } (see State:SaveSuccubus).
    WMacroCompilerDB.duelSuccubi = WMacroCompilerDB.duelSuccubi or {}
    -- Learned data: uppercased item name -> item ID, for PLAYER_CD on
    -- used items (see State:ScanItems).
    WMacroCompilerDB.itemIDs = WMacroCompilerDB.itemIDs or {}
    self.db = WMacroCompilerDB
end

-- Categories are per-scope, purely organizational UI groups; they never
-- affect naming rules, compilation, or the secure runtime.
local UNCATEGORIZED = "Uncategorized"

function addon:ValidateCategoryName(scope, name)
    if type(name) ~= "string" then
        return nil, "Category name is required."
    end
    name = trim(name)
    if name == "" then
        return nil, "Category name is required."
    end
    if #name > 30 then
        return nil, "Category name is too long."
    end
    if string.upper(name) == string.upper(UNCATEGORIZED) then
        return nil, "That category name is reserved."
    end
    local categories = self.db and self.db.categories[scope]
    if categories then
        local wanted = string.upper(name)
        for existing in pairs(categories) do
            if string.upper(existing) == wanted then
                return nil, "A category with that name already exists."
            end
        end
    end
    return name
end

function addon:CreateCategory(scope, name)
    scope = self:NormalizeScope(scope)
    local validName, nameError = self:ValidateCategoryName(scope, name)
    if not validName then
        return nil, nameError
    end
    local categories = self.db.categories[scope] or {}
    self.db.categories[scope] = categories
    categories[validName] = { collapsed = false }
    if self.UI then
        self.UI:RefreshList()
    end
    return true
end

function addon:RenameCategory(scope, oldName, newName)
    scope = self:NormalizeScope(scope)
    local categories = self.db.categories[scope]
    if not categories or not categories[oldName] then
        return nil, "Category not found."
    end
    if oldName == newName then
        return true, oldName
    end
    local validName, nameError = self:ValidateCategoryName(scope, newName)
    if not validName then
        return nil, nameError
    end
    categories[validName] = categories[oldName]
    categories[oldName] = nil
    local templates = self.db.templates[scope]
    if templates then
        for _, record in pairs(templates) do
            if record.category == oldName then
                record.category = validName
            end
        end
    end
    if self.UI then
        self.UI:RefreshList()
    end
    return true, validName
end

-- Deleting a category never deletes templates: members become uncategorized.
function addon:DeleteCategory(scope, name)
    scope = self:NormalizeScope(scope)
    local categories = self.db.categories[scope]
    if not categories or not categories[name] then
        return nil, "Category not found."
    end
    categories[name] = nil
    local templates = self.db.templates[scope]
    if templates then
        for _, record in pairs(templates) do
            if record.category == name then
                record.category = nil
            end
        end
    end
    if self.UI then
        self.UI:RefreshList()
    end
    return true
end

function addon:SetCategoryCollapsed(scope, name, collapsed)
    scope = self:NormalizeScope(scope)
    local categories = self.db.categories[scope]
    if not categories or not categories[name] then
        return nil, "Category not found."
    end
    categories[name].collapsed = collapsed and true or false
    if self.UI then
        self.UI:RefreshList()
    end
    return true
end

function addon:SetTemplateIcon(scope, name, icon)
    scope = self:NormalizeScope(scope)
    local record = self.db.templates[scope] and self.db.templates[scope][name]
    if not record then
        return nil, "Template not found."
    end
    record.icon = icon
    if self.UI then
        self.UI:RefreshList()
    end
    return true
end

function addon:SetTemplateCategory(scope, name, category)
    scope = self:NormalizeScope(scope)
    local record = self.db.templates[scope] and self.db.templates[scope][name]
    if not record then
        return nil, "Template not found."
    end
    if category ~= nil then
        local categories = self.db.categories[scope]
        if not categories or not categories[category] then
            return nil, "Category not found."
        end
    end
    record.category = category
    if self.UI then
        self.UI:RefreshList()
    end
    return true
end

function addon:BuildActiveTemplate(record, scope, name)
    local template = {
        id = self:TemplateId(scope, name),
        name = name,
        scope = scope,
        source = record.source or "",
        enabled = record.enabled ~= false,
        compilePolicy = "QUEUE",
        watchSet = {},
        dirty = false,
        output = nil,
        branch = nil,
        error = nil,
        frameNames = {},
    }

    local parsed, parseError = self.Compiler.Parse(template.source)
    if parsed then
        self.Compiler.ApplyMutes(parsed, self:MuteTable())
        template.parsed = parsed
        template.compilePolicy = parsed.compilePolicy
        template.watchSet = parsed.watchSet
    else
        template.error = parseError
        -- Kept separately so a later successful compile (against a carried-
        -- over older parse) doesn't erase the saved source's error marker.
        template.parseError = parseError
    end
    return template
end

function addon:ClearActiveTemplates()
    for _, template in ipairs(self.runtime.active) do
        self.Secure.Remove(template)
    end
    self.runtime.active = {}
    self.runtime.byId = {}
end

function addon:AddActiveTemplate(scope, name, record)
    local template = self:BuildActiveTemplate(record, scope, name)
    table.insert(self.runtime.active, template)
    self.runtime.byId[template.id] = template
    return template
end


function addon:RemoveActiveTemplate(id)
    local template = self.runtime.byId[id]
    if not template then
        return
    end
    self.Secure.Remove(template)
    self.runtime.byId[id] = nil
    for index, active in ipairs(self.runtime.active) do
        if active == template then
            table.remove(self.runtime.active, index)
            break
        end
    end
end

function addon:RebuildActiveTemplates()
    if self:IsInCombat() then
        self.runtime.pendingRebuild = true
        return false, "combat"
    end

    -- Rebuild in place: a template that still exists keeps its secure
    -- frames and last applied output (so a template that now fails to
    -- compile keeps its last valid button -- §7 step 7, §14), and only
    -- templates that are gone (deleted, renamed, disabled, moved) lose
    -- their frames.
    local previous = self.runtime.byId
    local previousList = self.runtime.active
    self.runtime.active = {}
    self.runtime.byId = {}
    local _, playerClass = UnitClass("player")
    local scopes = { "GENERAL", playerClass }
    for _, scope in ipairs(scopes) do
        local values = scope and self.db.templates[scope]
        if values then
            for name, record in pairs(values) do
                if record.enabled ~= false then
                    local template = self:AddActiveTemplate(scope, name, record)
                    local old = previous[template.id]
                    if old then
                        template.frameNames = old.frameNames or {}
                        template.primaryFrame = old.primaryFrame
                        template.sequenceHeader = old.sequenceHeader
                        template.lastAppliedOutput = old.lastAppliedOutput
                        template.output = old.output
                        template.branch = old.branch
                        template.lastReportedError = old.lastReportedError
                    end
                end
            end
        end
    end
    for _, old in ipairs(previousList) do
        if not self.runtime.byId[old.id] then
            self.Secure.Remove(old)
        end
    end
    self.runtime.pendingRebuild = false
    self:RebuildConditionRegistries()
    return true
end

-- Collects the spells referenced by the active templates' conditions so
-- observation stays scoped to what is actually watched: cooldown
-- tracking queries GetSpellCooldown only for listed spells (never a
-- blanket scan of every spell in the game). Likewise raid units' auras are
-- only scanned while an AURA:<PLACEHOLDER> address is in use, and the
-- .TIME threshold timer only runs for templates with a .TIME comparison.
function addon:RebuildConditionRegistries()
    local cooldowns = {}
    local groupAuras = false
    local timed
    local timedTemplates = {}
    local function scanGroups(groups)
        for _, group in ipairs(groups) do
            for _, condition in ipairs(group) do
                local field = condition.field
                if condition.placeholder then
                    groupAuras = true
                end
                if condition.measure == "TIME" then
                    timed = true
                end
                if field == "PLAYER_CD" then
                    for _, spell in ipairs(condition.values) do
                        cooldowns[spell] = true
                    end
                end
                -- VAR:<NAME> conditions (§5.9) need no special handling
                -- here: they hold no values of their own, and the
                -- #DECLARE body they point at is scanned separately below
                -- (every declare, referenced or not, so nothing is missed
                -- regardless of how deep a VAR reference chain goes).
            end
        end
    end
    for _, template in ipairs(self.runtime.active) do
        local parsed = template.parsed
        if parsed then
            timed = false
            for _, form in ipairs(parsed.forms) do
                scanGroups(form.groups)
            end
            if parsed.declares then
                for _, declared in pairs(parsed.declares) do
                    scanGroups(declared.groups)
                end
            end
            if timed then
                -- The answers it compiled with: the timer compares against
                -- these, so a crossing right after this rebuild is not missed.
                template.timeSignature = self.Compiler.TimeSignature(parsed, self:CompileValuesFor(parsed))
                table.insert(timedTemplates, template)
            end
        end
    end
    if self.State then
        self.State:SetCooldownWatches(cooldowns)
        self.runtime.groupAuras = groupAuras
        self.State:SetGroupAuraWatch(groupAuras or self.editorGroupAuras)
    end
    self.runtime.timedTemplates = timedTemplates
    if self.auraTimeTimer then
        if #timedTemplates > 0 then
            self.auraTimeTimer:Show()
        else
            self.auraTimeTimer:Hide()
        end
    end
end

-- The editor's source uses an AURA:<PLACEHOLDER> address: raid auras are
-- scanned for its preview too, even while no saved template needs them.
function addon:SetEditorGroupAuras(wanted)
    self.editorGroupAuras = wanted and true or false
    if self.State and self.State.initialized then
        self.State:SetGroupAuraWatch(self.runtime.groupAuras or self.editorGroupAuras)
    end
end

-- The values snapshot a template compiles against. Normally the shared
-- State.values; a template declaring "#WATCH ARENA ASSUME=<CLASS>" (inside
-- an arena) or "#WATCH DUEL ASSUME=<CLASS>" (during a duel with an
-- unresolved class) compiles against a shallow overlay instead: unsighted
-- arena slots / the duel class read as the assumed class FOR THIS TEMPLATE
-- ONLY. The assumption is evaluated fresh at matching time and is never
-- written back to shared state, so one template's guess can never
-- contaminate another template's view or outlive a real sighting. The
-- overlay's _RAW back-reference lets placeholder substitution keep reading
-- the real arena state (ASSUME affects condition matching only).
--
-- The editor's Preview-As (§13.5) passes its own base snapshot (the live
-- values with overrides applied -- Compiler.BuildPreviewValues) and the
-- facts ASSUME needs about it ({ sighted, opponentCount, duelActive }); the
-- overlay is built on top of that base, never on State.values.
function addon:CompileValuesFor(parsed, base, preview)
    local values = base or self.State.values
    if not parsed or (not parsed.arenaAssume and not parsed.duelAssume and not parsed.combatAssume) then
        return values
    end
    local overlay
    local function ensureOverlay()
        if overlay then
            return
        end
        overlay = {}
        for key, value in pairs(values) do
            overlay[key] = value
        end
    end
    if parsed.arenaAssume and values.INSTANCE == "ARENA" then
        ensureOverlay()
        local sighted = self.State.arenaSighted or {}
        local opponentCount = self.State.arenaOpponentCount
        if preview and preview.sighted then
            -- Previewed slots count as sighted, and the match is as big as
            -- the highest slot written, so ASSUME only fills the gaps.
            local merged = {}
            for index, seen in pairs(sighted) do
                merged[index] = seen
            end
            for index in pairs(preview.sighted) do
                merged[index] = true
            end
            sighted = merged
            opponentCount = math.max(opponentCount or 0, preview.opponentCount or 0)
        end
        -- A real match always has at least one opponent; 0 (or a missing
        -- API) means "unknown", so fall back to considering every slot.
        if not opponentCount or opponentCount < 1 then
            opponentCount = 5
        end
        local comp
        for index = 1, 5 do
            local key = "ARENA" .. index
            local class = overlay[key]
            if not class and not sighted[index] and index <= opponentCount then
                class = parsed.arenaAssume
                overlay[key] = class
            end
            if class then
                comp = comp or {}
                comp[class] = true
            end
        end
        overlay.COMP = comp
    end
    if parsed.duelAssume and (self.State.duelActive or (preview and preview.duelActive)) and values.DUEL == nil then
        ensureOverlay()
        overlay.DUEL = parsed.duelAssume
    end
    if parsed.combatAssume then
        -- #WATCH COMBAT ASSUME=YES/NO (§5.8): any COMBAT:<ADDRESS> value
        -- that's currently "UNKNOWN" (the unit exists but its live combat
        -- flag can't be assessed, e.g. a stealthed opponent) reads as the
        -- assumed value for this template only. COMBAT:COMP:<CLASS> needs
        -- no separate handling: it reads these same COMBAT:ARENAn keys
        -- straight out of `values` (combatCompConditionMatches in
        -- Compiler.lua), so overlaying them here already covers it.
        ensureOverlay()
        local combatAddresses = {
            "TARGET", "FOCUS", "DUELOPPONENT",
            "PARTY1", "PARTY2", "PARTY3", "PARTY4",
            "ARENA1", "ARENA2", "ARENA3", "ARENA4", "ARENA5",
        }
        for _, address in ipairs(combatAddresses) do
            local key = "COMBAT:" .. address
            if overlay[key] == "UNKNOWN" then
                overlay[key] = parsed.combatAssume
            end
        end
    end
    if not overlay then
        return values
    end
    overlay._RAW = values
    return overlay
end

function addon:CompileTemplate(template, defaultOnly)
    if not template.parsed then
        return nil, template.error or "Template could not be parsed."
    end
    local output, branch, compileError = self.Compiler.Compile(template.parsed, self:CompileValuesFor(template.parsed), defaultOnly)
    if not output then
        template.error = compileError
        return nil, compileError
    end
    template.error = template.parseError
    template.previewOutput = output
    template.previewBranch = branch
    if not defaultOnly then
        template.output = output
        template.branch = branch
    end
    return output, branch
end

function addon:CompileDefault(template)
    local output, branchOrError = self:CompileTemplate(template, true)
    if not output then
        return nil, branchOrError
    end
    template.output = output
    template.branch = "DEFAULT"
    template.dirty = false
    local ok, applyError = self.Secure.Apply(template, output)
    if not ok then
        template.dirty = true
        return nil, applyError
    end
    return true
end

function addon:CompileCurrent(template)
    local output, branchOrError = self:CompileTemplate(template, false)
    if not output then
        template.dirty = false
        if template.lastReportedError ~= branchOrError then
            template.lastReportedError = branchOrError
            self:Print(template.name .. ": " .. branchOrError)
        end
        -- Nothing valid was ever applied to this button (e.g. a new
        -- template whose very first compile ties): fall back to #DEFAULT,
        -- the same output login would give it, rather than no button at all.
        if not template.lastAppliedOutput and template.parsed then
            local fallback = self.Compiler.Compile(template.parsed, self:CompileValuesFor(template.parsed), true)
            if fallback then
                self.Secure.Apply(template, fallback)
            end
        end
        return nil, branchOrError
    end
    template.lastReportedError = nil
    template.dirty = false
    if self.Compiler.SameOutput(output, template.lastAppliedOutput) then
        return true
    end
    local ok, applyError = self.Secure.Apply(template, output)
    if not ok then
        template.dirty = true
        return nil, applyError
    end
    template.lastAppliedOutput = output
    return true
end

function addon:CompileAllDefaults()
    for _, template in ipairs(self.runtime.active) do
        local output, compileError = self:CompileDefault(template)
        if not output then
            self:Print(template.name .. ": " .. compileError)
        end
    end
end

function addon:CompileAllCurrent()
    for _, template in ipairs(self.runtime.active) do
        if self:IsInCombat() then
            return
        end
        self:CompileCurrent(template)
    end
end

function addon:HandleStateChange(categories)
    for _, category in ipairs(categories) do
        if category == "PLAYER_SPEC" and self.Keys then
            self.Keys:SpecChanged()
        end
    end
    local listChanged = false
    for _, template in ipairs(self.runtime.active) do
        local wasDirty, hadError = template.dirty, template.error
        local interested = false
        for _, category in ipairs(categories) do
            if template.watchSet[category] then
                interested = true
                break
            end
        end
        if interested then
            if self:IsInCombat() then
                if template.compilePolicy == "QUEUE" then
                    template.dirty = true
                end
            else
                self:CompileCurrent(template)
            end
        end
        if template.dirty ~= wasDirty or template.error ~= hadError then
            listChanged = true
        end
    end
    if self.UI then
        -- Coalesced: high-frequency events (auras, combat log) redraw the
        -- editor at most a few times per second, and the template list only
        -- when a row's dirty/error state actually changed.
        self.UI:RequestRefresh(listChanged)
    end
end

function addon:FlushDirty()
    if self:IsInCombat() then
        return
    end
    -- Compile against the state at this exact instant (a timed window that
    -- elapsed during combat has already reverted; one still live applies).
    if self.State and self.State.RefreshNow then
        self.State:RefreshNow()
    end
    if self.runtime.pendingRebuild then
        if not self:RebuildActiveTemplates() then
            return
        end
        self:CompileAllCurrent()
    else
        for _, template in ipairs(self.runtime.active) do
            if template.dirty then
                if self:IsInCombat() then
                    break
                end
                self:CompileCurrent(template)
            end
        end
    end
    -- Rows lose their dirty marker and the status line its "pending until
    -- combat ends" note only if the UI is told the flush happened.
    if self.UI then
        self.UI:RefreshList()
        self.UI:RefreshSelected()
    end
end

-- isNew: this save creates a template (the editor's "Create", duplicate,
-- import). Without it, saving under a name that already exists in the same
-- scope would silently overwrite that template, since a save is otherwise
-- indistinguishable from re-saving the existing one.
function addon:SaveTemplate(scope, name, source, oldScope, oldName, enabled, isNew)
    scope = self:NormalizeScope(scope)
    if scope ~= "GENERAL" and not classScopes[scope] then
        return nil, "Unknown template scope: " .. tostring(scope)
    end
    local validName, nameError = self:ValidateName(name)
    if not validName then
        return nil, nameError
    end
    name = validName
    if isNew then
        oldScope, oldName = nil, nil
        if self.db.templates[scope] and self.db.templates[scope][name] then
            return nil, "A template named " .. name .. " already exists in " .. scope .. "."
        end
    end
    oldScope = oldScope and self:NormalizeScope(oldScope) or scope
    oldName = oldName or name
    local oldId = self:TemplateId(oldScope, oldName)
    local conflict, conflictScope = self:NameConflict(scope, name, oldId)
    if conflict then
        return nil, "Button name conflicts with " .. tostring(conflictScope) .. "."
    end

    local parsed, parseError = self.Compiler.Parse(source or "")
    local values = self.db.templates[scope] or {}
    self.db.templates[scope] = values
    -- Icon and category are UI metadata that survive saves and renames.
    local previous = (oldScope and self.db.templates[oldScope] and self.db.templates[oldScope][oldName])
        or values[name]
    if oldScope ~= scope or oldName ~= name then
        if self.db.templates[oldScope] then
            self.db.templates[oldScope][oldName] = nil
        end
    end
    local category = previous and previous.category
    if category and not (self.db.categories[scope] and self.db.categories[scope][category]) then
        category = nil -- category was deleted (or not in this scope)
    end
    values[name] = {
        name = name,
        scope = scope,
        source = source or "",
        enabled = enabled ~= false,
        icon = previous and previous.icon or nil,
        category = category,
    }

    -- Targeted runtime update: never rebuild unrelated templates. Only
    -- GENERAL templates and the player's own class run at runtime; saving
    -- another class's template must never create a live secure button.
    local _, playerClass = UnitClass("player")
    local runtimeScope = scope == "GENERAL" or scope == playerClass
    if self:IsInCombat() then
        self.runtime.pendingRebuild = true
    elseif not runtimeScope or enabled == false then
        -- Remove any stale active template (covers moving an active
        -- template to another class's scope, and disabling).
        local newId = self:TemplateId(scope, name)
        if oldId ~= newId then
            self:RemoveActiveTemplate(oldId)
        end
        self:RemoveActiveTemplate(newId)
    elseif parseError then
        -- Keep the last valid compiled button working; just record the error.
        local newId = self:TemplateId(scope, name)
        local existing = self.runtime.byId[oldId] or self.runtime.byId[newId]
        if existing and existing.id ~= newId then
            -- Renamed or moved with an invalid source: the old WMC_<old>
            -- frame must go (§15), but the last valid behaviour moves to
            -- the new name by carrying the previous parse over.
            local template = self:AddActiveTemplate(scope, name, values[name])
            template.parsed = existing.parsed
            template.watchSet = existing.watchSet
            template.compilePolicy = existing.compilePolicy
            local lastOutput = existing.lastAppliedOutput
            self:RemoveActiveTemplate(existing.id)
            if template.parsed then
                self:CompileCurrent(template)
            elseif lastOutput then
                self.Secure.Apply(template, lastOutput)
            end
            template.error = parseError
        elseif existing then
            existing.error = parseError
            existing.parseError = parseError
        else
            local template = self:AddActiveTemplate(scope, name, values[name])
            template.error = parseError
        end
    else
        local newId = self:TemplateId(scope, name)
        if oldId ~= newId then
            self:RemoveActiveTemplate(oldId)
        end
        self:RemoveActiveTemplate(newId)
        local template = self:AddActiveTemplate(scope, name, values[name])
        self:CompileCurrent(template)
    end

    if not self:IsInCombat() then
        self:RebuildConditionRegistries()
    end
    if self.Keys then
        -- Keys follow a rename or a move; a save may add or remove the button.
        local newId = self:TemplateId(scope, name)
        if oldId ~= newId then
            self.Keys:TemplateChanged(oldId, newId)
        else
            self.Keys:Apply()
        end
    end
    if self.UI then
        self.UI:RefreshList()
        self.UI:Select(scope, name)
    end
    return true, parseError
end

-- Enables/disables a saved template immediately (the editor's "Enabled"
-- checkbox), without touching its source or redrawing the editor, so
-- unsaved edits in the source box survive the toggle.
function addon:SetTemplateEnabled(scope, name, enabled)
    scope = self:NormalizeScope(scope)
    local record = self.db.templates[scope] and self.db.templates[scope][name]
    if not record then
        return nil, "Template not found."
    end
    enabled = enabled ~= false
    if (record.enabled ~= false) == enabled then
        return true
    end
    record.enabled = enabled
    local id = self:TemplateId(scope, name)
    local _, playerClass = UnitClass("player")
    local runtimeScope = scope == "GENERAL" or scope == playerClass
    if self:IsInCombat() then
        self.runtime.pendingRebuild = true
    elseif not enabled then
        self:RemoveActiveTemplate(id)
        self:RebuildConditionRegistries()
    elseif runtimeScope and not self.runtime.byId[id] then
        local template = self:AddActiveTemplate(scope, name, record)
        if template.parsed then
            self:CompileCurrent(template)
        end
        self:RebuildConditionRegistries()
    end
    if self.Keys then
        self.Keys:Apply()
    end
    if self.UI then
        self.UI:RefreshList()
    end
    return true
end

-- A free name for a new template in `scope`, starting from `base`
-- (base, base_2, base_3, ...), respecting every naming rule (§3).
function addon:UniqueName(scope, base)
    base = (base or "macro"):gsub("[^%w_]", "_")
    if base == "" then
        base = "macro"
    end
    base = base:sub(1, 36)
    local candidate = base
    local index = 1
    while self:NameConflict(scope, candidate) or not self:ValidateName(candidate) do
        index = index + 1
        candidate = base .. "_" .. index
        if index > 999 then
            return nil
        end
    end
    return candidate
end

-- Copies a template's metadata (icon, and category when it exists in the
-- target scope) from one record onto another saved record.
local function copyMetadata(self, fromRecord, scope, name)
    if fromRecord.icon then
        self:SetTemplateIcon(scope, name, fromRecord.icon)
    end
    local categories = self.db.categories[scope]
    if fromRecord.category and categories and categories[fromRecord.category] then
        self:SetTemplateCategory(scope, name, fromRecord.category)
    end
end

function addon:DuplicateTemplate(scope, name)
    scope = self:NormalizeScope(scope)
    local record = self.db.templates[scope] and self.db.templates[scope][name]
    if not record then
        return nil, "Template not found."
    end
    local newName = self:UniqueName(scope, name .. "_copy")
    if not newName then
        return nil, "Could not find a free name for the copy."
    end
    local ok, saveError = self:SaveTemplate(scope, newName, record.source or "", nil, nil, record.enabled ~= false, true)
    if not ok then
        return nil, saveError
    end
    copyMetadata(self, record, scope, newName)
    return newName
end

-- Moves a saved template to another scope (a class or GENERAL), keeping its
-- name, saved source, enabled state and icon; its category follows only if
-- the target scope has a category with that name (§4).
function addon:MoveTemplate(scope, name, newScope)
    scope = self:NormalizeScope(scope)
    newScope = self:NormalizeScope(newScope)
    local record = self.db.templates[scope] and self.db.templates[scope][name]
    if not record then
        return nil, "Template not found."
    end
    if scope == newScope then
        return true
    end
    return self:SaveTemplate(newScope, name, record.source or "", scope, name, record.enabled ~= false)
end

-- ---------------------------------------------------------------------------
-- Export / import. Readable text: one header line per template, followed by
-- its source verbatim:
--   !WMC:1 ROGUE vanish icon=Interface\Icons\Ability_Vanish
--   #WATCH CLASS
--   ...
-- Several templates can be concatenated. Categories are local organisation
-- and are not exported.
-- ---------------------------------------------------------------------------
-- Version 2 = a template that uses #MODE or #-- comment lines. An older
-- WMC would read those lines as plain macro text (unknown '#' lines in a
-- body pass through), silently changing what the macro does, so such a
-- template is exported as !WMC:2, which older versions reject as "newer".
-- Version 3 = a template that uses #PRE, #POST, #STEP or #SEQUENCE
-- (§5.17), for the same reason: an older WMC would run every step at once.
-- Everything else stays !WMC:1 and keeps importing everywhere.
local EXPORT_VERSION = 3

local function exportVersion(source)
    local version = 1
    for line in ((source or "") .. "\n"):gmatch("(.-)\n") do
        local directive = trim(line)
        if directive == "#PRE" or directive == "#POST" or directive:match("^#STEP%f[%s%z]")
            or directive:match("^#SEQUENCE%f[%s%z]") then
            return 3
        end
        if directive:sub(1, 3) == "#--" or directive:match("^#MODE[%s%[]") then
            version = 2
        end
    end
    return version
end

function addon:ExportTemplates(entries)
    local blocks = {}
    for _, entry in ipairs(entries) do
        local scope = self:NormalizeScope(entry.scope)
        local record = self.db.templates[scope] and self.db.templates[scope][entry.name]
        if record then
            local header = "!WMC:" .. exportVersion(record.source) .. " " .. scope .. " " .. entry.name
            if record.icon then
                header = header .. " icon=" .. record.icon
            end
            local source = (record.source or ""):gsub("\r\n", "\n"):gsub("\n+$", "")
            table.insert(blocks, header .. "\n" .. source)
        end
    end
    return table.concat(blocks, "\n\n")
end

-- Parses export text into { scope, name, icon, source } entries.
function addon:ParseExport(text)
    text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    local entries = {}
    local current
    local lineNumber = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lineNumber = lineNumber + 1
        local version, scope, name, rest = line:match("^%s*!WMC:(%d+)%s+(%S+)%s+(%S+)%s*(.-)%s*$")
        if version then
            if tonumber(version) > EXPORT_VERSION then
                return nil, "Line " .. lineNumber .. ": exported by a newer version of WMC."
            end
            current = { scope = string.upper(scope), name = name, icon = rest:match("icon=(%S+)"), lines = {} }
            table.insert(entries, current)
        elseif current then
            table.insert(current.lines, line)
        elseif trim(line) ~= "" then
            return nil, "Not a WMC export (expected a line starting with !WMC:)."
        end
    end
    if #entries == 0 then
        return nil, "Not a WMC export (expected a line starting with !WMC:)."
    end
    for _, entry in ipairs(entries) do
        entry.source = table.concat(entry.lines, "\n"):gsub("\n+$", "") .. "\n"
        entry.lines = nil
    end
    return entries
end

-- Imports export text. A name that is already taken is never overwritten:
-- the import gets the next free name instead (reported as renamed).
-- Returns a list of { scope, name, originalName, error } results.
function addon:ImportTemplates(text)
    local entries, parseError = self:ParseExport(text)
    if not entries then
        return nil, parseError
    end
    local results = {}
    for _, entry in ipairs(entries) do
        local result = { scope = entry.scope, originalName = entry.name }
        local scope = entry.scope
        if scope ~= "GENERAL" and not classScopes[scope] then
            result.error = "unknown class " .. scope
        else
            local name = self:UniqueName(scope, entry.name)
            if not name then
                result.error = "no free name"
            else
                local ok, saveError = self:SaveTemplate(scope, name, entry.source, nil, nil, true, true)
                if ok then
                    result.name = name
                    if entry.icon then
                        self:SetTemplateIcon(scope, name, entry.icon)
                    end
                else
                    result.error = saveError
                end
            end
        end
        table.insert(results, result)
    end
    return results
end

-- ---------------------------------------------------------------------------
-- "Make macro": creates (or finds) a real WoW macro whose body is
-- /click WMC_<name>, with the template's icon, and puts it on the cursor so
-- it can be dropped onto an action bar. perCharacter chooses the character
-- tab over the general (account-wide) one.
-- ---------------------------------------------------------------------------
local MACRO_NAME_MAX = 16

local function macroIconIndex(texture)
    if texture and GetNumMacroIcons and GetMacroIconInfo then
        for index = 1, GetNumMacroIcons() do
            if GetMacroIconInfo(index) == texture then
                return index
            end
        end
    end
    return 1 -- the question-mark icon
end

function addon:MakeMacro(scope, name, perCharacter)
    scope = self:NormalizeScope(scope)
    local record = self.db.templates[scope] and self.db.templates[scope][name]
    if not record then
        return nil, "Save the template first."
    end
    if InCombatLockdown and InCombatLockdown() then
        return nil, "Macros can't be created in combat."
    end
    local _, playerClass = UnitClass("player")
    if scope ~= "GENERAL" and scope ~= playerClass then
        return nil, "This template's button only exists on " .. scope .. " characters."
    end
    if not CreateMacro or not GetMacroIndexByName then
        return nil, "Macro API unavailable."
    end
    local body = "/click WMC_" .. name
    local macroName = name:sub(1, MACRO_NAME_MAX)
    local existing = GetMacroIndexByName(macroName)
    if existing and existing > 0 then
        local _, _, existingBody = GetMacroInfo(existing)
        if existingBody and trim(existingBody) == body then
            if PickupMacro then
                PickupMacro(existing)
            end
            return existing, "existing"
        end
        return nil, "A different macro named \"" .. macroName .. "\" already exists."
    end
    local numAccount, numCharacter = GetNumMacros()
    if perCharacter and numCharacter >= (MAX_CHARACTER_MACROS or 18) then
        return nil, "No free character macro slots."
    end
    if not perCharacter and numAccount >= (MAX_ACCOUNT_MACROS or 36) then
        return nil, "No free general macro slots."
    end
    local index = CreateMacro(macroName, macroIconIndex(record.icon), body, perCharacter and 1 or nil)
    if not index then
        return nil, "Could not create the macro."
    end
    if PickupMacro then
        PickupMacro(index)
    end
    return index, "created"
end

function addon:DeleteTemplate(scope, name)
    scope = self:NormalizeScope(scope)
    local values = self.db.templates[scope]
    if not values or not values[name] then
        return nil, "Template not found."
    end
    local id = self:TemplateId(scope, name)
    values[name] = nil
    if self:IsInCombat() then
        self.runtime.pendingRebuild = true
    else
        self:RemoveActiveTemplate(id)
        self:RebuildConditionRegistries()
    end
    if self.Keys then
        self.Keys:TemplateChanged(id, nil)
    end
    if self.UI then
        self.UI:RefreshList()
    end
    return true
end

local duelTimer
local playerSpecRetryTimer
local eventFrame = CreateFrame("Frame", "WMC_EventFrame")
addon.eventFrame = eventFrame
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("UNIT_FLAGS")
eventFrame:RegisterEvent("INSPECT_TALENT_READY")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
eventFrame:RegisterEvent("ZONE_CHANGED")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("ZONE_CHANGED_INDOORS")
eventFrame:RegisterEvent("ARENA_OPPONENT_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("UNIT_NAME_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBER_DISABLE")
eventFrame:RegisterEvent("PARTY_MEMBER_ENABLE")
eventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("UNIT_FACTION")
eventFrame:RegisterEvent("UNIT_PET")
eventFrame:RegisterEvent("DUEL_REQUESTED")
eventFrame:RegisterEvent("DUEL_OUTOFBOUNDS")
eventFrame:RegisterEvent("DUEL_INBOUNDS")
eventFrame:RegisterEvent("DUEL_FINISHED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- the Macro Bank's (Bank/)
eventFrame:RegisterEvent("UPDATE_MACROS")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
eventFrame:RegisterEvent("EQUIPMENT_SWAP_FINISHED")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        addon:DefaultDatabase()
        addon.runtime.inCombat = isInCombat()
        addon.State:Initialize()
        addon:RebuildActiveTemplates()
        addon:CompileAllDefaults()
        addon.UI:Initialize()
        addon.MinimapButton:Initialize()
        addon.Flyout:Initialize()
        addon.Macros:Initialize()
        addon.Loadouts:Initialize()
        addon.Takeover:Initialize()
        addon.Keys:Initialize()
        return
    end
    if event == "PLAYER_LOGOUT" then
        addon.Loadouts:Logout()
        return
    end
    if event == "ACTIONBAR_SLOT_CHANGED" then
        addon.Loadouts:SlotChanged(...)
        return
    end
    if event == "EQUIPMENT_SWAP_FINISHED" then
        -- (success, the set's name)
        local success, set = ...
        addon.Loadouts:SwapFinished(set)
        if success then
            addon.Loadouts:GearWorn(set)
        end
        return
    end
    if event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        addon.Loadouts:TalentsChanged() -- (and on to State, below)
    end
    if event == "UPDATE_MACROS" then
        addon.BankUI:MacrosChanged()
        return
    end
    if event == "ADDON_LOADED" then
        addon.Takeover:AddonLoaded(...)
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then
        addon.runtime.inCombat = true
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        addon.runtime.inCombat = false
        addon.Secure.CombatEnded(addon.runtime.active)
        addon:FlushDirty()
        addon.Macros:CombatEnded()
        addon.Loadouts:CombatEnded()
        addon.Keys:CombatEnded()
        return
    end
    if (event == "SPELLS_CHANGED" or event == "BAG_UPDATE") and addon.Macros.db then
        addon.Loadouts:Available(event == "BAG_UPDATE" and "item" or "spell") -- (and on to State)
    end
    -- Events can arrive before PLAYER_LOGIN (e.g. SPELLS_CHANGED during
    -- load); State has no caches until it is initialized.
    if not addon.State or not addon.State.initialized then
        return
    end
    local categories = addon.State:HandleEvent(event, ...)
    if categories and #categories > 0 then
        addon:HandleStateChange(categories)
    end
    if event == "PLAYER_ENTERING_WORLD" and addon.State.values.PLAYER_SPEC == nil then
        playerSpecRetryTimer:Show()
    end
    if addon.State.duelPendingUntil then
        duelTimer:Show()
    end
end)


-- Pending-duel deadline watchdog. The challenge activation starts a pending
-- window (State.duelPendingUntil); real duel activity cancels it, otherwise
-- the challenge is assumed declined/ignored and wiped on expiry (this client
-- has no DUEL_CANCELLED event). Runs only while a deadline exists.
duelTimer = CreateFrame("Frame")
duelTimer:Hide()
do
    local elapsed = 0
    duelTimer:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < 0.5 then
            return
        end
        elapsed = 0
        local state = addon.State
        if not state or not state.duelPendingUntil then
            duelTimer:Hide()
            return
        end
        if state:TickDuel() then
            local categories = { "DUEL", "REACTION", "COMBAT", "AURA" }
            addon:HandleStateChange(categories)
        end
        if not state.duelPendingUntil then
            duelTimer:Hide()
        end
    end)
end

-- Cooldown-expiry watchdog. GetSpellCooldown reaching zero is a pure
-- function of elapsed time -- no event marks that moment the way
-- SPELL_UPDATE_COOLDOWN marks a cooldown *starting* -- so without this,
-- PLAYER_CD would go stale (staying "on cooldown") until some unrelated
-- cast happened to trigger a rescan. State:RefreshPlayerCooldowns shows and
-- hides this timer directly, so it runs only while something is actually
-- tracked as on cooldown.
local COOLDOWN_TICK_SECONDS = 0.2
local cooldownTimer = CreateFrame("Frame")
cooldownTimer:Hide()
addon.cooldownTimer = cooldownTimer
do
    local elapsed = 0
    cooldownTimer:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < COOLDOWN_TICK_SECONDS then
            return
        end
        elapsed = 0
        local state = addon.State
        if not state then
            cooldownTimer:Hide()
            return
        end
        if state:RefreshPlayerCooldowns() then
            addon:HandleStateChange({ "PLAYER_CD" })
        end
    end)
end

-- .TIME threshold watchdog (§5.7.1). An aura's remaining time crossing a
-- template's threshold is a pure function of elapsed time -- no event marks
-- it -- so while any active template has a .TIME comparison, this checks
-- once a second whether any of them changed its answer, and treats that
-- as an AURA change (compiled now, or queued in combat like any other).
local AURA_TIME_TICK_SECONDS = 1
local auraTimeTimer = CreateFrame("Frame")
auraTimeTimer:Hide()
addon.auraTimeTimer = auraTimeTimer
do
    local elapsed = 0
    auraTimeTimer:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < AURA_TIME_TICK_SECONDS then
            return
        end
        elapsed = 0
        local state = addon.State
        local timedTemplates = addon.runtime.timedTemplates
        if not state or not state.initialized or not timedTemplates or #timedTemplates == 0 then
            auraTimeTimer:Hide()
            return
        end
        state:RefreshNow()
        local crossed = false
        for _, template in ipairs(timedTemplates) do
            local signature = addon.Compiler.TimeSignature(template.parsed, addon:CompileValuesFor(template.parsed))
            if signature ~= template.timeSignature then
                crossed = true
            end
            template.timeSignature = signature
        end
        if crossed then
            addon:HandleStateChange({ "AURA" })
        end
    end)
end


-- One-shot bounded retry for a PLAYER_SPEC read that lost the race with
-- the client's own talent-data load right after PLAYER_ENTERING_WORLD
-- (see State:RetryPlayerSpec). Armed only when that race is actually lost;
-- fires exactly once and stays hidden afterward, whether or not the
-- recheck found anything -- a single bounded recheck, not a poll.
local PLAYER_SPEC_RETRY_SECONDS = 2
playerSpecRetryTimer = CreateFrame("Frame")
playerSpecRetryTimer:Hide()
do
    local elapsed = 0
    playerSpecRetryTimer:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < PLAYER_SPEC_RETRY_SECONDS then
            return
        end
        elapsed = 0
        playerSpecRetryTimer:Hide()
        if not addon.State then
            return
        end
        local categories = addon.State:RetryPlayerSpec()
        if categories then
            addon:HandleStateChange(categories)
        end
    end)
end

-- A set put on by the Equipment Manager or /equipset, for the loadout in
-- use (Bank/Loadouts.lua); EQUIPMENT_SWAP_FINISHED catches the action
-- bar's set buttons too.
if hooksecurefunc and UseEquipmentSet then
    hooksecurefunc("UseEquipmentSet", function(set)
        addon.Loadouts:GearWorn(set)
    end)
end

-- The client sends no event for duels the player starts (DUEL_REQUESTED is
-- recipient-only), so outgoing challenges are captured by hooking the same
-- global the /duel command and the unit menu both go through. The challenge
-- itself is the activation, so this is an ordinary watched-field change.
if hooksecurefunc and StartDuel then
    hooksecurefunc("StartDuel", function(unit)
        local activated = addon.State and addon.State.initialized
            and addon.State:HandleStartDuel(unit)
        if activated then
            local categories = { "DUEL", "REACTION", "COMBAT", "AURA" }
            addon:HandleStateChange(categories)
            if addon.State.duelPendingUntil then
                duelTimer:Show()
            end
        end
    end)
end

-- /qmc flag (§5.15):
--   /qmc flag                 list the active flags
--   /qmc flag NAME            toggle NAME (the form to put on a key)
--   /qmc flag NAME on|off     set NAME explicitly
--   /qmc flag off | clear     switch every flag off
-- A change recompiles FLAG-watching templates like any watched state: in
-- combat they are queued (or skipped, under #COMPILE IGNORE) until it ends.
function addon:FlagCommand(rest)
    local State = self.State
    local words = {}
    for word in (rest or ""):gmatch("%S+") do
        table.insert(words, word)
    end
    local function report(changed, verb)
        local active = State:ActiveFlags()
        local suffix = ""
        if changed and self:IsInCombat() then
            suffix = " (applies when combat ends)"
        end
        self:Print(verb .. " Active flags: " .. (#active > 0 and table.concat(active, ", ") or "none") .. "." .. suffix)
        if changed then
            self:HandleStateChange({ "FLAG" })
        end
    end
    if #words == 0 then
        local active = State:ActiveFlags()
        self:Print("Active flags: " .. (#active > 0 and table.concat(active, ", ") or "none")
            .. ". Usage: /qmc flag NAME [on|off], /qmc flag off.")
        return
    end
    local first = string.lower(words[1])
    if #words == 1 and (first == "off" or first == "clear") then
        report(State:ClearFlags(), "All flags off.")
        return
    end
    local name, nameError = self.Compiler.ValidFlagName(words[1])
    if not name then
        self:Print(nameError .. ".")
        return
    end
    local mode = words[2] and string.lower(words[2])
    local on
    if mode == "on" then
        on = true
    elseif mode == "off" then
        on = false
    elseif mode ~= nil and mode ~= "toggle" or #words > 2 then
        self:Print("Usage: /qmc flag NAME [on|off|toggle], /qmc flag off.")
        return
    end
    local state, changed = State:SetFlag(name, on)
    report(changed, "Flag " .. name .. " " .. (state and "on" or "off") .. ".")
end

-- /qmc pin / unpin (§6.1): decide who a class placeholder means in the
-- current group.
--   /qmc pin                 list the pins
--   /qmc pin MAGE            pin the current target as the MAGE
--   /qmc pin MAGE Name       pin that group member ("Name-Realm" accepted)
--   /qmc pin ANY [Name]      a free pin: any group member, whatever the class
--   /qmc unpin MAGE | unpin  clear one pin / all pins
-- A change recompiles GROUP-watching templates like any watched state: in
-- combat they are queued until it ends.
local PIN_STATUS_TEXT = { absent = " (not in group)", offline = " (offline)", active = "" }

function addon:PinList()
    local pins = self.State:ActivePins()
    if #pins == 0 then
        return "none"
    end
    local parts = {}
    for _, pin in ipairs(pins) do
        table.insert(parts, pin.class .. " -> " .. pin.name .. PIN_STATUS_TEXT[pin.status])
    end
    return table.concat(parts, ", ")
end

function addon:PinCommand(rest)
    local State = self.State
    local words = {}
    for word in (rest or ""):gmatch("%S+") do
        table.insert(words, word)
    end
    if #words == 0 then
        self:Print("Pins: " .. self:PinList() .. ". Usage: /qmc pin CLASS [Name], /qmc pin ANY [Name], /qmc unpin [CLASS or ANY].")
        return
    end
    local name, changed = State:SetPin(words[1], words[2])
    if not name then
        self:Print(changed .. ". Usage: /qmc pin CLASS [Name] or /qmc pin ANY [Name].")
        return
    end
    local suffix = ""
    if changed and self:IsInCombat() then
        suffix = " (applies when combat ends)"
    end
    self:Print(words[1]:upper() .. " pinned to " .. name .. ". Pins: " .. self:PinList() .. "." .. suffix)
    if changed then
        self:HandleStateChange({ "GROUP" })
    end
end

function addon:UnpinCommand(rest)
    local State = self.State
    local class = (rest or ""):match("%S+")
    local changed
    if class then
        if not (self.Compiler.classNames[class:upper()] or self.Compiler.freePins[class:upper()]) then
            self:Print("Unknown class \"" .. class .. "\". Usage: /qmc unpin [CLASS or ANY].")
            return
        end
        changed = State:ClearPin(class)
        if not changed then
            self:Print(class:upper() .. " has no pin. Pins: " .. self:PinList() .. ".")
            return
        end
    else
        changed = State:ClearPins()
    end
    local suffix = ""
    if changed and self:IsInCombat() then
        suffix = " (applies when combat ends)"
    end
    self:Print((class and (class:upper() .. " unpinned.") or "All pins cleared.") .. " Pins: " .. self:PinList() .. "." .. suffix)
    if changed then
        self:HandleStateChange({ "GROUP" })
    end
end

-- /qmc mute / unmute (§5.16): switch macro lines off in a mode's branches.
--   /qmc mute                          list the mutes
--   /qmc mute DUEL Line[; Line...]     mute those lines in every DUEL mode
--   /qmc unmute DUEL [Line[; Line...]] unmute those / all of DUEL's
--   /qmc unmute                        clear every mute
-- Mutes are applied to the parsed templates here, once; only templates
-- whose output changed recompile (in combat: queued under QUEUE).

-- The current character's mutes, or nil before State exists.
function addon:MuteTable()
    return self.State and self.State.Mutes and self.State:Mutes() or nil
end

function addon:ApplyMutesToAll(stats)
    local mutes = self:MuteTable()
    local listChanged = false
    for _, template in ipairs(self.runtime.active) do
        if template.parsed and self.Compiler.ApplyMutes(template.parsed, mutes, stats) then
            local wasDirty = template.dirty
            if self:IsInCombat() then
                if template.compilePolicy == "QUEUE" then
                    template.dirty = true
                end
            else
                self:CompileCurrent(template)
            end
            listChanged = listChanged or template.dirty ~= wasDirty
        end
    end
    if self.UI then
        self.UI:RequestRefresh(listChanged)
    end
end

-- Whether any active template has a mode of this name.
function addon:HasMode(mode)
    for _, template in ipairs(self.runtime.active) do
        for _, existing in ipairs(template.parsed and template.parsed.modes or {}) do
            if existing.name == mode then
                return true
            end
        end
    end
    return false
end

function addon:MuteListText()
    local parts = {}
    for _, item in ipairs(self.State:MuteList()) do
        table.insert(parts, item.mode .. ": " .. table.concat(item.entries, ", "))
    end
    return #parts > 0 and table.concat(parts, "; ") or "none"
end

local MUTE_USAGE = "Usage: /qmc mute MODE Line[; Line...], /qmc unmute [MODE [Line[; Line...]]]."

-- "DUEL Sapper; Evasion" -> "DUEL", { "Sapper", "Evasion" } (entries nil
-- when only the mode is given), or nil.
local function parseMuteArgs(rest)
    local mode, list = (rest or ""):match("^%s*([%a_][%w_]*)%s*(.-)%s*$")
    if not mode then
        return nil
    end
    local entries
    if list ~= "" then
        entries = {}
        for entry in (list .. ";"):gmatch("([^;]*);") do
            entry = entry:match("^%s*(.-)%s*$")
            if entry ~= "" then
                table.insert(entries, entry)
            end
        end
    end
    return mode:upper(), entries
end

local function combatSuffix(self)
    return self:IsInCombat() and " (applies when combat ends)" or ""
end

function addon:MuteCommand(rest)
    if not (rest or ""):find("%S") then
        self:Print("Mutes: " .. self:MuteListText() .. ". " .. MUTE_USAGE)
        return
    end
    local mode, entries = parseMuteArgs(rest)
    if not mode or not entries or #entries == 0 then
        self:Print(MUTE_USAGE)
        return
    end
    local added, already = self.State:AddMutes(mode, entries)
    if not added then
        self:Print(already .. ". " .. MUTE_USAGE)
        return
    end
    local stats = {}
    self:ApplyMutesToAll(stats)
    local list = self.State:Mutes()[mode] or {}
    local parts = {}
    for _, entry in ipairs(added) do
        local stat
        for index, existing in ipairs(list) do
            if existing == entry then
                stat = stats[mode] and stats[mode][index]
            end
        end
        local lines = stat and stat.lines or 0
        local text = entry .. " (" .. lines .. (lines == 1 and " line" or " lines")
        if stat and stat.skipped > 0 then
            text = text .. "; kept in " .. stat.skipped .. (stat.skipped == 1 and " branch" or " branches")
                .. " it would leave empty"
        end
        table.insert(parts, text .. ")")
    end
    for _, entry in ipairs(already) do
        table.insert(parts, entry .. " (already muted)")
    end
    local note = self:HasMode(mode) and "" or (" No active template has a " .. mode .. " mode yet.")
    self:Print("Muted in " .. mode .. ": " .. table.concat(parts, ", ") .. "." .. note .. combatSuffix(self))
end

function addon:UnmuteCommand(rest)
    if not (rest or ""):find("%S") then
        if not self.State:ClearMutes() then
            self:Print("No mutes to clear.")
            return
        end
        self:ApplyMutesToAll()
        self:Print("All mutes cleared." .. combatSuffix(self))
        return
    end
    local mode, entries = parseMuteArgs(rest)
    if not mode then
        self:Print(MUTE_USAGE)
        return
    end
    local removed, missing = self.State:RemoveMutes(mode, entries)
    if #removed == 0 then
        self:Print((entries and "Not muted in " .. mode .. ": " .. table.concat(missing, ", ") or (mode .. " has no mutes"))
            .. ". Mutes: " .. self:MuteListText() .. ".")
        return
    end
    self:ApplyMutesToAll()
    local text = "Unmuted in " .. mode .. ": " .. table.concat(removed, ", ") .. "."
    if #missing > 0 then
        text = text .. " Not muted: " .. table.concat(missing, ", ") .. "."
    end
    self:Print(text .. combatSuffix(self))
end

-- The x on a remembered mute (State section, flyout): unmutes it if it is
-- on, then drops it from the class's remembered mutes.
function addon:ForgetMute(mode, entry)
    local current = self.State:Mutes()[mode]
    local key = self.Compiler.MuteKey(entry)
    for _, existing in ipairs(current or {}) do
        local other = self.Compiler.MuteKey(existing)
        if key and other and other.command == key.command and other.argument == key.argument then
            self:UnmuteCommand(mode .. " " .. entry)
            break
        end
    end
    if self.State:ForgetMute(mode, entry) then
        self:Print("Removed from " .. mode .. "'s remembered mutes: " .. entry .. ".")
    end
end

-- /qmc size [smaller | normal | larger]: the windows' size (Theme.lua, Window
-- scale). Without an argument it says the current one.
local WINDOW_SIZE_NAMES = { smaller = "Smaller", normal = "Normal", larger = "Larger" }

function addon:WindowSizeCommand(size)
    local settings = self.db and self.db.settings
    if not settings then
        return
    end
    if size == "" then
        local width, height = self.Theme.ScreenPixels()
        local pixels = self.Theme.WindowPixels(settings.windowSize)
        self:Print("Window size: " .. WINDOW_SIZE_NAMES[settings.windowSize or "normal"] .. " ("
            .. (height and string.format("%dx%d, %.2f px per unit", width, height, pixels)
                or "screen size unknown, drawn at the UI scale")
            .. "). Usage: /qmc size smaller | normal | larger.")
        return
    end
    if not WINDOW_SIZE_NAMES[size] then
        self:Print("Usage: /qmc size smaller | normal | larger.")
        return
    end
    self:SetWindowSize(size)
    self:Print("Window size: " .. WINDOW_SIZE_NAMES[size] .. ".")
end

-- size: "smaller", "normal" or "larger".
function addon:SetWindowSize(size)
    self.db.settings.windowSize = size ~= "normal" and size or nil
    self:ApplyWindowSize()
    if self.UI and self.UI.rail then
        self.UI:RefreshRail()
    end
end

-- Puts every open window at the current size; popups take it when opened.
function addon:ApplyWindowSize()
    self.Menu:Close()
    self.Dialog:Cancel()
    self.IconPicker:Cancel()
    self.MuteDialog:Cancel()
    local UI = self.UI
    local bank = self.BankUI
    for _, window in pairs({ UI and UI.window, UI and UI.textWindow and UI.textWindow.window, bank and bank.window }) do
        window:ApplyScale()
    end
    -- Text measured at the old scale no longer fits (fonts snap to whole
    -- pixels): the source tab's caption is measured again.
    if UI and UI.tabStrip then
        UI.tabStrip:SetCaption(UI.tabStrip.captionText)
    end
    self.Flyout:ApplyScale()
    local guide = self.Guide
    if guide and guide.frame and guide.frame:IsShown() then
        guide:Show()
    end
end

-- /qmc since the Quintessence rename; /wmc kept so existing macros
-- (/wmc flag WPVP on a key) keep working.
SLASH_WOWMACROCOMPILER1 = "/qmc"
SLASH_WOWMACROCOMPILER2 = "/wmc"
SlashCmdList.WOWMACROCOMPILER = function(input)
    local command, rest = (input or ""):match("^(%S*)%s*(.-)$")
    command = string.lower(command or "")
    if command == "" then
        addon.UI:Toggle()
    elseif command == "duel" then
        if not addon.db then
            return
        end
        local subcommand, argument = (rest or ""):match("^(%S*)%s*(.-)$")
        subcommand = string.lower(subcommand or "")
        if subcommand == "add" then
            local warlockName, petName = (argument or ""):match("^(%S+)%s+(.+)$")
            petName = petName and trim(petName)
            if not warlockName or not petName or petName == "" then
                addon:Print("Usage: /qmc duel add <warlock name> <succubus name> -- store a succubus name manually.")
                return
            end
            local stored, liveChanged = addon.State:AddSuccubus(warlockName, petName)
            if not stored then
                addon:Print("Could not store that succubus name.")
                return
            end
            addon:Print("Stored succubus " .. petName .. " for " .. warlockName .. ".")
            if liveChanged then
                addon:HandleStateChange({ "DUEL" })
            end
        elseif subcommand == "list" then
            local filter = trim(argument or "")
            local rows, total = addon.State:ListSuccubi(filter)
            if total == 0 then
                addon:Print("No stored succubus names.")
                return
            end
            if #rows == 0 then
                addon:Print("No stored succubus matches \"" .. filter .. "\" (" .. total .. " stored).")
                return
            end
            -- A full book can be hundreds of rows: cap the chat output and
            -- point at the filter instead of flooding the chat frame.
            local LIST_LIMIT = 30
            addon:Print("Stored succubi (" .. (filter ~= "" and (#rows .. " match, of " .. total) or total) .. "):")
            for index = 1, math.min(#rows, LIST_LIMIT) do
                addon:Print("  " .. rows[index].warlock .. " - " .. rows[index].name)
            end
            if #rows > LIST_LIMIT then
                addon:Print("  ... " .. (#rows - LIST_LIMIT) .. " more; narrow it with /qmc duel list <text>.")
            end
        elseif subcommand == "forget" then
            local warlockName = trim(argument or "")
            if warlockName == "" then
                addon:Print("Usage: /qmc duel forget <warlock name> -- delete that warlock's stored succubus name.")
                return
            end
            local removed, liveChanged = addon.State:ForgetSuccubus(warlockName)
            if not removed then
                addon:Print("No stored succubus for " .. warlockName .. ".")
                return
            end
            addon:Print("Forgot the stored succubus for " .. warlockName .. ".")
            if liveChanged then
                -- The live duel opponent just lost their succubus name:
                -- DUEL-watching templates must recompile without it.
                addon:HandleStateChange({ "DUEL" })
            end
        else
            addon:Print("Usage: /qmc duel add <warlock name> <succubus name> -- store a succubus name manually.")
            addon:Print("Usage: /qmc duel list [text] -- show stored succubus names (optionally filtered).")
            addon:Print("Usage: /qmc duel forget <warlock name> -- delete that warlock's stored succubus name.")
        end
    elseif command == "guide" or command == "book" then
        -- /qmc guide [page]: the in-game guide (Guide.lua).
        local page = tonumber(rest)
        local count = addon.GuideData and #addon.GuideData or 0
        if rest ~= "" and not (page and page >= 1 and page <= count and page == math.floor(page)) then
            addon:Print("Usage: /qmc guide [page] -- the guide; pages 1 to " .. count .. ".")
            return
        end
        addon.Guide:Toggle(page)
    elseif command == "size" then
        addon:WindowSizeCommand(string.lower(rest))
    elseif command == "minimap" then
        addon.MinimapButton:Toggle()
    elseif command == "tab" then
        addon.Flyout:Toggle()
    elseif command == "uidebug" then
        if addon.UI and addon.UI.DebugGeometry then
            for _, text in ipairs(addon.UI:DebugGeometry()) do
                addon:Print(text)
            end
        end
    elseif command == "flag" then
        if not addon.db or not addon.State or not addon.State.values then
            return
        end
        addon:FlagCommand(rest)
    elseif command == "pin" or command == "unpin" then
        if not addon.db or not addon.State or not addon.State.values then
            return
        end
        if command == "pin" then
            addon:PinCommand(rest)
        else
            addon:UnpinCommand(rest)
        end
    elseif command == "mute" or command == "unmute" then
        if not addon.db or not addon.State then
            return
        end
        if command == "mute" then
            addon:MuteCommand(rest)
        else
            addon:UnmuteCommand(rest)
        end
    else
        addon:Print("Commands: /qmc (window), /qmc guide [page] (the guide), /qmc minimap (hide/show its button), /qmc tab (hide/show the screen-edge flyout), /qmc flag [NAME [on|off]], /qmc pin [CLASS [Name]], /qmc pin ANY [Name], /qmc unpin [CLASS or ANY], /qmc mute [MODE Line[; Line...]], /qmc unmute [MODE [Line...]], "
            .. "/qmc duel add <warlock> <succubus>, /qmc duel list [text], /qmc duel forget <name>")
    end
end
