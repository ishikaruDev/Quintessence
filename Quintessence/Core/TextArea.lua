local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme

--[[-----------------------------------------------------------------------------
WMC-TextArea widget: a multi-line text box (template source, compiled
preview, export/import text).

Replaces AceGUI's MultiLineEditBox, whose layout we had to fight:
  * its scrollbar is always shown, even with nothing to scroll;
  * the scrollbar's arrows extend past the top and bottom of the box;
  * the label gets a fixed 10px, so the box clips the label's descenders;
  * patching any of that meant modifying POOLED AceGUI widgets, which AceGUI
    shares with every other addon using the same library.
This widget owns its frames (its own pool, its own type), so none of that
can leak anywhere.

Layout, top to bottom: [label or section tab][gap][box]. The box is a
themed panel; the scrollbar sits OUTSIDE it, just to its right; arrows
included it spans exactly the box's height. It is hidden while the text
fits. Its column is always reserved, so the box keeps one width and text
never re-wraps when the bar appears.

Methods: SetLabel, SetSectionTab (a gold tab instead of a plain label),
SetText, GetText, SetNumLines, SetReadOnly, SetFocus, ClearFocus,
HighlightText, SetMaxLetters, SetRightReserve, SetOverlay, DisableButton (no-op; there is no accept
button), SetHighlighter, SetHighlightContext, ApplyHighlight,
GetCursorOffset, ReplaceText.
Field: editBox (the raw EditBox).
Callbacks: OnTextChanged (user edits only; always plain text),
OnCursorChanged, OnEnter, OnLeave.

Syntax highlighting (optional, SetHighlighter): the box shows the text with
|cffRRGGBB...|r color codes inserted by the highlighter function; GetText,
OnTextChanged and the widget's .text are always the PLAIN text, so nothing
outside this widget ever sees a color code (saved sources, the compiler,
the unsaved-changes guard). Recoloring is deferred: a keystroke only marks
the box dirty, and the codes are rebuilt HIGHLIGHT_DELAY seconds after the
last edit, keeping the cursor on the same character. Nothing here runs
unless the box is being edited (or its context changed) -- compilation of
the secure buttons never goes through this widget.

Script behaviour (cursor following, click-to-focus, spell/item drag) is
adapted from AceGUI-3.0's MultiLineEditBox (Ace3, BSD licence).
-------------------------------------------------------------------------------]]
local Type, Version = "WMC-TextArea", 2

local LINE_HEIGHT = 14
local LABEL_GAP = 4      -- between the label's baseline area and the box
-- A section tab sits partly on the box's top edge: its lower 8 units
-- overlap the box, so the tab rests on the panel's rim (the rim is the
-- panel art's top 1-3 rows).
local TAB_OVERLAP = 8
local BOX_PADDING = 8    -- text inset inside the box (clear of its corners)
-- The scrollbar column right of the box (shared with WMC-Section through
-- Theme.BOX_RIGHT_INSET, so every editor block has the same right edge).
local BAR_GAP = Theme.TEXTAREA_BAR_GAP         -- between the box and its scrollbar
local BAR_WIDTH = Theme.SCROLLBAR_WIDTH
local BAR_RIGHT_MARGIN = Theme.TEXTAREA_BAR_MARGIN -- keeps the arrows clear of a clipping parent's edge

-- Seconds of typing inactivity before the box is recolored.
local HIGHLIGHT_DELAY = 0.15

-- Global names are only needed by UIPanelScrollFrameTemplate (its scripts
-- look children up by name). No underscore after "WMC", so these can never
-- collide with a template's WMC_<name> button.
local widgetCount = 0

--[[ Color codes ]]
-- Walks raw EditBox text and classifies each escape: "||" is an escaped
-- pipe (two plain bytes -- it is what the box reports for a typed "|", and
-- it stays that way in the plain text, exactly as before highlighting
-- existed), "|cAARRGGBB" and "|r" are color codes (zero plain bytes). Any
-- other byte is one plain byte. Calls visit(rawStart, rawStop, plainLength)
-- for each unit, in order.
local function walk(raw, visit)
    local index, length = 1, #raw
    while index <= length do
        local stop = index
        local plain = 1
        if raw:byte(index) == 124 then -- "|"
            local nextChar = raw:sub(index + 1, index + 1)
            if nextChar == "|" then
                stop, plain = index + 1, 2
            elseif nextChar == "c" and raw:sub(index + 2, index + 9):match("^%x%x%x%x%x%x%x%x$") then
                stop, plain = index + 9, 0
            elseif nextChar == "r" then
                stop, plain = index + 1, 0
            end
        end
        if visit(index, stop, plain) then
            return
        end
        index = stop + 1
    end
