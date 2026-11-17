local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme
local UI = { selectedScope = nil, selectedName = nil, editing = false, filter = "" }
addon.UI = UI

local CLASS_ORDER = {
    "GENERAL",
    "DEATHKNIGHT", "DRUID", "HUNTER", "MAGE", "PALADIN",
    "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
}

local BLACK_SQUARE = "Interface\\Buttons\\WHITE8X8"
local NO_CATEGORY = "__NONE__"
local DRAFT_NAME = "new_macro"
local DRAFT_SOURCE = "#DEFAULT\n"
-- Vertical space between the search box and the template list, so the
-- list's scrollbar arrow never touches the search box.
local LIST_TOP_GAP = 6
-- Vertical space between the editor's dropdown row and the source box.
local EDITOR_SECTION_GAP = 10
-- Vertical space between the source box and the Preview-as row: its label's
-- own padding adds about as much as the note line under the row, so the
-- row sits evenly between the source and preview boxes.
local PREVIEW_AS_GAP = 6
-- Space between both columns' bottom edge and the window's bottom pipe
-- (the content area already keeps clear of it; no Close button down there).
local WINDOW_BOTTOM_GAP = 0
-- Sidebar width and the gap between the sidebar and the editor column.
local SIDEBAR_WIDTH = 220
local COLUMN_GAP = 14
-- The sidebar's left edge sits this far in from the content area's (within
-- SIDEBAR_WIDTH, so the editor column stays put): the frame's valve wheel,
-- bottom left, reaches 2 units into the content area (one more, by eye).
local SIDEBAR_INSET = 3
-- Both columns' tops sit this far below the content area's (the editor is
-- anchored to the sidebar's top, so its heading stays level with the class
-- dropdown).
local SIDEBAR_TOP = 1
-- Horizontal gap between buttons sharing a row.
local BUTTON_GAP = 6
-- Every flag toggle has the same width: flag names are at most
-- Compiler.FLAG_NAME_MAX (5) characters.
local FLAG_BUTTON_WIDTH = 104
-- Editor redraws triggered by game-state changes are coalesced to at most
-- one per REFRESH_INTERVAL seconds (auras and the combat log fire often).
local REFRESH_INTERVAL = 0.1
-- Evaluation panel: how many flattened forms to list before summarizing.
local EXPLAIN_MAX_FORMS = 25
local EXPLAIN_MAX_EXPRESSION = 70

-- Source tabs (§13.2): "All" shows the whole template; once it has modes,
-- "Base" (everything before the first #MODE) and one tab per mode appear.
local TAB_ALL = "ALL"
local TAB_ADD = "ADD"

-- "+ Mode" presets: name, condition, and the #WATCH the condition needs
-- (inserted into the metadata when missing). There is no WORLD preset: the
-- base template already is the open-world case (and the fallback for every
-- state without a mode); a world mode the game cannot detect on its own,
-- such as world PvP, is a flag mode ("Flag..." -- §5.15).
local MODE_PRESETS = {
    { name = "RAID", condition = "INSTANCE=RAID", watch = "INSTANCE" },
    { name = "DUNGEON", condition = "INSTANCE=PARTY", watch = "INSTANCE" },
    { name = "BATTLEGROUND", condition = "INSTANCE=PVP", watch = "INSTANCE" },
    { name = "ARENA", condition = "INSTANCE=ARENA", watch = "INSTANCE" },
    { name = "DUEL", condition = "DUEL=ANY", watch = "DUEL" },
}

-- Syntax highlighting colors (RRGGBB), by token kind (Compiler.TokenizeLine)
-- plus the editor's own line marks: "active" (the #IF / #MODE that is
-- currently selected) and "error" (the line an error points at).
local HIGHLIGHT_COLORS = {
    comment = "7f7f7f",
    directive = "ffd100",
    active = "40ff40",
    bad = "ff5555",
    number = "ff9f40",
    name = "ffe680",
    field = "66ccff",
    badfield = "ff5555",
    keyword = "c586ff",
    string = "a8e07a",
    value = nil, -- plain text color
    operator = "a0a0a0",
    command = "8fb8ff",
    conditional = "d7ba7d",
    placeholder = "ff79c6",
    macro = "8fb8ff",
    error = "ff4040",
}

-- Blizzard icon art has small rounded-corner notches baked into the
-- texture (normally hidden under a border/slot frame); cropping a few
-- percent in from every edge trims those notches so icons read as clean
-- squares even with no border drawn over them.
local ICON_ZOOM = 0.08

-- Circular class-icon sprite sheet: the same asset Blizzard's own UI uses
-- for class portraits. CLASS_ICON_TCOORDS (a global from FrameXML) maps a
-- class token to its {left, right, top, bottom} tile slice.
local CLASS_ICON = "Interface\\TargetingFrame\\UI-Classes-Circles"

-- The disc drawn within each tile touches the tile's edge midpoints, so its
-- only transparent area is the four corners outside the inscribed circle.
-- Zooming a square crop in by (0.5 - 0.5/sqrt(2)) ~= 0.1464 of the tile's
-- own width/height is the minimum that keeps every corner of that crop
-- inside the circle; a touch more (0.15) gives a small safety margin for
-- any soft/antialiased pixels right at the true edge. The result is a
-- fully opaque square, same as a cropped custom icon, so no corner ever
-- needs a fill color painted behind it.
local CLASS_ICON_ZOOM = 0.15
local function classIconCoords(scope)
    local tile = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[scope]
    if not tile then
        return nil
    end
    local left, right, top, bottom = tile[1], tile[2], tile[3], tile[4]
    local width, height = right - left, bottom - top
    return {
        left + CLASS_ICON_ZOOM * width,
        right - CLASS_ICON_ZOOM * width,
        top + CLASS_ICON_ZOOM * height,
        bottom - CLASS_ICON_ZOOM * height,
    }
end

local function currentClass()
    local _, class = UnitClass("player")
    return class or "ROGUE"
end

local function className(class)
    if class == "GENERAL" then
        return "General"
    end
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
end

local function classLabel(class)
    if class == "GENERAL" then
        return "|cffffffffGeneral|r"
    end
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    local name = className(class)
    if color then
        return ("|cff%02x%02x%02x%s|r"):format(color.r * 255, color.g * 255, color.b * 255, name)
    end
    return name
end

local function sortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl) do
        table.insert(keys, key)
    end
    table.sort(keys, function(a, b)
        return string.lower(a) < string.lower(b)
    end)
    return keys
end


--[[-----------------------------------------------------------------------------
Syntax highlighting (§13.3). Editor-only: runs when the source box is edited
(deferred by the TextArea until typing pauses) or when the error / active
branch marks change, never during compilation.
-------------------------------------------------------------------------------]]


-- One source line with color codes. `number` is the line's number in the
-- WHOLE template (mode tabs pass their offset), so error and active marks
-- line up whatever tab is shown.
local function colorizeLine(line, number, context)
    if line == "" then
        return line
    end
    if context and context.errorLines and context.errorLines[number] then
        return "|cff" .. HIGHLIGHT_COLORS.error .. line .. "|r"
    end
    -- A muted line (§5.16) never reaches the macro, like a comment.
    if context and context.mutedLines and context.mutedLines[number] then
        return "|cff" .. HIGHLIGHT_COLORS.comment .. line .. "|r"
    end
    local spans = addon.Compiler.TokenizeLine(line)
    if #spans == 0 then
        return line
    end
    local kinds = {}
    for _, span in ipairs(spans) do
        local kind = span[3]
        for index = span[1], span[2] do
            kinds[index] = kind
        end
    end
    if context and context.activeLines and context.activeLines[number] then
        for index = 1, #line do
            if kinds[index] == "directive" then
                kinds[index] = "active"
            end
        end
    end
    -- Never split an escaped pipe ("||") across two color runs.
    local index = 1
    while index < #line do
        if line:byte(index) == 124 and line:byte(index + 1) == 124 then
            kinds[index + 1] = kinds[index]
            index = index + 2
        else
            index = index + 1
        end
    end
    local out = {}
    local runStart, runKind = 1, kinds[1]
    for position = 2, #line + 1 do
        local kind = kinds[position]
        if position > #line or kind ~= runKind then
            local text = line:sub(runStart, position - 1)
            local color = runKind and (HIGHLIGHT_COLORS[runKind] or runKind:match("^#(%x+)$"))
            table.insert(out, color and ("|cff" .. color .. text .. "|r") or text)
            runStart, runKind = position, kind
        end
    end
    return table.concat(out)
end

