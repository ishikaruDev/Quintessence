local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme

--[[-----------------------------------------------------------------------------
Themed input controls, WMC-owned (own pools, like Widgets.lua): WMC-EditBox,
WMC-Dropdown, WMC-CheckBox, WMC-Icon and WMC-ScrollFrame. Each keeps the API
of the AceGUI widget it replaces, so UI.lua's calls stay the same; the art
comes from the theme instead of the Blizzard templates (and is never applied
to AceGUI's shared, pooled widgets).
-------------------------------------------------------------------------------]]

local LABEL_HEIGHT = 18
local FIELD_HEIGHT = 24
local FIELD_TEXT_INSET = 8

--[[-----------------------------------------------------------------------------
WMC-EditBox: a one-line field with an optional label above it.

Layout, top to bottom: [label 18][field 24]. The input box itself carries
the field art, so it is also its own visible region: `editbox.backdrop`
points at it, which lets UI.lua glue buttons to the field's exact edges
(anchorToBox). `boxLeft` (0) is the box's x offset in the widget, used when
UI.lua nudges the box's top edge onto a pixel line.

Methods: SetLabel, SetText, GetText, SetDisabled, SetMaxLetters,
DisableButton (no-op: Enter saves, there is no Okay button), SetFocus,
ClearFocus, HighlightText, SetSideButton(button) (a button at the field's
right end, as a dropdown's chevron; the field narrows; nil: none; let go
on release). Callbacks: OnTextChanged (on changes made by the
user, not by SetText), OnEnterPressed, OnEnter, OnLeave.
-------------------------------------------------------------------------------]]
do
    local Type, Version = "WMC-EditBox", 1

    local function EditBox_OnEnterPressed(editbox)
        local self = editbox.obj
        self:Fire("OnEnterPressed", editbox:GetText())
    end

    local function EditBox_OnEscapePressed(editbox)
        editbox:ClearFocus()
    end

    local function EditBox_OnTextChanged(editbox)
        local self = editbox.obj
        local value = editbox:GetText()
        if tostring(value) ~= tostring(self.lasttext) then
            self.lasttext = value
            self:Fire("OnTextChanged", value)
        end
    end

    local function EditBox_OnFocusGained(editbox)
        local self = editbox.obj
        self.slice:SetPiece("field-focus")
        if AceGUI.SetFocus then
            AceGUI:SetFocus(self)
        end
    end

    local function EditBox_OnFocusLost(editbox)
        local self = editbox.obj
        self.slice:SetPiece("field-normal")
        editbox:HighlightText(0, 0)
        if AceGUI.FocusedWidget == self then
            AceGUI.FocusedWidget = nil
        end
    end

    local function Control_OnEnter(frame)
        frame.obj:Fire("OnEnter")
    end

    local function Control_OnLeave(frame)
        frame.obj:Fire("OnLeave")
    end

    local methods = {
        ["OnAcquire"] = function(self)
            self:SetWidth(200)
            self:SetDisabled(false)
            self:SetLabel()
            self:SetText()
            self:SetMaxLetters(0)
            self.slice:SetPiece("field-normal")
        end,

        ["OnRelease"] = function(self)
            self.editbox:ClearFocus()
            self:SetSideButton(nil)
        end,

        ["SetSideButton"] = function(self, button)
            local editbox = self.editbox
            if self.sideButton and self.sideButton ~= button then
                self.sideButton:Hide()
                self.sideButton:ClearAllPoints()
            end
            self.sideButton = button
            editbox:ClearAllPoints()
            editbox:SetPoint("TOPLEFT", self.frame, "TOPLEFT", self.boxLeft,
                self.label:IsShown() and -LABEL_HEIGHT or 0)
            if button then
                button:SetParent(self.frame)
                button:ClearAllPoints()
                button:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", 0, 0)
                button:Show()
                editbox:SetPoint("BOTTOMRIGHT", button, "BOTTOMLEFT", 0, 0)
            else
                editbox:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", 0, 0)
            end
        end,

        ["SetDisabled"] = function(self, disabled)
            self.disabled = disabled and true or false
            local editbox = self.editbox
            if self.disabled then
                editbox:EnableMouse(false)
                editbox:ClearFocus()
                editbox:SetTextColor(0.5, 0.5, 0.5)
                self.label:SetTextColor(0.5, 0.5, 0.5)
            else
                editbox:EnableMouse(true)
                editbox:SetTextColor(1, 1, 1)
                self.label:SetTextColor(unpack(Theme.colors.label))
            end
        end,

        ["SetText"] = function(self, text)
            self.lasttext = text or ""
            self.editbox:SetText(text or "")
            self.editbox:SetCursorPosition(0)
        end,

        ["GetText"] = function(self)
            return self.editbox:GetText()
        end,

        ["SetLabel"] = function(self, text)
            local editbox = self.editbox
            if text and text ~= "" then
                self.label:SetText(text)
                self.label:Show()
                editbox:SetPoint("TOPLEFT", self.frame, "TOPLEFT", self.boxLeft, -LABEL_HEIGHT)
                self:SetHeight(LABEL_HEIGHT + FIELD_HEIGHT)
                self.alignoffset = LABEL_HEIGHT + FIELD_HEIGHT / 2
            else
                self.label:SetText("")
                self.label:Hide()
                editbox:SetPoint("TOPLEFT", self.frame, "TOPLEFT", self.boxLeft, 0)
                self:SetHeight(FIELD_HEIGHT)
                self.alignoffset = FIELD_HEIGHT / 2
            end
        end,

        ["DisableButton"] = function()
            -- Compatibility with AceGUI's EditBox call sites.
        end,

        ["SetMaxLetters"] = function(self, count)
            self.editbox:SetMaxLetters(count or 0)
        end,

        ["SetFocus"] = function(self)
            self.editbox:SetFocus()
        end,

        ["ClearFocus"] = function(self)
            self.editbox:ClearFocus()
        end,

        ["HighlightText"] = function(self, from, to)
            self.editbox:HighlightText(from, to)
        end,
    }

    local function Constructor()
        local frame = CreateFrame("Frame", nil, UIParent)
        frame:Hide()

        local editbox = CreateFrame("EditBox", nil, frame)
        editbox:SetAutoFocus(false)
        editbox:SetFontObject(Theme.TextFont())
        editbox:SetTextInsets(FIELD_TEXT_INSET, FIELD_TEXT_INSET, 0, 0)
        editbox:SetMaxLetters(256)
        editbox:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        editbox:SetScript("OnEnter", Control_OnEnter)
        editbox:SetScript("OnLeave", Control_OnLeave)
        editbox:SetScript("OnEnterPressed", EditBox_OnEnterPressed)
        editbox:SetScript("OnEscapePressed", EditBox_OnEscapePressed)
        editbox:SetScript("OnTextChanged", EditBox_OnTextChanged)
        editbox:SetScript("OnEditFocusGained", EditBox_OnFocusGained)
        editbox:SetScript("OnEditFocusLost", EditBox_OnFocusLost)
        -- The box draws its own field art: it is its own visible region.
        editbox.backdrop = editbox

        local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -2)
        label:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -2)
        label:SetJustifyH("LEFT")
        label:SetHeight(LABEL_HEIGHT)

        local widget = {
            alignoffset = LABEL_HEIGHT + FIELD_HEIGHT / 2,
            editbox = editbox,
            label = label,
            frame = frame,
            slice = Theme.CreateSlice(editbox, "BACKGROUND"),
            boxLeft = 0,
            buttonGap = 6,
            type = Type,
        }
        for method, func in pairs(methods) do
            widget[method] = func
        end
        editbox.obj = widget
        return AceGUI:RegisterAsWidget(widget)
    end

    AceGUI:RegisterWidgetType(Type, Constructor, Version)