end

local function StripCodes(raw)
    if not raw:find("|", 1, true) then
        return raw
    end
    local parts = {}
    walk(raw, function(from, to, plain)
        if plain > 0 then
            table.insert(parts, raw:sub(from, to))
        end
    end)
    return table.concat(parts)
end

-- Number of plain bytes before raw cursor position `cursor` (an offset:
-- 0 = before the first byte).
local function PlainOffset(raw, cursor)
    local count = 0
    walk(raw, function(from, to, plain)
        if to > cursor then
            return true
        end
        count = count + plain
    end)
    return count
end

-- Raw cursor offset that sits right after `offset` plain bytes.
local function RawOffset(raw, offset)
    if offset <= 0 then
        return 0
    end
    local count, result = 0, #raw
    walk(raw, function(from, to, plain)
        count = count + plain
        if plain > 0 and count >= offset then
            result = to
            return true
        end
    end)
    return result
end

--[[ Scripts ]]
local function OnCursorChanged(self, _, y, _, cursorHeight)                      -- EditBox
    self.obj:Fire("OnCursorChanged")
    local scrollFrame = self.obj.scrollFrame
    y = -y
    local offset = scrollFrame:GetVerticalScroll()
    if y < offset then
        scrollFrame:SetVerticalScroll(y)
    else
        y = y + cursorHeight - scrollFrame:GetHeight()
        if y > offset then
            scrollFrame:SetVerticalScroll(y)
        end
    end
end

--[[ Focus ]]
-- WoW keeps keyboard focus in an EditBox until something takes it away:
-- clicking the 3D world does NOT, so after clicking away, W/A/S/D would
-- still type into the template. Three things release it:
--   * AceGUI's focus manager: gaining focus registers the widget with
--     AceGUI:SetFocus, so whatever AceGUI does to drop focus (clicking the
--     window, another AceGUI edit box or dropdown taking over) also clears
--     this box;
--   * a click on the world (WorldFrame, hooked once for every text area);
--   * the box being hidden (window closed, editor redrawn).
local focusedArea
local worldHooked

local function ReleaseFocus()
    if focusedArea then
        focusedArea.editBox:ClearFocus()
    end
end

local function HookWorldClicks()
    if worldHooked or not WorldFrame or not WorldFrame.HookScript then
        return
    end
    worldHooked = true
    WorldFrame:HookScript("OnMouseDown", ReleaseFocus)
end

local function OnEditFocusGained(self)                                           -- EditBox
    local widget = self.obj
    focusedArea = widget
    HookWorldClicks()
    if AceGUI.SetFocus then
        AceGUI:SetFocus(widget)
    end
end

local function OnEditFocusLost(self)                                             -- EditBox
    self:HighlightText(0, 0)
    local widget = self.obj
    if focusedArea == widget then
        focusedArea = nil
    end
    if AceGUI.FocusedWidget == widget then
        AceGUI.FocusedWidget = nil
    end
    if widget.highlightPending and widget.highlighter then
        widget:ScheduleHighlight()
    end
end

local function OnEnter(self)                                                     -- EditBox / ScrollFrame
    local widget = self.obj
    if not widget.entered then
        widget.entered = true
        widget:Fire("OnEnter")
    end
end

local function OnLeave(self)                                                     -- EditBox / ScrollFrame
    local widget = self.obj
    if widget.entered then
        widget.entered = nil
        widget:Fire("OnLeave")
    end
end

-- The cursor position at the very end of the box's text. Cursor positions
-- count every raw byte, color codes included; GetNumLetters does not count
-- the codes (SetCountInvisibleLetters(false)), so it would put the cursor
-- that many bytes short of the end -- often inside a code, where Enter
-- splits it and shows it as text.
local function EndPosition(editBox)
    return #(editBox:GetText() or "")
end

-- Clicking the empty area below the text focuses the box, cursor at the end.
local function OnMouseUp(self)                                                   -- ScrollFrame / box
    local editBox = self.obj.editBox
    editBox:SetFocus()
    editBox:SetCursorPosition(EndPosition(editBox))
