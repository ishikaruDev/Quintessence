local addon = WMacroCompiler
local AceGUI = LibStub("AceGUI-3.0")
local Theme = addon.Theme

--[[-----------------------------------------------------------------------------
Guide: the in-game guide ("Arcanum"). Its pages are GuideData.lua, which
tools/build_guide.py generates from guide-draft.md (the master copy).

The window: the guide frame (a 9-slice: a thicker "panel"), a gold title
plate on the top band (the drag handle when the window is free), a close
button under the close plate's socket, a topic list on the left, and the
page: a numbered heading, the page's blocks in a scroll area, and previous /
next buttons. Below COMPACT_WIDTH the topic list shrinks to a column of
page-number badges.

The guide has two parts (guide-plan.md, "Two parts"): the Compiler's pages
and the Macros window's (page.part). The topic list has a header per part:
its emblem, its name and a divider, as the page's own heading; a click on it
opens the part's first page.

Placement (guide-plan.md): docked to the right of its host, the window it
was opened from (the main window, or the Macros window at the Macros
part: Guide.host, HOSTS), clear of
its art (side art included, when it has one), top-aligned and the same
height, anchored to it so it follows when that is dragged. If the pair would run off the right edge, the main
window slides left (back when the guide closes); if there is still no room,
the guide narrows to MIN_WIDTH; below that it opens free, overlapping the
main window's right side, draggable, its position remembered. With the main
window closed it opens alone, centred. Escape closes the guide first, then
the main window.

"Try it" opens a page's example as a new, unsaved GENERAL template in the
main window and sets its Preview-as line (UI:OpenExample).
-------------------------------------------------------------------------------]]
local Guide = { page = 1 }
addon.Guide = Guide

local PAGES = addon.GuideData
local TITLE = "Arcanum"

-- The guide's parts, in their pages' order (page.part).
local PARTS = {
    compiler = { label = "Compiler", icon = "guide-part-compiler" },
    macros = { label = "Macros", icon = "guide-part-macros" },
}

local WIDTH = 720
local MIN_WIDTH = 560
-- Below this width the topic list is a column of page numbers.
local COMPACT_WIDTH = 640
-- The background runs under the band's centre line.
local INSET = 9
-- Content area, units in from the window's edges: clear of the band, its
-- corner plates (~31 units square), the edge caps on the side bands (to
-- ~23 units in) and the title plate hanging from the top band.
local CONTENT = { left = 24, right = 24, top = 34, bottom = 20 }
local LIST_WIDTH = 204
local LIST_GAP = 12
local ROW_GAP = 3
-- A part's header: its emblem (the piece's height), then its rows.
local PART_GAP = 10       -- above every header but the first
local PART_ROW_GAP = 4    -- between a header and its first row
local PART_LABEL_GAP = 8  -- between the emblem and the name
local HEADER_HEIGHT = 34
local HEADER_GAP = 8
local FOOTER_HEIGHT = 30
-- The page keeps a scrollbar column at its right whether or not the bar
-- shows, so text wraps the same either way.
local BAR_SPACE = Theme.SCROLLBAR_WIDTH + 6
local SCROLL_STEP = 40
local DOCK_GAP = 4
-- Page blocks.
local BLOCK_GAP = 8
local HEADING_GAP = 6
local ICON_GAP = 8
local LIST_INDENT = 18
local LIST_ITEM_GAP = 3
local CELL_PAD_X = 6
local CELL_PAD_Y = 4
local CODE_PAD_X = 10
local CODE_PAD_Y = 8
-- Code examples sit on the "panel" piece, darkened.
local CODE_TINT = 0.55
local TRY_BUTTON_WIDTH = 72
local TRY_BUTTON_GAP = 6
local BUTTON_HEIGHT = 24

local NAME = "WMCGuideWindow"
-- The windows the guide docks to: their frame style (for their art's
-- reach) and their UISpecialFrames entry, which points at nothing (the name
-- .. "AfterGuide": no such global) while the guide is shown, so one Escape
-- closes only the guide.
local HOSTS = {
    main = { style = "main", escape = "WMCMainWindow", window = function() return addon.UI and addon.UI.window end },
    bank = { style = "bank", escape = "QMBWindow", window = function() return addon.BankUI and addon.BankUI.window end },
}
Guide.host = "main"

local function settings()
    local db = addon.db and addon.db.settings
    if not db then
        return nil
    end
    db.guide = db.guide or {}
    return db.guide
end

local function pieceHeight(name)
    return select(2, Theme.PieceSize(name))
end

local function textHeight(fontString, fallback)
    local value = fontString.GetStringHeight and fontString:GetStringHeight()
    return (type(value) == "number" and value > 0) and math.ceil(value) or (fallback or 14)
end

-- How far the host's art reaches past its right edge (the side art, when
-- it has one): the art's own edge (reach), else its tiles' edge.
local function mainOverhang()
    local frameData = Theme.FrameData(HOSTS[Guide.host].style)
    if frameData.reach then
        return math.max(0, frameData.reach - frameData.width)
    end
    local right = frameData.width
    for _, list in ipairs({ frameData.tiles, frameData.side or {}, frameData.housing or {} }) do
        for _, tile in ipairs(list) do
            right = math.max(right, tile[6] + tile[8])
        end
    end
    return right - frameData.width
end

-- The host window's frame (the main window's, or the Macros window's).
local function hostFrame(key)
    local window = HOSTS[key].window()
    return window and window.frame or nil