local function highlightSource(plain, context)
    local offset = context and context.lineOffset or 0
    local lineMap = context and context.lineMap
    local out = {}
    local number = 0
    for line in ((plain or "") .. "\n"):gmatch("(.-)\n") do
        number = number + 1
        local templateLine = number + offset
        if lineMap then
            templateLine = lineMap[number] or ((lineMap[#lineMap] or 0) + number - #lineMap)
        end
        out[number] = colorizeLine(line, templateLine, context)
    end
    return table.concat(out, "\n")
end
UI.HighlightSource = highlightSource

-- AceGUI's Flow layout lines up row siblings by their `alignoffset` (the
-- distance from a widget's top to its alignment line). An edit box has one,
-- tied to its frame with the input box at the bottom; a Button has none, so
-- Flow centres the button on that line. Give the button an offset that puts
-- its vertical centre on the input box's centre. Measured at runtime.
-- Whole pixels only: a widget placed on a half pixel can lose a 1px edge
-- of its art.
local function round(value)
    return math.floor(value + 0.5)
end

-- Flow puts a widget's top (a_e - a) below the edit box widget's top, so a
-- widget whose visible centre is `centre` below its own top lines up with
-- the edit box's visible centre `boxCentre` when a = a_e - boxCentre + centre.
-- Clamped to [0, a_e]: never above the edit box widget's own top (where the
-- row starts), so an implausible measurement can't push it out of the row.
local function offsetFor(editBox, boxCentre, centre)
    local editOffset = editBox.alignoffset or 30
    return math.max(0, math.min(round(editOffset - boxCentre + centre), editOffset))
end

-- First estimate, before anything is drawn: the input box is bottom-
-- anchored in the edit box widget, and the widget's visible part is assumed
-- to be centred in its frame.
local function alignWithEditBox(widget, editBox)
    local boxHeight = editBox.editbox and editBox.editbox:GetHeight() or 19
    local boxCentre = editBox.frame:GetHeight() - boxHeight / 2
    widget.alignoffset = offsetFor(editBox, boxCentre, widget.frame:GetHeight() / 2)
end

-- The visible part of an edit box: its backdrop when it has one (the
-- themed field draws its art on the input box itself, which is then its
-- own backdrop), else the input box.
local function visibleRegion(region)
    return region and (region.backdrop or region)
end

local pixelSize = Theme.PixelSize

-- The edit box's x offset in its widget (0 for WMC-EditBox; 7 was AceGUI's).
local function boxLeft(editBox)
    return editBox.boxLeft or 7
end

-- The input box is made exactly as tall as the row's button (a whole number
-- of screen pixels). The box's height is changed by moving its top anchor
-- (its bottom is pinned to the widget's bottom); the original anchor is put
-- back before the widget is released (restoreEditBoxHeight). `delta` extra
-- pixels make the visible box taller.
local function matchBoxHeight(editBox, wanted)
    local inner = editBox.editbox
    local region = visibleRegion(inner)
    local have = region and region:GetTop() and region:GetBottom()
        and (region:GetTop() - region:GetBottom()) or (region and region:GetHeight())
    if not (inner and inner.SetPoint and wanted and wanted > 0) then
        return true -- nothing to size
    end
    if not (have and have > 0) then
        return false -- not drawn yet: retry next frame
    end
    local applied = inner._wmcDelta or 0
    local delta = wanted - (have - applied)
    if delta ~= applied then
        local baseY = (editBox.label and editBox.label:IsShown()) and -18 or 0
        inner._wmcDelta = delta
        inner:SetPoint("TOPLEFT", editBox.frame, "TOPLEFT", boxLeft(editBox), baseY + delta)
    end
    return true
end

-- SetLabel re-anchors the input box (dropping the extra height); call this
-- after every SetLabel on a matched box.
local function reapplyBoxHeight(editBox)
    local inner = editBox and editBox.editbox
    if inner and inner._wmcDelta and inner.SetPoint then
        local baseY = (editBox.label and editBox.label:IsShown()) and -18 or 0
        inner:SetPoint("TOPLEFT", editBox.frame, "TOPLEFT", boxLeft(editBox), baseY + inner._wmcDelta)
    end
end

local function restoreEditBoxHeight(editBox)
    local inner = editBox and editBox.editbox
    if inner and inner._wmcDelta then
        local baseY = (editBox.label and editBox.label:IsShown()) and -18 or 0
        inner._wmcDelta = nil
        inner:SetPoint("TOPLEFT", editBox.frame, "TOPLEFT", boxLeft(editBox), baseY)
    end
end

-- On screens where one unit is not exactly one pixel (UI scale not
-- "pixel perfect"), a 24-unit button is 24.4 pixels tall and its edges fall
-- between pixels. The job's buttons get a whole-pixel height, and after
-- layout each is nudged so its top edge sits on a pixel line.
local function snapUnits(value, pixel)
    return round(value / pixel) * pixel
end

-- job = { editBox, boxHeight }: makes the box `boxHeight` tall (a whole
-- number of screen pixels). The row's buttons are glued to the box
-- (anchorToBox), so they follow it without any measuring here.
local function correctAlignment(job)
    local pixel = pixelSize(job.editBox.frame)
    local target = pixel and snapUnits(job.boxHeight, pixel) or job.boxHeight
    return matchBoxHeight(job.editBox, target)
end

-- Runs correctAlignment one frame after a redraw (and after the window is
-- shown), retrying a few frames while positions are still unresolved.
local alignFrame = CreateFrame("Frame")
alignFrame:Hide()
UI.alignFrame = alignFrame
alignFrame:SetScript("OnUpdate", function(frame)
    frame.tries = (frame.tries or 0) + 1
    local pending = false
    for index, job in pairs(frame.jobs or {}) do
        if correctAlignment(job) then
            frame.jobs[index] = nil
        else
            pending = true
        end
    end
    if not pending or frame.tries >= 10 then
        frame.jobs = nil
        frame:Hide()
    end
end)

local function scheduleAlignment(...)
    local jobs = {}
    for index = 1, select("#", ...) do
        local job = select(index, ...)
        if job then
            table.insert(jobs, job)
        end
    end
    alignFrame.jobs = jobs
    alignFrame.tries = 0
    alignFrame:Show()
end

-- Pixel snapping. A frame that sits on a fraction of a pixel can lose a 1px
-- edge of its art. Dragging leaves the window at an arbitrary fractional
-- position, so it is snapped to whole screen pixels when the drag ends and
-- when the window is shown; everything inside is laid out in whole units
-- from there.
-- Prints the measured geometry of the name row (for /qmc uidebug).
function UI:DebugGeometry()
    local function line(label, region)
        local top, bottom = region and region:GetTop(), region and region:GetBottom()
        local px = region and pixelSize(region)
        if not (top and bottom and px) then
            return label .. ": n/a"
        end
        return string.format("%s: top %.3f bottom %.3f height %.3f = %.2f px (top at %.2f px)",
            label, top, bottom, top - bottom, (top - bottom) / px, top / px)
    end
    local out = {}
    if self.nameBox then
        out[#out + 1] = line("name box", visibleRegion(self.nameBox.editbox))
    end
    if self.saveButton then
        out[#out + 1] = line("save button", self.saveButton.frame)
    end
    if self.previewAsBox then
        out[#out + 1] = line("preview box", visibleRegion(self.previewAsBox.editbox))
    end
    if self.previewModeButton then
        out[#out + 1] = line("this-mode button", self.previewModeButton.frame)
    end
    return out
end

function UI:SnapWindow()
    local window = self.window
    local frame = window and window.frame
    if not frame then
        return
    end
    local pixel = pixelSize(frame)
    local left, top = frame:GetLeft(), frame:GetTop()
    if not (pixel and left and top) then
        return
    end
    local newLeft, newTop = round(left / pixel) * pixel, round(top / pixel) * pixel
    if math.abs(newLeft - left) < 0.0001 and math.abs(newTop - top) < 0.0001 then
        return
    end
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", newLeft, newTop)
    local status = window.status or window.localstatus
    if status then
        status.left, status.top = newLeft, newTop
    end
end

-- An empty full-width row of fixed height, used as vertical spacing.
local function makeSpacer(height)
    local spacer = AceGUI:Create("WMC-Spacer")
    spacer:SetFullWidth(true)
    spacer:SetHeight(height)
    return spacer
end

-- A fixed-width gap between widgets of a Flow row (as tall as a button, so
-- it never changes the row's height or alignment).
local function makeGap(width)
    local gap = AceGUI:Create("WMC-Spacer")
    gap:SetWidth(width)
    gap:SetHeight(24)
    return gap
end

-- The editor is a List layout: each block hangs from the bottom of the one
-- above. A widget of height 0 has no height in WoW (and so no bottom), and
-- every block below it loses its place and falls to the top of the scroll
-- area, drawn over the source box. An empty Label is 0 tall, so texts that
-- can be empty get a single space instead.
local function nonEmpty(text)
    return (text and text ~= "") and text or " "
end

-- A captioned block of the editor (§13.6): a panel with a gold section tab
-- ("BUTTON", "FORMS", "STATE"), children laid out inside it.
local SECTION_GAP = 10
local function addSection(parent, title)
    local section = AceGUI:Create("WMC-Section")
    section:SetFullWidth(true)
    section:SetLayout("List")
    section:SetTitle(title)
    parent:AddChild(section)
    return section
end

local function stripGroupSkin(widget)
    local frame = widget and widget.frame
    if frame and frame.SetBackdrop then
        frame:SetBackdrop(nil)
    end
end


-- All buttons are WMC-Button (Widgets.lua): our own pool, identical press
-- feedback everywhere, and no state leaking through AceGUI's shared pool.
-- "WMC-Flow": AceGUI's Flow, then the row's own fix-ups. Flow places each
-- widget at whole-unit offsets from its neighbour; when one unit isn't one
-- screen pixel (any UI scale but the pixel-perfect one) those edges land
-- between pixels. A row that needs a widget glued to another sets userdata
-- "wmcAfterLayout" (cleared by AceGUI on release, so nothing leaks into the
-- shared SimpleGroup pool); it runs after every layout, because Flow clears
-- all anchors each time.
-- Flow also counts half of each widget's height below the row's alignment
-- line, which is too much for a labelled field (its line is below its
-- centre: 51 instead of 42). A row that always fits on one line sets
-- userdata "wmcOneRow" and is given its true height instead.
local function oneRowHeight(children)
    local line, bottom = 0, 0
    for _, child in ipairs(children) do
        local height = child.frame.height or child.frame:GetHeight() or 0
        line = math.max(line, child.alignoffset or (height / 2))
    end
    for _, child in ipairs(children) do
        local height = child.frame.height or child.frame:GetHeight() or 0
        bottom = math.max(bottom, line - (child.alignoffset or (height / 2)) + height)
    end
    return bottom
end

if AceGUI.GetLayout and AceGUI.RegisterLayout and AceGUI:GetLayout("Flow") then
    local flow = AceGUI:GetLayout("Flow")
    AceGUI:RegisterLayout("WMC-Flow", function(content, children)
        flow(content, children)
        local owner = content.obj
        if owner and owner.GetUserData and owner:GetUserData("wmcOneRow") and owner.LayoutFinished then
            owner:LayoutFinished(nil, oneRowHeight(children))
        end
        local after = owner and owner.GetUserData and owner:GetUserData("wmcAfterLayout")
        if after then
            after()
        end
    end)
end

-- Glues a row of buttons to an edit box's visible box: the first button's
-- top to the box's top and bottom to bottom, each next button the same to
-- the one before. All share the box's screen pixel rows: same height, edges
-- drawn identically, wherever the window is. `editBox.buttonGap` (the themed
-- field's 6 units) separates them. `follower` (e.g. a checkbox) goes after
-- the last button, centred on it. Only when the box has a visible region of
-- its own (`backdrop`); otherwise Flow's placement is kept.
local function anchorToBox(editBox, buttons, follower)
    local inner = editBox.editbox
    local region = inner and inner.backdrop
    if not (region and buttons and buttons[1] and buttons[1].frame) then
        return false
    end
    local gap = editBox.buttonGap or 0
    local frameRight, regionRight = editBox.frame:GetRight(), region:GetRight()
    local dx = (frameRight and regionRight) and (frameRight - regionRight) or 0
    local previous, previousIsBox = region, true
    for _, button in ipairs(buttons) do
        local frame = button.frame
        local x = (previousIsBox and dx or 0) + gap
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", previous, "TOPRIGHT", x, 0)
        frame:SetPoint("BOTTOMLEFT", previous, "BOTTOMRIGHT", x, 0)
        previous, previousIsBox = frame, false
    end
    if follower and follower.frame then
        follower.frame:ClearAllPoints()
        follower.frame:SetPoint("LEFT", previous, "RIGHT", 2 * gap, 0)
    end
    return true
end
UI.AnchorToBox = anchorToBox

local function makeButton(text, width, onClick)
    local button = AceGUI:Create("WMC-Button")
    button:SetText(text)
    if width then
        button:SetWidth(width)
    end
    button:SetCallback("OnClick", onClick)
    return button
end

-- Shows a message in the editor's status line (and chat for failures that
-- happen away from the editor, e.g. a menu action).
function UI:SetStatus(text, color)
    if self.status then
        self.status:SetText(nonEmpty((color or "") .. text .. (color and "|r" or "")))
        self:FitEditor()
    end
end

local ERROR_COLOR = "|cffff4040"
local WARN_COLOR = "|cffffcc00"
local NOTE_COLOR = "|cffffff80"
local OK_COLOR = "|cff80ff80"
local DIM_COLOR = "|cff808080"

--[[-----------------------------------------------------------------------------
Popups (Popups.lua): WMC's own modal dialog and context menu, not
Blizzard's shared StaticPopup / UIDropDownMenu frames. Destructive choices
(Delete, Discard) use the red button.
-------------------------------------------------------------------------------]]
local Dialog, Menu = addon.Dialog, addon.Menu
local ACCEPT_TEXT = ACCEPT or "Accept"
local CANCEL_TEXT = CANCEL or "Cancel"
local DELETE_TEXT = DELETE or "Delete"

-- A Cancel button: same as Escape (runs the dialog's onCancel).
local function cancelButton()
    return { text = CANCEL_TEXT, cancel = true }
end

Dialog:Register("WMC_NEW_CATEGORY", {
    title = "New category",
    text = "New category name:",
    hasEditBox = true,
    maxLetters = 30,
    buttons = {
        {
            text = ACCEPT_TEXT,
            action = function(text)
                local ok, errorMessage = addon:CreateCategory(UI.selectedScope, text)
                if not ok then
                    addon:Print(errorMessage)
                end
                UI:RefreshCategoryDropdown()
            end,
        },
        cancelButton(),
    },
})

-- The rail's send button (UI:SendSelected): the saved template to a player
-- (Send.lua), who is asked first.
Dialog:Register("WMC_SEND_TEMPLATE", {
    title = "Send template",
    text = "Send '%s' to:",
    hint = "The player's name. They need Quintessence, and are asked first.",
    hasEditBox = true,
    maxLetters = 12,
    editText = function(data)
        return data and data.target or ""
    end,
    highlight = true,
    buttons = {
        {
            text = "Send",
            action = function(text, data)
                addon.Send:Offer(data.scope, data.name, text)
            end,
        },
        cancelButton(),
    },
})

Dialog:Register("WMC_RENAME_CATEGORY", {
    title = "Rename category",
    text = "Rename category '%s':",
    hasEditBox = true,
    maxLetters = 30,
    editText = function(data)
        return data and data.name or ""
    end,
    highlight = true,
    buttons = {
        {
            text = ACCEPT_TEXT,
            action = function(text, data)
                local oldName = data and data.name
                local ok, result = addon:RenameCategory(UI.selectedScope, oldName, text)
                if not ok then
                    addon:Print(result)
                    return
                end
                if UI.editingDraft and UI.draftCategory == oldName then
                    UI.draftCategory = result
                end
                UI:RefreshCategoryDropdown()
            end,
        },
        cancelButton(),
    },
})

Dialog:Register("WMC_DELETE_CATEGORY", {
    title = "Delete category",
    text = "Delete category '%s'? Its templates become uncategorized.",
    buttons = {
        {
            text = DELETE_TEXT,
            style = "red",
            action = function(_, data)
                local name = data and data.name
                addon:DeleteCategory(UI.selectedScope, name)
                if UI.editingDraft and UI.draftCategory == name then
                    UI.draftCategory = nil
                end
                UI:RefreshCategoryDropdown()
            end,
        },
        cancelButton(),
    },
    -- Enter never deletes: it presses Cancel.
    default = 2,
})

Dialog:Register("WMC_DELETE_TEMPLATE", {
    title = "Delete template",
    text = "Delete template '%s'? This cannot be undone.",
    buttons = {
        {
            text = DELETE_TEXT,
            style = "red",
            action = function(_, data)
                UI:DeleteTemplateConfirmed(data.scope, data.name)
            end,
        },
        cancelButton(),
    },
    default = 2,
})

-- Unsaved-changes guard (UI:Guard): [Save] keeps the edits and goes on,
-- [Discard] drops them and goes on, Escape keeps editing. Enter saves (the
-- non-destructive choice).
Dialog:Register("WMC_DISCARD_CHANGES", {
    title = "Unsaved changes",
    text = "Save changes to '%s' before leaving?",
    hint = "Esc to keep editing",
    buttons = {
        { text = "Save", action = function() UI:GuardSave() end },
        { text = "Discard", style = "red", action = function() UI:GuardDiscard() end },
    },
    default = 1,
    onCancel = function()
        UI:GuardCancel()
    end,
})

-- "+ Mode" > "Custom...": NAME CONDITION.
Dialog:Register("WMC_NEW_MODE", {
    title = "New mode",
    text = "New mode: NAME CONDITION\n(for example: HEALER PLAYER_SPEC=HOLY)",
    hasEditBox = true,
    maxLetters = 200,
    buttons = {
        {
            text = ACCEPT_TEXT,
            action = function(text)
                local name, condition = (text or ""):match("^%s*([%a_][%w_]*)%s+(.-)%s*$")
                if not name or condition == "" then
                    addon:Print("A mode needs a name and a condition, e.g. HEALER PLAYER_SPEC=HOLY")
                    return
                end
                UI:AddMode(name, condition)
            end,
        },
        cancelButton(),
    },
})

-- "+ Mode" > "Flag...": a mode switched by /qmc flag NAME (§5.15). Flag
-- names are at most FLAG_NAME_MAX characters (the State block's toggles all
-- share one width).
local FLAG_NAME_MAX = addon.Compiler.FLAG_NAME_MAX or 5
Dialog:Register("WMC_NEW_FLAG_MODE", {
    title = "New flag mode",
    text = "New flag mode: FLAG NAME, up to " .. FLAG_NAME_MAX
        .. " letters\n(for example: WPVP -- switch it with /qmc flag WPVP)",
    hasEditBox = true,
    maxLetters = FLAG_NAME_MAX,
    buttons = {
        {
            text = ACCEPT_TEXT,
            action = function(text)
                local name, nameError = addon.Compiler.ValidFlagName(text)
                if not name then
                    addon:Print(nameError .. ".")
                    return
                end
                UI:AddMode(name, "FLAG=" .. name, "FLAG")
            end,
        },
        cancelButton(),
    },
})

-- Category header right-click: Rename / Delete.
function UI:OpenCategoryMenu(name, anchor)
    Menu:Open({
        {
            text = "Rename...",
            func = function()
                Dialog:Show("WMC_RENAME_CATEGORY", name, { name = name })
            end,
        },
        {
            text = "Delete",
            func = function()
                Dialog:Show("WMC_DELETE_CATEGORY", name, { name = name })
            end,
        },
    }, anchor)
end

-- "Make Macro" asks each time where the macro should go.
function UI:OpenMacroMenu(anchor)
    Menu:Open({
        { text = "Character macro", func = function() UI:MakeMacro(true) end },
        { text = "General macro", func = function() UI:MakeMacro(false) end },
    }, anchor)
end

-- "+ Mode": presets, a flag mode and a custom mode.
function UI:OpenModeMenu(anchor)
    local items = {}
    for _, preset in ipairs(MODE_PRESETS) do
        table.insert(items, {
            text = preset.name .. "  |cff808080" .. preset.condition .. "|r",
            func = function()
                UI:AddMode(preset.name, preset.condition, preset.watch)
            end,
        })
    end
    table.insert(items, {
        text = "Flag...  |cff808080FLAG=<NAME>, set with /qmc flag|r",
        func = function()
            Dialog:Show("WMC_NEW_FLAG_MODE")
        end,
    })
    table.insert(items, {
        text = "Custom...",
        func = function()
            Dialog:Show("WMC_NEW_MODE")
        end,
    })
    Menu:Open(items, anchor)
end

--[[-----------------------------------------------------------------------------
Coalesced refresh
-------------------------------------------------------------------------------]]
local refreshFrame = CreateFrame("Frame")
refreshFrame:Hide()
UI.refreshFrame = refreshFrame
do
    local elapsed = 0
    refreshFrame:SetScript("OnUpdate", function(frame, delta)
        elapsed = elapsed + delta
        if elapsed < REFRESH_INTERVAL then
            return
        end
        elapsed = 0
        frame:Hide()
        local listToo = UI.refreshList
        UI.refreshList = false
        if listToo then
            UI:RefreshList()
        end
        UI:RefreshSelected()
    end)
end

-- Schedules an editor refresh (and a list rebuild when listChanged) for the
-- next refresh tick. Nothing is drawn while the window is hidden; Toggle
-- catches up when it is shown again.
function UI:RequestRefresh(listChanged)
    if not self.window or not self.window.frame:IsShown() then
        return
    end
    if listChanged then
        self.refreshList = true
    end
    refreshFrame:Show()
end

--[[-----------------------------------------------------------------------------
Window
-------------------------------------------------------------------------------]]
-- An editor laid out while the window is hidden gets no real sizes: on the
-- first open its tab strip and caption are missing and the source box sits
-- far too low. Toggle redraws such an editor one frame after showing the
-- window, when the window has its geometry.
local redrawFrame = CreateFrame("Frame")
redrawFrame:Hide()
UI.redrawFrame = redrawFrame
redrawFrame:SetScript("OnUpdate", function(frame)
    frame:Hide()
    if UI.editorDrawnHidden and UI.window and UI.window.frame:IsShown() then
        UI:RedrawEditor()
    end
end)

-- The editor's input for a saved template.
local function savedTemplate(scope, name, record)
    return {
        name = name,
        scope = scope,
        source = record.source or "",
        enabled = record.enabled ~= false,
        icon = record.icon,
        category = record.category,
        isDraft = false,
    }
end

function UI:Initialize()
    if self.window then
        self:RefreshList()
        return
    end
    self.selectedScope = self.selectedScope or currentClass()

    -- The themed window (Widgets.lua): fixed size, pipe frame, title on the
    -- hanging plaque (also the drag handle), close button in the top-right
    -- housing.
    local window = AceGUI:Create("WMC-Window")
    window:SetFrameStyle("main")
    window:SetTitle(addon.TITLE)
    -- Remember the position across sessions (stored as top/left when the
    -- window is moved).
    local settings = addon.db and addon.db.settings
    if settings then
        settings.window = settings.window or {}
        window:SetStatusTable(settings.window)
    end
    window:SetLayout("Fill")
    window:SetCallback("OnClose", function(widget)
        -- A popup belongs to the window: closing it counts as Escape.
        Menu:Close()
        Dialog:Cancel()
        addon.IconPicker:Cancel()
        addon.MuteDialog:Cancel()
        self:ClearPreviewAs()
        addon:SetEditorGroupAuras(false)
        widget:Hide()
    end)
    if window.sizer_se then
        window.sizer_se:Hide()
    end
    self.window = window
    -- Popups veil this window and stack above it (Popups.lua).
    Dialog:SetOwner(window.frame)
    if window.title and window.title.HookScript then
        window.title:HookScript("OnMouseUp", function()
            self:SnapWindow()
            -- children were put on pixel lines relative to the old position
            scheduleAlignment(self.alignJob, self.previewAlignJob)
            -- the docked guide may have to slide the pair back on screen
            addon.Guide:MainMoved()
        end)
    end
    -- The guide docks beside the window while both are shown.
    addon.Guide:AttachMain(window.frame)
    -- ESC closes the window: UISpecialFrames holds global frame names. The
    -- name has no underscore after "WMC" so it can never collide with a
    -- template's WMC_<name> button.
    _G.WMCMainWindow = window.frame
    if UISpecialFrames then
        table.insert(UISpecialFrames, "WMCMainWindow")
    end

    -- The two columns are anchored manually inside window.content. AceGUI's
    -- Flow layout applies per-row vertical offsets that misalign full-height
    -- siblings, so we only use layout engines *within* each column.
    local sidebar = AceGUI:Create("SimpleGroup")
    sidebar:SetLayout("Flow")
    sidebar.noAutoHeight = true
    local sidebarWidth = SIDEBAR_WIDTH - SIDEBAR_INSET
    sidebar:SetWidth(sidebarWidth)
    sidebar.frame:SetParent(window.content)
    sidebar.frame:ClearAllPoints()
    sidebar.frame:SetPoint("TOPLEFT", window.content, "TOPLEFT", SIDEBAR_INSET, -SIDEBAR_TOP)
    sidebar.frame:SetPoint("BOTTOMLEFT", window.content, "BOTTOMLEFT", SIDEBAR_INSET, WINDOW_BOTTOM_GAP)
    sidebar.frame:Show()
    stripGroupSkin(sidebar)
    self.sidebar = sidebar

    local scopeDropdown = AceGUI:Create("WMC-Dropdown")
    scopeDropdown:SetLabel("Class")
    scopeDropdown:SetFullWidth(true)
    local list, order = {}, {}
    for _, class in ipairs(CLASS_ORDER) do
        list[class] = classLabel(class)
        table.insert(order, class)
    end
    scopeDropdown:SetList(list, order)
    scopeDropdown:SetValue(self.selectedScope)
    scopeDropdown:SetCallback("OnValueChanged", function(_, _, value)
        local previousScope = self.selectedScope
        self:Guard(function()
            self.selectedScope = value
            self.selectedName = nil
            self:RefreshList()
            self:NewTemplate()
        end, function()
            scopeDropdown:SetValue(previousScope)
        end)
    end)
    sidebar:AddChild(scopeDropdown)
    self.scopeDropdown = scopeDropdown

    -- Every button row is the same construction (a full-width group), so
    -- the vertical spacing between rows is identical. Two buttons share a
    -- row with a gap between them. The gap is ROW_SLACK short of filling
    -- the row: Flow wraps a child once the widths it reads back (GetWidth,
    -- through the UI scale) exceed the row's, and at some scales an exact
    -- fit read back a hair over and pushed the second button to a row of
    -- its own.
    local ROW_SLACK = 0.5
    local half = math.floor((sidebarWidth - BUTTON_GAP) / 2)
    local function addButtonRow(buttons)
        local row = AceGUI:Create("SimpleGroup")
        row:SetLayout("Flow")
        row:SetFullWidth(true)
        sidebar:AddChild(row)
        stripGroupSkin(row)
        for index, button in ipairs(buttons) do
            if index > 1 then
                row:AddChild(makeGap(sidebarWidth - 2 * half - ROW_SLACK))
            end
            row:AddChild(button)
        end
        return row
    end
    local deleteButton = makeButton("Delete", half, function() self:DeleteSelected() end)
    deleteButton:SetStyle("red")
    addButtonRow({
        makeButton("New", half, function()
            self:Guard(function() self:NewTemplate() end)
        end),
        deleteButton,
    })
    local newCategoryButton = makeButton("New Category", nil, function()
        Dialog:Show("WMC_NEW_CATEGORY")
    end)
    newCategoryButton:SetFullWidth(true)
    addButtonRow({ newCategoryButton })
    addButtonRow({
        makeButton("Import", half, function()
            self:Guard(function() self:OpenImport() end)
        end),
        makeButton("Export All", half, function() self:ExportScope() end),
    })

    local search = AceGUI:Create("WMC-EditBox")
    search:SetLabel("Search")
    search:SetFullWidth(true)
    search:DisableButton(true)
    search:SetText(self.filter or "")
    search:SetCallback("OnTextChanged", function(_, _, value)
        self.filter = value or ""
        self:RefreshList()
    end)
    -- Names only, or names and the source text (settings.searchInText).
    self.searchModeButton = self.searchModeButton or addon.SearchModeButton(
        function() return addon.db.settings.searchInText == true end,
        function(on)
            addon.db.settings.searchInText = on or nil
            self:RefreshList()
        end)
    search:SetSideButton(self.searchModeButton)
    sidebar:AddChild(search)
    self.searchBox = search
    sidebar:AddChild(makeSpacer(LIST_TOP_GAP))

    -- Full-height children must be last in a Flow group.
    local templateScroll = AceGUI:Create("WMC-ScrollFrame")
    templateScroll:SetFramed(true)
    templateScroll:SetLayout("List")
    templateScroll:SetFullWidth(true)
    templateScroll:SetFullHeight(true)
    sidebar:AddChild(templateScroll)
    self.templateScroll = templateScroll

    sidebar:DoLayout()

    -- Right column: editor + preview + status. It starts under the title
    -- plaque, which hangs into the window from the top pipe.
    local editor = AceGUI:Create("WMC-ScrollFrame")
    editor:SetLayout("List")
    editor.frame:SetParent(window.content)
    editor.frame:SetPoint("TOPLEFT", sidebar.frame, "TOPRIGHT", COLUMN_GAP, -Theme.EditorTop("main"))
    editor.frame:SetPoint("BOTTOMRIGHT", window.content, "BOTTOMRIGHT", 0, WINDOW_BOTTOM_GAP)
    -- The bottom-right gear housing reaches into the content area: end the
    -- scrollbar (down arrow included) above it.
    editor:SetBarBottomInset(Theme.BarBottomClearance("main") - WINDOW_BOTTOM_GAP)
    editor.frame:Show()
    self.editor = editor
    self:BuildRail(window)

    window:Hide()
    self:RefreshList()
    self:NewTemplate()
end

function UI:Toggle()
    if not self.window then
        self:Initialize()
    end
    if self.window.frame:IsShown() then
        addon:SetEditorGroupAuras(false)
        self.window:Hide()
    else
        -- Preview-As lasts for one editor session (§13.5).
        self:ClearPreviewAs()
        self.window:Show()
        self:SnapWindow()
        self:RefreshList()
        -- State changes are ignored while hidden; catch up now.
        self:RefreshSelected()
        -- Positions only exist once the window is drawn.
        scheduleAlignment(self.alignJob, self.previewAlignJob)
        if self.editorDrawnHidden then
            redrawFrame:Show()
        end
    end
end

-- Redraws the editor from what it was last drawn for (the selected saved
-- template, or a fresh draft). Only for an editor nobody could have typed
-- into: anything unsaved is lost.
function UI:RedrawEditor()
    local record = self.selectedName and addon.db and addon.db.templates[self.selectedScope]
        and addon.db.templates[self.selectedScope][self.selectedName]
    if self.editingDraft or not record then
        self:NewTemplate()
    else
        self:DrawEditor(savedTemplate(self.selectedScope, self.selectedName, record))
    end
end

--[[-----------------------------------------------------------------------------
Unsaved-changes guard
-------------------------------------------------------------------------------]]

-- True when the editor's name or source differs from what was loaded into
-- it (the saved record, or the defaults of a fresh draft).
function UI:IsEditorDirty()
    if not self.source or not self.nameBox then
        return false
    end
    return self:GetEditorSource() ~= (self.cleanSource or "")
        or (self.nameBox:GetText() or "") ~= (self.cleanName or "")
end

--[[-----------------------------------------------------------------------------
Source tabs (§13.2). The template is ONE source text (self.fullSource); a
mode tab shows and edits only that mode's slice of it (Compiler.SplitModes /
JoinModes), so nothing is stored twice and the All tab is the whole text --
except parked modes (`#MODE NAME OFF`, §5.13), which show only on their own
tab. Slices are re-cut only when the shown tab changes (or while the All
tab is shown), never while a slice is being edited.
-------------------------------------------------------------------------------]]

-- Key of the slice a parked slice follows (its anchor): "" for Base, else
-- the mode's name.
local function sliceKey(segment)
    return segment.kind == "BASE" and "" or segment.name
end

-- Sets allLineMap (the template line of each line shown on the All tab)
-- from the slices in template order, `hidden` marking the parked ones.
function UI:SetAllLineMap(slices, hidden)
    local lineMap, keyParts, line = {}, {}, 0
    for _, slice in ipairs(slices) do
        local count = slice.lineCount
        if hidden[slice] then
            table.insert(keyParts, line .. "+" .. count)
        else
            for offset = 1, count do
                table.insert(lineMap, line + offset)
            end
        end
        line = line + count
    end
    self.allLineMap, self.allLineKey = lineMap, table.concat(keyParts, ",")
end

-- The All tab's text: every slice but the parked ones. Remembers each
-- parked slice with the slice it follows (allParked), for CommitTab to put
-- it back in place, and the template line of each shown line (allLineMap).
-- Both are nil when nothing is parked: the All tab is then the whole text.
-- The parked set is fixed here, when All is shown: a mode switched to OFF
-- while All is shown stays shown until the tab is shown again.
function UI:BuildAllView()
    local segments = addon.Compiler.SplitModes(self.fullSource or "")
    local shown, parked, hidden = {}, {}, {}
    local anchor = ""
    for _, segment in ipairs(segments) do
        if segment.off then
            table.insert(parked, { segment = segment, anchor = anchor })
            hidden[segment] = true
        else
            table.insert(shown, segment)
            anchor = sliceKey(segment)
        end
    end
    if #parked == 0 then
        self.allParked, self.allLineMap, self.allLineKey = nil, nil, nil
        return self.fullSource or ""
    end
    self.allParked = parked
    self:SetAllLineMap(segments, hidden)
    return addon.Compiler.JoinModes(shown)
end

-- Shows the All tab.
function UI:ShowAllTab()
    self.activeTab = TAB_ALL
    self:ShowSourceText(self:BuildAllView())
end

-- Folds the source box's current text back into the full source.
function UI:CommitTab()
    if not self.source then
        return
    end
    local text = self.source:GetText() or ""
    local segment = type(self.activeTab) == "number" and self.modeSegments and self.modeSegments[self.activeTab]
    if segment then
        segment.text = text
        self.fullSource = addon.Compiler.JoinModes(self.modeSegments)
    elseif self.allParked then
        -- Each parked slice goes back after the slice it followed, or at
        -- the end when that slice is gone (renamed or deleted on All).
        local merged, placed, hidden = {}, {}, {}
        local function placeAfter(key)
            for index, entry in ipairs(self.allParked) do
                if not placed[index] and entry.anchor == key then
                    placed[index] = true
                    table.insert(merged, entry.segment)
                    hidden[entry.segment] = true
                end
            end
        end
        local shown = addon.Compiler.SplitModes(text)
        for _, slice in ipairs(shown) do
            table.insert(merged, slice)
            placeAfter(sliceKey(slice))
        end
        for index, entry in ipairs(self.allParked) do
            if not placed[index] then
                table.insert(merged, entry.segment)
                hidden[entry.segment] = true
            end
        end
        self.fullSource = addon.Compiler.JoinModes(merged)
        self:SetAllLineMap(merged, hidden)
    else
        self.fullSource = text
    end
end

-- The whole template source being edited, whatever tab is shown.
function UI:GetEditorSource()
    self:CommitTab()
    return self.fullSource or ""
end

-- Puts `text` into the source box without it counting as a user edit.
function UI:ShowSourceText(text)
    local editing = self.editing
    self.editing = false
    self.source:SetText(text)
    self.editing = editing
end

-- Line number (in the whole template) just before the shown slice.
function UI:TabLineOffset()
    local segment = type(self.activeTab) == "number" and self.modeSegments and self.modeSegments[self.activeTab]
    return segment and (segment.startLine - 1) or 0
end

-- The template line of line `shown` of the source box. On the All tab with
-- parked modes the shown lines skip theirs (allLineMap); a line past the
-- map (just typed at the end) continues from its last entry.
function UI:TemplateLine(shown)
    local lineMap = self.activeTab == TAB_ALL and self.allLineMap
    if lineMap then
        return lineMap[shown] or ((lineMap[#lineMap] or 0) + shown - #lineMap)
    end
    return self:TabLineOffset() + shown
end

-- Rebuilds the tab row from the current slices: All, then (with modes)
-- Base and one tab per mode, then "+ Mode". modeMarks colors a tab green
-- (its mode is the selected branch) or red (an error points into it).
function UI:RefreshTabs()
    if not self.tabStrip then
        return
    end
    local segments = self.modeSegments or {}
    local marks = self.modeMarks or {}
    local function label(text, mark)
        if mark == "error" then
            return "|cffff5555" .. text .. "|r"
        elseif mark == "active" then
            return "|cff40ff40" .. text .. "|r"
        end
        return text
    end
    local tabs = { { value = TAB_ALL, text = "All" } }
    if #segments > 1 then
        for index, segment in ipairs(segments) do
            if segment.kind == "BASE" then
                table.insert(tabs, { value = index, text = label("Base", marks[index]) })
            elseif segment.off and not marks[index] then
                -- Parked (OFF): dimmed, it never compiles.
                table.insert(tabs, { value = index, text = "|cff808080" .. segment.name .. "|r" })
            else
                table.insert(tabs, { value = index, text = label(segment.name, marks[index]) })
            end
        end
    end
    table.insert(tabs, { value = TAB_ADD, text = "+ Mode" })
    local key = {}
    for _, tab in ipairs(tabs) do
        table.insert(key, tostring(tab.value) .. "=" .. tab.text)
    end
    key = table.concat(key, ";")
    if key ~= self.tabKey then
        self.tabKey = key
        self.tabStrip:SetTabs(tabs)
    end
    self.tabStrip:SelectTab(self.activeTab)
end

-- Loads a whole template source into the editor, on the All tab.
function UI:LoadSource(text)
    self.fullSource = text or ""
    self.modeSegments = addon.Compiler.SplitModes(self.fullSource)
    self.modeMarks = {}
    self.tabKey = nil
    self:ResetAutoWatches(self.fullSource)
    self:ShowAllTab()
    self:RefreshTabs()
end

-- Switches the source box to another tab (TAB_ALL or a slice index).
function UI:SelectTab(value, tabButton)
    if value == TAB_ADD then
        self:OpenModeMenu(tabButton)
        if self.tabStrip then
            self.tabStrip:SelectTab(self.activeTab)
        end
        return
    end
    self:CommitTab()
    self.modeSegments = addon.Compiler.SplitModes(self.fullSource)
    local segment = type(value) == "number" and self.modeSegments[value]
    if segment and #self.modeSegments > 1 then
        self.activeTab = value
        self:ShowSourceText(segment.text)
    else
        self:ShowAllTab()
    end
    self.highlightKey = nil
    self:RefreshTabs()
    self:RefreshStatus(self:RefreshPreviewFromSource())
end

-- True when `source` already has `#WATCH <watch>` (with or without a
-- modifier) in its metadata.
local function hasWatch(source, watch)
    for line in ((source or "") .. "\n"):gmatch("(.-)\n") do
        local name = line:match("^%s*#WATCH%s+(%S+)")
        if name and string.upper(name) == watch then
            return true
        end
    end
    return false
end

local function splitSourceLines(source)
    local lines = {}
    for line in ((source or "") .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end
    return lines
end

local function findDefaultLine(lines)
    for index, line in ipairs(lines) do
        if line:match("^%s*#DEFAULT%s*$") then
            return index
        end
    end
end

-- Inserts "#WATCH <watch>" into `lines` after the last metadata line above
-- #DEFAULT (line `defaultLine`), leaving exactly one blank line between the
-- #WATCH block and #DEFAULT. Returns #DEFAULT's new line number.
local function insertWatchLine(lines, defaultLine, watch)
    local last = defaultLine - 1
    while last > 0 and lines[last]:match("^%s*$") do
        last = last - 1
    end
    for _ = last + 1, defaultLine - 1 do
        table.remove(lines, last + 1)
    end
    table.insert(lines, last + 1, "#WATCH " .. watch)
    table.insert(lines, last + 2, "")
    return last + 3
end

local function copySet(set)
    local copy = {}
    for key in pairs(set or {}) do
        copy[key] = true
    end
    return copy
end

-- Automatic #WATCH: a condition that needs a #WATCH the template lacks gets
-- it added once its line is finished; without it the condition's branch
-- could only be picked on login or save. Never added back once the player
-- removes it. A watch already missing when the template was loaded waits
-- for the first edit (or the save): merely opening a template never
-- changes it.
function UI:ResetAutoWatches(source)
    self.autoWatchSkip = {}
    self.autoWatchSeen = {}
    self.autoWatchDeferred = {}
    local parsed = addon.Compiler.Parse(source or "")
    if not parsed then
        return
    end
    for watch in pairs(addon.Compiler.NeededWatches(parsed)) do
        if not parsed.watchSet[watch] then
            self.autoWatchDeferred[watch] = true
        end
    end
    self.autoWatchSeen = copySet(parsed.watchSet)
end

-- Line number (in the whole template) the cursor is on.
function UI:CursorLine()
    local offset = self.source:GetCursorOffset()
    local _, breaks = (self.source:GetText() or ""):sub(1, offset):gsub("\n", "")
    return self:TemplateLine(breaks + 1)
end

-- Adds the missing #WATCHes the template's finished lines need. A line is
-- finished once the cursor has left it, so a condition still being typed
-- adds nothing; with `all` (saving) every line counts. While the cursor is
-- in the metadata nothing is added, so lines never move under it.
function UI:AutoAddWatches(all)
    if not self.source or not self.editing then
        return
    end
    local source = self:GetEditorSource()
    local parsed = addon.Compiler.Parse(source)
    if not parsed then
        return
    end
    local skip = self.autoWatchSkip or {}
    self.autoWatchSkip = skip
    for watch in pairs(self.autoWatchSeen or {}) do
        if not parsed.watchSet[watch] then
            skip[watch] = true
        end
    end
    self.autoWatchSeen = copySet(parsed.watchSet)
    if all or self:IsEditorDirty() then
        self.autoWatchDeferred = {}
    end
    local deferred = self.autoWatchDeferred or {}
    local lines = splitSourceLines(source)
    local defaultLine = findDefaultLine(lines)
    if not defaultLine then
        return
    end
    local cursorLine = self:CursorLine()
    local typing = not all and self.source.editBox:HasFocus()
    if typing and cursorLine <= defaultLine then
        return
    end
    local missing = {}
    for watch, needLines in pairs(addon.Compiler.NeededWatches(parsed)) do
        if not parsed.watchSet[watch] and not skip[watch] and not deferred[watch] then
            local first
            for line in pairs(needLines) do
                if not (typing and line == cursorLine) and (not first or line < first) then
                    first = line
                end
            end
            if first then
                table.insert(missing, { watch = watch, line = first })
            end
        end
    end
    if #missing == 0 then
        return
    end
    table.sort(missing, function(a, b)
        if a.line ~= b.line then
            return a.line < b.line
        end
        return a.watch < b.watch
    end)
    local oldCount = #lines
    for _, entry in ipairs(missing) do
        defaultLine = insertWatchLine(lines, defaultLine, entry.watch)
        self.autoWatchSeen[entry.watch] = true
    end
    local updated = table.concat(lines, "\n")
    local lineShift, byteShift = #lines - oldCount, #updated - #source
    local cursor = self.source:GetCursorOffset()
    if cursorLine < defaultLine - lineShift then
        -- Cursor above the inserted lines (only when not typing): stays put.
        lineShift, byteShift = 0, 0
    end
    self.fullSource = updated
    local segment = type(self.activeTab) == "number" and self.modeSegments and self.modeSegments[self.activeTab]
    local shown = updated
    if segment then
        self.modeSegments = addon.Compiler.SplitModes(updated)
        if segment.kind == "MODE" then
            -- The metadata is in Base: the shown mode slice is unchanged.
            return
        end
        shown = self.modeSegments[self.activeTab].text
    elseif self.allParked then
        -- All: the inserted lines are in Base, which the box shows first
        -- and whole, so swap the box's Base for the updated one.
        local oldBase = addon.Compiler.SplitModes(source)[1].text
        shown = addon.Compiler.SplitModes(updated)[1].text
            .. (self.source:GetText() or ""):sub(#oldBase + 1)
    end
    local editing = self.editing
    self.editing = false
    self.source:ReplaceText(shown, cursor + byteShift, lineShift)
    self.editing = editing
    if self.allParked and not segment then
        self:CommitTab() -- moves the All tab's line map down past the new lines
    end
    self.highlightKey = nil
end

-- Appends a new mode (a free name based on `name`) and shows its tab.
-- `watch`, when given, is added to the metadata if the template lacks it
-- (a preset's condition needs it to ever update).
function UI:AddMode(name, condition, watch)
    if not self.source then
        return
    end
    local source = self:GetEditorSource()
    local used = {}
    for _, segment in ipairs(addon.Compiler.SplitModes(source)) do
        if segment.kind == "MODE" then
            used[segment.name] = true
        end
    end
    local base = string.upper(name)
    local candidate, suffix = base, 2
    while used[candidate] do
        candidate = base .. "_" .. suffix
        suffix = suffix + 1
    end
    local lines = splitSourceLines(source)
    local defaultLine = findDefaultLine(lines)
    if not defaultLine then
        table.insert(lines, "#DEFAULT")
        defaultLine = #lines
    end
    if watch and not hasWatch(source, watch) then
        insertWatchLine(lines, defaultLine, watch)
    end
    while #lines > 0 and lines[#lines]:match("^%s*$") do
        table.remove(lines)
    end
    table.insert(lines, "")
    table.insert(lines, "#MODE " .. candidate .. " " .. condition)
    table.insert(lines, "")
    self.fullSource = table.concat(lines, "\n")
    self:ShowAllTab()
    local segments = addon.Compiler.SplitModes(self.fullSource)
    for index, segment in ipairs(segments) do
        if segment.kind == "MODE" and segment.name == candidate then
            self:SelectTab(index)
            break
        end
    end
    self:SetStatus("Added mode " .. candidate .. ".", OK_COLOR)
    return candidate
end

-- Runs continue() now, or -- when the editor has unsaved edits -- after the
-- unsaved-changes popup: Save (only if the save succeeds), Discard, or
-- Escape, which keeps editing and runs cancel() (e.g. to put a dropdown
-- back).
function UI:Guard(continue, cancel)
    if not self:IsEditorDirty() then
        continue()
        return
    end
    self.guardContinue, self.guardCancel = continue, cancel
    local name = (not self.editingDraft and self.selectedName) or (self.nameBox and self.nameBox:GetText()) or ""
    Dialog:Show("WMC_DISCARD_CHANGES", name)
end

local function takeGuard(self)
    local continue, cancel = self.guardContinue, self.guardCancel
    self.guardContinue, self.guardCancel = nil, nil
    return continue, cancel
end

-- [Save]: save (Create for a draft); go on only if that worked. A failed
-- save (invalid or taken name...) leaves the editor as it is, with the
-- error in the status line, and runs cancel() like Escape.
function UI:GuardSave()
    local continue, cancel = takeGuard(self)
    if self:SaveSelected() then
        if continue then
            continue()
        end
    elseif cancel then
        cancel()
    end
end

-- [Discard]: go on without saving.
function UI:GuardDiscard()
    local continue = takeGuard(self)
    if continue then
        continue()
    end
end

-- Escape: keep editing.
function UI:GuardCancel()
    local _, cancel = takeGuard(self)
    if cancel then
        cancel()
    end
end

--[[-----------------------------------------------------------------------------
Template list
-------------------------------------------------------------------------------]]

-- Adds one template row to the list.
local function addTemplateRow(self, scope, name, record, indent)
    local id = addon:TemplateId(scope, name)
    local runtime = addon.runtime.byId[id]
    local disabled = record.enabled == false
    local hasError = runtime and runtime.error and true or false
    local isDirty = runtime and runtime.dirty and true or false
    local isSelected = self.selectedName == name

    local row = AceGUI:Create("WMC-ListRow")
    row:SetFullWidth(true)
    row:SetIndent(indent)
    local classCoords = scope ~= "GENERAL" and classIconCoords(scope)
    if record.icon then
        row:SetRowIcon(record.icon)
    elseif classCoords then
        row:SetRowIcon(CLASS_ICON, classCoords)
    else
        row:SetRowIcon(nil) -- nil shows the black-square placeholder
    end
    row:SetText(disabled and (name .. " (off)") or name)
    if disabled then
        row:SetTextColor(0.5, 0.5, 0.5)
    elseif isDirty then
        row:SetTextColor(1, 1, 0.5)
    else
        row:SetTextColor(1, 1, 1)
    end
    row:SetRowBackground(addon.TemplateRowColor(scope, hasError, isSelected, disabled))
    row:SetSelected(isSelected)
    row:SetError(hasError)
    if isSelected then
        self.selectedRow = row
    end
    local hoverColor = addon.ClassColor(scope)
    if hoverColor then
        row:SetHoverColor(hoverColor.r, hoverColor.g, hoverColor.b)
    end -- GENERAL scope: leave the default white hover from OnAcquire
    row:SetCallback("OnClick", function()
        if self.selectedName == name and self.selectedScope == scope and not self.editingDraft then
            return -- already open; don't prompt to discard our own edits
        end
        self:Guard(function()
            self:Select(scope, name)
        end)
    end)
    row:SetCallback("OnIconClick", function()
        self:PickIconFor(scope, name)
    end)
    -- Its key here at the row's end; a right-click binds one (KeyPrompt.lua).
    local id = addon:TemplateId(scope, name)
    local key, level = addon.Keys:KeyFor("template", id)
    row:SetKeyText(key and addon.Keys.ShortText(key))
    row:SetCallback("OnRightClick", function()
        addon.KeyPrompt:Open("template", id, name)
    end)
    if key then
        row:SetCallback("OnEnter", function(widget)
            local Tooltip = addon.Tooltip
            Tooltip:SetOwner(widget.frame, "ANCHOR_RIGHT")
            Tooltip:SetText(name)
            Tooltip:AddLine("Key: " .. addon.Keys.KeyText(key) .. " (" .. addon.Keys.LevelName(level) .. ")")
            Tooltip:AddLine("Right-click to change it.", 0.6, 0.6, 0.6)
            Tooltip:Show()
        end)
        row:SetCallback("OnLeave", function()
            addon.Tooltip:Hide()
        end)
    end
    self.templateScroll:AddChild(row)
end

-- Adds one category header row (collapsible, right-click menu) or, when
-- name is nil, the non-collapsible "Uncategorized" section header.
-- `forceOpen` (search active) shows it expanded without changing the
-- stored collapsed state.
local function addCategoryRow(self, scope, name, count, collapsed, forceOpen)
    local row = AceGUI:Create("WMC-ListRow")
    row:SetFullWidth(true)
    row:SetRowIcon(false)
    if name then
        row:SetText(name .. "  |cff808080(" .. count .. ")|r")
        row:SetTextColor(1, 0.82, 0)
        if forceOpen then
            row:SetExpanded(nil)
        else
            row:SetExpanded(not collapsed)
            row:SetCallback("OnToggle", function()
                addon:SetCategoryCollapsed(scope, name, not collapsed)
            end)
            row:SetCallback("OnClick", function()
                addon:SetCategoryCollapsed(scope, name, not collapsed)
            end)
        end
        row:SetCallback("OnRightClick", function()
            self:OpenCategoryMenu(name)
        end)
    else
        row:SetText("Uncategorized" .. "  |cff808080(" .. count .. ")|r")
        row:SetTextColor(0.7, 0.7, 0.7)
        row:SetExpanded(nil)
    end
    self.templateScroll:AddChild(row)
end

-- A template's name, or with inText its source too, holds the filter
-- (plain text, any case).
local function matchesFilter(name, record, filter, inText)
    if filter == "" then
        return true
    end
    filter = string.lower(filter)
    return string.lower(name):find(filter, 1, true) ~= nil
        or (inText and string.lower(record.source or ""):find(filter, 1, true) ~= nil)
end

-- Scroll position of the template list, in pixels from the top. The
-- ScrollFrame keeps it in status.offset and re-derives the scrollbar from it
-- on its deferred FixScroll; rebuilding the rows can reset it to 0 on the
-- way, so RefreshList saves it first and restores it after.
local function listScrollStatus(scroll)
    return scroll.status or scroll.localstatus
end

function UI:RefreshList()
    if not self.templateScroll or not addon.db then
        return
    end
    local scroll = self.templateScroll
    local status = listScrollStatus(scroll)
    local keepOffset = status and status.offset or 0
    local center = self.centerOnRefresh
    self.centerOnRefresh = nil
    self.selectedRow = nil
    scroll:ReleaseChildren()
    local scope = self.selectedScope
    local values = addon.db.templates[scope] or {}
    local categories = addon.db.categories and addon.db.categories[scope]
    local filter = self.filter or ""
    local searching = filter ~= ""
    local inText = addon.db.settings.searchInText == true

    local byCategory, uncategorized = {}, {}
    for name, record in pairs(values) do
        if matchesFilter(name, record, filter, inText) then
            local category = record.category
            if category and categories and categories[category] then
                byCategory[category] = byCategory[category] or {}
                table.insert(byCategory[category], name)
            else
                table.insert(uncategorized, name)
            end
        end
    end
    table.sort(uncategorized)

    local categoryNames = categories and sortedKeys(categories) or {}
    local hasCategories = #categoryNames > 0

    for _, category in ipairs(categoryNames) do
        local members = byCategory[category] or {}
        -- While searching, categories without a match are hidden and the
        -- rest are shown open.
        if not searching or #members > 0 then
            table.sort(members)
            local collapsed = categories[category].collapsed and not searching
            addCategoryRow(self, scope, category, #members, categories[category].collapsed, searching)
            if not collapsed then
                for _, name in ipairs(members) do
                    addTemplateRow(self, scope, name, values[name], 16)
                end
            end
        end
    end
    if #uncategorized > 0 then
        if hasCategories then
            addCategoryRow(self, scope, nil, #uncategorized)
        end
        for _, name in ipairs(uncategorized) do
            addTemplateRow(self, scope, name, values[name], 0)
        end
    end
    self:RestoreListScroll(center and self.selectedRow or nil, keepOffset)
end

-- After a rebuild: centre `row` in the visible part of the list when given
-- (a template was just selected), otherwise keep the previous offset.
-- FixScroll clamps the offset to the content and moves the scrollbar; the
-- deferred FixScroll queued after layout reads the same offset.
function UI:RestoreListScroll(row, keepOffset)
    local scroll = self.templateScroll
    local status = listScrollStatus(scroll)
    if not status then
        return
    end
    local offset = keepOffset or 0
    if row then
        local top = 0
        for _, child in ipairs(scroll.children or {}) do
            if child == row then
                break
            end
            top = top + (child.frame:GetHeight() or 0)
        end
        local viewHeight = scroll.scrollframe and scroll.scrollframe:GetHeight() or 0
        offset = top + (row.frame:GetHeight() or 0) / 2 - viewHeight / 2
    end
    status.offset = math.max(0, math.floor(offset))
    -- Sizes are only reliable while the window is shown; when hidden, the
    -- stored offset is applied by the ScrollFrame's own FixScroll once shown.
    if scroll.FixScroll and self.window and self.window.frame:IsShown() then
        scroll:FixScroll()
    end
end

-- Dropdown items for the editor's category selector: "None" plus the
-- selected scope's categories (alphabetical).
function UI:BuildCategoryList()
    local list, order = {}, {}
    list[NO_CATEGORY] = "|cff808080None|r"
    table.insert(order, NO_CATEGORY)
    local categories = addon.db and addon.db.categories[self.selectedScope]
    for _, category in ipairs(categories and sortedKeys(categories) or {}) do
        list[category] = category
        table.insert(order, category)
    end
    return list, order
end

-- Rebuilds the editor's category dropdown after category CRUD without
-- touching the rest of the editor (unsaved source edits stay intact).
function UI:RefreshCategoryDropdown()
    local dropdown = self.categoryDropdown
    if not dropdown then
        return
    end
    local list, order = self:BuildCategoryList()
    dropdown:SetList(list, order)
    local current
    if self.editingDraft then
        current = self.draftCategory
    else
        local record = addon.db and addon.db.templates[self.selectedScope]
            and addon.db.templates[self.selectedScope][self.selectedName]
        current = record and record.category
    end
    if current and not list[current] then
        current = nil
    end
    dropdown:SetValue(current or NO_CATEGORY)
end

function UI:UpdateEditorIcon()
    if not self.iconWidget then
        return
    end
    local icon
    if self.editingDraft then
        icon = self.draftIcon
    else
        local record = addon.db and addon.db.templates[self.selectedScope]
            and addon.db.templates[self.selectedScope][self.selectedName]
        icon = record and record.icon
    end
    local scope = self.selectedScope
    local classCoords = scope and scope ~= "GENERAL" and classIconCoords(scope)
    if icon then
        self.iconWidget:SetImage(icon, ICON_ZOOM, 1 - ICON_ZOOM, ICON_ZOOM, 1 - ICON_ZOOM)
        self.iconWidget.image:SetVertexColor(1, 1, 1, 1)
    elseif classCoords then
        self.iconWidget:SetImage(CLASS_ICON, unpack(classCoords))
        self.iconWidget.image:SetVertexColor(1, 1, 1, 1)
    else
        self.iconWidget:SetImage(BLACK_SQUARE)
        self.iconWidget.image:SetVertexColor(0.02, 0.02, 0.02, 1)
    end
end

function UI:PickIconFor(scope, name)
    local record = addon.db and addon.db.templates[scope] and addon.db.templates[scope][name]
    if not record then
        return
    end
    addon.IconPicker:Open(record.icon, function(icon)
        addon:SetTemplateIcon(scope, name, icon)
        if self.selectedScope == scope and self.selectedName == name and not self.editingDraft then
            self:UpdateEditorIcon()
        end
    end, self.window and self.window.frame)
end

function UI:PickEditorIcon()
    if self.editingDraft then
        addon.IconPicker:Open(self.draftIcon, function(icon)
            self.draftIcon = icon
            self:UpdateEditorIcon()
        end, self.window and self.window.frame)
    elseif self.selectedName then
        self:PickIconFor(self.selectedScope, self.selectedName)
    end
end

-- Loads a saved template into the editor. Internal: callers that act on a
-- player's click go through UI:Guard first.
function UI:Select(scope, name)
    local record = addon.db and addon.db.templates[scope] and addon.db.templates[scope][name]
    if not record then
        return
    end
    -- The list rebuild that follows centres this template's row.
    self.centerOnRefresh = true
    -- Just saved (created, re-saved or renamed) from this editor: it already
    -- shows exactly this record, so update it in place. Rebuilding would
    -- destroy the Save button under the cursor mid-click (no press/hover
    -- feedback) and move keyboard focus.
    if self.source and self.nameBox and scope == self.selectedScope
        and self.nameBox:GetText() == name and self:GetEditorSource() == (record.source or "") then
        self:AdoptSaved(scope, name, record)
        return
    end
    self.selectedScope = scope
    self.selectedName = name
    if self.scopeDropdown then
        self.scopeDropdown:SetValue(scope)
    end
    self:DrawEditor(savedTemplate(scope, name, record))
    self:RefreshList()
end

-- Turns the current editor contents into "the saved record" without
-- redrawing: heading, Save label, enabled actions, and the clean snapshot
-- the unsaved-changes guard compares against.
function UI:AdoptSaved(scope, name, record)
    self.selectedScope = scope
    self.selectedName = name
    self.editingDraft = false
    self.cleanName = name
    self.cleanSource = record.source or ""
    self.enabledValue = record.enabled ~= false
    if self.heading then
        self.heading:SetText(classLabel(scope) .. "  |cffffffff/|r  " .. name)
    end
    if self.saveButton then
        self.saveButton:SetText("Save")
    end
    if self.moveDropdown then
        self.moveDropdown:SetDisabled(false)
        self.moveDropdown:SetValue(scope)
    end
    for _, button in ipairs(self.actionButtons or {}) do
        button:SetDisabled(false)
    end
    self:RefreshSourceIcons()
    self:RefreshCategoryDropdown()
    self:UpdateEditorIcon()
    self:RefreshList()
    self:RefreshSelected()
end

-- The guide's "Try it" (Guide.lua): opens `source` as a new, unsaved
-- GENERAL template (so any class can try it), named from `base`, with the
-- Preview-as line set to `state` (nil: the live state). Opens the window
-- if needed and goes through the unsaved-changes guard.
function UI:OpenExample(source, state, base)
    if not self.window then
        self:Initialize()
    end
    if not self.window.frame:IsShown() then
        self:Toggle()
    end
    -- Above the guide, so the guard's dialog is not hidden under it.
    if self.window.frame.Raise then
        self.window.frame:Raise()
    end
    self:Guard(function()
        local scope = "GENERAL"
        self.selectedScope = scope
        self.selectedName = nil
        if self.scopeDropdown then
            self.scopeDropdown:SetValue(scope)
        end
        self:DrawEditor({
            name = addon:UniqueName(scope, base) or DRAFT_NAME,
            scope = scope,
            source = source,
            enabled = true,
            isDraft = true,
        })
        self:RefreshList()
        if state then
            self:SetPreviewAs(state)
        end
    end)
end

-- The tool rail: icon buttons stacked in the strip between the editor's
-- scrollbar and the column (the main window's right edge), outside the
-- editor's scroll area, so they stay put while it scrolls. The first lines
-- up with the editor's heading row (34 units). The content ends at 927 and
-- the column's left side is at least 962 down to y 245 (frame preview,
-- alpha > 32): a 30 unit strip, room for six.
--   book: the guide (Arcanum);
--   keys: the key list (KeyList.lua);
--   + / -: the window's size steps.
-- What acts on the open template (Make Macro, Key Binding, Send, Mute
-- Lines) is in its source box instead (UI:SourceIcons).
local RAIL_LEFT = 6       -- units right of the content's right edge
local RAIL_GAP = 5
UI.RAIL_GAP = RAIL_GAP
local HEADING_ROW = 34

-- The window size steps (settings.windowSize, Theme.WINDOW_SIZES).
local SIZE_STEPS = { "smaller", "normal", "larger" }
local SIZE_NAMES = { smaller = "Smaller", normal = "Normal", larger = "Larger" }

-- A rail button's art (normal, hover glow, pressed, disabled).
local setRailPiece = Theme.SetRailPiece

-- title, text: strings, or functions returning them (read on each hover).
local function railButton(parent, piece, title, text, onClick)
    local button = CreateFrame("Button", nil, parent)
    local width, height = Theme.PieceSize(piece)
    button:SetWidth(width)
    button:SetHeight(height)
    setRailPiece(button, piece)
    Theme.HideHoverWhileHeld(button)
    button:SetScript("OnClick", function()
        if PlaySound then
            PlaySound("igMainMenuOption")
        end
        onClick()
    end)
    -- A disabled button still gets OnEnter: the tooltip says why.
    button:SetScript("OnEnter", function(frame)
        local tooltip = addon.Tooltip
        tooltip:SetOwner(frame, "ANCHOR_LEFT")
        tooltip:SetText(type(title) == "function" and title() or title)
        tooltip:AddLine(type(text) == "function" and text() or text, nil, nil, nil, true)
        tooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        addon.Tooltip:Hide()
    end)
    return button
end

-- The template source box's icons, as the bank editor's: Make Macro, Key
-- Binding, Send and Mute Lines, down its top right corner. Built once; the box (pooled, rebuilt with the editor) carries
-- them while it's the editor's (TextArea:SetOverlay).
local SOURCE_ICON_INSET = 6     -- from the box's top and right edges, as the bank editor's

function UI:SourceIcons()
    if self.sourceIcons then
        return self.sourceIcons
    end
    local holder = CreateFrame("Frame", nil, UIParent)
    holder:Hide()
    local y, widest = 0, 0
    local function icon(piece, title, text, onClick)
        local button = railButton(holder, piece, title, text, onClick)
        local width, height = Theme.PieceSize(piece)
        button:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, -y)
        y = y + height + RAIL_GAP
        widest = math.max(widest, width)
        return button
    end
    local function saved()
        return not self.editingDraft and self.selectedName ~= nil
    end
    self.macroButton = icon("rail-macro", "Make Macro",
        function()
            return saved() and "A macro that clicks this template, on your cursor to drop on an action bar."
                or "Save the template first."
        end,
        function()
            if saved() then
                self:OpenMacroMenu(self.macroButton)
            end
        end)
    self.keyButton = icon("rail-key", "Key Binding",
        function()
            if not saved() then
                return "Save the template first."
            end
            local key, level = addon.Keys:KeyFor("template", addon:TemplateId(self.selectedScope, self.selectedName))
            return (key and ("Now " .. addon.Keys.KeyText(key) .. " (" .. addon.Keys.LevelName(level) .. "). ")
                or "") .. "A key that clicks this template, no macro needed. Also: right-click it in the list."
        end,
        function()
            if saved() then
                addon.KeyPrompt:Open("template", addon:TemplateId(self.selectedScope, self.selectedName),
                    self.selectedName, self.window and self.window.frame)
            end
        end)
    self.sendButton = icon("rail-send", "Send Template",
        function()
            return saved() and "Send this template to another player with Quintessence. They're asked first."
                or "Save the template first."
        end,
        function() self:SendSelected() end)
    self.muteButton = icon("rail-mute", "Mute Lines",
        "Switch lines off in one of this template's modes, in every template (/qmc mute).",
        function() addon.MuteDialog:Open(self:GetEditorSource(), self.window and self.window.frame) end)
    holder:SetWidth(widest)
    holder:SetHeight(y - RAIL_GAP)
    holder.wmcWidth = widest
    self.sourceIcons = holder
    return holder
end

-- Make Macro, Key Binding and Send need a saved template: grey on a new one.
function UI:RefreshSourceIcons()
    local saved = not self.editingDraft and self.selectedName ~= nil
    for _, button in ipairs({ self.macroButton, self.keyButton, self.sendButton }) do
        if saved then
            button:Enable()
        else
            button:Disable()
        end
    end
end

function UI:BuildRail(window)
    local rail = CreateFrame("Frame", nil, window.content)
    local width, height = Theme.PieceSize("rail-book")
    rail:SetWidth(width)
    rail:SetHeight(1)
    rail:SetPoint("TOPLEFT", window.content, "TOPRIGHT", RAIL_LEFT,
        -(Theme.EditorTop("main") + math.floor((HEADING_ROW - height) / 2)))
    self.rail = rail
    self.bookButton = railButton(rail, "rail-book", "Arcanum", "The in-game guide: how to write templates.",
        function() addon.Guide:ToggleFor("main", "compiler") end)
    self.keysButton = railButton(rail, "rail-keys", "Key Bindings",
        "Every key bound to a template or a bank macro, as they apply on this character (/qmb keys)."
            .. " Right-click a template to bind one.",
        function() addon.KeyList:Open(window.frame) end)
    local buttons = { self.bookButton, self.keysButton }
    local function sizeText(delta)
        return function()
            local size = SIZE_STEPS[self:SizeStep()]
            local text = "Now " .. SIZE_NAMES[size] .. (size == "normal" and " (the sharpest)." or ".")
            if not SIZE_STEPS[self:SizeStep() + delta] then
                text = text .. (delta > 0 and " It's the largest size." or " It's the smallest size.")
            end
            return text .. " Also /qmc size."
        end
    end
    self.largerButton = railButton(rail, "rail-larger", "Larger Window", sizeText(1),
        function() self:StepWindowSize(1, self.largerButton) end)
    self.smallerButton = railButton(rail, "rail-smaller", "Smaller Window", sizeText(-1),
        function() self:StepWindowSize(-1, self.smallerButton) end)
    -- no wider gap before them: the column's pipe bend comes in below
    -- (it covered the - plate's corner)
    table.insert(buttons, self.largerButton)
    table.insert(buttons, self.smallerButton)
    local y = 0
    for _, button in ipairs(buttons) do
        button:SetPoint("TOP", rail, "TOP", 0, -y)
        y = y + button:GetHeight() + RAIL_GAP
    end
    self:RefreshRail()
end

function UI:SizeStep()
    local size = addon.db and addon.db.settings.windowSize or "normal"
    for index, step in ipairs(SIZE_STEPS) do
        if step == size then
            return index
        end
    end
    return 2
end

-- One size up (delta 1) or down. The clicked button stays where it is on
-- screen (under the cursor, for the next click): the window grows or
-- shrinks around it.
function UI:StepWindowSize(delta, button)
    local size = SIZE_STEPS[self:SizeStep() + delta]
    if not size then
        return
    end
    local window = self.window
    local frame = window.frame
    local left, top = frame:GetLeft(), frame:GetTop()
    local buttonLeft, buttonTop = button:GetLeft(), button:GetTop()
    local before = frame:GetEffectiveScale()
    addon:SetWindowSize(size)
    local after = frame:GetEffectiveScale()
    if left and top and buttonLeft and buttonTop and after > 0 then
        local status = window.status or window.localstatus
        status.left = buttonLeft * before / after - (buttonLeft - left)
        status.top = buttonTop * before / after - (buttonTop - top)
        status.scale = frame:GetScale()
        window:ApplyStatus()
    end
    if addon.Tooltip:IsOwned(button) then
        button:GetScript("OnEnter")(button)
    end
end

-- The send dialog for the selected template (its saved version: unsaved
-- edits are saved or discarded first), to the target when it's a player,
-- else the last recipient.
function UI:SendSelected()
    if self.editingDraft or not self.selectedName then
        self:SetStatus("Save the template first, then send it.", NOTE_COLOR)
        return
    end
    self:Guard(function()
        local scope, name = self.selectedScope, self.selectedName
        local target = UnitIsPlayer and UnitIsPlayer("target") and not UnitIsUnit("target", "player")
            and UnitName("target") or (addon.db.settings.lastRecipient or "")
        Dialog:Show("WMC_SEND_TEMPLATE", name, { scope = scope, name = name, target = target })
    end)
end

-- The size steps grey out at the ends.
function UI:RefreshRail()
    local step = self:SizeStep()
    for button, delta in pairs({ [self.largerButton or false] = 1, [self.smallerButton or false] = -1 }) do
        if button then
            if SIZE_STEPS[step + delta] then
                button:Enable()
            else
                button:Disable()
            end
        end
    end
end

function UI:NewTemplate()
    self.selectedName = nil
    self.draftIcon = nil
    self.draftCategory = nil
    self:DrawEditor({
        name = DRAFT_NAME,
        scope = self.selectedScope or currentClass(),
        source = DRAFT_SOURCE,
        enabled = true,
        isDraft = true,
    })
    self:RefreshList()
end

--[[-----------------------------------------------------------------------------
Editor
-------------------------------------------------------------------------------]]
function UI:DrawEditor(template)
    if not self.editor then
        return
    end
    self.editing = false
    self.editorDrawnHidden = not (self.window and self.window.frame:IsShown())
    self.editingDraft = template.isDraft and true or false
    self.draftIcon = template.icon
    self.draftCategory = template.category
    self.cleanName = template.name or ""
    self.cleanSource = template.source or ""
    -- Same for the edit boxes whose height was matched to a button.
    restoreEditBoxHeight(self.nameBox)
    restoreEditBoxHeight(self.previewAsBox)
    self.alignJob = nil
    self.previewAlignJob = nil
    self.editorLabelHeight = nil
    self.editor:ReleaseChildren()

    local heading = AceGUI:Create("WMC-Title")
    self.heading = heading
    heading:SetText(template.isDraft and ("New " .. classLabel(template.scope) .. " template")
        or (classLabel(template.scope) .. "  |cffffffff/|r  " .. template.name))
    heading:SetFullWidth(true)
    self.editor:AddChild(heading)

    local nameRow = AceGUI:Create("SimpleGroup")
    nameRow:SetLayout((AceGUI.GetLayout and AceGUI:GetLayout("WMC-Flow")) and "WMC-Flow" or "Flow")
    nameRow:SetFullWidth(true)
    self.editor:AddChild(nameRow)
    stripGroupSkin(nameRow)

    -- The template's icon in a brass slot; clicking it opens the picker.
    local iconWidget = AceGUI:Create("WMC-Icon")
    iconWidget:SetImageSize(24, 24)
    iconWidget:SetCallback("OnClick", function() self:PickEditorIcon() end)
    nameRow:AddChild(iconWidget)
    self.iconWidget = iconWidget
    nameRow:AddChild(makeGap(6))

    local nameBox = AceGUI:Create("WMC-EditBox")
    nameBox:SetLabel("Button name  (/click WMC_" .. (template.name or "") .. ")")
    nameBox:SetWidth(268)
    nameBox:SetText(template.name or "")
    nameBox:SetCallback("OnTextChanged", function(_, _, value)
        if self.editing then
            nameBox:SetLabel("Button name  (/click WMC_" .. value .. ")")
            reapplyBoxHeight(nameBox)
            self:RequestRefresh()
        end
    end)
    -- Enter creates/saves; the box's own "Okay" button is not needed.
    nameBox:DisableButton(true)
    nameBox:SetCallback("OnEnterPressed", function()
        nameBox:ClearFocus()
        self:SaveSelected()
    end)
    nameRow:AddChild(nameBox)
    self.nameBox = nameBox

    -- Save, Duplicate and Export; the box and buttons end where the
    -- Preview-as row's Live button does (612).
    local saveButton = makeButton(template.isDraft and "Create" or "Save", 96, function() self:SaveSelected() end)
    local duplicateButton = makeButton("Duplicate", 96, function() self:DuplicateSelected() end)
    local exportButton = makeButton("Export", 96, function() self:ExportSelected() end)
    local rowButtons = { saveButton, duplicateButton, exportButton }
    self.actionButtons = { duplicateButton, exportButton }
    for _, button in ipairs(rowButtons) do
        alignWithEditBox(button, nameBox)
        nameRow:AddChild(button)
    end
    for _, button in ipairs(self.actionButtons) do
        button:SetDisabled(template.isDraft and true or false)
    end
    self.nameRow = nameRow
    self.saveButton = saveButton
    -- Each button is glued to the name box's visible box after every layout
    -- (anchorToBox); their Flow offsets above are only estimates for the
    -- row's height. The job just makes the box a button's height (24).
    nameRow:SetUserData("wmcOneRow", true)
    nameRow:SetUserData("wmcAfterLayout", function()
        anchorToBox(nameBox, rowButtons)
    end)
    anchorToBox(nameBox, rowButtons)
    self.alignJob = { editBox = nameBox, boxHeight = 24 }
    scheduleAlignment(self.alignJob, self.previewAlignJob)

    local metaRow = AceGUI:Create("SimpleGroup")
    metaRow:SetLayout((AceGUI.GetLayout and AceGUI:GetLayout("WMC-Flow")) and "WMC-Flow" or "Flow")
    metaRow:SetUserData("wmcOneRow", true)
    metaRow:SetFullWidth(true)
    self.editor:AddChild(metaRow)
    stripGroupSkin(metaRow)

    local categoryDropdown = AceGUI:Create("WMC-Dropdown")
    categoryDropdown:SetLabel("Category")
    categoryDropdown:SetWidth(185)
    local categoryList, categoryOrder = self:BuildCategoryList()
    categoryDropdown:SetList(categoryList, categoryOrder)
    categoryDropdown:SetValue(template.category or NO_CATEGORY)
    categoryDropdown:SetCallback("OnValueChanged", function(_, _, value)
        local category = value ~= NO_CATEGORY and value or nil
        if self.editingDraft then
            self.draftCategory = category
        else
            addon:SetTemplateCategory(self.selectedScope, self.selectedName, category)
        end
    end)
    metaRow:AddChild(categoryDropdown)
    self.categoryDropdown = categoryDropdown
    metaRow:AddChild(makeGap(16))

    -- Move a saved template to another class (or GENERAL).
    local moveDropdown = AceGUI:Create("WMC-Dropdown")
    moveDropdown:SetLabel("Move to")
    moveDropdown:SetWidth(185)
    local moveList, moveOrder = {}, {}
    for _, class in ipairs(CLASS_ORDER) do
        moveList[class] = classLabel(class)
        table.insert(moveOrder, class)
    end
    moveDropdown:SetList(moveList, moveOrder)
    moveDropdown:SetValue(template.scope)
    moveDropdown:SetDisabled(template.isDraft and true or false)
    moveDropdown:SetCallback("OnValueChanged", function(_, _, value)
        self:MoveSelected(value)
    end)
    metaRow:AddChild(moveDropdown)
    self.moveDropdown = moveDropdown
    metaRow:AddChild(makeGap(16))

    local enabledBox = AceGUI:Create("WMC-CheckBox")
    enabledBox:SetLabel("Enabled")
    enabledBox:SetWidth(90)
    enabledBox:SetValue(template.enabled ~= false)
    enabledBox:SetCallback("OnValueChanged", function(_, _, value)
        self.enabledValue = value and true or false
        -- A saved template is enabled/disabled right away (like the
        -- Category dropdown); a draft keeps the choice for "Create".
        if not self.editingDraft and self.selectedName then
            local ok, errorMessage = addon:SetTemplateEnabled(self.selectedScope, self.selectedName, self.enabledValue)
            if not ok then
                self:SetStatus("Error: " .. errorMessage, ERROR_COLOR)
            end
            self:RefreshSelected()
        end
    end)
    -- No alignoffset: Flow then centres the checkbox on the row's line,
    -- which is the dropdowns' field centre (not their labels').
    metaRow:AddChild(enabledBox)
    self.enabledBox = enabledBox
    self.enabledValue = template.enabled ~= false

    -- Breathing room between the dropdowns and the source tab.
    self.editor:AddChild(makeSpacer(EDITOR_SECTION_GAP))

    -- "TEMPLATE SOURCE" tab and the All / Base / mode tabs, right on top of
    -- the source box (which therefore carries no label of its own).
    local tabStrip = AceGUI:Create("WMC-TabStrip")
    tabStrip:SetFullWidth(true)
    tabStrip:SetCaption("Template source")
    tabStrip:SetCallback("OnTabClicked", function(_, _, value, tabButton)
        self:SelectTab(value, tabButton)
    end)
    self.editor:AddChild(tabStrip)
    self.tabStrip = tabStrip

    local source = AceGUI:Create("WMC-TextArea")
    source:SetLabel("")
    source:SetNumLines(15)
    source:SetFullWidth(true)
    source:SetHighlighter(highlightSource)
    self.editor:AddChild(source)
    self.source = source
    local icons = self:SourceIcons()
    source:SetOverlay(icons, SOURCE_ICON_INSET, icons.wmcWidth)
    self:RefreshSourceIcons()
    self.highlightKey = nil
    self:LoadSource(template.source or "")

    self.editor:AddChild(makeSpacer(PREVIEW_AS_GAP))

    -- Preview-As (§13.5): a state to simulate, in condition syntax. Empty
    -- means the live state. Per editor session: every redraw starts empty.
    self.previewAs = ""
    self.previewHint = nil
    self.previewError = nil
    self.previewLabelText = nil
    local asRow = AceGUI:Create("SimpleGroup")
    asRow:SetLayout((AceGUI.GetLayout and AceGUI:GetLayout("WMC-Flow")) and "WMC-Flow" or "Flow")
    asRow:SetUserData("wmcOneRow", true)
    asRow:SetFullWidth(true)
    stripGroupSkin(asRow)
    self.editor:AddChild(asRow)
    local asBox = AceGUI:Create("WMC-EditBox")
    asBox:SetLabel("Preview as  (empty = live state)")
    asBox:SetWidth(440) -- a whole number: a relative width would put the buttons on a fractional pixel
    asBox:DisableButton(true)
    asBox:SetText("")
    asBox:SetCallback("OnTextChanged", function(_, _, value)
        self.previewAs = value or ""
        self.previewHint = nil
        if self.editing then
            self:RequestRefresh()
        end
    end)
    asBox:SetCallback("OnEnterPressed", function()
        asBox:ClearFocus()
    end)
    asRow:AddChild(asBox)
    self.previewAsBox = asBox
    local modeButton = makeButton("This mode", 96, function() self:PreviewThisMode() end)
    alignWithEditBox(modeButton, asBox)
    asRow:AddChild(modeButton)
    self.previewModeButton = modeButton
    local clearButton = makeButton("Live", 64, function() self:SetPreviewAs("") end)
    alignWithEditBox(clearButton, asBox)
    asRow:AddChild(clearButton)
    self.previewClearButton = clearButton
    -- Same as the name row: both buttons glued to the box after every
    -- layout; the job makes the box a button's height.
    asRow:SetUserData("wmcAfterLayout", function()
        anchorToBox(asBox, { modeButton, clearButton })
    end)
    anchorToBox(asBox, { modeButton, clearButton })
    self.previewAlignJob = { editBox = asBox, boxHeight = 24 }
    scheduleAlignment(self.alignJob, self.previewAlignJob)
    local asNote = AceGUI:Create("Label")
    asNote:SetFullWidth(true)
    asNote:SetText(" ")
    self.editor:AddChild(asNote)
    self.previewAsNote = asNote

    local preview = AceGUI:Create("WMC-TextArea")
    preview:SetSectionTab("Compiled preview (current game state)")
    preview:SetNumLines(10)
    preview:SetFullWidth(true)
    preview:SetReadOnly(true) -- selectable and copyable, not editable
    self.previewText = ""
    self.editor:AddChild(preview)
    self.preview = preview
    self.editor:AddChild(makeSpacer(SECTION_GAP))

    -- Below the preview, three captioned blocks (§13.6): Button (the secure
    -- button's state and the output size), Forms (notes, then one row per
    -- #IF form), State (flags, pins, then the live state as label/value rows).
    local buttonSection = addSection(self.editor, "Button")
    local status = AceGUI:Create("Label")
    status:SetFullWidth(true)
    status:SetColor(1, 1, 1)
    status:SetText(" ")
    buttonSection:AddChild(status)
    self.status = status

    self.editor:AddChild(makeSpacer(SECTION_GAP))
    local formsSection = addSection(self.editor, "Forms")
    -- Simulation notes, warnings and which form won.
    local explain = AceGUI:Create("Label")
    explain:SetFullWidth(true)
    explain:SetColor(1, 1, 1)
    explain:SetText(" ")
    formsSection:AddChild(explain)
    self.explainLabel = explain
    local forms = AceGUI:Create("SimpleGroup")
    forms:SetLayout("List")
    forms:SetFullWidth(true)
    stripGroupSkin(forms)
    formsSection:AddChild(forms)
    self.formsGroup = forms
    self.formRowCount = nil
    self.formWidgets = {}
    self.formRowsData = {}

    self.editor:AddChild(makeSpacer(SECTION_GAP))
    local stateBlock = addSection(self.editor, "State")
    -- Live state the player controls (§13.4): flag toggles and group pins.
    local section = AceGUI:Create("SimpleGroup")
    section:SetLayout("Flow")
    section:SetFullWidth(true)
    stripGroupSkin(section)
    stateBlock:AddChild(section)
    self.stateSection = section
    self.stateSectionKey = nil
    self:RefreshStateSection()
    -- The rest of the live state, one label/value row per subject; rows with
    -- nothing to show (no target, not in an arena, solo) are left out.
    local grid = AceGUI:Create("SimpleGroup")
    grid:SetLayout("List")
    grid:SetFullWidth(true)
    stripGroupSkin(grid)
    stateBlock:AddChild(grid)
    self.stateGrid = grid
    self.stateGridKey = nil
    self.stateValueLabels = {}
    self:RefreshStateGrid()
    self.editor:AddChild(makeSpacer(SECTION_GAP))

    self:UpdateEditorIcon()

    source:SetCallback("OnTextChanged", function()
        if self.editing then
            self:RequestRefresh()
        end
    end)
    -- Moving to another line finishes the one left (automatic #WATCH).
    source:SetCallback("OnCursorChanged", function()
        if self.editing then
            local line = self:CursorLine()
            if line ~= self.cursorLine then
                self.cursorLine = line
                self:RequestRefresh()
            end
        end
    end)
    self.editing = true
    self:RefreshStatus(self:RefreshPreviewFromSource())
end

--[[-----------------------------------------------------------------------------
State section (§13.4): one toggle per known flag and one row per class pin.
Rebuilt only when what it shows changes (the key below), never on every
refresh, so a click is never swallowed by a redraw.
-------------------------------------------------------------------------------]]
local STATE_LABEL_WIDTH = 56
local DIM = "|cff808080"
local PIN_STATUS_TEXT = { absent = " (not in group)", offline = " (offline)", active = "" }

local function stateRow(parent)
    local row = AceGUI:Create("SimpleGroup")
    row:SetLayout("Flow")
    row:SetFullWidth(true)
    stripGroupSkin(row)
    parent:AddChild(row)
    return row
end

local function stateCaption(row, text)
    local label = AceGUI:Create("Label")
    label:SetText(text)
    label:SetWidth(STATE_LABEL_WIDTH)
    label:SetColor(unpack(Theme.colors.caption))
    row:AddChild(label)
    return label
end

-- Removable entries (pins, mutes): a grid of cells, each its brass x, an
-- optional checkbox (a remembered mute: on / off), then its text. Columns
-- line up, and rows after the first start under the first cell rather than
-- under the caption. Two columns, or one when a text would not fit its
-- column (a long muted line).
local STATE_X_SIZE = 18
local STATE_X_GAP = 6        -- an x -> its checkbox / text
local STATE_BOX_SIZE = 20    -- the checkbox art
local STATE_COLUMN_GAP = 16  -- a cell's text -> the next cell's x
local STATE_TEXT_WIDTH = 230 -- a cell's text, in two columns
local STATE_WIDE_TEXT_WIDTH = 2 * STATE_TEXT_WIDTH + STATE_COLUMN_GAP + STATE_X_SIZE + STATE_X_GAP

local function stateSpacer(width)
    local gap = AceGUI:Create("WMC-Spacer")
    gap:SetWidth(width)
    gap:SetHeight(1)
    return gap
end

-- entries: { text, onRemove [, checked, onToggle(checked)] } each; an entry
-- with `checked` gets a checkbox. Returns { label, button, box } per entry,
-- in order. Empty: shows `emptyText` instead.
local function stateEntryGrid(section, caption, entries, emptyText)
    local row = stateRow(section)
    stateCaption(row, caption)
    if #entries == 0 then
        local none = AceGUI:Create("Label")
        none:SetText(DIM .. emptyText .. "|r")
        none:SetWidth(300)
        row:AddChild(none)
        return {}
    end
    local cells = {}
    local widest = 0
    for index, entry in ipairs(entries) do
        local label = AceGUI:Create("Label")
        label:SetText(entry.text)
        local fontString = label.label
        if fontString and fontString.GetStringWidth then
            widest = math.max(widest, fontString:GetStringWidth() or 0)
        end
        local remove = makeButton("x", STATE_X_SIZE, entry.onRemove)
        remove:SetStyle("pinx")
        local box
        if entry.checked ~= nil then
            box = AceGUI:Create("WMC-CheckBox")
            box:SetValue(entry.checked)
            box:SetWidth(STATE_BOX_SIZE)
            box:SetHeight(STATE_BOX_SIZE)
            box:SetCallback("OnValueChanged", function(_, _, checked)
                entry.onToggle(checked)
            end)
        end
        cells[index] = { label = label, button = remove, box = box }
    end
    -- A checkbox takes its room from the text.
    local boxRoom = cells[1].box and STATE_BOX_SIZE + STATE_X_GAP or 0
    local columns = widest > STATE_TEXT_WIDTH - boxRoom and 1 or 2
    local textWidth = (columns == 1 and STATE_WIDE_TEXT_WIDTH or STATE_TEXT_WIDTH) - boxRoom
    for index, cell in ipairs(cells) do
        local column = (index - 1) % columns
        if column == 0 and index > 1 then
            row = stateRow(section)
            row:AddChild(stateSpacer(STATE_LABEL_WIDTH))
        elseif column > 0 then
            row:AddChild(stateSpacer(STATE_COLUMN_GAP))
        end
        cell.label:SetWidth(textWidth)
        row:AddChild(cell.button)
        row:AddChild(stateSpacer(STATE_X_GAP))
        if cell.box then
            row:AddChild(cell.box)
            row:AddChild(stateSpacer(STATE_X_GAP))
        end
        row:AddChild(cell.label)
    end
    return cells
end

function UI:RefreshStateSection()
    local section = self.stateSection
    if not section or not addon.State then
        return
    end
    local flags = addon:KnownFlags()
    local pins = addon.State:ActivePins()
    local muteRows = addon.State:MuteRows()
    local parts = {}
    for _, flag in ipairs(flags) do
        table.insert(parts, flag.name .. (flag.on and "+" or "-"))
    end
    table.insert(parts, "|")
    for _, pin in ipairs(pins) do
        table.insert(parts, pin.class .. ">" .. pin.name .. ">" .. pin.status)
    end
    table.insert(parts, "|")
    for _, row in ipairs(muteRows) do
        table.insert(parts, row.mode .. ">" .. row.entry .. (row.on and "+" or "-"))
    end
    local key = table.concat(parts, ",")
    if key == self.stateSectionKey then
        return
    end
    self.stateSectionKey = key
    section:ReleaseChildren()
    self.flagButtons, self.pinLabels, self.pinButtons = {}, {}, {}
    self.muteButtons = {}

    local flagRow = stateRow(section)
    stateCaption(flagRow, "Flags:")
    if #flags == 0 then
        local none = AceGUI:Create("Label")
        none:SetText(DIM .. "none yet (use FLAG=NAME in a template)|r")
        none:SetWidth(300)
        flagRow:AddChild(none)
    end
    for index, flag in ipairs(flags) do
        local name = flag.name
        -- On: the lit-lamp toggle art, gold text. Off: a plain button.
        local text = flag.on and ("|cffffd100" .. name .. ": ON|r") or (name .. ": off")
        local button = makeButton(text, FLAG_BUTTON_WIDTH, function()
            addon:FlagCommand(name)
        end)
        if flag.on then
            button:SetStyle("toggle")
        end
        if index > 1 then
            flagRow:AddChild(makeGap(BUTTON_GAP))
        end
        flagRow:AddChild(button)
        self.flagButtons[name] = button
    end

    -- Pins: each x (the close button's small brass art) unpins its class.
    local pinEntries = {}
    for _, pin in ipairs(pins) do
        local class = pin.class
        local text = class .. " -> " .. pin.name .. PIN_STATUS_TEXT[pin.status]
        if pin.status ~= "active" then
            text = DIM .. text .. "|r"
        end
        table.insert(pinEntries, { text = text, onRemove = function()
            addon:UnpinCommand(class)
        end })
    end
    local pinCells = stateEntryGrid(section, "Pins:", pinEntries, "none (/qmc pin CLASS or ANY)")
    for index, pin in ipairs(pins) do
        self.pinLabels[pin.class] = pinCells[index].label
        self.pinButtons[pin.class] = pinCells[index].button
    end

    -- Mutes (§5.16): every line muted on this class, remembered. Its
    -- checkbox mutes / unmutes it; its x forgets it (unmuting it first).
    local muteEntries = {}
    for _, row in ipairs(muteRows) do
        local mode, entry = row.mode, row.entry
        local text = mode .. ": " .. entry
        if not row.on then
            text = DIM .. text .. "|r"
        end
        table.insert(muteEntries, { text = text, checked = row.on,
            onToggle = function(checked)
                addon[checked and "MuteCommand" or "UnmuteCommand"](addon, mode .. " " .. entry)
            end,
            onRemove = function()
                addon:ForgetMute(mode, entry)
            end })
    end
    local muteCells = stateEntryGrid(section, "Muted:", muteEntries, "none (/qmc mute MODE Line)")
    for index, row in ipairs(muteRows) do
        table.insert(self.muteButtons, { mode = row.mode, entry = row.entry, on = row.on,
            button = muteCells[index].button, box = muteCells[index].box })
    end
    section:DoLayout()
    if self.editor then
        self.editor:DoLayout()
    end
end

-- Sum of the given widgets' heights, to notice a text that wrapped.
local function heightsOf(widgets)
    local total = 0
    for _, widget in pairs(widgets) do
        total = total + (widget.frame and (widget.frame.height or widget.frame:GetHeight()) or 0)
    end
    return total
end

local FORM_COLUMN_WIDTHS = { line = 40, prio = 36, result = 60 }

local function formCell(row, width)
    local label = AceGUI:Create("Label")
    label:SetWidth(width)
    row:AddChild(label)
    return label
end

-- Form rows (Forms block): Line / Prio / Result / Condition columns. The
-- widgets are rebuilt only when the number of rows changes; otherwise their
-- texts are updated in place, so typing in the source stays cheap.
function UI:RenderForms(rows, more)
    local group = self.formsGroup
    if not group then
        return
    end
    self.formRowsData = rows
    local plain = {}
    for _, data in ipairs(rows) do
        table.insert(plain, data.plain)
    end
    self.formsPlain = table.concat(plain, "\n")
    local count = #rows + (more and 1 or 0)
    local rebuilt = false
    if count ~= self.formRowCount then
        self.formRowCount = count
        rebuilt = true
        group:ReleaseChildren()
        self.formWidgets = {}
        self.formMoreLabel = nil
        if #rows > 0 then
            local header = stateRow(group)
            formCell(header, FORM_COLUMN_WIDTHS.line):SetText(DIM_COLOR .. "Line|r")
            formCell(header, FORM_COLUMN_WIDTHS.prio):SetText(DIM_COLOR .. "Prio|r")
            formCell(header, FORM_COLUMN_WIDTHS.result):SetText(DIM_COLOR .. "Result|r")
            local conditionHeader = AceGUI:Create("Label")
            conditionHeader:SetRelativeWidth(0.74)
            conditionHeader:SetText(DIM_COLOR .. "Condition  (hover for details)|r")
            header:AddChild(conditionHeader)
        end
        for index = 1, #rows do
            local row = stateRow(group)
            local cells = {
                line = formCell(row, FORM_COLUMN_WIDTHS.line),
                prio = formCell(row, FORM_COLUMN_WIDTHS.prio),
                result = formCell(row, FORM_COLUMN_WIDTHS.result),
            }
            local condition = AceGUI:Create("InteractiveLabel")
            condition:SetRelativeWidth(0.74)
            condition:SetCallback("OnEnter", function(widget)
                self:ShowFormTooltip(widget, index)
            end)
            condition:SetCallback("OnLeave", function()
                addon.Tooltip:Hide()
            end)
            row:AddChild(condition)
            cells.condition = condition
            self.formWidgets[index] = cells
        end
        if more then
            local row = stateRow(group)
            self.formMoreLabel = formCell(row, 300)
        end
        if count == 0 then
            -- never 0 tall (see nonEmpty): an empty group keeps a 1px spacer
            group:AddChild(makeSpacer(1))
        end
    end
    local labels = {}
    for index, data in ipairs(rows) do
        local cells = self.formWidgets[index]
        cells.line:SetText(data.textColor .. data.line .. "|r")
        cells.prio:SetText(data.textColor .. data.prio .. "|r")
        cells.result:SetText(data.resultColor .. data.result .. "|r")
        cells.condition:SetText(data.textColor .. data.condition .. "|r")
        table.insert(labels, cells.condition)
    end
    if self.formMoreLabel then
        self.formMoreLabel:SetText(DIM_COLOR .. "... " .. tostring(more) .. " more|r")
    end
    local height = heightsOf(labels)
    if rebuilt or height ~= self.formRowsHeight then
        self.formRowsHeight = height
        group:DoLayout()
        if self.editor then
            self.editor:DoLayout()
        end
    end
end

function UI:ShowFormTooltip(widget, index)
    local data = self.formRowsData and self.formRowsData[index]
    if not (data and widget and widget.frame) then
        return
    end
    local tooltip = addon.Tooltip
    tooltip:SetOwner(widget.frame, "ANCHOR_TOPLEFT")
    tooltip:AddLine("Line " .. tostring(data.lineNumber) .. (data.mode and ("  (mode " .. data.mode .. ")") or ""))
    tooltip:AddLine(data.expression, 1, 1, 1, true)
    for _, text in ipairs(data.details) do
        tooltip:AddLine(text, 0.75, 0.75, 0.75, true)
    end
    tooltip:Show()
end

-- Live state as label/value rows (State block). Only rows with something
-- to show; flags are on their own toggles above. `plain` mirrors the rows
-- without colour codes (tests, /qmc output).
local STATE_SEPARATOR = DIM_COLOR .. " / |r"

local function countKeys(value)
    local count = 0
    if type(value) == "table" then
        for _ in pairs(value) do
            count = count + 1
        end
    end
    return count
end

local function stateRows()
    local v = addon.State and addon.State.values or {}
    local rows = {}
    local function add(caption, parts)
        if #parts > 0 then
            table.insert(rows, { caption = caption, parts = parts })
        end
    end
    local function auras(count)
        return count .. (count == 1 and " aura" or " auras")
    end

    local target = {}
    if v.NAME or v.CLASS then
        for _, value in ipairs({ v.NAME, v.CLASS, v.REACTION }) do
            if value then
                table.insert(target, tostring(value))
            end
        end
        if v.SPEC and v.SPEC ~= "UNKNOWN" then
            table.insert(target, "spec " .. tostring(v.SPEC))
        end
        local count = countKeys(v["AURA:TARGET"])
        if count > 0 then
            table.insert(target, auras(count))
        end
    end
    add("Target:", target)

    local player = {}
    if v.PLAYER_SPEC then
        table.insert(player, "spec " .. tostring(v.PLAYER_SPEC))
    end
    table.insert(player, auras(countKeys(v["AURA:SELF"])))
    if v.PET then
        table.insert(player, "pet " .. tostring(v.PET))
    end
    add("Player:", player)

    local zone = {}
    for _, value in ipairs({ v.ZONE, v.INSTANCE_NAME }) do
        if value then
            table.insert(zone, tostring(value))
        end
    end
    if v.INSTANCE and v.INSTANCE ~= "NONE" then
        table.insert(zone, "instance " .. tostring(v.INSTANCE))
    end
    add("Zone:", zone)

    local arena = {}
    for index = 1, 5 do
        if v["ARENA" .. index] then
            table.insert(arena, index .. ": " .. tostring(v["ARENA" .. index]))
        end
    end
    add("Arena:", arena)

    local party = {}
    for index = 1, 4 do
        if v["PARTY" .. index] then
            table.insert(party, index .. ": " .. tostring(v["PARTY" .. index]))
        end
    end
    add("Party:", party)

    local duel = {}
    if v.DUEL_NAME then
        table.insert(duel, tostring(v.DUEL_NAME) .. (v.DUEL and (" (" .. tostring(v.DUEL) .. ")") or ""))
        if v.DUEL_SUCCUBUS then
            table.insert(duel, "succubus " .. tostring(v.DUEL_SUCCUBUS))
        end
    end
    add("Duel:", duel)

    local group = v._GROUP
    if group then
        local tanks, assists = {}, {}
        for _, member in ipairs(group.members or {}) do
            if member.MAINTANK then
                table.insert(tanks, member.name or "?")
            end
            if member.MAINASSIST then
                table.insert(assists, member.name or "?")
            end
        end
        local parts = { tostring(group.kind) .. " (" .. #(group.members or {}) .. ")" }
        if #tanks > 0 then
            table.insert(parts, "main tank: " .. table.concat(tanks, ", "))
        end
        if #assists > 0 then
            table.insert(parts, "main assist: " .. table.concat(assists, ", "))
        end
        add("Group:", parts)
    end
    return rows
end
UI.StateRows = stateRows

-- Rebuilt only when the set of rows changes (a target appears, the arena
-- starts); otherwise the values are updated in place.
function UI:RefreshStateGrid()
    local grid = self.stateGrid
    if not grid then
        return
    end
    local rows = stateRows()
    local captions, plain = {}, {}
    for _, row in ipairs(rows) do
        table.insert(captions, row.caption)
        table.insert(plain, row.caption .. " " .. table.concat(row.parts, " / "))
    end
    self.statePlain = table.concat(plain, "\n")
    local key = table.concat(captions, ",")
    local rebuilt = false
    if key ~= self.stateGridKey then
        self.stateGridKey = key
        rebuilt = true
        grid:ReleaseChildren()
        self.stateValueLabels = {}
        for index, row in ipairs(rows) do
            local line = stateRow(grid)
            stateCaption(line, row.caption)
            local value = AceGUI:Create("Label")
            value:SetRelativeWidth(0.86)
            line:AddChild(value)
            self.stateValueLabels[index] = value
        end
        if #rows == 0 then
            grid:AddChild(makeSpacer(1)) -- never 0 tall (see nonEmpty)
        end
    end
    for index, row in ipairs(rows) do
        self.stateValueLabels[index]:SetText(table.concat(row.parts, STATE_SEPARATOR))
    end
    local height = heightsOf(self.stateValueLabels)
    if rebuilt or height ~= self.stateGridHeight then
        self.stateGridHeight = height
        grid:DoLayout()
        if self.editor then
            self.editor:DoLayout()
        end
    end
end

local function shorten(text, limit)
    if #text <= limit then
        return text
    end
    return text:sub(1, limit - 3) .. "..."
end

-- Builds the evaluation panel text: warnings, output size, and every
-- flattened #IF form with its match state against the current game state.
-- Output size, for the Button block: { text } or { error }.
local function plural(count, word)
    return count .. " " .. word .. (count == 1 and "" or "s")
end

local function measureOutput(output, buttonName)
    local buttons, measureError, sequence = addon.Secure.Measure(buttonName ~= "" and buttonName or "x", output)
    if not buttons then
        return { error = measureError }
    end
    if sequence then
        -- A long #PRE / #POST counts against every step (§12.1): say how
        -- many steps it pushed onto chain buttons.
        local text = plural(sequence.steps, "step") .. ", longest " .. plural(sequence.largest, "character")
            .. ", " .. plural(buttons, "button")
        if sequence.chained > 0 then
            text = text .. " (" .. sequence.chained .. " of " .. sequence.steps .. " steps chained)"
        end
        return { text = text }
    end
    return { text = #output .. (#output == 1 and " character, " or " characters, ")
        .. (buttons == 1 and "1 button" or ("chained across " .. buttons .. " buttons")) }
end

-- The preview of a compiled output: the text itself, or a stepped output's
-- blocks under numbered headers (in cycle order: openers first).
local function previewOf(output)
    if type(output) ~= "table" then
        return output or ""
    end
    local lines = {}
    if output.pre ~= "" then
        table.insert(lines, "#PRE (every press)")
        table.insert(lines, output.pre)
    end
    for index, text in ipairs(output.openers) do
        table.insert(lines, "#STEP " .. index .. " (once)")
        table.insert(lines, text)
    end
    for index, text in ipairs(output.steps) do
        table.insert(lines, "#STEP " .. (#output.openers + index))
        table.insert(lines, text)
    end
    if output.post ~= "" then
        table.insert(lines, "#POST (every press)")
        table.insert(lines, output.post)
    end
    return table.concat(lines, "\n")
end

-- The resets a stepped template has (§5.17), for the Forms notes.
local function resetsText(resets, buttonName)
    local parts = { "recompile" }
    if resets.combat then
        table.insert(parts, "combat end")
    end
    if resets.combatStart then
        table.insert(parts, "combat start")
    end
    if resets.noTarget then
        table.insert(parts, "no target / dead target")
    end
    if resets.condition then
        table.insert(parts, "pressed with " .. resets.condition)
    end
    table.insert(parts, "/click WMC_" .. (buttonName ~= "" and buttonName or "<name>") .. "_RESET")
    return table.concat(parts, ", ")
end

-- Notes above the form rows: what is simulated, warnings, which form won.
local function buildFormsNotes(parsed, explanation, simulated, buttonName)
    local lines = {}
    if simulated then
        table.insert(lines, NOTE_COLOR .. "Simulated state: " .. simulated .. "|r")
        table.insert(lines, DIM_COLOR .. "Not simulated: the raid/party roster (group placeholders use your live group).|r")
    end
    for _, warning in ipairs(parsed.warnings or {}) do
        table.insert(lines, WARN_COLOR .. "Warning:|r " .. warning.message)
    end
    -- Mutes (§5.16): what they removed, and where one was kept because the
    -- branch would have been left without a macro line.
    local mutedCount = 0
    for _, form in ipairs(parsed.forms or {}) do
        for _ in pairs(form.mutedLines or {}) do
            mutedCount = mutedCount + 1
        end
        if form.muteSkipped then
            table.insert(lines, NOTE_COLOR .. "Not muted at line " .. tostring(form.line) .. ":|r "
                .. table.concat(form.muteSkipped, ", ") .. DIM_COLOR .. " (the branch would be empty)|r")
        end
    end
    if mutedCount > 0 then
        table.insert(lines, DIM_COLOR .. "Muted: " .. mutedCount .. (mutedCount == 1 and " line" or " lines")
            .. " (dimmed in the source).|r")
    end
    if parsed.stepped then
        table.insert(lines, "Sequence resets: " .. resetsText(parsed.resets, buttonName or ""))
    end
    if explanation.defaultSteps then
        table.insert(lines, DIM_COLOR .. "#DEFAULT: " .. plural(explanation.defaultSteps, "step") .. ".|r")
    end
    if #explanation.forms == 0 then
        table.insert(lines, DIM_COLOR .. "No #IF forms: the #DEFAULT body is used.|r")
    else
        local winner = "#DEFAULT (no #IF matches)"
        if explanation.tie then
            winner = ERROR_COLOR .. "tie (see the error above)|r"
        else
            for _, row in ipairs(explanation.forms) do
                if row.selected then
                    winner = OK_COLOR .. "#IF at line " .. tostring(row.line) .. "|r"
                    break
                end
            end
        end
        table.insert(lines, #explanation.forms .. (#explanation.forms == 1 and " form" or " forms")
            .. ", selected: " .. winner)
    end
    return table.concat(lines, "\n")
end

-- One entry per form row (at most EXPLAIN_MAX_FORMS) plus how many more
-- there are. The result is spelled out ("selected", "matched", "no") so the
-- colour is never the only cue; the details go in the row's tooltip.
local FORM_RESULTS = {
    tie = { "tie", ERROR_COLOR, "Tie: another match has the same specificity and priority." },
    selected = { "selected", OK_COLOR, "Selected: the most specific match." },
    yields = { "yields", DIM_COLOR, "Matched, but yields to a live mode: " },
    matched = { "matched", "|cffffffff", "Matched, but a more specific or higher-priority form won." },
    no = { "no", DIM_COLOR, "Not matched." },
}
local FORM_CONDITION_LENGTH = 58

local function buildFormRows(explanation)
    local rows = {}
    for index, row in ipairs(explanation.forms) do
        if index > EXPLAIN_MAX_FORMS then
            break
        end
        local kind = (row.tied and "tie") or (row.selected and "selected") or (row.yieldedTo and "yields")
            or (row.specificity and "matched") or "no"
        local result = FORM_RESULTS[kind]
        local modeTag = row.mode and (row.mode .. ": ") or ""
        local condition = modeTag .. row.expression
        if row.steps then
            condition = "(" .. plural(row.steps, "step") .. ") " .. condition
        end
        local details = { result[3] .. (kind == "yields" and tostring(row.yieldedTo) or "") }
        if row.specificity then
            table.insert(details, "Specificity: " .. row.specificity .. " (conditions met)")
        end
        table.insert(details, "Priority: " .. tostring(row.priority))
        if row.steps then
            table.insert(details, "Sequence: " .. plural(row.steps, "step")
                .. (row.openers > 0 and (", " .. row.openers .. " once") or ""))
        end
        local strong = kind == "selected" or kind == "matched" or kind == "tie"
        local textColor = kind == "selected" and OK_COLOR or kind == "tie" and ERROR_COLOR
            or strong and "|cffffffff" or DIM_COLOR
        local prio = row.priority ~= 0 and tostring(row.priority) or "-"
        table.insert(rows, {
            line = "L" .. tostring(row.line),
            prio = prio,
            result = result[1],
            resultColor = result[2],
            textColor = textColor,
            condition = shorten(condition, FORM_CONDITION_LENGTH),
            expression = row.expression,
            mode = row.mode,
            lineNumber = row.line,
            details = details,
            plain = "L" .. tostring(row.line) .. " " .. prio .. " " .. result[1] .. " " .. condition,
        })
    end
    local more = #explanation.forms - #rows
    return rows, more > 0 and more or nil
end

-- Re-parses and re-compiles the editor's (possibly unsaved) source against
-- the current game state. Fills the preview and the evaluation panel;
-- returns the preview branch or nil and the error.
-- Index of the slice (modeSegments) holding a given template line.
local function segmentForLine(segments, line)
    local found
    for index, segment in ipairs(segments or {}) do
        if segment.startLine <= line then
            found = index
        end
    end
    return found
end

-- Pushes the error / active-branch marks to the source box's highlighter
-- and the mode tabs. `parsed` is nil on a parse error.
function UI:UpdateMarks(parsed, parseError, values)
    if not self.source then
        return
    end
    local errorLines, activeLines, mutedLines = {}, {}, {}
    local modeMarks = {}
    if self.activeTab == TAB_ALL then
        -- Tabs follow the text live while the whole source is shown.
        self.modeSegments = addon.Compiler.SplitModes(self.fullSource or "")
    end
    local segments = self.modeSegments
    local function markError(line)
        errorLines[line] = true
        local index = segmentForLine(segments, line)
        if index then
            modeMarks[index] = "error"
        end
    end
    if not parsed then
        local line = tonumber((parseError or ""):match("^Line (%d+):") or "")
        if line then
            markError(line)
        end
    else
        local explanation = addon.Compiler.Explain(parsed, values)
        local modeLines = {}
        for _, mode in ipairs(parsed.modes or {}) do
            modeLines[mode.name] = mode.lineNumber
        end
        for _, form in ipairs(parsed.forms) do
            for line in pairs(form.mutedLines or {}) do
                mutedLines[line] = true
            end
        end
        for _, row in ipairs(explanation.forms) do
            if row.tied then
                markError(row.line)
            elseif row.selected then
                activeLines[row.line] = true
                local header = row.mode and modeLines[row.mode]
                if header then
                    activeLines[header] = true
                    local index = segmentForLine(segments, header)
                    if index and not modeMarks[index] then
                        modeMarks[index] = "active"
                    end
                end
            end
        end
    end
    self.modeMarks = modeMarks
    self:RefreshTabs()
    local offset = self:TabLineOffset()
    local lineMap = self.activeTab == TAB_ALL and self.allLineMap or nil
    local keyParts = { tostring(offset) .. (lineMap and ("/" .. self.allLineKey) or "") }
    for _, set in ipairs({ errorLines, activeLines, mutedLines }) do
        local numbers = {}
        for line in pairs(set) do
            table.insert(numbers, line)
        end
        table.sort(numbers)
        table.insert(keyParts, table.concat(numbers, ","))
    end
    self.source:SetHighlightContext({
        errorLines = errorLines,
        activeLines = activeLines,
        mutedLines = mutedLines,
        lineOffset = offset,
        lineMap = lineMap,
    }, table.concat(keyParts, "|"))
end

-- Preview-As: the values the preview compiles against. The live snapshot,
-- or a COPY of it with the Preview-As line applied (never State.values).
-- Returns base, info and the simulated-state text (all nil when the line is
-- empty or invalid); the parse error, if any, is kept for the note.
function UI:ResolvePreviewAs()
    self.previewError = nil
    local text = self.previewAs or ""
    if not text:find("%S") then
        return nil
    end
    local overrides, order = addon.Compiler.ParseOverrides(text)
    if not overrides then
        self.previewError = order
        return nil
    end
    if not next(overrides) then
        return nil
    end
    local base, info = addon.Compiler.BuildPreviewValues(addon.State.values, overrides)
    return base, info, addon.Compiler.FormatOverrides(overrides, order)
end

-- The note under the line (error in red, hint, or what is simulated) and
-- the preview box's section tab.
function UI:UpdatePreviewAsUI(simulated)
    local label = simulated and "Preview (simulated)" or "Compiled preview (current game state)"
    if self.preview and label ~= self.previewLabelText then
        self.previewLabelText = label
        self.preview:SetSectionTab(label)
    end
    if not self.previewAsNote then
        return
    end
    local note = " "
    if self.previewError then
        note = ERROR_COLOR .. self.previewError .. "|r"
    elseif self.previewHint then
        note = NOTE_COLOR .. self.previewHint .. "|r"
    elseif simulated then
        note = NOTE_COLOR .. "Simulated: " .. simulated .. " (the button is not affected)|r"
    end
    self.previewAsNote:SetText(note)
end

-- Sets the Preview-As line (and its box) from code.
function UI:SetPreviewAs(text, hint)
    self.previewAs = text or ""
    self.previewHint = hint
    if self.previewAsBox then
        self.previewAsBox:SetText(self.previewAs)
    end
    self:RefreshStatus(self:RefreshPreviewFromSource())
end

function UI:ClearPreviewAs()
    self.previewAs = ""
    self.previewHint = nil
    self.previewError = nil
    if self.previewAsBox then
        self.previewAsBox:SetText("")
    end
end

-- "This mode": prefills the line from the shown mode tab's condition when
-- it is a plain AND of FIELD=VALUE terms; otherwise says why it cannot.
function UI:PreviewThisMode()
    local segment = type(self.activeTab) == "number" and self.modeSegments and self.modeSegments[self.activeTab]
    if not segment or segment.kind ~= "MODE" then
        self:SetPreviewAs(self.previewAs or "", "Open a mode's tab first, then press \"This mode\".")
        return
    end
    local parsed = addon.Compiler.Parse(self:GetEditorSource())
    local mode
    for _, candidate in ipairs(parsed and parsed.modes or {}) do
        if candidate.name == segment.name then
            mode = candidate
            break
        end
    end
    if not mode then
        self:SetPreviewAs(self.previewAs or "", "Fix the template's errors first; the mode could not be read.")
        return
    end
    if mode.off then
        self:SetPreviewAs(self.previewAs or "", segment.name .. " is parked (OFF): it never compiles.")
        return
    end
    local text, reason = addon.Compiler.OverridesFromGroups(mode.groups)
    if text then
        self:SetPreviewAs(text)
    else
        self:SetPreviewAs(self.previewAs or "", "Nothing prefilled for " .. segment.name .. ": " .. reason .. ".")
    end
end

function UI:RefreshPreviewFromSource()
    if not self.source or not self.preview then
        return nil
    end
    local base, info, simulated = self:ResolvePreviewAs()
    self.previewSimulated = simulated and true or false
    self:UpdatePreviewAsUI(simulated)
    local parsed, parseError = addon.Compiler.Parse(self:GetEditorSource())
    if parsed then
        addon.Compiler.ApplyMutes(parsed, addon:MuteTable())
        local shown = self.window and self.window.frame:IsShown()
        addon:SetEditorGroupAuras(shown and addon.Compiler.UsesPlaceholderAuras(parsed))
    end
    if not parsed then
        self.previewText = ""
        self.preview:SetText("")
        self.previewMeasure = nil
        if self.explainLabel then
            self.explainLabel:SetText(" ")
        end
        self:RenderForms({})
        self:UpdateMarks(nil, parseError)
        return nil, parseError
    end
    local values = addon:CompileValuesFor(parsed, base, info)
    local output, branch, compileError = addon.Compiler.Compile(parsed, values, false)
    self.previewText = previewOf(output)
    self.preview:SetText(self.previewText)
    self.previewMeasure = output and measureOutput(output, self.nameBox and self.nameBox:GetText() or "") or nil
    local explanation = addon.Compiler.Explain(parsed, values)
    if self.explainLabel then
        self.explainLabel:SetText(nonEmpty(buildFormsNotes(parsed, explanation, simulated,
            self.nameBox and self.nameBox:GetText() or "")))
    end
    self:RenderForms(buildFormRows(explanation))
    self:UpdateMarks(parsed, nil, values)
    if not output then
        return nil, compileError
    end
    return branch
end

-- Status line: the preview's result, then (for saved templates) the live
-- secure button's state, then an unsaved-changes note.
function UI:RefreshStatus(previewBranch, previewError)
    if not self.status then
        return
    end
    local lines = {}
    if previewError then
        table.insert(lines, ERROR_COLOR .. "Error: " .. previewError .. "|r")
    end
    -- One line for the button: branch / applied state / output size.
    local parts = {}
    local template = self.selectedName and not self.editingDraft
        and addon.runtime.byId[addon:TemplateId(self.selectedScope, self.selectedName)]
    if template then
        if template.error and template.error ~= previewError then
            table.insert(lines, ERROR_COLOR .. "Saved template: " .. template.error .. "|r")
        end
        table.insert(parts, "Branch: " .. tostring(template.previewBranch or template.branch or "DEFAULT"))
        if template.dirty then
            table.insert(parts, NOTE_COLOR .. "secure output pending until combat ends|r")
        elseif template.lastAppliedOutput and addon.Compiler.SameOutput(template.lastAppliedOutput, template.output) then
            table.insert(parts, OK_COLOR .. "up to date|r")
        end
    elseif self.selectedName and not self.editingDraft then
        table.insert(parts, DIM_COLOR .. "not active on this character (disabled or another class)|r")
    elseif previewBranch and not self.previewSimulated then
        table.insert(parts, "Preview branch: " .. previewBranch)
    end
    local measure = self.previewMeasure
    if measure and measure.error then
        table.insert(lines, ERROR_COLOR .. "Output: " .. measure.error .. "|r")
    elseif measure then
        table.insert(parts, DIM_COLOR .. measure.text .. "|r")
    end
    if #parts > 0 then
        table.insert(lines, table.concat(parts, DIM_COLOR .. "  /  |r"))
    end
    -- The simulated branch is always labelled and kept apart from the live
    -- button state above, so it is never mistaken for what the button does.
    if self.previewSimulated and previewBranch then
        table.insert(lines, NOTE_COLOR .. "Simulated branch (preview only): " .. previewBranch .. "|r")
    end
    if self:IsEditorDirty() then
        table.insert(lines, NOTE_COLOR .. (self.editingDraft and "Not created yet." or "Unsaved changes (preview shows the edited source).") .. "|r")
    end
    self.status:SetText(nonEmpty(table.concat(lines, "\n")))
    self:FitEditor()
end

-- The status, evaluation and state labels change height as their text
-- changes (more forms, more warnings), but the editor's scroll area only
-- learns its content height when it is laid out. Re-lay it out whenever
-- their combined height changes, so the bottom is always reachable; checked
-- again one frame later, as a wrapped text's height may settle late.
local function labelHeight(widget)
    local frame = widget and widget.frame
    return frame and (frame.height or frame:GetHeight()) or 0
end

local fitFrame = CreateFrame("Frame")
fitFrame:Hide()
UI.fitFrame = fitFrame

function UI:FitEditor(deferred)
    if not self.editor then
        return
    end
    local key = labelHeight(self.status) + labelHeight(self.explainLabel)
        + labelHeight(self.formsGroup) + labelHeight(self.stateGrid)
    if key ~= self.editorLabelHeight then
        self.editorLabelHeight = key
        self.editor:DoLayout()
    end
    if not deferred then
        fitFrame:Show()
    end
end

fitFrame:SetScript("OnUpdate", function(frame)
    frame:Hide()
    UI:FitEditor(true)
end)

-- Called on every relevant state change (coalesced through
-- RequestRefresh): re-renders the state summary, the live compiled preview,
-- the evaluation panel and the secure-button status so the editor always
-- mirrors what the secure button actually compiled to.
function UI:RefreshSelected()
    if not self.window or not self.window.frame:IsShown() then
        return
    end
    self:RefreshStateSection()
    self:RefreshStateGrid()
    self:AutoAddWatches()
    self:RefreshStatus(self:RefreshPreviewFromSource())
end

local MAX_CHAT_WARNINGS = 3

-- Returns true when the template was saved (even if it then failed to
-- compile), false when the save was refused.
function UI:SaveSelected()
    local wasDraft = self.editingDraft
    local draftIcon, draftCategory = self.draftIcon, self.draftCategory
    local name = self.nameBox:GetText()
    self:AutoAddWatches(true)
    local ok, errorMessage = addon:SaveTemplate(
        self.selectedScope,
        name,
        self:GetEditorSource(),
        self.selectedScope,
        self.selectedName,
        self.enabledValue,
        wasDraft
    )
    if not ok then
        self:SetStatus("Error: " .. errorMessage, ERROR_COLOR)
        return false
    end
    if wasDraft then
        -- SaveTemplate re-selected the new template; apply draft metadata
        -- now that the record exists, then redraw so the editor shows it.
        if draftIcon then
            addon:SetTemplateIcon(self.selectedScope, self.selectedName, draftIcon)
        end
        if draftCategory then
            addon:SetTemplateCategory(self.selectedScope, self.selectedName, draftCategory)
        end
        self:Select(self.selectedScope, self.selectedName)
    end
    if errorMessage then
        self:SetStatus("Saved, but compilation failed: " .. errorMessage, NOTE_COLOR)
        return true
    end
    -- Warnings go to chat once per save (the editor shows them all).
    local parsed = addon.Compiler.Parse(self:GetEditorSource())
    local warnings = parsed and parsed.warnings or {}
    for index, warning in ipairs(warnings) do
        if index > MAX_CHAT_WARNINGS then
            addon:Print(self.selectedName .. ": ... " .. (#warnings - MAX_CHAT_WARNINGS) .. " more warning(s), see the editor.")
            break
        end
        addon:Print(self.selectedName .. ": " .. warning.message)
    end
    return true
end

function UI:DeleteSelected()
    if not self.selectedName or self.editingDraft then
        return
    end
    Dialog:Show("WMC_DELETE_TEMPLATE", self.selectedName,
        { scope = self.selectedScope, name = self.selectedName })
end

function UI:DeleteTemplateConfirmed(scope, name)
    local ok, errorMessage = addon:DeleteTemplate(scope, name)
    if not ok then
        self:SetStatus("Error: " .. errorMessage, ERROR_COLOR)
        return
    end
    if self.selectedScope == scope and self.selectedName == name then
        self.selectedName = nil
        self:NewTemplate()
    end
    self:RefreshList()
end

function UI:DuplicateSelected()
    if self.editingDraft or not self.selectedName then
        return
    end
    local scope, name = self.selectedScope, self.selectedName
    self:Guard(function()
        local newName, errorMessage = addon:DuplicateTemplate(scope, name)
        if not newName then
            self:SetStatus("Error: " .. errorMessage, ERROR_COLOR)
            return
        end
        self:Select(scope, newName)
        self:SetStatus("Duplicated as " .. newName .. ".", OK_COLOR)
    end)
end

function UI:MoveSelected(newScope)
    local scope, name = self.selectedScope, self.selectedName
    if self.editingDraft or not name or newScope == scope then
        return
    end
    local function revert()
        if self.moveDropdown then
            self.moveDropdown:SetValue(scope)
        end
    end
    self:Guard(function()
        local ok, errorMessage = addon:MoveTemplate(scope, name, newScope)
        if not ok then
            revert()
            self:SetStatus("Error: " .. errorMessage, ERROR_COLOR)
            return
        end
        -- SaveTemplate already selected it in its new scope.
        self:Select(newScope, name)
        self:SetStatus("Moved to " .. newScope .. ".", OK_COLOR)
    end, revert)
end

function UI:MakeMacro(perCharacter)
    if self.editingDraft or not self.selectedName then
        return
    end
    local index, result = addon:MakeMacro(self.selectedScope, self.selectedName, perCharacter)
    if not index then
        self:SetStatus("Error: " .. result, ERROR_COLOR)
        addon:Print(result)
        return
    end
    local message
    if result == "existing" then
        message = "That macro already exists; it is on your cursor. Drop it on an action bar."
    else
        message = "Created a " .. (perCharacter and "character" or "general")
            .. " macro; it is on your cursor. Drop it on an action bar."
    end
    -- Into the bank category loaded in that tab, so a loadout keeps it:
    -- only when asked for (the bank's settings).
    local Bank = addon.Bank
    if Bank and Bank.SaveToLoaded and Bank:AutoSave() then
        local id, banked, place = Bank:SaveToLoaded(index)
        if id and banked ~= "linked" then
            message = message .. " Saved to the bank: " .. Bank.SectionName(place.section) .. " / "
                .. (place.category or Bank.UNSORTED) .. "."
        elseif place and not id then
            message = message .. " Not saved to the bank: " .. tostring(banked)
        end
    end
    self:SetStatus(message, OK_COLOR)
    addon:Print(message)
end

--[[-----------------------------------------------------------------------------
Export / import window: a smaller window in the popups' look (Theme.POPUP_FRAMES).
-------------------------------------------------------------------------------]]
local TEXT_BUTTON_GAP = 6 -- between the box and the buttons under it

function UI:GetTextWindow()
    if self.textWindow then
        return self.textWindow
    end
    local window = AceGUI:Create("WMC-Window")
    window:SetFrameStyle("text")
    window:SetLayout("List")
    window:SetCallback("OnClose", function(widget)
        widget:Hide()
    end)
    if window.sizer_se then
        window.sizer_se:Hide()
    end
    _G.WMCTextWindow = window.frame
    if UISpecialFrames then
        table.insert(UISpecialFrames, "WMCTextWindow")
    end

    local box = AceGUI:Create("WMC-TextArea")
    box:SetFullWidth(true)
    box:SetNumLines(17)
    window:AddChild(box)

    -- Close at the bottom, its right edge on the box's (not the scrollbar's
    -- column); Import, when shown, left of it.
    local closeButton = makeButton("Close", 140, function()
        window:Hide()
    end)
    local importButton = makeButton("Import", 140, function()
        self:ImportText(box:GetText())
    end)
    local content = window.content
    closeButton.frame:SetParent(content)
    closeButton.frame:ClearAllPoints()
    closeButton.frame:SetPoint("TOPRIGHT", box.box, "BOTTOMRIGHT", 0, -TEXT_BUTTON_GAP)
    importButton.frame:SetParent(content)
    importButton.frame:ClearAllPoints()
    importButton.frame:SetPoint("TOPRIGHT", closeButton.frame, "TOPLEFT", -BUTTON_GAP, 0)
    closeButton.frame:Show()
    window:AddChild(makeSpacer(TEXT_BUTTON_GAP + closeButton.frame:GetHeight()))

    self.textWindow = { window = window, box = box, importButton = importButton, closeButton = closeButton }
    return self.textWindow
end

local function showTextWindow(self, title, label, text, importing)
    local tw = self:GetTextWindow()
    tw.window:SetTitle(unpack(type(title) == "table" and title or { title }))
    tw.box:SetLabel(label)
    tw.box:SetText(text or "")
    if importing then
        tw.importButton.frame:Show()
    else
        tw.importButton.frame:Hide()
    end
    tw.window:Show()
    -- Float above the main window and its frame art (both live in
    -- FULLSCREEN_DIALOG; the main window's pipes are at its level + 20).
    local main = self.window and self.window.frame
    tw.window.frame:SetFrameLevel((main and main:GetFrameLevel() or 100) + 50)
    tw.box.editBox:SetFocus()
    if not importing then
        tw.box.editBox:HighlightText()
    end
end

function UI:ExportSelected()
    if self.editingDraft or not self.selectedName then
        return
    end
    local text = addon:ExportTemplates({ { scope = self.selectedScope, name = self.selectedName } })
    showTextWindow(self, { "Export " .. self.selectedName, self.selectedName }, "Copy this text (Ctrl+C)", text, false)
end

function UI:ExportScope()
    local values = addon.db and addon.db.templates[self.selectedScope] or {}
    local entries = {}
    for _, name in ipairs(sortedKeys(values)) do
        table.insert(entries, { scope = self.selectedScope, name = name })
    end
    if #entries == 0 then
        self:SetStatus("Nothing to export in this class.", NOTE_COLOR)
        return
    end
    -- the class and the count alone when the whole title won't fit the plaque
    local scope = className(self.selectedScope) .. " (" .. #entries .. ")"
    showTextWindow(self, { "Export " .. scope, scope }, "Copy this text (Ctrl+C)", addon:ExportTemplates(entries), false)
end

function UI:OpenImport()
    showTextWindow(self, "Import templates", "Paste exported text (Ctrl+V), then press Import", "", true)
end

function UI:ImportText(text)
    local results, errorMessage = addon:ImportTemplates(text)
    if not results then
        addon:Print("Import failed: " .. errorMessage)
        return
    end
    local imported, lastScope, lastName = 0, nil, nil
    for _, result in ipairs(results) do
        if result.error then
            addon:Print("Import of " .. tostring(result.originalName) .. " failed: " .. result.error)
        else
            imported = imported + 1
            lastScope, lastName = result.scope, result.name
            if result.name ~= result.originalName then
                addon:Print("Imported " .. result.originalName .. " as " .. result.name .. " (name was taken).")
            else
                addon:Print("Imported " .. result.scope .. " template " .. result.name .. ".")
            end
        end
    end
    if self.textWindow then
        self.textWindow.window:Hide()
    end
    if lastName then
        self:Select(lastScope, lastName)
        self:SetStatus("Imported " .. imported .. " template(s).", OK_COLOR)
    end
end