end

-- Dropping a spell or item into the box inserts its name.
local function OnReceiveDrag(self)                                               -- EditBox / ScrollFrame
    local widget = self.obj
    if widget.readOnly or not GetCursorInfo then
        return
    end
    local kind, id, info = GetCursorInfo()
    if kind == "spell" then
        info = GetSpellInfo(id, info)
    elseif kind ~= "item" then
        return
    end
    ClearCursor()
    local editBox = widget.editBox
    if not editBox:HasFocus() then
        editBox:SetFocus()
        editBox:SetCursorPosition(EndPosition(editBox))
    end
    editBox:Insert(info)
end

-- The EditBox is the scroll child and is as tall as its text, so parts of
-- it lie above and below the visible area. Its clickable region is cut
-- down to the visible part, so lines scrolled out of view can't catch
-- clicks meant for frames around the box. That cut must follow the CURRENT
-- scroll offset and text height: if it is computed for one text and the box
-- then shows another (switching tabs, adding a mode, loading a template),
-- the stale cut can cover the visible text, and clicks fall through to the
-- background (cursor jumps to the end) or nowhere. So it is recomputed on
-- every scroll, every size change of the EditBox or the scroll frame, and
-- every text change.
local function UpdateHitRect(widget)
    local editBox, scrollFrame = widget.editBox, widget.scrollFrame
    local offset = scrollFrame:GetVerticalScroll() or 0
    local height = editBox:GetHeight() or 0
    local view = scrollFrame:GetHeight() or 0
    editBox:SetHitRectInsets(0, 0, math.max(0, offset), math.max(0, height - offset - view))
end

local function OnSizeChanged(self, width)                                        -- ScrollFrame
    self.obj.editBox:SetWidth(width)
    UpdateHitRect(self.obj)
end

local function OnEditBoxSizeChanged(self)                                        -- EditBox
    UpdateHitRect(self.obj)
end

local function OnTextChanged(self, userInput)                                    -- EditBox
    if not userInput then
        return
    end
    local widget = self.obj
    if widget.readOnly then
        -- Read-only boxes stay selectable/copyable; edits are undone.
        if widget:GetText() ~= widget.text then
            widget:SetText(widget.text)
        end
        return
    end
    widget.text = widget:GetText()
    UpdateHitRect(widget)
    widget:Fire("OnTextChanged", widget.text)
    if widget.highlighter then
        widget:ScheduleHighlight()
    end
end

-- Deferred recolor: runs once, HIGHLIGHT_DELAY after the last request.
local function HighlightTimer_OnUpdate(frame, elapsed)
    frame.elapsed = (frame.elapsed or 0) + elapsed
    if frame.elapsed < HIGHLIGHT_DELAY then
        return
    end
    frame:Hide()
    frame.obj:ApplyHighlight()
end

local function OnVerticalScroll(self)                                            -- ScrollFrame
    UpdateHitRect(self.obj)
end

-- Shows the scrollbar only while there is something to scroll. The native
-- template does the same when scrollBarHideable is set; this hook repeats
-- it so the result doesn't depend on the template script.
local function OnScrollRangeChanged(self, _, yrange)                             -- ScrollFrame
    yrange = yrange or self:GetVerticalScrollRange()
    local bar = self.obj.scrollBar
    if math.floor(yrange or 0) > 0 then
        bar:Show()
    else
        bar:Hide()
        self:SetVerticalScroll(0)
    end
    UpdateHitRect(self.obj)
end

--[[ Layout ]]

-- Places the scrollbar just right of the box so its arrows start and end
-- exactly at the box's top and bottom edges. Arrow heights are measured.
--
-- The column reserved right of the box is as wide as the widest of the bar
-- and its arrows, plus a small margin, so nothing is clipped by a parent
-- scroll frame's edge.
local function AnchorScrollBar(self)
    local bar, box = self.scrollBar, self.box
    local up, down = self.upButton, self.downButton
    local upHeight = up and up:GetHeight() or 16
    local downHeight = down and down:GetHeight() or 16
    local column = math.max(BAR_WIDTH, up and up:GetWidth() or 0, down and down:GetWidth() or 0)
    box:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -(BAR_GAP + column + BAR_RIGHT_MARGIN), 0)
    -- The track is as wide as the arrows, like every other scrollbar.
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", BAR_GAP, -upHeight)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", BAR_GAP, downHeight)
    bar:SetWidth(column)
    if up then
        up:ClearAllPoints()
        up:SetPoint("BOTTOM", bar, "TOP")
    end
    if down then
        down:ClearAllPoints()
        down:SetPoint("TOP", bar, "BOTTOM")
    end