end

local function mainFrame()
    return hostFrame(Guide.host)
end

local function mainShown()
    local frame = mainFrame()
    return frame ~= nil and frame:IsShown()
end

--[[ Escape order ]]

-- Points the host's Escape entry at nothing while the guide is shown (and
-- gives every other window its own back). Restoring waits a frame:
-- CloseSpecialWindows is still walking the list when the guide hides, and
-- must not reach the host on the same key press.
local escapeFrame = CreateFrame("Frame")
escapeFrame:Hide()
local function setMainEscape(blocked)
    if not UISpecialFrames then
        return
    end
    for key, host in pairs(HOSTS) do
        local name, blockedName = host.escape, host.escape .. "AfterGuide"
        local from, to = blockedName, name
        if blocked and key == Guide.host then
            from, to = name, blockedName
        end
        for index, entry in ipairs(UISpecialFrames) do
            if entry == from then
                UISpecialFrames[index] = to
            end
        end
    end
end
escapeFrame:SetScript("OnUpdate", function(frame)
    frame:Hide()
    if not (Guide.frame and Guide.frame:IsShown()) then
        setMainEscape(false)
    end
end)
Guide.escapeFrame = escapeFrame

--[[ Small parts ]]

-- A Button drawn with whole pieces: normal, hover (drawn over it), pressed;
-- disabled dims the normal art.
local function pieceButton(parent, piece)
    local button = CreateFrame("Button", nil, parent)
    local width, height = Theme.PieceSize(piece)
    button:SetWidth(width)
    button:SetHeight(height)
    Theme.SetButtonPiece(button, "Normal", piece)
    Theme.SetButtonPiece(button, "Highlight", piece .. "-hover")
    Theme.SetButtonPiece(button, "Pushed", piece .. "-pressed")
    local disabled = Theme.SetButtonPiece(button, "Disabled", piece)
    if disabled and disabled.SetVertexColor then
        disabled:SetVertexColor(0.4, 0.4, 0.4)
    end
    return button
end

local function pieceTexture(parent, piece, layer)
    local texture = parent:CreateTexture(nil, layer or "ARTWORK")
    Theme.SetPiece(texture, piece)
    local width, height = Theme.PieceSize(piece)
    texture:SetWidth(width)
    texture:SetHeight(height)
    return texture
end

--[[ Window ]]

local function Title_OnMouseDown(frame)
    local guide = frame.guide
    if not guide.docked then
        guide.frame:StartMoving()
    end
end

local function Title_OnMouseUp(frame)
    local guide = frame.guide
    guide.frame:StopMovingOrSizing()
    if guide.docked then
        return
    end
    -- Only a free window next to the main one remembers where it was put;
    -- alone it always opens centred.
    if guide.mode == "free" then
        local saved = settings()
        if saved then
            saved.top, saved.left = guide.frame:GetTop(), guide.frame:GetLeft()
            saved.scale = guide.frame:GetScale() -- the units top / left are in
        end
    end
end

