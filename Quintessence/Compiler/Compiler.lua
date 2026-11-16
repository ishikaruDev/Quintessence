local addon = WMacroCompiler
local Compiler = {}
addon.Compiler = Compiler

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitLines(text)
    text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end
    return lines
end

local function trimBody(lines)
    local first = 1
    local last = #lines
    while first <= last and trim(lines[first]) == "" do
        first = first + 1
    end
    while last >= first and trim(lines[last]) == "" do
        last = last - 1
    end
    local result = {}
    for index = first, last do
        table.insert(result, lines[index])
    end
    return table.concat(result, "\n")
end

-- A body line and its line number in the source (for the editor's mute
-- marks, §5.16). The numbers run parallel to node.lines.
local function addBodyLine(node, line, lineNumber)
    table.insert(node.lines, line)
    node.lineNumbers = node.lineNumbers or {}
    table.insert(node.lineNumbers, lineNumber)
end

-- Macro lines are what a branch must keep at least one of: everything but
-- blank lines and # lines (#showtooltip...).
local function isMacroLine(line)
    local first = line:match("^%s*(%S)")
    return first ~= nil and first ~= "#"
end

-- ---------------------------------------------------------------------------
-- Sequences (§5.17): a body containing #STEP runs one step per press. Its
-- block headers are kept as body lines while parsing (so nesting and mode
-- structure treat them like any body text) and split out per body once the
-- forms exist.
-- ---------------------------------------------------------------------------

local blockHeaders = { ["#PRE"] = "PRE", ["#POST"] = "POST", ["#STEP"] = "STEP", ["#STEP ONCE"] = "ONCE" }

-- The block a trimmed line opens ("PRE", "POST", "STEP", "ONCE"), nil for
-- any other line, or false and an error for a malformed header.
local function blockHeader(directive)
    local kind = blockHeaders[(directive:gsub("%s+", " "))]
    if kind then
        return kind
    end
    if directive:match("^#STEP%s") then
        return false, "#STEP takes only ONCE (#STEP or #STEP ONCE)."
    end
    if directive:match("^#PRE%s") or directive:match("^#POST%s") then
        return false, directive:match("^(#%u+)") .. " takes no options."
    end
    return nil
end

local blockNames = { PRE = "#PRE", POST = "#POST", STEP = "#STEP", ONCE = "#STEP ONCE" }

-- Splits one body into its blocks. Returns nil for a plain body (no
-- #STEP), { pre, post, openers, steps } for a stepped one (each block
-- { kind, line, lines, lineNumbers }), or false and an error.
local function splitSteps(lines, numbers)
    local sequence = { openers = {}, steps = {} }
    local block, looseLine, firstPrePost
    for index, line in ipairs(lines or {}) do
        local number = numbers and numbers[index] or 0
        local kind, headerError = blockHeader(trim(line))
        if kind == false then
            return false, "Line " .. number .. ": " .. headerError
        end
        if kind then
            local stepCount = #sequence.openers + #sequence.steps
            if kind == "PRE" then
                if sequence.pre then
                    return false, "Line " .. number .. ": a body has at most one #PRE (first at line "
                        .. sequence.pre.line .. ")."
                end
                if stepCount > 0 or sequence.post then
                    return false, "Line " .. number .. ": #PRE must come before the steps."
                end
            elseif kind == "POST" then
                if sequence.post then
                    return false, "Line " .. number .. ": a body has at most one #POST (first at line "
                        .. sequence.post.line .. ")."
                end
            elseif sequence.post then
                return false, "Line " .. number .. ": a step cannot follow #POST."
            elseif kind == "ONCE" and #sequence.steps > 0 then
                return false, "Line " .. number .. ": #STEP ONCE must come before every plain #STEP."
            end
            block = { kind = kind, line = number, lines = {}, lineNumbers = {} }
            if kind == "PRE" then
                sequence.pre = block
            elseif kind == "POST" then
                sequence.post = block
            elseif kind == "ONCE" then
                table.insert(sequence.openers, block)
            else
                table.insert(sequence.steps, block)
            end
            if (kind == "PRE" or kind == "POST") and not firstPrePost then
                firstPrePost = block
            end
        elseif block then
            table.insert(block.lines, line)
            table.insert(block.lineNumbers, number)
        elseif trim(line) ~= "" then
            looseLine = looseLine or number
        end
    end
    if #sequence.openers + #sequence.steps == 0 then
        if firstPrePost then
            return false, "Line " .. firstPrePost.line .. ": " .. blockNames[firstPrePost.kind]
                .. " needs #STEP (it only exists in a stepped body)."
        end
        return nil
    end
    if looseLine then
        return false, "Line " .. looseLine
            .. ": in a body with #STEP every line belongs to a block (put lines for every press under #PRE)."
    end
    if #sequence.steps == 0 then
        return false, "Line " .. sequence.openers[1].line
            .. ": #STEP ONCE needs at least one plain #STEP after it (the cycle it returns to)."
    end
    for _, list in ipairs({ sequence.openers, sequence.steps }) do
        for _, step in ipairs(list) do
            local hasMacro = false
            for _, line in ipairs(step.lines) do
                if isMacroLine(line) then
                    hasMacro = true
                    break
                end
            end
            if not hasMacro then
                return false, "Line " .. step.line .. ": " .. blockNames[step.kind] .. " has no macro line."
            end
        end
    end
    return sequence
end

-- The texts of a stepped body: { pre, post, openers = {...}, steps = {...} },
-- each trimmed like a plain body.
local function sequenceTexts(sequence)
    local texts = {
        pre = sequence.pre and trimBody(sequence.pre.lines) or "",
        post = sequence.post and trimBody(sequence.post.lines) or "",
        openers = {},
        steps = {},
    }
    for _, step in ipairs(sequence.openers) do
        table.insert(texts.openers, trimBody(step.lines))
    end
    for _, step in ipairs(sequence.steps) do
        table.insert(texts.steps, trimBody(step.lines))
    end
    return texts
end