end

local function Layout(self)
    local labelHeight = 0
    if self.tabText and self.tabText ~= "" then
        labelHeight = Theme.SECTION_TAB_HEIGHT - TAB_OVERLAP
    elseif self.labelText and self.labelText ~= "" then
        -- Measured from the font, so descenders ("p", "g") are never clipped.
        labelHeight = math.ceil(self.label:GetStringHeight() or 10) + LABEL_GAP
    end
    self.box:ClearAllPoints()
    self.box:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -labelHeight)
    -- The box's right edge depends on the scrollbar column: set there.
    self:SetHeight(labelHeight + self.numlines * LINE_HEIGHT + 2 * BOX_PADDING + 2)
    AnchorScrollBar(self)
end

--[[ Methods ]]
local methods = {
    ["OnAcquire"] = function(self)
        self.readOnly = false
        self.highlighter = nil
        self.highlightContext = nil
        self.highlightKey = nil
        self.highlightTimer:Hide()
        self.numlines = 4
        self.tabText = nil
        self.tab:Hide()
        self:SetLabel("")
        self:SetText("")
        self:SetWidth(200)
        self:SetRightReserve(0)
        self.editBox:SetFontObject(Theme.TextFont())
        self.editBox:SetMaxLetters(0)
    end,

    ["OnRelease"] = function(self)
        self:ClearFocus()
        self.highlightTimer:Hide()
        self.highlighter = nil
        self:SetOverlay(nil)
    end,

    -- fn(plainText, context) -> text with color codes. nil turns
    -- highlighting off (the box then shows and returns plain text as is).
    ["SetHighlighter"] = function(self, fn)
        self.highlighter = fn
        self:ApplyHighlight()
    end,

    -- Extra input for the highlighter (error lines, the active branch...).
    -- `key` identifies the context's content: an unchanged key is a no-op,
    -- so callers can push the context on every refresh for free.
    ["SetHighlightContext"] = function(self, context, key)
        if key ~= nil and key == self.highlightKey then
            return
        end
        self.highlightContext = context
        self.highlightKey = key
        if not self.highlighter then
            return
        end
        if self.editBox:HasFocus() then
            -- A context change comes from game state, not from the player:
            -- don't rewrite the text (and drop a selection) under the
            -- cursor. The next keystroke recolors anyway; otherwise it is
            -- applied when the box loses focus.
            self.highlightPending = true
        else
            self:ScheduleHighlight()
        end
    end,

    ["ScheduleHighlight"] = function(self)
        local timer = self.highlightTimer
        timer.elapsed = 0
        timer:Show()
    end,

    -- Rebuilds the color codes now, keeping the cursor on the same plain
    -- character and the view where it was. A no-op when nothing changed.
    ["ApplyHighlight"] = function(self)
        self.highlightTimer:Hide()
        self.highlightPending = nil
        local editBox = self.editBox
        local raw = editBox:GetText() or ""
        local plain = StripCodes(raw)
        local colored = self.highlighter and self.highlighter(plain, self.highlightContext) or plain
        if colored == raw then
            return
        end
        local cursor = PlainOffset(raw, editBox:GetCursorPosition() or 0)
        local scroll = self.scrollFrame:GetVerticalScroll()
        editBox:SetText(colored)
        editBox:SetCursorPosition(RawOffset(colored, cursor))
        if scroll then
            self.scrollFrame:SetVerticalScroll(scroll)
        end
        UpdateHitRect(self)
    end,

    ["SetLabel"] = function(self, text)
        self.labelText = text or ""
        self.label:SetText(self.labelText)
        if self.labelText ~= "" and not (self.tabText and self.tabText ~= "") then
            self.label:Show()
        else
            self.label:Hide()
        end
        Layout(self)
    end,

    -- A gold section tab on the box's top-left corner instead of a plain
    -- label ("COMPILED PREVIEW"). nil or "" removes it.
    ["SetSectionTab"] = function(self, text)
        self.tabText = text or ""
        if self.tabText ~= "" then
            self.tab:SetText(self.tabText)
            self.tab:Show()
            self.label:Hide()
        else
            self.tab:Hide()
            if self.labelText and self.labelText ~= "" then
                self.label:Show()
            end
        end
        Layout(self)
    end,

    -- Units at the box's right kept clear of the text (something drawn
    -- inside the box there: the bank editor's icons).
    ["SetRightReserve"] = function(self, units)
        local scrollFrame = self.scrollFrame
        scrollFrame:ClearAllPoints()
        scrollFrame:SetPoint("TOPLEFT", self.box, "TOPLEFT", BOX_PADDING + 1, -BOX_PADDING)
        scrollFrame:SetPoint("BOTTOMRIGHT", self.box, "BOTTOMRIGHT", -(BOX_PADDING + (units or 0)), BOX_PADDING)
    end,

    -- A frame of its owner's drawn in the box's top right corner (the
    -- Compiler's icons), the text kept clear of its width plus `inset`;
    -- hidden and let go when the widget is released (the pool hands the
    -- box to someone else). nil: none. width: the frame's (default its
    -- GetWidth).
    ["SetOverlay"] = function(self, frame, inset, width)
        local old = self.overlay
        if old and old ~= frame then
            old:Hide()
            old:ClearAllPoints()
        end
        self.overlay = frame
        if not frame then
            self:SetRightReserve(0)
            return
        end
        inset = inset or 0
        frame:SetParent(self.box)
        frame:ClearAllPoints()
        frame:SetPoint("TOPRIGHT", self.box, "TOPRIGHT", -inset, -inset)
        frame:SetFrameLevel(self.box:GetFrameLevel() + 5)
        frame:Show()
        self:SetRightReserve((width or frame:GetWidth()) + inset)
    end,

    ["SetNumLines"] = function(self, lines)
        self.numlines = math.max(1, lines or 4)
        Layout(self)
    end,

    ["SetText"] = function(self, text)
        self.text = text or ""
        self.highlightTimer:Hide()
        local shown = self.text
        if self.highlighter then
            shown = self.highlighter(self.text, self.highlightContext) or self.text
        end
        self.editBox:SetText(shown)
        self.editBox:HighlightText(0, 0)
        self.editBox:SetCursorPosition(0)
        self.scrollFrame:SetVerticalScroll(0)
        UpdateHitRect(self)
    end,

    -- The cursor as a plain-text offset (0 = before the first character).
    ["GetCursorOffset"] = function(self)
        local cursor = self.editBox:GetCursorPosition() or 0
        if self.highlighter then
            return PlainOffset(self.editBox:GetText() or "", cursor)
        end
        return cursor
    end,

    -- SetText for a change the player didn't type (a line inserted above the
    -- cursor): the cursor goes to plain offset `cursor` and the view follows
    -- the `lineShift` lines inserted above it, instead of jumping to the top.
    ["ReplaceText"] = function(self, text, cursor, lineShift)
        local scroll = self.scrollFrame:GetVerticalScroll() or 0
        self:SetText(text)
        local raw = self.editBox:GetText() or ""
        self.editBox:SetCursorPosition(self.highlighter and RawOffset(raw, cursor) or cursor)
        self.scrollFrame:SetVerticalScroll(math.max(0, scroll + (lineShift or 0) * LINE_HEIGHT))
        UpdateHitRect(self)
    end,

    -- Always the plain text: color codes are a display detail of this box.
    ["GetText"] = function(self)
        local raw = self.editBox:GetText() or ""
        if self.highlighter then
            return StripCodes(raw)
        end
        return raw
    end,

    ["SetReadOnly"] = function(self, readOnly)
        self.readOnly = readOnly and true or false
    end,

    ["SetMaxLetters"] = function(self, count)
        self.editBox:SetMaxLetters(count or 0)
    end,

    ["DisableButton"] = function()
        -- Compatibility with MultiLineEditBox call sites: no accept button.
    end,

    ["ClearFocus"] = function(self)
        self.editBox:ClearFocus()
    end,

    ["SetFocus"] = function(self)
        self.editBox:SetFocus()
    end,

    ["HighlightText"] = function(self, from, to)
        self.editBox:HighlightText(from, to)
    end,
}