end

--[[-----------------------------------------------------------------------------
WMC-Dropdown: a field showing the chosen value, with the chevron button at
its right end; clicking either opens its list -- WMC's own menu
(addon.Menu, Popups.lua), opened under the field at the dropdown's full
width, the current value checked. Clicking the field again, a click
outside, Escape or a choice closes it; a choice closes it, then fires
OnValueChanged (choosing the current value only closes it). Items keep the
order passed to SetList (AceGUI's own Dropdown of this version sorts by
key). A disabled dropdown never opens.

Methods: SetLabel, SetList(list, order), SetValue, GetValue, SetText,
SetDisabled, ClearFocus, Open, Close, IsOpen. Callback:
OnValueChanged(value), OnClosed.
-------------------------------------------------------------------------------]]
do
    local Type, Version = "WMC-Dropdown", 2

    local function Choose(self, value)
        if value == self.value then
            return
        end
        self:SetValue(value)
        self:Fire("OnValueChanged", value)
    end

    local function Open(self)
        if self.disabled then
            return
        end
        local items, selected = {}, nil
        for index, entry in ipairs(self.items) do
            local value = entry.value
            items[index] = {
                text = entry.text,
                func = function()
                    Choose(self, value)
                end,
            }
            if value == self.value then
                selected = index
            end
        end
        self.open = true
        addon.Menu:Open(items, self.box, {
            width = self.frame:GetWidth(),
            selected = selected,
            list = true,
            client = self,
            onClose = function()
                self.open = nil
                self:Fire("OnClosed")
            end,
        })
    end

    local function Close(self)
        if addon.Menu:IsOpenFor(self) then
            addon.Menu:Close()
        end
        self.open = nil
    end

    local function Toggle(self)
        if addon.Menu:IsOpenFor(self) then
            Close(self)
        else
            Open(self)
        end
    end

    local function Box_OnClick(frame)
        Toggle(frame.obj)
    end

    local function Box_OnEnter(frame)
        local self = frame.obj
        if not self.disabled then
            self.chevron:LockHighlight()
        end
        self:Fire("OnEnter")
    end

    local function Box_OnLeave(frame)
        local self = frame.obj
        self.chevron:UnlockHighlight()
        self:Fire("OnLeave")
    end

    local function Frame_OnHide(frame)
        Close(frame.obj)
    end

    local methods = {
        ["OnAcquire"] = function(self)
            self.items = {}
            self:SetWidth(200)
            self:SetLabel("")
            self:SetDisabled(false)
            self:SetText("")
        end,

        ["OnRelease"] = function(self)
            Close(self)
            self.items = {}
            self.value = nil
            self.list = nil
            self.open = nil
        end,

        ["SetLabel"] = function(self, text)
            local box = self.box
            if text and text ~= "" then
                self.label:SetText(text)
                self.label:Show()
                box:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -LABEL_HEIGHT)
                self:SetHeight(LABEL_HEIGHT + FIELD_HEIGHT)
                self.alignoffset = LABEL_HEIGHT + FIELD_HEIGHT / 2
            else
                self.label:SetText("")
                self.label:Hide()
                box:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 0)
                self:SetHeight(FIELD_HEIGHT)
                self.alignoffset = FIELD_HEIGHT / 2
            end
        end,

        ["SetText"] = function(self, text)
            self.text:SetText(text or "")
        end,

        ["SetValue"] = function(self, value)
            if self.list then
                self:SetText(self.list[value] or "")
            end
            self.value = value
        end,

        ["GetValue"] = function(self)
            return self.value
        end,

        -- order: keys in display order; nil sorts the keys.
        ["SetList"] = function(self, list, order)
            self.list = list
            Close(self)
            self.items = {}
            if not list then
                return
            end
            local keys = order
            if not keys then
                keys = {}
                for key in pairs(list) do
                    table.insert(keys, key)
                end
                table.sort(keys, function(a, b)
                    return tostring(a) < tostring(b)
                end)
            end
            for _, key in ipairs(keys) do
                if list[key] then
                    table.insert(self.items, { value = key, text = list[key] })
                end
            end
            if self.value ~= nil then
                self:SetText(list[self.value] or "")
            end
        end,

        ["SetDisabled"] = function(self, disabled)
            self.disabled = disabled and true or false
            if self.disabled then
                Close(self)
                self.box:Disable()
                self.chevron:Disable()
                self.text:SetTextColor(0.5, 0.5, 0.5)
                self.label:SetTextColor(0.5, 0.5, 0.5)
            else
                self.box:Enable()
                self.chevron:Enable()
                self.text:SetTextColor(1, 1, 1)
                self.label:SetTextColor(unpack(Theme.colors.label))
            end
        end,

        ["ClearFocus"] = function(self)
            Close(self)
        end,

        ["Open"] = Open,
        ["Close"] = Close,

        ["IsOpen"] = function(self)
            return addon.Menu:IsOpenFor(self)
        end,
    }

    local function Constructor()
        local frame = CreateFrame("Frame", nil, UIParent)
        frame:Hide()
        frame:SetScript("OnHide", Frame_OnHide)

        local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -2)
        label:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -2)
        label:SetJustifyH("LEFT")
        label:SetHeight(LABEL_HEIGHT)

        local chevronWidth = Theme.PieceSize("chevron-normal")
        local chevron = CreateFrame("Button", nil, frame)
        chevron:SetWidth(chevronWidth)
        chevron:SetHeight(FIELD_HEIGHT)
        chevron:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        Theme.SetButtonPiece(chevron, "Normal", "chevron-normal")
        Theme.SetButtonPiece(chevron, "Pushed", "chevron-pressed")
        Theme.SetButtonPiece(chevron, "Disabled", "chevron-disabled")
        Theme.SetButtonPiece(chevron, "Highlight", "chevron-hover")
        chevron:SetScript("OnClick", Box_OnClick)

        local box = CreateFrame("Button", nil, frame)
        box:SetPoint("BOTTOMRIGHT", chevron, "BOTTOMLEFT", 0, 0)
        box:RegisterForClicks("LeftButtonUp")
        box:SetScript("OnClick", Box_OnClick)
        box:SetScript("OnEnter", Box_OnEnter)
        box:SetScript("OnLeave", Box_OnLeave)
        local slice = Theme.CreateSlice(box, "BACKGROUND")
        slice:SetPiece("field-normal")

        local text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("LEFT", box, "LEFT", FIELD_TEXT_INSET, 0)
        text:SetPoint("RIGHT", box, "RIGHT", -4, 0)
        text:SetJustifyH("LEFT")

        local widget = {
            alignoffset = LABEL_HEIGHT + FIELD_HEIGHT / 2,
            frame = frame,
            box = box,
            chevron = chevron,
            button = chevron, -- AceGUI Dropdown's name for it
            text = text,
            label = label,
            slice = slice,
            items = {},
            type = Type,
        }
        for method, func in pairs(methods) do
            widget[method] = func
        end
        frame.obj, box.obj, chevron.obj = widget, widget, widget
        return AceGUI:RegisterAsWidget(widget)
    end

    AceGUI:RegisterWidgetType(Type, Constructor, Version)
