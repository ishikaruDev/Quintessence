local addon = WMacroCompiler
local Secure = {}
addon.Secure = Secure

local MAX_TEXT = addon.MAX_MACROTEXT

-- template.primaryName: the first button's own name (a bank long macro's
-- QMB<id>, Bank/Macros.lua) instead of WMC_<name>.
local function frameName(template, index)
    if index == 1 then
        return template.primaryName or ("WMC_" .. template.name)
    end
    return "WMC_INTERNAL_" .. template.name .. "_" .. tostring(index)
end

-- Sequences (§12.2): the header holding the step texts, the button that
-- resets it, and the chain buttons of a long step.
local function headerName(template)
    return "WMC_INTERNAL_" .. template.name .. "_SEQ"
end

local function resetName(template)
    return "WMC_" .. template.name .. "_RESET"
end

local function stepFrameName(template, step, index)
    return "WMC_INTERNAL_" .. template.name .. "_S" .. step .. "_" .. tostring(index)
end

local function splitLines(text)
    local lines = {}
    for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end
    return lines
end

-- SDM-style link: propagates the mouse button used, so right-click etc. survive chaining.
local function linkText(nextName)
    return "/click [btn:5]" .. nextName .. " Button5;[btn:4]" .. nextName .. " Button4;[btn:3]"
        .. nextName .. " MiddleButton;[btn:2]" .. nextName .. " RightButton;" .. nextName
end

-- nameOf(index): the name of the chunk's button (for the link's length).
local function buildChunks(nameOf, text)
    if #text <= MAX_TEXT then
        return { text }
    end
    local reserve = #(linkText(nameOf(9999))) + 1
    local payloadLimit = MAX_TEXT - reserve
    local chunks = {}
    local current = ""
    for _, line in ipairs(splitLines(text)) do
        local candidate = current == "" and line or current .. "\n" .. line
        if #candidate > payloadLimit then
            if current == "" then
                return nil, "A macro line is too long to chain safely."
            end
            table.insert(chunks, current)
            current = line
            if #current > payloadLimit then
                return nil, "A macro line is too long to chain safely."
            end
        else
            current = candidate
        end
    end
    if current ~= "" or #chunks == 0 then
        table.insert(chunks, current)
    end
    return chunks
end

local function plainNames(template)
    return function(index)
        return frameName(template, index)
    end
end

local function stepNames(template, step)
    return function(index)
        if index == 1 then
            return frameName(template, 1)
        end
        return stepFrameName(template, step, index)
    end
end

-- Lays out a stepped output: per press text (cycle order), its chunks.
-- Returns { texts, loop, chunks = { [step] = {...} } } or nil and an error.
local function layoutSteps(template, output)
    local texts, loop = addon.Compiler.PressTexts(output)
    local chunks = {}
    for step, text in ipairs(texts) do
        local stepChunks, splitError = buildChunks(stepNames(template, step), text)
        if not stepChunks then
            return nil, "Step " .. step .. ": " .. splitError, true
        end
        chunks[step] = stepChunks
    end
    return { texts = texts, loop = loop, chunks = chunks }
end