function Guide:Create()
    if self.frame then
        return self.frame
    end
    local frame = CreateFrame("Frame", NAME, UIParent)
    frame:Hide()
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetToplevel(true)
    frame:SetScript("OnMouseDown", function()
        AceGUI:ClearFocus()
    end)
    frame:SetScript("OnShow", function()
        setMainEscape(true)
    end)
    frame:SetScript("OnHide", function()
        self:OnHide()
    end)
    self.frame = frame
    if UISpecialFrames then
        table.insert(UISpecialFrames, NAME)
    end

    self.background = Theme.CreateBackground(frame)

    -- The frame art, over the content (like the main window's pipes).
    local art = CreateFrame("Frame", nil, frame)
    art:SetAllPoints(frame)
    art:SetFrameLevel(frame:GetFrameLevel() + 20)
    self.art = art
    local border = Theme.CreateSlice(art, "ARTWORK")
    border:SetHollow(true)
    border:SetPiece("guide-frame")
    self.border = border

    local leftCap = pieceTexture(art, "guide-edge-cap", "OVERLAY")
    leftCap:SetPoint("CENTER", frame, "LEFT", INSET, 0)
    local rightCap = pieceTexture(art, "guide-edge-cap", "OVERLAY")
    rightCap:SetPoint("CENTER", frame, "RIGHT", -INSET, 0)

    -- Title plate: centred on the top band; live text; the drag handle.
    local title = CreateFrame("Frame", nil, frame)
    local titleWidth, titleHeight = Theme.PieceSize("guide-title")
    title:SetWidth(titleWidth)
    title:SetHeight(titleHeight)
    title:SetPoint("CENTER", frame, "TOP", 0, -INSET)
    title:SetFrameLevel(art:GetFrameLevel() + 2)
    title:EnableMouse(true)
    title.guide = self
    title:SetScript("OnMouseDown", Title_OnMouseDown)
    title:SetScript("OnMouseUp", Title_OnMouseUp)
    local plate = title:CreateTexture(nil, "ARTWORK")
    Theme.SetPiece(plate, "guide-title")
    plate:SetAllPoints(title)
    local titleText = title:CreateFontString(nil, "OVERLAY")
    titleText:SetFontObject(GameFontNormal)
    if titleText.SetFont then
        titleText:SetFont(Theme.TITLE_FONT, Theme.TITLE_FONT_SIZES.guide or 15)
    end
    titleText:SetPoint("CENTER", title, "CENTER", 0, Theme.TITLE_LIFT.guide or 0)
    titleText:SetTextColor(unpack(Theme.colors.tabText))
    if titleText.SetShadowOffset then
        titleText:SetShadowOffset(0, 0)
    end
    titleText:SetText(TITLE)
    self.title = title
    self.titleText = titleText

    -- Close plate: replaces the top-right corner plate (it is a little
    -- larger, so the corner never shows around it). Layers: frame art, the
    -- close button, then the plate, so the button shows through its socket.
    local closeWidth, closeHeight = Theme.PieceSize("guide-close")
    local closeLayer = CreateFrame("Frame", nil, art)
    closeLayer:SetAllPoints(art)
    closeLayer:SetFrameLevel(art:GetFrameLevel() + 2)
    local closePlate = pieceTexture(closeLayer, "guide-close", "OVERLAY")
    closePlate:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    local hx0, hy0, hx1, hy1 = unpack(addon.ThemeData.guideCloseHole)
    local closeSize = math.ceil(math.max(hx1 - hx0, hy1 - hy0)) + 4
    local close = CreateFrame("Button", nil, frame)
    close:SetWidth(closeSize)
    close:SetHeight(closeSize)
    close:SetPoint("CENTER", frame, "TOPRIGHT", -closeWidth + (hx0 + hx1) / 2, -(hy0 + hy1) / 2)
    close:SetFrameLevel(art:GetFrameLevel() + 1)
    Theme.SetButtonPiece(close, "Normal", "close-normal")
    Theme.SetButtonPiece(close, "Pushed", "close-pressed")
    Theme.SetButtonPiece(close, "Highlight", "close-hover")
    Theme.HideHoverWhileHeld(close)
    close:SetScript("OnClick", function()
        if PlaySound then
            PlaySound("gsTitleOptionExit")
        end
        self:Hide()
    end)
    self.closeButton = close
    self.closePlate = closePlate

    -- Topic list: one row per page (wide), or one badge per page (compact).
    self.rows = {}
    self.badges = {}
    for index, page in ipairs(PAGES) do
        self.rows[index] = self:CreateRow(index, page)
        self.badges[index] = self:CreateBadge(index, page)
    end
    -- A header per part, over its pages' rows.
    self.parts = {}
    for index, page in ipairs(PAGES) do
        local last = self.parts[#self.parts]
        if last and last.key == page.part then
            last.last = index
        else
            local part = { key = page.part, first = index, last = index }
            part.header = self:CreatePartHeader(part)
            self.parts[#self.parts + 1] = part
        end
    end

    -- Page heading: number badge, title, riveted divider.
    local header = CreateFrame("Frame", nil, frame)
    header:SetHeight(HEADER_HEIGHT + pieceHeight("guide-divider"))
    local badge = pieceTexture(header, "guide-badge")
    badge:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0)
    local number = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    number:SetPoint("CENTER", badge, "CENTER", 0, 0)
    number:SetTextColor(unpack(Theme.colors.title))
    local heading = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    if heading.SetFont then
        heading:SetFont(Theme.TITLE_FONT, 17)
    end
    heading:SetPoint("LEFT", badge, "RIGHT", 10, 0)
    heading:SetPoint("RIGHT", header, "RIGHT", 0, 0)
    heading:SetJustifyH("LEFT")
    heading:SetTextColor(unpack(Theme.colors.title))
    local divider = CreateFrame("Frame", nil, header)
    divider:SetHeight(pieceHeight("guide-divider"))
    divider:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    divider:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    Theme.CreateSlice(divider, "ARTWORK"):SetPiece("guide-divider")
    local dividerCap = pieceTexture(divider, "guide-divider-cap", "OVERLAY")
    dividerCap:SetPoint("CENTER", divider, "CENTER", 0, 0)
    self.header, self.headerNumber, self.headerTitle = header, number, heading

    -- The page's blocks, in a scroll area with the themed bar.
    local scroll = CreateFrame("ScrollFrame", nil, frame)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        self:Scroll(-delta * SCROLL_STEP)
    end)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(1)
    content:SetHeight(1)
    scroll:SetScrollChild(content)
    -- The page's text and icons, on their own frame. Text inside a box
    -- (a table, a code example) is made on the box's own frame instead
    -- (Guide:Panel): frame levels set at creation do not reliably keep one
    -- frame above another later, but within one frame OVERLAY text always
    -- draws over the box's BACKGROUND art.
    local textLayer = CreateFrame("Frame", nil, content)
    textLayer:SetAllPoints(content)
    textLayer:SetFrameLevel(content:GetFrameLevel() + 3)
    self.textLayer = textLayer
    local bar = CreateFrame("Slider", "WMCGuideScrollBar", scroll, "UIPanelScrollBarTemplate")
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    bar:Hide()
    local up, down = Theme.ScrollBarButtons(bar)
    Theme.SkinScrollBar(bar, up, down)
    bar:SetScript("OnValueChanged", function(_, value)
        self:SetScroll(value)
    end)
    self.scroll, self.content, self.bar, self.upButton, self.downButton = scroll, content, bar, up, down

    -- Footer: previous / page n of N / next.
    local footer = CreateFrame("Frame", nil, frame)
    footer:SetHeight(FOOTER_HEIGHT)
    local prev = pieceButton(footer, "guide-prev")
    prev:SetPoint("BOTTOMLEFT", footer, "BOTTOMLEFT", 0, 0)
    prev:SetScript("OnClick", function()
        self:ShowPage(self.page - 1)
    end)
    local next = pieceButton(footer, "guide-next")
    next:SetPoint("BOTTOMRIGHT", footer, "BOTTOMRIGHT", 0, 0)
    next:SetScript("OnClick", function()
        self:ShowPage(self.page + 1)
    end)
    local count = footer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("CENTER", footer, "CENTER", 0, 0)
    count:SetTextColor(unpack(Theme.colors.dim))
    self.footer, self.prevButton, self.nextButton, self.pageCount = footer, prev, next, count

    -- Pools for the page's parts (reused page to page).
    self.pool = { fonts = {}, textures = {}, panels = {}, buttons = {} }
    self.probe = frame:CreateFontString(nil, "OVERLAY")
    self.probe:Hide()

    local saved = settings()
    self.page = saved and tonumber(saved.page) or 1
    return frame
end

function Guide:CreateRow(index, page)
    local row = CreateFrame("Button", nil, self.frame)
    row:SetHeight(pieceHeight("guide-row"))
    row.slice = Theme.CreateSlice(row, "BACKGROUND")
    row.slice:SetPiece("guide-row")
    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", row, "LEFT", 20, 0)
    text:SetPoint("RIGHT", row, "RIGHT", -12, 0)
    -- One line: a label too long for the row is cut short, not wrapped.
    text:SetHeight(12)
    text:SetJustifyH("LEFT")
    text:SetText(index .. "  " .. page.short)
    row.text = text
    row:SetScript("OnEnter", function()
        if self.page ~= index then
            row.slice:SetPiece("guide-row-hover")
        end
    end)
    row:SetScript("OnLeave", function()
        self:UpdateRow(index)
    end)
    row:SetScript("OnClick", function()
        self:ShowPage(index)
    end)
    return row
end

-- A part's header: its emblem, its name over a divider (wide); the emblem
-- alone, its name in a tooltip (compact). Opens the part's first page.
function Guide:CreatePartHeader(part)
    local meta = PARTS[part.key] or { label = part.key, icon = "guide-book" }
    local header = CreateFrame("Button", nil, self.frame)
    local icon = header:CreateTexture(nil, "ARTWORK")
    Theme.SetPiece(icon, meta.icon)
    icon:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0)
    header.icon = icon
    local divider = CreateFrame("Frame", nil, header)
    divider:SetHeight(pieceHeight("guide-divider"))
    divider:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", PART_LABEL_GAP, 0)
    divider:SetPoint("RIGHT", header, "RIGHT", 0, 0)
    Theme.CreateSlice(divider, "ARTWORK"):SetPiece("guide-divider")
    header.divider = divider
    local label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    if label.SetFont then
        label:SetFont(Theme.TITLE_FONT, 17)
    end
    label:SetPoint("BOTTOMLEFT", divider, "TOPLEFT", 0, 1)
    label:SetJustifyH("LEFT")
    label:SetTextColor(unpack(Theme.colors.title))
    label:SetText(meta.label)
    header.label = label
    header:SetScript("OnEnter", function()
        if self.compact then
            addon.Tooltip:SetOwner(header, "ANCHOR_RIGHT")
            addon.Tooltip:SetText(meta.label)
            addon.Tooltip:Show()
        end
    end)
    header:SetScript("OnLeave", function()
        addon.Tooltip:Hide()
    end)
    header:SetScript("OnClick", function()
        self:ShowPage(part.first)
    end)
    return header