end

--[[-----------------------------------------------------------------------------
WMC-CheckBox: a brass square with a gold check, and a label.
Methods: SetLabel, SetValue, GetValue, SetDisabled.
Callback: OnValueChanged(checked).
-------------------------------------------------------------------------------]]
do
    local Type, Version = "WMC-CheckBox", 1
    local HEIGHT = 24

    local function UpdateLook(self)
        Theme.SetPiece(self.box, self.disabled and "check-disabled" or "check-box")
        if self.checked then
            self.check:Show()
            self.check:SetVertexColor(1, 1, 1, self.disabled and 0.5 or 1)
        else
            self.check:Hide()
        end
    end

    local function OnClick(frame)
        local self = frame.obj
        if self.disabled then
            return
        end
        AceGUI:ClearFocus()
        self.checked = not self.checked
        UpdateLook(self)
        if PlaySound then
            PlaySound(self.checked and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
        end
        self:Fire("OnValueChanged", self.checked)
    end

    local function Control_OnEnter(frame)
        frame.obj:Fire("OnEnter")
    end

    local function Control_OnLeave(frame)
        frame.obj:Fire("OnLeave")
    end

    local methods = {
        ["OnAcquire"] = function(self)
            self.alignoffset = nil
            self:SetValue(false)
            self:SetLabel("")
            self:SetDisabled(false)
            self:SetWidth(200)
            self:SetHeight(HEIGHT)
        end,

        ["SetLabel"] = function(self, text)
            self.text:SetText(text or "")
        end,

        ["SetValue"] = function(self, value)
            self.checked = value and true or false
            UpdateLook(self)
        end,

        ["GetValue"] = function(self)
            return self.checked
        end,

        ["SetDisabled"] = function(self, disabled)
            self.disabled = disabled and true or false
            if self.disabled then
                self.frame:Disable()
                self.text:SetTextColor(0.5, 0.5, 0.5)
            else
                self.frame:Enable()
                self.text:SetTextColor(1, 1, 1)
            end
            UpdateLook(self)
        end,
    }

    local function Constructor()
        local frame = CreateFrame("Button", nil, UIParent)
        frame:Hide()
        frame:EnableMouse(true)
        frame:SetScript("OnClick", OnClick)
        frame:SetScript("OnEnter", Control_OnEnter)
        frame:SetScript("OnLeave", Control_OnLeave)

        local boxWidth, boxHeight = Theme.PieceSize("check-box")
        local box = frame:CreateTexture(nil, "ARTWORK")
        box:SetWidth(boxWidth)
        box:SetHeight(boxHeight)
        box:SetPoint("LEFT", frame, "LEFT", 0, 0)

        local checkWidth, checkHeight = Theme.PieceSize("check-mark")
        local check = frame:CreateTexture(nil, "OVERLAY")
        check:SetWidth(checkWidth)
        check:SetHeight(checkHeight)
        check:SetPoint("CENTER", box, "CENTER", 1, 1)
        Theme.SetPiece(check, "check-mark")

        local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetJustifyH("LEFT")
        text:SetPoint("LEFT", box, "RIGHT", 6, 0)
        text:SetPoint("RIGHT", frame, "RIGHT", 0, 0)

        local widget = {
            frame = frame,
            box = box,
            check = check,
            checkbg = box, -- AceGUI CheckBox's name for it
            text = text,
            type = Type,
        }
        for method, func in pairs(methods) do
            widget[method] = func
        end
        frame.obj = widget
        return AceGUI:RegisterAsWidget(widget)
    end

    AceGUI:RegisterWidgetType(Type, Constructor, Version)
end

--[[-----------------------------------------------------------------------------
WMC-Icon: the editor's clickable template icon in a brass slot frame.
Methods: SetImage(path [, left, right, top, bottom]), SetImageSize(w, h),
SetLabel (no-op). Field: image. Callback: OnClick.
-------------------------------------------------------------------------------]]
do
    local Type, Version = "WMC-Icon", 1
    local SLOT_RATIO = 34 / 24 -- slot art size per icon size (its opening)

    local function OnClick(frame)
        AceGUI:ClearFocus()
        frame.obj:Fire("OnClick")
    end

    local methods = {
        ["OnAcquire"] = function(self)
            self:SetImage(nil)
            self:SetImageSize(24, 24)
            self:SetWidth(32)
            self:SetHeight(32)
        end,

        ["SetImage"] = function(self, path, ...)
            local image = self.image
            image:SetTexture(path)
            if select("#", ...) == 4 then
                image:SetTexCoord(...)
            else
                image:SetTexCoord(0, 1, 0, 1)
            end
        end,

        ["SetImageSize"] = function(self, width, height)
            self.image:SetWidth(width)
            self.image:SetHeight(height)
            self.slot:SetWidth(math.floor(width * SLOT_RATIO + 0.5))
            self.slot:SetHeight(math.floor(height * SLOT_RATIO + 0.5))
        end,

        ["SetLabel"] = function()
        end,
    }

    local function Constructor()
        local frame = CreateFrame("Button", nil, UIParent)
        frame:Hide()
        frame:EnableMouse(true)
        frame:SetScript("OnClick", OnClick)

        local image = frame:CreateTexture(nil, "ARTWORK")
        image:SetPoint("CENTER", frame, "CENTER", 0, 0)

        local slot = frame:CreateTexture(nil, "OVERLAY")
        slot:SetPoint("CENTER", frame, "CENTER", 0, 0)
        Theme.SetPiece(slot, "icon-slot")

        local highlight = frame:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints(image)
        highlight:SetTexture(1, 1, 1, 0.15)
        highlight:SetBlendMode("ADD")

        local widget = { frame = frame, image = image, slot = slot, type = Type }
        for method, func in pairs(methods) do
            widget[method] = func
        end
        frame.obj = widget
        return AceGUI:RegisterAsWidget(widget)
    end

    AceGUI:RegisterWidgetType(Type, Constructor, Version)
end

--[[-----------------------------------------------------------------------------
WMC-ScrollFrame container: AceGUI's ScrollFrame (same methods, same status
table, same scroll arithmetic -- adapted from AceGUI-3.0, BSD licence) with
the themed scrollbar. SetFramed(true) draws a panel around it and insets the
scroll area inside the panel (the template list).

SetBarBottomInset(units) ends the scrollbar (its down arrow included) that
far above the frame's bottom, clear of window art that reaches into the
corner (the main window's gear housing); the scroll area keeps its height.
-------------------------------------------------------------------------------]]
do
    local Type, Version = "WMC-ScrollFrame", 2
    local min, max, floor = math.min, math.max, math.floor
    local BAR_SPACE = 20 -- scrollbar column taken from the content when shown
    local FRAMED_PAD = 6

    local function FixScrollOnUpdate(frame)
        frame:SetScript("OnUpdate", nil)
        frame.obj:FixScroll()
    end

    local function ScrollFrame_OnMouseWheel(frame, value)
        frame.obj:MoveScroll(value)
    end

    local function ScrollFrame_OnSizeChanged(frame)
        frame:SetScript("OnUpdate", FixScrollOnUpdate)
    end

    local function ScrollBar_OnScrollValueChanged(frame, value)
        frame.obj:SetScroll(value)
    end

    -- Places the scroll area inside the frame (or panel), leaving the bar's
    -- column free while it is shown.
    local function AnchorScrollArea(self)
        local pad = self.framed and FRAMED_PAD or 0
        local scrollframe = self.scrollframe
        scrollframe:ClearAllPoints()
        scrollframe:SetPoint("TOPLEFT", self.frame, "TOPLEFT", pad, -pad)
        scrollframe:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT",
            -pad - (self.scrollBarShown and BAR_SPACE or 0), pad)
    end

    -- The bar's track runs between the arrows (each a bar width tall),
    -- the down arrow ending `barBottomInset` above the scroll area's bottom.
    local function AnchorScrollBar(self)
        local bar = self.scrollbar
        local size = Theme.SCROLLBAR_WIDTH
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", self.scrollframe, "TOPRIGHT", 4, -size)
        bar:SetPoint("BOTTOMLEFT", self.scrollframe, "BOTTOMRIGHT", 4, size + (self.barBottomInset or 0))
    end

    local methods = {
        ["OnAcquire"] = function(self)
            self:SetFramed(false)
            self:SetBarBottomInset(0)
            self:SetScroll(0)
        end,

        ["SetBarBottomInset"] = function(self, units)
            self.barBottomInset = math.max(0, units or 0)
            AnchorScrollBar(self)
        end,

        ["OnRelease"] = function(self)
            self.status = nil
            for key in pairs(self.localstatus) do
                self.localstatus[key] = nil
            end
            self.scrollbar:Hide()
            self.scrollBarShown = nil
            AnchorScrollArea(self)
            self.content.height, self.content.width = nil, nil
        end,

        ["SetFramed"] = function(self, framed)
            self.framed = framed and true or false
            if self.framed then
                self.panel:Show()
            else
                self.panel:Hide()
            end
            AnchorScrollArea(self)
        end,

        ["SetScroll"] = function(self, value)
            local status = self.status or self.localstatus
            local viewheight = self.scrollframe:GetHeight()
            local height = self.content:GetHeight()
            local offset
            if viewheight > height then
                offset = 0
            else
                offset = floor((height - viewheight) / 1000.0 * value)
            end
            self.content:ClearAllPoints()
            self.content:SetPoint("TOPLEFT", 0, offset)
            self.content:SetPoint("TOPRIGHT", 0, offset)
            status.offset = offset
            status.scrollvalue = value
            -- Arrows grey out at the ends, as on the text areas' bars.
            local up, down = self.upButton, self.downButton
            if up and down then
                if offset > 0 then up:Enable() else up:Disable() end
                if offset < floor(height - viewheight) then down:Enable() else down:Disable() end
            end
        end,

        ["MoveScroll"] = function(self, value)
            local status = self.status or self.localstatus
            local height, viewheight = self.scrollframe:GetHeight(), self.content:GetHeight()
            if self.scrollBarShown then
                local diff = height - viewheight
                local delta = 1
                if value < 0 then
                    delta = -1
                end
                self.scrollbar:SetValue(min(max(status.scrollvalue + delta * (1000 / (diff / 45)), 0), 1000))
            end
        end,

        ["FixScroll"] = function(self)
            if self.updateLock then
                return
            end
            self.updateLock = true
            local status = self.status or self.localstatus
            local height, viewheight = self.scrollframe:GetHeight(), self.content:GetHeight()
            local offset = status.offset or 0
            -- A 2-unit margin stops floating-point noise from toggling the bar.
            if viewheight < height + 2 then
                if self.scrollBarShown then
                    self.scrollBarShown = nil
                    self.scrollbar:Hide()
                    self.scrollbar:SetValue(0)
                    AnchorScrollArea(self)
                    self:DoLayout()
                end
            else
                if not self.scrollBarShown then
                    self.scrollBarShown = true
                    self.scrollbar:Show()
                    AnchorScrollArea(self)
                    self:DoLayout()
                end
                local value = (offset / (viewheight - height) * 1000)
                if value > 1000 then
                    value = 1000
                end
                self.scrollbar:SetValue(value)
                self:SetScroll(value)
                if value < 1000 then
                    self.content:ClearAllPoints()
                    self.content:SetPoint("TOPLEFT", 0, offset)
                    self.content:SetPoint("TOPRIGHT", 0, offset)
                    status.offset = offset
                end
            end
            self.updateLock = nil
        end,

        ["LayoutFinished"] = function(self, width, height)
            self.content:SetHeight(height or 0 + 20)
            self.scrollframe:SetScript("OnUpdate", FixScrollOnUpdate)
        end,

        ["SetStatusTable"] = function(self, status)
            assert(type(status) == "table")
            self.status = status
            if not status.scrollvalue then
                status.scrollvalue = 0
            end
        end,

        ["OnWidthSet"] = function(self, width)
            local content = self.content
            local pad = self.framed and 2 * FRAMED_PAD or 0
            content.width = width - pad - (self.scrollBarShown and BAR_SPACE or 0)
        end,

        ["OnHeightSet"] = function(self, height)
            local content = self.content
            content.height = height - (self.framed and 2 * FRAMED_PAD or 0)
        end,
    }

    local function Constructor()
        local frame = CreateFrame("Frame", nil, UIParent)
        local num = AceGUI:GetNextWidgetNum(Type)

        local panel = Theme.CreatePanel(frame)

        local scrollframe = CreateFrame("ScrollFrame", nil, frame)
        scrollframe:EnableMouseWheel(true)
        scrollframe:SetScript("OnMouseWheel", ScrollFrame_OnMouseWheel)
        scrollframe:SetScript("OnSizeChanged", ScrollFrame_OnSizeChanged)

        -- Named: UIPanelScrollBarTemplate finds its arrows by global name.
        -- No underscore after "WMC", so it never collides with WMC_<name>.
        local scrollbar = CreateFrame("Slider", ("WMCScrollFrame%dScrollBar"):format(num), scrollframe,
            "UIPanelScrollBarTemplate")
        scrollbar:SetMinMaxValues(0, 1000)
        scrollbar:SetValueStep(1)
        scrollbar:SetValue(0)
        scrollbar:Hide()
        local upButton, downButton = Theme.ScrollBarButtons(scrollbar)
        Theme.SkinScrollBar(scrollbar, upButton, downButton)
        -- Set the script last, so it doesn't fire yet.
        scrollbar:SetScript("OnValueChanged", ScrollBar_OnScrollValueChanged)

        local content = CreateFrame("Frame", nil, scrollframe)
        content:SetPoint("TOPLEFT")
        content:SetPoint("TOPRIGHT")
        content:SetHeight(400)
        scrollframe:SetScrollChild(content)

        local widget = {
            localstatus = { scrollvalue = 0 },
            scrollframe = scrollframe,
            scrollbar = scrollbar,
            upButton = upButton,
            downButton = downButton,
            panel = panel,
            content = content,
            frame = frame,
            type = Type,
        }
        for method, func in pairs(methods) do
            widget[method] = func
        end
        scrollframe.obj, scrollbar.obj = widget, widget
        AnchorScrollArea(widget)
        AnchorScrollBar(widget)
        return AceGUI:RegisterAsContainer(widget)
    end

    AceGUI:RegisterWidgetType(Type, Constructor, Version)
