local addon = WMacroCompiler

--[[-----------------------------------------------------------------------------
API for other addons (§6.2): set the player's flags and pins from code, e.g.
a WeakAura or a raid-reminders addon that turns on #IF FLAG=LK for the Lich
King fight and points the TASK placeholder at the mage the player was
assigned to.

    local WMC = WMacroCompiler and WMacroCompiler.API
    if WMC and WMC.VERSION >= 1 then
        WMC.SetFlag("LK", true)
        WMC.SetPin("TASK", "Frostmage")
    end

Every call does exactly what the matching /qmc command does: the change is
confirmed in chat (marked as coming from another addon, so the player always
knows why a button changed), templates that watch FLAG / GROUP recompile, and
in combat that recompile waits until combat ends (secure buttons cannot be
rewritten in combat; make the call before the pull). Nothing here listens to
the network: receiving a raid leader's message is the calling addon's job.

Functions return nil plus an error message on bad input or before the
player has logged in; they never raise errors.
-------------------------------------------------------------------------------]]
local API = { VERSION = 1 }
addon.API = API

local FROM_API = " (set by another addon)"

local function ready()
    return addon.db and addon.State and addon.State.values
end

local function combatSuffix()
    return addon:IsInCombat() and " (applies when combat ends)" or ""
end

-- on: true, false, or nil to toggle. Returns the flag's new state (true /
-- false) and whether it changed.
function API.SetFlag(name, on)
    if not ready() then
        return nil, "WMC is not loaded yet"
    end
    local flag, nameError = addon.Compiler.ValidFlagName(name)
    if not flag then
        return nil, nameError
    end
    local state, changed = addon.State:SetFlag(flag, on)
    if changed then
        addon:Print("Flag " .. flag .. " " .. (state and "on" or "off") .. "." .. FROM_API .. combatSuffix())
        addon:HandleStateChange({ "FLAG" })
    end
    return state, changed
end

function API.GetFlag(name)
    if not ready() then
        return nil, "WMC is not loaded yet"
    end
    local flag, nameError = addon.Compiler.ValidFlagName(name)
    if not flag then
        return nil, nameError
    end
    return addon.State:FlagStore()[flag] == true
end

-- slot: "TASK", "ANY" or a class ("MAGE"). player: a group member's name
-- ("Name" or "Name-Realm"). Returns the pinned member's full name and
-- whether it changed. The same checks as /qmc pin apply (in your group, not
-- you, of that class for a class slot).
function API.SetPin(slot, player)
    if not ready() then
        return nil, "WMC is not loaded yet"
    end
    if type(player) ~= "string" or player == "" then
        return nil, "No player name given"
    end
    local name, changed = addon.State:SetPin(slot, player)
    if not name then
        return nil, changed
    end
    if changed then
        addon:Print(tostring(slot):upper() .. " pinned to " .. name .. "." .. FROM_API .. combatSuffix())
        addon:HandleStateChange({ "GROUP" })
    end
    return name, changed
end

-- Returns whether there was a pin to clear.
function API.ClearPin(slot)
    if not ready() then
        return nil, "WMC is not loaded yet"
    end
    local had = addon.State:ClearPin(slot)
    if had then
        addon:Print(tostring(slot):upper() .. " unpinned." .. FROM_API .. combatSuffix())
        addon:HandleStateChange({ "GROUP" })
    end
    return had
end

-- The pinned player's name, or nil.
function API.GetPin(slot)
    if not ready() or type(slot) ~= "string" then
        return nil
    end
    return addon.State.pins[slot:upper()]
end