end

function Guide:CreateBadge(index, page)
    local badge = CreateFrame("Button", nil, self.frame)
    local width, height = Theme.PieceSize("guide-badge")
    badge:SetWidth(width)
    badge:SetHeight(height)
    badge.art = badge:CreateTexture(nil, "BACKGROUND")
    Theme.SetPiece(badge.art, "guide-badge")
    badge.art:SetAllPoints(badge)
    local text = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("CENTER", badge, "CENTER", 0, 0)
    text:SetText(tostring(index))
    badge.text = text
    badge:SetScript("OnEnter", function()
        addon.Tooltip:SetOwner(badge, "ANCHOR_RIGHT")
        addon.Tooltip:SetText(index .. ". " .. page.title)
        addon.Tooltip:Show()
    end)
    badge:SetScript("OnLeave", function()
        addon.Tooltip:Hide()
    end)
    badge:SetScript("OnClick", function()
        self:ShowPage(index)
    end)
    return badge
end

function Guide:UpdateRow(index)
    local selected = index == self.page
    local row, badge = self.rows[index], self.badges[index]
    row.slice:SetPiece(selected and "guide-row-selected" or "guide-row")
    row.text:SetTextColor(unpack(selected and Theme.colors.tabText or Theme.colors.title))
    if row.text.SetShadowOffset then
        row.text:SetShadowOffset(selected and 0 or 1, selected and 0 or -1)
    end
    local shade = selected and 1 or 0.6
    badge.art:SetVertexColor(shade, shade, shade)
    badge.text:SetTextColor(unpack(selected and Theme.colors.title or Theme.colors.dim))
end