end

--[[-----------------------------------------------------------------------------
The search fields' mode button (the Compiler's template search, the bank's
macro search). Its icon is the mode in use: names only (search-name) or
names and text (search-text); a click switches it.

  addon.SearchModeButton(getInText, setInText) -> the button, for
      WMC-EditBox:SetSideButton. getInText() -> whether the text is
      searched; setInText(on) stores it and refreshes the list.
  button:Refresh()  its icon from getInText()
-------------------------------------------------------------------------------]]
function addon.SearchModeButton(getInText, setInText)
    local button = CreateFrame("Button", nil, UIParent)
    button:SetWidth(FIELD_HEIGHT)
    button:SetHeight(FIELD_HEIGHT)
    function button:Refresh()
        local mode = getInText() and "search-text" or "search-name"
        Theme.SetButtonPiece(self, "Normal", mode)
        Theme.SetButtonPiece(self, "Pushed", mode .. "-pressed")
        Theme.SetButtonPiece(self, "Highlight", mode .. "-hover")
    end
    local function tooltip(frame)
        local inText = getInText()
        addon.Tooltip:SetOwner(frame, "ANCHOR_RIGHT")
        addon.Tooltip:SetText(inText and "Searching names and text" or "Searching names", 1, 1, 1)
        addon.Tooltip:AddLine(inText and "Click to search names only."
            or "Click to search inside the text too.", nil, nil, nil, true)
        addon.Tooltip:Show()
    end
    button:SetScript("OnClick", function(frame)
        if PlaySound then
            PlaySound("igMainMenuOptionCheckBoxOn")
        end
        setInText(not getInText())
        frame:Refresh()
        tooltip(frame)
    end)
    button:SetScript("OnEnter", tooltip)
    button:SetScript("OnLeave", function() addon.Tooltip:Hide() end)
    Theme.HideHoverWhileHeld(button)
    button:Refresh()
    return button
end