-- A string that is equal for two stepped outputs exactly when they write
-- the same attributes ("\0" never occurs in macro text).
local function blocksKey(blocks, rules)
    local parts = { "SEQ", blocks.pre, blocks.post, tostring(#blocks.openers) }
    for _, text in ipairs(blocks.openers) do
        table.insert(parts, text)
    end
    for _, text in ipairs(blocks.steps) do
        table.insert(parts, text)
    end
    if rules then
        table.insert(parts, (rules.combat and "C" or "") .. (rules.combatStart and "S" or "")
            .. (rules.noTarget and "T" or "") .. "|" .. (rules.condition or ""))
    end
    return table.concat(parts, "\0")
end

-- `#SEQUENCE RESET=...` (§5.17). Returns the reset rules or nil and an
-- error. Without the line a stepped template gets Compiler.DEFAULT_RESETS.
local resetNames = { COMBAT = "combat", NOCOMBAT = "nocombat", COMBATSTART = "combatStart", NOTARGET = "noTarget" }

local function parseSequence(text)
    text = trim(text)
    if not string.upper(text):match("^RESET%s*=") then
        return nil, "expected #SEQUENCE RESET=..."
    end
    local list = trim(text:match("^[^=]*=(.*)$"))
    if list == "" then
        return nil, "RESET= needs at least one reset (COMBAT, NOCOMBAT, COMBATSTART, NOTARGET or [conditions])."
    end
    -- Split at commas outside brackets ([mod:alt,nocombat] is one item).
    local items, current, inBracket = {}, "", false
    for index = 1, #list do
        local char = list:sub(index, index)
        if char == "[" then
            if inBracket then
                return nil, "unexpected [ inside a [conditions] list."
            end
            inBracket = true
        elseif char == "]" then
            if not inBracket then
                return nil, "unexpected ] in RESET=."
            end
            inBracket = false
        end
        if char == "," and not inBracket then
            table.insert(items, trim(current))
            current = ""
        else
            current = current .. char
        end
    end
    if inBracket then
        return nil, "unclosed [ in RESET=."
    end
    table.insert(items, trim(current))
    local rules, seen = {}, {}
    for _, item in ipairs(items) do
        if item == "" then
            return nil, "empty item in RESET= (two commas in a row?)."
        end
        if item:sub(1, 1) == "[" then
            if item:gsub("%b[]", ""):match("%S") then
                return nil, "a [conditions] list is only brackets: " .. item
            end
            if rules.condition then
                return nil, "RESET= takes at most one [conditions] list."
            end
            rules.condition = item
        else
            local name = string.upper(item)
            if name == "TARGET" then
                return nil, "there is no TARGET reset: a switch between two live targets can't be detected in"
                    .. " combat. Use NOTARGET (the target is gone or dead)."
            end
            local key = resetNames[name]
            if not key then
                return nil, "unknown reset " .. item
                    .. " (expected COMBAT, NOCOMBAT, COMBATSTART, NOTARGET or [conditions])."
            end
            if seen[name] then
                return nil, "duplicate reset " .. name .. "."
            end
            seen[name] = true
            rules[key] = true
        end
    end
    if rules.combat and rules.nocombat then
        return nil, "COMBAT and NOCOMBAT contradict each other."
    end
    return {
        combat = not rules.nocombat,
        combatStart = rules.combatStart or nil,
        noTarget = rules.noTarget or nil,
        condition = rules.condition,
    }
end

-- Recompile (always) and combat end.
Compiler.DEFAULT_RESETS = { combat = true }

-- Canonical watch names.
local watchNames = {
    CLASS = "CLASS",
    SPEC = "SPEC",
    INSTANCE = "INSTANCE",
    PLAYER_SPEC = "PLAYER_SPEC",
    NAME = "NAME",
    AURA = "AURA",
    ARENA = "ARENA",
    ZONE = "ZONE",
    REACTION = "REACTION",
    PLAYER_CD = "PLAYER_CD",
    PARTY = "PARTY",
    DUEL = "DUEL",
    COMBAT = "COMBAT",
    PET = "PET",
    -- Raid/party roster for the group placeholders (ROGUE -> a raid or
    -- party member's name outside arena, MAINTANK, MAINASSIST -- §6.1).
    GROUP = "GROUP",
    -- User flags set with /qmc flag (FLAG=<NAME> -- §5.15).
    FLAG = "FLAG",
}

-- The ten playable classes; used to validate ASSUME classes, COMP
-- addresses, and @<CLASS> body placeholders.
local classNames = {
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
Compiler.classNames = classNames

-- Free pins (§6.1): placeholders that mean whichever group member the
-- player pins to them, whatever their class. Unpinned, they never resolve.
local freePins = {
    ANY = true,
    TASK = true, -- meant for other addons (API.lua), e.g. a raid assignment
}
Compiler.freePins = freePins

-- Canonical condition fields, plus the PCD alias. The addressed fields
-- (AURA, COMBAT, ...) are deliberately absent as flat entries: they are
-- colon-qualified (AURA:TARGET, AURA:COMP:MAGE, COMBAT:FOCUS, ...) and
-- validated separately.
local fieldNames = {
    PLAYER_CLASS = "PLAYER_CLASS",
    PLAYER_SPEC = "PLAYER_SPEC",
    CLASS = "CLASS",
    SPEC = "SPEC",
    INSTANCE = "INSTANCE",
    INSTANCE_NAME = "INSTANCE_NAME",
    NAME = "NAME",
    ZONE = "ZONE",
    ARENA1 = "ARENA1",
    ARENA2 = "ARENA2",
    ARENA3 = "ARENA3",
    ARENA4 = "ARENA4",
    ARENA5 = "ARENA5",
    COMP = "COMP",
    REACTION = "REACTION",
    PLAYER_CD = "PLAYER_CD",
    PARTY1 = "PARTY1",
    PARTY2 = "PARTY2",
    PARTY3 = "PARTY3",
    PARTY4 = "PARTY4",
    DUEL = "DUEL",
    DUEL_SUCCUBUS = "DUEL_SUCCUBUS",
    PET = "PET",
    FLAG = "FLAG",
    -- Alias.
    PCD = "PLAYER_CD",
}

-- Address tokens of the addressed fields (AURA:<ADDRESS>...).
-- <FIELD>:COMP:<CLASS> addresses are validated separately below,
-- since COMP is a synthetic address (every arena slot of a class), not a
-- literal unit token.
local unitAddresses = {
    TARGET = true,
    FOCUS = true,
    SELF = true,
    PARTY1 = true,
    PARTY2 = true,
    PARTY3 = true,
    PARTY4 = true,
    ARENA1 = true,
    ARENA2 = true,
    ARENA3 = true,
    ARENA4 = true,
    ARENA5 = true,
}

-- COMBAT:<ADDRESS> deliberately excludes SELF: the player's own combat
-- status is already exact and immediate via PLAYER_REGEN_DISABLED/ENABLED,
-- and WoW's native [combat] macro conditional already covers it with no
-- addon involvement at all. It also could never reach a live secure
-- button: entering/leaving combat IS the event that opens and closes the
-- window in which secure writes are even possible, so a COMBAT:SELF
-- condition could only ever be true at an instant when applying it is
-- impossible. See §5.8 of the spec for the full reasoning.
-- DUELOPPONENT is absent from unitAddresses: there is no unit token for
-- "the duel opponent" -- duel opponents are identified by name only, and
-- the unit APIs don't accept a bare name. Each address family adds it on
-- its own terms: COMBAT and AURA borrow TARGET's
-- value while TARGET provably *is* the duel opponent
-- (State:RefreshDuelOpponent -- §5.7, §5.8).
local combatUnitAddresses = {
    TARGET = true,
    FOCUS = true,
    PARTY1 = true,
    PARTY2 = true,
    PARTY3 = true,
    PARTY4 = true,
    ARENA1 = true,
    ARENA2 = true,
    ARENA3 = true,
    ARENA4 = true,
    ARENA5 = true,
    DUELOPPONENT = true,
}


local reactionValues = {
    ENEMY = true,
    ALLY = true,
    NEUTRAL = true,
}

local combatValues = {
    YES = true,
    NO = true,
}

-- Accepted PET values: the six warlock demon companions, plus YES/NO to
-- test whether any pet at all is currently summoned, independent of type.
-- Unlike REACTION/COMBAT, PET has no unit-existence ambiguity to speak of
-- for the YES/NO test itself -- see petConditionMatches -- but a specific
-- demon-type comparison still follows the usual "unknown never matches"
-- convention when no pet exists at all.
local petValues = {
    YES = true,
    NO = true,
    IMP = true,
    SUCCUBUS = true,
    FELHUNTER = true,
    VOIDWALKER = true,
    FELGUARD = true,
    INFERNAL = true,
}

-- Addresses accepted by AURA:<ADDRESS>: unitAddresses plus DUELOPPONENT.
local auraUnitAddresses = {}
for address in pairs(unitAddresses) do
    auraUnitAddresses[address] = true
end
auraUnitAddresses.DUELOPPONENT = true

-- Validates a "<PREFIX>:<ADDRESS>", "<PREFIX>:COMP:<CLASS>", or (when
-- allowNotClass is set) "<PREFIX>:COMP:NOT<CLASS>" field identifier
-- (already uppercased) against the given address set and returns its
-- canonical form. Shared by the addressed fields (AURA:..., COMBAT:...),
-- which differ only in which addresses they accept.
--
-- <PREFIX>:COMP:NOT<CLASS> (e.g. AURA:COMP:NOTMAGE, COMBAT:COMP:NOTDRUID)
-- addresses the single arena opponent resolved by resolveNotClassSlot
-- below -- the lowest-numbered slot whose class is *known* and differs
-- from <CLASS> -- canonicalized to "<PREFIX>:COMP:NOT:<CLASS>" so
-- conditionMatches can dispatch on it with a plain prefix check (checked
-- ahead of the plain COMP: prefix, which it also starts with). It sits
-- under the same COMP: namespace as COMP:<CLASS> since both address
-- something about "the enemy comp" rather than a fixed unit slot -- COMP
-- existentially over a class, COMP:NOT<CLASS> to one specific opponent.
-- Only the AURA/COMBAT callers pass allowNotClass=true.
local function parseAddressField(prefix, identifier, addresses, allowNotClass)
    local parts = {}
    for part in identifier:gmatch("[^:]+") do
        table.insert(parts, part)
    end
    if #parts == 2 and addresses[parts[2]] then
        return prefix .. ":" .. parts[2]
    end
    if #parts == 3 and parts[2] == "COMP" then
        if classNames[parts[3]] then
            return prefix .. ":COMP:" .. parts[3]
        end
        if allowNotClass then
            local excludedClass = parts[3]:match("^NOT(.+)$")
            if excludedClass and classNames[excludedClass] then
                return prefix .. ":COMP:NOT:" .. excludedClass
            end
        end
        return nil, "Unknown class in " .. prefix .. " address: " .. identifier
    end
    return nil, "Invalid " .. prefix .. " address: " .. identifier
end


-- Defined with the body placeholders below; AURA:<PLACEHOLDER> addresses
-- (§5.7) classify their address with it.
local classifyPlaceholder

-- A group placeholder used as an AURA address (§5.7): a class (ROGUE,
-- ROGUE#2 -- the class pins apply), a role (MAINTANK, MAINASSIST#2) or a
-- free pin (ANY, TASK). Not the pet forms (their auras aren't tracked) and
-- not NOT<CLASS> (AURA:COMP:NOT<CLASS> already addresses that unit).
-- Returns { kind, what, ordinal } or nil.
local function parsePlaceholderAddress(address)
    local base, digits = address:match("^(%u+)#(%d+)$")
    base = base or address
    local kind, what, negate, pet = classifyPlaceholder("@", base)
    if not kind or kind == "DUEL" or negate or pet then
        return nil
    end
    local ordinal = 1
    if digits then
        ordinal = tonumber(digits)
        if ordinal < 1 or kind == "PIN" then
            return nil
        end
    end
    return { kind = kind, what = what, ordinal = ordinal }
end

-- Validates an AURA:<ADDRESS> field identifier (already uppercased) and
-- returns its canonical form, plus the placeholder for a placeholder
-- address.
local function parseAuraField(identifier)
    local address = identifier:match("^AURA:([^:]+)$")
    if address and not auraUnitAddresses[address] then
        local placeholder = parsePlaceholderAddress(address)
        if placeholder then
            return identifier, nil, placeholder
        end
    end
    return parseAddressField("AURA", identifier, auraUnitAddresses, true)
end

-- Validates a COMBAT:<ADDRESS> field identifier (already uppercased) and
-- returns its canonical form. Uses combatUnitAddresses, not unitAddresses:
-- SELF is not a valid COMBAT address (see the comment on that table).
local function parseCombatField(identifier)
    return parseAddressField("COMBAT", identifier, combatUnitAddresses, true)
end

-- Parses one #WATCH line, including the optional ASSUME=<CLASS> modifier
-- accepted by the ARENA and DUEL watches (a template-local fallback class,
-- evaluated per-template at matching time only -- never written to shared
-- state).
local function addWatch(parsed, text)
    text = trim(text)
    local name, modifier = text:match("^(%S+)%s*(.-)$")
    name = string.upper(name or "")
    if name == "" then
        return nil, "#WATCH requires a semantic state name."
    end
    local canonical = watchNames[name]
    if not canonical then
        return nil, "Unknown watch: " .. name
    end
    parsed.watchSet[canonical] = true
    table.insert(parsed.watches, canonical)
    modifier = trim(modifier or "")
    if modifier == "" then
        return true
    end
    if canonical ~= "ARENA" and canonical ~= "DUEL" and canonical ~= "COMBAT" then
        return nil, "#WATCH " .. canonical .. " does not accept a modifier."
    end
    if string.upper(modifier):match("^ASSUME=%[") then
        return nil, "#WATCH " .. canonical .. " ASSUME accepts a single value, not a list."
    end
    local key, value = modifier:match("^([%a]+)=([%a]+)$")
    if key and string.upper(key) ~= "ASSUME" then
        return nil, "Unknown #WATCH " .. canonical .. " modifier: " .. string.upper(key)
    end
    if not value then
        return nil, "Malformed #WATCH " .. canonical .. " modifier (expected ASSUME=<CLASS>)."
    end
    local assumeValue = string.upper(value)
    if canonical == "COMBAT" then
        -- #WATCH COMBAT ASSUME=YES/NO: for this template only, a unit that
        -- exists but whose current combat status can't be assessed (e.g. a
        -- stealthed arena opponent) is treated as the assumed value at
        -- matching time -- never written to shared state. See §5.8.
        if not combatValues[assumeValue] then
            return nil, "#WATCH COMBAT ASSUME must be YES or NO: " .. assumeValue
        end
        if parsed.combatAssume and parsed.combatAssume ~= assumeValue then
            return nil, "Conflicting #WATCH COMBAT ASSUME declarations."
        end
        parsed.combatAssume = assumeValue
        return true
    end
    if not classNames[assumeValue] then
        return nil, "Unknown class in ASSUME: " .. assumeValue
    end
    local assumeKey = canonical == "ARENA" and "arenaAssume" or "duelAssume"
    if parsed[assumeKey] and parsed[assumeKey] ~= assumeValue then
        return nil, "Conflicting #WATCH " .. canonical .. " ASSUME declarations."
    end
    parsed[assumeKey] = assumeValue
    return true
end

-- Expression scanner. Quotes and bracket lists are respected, so AND/OR
-- keywords or commas inside quoted values never split a condition.
local Scanner = {}
Scanner.__index = Scanner

local function newScanner(text)
    return setmetatable({ text = text, pos = 1, length = #text }, Scanner)
end

function Scanner:skipSpace()
    while self.pos <= self.length and self.text:sub(self.pos, self.pos):match("%s") do
        self.pos = self.pos + 1
    end
end

function Scanner:atEnd()
    self:skipSpace()
    return self.pos > self.length
end

function Scanner:peek()
    return self.text:sub(self.pos, self.pos)
end

function Scanner:readWord()
    self:skipSpace()
    local word = self.text:match("^[%w_]+", self.pos)
    if word then
        self.pos = self.pos + #word
    end
    return word
end

function Scanner:readQuoted()
    local quote = self:peek()
    local closing = self.text:find(quote, self.pos + 1, true)
    if not closing then
        return nil, "Unterminated quote"
    end
    local value = self.text:sub(self.pos + 1, closing - 1)
    self.pos = closing + 1
    return value
end

-- Reads a field identifier: a plain word (CLASS) or a colon-qualified one
-- (AURA:TARGET, AURA:COMP:WARLOCK). Everything left of "=" is the identifier.
-- A part may end in "#N", the ordinal of a placeholder address
-- (AURA:ROGUE#2).
function Scanner:readFieldIdentifier()
    local word = self:readWord()
    if not word then
        return nil
    end
    local function readOrdinal()
        local ordinal = self.text:match("^#%d+", self.pos)
        if ordinal then
            self.pos = self.pos + #ordinal
            word = word .. ordinal
        end
    end
    readOrdinal()
    while self:peek() == ":" do
        self.pos = self.pos + 1
        local part = self:readWord()
        if not part then
            -- Trailing colon: return the malformed identifier so validation
            -- can report it properly.
            return word .. ":"
        end
        word = word .. ":" .. part
        readOrdinal()
    end
    return word
end

-- Reads one value: quoted, bare token, or [comma, separated, list].
-- Returns a list of uppercased accepted values. When stopColon is set, a
-- bare token stops at ":" (for a field whose value takes : suffixes).
function Scanner:readValues(stopColon)
    self:skipSpace()
    local char = self:peek()
    if char == '"' or char == "'" then
        local value, quoteError = self:readQuoted()
        if not value then
            return nil, quoteError
        end
        return { string.upper(value) }
    end
    if char == "[" then
        self.pos = self.pos + 1
        local values = {}
        while true do
            self:skipSpace()
            char = self:peek()
            if self.pos > self.length then
                return nil, "Unterminated [list]"
            end
            if char == "]" then
                self.pos = self.pos + 1
                break
            end
            local value, itemError
            if char == '"' or char == "'" then
                value, itemError = self:readQuoted()
                if not value then
                    return nil, itemError
                end
            else
                value = self.text:match("^[^,%]%s]+", self.pos)
                if not value then
                    return nil, "Malformed [list] value"
                end
                self.pos = self.pos + #value
            end
            table.insert(values, string.upper(value))
            self:skipSpace()
            char = self:peek()
            if char == "," then
                self.pos = self.pos + 1
            elseif char ~= "]" then
                return nil, "Expected , or ] in [list]"
            end
        end
        if #values == 0 then
            return nil, "[list] requires at least one value"
        end
        return values
    end
    local value = self.text:match(stopColon and "^[^%s:]+" or "^%S+", self.pos)
    if not value or value == "" then
        return nil, "Missing condition value"
    end
    self.pos = self.pos + #value
    return { string.upper(value) }
end

-- Parses `[NOT] FIELD=VALUE [AND ...] [OR ...]` into disjuncts: a list of
-- condition groups. The form matches if any single group fully matches.
-- FIELD may be colon-qualified (AURA:TARGET, AURA:COMP:WARLOCK).
-- `declares` (optional) maps an uppercased #DECLARE name to its already-
-- parsed { groups = ... } entry (§5.9). Passed by both #IF parsing (every
-- #DECLARE in the template, since all of them precede #DEFAULT) and by
-- #DECLARE parsing itself (only the names declared so far, enforcing
-- declare-before-use and making cycles impossible by construction).
-- Resolves an uppercased field identifier to its canonical name: a flat
-- field or alias, or a colon-addressed field (AURA:..., COMBAT:...).
-- Returns nil plus the address error for a malformed addressed field, and
-- plain nil for an identifier that is not a field at all (it may still be
-- a #DECLARE name). Shared by the parser and the editor's highlighter, so
-- both always agree on what is a valid field.
local addressParsers = {
    AURA = parseAuraField,
    COMBAT = parseCombatField,
}

local function resolveField(upper)
    local canonical = fieldNames[upper]
    if canonical then
        return canonical
    end
    local prefix = upper:match("^(%u+):")
    local parser = prefix and addressParsers[prefix]
    if parser then
        return parser(upper)
    end
    return nil
end

-- Flag names (FLAG=<NAME>, /qmc flag <NAME> -- §5.15): an identifier of at
-- most FLAG_NAME_MAX characters, stored uppercase. ON, OFF, TOGGLE and
-- CLEAR are the slash command's own words. The length cap keeps every flag
-- toggle in the editor's State section the same width. Returns the
-- uppercased name, or nil and an error.
local reservedFlagNames = { ON = true, OFF = true, TOGGLE = true, CLEAR = true }
local FLAG_NAME_MAX = 5
Compiler.FLAG_NAME_MAX = FLAG_NAME_MAX
function Compiler.ValidFlagName(name)
    local upper = string.upper(trim(tostring(name or "")))
    if not upper:match("^[%a_][%w_]*$") then
        return nil, "Invalid flag name: " .. upper .. " (letters, digits and _, not starting with a digit)"
    end
    if #upper > FLAG_NAME_MAX then
        return nil, "Invalid flag name: " .. upper .. " (" .. FLAG_NAME_MAX .. " characters at most)"
    end
    if reservedFlagNames[upper] then
        return nil, "Invalid flag name: " .. upper .. " (ON, OFF, TOGGLE and CLEAR are reserved)"
    end
    return upper
end

-- Aura measures (§5.7.1): AURA:<ADDRESS>:"<AURA>".TIME <op> <amount> and
-- .STACKS <op> <count>, on AURA:SELF and the group placeholders only. TIME
-- amounts carry a unit (s, m or h); they are kept in seconds.
local auraMeasures = { TIME = true, STACKS = true }
local TIME_UNITS = { S = 1, M = 60, H = 3600 }

-- Called right after readFieldIdentifier returned `upper` (uppercased).
-- When the identifier opens an aura measure, reads the aura name (quoted,
-- or a bare last part: AURA:SELF:RENEW.TIME) and ".TIME"/".STACKS".
-- Returns nil for an ordinary condition, { field, placeholder, aura,
-- measure } for an aura measure, or false and a message when it is
-- malformed.
local function readAuraMeasure(scanner, upper)
    if upper:sub(1, 5) ~= "AURA:" then
        return nil
    end
    local address, aura
    local char = scanner:peek()
    if upper:sub(-1) == ":" and (char == '"' or char == "'") then
        local name, quoteError = scanner:readQuoted()
        if not name then
            return false, quoteError
        end
        address, aura = upper:sub(1, -2), string.upper(name)
    elseif char == "." then
        address, aura = upper:match("^(AURA:.+):([^:]+)$")
        if not address then
            return false, "Name the aura before .TIME/.STACKS: " .. upper .. ":\"<AURA>\".TIME"
        end
    else
        return nil
    end
    local measure
    if scanner:peek() == "." then
        scanner.pos = scanner.pos + 1
        measure = scanner.text:match("^[%a]+", scanner.pos)
        scanner.pos = scanner.pos + #(measure or "")
        measure = measure and string.upper(measure)
    end
    if not auraMeasures[measure] then
        return false, "Expected .TIME or .STACKS after the aura name in " .. address
    end
    local field, addressError, placeholder = resolveField(address)
    if not field then
        return false, addressError or ("Invalid AURA address: " .. address)
    end
    if field ~= "AURA:SELF" and not placeholder then
        return false, "." .. measure .. " works on AURA:SELF and the group placeholders (ANY, MAINTANK, PRIEST#2...), not "
            .. address
    end
    return { field = field, placeholder = placeholder, aura = aura, measure = measure }
end

-- Reads a measure's amount: TIME takes a whole number with a unit (90s,
-- 15m, 1h -> seconds), STACKS a plain whole number. Returns the amount
-- and its text as written, or nil and a message.
local function readMeasureAmount(scanner, measure)
    scanner:skipSpace()
    local digits, unit = scanner.text:match("^(%d+)([%a]*)", scanner.pos)
    if not digits then
        return nil, "Expected a whole number for ." .. measure
    end
    scanner.pos = scanner.pos + #digits + #unit
    if measure == "STACKS" then
        if unit ~= "" then
            return nil, ".STACKS takes a plain number, not " .. digits .. unit
        end
        return tonumber(digits), digits
    end
    if unit == "" then
        return nil, "Add a unit to the .TIME amount: " .. digits .. "s, or minutes (" .. digits .. "m)"
    end
    local factor = TIME_UNITS[string.upper(unit)]
    if not factor then
        return nil, "Unknown time unit \"" .. unit .. "\" (use s, m or h)"
    end
    return tonumber(digits) * factor, digits .. string.lower(unit)
end

-- The comparison after a measure: <, <=, > or >= and the amount.
local function readMeasureComparison(scanner, measure)
    scanner:skipSpace()
    local op = scanner.text:match("^[<>]=?", scanner.pos)
    if not op then
        return nil, "Expected <, <=, > or >= after ." .. measure.measure
    end
    scanner.pos = scanner.pos + #op
    local amount, amountText = readMeasureAmount(scanner, measure.measure)
    if not amount then
        return nil, amountText
    end
    return {
        field = measure.field, placeholder = measure.placeholder, aura = measure.aura,
        measure = measure.measure, op = op, amount = amount, amountText = amountText,
    }
end

local function parseConditions(expression, declares)
    local scanner = newScanner(trim(expression or ""))
    local groups = {}
    local current = {}
    while true do
        local field = scanner:readFieldIdentifier()
        if not field then
            return nil, "Invalid condition near: " .. scanner.text:sub(scanner.pos, scanner.pos + 20)
        end
        local negated = false
        if string.upper(field) == "NOT" then
            negated = true
            field = scanner:readFieldIdentifier()
            if not field then
                return nil, "Expected a state variable after NOT"
            end
        end
        local upper = string.upper(field)
        local measure, measureError = readAuraMeasure(scanner, upper)
        if measure == false then
            return nil, measureError
        end
        local canonical, addressError, placeholder
        if not measure then
            canonical, addressError, placeholder = resolveField(upper)
            if not canonical and addressError then
                return nil, addressError
            end
        end
        local declared = not measure and not canonical and declares and declares[upper]
        if not measure and not canonical and not declared then
            return nil, "Unknown state variable: " .. upper
        end
        if measure then
            local condition, comparisonError = readMeasureComparison(scanner, measure)
            if not condition then
                return nil, comparisonError .. " for " .. measure.field
            end
            condition.negated = negated
            table.insert(current, condition)
        elseif declared then
            -- A #DECLARE reference (§5.9): an opaque boolean term with no
            -- "=value" of its own. Counts as exactly one condition for
            -- specificity, the same way a bracket list does (§5.5, §7).
            table.insert(current, { field = "VAR:" .. upper, declaredGroups = declared.groups, negated = negated })
        else
            scanner:skipSpace()
            if scanner:peek() ~= "=" then
                return nil, "Expected = after " .. upper
            end
            scanner.pos = scanner.pos + 1
            local values, valueError = scanner:readValues()
            if not values then
                return nil, valueError .. " for " .. upper
            end
            if canonical == "REACTION" then
                for _, accepted in ipairs(values) do
                    if not reactionValues[accepted] then
                        return nil, "Invalid REACTION value: " .. accepted .. " (expected ENEMY, ALLY, or NEUTRAL)"
                    end
                end
            end
            if canonical == "PET" then
                for _, accepted in ipairs(values) do
                    if not petValues[accepted] then
                        return nil, "Invalid PET value: " .. accepted
                            .. " (expected YES, NO, IMP, SUCCUBUS, FELHUNTER, VOIDWALKER, FELGUARD, or INFERNAL)"
                    end
                end
            end
            if canonical == "DUEL_SUCCUBUS" then
                for _, accepted in ipairs(values) do
                    if not combatValues[accepted] then
                        return nil, "Invalid DUEL_SUCCUBUS value: " .. accepted .. " (expected YES or NO)"
                    end
                end
            end
            if canonical == "FLAG" then
                for _, accepted in ipairs(values) do
                    local _, flagError = Compiler.ValidFlagName(accepted)
                    if flagError then
                        return nil, flagError
                    end
                end
            end
            if canonical:sub(1, 7) == "COMBAT:" then
                for _, accepted in ipairs(values) do
                    if not combatValues[accepted] then
                        return nil, "Invalid COMBAT value: " .. accepted .. " (expected YES or NO)"
                    end
                end
            end
            table.insert(current, {
                field = canonical, values = values, negated = negated, placeholder = placeholder,
            })
        end
        if scanner:atEnd() then
            break
        end
        local keyword = scanner:readWord()
        keyword = keyword and string.upper(keyword)
        if keyword == "AND" then
            -- continue current group
        elseif keyword == "OR" then
            table.insert(groups, current)
            current = {}
        else
            return nil, "Expected AND or OR near: " .. tostring(keyword)
        end
        if scanner:atEnd() then
            return nil, "Dangling " .. keyword .. " in condition"
        end
    end
    table.insert(groups, current)
    for _, group in ipairs(groups) do
        if #group == 0 then
            return nil, "#IF requires a condition."
        end
    end
    return groups
end

-- Reserved words that can never be used as a #DECLARE name -- either
-- grammar keywords (which would make the declare line itself unparsable)
-- or the #DEFAULT directive name.
local reservedDeclareNames = {
    AND = true,
    OR = true,
    NOT = true,
    DEFAULT = true,
    OFF = true, -- #MODE NAME OFF (§5.13)
}

-- Parses one `#DECLARE NAME=<condition expression>` line (§5.9). The body
-- uses the exact same grammar as #IF (including references to earlier
-- #DECLAREs), via parseConditions. The name must not shadow a real field
-- name/alias/reserved word, and must not already be declared in this
-- template.
-- Stamps every condition in an OR-of-AND group list with the source line
-- it was written on, so warnings (Compiler.Lint) can point at it even after
-- nested #IF flattening has copied it into several forms.
local function stampLine(groups, lineNumber)
    for _, group in ipairs(groups) do
        for _, condition in ipairs(group) do
            condition.line = condition.line or lineNumber
        end
    end
end

local function addDeclare(parsed, text, lineNumber)
    text = trim(text)
    local name, rest = text:match("^([%a_][%w_]*)%s*=%s*(.*)$")
    if not name then
        return nil, "Malformed #DECLARE (expected NAME=CONDITION)."
    end
    local upperName = string.upper(name)
    if reservedDeclareNames[upperName] then
        return nil, "#DECLARE name cannot be a reserved word: " .. upperName
    end
    if fieldNames[upperName] or addressParsers[upperName] or upperName:match("^AURA:") or upperName:match("^COMBAT:")
        then
        return nil, "#DECLARE name conflicts with an existing state variable: " .. upperName
    end
    if parsed.declares[upperName] then
        return nil, "Duplicate #DECLARE: " .. upperName
    end
    if rest == "" then
        return nil, "#DECLARE requires a condition expression."
    end
    local groups, conditionError = parseConditions(rest, parsed.declares)
    if not groups then
        return nil, conditionError
    end
    stampLine(groups, lineNumber)
    parsed.declares[upperName] = { name = upperName, expression = rest, groups = groups, line = lineNumber }
    table.insert(parsed.declareOrder, upperName)
    return true
end


-- ---------------------------------------------------------------------------
-- Nested #IF (§5.5.1): pure condition-grouping sugar, never a real
-- evaluation feature. A nested #IF's conditions are AND-ed onto every
-- ancestor #IF's conditions; there is no #ELSE. A block with nested
-- children may carry its own body only AFTER all of them (one more flat
-- form using just its own combined condition) -- nesting
-- only ever expands into ordinary, independent flat #IF forms, identical
-- to what an author would get from typing each combination out by hand.
-- The tree built during parsing (parsed.ifRoots) exists only to make that
-- expansion easy to write; nothing past Compiler.Parse ever sees it --
-- Compile, formSpecificity, RebuildConditionRegistries etc. only ever see
-- the flattened parsed.forms list, exactly as before this feature existed.
-- ---------------------------------------------------------------------------

-- AND-joins two OR-of-AND group lists by cross product: every resulting
-- group is one group from `a` concatenated with one group from `b`. This
-- is the distribution step ((P1 OR P2) AND (C1 OR C2) = ...) that lets an
-- ancestor's OR-disjuncts combine correctly with a descendant's.
local function crossJoinGroups(a, b)
    local result = {}
    for _, groupA in ipairs(a) do
        for _, groupB in ipairs(b) do
            local combined = {}
            for _, condition in ipairs(groupA) do
                table.insert(combined, condition)
            end
            for _, condition in ipairs(groupB) do
                table.insert(combined, condition)
            end
            table.insert(result, combined)
        end
    end
    return result
end

-- Walks one #IF node of the nesting tree, appending one flattened, fully
-- ordinary #IF form per leaf into `forms`. `ancestorGroups` is the
-- AND-combination of every open ancestor so far (the identity value {{}}
-- -- one empty group, "true" -- at the root). `ancestorPriority` carries
-- the nearest declared ancestor #IF[n] down to descendants that don't
-- declare their own (a child's own #IF[n], if present, always overrides
-- rather than combines -- priority is tie-break metadata, not a
-- condition to AND together).
local function flattenIfNode(node, ancestorGroups, ancestorPriority, ancestorExpression, forms, mode)
    local expression = ancestorExpression == "" and node.expression
        or (ancestorExpression .. " AND " .. node.expression)
    local combinedGroups = crossJoinGroups(ancestorGroups, node.groups)
    local effectivePriority = node.priority or ancestorPriority
    -- A node emits its own flattened leaf form whenever it has no children
    -- (the ordinary case -- possibly an empty body) OR it accumulated its
    -- own trailing body text alongside children (§5.5.1's "own body after
    -- nested #IF blocks" form). Either way, children (if any) are always
    -- flattened too, using this node's own combined condition as their
    -- ancestor contribution.
    if #node.children == 0 or node.sawBody then
        table.insert(forms, {
            expression = expression,
            groups = combinedGroups,
            priority = effectivePriority or 0,
            output = trimBody(node.lines),
            bodyLines = node.lines,
            bodyLineNumbers = node.lineNumbers,
            line = node.lineNumber,
            mode = mode,
        })
    end
    for _, child in ipairs(node.children) do
        flattenIfNode(child, combinedGroups, effectivePriority, expression, forms, mode)
    end
end

-- ---------------------------------------------------------------------------
-- Modes (§5.13): `#MODE[n] NAME CONDITION` opens a region that runs until
-- the next #MODE or the end of the template. Like nesting, a mode is pure
-- grouping sugar: its own body (the text right after the header, or after
-- an optional `#DEFAULT` marker) becomes one form whose condition is the
-- mode's, and each of its #IF blocks -- written exactly as at template
-- level, flat ones closing implicitly -- has the mode's condition AND-ed
-- in front. The mode's #MODE[n] priority is inherited the same way an
-- ancestor #IF[n] is. Nothing after Compiler.Parse sees modes, except the
-- `mode` tag on each form (for the editor's evaluation panel and tabs).
-- ---------------------------------------------------------------------------

-- `#MODE NAME CONDITION` / `#MODE[n] NAME CONDITION`. Returns a mode node
-- (without groups) or nil and an error message.
local function parseModeHeader(directive)
    local priorityText, rest = directive:match("^#MODE%[(%d+)%]%s*(.*)$")
    local priority
    if priorityText then
        priority = tonumber(priorityText)
    elseif directive:match("^#MODE%[") then
        return nil, "malformed #MODE priority (expected #MODE[n] NAME CONDITION)."
    else
        rest = directive:match("^#MODE%s+(.*)$") or ""
    end
    local name, expression = rest:match("^([%a_][%w_]*)%s+(.-)%s*$")
    if not name then
        if rest:match("^([%a_][%w_]*)%s*$") then
            return nil, "#MODE needs a condition (expected #MODE NAME CONDITION)."
        end
        return nil, "Malformed #MODE (expected #MODE NAME CONDITION)."
    end
    if expression == "" then
        return nil, "#MODE needs a condition (expected #MODE NAME CONDITION)."
    end
    return { name = string.upper(name), displayName = name, expression = expression, priority = priority }
end

-- A mode condition containing OR reads ambiguously when prefixed to a
-- child's expression; the evaluation panel shows it parenthesized (display
-- only -- the grammar itself has no parentheses).
local function modeDisplayExpression(expression)
    if (" " .. string.upper(expression) .. " "):find("%sOR%s") then
        return "(" .. expression .. ")"
    end
    return expression
end

-- True for a line (already trimmed) that opens a mode. Shared with
-- Compiler.SplitModes so the editor's tabs split exactly where the parser
-- does.
local function isModeHeader(directive)
    return directive:match("^#MODE[%s%[]") ~= nil or directive == "#MODE"
end

-- True for a whole-line comment: `#--` anywhere (metadata or body). The
-- parser drops these before anything else looks at the line, so they never
-- reach compiled output and never count as body text.
-- True when every condition of an OR-of-AND group list tests one of
-- `fields` (a set of field names).
local function testsOnly(groups, fields)
    if not groups or #groups == 0 then
        return false
    end
    for _, group in ipairs(groups) do
        for _, condition in ipairs(group) do
            if not fields[condition.field] then
                return false
            end
        end
    end
    return true
end

-- A mode's tier: a live mode makes every mode of a lower tier yield.
-- Duel modes (only DUEL / DUEL_SUCCUBUS) lead, since a duel can sit inside
-- an instance on some servers (Warmane's Ruby Sanctum duel area, §5.13);
-- flag modes (only FLAG) yield to every other mode (§5.15).
local MODE_TIER_FLAG, MODE_TIER_ORDINARY, MODE_TIER_DUEL = 0, 1, 2
local DUEL_FIELDS = { DUEL = true, DUEL_SUCCUBUS = true }
local FLAG_FIELDS = { FLAG = true }
local function modeTier(groups)
    if testsOnly(groups, DUEL_FIELDS) then
        return MODE_TIER_DUEL
    elseif testsOnly(groups, FLAG_FIELDS) then
        return MODE_TIER_FLAG
    end
    return MODE_TIER_ORDINARY
end

local function isComment(directive)
    return directive:sub(1, 3) == "#--"
end

function Compiler.Parse(source)
    if type(source) ~= "string" then
        return nil, "Template source must be text."
    end
    local parsed = {
        source = source,
        watches = {},
        watchSet = {},
        compilePolicy = "QUEUE",
        compileDirectiveSeen = false,
        declares = {},
        declareOrder = {},
        default = nil,
        ifRoots = {},
        modes = {},
        forms = {},
    }
    local phase = "metadata"
    local current
    -- Stack of currently-open #IF nodes, outermost first. Empty means
    -- we're not inside any #IF (top level: before the first #IF, or
    -- between a fully-closed root #IF and the next one).
    local ifStack = {}
    -- The mode currently being read (nil while in the template's base
    -- region). Root #IFs go to its own ifRoots instead of the template's.
    local currentMode
    local function rootList()
        return currentMode and currentMode.ifRoots or parsed.ifRoots
    end
    -- Closes whatever top-level #IF is still open at a region boundary (a
    -- #MODE header, or the end of the template). A lone root leaf closes
    -- implicitly, exactly as at the end of a template; anything nested must
    -- have been closed with #ENDIF.
    local function closeRegion(atLine)
        if #ifStack == 0 then
            return true
        end
        if #ifStack == 1 and #ifStack[1].children == 0 then
            table.remove(ifStack)
            return true
        end
        local unclosed = ifStack[#ifStack]
        local message = "Line " .. unclosed.lineNumber .. ": #IF is missing a matching #ENDIF"
            .. (atLine and (" before the #MODE at line " .. atLine) or "") .. "."
        -- The most likely cause of an unclosed nested block in an old
        -- flat template: an #IF with an EMPTY body directly followed by
        -- another #IF reads as "open a nested child" (§5.5.1). Say so.
        local parent = ifStack[#ifStack - 1]
        if parent and not parent.sawBody and parent.children[1] == ifStack[#ifStack] then
            message = message .. " If the #IF at line " .. parent.lineNumber
                .. " was meant to have an empty body, close it with #ENDIF before line "
                .. unclosed.lineNumber .. "."
        end
        return nil, message
    end
    local lines = splitLines(source)
    for lineNumber, line in ipairs(lines) do
        local directive = trim(line)
        if isComment(directive) then
            -- #-- comment: dropped entirely (§5.14). Not body text, not a
            -- directive, invisible to nesting and mode structure.
        elseif directive == "" then
            if current then
                addBodyLine(current, line, lineNumber)
            end
        elseif isModeHeader(directive) then
            if not parsed.default then
                return nil, "Line " .. lineNumber .. ": #MODE must follow #DEFAULT."
            end
            local ok, closeError = closeRegion(lineNumber)
            if not ok then
                return nil, closeError
            end
            local mode, modeError = parseModeHeader(directive)
            if not mode then
                return nil, "Line " .. lineNumber .. ": " .. modeError
            end
            for _, existing in ipairs(parsed.modes) do
                if existing.name == mode.name then
                    return nil, "Line " .. lineNumber .. ": duplicate #MODE name " .. mode.name
                        .. " (first used at line " .. existing.lineNumber .. ")."
                end
            end
            -- `#MODE NAME OFF`: a parked mode (§5.13). Its branches are
            -- parsed and checked like any other, but never compiled.
            local groups, conditionError
            if string.upper(mode.expression) == "OFF" then
                mode.off = true
                groups = {}
            else
                groups, conditionError = parseConditions(mode.expression, parsed.declares)
            end
            if not groups then
                return nil, "Line " .. lineNumber .. ": " .. conditionError
            end
            stampLine(groups, lineNumber)
            mode.groups = groups
            mode.lineNumber = lineNumber
            mode.lines = {}
            mode.ifRoots = {}
            mode.kind = "MODE"
            table.insert(parsed.modes, mode)
            currentMode = mode
            current = mode
            phase = "body"
        elseif phase == "metadata" and directive:match("^#WATCH%s+") then
            local ok, errorMessage = addWatch(parsed, directive:sub(8))
            if not ok then
                return nil, "Line " .. lineNumber .. ": " .. errorMessage
            end
        elseif phase == "metadata" and directive:match("^#COMPILE%s+") then
            local policy = string.upper(trim(directive:sub(9)))
            if policy ~= "QUEUE" and policy ~= "IGNORE" then
                return nil, "Line " .. lineNumber .. ": #COMPILE must be QUEUE or IGNORE."
            end
            if parsed.compileDirectiveSeen then
                return nil, "Line " .. lineNumber .. ": duplicate #COMPILE directives."
            end
            parsed.compilePolicy = policy
            parsed.compileDirectiveSeen = true
        elseif phase == "metadata" and (directive:match("^#SEQUENCE%s+") or directive == "#SEQUENCE") then
            if parsed.sequenceLine then
                return nil, "Line " .. lineNumber .. ": duplicate #SEQUENCE (first at line "
                    .. parsed.sequenceLine .. ")."
            end
            local rules, sequenceError = parseSequence(directive:sub(10))
            if not rules then
                return nil, "Line " .. lineNumber .. ": " .. sequenceError
            end
            parsed.resets = rules
            parsed.sequenceLine = lineNumber
        elseif phase == "metadata" and directive:match("^#DECLARE%s+") then
            local ok, errorMessage = addDeclare(parsed, directive:sub(9), lineNumber)
            if not ok then
                return nil, "Line " .. lineNumber .. ": " .. errorMessage
            end
        elseif directive == "#DEFAULT" and currentMode then
            -- Optional marker for the mode's own body. Allowed only where
            -- the mode's body can still start: before its first #IF and
            -- before any body text. Writing it makes an intentionally empty
            -- mode body count (the mode then compiles to nothing, instead
            -- of falling back to the template's #DEFAULT).
            if currentMode.defaultSeen then
                return nil, "Line " .. lineNumber .. ": duplicate #DEFAULT in #MODE " .. currentMode.name .. "."
            end
            if #currentMode.ifRoots > 0 or #ifStack > 0 then
                return nil, "Line " .. lineNumber .. ": a mode's #DEFAULT must come before its #IF blocks."
            end
            if trimBody(currentMode.lines) ~= "" then
                return nil, "Line " .. lineNumber .. ": a mode's #DEFAULT must come before its body text."
            end
            currentMode.defaultSeen = true
            current = currentMode
        elseif directive == "#DEFAULT" then
            if parsed.default then
                return nil, "Line " .. lineNumber .. ": duplicate #DEFAULT."
            end
            parsed.default = { kind = "DEFAULT", lines = {} }
            current = parsed.default
            phase = "body"
        elseif directive:match("^#IF%s+") or directive:match("^#IF%[") then
            if not parsed.default then
                return nil, "Line " .. lineNumber .. ": #IF must follow #DEFAULT."
            end
            -- Optional explicit priority: #IF[n] CONDITION. The priority only
            -- breaks equal-specificity ties; it never outranks specificity.
            -- nil (not 0) means "not declared at this level", so a nested
            -- #IF without its own [n] can inherit an ancestor's instead of
            -- silently defaulting to 0.
            local priority = nil
            local expression
            local priorityText, rest = directive:match("^#IF%[(%d+)%]%s*(.*)$")
            if priorityText then
                priority = tonumber(priorityText)
                expression = rest
            else
                if directive:match("^#IF%[") then
                    return nil, "Line " .. lineNumber .. ": malformed #IF priority (expected #IF[n] CONDITION)."
                end
                expression = directive:sub(5)
            end
            local groups, conditionError = parseConditions(expression, parsed.declares)
            if not groups then
                return nil, "Line " .. lineNumber .. ": " .. conditionError
            end
            stampLine(groups, lineNumber)
            local node = {
                kind = "IF",
                expression = expression,
                groups = groups,
                priority = priority,
                lines = {},
                sawBody = false,
                children = {},
                lineNumber = lineNumber,
            }
            local top = ifStack[#ifStack]
            if not top then
                -- Top level (of the template, or of the current mode): a
                -- new root #IF.
                table.insert(rootList(), node)
                table.insert(ifStack, node)
            elseif top.sawBody and #top.children == 0 then
                -- top is a plain leaf-in-progress with no children yet:
                -- body text came first, with nothing nested under it. A
                -- root leaf may still be closed implicitly here, exactly
                -- like before nesting existed -- this is the classic flat
                -- template pattern (no #ENDIF anywhere), and it must keep
                -- meaning "two independent forms" for backward
                -- compatibility, since there is no way to tell it apart
                -- from a genuinely-intended nested child from the text
                -- alone. Anything deeper must be closed with an explicit
                -- #ENDIF first. (A block's own body text CAN still combine
                -- with nested children -- see the sawBody branch below and
                -- §5.5.1 -- but only when written AFTER them; body written
                -- first, as here, can never retroactively become a branch
                -- without risking exactly this ambiguity.)
                if #ifStack == 1 then
                    table.remove(ifStack)
                    table.insert(rootList(), node)
                    table.insert(ifStack, node)
                else
                    return nil, "Line " .. lineNumber .. ": missing #ENDIF to close the #IF opened at line "
                        .. top.lineNumber .. "."
                end
            elseif top.sawBody then
                -- top already has at least one child AND has since
                -- accumulated its own trailing body text (§5.5.1): that
                -- body is meant to be its last piece of content, right
                -- before its own #ENDIF. A #IF appearing after it would be
                -- interleaving, not trailing -- reject it rather than
                -- guess whether it belongs before or after the body
                -- that's already there.
                return nil, "Line " .. lineNumber
                    .. ": a #IF's own body text must come after all of its nested #IF blocks, "
                    .. "immediately before its own #ENDIF -- no #IF may follow it."
            else
                -- top is fresh or already a branch with no trailing body
                -- yet: the new #IF becomes its child.
                table.insert(top.children, node)
                table.insert(ifStack, node)
            end
            current = node
            phase = "body"
        elseif directive == "#ELSE" then
            return nil, "Line " .. lineNumber
                .. ": #ELSE is not supported; nested #IF has no implicit fallback body (see spec §5.5.1)."
        elseif directive == "#ENDIF" then
            if #ifStack == 0 then
                return nil, "Line " .. lineNumber .. ": #ENDIF has no matching #IF."
            end
            table.remove(ifStack)
            current = ifStack[#ifStack] -- parent node, or nil if a root just closed
        elseif directive:match("^#WATCH") or directive:match("^#COMPILE") or directive:match("^#DECLARE")
            or directive:match("^#SEQUENCE") then
            return nil, "Line " .. lineNumber .. ": metadata directives must appear before #DEFAULT."
        elseif phase == "metadata" and blockHeader(directive) ~= nil then
            return nil, "Line " .. lineNumber .. ": " .. directive
                .. " belongs in a body (after #DEFAULT, #MODE or #IF)."
        elseif phase == "metadata" and directive:sub(1, 1) == "#" then
            return nil, "Line " .. lineNumber .. ": unknown compiler directive."
        elseif current then
            -- Body text is always legal to append here, whether current
            -- has children yet or not (§5.5.1): a block with zero
            -- children is an ordinary leaf; a block with children may
            -- still carry its own trailing body, appended after all of
            -- them, as one more independent flattened form. The one thing
            -- this can never become is interleaved with further #IF
            -- children -- that's rejected above, at the point a new #IF
            -- would try to follow trailing body that's already started.
            if current.sawBody ~= nil then
                current.sawBody = true
            end
            addBodyLine(current, line, lineNumber)
        else
            if parsed.default then
                -- Only reachable after a top-level #ENDIF closed the last
                -- open block: there is no block left to hold this text.
                return nil, "Line " .. lineNumber .. ": text after #ENDIF is outside any #IF block."
            end
            return nil, "Line " .. lineNumber .. ": content must follow #DEFAULT."
        end
    end
    if not parsed.default then
        return nil, "Template must contain #DEFAULT."
    end
    -- A single still-open root LEAF (zero children, whether or not it has
    -- body text) closes implicitly at end of file, exactly like before
    -- nesting existed -- an #IF with no trailing #ENDIF and nothing after
    -- it is business as usual. Anything else -- a still-open nested block,
    -- or a root that gained children but was never explicitly closed -- is
    -- an error: there is no indentation to infer the missing #ENDIF(s) from.
    local closed, closeError = closeRegion(nil)
    if not closed then
        return nil, closeError
    end
    parsed.default.output = trimBody(parsed.default.lines)
    for _, root in ipairs(parsed.ifRoots) do
        flattenIfNode(root, { {} }, nil, "", parsed.forms)
    end
    -- Mode tiers (§5.13, §5.15): a flag mode is the player's fallback for
    -- states the game cannot detect, so it steps aside whenever any other
    -- mode's condition is true; every non-duel mode steps aside for a live
    -- duel mode. Each mode form carries its mode's tier; selectForm drops
    -- the forms of a lower tier than a live mode's.
    for _, mode in ipairs(parsed.modes) do
        mode.tier = modeTier(mode.groups)
    end
    -- A parked (OFF) mode's forms go to parsed.parkedForms instead: checked
    -- below like any others, never selected, watched or flag-collected.
    parsed.parkedForms = {}
    for _, mode in ipairs(parsed.modes) do
        local modeExpression = modeDisplayExpression(mode.expression)
        local body = trimBody(mode.lines)
        local forms = mode.off and parsed.parkedForms or parsed.forms
        local firstForm = #forms + 1
        if mode.defaultSeen or body ~= "" then
            table.insert(forms, {
                expression = modeExpression,
                groups = mode.groups,
                priority = mode.priority or 0,
                output = body,
                bodyLines = mode.lines,
                bodyLineNumbers = mode.lineNumbers,
                line = mode.lineNumber,
                mode = mode.name,
            })
        end
        for _, root in ipairs(mode.ifRoots) do
            flattenIfNode(root, mode.off and { {} } or mode.groups, mode.priority, modeExpression, forms, mode.name)
        end
        for index = firstForm, #forms do
            forms[index].tier = mode.tier
        end
    end
    -- Stepped bodies (§5.17): split each body into its blocks.
    local stepped = false
    local holders = { parsed.default, unpack(parsed.forms) }
    local parked = {}
    for _, form in ipairs(parsed.parkedForms) do
        table.insert(holders, form)
        parked[form] = true
    end
    for _, holder in ipairs(holders) do
        local lines, numbers = holder.bodyLines or holder.lines, holder.bodyLineNumbers or holder.lineNumbers
        local sequence, stepError = splitSteps(lines, numbers)
        if sequence == false then
            return nil, stepError
        end
        if sequence then
            holder.sequence = sequence
            holder.blocks = sequenceTexts(sequence)
            stepped = stepped or not parked[holder]
        end
    end
    parsed.stepped = stepped
    parsed.resets = parsed.resets or Compiler.DEFAULT_RESETS
    -- Non-fatal warnings (typos in closed vocabularies, missing #WATCH
    -- lines). Never turns a valid template into an error.
    parsed.warnings = Compiler.Lint(parsed)
    return parsed
end

-- A nil state value never matches, negated or not (unknown ≠ anything,
-- so "NOT FIELD=X" only matches when FIELD is known and differs).
-- A table state value (e.g. an AURA:<ADDRESS> name set) is a membership
-- test.

-- AURA:COMP:<CLASS> matches when any arena opponent currently identified as
-- that class has one of the listed auras active right now. Unlike a direct
-- AURA:ARENAn lookup this isn't a single stored table -- which slots count
-- shifts as opponents get revealed -- so it's recomputed here from
-- values.ARENAn (each slot's class) and values["AURA:ARENAn"] (that slot's
-- current aura set), both kept in lockstep by State:RefreshArena. No
-- opponent of the class currently in the match is a known, legitimate "no",
-- not "unknown", so nil never short-circuits negation here.
local function auraCompConditionMatches(values, condition)
    local wantedClass = condition.field:match("^AURA:COMP:(.+)$")
    local matched = false
    for index = 1, 5 do
        if values["ARENA" .. index] == wantedClass then
            local auras = values["AURA:ARENA" .. index]
            if type(auras) == "table" then
                for _, accepted in ipairs(condition.values) do
                    if auras[accepted] then
                        matched = true
                        break
                    end
                end
            end
        end
        if matched then
            break
        end
    end
    if condition.negated then
        return not matched
    end
    return matched
end

-- COMBAT:COMP:<CLASS> matches when any current arena opponent classified
-- as that class currently has the given combat status (YES/NO) -- the
-- COMBAT counterpart to AURA:COMP:<CLASS>. Like
-- AURA:COMP, this is existential ("any") over every arena slot classified
-- as that class: COMBAT:COMP:ROGUE=NO matches as soon as one
-- Rogue-classified opponent is flagged out of combat.
--
-- Sharp edge: because it's existential over the CLASS's slots, not a
-- negation of COMBAT:COMP:ROGUE=YES, "no rogue currently in the match"
-- makes BOTH =YES and =NO evaluate false -- there is no rogue slot to
-- satisfy either. To say "no rogue is in combat, including when no rogue
-- is in the match at all", write `NOT COMBAT:COMP:ROGUE=YES`, not
-- `COMBAT:COMP:ROGUE=NO`. The NOT keyword is what carries AURA:COMP's "no
-- qualifying opponent is a known, legitimate no" exception here too --
-- the literal value NO does not.
local function combatCompConditionMatches(values, condition)
    local wantedClass = condition.field:match("^COMBAT:COMP:(.+)$")
    local matched = false
    for index = 1, 5 do
        if values["ARENA" .. index] == wantedClass then
            local status = values["COMBAT:ARENA" .. index]
            -- Only a resolved YES/NO counts. Status can also be "UNKNOWN"
            -- (the slot's class is known but its live combat flag can't
            -- currently be assessed, e.g. a stealthed opponent -- §5.8);
            -- that must not silently count as either YES or NO here. A
            -- #WATCH COMBAT ASSUME=YES/NO overlay (applied by the caller
            -- before this function ever runs, in CompileValuesFor) is what
            -- turns UNKNOWN into a real status for a template that opts in.
            if status == "YES" or status == "NO" then
                for _, accepted in ipairs(condition.values) do
                    if status == accepted then
                        matched = true
                        break
                    end
                end
            end
        end
        if matched then
            break
        end
    end
    if condition.negated then
        return not matched
    end
    return matched
end


-- Resolves the single arena slot addressed by <PREFIX>:COMP:NOT:<CLASS>:
-- the lowest-numbered slot whose class is *known* and differs from
-- <CLASS>. This is the single-unit mirror of AURA:COMP/COMBAT:COMP
-- (which are existential over every slot of a matching class):
-- COMP:NOT:<CLASS> resolves to one specific opponent -- "the other guy"
-- -- so it can back an ordinary per-unit AURA/COMBAT lookup exactly the
-- way ARENAn does.
--
-- A slot whose class is still unresolved never qualifies, even though it
-- might well not be <CLASS> -- unlike AURA:COMP's "no qualifying opponent
-- is a known, legitimate no" exception, an unresolved slot here really
-- could BE <CLASS>, so treating it as "not <CLASS>" would be a guess, not
-- a fact. (A #WATCH ARENA ASSUME=<CLASS> overlay, when active, already
-- resolves the slot's class before this ever runs -- see CompileValuesFor
-- -- so ASSUME applies here for free, the same way it already does for
-- COMP.) No qualifying slot at all means this address doesn't currently
-- exist -- never matches, negated or not -- the same convention a direct
-- ARENAn/PARTYn address already uses, not COMP's "empty is a known no."
local function resolveNotClassSlot(values, excludedClass)
    for index = 1, 5 do
        local slotClass = values["ARENA" .. index]
        if slotClass and slotClass ~= excludedClass then
            return index
        end
    end
    return nil
end

-- AURA:COMP:NOT:<CLASS> matches when the resolved COMP:NOT:<CLASS>
-- opponent (see resolveNotClassSlot) currently has one of the listed
-- auras. No qualifying opponent is checked FIRST and returns false
-- immediately, bypassing negation -- unlike AURA:COMP:<CLASS>'s "no
-- qualifying opponent is a known, legitimate no" exception,
-- COMP:NOT:<CLASS> addresses a single unit, so "no such unit" must follow
-- the ordinary "unknown never matches, negated or not" rule instead.
local function auraNotConditionMatches(values, condition)
    local excludedClass = condition.field:match("^AURA:COMP:NOT:(.+)$")
    local index = resolveNotClassSlot(values, excludedClass)
    if not index then
        return false
    end
    local matched = false
    local auras = values["AURA:ARENA" .. index]
    if type(auras) == "table" then
        for _, accepted in ipairs(condition.values) do
            if auras[accepted] then
                matched = true
                break
            end
        end
    end
    if condition.negated then
        return not matched
    end
    return matched
end

-- COMBAT:COMP:NOT:<CLASS> matches when the resolved COMP:NOT:<CLASS>
-- opponent (see resolveNotClassSlot) currently has the given combat
-- status. Reads values["COMBAT:ARENAn"] directly, so a #WATCH COMBAT
-- ASSUME overlay (which rewrites those same keys before Compile ever
-- runs -- see CompileValuesFor) already applies here with no extra
-- handling, exactly as it does for COMBAT:COMP:<CLASS>. As with
-- AURA:COMP:NOT above, "no qualifying opponent" returns false
-- immediately, ahead of negation.
local function combatNotConditionMatches(values, condition)
    local excludedClass = condition.field:match("^COMBAT:COMP:NOT:(.+)$")
    local index = resolveNotClassSlot(values, excludedClass)
    if not index then
        return false
    end
    local status = values["COMBAT:ARENA" .. index]
    if status ~= "YES" and status ~= "NO" then
        -- "UNKNOWN" (exists, unassessable, no ASSUME overlay resolved it)
        -- or nil (shouldn't normally happen once the slot's class is
        -- known, but handled the same defensively): never matches,
        -- negated or not, exactly like a direct COMBAT:<ADDRESS>.
        return false
    end
    local matched = false
    for _, accepted in ipairs(condition.values) do
        if status == accepted then
            matched = true
            break
        end
    end
    if condition.negated then
        return not matched
    end
    return matched
end

-- PET matches the player's own pet. PET=<TYPE> (IMP, SUCCUBUS, FELHUNTER,
-- VOIDWALKER, FELGUARD, INFERNAL) tests the specific demon currently
-- summoned; PET=YES/NO tests whether any pet is summoned at all,
-- independent of type.
--
-- Unlike every other "unknown never matches" field in this compiler, "no
-- pet summoned" is not an unassessable state for the player's own pet --
-- UnitExists("pet") is always immediate and definite, with none of the
-- stealth/fog-of-war ambiguity a remote arena opponent's status can have
-- -- so PET=NO is a real, positive match on a known "no", and PET=YES/NO
-- both participate in ordinary negation (NOT PET=YES is exactly PET=NO).
--
-- A specific demon-type comparison is different: it still follows the
-- usual "unknown never matches, negated or not" convention when no pet
-- exists at all, exactly like CLASS/SPEC/PARTYn against a nonexistent
-- unit -- NOT PET=IMP means "a pet exists and it is not an Imp", not "no
-- pet or not an Imp". Values.PET itself can be nil (no pet), a specific
-- uppercased demon-family token, or "UNKNOWN" (a pet exists but its
-- family couldn't be determined, e.g. an unrecognized creature family) --
-- "UNKNOWN" satisfies PET=YES like any other summoned pet, but correctly
-- fails every specific-type comparison.
local function petConditionMatches(values, condition)
    local currentType = values.PET
    if currentType == nil then
        local asksExistence = false
        for _, accepted in ipairs(condition.values) do
            if accepted == "YES" or accepted == "NO" then
                asksExistence = true
                break
            end
        end
        if not asksExistence then
            return false
        end
    end
    local matched = false
    for _, accepted in ipairs(condition.values) do
        if accepted == "YES" then
            if currentType ~= nil then
                matched = true
                break
            end
        elseif accepted == "NO" then
            if currentType == nil then
                matched = true
                break
            end
        elseif currentType == accepted then
            matched = true
            break
        end
    end
    if condition.negated then
        return not matched
    end
    return matched
end

-- DUEL matches the captured duel opponent's class. DUEL=ANY is the
-- class-agnostic form: it matches whenever a duel is live (values.DUEL_NAME
-- is set from the challenge until the duel ends), including before the
-- opponent's class has been captured -- the opponent demonstrably exists
-- even when its class is still unknown. Outside a duel nothing matches,
-- negated or not.
--
-- "Unknown never matches, negated or not" still governs the class itself:
-- while the class is unresolved only a non-negated ANY can match, so
-- NOT DUEL=MAGE stays false until a class is known (as before this field
-- accepted ANY), and NOT DUEL=ANY is never true (a live duel always
-- satisfies ANY; no duel is "absent", which never matches).
--
-- ANY and a specific class tie on specificity when written as two flat
-- #IF forms. Nest them to have the class branch win -- #IF DUEL=ANY
-- containing #IF DUEL=MAGE flattens to a 2-condition form (§5.5.1, §7) --
-- or give the class form an #IF[n] priority.
local function duelConditionMatches(values, condition)
    local currentClass = values.DUEL
    if currentClass == nil then
        if condition.negated or values.DUEL_NAME == nil then
            return false
        end
        for _, accepted in ipairs(condition.values) do
            if accepted == "ANY" then
                return true
            end
        end
        return false
    end
    currentClass = string.upper(tostring(currentClass))
    local matched = false
    for _, accepted in ipairs(condition.values) do
        if accepted == "ANY" or accepted == currentClass then
            matched = true
            break
        end
    end
    if condition.negated then
        return not matched
    end
    return matched
end

-- DUEL_SUCCUBUS=YES/NO tests whether the duel opponent's succubus name is
-- currently known (values.DUEL_SUCCUBUS -- learned from a Seduction cast on
-- the player, or restored from the stored per-warlock database at the
-- challenge; see State:ActivateDuel / State:HandleCombatLog). It exists to
-- gate a branch that uses the SUCCUBUS placeholder, so that branch is only
-- selected once the placeholder can actually resolve.
--
-- Outside a duel the address is absent (values.DUEL_NAME is nil): never
-- matches, negated or not -- the same convention as DUEL itself. During a
-- live duel the answer is always definite, so NOT DUEL_SUCCUBUS=YES is
-- exactly DUEL_SUCCUBUS=NO.
local function duelSuccubusConditionMatches(values, condition)
    if values.DUEL_NAME == nil then
        return false
    end
    local status = values.DUEL_SUCCUBUS ~= nil and "YES" or "NO"
    local matched = false
    for _, accepted in ipairs(condition.values) do
        if accepted == status then
            matched = true
            break
        end
    end
    if condition.negated then
        return not matched
    end
    return matched
end

-- conditionMatches, groupMatches, and anyGroupMatches are mutually
-- recursive: a #DECLARE reference (VAR:<NAME>) evaluates its own stored
-- groups via anyGroupMatches, which walks groups via groupMatches, which
-- evaluates each condition via conditionMatches -- so all three are
-- forward-declared here and assigned below.
local conditionMatches
local groupMatches

-- True when any OR-disjunct in `groups` fully matches the given state.
-- Used both for a #DECLARE reference's own boolean value (§5.9) and, via
-- formSpecificity further down, for #IF form selection.
-- Resolves a placeholder address to the unit token it means right now
-- (raidN, partyN or arenaN), or nil. Assigned with the body placeholders
-- below, which resolve exactly the same way.
local resolvePlaceholderUnit

-- A unit token's auras: the name set and, for the player and group units,
-- the per-aura info ({ [NAME] = { count, expires } }) State keeps in
-- values._UNITAURA. Arena slots only have their AURA:ARENAn set.
local function unitAuras(values, unit)
    if not unit then
        return nil
    end
    local slot = unit:match("^arena(%d)$")
    if slot then
        return values["AURA:ARENA" .. slot], nil
    end
    local data = values._UNITAURA and values._UNITAURA[unit]
    if data then
        return data.set, data.info
    end
    return nil
end

-- The aura set an AURA:<PLACEHOLDER> condition tests: a Preview-As override
-- of the field when there is one, otherwise the resolved unit's auras.
local function placeholderAuraSet(values, condition)
    if values[condition.field] ~= nil then
        return values[condition.field]
    end
    return (unitAuras(values, resolvePlaceholderUnit(values, condition.placeholder)))
end

-- AURA:<ADDRESS>:"<AURA>".TIME / .STACKS (§5.7.1). A missing aura, an
-- unresolved placeholder and a TIME on an aura without a duration are all
-- unknown: never a match, negated or not. A present aura with no stacks
-- counts as 1. Preview-As values (values._AURAPREVIEW, keyed
-- "<FIELD>:<AURA>") replace the live measure.

local function measureConditionMatches(values, condition)
    local preview = values._AURAPREVIEW and values._AURAPREVIEW[condition.field .. ":" .. condition.aura]
    local measured = preview and preview[condition.measure]
    if measured == nil then
        local unit = condition.placeholder and resolvePlaceholderUnit(values, condition.placeholder) or "player"
        local _, info = unitAuras(values, unit)
        local entry = info and info[condition.aura]
        if not entry then
            return false
        end
        if condition.measure == "TIME" then
            if not entry.expires then
                return false
            end
            measured = entry.expires - (values._NOW or 0)
        else
            measured = entry.count
        end
    end
    local amount, op = condition.amount, condition.op
    local matched = (op == "<" and measured < amount) or (op == "<=" and measured <= amount)
        or (op == ">" and measured > amount) or (op == ">=" and measured >= amount)
    if condition.negated then
        return not matched
    end
    return matched
end

local function anyGroupMatches(values, groups)
    for _, group in ipairs(groups) do
        if groupMatches(values, group) then
            return true
        end
    end
    return false
end

conditionMatches = function(values, condition)
    if condition.measure then
        return measureConditionMatches(values, condition)
    end
    -- COMP:NOT:<CLASS> checks come first: both fields share the "AURA:COMP:"
    -- / "COMBAT:COMP:" prefix with the plain COMP:<CLASS> fields below, so
    -- the more specific check must run first or it would never be reached.
    if condition.field:sub(1, 14) == "AURA:COMP:NOT:" then
        return auraNotConditionMatches(values, condition)
    end
    if condition.field:sub(1, 10) == "AURA:COMP:" then
        return auraCompConditionMatches(values, condition)
    end
    if condition.field:sub(1, 16) == "COMBAT:COMP:NOT:" then
        return combatNotConditionMatches(values, condition)
    end
    if condition.field:sub(1, 12) == "COMBAT:COMP:" then
        return combatCompConditionMatches(values, condition)
    end
    if condition.field:sub(1, 4) == "VAR:" then
        -- A #DECLARE reference (§5.9) is always a definite boolean: its own
        -- conditions already resolve any unknown state to false internally,
        -- so negating it (NOT VAR_NAME) is always meaningful, unlike
        -- negating a possibly-unknown field directly.
        local matched = anyGroupMatches(values, condition.declaredGroups)
        if condition.negated then
            return not matched
        end
        return matched
    end
    if condition.field == "PET" then
        return petConditionMatches(values, condition)
    end
    if condition.field == "DUEL" then
        return duelConditionMatches(values, condition)
    end
    if condition.field == "DUEL_SUCCUBUS" then
        return duelSuccubusConditionMatches(values, condition)
    end
    local value
    if condition.placeholder then
        value = placeholderAuraSet(values, condition)
    else
        value = values[condition.field]
    end
    if value == nil then
        return false
    end
    if condition.field:sub(1, 7) == "COMBAT:" and value == "UNKNOWN" then
        -- Exists, but current status can't be assessed and no ASSUME
        -- overlay resolved it: unknown never matches, negated or not,
        -- exactly like a nonexistent unit (§5.8).
        return false
    end
    local matched = false
    if type(value) == "table" then
        for _, accepted in ipairs(condition.values) do
            if value[accepted] then
                matched = true
                break
            end
        end
    else
        value = string.upper(tostring(value))
        for _, accepted in ipairs(condition.values) do
            if value == accepted then
                matched = true
                break
            end
        end
    end
    if condition.negated then
        return not matched
    end
    return matched
end

groupMatches = function(values, group)
    for _, condition in ipairs(group) do
        if not conditionMatches(values, condition) then
            return false
        end
    end
    return true
end

-- A form's match specificity is the condition count of its best matching
-- OR-disjunct. A [list] counts as one condition. Two disjuncts of the same
-- form matching at equal specificity is fine (same body); equal-specificity
-- matches across different forms are a compile error.
local function formSpecificity(values, form)
    local best
    for _, group in ipairs(form.groups) do
        if groupMatches(values, group) then
            if not best or #group > best then
                best = #group
            end
        end
    end
    return best
end

-- Body placeholders resolve arena/duel units inside macro text:
--   @ROGUE  -> @arenaN,  ROGUE  -> arenaN     (lowest slot holding the class)
--   @ROGUEPET -> @arenapetN,  ROGUEPET -> arenapetN
--   @NOTROGUE -> @arenaN,  NOTROGUE -> arenaN (lowest slot NOT holding the
--                                               class -- "the other guy")
--   @NOTROGUEPET -> @arenapetN,  NOTROGUEPET -> arenapetN
--   @DUELOPPONENT -> @<captured name>,  DUELOPPONENT -> <captured name>
--   SUCCUBUS -> <the duel opponent's succubus name>   (bare ALL-CAPS only)
-- SUCCUBUS has no @-prefixed form: a pet resolved by name is only usable by
-- commands that take a plain name (/target SUCCUBUS -> /target Kyrie), not
-- as a bracket-conditional unit, so "@SUCCUBUS" is left untouched. Its name
-- is learned/restored per duel (State:HandleCombatLog / ActivateDuel); gate
-- a branch on DUEL_SUCCUBUS=YES so it is only selected once a name is known.
-- The @-prefixed form keeps its @ (in WoW macro syntax @unit is the
-- target=unit shorthand, so "[@ROGUE,harm]" must become "[@arena1,harm]",
-- never "[arena1,harm]") and is case-insensitive -- the @ already signals
-- intent. The bare form exists for commands that take a plain unit or name
-- (/target ROGUE -> /target arena1) and opts in by being written ALL-CAPS,
-- the compiler's condition-token style; mixed/lowercase words (chat text
-- like "/y Rogue on me!") are left untouched.
-- NOT<CLASS> resolves to the lowest-numbered slot whose class is *known*
-- and differs from <CLASS> -- the placeholder counterpart to the
-- AURA:COMP:NOT:<CLASS> / COMBAT:COMP:NOT:<CLASS> condition addresses. A
-- slot whose class is still unresolved never qualifies (it might well BE
-- <CLASS>), matching that same address's resolution rule.
-- Resolution reads the raw arena state (values._RAW points at the unoverlaid
-- state when an ASSUME overlay is in effect: assumptions influence condition
-- matching only, never placeholder substitution). An unresolvable
-- placeholder becomes "arena0"/"arenapet0" (@-prefixed as appropriate),
-- which WoW's own bracket conditionals already treat as never-matching --
-- the line simply does not fire. Any other @word (e.g. @focus, @pet) or
-- non-class word is left untouched.
-- Classifies one word of body text as a placeholder. Returns the kind of
-- state it reads ("ARENA" or "DUEL") plus its parsed parts, or nil when the
-- word is not a placeholder and must be left untouched. Shared by
-- substitution and by Compiler.Lint (placeholder watch warnings) so both
-- always agree on what counts as a placeholder.
--
-- Kinds: "CLASS" (the class family, resolved against arena opponents in
-- an arena and against the raid/party roster elsewhere -- §6.1), "ROLE"
-- (MAINTANK / MAINASSIST, the raid's assigned main tanks and assists),
-- "PIN" (a free pin such as ANY, and its ANYPET) and "DUEL"
-- (DUELOPPONENT, SUCCUBUS).
local roleNames = {
    MAINTANK = true,
    MAINASSIST = true,
}

classifyPlaceholder = function(at, word)
    local upper = string.upper(word)
    if at == "" and upper ~= word then
        return nil -- bare placeholders must be ALL-CAPS
    end
    if upper == "SUCCUBUS" then
        if at ~= "" then
            return nil -- bare form only; see the placeholder notes above
        end
        return "DUEL", "SUCCUBUS"
    end
    if upper == "DUELOPPONENT" then
        return "DUEL", "DUELOPPONENT"
    end
    if roleNames[upper] then
        return "ROLE", upper
    end
    if freePins[upper] then
        return "PIN", upper, false, false
    end
    local pinBase = upper:match("^(.+)PET$")
    if pinBase and freePins[pinBase] then
        return "PIN", pinBase, false, true
    end
    local negate = false
    local rest = upper
    local notRest = upper:match("^NOT(.+)$")
    if notRest then
        negate, rest = true, notRest
    end
    local class, pet = rest, false
    if not classNames[class] then
        local base = rest:match("^(.+)PET$")
        if base and classNames[base] then
            class, pet = base, true
        end
    end
    if not classNames[class] then
        return nil
    end
    return "CLASS", class, negate, pet
end
Compiler.ClassifyPlaceholder = classifyPlaceholder

-- A placeholder is a whole word: the frontier patterns stop "ROGUE" from
-- matching inside identifiers such as "WMC_vs_ROGUE" or "ROGUE2" (letters,
-- digits and underscores all count as word characters), so /click lines
-- to other WMC buttons and item/spell names are never rewritten. An
-- optional "#N" right after the word picks the Nth match (ROGUE#2 is the
-- second rogue); "#" is not a word character, so it never glues onto a
-- longer identifier.
local PLACEHOLDER_PATTERN = "(@?)%f[%w_]([%a]+)%f[^%w_](#?)(%d*)"
Compiler.PLACEHOLDER_PATTERN = PLACEHOLDER_PATTERN

-- An arena match is in progress: class placeholders address the enemy
-- team. True inside an arena, and whenever any opponent slot is known
-- (the slot state is reset on entering the world, so it never leaks out).
local function inArenaContext(source)
    if source.INSTANCE == "ARENA" then
        return true
    end
    for index = 1, 5 do
        if source["ARENA" .. index] then
            return true
        end
    end
    return false
end

-- The Nth group member (raid order, or party1-4) passing `accept`.
local function nthGroupMember(source, ordinal, accept)
    local group = source._GROUP
    if not group or not group.members then
        return nil
    end
    local count = 0
    for _, member in ipairs(group.members) do
        if accept(member) then
            count = count + 1
            if count == ordinal then
                return member
            end
        end
    end
    return nil
end

-- With asUnit, a group member resolves to its unit token (raidN / partyN)
-- instead of its name: AURA:<PLACEHOLDER> reads the unit's auras.
local function resolveClassPlaceholder(source, class, negate, pet, ordinal, asUnit)
    if inArenaContext(source) then
        local count = 0
        for index = 1, 5 do
            local slotClass = source["ARENA" .. index]
            if slotClass and ((negate and slotClass ~= class) or (not negate and slotClass == class)) then
                count = count + 1
                if count == ordinal then
                    return (pet and "arenapet" or "arena") .. index
                end
            end
        end
        return nil
    end
    if negate then
        -- "Any raid member but a rogue" is not a useful unit; NOT<CLASS>
        -- stays an arena-only placeholder.
        return nil
    end
    -- Offline members never resolve. A pin (§6.1) makes its player #1 when
    -- they are in the group, of that class and online; the rest follow in
    -- roster order from #2. Otherwise the pin is ignored (but kept).
    local pinned
    local pinName = source._PINS and source._PINS[class]
    if pinName then
        local group = source._GROUP
        for _, candidate in ipairs(group and group.members or {}) do
            if candidate.name == pinName and candidate.class == class
                and not candidate.isPlayer and candidate.online ~= false then
                pinned = candidate
                break
            end
        end
    end
    if pinned then
        if ordinal == 1 then
            if asUnit then
                return pinned.unit
            end
            return pet and pinned.pet or pinned.name
        end
        ordinal = ordinal - 1
    end
    local member = nthGroupMember(source, ordinal, function(candidate)
        return candidate.class == class and not candidate.isPlayer
            and candidate.online ~= false and candidate ~= pinned
    end)
    if not member then
        return nil
    end
    if asUnit then
        return member.unit
    end
    if pet then
        return member.pet
    end
    return member.name
end

-- A free pin is only ever its pinned member: in the group, online, not
-- the player. There is no roster fallback (no class to fall back on), and
-- it works in arenas too (it names a teammate, never an opponent).
local function resolveFreePin(source, pin, pet, asUnit)
    local pinName = source._PINS and source._PINS[pin]
    if not pinName then
        return nil
    end
    local group = source._GROUP
    for _, candidate in ipairs(group and group.members or {}) do
        if candidate.name == pinName and not candidate.isPlayer and candidate.online ~= false then
            if asUnit then
                return candidate.unit
            end
            if pet then
                return candidate.pet
            end
            return candidate.name
        end
    end
    return nil
end

resolvePlaceholderUnit = function(values, placeholder)
    local source = values._RAW or values
    local what, ordinal = placeholder.what, placeholder.ordinal
    if placeholder.kind == "ROLE" then
        local member = nthGroupMember(source, ordinal, function(candidate)
            return candidate[what] and candidate.online ~= false
        end)
        return member and member.unit
    elseif placeholder.kind == "PIN" then
        return resolveFreePin(source, what, false, true)
    end
    return resolveClassPlaceholder(source, what, false, false, ordinal, true)
end

local function substitutePlaceholders(output, values)
    if not output:find("@", 1, true) and not output:find("%u") then
        return output
    end
    local source = values._RAW or values
    return (output:gsub(PLACEHOLDER_PATTERN, function(at, word, hash, digits)
        local kind, what, negate, pet = classifyPlaceholder(at, word)
        if not kind then
            return nil -- not a placeholder: keep the original text
        end
        local ordinal, trailing = 1, hash
        if digits ~= "" then
            ordinal = tonumber(digits)
            trailing = ""
            if ordinal < 1 or kind == "DUEL" or kind == "PIN" then
                return nil -- ROGUE#0, DUELOPPONENT#2, ANY#2: not a placeholder
            end
        end
        local resolved, pet0
        if what == "SUCCUBUS" then
            resolved = source.DUEL_SUCCUBUS
        elseif what == "DUELOPPONENT" then
            resolved = source.DUEL_NAME
        elseif kind == "ROLE" then
            local member = nthGroupMember(source, ordinal, function(candidate)
                return candidate[what] and candidate.online ~= false
            end)
            resolved = member and member.name
        elseif kind == "PIN" then
            resolved = resolveFreePin(source, what, pet)
            pet0 = pet
        else
            resolved = resolveClassPlaceholder(source, what, negate, pet, ordinal)
            pet0 = pet
        end
        return at .. (resolved or (pet0 and "arenapet0" or "arena0")) .. trailing
    end))
end

-- Form selection (§7), shared by Compile and Explain so the editor's
-- explanation can never disagree with what actually compiles. Most specific
-- matching form wins; within the top specificity tier an explicit #IF[n]
-- priority breaks the tie; an equal-priority tie in the top tier is an error.
-- The decision is made only after EVERY form has been seen: a tie between two
-- less specific forms is irrelevant when a later, more specific form (or a
-- higher-priority one in the same tier) matches.
-- Returns selected form (or nil), the form tied with it (or nil), a
-- per-form list of specificities (nil = did not match) and a per-form list
-- of the live mode each form yielded to (nil = did not yield).
-- Within one specificity/priority tier, a form from a #MODE outranks a
-- base-template form (§5.13): a mode is a state the author opted into for
-- that game state, so its own body must not tie with every one-condition
-- base #IF. Two mode forms (or two base forms) still tie.
local function selectForm(parsed, values)
    local selected, selectedSpecificity, selectedPriority, selectedRank, tied
    local specificities, yieldedTo = {}, {}
    -- A live mode suppresses every form of a lower-tier mode: a live duel
    -- mode every other mode's, a live ordinary mode the flag modes' (§5.13,
    -- §5.15). The first live mode of each tier, in source order, is named.
    local liveByTier = {}
    for _, mode in ipairs(parsed.modes or {}) do
        if not mode.off and not liveByTier[mode.tier] and anyGroupMatches(values, mode.groups) then
            liveByTier[mode.tier] = mode.name
        end
    end
    for index, form in ipairs(parsed.forms) do
        local leader
        if form.tier then
            for tier = MODE_TIER_DUEL, form.tier + 1, -1 do
                leader = leader or liveByTier[tier]
            end
        end
        yieldedTo[index] = leader
        local specificity
        if not leader then
            specificity = formSpecificity(values, form)
        end
        specificities[index] = specificity
        if specificity then
            local priority = form.priority or 0
            local rank = form.mode and 1 or 0
            local better = not selected or specificity > selectedSpecificity
                or (specificity == selectedSpecificity and priority > selectedPriority)
                or (specificity == selectedSpecificity and priority == selectedPriority and rank > selectedRank)
            if better then
                selected = form
                selectedSpecificity = specificity
                selectedPriority = priority
                selectedRank = rank
                tied = nil
            elseif specificity == selectedSpecificity and priority == selectedPriority and rank == selectedRank then
                tied = tied or form
            end
        end
    end
    return selected, tied, specificities, yieldedTo
end

-- ---------------------------------------------------------------------------
-- Mutes (§5.16): the player switches off macro lines in a mode's branches,
-- per mode name, e.g. "Global Thermal Sapper Charge" in DUEL. Applied to a
-- parse once (when a template is built, and again when the mutes change) by
-- rewriting each affected form's stored output, so Compile never sees them
-- and costs exactly what it did before.

local function normalizeText(text)
    return trim((string.lower(text):gsub("%s+", " ")))
end

-- A command line's command ("/cast") and its argument: the text after the
-- command with [conditionals] removed, identical in every ;-clause, or false
-- when the clauses differ ("/cast [mod] A; B"), "" when there is none
-- ("/startattack"). nil for a line that is not a slash command.
local function commandParts(text)
    local command, rest = normalizeText(text):match("^(/[^%s%[]+)%s*(.*)$")
    if not command then
        return nil
    end
    rest = rest:gsub("%b[]", "")
    local argument
    for clause in (rest .. ";"):gmatch("([^;]*);") do
        clause = trim(clause)
        if clause ~= "" then
            if argument and argument ~= clause then
                return command, false
            end
            argument = clause
        end
    end
    return command, argument or ""
end

-- One mute entry as typed -> { command = "/cast" or nil, argument = "..." },
-- or nil and an error. Without a command it matches any slash command
-- ("Evasion" mutes /cast and /use lines alike).
function Compiler.MuteKey(text)
    text = trim(text or "")
    if text == "" then
        return nil, "Nothing to mute"
    end
    if text:find(";", 1, true) then
        return nil, "One line per entry (separate entries with ;)"
    end
    local command, argument = commandParts(text)
    if not command then
        command, argument = nil, normalizeText((text:gsub("%b[]", "")))
        if argument == "" then
            return nil, "Nothing to mute"
        end
    end
    return { command = command, argument = argument }
end

local function muteMatches(line, key)
    local command, argument = commandParts(line)
    if not command or argument == false then
        return false
    end
    if key.command and key.command ~= command then
        return false
    end
    return argument == key.argument
end
Compiler.MuteMatches = function(line, text)
    local key = Compiler.MuteKey(text)
    return key and muteMatches(line, key) or false
end

-- The entries that would mute `text`'s slash-command lines, one per
-- distinct key, in source order, as written: the argument without its
-- [conditionals] ("Evasion" for "/cast [combat] Evasion"), or the command
-- itself for a bare one ("/startattack"). Lines whose clauses differ
-- ("/cast [mod] A; B") can't be muted and are left out. The mute dialog
-- (MuteDialog.lua) lists these for a mode's segment.
function Compiler.MuteCandidates(text)
    local entries, seen = {}, {}
    for _, line in ipairs(splitLines(text or "")) do
        local command, argument = commandParts(line)
        if command and argument ~= false then
            local entry, key = command, command .. "|"
            if argument ~= "" then
                key = "|" .. argument
                local rest = (trim(line):match("^/[^%s%[]+%s*(.*)$") or ""):gsub("%b[]", "")
                for clause in (rest .. ";"):gmatch("([^;]*);") do
                    clause = trim(clause)
                    if clause ~= "" then
                        entry = (clause:gsub("%s+", " "))
                        break
                    end
                end
            end
            if not seen[key] then
                seen[key] = true
                table.insert(entries, entry)
            end
        end
    end
    return entries
end

-- mutes: { [MODE] = { "entry", ... } } in the order they were added.
-- Within a branch they apply in that order, and an entry that would leave
-- the branch without a single macro line is skipped there (recorded in
-- form.muteSkipped); the lines it matches stay. A stepped branch (§5.17)
-- applies them per block: the never-empty rule holds per step, while #PRE
-- and #POST may be muted empty. Muted forms get
-- form.mutedLines = { [source line] = true }. Base-template forms and
-- #DEFAULT are never touched. stats (optional) collects per entry:
-- stats[MODE][index] = { lines = muted lines, skipped = branches skipped }.
-- Returns true when any form's output changed.

-- The parts mutes apply to one by one: the whole body of a plain form, or
-- each block of a stepped one. keep = must keep a macro line.
local function muteSegments(form)
    if not form.sequence then
        return { { lines = form.bodyLines, numbers = form.bodyLineNumbers, keep = true } }
    end
    local sequence, segments = form.sequence, {}
    local function add(block, keep, slot, index)
        table.insert(segments, { lines = block.lines, numbers = block.lineNumbers, keep = keep, slot = slot, index = index })
    end
    if sequence.pre then
        add(sequence.pre, false, "pre")
    end
    for index, block in ipairs(sequence.openers) do
        add(block, true, "openers", index)
    end
    for index, block in ipairs(sequence.steps) do
        add(block, true, "steps", index)
    end
    if sequence.post then
        add(sequence.post, false, "post")
    end
    return segments
end

local function outputSignature(form)
    return form.blocks and blocksKey(form.blocks) or form.output
end

function Compiler.ApplyMutes(parsed, mutes, stats)
    if not parsed or not (parsed.muted or (mutes and next(mutes))) then
        return false
    end
    local changed, anyMuted = false, false
    for _, form in ipairs(parsed.forms) do
        local before = outputSignature(form)
        form.baseOutput = form.baseOutput or form.output
        form.output = form.baseOutput
        if form.sequence then
            form.blocks = sequenceTexts(form.sequence)
        end
        form.mutedLines, form.muteSkipped = nil, nil
        local entries = form.mode and mutes and mutes[form.mode]
        if entries and #entries > 0 and form.bodyLines then
            local segments = muteSegments(form)
            for _, segment in ipairs(segments) do
                segment.muted, segment.alive = {}, 0
                for _, line in ipairs(segment.lines) do
                    if isMacroLine(line) then
                        segment.alive = segment.alive + 1
                    end
                end
            end
            for index, entry in ipairs(entries) do
                local key = Compiler.MuteKey(entry)
                local matched, mutedCount, skipped = false, 0, false
                for _, segment in ipairs(segments) do
                    local hits = {}
                    for lineIndex, line in ipairs(segment.lines) do
                        if key and not segment.muted[lineIndex] and isMacroLine(line) and muteMatches(line, key) then
                            table.insert(hits, lineIndex)
                        end
                    end
                    if #hits > 0 then
                        matched = true
                        if not segment.keep or segment.alive - #hits >= 1 then
                            for _, lineIndex in ipairs(hits) do
                                segment.muted[lineIndex] = true
                            end
                            segment.alive = segment.alive - #hits
                            mutedCount = mutedCount + #hits
                        else
                            skipped = true
                        end
                    end
                end
                if matched then
                    local stat
                    if stats then
                        stats[form.mode] = stats[form.mode] or {}
                        stat = stats[form.mode][index] or { lines = 0, skipped = 0 }
                        stats[form.mode][index] = stat
                    end
                    if stat then
                        stat.lines = stat.lines + mutedCount
                    end
                    if skipped then
                        form.muteSkipped = form.muteSkipped or {}
                        table.insert(form.muteSkipped, entry)
                        if stat then
                            stat.skipped = stat.skipped + 1
                        end
                    end
                end
            end
            local mutedLines
            for _, segment in ipairs(segments) do
                if next(segment.muted) then
                    mutedLines = mutedLines or {}
                    local kept = {}
                    for lineIndex, line in ipairs(segment.lines) do
                        if segment.muted[lineIndex] then
                            mutedLines[segment.numbers[lineIndex]] = true
                        else
                            table.insert(kept, line)
                        end
                    end
                    if not segment.slot then
                        form.output = trimBody(kept)
                    elseif segment.index then
                        form.blocks[segment.slot][segment.index] = trimBody(kept)
                    else
                        form.blocks[segment.slot] = trimBody(kept)
                    end
                end
            end
            if mutedLines then
                form.mutedLines = mutedLines
                anyMuted = true
            end
        end
        if outputSignature(form) ~= before then
            changed = true
        end
    end
    parsed.muted = anyMuted or nil
    return changed
end

-- A form's (or #DEFAULT's) compiled output: its text with placeholders
-- substituted, or for a stepped body (§5.17) a table
-- { pre, post, openers = {...}, steps = {...}, resets, key }, each block
-- substituted on its own. `key` compares two stepped outputs
-- (Compiler.SameOutput).
local function compileBody(parsed, holder, values)
    local blocks = holder.blocks
    if not blocks then
        return substitutePlaceholders(holder.output, values)
    end
    local output = {
        pre = substitutePlaceholders(blocks.pre, values),
        post = substitutePlaceholders(blocks.post, values),
        openers = {},
        steps = {},
        resets = parsed.resets,
    }
    for _, text in ipairs(blocks.openers) do
        table.insert(output.openers, substitutePlaceholders(text, values))
    end
    for _, text in ipairs(blocks.steps) do
        table.insert(output.steps, substitutePlaceholders(text, values))
    end
    output.key = blocksKey(output, parsed.resets)
    return output
end

function Compiler.Compile(parsed, values, defaultOnly)
    values = values or {}
    if defaultOnly then
        return compileBody(parsed, parsed.default, values), "DEFAULT"
    end
    local selected, tied = selectForm(parsed, values)
    if tied then
        return nil, nil, "Equal-specificity conditions match: " .. selected.expression
            .. "  vs  " .. tied.expression
    end
    if selected then
        return compileBody(parsed, selected, values), selected.expression
    end
    return compileBody(parsed, parsed.default, values), "DEFAULT"
end


-- Whether two compiled outputs write the same secure attributes: equal
-- text, or stepped outputs with the same blocks and resets.
function Compiler.SameOutput(a, b)
    if type(a) == "table" and type(b) == "table" then
        return a.key == b.key
    end
    return a == b
end

-- The texts one press of a stepped output runs, in cycle order: each
-- opener, then each step, joined as #PRE + step + #POST. Also returns the
-- index the cycle wraps to (the first plain step).
function Compiler.PressTexts(output)
    local texts = {}
    local function join(step)
        local parts = {}
        for _, part in ipairs({ output.pre, step, output.post }) do
            if part ~= "" then
                table.insert(parts, part)
            end
        end
        table.insert(texts, table.concat(parts, "\n"))
    end
    for _, step in ipairs(output.openers) do
        join(step)
    end
    for _, step in ipairs(output.steps) do
        join(step)
    end
    return texts, #output.openers + 1
end

-- Explains a selection for the editor preview: every flattened form in
-- source order with whether it matched, its specificity and priority, and
-- which one won (or which two tied). Uses exactly the logic Compile uses.
function Compiler.Explain(parsed, values)
    values = values or {}
    local selected, tied, specificities, yieldedTo = selectForm(parsed, values)
    local rows = {}
    for index, form in ipairs(parsed.forms) do
        table.insert(rows, {
            expression = form.expression,
            mode = form.mode,
            line = form.line,
            priority = form.priority or 0,
            specificity = specificities[index],
            selected = form == selected and not tied,
            tied = tied ~= nil and (form == selected or form == tied),
            yieldedTo = yieldedTo[index],
            steps = form.blocks and (#form.blocks.openers + #form.blocks.steps) or nil,
            openers = form.blocks and #form.blocks.openers or nil,
        })
    end
    local default = parsed.default and parsed.default.blocks
    return {
        forms = rows, usedDefault = selected == nil, tie = tied ~= nil,
        defaultSteps = default and (#default.openers + #default.steps) or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Warnings (Compiler.Lint). Never errors: a template that compiled before
-- still compiles; warnings only point at things that will silently never
-- match or never update. Collected into parsed.warnings by Compiler.Parse.
-- ---------------------------------------------------------------------------

-- Spec tokens per class, mirroring State.lua's classSpecs.
local specTokens = {}
for _, specs in pairs({
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
}) do
    for _, spec in ipairs(specs) do
        specTokens[spec] = true
    end
end

local instanceTokens = { NONE = true, PARTY = true, RAID = true, PVP = true, ARENA = true }

-- Which closed vocabulary (if any) a field's values come from.
local function fieldVocabulary(field)
    if field == "CLASS" or field == "PLAYER_CLASS" or field == "COMP"
        or field:match("^ARENA%d$") or field:match("^PARTY%d$") then
        return classNames, "class"
    end
    if field == "DUEL" then
        return classNames, "class", { ANY = true }
    end
    if field == "SPEC" or field == "PLAYER_SPEC" then
        return specTokens, "specialization"
    end
    if field == "INSTANCE" then
        return instanceTokens, "instance type"
    end
    return nil
end

-- The #WATCH a field needs to ever recompile on its own, plus a second
-- watch for COMP-addressed fields, whose answer also changes when an arena
-- opponent's class is revealed (§5.7), and for placeholder addresses, whose
-- unit changes with the roster and the pins.
local function fieldWatches(field)
    if field:sub(1, 4) == "VAR:" or field == "PLAYER_CLASS" then
        return nil
    end
    local auraAddress = field:match("^AURA:([^:]+)$")
    if auraAddress and not auraUnitAddresses[auraAddress] and parsePlaceholderAddress(auraAddress) then
        return "AURA", "GROUP"
    end
    local prefix = field:match("^(%u+):")
    if prefix then
        local main = prefix
        if field:match("^%u+:COMP:") then
            return main, "ARENA"
        end
        return main
    end
    if field == "INSTANCE_NAME" then
        return "INSTANCE"
    end
    if field == "DUEL_SUCCUBUS" then
        return "DUEL"
    end
    if field == "COMP" or field:match("^ARENA%d$") then
        return "ARENA"
    end
    if field:match("^PARTY%d$") then
        return "PARTY"
    end
    return field
end

local function displayField(field)
    return (field:gsub(":COMP:NOT:", ":COMP:NOT"))
end

-- Where a class placeholder in a branch resolves, judged from the branch's
-- conditions (§6.1): "ARENA" when every way it can match is inside an arena
-- (INSTANCE=ARENA, or any arena slot / COMP field), "GROUP" when none is
-- (any other INSTANCE, NOT INSTANCE=ARENA), nil when the branch doesn't
-- say (#DEFAULT, a branch without INSTANCE) or contradicts itself.
local function conjunctContext(group)
    local context
    local function note(found)
        if found and context and found ~= context then
            context = false
        elseif found and context == nil then
            context = found
        end
    end
    for _, condition in ipairs(group) do
        local field = condition.field
        if condition.declaredGroups then
            if not condition.negated and #condition.declaredGroups == 1 then
                note(conjunctContext(condition.declaredGroups[1]))
            end
        elseif field == "INSTANCE" then
            local arena, other = false, false
            for _, value in ipairs(condition.values or {}) do
                if value == "ARENA" then
                    arena = true
                else
                    other = true
                end
            end
            if condition.negated then
                note(arena and "GROUP" or nil)
            elseif arena ~= other then
                note(arena and "ARENA" or "GROUP")
            end
        else
            local mainWatch, extraWatch = fieldWatches(field)
            if mainWatch == "ARENA" or extraWatch == "ARENA" then
                note("ARENA") -- an unknown slot never matches, negated or not
            end
        end
    end
    return context or nil
end

local function branchContext(groups)
    local context
    for index, group in ipairs(groups or {}) do
        local found = conjunctContext(group)
        if not found or (index > 1 and found ~= context) then
            return nil
        end
        context = found
    end
    return context
end

-- The #WATCH a placeholder needs, or nil when it can't be told (a class
-- placeholder in a branch whose context is unknown: the lint warning asks).
local function placeholderWatch(at, word, context)
    local kind, _, negate = classifyPlaceholder(at, word)
    if kind == "DUEL" then
        return "DUEL"
    elseif kind == "ROLE" or kind == "PIN" then
        return "GROUP"
    elseif kind == "CLASS" then
        return negate and "ARENA" or context -- NOT<CLASS> is arena-only
    end
end

function Compiler.Lint(parsed)
    local warnings = {}
    local seenMessages = {}
    local function warn(line, message)
        local text = (line and ("Line " .. line .. ": ") or "") .. message
        if not seenMessages[text] then
            seenMessages[text] = true
            table.insert(warnings, { line = line, message = text })
        end
    end
    local missingWatch = {} -- watch -> true once reported

    local function checkCondition(condition)
        local field = condition.field
        local vocabulary, label, extra = fieldVocabulary(field)
        if vocabulary then
            for _, value in ipairs(condition.values or {}) do
                if not vocabulary[value] and not (extra and extra[value]) then
                    warn(condition.line, "unknown " .. label .. " \"" .. value .. "\" in "
                        .. displayField(field) .. " (it will never match).")
                end
            end
        end
        local mainWatch, extraWatch = fieldWatches(field)
        for _, watch in ipairs({ mainWatch or false, extraWatch or false }) do
            if watch and not parsed.watchSet[watch] and not missingWatch[watch] then
                missingWatch[watch] = true
                if watch == "GROUP" then
                    warn(condition.line, "uses " .. displayField(field) .. " but has no #WATCH GROUP"
                        .. "; it won't update when the roster or the pins change.")
                elseif watch == extraWatch then
                    warn(condition.line, "uses " .. displayField(field) .. " but has no #WATCH " .. watch
                        .. "; it won't update when an opponent's class is revealed.")
                else
                    warn(condition.line, "uses " .. displayField(field) .. " but has no #WATCH " .. watch
                        .. "; it will only update on login or save.")
                end
            end
        end
    end

    local seenConditions = {}
    local function scanGroups(groups)
        for _, group in ipairs(groups) do
            for _, condition in ipairs(group) do
                if not seenConditions[condition] then
                    seenConditions[condition] = true
                    checkCondition(condition)
                end
            end
        end
    end
    for _, name in ipairs(parsed.declareOrder or {}) do
        scanGroups(parsed.declares[name].groups)
    end
    for _, form in ipairs(parsed.forms) do
        scanGroups(form.groups)
    end

    -- Placeholders read arena / group / duel state; without the matching
    -- watch the substituted unit never changes after login or save. A class
    -- placeholder needs the watch for where its branch runs (placeholderWatch:
    -- ARENA in an arena-only branch, GROUP in one that can't be in an arena);
    -- where the branch doesn't say, either one satisfies it.
    local function scanBody(text, line, context)
        for at, word, hash, digits in text:gmatch(PLACEHOLDER_PATTERN) do
            local kind = classifyPlaceholder(at, word)
            local shown = at .. word .. (digits ~= "" and (hash .. digits) or "")
            if kind == "CLASS" then
                local watch = placeholderWatch(at, word, context)
                if watch then
                    if not parsed.watchSet[watch] and not missingWatch["CLASS:" .. watch] then
                        missingWatch["CLASS:" .. watch] = true
                        warn(line, "placeholder " .. shown .. " needs #WATCH " .. watch
                            .. (watch == "ARENA" and " (arena opponents" or " (raid/party members")
                            .. (watch == context and ", where this branch runs)" or ")")
                            .. " to follow who it points at.")
                    end
                elseif not parsed.watchSet.ARENA and not parsed.watchSet.GROUP and not missingWatch.CLASS then
                    missingWatch.CLASS = true
                    warn(line, "placeholder " .. shown .. " needs #WATCH ARENA (arena opponents) or"
                        .. " #WATCH GROUP (raid/party members) to follow who it points at.")
                end
            elseif kind == "ROLE" or kind == "PIN" then
                if not parsed.watchSet.GROUP and not missingWatch.GROUP then
                    missingWatch.GROUP = true
                    warn(line, "placeholder " .. shown .. " needs #WATCH GROUP to follow "
                        .. (kind == "PIN" and "who it is pinned to." or "raid assignments."))
                end
            elseif kind == "DUEL" then
                if not parsed.watchSet.DUEL and not missingWatch.DUEL then
                    missingWatch.DUEL = true
                    warn(line, "placeholder " .. shown .. " needs #WATCH DUEL to follow the current duel.")
                end
            end
        end
    end
    if parsed.default then
        scanBody(parsed.default.output or "", nil, nil)
    end
    for _, form in ipairs(parsed.forms) do
        scanBody(form.output or "", form.line, branchContext(form.groups))
    end

    -- Sequences (§5.17).
    if parsed.sequenceLine and not parsed.stepped then
        warn(parsed.sequenceLine, "#SEQUENCE has no steps to reset (no body has #STEP).")
    end
    for _, holder in ipairs({ parsed.default or {}, unpack(parsed.forms) }) do
        local sequence = holder.sequence
        for _, block in ipairs({ sequence and sequence.pre or false, sequence and sequence.post or false }) do
            if block and trimBody(block.lines) == "" then
                warn(block.line, (block.kind == "PRE" and "#PRE" or "#POST") .. " has no lines.")
            end
        end
    end
    return warnings
end

-- The #WATCHes a parsed template needs: its conditions' (#IF, #MODE and
-- #DECLARE) and its body placeholders' (placeholderWatch), as
-- watch -> { [line] = true } for every line that needs it, whether or not
-- the template already declares it. The editor uses it to add a missing
-- #WATCH once the line needing it is finished.
function Compiler.NeededWatches(parsed)
    local needs = {}
    local function scanGroups(groups)
        for _, group in ipairs(groups or {}) do
            for _, condition in ipairs(group) do
                local mainWatch, extraWatch = fieldWatches(condition.field)
                for _, watch in ipairs({ mainWatch or false, extraWatch or false }) do
                    if watch and watchNames[watch] == watch then
                        needs[watch] = needs[watch] or {}
                        needs[watch][condition.line or 0] = true
                    end
                end
            end
        end
    end
    for _, name in ipairs(parsed.declareOrder or {}) do
        scanGroups(parsed.declares[name].groups)
    end
    for _, form in ipairs(parsed.forms or {}) do
        scanGroups(form.groups)
    end
    local function scanBody(lines, numbers, context)
        for index, line in ipairs(lines or {}) do
            for at, word in line:gmatch(PLACEHOLDER_PATTERN) do
                local watch = placeholderWatch(at, word, context)
                if watch then
                    needs[watch] = needs[watch] or {}
                    needs[watch][numbers and numbers[index] or 0] = true
                end
            end
        end
    end
    if parsed.default then
        scanBody(parsed.default.lines, parsed.default.lineNumbers, nil)
    end
    for _, form in ipairs(parsed.forms or {}) do
        scanBody(form.bodyLines, form.bodyLineNumbers, branchContext(form.groups))
    end
    return needs
end

-- The answers of a parsed template's aura .TIME comparisons against
-- `values`, as one string ("1" / "0" per condition, in source order). The
-- .TIME timer (§5.7.1) recompiles when it changes: a remaining time
-- crossing a threshold has no event of its own.
function Compiler.TimeSignature(parsed, values)
    local parts = {}
    local seen = {}
    local function scanGroups(groups)
        for _, group in ipairs(groups or {}) do
            for _, condition in ipairs(group) do
                if condition.measure == "TIME" and not seen[condition] then
                    seen[condition] = true
                    table.insert(parts, conditionMatches(values, condition) and "1" or "0")
                end
            end
        end
    end
    if parsed then
        for _, name in ipairs(parsed.declareOrder or {}) do
            scanGroups(parsed.declares[name].groups)
        end
        for _, form in ipairs(parsed.forms or {}) do
            scanGroups(form.groups)
        end
    end
    return table.concat(parts)
end

-- True when a parsed template has an AURA:<PLACEHOLDER> condition (plain or
-- a measure): raid units' auras must then be scanned (§5.7).
function Compiler.UsesPlaceholderAuras(parsed)
    local function scanGroups(groups)
        for _, group in ipairs(groups or {}) do
            for _, condition in ipairs(group) do
                if condition.placeholder then
                    return true
                end
            end
        end
        return false
    end
    for _, name in ipairs(parsed and parsed.declareOrder or {}) do
        if scanGroups(parsed.declares[name].groups) then
            return true
        end
    end
    for _, form in ipairs(parsed and parsed.forms or {}) do
        if scanGroups(form.groups) then
            return true
        end
    end
    return false
end

-- The set of flag names ({ NAME = true }) a parsed template tests anywhere
-- with FLAG=<NAME>: base forms, #DECLAREs and mode conditions (including a
-- flag-only mode with no body). The editor's State section uses it to keep
-- a flag that is currently off one click away (§13.4).
function Compiler.CollectFlagNames(parsed)
    local names = {}
    local function scanGroups(groups)
        for _, group in ipairs(groups or {}) do
            for _, condition in ipairs(group) do
                if condition.field == "FLAG" then
                    for _, value in ipairs(condition.values or {}) do
                        local name = Compiler.ValidFlagName(value)
                        if name then
                            names[name] = true
                        end
                    end
                end
            end
        end
    end
    if not parsed then
        return names
    end
    for _, declared in pairs(parsed.declares or {}) do
        scanGroups(declared.groups)
    end
    for _, form in ipairs(parsed.forms or {}) do
        scanGroups(form.groups)
    end
    for _, mode in ipairs(parsed.modes or {}) do
        scanGroups(mode.groups)
    end
    return names
end

-- ---------------------------------------------------------------------------
-- Preview-As (§13.5): the editor can show what a template compiles to in a
-- state the player is not in. The state is written in condition syntax
-- (`INSTANCE=ARENA ARENA1=MAGE FLAG=WPVP`), parsed by the same scanner as an
-- #IF, and applied as an OVERLAY on a copy of the values -- the live state is
-- never written, and nothing here touches the secure buttons.
-- ---------------------------------------------------------------------------

-- Fields whose state value is a set: a single value adds to the live set, a
-- [list] replaces it.
local function isSetField(field)
    return field == "FLAG" or field == "PLAYER_CD" or field:sub(1, 5) == "AURA:"
end

-- Parses the Preview-As line. Terms are separated by spaces or AND; each is
-- FIELD=VALUE (a [list] only for set fields), or an aura measure set to an
-- amount (AURA:SELF:"FEL ARMOR".TIME=4m, .STACKS=3 -- §5.7.1). No OR, no
-- NOT, no #DECLARE names, no combat-log windows, no one-field-twice. Returns
--   overrides, order   -- { [FIELD] = { "VALUE", ... } } and the fields in
--                         the order written; both empty for an empty line.
--                         A measure's key is its text (AURA:SELF:"X".TIME)
--                         and its entry also carries field, placeholder,
--                         aura, measure and amount.
--   nil, message       -- on a syntax error
function Compiler.ParseOverrides(text)
    text = trim(text or "")
    if text == "" then
        return {}, {}
    end
    -- Split into terms with the condition scanner, then re-join with AND so
    -- the real condition parser validates every field and value. Measures
    -- are not conditions (they set an amount, not test one): they are read
    -- here and slotted back into the written order at the end.
    local scanner = newScanner(text)
    local terms = {}
    local measures, sequence = {}, {}
    while not scanner:atEnd() do
        scanner:skipSpace()
        local start = scanner.pos
        local field = scanner:readFieldIdentifier()
        if not field then
            return nil, "Invalid term near: " .. text:sub(start, start + 20)
        end
        local upper = string.upper(field)
        local measure, measureError = readAuraMeasure(scanner, upper)
        if measure == false then
            return nil, measureError
        end
        if measure then
            scanner:skipSpace()
            if scanner:peek() ~= "=" then
                return nil, "Expected = after ." .. measure.measure .. " (Preview-As sets an amount: .TIME=4m)"
            end
            scanner.pos = scanner.pos + 1
            local amount, amountText = readMeasureAmount(scanner, measure.measure)
            if not amount then
                return nil, amountText
            end
            local key = measure.field .. ":\"" .. measure.aura .. "\"." .. measure.measure
            if measures[key] then
                return nil, key .. " is given twice"
            end
            measures[key] = {
                amountText, field = measure.field, placeholder = measure.placeholder,
                aura = measure.aura,
                measure = measure.measure, amount = amount,
            }
            table.insert(sequence, key)
        elseif upper == "AND" then
            -- optional separator
        elseif upper == "OR" or upper == "NOT" then
            return nil, upper .. " is not supported here (one state per line)"
        else
            scanner:skipSpace()
            if scanner:peek() ~= "=" then
                return nil, "Expected = after " .. upper
            end
            scanner.pos = scanner.pos + 1
            local _, valueError = scanner:readValues(false)
            if valueError then
                return nil, valueError .. " for " .. upper
            end
            table.insert(terms, text:sub(start, scanner.pos - 1))
            table.insert(sequence, #terms)
        end
    end
    local overrides, order = {}, {}
    local termFields = {}
    local groups = { {} }
    if #terms > 0 then
        local parseError
        groups, parseError = parseConditions(table.concat(terms, " AND "), nil)
        if not groups then
            return nil, parseError
        end
    end
    for _, condition in ipairs(groups[1]) do
        local field = condition.field
        if field == "COMP" or field:find(":COMP:", 1, true) then
            return nil, "Set ARENA1-ARENA5 instead of " .. field .. " (the comp follows the arena slots)"
        elseif overrides[field] then
            return nil, field .. " is given twice"
        end
        local values = condition.values
        if #values > 1 and not isSetField(field) then
            return nil, field .. " takes one value"
        end
        if field == "CLASS" or field == "PLAYER_CLASS" or field:match("^ARENA%d$") or field:match("^PARTY%d$") then
            if not classNames[values[1]] then
                return nil, "Unknown class \"" .. values[1] .. "\" for " .. field
            end
        elseif field == "DUEL" and values[1] ~= "ANY" and not classNames[values[1]] then
            return nil, "Unknown class \"" .. values[1] .. "\" for DUEL (a class or ANY)"
        end
        overrides[field] = values
        table.insert(termFields, field)
    end
    for _, item in ipairs(sequence) do
        if type(item) == "number" then
            table.insert(order, termFields[item])
        else
            overrides[item] = measures[item]
            table.insert(order, item)
        end
    end
    return overrides, order
end

-- The overrides back as Preview-As text, in the order given.
function Compiler.FormatOverrides(overrides, order)
    local parts = {}
    for _, field in ipairs(order or {}) do
        local values = overrides[field]
        if values then
            if #values == 1 then
                table.insert(parts, field .. "=" .. values[1])
            else
                table.insert(parts, field .. "=[" .. table.concat(values, ",") .. "]")
            end
        end
    end
    return table.concat(parts, " ")
end

local PREVIEW_DUEL_NAME = "Preview"

-- A copy of `values` with the overrides applied, and the derived state that
-- has to follow them (otherwise the preview would lie):
--   ARENAn=<CLASS>   rebuilds COMP from all five slots (live slots that are
--                    not overridden stay), and puts the copy in arena
--                    context, so class placeholders resolve to arenaN;
--   DUEL=<CLASS|ANY> also sets DUEL_NAME (the live one, else "Preview"), so
--                    DUEL=ANY and DUELOPPONENT behave as in a live duel;
--   DUEL_SUCCUBUS    YES/NO sets or clears the succubus name (in a duel);
--   FLAG=X           adds to the live set, FLAG=[X,Y] sets the whole set (as
--                    for every set field; for AURA:<PLACEHOLDER> the live
--                    set is the resolved unit's);
--   AURA:...:"X".TIME=4m / .STACKS=3
--                    puts that amount in values._AURAPREVIEW and the aura
--                    in the address's set (a measure implies the aura).
-- The raid roster is deliberately not simulated.
-- The second result tells #WATCH ... ASSUME how to behave in the preview:
-- { sighted = { [slot] = true }, opponentCount = n, duelActive = bool }.
function Compiler.BuildPreviewValues(values, overrides)
    local copy = {}
    for key, value in pairs(values) do
        copy[key] = value
    end
    copy._RAW = nil
    local info = {}
    local arenaTouched
    -- The live set of an AURA field: its own value, or for a placeholder
    -- address the resolved unit's.
    local function liveSet(field)
        if type(values[field]) == "table" then
            return values[field]
        end
        local _, _, placeholder = resolveField(field)
        if placeholder then
            return (unitAuras(values, resolvePlaceholderUnit(values, placeholder)))
        end
    end
    local measures = {}
    for field, accepted in pairs(overrides or {}) do
        if accepted.measure then
            table.insert(measures, accepted)
        elseif isSetField(field) then
            local set = {}
            if #accepted == 1 then
                for key, present in pairs(liveSet(field) or {}) do
                    set[key] = present
                end
            end
            for _, value in ipairs(accepted) do
                set[value] = true
            end
            copy[field] = set
        elseif field == "DUEL" then
            copy.DUEL_NAME = copy.DUEL_NAME or PREVIEW_DUEL_NAME
            copy.DUEL = accepted[1] ~= "ANY" and accepted[1] or nil
            info.duelActive = true
        elseif field == "DUEL_SUCCUBUS" then
            copy.DUEL_NAME = copy.DUEL_NAME or PREVIEW_DUEL_NAME
            copy.DUEL_SUCCUBUS = accepted[1] == "YES" and (values.DUEL_SUCCUBUS or "Preview Succubus") or nil
            info.duelActive = true
        else
            copy[field] = accepted[1]
            local slot = field:match("^ARENA(%d)$")
            if slot then
                slot = tonumber(slot)
                arenaTouched = true
                info.sighted = info.sighted or {}
                info.sighted[slot] = true
                info.opponentCount = math.max(info.opponentCount or 0, slot)
            end
        end
    end
    -- After the set overrides, so a measure's aura joins an overridden set.
    if #measures > 0 then
        local previews = {}
        for key, entry in pairs(values._AURAPREVIEW or {}) do
            previews[key] = entry
        end
        copy._AURAPREVIEW = previews
        for _, accepted in ipairs(measures) do
            do
                local key = accepted.field .. ":" .. accepted.aura
                local entry = {}
                for measure, amount in pairs(previews[key] or {}) do
                    entry[measure] = amount
                end
                entry[accepted.measure] = accepted.amount
                previews[key] = entry
                local set = {}
                local base = copy[accepted.field]
                if base == nil then
                    base = liveSet(accepted.field)
                end
                for name, present in pairs(base or {}) do
                    set[name] = present
                end
                set[accepted.aura] = true
                copy[accepted.field] = set
            end
        end
    end
    if arenaTouched then
        local comp
        for index = 1, 5 do
            local class = copy["ARENA" .. index]
            if class then
                comp = comp or {}
                comp[class] = true
            end
        end
        copy.COMP = comp
    end
    return copy, info
end

-- The Preview-As text that reproduces a mode's condition, for "Preview this
-- mode". Only a plain AND of FIELD=VALUE terms can be reproduced: with OR,
-- NOT, a #DECLARE name or a combat-log window it returns nil and the reason.
-- Prefill choices: a [list] on a scalar field uses its first value; DUEL=ANY
-- stays DUEL=ANY (a live duel whose class is not known yet, which is exactly
-- what the mode tests); COMP=<CLASS> takes the next free arena slot.
function Compiler.OverridesFromGroups(groups)
    if not groups or #groups == 0 then
        return nil, "the mode has no condition"
    end
    if #groups > 1 then
        return nil, "its condition uses OR"
    end
    local overrides, order = {}, {}
    local usedSlots = {}
    for _, condition in ipairs(groups[1]) do
        if condition.negated then
            return nil, "its condition uses NOT"
        end
        local field = condition.field
        if condition.measure then
            return nil, "its condition tests an aura's ." .. condition.measure
        elseif field:sub(1, 4) == "VAR:" then
            return nil, "its condition uses a #DECLARE name"
        elseif field:find(":COMP:", 1, true) then
            return nil, "its condition uses " .. field
        end
        local slot = field:match("^ARENA(%d)$")
        if slot then
            usedSlots[tonumber(slot)] = true
        end
    end
    for _, condition in ipairs(groups[1]) do
        local field = condition.field
        local values = condition.values
        if field == "COMP" then
            local slot = 1
            while usedSlots[slot] do
                slot = slot + 1
            end
            if slot > 5 then
                return nil, "its comp does not fit in five arena slots"
            end
            usedSlots[slot] = true
            field, values = "ARENA" .. slot, { values[1] }
        elseif not isSetField(field) and #values > 1 then
            values = { values[1] }
        end
        if overrides[field] then
            return nil, field .. " appears twice in its condition"
        end
        overrides[field] = values
        table.insert(order, field)
    end
    return Compiler.FormatOverrides(overrides, order)
end

-- ---------------------------------------------------------------------------
-- Mode segments for the editor's tabs (§13.2). The source is split at every
-- #MODE header line into a base segment (everything before the first mode:
-- metadata, #DEFAULT, top-level #IFs) and one segment per mode (its header
-- line through the line before the next header). Joining the segments with
-- "\n" gives back the exact source, so a tab edits its slice of the one
-- source text and nothing is ever stored twice. A parked mode's segment
-- (`#MODE NAME OFF`) is marked `off`: the All tab leaves it out.
-- ---------------------------------------------------------------------------
function Compiler.SplitModes(source)
    local lines = splitLines(source or "")
    local segments = { { kind = "BASE", startLine = 1, lines = {} } }
    for lineNumber, line in ipairs(lines) do
        local directive = trim(line)
        if isModeHeader(directive) then
            local name, condition = directive:match("^#MODE%[?%d*%]?%s+([%a_][%w_]*)%s*(.-)%s*$")
            table.insert(segments, {
                kind = "MODE",
                name = name and string.upper(name) or "?",
                off = condition ~= nil and string.upper(condition) == "OFF",
                startLine = lineNumber,
                lines = {},
            })
        end
        table.insert(segments[#segments].lines, line)
    end
    for _, segment in ipairs(segments) do
        segment.text = table.concat(segment.lines, "\n")
        segment.lineCount = #segment.lines
        segment.lines = nil
    end
    return segments
end

-- Inverse of SplitModes. A base segment that never had any lines (the
-- source started with a #MODE) and is still empty is skipped, so the
-- round trip adds no leading blank line.
function Compiler.JoinModes(segments)
    local parts = {}
    for index, segment in ipairs(segments) do
        if not (index == 1 and segment.kind == "BASE" and segment.lineCount == 0 and segment.text == "") then
            table.insert(parts, segment.text)
        end
    end
    return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- Editor tokenizer (syntax highlighting, §13.3). Splits ONE source line into
-- spans { from, to, kind } (byte offsets, inclusive). Later spans override
-- earlier ones where they overlap (a placeholder inside a [conditional]).
-- It is purely lexical and per line -- no parse, no state -- so it can run
-- on every keystroke; it uses the same field / placeholder / directive
-- rules as the parser so the colors never disagree with what compiles.
-- It is only ever called by the editor: compilation never touches it.
--
-- Kinds: comment, directive, bad (unknown/unsupported), number, name,
-- field, badfield, keyword, string, value, operator, command, conditional,
-- placeholder, macro (a body line starting with '#', e.g. #showtooltip),
-- ---------------------------------------------------------------------------
local directiveSet = {
    WATCH = true, COMPILE = true, DECLARE = true, DEFAULT = true,
    IF = true, ENDIF = true, MODE = true, ELSE = true,
    PRE = true, POST = true, STEP = true, SEQUENCE = true,
}
local keywordSet = { AND = true, OR = true, NOT = true }

local function tokenizeExpression(line, pos, add)
    local length = #line
    local expectValue = false
    local function valueSuffix(at)
        return at
    end
    while pos <= length do
        local char = line:sub(pos, pos)
        if char:match("%s") then
            pos = pos + 1
        elseif char == '"' or char == "'" then
            local closing = line:find(char, pos + 1, true)
            add(pos, closing or length, closing and "string" or "bad")
            pos = valueSuffix((closing or length) + 1)
            expectValue = false
        elseif char == "[" then
            local closing = line:find("]", pos + 1, true)
            local stop = closing or length
            add(pos, pos, "operator")
            local inner = pos + 1
            while inner < stop do
                local c = line:sub(inner, inner)
                if c == '"' or c == "'" then
                    local q = line:find(c, inner + 1, true)
                    if not q or q > stop then
                        add(inner, stop, "bad")
                        inner = stop
                    else
                        add(inner, q, "string")
                        inner = q + 1
                    end
                elseif c == "," then
                    add(inner, inner, "operator")
                    inner = inner + 1
                elseif c:match("%s") then
                    inner = inner + 1
                else
                    local s, e = line:find("^[^,%]%s]+", inner)
                    add(s, e, "value")
                    inner = e + 1
                end
            end
            if closing then
                add(closing, closing, "operator")
            end
            pos = closing and valueSuffix(stop + 1) or stop + 1
            expectValue = false
        elseif char == "=" then
            add(pos, pos, "operator")
            pos = pos + 1
            expectValue = true
        elseif char == "." then
            -- An aura measure (§5.7.1): .TIME / .STACKS.
            local s, e = line:find("^%a+", pos + 1)
            add(pos, pos, "operator")
            if s then
                add(s, e, auraMeasures[string.upper(line:sub(s, e))] and "field" or "badfield")
                pos = e + 1
            else
                pos = pos + 1
            end
        elseif char == "<" or char == ">" then
            local _, opEnd = line:find("^[<>]=?", pos)
            add(pos, opEnd, "operator")
            local s, e = line:find("^%s*%d+%a*", opEnd + 1)
            if s then
                s = line:find("%d", s)
                add(s, e, "number")
                pos = e + 1
            else
                pos = opEnd + 1
            end
        elseif expectValue then
            local s, e = line:find("^[^%s%[%],=:]+", pos)
            if not s then
                pos = pos + 1
            else
                add(s, e, "value")
                pos = valueSuffix(e + 1)
                expectValue = false
            end
        else
            local s, e = line:find("^[%w_:#]+", pos)
            if not s then
                add(pos, pos, "bad")
                pos = pos + 1
            else
                local word = line:sub(s, e)
                local upper = string.upper(word)
                local nextChar = line:match("^%s*(.)", e + 1)
                local measureAddress
                local measureKind = upper:match("^(AURA):")
                if measureKind then
                    if upper:sub(-1) == ":" and (nextChar == '"' or nextChar == "'") then
                        measureAddress = upper:sub(1, -2)
                    elseif nextChar == "." then
                        measureAddress = upper:match("^(" .. measureKind .. ":.+):[^:]+$")
                    end
                end
                if keywordSet[upper] then
                    add(s, e, "keyword")
                elseif measureAddress then
                    add(s, e, resolveField(measureAddress) and "field" or "badfield")
                elseif nextChar == "=" then
                    add(s, e, resolveField(upper) and "field" or "badfield")
                else
                    add(s, e, "name") -- a #DECLARE reference
                end
                pos = e + 1
            end
        end
    end
end

local function tokenizeBody(line, add)
    local s, e = line:find("^%s*/[^%s%[]+")
    if s then
        add(line:find("/", s, true), e, "command")
    end
    local pos = 1
    while true do
        local b1, b2 = line:find("%b[]", pos)
        if not b1 then
            break
        end
        add(b1, b2, "conditional")
        pos = b2 + 1
    end
    for start, at, word, hash, digits, stop in line:gmatch("()(@?)%f[%w_]([%a]+)%f[^%w_](#?)(%d*)()") do
        local kind = classifyPlaceholder(at, word)
        if kind and not ((kind == "DUEL" or kind == "PIN") and digits ~= "") then
            local last = stop - 1
            if digits == "" and hash ~= "" then
                last = last - 1 -- a bare '#' is not part of the placeholder
            end
            add(start, last, "placeholder")
        end
    end
end

function Compiler.TokenizeLine(line)
    local spans = {}
    local function add(from, to, kind, extra)
        if from and to and to >= from then
            table.insert(spans, { from, to, kind, extra })
        end
    end
    local first = line:find("%S")
    if not first then
        return spans
    end
    if line:sub(first, first + 2) == "#--" then
        add(first, #line, "comment")
        return spans
    end
    if line:sub(first, first) ~= "#" then
        tokenizeBody(line, add)
        return spans
    end
    local word = line:match("^#(%u+)", first)
    local after = word and line:sub(first + #word + 1, first + #word + 1)
    if not word or not directiveSet[word] or not (after == "" or after:match("[%s%[]")) then
        -- #showtooltip and friends: macro text that passes through.
        add(first, #line, "macro")
        return spans
    end
    local pos = first + #word + 1
    add(first, pos - 1, word == "ELSE" and "bad" or "directive")
    if word == "IF" or word == "MODE" then
        local b1, b2 = line:find("^%[[^%]]*%]", pos)
        if b1 then
            add(b1, b2, line:sub(b1, b2):match("^%[%d+%]$") and "number" or "bad")
            pos = b2 + 1
        end
    end
    if word == "MODE" or word == "DECLARE" then
        local n1, n2 = line:find("^%s*[%a_][%w_]*", pos)
        if n1 then
            add(line:find("%S", n1), n2, "name")
            pos = n2 + 1
        end
        if word == "DECLARE" then
            local eq = line:find("^%s*=", pos)
            if eq then
                local at = line:find("=", eq, true)
                add(at, at, "operator")
                pos = at + 1
            end
        end
        tokenizeExpression(line, pos, add)
    elseif word == "IF" then
        tokenizeExpression(line, pos, add)
    elseif word == "WATCH" then
        local n1, n2 = line:find("^%s*%S+", pos)
        if n1 then
            local ns = line:find("%S", n1)
            add(ns, n2, watchNames[string.upper(line:sub(ns, n2))] and "field" or "badfield")
            pos = n2 + 1
            local k1, k2 = line:find("^%s*%a+", pos)
            if k1 then
                local ks = line:find("%S", k1)
                add(ks, k2, string.upper(line:sub(ks, k2)) == "ASSUME" and "keyword" or "bad")
                pos = k2 + 1
                local e1 = line:find("^=", pos)
                if e1 then
                    add(e1, e1, "operator")
                    local v1, v2 = line:find("^%S+", e1 + 1)
                    add(v1, v2, "value")
                end
            end
        end
    elseif word == "COMPILE" then
        local v1, v2 = line:find("^%s*%S+", pos)
        if v1 then
            local vs = line:find("%S", v1)
            local policy = string.upper(line:sub(vs, v2))
            add(vs, v2, (policy == "QUEUE" or policy == "IGNORE") and "value" or "bad")
        end
    elseif word == "STEP" or word == "PRE" or word == "POST" then
        -- #STEP ONCE; anything else after a block header is an error.
        local r1, r2 = line:find("^%s*%S.-%s*$", pos)
        if r1 then
            local rs = line:find("%S", r1)
            local rest = line:sub(rs, r2)
            add(rs, r2, (word == "STEP" and rest == "ONCE") and "keyword" or "bad")
        end
    elseif word == "SEQUENCE" then
        local k1, k2 = line:find("^%s*%a+", pos)
        if k1 then
            local ks = line:find("%S", k1)
            add(ks, k2, string.upper(line:sub(ks, k2)) == "RESET" and "keyword" or "bad")
            pos = k2 + 1
            local e1 = line:find("^%s*=", pos)
            if e1 then
                local at = line:find("=", e1, true)
                add(at, at, "operator")
                pos = at + 1
                while pos <= #line do
                    local b1, b2 = line:find("^%s*%b[]", pos)
                    if b1 then
                        add(line:find("%[", b1), b2, "conditional")
                        pos = b2 + 1
                    else
                        local n1, n2 = line:find("^%s*[^,%[%s]+", pos)
                        if not n1 then
                            break
                        end
                        local ns = line:find("%S", n1)
                        add(ns, n2, resetNames[string.upper(line:sub(ns, n2))] and "value" or "bad")
                        pos = n2 + 1
                    end
                    local c1, c2 = line:find("^%s*,", pos)
                    if c1 then
                        pos = c2 + 1
                    end
                end
            end
        end
    end
    return spans
end