-- Sizes the window and lays out its parts for `width` x `height`.
function Guide:SetSize(width, height)
    local frame = self.frame
    width, height = math.floor(width), math.floor(height)
    frame:SetWidth(width)
    frame:SetHeight(height)
    self.width, self.height = width, height
    self.background:Layout(INSET, INSET, width - 2 * INSET, height - 2 * INSET)

    local compact = width < COMPACT_WIDTH
    self.compact = compact
    local listWidth = compact and Theme.PieceSize("guide-badge") or LIST_WIDTH
    local top = CONTENT.top
    -- Each part: its header, then its rows (or badges). The rows close up
    -- when the list would run past the bottom; badges then shrink too (19
    -- pages at 30 overran the docked height).
    local iconSize = compact and listWidth or pieceHeight(PARTS.compiler.icon)
    local rowHeight = pieceHeight(compact and "guide-badge" or "guide-row")
    local headers = #self.parts * (iconSize + PART_ROW_GAP) + (#self.parts - 1) * PART_GAP
    local room = height - top - CONTENT.bottom - headers
    local step = math.max(rowHeight, math.min(rowHeight + ROW_GAP, math.floor((room + ROW_GAP) / #PAGES)))
    if compact and #PAGES * rowHeight > room then
        rowHeight = math.floor(room / #PAGES)
        step = rowHeight
    end
    local y = top
    for partIndex, part in ipairs(self.parts) do
        if partIndex > 1 then
            y = y + PART_GAP
        end
        local header = part.header
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", frame, "TOPLEFT", CONTENT.left, -y)
        header:SetWidth(listWidth)
        header:SetHeight(iconSize)
        header.icon:SetWidth(iconSize)
        header.icon:SetHeight(iconSize)
        if compact then
            header.label:Hide()
            header.divider:Hide()
        else
            header.label:Show()
            header.divider:Show()
        end
        header:Show()
        y = y + iconSize + PART_ROW_GAP
        for index = part.first, part.last do
            local row, badge = self.rows[index], self.badges[index]
            row:ClearAllPoints()
            badge:ClearAllPoints()
            if compact then
                row:Hide()
                badge:SetPoint("TOPLEFT", frame, "TOPLEFT", CONTENT.left + (listWidth - rowHeight) / 2, -y)
                badge:SetWidth(rowHeight)
                badge:SetHeight(rowHeight)
                badge:Show()
            else
                badge:Hide()
                row:SetPoint("TOPLEFT", frame, "TOPLEFT", CONTENT.left, -y)
                row:SetWidth(listWidth)
                row:Show()
            end
            y = y + step
        end
        y = y - step + rowHeight
    end

    -- The page column.
    local left = CONTENT.left + listWidth + LIST_GAP
    local pageWidth = width - left - CONTENT.right
    self.pageLeft, self.pageWidth = left, pageWidth
    self.header:ClearAllPoints()
    self.header:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -top)
    self.header:SetWidth(pageWidth - BAR_SPACE)
    local scrollTop = top + HEADER_HEIGHT + pieceHeight("guide-divider") + HEADER_GAP
    local scrollBottom = CONTENT.bottom + FOOTER_HEIGHT + 4
    self.textWidth = pageWidth - BAR_SPACE
    self.viewHeight = height - scrollTop - scrollBottom
    self.scroll:ClearAllPoints()
    self.scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -scrollTop)
    self.scroll:SetWidth(self.textWidth)
    self.scroll:SetHeight(self.viewHeight)
    self.content:SetWidth(self.textWidth)
    local size = Theme.SCROLLBAR_WIDTH
    self.bar:ClearAllPoints()
    self.bar:SetPoint("TOPLEFT", self.scroll, "TOPRIGHT", BAR_SPACE - size, -size)
    self.bar:SetPoint("BOTTOMLEFT", self.scroll, "BOTTOMRIGHT", BAR_SPACE - size, size)
    self.footer:ClearAllPoints()
    self.footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", left, CONTENT.bottom)
    self.footer:SetWidth(pageWidth - BAR_SPACE)
    if self.rendered and self.renderedWidth ~= self.textWidth then
        self:RenderPage()
    end
end

--[[ Placement ]]

-- Slides the main window so its left edge is at `left` (not saved: the
-- guide puts it back when it closes).
function Guide:SlideMain(left)
    local main = mainFrame()
    local top = main:GetTop()
    if not top then
        return
    end
    main:ClearAllPoints()
    main:SetPoint("TOP", UIParent, "BOTTOM", 0, top)
    main:SetPoint("LEFT", UIParent, "LEFT", left, 0)
    self.slid = self.host
end

-- Puts the main window back where it was before the guide slid it.
function Guide:RestoreMain()
    local window = self.slid and HOSTS[self.slid].window()
    self.slid = false
    if window then
        window:ApplyStatus()
    end
end

-- Chooses the guide's place and size (see the header).
function Guide:Place()
    local frame = self.frame
    local height = Theme.FrameData("main").height
    local room = Theme.RoomFor(frame) -- in the guide's units (its own scale)
    frame:ClearAllPoints()
    self.docked = false
    if not mainShown() then
        self.mode = "alone"
        self:SetSize(math.min(WIDTH, room), height)
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        return
    end
    local main = mainFrame()
    setMainEscape(true)
    local offset = main:GetWidth() + mainOverhang() + DOCK_GAP
    local width = math.min(WIDTH, room - offset)
    if width >= MIN_WIDTH then
        local left = main:GetLeft() or 0
        if left + offset + width > room then
            self:SlideMain(math.max(0, room - offset - width))
        end
        self.mode = "docked"
        self.docked = true
        self:SetSize(width, main:GetHeight())
        frame:SetPoint("TOPLEFT", main, "TOPRIGHT", offset - main:GetWidth(), 0)
        return
    end
    -- No room beside it: a free window over the main window's right side.
    self.mode = "free"
    self:RestoreMain()
    self:SetSize(math.min(WIDTH, room), height)
    local saved = settings()
    if saved and saved.top and saved.left then
        -- saved at another scale (or before the guide had one): the same spot
        local ratio = (saved.scale or 1) / frame:GetScale()
        frame:SetPoint("TOP", UIParent, "BOTTOM", 0, saved.top * ratio)
        frame:SetPoint("LEFT", UIParent, "LEFT", saved.left * ratio, 0)
    else
        frame:SetPoint("TOPRIGHT", main, "TOPRIGHT", mainOverhang(), 0)
    end
end

-- A host was dragged: the pair may need to slide again.
function Guide:MainMoved(key)
    if self.frame and self.frame:IsShown() and self.docked and self.host == (key or "main") then
        self.slid = false
        self:Place()
    end
end

-- Hooks a host's show and hide (UI:Initialize and BankUI:Build call this).
function Guide:Attach(key, main)
    if not main or main.wmcGuideHooked then
        return
    end
    main.wmcGuideHooked = true
    main:HookScript("OnShow", function()
        if self.frame and self.frame:IsShown() and self.host == key then
            self:Place()
        end
    end)
    main:HookScript("OnHide", function()
        if not (self.frame and self.frame:IsShown()) or self.host ~= key then
            return
        end
        -- Stay where it is, now on its own.
        local left, top = self.frame:GetLeft(), self.frame:GetTop()
        self.slid = false
        self.docked = false
        self.mode = "alone"
        if left and top then
            self.frame:ClearAllPoints()
            self.frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        end
    end)
end

function Guide:AttachMain(main)
    self:Attach("main", main)
end

--[[ Show / hide ]]

-- host: the window it docks to (HOSTS); by default the main window when
-- shown, else the Macros window when shown.
function Guide:Show(page, host)
    self:Create()
    if page then
        self.page = page
    end
    if not host then
        host = (hostFrame("main") and hostFrame("main"):IsShown() and "main")
            or (hostFrame("bank") and hostFrame("bank"):IsShown() and "bank") or "main"
    end
    if host ~= self.host then
        self:RestoreMain()
        self.host = host
    end
    Theme.ScalePopup(self.frame) -- the windows' scale (Theme.lua)
    self:Place()
    self.frame:Show()
    if self.frame.Raise then
        self.frame:Raise()
    end
    self:ShowPage(self.page)
end

function Guide:Hide()
    if self.frame then
        self.frame:Hide()
    end
end

function Guide:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

function Guide:Toggle(page)
    if self:IsShown() and not page then
        self:Hide()
    else
        self:Show(page)
    end
end

-- The part's first page.
function Guide:FirstPage(part)
    for index, page in ipairs(PAGES) do
        if page.part == part then
            return index
        end
    end
    return 1
end

-- A window's book: the guide beside `host`, at `part` (the page last read
-- there when it is of that part); hides it when already shown there.
function Guide:ToggleFor(host, part)
    if self:IsShown() and self.host == host then
        self:Hide()
        return
    end
    self:Create()
    local current = PAGES[self.page]
    self:Show((current and current.part == part) and self.page or self:FirstPage(part), host)
end

function Guide:OnHide()
    addon.Tooltip:Hide()
    self:RestoreMain()
    self.docked = false
    escapeFrame:Show()
end

--[[ Pages ]]

function Guide:ShowPage(index)
    index = math.max(1, math.min(#PAGES, tonumber(index) or 1))
    self.page = index
    local saved = settings()
    if saved then
        saved.page = index
    end
    local page = PAGES[index]
    self.headerNumber:SetText(tostring(index))
    self.headerTitle:SetText(page.title)
    self.pageCount:SetText("Page " .. index .. " of " .. #PAGES)
    if index > 1 then self.prevButton:Enable() else self.prevButton:Disable() end
    if index < #PAGES then self.nextButton:Enable() else self.nextButton:Disable() end
    for row = 1, #PAGES do
        self:UpdateRow(row)
    end
    self:RenderPage()
    self.bar:SetValue(0)
    self:SetScroll(0)
end

function Guide:Scroll(delta)
    local value = (self.scrollValue or 0) + delta
    self.bar:SetValue(math.max(0, math.min(self.scrollMax or 0, value)))
end

-- Scrolls by moving the content (as WMC-ScrollFrame does): the client
-- updates a scroll frame's own range only lazily.
function Guide:SetScroll(value)
    value = math.max(0, math.min(self.scrollMax or 0, value or 0))
    self.scrollValue = value
    self.content:ClearAllPoints()
    self.content:SetPoint("TOPLEFT", self.scroll, "TOPLEFT", 0, value)
    local up, down = self.upButton, self.downButton
    if up and down then
        if value > 0 then up:Enable() else up:Disable() end
        if value < (self.scrollMax or 0) then down:Enable() else down:Disable() end
    end
end

--[[ Rendering ]]

local function take(list, create)
    list.used = (list.used or 0) + 1
    local item = list[list.used]
    if not item then
        item = create()
        list[list.used] = item
    end
    return item
end

local function releaseRegions(owner)
    for _, kind in ipairs({ "fonts", "textures" }) do
        for index = 1, #owner[kind] do
            owner[kind][index]:Hide()
            owner[kind][index]:ClearAllPoints()
        end
        owner[kind].used = 0
    end
end

function Guide:ReleaseParts()
    local pool = self.pool
    self.owner = nil
    releaseRegions(pool)
    for index = 1, #pool.panels do
        pool.panels[index].frame:Hide()
        releaseRegions(pool.panels[index])
    end
    pool.panels.used = 0
    for _, button in ipairs(pool.buttons) do
        AceGUI:Release(button)
    end
    pool.buttons = {}
end

-- Where new text and textures are made: the box being filled (self.owner,
-- a Panel record), else the page's text layer.
function Guide:Owner()
    return self.owner or self.pool, self.owner and self.owner.frame or self.textLayer
end

-- A font string on the page: `text` wrapped to `width`, its top-left at
-- (x, y) units from the page's top-left. Returns it and its height.
function Guide:Text(fontObject, text, x, y, width, color)
    local content = self.content
    local owner, frame = self:Owner()
    local fontString = take(owner.fonts, function()
        return frame:CreateFontString(nil, "OVERLAY")
    end)
    fontString:SetFontObject(fontObject)
    fontString:SetJustifyH("LEFT")
    if fontString.SetJustifyV then
        fontString:SetJustifyV("TOP")
    end
    if fontString.SetNonSpaceWrap then
        fontString:SetNonSpaceWrap(fontObject == Theme.textFont)
    end
    fontString:SetTextColor(unpack(color or Theme.colors.text))
    fontString:SetWidth(width)
    fontString:SetText(text)
    fontString:ClearAllPoints()
    fontString:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
    fontString:Show()
    return fontString, textHeight(fontString)
end

function Guide:Texture(x, y, width, height)
    local content = self.content
    local owner, frame = self:Owner()
    local texture = take(owner.textures, function()
        return frame:CreateTexture(nil, "ARTWORK")
    end)
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
    texture:SetWidth(width)
    texture:SetHeight(height)
    texture:SetVertexColor(1, 1, 1, 1)
    texture:Show()
    return texture
end

function Guide:Icon(piece, x, y)
    local width, height = Theme.PieceSize(piece)
    local texture = self:Texture(x, y, width, height)
    Theme.SetPiece(texture, piece)
    return texture
end

-- A box (the "panel" piece) behind a code example or a table; its text
-- and bands are made on its own frame (`fonts`, `textures`: see Owner).
function Guide:Panel(x, y, width, height, tint)
    local content = self.content
    local panel = take(self.pool.panels, function()
        local frame = CreateFrame("Frame", nil, content)
        return { frame = frame, slice = Theme.CreatePanel(frame), fonts = {}, textures = {} }
    end)
    panel.frame:ClearAllPoints()
    panel.frame:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
    panel.frame:SetWidth(width)
    panel.frame:SetHeight(height)
    panel.slice:SetVertexColor(tint, tint, tint)
    panel.frame:Show()
    return panel
end

function Guide:Button(text, x, y, width, onClick)
    local button = AceGUI:Create("WMC-Button")
    button:SetText(text)
    button:SetWidth(width)
    button:SetCallback("OnClick", onClick)
    button.frame:SetParent(self.content)
    -- Created on UIParent by AceGUI: set the strata, don't inherit it.
    button.frame:SetFrameStrata(self.frame:GetFrameStrata())
    button.frame:SetFrameLevel(self.textLayer:GetFrameLevel() + 1)
    button.frame:ClearAllPoints()
    button.frame:SetPoint("TOPLEFT", self.content, "TOPLEFT", x, -y)
    button.frame:Show()
    table.insert(self.pool.buttons, button)
    return button
end

-- The unwrapped width of `text` in `fontObject`.
function Guide:Measure(fontObject, text)
    local probe = self.probe
    probe:SetFontObject(fontObject)
    probe:SetText(text)
    local width = probe.GetStringWidth and probe:GetStringWidth()
    if type(width) ~= "number" then
        width = #text * 6
    end
    return math.ceil(width)
end

-- Column widths for a table `total` units wide: a column whose text fits in
-- an equal share of what is left keeps its natural width; the others share
-- the rest and wrap. Spare room goes to the last column.
local function columnWidths(natural, total)
    local count = #natural
    local widths, fixed = {}, {}
    local remaining, open = total, count
    local changed = true
    while changed and open > 0 do
        changed = false
        local share = remaining / open
        for column = 1, count do
            if not fixed[column] and natural[column] <= share then
                fixed[column] = true
                widths[column] = natural[column]
                remaining = remaining - natural[column]
                open = open - 1
                changed = true
            end
        end
    end
    for column = 1, count do
        if not fixed[column] then
            widths[column] = math.floor(remaining / open)
        end
    end
    if open == 0 then
        widths[count] = widths[count] + remaining
    end
    return widths
end
Guide.ColumnWidths = columnWidths

local renderers = {}

function renderers.heading(self, block, y, width)
    local _, height = self:Text(GameFontNormal, block.text, 0, y + HEADING_GAP, width, Theme.colors.title)
    return HEADING_GAP + height
end

function renderers.para(self, block, y, width)
    local _, height = self:Text(GameFontHighlight, block.text, 0, y, width)
    return height
end

-- A paragraph with an icon at its left.
local function iconText(self, piece, text, y, width)
    local iconWidth, iconHeight = Theme.PieceSize(piece)
    self:Icon(piece, 0, y)
    local left = iconWidth + ICON_GAP
    local _, height = self:Text(GameFontHighlight, text, left, y + 2, width - left)
    return math.max(iconHeight, height + 2), left
end

function renderers.tip(self, block, y, width)
    return (iconText(self, "guide-tip", block.text, y, width))
end

function renderers.list(self, block, y, width)
    local top = y
    for index, item in ipairs(block.items) do
        local marker = block.ordered and (index .. ".") or "\226\128\162" -- bullet
        self:Text(GameFontNormal, marker, block.ordered and 0 or 4, y, LIST_INDENT, Theme.colors.title)
        local _, height = self:Text(GameFontHighlight, item, LIST_INDENT, y, width - LIST_INDENT)
        y = y + height + LIST_ITEM_GAP
    end
    return y - top - LIST_ITEM_GAP
end

function renderers.code(self, block, y, width)
    local highlight = addon.UI and addon.UI.HighlightSource
    local text = highlight and highlight(block.source) or block.source
    local panel = self:Panel(0, y, width, 1, CODE_TINT)
    self.owner = panel
    local _, height = self:Text(Theme.TextFont(), text, CODE_PAD_X, y + CODE_PAD_Y, width - 2 * CODE_PAD_X)
    self.owner = nil
    height = height + 2 * CODE_PAD_Y
    panel.frame:SetHeight(height)
    return height
end

function renderers.table(self, block, y, width)
    local rows = { block.header }
    for _, row in ipairs(block.rows) do
        rows[#rows + 1] = row
    end
    local columns = #block.header
    local natural = {}
    for column = 1, columns do
        natural[column] = 0
        for index, row in ipairs(rows) do
            local font = index == 1 and GameFontNormalSmall or GameFontHighlightSmall
            natural[column] = math.max(natural[column], self:Measure(font, row[column] or "") + 2 * CELL_PAD_X)
        end
    end
    local inner = width - 4
    local widths = columnWidths(natural, inner)
    local top = y
    local panel = self:Panel(0, top, width, 1, 1)
    self.owner = panel
    y = y + 2
    for index, row in ipairs(rows) do
        local header = index == 1
        local font = header and GameFontNormalSmall or GameFontHighlightSmall
        local x, rowHeight = 2, 0
        local cells = {}
        for column = 1, columns do
            local cell, height = self:Text(font, row[column] or "", x + CELL_PAD_X, y + CELL_PAD_Y,
                widths[column] - 2 * CELL_PAD_X, header and Theme.colors.title or Theme.colors.text)
            cells[column] = cell
            rowHeight = math.max(rowHeight, height)
            x = x + widths[column]
        end
        rowHeight = rowHeight + 2 * CELL_PAD_Y
        -- Header band, then faint bands on every other row.
        if header or index % 2 == 1 then
            local band = self:Texture(2, y, inner, rowHeight)
            band:SetTexture(header and 0 or 1, header and 0 or 1, header and 0 or 1, 1)
            band:SetVertexColor(1, 1, 1, header and 0.35 or 0.05)
        end
        y = y + rowHeight
    end
    y = y + 2
    self.owner = nil
    panel.frame:SetHeight(y - top)
    return y - top
end

function renderers.try(self, block, y, width)
    if not block.example then
        return (iconText(self, "guide-warning", block.text, y, width))
    end
    local iconWidth, iconHeight = Theme.PieceSize("guide-try")
    self:Icon("guide-try", 0, y)
    local left = iconWidth + ICON_GAP
    local _, height = self:Text(GameFontHighlight, block.text, left, y + 2, width - left)
    local buttonsTop = y + 2 + height + 6
    local states = block.states
    local page = self.page
    local count = math.max(1, #states)
    for index = 1, count do
        local label = #states > 1 and ("Try " .. index) or "Try it"
        self:Button(label, left + (index - 1) * (TRY_BUTTON_WIDTH + TRY_BUTTON_GAP), buttonsTop,
            TRY_BUTTON_WIDTH, function()
                self:Try(page, block, states[index])
            end)
    end
    return math.max(iconHeight, buttonsTop - y + BUTTON_HEIGHT)
end

-- Lays out the current page's blocks at the current width.
function Guide:RenderPage()
    if not self.frame or not self.textWidth then
        return
    end
    self:ReleaseParts()
    local page = PAGES[self.page]
    local width = self.textWidth
    local y = 0
    for index, block in ipairs(page.blocks) do
        if index > 1 then
            y = y + BLOCK_GAP
        end
        y = y + renderers[block.kind](self, block, y, width)
    end
    y = y + BLOCK_GAP
    self.content:SetHeight(math.max(1, y))
    self.contentHeight = y
    self.rendered = true
    self.renderedWidth = width
    self.scrollMax = math.max(0, math.ceil(y - self.viewHeight))
    self.bar:SetMinMaxValues(0, self.scrollMax)
    if self.scrollMax > 0 then
        self.bar:Show()
    else
        self.bar:Hide()
    end
    self:SetScroll(math.min(self.scrollValue or 0, self.scrollMax))
end

-- The source of the page's `n`th code block.
function Guide:Example(pageIndex, n)
    local count = 0
    for _, block in ipairs(PAGES[pageIndex].blocks) do
        if block.kind == "code" then
            count = count + 1
            if count == n then
                return block.source
            end
        end
    end
end

-- Try it: the example as a new GENERAL template, previewed as `state`.
function Guide:Try(pageIndex, block, state)
    local source = self:Example(pageIndex, block.example)
    if source and addon.UI then
        addon.UI:OpenExample(source, state, "guide" .. pageIndex)
    end
end
