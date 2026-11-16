local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme

--[[-----------------------------------------------------------------------------
Send (addon.Send): a template or a macro from one Quintessence user to
another, by addon whispers (SendAddonMessage, prefix "QMC"; same faction
only, as any whisper on 3.3.5a). For a template what travels is the export
text (addon:ExportTemplates), so the receiving end imports it as the import
window does: a taken name gets the next free one, the icon comes along. A
macro (the bank window's Send) travels as its name, icon and text, one per
line (the text's own lines after), and lands in the bank: its section's
Unsorted, renamed "<name> 2" (and so on) when the section has that name.

The sender offers first; nothing else is sent until the receiver accepts:

  sender                         receiver
  O id proto scope name size ->  (M: the same, for a macro)
                              <- S id      (has Quintessence; asking)
                                 (B busy with another offer, V other
                                 protocol, D too big; ignored: nothing)
                              <- A id / D id   (Accept / Decline / expired)
  C id n total data ...      ->  (the text in chunks, SEND_INTERVAL apart)
                              <- R id ok|<error>
  X id                       ->  (the offer withdrawn: a newer one)

No S within SEEN_TIMEOUT: the player is offline or has no Quintessence.
The receiver's prompt (Accept / Decline) is its own small popup, not the
shared modal Dialog: it never takes the keyboard or cancels what the
receiver has open. It waits for the end of combat and declines itself
ANSWER_TIMEOUT after the offer arrived. The text is %XX-escaped (control
characters, '%', '|', non-ASCII), so a chunk is plain printable text.

  Send:Offer(scope, name, target) -- from the rail's send button (UI.lua)
  Send:OfferMacro(section, name, icon, text, target) -- the bank's Send
  Send:OnAddonMessage(prefix, message, channel, sender) -- CHAT_MSG_ADDON
  Send:Accept(), Send:Decline() -- the prompt's buttons
  Send:Update(elapsed) -- the driver's OnUpdate: queue and timeouts
  Fields: outgoing, incoming (the current offer each way), queue, clock,
  prompt (the receive popup's frame).
-------------------------------------------------------------------------------]]

local Send = { queue = {}, clock = 0, sent = 0 }
addon.Send = Send

local PREFIX = "QMC"
local PROTOCOL = 1
local CHUNK = 200            -- escaped characters per message (limit 254 with the header)
local SEND_INTERVAL = 0.2    -- seconds between messages: under the server's throttle
local SEEN_TIMEOUT = 5
local ANSWER_TIMEOUT = 75    -- the receiver's prompt (and combat) from the offer on
local WAIT_TIMEOUT = 90      -- the sender's patience for Accept / Decline
local TRANSFER_TIMEOUT = 30  -- no chunk (or result) for this long: given up
local MAX_SIZE = 30000       -- export text, in bytes
Send.PREFIX, Send.SEND_INTERVAL = PREFIX, SEND_INTERVAL
Send.SEEN_TIMEOUT, Send.ANSWER_TIMEOUT, Send.MAX_SIZE = SEEN_TIMEOUT, ANSWER_TIMEOUT, MAX_SIZE

local NAME_COLOR = "|cffffd100"
local KIND_NAMES = { template = "template", macro = "macro" }
local TEMPLATE_COLOR = "|cffffffff"

local function className(scope)
    if scope == "GENERAL" then
        return "General"
    end
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[scope]) or scope
end

local function sameName(a, b)
    return a and b and string.lower(a) == string.lower(b)
end

local function encode(text)
    return (text:gsub("[%%%c|\128-\255]", function(char)
        return string.format("%%%02X", char:byte())
    end))
end

local function decode(text)
    return (text:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end
Send.Encode, Send.Decode = encode, decode

-- Chunks of at most CHUNK characters, never cutting a %XX escape.
local function chunks(text)
    local list, position = {}, 1
    while position <= #text do
        local last = math.min(position + CHUNK - 1, #text)
        local percent = text:sub(last - 1, last):find("%%")
        if percent and last < #text then
            last = last - 2 + percent - 1
        end
        table.insert(list, text:sub(position, last))
        position = last + 1
    end
    return list
end
Send.Chunks = chunks

local function isIgnored(name)
    if IsIgnored then
        return IsIgnored(name) and true or false
    end
    if GetNumIgnores and GetIgnoreName then
        for index = 1, GetNumIgnores() do
            if sameName(GetIgnoreName(index), name) then
                return true
            end
        end
    end
    return false
end

local function whisper(target, ...)
    if SendAddonMessage then
        SendAddonMessage(PREFIX, table.concat({ ... }, "\t"), "WHISPER", target)
    end
end

-- "  name " / "nAME" -> "Name"; nil for anything that can't be a name.
function Send.NormalizeName(text)
    local name = (text or ""):match("^%s*(.-)%s*$")
    if name == "" or name:find("[%s%d%p]") then
        return nil
    end
    return name:sub(1, 1):upper() .. name:sub(2):lower()
end

--[[ Sending ]]

-- A macro as it travels: the name, the icon, then the text.
function Send.PackMacro(name, icon, text)
    return (name or "") .. "\n" .. (icon or "") .. "\n" .. (text or "")
end

function Send.UnpackMacro(packed)
    local name, icon, text = (packed or ""):match("^([^\n]*)\n([^\n]*)\n(.*)$")
    if not name then
        return nil
    end
    return name, icon ~= "" and icon or nil, text
end

function Send:Offer(scope, name, target)
    if not Send.NormalizeName(target) then
        addon:Print("Send: enter a player name.")
        return false
    end
    local text = addon:ExportTemplates({ { scope = scope, name = name } })
    if text == "" then
        addon:Print("Send: save the template first.")
        return false
    end
    return self:OfferText("template", scope, name, text, target)
end

function Send:OfferMacro(section, name, icon, text, target)
    if not Send.NormalizeName(target) then
        addon:Print("Send: enter a player name.")
        return false
    end
    return self:OfferText("macro", section, name, Send.PackMacro(name, icon, text), target)
end

-- kind: "template" (offered with O) or "macro" (M; a client from before
-- macros ignores it, so the sender hears nothing back).
function Send:OfferText(kind, scope, name, text, target)
    target = Send.NormalizeName(target)
    if #text > MAX_SIZE then
        addon:Print("Send: " .. name .. " is too long to send (" .. #text .. " of " .. MAX_SIZE .. " characters).")
        return false
    end
    local old = self.outgoing
    if old then
        whisper(old.target, "X", old.id)
        self:DropQueue(old.id)
    end
    self.sent = self.sent + 1
    local id = tostring(math.random(1000, 9999)) .. self.sent
    self.outgoing = { id = id, kind = kind, target = target, scope = scope, name = name, text = text,
        stage = "offer", deadline = self.clock + SEEN_TIMEOUT }
    if addon.db then
        addon.db.settings.lastRecipient = target
    end
    whisper(target, kind == "macro" and "M" or "O", id, PROTOCOL, scope, name, #text)
    addon:Print("Offering " .. name .. " to " .. target .. "...")
    return true
end

local function finishOutgoing(self, message)
    if message then
        addon:Print(message)
    end
    if self.outgoing then
        self:DropQueue(self.outgoing.id)
    end
    self.outgoing = nil
end

local function fromReceiver(self, kind, id, sender, rest)
    local out = self.outgoing
    if not out or out.id ~= id or not sameName(out.target, sender) then
        return
    end
    local name, target = out.name, out.target
    if kind == "S" then
        out.stage, out.deadline = "waiting", self.clock + WAIT_TIMEOUT
        addon:Print("Waiting for " .. target .. " to accept " .. name .. ".")
    elseif kind == "A" and out.stage ~= "sending" then
        out.stage = "sending"
        local list = chunks(encode(out.text))
        for index, chunk in ipairs(list) do
            table.insert(self.queue, { id = id, target = target,
                message = table.concat({ "C", id, index, #list, chunk }, "\t") })
        end
        out.deadline = self.clock + TRANSFER_TIMEOUT + #list * SEND_INTERVAL
    elseif kind == "D" then
        finishOutgoing(self, target .. " declined " .. name .. ".")
    elseif kind == "B" then
        finishOutgoing(self, target .. " is answering another offer; try again in a moment.")
    elseif kind == "V" then
        finishOutgoing(self, target .. "'s Quintessence can't receive " .. KIND_NAMES[out.kind] .. "s from this version.")
    elseif kind == "R" then
        if rest == "ok" then
            finishOutgoing(self, target .. " received " .. name .. ".")
        else
            finishOutgoing(self, target .. " couldn't import " .. name .. ": " .. tostring(rest))
        end
    end
end

function Send:DropQueue(id)
    for index = #self.queue, 1, -1 do
        if self.queue[index].id == id then
            table.remove(self.queue, index)
        end
    end
end

--[[ Receiving ]]

local function finishIncoming(self, message)
    if message then
        addon:Print(message)
    end
    self.incoming = nil
    if self.prompt then
        self.prompt:Hide()
    end
end

local function inCombat()
    return InCombatLockdown and InCombatLockdown()
end

local function fromSender(self, kind, id, sender, fields)
    local incoming = self.incoming
    if kind == "O" or kind == "M" then
        if isIgnored(sender) then
            return
        end
        local protocol, scope, name, size = tonumber(fields[1]), fields[2], fields[3], tonumber(fields[4])
        if protocol ~= PROTOCOL then
            whisper(sender, "V", id)
            return
        end
        if not scope or not name or not size or size > MAX_SIZE then
            whisper(sender, "D", id)
            return
        end
        if incoming and not sameName(incoming.sender, sender) then
            whisper(sender, "B", id)
            return
        end
        self.incoming = { id = id, kind = kind == "M" and "macro" or "template", sender = sender, scope = scope,
            name = name, size = size, stage = "ask", deadline = self.clock + ANSWER_TIMEOUT }
        whisper(sender, "S", id)
        if not inCombat() then
            self:ShowPrompt()
        end
        return
    end
    if not incoming or incoming.id ~= id or not sameName(incoming.sender, sender) then
        return
    end
    if kind == "X" then
        finishIncoming(self, sender .. " withdrew the offer of " .. incoming.name .. ".")
    elseif kind == "C" and incoming.stage == "receiving" then
        local index, total, data = tonumber(fields[1]), tonumber(fields[2]), fields[3] or ""
        if not index or not total or total < 1 or index > total then
            return
        end
        incoming.total = total
        if not incoming.parts[index] then
            incoming.parts[index] = data
            incoming.count = incoming.count + 1
        end
        incoming.deadline = self.clock + TRANSFER_TIMEOUT
        if incoming.count == total then
            self:Import(incoming)
        end
    end
end

-- A macro: into the bank, Unsorted in its section (General when the
-- section is unknown here).
function Send:ImportMacro(incoming, text)
    local Bank = addon.Bank
    local name, icon, body = Send.UnpackMacro(text)
    local section = "GENERAL"
    for _, known in ipairs(Bank and Bank.SECTIONS or {}) do
        if known == incoming.scope then
            section = known
        end
    end
    local id, addError, received
    if not name then
        addError = "not a macro"
    elseif not Bank then
        addError = "no macro bank"
    else
        received = Bank:FreeName(section, name)
        id, addError = Bank:Add(section, nil, received, icon, body)
    end
    if not id then
        whisper(incoming.sender, "R", incoming.id, addError)
        finishIncoming(self, "Couldn't take the macro " .. incoming.name .. " from " .. incoming.sender .. ": "
            .. tostring(addError))
        return
    end
    whisper(incoming.sender, "R", incoming.id, "ok")
    local renamed = received ~= name and (" as " .. received .. " (name was taken)") or ""
    finishIncoming(self, "Received the macro " .. name .. " from " .. incoming.sender .. renamed .. ": in the bank, "
        .. Bank.SectionName(section) .. " / " .. Bank.UNSORTED .. ".")
end

-- All chunks in: imported as pasted export text (a macro: into the bank).
function Send:Import(incoming)
    local text = decode(table.concat(incoming.parts, "", 1, incoming.total))
    if incoming.kind == "macro" then
        return self:ImportMacro(incoming, text)
    end
    local results, errorMessage = addon:ImportTemplates(text)
    local result = results and results[1]
    errorMessage = errorMessage or (not result and "nothing to import") or result.error
    if errorMessage then
        whisper(incoming.sender, "R", incoming.id, errorMessage)
        finishIncoming(self, "Couldn't import " .. incoming.name .. " from " .. incoming.sender .. ": " .. errorMessage)
        return
    end
    whisper(incoming.sender, "R", incoming.id, "ok")
    local renamed = result.name ~= result.originalName and (" as " .. result.name .. " (name was taken)") or ""
    finishIncoming(self, "Received " .. className(result.scope) .. " template " .. result.originalName
        .. " from " .. incoming.sender .. renamed .. ".")
    local UI = addon.UI
    if UI and UI.window and UI.window.frame:IsShown() then
        if UI:IsEditorDirty() then
            UI:RequestRefresh(true)
        else
            UI:Select(result.scope, result.name)
        end
    end
end

function Send:Accept()
    local incoming = self.incoming
    if not incoming or incoming.stage ~= "ask" then
        return
    end
    incoming.stage, incoming.parts, incoming.count = "receiving", {}, 0
    incoming.deadline = self.clock + TRANSFER_TIMEOUT
    whisper(incoming.sender, "A", incoming.id)
    if self.prompt then
        self.prompt:Hide()
    end
end

function Send:Decline()
    local incoming = self.incoming
    if not incoming or incoming.stage ~= "ask" then
        return
    end
    whisper(incoming.sender, "D", incoming.id)
    finishIncoming(self)
end

function Send:OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX or channel ~= "WHISPER" or not sender then
        return
    end
    local fields = {}
    for field in (message .. "\t"):gmatch("(.-)\t") do
        table.insert(fields, field)
    end
    local kind, id = table.remove(fields, 1), table.remove(fields, 1)
    if not id then
        return
    end
    if kind == "O" or kind == "M" or kind == "C" or kind == "X" then
        fromSender(self, kind, id, sender, fields)
    else
        fromReceiver(self, kind, id, sender, fields[1])
    end
end

function Send:Update(elapsed)
    self.clock = self.clock + (elapsed or 0)
    self.wait = (self.wait or 0) - (elapsed or 0)
    if self.queue[1] and self.wait <= 0 then
        local item = table.remove(self.queue, 1)
        if SendAddonMessage then
            SendAddonMessage(PREFIX, item.message, "WHISPER", item.target)
        end
        self.wait = SEND_INTERVAL
    end
    local out = self.outgoing
    if out and self.clock >= out.deadline then
        if out.stage == "offer" then
            finishOutgoing(self, "No answer from " .. out.target .. ": offline, or without Quintessence.")
        elseif out.stage == "waiting" then
            finishOutgoing(self, out.target .. " didn't answer the offer of " .. out.name .. ".")
        else
            finishOutgoing(self, "Sending " .. out.name .. " to " .. out.target .. " timed out.")
        end
    end
    local incoming = self.incoming
    if incoming and self.clock >= incoming.deadline then
        if incoming.stage == "ask" then
            whisper(incoming.sender, "D", incoming.id)
            finishIncoming(self, "The offer of " .. incoming.name .. " from " .. incoming.sender .. " expired.")
        else
            finishIncoming(self, "Receiving " .. incoming.name .. " from " .. incoming.sender .. " timed out.")
        end
    end
end

--[[ The receive prompt ]]

local WIDTH = 340
local PAD = 18
local RIM = 5
local TAB_HALF = math.floor(Theme.SECTION_TAB_HEIGHT / 2)
local TEXT_TOP = Theme.SECTION_TAB_HEIGHT + 12
local BUTTON_WIDTH = 96
local BUTTON_HEIGHT = 24
local BUTTON_GAP = 10

local function promptButton(self, frame, text, style, onClick)
    local button = AceGUI:Create("WMC-Button")
    button.frame:SetParent(frame)
    button:SetStyle(style)
    button:SetText(text)
    button:SetWidth(BUTTON_WIDTH)
    button:SetHeight(BUTTON_HEIGHT)
    button:SetCallback("OnClick", onClick)
    return button
end

function Send:BuildPrompt()
    if self.prompt then
        return self.prompt
    end
    local frame = CreateFrame("Frame", "WMCSendPrompt", UIParent)
    frame:Hide()
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetWidth(WIDTH)

    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -TAB_HALF)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    frame.body = body
    Theme.CreateShadow(body)
    Theme.CreatePanel(body, "BACKGROUND")
    frame.background = Theme.CreateBackground(body, "BORDER", 0)

    local tab = Theme.CreateSectionTab(frame)
    tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    tab:SetText("Template offered")
    frame.tab = tab

    -- On the body (a child frame, drawn over the prompt frame itself).
    local text = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -TEXT_TOP)
    text:SetWidth(WIDTH - 2 * PAD)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    frame.text = text

    frame.accept = promptButton(self, frame, ACCEPT or "Accept", "normal", function()
        if PlaySound then
            PlaySound("igMainMenuOptionCheckBoxOn")
        end
        Send:Accept()
    end)
    frame.decline = promptButton(self, frame, DECLINE or "Decline", "red", function()
        if PlaySound then
            PlaySound("igMainMenuClose")
        end
        Send:Decline()
    end)
    self.prompt = frame
    return frame
end

function Send:ShowPrompt()
    local incoming = self.incoming
    if not incoming or incoming.stage ~= "ask" then
        return
    end
    local frame = self:BuildPrompt()
    local kind = KIND_NAMES[incoming.kind] or "template"
    frame.tab:SetText(kind == "macro" and "Macro offered" or "Template offered")
    frame.text:SetText(NAME_COLOR .. incoming.sender .. "|r wants to send you the " .. className(incoming.scope)
        .. " " .. kind .. " " .. TEMPLATE_COLOR .. incoming.name .. "|r.")
    local measured = frame.text.GetStringHeight and frame.text:GetStringHeight()
    local height = TEXT_TOP + ((type(measured) == "number" and measured > 0) and math.ceil(measured) or 28) + 16
    local x = math.floor((WIDTH - 2 * BUTTON_WIDTH - BUTTON_GAP) / 2)
    for _, button in ipairs({ frame.accept, frame.decline }) do
        button.frame:ClearAllPoints()
        button.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -height)
        -- Created on UIParent by AceGUI: set the strata, don't inherit it.
        button.frame:SetFrameStrata(frame:GetFrameStrata())
        button.frame:SetFrameLevel(frame:GetFrameLevel() + 3)
        button.frame:Show()
        x = x + BUTTON_WIDTH + BUTTON_GAP
    end
    height = height + BUTTON_HEIGHT + 16
    frame:SetHeight(height)
    frame.background:Layout(RIM, RIM, WIDTH - 2 * RIM, height - TAB_HALF - 2 * RIM)
    frame.tab:SetFrameLevel(frame:GetFrameLevel() + 3)
    Theme.ScalePopup(frame) -- the windows' scale (Theme.lua)
    frame:ClearAllPoints()
    frame:SetPoint("TOP", UIParent, "TOP", 0, -140)
    frame:Show()
    if PlaySound then
        PlaySound("igMainMenuOpen")
    end
end

--[[ Events ]]

local driver = CreateFrame("Frame")
driver:RegisterEvent("CHAT_MSG_ADDON")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        Send:OnAddonMessage(...)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- an offer that came in during combat
        if Send.incoming and Send.incoming.stage == "ask" and not (Send.prompt and Send.prompt:IsShown()) then
            Send:ShowPrompt()
        end
    end
end)
driver:SetScript("OnUpdate", function(_, elapsed)
    Send:Update(elapsed)
end)
Send.driver = driver