--[[ Constructor ]]
local function Constructor()
    widgetCount = widgetCount + 1
    local name = "WMCTextArea" .. widgetCount

    local frame = CreateFrame("Frame", nil, UIParent)
    frame:Hide()

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    label:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    label:SetJustifyH("LEFT")

    local box = CreateFrame("Frame", nil, frame)
    box:EnableMouse(true)
    local panel = Theme.CreatePanel(box)

    -- Above the box, so the tab sits on the panel's top edge.
    local tab = Theme.CreateSectionTab(frame)
    tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    tab:SetFrameLevel(box:GetFrameLevel() + 3)
    tab:Hide()

    local scrollFrame = CreateFrame("ScrollFrame", name .. "ScrollFrame", box, "UIPanelScrollFrameTemplate")
    scrollFrame.scrollBarHideable = 1
    scrollFrame:SetPoint("TOPLEFT", box, "TOPLEFT", BOX_PADDING + 1, -BOX_PADDING)
    scrollFrame:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -BOX_PADDING, BOX_PADDING)

    local scrollBar = _G[name .. "ScrollFrameScrollBar"]
    local upButton = _G[name .. "ScrollFrameScrollBarScrollUpButton"]
    local downButton = _G[name .. "ScrollFrameScrollBarScrollDownButton"]
    Theme.SkinScrollBar(scrollBar, upButton, downButton)
    scrollBar:Hide()

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    -- As in MultiLineEditBox: a multi-line EditBox grows with its text;
    -- OnSizeChanged keeps its width equal to the scroll frame's.
    editBox:SetAllPoints()
    editBox:SetFontObject(Theme.TextFont())
    editBox:SetMultiLine(true)
    editBox:EnableMouse(true)
    editBox:SetAutoFocus(false)
    editBox:SetCountInvisibleLetters(false)
    editBox:SetScript("OnCursorChanged", OnCursorChanged)
    editBox:SetScript("OnEditFocusGained", OnEditFocusGained)
    editBox:SetScript("OnEditFocusLost", OnEditFocusLost)
    editBox:SetScript("OnEnter", OnEnter)
    editBox:SetScript("OnLeave", OnLeave)
    editBox:SetScript("OnEscapePressed", editBox.ClearFocus)
    editBox:SetScript("OnMouseDown", OnReceiveDrag)
    editBox:SetScript("OnReceiveDrag", OnReceiveDrag)
    editBox:SetScript("OnTextChanged", OnTextChanged)
    editBox:SetScript("OnSizeChanged", OnEditBoxSizeChanged)
    scrollFrame:SetScrollChild(editBox)

    scrollFrame:SetScript("OnEnter", OnEnter)
    scrollFrame:SetScript("OnLeave", OnLeave)
    scrollFrame:SetScript("OnMouseUp", OnMouseUp)
    scrollFrame:SetScript("OnReceiveDrag", OnReceiveDrag)
    scrollFrame:SetScript("OnSizeChanged", OnSizeChanged)
    scrollFrame:HookScript("OnVerticalScroll", OnVerticalScroll)
    scrollFrame:HookScript("OnScrollRangeChanged", OnScrollRangeChanged)
    box:SetScript("OnMouseUp", OnMouseUp)

    local widget = {
        frame = frame,
        label = label,
        tab = tab,
        box = box,
        panel = panel,
        scrollFrame = scrollFrame,
        scrollBar = scrollBar,
        upButton = upButton,
        downButton = downButton,
        editBox = editBox,
        numlines = 4,
        labelText = "",
        text = "",
        type = Type,
    }
    for method, func in pairs(methods) do
        widget[method] = func
    end
    editBox.obj, scrollFrame.obj, box.obj = widget, widget, widget

    local highlightTimer = CreateFrame("Frame", nil, frame)
    highlightTimer:Hide()
    highlightTimer:SetScript("OnUpdate", HighlightTimer_OnUpdate)
    highlightTimer.obj = widget
    widget.highlightTimer = highlightTimer

    -- Hiding the box (window closed, editor redrawn) gives focus back.
    frame:SetScript("OnHide", function()
        editBox:ClearFocus()
    end)
    frame:SetScript("OnShow", function()
        AnchorScrollBar(widget)
        OnScrollRangeChanged(scrollFrame)
    end)

    -- Layout needs SetHeight, which RegisterAsWidget provides; OnAcquire
    -- (run by AceGUI:Create) lays the widget out.
    return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)

-- Exposed for the highlighter (UI.lua) and the tests.
addon.TextCodes = { Strip = StripCodes, PlainOffset = PlainOffset, RawOffset = RawOffset }