-- How a compiled output would be laid out on secure buttons, without
-- touching any frame: returns the number of buttons, or nil and the error
-- Apply would report. Used by the editor's output-size line. For a stepped
-- output it also returns { steps = steps in the cycle, largest = the
-- longest joined step's length, chained = steps that need chain buttons };
-- its count includes the reset button.
function Secure.Measure(name, output)
    local template = { name = name }
    if type(output) == "table" then
        local layout, layoutError = layoutSteps(template, output)
        if not layout then
            return nil, layoutError
        end
        local buttons, largest, chained = 2, 0, 0
        for step, text in ipairs(layout.texts) do
            buttons = buttons + #layout.chunks[step] - 1
            largest = math.max(largest, #text)
            if #layout.chunks[step] > 1 then
                chained = chained + 1
            end
        end
        return buttons, nil, { steps = #layout.texts, largest = largest, chained = chained }
    end
    local chunks, splitError = buildChunks(plainNames(template), output or "")
    if not chunks then
        return nil, splitError
    end
    return #chunks
end

-- The press snippet (§12.2), run by the header before every click of the
-- primary button, in combat too: reset if the RESET= conditions hold, load
-- the current step's text, advance (wrapping to the first plain step).
local PRESS_SNIPPET = [[
    local index = owner:GetAttribute("index") or 1
    local reset = owner:GetAttribute("reset")
    if reset and SecureCmdOptionParse(reset) == "reset" then
        index = 1
    end
    self:SetAttribute("macrotext", owner:GetAttribute("step-" .. index))
    index = index + 1
    if index > owner:GetAttribute("steps") then
        index = owner:GetAttribute("loop")
    end
    owner:SetAttribute("index", index)
]]

local RESET_STATE = [[
    if newstate == "on" then
        self:SetAttribute("index", 1)
    end
]]

local RESET_CLICK = [[
    self:GetFrameRef("header"):SetAttribute("index", 1)
]]

-- Each name is created with one template; a frame is claimed by at most one
-- active WMC template at a time (frame.WMC_Template, cleared on cleanup; a
-- claim by a template that is no longer active doesn't count).
local KIND_TEMPLATES = {
    action = "SecureActionButtonTemplate",
    header = "SecureHandlerStateTemplate",
    reset = "SecureHandlerClickTemplate",
}

local function checkName(template, name, kind)
    local frame = _G[name]
    if not frame then
        return true
    end
    local claim = frame.WMC_Template
    if frame.WMC_Owner ~= addon or (frame.WMC_Kind or "action") ~= kind
        or (claim and claim ~= template.id and addon.runtime.byId[claim]) then
        return nil, "Frame name is already in use: " .. name
    end
    return true
end

local function claimFrame(template, name, kind)
    local frame = _G[name]
    if not frame then
        frame = CreateFrame(kind == "header" and "Frame" or "Button", name, nil, KIND_TEMPLATES[kind])
    end
    if not frame then
        return nil, "Could not create secure frame " .. name
    end
    frame.WMC_Owner = addon
    frame.WMC_Kind = kind
    frame.WMC_Template = template.id
    return frame
end

local function stopSequence(header)
    UnregisterStateDriver(header, "combat")
    UnregisterStateDriver(header, "notarget")
    header:SetAttribute("_onstate-combat", nil)
    header:SetAttribute("_onstate-notarget", nil)
    if header.WMC_Wrapped then
        header:UnwrapScript(header.WMC_Wrapped, "OnClick")
        header.WMC_Wrapped = nil
    end
    for step = 1, header.WMC_Steps or 0 do
        header:SetAttribute("step-" .. step, nil)
    end
    header.WMC_Steps = nil
    for _, key in ipairs({ "steps", "loop", "index", "reset" }) do
        header:SetAttribute(key, nil)
    end
end

local function cleanupName(name)
    local frame = _G[name]
    if frame and frame.WMC_Owner == addon then
        local kind = frame.WMC_Kind or "action"
        if kind == "header" then
            stopSequence(frame)
        elseif kind == "reset" then
            frame:SetAttribute("_onclick", nil)
        else
            frame:SetAttribute("type", nil)
            frame:SetAttribute("macrotext", nil)
        end
        frame.WMC_Template = nil
        frame:Hide()
    end
end

function Secure.Remove(template)
    if not template or not template.frameNames then
        return
    end
    if addon:IsInCombat() then
        template.pendingRemove = true
        return
    end
    for _, name in ipairs(template.frameNames) do
        cleanupName(name)
    end
    template.frameNames = {}
    template.primaryFrame = nil
end

-- Writes one chain: the first chunk goes to `first` (a frame or an
-- attribute setter), the rest onto the named chain buttons. Returns the
-- names it used.
local function writeChain(template, chunks, nameOf, setFirst, names)
    for index = 1, #chunks do
        local body = chunks[index]
        if index < #chunks then
            body = body .. "\n" .. linkText(nameOf(index + 1))
        end
        if index == 1 then
            setFirst(body)
        else
            local name = nameOf(index)
            local frame, frameError = claimFrame(template, name, "action")
            if not frame then
                return nil, frameError
            end
            frame:SetAttribute("type", "macro")
            frame:SetAttribute("macrotext", body)
            frame:Show()
            table.insert(names, name)
        end
    end
    return true
end

-- The resets that run in the secure environment (§12.2); COMBAT (combat
-- end) is normal code, Secure.CombatEnded.
local function applyResets(header, resets)
    if resets.combatStart then
        header:SetAttribute("_onstate-combat", RESET_STATE)
        RegisterStateDriver(header, "combat", "[combat] on; off")
    else
        UnregisterStateDriver(header, "combat")
        header:SetAttribute("_onstate-combat", nil)
    end
    if resets.noTarget then
        header:SetAttribute("_onstate-notarget", RESET_STATE)
        RegisterStateDriver(header, "notarget", "[@target,noexists][@target,dead] on; off")
    else
        UnregisterStateDriver(header, "notarget")
        header:SetAttribute("_onstate-notarget", nil)
    end
    header:SetAttribute("reset", resets.condition and (resets.condition .. " reset") or nil)
end

local function applySteps(template, output, names)
    local layout, layoutError = layoutSteps(template, output)
    if not layout then
        return nil, layoutError, true
    end
    -- Pre-validate every frame name before mutating anything.
    local wanted = { { frameName(template, 1), "action" }, { headerName(template), "header" },
        { resetName(template), "reset" } }
    for step, chunks in ipairs(layout.chunks) do
        for index = 2, #chunks do
            table.insert(wanted, { stepFrameName(template, step, index), "action" })
        end
    end
    for _, entry in ipairs(wanted) do
        local ok, nameError = checkName(template, entry[1], entry[2])
        if not ok then
            return nil, nameError
        end
    end

    local primary, frameError = claimFrame(template, frameName(template, 1), "action")
    if not primary then
        return nil, frameError
    end
    local header
    header, frameError = claimFrame(template, headerName(template), "header")
    if not header then
        return nil, frameError
    end
    primary:SetAttribute("type", "macro")
    primary:RegisterForClicks("AnyDown") -- a bound key fires on the press, once (Keys.lua)
    primary:Show()
    table.insert(names, frameName(template, 1))
    table.insert(names, headerName(template))

    for step, chunks in ipairs(layout.chunks) do
        local ok, chainError = writeChain(template, chunks, stepNames(template, step), function(body)
            header:SetAttribute("step-" .. step, body)
        end, names)
        if not ok then
            return nil, chainError
        end
    end
    for step = #layout.chunks + 1, header.WMC_Steps or 0 do
        header:SetAttribute("step-" .. step, nil)
    end
    header.WMC_Steps = #layout.chunks
    header:SetAttribute("steps", #layout.chunks)
    header:SetAttribute("loop", layout.loop)
    header:SetAttribute("index", 1)
    primary:SetAttribute("macrotext", header:GetAttribute("step-1"))
    if header.WMC_Wrapped ~= primary then
        if header.WMC_Wrapped then
            header:UnwrapScript(header.WMC_Wrapped, "OnClick")
        end
        header:WrapScript(primary, "OnClick", PRESS_SNIPPET)
        header.WMC_Wrapped = primary
    end
    applyResets(header, output.resets or addon.Compiler.DEFAULT_RESETS)
    header:Show()

    local reset
    reset, frameError = claimFrame(template, resetName(template), "reset")
    if not reset then
        return nil, frameError
    end
    reset:SetFrameRef("header", header)
    reset:SetAttribute("_onclick", RESET_CLICK)
    reset:Show()
    table.insert(names, resetName(template))
    template.primaryFrame = primary
    template.sequenceHeader = header
    return true
end

local function applyPlain(template, text, names)
    local chunks, splitError = buildChunks(plainNames(template), text)
    if not chunks then
        return nil, splitError, true
    end

    -- Pre-validate every frame name before mutating anything.
    for index = 1, #chunks do
        local ok, nameError = checkName(template, frameName(template, index), "action")
        if not ok then
            return nil, nameError
        end
    end

    -- Populate the new chain first, then retire stale frames, so a failure
    -- leaves the previous working chain untouched.
    local primary, frameError = claimFrame(template, frameName(template, 1), "action")
    if not primary then
        return nil, frameError
    end
    primary:SetAttribute("type", "macro")
    primary:RegisterForClicks("AnyDown") -- a bound key fires on the press, once (Keys.lua)
    primary:Show()
    table.insert(names, frameName(template, 1))
    local ok, chainError = writeChain(template, chunks, plainNames(template), function(body)
        primary:SetAttribute("macrotext", body)
    end, names)
    if not ok then
        return nil, chainError
    end
    template.primaryFrame = primary
    template.sequenceHeader = nil
    return true
end

-- output: macro text, or a stepped output (a table, §5.17).
function Secure.Apply(template, output)
    if addon:IsInCombat() then
        template.dirty = true
        return nil, "Secure macro update deferred until combat ends."
    end
    local names = {}
    local ok, applyError, splitFailed
    if type(output) == "table" then
        ok, applyError, splitFailed = applySteps(template, output, names)
    else
        ok, applyError, splitFailed = applyPlain(template, output, names)
    end
    if not ok then
        if splitFailed then
            template.error = applyError
            addon:Print(template.name .. ": " .. applyError)
        end
        return nil, applyError
    end

    local keep = {}
    for _, name in ipairs(names) do
        keep[name] = true
    end
    for _, oldName in ipairs(template.frameNames or {}) do
        if not keep[oldName] then
            cleanupName(oldName)
        end
    end

    template.frameNames = names
    template.lastAppliedOutput = output
    template.pendingRemove = false
    return true
end

-- Combat ended (out of combat again): the COMBAT reset of every stepped
-- template that has it (§5.17).
function Secure.CombatEnded(templates)
    if addon:IsInCombat() then
        return
    end
    for _, template in ipairs(templates) do
        local header = template.sequenceHeader
        local output = template.lastAppliedOutput
        if header and type(output) == "table" and (output.resets or addon.Compiler.DEFAULT_RESETS).combat then
            header:SetAttribute("index", 1)
        end
    end
end
