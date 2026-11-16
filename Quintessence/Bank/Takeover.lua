local addon = WMacroCompiler
local Macros = addon.Macros

--[[-----------------------------------------------------------------------------
Takeover (addon.Takeover): the Macro Bank opens wherever Blizzard's macro
window would (/macro, the game menu's Macros button).

Blizzard_MacroUI is load-on-demand. Once it is loaded, MacroFrame gets an
OnShow hook: it makes the frame invisible at once and, on the next frame,
closes it and shows the bank (closing a panel from inside its own OnShow
would run in the middle of ShowUIPanel). No global is replaced, so other
addons' hooks on MacroFrame keep working.

The way back to Blizzard's window: Shift held while it opens, /qmb blizzard
(Takeover:OpenBlizzard), or the takeover switched off (/qmb takeover off;
QuintessenceBankDB.settings.takeover = false).
-------------------------------------------------------------------------------]]
local Takeover = {}
addon.Takeover = Takeover

function Takeover:Enabled()
    return Macros.db ~= nil and Macros.db.settings.takeover ~= false
end

local swapTimer = CreateFrame("Frame")
swapTimer:Hide()
swapTimer:SetScript("OnUpdate", function(frame)
    frame:Hide()
    Takeover:Swap()
end)
Takeover.swapTimer = swapTimer

-- Closes Blizzard's window (shown invisible by the hook) and opens the bank.
function Takeover:Swap()
    local frame = MacroFrame
    if not frame then
        return
    end
    frame:SetAlpha(1)
    if not frame:IsShown() then
        return
    end
    if HideUIPanel then
        HideUIPanel(frame)
    else
        frame:Hide()
    end
    addon.BankUI:Show()
end

local function MacroFrame_OnShow(frame)
    if Takeover.passThrough or not Takeover:Enabled() or (IsShiftKeyDown and IsShiftKeyDown()) then
        return
    end
    frame:SetAlpha(0)
    swapTimer:Show()
end

function Takeover:Hook()
    if self.hooked or not MacroFrame then
        return
    end
    self.hooked = true
    MacroFrame:HookScript("OnShow", MacroFrame_OnShow)
end

-- PLAYER_LOGIN: Blizzard_MacroUI may already be loaded (another addon).
function Takeover:Initialize()
    self:Hook()
end

-- ADDON_LOADED.
function Takeover:AddonLoaded(name)
    if name == "Blizzard_MacroUI" then
        self:Hook()
    end
end

function Takeover:OpenBlizzard()
    if not ShowMacroFrame then
        addon:Print("Blizzard's macro window is not available.")
        return
    end
    self.passThrough = true
    ShowMacroFrame()
    self.passThrough = nil
end

-- /qmb takeover [on | off]
function Takeover:Command(argument)
    if not Macros.db then
        return
    end
    if argument == "on" or argument == "off" then
        Macros.db.settings.takeover = argument == "on"
    elseif argument ~= "" then
        addon:Print("Usage: /qmb takeover on | off.")
        return
    end
    addon:Print(self:Enabled()
        and "/macro opens the Macro Bank (hold Shift, or /qmb blizzard, for Blizzard's window)."
        or "/macro opens Blizzard's macro window (/qmb opens the Macro Bank).")
end
